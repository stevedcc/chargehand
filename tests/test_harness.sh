. "$(dirname "$0")/lib.sh"
. "$HARNESS_ROOT/scripts/lib/harness.sh"

test_project_get_reads_and_expands() {
    write_project demo '{"repo": "~/src/demo", "target_branch": "main", "e2e_agent_instances": [1, 20]}'
    assert_eq "string key, ~ expanded" "$(project_get demo repo)" "$HOME/src/demo"
    assert_eq "non-string key as JSON" "$(project_get demo e2e_agent_instances)" "[1,20]"
    assert_eq "default for a missing key" "$(project_get demo port_check none)" "none"
}
test_project_get_missing_key_fails_clearly() {
    write_project demo '{"repo": "/x"}'
    out="$( (project_get demo target_branch) 2>&1 )"; rc=$?
    assert_eq "exit 2" "$rc" "2"
    assert_contains "names file and key" "$out" 'demo.json: missing key "target_branch"'
}
test_missing_project_file_fails_clearly() {
    out="$( (project_get nope repo) 2>&1 )"; rc=$?
    assert_eq "exit 2" "$rc" "2"
    assert_contains "names the file" "$out" "projects/nope.json"
}
test_bad_names_are_refused() {
    for bad in '../x' 'a/b' 'A B' ''; do
        out="$( (project_file "$bad") 2>&1 )"; assert_eq "project [$bad] refused" "$?" "2"
        out="$( (brief_dir demo "$bad") 2>&1 )"; assert_eq "tag [$bad] refused" "$?" "2"
    done
    assert_eq "good tag" "$(brief_dir demo 03m)" "$HARNESS_STATE_DIR/demo/briefs/03m"
}
test_config_defaults_without_file() {
    assert_eq "default when config.json is missing" "$(config_get agent_user opencode)" "opencode"
    assert_eq "no forbidden tools" "$(forbidden_tools)" ""
}
test_forbidden_tools() {
    write_config '{"forbidden_tools": ["kubectl", "helm"]}'
    assert_eq "one per line" "$(forbidden_tools | paste -sd,)" "kubectl,helm"
}
test_missing_config_points_to_the_skill() {
    out="$( (project_get demo repo) 2>&1 )"
    assert_contains "pointer" "$out" "ask Claude to configure chargehand"
}
test_agent_text_strips_control_characters() {
    in="$(printf 'fix\033[2J\033[Hhidden\033]0;title\007 done\r\x01\x7f\xc2\x9b31m tab\there')"
    out="$(printf '%s' "$in" | agent_text)"
    assert_eq "escapes, C0, DEL, C1 gone; tab kept" "$out" "fixhidden done31m tab	here"
    assert_eq "newlines kept" "$(printf 'a\nb' | agent_text)" "$(printf 'a\nb')"
    assert_eq "plain UTF-8 untouched" "$(printf 'Größe – ok' | agent_text)" "Größe – ok"
}
test_record_name_is_injective() {
    assert_eq "slash and percent both encoded" "$(record_name 'agent/brief/x')" "agent%2Fbrief%2Fx"
    if [ "$(record_name 'agent/brief/x')" != "$(record_name 'agent/brief%x')" ]; then ok "different refs, different records"; else fail "agent/brief/x and agent/brief%x collide"; fi
}
test_records_dir_defaults_under_the_state_dir_and_is_created() {
    write_config '{}'
    d="$(records_dir demo)"
    assert_eq "default" "$d" "$HARNESS_STATE_DIR/demo/records"
    assert_eq "created" "$(test -d "$d" && echo yes)" "yes"
}
test_records_dir_from_config_with_home_and_project_placeholders() {
    write_config '{"records_dir": "~/notes/chargehand/{project}/records"}'
    assert_eq "configured" "$(records_dir demo)" "$HOME/notes/chargehand/demo/records"
    assert_eq "script prints the same" "$(bash "$HARNESS_ROOT/skills/writing-retros/scripts/records-dir.sh" --project demo)" "$HOME/notes/chargehand/demo/records"
}
test_records_dir_rejects_a_bad_project_name() {
    write_config '{}'; out="$( (records_dir '../x') 2>&1 )"; assert_eq "exit 2" "$?" "2"
}
run_tests
