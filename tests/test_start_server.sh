. "$(dirname "$0")/lib.sh"
START="$HARNESS_ROOT/skills/setting-up-agent-sandbox/scripts/start-server.sh"
PW='s3cret "pw" value'
export EXPECTED_PW="$PW"
unset OPENCODE_SERVER_PASSWORD

# The scripts run on a PATH of stubs plus links to the few system tools they need, so a test can
# leave gnome-session-inhibit or systemd-inhibit out even where the machine has them.
# Every stub appends "<name> pid=<its pid> pw=<match|unset|other> argv=<args>" to $TEST_TMP/calls:
# whether the launcher got the password in its environment, never the value itself.
setup_bin() {
    mkdir -p "$TEST_TMP/bin" "$TEST_TMP/sys"
    local c p
    for c in bash jq curl mkdir stat id sed cut dirname cat env grep rm mv flock sleep date; do
        p="$(type -P "$c")" && ln -sf "$p" "$TEST_TMP/sys/$c"
    done
    export TEST_TMP
}
stub() {
    local name="$1" rest="${2:-}"
    cat > "$TEST_TMP/bin/$name" <<EOF
#!/bin/bash
if [ -z "\${OPENCODE_SERVER_PASSWORD+x}" ]; then s=unset
elif [ "\$OPENCODE_SERVER_PASSWORD" = "\$EXPECTED_PW" ]; then s=match; else s=other; fi
st=\$(sed 's/^.*) //' /proc/\$\$/stat | cut -d' ' -f20)
echo "$name pid=\$\$ start=\$st pw=\$s argv=\$*" >> "\$TEST_TMP/calls"
$rest
EOF
    chmod +x "$TEST_TMP/bin/$name"
}
# Both inhibitors run their command as a child, as the real ones do.
gnome_stub()   { stub gnome-session-inhibit 'while [[ "$1" == --* ]]; do [ "$1" = --reason ] && shift; shift; done; "$@"'; }
systemd_stub() { stub systemd-inhibit 'while [[ "$1" == --* ]]; do shift; done; "$@"'; }
sudo_stub()    { stub sudo 'exit 0'; }
run_start() { PATH="$TEST_TMP/bin:$TEST_TMP/sys" "$(type -P bash)" "$START" "$@"; }
calls() { cat "$TEST_TMP/calls" 2>/dev/null; }
with_form() {
    write_config "{\"server_url\": \"http://127.0.0.1:1\", \"agent_user\": \"agentx\", \"launcher\": \"/opt/ch/launcher\", \"server_password\": $1}"
}
pid_of() { calls | grep "^$1 " | head -1 | sed 's/.* pid=\([0-9]*\) .*/\1/'; }
start_of() { calls | grep "^$1 " | head -1 | sed 's/.* start=\([0-9]*\) .*/\1/'; }
# A stand-in for `tswap run`: replaces TOKEN in its arguments with the password, then runs them.
# It also logs its arguments after the substitution, with the value shown as <PW>.
wrap_stub() {
    stub wrap 'args=(); for a in "$@"; do args+=("${a//TOKEN/$EXPECTED_PW}"); done
shown=(); for a in "${args[@]}"; do shown+=("${a//"$EXPECTED_PW"/<PW>}"); done
echo "wrap substituted: ${shown[*]}" >> "$TEST_TMP/calls"
exec "${args[@]}"'
}
no_pid_file() { [ -e "$HARNESS_STATE_DIR/server.pid" ] && echo yes || echo no; }

