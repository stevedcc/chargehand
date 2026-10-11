. "$(dirname "$0")/lib.sh"
SCRIPT="$HARNESS_ROOT/skills/writing-retros/scripts/brief-cost.sh"
# session ID PARENT PROVIDER MODEL COST INPUT OUTPUT REASONING CACHE_READ [DIRECTORY]
session() { echo "{\"id\": \"$1\", \"parentID\": \"$2\", \"model\": {\"providerID\": \"$3\", \"id\": \"$4\"}, \"cost\": $5,
  \"tokens\": {\"input\": $6, \"output\": $7, \"reasoning\": $8, \"cache\": {\"read\": $9, \"write\": 0}},
  \"location\": {\"directory\": \"${10:-/srv/agents/x}\"}}"; }
brief() { mkdir -p "$HARNESS_STATE_DIR/demo/briefs/$1"; echo "$2" > "$HARNESS_STATE_DIR/demo/briefs/$1/sid"; }
line() { jq -c --arg p "$1" ".lines[] | select(.provider == \$p) | $2" "$HARNESS_STATE_DIR/demo/briefs/03m/cost.json"; }

test_three_pricing_forms() {
    start_api; brief 03m s1
    write_models '{"subscriptions": {
        "xm": {"pricing": {"per_mtok": 0.024}},
        "km": {"pricing": {"per_mtok": {"input": 0.5, "output": 2, "cache_read": 0.05}}},
        "go": {"pricing": {"metered": {"plan_usd": 40, "model_limit_usd": {"deepseek-v4-pro": 60}}}}}, "roles": {}}'
    fixture GET /api/session "{\"data\": [
      $(session s1 '' xm mimo-v2.6-pro 0 1000000 0 0 9000000),
      $(session s2 s1 km kimi-for-coding 0 500000 0 0 500000),
      $(session s5 s2 go deepseek-v4-pro 1.5 0 0 0 0),
      $(session s3 '' xm mimo-v2.6-pro 0 0 0 0 2000000 /srv/agents/x/.worktrees/03m),
      $(session s4 '' xm mimo-v2.6-pro 0 7000000 0 0 0)]}"
    out="$(bash "$SCRIPT" --project demo --tag 03m)"
    assert_eq "blended: tree + worktree session, not s4" "$(line xm '[.sessions, .form, .usd]')" '[2,"blended",0.29]'
    assert_eq "per kind" "$(line km '[.form, .usd]')" '["per kind",0.28]'
    assert_eq "metered: reported cost / limit x plan" "$(line go '[.form, .usd]')" '["metered",1]'
    assert_eq "total" "$(jq .total_usd "$HARNESS_STATE_DIR/demo/briefs/03m/cost.json")" "1.57"
    assert_contains "table names the form" "$out" "metered"
}
test_reasoning_counts_as_output() {
    start_api; brief 03m s1
    write_models '{"subscriptions": {"km": {"pricing": {"per_mtok": {"output": 1}}}}, "roles": {}}'
    fixture GET /api/session "{\"data\": [$(session s1 '' km k-1 0 0 1000000 1000000 0)]}"
    bash "$SCRIPT" --project demo --tag 03m >/dev/null
    assert_eq "2M output tokens" "$(line km .usd)" "2"
}
test_missing_pricing_and_missing_limit_are_flagged() {
    start_api; brief 03m s1
    write_models '{"subscriptions": {"zz": {}, "go": {"pricing": {"metered": {"plan_usd": 40, "model_limit_usd": {}}}}}, "roles": {}}'
    fixture GET /api/session "{\"data\": [$(session s1 '' zz a-1 0 1 0 0 0), $(session s2 s1 go b-1 2 0 0 0 0)]}"
    out="$(bash "$SCRIPT" --project demo --tag 03m)"
    assert_contains "no pricing" "$out" "no rate"
    assert_contains "no limit for the model" "$out" "no limit for b-1"
}
test_large_session_list() {
    start_api; brief 03m s1
    write_models '{"subscriptions": {"xm": {"pricing": {"per_mtok": 1}}}, "roles": {}}'
    pad="$(head -c 200000 /dev/zero | tr '\0' x)"
    fixture GET /api/session "{\"data\": [$(session s1 '' xm m-1 0 1000000 0 0 0), {\"id\": \"big\", \"note\": \"$pad\", \"model\": {\"providerID\": \"xm\", \"id\": \"m-1\"}, \"tokens\": {\"input\": 5, \"output\": 0, \"reasoning\": 0, \"cache\": {\"read\": 0, \"write\": 0}}}]}"
    bash "$SCRIPT" --project demo --tag 03m >/dev/null 2>&1; assert_eq "runs" "$?" "0"
    assert_eq "priced" "$(line xm .usd)" "1"
}
run_tests
