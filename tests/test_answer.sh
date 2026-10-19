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
    assert_eq "exit 2" "$?" "2"; assert_contains "lists choices" "$out" "decision must be once or reject"
}
test_always_is_not_a_decision() {
    start_api; out="$(bash "$SCRIPT" permission s2 per_1 always 2>&1)"
    assert_eq "exit 2" "$?" "2"; assert_contains "refused" "$out" "decision must be once or reject"
    assert_eq "nothing sent" "$(requests | wc -l)" "0"
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
test_pending_lists_permissions_and_forms_of_the_session_tree_only() {
    start_api
    fixture GET /api/session '{"data": [{"id": "s1"}, {"id": "c1", "parentID": "s1"}, {"id": "g1", "parentID": "c1"}, {"id": "other"}]}'
    fixture GET /api/permission/request '{"data": [
      {"id": "per_1", "sessionID": "g1", "action": "shell", "resources": ["git push"]},
      {"id": "per_2", "sessionID": "other", "action": "shell", "resources": ["rm -rf /"]}]}'
    fixture GET /api/session/s1/form '{"data": []}'
    fixture GET /api/session/c1/form '{"data": [{"id": "frm_1", "sessionID": "c1", "title": "Which branch?\u001b[2J", "fields": [{"title": "Name"}]}]}'
    fixture GET /api/session/g1/form '{"data": []}'
    out="$(bash "$SCRIPT" pending s1)"
    assert_contains "permission of a grandchild" "$out" "permission g1 per_1 shell git push"
    assert_contains "form of a child" "$out" "form c1 frm_1 Which branch?: Name"
    assert_not_contains "other tree left out" "$out" "per_2"
    assert_not_contains "no escape bytes" "$out" $'\e'
}
test_pending_with_nothing_pending_says_so() {
    start_api; fixture GET /api/session '{"data": [{"id": "s1"}]}'; fixture GET /api/permission/request '{"data": []}'
    fixture GET /api/session/s1/form '{"data": []}'
    assert_contains "says so" "$(bash "$SCRIPT" pending s1)" "nothing pending"
}
test_interrupt_posts_to_the_session() {
    start_api; fixture POST /api/session/c1/interrupt '{"data": true}'
    out="$(bash "$SCRIPT" interrupt c1)"
    assert_eq "one POST with resume=false" "$(requests | jq -r 'select(.path == "/api/session/c1/interrupt") | "\(.method) \(.query)"')" "POST resume=false"
    assert_contains "says so" "$out" "interrupted c1"
}
test_interrupt_needs_a_session() {
    start_api; out="$(bash "$SCRIPT" interrupt 2>&1)"; assert_eq "exit 2" "$?" "2"
}
run_tests
