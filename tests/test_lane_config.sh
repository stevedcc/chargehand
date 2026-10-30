. "$(dirname "$0")/lib.sh"
EXAMPLE="$HARNESS_ROOT/examples/lane.json"

# lane CMD...: run a lane.sh function in a subshell (die exits); output (stderr folded in) lands in
# LANE_OUT and the exit code in LANE_RC. Called directly, not in $(...), so both survive.
lane() {
    LANE_OUT="$( . "$HARNESS_ROOT/scripts/lib/harness.sh"; . "$HARNESS_ROOT/scripts/lib/lane.sh"; "$@" 2>&1 )"
    LANE_RC=$?
}
# use_example [jq-filter]: install the example as this test's lane.json, optionally edited.
use_example() { jq "${1:-.}" "$EXAMPLE" > "$HARNESS_CONFIG_DIR/lane.json"; }

test_valid_example_passes() {
    use_example; lane lane_check; out="$LANE_OUT"
    assert_eq "lane_check returns 0" "$LANE_RC" "0"
    assert_eq "prints nothing" "$out" ""
}
test_tag_image_is_refused() {
    use_example '.projects.example.runner_image = "x/runner:latest"'; lane lane_check; out="$LANE_OUT"
    assert_eq "runner tag exit" "$LANE_RC" "2"
    assert_contains "runner tag" "$out" "runner_image for example must be pinned by digest (…@sha256:…)"
    use_example '.projects.example.services[0].image = "docker.io/library/postgres:18"'; lane lane_check; out="$LANE_OUT"
    assert_eq "service tag exit" "$LANE_RC" "2"
    assert_contains "service tag" "$out" "image for service db of example must be pinned by digest (…@sha256:…)"
}
test_unknown_runtime_is_refused() {
    use_example '.runtime = "lxc"'; lane lane_check; out="$LANE_OUT"
    assert_eq "exit" "$LANE_RC" "2"
    assert_contains "runtime" "$out" "runtime must be docker, podman or container"
}
test_tests_list_required() {
    use_example 'del(.projects.example.tests)'; lane lane_check; out="$LANE_OUT"
    assert_eq "exit" "$LANE_RC" "2"
    assert_contains "tests" "$out" "example: tests must be a non-empty list"
    use_example '.projects.example.tests = []'; lane lane_check; out="$LANE_OUT"
    assert_contains "empty tests" "$out" "example: tests must be a non-empty list"
}
test_summary_pattern_required() {
    use_example 'del(.projects.example.summary_pattern)'; lane lane_check; out="$LANE_OUT"
    assert_eq "missing exit" "$LANE_RC" "2"
    assert_contains "missing msg" "$out" "example: summary_pattern must be a non-empty string"
    use_example '.projects.example.summary_pattern = ""'; lane lane_check; out="$LANE_OUT"
    assert_eq "empty exit" "$LANE_RC" "2"
    assert_contains "empty msg" "$out" "example: summary_pattern must be a non-empty string"
}
test_home_paths_expand() {
    use_example
    lane lane_get .repos_dir; assert_eq "repos_dir" "$LANE_OUT" "$HOME/lane/repos"
    lane lane_get .work_dir; assert_eq "work_dir" "$LANE_OUT" "$HOME/lane/work"
    lane lane_project_get example .restore; assert_eq "project value" "$LANE_OUT" "dotnet restore Example.slnx --locked-mode"
}
test_get_defaults() {
    use_example
    lane lane_get .nope fallback; assert_eq "missing with default" "$LANE_OUT" "fallback"
    lane lane_get .nope; assert_eq "missing without default dies" "$LANE_RC" "2"
    lane lane_project_get example .nope d; assert_eq "project default" "$LANE_OUT" "d"
    lane lane_project_get example .runner_image; assert_contains "project value" "$LANE_OUT" "@sha256:"
}
test_service_memory_optional() {
    use_example '.projects.example.services[0].memory = "2g"'; lane lane_check
    assert_eq "memory accepted" "$LANE_RC" "0"
    use_example '.projects.example.services[0].memory = 5'; lane lane_check; out="$LANE_OUT"
    assert_eq "non-string memory refused" "$LANE_RC" "2"
    assert_contains "memory msg" "$out" "memory of service db must be a string"
}
test_service_files_are_checked() {
    use_example '.projects.example.services[0].files = {"/app/login.html": "dev/login.html", "/app/config.json": "dev/mock-oauth2-config.json"}'
    lane lane_check; assert_eq "files accepted" "$LANE_RC" "0"
    use_example '.projects.example.services[0].files = ["dev/login.html"]'; lane lane_check; out="$LANE_OUT"
    assert_eq "list refused" "$LANE_RC" "2"
    assert_contains "list msg" "$out" "example: files of service db must be an object of strings"
    local target source
    for target in "app/login.html" "/app/../etc/passwd" "/app/a,b" "/app/a:b" "/" "/app/x y" "/." "/app/./x"; do
        use_example ".projects.example.services[0].files = {\"$target\": \"dev/login.html\"}"; lane lane_check; out="$LANE_OUT"
        assert_eq "target $target refused" "$LANE_RC" "2"
        assert_contains "target $target msg" "$out" "example: file target $target of service db must be an absolute path (letters, digits, . _ - /) without .."
    done
    for source in "/etc/passwd" "../secret" "dev/../../x" "dev/a b" "" "dev/x:y" "." "./x"; do
        use_example ".projects.example.services[0].files = {\"/app/f\": \"$source\"}"; lane lane_check; out="$LANE_OUT"
        assert_eq "source '$source' refused" "$LANE_RC" "2"
        assert_contains "source '$source' msg" "$out" "example: file source $source of service db must be a path in the repo (letters, digits, . _ - /) without .."
    done
    # jq's $ matches before a final newline; a path must not end in one.
    use_example '.projects.example.services[0].files = {"/app/f\n": "dev/login.html"}'; lane lane_check
    assert_eq "target with a trailing newline refused" "$LANE_RC" "2"
    use_example '.projects.example.services[0].files = {"/app/f": "dev/login.html\n"}'; lane lane_check
    assert_eq "source with a trailing newline refused" "$LANE_RC" "2"
}
test_missing_file_and_bad_json() {
    lane lane_check; out="$LANE_OUT"; assert_eq "missing" "$LANE_RC" "2"; assert_contains "missing msg" "$out" "lane.json"
    echo '{' > "$HARNESS_CONFIG_DIR/lane.json"; lane lane_check; out="$LANE_OUT"
    assert_eq "bad json" "$LANE_RC" "2"; assert_contains "bad json msg" "$out" "not valid JSON"
}
run_tests
