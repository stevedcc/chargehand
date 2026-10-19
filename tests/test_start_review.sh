. "$(dirname "$0")/lib.sh"
SCRIPT="$HARNESS_ROOT/skills/running-briefs/scripts/start-review.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
MODELS='{"subscriptions": {"go": {}, "km": {}},
         "roles": {"implementer": ["go/mimo-v2.6-pro"], "task_review": ["km/kimi-for-coding"],
                   "final_review": ["go/deepseek-v4-pro"], "low_level": ["go/mimo-v2.6-flash"]}}'
setup_review() {
    git -c init.defaultBranch=main init -q "$HOME/repo"; git -C "$HOME/repo" commit -q --allow-empty -m base
    git -C "$HOME/repo" checkout -q -b "$1"
    git -C "$HOME/repo" init -q --bare "$TEST_TMP/mirror.git" 2>/dev/null
    git -C "$HOME/repo" remote add agent-upstream "$TEST_TMP/mirror.git"
    write_project demo "{\"owner_worktree\": \"~/repo\", \"target_branch\": \"main\"}"
    write_models "$MODELS"
    printf 'Review {TAG}: branch {BRANCH}, base {BASE}.\n' > "$TEST_TMP/prompt.md"
}

test_review_session_and_prompt() {
    start_api; setup_review feat/x
    fixture POST /api/session '{"data": {"id": "ses_r"}}'
    fixture POST /api/session/ses_r/prompt '{"data": {"id": "m1"}}'
    out="$(bash "$SCRIPT" --project demo --tag 07a --branch feat/x --base abc123 --role task_review --prompt "$TEST_TMP/prompt.md")"
    assert_eq "prints model and sid" "$out" "km/kimi-for-coding ses_r"
    d="$HARNESS_STATE_DIR/demo/briefs/07a-review"
    assert_eq "sid saved" "$(cat "$d/sid")" "ses_r"
    assert_eq "prompt filled in" "$(cat "$d/launch.txt")" "Review 07a: branch feat/x, base abc123."
}
test_ampersand_in_a_branch_name() {
    start_api; setup_review 'feat/a&b'
    fixture POST /api/session '{"data": {"id": "ses_r"}}'
    fixture POST /api/session/ses_r/prompt '{"data": {"id": "m1"}}'
    bash "$SCRIPT" --project demo --tag 07a --branch 'feat/a&b' --base abc123 --role task_review --prompt "$TEST_TMP/prompt.md" >/dev/null
    assert_eq "branch kept verbatim" "$(cat "$HARNESS_STATE_DIR/demo/briefs/07a-review/launch.txt")" "Review 07a: branch feat/a&b, base abc123."
}
test_previous_session_is_kept() {
    start_api; setup_review feat/x
    fixture POST /api/session '{"data": {"id": "ses_r2"}}'
    fixture POST /api/session/ses_r2/prompt '{"data": {"id": "m1"}}'
    d="$HARNESS_STATE_DIR/demo/briefs/07a-review"; mkdir -p "$d"; echo ses_r1 > "$d/sid"
    bash "$SCRIPT" --project demo --tag 07a --branch feat/x --base abc123 --role task_review --prompt "$TEST_TMP/prompt.md" >/dev/null
    assert_eq "rotated" "$(cat "$d/sid.prev1")" "ses_r1"
    assert_eq "new sid" "$(cat "$d/sid")" "ses_r2"
}
test_review_never_picks_a_pay_per_use_model_unasked() {
    start_api; setup_review feat/x
    write_models '{"subscriptions": {"go": {}, "api": {"pay_per_use": true}}, "roles": {"implementer": ["go/mimo-v2.6-pro"], "task_review": ["api/big-2"], "final_review": ["api/big-2", "go/deepseek-v4-pro"], "low_level": ["go/mimo-v2.6-flash"]}}'
    fixture POST /api/session '{"data": {"id": "ses_r"}}'
    fixture POST /api/session/ses_r/prompt '{"data": {"id": "m1"}}'
    out="$(bash "$SCRIPT" --project demo --tag 07a --branch feat/x --base abc123 --role task_review --prompt "$TEST_TMP/prompt.md" 2>&1)"
    assert_eq "refused" "$?" "2"; assert_contains "says how" "$out" "needs --allow-paid"
    out="$(bash "$SCRIPT" --project demo --tag 07a --branch feat/x --base abc123 --role final_review --prompt "$TEST_TMP/prompt.md" 2>/dev/null)"
    assert_eq "flat-rate fallback" "$out" "go/deepseek-v4-pro ses_r"
    out="$(bash "$SCRIPT" --project demo --tag 07b --branch feat/x --base abc123 --role task_review --allow-paid --prompt "$TEST_TMP/prompt.md" 2>/dev/null)"
    assert_eq "allowed" "$out" "api/big-2 ses_r"
}
run_tests
