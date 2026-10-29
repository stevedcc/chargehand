. "$(dirname "$0")/lib.sh"
# images/build.sh against the fake runtime (tests/fake_runtime.sh). The real build is a manual step
# (it takes long and needs qemu for the other architecture): see images/build.sh.
D64=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
P64=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
TAG=registry.example/chargehand-runner-dotnet:11.0.100-rc.3
ARGS=(runner --sdk 11.0.100-rc.3.26522.148 --playwright 1.64.1 --browsers "chromium firefox" --tag "$TAG")

# fake_rt: the fake runtime as podman and docker, behind a wrapper: `podman manifest exists` exits
# $FAKE_MANIFEST_EXISTS (default 1, absent), `podman manifest push --digestfile F` writes sha256:$P64
# to F, and `docker buildx build --metadata-file F` writes a buildx metadata file naming sha256:$P64.
fake_rt() {
    mkdir -p "$TEST_TMP/bin" "$TEST_TMP/real"
    local n; for n in podman docker; do
        cp "$HARNESS_ROOT/tests/fake_runtime.sh" "$TEST_TMP/real/$n"
        cat > "$TEST_TMP/bin/$n" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "manifest exists" ]; then echo "$(basename "$0") $*" >> "$TEST_TMP/rt.log"; exit "${FAKE_MANIFEST_EXISTS:-1}"; fi
prev=; for a in "$@"; do
    [ "$prev" = --digestfile ] && printf 'sha256:%s' "$P64" > "$a"
    [ "$prev" = --metadata-file ] && printf '{"containerimage.digest": "sha256:%s"}\n' "$P64" > "$a"
    prev="$a"
