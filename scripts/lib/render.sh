# Rendering of generated files: session permissions, and the root-owned files setup installs.
# Source after harness.sh.

# render_permissions BASE_FILE: the base rules plus a shell deny for sudo and each forbidden tool.
render_permissions() {
    local tools dirs
    tools="$( { echo sudo; forbidden_tools; } | jq -R . | jq -sc .)"
    dirs="$(printf '%s\n' "${@:2}" | jq -R 'select(. != "")' | jq -sc .)"
    jq -c --argjson tools "$tools" --argjson dirs "$dirs" '. + [$tools[] | {action: "shell", resource: "\(.)*", effect: "deny"}]
        + [$dirs[] | {action: "external_directory", resource: "\(.)/**", effect: "allow"}]' "$1"
}

# render_rules TEMPLATE: the implementer rules with the owner's forbidden tools filled in.
render_rules() {
    local list="" t text
    while IFS= read -r t; do [ -n "$t" ] && list+=", \`$t\`"; done < <(forbidden_tools)
    text="$(<"$1")"
    printf '%s\n' "${text//\{\{FORBIDDEN_TOOLS\}\}/$list}"
}

# render_opencode_config EXISTING_FILE SHARE_DIR LOW_LEVEL_MODEL [SUPERPOWERS=yes|no]: the agent
# user's opencode.json. Keeps every existing key (plugins, providers ...), adds the rules to
# "instructions" once, defines the harness subagent with its prompt inlined (OpenCode v2's
# agents take the prompt as text in "system"), and adds the Superpowers plugin when no plugin
# entry names superpowers (the implementer rules use its skills); "no" leaves plugins alone. A
# test-runner agent left by an older setup is removed.
render_opencode_config() {
    local existing='{}' agents="$HARNESS_ROOT/implementer/agents"
    [ -f "$1" ] && existing="$(<"$1")"
    jq --arg share "$2" --arg m "$3" --arg sp "${4:-yes}" \
       --rawfile pa "$agents/pattern-applier.md" '
      (.instructions // []) as $i
      | .instructions = ($i - [$share + "/rules.md"] + [$share + "/rules.md"])
      | if $sp == "yes" and ((.plugins // []) | any(test("superpowers")) | not)
        then .plugins = ((.plugins // []) + ["superpowers@git+https://github.com/obra/superpowers.git"])
        else . end
      | .agents = ((.agents // {}) | del(.["test-runner"])) + {
          "pattern-applier": {
            description: "Applies an already-designed change (a reference commit) to further locations. Use only for tasks marked \"apply pattern\" whose reference commit exists and was reviewed.",
            mode: "subagent", model: $m, system: $pa } }' <<<"$existing"
}

# render_env PROJECT_FILE NAME: the root-owned /etc/chargehand/<name>.env the launcher sources.
# Lists are newline-separated; a leading ~ in toolchain and PATH entries means the agent's home.
render_env() {
    local f="$1" k
    for k in agent_clone mirror target_branch; do
        jq -e --arg k "$k" '.[$k] != null' "$f" >/dev/null || die "$f: missing key \"$k\""
    done
    q() { printf '%s=%q\n' "$1" "$2"; }
    q PROJECT "$2"
    q AGENT_CLONE "$(jq -r .agent_clone "$f")"
    q MIRROR "$(jq -r .mirror "$f")"
    q TARGET_BRANCH "$(jq -r .target_branch "$f")"
    q TEST_FILTER "$(jq -r '.test_filter // "."' "$f")"
    q VERIFY_BUILD "$(jq -r '.verify_build // ""' "$f")"
    q VERIFY_TESTS "$(jq -r '(.verify_tests // [])[]' "$f")"
    q VERIFY_TIMEOUT_MIN "$(jq -r '.verify_timeout_min // 60' "$f")"
    q E2E_COMMAND "$(jq -r '.e2e_command // ""' "$f")"
    q E2E_VERIFY_FIRST "$(jq -r '.e2e_verify_first // 21' "$f")"
    q E2E_INSTANCES "$(jq -r '.e2e_instances_per_run // 3' "$f")"
    q E2E_STOP "$(jq -r '.e2e_stop // ""' "$f")"
    q TOOLCHAIN_RO "$(jq -r '(.toolchain.ro // [])[]' "$f")"
    q TOOLCHAIN_RW "$(jq -r '(.toolchain.rw // [])[]' "$f")"
    q PATH_PREPEND "$(jq -r '(.path_prepend // [])[]' "$f")"
    q SANDBOX_ENV "$(jq -r '(.sandbox_env // {}) | to_entries[] | "\(.key)=\(.value)"' "$f")"
    q SELFTEST_EXTRA "$(jq -r '(.selftest_extra // [])[] | "\(.name)\t\(.cmd)"' "$f")"
}

# render_sudoers OWNER AGENT LAUNCHER PROJECT...: the owner may run only the launcher's fixed forms.
render_sudoers() {
    local owner="$1" agent="$2" l="$3" p cmds; shift 3
    cmds="$l \"\""
    for p in "$@"; do cmds+=", $l --selftest --project $p, $l --verify --project $p *"; done
    printf '# Managed by chargehand setup-agent-user.sh\n'
    printf 'Defaults!%s env_keep += "OPENCODE_SERVER_PASSWORD"\n' "$l"
    printf '%s ALL=(%s) NOPASSWD: %s\n' "$owner" "$agent" "$cmds"
}
