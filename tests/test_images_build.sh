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

# --from: the versions come from a project's repo (pin_repo in tests/lib.sh).
GLOBAL='{ "sdk": { "version": "11.0.100-rc.3.26522.148", "rollForward": "latestFeature" } }'
E2E='<Project><ItemGroup>
    <PackageReference Include="Deque.AxeCore.Playwright" Version="4.14.0" />
    <PackageReference Include="Microsoft.Playwright.NUnit" Version="1.64.1" />
</ItemGroup></Project>'
FROM_ARGS=(--browsers chromium --tag "$TAG")
rev7() { local s; s="$(git -C "$1" rev-parse "${2:-HEAD}")"; printf '%s\n' "${s:0:7}"; }

test_from_passes_the_repos_versions() {
    fake_rt
    pin_repo "$TEST_TMP/p" global.json "$GLOBAL" e2e/e2e.csproj "$E2E"
    FAKE_RT_OUT_images="$LOCAL_LIST" build runner --from "$TEST_TMP/p.git" "${FROM_ARGS[@]}"
    assert_eq "exit" "$RC" "0"
    assert_contains "sdk from global.json" "$(rt_log)" "--build-arg DOTNET_SDK_VERSION=11.0.100-rc.3.26522.148 "
    assert_contains "playwright from the csproj" "$(rt_log)" "--build-arg PLAYWRIGHT_VERSION=1.64.1 "
    assert_contains "stderr names both, and where from" "$ERR" \
        "build.sh: .NET SDK 11.0.100-rc.3.26522.148, Playwright 1.64.1 (from $TEST_TMP/p.git at $(rev7 "$TEST_TMP/p.git"))"
}
test_rev_picks_an_older_commit() {
    fake_rt
    pin_repo "$TEST_TMP/p" global.json "$GLOBAL" e2e/e2e.csproj "$E2E"
    local old; old="$(git -C "$TEST_TMP/p" rev-parse HEAD)"
    printf '%s\n' '{ "sdk": { "version": "11.0.101" } }' > "$TEST_TMP/p/global.json"
    sed -i 's/1\.64\.1/1.65.0/' "$TEST_TMP/p/e2e/e2e.csproj"
    git -C "$TEST_TMP/p" -c user.name=t -c user.email=t@t commit -q -am bump
    FAKE_RT_OUT_images="$LOCAL_LIST" build runner --from "$TEST_TMP/p" --rev "$old" "${FROM_ARGS[@]}"
    assert_eq "exit" "$RC" "0"
    assert_contains "older sdk" "$(rt_log)" "--build-arg DOTNET_SDK_VERSION=11.0.100-rc.3.26522.148 "
    assert_contains "older playwright" "$(rt_log)" "--build-arg PLAYWRIGHT_VERSION=1.64.1 "
    assert_contains "stderr names the older commit" "$ERR" "(from $TEST_TMP/p at ${old:0:7})"
    : > "$TEST_TMP/rt.log"
    FAKE_RT_OUT_images="$LOCAL_LIST" build runner --from "$TEST_TMP/p" "${FROM_ARGS[@]}"
    assert_contains "HEAD by default" "$(rt_log)" "--build-arg DOTNET_SDK_VERSION=11.0.101 --build-arg PLAYWRIGHT_VERSION=1.65.0 "
}
test_from_with_sdk_or_playwright_exits_2() {
    fake_rt
    pin_repo "$TEST_TMP/p" global.json "$GLOBAL" e2e/e2e.csproj "$E2E"
    build runner --from "$TEST_TMP/p.git" --sdk 11.0.100 "${FROM_ARGS[@]}"
    assert_eq "with --sdk" "$RC" "2"
    assert_contains "message" "$ERR" "--from reads the versions; do not pass --sdk or --playwright with it"
    build runner --playwright 1.64.1 --from "$TEST_TMP/p.git" "${FROM_ARGS[@]}"
    assert_eq "with --playwright, before --from" "$RC" "2"
    assert_contains "message" "$ERR" "--from reads the versions; do not pass --sdk or --playwright with it"
    assert_eq "no runtime call" "$(rt_log)" ""
}
test_rev_without_from_exits_2() {
    fake_rt
    build "${ARGS[@]}" --rev HEAD
    assert_eq "exit" "$RC" "2"
    assert_contains "usage" "$ERR" "Usage: images/build.sh runner"
    assert_eq "no runtime call" "$(rt_log)" ""
}
test_repo_without_pins_dies() {
    fake_rt
    pin_repo "$TEST_TMP/p" e2e/e2e.csproj "$E2E"
    build runner --from "$TEST_TMP/p.git" "${FROM_ARGS[@]}"
    assert_eq "no global.json: exit" "$RC" "2"
    assert_contains "no global.json: message" "$ERR" \
        "$TEST_TMP/p.git at $(rev7 "$TEST_TMP/p.git") pins no .NET SDK (global.json sdk.version)"
    pin_repo "$TEST_TMP/q" global.json "$GLOBAL"
    build runner --from "$TEST_TMP/q.git" "${FROM_ARGS[@]}"
    assert_eq "no playwright: exit" "$RC" "2"
    assert_contains "no playwright: message" "$ERR" \
        "$TEST_TMP/q.git at $(rev7 "$TEST_TMP/q.git") pins no Microsoft.Playwright version"
    assert_eq "no runtime call" "$(rt_log)" ""
}
test_unreadable_pins_die_with_the_hint() {
    fake_rt
    pin_repo "$TEST_TMP/p" global.json '{ // a comment
  "sdk": { "version": "11.0.100" } }' e2e/e2e.csproj "$E2E"
    build runner --from "$TEST_TMP/p.git" "${FROM_ARGS[@]}"
    assert_eq "commented global.json: exit" "$RC" "2"
    assert_contains "pin message plus hint" "$ERR" \
        "global.json at $(rev7 "$TEST_TMP/p.git") is not plain JSON (pass --sdk / --playwright by hand)"
    pin_repo "$TEST_TMP/q" global.json "$GLOBAL" a.csproj "$E2E" \
        b.csproj '<Project><ItemGroup><PackageReference Include="Microsoft.Playwright" Version="1.63.0" /></ItemGroup></Project>'
    build runner --from "$TEST_TMP/q.git" "${FROM_ARGS[@]}"
    assert_eq "two playwright versions: exit" "$RC" "2"
    assert_contains "differ message plus hint" "$ERR" \
        "Playwright versions differ at $(rev7 "$TEST_TMP/q.git"): 1.64.1 (a.csproj), 1.63.0 (b.csproj) (pass --sdk / --playwright by hand)"
    build runner --from "$TEST_TMP/q.git" --rev nosuchrev "${FROM_ARGS[@]}"
    assert_eq "unknown rev: exit" "$RC" "2"
    assert_contains "unknown rev: message" "$ERR" "\"nosuchrev\" is not a commit in $TEST_TMP/q.git (pass --sdk / --playwright by hand)"
    assert_eq "no runtime call" "$(rt_log)" ""
}
test_pinned_values_get_the_version_checks() {
    fake_rt
    pin_repo "$TEST_TMP/p" global.json '{ "sdk": { "version": "banana" } }' e2e/e2e.csproj "$E2E"
    build runner --from "$TEST_TMP/p.git" "${FROM_ARGS[@]}"
    assert_eq "exit" "$RC" "2"
    assert_contains "message" "$ERR" 'bad SDK version "banana"'
    assert_eq "no runtime call" "$(rt_log)" ""
}
test_stderr_names_the_versions_without_from() {
    fake_rt
    FAKE_RT_OUT_images="$LOCAL_LIST" build "${ARGS[@]}"
    assert_eq "exit" "$RC" "0"
    assert_eq "the line, no from part" "$(grep '^build.sh: .NET SDK' <<<"$ERR")" \
        "build.sh: .NET SDK 11.0.100-rc.3.26522.148, Playwright 1.64.1"
}
test_usage_shows_the_from_option() {
    fake_rt
    build
    assert_contains "--from in the usage line" "$ERR" "| --from <repo> [--rev <rev>])"
    assert_contains "--rev explained" "$ERR" "--rev"
    assert_contains "exit 2 covers unreadable pins" "$ERR" "2 usage, or the repo's pins cannot be read"
}

