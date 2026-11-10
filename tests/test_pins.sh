. "$(dirname "$0")/lib.sh"
. "$HARNESS_ROOT/scripts/lib/harness.sh"
. "$HARNESS_ROOT/scripts/lib/pins.sh"

# pin FN REPO REV: runs FN in $( ); stdout to PIN_OUT, stderr to PIN_ERR, status to PIN_RC.
pin() {
    local errf="$TEST_TMP/err"
    PIN_OUT="$("$1" "$2" "$3" 2>"$errf")"; PIN_RC=$?
    PIN_ERR="$(cat "$errf")"
}

CROFT_GLOBAL='{
  "sdk": {
    "version": "11.0.100-rc.3.26522.148",
    "rollForward": "latestFeature"
  }
}'
CROFT_E2E='<Project Sdk="Microsoft.NET.Sdk">
  <ItemGroup>
    <PackageReference Include="Deque.AxeCore.Playwright" Version="4.14.0" />
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="18.0.1" />
    <PackageReference Include="Microsoft.Playwright.NUnit" Version="1.64.1" />
    <PackageReference Include="NUnit" Version="4.4.0" />
  </ItemGroup>
</Project>'
ref() { printf '<Project>\n  <ItemGroup>\n    %s\n  </ItemGroup>\n</Project>' "$1"; }

