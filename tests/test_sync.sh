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
test_accept_fast_forwards_to_a_branch_that_carries_the_brief_commit() {
    repos; g -C "$W" switch -q -c brief/x main; echo "# x" > "$W/brief.md"; g -C "$W" add brief.md; g -C "$W" commit -q -m "brief x"
    g -C "$W" push -q agent-upstream brief/x; g -C "$W" switch -q main
    g -C "$C" fetch -q origin brief/x; g -C "$C" checkout -q -b brief/x origin/brief/x; g -C "$C" commit -q --allow-empty -m "agent work"
    sync fetch >/dev/null; fake_sudo 0; PATH="$TEST_TMP/bin:$PATH" sync verify agent/brief/x >/dev/null
    sync accept brief/x >/dev/null 2>&1; assert_eq "accepted" "$?" "0"
    assert_eq "target carries the brief commit and the work" "$(g -C "$W" log --format=%s main | head -3 | paste -sd,)" "agent work,brief x,base"
}
# R5b: after accept the owner's own brief/<tag> branch is merged, so it goes.
brief_branch_with_agent_work() {   # owner brief/x (brief commit, pushed), agent branch $1 from it plus work, verified
    repos; g -C "$W" switch -q -c brief/x main; echo "# x" > "$W/brief.md"; g -C "$W" add brief.md; g -C "$W" commit -q -m "brief x"
    g -C "$W" push -q agent-upstream brief/x; g -C "$W" switch -q main
    g -C "$C" fetch -q origin brief/x; g -C "$C" checkout -q -b "$1" origin/brief/x; g -C "$C" commit -q --allow-empty -m "agent work"
    sync fetch >/dev/null; fake_sudo 0; PATH="$TEST_TMP/bin:$PATH" sync verify "agent/$1" >/dev/null
}
test_accept_deletes_the_owners_merged_brief_branch() {
    brief_branch_with_agent_work brief/x
    out="$(sync accept brief/x 2>&1)"; assert_eq "accepted" "$?" "0"
    assert_contains "says so" "$out" "deleted local branch brief/x"
    assert_eq "branch gone" "$(g -C "$W" branch --list brief/x)" ""
}
test_accept_of_a_review_ref_deletes_the_owners_brief_branch() {
    brief_branch_with_agent_work review/x-abc1234
    out="$(sync accept review/x-abc1234 2>&1)"; assert_eq "accepted" "$?" "0"
    assert_contains "says so" "$out" "deleted local branch brief/x"
    assert_eq "branch gone" "$(g -C "$W" branch --list brief/x)" ""
}
test_accept_keeps_an_owner_branch_that_is_not_merged() {
    brief_branch_with_agent_work brief/x
    g -C "$W" switch -q brief/x; g -C "$W" commit -q --allow-empty -m "owner only"; g -C "$W" switch -q main
    out="$(sync accept brief/x 2>&1)"; assert_eq "accepted" "$?" "0"
    assert_not_contains "nothing deleted" "$out" "deleted local branch"
    assert_eq "branch kept" "$(g -C "$W" branch --list brief/x | wc -l)" "1"
}
test_diff_is_the_three_dot_diff_without_control_characters() {
    repos; g -C "$C" checkout -q -b brief/x; printf 'safe\n\033[2J\033]0;pwned\007line\n' > "$C/f.txt"; g -C "$C" add f.txt; g -C "$C" commit -q -m "agent adds f"
    g -C "$W" commit -q --allow-empty -m "owner moved on"
    sync fetch >/dev/null 2>&1
    out="$(sync diff agent/brief/x)"; assert_eq "exit 0" "$?" "0"
    assert_contains "shows the agent's change" "$out" "+safe"
    assert_not_contains "no escape byte" "$out" $'\e'
    assert_not_contains "no bell byte" "$out" $'\a'
    assert_not_contains "three dots: the owner's own commit is not in it" "$out" "owner moved on"
    out="$(sync diff 2>&1)"; assert_eq "needs a ref" "$?" "2"
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
# Finding 5: two failures of a branch that IS a fast-forward must not be called "not a fast-forward".
verified_branch_adding() {   # a file path the agent's commit adds, verified
    repos; g -C "$C" checkout -q -b brief/x; echo agent > "$C/$1"; g -C "$C" add "$1"; g -C "$C" commit -q -m "agent adds $1"
    sync fetch >/dev/null 2>&1; fake_sudo 0; PATH="$TEST_TMP/bin:$PATH" sync verify agent/brief/x >/dev/null
}
test_untracked_file_in_the_way_is_not_reported_as_non_ff() {
    verified_branch_adding new.cs; echo mine > "$W/new.cs"
    out="$(sync accept brief/x 2>&1)"; assert_eq "exit 2" "$?" "2"
    assert_not_contains "not misdiagnosed" "$out" "not a fast-forward"
    assert_contains "git's own text" "$out" "untracked working tree files would be overwritten"
    assert_eq "owner branch unchanged" "$(g -C "$W" log -1 --format=%s main)" "base"
}
test_merge_error_text_is_filtered_as_agent_text() {   # agent-named files; git 2.5x already prints "?" for these bytes, so a guard only
    name=$'evil\e]0;pwned\a.cs'
    verified_branch_adding "$name"; echo mine > "$W/$name"
    out="$(sync accept brief/x 2>&1)"; assert_eq "exit 2" "$?" "2"
    assert_not_contains "no escape byte" "$out" $'\e'
    assert_not_contains "no bell byte" "$out" $'\a'
}
test_stale_index_lock_is_not_reported_as_non_ff() {
    verified_branch_adding new.cs; touch "$W/.git/index.lock"
    out="$(sync accept brief/x 2>&1)"; assert_eq "exit 2" "$?" "2"
    assert_not_contains "not misdiagnosed" "$out" "not a fast-forward"
    assert_contains "git's own text" "$out" "index.lock"
}
# Finding 10: the launcher's exit codes say why a verify did not pass.
test_verify_exit_codes_are_told_apart() {
    repos
    for pair in "10:the build or a suite failed" "4:the sandbox could not start" "3:another verify of demo is running" "1:could not run the verification"; do
        fake_sudo "${pair%%:*}"; out="$(PATH="$TEST_TMP/bin:$PATH" sync verify main 2>&1)"; rc=$?
        assert_eq "exit ${pair%%:*} passed through" "$rc" "${pair%%:*}"
        assert_contains "says why for ${pair%%:*}" "$out" "${pair#*:}"
        assert_eq "not recorded" "$(ls "$HARNESS_STATE_DIR/demo/verified" 2>/dev/null | wc -l)" "0"
    done
}
# A launcher that answers 3 (busy) for its first N calls, then starts (prints "Verifying", as the
# real one does only once it holds the lock) and exits with the given code.
fake_busy_sudo() {
    mkdir -p "$TEST_TMP/bin"; : > "$TEST_TMP/sudo-calls"
    printf '#!/bin/sh\necho call >> "%s"\n[ "$(wc -l < "%s")" -le %s ] && exit 3\necho "Verifying abc123 subject"\nexit %s\n' \
        "$TEST_TMP/sudo-calls" "$TEST_TMP/sudo-calls" "$1" "${2:-0}" > "$TEST_TMP/bin/sudo"; chmod +x "$TEST_TMP/bin/sudo"
}
test_verify_wait_queues_behind_a_running_verify_then_runs() {
    repos; fake_busy_sudo 2 0
    out="$(CHARGEHAND_VERIFY_POLL_SEC=0 PATH="$TEST_TMP/bin:$PATH" sync verify --wait main 2>&1)"; rc=$?
    assert_eq "passes once the other verify is done" "$rc" "0"
    assert_eq "tried until the launcher was free" "$(wc -l < "$TEST_TMP/sudo-calls")" "3"
    assert_eq "says it waits, once" "$(grep -c "another verify of demo is running; waiting" <<<"$out")" "1"
    assert_contains "says when it really starts" "$out" "chargehand: verify of $(g -C "$W" rev-parse --short main) started"
    assert_eq "recorded" "$(ls "$HARNESS_STATE_DIR/demo/verified" | wc -l)" "1"
}
test_verify_wait_gives_up_after_its_limit() {
    repos; fake_busy_sudo 1000 0
    out="$(CHARGEHAND_VERIFY_POLL_SEC=1 CHARGEHAND_VERIFY_WAIT_MAX_SEC=2 PATH="$TEST_TMP/bin:$PATH" sync verify --wait main 2>&1)"; rc=$?
    assert_eq "exit 75 when the wait runs out" "$rc" "75"
    assert_contains "says it gave up" "$out" "gave up waiting"
    assert_eq "not recorded" "$(ls "$HARNESS_STATE_DIR/demo/verified" 2>/dev/null | wc -l)" "0"
}
test_verify_wait_does_not_retry_a_failure() {
    repos; fake_busy_sudo 0 10
    out="$(CHARGEHAND_VERIFY_POLL_SEC=0 PATH="$TEST_TMP/bin:$PATH" sync verify --wait main 2>&1)"; rc=$?
    assert_eq "a failed verify is final" "$rc" "10"
    assert_eq "ran once" "$(wc -l < "$TEST_TMP/sudo-calls")" "1"
}
test_verify_without_wait_still_refuses_at_once() {
    repos; fake_busy_sudo 1000 0
    out="$(PATH="$TEST_TMP/bin:$PATH" sync verify main 2>&1)"; rc=$?
    assert_eq "exit 3 without --wait" "$rc" "3"
    assert_eq "tried once" "$(wc -l < "$TEST_TMP/sudo-calls")" "1"
}
test_verify_announces_the_start_while_the_verify_still_runs() {
    # The start line must come when the launcher prints "Verifying", not when it exits: the filters
    # between them (agent_text) would otherwise hold it back until the end of the run.
    repos; mkdir -p "$TEST_TMP/bin"
    printf '#!/bin/sh\necho "Verifying abc123 subject"\nwhile [ ! -e "%s" ]; do sleep 0.1; done\ntouch "%s"\nexit 0\n' \
        "$TEST_TMP/release" "$TEST_TMP/exited" > "$TEST_TMP/bin/sudo"; chmod +x "$TEST_TMP/bin/sudo"
    PATH="$TEST_TMP/bin:$PATH" sync verify --wait main > "$TEST_TMP/out" 2>&1 &
    local pid=$! seen=no
    for _ in $(seq 50); do grep -q "chargehand: verify of" "$TEST_TMP/out" && { seen=yes; break; }; sleep 0.1; done
    assert_eq "start line shown while the launcher still runs" "$seen" "yes"
    assert_eq "the launcher had not exited yet" "$([ -e "$TEST_TMP/exited" ] && echo exited || echo running)" "running"
    touch "$TEST_TMP/release"; wait "$pid"; assert_eq "then passes" "$?" "0"
}

# Task 5: verify --lane pushes the SHA to a lane over SSH and runs the lane's controller there.
# The fake ssh logs its argv; git's own receive-pack call (git push over ssh) runs locally.
fake_lane() {   # $1 = exit code, $2 = output line to print after "Verifying"
    [ -d "$TEST_TMP/owner" ] || repos
    L="$TEST_TMP/lane"; mkdir -p "$L" "$TEST_TMP/bin"; [ -d "$L/demo.git" ] || g init -q --bare "$L/demo.git"
    write_config '{}'
    printf '{"box": {"ssh": "box", "repos_dir": "%s"}}' "$L" > "$HARNESS_CONFIG_DIR/lanes.json"
    cat > "$TEST_TMP/bin/ssh" <<EOS
#!/bin/bash
printf '%s\n' "\$*" >> "$TEST_TMP/ssh.log"
last="\${!#}"
case "\$last" in git-receive-pack*|git-upload-pack*) printf 'banner \\033]0;owned\\007\\033[2Jpush\\n' >&2; exec sh -c "\$last" ;; esac
echo "Verifying abc1234 x"
printf '%b\n' '$2'
exit $1
EOS
    chmod +x "$TEST_TMP/bin/ssh"
}
test_lane_verify_pushes_then_calls_the_controller() {
    fake_lane 0 'Passed!  - Failed: 0, Passed: 1'
    sha="$(g -C "$W" rev-parse main)"
    out="$(PATH="$TEST_TMP/bin:$PATH" sync verify --lane box main 2>&1)"; rc=$?
    assert_eq "passes" "$rc" "0"
    assert_eq "the SHA reached the lane's repo" "$(g -C "$L/demo.git" rev-parse --verify "refs/verify/$sha")" "$sha"
    assert_eq "verify call is exactly BatchMode, --, destination, controller command" "$(grep -F chargehand-lane "$TEST_TMP/ssh.log")" "-o BatchMode=yes -- box .local/bin/chargehand-lane verify --project demo $sha"
    assert_contains "the push is non-interactive too" "$(grep -F git-receive-pack "$TEST_TMP/ssh.log")" "-o BatchMode=yes"
    assert_contains "announces the start" "$out" "verify of ${sha:0:7} started"
    assert_contains "streams the output" "$out" "Passed!  - Failed: 0, Passed: 1"
    assert_eq "record is sha plus lane" "$(cat "$HARNESS_STATE_DIR/demo/verified/main")" "$sha lane=box"
}
test_lane_push_output_is_agent_text() {
    fake_lane 0 ok
    out="$(PATH="$TEST_TMP/bin:$PATH" sync verify --lane box main 2>&1)"
    assert_eq "no ESC from the push reaches the output" "$(printf '%s' "$out" | grep -c $'\033' || true)" "0"
    assert_contains "push text survives" "$out" "banner"
}
test_lane_verify_strips_control_characters() {
    fake_lane 0 'bad \033]0;owned\007text \033[2Jgone'
    out="$(PATH="$TEST_TMP/bin:$PATH" sync verify --lane box main 2>&1 || true)"
    assert_eq "no ESC reaches stdout" "$(printf '%s' "$out" | grep -c $'\033' || true)" "0"
    assert_contains "text survives" "$out" "bad text gone"
}
test_unknown_lane_dies() {
    fake_lane 0 ok
    out="$(PATH="$TEST_TMP/bin:$PATH" sync verify --lane nope main 2>&1)"; rc=$?
    assert_eq "usage/config exit" "$rc" "2"
    assert_contains "names the lane" "$out" 'no lane "nope" in lanes.json'
}
test_lane_verify_exit_codes_and_wait() {
    fake_lane 4 ""
    out="$(PATH="$TEST_TMP/bin:$PATH" sync verify --lane box main 2>&1)"; rc=$?
    assert_eq "runtime unavailable" "$rc" "4"
    assert_contains "says the lane's runtime" "$out" "the lane's container runtime is unavailable"
    fake_lane 10 ""
    PATH="$TEST_TMP/bin:$PATH" sync verify --wait --lane box main >/dev/null 2>&1; assert_eq "failure is final" "$?" "10"
}
test_accept_reads_a_lane_record() {
    fake_lane 0 'ok'
    g -C "$C" checkout -q -b brief/x; g -C "$C" commit -q --allow-empty -m "agent work"
    sync fetch >/dev/null; PATH="$TEST_TMP/bin:$PATH" sync verify --lane box agent/brief/x >/dev/null 2>&1
    sync accept brief/x >/dev/null 2>&1; assert_eq "accepted" "$?" "0"
    assert_eq "owner branch moved" "$(g -C "$W" log -1 --format=%s main)" "agent work"
}

run_tests
