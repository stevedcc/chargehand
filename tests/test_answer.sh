. "$(dirname "$0")/lib.sh"
SCRIPT="$HARNESS_ROOT/skills/running-briefs/scripts/answer.sh"
last_body() { requests | jq -rs --arg p "$1" '[.[] | select(.path == $p)] | last | .body'; }

test_permission_reply() {
    start_api; fixture POST /api/session/s2/permission/per_1/reply '{"data": true}'
    bash "$SCRIPT" permission s2 per_1 reject "Not outside your clone; see the rules." >/dev/null
    assert_eq "body" "$(last_body /api/session/s2/permission/per_1/reply | jq -c .)" \
        '{"decision":"reject","message":"Not outside your clone; see the rules."}'
}
test_permission_bad_decision() {
    start_api; out="$(bash "$SCRIPT" permission s2 per_1 maybe 2>&1)"
    assert_eq "exit 2" "$?" "2"; assert_contains "lists choices" "$out" "once, always or reject"
}
test_form_reply() {
    start_api; fixture POST /api/session/s3/form/frm_1/reply '{"data": true}'
    bash "$SCRIPT" form s3 frm_1 '{"q0": "Use option B"}' >/dev/null
    assert_eq "body" "$(last_body /api/session/s3/form/frm_1/reply | jq -c .)" '{"answer":{"q0":"Use option B"}}'
}
test_form_answer_must_be_object() {
    start_api; out="$(bash "$SCRIPT" form s3 frm_1 'B' 2>&1)"; assert_eq "exit 2" "$?" "2"
}
test_list() {
    start_api; fixture GET /api/permission/request '{"data": [{"id": "per_1", "sessionID": "s2", "action": "shell", "resources": ["git push"]}]}'
    assert_contains "shows pending" "$(bash "$SCRIPT" list)" "per_1"
}
run_tests
