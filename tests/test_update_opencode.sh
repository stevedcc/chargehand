. "$(dirname "$0")/lib.sh"
. "$HARNESS_ROOT/scripts/lib/harness.sh"
. "$HARNESS_ROOT/scripts/lib/api.sh"
UPDATE="$HARNESS_ROOT/skills/setting-up-agent-sandbox/scripts/update-opencode.sh"
START="$HARNESS_ROOT/skills/setting-up-agent-sandbox/scripts/start-server.sh"

session() { echo "{\"id\": \"$1\", \"title\": \"$4\", \"model\": {\"providerID\": \"$2\", \"id\": \"m\"}, \"time\": {\"created\": $3, \"updated\": $3}}"; }
busy_msgs='{"data": [{"type": "assistant"}, {"type": "user"}]}'
idle_msgs='{"data": [{"type": "idle", "outcome": "succeeded"}, {"type": "assistant"}, {"type": "user"}]}'

# oc_busy_session_ids [PROVIDER]: models_busy's rules, as ids; no provider means every session.
test_busy_session_ids() {
    start_api
    old=$(( $(now_ms) - 30 * 60000 ))
    fixture GET /api/session "{\"data\": [$(session s1 z "$(now_ms)" a), $(session s2 go "$(now_ms)" b),
        $(session s3 z "$(now_ms)" c), $(session s4 go "$old" d)]}"
    fixture GET /api/session/s1/message "$busy_msgs"
    fixture GET /api/session/s2/message "$busy_msgs"
    fixture GET /api/session/s3/message "$idle_msgs"
    fixture GET /api/session/s4/message "$busy_msgs"
    assert_eq "one provider" "$(oc_busy_session_ids z | tr '\n' ' ')" "s1 "
    assert_eq "every provider" "$(oc_busy_session_ids | tr '\n' ' ')" "s1 s2 "
}

# The update runs against the fake API with a stub sudo on PATH that answers each fixed form:
# opencode --version and upgrade (as the agent user), the launcher's self-test, and the launcher
# itself (the server: it runs until SIGTERM, then takes the fake API down, as the real server
# going away would). Every call is appended to $TEST_TMP/calls.
setup_update() {
    start_api
    jq '. + {"agent_user": "agentx", "launcher": "/opt/ch/launcher"}' "$HARNESS_CONFIG_DIR/config.json" > "$TEST_TMP/c.json"
    mv "$TEST_TMP/c.json" "$HARNESS_CONFIG_DIR/config.json"
    write_models '{"subscriptions": {"go": {}, "z": {}}, "roles": {"implementer": ["go/mimo-v2.6-pro"],
        "task_review": ["z/glm-5.3"], "final_review": ["z/glm-5.3"], "low_level": ["go/mimo-v2.6-flash"]}}'
    write_project p '{}'
    fixture GET /api/session '{"data": []}'
    mkdir -p "$TEST_TMP/bin"
    # #!/bin/bash, not env: the process is then named "sudo", as the real one is.
    cat > "$TEST_TMP/bin/sudo" <<'SH'
#!/bin/bash
echo "sudo $*" >> "$TEST_TMP/calls"
case "$*" in
    "-iu agentx opencode --version") cat "$TEST_TMP/version" ;;
    "-iu agentx opencode upgrade") [ -f "$TEST_TMP/version.new" ] && cp "$TEST_TMP/version.new" "$TEST_TMP/version"; echo "upgrading" ;;
    "-n -u agentx /opt/ch/launcher --selftest --project p") cat "$TEST_TMP/selftest"; exit "$(cat "$TEST_TMP/selftest.rc" 2>/dev/null || echo 0)" ;;
    "-n -u agentx /opt/ch/launcher")
        trap 'echo "sudo got SIGTERM" >> "$TEST_TMP/calls"; kill "$API_PID"; exit 143' TERM
        while :; do sleep 0.05; done ;;
    *) echo "unexpected sudo $*" >&2; exit 99 ;;
esac
SH
    cat > "$TEST_TMP/bin/gnome-session-inhibit" <<'SH'
