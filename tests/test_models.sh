. "$(dirname "$0")/lib.sh"
. "$HARNESS_ROOT/scripts/lib/harness.sh"
. "$HARNESS_ROOT/scripts/lib/models.sh"
MODELS='{
  "subscriptions": {
    "go":   {"pricing": {"per_mtok": 0.047}},
    "kimi": {"pricing": {"per_mtok": 0.49}, "ends": "2026-11-06"},
    "xm":   {"pricing": {"per_mtok": 0.024}}
  },
  "roles": {
    "implementer":  ["xm/mimo-v2.6-pro", "go/mimo-v2.6-pro"],
    "task_review":  ["kimi/kimi-for-coding", "go/deepseek-v4-pro"],
    "final_review": ["go/deepseek-v4-pro"],
    "low_level":    ["go/mimo-v2.6-flash"]
  }
}'
script() { bash "$HARNESS_ROOT/skills/running-briefs/scripts/models.sh" "$@"; }

test_effective_and_overrides() {
    write_models "$MODELS"; write_project p '{"roles": {"final_review": ["kimi/kimi-for-coding"]}}'
    eff="$(models_effective p implementer=go/glm-5.3)"
    assert_eq "per-brief override" "$(jq -c .implementer <<<"$eff")" '["go/glm-5.3"]'
    assert_eq "project override" "$(jq -c .final_review <<<"$eff")" '["kimi/kimi-for-coding"]'
    assert_eq "untouched role" "$(jq -c .low_level <<<"$eff")" '["go/mimo-v2.6-flash"]'
}
test_clean_allocation_has_no_problems() {
    write_models "$MODELS"; write_project p '{}'
    out="$(HARNESS_TODAY=2026-10-10 script --project p)"; rc=$?
    assert_eq "exit 0" "$rc" "0"
    assert_contains "implementer line" "$out" '`xm/mimo-v2.6-pro`; fallback: `go/mimo-v2.6-pro`'
    assert_contains "allowed providers" "$out" 'Allowed providers: `go/`, `kimi/`, `xm/`'
}
test_unknown_provider_refused() {
    write_models "$MODELS"; write_project p '{}'
    out="$(HARNESS_TODAY=2026-10-10 script --project p --role implementer=opencode/mimo-v2.6-pro)"; rc=$?
    assert_eq "exit 3" "$rc" "3"
    assert_contains "says which" "$out" "provider opencode is not one of your subscriptions"
}
test_ended_subscription() {
    write_models "$MODELS"; write_project p '{}'
    out="$(HARNESS_TODAY=2026-11-06 script --project p)"; assert_eq "usable on its end date" "$?" "0"
    out="$(HARNESS_TODAY=2026-11-07 script --project p)"; assert_eq "refused the day after" "$?" "3"
    assert_contains "names role and date" "$out" "role task_review: subscription kimi ended on 2026-11-06"
    assert_not_contains "ended provider not allowed" "$(sed -n '/Allowed providers/p' <<<"$out")" "kimi/"
}
test_same_family_reviewer_refused() {
    write_models "$MODELS"; write_project p '{}'
    out="$(HARNESS_TODAY=2026-10-10 script --project p --role final_review=go/mimo-v2.6-pro)"
    assert_eq "exit 3" "$?" "3"
    assert_contains "says why" "$out" "role final_review: go/mimo-v2.6-pro is the same model family as the implementer"
}
test_bad_override_syntax() {
    write_models "$MODELS"; write_project p '{}'
    out="$( (models_effective p implementer) 2>&1 )"; assert_eq "exit 2" "$?" "2"
    assert_contains "says the form" "$out" "want role=provider/model"
}
test_family_from_server_wins() {
    write_models "$MODELS"; write_project p '{}'
    eff="$(models_effective p final_review=go/deepseek-v4-pro)"
    fam='{"xm/mimo-v2.6-pro": "mimo", "go/deepseek-v4-pro": "mimo", "kimi/kimi-for-coding": "kimi"}'
    assert_contains "server family used" "$(HARNESS_TODAY=2026-10-10 models_check "$eff" "$fam")" "same model family"
}
test_family_variants_count_as_one_family() {
    write_models '{"subscriptions": {"z": {}}, "roles": {"implementer": ["z/glm-5.3"], "task_review": ["z/glm-5.3-flash"], "final_review": ["z/other-1"], "low_level": ["z/glm-5.3-flash"]}}'
    write_project p '{}'
    eff="$(models_effective p)"
    fam='{"z/glm-5.3": "glm", "z/glm-5.3-flash": "glm-flash", "z/other-1": null}'
    assert_contains "glm-flash is glm" "$(HARNESS_TODAY=2026-10-10 models_check "$eff" "$fam")" "role task_review: z/glm-5.3-flash is the same model family"
}
# models_pick: a provider with "max_busy_sessions" is skipped while that many of its sessions are
# busy (no "idle" message since their last prompt); the role's next model is used instead.
PICK_MODELS='{
  "subscriptions": {"z": {"max_busy_sessions": 1}, "go": {}},
  "roles": {"implementer": ["go/mimo-v2.6-pro"], "task_review": ["z/glm-5.3", "go/deepseek-v4-pro"],
            "final_review": ["z/glm-5.3", "go/deepseek-v4-pro"], "low_level": ["go/mimo-v2.6-flash"]}
}'
pick_session() { echo "{\"id\": \"$1\", \"model\": {\"providerID\": \"$2\", \"id\": \"m\"}, \"time\": {\"created\": $3, \"updated\": $3}}"; }
busy_msgs='{"data": [{"type": "assistant"}, {"type": "user"}]}'
idle_msgs='{"data": [{"type": "idle", "outcome": "succeeded"}, {"type": "assistant"}, {"type": "user"}]}'
pick() { . "$HARNESS_ROOT/scripts/lib/api.sh"; models_pick "$(models_effective p)" "$1"; }

