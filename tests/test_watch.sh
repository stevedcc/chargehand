. "$(dirname "$0")/lib.sh"
SCRIPT="$HARNESS_ROOT/skills/running-briefs/scripts/watch.sh"
export WATCH_POLL_SECONDS=0 WATCH_MAX_SECONDS=0

brief() { mkdir -p "$HARNESS_STATE_DIR/demo/briefs/$1"; echo "$2" > "$HARNESS_STATE_DIR/demo/briefs/$1/sid"; }
# A healthy tree: s1 (brief) -> s2 (subagent) -> s3 (its subagent); messages a minute old.
healthy() {
    start_api; brief 07a s1
    fixture GET /api/session '{"data": [{"id": "s1"}, {"id": "s2", "parentID": "s1"}, {"id": "s3", "parentID": "s2"}, {"id": "x9"}]}'
    fixture GET /api/permission/request '{"location": {}, "data": []}'
    local t=$(( $(now_ms) - 60000 ))
    for s in s1 s2 s3; do
        fixture GET /api/session/$s/message "{\"data\": [{\"type\": \"assistant\", \"id\": \"m_$s\", \"time\": {\"created\": $t}}, {\"type\": \"user\", \"time\": {\"created\": $t}}]}"
        fixture GET /api/session/$s/form '{"data": []}'
    done
}
watch() { bash "$SCRIPT" --project demo "$@"; }

test_timeout_when_healthy() {
    healthy; out="$(watch 07a)"; assert_eq "exit 1" "$?" "1"; assert_contains "says so" "$out" "TIMEOUT"
}
test_idle() {
    healthy
    fixture GET /api/session/s1/message "{\"data\": [{\"type\": \"idle\", \"outcome\": \"succeeded\", \"time\": {\"created\": $(now_ms)}}, {\"type\": \"user\", \"time\": {\"created\": 1}}]}"
    out="$(watch 07a)"; assert_eq "exit 0" "$?" "0"; assert_contains "outcome" "$out" "07a IDLE: outcome=succeeded"
}
test_old_idle_before_a_newer_prompt_is_not_idle() {
    healthy
    fixture GET /api/session/s1/message "{\"data\": [{\"type\": \"assistant\", \"time\": {\"created\": $(now_ms)}}, {\"type\": \"user\", \"time\": {\"created\": 2}}, {\"type\": \"idle\", \"outcome\": \"succeeded\", \"time\": {\"created\": 1}}]}"
    watch 07a >/dev/null; assert_eq "still running" "$?" "1"
}
test_permission() {
    healthy
    fixture GET /api/permission/request '{"location": {}, "data": [{"id": "per_1", "sessionID": "s2", "action": "external_directory", "resources": ["/home/x/*"]}]}'
    out="$(watch 07a)"; assert_eq "exit 4" "$?" "4"; assert_contains "shows it" "$out" "per_1"
}
test_question_in_a_subagent() {
    healthy; fixture GET /api/session/s3/form '{"data": [{"id": "frm_1", "sessionID": "s3", "title": "Which?", "fields": [{"title": "Pick"}]}]}'
    out="$(watch 07a)"; assert_eq "exit 5" "$?" "5"; assert_contains "shows it" "$out" "frm_1"
}
test_aborted_grandchild_reported_once() {
    healthy
    fixture GET /api/session/s3/message "{\"data\": [{\"type\": \"assistant\", \"id\": \"msg_x\", \"time\": {\"created\": 1791624990139}, \"error\": {\"type\": \"aborted\", \"message\": \"Step interrupted\"}}]}"
    out="$(watch 07a)"; assert_eq "exit 6" "$?" "6"
    assert_contains "error type" "$out" '"error":"aborted"'
    assert_contains "message's own time, UTC" "$out" "2026-10-10T"
    watch 07a >/dev/null; assert_eq "not again on the next run" "$?" "1"
}
test_stall() {
    healthy; local old=$(( $(now_ms) - 20 * 60000 ))
    for s in s1 s2 s3; do fixture GET /api/session/$s/message "{\"data\": [{\"type\": \"assistant\", \"time\": {\"created\": $old}}]}"; done
    out="$(watch 07a)"; assert_eq "exit 7" "$?" "7"; assert_contains "minutes" "$out" "no new message for 20 min"
}
test_missing_forms_endpoint_is_not_a_failure() {
    healthy; rm "$API_DIR/fixtures/GET/api/session/s2/form.json"
    watch 07a >/dev/null; assert_eq "still a timeout" "$?" "1"
}
test_server_down() {
    healthy; rm "$API_DIR/fixtures/GET/api/session.json"
    out="$(watch 07a)"; assert_eq "exit 8" "$?" "8"; assert_contains "says so" "$out" "SERVER DOWN"
}
test_unknown_brief() {
    start_api; out="$(watch nope 2>&1)"; assert_eq "exit 2" "$?" "2"; assert_contains "says which" "$out" "no session for brief nope"
}
run_tests
