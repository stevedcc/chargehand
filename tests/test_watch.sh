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
# Finding 1: the brief's own session can end in a provider error (402, quota, auth).
root_error_msg() { echo "{\"type\": \"assistant\", \"id\": \"msg_err\", \"time\": {\"created\": $(now_ms)}, \"error\": {\"type\": \"APIError\", \"message\": \"402 insufficient funds\"}}"; }
test_root_error_without_idle_is_reported() {
    healthy
    fixture GET /api/session/s1/message "{\"data\": [$(root_error_msg), {\"type\": \"user\", \"time\": {\"created\": 1}}]}"
    out="$(watch 07a)"; assert_eq "exit 9" "$?" "9"
    assert_contains "says so" "$out" "07a BRIEF SESSION ERROR"
    assert_contains "provider message" "$out" "402 insufficient funds"
}
test_idle_after_an_error_is_never_exit_0() {
    healthy
    fixture GET /api/session/s1/message "{\"data\": [{\"type\": \"idle\", \"outcome\": \"error\", \"time\": {\"created\": $(now_ms)}}, $(root_error_msg), {\"type\": \"user\", \"time\": {\"created\": 1}}]}"
    out="$(watch 07a)"; assert_eq "exit 9" "$?" "9"
    watch 07a >/dev/null; assert_eq "still 9 on a restart, never 0" "$?" "9"
}
test_idle_succeeded_with_an_errored_last_message_is_not_exit_0() {
    healthy
    fixture GET /api/session/s1/message "{\"data\": [{\"type\": \"idle\", \"outcome\": \"succeeded\", \"time\": {\"created\": $(now_ms)}}, $(root_error_msg), {\"type\": \"user\", \"time\": {\"created\": 1}}]}"
    watch 07a >/dev/null; assert_eq "exit 9" "$?" "9"
}
test_old_root_error_before_a_newer_prompt_is_ignored() {
    healthy
    fixture GET /api/session/s1/message "{\"data\": [{\"type\": \"assistant\", \"time\": {\"created\": $(now_ms)}}, {\"type\": \"user\", \"time\": {\"created\": 5}}, {\"type\": \"assistant\", \"id\": \"old\", \"time\": {\"created\": 2}, \"error\": {\"type\": \"APIError\", \"message\": \"402\"}}]}"
    watch 07a >/dev/null; assert_eq "still running" "$?" "1"
}
test_unknown_idle_outcome_is_not_success() {
    healthy
    fixture GET /api/session/s1/message "{\"data\": [{\"type\": \"idle\", \"outcome\": \"weird\", \"time\": {\"created\": $(now_ms)}}, {\"type\": \"user\", \"time\": {\"created\": 1}}]}"
    watch 07a >/dev/null; assert_eq "exit 9" "$?" "9"
}
# Finding 2: a watcher that cannot read a brief's messages must say so, not time out silently.
test_empty_root_messages_exit_10() {
    healthy; fixture GET /api/session/s1/message '{"data": []}'
    out="$(WATCH_MAX_SECONDS=20 watch 07a)"; assert_eq "exit 10" "$?" "10"
    assert_contains "says which" "$out" "07a WATCHER BLIND"
}
test_root_message_fetch_failing_exit_10() {
    healthy; rm "$API_DIR/fixtures/GET/api/session/s1/message.json"
    out="$(WATCH_MAX_SECONDS=20 watch 07a)"; assert_eq "exit 10" "$?" "10"
    assert_contains "reason" "$out" "message list did not answer"
}
test_root_gone_from_the_server_exit_10() {
    healthy; fixture GET /api/session '{"data": [{"id": "x9"}]}'; rm "$API_DIR/fixtures/GET/api/session/s1/message.json"
    out="$(WATCH_MAX_SECONDS=20 watch 07a)"; assert_eq "exit 10" "$?" "10"
}
test_session_updated_time_prevents_a_stall() {
    healthy; local old=$(( $(now_ms) - 20 * 60000 ))
    fixture GET /api/session "{\"data\": [{\"id\": \"s1\", \"time\": {\"updated\": $old}}, {\"id\": \"s2\", \"parentID\": \"s1\", \"time\": {\"updated\": $(now_ms)}}]}"
    for s in s1 s2; do fixture GET /api/session/$s/message "{\"data\": [{\"type\": \"assistant\", \"time\": {\"created\": $old}}]}"; done
    watch 07a >/dev/null; assert_eq "streaming child is not stalled" "$?" "1"
}
test_non_integer_message_time_does_not_break_the_stall_check() {
    healthy; local old=$(( $(now_ms) - 20 * 60000 ))
    fixture GET /api/session/s1/message "{\"data\": [{\"type\": \"assistant\", \"time\": {\"created\": \"soon\"}}, {\"type\": \"user\", \"time\": {\"created\": $old}}]}"
    for s in s2 s3; do fixture GET /api/session/$s/message "{\"data\": [{\"type\": \"assistant\", \"time\": {\"created\": $old}}]}"; done
    out="$(watch 07a 2>&1)"; assert_eq "stall check still runs" "$?" "7"
    assert_not_contains "no shell error" "$out" "integer expression"
}
test_message_lists_are_limited() {
    healthy; watch 07a >/dev/null
    assert_contains "limit passed" "$(requests | jq -r 'select(.path == "/api/session/s1/message") | .query' | head -1)" "limit="
}
test_permission() {
    healthy
    fixture GET /api/permission/request '{"location": {}, "data": [{"id": "per_1", "sessionID": "s2", "action": "external_directory", "resources": ["/home/x/*"]}]}'
    out="$(watch 07a)"; assert_eq "exit 4" "$?" "4"; assert_contains "shows it" "$out" "per_1"
}
test_permission_from_a_session_outside_the_watched_trees_is_information_only() {
    healthy
    fixture GET /api/permission/request '{"location": {}, "data": [{"id": "per_9", "sessionID": "x9", "action": "external_directory", "resources": ["/home/x/*"]}]}'
    out="$(watch 07a)"; assert_eq "keeps watching: timeout" "$?" "1"
    assert_contains "mentioned once as information" "$out" "per_9"
    assert_eq "only once" "$(grep -c per_9 <<<"$out")" "1"
}
test_permission_without_a_session_id_still_stops_the_watcher() {
    healthy
    fixture GET /api/permission/request '{"location": {}, "data": [{"id": "per_n", "action": "external_directory", "resources": ["/x"]}]}'
    watch 07a >/dev/null; assert_eq "exit 4" "$?" "4"
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
test_api_lock_contention_is_not_reported_as_server_down() {
    healthy; write_config "{\"server_url\": \"$API_URL\", \"server_password\": {\"wrapper\": [\"env\"], \"token\": \"test-password\"}}"
    mkdir -p "$HARNESS_STATE_DIR"
    ( flock 9; sleep 8 ) 9>"$HARNESS_STATE_DIR/api.lock" & holder=$!
    sleep 0.3
    out="$(HARNESS_API_LOCK_WAIT=1 WATCH_MAX_SECONDS=6 watch 07a)"; rc=$?
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
    assert_not_contains "not SERVER DOWN" "$out" "SERVER DOWN"
    assert_contains "says the lock is busy" "$out" "API lock busy"
    assert_eq "exit 8 only after repeated contention, with its own text" "$(grep -c 'API LOCK STUCK' <<<"$out")" "1"
}
# Finding 12: contract gaps.
test_message_order_does_not_matter() {
    healthy; local n; n=$(now_ms)
    fixture GET /api/session/s1/message "{\"data\": [{\"type\": \"user\", \"time\": {\"created\": $((n - 3000))}}, {\"type\": \"assistant\", \"time\": {\"created\": $((n - 2000))}}, {\"type\": \"idle\", \"outcome\": \"succeeded\", \"time\": {\"created\": $((n - 1000))}}]}"
    out="$(watch 07a)"; assert_eq "oldest-first list: idle found" "$?" "0"
}
test_a_second_watcher_for_the_same_brief_is_refused() {
    healthy
    ( WATCH_POLL_SECONDS=1 WATCH_MAX_SECONDS=4 watch 07a >/dev/null ) & first=$!
    sleep 1.5
    out="$(watch 07a 2>&1)"; assert_eq "exit 2" "$?" "2"; assert_contains "says who" "$out" "already being watched"
    wait "$first"
    watch 07a >/dev/null; assert_eq "free again afterwards" "$?" "1"
}
test_a_stale_pid_file_does_not_block() {
    healthy; echo 999999 > "$HARNESS_STATE_DIR/demo/briefs/07a/watch.pid"
    watch 07a >/dev/null; assert_eq "runs" "$?" "1"
}
test_a_config_error_is_exit_2_not_server_down() {
    healthy; write_config "{\"server_url\": \"$API_URL\"}"
    out="$(watch 07a 2>&1)"; assert_eq "exit 2" "$?" "2"
    assert_contains "says what" "$out" 'missing key "server_password"'
}
run_tests
