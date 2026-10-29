#!/usr/bin/env bash
# The owner's side of the fork model. Run as yourself.
# Usage: agent-sync.sh --project <name> push | fetch | diff <ref> | verify [--wait] [--lane <name>] [ref] | accept [branch]
#   push           push the target branch to the read-only mirror the agents pull from
#   fetch          fetch the agent clone's branches into agent/* and show what's new
#   diff <ref>     what ref (e.g. agent/brief/<tag>) adds to the target: git diff <target>...<ref>,
#                  with terminal control characters stripped (the diff is agent-authored text)
#   verify [ref]   clean build and all suites for ref (default agent/<target>), as the agent user,
#                  inside the sandbox (never as you). Exit 0 passed; 10 the build or a suite failed or
#                  timed out; 3 another verify of the project is running; 4 the sandbox could not
#                  start; other: could not run (sudo refused, old launcher)
#                  --wait: queue behind a running verify of the project instead of exit 3 (says
#                  so once, retries every CHARGEHAND_VERIFY_POLL_SEC, default 30), up to
#                  CHARGEHAND_VERIFY_WAIT_MAX_SEC (default 7200), then exit 75. Prints
#                  "chargehand: verify of <sha> started <time>" the moment the launcher really starts.
#                  --lane <name>: verify on the container lane <name> from lanes.json (ssh destination and
#                  repos_dir) instead of the local sandbox: pushes the commit to the lane, runs
#                  `chargehand-lane verify` there over ssh. Same exit codes; the record says lane=<name>.
#   accept [br]    fast-forward the target branch to agent/<br> (default the target), push the mirror,
#                  delete your local brief/<tag> if it is now merged
# Never build, test or run agent-authored code as yourself before accept. Reading diffs is safe.
set -euo pipefail
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$HARNESS_ROOT/scripts/lib/harness.sh"
usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; }
[ "${1:-}" = --project ] && [ "$#" -ge 2 ] || { usage; exit 2; }
project="$2"; shift 2
cmd="${1:-}"; [ "$#" -gt 0 ] && shift
repo="$(project_get "$project" owner_worktree)"
target="$(project_get "$project" target_branch)"
clone="$(project_get "$project" agent_clone)"
verified="$HARNESS_STATE_DIR/$project/verified"
cd "$repo"
case "$cmd" in
push)
    git push agent-upstream "$target" ;;
fetch)
    # upload-pack runs no hooks and ignores the clone's config; the safe.directory override is
    # scoped to this one process. Never add the agent's clone to your global safe.directory.
    # Two fetches into one repo (integrate.sh in the background plus yours) collide on the ref
    # locks about half the time, so they queue on one lock, held for the fetch only.
    mkdir -p "$HARNESS_STATE_DIR/$project"
    ( flock -w 120 9 || die "timed out waiting for another fetch of $project"
      git fetch --no-tags --upload-pack="git -c safe.directory=$clone upload-pack" agent "+refs/heads/*:refs/remotes/agent/*"
    ) 9>"$HARNESS_STATE_DIR/$project/repo.lock"
    echo; echo "New on agent/$target:"
    { git log --oneline "$target..agent/$target" 2>/dev/null || true; } | agent_text ;;
diff)
    [ -n "${1:-}" ] || die "usage: agent-sync.sh --project $project diff <ref>"
    git --no-pager diff --no-color --no-ext-diff "$target...$1" | agent_text ;;
