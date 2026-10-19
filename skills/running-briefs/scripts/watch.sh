#!/usr/bin/env bash
# Watch running briefs and every subagent session under them until something needs you.
# Usage: watch.sh --project <name> [--max-min N (115)] [--stall-min M (15)] <tag>...
# Start it with Claude Code's run_in_background, never with "&". Exit codes:
#   0 a brief went idle           1 timeout, nothing happened      2 usage error
#   4 a permission is pending      5 a question (form) is pending
#   6 a subagent session ended in an error (each error is reported once)
#   7 no new message anywhere in a brief for M minutes            8 the server stopped answering, or the API lock stayed taken 5 polls
#  10 the brief's messages could not be read for 3 polls (not on the server, empty, or the
#     message list fails): the watcher is blind, not the brief quiet
#   9 the brief's own session ended in an error (provider 402/quota/auth ...) or went idle with
#     an outcome that is not a success: never verify; show the message
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
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown argument \"$1\"" ;;
        *) tags+=("$1"); shift ;;
    esac
done
[ -n "$project" ] && [ "${#tags[@]}" -gt 0 ] || die "--project and at least one brief tag are required"
poll="${WATCH_POLL_SECONDS:-60}"
max="${WATCH_MAX_SECONDS:-$((max_min * 60))}"
stall="${WATCH_STALL_SECONDS:-$((stall_min * 60))}"
declare -A root dirs lastupd childnew blind foreign
msglimit="${WATCH_MESSAGE_LIMIT:-50}"
for tag in "${tags[@]}"; do
    d="$(brief_dir "$project" "$tag")" || exit 2
    [ -s "$d/sid" ] || die "no session for brief $tag ($d/sid)"
    root[$tag]="$(<"$d/sid")"; dirs[$tag]="$d"
done

# Wrapper-form API calls queue on one lock: never wait longer for it than a poll takes.
export HARNESS_API_LOCK_WAIT="${HARNESS_API_LOCK_WAIT:-$(( poll > 3 ? poll * 2 / 3 : 1 ))}"
# One watcher per brief: two would report every event twice. A pid file, ignored when its owner is
# gone (a killed watcher leaves one) or is not a watch.sh any more (pid reuse).
for tag in "${tags[@]}"; do
    old="$(cat "${dirs[$tag]}/watch.pid" 2>/dev/null || true)"
    if [[ "$old" =~ ^[0-9]+$ ]] && [ "$old" != "$$" ] && kill -0 "$old" 2>/dev/null \
            && tr '\0' ' ' < "/proc/$old/cmdline" 2>/dev/null | grep -q 'watch\.sh'; then
        die "brief $tag is already being watched (pid $old, ${dirs[$tag]}/watch.pid); stop that watcher first"
    fi
done
for tag in "${tags[@]}"; do echo "$$" > "${dirs[$tag]}/watch.pid"; done
cleanup() { for tag in "${tags[@]}"; do [ "$(cat "${dirs[$tag]}/watch.pid" 2>/dev/null)" != "$$" ] || rm -f "${dirs[$tag]}/watch.pid"; done; }
trap cleanup EXIT
start=$(date +%s); misses=0 lockmisses=0 trunc_said=; trunc_file="${dirs[${tags[0]}]}/session-list.err"
say() { echo "[$(( ($(date +%s) - start) / 60 )) min] $*" | agent_text; }   # messages quote agent text

