. "$(dirname "$0")/lib.sh"
SCRIPT="$HARNESS_ROOT/skills/running-briefs/scripts/integrate.sh"
SYNC="$HARNESS_ROOT/skills/verifying-and-accepting/scripts/agent-sync.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
g() { git -c init.defaultBranch=main "$@"; }
repos() {
    W="$TEST_TMP/owner"; M="$TEST_TMP/mirror.git"; C="$TEST_TMP/clone"
    g init -q "$W"; echo one > "$W/f.txt"; g -C "$W" add f.txt; g -C "$W" commit -q -m base
    g clone -q --bare "$W" "$M"; g clone -q "$M" "$C"
    g -C "$W" remote add agent-upstream "$M"; g -C "$W" remote add agent "$C"
    write_project demo "{\"owner_worktree\": \"$W\", \"target_branch\": \"main\", \"agent_clone\": \"$C\"}"
    write_config '{}'
}
# agent_branch TAG FILE CONTENT: a brief branch in the agent clone that writes FILE, with a running session.
agent_branch() {
    g -C "$C" checkout -q -b "brief/$1" main; echo "$3" > "$C/$2"; g -C "$C" add "$2"; g -C "$C" commit -q -m "$1 writes $2"
    g -C "$C" checkout -q main
    mkdir -p "$HARNESS_STATE_DIR/demo/briefs/$1"; echo "ses_$1" > "$HARNESS_STATE_DIR/demo/briefs/$1/sid"
}

test_clean_briefs() {
    repos; agent_branch a a.txt A; agent_branch b b.txt B
    out="$(bash "$SCRIPT" --project demo 2>&1)"; assert_eq "exit 0" "$?" "0"
    assert_contains "pair checked" "$out" "a + b"; assert_contains "clean" "$out" "clean"
}
test_conflicting_briefs() {
    repos; agent_branch a f.txt A; agent_branch b f.txt B
    out="$(bash "$SCRIPT" --project demo 2>&1)"; assert_eq "exit 1" "$?" "1"
    assert_contains "names the file" "$out" "f.txt"; assert_contains "says conflict" "$out" "CONFLICT"
}
test_no_running_briefs() {
    repos; out="$(bash "$SCRIPT" --project demo 2>&1)"; assert_eq "exit 0" "$?" "0"
    assert_contains "says so" "$out" "No running briefs"
}
test_fetch_failure_is_reported_not_silent() {
    repos; agent_branch a a.txt A; g -C "$W" remote set-url agent "$TEST_TMP/nonexistent"
    out="$(bash "$SCRIPT" --project demo 2>&1)"; rc=$?
    assert_eq "exit 2, not git's code" "$rc" "2"
    assert_contains "says what failed" "$out" "fetch of the agent clone failed"
}
test_concurrent_fetches_do_not_collide() {
    # Two fetches into one owner repo (integrate.sh every ten minutes plus a verify's fetch) used
    # to lose about half the time to "cannot lock ref"; they now queue on a lock.
    repos; agent_branch a a.txt A
    local pids=() i round bad=0
    for round in 1 2 3 4 5 6; do
        g -C "$C" checkout -q brief/a; g -C "$C" commit -q --allow-empty -m "r$round"; g -C "$C" checkout -q main
        pids=(); for i in 1 2 3 4; do bash "$SYNC" --project demo fetch >"$TEST_TMP/f$i" 2>&1 & pids+=($!); done
        for p in "${pids[@]}"; do wait "$p" || bad=$((bad + 1)); done
    done
    assert_eq "no fetch lost to a ref lock" "$bad" "0"
}
run_tests
