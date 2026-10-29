. "$(dirname "$0")/lib.sh"
# chargehand-lane verify (scripts/lane.sh) against the fake runtime (tests/fake_runtime.sh).
D0=0000000000000000000000000000000000000000000000000000000000000000

# lane_setup [jq-filter]: a lane.json (podman, project "demo" with one service "db"), a bare repo
# with one commit that sits only under refs/verify/ (as the requester pushes it), and the fake
# runtime behind a wrapper: `wait` on the suites runner prints $SUITES_RC (default 0), and the
# suites `run` copies its /recipe mount to $TEST_TMP/recipe-copy before the run dir is removed
# and writes $SUITES_TXT (default: two clean suites) to suites.txt in its /out mount.
lane_setup() {
    jq -n --arg d "$D0" '{
        runtime: "podman", cpus: 3, memory: "6g",
        repos_dir: "~/lane/repos", work_dir: "~/lane/work", verify_timeout_min: 45,
        projects: { demo: {
            runner_image: "registry.example/runner@sha256:\($d)",
            restore: "dotnet restore Demo.slnx --locked-mode",
            build: "dotnet build Demo.slnx --no-restore",
            tests: ["dotnet test tests/A --no-build", "dotnet test tests/B --no-build"],
            test_filter: "Passed!|Failed!",
            summary_pattern: "^(Passed|Failed)!",
            env: { DEMO_DB: "Host=db" },
            services: [ { name: "db", image: "registry.example/postgres@sha256:\($d)",
                          env: { POSTGRES_PASSWORD: "pw" },
                          ready: ["pg_isready", "-U", "postgres"], ready_timeout_sec: 5 } ] } } }' \
        | jq "${1:-.}" > "$HARNESS_CONFIG_DIR/lane.json"
    local seed="$TEST_TMP/seed" repo="$HOME/lane/repos/demo.git"
    git init -q "$seed"
    git -C "$seed" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "demo subject"
    SHA="$(git -C "$seed" rev-parse HEAD)"; SHA7="${SHA:0:7}"
    git init -q --bare "$repo"
    git -C "$seed" push -q "$repo" "$SHA:refs/verify/$SHA"
    mkdir -p "$TEST_TMP/bin" "$TEST_TMP/real"
    cp "$HARNESS_ROOT/tests/fake_runtime.sh" "$TEST_TMP/real/podman"
    cat > "$TEST_TMP/bin/podman" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = run ] && [[ " $* " == *" --name chv-"*"-suites "* ]]; then
    prev=; for a in "$@"; do
        if [ "$prev" = -v ] && [[ "$a" == *:/recipe:ro* ]]; then cp -r "${a%%:*}" "$TEST_TMP/recipe-copy"; fi
        if [ "$prev" = -v ] && [[ "$a" == *:/out || "$a" == *:/out:* ]]; then printf '%s\n' "${SUITES_TXT-$(printf '1 0 1\n2 0 1')}" > "${a%%:*}/suites.txt"; fi
        prev="$a"
    done
fi
if [ "$1" = wait ] && [ -n "${FAKE_WAIT_BLOCK:-}" ] && [[ "$2" == chv-*-"$FAKE_WAIT_BLOCK" ]]; then
    echo "podman $*" >> "$TEST_TMP/rt.log"; exec sleep 60   # a runner that never stops
fi
if [ "$1" = logs ] && [ -n "${FAKE_LOGS_BLOCK:-}" ]; then
    echo "podman $*" >> "$TEST_TMP/rt.log"; echo "${FAKE_RT_OUT_logs:-}"; exec sleep 60   # a stream that never ends
