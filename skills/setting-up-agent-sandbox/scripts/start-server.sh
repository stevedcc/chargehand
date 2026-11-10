#!/usr/bin/env bash
# Run the OpenCode server in the sandbox, in the foreground of this terminal (Ctrl-C stops it),
# with its password from config.json's "server_password" (any form) and the machine kept from
# suspending while it runs.
# Usage: start-server.sh [--no-inhibit]
#   --no-inhibit   do not wrap the server in gnome-session-inhibit / systemd-inhibit
# Exit 1 when server_url already answers, 2 on a usage or config problem; otherwise the server's.
# Linux only (/proc, GNU coreutils: mv -T).
set -uo pipefail
# A wrapper that cannot run is reported below; without this, a failed exec ends the script bare.
shopt -s execfail
# This script by its absolute path: the wrapper may change directory before it runs it again.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${BASH_SOURCE[0]##*/}"
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$HARNESS_ROOT/scripts/lib/harness.sh"
. "$HARNESS_ROOT/scripts/lib/api.sh"
usage() { sed -n '5,6p' "$SELF" | sed 's/^# \{0,1\}//'; }

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
kind="$(server_password_form)" || exit 2
if [ "$have_pw_arg" = 1 ]; then
    # The re-run under the wrapper: the password is in this bash's argv until the exec at the end,
    # so it does no more than it must (the outer run probed the server already).
    [ "$kind" = wrapper ] || die "--password-arg is internal: only the wrapper form of server_password passes it"
    tok="$(_server_password_json | jq -r '.token // empty')"
    [ -n "$tok" ] || die 'server_password: the wrapper form needs a non-empty "wrapper" and a "token"'
    [ "$pw_arg" != "$tok" ] || die "server_password: the wrapper did not substitute the token"
    [ -n "$pw_arg" ] || die "server_password: the wrapper substituted an empty value"
    pw="$pw_arg"
else
    # Any HTTP answer (a 401 too) means a server already holds the port; a second would fail to bind.
    if oc_answers; then echo "chargehand: an OpenCode server is already running at $url" >&2; exit 1; fi
    if [ "$kind" = wrapper ]; then
        # The wrapper (e.g. `tswap run`) only substitutes into a command's arguments and refuses
        # env, printf or inline shells, so this script runs again as a script file under it, the
        # token in one argument. The value is then in that bash's argv, visible in the process list,
        # until it execs the inhibitor or sudo below: a few config reads, no network.
        mapfile -t wrap < <(_server_password_json | jq -r '.wrapper[]?')
        tok="$(_server_password_json | jq -r '.token // empty')"
        [ "${#wrap[@]}" -gt 0 ] && [ -n "$tok" ] \
            || die 'server_password: the wrapper form needs a non-empty "wrapper" and a "token"'
        exec "${wrap[@]}" bash "$SELF" --password-arg "$tok" "${orig[@]}" \
            || die "server_password: could not run the wrapper (${wrap[0]})"
    fi
    pw="$(server_password_value)" || exit 2
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
# start time, so a reused PID is never mistaken for it. Mode 600 and written whole (a temporary
# file, then mv): update-opencode.sh trusts only such a file of the owner's.
pidf="$HARNESS_STATE_DIR/server.pid"
# The temporary file is this process's own (two starts at once never share one); mv -T never moves
# it into a directory that took the file's name.
{ mkdir -p "$HARNESS_STATE_DIR" \
    && ( umask 077; printf '%s\n%s\n' "$$" "$(sed 's/^.*) //' "/proc/$$/stat" | cut -d' ' -f20)" > "$pidf.$$" ) \
    && mv -fT "$pidf.$$" "$pidf"; } || { rm -f "$pidf.$$"; die "could not write $pidf"; }
# A launcher installed before it refused to serve without a password would start an open server
# if sudo dropped the password: say so (setup-agent-user.sh installs the current one).
if [ -r "$launcher" ] && ! grep -q 'refusing to serve without OPENCODE_SERVER_PASSWORD' "$launcher"; then
    echo "chargehand: warning: $launcher is older than this script: it serves without a password if sudo drops it; re-run setup-agent-user.sh" >&2
fi
echo "chargehand: starting the OpenCode server at $url (Ctrl-C stops it)" >&2
# The password is in the environment of this exec chain (the inhibitor, sudo and the launcher; the
# sudoers rule keeps OPENCODE_SERVER_PASSWORD for the launcher only), the owner's processes, for the
# server's lifetime. Never in their argv or a file.
OPENCODE_SERVER_PASSWORD="$pw" exec "${cmd[@]}" sudo -n -u "$agent" "$launcher" \
    || { rm -f "$pidf"; die "could not run sudo or the inhibitor (${cmd[0]:-sudo})"; }
