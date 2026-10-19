. "$(dirname "$0")/lib.sh"
. "$HARNESS_ROOT/scripts/lib/harness.sh"
. "$HARNESS_ROOT/scripts/lib/api.sh"

with_form() { write_config "{\"server_url\": \"$API_URL\", \"server_password\": $1}"; }

test_env_form() {
    start_api; fixture GET /api/session '{"data": [{"id": "s1"}]}'
    assert_eq "body returned" "$(oc_api GET '/api/session?limit=1000' | jq -r '.data[0].id')" "s1"
}
test_file_form_and_permissions() {
    start_api; fixture GET /api/agent '{"data": []}'
    printf 'test-password\n' > "$HOME/pw"; chmod 600 "$HOME/pw"
    with_form '{"file": "~/pw"}'
    assert_eq "0600 file works" "$(oc_api GET /api/agent)" '{"data": []}'
    chmod 644 "$HOME/pw"
    out="$( (oc_api GET /api/agent) 2>&1 )"; assert_eq "0644 refused" "$?" "2"
    assert_contains "says why" "$out" "must be mode 600"
}
test_command_form() {
    start_api; fixture GET /api/agent '{"data": []}'
    with_form '{"command": ["printf", "test-password"]}'
    assert_eq "command output is the password" "$(oc_api GET /api/agent)" '{"data": []}'
}
test_wrapper_form() {
    start_api; fixture GET /api/agent '{"data": []}'
    # A stand-in for a token-substituting tool: replaces TOKEN in its arguments with the password.
    cat > "$HOME/subst" <<'SH'
#!/usr/bin/env bash
args=(); for a in "$@"; do args+=("${a//TOKEN/test-password}"); done; exec "${args[@]}"
SH
    chmod +x "$HOME/subst"
    with_form "{\"wrapper\": [\"$HOME/subst\"], \"token\": \"TOKEN\"}"
    assert_eq "wrapper substitutes the token" "$(oc_api GET /api/agent)" '{"data": []}'
}
test_password_with_quote_and_backslash() {
    start_api 'p"w\x'; fixture GET /api/agent '{"data": []}'
    assert_eq "escaped for curl config" "$(oc_api GET /api/agent)" '{"data": []}'
}
test_wrong_password_and_404_fail() {
    start_api; export TEST_SERVER_PASSWORD=wrong
    (oc_api GET /api/agent >/dev/null 2>&1); assert_eq "401 fails" "$?" "22"
    export TEST_SERVER_PASSWORD=test-password
    (oc_api GET /api/nothing >/dev/null 2>&1); assert_eq "404 fails" "$?" "22"
}
test_password_never_in_output_or_argv() {
    start_api; fixture GET /api/agent '{"data": []}'
    out="$(oc_api GET /api/agent 2>&1)"
    assert_not_contains "not in output" "$out" "test-password"
    # The server answers after a second, so curl is still running when the process list is read.
    echo 1.5 > "$API_DIR/delay"
    ( oc_api GET /api/agent >/dev/null & p=$!; sleep 0.5; ps -eo args > "$TEST_TMP/ps.txt"; wait $p )
    assert_contains "curl was running when sampled (the check is not vacuous)" "$(cat "$TEST_TMP/ps.txt")" "curl"
    assert_contains "and its argv held the url" "$(grep curl "$TEST_TMP/ps.txt")" "$API_URL/api/agent"
    # Only this test's curl (other processes on the machine may mention the word for their own reasons).
    assert_not_contains "not in curl's argv" "$(grep "^curl .*$API_URL" "$TEST_TMP/ps.txt")" "test-password"
    rm -f "$API_DIR/delay"
    assert_eq "only the wrapper line passes -u" "$(grep -c -- '-u "' "$HARNESS_ROOT/scripts/lib/api.sh")" "1"
}
test_post_sends_body() {
    start_api; fixture POST /api/session '{"data": {"id": "ses_1"}}'
    echo '{"title": "t"}' > "$TEST_TMP/body.json"
    assert_eq "post" "$(oc_api POST /api/session "$TEST_TMP/body.json" | jq -r .data.id)" "ses_1"
    assert_contains "body recorded" "$(requests)" '\"title\": \"t\"'
}
test_wrapper_calls_never_overlap() {
    start_api; fixture GET /api/agent '{"data": []}'
    # A stand-in for a hardware-backed secret tool that fails when two copies use the device at
    # once (a YubiKey-backed vault reports "No YubiKey detected" to the loser).
    cat > "$HOME/subst" <<SH
#!/usr/bin/env bash
mkdir "$TEST_TMP/device" 2>/dev/null || { echo "device busy" >&2; exit 1; }
sleep 0.3
args=(); for a in "\$@"; do args+=("\${a//TOKEN/test-password}"); done
"\${args[@]}"; rc=\$?; rmdir "$TEST_TMP/device"; exit \$rc
SH
    chmod +x "$HOME/subst"
    with_form "{\"wrapper\": [\"$HOME/subst\"], \"token\": \"TOKEN\"}"
    local pids=() i
    for i in 1 2 3 4; do (oc_api GET /api/agent > "$TEST_TMP/out$i" 2>&1; echo $? > "$TEST_TMP/rc$i") & pids+=($!); done
    wait "${pids[@]}"
    assert_eq "all four succeed" "$(cat "$TEST_TMP"/rc1 "$TEST_TMP"/rc2 "$TEST_TMP"/rc3 "$TEST_TMP"/rc4 | tr -d '\n')" "0000"
}
# Finding 11: the lock wait is configurable, and a timeout is its own status (75).
test_wrapper_lock_wait_is_configurable_and_times_out_with_75() {
    start_api; fixture GET /api/agent '{"data": []}'
    with_form '{"wrapper": ["env"], "token": "test-password"}'
    mkdir -p "$HARNESS_STATE_DIR"
    ( flock 9; sleep 4 ) 9>"$HARNESS_STATE_DIR/api.lock" & holder=$!
    sleep 0.3
    start=$SECONDS; out="$( (HARNESS_API_LOCK_WAIT=1 oc_api GET /api/agent) 2>&1 )"; rc=$?
    assert_eq "75 when the lock stays taken" "$rc" "75"
    assert_contains "says why" "$out" "timed out waiting for the API lock"
    assert_eq "waited about the configured second, not 120" "$(( SECONDS - start < 4 ))" "1"
    wait "$holder"
    assert_eq "works when free" "$(HARNESS_API_LOCK_WAIT=1 oc_api GET /api/agent)" '{"data": []}'
}
run_tests