#!/bin/bash
while [[ "$1" == --* ]]; do [ "$1" = --reason ] && shift; shift; done; "$@"
SH
    chmod +x "$TEST_TMP/bin/sudo" "$TEST_TMP/bin/gnome-session-inhibit"
    export PATH="$TEST_TMP/bin:$PATH" TEST_TMP API_PID
    echo "1.0.0" > "$TEST_TMP/version"
    printf 'ok   boundary one\nok   boundary two\n' > "$TEST_TMP/selftest"
}
calls() { cat "$TEST_TMP/calls" 2>/dev/null; }
# After each test (run_tests calls it): a failed test must not leave a stub server or an update
# polling behind.
after_each() {
    local p
    if [ -n "${UPDATE_PID:-}" ]; then pkill -P "$UPDATE_PID" 2>/dev/null; wait "$UPDATE_PID" 2>/dev/null; UPDATE_PID=; fi
    if [ -f "$HARNESS_STATE_DIR/server.pid" ]; then
        p="$(head -1 "$HARNESS_STATE_DIR/server.pid")"; pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null
    fi
    if [ -n "${OTHER_PID:-}" ]; then kill "$OTHER_PID" 2>/dev/null; wait "$OTHER_PID" 2>/dev/null; OTHER_PID=; fi
}
failing_selftest() { printf 'ok   one\nFAIL /home/other is visible\n' > "$TEST_TMP/selftest"; }
# run_update SCALE ARGS...: in the background; output in $TEST_TMP/out, status in $TEST_TMP/rc.
run_update() {
    local scale="$1"; shift
    ( CHARGEHAND_POLL_SCALE="$scale" bash "$UPDATE" --project p "$@" > "$TEST_TMP/out" 2>&1; echo $? > "$TEST_TMP/rc" ) &
    UPDATE_PID=$!
}
finish() { wait "$UPDATE_PID"; RC="$(cat "$TEST_TMP/rc")"; }
out() { cat "$TEST_TMP/out" 2>/dev/null; }
# wait_out TEXT: until the update has printed TEXT (10 s at most).
wait_out() { local _; for _ in $(seq 200); do grep -qF -- "$1" "$TEST_TMP/out" 2>/dev/null && return 0; sleep 0.05; done; return 1; }
# The server coming back: the fake API again, on the same port, with the same fixtures.
restart_api() {
    FAKE_API_PORT="${API_URL##*:}" FAKE_API_PASSWORD=test-password python3 "$HARNESS_ROOT/tests/fake_api.py" "$API_DIR" &
    API_PID=$!
}
# start_stub_server: start-server.sh itself (its own config: a port nothing answers on), so the pid
# file and the inhibitor -> sudo process tree are the real ones.
start_stub_server() {
    local conf="$TEST_TMP/server-conf"; mkdir -p "$conf"
    printf '{"server_url": "http://127.0.0.1:1", "agent_user": "agentx", "launcher": "/opt/ch/launcher", "server_password": {"env": "SRV_PW"}}\n' > "$conf/config.json"
    SRV_PW=x HARNESS_CONFIG_DIR="$conf" bash "$START" >/dev/null 2>&1 &
    local _; for _ in $(seq 100); do grep -q '^sudo -n -u agentx /opt/ch/launcher$' "$TEST_TMP/calls" 2>/dev/null && return 0; sleep 0.05; done
    return 1
}