test_env_form_gnome_inhibit_and_pid_file() {
    setup_bin; sudo_stub; gnome_stub; systemd_stub
    export SS_PW="$PW"; with_form '{"env": "SS_PW"}'
    out="$(run_start 2>&1)"; rc=$?
    assert_eq "exit 0" "$rc" "0"
    assert_contains "gnome-session-inhibit wraps the launcher" "$(calls)" \
        "gnome-session-inhibit pid=$(pid_of gnome-session-inhibit) start=$(start_of gnome-session-inhibit) pw=match argv=--inhibit=suspend --reason Chargehand: OpenCode server running sudo -n -u agentx /opt/ch/launcher"
    assert_contains "the launcher runs as the agent user with the password in its env" "$(calls)" \
        "pw=match argv=-n -u agentx /opt/ch/launcher"
    assert_not_contains "systemd-inhibit not used" "$(calls)" "systemd-inhibit"
    assert_not_contains "password in no argv" "$(calls)" "s3cret"
    assert_not_contains "password not printed" "$out" "s3cret"
    assert_eq "pid file names the process that became the inhibitor" \
        "$(head -1 "$HARNESS_STATE_DIR/server.pid")" "$(pid_of gnome-session-inhibit)"
    assert_eq "and its start time" "$(sed -n 2p "$HARNESS_STATE_DIR/server.pid")" "$(start_of gnome-session-inhibit)"
    assert_eq "pid file mode 600" "$(stat -c %a "$HARNESS_STATE_DIR/server.pid")" "600"
    assert_eq "no temporary file left" "$(ls -A "$HARNESS_STATE_DIR")" "server.pid"
}
test_pid_file_write_failure_stops_before_the_launcher() {
    setup_bin; sudo_stub; export SS_PW="$PW"; with_form '{"env": "SS_PW"}'
    mkdir -p "$(dirname "$HARNESS_STATE_DIR")"; : > "$HARNESS_STATE_DIR"   # a file where the folder should be
    out="$(run_start --no-inhibit 2>&1)"; rc=$?
    assert_eq "exit 2" "$rc" "2"
    assert_contains "says why" "$out" "could not write $HARNESS_STATE_DIR/server.pid"
    assert_eq "launcher not run" "$(calls)" ""
}
test_pid_file_path_taken_by_a_directory_stops_before_the_launcher() {
    setup_bin; sudo_stub; export SS_PW="$PW"; with_form '{"env": "SS_PW"}'
    mkdir -p "$HARNESS_STATE_DIR/server.pid"
    out="$(run_start --no-inhibit 2>&1)"; rc=$?
    assert_eq "exit 2" "$rc" "2"
    assert_contains "says why" "$out" "could not write $HARNESS_STATE_DIR/server.pid"
    assert_eq "launcher not run" "$(calls)" ""
    assert_eq "no temporary file left" "$(ls -A "$HARNESS_STATE_DIR")" "server.pid"
}
test_password_with_a_newline_is_refused() {
    setup_bin; sudo_stub; export SS_PW=$'two\nlines'; with_form '{"env": "SS_PW"}'
    out="$(run_start --no-inhibit 2>&1)"; rc=$?
    assert_eq "exit 2" "$rc" "2"
    assert_contains "says why" "$out" "server_password: the value contains a line break"
    assert_eq "launcher not run" "$(calls)" ""
}
test_file_form() {
    setup_bin; sudo_stub
    printf '%s\n' "$PW" > "$HOME/pw"; chmod 600 "$HOME/pw"; with_form '{"file": "~/pw"}'
    out="$(run_start --no-inhibit 2>&1)"
    assert_contains "launcher got the value" "$(calls)" "sudo pid=$(pid_of sudo) start=$(start_of sudo) pw=match argv=-n -u agentx /opt/ch/launcher"
    assert_not_contains "password in no argv" "$(calls)" "s3cret"
    assert_not_contains "password not printed" "$out" "s3cret"
}
test_command_form() {
    setup_bin; sudo_stub
    printf '#!/bin/bash\nprintf "%%s" "$EXPECTED_PW"\n' > "$TEST_TMP/getpw"; chmod +x "$TEST_TMP/getpw"
    with_form "{\"command\": [\"$TEST_TMP/getpw\"]}"
    out="$(run_start --no-inhibit 2>&1)"
    assert_contains "launcher got the value" "$(calls)" "pw=match argv=-n -u agentx /opt/ch/launcher"
    assert_not_contains "password in no argv" "$(calls)" "s3cret"
}
test_password_lookup_failure_stops_before_the_launcher() {
    setup_bin; sudo_stub; with_form '{"env": "SS_UNSET_PW"}'
    out="$(run_start --no-inhibit 2>&1)"; rc=$?
    assert_eq "exit 2" "$rc" "2"
    assert_contains "says why" "$out" 'server_password: $SS_UNSET_PW is empty'
    assert_eq "launcher not run" "$(calls)" ""
}
test_wrapper_form_reruns_under_the_wrapper() {
    setup_bin; sudo_stub; gnome_stub
    wrap_stub; stub curl 'exec "$TEST_TMP/sys/curl" "$@"'
    with_form '{"wrapper": ["wrap"], "token": "TOKEN"}'
    out="$(run_start 2>&1)"; rc=$?
    assert_eq "exit 0" "$rc" "0"
    assert_contains "re-run as a script file under the wrapper, token in one argument" "$(calls)" \
        "wrap pid=$(pid_of wrap) start=$(start_of wrap) pw=unset argv=bash $START --password-arg TOKEN"
    assert_contains "after substitution the value is in that one argument (<PW> marks it in the log)" "$(calls)" \
        "wrap substituted: bash $START --password-arg <PW>"
    assert_contains "launcher got the substituted value" "$(calls)" "pw=match argv=-n -u agentx /opt/ch/launcher"
    assert_not_contains "password in no stub's argv, the wrapper's included" "$(calls)" "s3cret"
    assert_not_contains "password not printed" "$out" "s3cret"
    assert_eq "the server is probed once, before the wrapper: the re-run (password in its argv) skips it" \
        "$(calls | grep -c '^curl ')" "1"
}
test_wrapper_that_does_not_substitute_is_refused() {
    setup_bin; sudo_stub; stub wrap 'exec "$@"'
    with_form '{"wrapper": ["wrap"], "token": "TOKEN"}'
    out="$(run_start --no-inhibit 2>&1)"; rc=$?
    assert_eq "exit 2" "$rc" "2"
    assert_contains "says why" "$out" "server_password: the wrapper did not substitute the token"
    assert_not_contains "launcher not run" "$(calls)" "/opt/ch/launcher"
    assert_eq "no pid file" "$(no_pid_file)" "no"
}
test_wrapper_that_substitutes_an_empty_value_is_refused() {
    setup_bin; sudo_stub; stub wrap 'args=(); for a in "$@"; do args+=("${a//TOKEN/}"); done; exec "${args[@]}"'
    with_form '{"wrapper": ["wrap"], "token": "TOKEN"}'
    out="$(run_start --no-inhibit 2>&1)"; rc=$?
    assert_eq "exit 2" "$rc" "2"
    assert_contains "says why" "$out" "server_password: the wrapper substituted an empty value"
    assert_not_contains "launcher not run" "$(calls)" "/opt/ch/launcher"
}
test_wrapper_that_changes_directory_still_finds_the_script() {
    setup_bin; sudo_stub
    stub wrap 'cd /; args=(); for a in "$@"; do args+=("${a//TOKEN/$EXPECTED_PW}"); done; exec "${args[@]}"'
    with_form '{"wrapper": ["wrap"], "token": "TOKEN"}'
    out="$(cd "$(dirname "$START")" && PATH="$TEST_TMP/bin:$TEST_TMP/sys" "$(type -P bash)" ./start-server.sh --no-inhibit 2>&1)"; rc=$?
    assert_eq "exit 0" "$rc" "0"
    assert_contains "launcher got the value" "$(calls)" "pw=match argv=-n -u agentx /opt/ch/launcher"
}
test_missing_sudo_is_reported() {
    setup_bin; export SS_PW="$PW"; with_form '{"env": "SS_PW"}'   # no sudo on PATH
    out="$(run_start --no-inhibit 2>&1)"; rc=$?
    assert_eq "exit 2" "$rc" "2"
    assert_contains "says why" "$out" "could not run sudo"
    assert_eq "no pid file naming a process that never ran" "$(no_pid_file)" "no"
}
test_an_old_installed_launcher_is_reported() {
    setup_bin; sudo_stub; export SS_PW="$PW"
    printf '#!/bin/bash\n# a launcher from before the refusal\n' > "$TEST_TMP/old-launcher"
    write_config "{\"server_url\": \"http://127.0.0.1:1\", \"agent_user\": \"agentx\", \"launcher\": \"$TEST_TMP/old-launcher\", \"server_password\": {\"env\": \"SS_PW\"}}"
    out="$(run_start --no-inhibit 2>&1)"
    assert_contains "warns" "$out" "warning: $TEST_TMP/old-launcher is older than this script"
    printf '#!/bin/bash\necho "refusing to serve without OPENCODE_SERVER_PASSWORD"\n' > "$TEST_TMP/old-launcher"
    out="$(run_start --no-inhibit 2>&1)"
    assert_not_contains "a current launcher: no warning" "$out" "is older than this script"
}
test_wrapper_form_needs_a_wrapper_and_a_token() {
    setup_bin; sudo_stub; wrap_stub
    with_form '{"wrapper": [], "token": "TOKEN"}'
    out="$(run_start --no-inhibit 2>&1)"; rc=$?
    assert_eq "empty wrapper: exit 2" "$rc" "2"
    assert_contains "empty wrapper: says why" "$out" 'server_password: the wrapper form needs a non-empty "wrapper" and a "token"'
    with_form '{"wrapper": ["wrap"]}'
    out="$(run_start --no-inhibit 2>&1)"; rc=$?
    assert_eq "no token: exit 2" "$rc" "2"
    assert_contains "no token: says why" "$out" 'needs a non-empty "wrapper" and a "token"'
    assert_eq "nothing run" "$(calls)" ""
}
test_wrapper_that_cannot_run_is_reported() {
    setup_bin; sudo_stub
    with_form '{"wrapper": ["no-such-wrapper"], "token": "TOKEN"}'
    out="$(run_start --no-inhibit 2>&1)"; rc=$?
    assert_eq "exit 2" "$rc" "2"
    assert_contains "says why" "$out" "server_password: could not run the wrapper (no-such-wrapper)"
    assert_eq "launcher not run" "$(calls)" ""
    assert_eq "no pid file" "$(no_pid_file)" "no"
}
test_wrapper_form_keeps_the_original_arguments() {
    setup_bin; sudo_stub; gnome_stub; wrap_stub
    with_form '{"wrapper": ["wrap"], "token": "TOKEN"}'
    run_start --no-inhibit >/dev/null 2>&1
    assert_contains "--no-inhibit passed on" "$(calls)" "argv=bash $START --password-arg TOKEN --no-inhibit"
    assert_not_contains "and honoured" "$(calls)" "gnome-session-inhibit"
}
test_password_arg_only_for_the_wrapper_form() {
    setup_bin; sudo_stub; export SS_PW="$PW"; with_form '{"env": "SS_PW"}'
    out="$(run_start --password-arg x 2>&1)"; rc=$?
    assert_eq "exit 2" "$rc" "2"
    assert_contains "says why" "$out" "--password-arg is internal"
    assert_eq "launcher not run" "$(calls)" ""
}
test_refuses_when_the_server_already_answers() {
    setup_bin; sudo_stub; gnome_stub
    start_api   # answers 401 to a request without credentials
    out="$(run_start 2>&1)"; rc=$?
    assert_eq "exit 1" "$rc" "1"
    assert_contains "says so" "$out" "already running"
    assert_eq "nothing started" "$(calls)" ""
    assert_eq "no pid file" "$(no_pid_file)" "no"
}
test_only_systemd_inhibit() {
    setup_bin; sudo_stub; systemd_stub; export SS_PW="$PW"; with_form '{"env": "SS_PW"}'
    run_start >/dev/null 2>&1
    assert_contains "systemd-inhibit wraps the launcher" "$(calls)" \
        "pw=match argv=--what=sleep --who=chargehand --why=OpenCode server running sudo -n -u agentx /opt/ch/launcher"
    assert_contains "launcher got the value" "$(calls)" "pw=match argv=-n -u agentx /opt/ch/launcher"
    assert_eq "pid file names systemd-inhibit" "$(head -1 "$HARNESS_STATE_DIR/server.pid")" "$(pid_of systemd-inhibit)"
}
test_no_inhibitor_warns_and_runs_the_launcher() {
    setup_bin; sudo_stub; export SS_PW="$PW"; with_form '{"env": "SS_PW"}'
    out="$(run_start 2>&1)"; rc=$?
    assert_eq "exit 0" "$rc" "0"
    assert_contains "warns" "$out" "neither gnome-session-inhibit nor systemd-inhibit"
    assert_contains "launcher got the value" "$(calls)" "pw=match argv=-n -u agentx /opt/ch/launcher"
    assert_eq "pid file names sudo itself" "$(head -1 "$HARNESS_STATE_DIR/server.pid")" "$(pid_of sudo)"
}
test_no_inhibit_flag() {
    setup_bin; sudo_stub; gnome_stub; systemd_stub; export SS_PW="$PW"; with_form '{"env": "SS_PW"}'
    out="$(run_start --no-inhibit 2>&1)"
    assert_not_contains "no inhibitor" "$(calls)" "inhibit"
    assert_not_contains "no warning either" "$out" "neither"
    assert_contains "launcher got the value" "$(calls)" "pw=match argv=-n -u agentx /opt/ch/launcher"
}
test_defaults_and_bad_arguments() {
    setup_bin; sudo_stub; export SS_PW="$PW"
    write_config '{"server_url": "http://127.0.0.1:1", "server_password": {"env": "SS_PW"}}'
    run_start --no-inhibit >/dev/null 2>&1
    assert_contains "default agent user and launcher" "$(calls)" "argv=-n -u opencode /usr/local/bin/chargehand-sandbox"
    out="$(run_start --bogus 2>&1)"; assert_eq "unknown argument: exit 2" "$?" "2"
    assert_contains "usage" "$out" "Usage: start-server.sh [--no-inhibit]"
}
run_tests
