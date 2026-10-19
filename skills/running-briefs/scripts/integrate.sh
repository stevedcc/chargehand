#!/usr/bin/env bash
# Throwaway integration check for briefs running in parallel ("branch per feature"): would the
# running briefs merge cleanly into the target branch, alone and with each other? Fetches the
# agent clone's branches, then for every running brief and every pair of them computes the merge
# with `git merge-tree --write-tree` inside the object database: no worktree, no build, no agent
# code is run (agent-sync.sh's rule), nothing is committed, so nothing needs throwing away.
# Usage: integrate.sh --project <name> [<tag>...]   (default: briefs with a session and commits
#        not yet on the target)
# Exit 0 when everything merges cleanly, 1 when something conflicts (files listed), 2 on usage or
# when it could not run (fetch failed, git too old).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(cd "$here/../../.." && pwd)"
. "$HARNESS_ROOT/scripts/lib/harness.sh"
[ "${1:-}" = --project ] && [ "$#" -ge 2 ] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
project="$2"; shift 2
repo="$(project_get "$project" owner_worktree)"
target="$(project_get "$project" target_branch)"
bash "$HARNESS_ROOT/skills/verifying-and-accepting/scripts/agent-sync.sh" --project "$project" fetch >/dev/null \
    || die "fetch of the agent clone failed (git's message is above)"
cd "$repo"
git merge-tree --write-tree "$target" "$target" >/dev/null 2>&1 || die "this git has no merge-tree --write-tree (needs 2.38+)"

tags=("$@")
if [ "${#tags[@]}" -eq 0 ]; then
    for d in "$HARNESS_STATE_DIR/$project/briefs"/*/; do
        t="$(basename "$d")"
        [ -s "$d/sid" ] || continue
        git rev-parse -q --verify "agent/brief/$t^{commit}" >/dev/null || continue
        [ -n "$(git rev-list -1 "$target..agent/brief/$t")" ] || continue
        tags+=("$t")
    done
fi
[ "${#tags[@]}" -gt 0 ] || { echo "No running briefs with commits beyond $target."; exit 0; }

status=0
check() {   # label, ours, theirs
    local out rc
    out="$(git merge-tree --write-tree --name-only --no-messages "$2" "$3" 2>&1)" && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '  %-28s clean\n' "$1"
    elif [ "$rc" -eq 1 ]; then
        printf '  %-28s CONFLICT in:\n' "$1"; tail -n +2 <<<"$out" | sed 's/^/      /'; status=1
    else
        printf '  %-28s ERROR: %s\n' "$1" "$out"; status=1
    fi
}

echo "Integration check against $target ($(git rev-parse --short "$target")), briefs: ${tags[*]}"
for t in "${tags[@]}"; do
    check "$t -> $target" "$target" "agent/brief/$t"
done
for ((i = 0; i < ${#tags[@]}; i++)); do
    for ((j = i + 1; j < ${#tags[@]}; j++)); do
        check "${tags[i]} + ${tags[j]}" "agent/brief/${tags[i]}" "agent/brief/${tags[j]}"
    done
done
exit "$status"
