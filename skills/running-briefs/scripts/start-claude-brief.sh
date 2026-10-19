#!/usr/bin/env bash
# Prepare a brief for a Claude subagent implementer in the owner's repo (no OpenCode session): create
# its worktree on brief/<tag> (the branch whose first commit is the brief), keep .worktrees/ and
# .superpowers/ out of git, and print the filled prompt (implementer/claude-implementer.md) on
# stdout. It cannot start the subagent: pass the printed prompt to Claude Code's Agent tool.
# Usage: start-claude-brief.sh --project <name> --tag <tag> --brief <path in repo> [--first-instance K]
# --first-instance K: the E2E instances K..K+n-1 the subagent may use (required if the project has an
# e2e_command). stderr gets the worktree and the review base (pass it as --base to start-review.sh).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(cd "$here/../../.." && pwd)"
. "$HARNESS_ROOT/scripts/lib/harness.sh"

project= tag= brief= first=
while [ $# -gt 0 ]; do
    case "$1" in
        --project) project="$2"; shift 2 ;;
        --tag) tag="$2"; shift 2 ;;
        --brief) brief="$2"; shift 2 ;;
        --first-instance) first="$2"; shift 2 ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument \"$1\"" ;;
    esac
done
[ -n "$project" ] && [ -n "$tag" ] && [ -n "$brief" ] || die "--project, --tag and --brief are required"
valid_name "$tag" || die "bad brief tag \"$tag\""
repo="$(project_get "$project" owner_worktree)"
target="$(project_get "$project" target_branch)"
if ! git -C "$repo" cat-file -e "refs/heads/brief/$tag:$brief" 2>/dev/null; then
    git -C "$repo" cat-file -e "refs/heads/$target:$brief" 2>/dev/null \
        || die "no brief $brief committed in $repo: commit it on brief/$tag (created from $target) first"
    echo "chargehand: warning: brief $brief is on $target, not on its own brief/$tag commit; launching from the target" >&2
fi
git -C "$repo" rev-parse -q --verify "refs/heads/brief/$tag" >/dev/null || git -C "$repo" branch "brief/$tag" "$target"

e2e="$(project_get "$project" e2e_command "")"
if [ -z "$e2e" ]; then e2e_text=""
else
    [ -n "$first" ] || die "the project has an e2e_command: pass --first-instance K (instances nothing else uses)"
    n="$(project_get "$project" e2e_instances_per_run 3)"
    cmd="${e2e//\{N\}/$n}"; e2e_text="Run E2E with \`${cmd//\{K\}/$first}\` (instances $first..$((first + n - 1)) are yours)."
fi

wt="$repo/.worktrees/$tag"
[ ! -e "$wt" ] || die "$wt already exists: the brief has a worktree"
git -C "$repo" worktree add -q "$wt" "brief/$tag"
exclude="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
mkdir -p "$(dirname "$exclude")"
for p in .superpowers/ .worktrees/; do grep -qxF -- "$p" "$exclude" 2>/dev/null || printf '%s\n' "$p" >> "$exclude"; done

echo "chargehand: worktree $wt on brief/$tag; review base $(git -C "$wt" rev-parse HEAD)" >&2
msg="$(<"$HARNESS_ROOT/implementer/claude-implementer.md")"
msg="${msg//\{RULES\}/$HARNESS_ROOT/implementer/claude-subagent-rules.md}"; msg="${msg//\{WORKTREE\}/$wt}"
msg="${msg//\{TAG\}/$tag}"; msg="${msg//\{BRIEF\}/$brief}"; msg="${msg//\{E2E\}/$e2e_text}"
printf '%s\n' "$msg"
