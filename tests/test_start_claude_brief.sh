. "$(dirname "$0")/lib.sh"
SCRIPT="$HARNESS_ROOT/skills/running-briefs/scripts/start-claude-brief.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
g() { git -c init.defaultBranch=main "$@"; }
setup_claude() {   # owner repo with the brief committed on brief/09a
    W="$HOME/repo"; g init -q "$W"; g -C "$W" commit -q --allow-empty -m base
    g -C "$W" switch -q -c brief/09a; mkdir -p "$W/docs"; echo "# 09a" > "$W/docs/09a.md"; g -C "$W" add docs
    g -C "$W" commit -q -m "brief 09a"; g -C "$W" switch -q main
    write_project demo "{\"owner_worktree\": \"$W\", \"target_branch\": \"main\",
      \"e2e_command\": \"run-e2e --instances {N} --first-instance {K}\", \"e2e_instances_per_run\": 3}"
}

test_creates_the_worktree_and_prints_the_prompt() {
    setup_claude
    out="$(bash "$SCRIPT" --project demo --tag 09a --brief docs/09a.md --first-instance 30 2>"$TEST_TMP/err")"
    assert_eq "worktree on the brief branch" "$(g -C "$W/.worktrees/09a" branch --show-current)" "brief/09a"
    assert_eq "brief is there" "$(cat "$W/.worktrees/09a/docs/09a.md")" "# 09a"
    assert_contains "prompt names the worktree" "$out" "$W/.worktrees/09a"
    assert_contains "brief" "$out" '`docs/09a.md`'
    assert_contains "rules file" "$out" "$HARNESS_ROOT/implementer/claude-subagent-rules.md"
    assert_contains "instance range" "$out" 'run-e2e --instances 3 --first-instance 30` (instances 30..32 are yours)'
    for ph in TAG BRIEF RULES WORKTREE E2E; do assert_not_contains "no {$ph} left" "$out" "{$ph}"; done
    assert_contains "review base on stderr" "$(cat "$TEST_TMP/err")" "review base $(g -C "$W" rev-parse brief/09a)"
}
test_keeps_worktrees_and_notes_out_of_git_once() {
    setup_claude
    bash "$SCRIPT" --project demo --tag 09a --brief docs/09a.md --first-instance 30 >/dev/null 2>&1
    mkdir -p "$W/.worktrees/09a/.superpowers"; : > "$W/.worktrees/09a/.superpowers/state.md"
    assert_eq "git sees nothing new" "$(g -C "$W" status --porcelain)" ""
    assert_eq "worktree sees nothing new" "$(g -C "$W/.worktrees/09a" status --porcelain)" ""
    assert_eq "each pattern once" "$(sort "$W/.git/info/exclude" | grep -cE '^(\.superpowers/|\.worktrees/)$')" "2"
}
test_refuses_an_uncommitted_brief_a_missing_instance_and_a_second_worktree() {
    setup_claude
    out="$(bash "$SCRIPT" --project demo --tag 09a --brief docs/nope.md --first-instance 30 2>&1)"
    assert_eq "no such brief" "$?" "2"; assert_contains "says how" "$out" "commit it on brief/09a"
    out="$(bash "$SCRIPT" --project demo --tag 09a --brief docs/09a.md 2>&1)"
    assert_eq "instances required with an e2e command" "$?" "2"; assert_contains "says so" "$out" "--first-instance"
    bash "$SCRIPT" --project demo --tag 09a --brief docs/09a.md --first-instance 30 >/dev/null 2>&1
    out="$(bash "$SCRIPT" --project demo --tag 09a --brief docs/09a.md --first-instance 30 2>&1)"
    assert_eq "second worktree refused" "$?" "2"; assert_contains "says so" "$out" "already exists"
}
test_a_brief_only_on_the_target_warns() {
    setup_claude; g -C "$W" branch -D brief/09a -q 2>/dev/null || g -C "$W" branch -D brief/09a >/dev/null
    mkdir -p "$W/docs"; echo "# 09a" > "$W/docs/09a.md"; g -C "$W" add docs; g -C "$W" commit -q -m "brief on main"
    out="$(bash "$SCRIPT" --project demo --tag 09a --brief docs/09a.md --first-instance 30 2>"$TEST_TMP/err")"
    assert_contains "warns" "$(cat "$TEST_TMP/err")" "brief docs/09a.md is on main, not on its own brief/09a commit; launching from the target"
    assert_not_contains "no first-commit claim" "$out" "first commit"
}
test_worktree_goes_beside_the_main_checkout_when_the_owner_worktree_is_linked() {
    M="$HOME/main"; g init -q "$M"; g -C "$M" commit -q --allow-empty -m base
    g -C "$M" switch -q -c brief/09a; mkdir -p "$M/docs"; echo "# 09a" > "$M/docs/09a.md"; g -C "$M" add docs; g -C "$M" commit -q -m "brief 09a"; g -C "$M" switch -q main
    g -C "$M" worktree add -q -b blog "$M/.worktrees/blog" main
    write_project demo "{\"owner_worktree\": \"$M/.worktrees/blog\", \"target_branch\": \"blog\"}"
    out="$(bash "$SCRIPT" --project demo --tag 09a --brief docs/09a.md 2>"$TEST_TMP/err")"
    assert_eq "at <main>/.worktrees/<tag>" "$(g -C "$M/.worktrees/09a" branch --show-current)" "brief/09a"
    assert_eq "not nested in the target checkout" "$(ls -d "$M/.worktrees/blog/.worktrees" 2>/dev/null)" ""
    assert_contains "prompt names it" "$out" "$M/.worktrees/09a"
    assert_contains "stderr names it" "$(cat "$TEST_TMP/err")" "worktree $M/.worktrees/09a on brief/09a"
}
test_a_bare_common_dir_falls_back_to_the_owner_worktrees_parent() {
    B="$HOME/bare.git"; g init -q --bare "$B"; g clone -q "$B" "$HOME/seed" 2>/dev/null
    g -C "$HOME/seed" commit -q --allow-empty -m base; g -C "$HOME/seed" push -q origin HEAD:main
    g -C "$HOME/seed" switch -q -c brief/09a; mkdir -p "$HOME/seed/docs"; echo "# 09a" > "$HOME/seed/docs/09a.md"
    g -C "$HOME/seed" add docs; g -C "$HOME/seed" commit -q -m "brief 09a"; g -C "$HOME/seed" push -q origin brief/09a
    mkdir -p "$HOME/trees"; g -C "$B" worktree add -q "$HOME/trees/main" main
    write_project demo "{\"owner_worktree\": \"$HOME/trees/main\", \"target_branch\": \"main\"}"
    bash "$SCRIPT" --project demo --tag 09a --brief docs/09a.md >/dev/null 2>"$TEST_TMP/err"
    assert_eq "beside the owner worktree" "$(g -C "$HOME/trees/.worktrees/09a" branch --show-current)" "brief/09a"
}
test_a_project_without_e2e_needs_no_instances() {
    setup_claude; write_project demo "{\"owner_worktree\": \"$W\", \"target_branch\": \"main\"}"
    out="$(bash "$SCRIPT" --project demo --tag 09a --brief docs/09a.md 2>/dev/null)"
    assert_eq "ok" "$?" "0"; assert_not_contains "no E2E sentence" "$out" "Run E2E"
}
run_tests
