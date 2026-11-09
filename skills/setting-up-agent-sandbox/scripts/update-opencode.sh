#!/usr/bin/env bash
# Update OpenCode for the agent user and restart the server around it: refuse while sessions are
# busy, upgrade, self-test the sandbox, stop the server, wait until it is started again, then show
# the project's model allocation against the new server.
# Usage: update-opencode.sh --project <name> [--force]
#   --force   go on while sessions are busy (their work stops with the server)
# Exit 1 when a step stops it (busy sessions, self-test, the server not stopping or not coming
# back, an interrupt); 2 usage or config; otherwise models.sh's own status (0 the allocation is
# usable, 3 it has problems).
# CHARGEHAND_POLL_SCALE (default 1) scales the poll intervals and time limits (for tests).
# Linux only (/proc, pgrep, GNU date).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(cd "$HERE/../../.." && pwd)"
. "$HARNESS_ROOT/scripts/lib/harness.sh"
. "$HARNESS_ROOT/scripts/lib/api.sh"
usage() { sed -n '5,6p' "$0" | sed 's/^# \{0,1\}//'; }

project= force=0
while [ $# -gt 0 ]; do
    case "$1" in
        --project) [ $# -ge 2 ] || { usage >&2; exit 2; }; project="$2"; shift 2 ;;
        --force) force=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[ -n "$project" ] || { usage >&2; exit 2; }
valid_name "$project" || die "bad project name \"$project\""
url="$(config_get server_url http://127.0.0.1:4096)" || exit 2
agent="$(config_get agent_user opencode)" || exit 2
launcher="$(config_get launcher /usr/local/bin/chargehand-sandbox)" || exit 2
pidf="$HARNESS_STATE_DIR/server.pid"

scaled() { awk -v v="$1" -v s="${CHARGEHAND_POLL_SCALE:-1}" -v f="$2" 'BEGIN { printf f, v * s }'; }
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }
# wait_server up|down INTERVAL LIMIT (seconds, before scaling): poll until the server answers (up)
# or stops answering (down); 1 when LIMIT runs out first.
wait_server() {
    local want="$1" interval end
    interval="$(scaled "$2" %.3f)"; end=$(( $(now_ms) + $(scaled "$(( $3 * 1000 ))" %d) ))
    while :; do
        if oc_answers; then [ "$want" = up ] && return 0; else [ "$want" = down ] && return 0; fi
        [ "$(now_ms)" -lt "$end" ] || return 1
        sleep "$interval"
    done
}
# server_sudo: the PID of the sudo that runs the server start-server.sh started, when server.pid
# still names that process (same PID and start time; start-server.sh exec'd into the inhibitor or
# straight into sudo). The owner may signal it: sudo's real uid is the owner's, and sudo relays the
# signal to the server. Only a file as start-server.sh writes it is trusted: the owner's, mode 600.
server_sudo() {
    local pid= start=
    [ -f "$pidf" ] && [ "$(stat -c '%a %u' "$pidf")" = "600 $(id -u)" ] || return 1
    { read -r pid; read -r start; } < "$pidf"
    [[ "$pid" =~ ^[0-9]+$ ]] && [ -r "/proc/$pid/stat" ] || return 1
    [ "$(sed 's/^.*) //' "/proc/$pid/stat" | cut -d' ' -f20)" = "$start" ] || return 1
    if [ "$(cat "/proc/$pid/comm")" = sudo ]; then echo "$pid"; return 0; fi
    pgrep -P "$pid" -x sudo | head -1 | grep .
}

