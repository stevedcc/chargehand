. "$(dirname "$0")/lib.sh"
SCRIPT="$HARNESS_ROOT/skills/configuring-chargehand/scripts/check-config.sh"
ROLES='"roles": {"implementer": ["go/a-1"], "task_review": ["go/b-1"], "final_review": ["go/c-1"], "low_level": ["go/a-2"]}'

test_nothing_configured() {
    out="$(bash "$SCRIPT")"; assert_eq "exit 3" "$?" "3"
    assert_contains "config.json" "$out" "config.json: missing"
    assert_contains "models.json" "$out" "models.json: missing"
}
test_project_problems_listed() {
    start_api; write_models "{\"subscriptions\": {\"go\": {}}, $ROLES}"
    write_project demo '{"agent_clone": "/x"}'
    out="$(bash "$SCRIPT" --project demo)"; assert_eq "exit 3" "$?" "3"
    for k in owner_worktree target_branch mirror; do assert_contains "$k" "$out" "demo.json: missing key \"$k\""; done
}
test_complete_config_passes() {
    start_api; write_models "{\"subscriptions\": {\"go\": {}}, $ROLES}"
    write_project demo "{\"owner_worktree\": \"$HOME\", \"target_branch\": \"main\", \"agent_clone\": \"/x\", \"mirror\": \"/y\"}"
    fixture GET /api/model '{"data": []}'
    out="$(HARNESS_TODAY=2026-10-10 bash "$SCRIPT" --project demo)"; assert_eq "exit 0" "$?" "0"
    assert_contains "says so" "$out" "config complete"
}
test_model_problems_use_server_families() {
    start_api; write_models "{\"subscriptions\": {\"go\": {}}, $ROLES}"
    write_project demo "{\"owner_worktree\": \"$HOME\", \"target_branch\": \"main\", \"agent_clone\": \"/x\", \"mirror\": \"/y\"}"
    fixture GET /api/model '{"data": [{"providerID": "go", "modelID": "a-1", "family": "same"}, {"providerID": "go", "modelID": "b-1", "family": "same"}]}'
    out="$(HARNESS_TODAY=2026-10-10 bash "$SCRIPT" --project demo)"; assert_eq "exit 3" "$?" "3"
    assert_contains "family clash" "$out" "go/b-1 is the same model family"
}
test_available_models() {
    start_api
    fixture GET /api/model '{"data": [{"providerID": "go", "modelID": "mimo-v2.6-pro", "family": "mimo", "enabled": true},
                                      {"providerID": "go", "modelID": "old-1", "family": "old", "enabled": false}]}'
    out="$(bash "$SCRIPT" --available-models)"
    assert_eq "enabled only" "$out" $'go/mimo-v2.6-pro\tmimo'
}
test_families_when_server_down() {
    write_config '{"server_url": "http://127.0.0.1:9", "server_password": {"env": "NOPE"}}'
    export NOPE=x
    assert_eq "empty map" "$(bash "$SCRIPT" --families)" "{}"
}
test_wrong_server_password_is_a_problem() {
    start_api; export TEST_SERVER_PASSWORD=wrong; write_models "{\"subscriptions\": {\"go\": {}}, $ROLES}"
    fixture GET /api/model '{"data": []}'
    out="$(HARNESS_TODAY=2026-10-10 bash "$SCRIPT")"; assert_eq "exit 3" "$?" "3"
    assert_contains "says what" "$out" "server refused the request"
}
test_unreachable_server_is_a_note_not_a_problem() {
    write_models "{\"subscriptions\": {\"go\": {}}, $ROLES}"
    write_config '{"server_url": "http://127.0.0.1:9", "server_password": {"env": "NOPE"}}'; export NOPE=x
    out="$(HARNESS_TODAY=2026-10-10 bash "$SCRIPT")"; assert_eq "exit 0" "$?" "0"
    assert_contains "complete" "$out" "config complete"; assert_contains "note" "$out" "note: the server did not answer"
}
run_tests
