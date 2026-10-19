#!/usr/bin/env bash
# The owner's side of the fork model. Run as yourself.
# Usage: agent-sync.sh --project <name> push | fetch | verify [ref] | accept [branch]
#   push           push the target branch to the read-only mirror the agents pull from
#   fetch          fetch the agent clone's branches into agent/* and show what's new
#   verify [ref]   clean build and all suites for ref (default agent/<target>), as the agent user,
#                  inside the sandbox (never as you). Exit 0 passed; 10 the build or a suite failed or
#                  timed out; 3 another verify of the project is running; 4 the sandbox could not
#                  start; other: could not run (sudo refused, old launcher)
#   accept [br]    fast-forward the target branch to agent/<br> (default the target), push the mirror
# Never build, test or run agent-authored code as yourself before accept. Reading diffs is safe.
set -euo pipefail
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$HARNESS_ROOT/scripts/lib/harness.sh"
usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }
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
verify)
    ref="${1:-agent/$target}"
    sha="$(git rev-parse --verify "$ref^{commit}")"
    rc=0
    sudo -n -u "$(config_get agent_user opencode)" "$(config_get launcher /usr/local/bin/chargehand-sandbox)" \
        --verify --project "$project" "$sha" 2>&1 | agent_text || rc="${PIPESTATUS[0]}"   # test output is agent-authored text
    case "$rc" in
        0) ;;
        10) echo "chargehand: verify FAILED: the build or a suite failed or timed out (see above)" >&2; exit 10 ;;
        3)  echo "chargehand: verify not run: another verify of $project is running" >&2; exit 3 ;;
        4)  echo "chargehand: verify not run: the sandbox could not start (Podman socket missing?)" >&2; exit 4 ;;
        *)  echo "chargehand: verify not run: could not run the verification (launcher exit $rc: sudo refused, an out-of-date launcher or sudoers, or the sandbox/checkout failed; see above)" >&2; exit "$rc" ;;
    esac
    # Only a passing run is recorded: accept takes exactly this commit and nothing a later fetch brought.
    mkdir -p "$verified"
    printf '%s\n' "$sha" > "$verified/$(record_name "$ref")" ;;
accept)
    [ "$(git branch --show-current)" = "$target" ] || die "run accept with $target checked out in $repo"
    [ -z "$(git status --porcelain --untracked-files=no)" ] || die "$repo has uncommitted changes: set them aside (patch), accept, then re-apply"
    src="agent/${1:-$target}"
    record="$verified/$(record_name "$src")"
    [ -s "$record" ] || die "$src is not verified: run verify $src first (only a passing verify counts)"
    sha="$(<"$record")"; now="$(git rev-parse --verify "$src^{commit}")"
    [ "$now" = "$sha" ] || die "$src moved since verify ($sha verified, now $now): read the new commits, then verify again"
    git merge-base --is-ancestor "$target" "$sha" \
        || die "$src is not a fast-forward of $target: ask the agent to merge origin/$target into it, then fetch and verify again"
    # It is a fast-forward, so a failure now has another cause (untracked file in the way, index.lock ...): show git's text.
    merge_out="$(git merge --ff-only -q "$sha" 2>&1)" || die "merging $src into $target failed (it is a fast-forward; the cause is in $repo): $(agent_text <<<"$merge_out")"
    rm -f "$record"
    git push -q agent-upstream "$target" ;;
*)
    usage; exit 2 ;;
esac