# check_busy [NOTE]: list the busy sessions (stopping the server ends their work) and exit 1 unless
# --force, printing NOTE (what has happened so far) first. Run before the upgrade and again just
# before the stop, as a brief may start while OpenCode upgrades.
check_busy() {
    local sessions busy s
    sessions="$(oc_sessions)" || die "could not list the sessions at $url (is server_password right?)"
    mapfile -t busy < <(oc_busy_session_ids)
    [ "${#busy[@]}" -gt 0 ] || return 0
    echo "Busy sessions (updated in the last ${MODELS_BUSY_WINDOW_MIN:-20} min, not idle since their last prompt):"
    for s in "${busy[@]}"; do
        jq -r --arg s "$s" '.data[]? | select(.id == $s) | "  \(.id)  \(.title // "")"' <<<"$sessions"
    done | agent_text
    if [ "$force" = 0 ]; then
        [ -z "${1:-}" ] || echo "$1"
        echo "Wait for them to finish, or re-run with --force (their work stops with the server)." >&2
        exit 1
    fi
    echo "--force: going on; their work stops with the server."
}

# 1. Busy sessions.
if oc_answers; then check_busy
else echo "The server at $url is not answering; skipping the busy check."; fi

# 2-3. Upgrade as the agent user (OpenCode lives in its home), with the versions either side. Three
# sudo calls, one password prompt (sudo's cached credentials). -i: a login shell, as OpenCode's
# installer puts it on the agent's PATH there.
before="$(sudo -iu "$agent" opencode --version)" || die "could not read OpenCode's version as $agent"
echo "OpenCode before the upgrade: $before"
sudo -iu "$agent" opencode upgrade || die "opencode upgrade failed; the server was not touched"
after="$(sudo -iu "$agent" opencode --version)" || die "could not read OpenCode's version as $agent after the upgrade"
if [ "$after" = "$before" ]; then echo "OpenCode is already current ($after)."
else echo "OpenCode upgraded: $before -> $after"; fi

# 4. The sandbox must still hold before the server goes down: a FAIL line is a broken boundary.
st="$(sudo -n -u "$agent" "$launcher" --selftest --project "$project" 2>&1)"; rc=$?
# An ok line is "ok" alone or "ok " and more ("okay ..." is not); at least one must come.
bad="$(grep -v -E -e '^ok( |$)' -e '^$' <<<"$st")"; oks="$(grep -c -E '^ok( |$)' <<<"$st")"
if [ "$rc" -ne 0 ] || [ -n "$bad" ] || [ "$oks" -eq 0 ]; then
    [ -z "$bad" ] || agent_text <<<"$bad"
    [ "$oks" -gt 0 ] && why="exit $rc" || why="exit $rc, no ok lines"
    echo "chargehand: the sandbox self-test failed ($why); the server was not touched" >&2
    exit 1
fi
echo "Self-test: $oks ok lines."

# 5. Stop the running server, unless a session became busy meanwhile.
if ! oc_answers; then
    echo "The server is not running; nothing to stop."
else
    check_busy "OpenCode is upgraded; the server was not touched."
    # From here on the server may be down: an interrupt says how to bring it back.
    trap 'echo "chargehand: interrupted with the server stopped: start it again with $HERE/start-server.sh, then run bash $HARNESS_ROOT/skills/running-briefs/scripts/models.sh --project $project" >&2; exit 1' INT TERM
    if sp="$(server_sudo)"; then
        echo "Stopping the server (SIGTERM to its sudo, PID $sp)."
        kill -TERM "$sp" || echo "chargehand: could not signal PID $sp; stop the server now (Ctrl-C in its terminal)" >&2
    else
        echo "Stop the server now (Ctrl-C in its terminal)."
    fi
    wait_server down 2 120 || {
        echo "chargehand: the server at $url is still answering after $(scaled 120 %g) s; stop it and run this again" >&2
        exit 1
    }
    echo "The server has stopped."
fi

# 6. The owner starts it again in its own (visible, suspend-inhibited) terminal.
echo "Start it again: run $HERE/start-server.sh in the server's terminal"
wait_server up 5 1800 || {
    echo "chargehand: the server at $url did not answer within $(scaled 30 %g) min; once it runs: bash $HARNESS_ROOT/skills/running-briefs/scripts/models.sh --project $project" >&2
    exit 1
}
echo "The server is answering again."
trap - INT TERM

# 7. The allocation against the new server (its model list may have changed).
bash "$HARNESS_ROOT/skills/running-briefs/scripts/models.sh" --project "$project"
