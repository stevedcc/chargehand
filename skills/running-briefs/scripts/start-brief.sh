#!/usr/bin/env bash
# Launch an OpenCode session for a brief: push the target branch and the brief branch (brief/<tag>,
# which carries the brief as its first commit) to the agents' mirror, create the
# session with the implementer model pinned and the permission rules, send the launch message,
# and record the brief's state (sid, launch.txt) under ~/.local/state/chargehand.
# Usage: start-brief.sh --project <name> --tag <tag> --brief <path in repo> [--title <text>]
#        [--role role=provider/model]... [--first-instance K] [--extra <text>] [--no-push] [--dry-run]
#        [--resume] [--allow-paid]
# --allow-paid: the owner said a pay-per-use model ("pay_per_use": true in models.json) may be used.
# --resume: the brief's session died (provider error, quota): start a new session that carries on
# from its worktree and state.md. Pass --role implementer=<fallback> for another model. The old
# sid becomes sid.prev<n> (brief-cost.sh counts it); the old launch.txt becomes launch.txt.prev<n>.
# Prints the session id. --dry-run prints the launch message and the session request instead.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(cd "$here/../../.." && pwd)"
for lib in harness api models render; do . "$HARNESS_ROOT/scripts/lib/$lib.sh"; done

project= tag= brief= title= extra= first= push=1 dry=0 resume=0 paid=; roles=()
while [ $# -gt 0 ]; do
    case "$1" in
        --project) project="$2"; shift 2 ;;
        --tag) tag="$2"; shift 2 ;;
        --brief) brief="$2"; shift 2 ;;
        --title) title="$2"; shift 2 ;;
        --role) roles+=("$2"); shift 2 ;;
        --first-instance) first="$2"; shift 2 ;;
        --extra) extra="$2"; shift 2 ;;
        --no-push) push=0; shift ;;
        --dry-run) dry=1; shift ;;
        --resume) resume=1; shift ;;
        --allow-paid) paid=--allow-paid; shift ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument \"$1\"" ;;
    esac
done
[ -n "$project" ] && [ -n "$tag" ] && [ -n "$brief" ] || die "--project, --tag and --brief are required"
dir="$(brief_dir "$project" "$tag")"
if [ "$resume" -eq 1 ]; then
    [ -s "$dir/sid" ] || die "brief $tag has no session to resume ($dir/sid); launch it without --resume"
    # brief.txt is written at launch; a brief launched before it existed is not checked.
    [ ! -s "$dir/brief.txt" ] || [ "$(<"$dir/brief.txt")" = "$brief" ] \
        || die "brief $tag was launched with $(<"$dir/brief.txt"), not $brief: resume with the same --brief"
else
    [ ! -s "$dir/sid" ] || die "brief $tag already has a session ($(cat "$dir/sid")); to carry on after a provider error use --resume (--role implementer=<fallback>)"
fi
repo="$(project_get "$project" owner_worktree)"
target="$(project_get "$project" target_branch)"
# The brief normally is the first commit of its own branch brief/<tag>: the launch
# message makes the agent's worktree from origin/brief/<tag>. A brief only on the target is allowed, with a warning.
if ! git -C "$repo" cat-file -e "refs/heads/brief/$tag:$brief" 2>/dev/null; then
    git -C "$repo" cat-file -e "refs/heads/$target:$brief" 2>/dev/null \
        || die "no brief $brief committed in $repo: commit it on brief/$tag (created from $target), not as an uncommitted file"
    echo "chargehand: warning: brief $brief is on $target, not on its own brief/$tag commit; launching from the target" >&2
fi

eff="$(models_effective "$project" "${roles[@]}")"
problems="$(models_check "$eff" "$(bash "$HARNESS_ROOT/skills/configuring-chargehand/scripts/check-config.sh" --families)")"
[ -z "$problems" ] || die "model allocation: $problems (see models.sh --project $project)"

e2e="$(project_get "$project" e2e_command "")"
n="$(project_get "$project" e2e_instances_per_run 3)"
if [ -z "$e2e" ]; then
    e2e_text=""