# The image records its versions: each label is set from its own ARG, after the ARG lines (before
# them the values would be empty). Checked statically; no test builds the real runner image.
test_containerfile_labels_come_from_the_args_after_them() {
    local cf="$HARNESS_ROOT/images/runner/Containerfile" key arg label_line last_arg key_line
    label_line="$(grep -n '^LABEL ' "$cf" | cut -d: -f1)"
    last_arg="$(grep -n '^ARG ' "$cf" | tail -1 | cut -d: -f1)"
    for key in dotnet-sdk:DOTNET_SDK_VERSION playwright:PLAYWRIGHT_VERSION browsers:PLAYWRIGHT_BROWSERS; do
        arg="${key#*:}"; key="${key%%:*}"
        key_line="$(grep -nE "^(LABEL[[:space:]]+)?[[:space:]]*org\.chargehand\.runner\.$key=\"\\\$$arg\"" "$cf" | cut -d: -f1)"
        assert_eq "label $key from \$$arg, once" "$(grep -c . <<<"$key_line")" "1"
        assert_eq "label $key set in the LABEL, after the ARGs" "$(( ${key_line:-0} >= ${label_line:-999} && ${key_line:-0} > ${last_arg:-999} ))" "1"
    done
    assert_eq "one LABEL instruction" "$(grep -c '^LABEL ' "$cf")" "1"
    assert_eq "LABEL after the last ARG" "$(( ${label_line:-0} > ${last_arg:-999} ))" "1"
}

# Renovate pins the base by digest (renovate.json): the FROM line must name a tag, with or without
# "@sha256:<digest>", so its pin PR (and later digest PRs) keep this suite green.
test_containerfile_from_names_a_tag_with_or_without_a_digest() {
    local cf="$HARNESS_ROOT/images/runner/Containerfile" from
    from="$(grep -E '^FROM[[:space:]]' "$cf")"
    assert_eq "one FROM" "$(grep -c . <<<"$from")" "1"
    assert_eq "a tag, optionally @sha256" \
        "$(grep -cE '^FROM [a-z0-9.-]+(/[a-z0-9._-]+)+:[A-Za-z0-9_][A-Za-z0-9._-]*(@sha256:[0-9a-f]{64})?$' <<<"$from")" "1"
}

run_tests