done
exec "$TEST_TMP/real/$(basename "$0")" "$@"
EOF
        chmod +x "$TEST_TMP/bin/$n"
    done
    export PATH="$TEST_TMP/bin:$PATH" TEST_TMP P64
    : > "$TEST_TMP/rt.log"
}
rt_log() { cat "$TEST_TMP/rt.log"; }
# build ARGS...: runs images/build.sh; stdout in OUT, stderr in ERR, exit code in RC.
build() { OUT="$(bash "$HARNESS_ROOT/images/build.sh" "$@" 2>"$TEST_TMP/err")"; RC=$?; ERR="$(cat "$TEST_TMP/err")"; }
# `podman images --format json` after a manifest build (shape seen on Podman 5.8): the list's own
# Digest field is the empty list it started from; its last repo digest is the list as built.
E64=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
LOCAL_LIST="[{\"Names\": [\"$TAG\"], \"Digest\": \"sha256:$E64\",
  \"RepoDigests\": [\"registry.example/chargehand-runner-dotnet@sha256:$E64\", \"registry.example/chargehand-runner-dotnet@sha256:$D64\"]},
 {\"Names\": null, \"Digest\": \"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\", \"RepoDigests\": []}]"

test_usage_errors_exit_2() {
    fake_rt
    build; assert_eq "no arguments" "$RC" "2"
    assert_contains "usage ends with the exit codes" "$ERR" "Exit 0 built (and pushed); 2 usage"
    assert_eq "usage prints no code" "$(grep -c 'set -uo\|IMAGES_DIR' <<<"$ERR")" "0"
    build other --tag x; assert_eq "unknown image" "$RC" "2"
    build runner --sdk 11.0.100 --playwright 1.64.1 --browsers chromium; assert_eq "no tag" "$RC" "2"
    build runner --sdk "11.0;x" --playwright 1.64.1 --browsers chromium --tag t; assert_eq "bad sdk" "$RC" "2"
    build runner --sdk 11.0.100 --playwright latest --browsers chromium --tag t; assert_eq "bad playwright" "$RC" "2"
    build runner --sdk 11.0.100 --playwright 1.64.1 --browsers "chromium; rm" --tag t; assert_eq "bad browser" "$RC" "2"
    assert_contains "browser message" "$ERR" 'unknown browser "chromium;"'
    build runner --sdk 11.0.100 --playwright 1.64.1 --browsers "" --tag t; assert_eq "no browsers" "$RC" "2"
    build "${ARGS[@]}" --pull; assert_eq "unknown option" "$RC" "2"
    assert_eq "no runtime call" "$(rt_log)" ""
}
test_podman_builds_both_architectures_into_one_manifest() {
    fake_rt
    FAKE_RT_OUT_images="$LOCAL_LIST" build "${ARGS[@]}"
    assert_eq "exit" "$RC" "0"
    assert_eq "prints the manifest list digest" "$OUT" "sha256:$D64"
    assert_contains "says it is local" "$ERR" "local digest"
    local r="$HARNESS_ROOT/images/runner"
    assert_contains "one build, both platforms" "$(rt_log)" "podman build --platform linux/amd64,linux/arm64 --manifest $TAG -f $r/Containerfile --build-arg DOTNET_SDK_VERSION=11.0.100-rc.3.26522.148 --build-arg PLAYWRIGHT_VERSION=1.64.1 --build-arg PLAYWRIGHT_BROWSERS=chromium firefox $r"
    assert_not_contains "no stale manifest to remove" "$(rt_log)" "manifest rm"
    assert_not_contains "no push" "$(rt_log)" "push"
}
test_platforms_option_builds_only_those() {
    fake_rt
    FAKE_RT_OUT_images="$LOCAL_LIST" build "${ARGS[@]}" --platforms linux/amd64
    assert_eq "exit" "$RC" "0"
    assert_contains "one platform" "$(rt_log)" "podman build --platform linux/amd64 --manifest $TAG "
    FAKE_RT_OUT_images="$LOCAL_LIST" build "${ARGS[@]}" --platforms "linux/arm64,linux/amd64"
    assert_contains "both, in the given order" "$(rt_log)" "podman build --platform linux/arm64,linux/amd64 --manifest $TAG "
    : > "$TEST_TMP/rt.log"
    build "${ARGS[@]}" --platforms linux/s390x; assert_eq "unknown platform" "$RC" "2"
    assert_contains "platform message" "$ERR" 'unknown platform "linux/s390x" (expected linux/amd64 or linux/arm64)'
    build "${ARGS[@]}" --platforms ""; assert_eq "empty platforms" "$RC" "2"
    build "${ARGS[@]}" --platforms "linux/amd64,"; assert_eq "trailing comma" "$RC" "2"
    build "${ARGS[@]}" --platforms; assert_eq "missing value" "$RC" "2"
    assert_eq "no runtime call" "$(rt_log)" ""
}
test_podman_rebuild_starts_a_new_manifest() {
    fake_rt
    FAKE_MANIFEST_EXISTS=0 FAKE_RT_OUT_images="$LOCAL_LIST" build "${ARGS[@]}"
    assert_eq "exit" "$RC" "0"
    local rm build
    rm="$(grep -n "^podman manifest rm $TAG$" "$TEST_TMP/rt.log" | cut -d: -f1)"
    build="$(grep -n '^podman build ' "$TEST_TMP/rt.log" | cut -d: -f1)"
    assert_eq "old manifest removed before the build" "$(( ${rm:-999} < ${build:-0} ))" "1"
}
test_podman_push_prints_the_pushed_digest() {
    fake_rt
    build "${ARGS[@]}" --push
    assert_eq "exit" "$RC" "0"
    assert_eq "pushed digest" "$OUT" "sha256:$P64"
    assert_contains "pushes every architecture" "$(rt_log)" "podman manifest push --all --digestfile "
    assert_contains "to the tag's registry" "$(rt_log | grep 'manifest push')" " $TAG docker://$TAG"
}
test_docker_uses_buildx() {
    fake_rt
    CHARGEHAND_RUNTIME=docker build "${ARGS[@]}" --push
    assert_eq "exit" "$RC" "0"
    assert_eq "pushed digest" "$OUT" "sha256:$P64"
    local r="$HARNESS_ROOT/images/runner"
    assert_contains "buildx, both platforms" "$(rt_log)" "docker buildx build --platform linux/amd64,linux/arm64 -f $r/Containerfile -t $TAG --build-arg DOTNET_SDK_VERSION=11.0.100-rc.3.26522.148"
    assert_contains "pushes" "$(rt_log)" " --push $r"
    assert_eq "one runtime call" "$(grep -c . "$TEST_TMP/rt.log")" "1"
}
test_build_failure_fails_without_a_digest() {
    fake_rt
    FAKE_RT_RC_build=1 build "${ARGS[@]}"
    assert_eq "exit" "$RC" "1"
    assert_eq "no digest" "$OUT" ""
    FAKE_RT_OUT_images='[]' build "${ARGS[@]}"
    assert_eq "no manifest found" "$RC" "1"
    assert_contains "message" "$ERR" "could not read the digest of $TAG"
}
test_apple_container_is_refused() {
    fake_rt
    CHARGEHAND_RUNTIME=container build "${ARGS[@]}"
    assert_eq "exit" "$RC" "2"
    assert_contains "message" "$ERR" "multi-architecture builds need docker or podman"
}

run_tests
