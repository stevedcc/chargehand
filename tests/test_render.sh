. "$(dirname "$0")/lib.sh"
. "$HARNESS_ROOT/scripts/lib/harness.sh"
. "$HARNESS_ROOT/scripts/lib/render.sh"

test_rules_with_and_without_tools() {
    write_config '{"forbidden_tools": ["kubectl", "tswap"]}'
    out="$(render_rules "$HARNESS_ROOT/implementer/rules.md")"
    assert_contains "listed" "$out" '`sudo`, `kubectl`, `tswap`;'
    assert_not_contains "placeholder gone" "$out" "{{FORBIDDEN_TOOLS}}"
    write_config '{}'
    assert_contains "sudo alone" "$(render_rules "$HARNESS_ROOT/implementer/rules.md")" '`sudo`;'
}
test_rules_name_no_test_runner() {
    assert_eq "no test-runner anywhere in the rules or agents" "$(grep -rn 'test-runner' "$HARNESS_ROOT/implementer" | wc -l)" "0"
    assert_contains "launch message and rules disagree: stop" "$(cat "$HARNESS_ROOT/implementer/rules.md")" \
        "Where this file and your launch message disagree, stop and report; neither overrides the other."
}
test_permissions_deny_every_way_to_move_a_commit_or_branch() {
    # Pattern semantics are unverified against a real OpenCode server: this checks the list only.
    perms="$HARNESS_ROOT/skills/running-briefs/permissions.json"
    for p in 'git commit --amend*' 'git commit* --amend*' 'git reset --soft*' 'git reset --mixed*' 'git reset HEAD~*' \
             'git branch -f*' 'git branch --force*' 'git update-ref*' 'git checkout -B*' 'git switch -C*' \
             'git clean*' 'git stash drop*' 'git stash clear*'; do
        assert_eq "denied: $p" "$(jq -r --arg r "$p" '[.[] | select(.action == "shell" and .effect == "deny" and .resource == $r)] | length' "$perms")" "1"
    done
}
test_rules_say_never_move_a_commit_once() {
    out="$(tr '\n' ' ' < "$HARNESS_ROOT/implementer/rules.md" | sed 's/  */ /g')"   # wrapped lines
    assert_contains "one rule" "$out" "never amend, reset, squash, rebase or otherwise move a commit or branch once made; fixes are new commits"
    assert_not_contains "no exception" "$out" "you didn't just make"
}
test_rules_path_is_filled_in_for_subagents() {
    write_config '{}'
    out="$(render_rules "$HARNESS_ROOT/implementer/rules.md" /usr/local/share/chargehand/rules.md)"
    assert_contains "path given to subagents" "$(tr '\n' ' ' <<<"$out" | sed 's/  */ /g')" "gets the path of this rules file, \`/usr/local/share/chargehand/rules.md\`"
    assert_not_contains "placeholder gone" "$out" "{{RULES_FILE}}"
    assert_contains "default path" "$(render_rules "$HARNESS_ROOT/implementer/rules.md")" "\`/usr/local/share/chargehand/rules.md\`"
}
test_launch_rules_live_in_rules_md_and_the_messages_only_point_at_them() {
    rules="$(tr '\n' ' ' < "$HARNESS_ROOT/implementer/rules.md" | sed 's/  */ /g')"
    assert_contains "no re-grading" "$rules" "Never downgrade, re-grade or \"accept as limitation\""
    assert_contains "no way to record it away" "$rules" "or stop and report it with evidence; the orchestrator decides"
    assert_not_contains "no 'record why not'" "$rules" "record why not"
    assert_contains "verbatim claims" "$rules" "quote totals verbatim"
    assert_contains "no report files" "$rules" "never as files in the repository"
    for f in launch resume; do
        m="$(cat "$HARNESS_ROOT/skills/running-briefs/$f.md")"
        assert_contains "$f points at the rules" "$m" "harness rules in your instructions"
        assert_not_contains "$f carries no re-grading rule" "$m" "re-grade"
        assert_not_contains "$f carries no amend rule" "$m" "amend"
    done
}
test_rules_name_no_project() {
    out="$(grep -niE 'newblog|crawford|blog-framework|dotnet|tswap|kubectl|helm|mimo|kimi|glm|deepseek' "$HARNESS_ROOT/implementer/rules.md" "$HARNESS_ROOT/implementer/agents/"*.md)"
    assert_eq "no project, tool or model names" "$out" ""
}
test_opencode_config_keeps_existing_keys() {
    echo '{"plugins": ["superpowers@git+https://example/sp.git"], "instructions": ["/x.md"]}' > "$TEST_TMP/oc.json"
    out="$(render_opencode_config "$TEST_TMP/oc.json" /usr/local/share/chargehand go/mimo-v2.6-flash)"
    assert_eq "plugins kept" "$(jq -c .plugins <<<"$out")" '["superpowers@git+https://example/sp.git"]'
    assert_eq "rules added once" "$(jq -c .instructions <<<"$out")" '["/x.md","/usr/local/share/chargehand/rules.md"]'
    again="$(echo "$out" > "$TEST_TMP/oc2.json"; render_opencode_config "$TEST_TMP/oc2.json" /usr/local/share/chargehand go/mimo-v2.6-flash)"
    assert_eq "idempotent" "$(jq -c .instructions <<<"$again")" '["/x.md","/usr/local/share/chargehand/rules.md"]'
    assert_eq "no test-runner subagent" "$(jq -c '.agents | has("test-runner")' <<<"$out")" "false"
    assert_eq "pattern-applier pinned" "$(jq -r '.agents["pattern-applier"].model' <<<"$out")" "go/mimo-v2.6-flash"
    assert_contains "prompt inlined" "$(jq -r '.agents["pattern-applier"].system' <<<"$out")" "You apply a known pattern"
}
test_opencode_config_drops_an_old_test_runner() {
    echo '{"agents": {"test-runner": {"model": "x"}, "mine": {"model": "y"}}}' > "$TEST_TMP/oc.json"
    out="$(render_opencode_config "$TEST_TMP/oc.json" /s go/m-1)"
    assert_eq "old test-runner removed, own agent kept" "$(jq -c '.agents | keys' <<<"$out")" '["mine","pattern-applier"]'
}
test_opencode_config_from_nothing() {
    out="$(render_opencode_config /nonexistent /s go/m-1)"
    assert_eq "fresh" "$(jq -c .instructions <<<"$out")" '["/s/rules.md"]'
}
test_env_round_trips_through_bash() {
    write_project demo '{"agent_clone": "/srv/agents/demo", "mirror": "/srv/agents/upstream/demo.git",
      "target_branch": "main", "test_filter": "Passed!|Failed!|^\\s+Failed \\S+ \\[|Error Message",
      "verify_tests": ["dotnet test a --no-build", "dotnet test b --no-build"],
      "e2e_command": "dev/run-e2e.sh --instances {N} --first-instance {K}", "e2e_stop": "./stop.sh --instance {I}",
      "toolchain": {"ro": ["/opt/sdk", "~/.cache/pw"], "rw": ["~/.nuget"]},
      "sandbox_env": {"SDK_ROOT": "/opt/sdk"}, "selftest_extra": [{"name": "sdk", "cmd": "sdk --version | grep -q ^10"}]}'
    render_env "$HARNESS_CONFIG_DIR/projects/demo.json" demo > "$TEST_TMP/demo.env"
    ( . "$TEST_TMP/demo.env"
      assert_eq "filter survives quoting" "$TEST_FILTER" 'Passed!|Failed!|^\s+Failed \S+ \[|Error Message'
      assert_eq "tests one per line" "$(wc -l <<<"$VERIFY_TESTS")" "2"
      assert_eq "defaults" "$E2E_VERIFY_FIRST/$E2E_INSTANCES" "21/3"
      assert_eq "toolchain ~ kept for the agent's home" "$TOOLCHAIN_RO" $'/opt/sdk\n~/.cache/pw'
      assert_eq "selftest line" "$SELFTEST_EXTRA" $'sdk\tsdk --version | grep -q ^10'
      [ "$FAILS" -eq 0 ] ) || FAILS=$((FAILS + 1))
}
test_env_requires_core_keys() {
    write_project demo '{"agent_clone": "/x"}'
    out="$( (render_env "$HARNESS_CONFIG_DIR/projects/demo.json" demo) 2>&1 )"
    assert_eq "exit 2" "$?" "2"; assert_contains "names key" "$out" '"mirror"'
}
test_sudoers() {
    out="$(render_sudoers alice opencode /usr/local/bin/chargehand-sandbox demo other)"
    assert_contains "env kept" "$out" 'Defaults!/usr/local/bin/chargehand-sandbox env_keep += "OPENCODE_SERVER_PASSWORD"'
    assert_contains "serve" "$out" 'alice ALL=(opencode) NOPASSWD: /usr/local/bin/chargehand-sandbox ""'
    assert_contains "selftest per project" "$out" '/usr/local/bin/chargehand-sandbox --selftest --project other'
    assert_contains "verify per project" "$out" '/usr/local/bin/chargehand-sandbox --verify --project demo *'
}
test_opencode_config_adds_superpowers() {
    out="$(render_opencode_config /nonexistent /s go/m-1)"
    assert_eq "added when missing" "$(jq -c .plugins <<<"$out")" '["superpowers@git+https://github.com/obra/superpowers.git"]'
    echo '{"plugins": ["other-plugin"]}' > "$TEST_TMP/oc.json"
    out="$(render_opencode_config "$TEST_TMP/oc.json" /s go/m-1)"
    assert_eq "appended to others" "$(jq -c .plugins <<<"$out")" '["other-plugin","superpowers@git+https://github.com/obra/superpowers.git"]'
    echo '{"plugins": ["superpowers@git+https://example/fork.git"]}' > "$TEST_TMP/oc.json"
    out="$(render_opencode_config "$TEST_TMP/oc.json" /s go/m-1)"
    assert_eq "an existing superpowers entry is kept, not doubled" "$(jq -c .plugins <<<"$out")" '["superpowers@git+https://example/fork.git"]'
    out="$(render_opencode_config /nonexistent /s go/m-1 no)"
    assert_eq "opt-out" "$(jq -c '.plugins // []' <<<"$out")" '[]'
}
run_tests
