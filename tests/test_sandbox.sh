. "$(dirname "$0")/lib.sh"
SCRIPT="$HARNESS_ROOT/skills/setting-up-agent-sandbox/scripts/sandbox.sh"
command -v bwrap >/dev/null || { echo "  skip  bubblewrap not installed"; exit 0; }
podman_ok() { [ -S "/run/user/$(id -u)/podman/podman.sock" ]; }
# The tests run the repo copy as yourself, which the launcher allows only with CHARGEHAND_ETC
# set. HOME stays the real one here: the launcher resets it from passwd anyway.

project_env() {   # project_env NAME JSON: render an env file into $TEST_TMP/etc
    mkdir -p "$TEST_TMP/etc"
    write_project "$1" "$2"
    ( . "$HARNESS_ROOT/scripts/lib/harness.sh"; . "$HARNESS_ROOT/scripts/lib/render.sh"
      render_env "$HARNESS_CONFIG_DIR/projects/$1.json" "$1" ) > "$TEST_TMP/etc/$1.env"
    chmod 644 "$TEST_TMP/etc/$1.env"
}

test_selftest_as_owner() {
    podman_ok || { echo "  skip  no podman socket"; return; }
    git init -q "$TEST_TMP/clone"; git init -q --bare "$TEST_TMP/mirror.git"
    git -C "$TEST_TMP/clone" remote add origin "$TEST_TMP/mirror.git"
    mkdir -p "$TEST_TMP/share"; echo rules > "$TEST_TMP/share/rules.md"
    project_env t "{\"agent_clone\": \"$TEST_TMP/clone\", \"mirror\": \"$TEST_TMP/mirror.git\", \"target_branch\": \"main\",
      \"test_filter\": \"Passed!|Failed!|^\\\\s+Failed \\\\S+ \\\\[|Error Message\",
      \"selftest_extra\": [{\"name\": \"extra check runs\", \"cmd\": \"true\"}]}"
    out="$(CHARGEHAND_ETC="$TEST_TMP/etc" CHARGEHAND_SHARE="$TEST_TMP/share" bash "$SCRIPT" --selftest --project t 2>&1)"
    for line in "ok    write own clone" "ok    write /tmp" "ok    write upstream mirror" \
                "ok    read implementer rules" "ok    write implementer rules" "ok    write project config" \
                "ok    extra check runs" "ok    keeps a passing summary" "ok    names a failing test" \
                "ok    drops EF Core log noise"; do
        assert_contains "$line" "$out" "$line"
    done
}
test_refuses_group_writable_env() {
    mkdir -p "$TEST_TMP/etc"; echo 'PROJECT=t' > "$TEST_TMP/etc/t.env"; chmod 664 "$TEST_TMP/etc/t.env"
    out="$(CHARGEHAND_ETC="$TEST_TMP/etc" bash "$SCRIPT" --selftest --project t 2>&1)"
    assert_eq "exit 2" "$?" "2"; assert_contains "says why" "$out" "writable by others"
}
test_refuses_unknown_project_and_bad_sha() {
    mkdir -p "$TEST_TMP/etc"
    out="$(CHARGEHAND_ETC="$TEST_TMP/etc" bash "$SCRIPT" --verify --project t 'abc;rm' 2>&1)"; assert_eq "bad sha" "$?" "2"
    out="$(CHARGEHAND_ETC="$TEST_TMP/etc" bash "$SCRIPT" --selftest --project nope 2>&1)"
    assert_eq "unknown exit 2" "$?" "2"; assert_contains "unknown" "$out" "no project nope"
    out="$(CHARGEHAND_ETC="$TEST_TMP/etc" bash "$SCRIPT" --selftest --project ../x 2>&1)"; assert_contains "bad name" "$out" "bad project name"
}
test_password_never_reaches_selftest_or_verify() {
    assert_eq "never passed with --setenv" "$(grep -c -- '--setenv OPENCODE_SERVER_PASSWORD' "$SCRIPT")" "0"
    podman_ok || { echo "  skip  no podman socket"; return; }
    git init -q "$TEST_TMP/clone"; git init -q --bare "$TEST_TMP/mirror.git"
    project_env t "{\"agent_clone\": \"$TEST_TMP/clone\", \"mirror\": \"$TEST_TMP/mirror.git\", \"target_branch\": \"main\",
      \"selftest_extra\": [{\"name\": \"no server password inside\", \"cmd\": \"test -z \\\"\$OPENCODE_SERVER_PASSWORD\\\"\"}]}"
    out="$(OPENCODE_SERVER_PASSWORD=sekret-value CHARGEHAND_ETC="$TEST_TMP/etc" bash "$SCRIPT" --selftest --project t 2>&1)"
    assert_contains "absent inside the sandbox" "$out" "ok    no server password inside"
}
test_verify_uses_a_fresh_checkout() {
    podman_ok || { echo "  skip  no podman socket"; return; }
    local name="harness-test-$$"
    git init -q -b main "$TEST_TMP/clone"; git -C "$TEST_TMP/clone" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
    git init -q --bare "$TEST_TMP/mirror.git"
    # The "build" plants a file in .git, as a malicious commit could; the "test" fails if it finds one.
    project_env "$name" "{\"agent_clone\": \"$TEST_TMP/clone\", \"mirror\": \"$TEST_TMP/mirror.git\", \"target_branch\": \"main\",
      \"verify_build\": \"test ! -e .git/planted && touch .git/planted\", \"verify_tests\": [\"echo Passed!\"], \"test_filter\": \"Passed!\"}"
    sha="$(git -C "$TEST_TMP/clone" rev-parse HEAD)"
    CHARGEHAND_ETC="$TEST_TMP/etc" bash "$SCRIPT" --verify --project "$name" "$sha" >/dev/null 2>&1; first=$?
    out="$(CHARGEHAND_ETC="$TEST_TMP/etc" bash "$SCRIPT" --verify --project "$name" "$sha" 2>&1)"; second=$?
    rm -rf "$(getent passwd "$(id -un)" | cut -d: -f6)/verify/$name"
    assert_eq "first run passes" "$first" "0"
    assert_eq "second run starts clean" "$second" "0"
}
run_tests
