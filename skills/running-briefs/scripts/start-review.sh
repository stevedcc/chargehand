#!/usr/bin/env bash
# Start a review session (OpenCode, sandboxed) for a branch that was implemented outside the
# sandbox, e.g. by a Claude subagent in the owner's repo. Pushes the branch to the agents'
# mirror; the prompt tells the reviewer to fetch it into the agent clone, which is also how a
# later `agent-sync.sh verify` finds the commit. The model is the role's first one whose
# subscription is under its "max_busy_sessions" (models_pick), unless --model names one.
# Usage: start-review.sh --project <name> --tag <tag> --branch <branch> --base <sha>
#        --role task_review|final_review (--brief <path> | --prompt <file>) [--extra <text>]
#        [--model provider/model] [--arm <name>] [--allow-paid]
# Without --prompt the shipped template (review.md next to SKILL.md) is used: it needs --brief, the
# brief's path, and puts --extra (what to judge in particular) in its {EXTRA} slot. A prompt file's
# {TAG}, {BRANCH}, {BASE}, {BRIEF} and {EXTRA} are filled in. --allow-paid: the owner said a
# pay-per-use model may be picked. State goes to the brief folder
# "<tag>-review[-<arm>]" (sid, launch.txt), so watch.sh and brief-cost.sh work on it.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(cd "$here/../../.." && pwd)"
for lib in harness api models render; do . "$HARNESS_ROOT/scripts/lib/$lib.sh"; done

project= tag= branch= base= role= prompt= model= arm= paid= brief= extra=
while [ $# -gt 0 ]; do
    case "$1" in
        --project) project="$2"; shift 2 ;;
        --tag) tag="$2"; shift 2 ;;
        --branch) branch="$2"; shift 2 ;;
        --base) base="$2"; shift 2 ;;
        --role) role="$2"; shift 2 ;;
        --prompt) prompt="$2"; shift 2 ;;
        --brief) brief="$2"; shift 2 ;;
        --extra) extra="$2"; shift 2 ;;
        --model) model="$2"; shift 2 ;;
        --arm) arm="$2"; shift 2 ;;
        --allow-paid) paid=--allow-paid; shift ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument \"$1\"" ;;
    esac
done
[ -n "$project" ] && [ -n "$tag" ] && [ -n "$branch" ] && [ -n "$base" ] \
    || die "--project, --tag, --branch and --base are required"
if [ -z "$prompt" ]; then
    [ -n "$brief" ] || die "without --prompt the shipped review template is used, and it needs --brief <path of the brief>"
    prompt="$here/../review.md"
fi
case "$role" in task_review|final_review) ;; *) die "--role must be task_review or final_review" ;; esac
[ -f "$prompt" ] || die "no prompt file $prompt"
[ -n "$model" ] || model="$(models_pick "$(models_effective "$project")" "$role" $paid)"

repo="$(project_get "$project" owner_worktree)"
dir="$(brief_dir "$project" "$tag-review${arm:+-$arm}")"; mkdir -p "$dir"
if [ -s "$dir/sid" ]; then
    n=1; while [ -e "$dir/sid.prev$n" ]; do n=$((n + 1)); done; mv "$dir/sid" "$dir/sid.prev$n"
fi
git -C "$repo" push -q agent-upstream "+$branch:refs/heads/$branch"
req="$(jq -n --arg t "Review $tag${arm:+ ($arm)}" --arg p "${model%%/*}" --arg m "${model#*/}" \
        --argjson perms "$(render_permissions "$here/../permissions.json")" \
        '{title: $t, agent: "build", model: {providerID: $p, id: $m}, permissions: $perms}')"
printf '%s\n' "$req" > "$dir/session-request.json"
text="$(<"$prompt")"
text="${text//\{TAG\}/"$tag"}"; text="${text//\{BRANCH\}/"$branch"}"; text="${text//\{BASE\}/"$base"}"
text="${text//\{BRIEF\}/"$brief"}"; text="${text//\{EXTRA\}/"$extra"}"
printf '%s\n' "$text" > "$dir/launch.txt"
sid="$(oc_launch "$dir")"
echo "$model $sid"
