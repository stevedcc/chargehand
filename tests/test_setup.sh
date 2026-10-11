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
run_tests
