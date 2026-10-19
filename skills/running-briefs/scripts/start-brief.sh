#!/usr/bin/env bash
# Launch an OpenCode session for a brief: push the target branch to the agents' mirror, create the
# session with the implementer model pinned and the permission rules, send the launch message,
# and record the brief's state (sid, launch.txt) under ~/.local/state/chargehand.
# Usage: start-brief.sh --project <name> --tag <tag> --brief <path in repo> [--title <text>]
#        [--role role=provider/model]... [--first-instance K] [--extra <text>] [--no-push] [--dry-run]
# Prints the session id. --dry-run prints the launch message and the session request instead.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(cd "$here/../../.." && pwd)"
for lib in harness api models render; do . "$HARNESS_ROOT/scripts/lib/$lib.sh"; done

project= tag= brief= title= extra= first= push=1 dry=0; roles=()
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
        -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument \"$1\"" ;;
    esac
done
[ -n "$project" ] && [ -n "$tag" ] && [ -n "$brief" ] || die "--project, --tag and --brief are required"
dir="$(brief_dir "$project" "$tag")"
[ ! -s "$dir/sid" ] || die "brief $tag already has a session ($(cat "$dir/sid")); remove $dir/sid to launch again"
repo="$(project_get "$project" owner_worktree)"
target="$(project_get "$project" target_branch)"
[ -f "$repo/$brief" ] || die "no brief $brief in $repo"

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

msg="$(<"$here/../launch.md")"
msg="${msg//\{TARGET\}/$target}"; msg="${msg//\{BRIEF\}/$brief}"; msg="${msg//\{TAG\}/$tag}"
msg="${msg//\{E2E\}/$e2e_text}"; msg="${msg//\{MODELS\}/$(models_render "$eff")}"; msg="${msg//\{EXTRA\}/$extra}"

# The project's toolchain folders and OpenCode's own cache, as the agent user sees them: OpenCode may use them
# without asking (the sandbox mounts the same list).
agent="$(config_get agent_user opencode)"
agent_home="$(getent passwd "$agent" | cut -d: -f6 || true)"; agent_home="${agent_home:-/home/$agent}"
mapfile -t tool_dirs < <(jq -r '(.toolchain.ro // []) + (.toolchain.rw // []) | .[]' "$(project_file "$project")" \
    | sed "s|^~/|$agent_home/|"; echo "$agent_home/.cache/opencode")

# A subscription at its "max_busy_sessions" (e.g. Z.ai's 5-hour window) passes to the next model.
if [ "$dry" -eq 1 ]; then impl="$(jq -r '.implementer[0]' <<<"$eff")"; else impl="$(models_pick "$eff" implementer)"; fi
req="$(jq -n --arg t "${title:-Brief $tag}" --arg p "${impl%%/*}" --arg m "${impl#*/}" \
        --argjson perms "$(render_permissions "$here/../permissions.json" "${tool_dirs[@]}")" \
        '{title: $t, agent: "build", model: {providerID: $p, id: $m}, permissions: $perms}')"

if [ "$dry" -eq 1 ]; then printf '%s\n\n%s\n' "$msg" "$req"; exit 0; fi

[ "$push" -eq 0 ] || bash "$HARNESS_ROOT/skills/verifying-and-accepting/scripts/agent-sync.sh" --project "$project" push >&2
mkdir -p "$dir"
printf '%s\n' "$msg" > "$dir/launch.txt"
printf '%s\n' "$req" > "$dir/session-request.json"
sid="$(oc_api POST /api/session "$dir/session-request.json" | jq -r '.data.id // empty')"
[ -n "$sid" ] || die "creating the session failed"
printf '%s\n' "$sid" > "$dir/sid"
jq -n --rawfile t "$dir/launch.txt" '{text: $t}' > "$dir/prompt-request.json"
oc_api POST "/api/session/$sid/prompt" "$dir/prompt-request.json" | jq -e '.data.id' >/dev/null \
    || die "sending the launch message to $sid failed"
echo "$sid"