test_busy_sessions_refuse_without_force() {
    setup_update
    fixture GET /api/session "{\"data\": [$(session ses_busy go "$(now_ms)" "Brief 19a")]}"
    fixture GET /api/session/ses_busy/message "$busy_msgs"
    run_update 0.01; finish; rc="$RC"
    assert_eq "exit 1" "$rc" "1"
    assert_contains "lists the busy session" "$(out)" "ses_busy  Brief 19a"
    assert_contains "says how to go on" "$(out)" "--force"
    assert_eq "nothing run as the agent user" "$(calls)" ""
}
test_force_goes_on_past_busy_sessions() {
    setup_update; failing_selftest
    fixture GET /api/session "{\"data\": [$(session ses_busy go "$(now_ms)" "Brief 19a")]}"
    fixture GET /api/session/ses_busy/message "$busy_msgs"
    run_update 0.01 --force; finish
    assert_contains "still lists it" "$(out)" "ses_busy  Brief 19a"
    assert_contains "and upgrades" "$(calls)" "sudo -iu agentx opencode upgrade"
}
test_server_down_skips_the_busy_check() {
    setup_update; failing_selftest; stop_api
    run_update 0.01; finish
    assert_contains "says so" "$(out)" "not answering; skipping the busy check"
    assert_contains "and goes on" "$(calls)" "sudo -iu agentx opencode --version"
}
test_failing_selftest_stops_before_the_server_is_touched() {
    setup_update; failing_selftest; start_stub_server
    run_update 0.01; finish; rc="$RC"
    assert_eq "exit 1" "$rc" "1"
    assert_contains "prints the failing line" "$(out)" "FAIL /home/other is visible"
    assert_not_contains "not the passing ones" "$(out)" "ok   one"
    assert_not_contains "server not signalled" "$(calls)" "SIGTERM"
    assert_not_contains "not asked to stop" "$(out)" "Stop the server"
    oc_answers; assert_eq "server still answers" "$?" "0"
}
test_selftest_nonzero_exit_stops_too() {
    setup_update; echo 4 > "$TEST_TMP/selftest.rc"; printf 'ok   all lines fine\n' > "$TEST_TMP/selftest"
    run_update 0.01; finish; rc="$RC"
    assert_eq "exit 1" "$rc" "1"
    assert_contains "says the status" "$(out)" "self-test failed (exit 4)"
    assert_not_contains "not asked to stop" "$(out)" "Stop the server"
}
test_versions_and_already_current() {
    setup_update; failing_selftest
    run_update 0.01; finish
    assert_contains "version before" "$(out)" "OpenCode before the upgrade: 1.0.0"
    assert_contains "already current" "$(out)" "already current (1.0.0)"
    assert_contains "the self-test still ran" "$(calls)" "--selftest --project p"
    : > "$TEST_TMP/calls"; echo "1.1.0" > "$TEST_TMP/version.new"
    run_update 0.01; finish
    assert_contains "upgraded" "$(out)" "OpenCode upgraded: 1.0.0 -> 1.1.0"
    assert_eq "order: version, upgrade, version, self-test" "$(calls | cut -d' ' -f2-5 | tr '\n' '|')" \
        "-iu agentx opencode --version|-iu agentx opencode upgrade|-iu agentx opencode --version|-n -u agentx /opt/ch/launcher|"
}
test_stop_through_the_pid_file_then_wait_for_the_restart() {
    setup_update; start_stub_server
    run_update 0.01
    wait_out "Start it again"
    assert_contains "sudo got SIGTERM" "$(calls)" "sudo got SIGTERM"
    assert_contains "says it stopped it" "$(out)" "The server has stopped."
    assert_not_contains "did not ask the user" "$(out)" "Stop the server now"
    assert_contains "start hint has the full path" "$(out)" "Start it again: run $START in the server's terminal"
    restart_api
    finish; rc="$RC"
    assert_eq "exit 0" "$rc" "0"
    assert_contains "server back" "$(out)" "The server is answering again."
    assert_contains "models.sh output passed through" "$(out)" "Models for this brief."
}
test_stop_without_a_pid_file_asks_the_user() {
    setup_update
    run_update 0.01
    wait_out "Stop the server now (Ctrl-C in its terminal)"
    assert_eq "still running meanwhile" "$(kill -0 "$UPDATE_PID" 2>/dev/null && echo yes)" "yes"
    stop_api
    wait_out "Start it again"
    restart_api
    finish; assert_eq "exit 0" "$RC" "0"
}
test_a_stale_pid_file_is_not_trusted() {
    setup_update
    # A live sudo running the launcher that start-server.sh did not start (the PID was reused):
    # the right name, the wrong start time. Signalling it would be wrong.
    "$TEST_TMP/bin/sudo" -n -u agentx /opt/ch/launcher >/dev/null 2>&1 & OTHER_PID=$!
    mkdir -p "$HARNESS_STATE_DIR"; printf '%s\n1\n' "$OTHER_PID" > "$HARNESS_STATE_DIR/server.pid"
    run_update 0.01
    wait_out "Stop the server now"
    assert_not_contains "the other process was not signalled" "$(calls)" "SIGTERM"
    assert_eq "and is still running" "$(kill -0 "$OTHER_PID" 2>/dev/null && echo alive)" "alive"
    stop_api; wait_out "Start it again"; restart_api; finish
}
test_server_that_never_stops_gives_up() {
    setup_update
    run_update 0.01; finish; rc="$RC"
    assert_eq "exit 1" "$rc" "1"
    assert_contains "says so" "$(out)" "still answering after"
    assert_not_contains "no start hint" "$(out)" "Start it again"
}
test_start_wait_times_out() {
    setup_update; stop_api   # down from the start: nothing to stop, and it never comes back
    run_update 0.001; finish; rc="$RC"
    assert_eq "exit 1" "$rc" "1"
    assert_contains "nothing to stop" "$(out)" "The server is not running; nothing to stop."
    assert_contains "says so" "$(out)" "did not answer within"
    assert_not_contains "no models run" "$(out)" "Models for this brief."
}
test_usage() {
    out="$(bash "$UPDATE" 2>&1)"; assert_eq "no project: exit 2" "$?" "2"
    assert_contains "usage" "$out" "Usage: update-opencode.sh --project <name> [--force]"
}
run_tests