elif [ -n "$first" ]; then
    cmd="${e2e//\{N\}/$n}"; e2e_text="Run E2E with \`${cmd//\{K\}/$first}\` (the orchestrator chose these instances)."
else
    range="$(project_get "$project" e2e_agent_instances)"
    lo="$(jq '.[0]' <<<"$range")"; hi="$(jq '.[1]' <<<"$range")"
    check="$(project_get "$project" port_check "")"
    e2e_text="Run E2E with \`${e2e//\{N\}/$n}\`, choosing K so instances K..K+$((n - 1)) lie within $lo..$hi and nothing else uses them${check:+ ($check)}."
fi

template=launch.md; [ "$resume" -eq 0 ] || template=resume.md
msg="$(<"$here/../$template")"
msg="${msg//\{PREVIOUS\}/$( [ "$resume" -eq 1 ] && cat "$dir/sid" || true)}"
msg="${msg//\{TARGET\}/$target}"; msg="${msg//\{BRIEF\}/$brief}"; msg="${msg//\{TAG\}/$tag}"
msg="${msg//\{E2E\}/$e2e_text}"; msg="${msg//\{MODELS\}/$(models_render "$eff" $paid)}"; msg="${msg//\{EXTRA\}/$extra}"

# The project's toolchain folders and OpenCode's own cache, as the agent user sees them: OpenCode may use them
# without asking (the sandbox mounts the same list).
agent="$(config_get agent_user opencode)"
agent_home="$(getent passwd "$agent" | cut -d: -f6 || true)"; agent_home="${agent_home:-/home/$agent}"
mapfile -t tool_dirs < <(jq -r '(.toolchain.ro // []) + (.toolchain.rw // []) | .[]' "$(project_file "$project")" \
    | sed "s|^~/|$agent_home/|"; echo "$agent_home/.cache/opencode")

# A subscription at its "max_busy_sessions" (e.g. Z.ai's 5-hour window) passes to the next model.
if [ "$dry" -eq 1 ]; then impl="$(jq -r '.implementer[0]' <<<"$eff")"; else impl="$(models_pick "$eff" implementer $paid)"; fi
[ "$dry" -eq 1 ] || echo "chargehand: implementer model: $impl" >&2
req="$(jq -n --arg t "${title:-Brief $tag}" --arg p "${impl%%/*}" --arg m "${impl#*/}" \
        --argjson perms "$(render_permissions "$here/../permissions.json" "${tool_dirs[@]}")" \
        '{title: $t, agent: "build", model: {providerID: $p, id: $m}, permissions: $perms}')"

if [ "$dry" -eq 1 ]; then printf '%s\n\n%s\n' "$msg" "$req"; exit 0; fi

# A brief that sits on the target gets its branch now, at the target.
git -C "$repo" rev-parse -q --verify "refs/heads/brief/$tag" >/dev/null || git -C "$repo" branch "brief/$tag" "$target"
if [ "$push" -eq 1 ]; then
    bash "$HARNESS_ROOT/skills/verifying-and-accepting/scripts/agent-sync.sh" --project "$project" push >&2
    git -C "$repo" push -q agent-upstream "+refs/heads/brief/$tag:refs/heads/brief/$tag" >&2
fi
mkdir -p "$dir"
if [ "$resume" -eq 1 ]; then
    # Keep the dead session (cost, and a way back to it) and the message it was launched with.
    n=1; while [ -e "$dir/sid.prev$n" ]; do n=$((n + 1)); done
    mv "$dir/sid" "$dir/sid.prev$n"; [ ! -e "$dir/launch.txt" ] || mv "$dir/launch.txt" "$dir/launch.txt.prev$n"
    echo "chargehand: resuming $tag on $impl; previous session in $dir/sid.prev$n" >&2
fi
printf '%s\n' "$brief" > "$dir/brief.txt"
printf '%s\n' "$msg" > "$dir/launch.txt"
printf '%s\n' "$req" > "$dir/session-request.json"
oc_launch "$dir"
