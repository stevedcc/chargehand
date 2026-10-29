. "$(dirname "$0")/lib.sh"
SETUP="$HARNESS_ROOT/skills/setting-up-agent-sandbox/scripts/setup-lane.sh"
EXAMPLE="$HARNESS_ROOT/examples/lane.json"

# lane_home [jq-filter]: a lane user's HOME with the fake runtime on PATH and the example lane.json
# (paths under the temp HOME), optionally edited.
lane_home() {
    mkdir -p "$TEST_TMP/bin"
    local n; for n in docker podman container; do cp "$HARNESS_ROOT/tests/fake_runtime.sh" "$TEST_TMP/bin/$n"; done
    export PATH="$TEST_TMP/bin:$PATH" TEST_TMP
    : > "$TEST_TMP/rt.log"
    jq "${1:-.}" "$EXAMPLE" > "$HARNESS_CONFIG_DIR/lane.json"
}

test_setup_creates_repo_and_wrapper() {
    lane_home
    out="$(bash "$SETUP" --project example 2>&1)"; rc=$?
    assert_eq "exit" "$rc" "0"
    assert_eq "bare repo" "$(git --git-dir="$HOME/lane/repos/example.git" rev-parse --is-bare-repository)" "true"
    assert_eq "work dir" "$([ -d "$HOME/lane/work" ] && echo yes)" "yes"
    assert_eq "wrapper is executable" "$([ -x "$HOME/.local/bin/chargehand-lane" ] && echo yes)" "yes"
    help="$("$HOME/.local/bin/chargehand-lane" --help 2>&1)"
    assert_contains "wrapper runs the controller" "$help" "Usage: chargehand-lane verify --project <name> <sha>"
    assert_contains "runtime was pinged" "$(cat "$TEST_TMP/rt.log")" "podman "
    assert_contains "prints the lanes.json entry" "$out" '"repos_dir": "'"$HOME"'/lane/repos"'
    assert_contains "entry has an ssh placeholder" "$out" '<lane-user>@<box>'
    out2="$(bash "$SETUP" --project example 2>&1)"
    assert_eq "re-run is safe" "$?" "0"
}
test_wrapper_follows_home() {
    lane_home
    bash "$SETUP" --project example >/dev/null 2>&1
    other="$TEST_TMP/other-home"; mkdir -p "$other/.local/share" "$other/.config"
    cp -r "$HOME/.local/share/chargehand-lane" "$other/.local/share/"
    assert_not_contains "no absolute install path baked in" "$(cat "$HOME/.local/bin/chargehand-lane")" "$HOME"
    help="$(HOME="$other" "$HOME/.local/bin/chargehand-lane" --help 2>&1)"
    assert_contains "uses the HOME it runs under" "$help" "Usage: chargehand-lane"
}
test_setup_refuses_bad_config() {
    lane_home '.projects.example.runner_image = "x/runner:latest"'
    out="$(bash "$SETUP" --project example 2>&1)"; rc=$?
    assert_eq "exit" "$rc" "2"
    assert_contains "lane_check's message" "$out" "runner_image for example must be pinned by digest (…@sha256:…)"
    assert_eq "nothing installed" "$([ -e "$HOME/.local/bin/chargehand-lane" ] && echo yes || echo no)" "no"
}
test_setup_refuses_unknown_project_and_dead_runtime() {
    lane_home
    out="$(bash "$SETUP" --project nope 2>&1)"; rc=$?
    assert_eq "unknown project exit" "$rc" "2"
    assert_contains "unknown project" "$out" 'no project "nope" in'
    out="$(FAKE_RT_RC=1 bash "$SETUP" --project example 2>&1)"; rc=$?
    assert_eq "dead runtime exit" "$rc" "4"
    assert_contains "dead runtime" "$out" "runtime is unavailable"
}
test_setup_needs_no_sudo() {
    assert_not_contains "no sudo call" "$(grep -v '^\s*#' "$SETUP")" "sudo"
}
run_tests
