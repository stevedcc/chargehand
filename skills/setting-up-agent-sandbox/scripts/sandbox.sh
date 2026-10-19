#!/usr/bin/env bash
# The agent sandbox launcher: OpenCode's server, a self-test, or a verification run, inside
# bubblewrap, as the dedicated agent user.
#
# The sandbox can only see:
#   - each project's agent clone (read/write; read-only in --verify mode) and its read-only mirror
#   - a private /tmp (host: /tmp/chargehand-<user>) and, in --verify mode, ~/verify/<project>
#   - the project's toolchain mounts, the harness's implementer files (read-only), git config and
#     OpenCode's own state
#   - the user's own rootless Podman socket (Testcontainers)
#   - the system (/usr, /etc) read-only
# Everything else under /home does not exist inside the sandbox; $HOME itself is an in-memory tmpfs.
#
# Installed root-owned as /usr/local/bin/chargehand-sandbox by setup-agent-user.sh, which pins
# HARNESS_ETC and HARNESS_SHARE below to their literal paths. Project settings come only from the
# root-owned $HARNESS_ETC/<project>.env files setup renders, never from the caller.
#
# Usage:
#   chargehand-sandbox                                  opencode serve on 127.0.0.1:4096, all projects
#   chargehand-sandbox --selftest --project <name>      check the boundaries and the toolchain
#   chargehand-sandbox --verify --project <name> <sha>  clean checkout of <sha>, build, all suites
set -euo pipefail

HARNESS_ETC="${CHARGEHAND_ETC:-/etc/chargehand}"
HARNESS_SHARE="${CHARGEHAND_SHARE:-/usr/local/share/chargehand}"

# Never trust an inherited HOME (sudo may keep the caller's); use the running user's own.
HOME="$(getent passwd "$(id -un)" | cut -d: -f6)"
export HOME

home_path() { case "$1" in "~") echo "$HOME" ;; "~/"*) echo "$HOME/${1#\~/}" ;; *) echo "$1" ;; esac; }

# load_project NAME: source its env file after checking nobody else could have written it.
load_project() {
    local f="$HARNESS_ETC/$1.env"
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "bad project name \"$1\"" >&2; exit 2; }
    [ -f "$f" ] || { echo "no project $1 ($f)" >&2; exit 2; }
    case "$(stat -c '%a' "$f")" in
        *[2367]? | *[2367]) echo "$f is writable by others" >&2; exit 2 ;;
    esac
    if [ -z "${CHARGEHAND_ETC:-}" ] && [ "$(stat -c '%u' "$f")" != 0 ]; then
        echo "$f is not root-owned" >&2; exit 2
    fi
    # shellcheck disable=SC1090
    . "$f"
}

mode=serve project=
case "${1:-}" in
    --selftest)
        [ "${2:-}" = --project ] && [ "$#" -eq 3 ] || { echo "Usage: $0 --selftest --project <name>" >&2; exit 2; }
        mode=selftest project="$3" ;;
    --verify)
        [ "${2:-}" = --project ] && [ "$#" -eq 4 ] && [[ "$4" =~ ^[0-9a-f]{7,40}$ ]] \
            || { echo "Usage: $0 --verify --project <name> <commit sha (7-40 hex)>" >&2; exit 2; }
        mode=verify project="$3" sha="$4" ;;
    "") ;;
    *) echo "Usage: $0 [--selftest --project <name> | --verify --project <name> <sha>]" >&2; exit 2 ;;
esac

