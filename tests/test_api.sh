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
    ( oc_api GET /api/agent >/dev/null & p=$!; sleep 0.05; ps -eo args > "$TEST_TMP/ps.txt"; wait $p )
    assert_not_contains "not in any process's argv" "$(cat "$TEST_TMP/ps.txt")" "test-password"
    assert_eq "only the wrapper line passes -u" "$(grep -c -- '-u "' "$HARNESS_ROOT/scripts/lib/api.sh")" "1"
}
test_post_sends_body() {
    start_api; fixture POST /api/session '{"data": {"id": "ses_1"}}'
    echo '{"title": "t"}' > "$TEST_TMP/body.json"
    assert_eq "post" "$(oc_api POST /api/session "$TEST_TMP/body.json" | jq -r .data.id)" "ses_1"
    assert_contains "body recorded" "$(requests)" '\"title\": \"t\"'
}
run_tests
