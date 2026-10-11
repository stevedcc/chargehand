. "$(dirname "$0")/lib.sh"
SCRIPT="$HARNESS_ROOT/skills/running-briefs/scripts/start-brief.sh"
MODELS='{"subscriptions": {"go": {}, "km": {}},
         "roles": {"implementer": ["go/mimo-v2.6-pro"], "task_review": ["km/kimi-for-coding"],
                   "final_review": ["go/deepseek-v4-pro"], "low_level": ["go/mimo-v2.6-flash"]}}'
setup_project() {
    mkdir -p "$HOME/repo/docs/briefs"; echo "# Brief" > "$HOME/repo/docs/briefs/07a.md"
    write_project demo "{\"owner_worktree\": \"~/repo\", \"target_branch\": \"main\",
      \"e2e_command\": \"dev/run-e2e.sh --instances {N} --first-instance {K}\",
      \"e2e_agent_instances\": [1, 20], \"e2e_instances_per_run\": 3, \"port_check\": \"ss -ltn on ports 5000-5199\"}"
    write_models "$MODELS"
    jq '. + {forbidden_tools: ["kubectl"]}' "$HARNESS_CONFIG_DIR/config.json" > "$TEST_TMP/c" && mv "$TEST_TMP/c" "$HARNESS_CONFIG_DIR/config.json"
}

test_launch_creates_session_and_state() {
    start_api; setup_project
    fixture POST /api/session '{"data": {"id": "ses_new"}}'
    fixture POST /api/session/ses_new/prompt '{"data": {"id": "msg_1"}}'
    sid="$(bash "$SCRIPT" --project demo --tag 07a --brief docs/briefs/07a.md --no-push --extra "Owner note.")"
    assert_eq "prints the session id" "$sid" "ses_new"
    d="$HARNESS_STATE_DIR/demo/briefs/07a"
    assert_eq "sid saved" "$(cat "$d/sid")" "ses_new"
    req="$(jq -c . "$d/session-request.json")"
    assert_contains "model pinned" "$req" '"model":{"providerID":"go","id":"mimo-v2.6-pro"}'
    assert_contains "sudo denied" "$req" '{"action":"shell","resource":"sudo*","effect":"deny"}'
    assert_contains "forbidden tool denied" "$req" '{"action":"shell","resource":"kubectl*","effect":"deny"}'
    msg="$(cat "$d/launch.txt")"
    assert_contains "brief named" "$msg" '`docs/briefs/07a.md`'
    assert_contains "worktree" "$msg" "git worktree add .worktrees/07a -b brief/07a origin/main"
    assert_contains "instance range" "$msg" "within 1..20"
    assert_contains "models block" "$msg" '`km/kimi-for-coding`'
    assert_contains "extra text" "$msg" "Owner note."
    assert_contains "prompt sent" "$(requests | jq -r 'select(.path == "/api/session/ses_new/prompt") | .body')" "Owner note."
}
test_fixed_first_instance() {
    start_api; setup_project
    out="$(bash "$SCRIPT" --project demo --tag 07a --brief docs/briefs/07a.md --first-instance 4 --dry-run)"
    assert_contains "command filled in" "$out" "dev/run-e2e.sh --instances 3 --first-instance 4"
}
test_refuses_bad_models_and_relaunch_and_missing_brief() {
    start_api; setup_project
    out="$(bash "$SCRIPT" --project demo --tag 07a --brief docs/briefs/07a.md --role final_review=go/mimo-v2.6-pro --dry-run 2>&1)"
    assert_eq "same family refused" "$?" "2"
    mkdir -p "$HARNESS_STATE_DIR/demo/briefs/07a"; echo ses_old > "$HARNESS_STATE_DIR/demo/briefs/07a/sid"
    out="$(bash "$SCRIPT" --project demo --tag 07a --brief docs/briefs/07a.md --dry-run 2>&1)"
    assert_contains "relaunch refused" "$out" "already has a session (ses_old)"
    out="$(bash "$SCRIPT" --project demo --tag 07b --brief docs/briefs/nope.md --dry-run 2>&1)"
    assert_contains "missing brief refused" "$out" "no brief docs/briefs/nope.md"
}
test_toolchain_dirs_allowed() {
    start_api; setup_project
    jq '. + {toolchain: {ro: ["/opt/sdk", "~/.cache/pw"], rw: ["~/.nuget"]}}' "$HARNESS_CONFIG_DIR/projects/demo.json" > "$TEST_TMP/p" \
        && mv "$TEST_TMP/p" "$HARNESS_CONFIG_DIR/projects/demo.json"
    jq '. + {agent_user: "nosuchagent"}' "$HARNESS_CONFIG_DIR/config.json" > "$TEST_TMP/c" && mv "$TEST_TMP/c" "$HARNESS_CONFIG_DIR/config.json"
    out="$(bash "$SCRIPT" --project demo --tag 07a --brief docs/briefs/07a.md --dry-run | sed -n '/^{/,$p' | jq -c .permissions)"
    assert_contains "absolute dir" "$out" '{"action":"external_directory","resource":"/opt/sdk/**","effect":"allow"}'
    assert_contains "agent home dir" "$out" '{"action":"external_directory","resource":"/home/nosuchagent/.cache/pw/**","effect":"allow"}'
    assert_contains "rw dir" "$out" '{"action":"external_directory","resource":"/home/nosuchagent/.nuget/**","effect":"allow"}'
    assert_contains "agent opencode cache" "$out" '{"action":"external_directory","resource":"/home/nosuchagent/.cache/opencode/**","effect":"allow"}'
    case "$out" in *dotnet*) fail "no project-specific dirs built in" ;; *) ok "no project-specific dirs built in" ;; esac
}
run_tests