fi
if [ "$1" = wait ] && [[ "$2" == chv-*-suites ]]; then export FAKE_RT_OUT_wait="${SUITES_RC:-0}"; fi
# Ruling R9: `podman unshare rm` really removes (as the lane user here); `unshare chown` is only logged.
if [ "$1" = unshare ] && [ "$2" = rm ]; then "${@:2}"; fi
exec "$TEST_TMP/real/podman" "$@"
EOF
    chmod +x "$TEST_TMP/bin/podman"
    export PATH="$TEST_TMP/bin:$PATH" TEST_TMP FAKE_RT_OUT_wait=0
    : > "$TEST_TMP/rt.log"
}
# verify [sha]: runs the controller; output (stderr folded in) in OUT, exit code in RC.
verify() { OUT="$(bash "$HARNESS_ROOT/scripts/lane.sh" verify --project demo "${1:-$SHA}" 2>&1)"; RC=$?; }
rt_log() { cat "$TEST_TMP/rt.log"; }
# runner_mounts: every -v argument of the two runner `run` lines, one per line.
runner_mounts() { grep -- '--name chv-' "$TEST_TMP/rt.log" | grep '^podman run ' \
    | awk '{ for (i = 1; i < NF; i++) if ($i == "-v") print $(i + 1) }'; }

