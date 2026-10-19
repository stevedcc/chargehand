#!/usr/bin/env bash
# Watch running briefs and every subagent session under them until something needs you.
# Usage: watch.sh --project <name> [--max-min N (115)] [--stall-min M (15)] <tag>...
# Start it with Claude Code's run_in_background, never with "&". Exit codes:
#   0 a brief went idle           1 timeout, nothing happened      2 usage error
#   4 a permission is pending      5 a question (form) is pending
#   6 a subagent session ended in an error (each error is reported once)
#   7 no new message anywhere in a brief for M minutes            8 the server stopped answering
set -uo pipefail
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$HARNESS_ROOT/scripts/lib/harness.sh"
. "$HARNESS_ROOT/scripts/lib/api.sh"

project= max_min=115 stall_min=15; tags=()
while [ $# -gt 0 ]; do
    case "$1" in
        --project) project="$2"; shift 2 ;;
        --max-min) max_min="$2"; shift 2 ;;
        --stall-min) stall_min="$2"; shift 2 ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown argument \"$1\"" ;;
        *) tags+=("$1"); shift ;;
    esac
done
[ -n "$project" ] && [ "${#tags[@]}" -gt 0 ] || die "--project and at least one brief tag are required"
poll="${WATCH_POLL_SECONDS:-60}"
max="${WATCH_MAX_SECONDS:-$((max_min * 60))}"
stall="${WATCH_STALL_SECONDS:-$((stall_min * 60))}"
declare -A root dirs
for tag in "${tags[@]}"; do
    d="$(brief_dir "$project" "$tag")" || exit 2
    [ -s "$d/sid" ] || die "no session for brief $tag ($d/sid)"
    root[$tag]="$(<"$d/sid")"; dirs[$tag]="$d"
done

start=$(date +%s); misses=0
say() { echo "[$(( ($(date +%s) - start) / 60 )) min] $*" | agent_text; }   # messages quote agent text

while :; do
    if ! all="$(oc_api GET '/api/session?limit=1000' 2>/dev/null)"; then
        misses=$((misses + 1)); say "server did not answer ($misses)"
        if [ "$misses" -ge 3 ]; then say "SERVER DOWN"; exit 8; fi
        sleep "$poll"; continue
    fi
    misses=0
    perms="$(oc_api GET /api/permission/request 2>/dev/null | jq -c '[(.data // [])[] | {id, sessionID, action, resources}]')"
    if [ -n "$perms" ] && [ "$perms" != "[]" ]; then say "PENDING PERMISSION: $perms"; exit 4; fi
    now=$(date +%s)
    for tag in "${tags[@]}"; do
        r="${root[$tag]}"; newest=0
        mapfile -t tree < <(jq -r --arg r "$r" '.data as $d
            | def kids($id): $d[] | select(.parentID == $id) | .id, kids(.id);
            $r, kids($r)' <<<"$all")
        for s in "${tree[@]}"; do
            forms="$(oc_api GET "/api/session/$s/form" 2>/dev/null | jq -c '[(.data // [])[] | {id, sessionID, title, fields: [.fields[]?.title]}]')"
            if [ -n "$forms" ] && [ "$forms" != "[]" ]; then say "$tag PENDING QUESTION: $forms"; exit 5; fi
            msgs="$(oc_api GET "/api/session/$s/message" 2>/dev/null)" || continue
            t="$(jq '[.data[]? | .time.created // 0] | max // 0' <<<"$msgs")"
            [ "$t" -gt "$newest" ] && newest="$t"
            if [ "$s" = "$r" ]; then
                idle="$(jq -r '.data | (map(.type) | index("user")) as $u | .[0:$u]
                               | map(select(.type == "idle")) | first | .outcome // empty' <<<"$msgs")"
                if [ -n "$idle" ]; then say "$tag IDLE: outcome=$idle"; exit 0; fi
            else
                err="$(jq -c --arg s "$s" '.data[0] | select(.error != null)
                              | {session: $s, id, error: .error.type, message: .error.message,
                                 at: ((.time.created / 1000) | floor | todate)}' <<<"$msgs")"
                if [ -n "$err" ]; then
                    id="$(jq -r .id <<<"$err")"
                    if ! grep -qxF "$id" "${dirs[$tag]}/seen-errors" 2>/dev/null; then
                        echo "$id" >> "${dirs[$tag]}/seen-errors"
                        say "$tag SUBAGENT ERROR: $err"; exit 6
                    fi
                fi
            fi
        done
        if [ "$newest" -gt 0 ] && [ $(( now - newest / 1000 )) -ge "$stall" ]; then
            say "$tag STALLED: no new message for $(( (now - newest / 1000) / 60 )) min"; exit 7
        fi
    done
    if [ $(( $(date +%s) - start )) -ge "$max" ]; then say "TIMEOUT"; exit 1; fi
    sleep "$poll"
done