test_croft_shapes_from_bare_at_sha_and_worktree_at_head() {
    pin_repo "$TEST_TMP/r" global.json "$CROFT_GLOBAL" tests/Croft.Web.E2E/Croft.Web.E2E.csproj "$CROFT_E2E"
    local sha; sha="$(git -C "$TEST_TMP/r" rev-parse HEAD)"
    pin pins_sdk "$TEST_TMP/r.git" "$sha"
    assert_eq "bare: sdk rc" "$PIN_RC" 0
    assert_eq "bare: sdk version" "$PIN_OUT" "11.0.100-rc.3.26522.148"
    pin pins_playwright "$TEST_TMP/r.git" "$sha"
    assert_eq "bare: playwright rc" "$PIN_RC" 0
    assert_eq "bare: exactly the NUnit version, not Deque's" "$PIN_OUT" "1.64.1"
    assert_eq "bare: no stderr" "$PIN_ERR" ""
    pin pins_sdk "$TEST_TMP/r" HEAD
    assert_eq "worktree: sdk version" "$PIN_OUT" "11.0.100-rc.3.26522.148"
    pin pins_playwright "$TEST_TMP/r" HEAD
    assert_eq "worktree: playwright rc" "$PIN_RC" 0
    assert_eq "worktree: playwright version" "$PIN_OUT" "1.64.1"
}
test_central_package_version() {
    pin_repo "$TEST_TMP/r" Directory.Packages.props "$(ref '<PackageVersion Include="Microsoft.Playwright" Version="1.65.0" />')" \
        e2e/e2e.csproj "$(ref '<PackageReference Include="Microsoft.Playwright" />')"
    pin pins_playwright "$TEST_TMP/r.git" HEAD
    assert_eq "rc" "$PIN_RC" 0
    assert_eq "version from PackageVersion" "$PIN_OUT" "1.65.0"
}
test_version_before_include() {
    pin_repo "$TEST_TMP/r" a.csproj "$(ref '<PackageReference Version="1.64.1" Include="Microsoft.Playwright.MSTest" />')"
    pin pins_playwright "$TEST_TMP/r.git" HEAD
    assert_eq "rc" "$PIN_RC" 0
    assert_eq "version" "$PIN_OUT" "1.64.1"
}
test_two_versions_differ() {
    pin_repo "$TEST_TMP/r" path/a.csproj "$(ref '<PackageReference Include="Microsoft.Playwright.NUnit" Version="1.64.1" />')" \
        path/b.csproj "$(ref '<PackageReference Include="Microsoft.Playwright" Version="1.63.0" />')"
    local rev7; rev7="$(git -C "$TEST_TMP/r" rev-parse HEAD)"; rev7="${rev7:0:7}"
    pin pins_playwright "$TEST_TMP/r.git" HEAD
    assert_eq "rc" "$PIN_RC" 2
    assert_eq "nothing on stdout" "$PIN_OUT" ""
    assert_eq "message names both files" "$PIN_ERR" \
        "Playwright versions differ at $rev7: 1.64.1 (path/a.csproj), 1.63.0 (path/b.csproj)"
}
test_split_element_and_version_override() {
    pin_repo "$TEST_TMP/r" a.csproj '<Project>
  <ItemGroup>
    <PackageReference
        Include="Microsoft.Playwright.NUnit"
        Version="1.64.1" />
  </ItemGroup>
</Project>'
    pin pins_playwright "$TEST_TMP/r.git" HEAD
    assert_eq "split: rc" "$PIN_RC" 0
    assert_eq "split: version" "$PIN_OUT" "1.64.1"
    pin_repo "$TEST_TMP/s" a.csproj "$(ref '<PackageReference Update="Microsoft.Playwright" VersionOverride="1.66.0" />')"
    pin pins_playwright "$TEST_TMP/s.git" HEAD
    assert_eq "override: rc" "$PIN_RC" 0
    assert_eq "override: version" "$PIN_OUT" "1.66.0"
}
test_bad_version_and_no_version() {
    pin_repo "$TEST_TMP/r" e2e/a.csproj "$(ref '<PackageReference Include="Microsoft.Playwright.NUnit" Version="$(PlaywrightVersion)" />')"
    pin pins_playwright "$TEST_TMP/r.git" HEAD
    assert_eq "property: rc" "$PIN_RC" 2
    assert_eq "property: bad-version message" "$PIN_ERR" 'bad Playwright version "$(PlaywrightVersion)" in e2e/a.csproj'
    pin_repo "$TEST_TMP/s" a.csproj '<Project>
  <ItemGroup>
    <PackageReference Include="Microsoft.Playwright.NUnit">
      <Version>1.64.1</Version>
    </PackageReference>
  </ItemGroup>
</Project>'
    local rev7; rev7="$(git -C "$TEST_TMP/s" rev-parse HEAD)"; rev7="${rev7:0:7}"
    pin pins_playwright "$TEST_TMP/s.git" HEAD
    assert_eq "no version: rc" "$PIN_RC" 2
    assert_eq "no version: nothing on stdout" "$PIN_OUT" ""
    assert_eq "no version: message" "$PIN_ERR" "$rev7 references Microsoft.Playwright but no version was found"
}
test_paths_with_space_and_newline() {
    pin_repo "$TEST_TMP/r" "with space/a.csproj" "$(ref '<PackageReference Include="Microsoft.Playwright" Version="1.64.1" />')"
    pin pins_playwright "$TEST_TMP/r.git" HEAD
    assert_eq "space: rc" "$PIN_RC" 0
    assert_eq "space: version" "$PIN_OUT" "1.64.1"
    pin_repo "$TEST_TMP/s" "new"$'\n'"line/a.csproj" "$(ref '<PackageReference Include="Microsoft.Playwright" Version="1.64.1" />')"
    pin pins_playwright "$TEST_TMP/s.git" HEAD
    assert_eq "newline: rc" "$PIN_RC" 0
    assert_eq "newline: version" "$PIN_OUT" "1.64.1"
    assert_eq "newline: no stderr" "$PIN_ERR" ""
}
test_status_2_never_exits_the_caller() {
    pin_repo "$TEST_TMP/r" global.json '{"sdk": {"version": ""}}' \
        a.csproj "$(ref '<PackageReference Include="Microsoft.Playwright" Version="x" />')"
    local out rc
    out="$(pins_sdk "$TEST_TMP/r.git" HEAD 2>/dev/null)"; rc=$?
    assert_eq "inside \$( ): status 2" "$rc" 2
    pins_playwright "$TEST_TMP/r.git" HEAD >/dev/null 2>&1; rc=$?
    assert_eq "plain call: status 2, and the shell carries on" "$rc" 2
    pins_sdk "$TEST_TMP/r.git" HEAD >/dev/null 2>&1; rc=$?
    assert_eq "plain call: sdk status 2, and the shell carries on" "$rc" 2
}
test_empty_sdk_version_is_an_error() {
    pin_repo "$TEST_TMP/r" global.json '{"sdk": {"version": ""}}'
    local rev7; rev7="$(git -C "$TEST_TMP/r" rev-parse HEAD)"; rev7="${rev7:0:7}"
    pin pins_sdk "$TEST_TMP/r.git" HEAD
    assert_eq "rc" "$PIN_RC" 2
    assert_eq "no empty pin printed" "$PIN_OUT" ""
    assert_eq "message" "$PIN_ERR" "global.json at $rev7 has an empty sdk.version"
}
test_same_version_twice_is_printed_once() {
    pin_repo "$TEST_TMP/r" a.csproj "$(ref '<PackageReference Include="Microsoft.Playwright.NUnit" Version="1.64.1" />')" \
        b.csproj "$(ref '<PackageReference Include="Microsoft.Playwright" Version="1.64.1" />')"
    pin pins_playwright "$TEST_TMP/r.git" HEAD
    assert_eq "rc" "$PIN_RC" 0
    assert_eq "once" "$PIN_OUT" "1.64.1"
}
test_nothing_pinned() {
    pin_repo "$TEST_TMP/r" README.md "nothing" a.csproj "$(ref '<PackageReference Include="Deque.AxeCore.Playwright" Version="4.14.0" />')"
    pin pins_sdk "$TEST_TMP/r.git" HEAD
    assert_eq "no global.json: rc 1" "$PIN_RC" 1
    assert_eq "no global.json: no output" "$PIN_OUT$PIN_ERR" ""
    pin pins_playwright "$TEST_TMP/r.git" HEAD
    assert_eq "no Playwright reference: rc 1" "$PIN_RC" 1
    assert_eq "no Playwright reference: no output" "$PIN_OUT$PIN_ERR" ""
    pin_repo "$TEST_TMP/s" global.json '{"msbuild-sdks": {"Foo": "1.0.0"}}'
    pin pins_sdk "$TEST_TMP/s.git" HEAD
    assert_eq "no sdk.version: rc 1" "$PIN_RC" 1
    assert_eq "no sdk.version: no output" "$PIN_OUT$PIN_ERR" ""
}
test_global_json_with_comment_is_refused() {
    pin_repo "$TEST_TMP/r" global.json '{
  // pinned by Renovate
  "sdk": {"version": "11.0.100"}
}'
    local rev7; rev7="$(git -C "$TEST_TMP/r" rev-parse HEAD)"; rev7="${rev7:0:7}"
    pin pins_sdk "$TEST_TMP/r.git" HEAD
    assert_eq "rc" "$PIN_RC" 2
    assert_eq "nothing on stdout" "$PIN_OUT" ""
    assert_eq "message" "$PIN_ERR" "global.json at $rev7 is not plain JSON"
}
test_rev_is_honoured_not_the_working_tree() {
    pin_repo "$TEST_TMP/r" global.json '{"sdk": {"version": "10.0.100"}}' \
        a.csproj "$(ref '<PackageReference Include="Microsoft.Playwright" Version="1.60.0" />')"
    local old; old="$(git -C "$TEST_TMP/r" rev-parse HEAD)"
    printf '%s\n' '{"sdk": {"version": "11.0.100"}}' > "$TEST_TMP/r/global.json"
    ref '<PackageReference Include="Microsoft.Playwright" Version="1.64.1" />' > "$TEST_TMP/r/a.csproj"
    git -C "$TEST_TMP/r" -c user.name=t -c user.email=t@t commit -q -am later
    pin pins_sdk "$TEST_TMP/r" "$old"
    assert_eq "old sdk at the earlier rev" "$PIN_OUT" "10.0.100"
    pin pins_playwright "$TEST_TMP/r" "$old"
    assert_eq "old playwright at the earlier rev" "$PIN_OUT" "1.60.0"
    pin pins_sdk "$TEST_TMP/r" HEAD
    assert_eq "new sdk at HEAD" "$PIN_OUT" "11.0.100"
}

run_tests
