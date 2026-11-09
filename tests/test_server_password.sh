. "$(dirname "$0")/lib.sh"
. "$HARNESS_ROOT/scripts/lib/harness.sh"
. "$HARNESS_ROOT/scripts/lib/api.sh"
# server_password_form / server_password_value: the lookup oc_api, start-server.sh and
# update-opencode.sh share.

with_form() { write_config "{\"server_url\": \"http://127.0.0.1:1\", \"server_password\": $1}"; }

test_form_kinds() {
    with_form '{"env": "X"}';                  assert_eq "env" "$(server_password_form)" "env"
    with_form '{"file": "~/pw"}';              assert_eq "file" "$(server_password_form)" "file"
    with_form '{"command": ["true"]}';         assert_eq "command" "$(server_password_form)" "command"
    with_form '{"wrapper": ["w"], "token": "T", "env": "X"}'
    assert_eq "wrapper wins over the others, as in oc_api" "$(server_password_form)" "wrapper"
}
test_form_missing_or_unknown_dies() {
    write_config '{"server_url": "http://127.0.0.1:1"}'
    out="$( (server_password_form) 2>&1)"; assert_eq "missing: exit 2" "$?" "2"
    assert_contains "missing: says so" "$out" 'config.json: missing key "server_password"'
    with_form '{"vault": "x"}'
    out="$( (server_password_form) 2>&1)"; assert_eq "unknown: exit 2" "$?" "2"
    assert_contains "unknown: says the forms" "$out" "server_password: use one of env, file, command, wrapper"
}
test_value_env() {
    with_form '{"env": "SP_TEST_PW"}'
    assert_eq "env value" "$(SP_TEST_PW='a b"c' server_password_value)" 'a b"c'
    out="$( (SP_TEST_PW= server_password_value) 2>&1)"; assert_eq "empty: exit 2" "$?" "2"
    assert_contains "empty: says which" "$out" 'server_password: $SP_TEST_PW is empty'
}
test_value_with_a_line_break_is_refused() {
    with_form '{"env": "SP_TEST_PW"}'
    for v in $'a\nb' $'a\rb' $'trailing\n'; do
        out="$( (SP_TEST_PW="$v" server_password_value) 2>&1)"; assert_eq "exit 2 for ${v@Q}" "$?" "2"
        assert_contains "says why for ${v@Q}" "$out" "server_password: the value contains a line break"
    done
    printf 'one\ntwo\n' > "$HOME/pw"; chmod 600 "$HOME/pw"; with_form '{"file": "~/pw"}'
    out="$( (server_password_value) 2>&1)"; assert_eq "two-line file: exit 2" "$?" "2"
}
test_value_file() {
    printf 'from-file\n' > "$HOME/pw"; chmod 600 "$HOME/pw"
    with_form '{"file": "~/pw"}'
    assert_eq "file value, newline dropped" "$(server_password_value)" "from-file"
    chmod 640 "$HOME/pw"
    out="$( (server_password_value) 2>&1)"; assert_eq "0640: exit 2" "$?" "2"
    assert_contains "0640: says why" "$out" "must be mode 600 and yours"
    rm "$HOME/pw"
    out="$( (server_password_value) 2>&1)"; assert_contains "no file" "$out" "server_password: no file $HOME/pw"
}
test_value_command() {
    with_form '{"command": ["printf", "from-command"]}'
    assert_eq "command value" "$(server_password_value)" "from-command"
    with_form '{"command": ["false"]}'
    out="$( (server_password_value) 2>&1)"; assert_eq "failed: exit 2" "$?" "2"
    assert_contains "failed: says so" "$out" "server_password: the command failed"
}
test_value_refuses_the_wrapper_form() {
    with_form '{"wrapper": ["w"], "token": "T"}'
    out="$( (server_password_value) 2>&1)"; assert_eq "exit 2" "$?" "2"
    assert_contains "says why" "$out" "the wrapper form has no value to read"
}
test_server_answers() {
    with_form '{"env": "X"}'
    oc_answers; assert_eq "nothing listening: no" "$?" "1"
    start_api
    oc_answers; assert_eq "a 401 is an answer" "$?" "0"
    assert_eq "and it sent no credentials" "$(requests | jq -r .auth)" ""
}
run_tests
