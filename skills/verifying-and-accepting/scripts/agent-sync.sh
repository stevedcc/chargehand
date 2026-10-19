#!/usr/bin/env bash
# The owner's side of the fork model. Run as yourself.
# Usage: agent-sync.sh --project <name> push | fetch | verify [ref] | accept [branch]
#   push           push the target branch to the read-only mirror the agents pull from
#   fetch          fetch the agent clone's branches into agent/* and show what's new
#   verify [ref]   clean build and all suites for ref (default agent/<target>), as the agent user,
#                  inside the sandbox (never as you)
#   accept [br]    fast-forward the target branch to agent/<br> (default the target), push the mirror
# Never build, test or run agent-authored code as yourself before accept. Reading diffs is safe.
set -euo pipefail
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$HARNESS_ROOT/scripts/lib/harness.sh"
usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; }
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
    git fetch --no-tags --upload-pack="git -c safe.directory=$clone upload-pack" agent "+refs/heads/*:refs/remotes/agent/*"
    echo; echo "New on agent/$target:"
    { git log --oneline "$target..agent/$target" 2>/dev/null || true; } | agent_text ;;
verify)
    ref="${1:-agent/$target}"
    sha="$(git rev-parse --verify "$ref^{commit}")"
    sudo -n -u "$(config_get agent_user opencode)" "$(config_get launcher /usr/local/bin/chargehand-sandbox)" \
        --verify --project "$project" "$sha" 2>&1 | agent_text   # test output is agent-authored text
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
    git merge --ff-only -q "$sha" 2>/dev/null \
        || die "$src is not a fast-forward of $target: ask the agent to merge origin/$target into it, then fetch and verify again"
    rm -f "$record"
    git push -q agent-upstream "$target" ;;
*)
    usage; exit 2 ;;
esac