while :; do
    all="$(oc_sessions 2>"$trunc_file")" && listrc=0 || listrc=$?
    if [ -s "$trunc_file" ] && [ -z "$trunc_said" ]; then trunc_said=1; say "$(head -1 "$trunc_file")"; fi
    if [ "$listrc" -eq 75 ]; then
        # Another script holds the API lock (not a server problem): try again next poll.
        lockmisses=$((lockmisses + 1)); say "API lock busy ($lockmisses)"
        if [ "$lockmisses" -ge 5 ]; then say "API LOCK STUCK: another script has held the API lock for $lockmisses polls (state dir api.lock)"; exit 8; fi
        sleep "$poll"; continue
    fi
    lockmisses=0
    if [ "$listrc" -eq 2 ]; then   # oc_api's own die (config): not a server problem, and retrying will not help
        say "cannot call the API: $(oc_api GET /api/session 2>&1 >/dev/null | head -1)"; exit 2
    fi
    if [ "$listrc" -ne 0 ]; then
        misses=$((misses + 1)); say "server did not answer ($misses)"
        if [ "$misses" -ge 3 ]; then say "SERVER DOWN"; exit 8; fi
        sleep "$poll"; continue
    fi
    misses=0
    # Permission requests are server-wide: only those from the watched trees stop the watcher.
    watched="$(for tag in "${tags[@]}"; do jq -r --arg r "${root[$tag]}" '.data as $d
        | def kids($id): $d[] | select(.parentID == $id) | .id, kids(.id);
        $r, kids($r)' <<<"$all"; done | jq -R . | jq -sc .)"
    allperms="$(oc_api GET /api/permission/request 2>/dev/null | jq -c '[(.data // [])[] | {id, sessionID, action, resources}]')"
    perms="$(jq -c --argjson w "$watched" '[.[]? | select(.sessionID == null or (.sessionID as $s | $w | index($s)))]' <<<"${allperms:-[]}")"
    if [ -n "$perms" ] && [ "$perms" != "[]" ]; then say "PENDING PERMISSION: $perms"; exit 4; fi
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        fid="$(jq -r .id <<<"$f")"
        if [ -z "${foreign[$fid]:-}" ]; then foreign[$fid]=1; say "permission request from a session outside these briefs (not for this watcher, not stopping): $f"; fi
    done < <(jq -c --argjson w "$watched" '.[]? | select(.sessionID != null and (.sessionID as $s | $w | index($s) | not))' <<<"${allperms:-[]}")
    now=$(date +%s)
    for tag in "${tags[@]}"; do
        r="${root[$tag]}"; newest=0; rootok=0; why="the brief's session is not on the server"
        mapfile -t tree < <(jq -r --arg r "$r" '.data as $d
            | def kids($id): $d[] | select(.parentID == $id) | .id, kids(.id);
            $r, kids($r)' <<<"$all")
        for s in "${tree[@]}"; do
            forms="$(oc_api GET "/api/session/$s/form" 2>/dev/null | jq -c '[(.data // [])[] | {id, sessionID, title, fields: [.fields[]?.title]}]')"
            if [ -n "$forms" ] && [ "$forms" != "[]" ]; then say "$tag PENDING QUESTION: $forms"; exit 5; fi
            # The session list's own time.updated moves on every part write: a streaming step is
            # alive, a dead one is not. Message lists are fetched for the root every poll and for
            # a child only when its updated time changed.
            upd="$(jq -r --arg s "$s" '[.data[]? | select(.id == $s) | (.time.updated // 0 | tonumber? // 0)] | first // 0' <<<"$all")"
            [ "$upd" -gt "$newest" ] && newest="$upd"
            if [ "$s" != "$r" ] && [ "${lastupd[$s]:-}" = "$upd" ]; then
                [ "${childnew[$s]:-0}" -gt "$newest" ] && newest="${childnew[$s]}"
                continue
            fi
            msgs="$(oc_api GET "/api/session/$s/message?limit=$msglimit" 2>/dev/null)" && mrc=0 || mrc=$?
            if [ "$mrc" -ne 0 ]; then
                if [ "$s" = "$r" ]; then
                    why="the brief's message list did not answer"; [ "$mrc" -ne 75 ] || why="the API lock was busy (another script holds it)"
                fi
                continue
            fi
            msgs="$(oc_newest_first <<<"$msgs")"   # idle/error checks below read the newest message first
            t="$(jq '[.data[]? | (.time.created // 0 | tonumber? // 0)] | max // 0' <<<"$msgs")"
            [ "$t" -gt "$newest" ] && newest="$t"
            if [ "$s" = "$r" ]; then
                if [ "$(jq '.data | length' <<<"$msgs")" -eq 0 ]; then why="the brief's message list is empty"; continue; fi
                rootok=1
                # Only messages newer than the last prompt count.
                rerr="$(jq -c --arg s "$s" '.data | (map(.type) | index("user")) as $u | .[0:$u]
                              | map(select(.type == "assistant")) | first // empty | select(.error != null)
                              | {session: $s, id, error: .error.type, message: .error.message,
                                 at: ((.time.created / 1000) | floor | todate)}' <<<"$msgs")"
                idle="$(jq -r '.data | (map(.type) | index("user")) as $u | .[0:$u]
                               | map(select(.type == "idle")) | first | .outcome // empty' <<<"$msgs")"
                if [ -n "$rerr" ]; then
                    id="$(jq -r .id <<<"$rerr")"
                    if [ -n "$idle" ] || ! grep -qxF "$id" "${dirs[$tag]}/seen-errors" 2>/dev/null; then
                        echo "$id" >> "${dirs[$tag]}/seen-errors"
                        say "$tag BRIEF SESSION ERROR${idle:+ (idle, outcome=$idle)}: $rerr"; exit 9
                    fi
                fi
                if [ -n "$idle" ]; then
                    case "$idle" in
                        succeeded|success|completed) say "$tag IDLE: outcome=$idle"; exit 0 ;;
                        *) say "$tag BRIEF SESSION ERROR: idle with outcome=$idle (not a success; read the last messages)"; exit 9 ;;
                    esac
                fi
            else
                lastupd[$s]="$upd"; childnew[$s]="$t"
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
        # A brief whose messages cannot be read is a blind watch, not a quiet brief: say so.
        if [ "$rootok" -eq 1 ]; then blind[$tag]=0; else
            blind[$tag]=$(( ${blind[$tag]:-0} + 1 ))
            say "$tag cannot read the brief: $why (${blind[$tag]})"
            if [ "${blind[$tag]}" -ge 3 ]; then say "$tag WATCHER BLIND: $why, 3 polls in a row"; exit 10; fi
            continue
        fi
        if [ "$newest" -gt 0 ] && [ $(( now - newest / 1000 )) -ge "$stall" ]; then
            say "$tag STALLED: no new message for $(( (now - newest / 1000) / 60 )) min"; exit 7
        fi
    done
    if [ $(( $(date +%s) - start )) -ge "$max" ]; then say "TIMEOUT"; exit 1; fi
    sleep "$poll"
done