test_busy_lock_exits_3() {
    lane_setup
    mkdir -p "$HOME/lane/work"
    exec 7>"$HOME/lane/work/suite.lock"; flock -n 7
    verify
    exec 7>&-
    assert_eq "exit" "$RC" "3"
    assert_contains "message" "$OUT" "another verify is running on this machine"
    assert_eq "no runtime call" "$(rt_log)" ""
}
test_missing_commit_exits_2() {
    lane_setup
    verify 1234567890abcdef1234567890abcdef12345678
    assert_eq "exit" "$RC" "2"
    assert_contains "message" "$OUT" "commit 1234567890abcdef1234567890abcdef12345678 not in $HOME/lane/repos/demo.git"
    assert_not_contains "no git stack trace" "$OUT" "fatal:"
    assert_not_contains "no network" "$(rt_log)" "network create"
}
test_bad_sha_is_a_usage_error() {
    lane_setup
    verify "HEAD;rm"
    assert_eq "exit" "$RC" "2"
    assert_eq "no runtime call" "$(rt_log)" ""
}
test_config_error_exits_2() {
    lane_setup '.projects.demo.runner_image = "registry.example/runner:latest"'
    verify
    assert_eq "exit" "$RC" "2"
    assert_contains "message" "$OUT" "must be pinned by digest"
}
test_runtime_unavailable_exits_4() {
    lane_setup
    FAKE_RT_RC_ps=125 verify
    assert_eq "exit" "$RC" "4"
    assert_contains "message" "$OUT" "container runtime is unavailable"
}
test_runner_phases_use_the_right_networks() {
    lane_setup; verify
    assert_eq "exit" "$RC" "0"
    local restore suites
    restore="$(grep "^podman run .* --name chv-$SHA7-restore " "$TEST_TMP/rt.log")"
    suites="$(grep "^podman run .* --name chv-$SHA7-suites " "$TEST_TMP/rt.log")"
    assert_contains "restore ran" "$restore" "registry.example/runner@sha256:$D0 chargehand-run restore"
    assert_not_contains "restore not on the run network" "$restore" "--network chv-"
    assert_contains "restore on the default network" "$restore" "--network podman "
    assert_contains "restore cache read-write" "$restore" "-v $HOME/lane/work/cache/demo:/cache:z "
    assert_contains "restore NuGet cache" "$restore" "-e NUGET_PACKAGES=/cache/nuget"
    assert_contains "suites ran" "$suites" "registry.example/runner@sha256:$D0 chargehand-run suites"
    assert_contains "suites on the run network" "$suites" "--network chv-$SHA7 "
    assert_contains "suites cache read-only" "$suites" "-v $HOME/lane/work/cache/demo:/cache:ro,z "
    assert_eq "no read-write cache mount" "$(grep -c -- '-v [^ ]*:/cache:z ' <<<"$suites")" "0"
    assert_contains "suites out mount" "$suites" "-v $HOME/lane/work/run-$SHA7/out:/out:Z "
    assert_contains "suites project env" "$suites" "-e DEMO_DB=Host=db"
    assert_contains "runner limits" "$suites" "--cpus 3 --memory 6g"
    assert_contains "network is internal" "$(rt_log)" "podman network create --internal --label chargehand=1 chv-$SHA7"
}
test_service_runs_on_the_run_network_and_is_polled() {
    lane_setup; verify
    assert_contains "service run" "$(rt_log)" "podman run -d --name db --network chv-$SHA7 --cpus 1 --memory 1g -e POSTGRES_PASSWORD=pw --label chargehand=1 registry.example/postgres@sha256:$D0"
    assert_contains "ready probe" "$(rt_log)" "podman exec db pg_isready -U postgres"
    local svc restore
    svc="$(grep -n "^podman run .* --name db " "$TEST_TMP/rt.log" | cut -d: -f1)"
    restore="$(grep -n "^podman run .* --name chv-$SHA7-restore " "$TEST_TMP/rt.log" | cut -d: -f1)"
    assert_eq "service before restore" "$((svc < restore))" "1"
}
test_service_never_ready_fails_and_cleans_up() {
    lane_setup '.projects.demo.services[0].ready_timeout_sec = 2'
    FAKE_RT_RC_exec=1 verify
    assert_eq "exit" "$RC" "10"
    assert_contains "message" "$OUT" "service db not ready after 2 s"
    assert_eq "rm db third to last" "$(rt_log | tail -3 | head -1)" "podman rm -f db"
    assert_eq "network rm second to last" "$(rt_log | tail -2 | head -1)" "podman network rm chv-$SHA7"
    assert_eq "run dir removed last, in the user namespace" "$(rt_log | tail -1)" "podman unshare rm -rf $HOME/lane/work/run-$SHA7"
    assert_not_contains "no runner started" "$(rt_log)" "--name chv-$SHA7-restore"
    assert_eq "run dir removed" "$([ -e "$HOME/lane/work/run-$SHA7" ] && echo there || echo gone)" "gone"
}
# Ruling R9: the runner is UID 1000, not the lane user. Before the runner phases the controller gives
# it src, out and the project cache (the recipe stays the lane's), and it removes run directories only
# through the runtime, which can delete what the runner wrote.
test_runner_dirs_are_owned_before_the_runner_phases() {
    lane_setup; verify
    assert_eq "exit" "$RC" "0"
    local w="$HOME/lane/work" r="$HOME/lane/work/run-$SHA7" restore
    assert_eq "chowns" "$(grep '^podman unshare chown' "$TEST_TMP/rt.log")" "podman unshare chown -R 1000:1000 $r/src
podman unshare chown -R 1000:1000 $r/out
podman unshare chown -R 1000:1000 $w/cache/demo"
    restore="$(grep -n "^podman run .* --name chv-$SHA7-restore " "$TEST_TMP/rt.log" | cut -d: -f1)"
    assert_eq "last chown before the restore runner" "$(( $(grep -n '^podman unshare chown' "$TEST_TMP/rt.log" | tail -1 | cut -d: -f1) < ${restore:-0} ))" "1"
    assert_not_contains "podman runner keeps the image user" "$(grep -- '--name chv-' "$TEST_TMP/rt.log")" "--user"
}
test_run_dir_is_removed_through_the_runtime() {
    lane_setup
    mkdir -p "$HOME/lane/work/run-$SHA7/src/stale"
    verify
    local r="$HOME/lane/work/run-$SHA7" first net
    first="$(grep -n "^podman unshare rm -rf $r$" "$TEST_TMP/rt.log" | head -1 | cut -d: -f1)"
    net="$(grep -n '^podman network create ' "$TEST_TMP/rt.log" | cut -d: -f1)"
    assert_eq "stale run dir removed before the run" "$(( ${first:-999} < ${net:-0} ))" "1"
    assert_eq "removed again on exit" "$(rt_log | tail -1)" "podman unshare rm -rf $r"
    assert_eq "run dir gone" "$([ -e "$r" ] && echo there || echo gone)" "gone"
}
test_docker_runner_runs_as_the_host_user() {
    lane_setup '.runtime = "docker"'
    cp "$HARNESS_ROOT/tests/fake_runtime.sh" "$TEST_TMP/bin/docker"
    verify
    local runners
    runners="$(grep -- '^docker run .*--name chv-' "$TEST_TMP/rt.log")"
    assert_eq "both runners as the host user" "$(grep -c -- "--user $(id -u):$(id -g) " <<<"$runners")" "2"
    assert_not_contains "service keeps its image user" "$(grep -- '^docker run .*--name db ' "$TEST_TMP/rt.log")" "--user"
    assert_not_contains "no user namespace calls" "$(rt_log)" "unshare"
}
test_leftovers_are_removed_first() {
    lane_setup
    FAKE_RT_OUT_ps='old-runner' verify
    local rm_old net
    rm_old="$(grep -n '^podman rm -f old-runner$' "$TEST_TMP/rt.log" | head -1 | cut -d: -f1)"
    net="$(grep -n '^podman network create ' "$TEST_TMP/rt.log" | head -1 | cut -d: -f1)"
    assert_eq "first runtime call lists leftovers" "$(rt_log | head -1)" "podman ps -a --filter label=chargehand=1 --format {{.Names}}"
    assert_eq "old-runner removed before network create" "$(( ${rm_old:-999} < ${net:-0} ))" "1"
}
test_no_socket_or_home_mounted_in_runner() {
    lane_setup; verify
    local mounts m host bad=""
    mounts="$(runner_mounts)"
    assert_eq "both runners have mounts" "$(grep -c . <<<"$mounts")" "7"
    while IFS= read -r m; do
        host="${m%%:*}"
        case "$m" in *.sock*|*/etc*) bad+=" $m" ;; esac
        case "$host" in "$HOME/lane/work/"*) ;; "$HOME"*) bad+=" $m" ;; esac
    done <<<"$mounts"
    assert_eq "no socket, /etc or home outside work_dir" "$bad" ""
}
# Ruling R8: on SELinux hosts a container can read a bind mount only once it is relabelled. The
# per-run directories get the private label (Z), the per-project cache, shared by both runners, the
# shared one (z). Every relabelled path is under work_dir.
test_bind_mounts_are_relabelled_for_selinux() {
    lane_setup; verify
    local w="$HOME/lane/work" r="$HOME/lane/work/run-$SHA7"
    assert_eq "runner mounts" "$(runner_mounts)" "$r/src:/work:Z
$r/recipe:/recipe:ro,Z
$w/cache/demo:/cache:z
$r/src:/work:Z
$r/recipe:/recipe:ro,Z
$w/cache/demo:/cache:ro,z
$r/out:/out:Z"
}
test_recipe_reaches_runner_as_files() {
    lane_setup; verify
    local r="$TEST_TMP/recipe-copy"
    assert_eq "restore" "$(cat "$r/restore")" "dotnet restore Demo.slnx --locked-mode"
    assert_eq "build" "$(cat "$r/build")" "dotnet build Demo.slnx --no-restore"
    assert_eq "tests" "$(cat "$r/tests")" $'dotnet test tests/A --no-build\ndotnet test tests/B --no-build'
    assert_eq "filter" "$(cat "$r/filter")" "Passed!|Failed!"
    assert_eq "summary" "$(cat "$r/summary")" "^(Passed|Failed)!"
    assert_eq "timeout_min" "$(cat "$r/timeout_min")" "45"
    assert_not_contains "recipe not on a command line" "$(rt_log)" "dotnet"
}
test_pass_prints_start_logs_and_digests() {
    lane_setup
    FAKE_RT_OUT_logs='Passed!  - Failed: 0, Passed: 1' FAKE_RT_OUT_image="[\"registry.example/x@sha256:$D0\"]" verify
    assert_eq "exit" "$RC" "0"
    assert_eq "first line" "$(head -1 <<<"$OUT")" "Verifying $SHA7 demo subject"
    assert_contains "runner output" "$OUT" "Passed!  - Failed: 0, Passed: 1"
    assert_eq "digests last" "$(tail -1 <<<"$OUT")" "digests: runner=sha256:$D0 db=sha256:$D0"
    assert_contains "everything removed" "$(rt_log)" "podman rm -f chv-$SHA7-suites"
    assert_eq "run dir removed" "$([ -e "$HOME/lane/work/run-$SHA7" ] && echo there || echo gone)" "gone"
    assert_eq "lock file kept" "$([ -e "$HOME/lane/work/suite.lock" ] && echo there || echo gone)" "there"
}
test_restore_failure_exits_10() {
    lane_setup
    FAKE_RT_OUT_wait=1 verify
    assert_eq "exit" "$RC" "10"
    assert_contains "message" "$OUT" "RESTORE FAILED"
    assert_not_contains "suites never ran" "$(rt_log)" "--name chv-$SHA7-suites"
}
test_suites_failure_exits_10() {
    lane_setup
    SUITES_RC=1 verify
    assert_eq "exit" "$RC" "10"
}
test_verdict_needs_one_summary_per_suite() {
    lane_setup
    SUITES_TXT=$'1 0 1\n2 0 0' verify
    assert_eq "exit" "$RC" "10"
    assert_contains "names suite and reason" "$OUT" "suite 2: no summary line"
    lane_setup
    SUITES_TXT=$'1 0 2\n2 0 1' verify
    assert_eq "exit (two summaries)" "$RC" "10"
    assert_contains "message" "$OUT" "suite 1: 2 summary lines"
    lane_setup
    SUITES_TXT='1 0 0' verify
    assert_contains "single-line fixture" "$OUT" "suite 1: no summary line"
}
test_verdict_fails_a_suite_that_exited_nonzero() {
    lane_setup
    SUITES_TXT=$'1 0 1\n2 1 1' verify
    assert_eq "exit" "$RC" "10"
    assert_contains "message" "$OUT" "suite 2: exit code 1"
}
test_verdict_fails_when_suites_are_missing() {
    lane_setup
    SUITES_TXT='' verify
    assert_eq "no suites.txt content" "$RC" "10"
    assert_contains "message" "$OUT" "suite 1: no result"
    lane_setup
    SUITES_TXT='1 0 1' verify
    assert_eq "second suite missing" "$RC" "10"
    assert_contains "message" "$OUT" "suite 2: no result"
}
test_verdict_fails_on_extra_results() {
    lane_setup
    SUITES_TXT=$'1 0 1\n2 0 1\n3 0 1' verify
    assert_eq "exit" "$RC" "10"
    assert_contains "message" "$OUT" "suites.txt has 3 results for 2 suites"
}
test_verdict_rejects_overflowing_malformed_and_misindexed_lines() {
    lane_setup
    SUITES_TXT=$'1 99999999999999999999 1\n2 0 1' verify
    assert_eq "overflowing exit code" "$RC" "10"
    lane_setup
    SUITES_TXT=$'1 0 99999999999999999999\n2 0 1' verify
    assert_eq "overflowing count" "$RC" "10"
    lane_setup
    SUITES_TXT=$'1 0 x\n2 0 1' verify
    assert_eq "malformed line" "$RC" "10"
    assert_contains "malformed message" "$OUT" "suite 1: malformed result line"
    lane_setup
    SUITES_TXT=$'2 0 1\n1 0 1' verify
    assert_eq "index mismatch" "$RC" "10"
    assert_contains "mismatch message" "$OUT" "suite 1: malformed result line"
}
test_verdict_passes_on_clean_summaries() {
    lane_setup
    SUITES_TXT=$'1 0 1\n2 0 1' verify
    assert_eq "exit" "$RC" "0"
}
test_runner_output_is_followed_before_the_verdict() {
    lane_setup
    FAKE_RT_OUT_logs='restore says hi' FAKE_RT_OUT_wait=1 verify
    local run follow next
    run="$(grep -n "^podman run .* --name chv-$SHA7-restore " "$TEST_TMP/rt.log" | cut -d: -f1)"
    follow="$(grep -n "^podman logs -f chv-$SHA7-restore$" "$TEST_TMP/rt.log" | cut -d: -f1)"
    next="$(grep -n "^podman rm -f chv-$SHA7-restore$" "$TEST_TMP/rt.log" | cut -d: -f1)"
    assert_eq "follow after run, before rm" "$(( ${run:-999} < ${follow:-0} && ${follow:-999} < ${next:-0} ))" "1"
    assert_eq "output, then the verdict" "$(grep -E 'restore says hi|RESTORE FAILED' <<<"$OUT")" $'restore says hi\nRESTORE FAILED'
    lane_setup
    FAKE_RT_OUT_logs='suites say hi' verify
    follow="$(grep -n "^podman logs -f chv-$SHA7-suites$" "$TEST_TMP/rt.log" | cut -d: -f1)"
    next="$(grep -n "^podman wait chv-$SHA7-suites$" "$TEST_TMP/rt.log" | cut -d: -f1)"
    assert_eq "suites followed" "$(( ${follow:-0} > 0 && ${next:-0} > 0 ))" "1"
    assert_eq "suites output before digests" "$(tail -2 <<<"$OUT" | head -1)" "suites say hi"
}
test_restore_that_never_ends_times_out() {
    lane_setup '.verify_timeout_min = 0.02'
    CHARGEHAND_LANE_GRACE_SEC=0 FAKE_WAIT_BLOCK=restore verify
    assert_eq "exit" "$RC" "10"
    assert_contains "message" "$OUT" "TIMED OUT (controller) after 0.02 min: restore"
    assert_contains "runner removed" "$(rt_log)" "podman rm -f chv-$SHA7-restore"
    assert_eq "network removed second to last" "$(rt_log | tail -2 | head -1)" "podman network rm chv-$SHA7"
    assert_eq "run dir removed last" "$(rt_log | tail -1)" "podman unshare rm -rf $HOME/lane/work/run-$SHA7"
    assert_eq "run dir removed" "$([ -e "$HOME/lane/work/run-$SHA7" ] && echo there || echo gone)" "gone"
}
test_suites_deadline_counts_every_test() {
    lane_setup '.verify_timeout_min = 0.02'
    CHARGEHAND_LANE_GRACE_SEC=0 FAKE_WAIT_BLOCK=suites verify
    assert_eq "exit" "$RC" "10"
    assert_contains "message (0.02 x (1 + 2 tests))" "$OUT" "TIMED OUT (controller) after 0.06 min: suites"
    assert_contains "runner removed" "$(rt_log)" "podman rm -f chv-$SHA7-suites"
}
test_failed_wait_stops_the_stream_at_once() {
    lane_setup
    local t0=$SECONDS
    FAKE_LOGS_BLOCK=1 FAKE_RT_RC_wait=1 verify
    assert_eq "exit (could not run)" "$RC" "1"
    assert_contains "message" "$OUT" "could not wait for chv-$SHA7-restore"
    assert_eq "ends promptly" "$(( SECONDS - t0 < 10 ))" "1"
    assert_contains "runner removed" "$(rt_log)" "podman rm -f chv-$SHA7-restore"
}
test_stream_that_never_ends_is_stopped_after_the_drain() {
    lane_setup
    local t0=$SECONDS
    CHARGEHAND_LANE_DRAIN_SEC=1 FAKE_LOGS_BLOCK=1 FAKE_RT_OUT_logs='still streaming' SUITES_RC=1 verify
    assert_eq "exit (the verdict)" "$RC" "10"
    assert_contains "output kept" "$OUT" "still streaming"
    assert_contains "says so" "$OUT" "output stream of chv-$SHA7-suites did not end after 1 s"
    assert_eq "ends promptly" "$(( SECONDS - t0 < 10 ))" "1"
}

run_tests
