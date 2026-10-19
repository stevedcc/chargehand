. "$(dirname "$0")/lib.sh"
SETUP="$HARNESS_ROOT/skills/setting-up-agent-sandbox/scripts/setup-agent-user.sh"
# setup runs as root and can't run here. Anything under the agent's home is the agent's to
# control (symlinks), so every operation there must run as the agent (as_agent), never as root.
test_setup_never_writes_agent_home_as_root() {
    bad="$(grep -nE 'AGENT_HOME/|"\$oc"' "$SETUP" | grep -v 'as_agent' | grep -vE '^[0-9]+:\s*(#|[a-z_]+="\$AGENT_HOME)')"
    assert_eq "every AGENT_HOME path is touched via as_agent" "$bad" ""
}
test_setup_reads_agent_config_as_agent() {
    assert_not_contains "no root read of the agent's opencode.json" "$(grep -n 'base=' "$SETUP")" 'base="$oc"'
}
test_agent_clone_is_not_world_readable() {
    line="$(grep -n 'install -d -o "$AGENT".*"$clone"' "$SETUP")"
    assert_contains "clone owned by the agent, group the owner" "$line" '-o "$AGENT" -g "$OWNER"'
    assert_contains "no access for others" "$line" '-m 2750'
}
test_launcher_never_mounts_a_path_the_clone_names() {
    sb="$HARNESS_ROOT/skills/setting-up-agent-sandbox/scripts/sandbox.sh"
    assert_not_contains "no bind of the clone's reported git directory" "$(cat "$sb")" '--bind "$common"'
    assert_contains "refuses a git directory outside the clone" "$(cat "$sb")" 'outside the clone'
}
test_clone_excludes_the_resume_notes_once() {
    . "$HARNESS_ROOT/scripts/lib/render.sh"
    mkdir -p "$TEST_TMP/clone/.git/info"
    sh -c "$CLONE_EXCLUDE_SH" sh "$TEST_TMP/clone"; sh -c "$CLONE_EXCLUDE_SH" sh "$TEST_TMP/clone"
    assert_eq "both patterns, once each" "$(cat "$TEST_TMP/clone/.git/info/exclude")" $'.superpowers/\nwip-*.md'
    git init -q "$TEST_TMP/wt" && mkdir -p "$TEST_TMP/wt/.superpowers" && : > "$TEST_TMP/wt/.superpowers/state.md" && : > "$TEST_TMP/wt/wip-a.md"
    sh -c "$CLONE_EXCLUDE_SH" sh "$TEST_TMP/wt"
    assert_eq "git ignores both" "$(git -C "$TEST_TMP/wt" status --porcelain)" ""
}
test_setup_applies_the_exclude_to_the_clone_as_the_agent() {
    assert_contains "as the agent" "$(grep -n 'CLONE_EXCLUDE_SH' "$SETUP")" 'as_agent sh -c "$CLONE_EXCLUDE_SH" sh "$clone"'
}
run_tests
