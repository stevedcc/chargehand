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
run_tests