verify)
    wait=0; lane=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --wait) wait=1; shift ;;
            --lane) [ "$#" -ge 2 ] || die "--lane needs a lane name"; lane="$2"; shift 2 ;;
            *) break ;;
        esac
    done
    if [ -n "$lane" ]; then
        lane_ssh="$(lane_remote_get "$lane" ssh)" || exit 2
        lane_repos="$(lane_remote_get "$lane" repos_dir)" || exit 2
    fi
    ref="${1:-agent/$target}"
    sha="$(git rev-parse --verify "$ref^{commit}")"
    # The launcher prints "Verifying ..." only once it holds the project's verify lock, so that line
    # is the real start: announce it, so a queued verify that never starts is visible as such.
    announce_start() {
        local line started=0
        while IFS= read -r line; do
            if [ "$started" = 0 ] && [[ "$line" == Verifying\ * ]]; then
                echo "chargehand: verify of ${sha:0:7} started $(date +%H:%M)"; started=1
            fi
            printf '%s\n' "$line"
        done
    }
    poll="${CHARGEHAND_VERIFY_POLL_SEC:-30}"; deadline=$(( $(date +%s) + ${CHARGEHAND_VERIFY_WAIT_MAX_SEC:-7200} )); told=0
    if [ -n "$lane" ]; then
        valid_name "$project" || die "bad project name \"$project\""
        # BatchMode: an unattended push must fail, not wait on a host-key or password prompt. The push's
        # stderr (remote: lines, banners) is lane-authored text.
        push_rc=0
        git -c core.sshCommand='ssh -o BatchMode=yes' push -q -- "$lane_ssh:$lane_repos/$project.git" "$sha:refs/verify/$sha" 2>&1 \
            | agent_text >&2 || push_rc="${PIPESTATUS[0]}"
        [ "$push_rc" = 0 ] || die "could not push $sha to lane $lane (ssh access, or $lane_repos/$project.git missing on the lane)"
    fi
    while true; do
        rc=0
        if [ -n "$lane" ]; then
            # Config values are passed as separate arguments, never through a shell string. The lane's
            # sshd runs the remote command through the lane user's shell; sha and project are validated.
            ssh -o BatchMode=yes -- "$lane_ssh" chargehand-lane verify --project "$project" "$sha" 2>&1 \
                | agent_text | announce_start || rc="${PIPESTATUS[0]}"   # runner output is agent-authored text
        else
        sudo -n -u "$(config_get agent_user opencode)" "$(config_get launcher /usr/local/bin/chargehand-sandbox)" \
            --verify --project "$project" "$sha" 2>&1 | agent_text | announce_start || rc="${PIPESTATUS[0]}"   # test output is agent-authored text
        fi
        [ "$rc" = 3 ] && [ "$wait" = 1 ] || break
        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "chargehand: gave up waiting for the other verify of $project (CHARGEHAND_VERIFY_WAIT_MAX_SEC); verify not run" >&2; exit 75
        fi
        [ "$told" = 1 ] || { echo "chargehand: another verify of $project is running; waiting $(date +%H:%M)" >&2; told=1; }
        sleep "$poll"
    done
    case "$rc" in
        0) ;;
        10) echo "chargehand: verify FAILED: the build or a suite failed or timed out (see above)" >&2; exit 10 ;;
        3)  echo "chargehand: verify not run: another verify of $project is running" >&2; exit 3 ;;
        4)  if [ -n "$lane" ]; then echo "chargehand: verify not run: the lane's container runtime is unavailable" >&2
            else echo "chargehand: verify not run: the sandbox could not start (Podman socket missing?)" >&2; fi
            exit 4 ;;
        *)  echo "chargehand: verify not run: could not run the verification (launcher exit $rc: sudo refused, an out-of-date launcher or sudoers, or the sandbox/checkout failed; see above)" >&2; exit "$rc" ;;
    esac
    # Only a passing run is recorded: accept takes exactly this commit and nothing a later fetch brought.
    mkdir -p "$verified"
    if [ -n "$lane" ]; then record_text="$sha lane=$lane"; else record_text="$sha"; fi
    printf '%s\n' "$record_text" > "$verified/$(record_name "$ref")" ;;
accept)
    [ "$(git branch --show-current)" = "$target" ] || die "run accept with $target checked out in $repo"
    [ -z "$(git status --porcelain --untracked-files=no)" ] || die "$repo has uncommitted changes: set them aside (patch), accept, then re-apply"
    src="agent/${1:-$target}"
    record="$verified/$(record_name "$src")"
    [ -s "$record" ] || die "$src is not verified: run verify $src first (only a passing verify counts)"
    sha="$(<"$record")"; sha="${sha%% *}"; now="$(git rev-parse --verify "$src^{commit}")"
    [ "$now" = "$sha" ] || die "$src moved since verify ($sha verified, now $now): read the new commits, then verify again"
    git merge-base --is-ancestor "$target" "$sha" \
        || die "$src is not a fast-forward of $target: ask the agent to merge origin/$target into it, then fetch and verify again"
    # It is a fast-forward, so a failure now has another cause (untracked file in the way, index.lock ...): show git's text.
    merge_out="$(git merge --ff-only -q "$sha" 2>&1)" || die "merging $src into $target failed (it is a fast-forward; the cause is in $repo): $(agent_text <<<"$merge_out")"
    rm -f "$record"
    git push -q agent-upstream "$target"
    # The owner's own brief/<tag> (a review/<tag>-<sha7> ref comes from it) is merged now: delete it.
    own="${src#agent/}"; own="$(sed -E 's|^review/(.+)-[0-9a-f]{7}$|brief/\1|' <<<"$own")"
    case "$own" in brief/*)
        if git rev-parse -q --verify "refs/heads/$own" >/dev/null && git merge-base --is-ancestor "$own" "$target"; then
            if git branch -q -d "$own" 2>/dev/null; then echo "deleted local branch $own (merged into $target)"
            else echo "kept local branch $own (merged into $target, but checked out in a worktree: remove that worktree, then delete it)"; fi
        fi ;;
    esac ;;
*)
    usage; exit 2 ;;
esac
