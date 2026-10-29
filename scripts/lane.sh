#!/usr/bin/env bash
# chargehand-lane: a verify lane's controller, the only process that talks to this machine's
# container runtime. Run as the lane's dedicated user (the requester calls it over SSH).
# Usage: chargehand-lane verify --project <name> <sha>
#   Builds and tests <sha> from <repos_dir>/<name>.git in an untrusted runner container: restore
#   with outbound network, then build and suites on a private internal network with the project's
#   services. Config: $HARNESS_CONFIG_DIR/lane.json (shape: examples/lane.json).
#   Exit 0 passed; 10 the build or a suite failed or timed out (or a service never got ready);
#   3 another verify is running on this machine; 4 the container runtime is unavailable;
#   2 usage or config (also: the commit is not in the lane's repo); other: could not run.
#   Stdout: "Verifying <sha7> <subject>" once the machine lock is held, the runner's output, then
#   "digests: runner=<sha256> <service>=<sha256> ...".
set -uo pipefail
LANE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
. "$LANE_LIB/harness.sh"
. "$LANE_LIB/lane.sh"
. "$LANE_LIB/runtime.sh"

usage() { sed -n '4,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
cant_run() { echo "chargehand-lane: $*" >&2; exit 1; }
runtime_unavailable() { echo "chargehand-lane: the container runtime is unavailable ($CHARGEHAND_RUNTIME)" >&2; exit 4; }

# env_args JSON_OBJECT: prints --env and K=V, one per line, for mapfile.
env_args() { jq -r 'to_entries[] | "--env", "\(.key)=\(.value)"' <<<"$1"; }

# The run's state, for the EXIT trap. Containers and the network are recorded before they are
# created, so a half-created one is removed too.
STARTED=() NETWORK="" RUN_DIR="" RUNNER_DIGEST="" SERVICE_DIGESTS=() FOLLOW_PID=""

record_digest() {   # record_digest NAME IMAGE
    local d; d="$(rt_image_digest "$2" 2>/dev/null)" || d=unavailable
    if [ "$1" = runner ]; then RUNNER_DIGEST="$d"; else SERVICE_DIGESTS+=("$1=$d"); fi
}

cleanup() {
    local rc=$? c line
    trap - EXIT
    stop_follow
    for c in "${STARTED[@]}"; do rt_rm "$c"; done
    if [ -n "$NETWORK" ]; then
        rt_network_rm "$NETWORK" >/dev/null 2>&1 || echo "chargehand-lane: could not remove network $NETWORK (the next verify retries)" >&2
    fi
    if [ -n "$RUN_DIR" ]; then
        rm -rf "$RUN_DIR" || echo "chargehand-lane: could not remove $RUN_DIR" >&2
    fi
    if [ "${#STARTED[@]}" -gt 0 ]; then
        line="digests:"
        [ -n "$RUNNER_DIGEST" ] && line+=" runner=$RUNNER_DIGEST"
        for c in "${SERVICE_DIGESTS[@]}"; do line+=" $c"; done
        echo "$line"
    fi
    exit "$rc"
}

# stop_follow: ends the output stream, the runtime CLI included: an orphaned `logs -f` would keep
# this process's stdout (the requester's SSH session) open.
stop_follow() {
    [ -n "$FOLLOW_PID" ] || return 0
    pkill -P "$FOLLOW_PID" 2>/dev/null; kill "$FOLLOW_PID" 2>/dev/null; wait "$FOLLOW_PID" 2>/dev/null; FOLLOW_PID=""
}

# drain_follow NAME: once the runner has stopped, gives its stream DRAIN_SEC to end, then stops it.
drain_follow() {
    local end=$((SECONDS + DRAIN_SEC))
    while kill -0 "$FOLLOW_PID" 2>/dev/null && [ "$SECONDS" -lt "$end" ]; do sleep 0.2; done
    if kill -0 "$FOLLOW_PID" 2>/dev/null; then
        echo "chargehand-lane: the output stream of $1 did not end after $DRAIN_SEC s; stopped it" >&2
        stop_follow
        return
    fi
    wait "$FOLLOW_PID" || echo "chargehand-lane: could not stream the output of $1" >&2
    FOLLOW_PID=""
}

# minutes EXPR: awk arithmetic on minutes (fractions allowed), printed short (0.06, 95).
minutes() { awk "BEGIN { printf \"%g\", $1 }"; }

# wait_runner NAME PHASE MINUTES: streams the runner's output while it runs and sets RUNNER_RC to
# its exit code (from rt_wait, not from the stream). The runner's own timeouts run inside code under
# test, which can kill or outlive them, so the controller holds its own deadline: past MINUTES the
# runner is removed and the verify fails.
wait_runner() {
    local c="$1" phase="$2" mins="$3" code rc=0
    rt_logs_follow "$c" 2>&1 9>&- &
    FOLLOW_PID=$!
    code="$(timeout "$(minutes "$mins * 60")" bash -c '. "$1/runtime.sh"; rt_wait "$2"' _ "$LANE_LIB" "$c" 9>&-)" || rc=$?
    if [ "$rc" -eq 124 ]; then
        rt_rm "$c"
        stop_follow
        echo "TIMED OUT (controller) after $mins min: $phase"
        exit 10
    fi
    # A failed wait says nothing about the container, which may still run: never wait on its stream.
    [ "$rc" -eq 0 ] || { stop_follow; cant_run "could not wait for $c"; }
    # The stream ends when the container stops, so its output is out before the verdict; bounded all
    # the same, in case the runtime's `logs -f` does not end.
    drain_follow "$c"
    [[ "$code" =~ ^[0-9]+$ ]] || cant_run "no exit code from $c"
    RUNNER_RC="$code"
}

# verdict RUNNER_RC OUT_DIR TEST_COUNT: the verify's exit code, 0 only if the runner exited 0 and
# out/suites.txt ("<index> <exit-code> <summary-line-count>", one line per suite) shows every suite
# with exit code 0 and exactly one summary line. A runner that exits 0 without running the suites
# (or without a summary) fails, naming the suite and the reason. suites.txt is runner-written, so
# this catches a broken runner, not a hostile one that forges the file.
verdict() {
    local rc="$1" out="$2" want="$3" bad=0 n=0 idx code count extra
    if [ "$rc" -ne 0 ]; then bad=1; fi
    if [ -f "$out/suites.txt" ]; then
        while read -r idx code count extra; do
            [ -n "$idx" ] || continue
            n=$((n + 1))
            if [ "$idx" != "$n" ] || ! [[ "$code" =~ ^[0-9]+$ && "$count" =~ ^[0-9]+$ && -z "$extra" ]]; then
                echo "suite $n: malformed result line"; bad=1; continue
            fi
            if [ "$code" -ne 0 ]; then echo "suite $n: exit code $code"; bad=1
            elif [ "$count" -eq 0 ]; then echo "suite $n: no summary line"; bad=1
            elif [ "$count" -ne 1 ]; then echo "suite $n: $count summary lines"; bad=1; fi
        done < "$out/suites.txt"
    fi
    if [ "$n" -gt "$want" ]; then echo "suites.txt has $n results for $want suites"; bad=1; fi
    while [ "$n" -lt "$want" ]; do n=$((n + 1)); echo "suite $n: no result"; bad=1; done
    [ "$bad" -eq 0 ] && return 0
    return 10
}

verify() {
    [ "${1:-}" = --project ] && [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    local project="$2" sha="$3"
    valid_name "$project" || die "bad project name \"$project\""
    [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]] || die "bad commit \"$sha\" (expected a hexadecimal SHA)"
    lane_check
    local runtime work_dir repos_dir cpus memory timeout_min runner_image
    runtime="$(lane_get .runtime)" || exit 2
    export CHARGEHAND_RUNTIME="$runtime"
    work_dir="$(lane_get .work_dir)" || exit 2
    repos_dir="$(lane_get .repos_dir)" || exit 2
    cpus="$(lane_get .cpus)" || exit 2
    memory="$(lane_get .memory)" || exit 2
    timeout_min="$(lane_get .verify_timeout_min)" || exit 2
    runner_image="$(lane_project_get "$project" .runner_image)" || exit 2
    # The controller's grace on top of the runner's own timeouts (ruling R7: 5 min). Tests shorten it.
    local grace_sec="${CHARGEHAND_LANE_GRACE_SEC:-300}"
    [[ "$grace_sec" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "CHARGEHAND_LANE_GRACE_SEC must be a number of seconds"
    # How long a stopped runner's output stream may take to end. Tests shorten it.
    DRAIN_SEC="${CHARGEHAND_LANE_DRAIN_SEC:-30}"
    [[ "$DRAIN_SEC" =~ ^[0-9]+$ ]] || die "CHARGEHAND_LANE_DRAIN_SEC must be a whole number of seconds"

    # 1. One verify at a time on this machine, for the whole verify.
    mkdir -p "$work_dir" || cant_run "cannot create $work_dir"
    exec 9>"$work_dir/suite.lock"
    flock -n 9 || { echo "chargehand-lane: another verify is running on this machine" >&2; exit 3; }
    trap cleanup EXIT
    trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM

    # 2. Whatever a killed verify left behind. Only the lane uses the runtime on this machine, so
    # everything labelled chargehand=1 is the lane's.
    local leftovers c
    leftovers="$(rt_ls_labelled chargehand=1)" || runtime_unavailable
    while IFS= read -r c; do [ -n "$c" ] && rt_rm "$c"; done <<<"$leftovers"
    leftovers="$(rt_networks_labelled chargehand=1)" || runtime_unavailable
    while IFS= read -r c; do [ -n "$c" ] && { rt_network_rm "$c" >/dev/null 2>&1 || true; }; done <<<"$leftovers"

    # 3. The commit must already be in the lane's repo (the requester pushes it).
    local repo="$repos_dir/$project.git" sha7 subject
    git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null || { echo "chargehand-lane: commit $sha not in $repo" >&2; exit 2; }
    sha="$(git -C "$repo" rev-parse --verify -q "$sha^{commit}")" || cant_run "cannot resolve $sha in $repo"
    sha7="${sha:0:7}"
    subject="$(git -C "$repo" log -1 --format=%s "$sha")"
    echo "Verifying $sha7 $subject"

    # 4. A fresh checkout every run, hooks off. --no-hardlinks: the runner can write to the
    # checkout, so its objects must not be the repo's own files. A local clone copies every object,
    # so a commit that sits only under refs/verify/ is there too.
    RUN_DIR="$work_dir/run-$sha7"
    local src="$RUN_DIR/src" out="$RUN_DIR/out" recipe="$RUN_DIR/recipe" cache="$work_dir/cache/$project" msg
    rm -rf "$RUN_DIR" || cant_run "cannot remove the old $RUN_DIR"
    mkdir -p "$out" "$recipe" "$cache" || cant_run "cannot create $RUN_DIR"
    msg="$(git -c core.hooksPath=/dev/null clone -q --no-checkout --no-hardlinks "$repo" "$src" 2>&1)" \
        || cant_run "clone of $repo failed: $msg"
    msg="$(git -C "$src" -c core.hooksPath=/dev/null checkout -q --detach "$sha" 2>&1)" \
        || cant_run "checkout of $sha failed: $msg"

    # The recipe reaches the runner as files, never on a command line.
    lane_project_get "$project" .restore > "$recipe/restore" || exit 2
    lane_project_get "$project" .build > "$recipe/build" || exit 2
    lane_project_get "$project" .tests | jq -r '.[]' > "$recipe/tests" || exit 2
    lane_project_get "$project" .test_filter "" > "$recipe/filter" || exit 2
    lane_project_get "$project" .summary_pattern "" > "$recipe/summary" || exit 2
    printf '%s\n' "$timeout_min" > "$recipe/timeout_min"

    # 5. The run's private network: no outbound access.
    NETWORK="chv-$sha7"
    rt_network_create "$NETWORK" yes >/dev/null || cant_run "could not create network $NETWORK"

    # 6. Services, named after themselves (their host names on the network), then wait for each.
    # Every rt_run closes fd 9: a runtime helper that outlives this process (conmon, a network
    # namespace holder) must not keep the machine lock.
    local count i name image envs readies=() names=() timeouts=() ready tmo deadline
    count="$(lane_project_get "$project" '.services | length' 0)" || exit 2
    for ((i = 0; i < count; i++)); do
        name="$(lane_project_get "$project" ".services[$i].name")" || exit 2
        valid_name "$name" || die "bad service name \"$name\" in project $project"
        image="$(lane_project_get "$project" ".services[$i].image")" || exit 2
        mapfile -t envs < <(env_args "$(lane_project_get "$project" ".services[$i].env" '{}')")
        STARTED+=("$name")
        rt_run "$name" "$image" "$NETWORK" 1 "$(lane_project_get "$project" ".services[$i].memory" 1g)" \
            "${envs[@]}" -- >/dev/null 9>&- || cant_run "could not start service $name"
        record_digest "$name" "$image"
        names+=("$name")
        readies+=("$(lane_project_get "$project" ".services[$i].ready" '[]')")
        timeouts+=("$(lane_project_get "$project" ".services[$i].ready_timeout_sec" 60)")
    done
    for ((i = 0; i < count; i++)); do
        mapfile -t ready < <(jq -r '.[]' <<<"${readies[$i]}")
        [ "${#ready[@]}" -gt 0 ] || continue
        tmo="${timeouts[$i]%.*}"; [ "${tmo:-0}" -gt 0 ] || tmo=1
        deadline=$((SECONDS + tmo))
        until rt_exec "${names[$i]}" -- "${ready[@]}" >/dev/null 2>&1; do
            if [ "$SECONDS" -ge "$deadline" ]; then echo "service ${names[$i]} not ready after ${timeouts[$i]} s"; exit 10; fi
            sleep 1
        done
    done

    # 7. Restore: the only phase with outbound network.
    c="chv-$sha7-restore"
    STARTED+=("$c")
    rt_run "$c" "$runner_image" "$(rt_default_network)" "$cpus" "$memory" \
        --mount "$src:/work" --mount "$recipe:/recipe:ro" --mount "$cache:/cache" \
        --env NUGET_PACKAGES=/cache/nuget --workdir /work -- chargehand-run restore >/dev/null 9>&- \
        || cant_run "could not start $c"
    record_digest runner "$runner_image"
    wait_runner "$c" restore "$(minutes "$timeout_min + $grace_sec / 60")"
    [ "$RUNNER_RC" -eq 0 ] || { echo "RESTORE FAILED"; exit 10; }

    # 8. Build and suites on the private network only, the cache read-only.
    c="chv-$sha7-suites"
    mapfile -t envs < <(env_args "$(lane_project_get "$project" .env '{}')")
    STARTED+=("$c")
    rt_run "$c" "$runner_image" "$NETWORK" "$cpus" "$memory" \
        --mount "$src:/work" --mount "$recipe:/recipe:ro" --mount "$cache:/cache:ro" --mount "$out:/out" \
        "${envs[@]}" --workdir /work -- chargehand-run suites >/dev/null 9>&- \
        || cant_run "could not start $c"
    wait_runner "$c" suites "$(minutes "$timeout_min * (1 + $(grep -c . "$recipe/tests")) + $grace_sec / 60")"

    # 9. Verdict; 10. the EXIT trap cleans up and prints the digests.
    verdict "$RUNNER_RC" "$out" "$(grep -c . "$recipe/tests")"
    exit $?
}

case "${1:-}" in
    verify) shift; verify "$@" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
