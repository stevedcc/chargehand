. "$(dirname "$0")/lib.sh"
. "$HARNESS_ROOT/scripts/lib/runtime.sh"

fake_rt() {
    mkdir -p "$TEST_TMP/bin"
    local n; for n in docker podman container; do cp "$HARNESS_ROOT/tests/fake_runtime.sh" "$TEST_TMP/bin/$n"; done
    export PATH="$TEST_TMP/bin:$PATH" TEST_TMP
    : > "$TEST_TMP/rt.log"
}
rt_log() { cat "$TEST_TMP/rt.log"; }

test_podman_internal_network() {
    fake_rt; CHARGEHAND_RUNTIME=podman rt_network_create v1 yes
    assert_eq "podman network create" "$(rt_log)" "podman network create --internal --label chargehand=1 v1"
}
test_docker_run_flags() {
    fake_rt; CHARGEHAND_RUNTIME=docker rt_run r1 img@sha256:aa net1 2 6g --mount /a:/w --mount /b:/o:ro \
        --env X=1 --label chargehand.verify=s1 -- bash -lc go
    assert_eq "docker run" "$(rt_log)" "docker run -d --name r1 --network net1 --cpus 2 --memory 6g -v /a:/w -v /b:/o:ro -e X=1 --label chargehand=1 --label chargehand.verify=s1 img@sha256:aa bash -lc go"
}
test_docker_run_workdir() {
    fake_rt; CHARGEHAND_RUNTIME=docker rt_run r1 img net1 1 1g --workdir /w -- true
    assert_contains "workdir flag" "$(rt_log)" "--workdir /w"
}
test_apple_container_uses_its_own_verbs() {
    fake_rt; export CHARGEHAND_RUNTIME=container
    rt_rm r1; rt_network_create v1 no
    assert_eq "apple verbs" "$(rt_log)" "container delete --force r1
container network create --label chargehand=1 v1"
    local err; err="$( (rt_network_create v1 yes) 2>&1)"; local rc=$?
    assert_eq "internal refused" "$rc" "2"
    assert_contains "internal message" "$err" "internal networks are not supported by the container runtime"
    assert_eq "nothing created" "$(rt_log | grep -c 'network create')" "1"
}
test_unknown_runtime_dies() {
    local err; err="$( (CHARGEHAND_RUNTIME=lxc rt_bin) 2>&1)"; local rc=$?
    assert_eq "non-zero" "$((rc != 0))" "1"
    assert_contains "message" "$err" 'unknown runtime "lxc"'
}
test_rm_absent_is_ok() {
    fake_rt; CHARGEHAND_RUNTIME=docker FAKE_RT_RC=1 rt_rm gone; assert_eq "rc" "$?" "0"
}
D64=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
test_digest_is_parsed_from_repo_digests() {
    fake_rt
    assert_eq "digest" "$(CHARGEHAND_RUNTIME=podman FAKE_RT_OUT_image="[\"docker.io/library/img@sha256:$D64\"]" rt_image_digest x)" "sha256:$D64"
    assert_contains "uses image inspect" "$(rt_log)" "podman image inspect --format {{json .RepoDigests}} x"
}
test_digest_fails_without_a_repo_digest() {
    fake_rt
    local out rc
    out="$(CHARGEHAND_RUNTIME=podman FAKE_RT_OUT_image='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' rt_image_digest x)"; rc=$?
    assert_eq "fails" "$((rc != 0))" "1"
    assert_eq "no output" "$out" ""
    out="$(CHARGEHAND_RUNTIME=docker FAKE_RT_OUT_image='[]' rt_image_digest x)"; rc=$?
    assert_eq "fails on empty list" "$((rc != 0))" "1"
}
test_apple_wait_reads_exit_code() {
    fake_rt
    assert_eq "code" "$(CHARGEHAND_RUNTIME=container FAKE_RT_OUT_inspect='[{"status":"stopped","exitCode":4}]' rt_wait r1)" "4"
}
test_apple_wait_without_exit_code_fails() {
    fake_rt
    local out rc
    out="$(CHARGEHAND_RUNTIME=container FAKE_RT_OUT_inspect='[{"status":"stopped"}]' rt_wait r1)"; rc=$?
    assert_eq "fails" "$((rc != 0))" "1"
    assert_eq "no output" "$out" ""
}
test_per_verb_overrides() {
    fake_rt; export CHARGEHAND_RUNTIME=docker
    FAKE_RT_RC_exec=7 rt_exec r1 -- true; assert_eq "exec rc" "$?" "7"
    assert_eq "exec argv" "$(rt_log | tail -1)" "docker exec r1 true"
    FAKE_RT_RC_exec=7 rt_logs r1; assert_eq "other verbs unaffected" "$?" "0"
    assert_eq "ps output" "$(FAKE_RT_OUT_ps=$'a\nb' rt_ls_labelled chargehand=1)" $'a\nb'
    assert_contains "ps filter" "$(rt_log | tail -1)" "ps -a --filter label=chargehand=1"
}
test_wait_prints_exit_code() {
    fake_rt; assert_eq "wait" "$(CHARGEHAND_RUNTIME=docker FAKE_RT_OUT_wait=3 rt_wait r1)" "3"
}
test_networks_labelled() {
    fake_rt; assert_eq "networks" "$(CHARGEHAND_RUNTIME=podman FAKE_RT_OUT_network=n1 rt_networks_labelled chargehand=1)" "n1"
}
test_pull() {
    fake_rt; CHARGEHAND_RUNTIME=docker rt_pull img; CHARGEHAND_RUNTIME=container rt_pull img
    assert_eq "pull verbs" "$(rt_log)" "docker pull img
container image pull img"
}
run_tests
