. "$(dirname "$0")/lib.sh"
SCRIPT="$HARNESS_ROOT/skills/verifying-and-accepting/scripts/agent-sync.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
g() { git -c init.defaultBranch=main "$@"; }
# owner repo (worktree = repo), bare mirror, agent clone; remotes as setup creates them.
repos() {
    W="$TEST_TMP/owner"; M="$TEST_TMP/mirror.git"; C="$TEST_TMP/clone"
    g init -q "$W"; g -C "$W" commit -q --allow-empty -m base
    g clone -q --bare "$W" "$M"; g clone -q "$M" "$C"
    g -C "$W" remote add agent-upstream "$M"; g -C "$W" remote add agent "$C"
    write_project demo "{\"owner_worktree\": \"$W\", \"target_branch\": \"main\", \"agent_clone\": \"$C\"}"
    write_config '{}'
}
sync() { bash "$SCRIPT" --project demo "$@"; }

fake_sudo() { mkdir -p "$TEST_TMP/bin"; printf '#!/bin/sh\necho "sudo $*"\nexit %s\n' "${1:-0}" > "$TEST_TMP/bin/sudo"; chmod +x "$TEST_TMP/bin/sudo"; }
test_fetch_and_fast_forward_accept() {
    repos; g -C "$C" checkout -q -b brief/x; g -C "$C" commit -q --allow-empty -m "agent work"
    sync fetch >/dev/null; assert_contains "fetched" "$(g -C "$W" branch -r)" "agent/brief/x"
    fake_sudo 0; PATH="$TEST_TMP/bin:$PATH" sync verify agent/brief/x >/dev/null
    sync accept brief/x >/dev/null 2>&1; assert_eq "accepted" "$?" "0"
    assert_eq "owner branch moved" "$(g -C "$W" log -1 --format=%s main)" "agent work"
    assert_eq "mirror updated" "$(g -C "$M" log -1 --format=%s main)" "agent work"
}
test_non_fast_forward_refused() {
    repos; g -C "$C" checkout -q -b brief/x; g -C "$C" commit -q --allow-empty -m "agent work"
    g -C "$W" commit -q --allow-empty -m "owner work"
    sync fetch >/dev/null; fake_sudo 0; PATH="$TEST_TMP/bin:$PATH" sync verify agent/brief/x >/dev/null
    out="$(sync accept brief/x 2>&1)"; assert_eq "exit 2" "$?" "2"
    assert_contains "says what to do" "$out" "merge origin/main into it"
    assert_eq "owner branch unchanged" "$(g -C "$W" log -1 --format=%s main)" "owner work"
}
test_dirty_tree_refused() {
    repos; echo x > "$W/f"; g -C "$W" add f
    out="$(sync accept 2>&1)"; assert_eq "exit 2" "$?" "2"; assert_contains "says why" "$out" "uncommitted changes"
}
test_verify_command() {
    repos; mkdir -p "$TEST_TMP/bin"; printf '#!/bin/sh\necho "sudo $*"\n' > "$TEST_TMP/bin/sudo"; chmod +x "$TEST_TMP/bin/sudo"
    out="$(PATH="$TEST_TMP/bin:$PATH" sync verify main)"
    assert_contains "runs the launcher as the agent user" "$out" "sudo -n -u opencode /usr/local/bin/chargehand-sandbox --verify --project demo $(g -C "$W" rev-parse main)"
}
test_accept_needs_a_verify_of_that_exact_commit() {
    repos; g -C "$C" checkout -q -b brief/x; g -C "$C" commit -q --allow-empty -m "verified work"
    sync fetch >/dev/null
    out="$(sync accept brief/x 2>&1)"; assert_eq "unverified refused" "$?" "2"; assert_contains "says why" "$out" "not verified"
    fake_sudo 1; PATH="$TEST_TMP/bin:$PATH" sync verify agent/brief/x >/dev/null
    out="$(sync accept brief/x 2>&1)"; assert_eq "failed verify refused" "$?" "2"
    fake_sudo 0; PATH="$TEST_TMP/bin:$PATH" sync verify agent/brief/x >/dev/null
    g -C "$C" commit -q --allow-empty -m "unread work"; sync fetch >/dev/null
    out="$(sync accept brief/x 2>&1)"; assert_eq "moved branch refused" "$?" "2"
    assert_contains "names both commits" "$out" "moved since verify"
    assert_eq "owner branch unchanged" "$(g -C "$W" log -1 --format=%s main)" "base"
}
run_tests