test_pick_skips_a_provider_at_its_busy_limit() {
    start_api; write_models "$PICK_MODELS"; write_project p '{}'
    fixture GET /api/session "{\"data\": [$(pick_session s1 z "$(now_ms)")]}"
    fixture GET /api/session/s1/message "$busy_msgs"
    out="$(pick task_review 2>"$TEST_TMP/err")"
    assert_eq "falls back to the next model" "$out" "go/deepseek-v4-pro"
    assert_contains "says why" "$(cat "$TEST_TMP/err")" "z: 1 busy session(s), limit 1"
}
test_pick_counts_idle_sessions_as_free() {
    start_api; write_models "$PICK_MODELS"; write_project p '{}'
    fixture GET /api/session "{\"data\": [$(pick_session s1 z "$(now_ms)")]}"
    fixture GET /api/session/s1/message "$idle_msgs"
    assert_eq "first model" "$(pick task_review 2>/dev/null)" "z/glm-5.3"
}
test_pick_ignores_other_providers_and_old_sessions() {
    start_api; write_models "$PICK_MODELS"; write_project p '{}'
    old=$(( $(now_ms) - 7 * 3600 * 1000 ))
    fixture GET /api/session "{\"data\": [$(pick_session s1 go "$(now_ms)"), $(pick_session s2 z "$old")]}"
    fixture GET /api/session/s1/message "$busy_msgs"
    fixture GET /api/session/s2/message "$busy_msgs"
    assert_eq "first model" "$(pick final_review 2>/dev/null)" "z/glm-5.3"
}
test_pick_without_a_limit_never_skips() {
    start_api; write_models "$PICK_MODELS"; write_project p '{}'
    fixture GET /api/session "{\"data\": [$(pick_session s1 go "$(now_ms)")]}"
    fixture GET /api/session/s1/message "$busy_msgs"
    assert_eq "first model" "$(pick implementer 2>/dev/null)" "go/mimo-v2.6-pro"
}
test_pick_all_capped_keeps_the_first_and_warns() {
    start_api; write_project p '{}'
    write_models '{"subscriptions": {"z": {"max_busy_sessions": 1}}, "roles": {"implementer": ["z/a-1"], "task_review": ["z/glm-5.3"], "final_review": ["z/glm-5.3"], "low_level": ["z/a-1"]}}'
    fixture GET /api/session "{\"data\": [$(pick_session s1 z "$(now_ms)")]}"
    fixture GET /api/session/s1/message "$busy_msgs"
    out="$(pick task_review 2>"$TEST_TMP/err")"
    assert_eq "first model anyway" "$out" "z/glm-5.3"
    assert_contains "warns" "$(cat "$TEST_TMP/err")" "every model for task_review is at its busy limit"
}
test_pick_does_not_count_a_session_that_died_on_a_provider_error() {
    start_api; write_models "$PICK_MODELS"; write_project p '{}'
    fixture GET /api/session "{\"data\": [$(pick_session s1 z "$(now_ms)")]}"
    fixture GET /api/session/s1/message '{"data": [{"type": "assistant", "error": {"type": "APIError", "message": "402"}}, {"type": "user"}]}'
    assert_eq "dead session is not busy" "$(pick task_review 2>/dev/null)" "z/glm-5.3"
}
test_pick_counts_only_recently_active_sessions_as_busy() {
    start_api; write_models "$PICK_MODELS"; write_project p '{}'
    stale=$(( $(now_ms) - 30 * 60000 ))
    fixture GET /api/session "{\"data\": [$(pick_session s1 z "$stale")]}"
    fixture GET /api/session/s1/message "$busy_msgs"
    assert_eq "a session silent for 30 min is not busy" "$(pick task_review 2>/dev/null)" "z/glm-5.3"
}
run_tests
