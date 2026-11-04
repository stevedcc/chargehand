#!/usr/bin/env bash
# Run the OpenCode server in the sandbox, in the foreground of this terminal (Ctrl-C stops it),
# with its password from config.json's "server_password" (any form) and the machine kept from
# suspending while it runs.
# Usage: start-server.sh [--no-inhibit]
#   --no-inhibit   do not wrap the server in gnome-session-inhibit / systemd-inhibit
# Exit 1 when server_url already answers, 2 on a usage or config problem; otherwise the server's.
set -uo pipefail
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$HARNESS_ROOT/scripts/lib/harness.sh"
. "$HARNESS_ROOT/scripts/lib/api.sh"
usage() { sed -n '5,6p' "$0" | sed 's/^# \{0,1\}//'; }

inhibit=1 pw_arg= have_pw_arg=0 orig=()
while [ $# -gt 0 ]; do
    case "$1" in
        --no-inhibit) inhibit=0; orig+=("$1"); shift ;;
        # Internal: how the wrapper form hands the substituted value back to this script.
        --password-arg) [ $# -ge 2 ] || die "--password-arg needs a value"; pw_arg="$2"; have_pw_arg=1; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

url="$(config_get server_url http://127.0.0.1:4096)" || exit 2
agent="$(config_get agent_user opencode)" || exit 2
launcher="$(config_get launcher /usr/local/bin/chargehand-sandbox)" || exit 2
# Any HTTP answer (a 401 too) means a server already holds the port; a second would fail to bind.
if oc_answers; then echo "chargehand: an OpenCode server is already running at $url" >&2; exit 1; fi

kind="$(server_password_form)" || exit 2
if [ "$have_pw_arg" = 1 ]; then
    [ "$kind" = wrapper ] || die "--password-arg is internal: only the wrapper form of server_password passes it"
    pw="$pw_arg"
elif [ "$kind" = wrapper ]; then
    # The wrapper (e.g. `tswap run`) only substitutes into a command's arguments and refuses env,
    # printf or inline shells, so this script runs again as a script file under it, the token in
    # one argument. The value then sits in that bash's argv until it execs the launcher below: the
    # same exposure oc_api already accepts for its wrapper curl call.
    mapfile -t wrap < <(_server_password_json | jq -r '.wrapper[]')
    tok="$(_server_password_json | jq -r .token)"
    exec "${wrap[@]}" bash "$0" --password-arg "$tok" "${orig[@]}"
else
    # The "x" keeps a value's own trailing newlines, as oc_api does.
    pw="$(server_password_value && printf x)" || exit 2; pw="${pw%x}"
fi

cmd=()
if [ "$inhibit" = 1 ]; then
    if command -v gnome-session-inhibit >/dev/null; then
        cmd=(gnome-session-inhibit --inhibit=suspend --reason "Chargehand: OpenCode server running")
    elif command -v systemd-inhibit >/dev/null; then
        cmd=(systemd-inhibit --what=sleep --who=chargehand --why="OpenCode server running")
    else
        echo "chargehand: warning: neither gnome-session-inhibit nor systemd-inhibit found; the machine may suspend while agents work" >&2
    fi
fi

# update-opencode.sh stops this server through this file: the PID (kept by the exec below) and its
# start time, so a reused PID is never mistaken for it.
mkdir -p "$HARNESS_STATE_DIR"
printf '%s\n%s\n' "$$" "$(sed 's/^.*) //' "/proc/$$/stat" | cut -d' ' -f20)" > "$HARNESS_STATE_DIR/server.pid"
echo "chargehand: starting the OpenCode server at $url (Ctrl-C stops it)" >&2
# The password is in this exec's environment only (the sudoers rule keeps OPENCODE_SERVER_PASSWORD
# for the launcher): never in an argv or a file.
OPENCODE_SERVER_PASSWORD="$pw" exec "${cmd[@]}" sudo -n -u "$agent" "$launcher"
