. "$(dirname "$0")/lib.sh"
# images/runner/chargehand-run against a recipe directory and an out directory in TEST_TMP
# (CHARGEHAND_RECIPE_DIR / CHARGEHAND_OUT_DIR stand in for /recipe and /out).
RUN="$HARNESS_ROOT/images/runner/chargehand-run"

# recipe BUILD TESTS... : writes a recipe with the sandbox's own filter; each TESTS argument is one line.
recipe() {
    R="$TEST_TMP/recipe"; O="$TEST_TMP/out"; mkdir -p "$R" "$O"
    printf '%s\n' "$1" > "$R/build"; shift
    printf '%s\n' "$@" > "$R/tests"
    : > "$R/restore"
    printf '%s\n' 'Passed!|Failed!|^\s+Failed \S+ \[|Error Message' > "$R/filter"
    printf '%s\n' '^(Passed|Failed)!' > "$R/summary"
    printf '%s\n' "${TIMEOUT_MIN:-5}" > "$R/timeout_min"
}
run_runner() {   # run_runner PHASE: output in OUT, exit code in RC
    OUT="$(CHARGEHAND_RECIPE_DIR="$R" CHARGEHAND_OUT_DIR="$O" bash "$RUN" "$@" 2>&1)"; RC=$?
}

test_runner_filters_like_the_sandbox() {
    recipe "true" "printf '%s\n' 'Failed executing DbCommand' '  Failed Ns.Cls.Name [5 s]' '  Error Message:' '   boom' 'Failed!  - Failed: 1, Passed: 2'; exit 1"
    run_runner suites
    local f; f="$(cat "$O/filtered.txt")"
    assert_eq "exit" "$RC" "10"
    assert_contains "test name kept" "$f" "Failed Ns.Cls.Name [5 s]"
    assert_contains "message kept" "$f" "boom"
    assert_contains "summary kept" "$f" "Failed!  - Failed: 1, Passed: 2"
    assert_not_contains "DbCommand dropped" "$f" "DbCommand"
    assert_contains "full log keeps DbCommand" "$(cat "$O/full.log")" "DbCommand"
    assert_eq "suites.txt" "$(cat "$O/suites.txt")" "1 1 1"
    assert_contains "filtered lines on stdout" "$OUT" "boom"
}
test_runner_timeout_is_a_failure() {
    TIMEOUT_MIN=0.02 recipe "true" "sleep 5"
    run_runner suites
    assert_eq "exit" "$RC" "10"
    assert_contains "message" "$OUT" "TIMED OUT after 0.02 min: sleep 5"
    assert_eq "suites.txt" "$(cat "$O/suites.txt")" "1 124 0"
}
test_runner_passes_with_one_summary_per_suite() {
    recipe "true" "echo 'Passed!  - Failed: 0, Passed: 3'" "echo 'Passed!  - Failed: 0, Passed: 1'"
    run_runner suites
    assert_eq "exit" "$RC" "0"
    assert_eq "suites.txt" "$(cat "$O/suites.txt")" $'1 0 1\n2 0 1'
}
test_runner_build_failure_stops_before_the_suites() {
    recipe "echo compiling; exit 3" "echo 'Passed!  - Failed: 0, Passed: 3'"
    run_runner suites
    assert_eq "exit" "$RC" "10"
    assert_contains "message" "$OUT" "BUILD FAILED"
    assert_eq "no suites.txt" "$([ -s "$O/suites.txt" ] && echo there || echo none)" "none"
}
test_runner_counts_every_summary_line() {
    recipe "true" "echo 'Passed!  - a'; echo 'Passed!  - b'" "echo 'no summary here'"
    run_runner suites
    assert_eq "exit" "$RC" "0"
    assert_eq "suites.txt" "$(cat "$O/suites.txt")" $'1 0 2\n2 0 0'
}
test_runner_restore_runs_the_recipe() {
    recipe "true" "true"
    printf '%s\n' 'echo restoring' > "$R/restore"
    run_runner restore
    assert_eq "exit" "$RC" "0"
    assert_contains "output" "$OUT" "restoring"
    printf '%s\n' 'exit 4' > "$R/restore"
    run_runner restore
    assert_eq "restore failure exit" "$RC" "10"
}
test_runner_restore_timeout() {
    TIMEOUT_MIN=0.02 recipe "true" "true"
    printf '%s\n' 'sleep 5' > "$R/restore"
    run_runner restore
    assert_eq "exit" "$RC" "10"
    assert_contains "message" "$OUT" "TIMED OUT after 0.02 min: sleep 5"
}
test_runner_usage_errors_exit_2() {
    recipe "true" "true"
    run_runner
    assert_eq "no phase" "$RC" "2"
    run_runner bogus
    assert_eq "bad phase" "$RC" "2"
    run_runner suites extra
    assert_eq "extra argument" "$RC" "2"
    rm "$R/filter"
    run_runner suites
    assert_eq "missing recipe file" "$RC" "2"
    assert_contains "names the file" "$OUT" "filter"
}

run_tests