# Collect the projects this run mounts: one for selftest/verify, every configured one for serve.
clones=() mirrors=() ro=() rw=() paths=() envs=()
add_project() {
    local line
    clones+=("$AGENT_CLONE"); mirrors+=("$MIRROR")
    while IFS= read -r line; do if [ -n "$line" ]; then ro+=("$(home_path "$line")"); fi; done <<<"$TOOLCHAIN_RO"
    while IFS= read -r line; do if [ -n "$line" ]; then rw+=("$(home_path "$line")"); fi; done <<<"$TOOLCHAIN_RW"
    while IFS= read -r line; do if [ -n "$line" ]; then paths+=("$(home_path "$line")"); fi; done <<<"$PATH_PREPEND"
    while IFS= read -r line; do if [ -n "$line" ]; then envs+=("$line"); fi; done <<<"$SANDBOX_ENV"
}
if [ "$mode" = serve ]; then
    found=0
    for f in "$HARNESS_ETC"/*.env; do
        [ -e "$f" ] || continue
        load_project "$(basename "$f" .env)"; add_project; found=1
    done
    [ "$found" -eq 1 ] || { echo "no projects in $HARNESS_ETC" >&2; exit 2; }
else
    load_project "$project"; add_project
fi

PRIVATE_TMP="/tmp/chargehand-$(id -un)"
RUNTIME_DIR="/run/user/$(id -u)"
PODMAN_SOCKET="$RUNTIME_DIR/podman/podman.sock"
# verify mode gets its own /tmp: build servers and stack PID files live there, and must never be
# shared with the agent's server sandbox.
[ "$mode" = verify ] && PRIVATE_TMP="$PRIVATE_TMP-verify"
mkdir -p "$PRIVATE_TMP" "$HOME/.config/opencode" "$HOME/.local/share/opencode" \
         "$HOME/.local/state/opencode" "$HOME/.cache/opencode"
[ -S "$PODMAN_SOCKET" ] || { echo "Podman socket $PODMAN_SOCKET missing: systemctl --user enable --now podman.socket" >&2; exit 1; }

args=(
    --die-with-parent
    --unshare-pid --unshare-ipc --unshare-uts
    --ro-bind /usr /usr
    --symlink usr/bin /bin --symlink usr/sbin /sbin
    --symlink usr/lib /lib --symlink usr/lib64 /lib64
    --ro-bind /etc /etc
    --proc /proc
    --dev /dev
    --tmpfs /run
    --ro-bind /run/systemd/resolve /run/systemd/resolve
    --bind "$PODMAN_SOCKET" "$PODMAN_SOCKET"
    --bind "$PRIVATE_TMP" /tmp
    --tmpfs /var/tmp
    --tmpfs /home
    --dir "$HOME"
    --bind "$HOME/.config/opencode" "$HOME/.config/opencode"
    --bind "$HOME/.local/share/opencode" "$HOME/.local/share/opencode"
    --bind "$HOME/.local/state/opencode" "$HOME/.local/state/opencode"
    --bind "$HOME/.cache/opencode" "$HOME/.cache/opencode"
)
for p in "${ro[@]}"; do if [ -e "$p" ]; then args+=(--ro-bind "$p" "$p"); fi; done
for p in "${rw[@]}"; do mkdir -p "$p"; args+=(--bind "$p" "$p"); done
[ -d "$HARNESS_SHARE" ] && args+=(--ro-bind "$HARNESS_SHARE" "$HARNESS_SHARE")
for i in "${!clones[@]}"; do
    c="${clones[$i]}"
    if [ "$mode" = verify ]; then
        # Verification never touches the agent's working clone: read-only source, separate checkout.
        args+=(--ro-bind "$c" "$c")
    else
        args+=(--bind "$c" "$c")
        # setup-agent-user.sh creates normal clones (.git inside the clone). The clone belongs to the
        # agent, so what it reports as its git directory is agent-controlled: never mount a path it
        # names. A git directory outside the clone means someone changed it — refuse.
        common="$(git -C "$c" rev-parse --path-format=absolute --git-common-dir)"
        case "$common/" in
            "$c"/*) ;;
            *) echo "sandbox: $c's git directory is outside the clone ($common); refusing" >&2; exit 2 ;;
        esac
    fi
    if [ -d "${mirrors[$i]}" ]; then args+=(--ro-bind "${mirrors[$i]}" "${mirrors[$i]}"); fi
done
if [ "$mode" = verify ]; then
    # A fresh checkout every run: a previous run's code could have planted hooks or config in a
    # persistent .git and rigged every later verification.
    VERIFY_DIR="$HOME/verify/$project"
    rm -rf "$VERIFY_DIR"; mkdir -p "$VERIFY_DIR"; args+=(--bind "$VERIFY_DIR" "$VERIFY_DIR")
fi
for p in "$HOME/.gitconfig" "$HOME/.opencode"; do
    if [ -e "$p" ]; then args+=(--ro-bind "$p" "$p"); fi
done

path=""; for p in "${paths[@]}"; do path+="$p:"; done
args+=(
    --chdir "${clones[0]}"
    --clearenv
    --setenv HOME "$HOME"
    --setenv USER "$(id -un)"
    --setenv LANG "${LANG:-C.UTF-8}"
    --setenv TERM "${TERM:-xterm-256color}"
    --setenv PATH "${path}$HOME/.opencode/bin:/usr/local/bin:/usr/bin"
    --setenv XDG_RUNTIME_DIR "$RUNTIME_DIR"
    --setenv DOCKER_HOST "unix://$PODMAN_SOCKET"
    --setenv TMPDIR /tmp
)
for e in "${envs[@]}"; do args+=(--setenv "${e%%=*}" "${e#*=}"); done
# The server password never goes on a command line (bwrap's argv lives as long as the server, and
# /proc/<pid>/cmdline is world-readable). Serve mode hands it over on fd 3; the other modes run
# agent code and never get it (--clearenv drops it).
password="${OPENCODE_SERVER_PASSWORD:-}"
unset OPENCODE_SERVER_PASSWORD

# The self-test. TEST_FILTER is the project's verify filter, so verify and its check share one
# definition. Keep this a quoted heredoc: no expansion here, values arrive through --setenv.
read -r -d '' SELFTEST <<'EOF' || true
fail=0
chk() { if eval "$2" >/dev/null 2>&1; then r=yes; else r=no; fi
        if [ "$r" = "$3" ]; then echo "  ok    $1"; else echo "  FAIL  $1 (got $r, want $3)"; fail=1; fi; }
echo "Must be blocked:"
for h in $OTHERS; do chk "see $h" "ls $h" no; done
chk "sudo"                           "sudo -n true" no
chk "rootful podman socket"          "ls /run/podman/podman.sock" no
if [ -n "$UPSTREAM" ]; then chk "write upstream mirror" "touch $UPSTREAM/probe" no; fi
echo "Must work:"
chk "write own clone"                "touch .sandbox-probe && rm .sandbox-probe" yes
chk "write /tmp"                     "touch /tmp/p && rm /tmp/p" yes
chk "git status + object write"      "git status --short && echo probe | git hash-object -w --stdin" yes
if [ -n "$UPSTREAM" ]; then chk "fetch from upstream mirror" "git fetch --dry-run origin" yes; fi
chk "own podman socket"              "curl -sf --unix-socket $XDG_RUNTIME_DIR/podman/podman.sock http://d/v4.0.0/libpod/_ping" yes
chk "internet"                       "curl -sfI https://github.com" yes
chk "opencode binary"                "command -v opencode" yes
echo "Harness files:"
chk "read implementer rules"         "test -r $HARNESS_SHARE/rules.md" yes
chk "write implementer rules"        "touch $HARNESS_SHARE/probe" no
chk "write project config"           "touch $HARNESS_ETC/probe" no
if [ -n "$SELFTEST_EXTRA" ]; then
    echo "Project:"
    while IFS=$'\t' read -r name cmd <&3; do chk "$name" "$cmd" yes; done 3<<<"$SELFTEST_EXTRA"
fi
echo "Verify output filter:"
printf "%s\n" "Passed!  - Failed:     0, Passed:     3, Skipped:     0, Total:     3" > /tmp/vf-pass
printf "%s\n" "      Failed executing DbCommand (2ms) [Parameters=[]]" "  Failed Ns.Cls.Name [5 s]" \
    "  Error Message:" "   boom" "Failed!  - Failed:     1, Passed:     2" > /tmp/vf-fail
chk "keeps a passing summary"        "grep -E -A1 \"\$TEST_FILTER\" /tmp/vf-pass | grep -q Passed!" yes
chk "names a failing test"           "grep -E -A1 \"\$TEST_FILTER\" /tmp/vf-fail | grep -q Ns.Cls.Name" yes
chk "keeps its error message"        "grep -E -A1 \"\$TEST_FILTER\" /tmp/vf-fail | grep -q boom" yes
chk "keeps a failing summary"        "grep -E -A1 \"\$TEST_FILTER\" /tmp/vf-fail | grep -q Failed!" yes
chk "drops EF Core log noise"        "grep -E -A1 \"\$TEST_FILTER\" /tmp/vf-fail | grep -q DbCommand" no
rm -f /tmp/vf-pass /tmp/vf-fail
exit $fail
EOF

# Verification: a clean checkout of SHA from the agent clone, the project's build, its test suites
# (filtered to summaries and failures), then its E2E command on instances of verify's own range.
read -r -d '' VERIFY <<'EOF' || true
set -euo pipefail
git -c core.hooksPath=/dev/null clone -q --no-checkout "$SRC" "$VERIFY_DIR"
cd "$VERIFY_DIR"
git -c core.hooksPath=/dev/null checkout -q --detach "$SHA"
echo "Verifying $(git log --oneline -1)"
[ -z "$VERIFY_BUILD" ] || eval "$VERIFY_BUILD"
status=0
while IFS= read -r t <&3; do
    [ -n "$t" ] || continue
    eval "$t" 2>&1 | grep -E -A1 "$TEST_FILTER" || status=1
    [ "${PIPESTATUS[0]}" -eq 0 ] || status=1
done 3<<<"$VERIFY_TESTS"
if [ -n "$E2E_COMMAND" ]; then
    stop_e2e() {
        local i
        for i in $(seq "$E2E_VERIFY_FIRST" $((E2E_VERIFY_FIRST + E2E_INSTANCES - 1))); do
            [ -z "$E2E_STOP" ] || eval "${E2E_STOP//\{I\}/$i}" >/dev/null 2>&1 || true
        done
    }
    trap stop_e2e EXIT
    cmd="${E2E_COMMAND//\{N\}/$E2E_INSTANCES}"; cmd="${cmd//\{K\}/$E2E_VERIFY_FIRST}"
    eval "$cmd" 2>&1 | grep -E -A1 "$TEST_FILTER" || status=1
    [ "${PIPESTATUS[0]}" -eq 0 ] || status=1
fi
exit "$status"
EOF

case "$mode" in
selftest)
    # Paths that must NOT be visible: every other user's home.
    others="$(getent passwd | awk -F: '$3>=1000 && $3<60000 {print $6}' | grep -vx "$HOME" | tr '\n' ' ')"
    exec bwrap "${args[@]}" --setenv OTHERS "$others" --setenv UPSTREAM "$MIRROR" \
        --setenv TEST_FILTER "$TEST_FILTER" --setenv SELFTEST_EXTRA "$SELFTEST_EXTRA" \
        --setenv HARNESS_ETC "$HARNESS_ETC" --setenv HARNESS_SHARE "$HARNESS_SHARE" \
        -- bash -c "$SELFTEST" ;;
verify)
    exec bwrap "${args[@]}" --setenv SRC "$AGENT_CLONE" --setenv SHA "$sha" --setenv VERIFY_DIR "$VERIFY_DIR" \
        --setenv TEST_FILTER "$TEST_FILTER" --setenv VERIFY_BUILD "$VERIFY_BUILD" --setenv VERIFY_TESTS "$VERIFY_TESTS" \
        --setenv E2E_COMMAND "$E2E_COMMAND" --setenv E2E_VERIFY_FIRST "$E2E_VERIFY_FIRST" \
        --setenv E2E_INSTANCES "$E2E_INSTANCES" --setenv E2E_STOP "$E2E_STOP" \
        -- bash -c "$VERIFY" ;;
serve)
    if [ -n "$password" ]; then
        exec 3<<<"$password"; unset password
        exec bwrap "${args[@]}" -- bash -c \
            'IFS= read -r OPENCODE_SERVER_PASSWORD <&3; exec 3<&-; export OPENCODE_SERVER_PASSWORD; exec "$@"' \
            serve "$HOME/.opencode/bin/opencode" serve --hostname 127.0.0.1 --port 4096
    fi
    exec bwrap "${args[@]}" -- "$HOME/.opencode/bin/opencode" serve --hostname 127.0.0.1 --port 4096 ;;
esac
