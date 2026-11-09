# Brief lane-image-pins: lane runner images follow the project's own version pins

Chargehand has no AGENTS.md: read README.md ("Tests"), `skills/setting-up-agent-sandbox/SKILL.md`
("Container lane") and `skills/verifying-and-accepting/SKILL.md` ("Verifying on a lane") first.
One commit per item, TDD (the failing test first, watched failing for the right reason),
break-it-once for every key test (named below; report it in the commit message), and
`bash tests/run.sh` once per item after the last change, its summary line quoted in the commit.
Every SKILL.md change gets a dated line in `tests/skills/<skill>.md` (fact change, no new
pressure test). Never download toolchains, packages or images yourself: nothing here needs a
real image build.

## Why

At the moment the owner keeps three versions current by hand for each lane runner image:
- the Debian base (`FROM docker.io/library/debian:trixie-slim` in `images/runner/Containerfile`,
  a moving tag);
- the .NET SDK (`images/build.sh --sdk`);
- Playwright (`--playwright`).

The project already pins the second and third. Croft's `global.json` has `"version":
"11.0.100-rc.3.26522.148"`, and `tests/Croft.Web.E2E/Croft.Web.E2E.csproj:31` has
`Microsoft.Playwright.NUnit` `1.64.1`. Croft's Renovate keeps both current. When Renovate bumps
either one, the lane carries on with the old image. The verify then fails deep in restore,
build or a browser test with an error that does not say "rebuild the image".

After this brief:
1. `build.sh` reads the SDK and Playwright versions from the project's own repo.
2. The image records the versions it was built with.
3. A verify whose commit pins different versions stops before any container runs, says which
   version differs, and gives the rebuild command.
4. Renovate keeps the base image pinned by digest and merges digest updates itself.

## Item 1: `scripts/lib/pins.sh`, the project's pins at a commit

**Now:** nothing reads them. `build.sh` takes `--sdk` and `--playwright` by hand.

**Do:** add a new library, sourced after `harness.sh`. It reads files with
`git -C REPO show REV:<path>` and lists them with `git -C REPO grep -z -l … REV`, so a bare repo
works (the lane's `<repos_dir>/<p>.git` is bare) and nothing is checked out. `-z` keeps paths
verbatim: they come from an untrusted commit, so a quoted or newline-bearing path must not break
the parsing. Values from the commit are only ever compared and printed (quoted), never evaluated.

**Contract:** the functions never `die`. They print the value on stdout and return 0, return 1
with nothing printed when nothing is pinned, or return 2 with one line on stderr naming the
problem (no hint about flags: each caller adds its own). `build.sh` turns 2 into a usage-style
death; `verify` turns it into exit 5 (Item 3).

- `pins_sdk REPO REV`:
  - prints `.sdk.version` of `global.json` at REV;
  - status 1, nothing printed, when there is no `global.json` or it has no `sdk.version`;
  - returns 2 with `global.json at <rev7> is not plain JSON` when jq cannot parse it. `dotnet`
    allows comments there; we do not strip them.
- `pins_playwright REPO REV`:
  - prints the one version of `Microsoft.Playwright` or `Microsoft.Playwright.<Word>`
    (NUnit, MSTest, Xunit… They release in lockstep with the driver; the existing build already
    relies on that).
  - Sources: `PackageReference` and `PackageVersion` elements, in `*.csproj`, `*.props` and
    `*.targets` files at REV, parsed per element, not per line: read each file whole (`git show`),
    so an element split over several lines counts. The package is named by `Include` or `Update`;
    the version by a `Version` or `VersionOverride` attribute, in any attribute order. An element
    without either attribute contributes nothing (with central package management the version is
    on the `PackageVersion` element in `Directory.Packages.props`).
  - The package referenced but no version found anywhere: return 2 with
    `<rev7> references Microsoft.Playwright but no version was found` (never a silent "not
    pinned", which would skip the lane's check for exactly the repos that need it).
  - Other packages whose name merely contains "Playwright" do not count
    (`Deque.AxeCore.Playwright` `4.14.0` must not match).
  - Several distinct versions: return 2 with
    `Playwright versions differ at <rev7>: 1.64.1 (path/a.csproj), 1.63.0 (path/b.csproj)`.
  - None: status 1, nothing printed.
  - A version that is not `^[0-9]+\.[0-9]+\.[0-9]+$` (e.g. `$(PlaywrightVersion)`) returns 2
    with `bad Playwright version "<v>" in <path>` (the same check `build.sh` makes).

**Tests:** a new file, `tests/test_pins.sh`. Each test builds its own throwaway git repo
(`git init`, files, one commit) in `$TEST_TMP`, then makes a bare clone of it. Cases:
- Croft's real shapes. `global.json` with `rollForward` gives `11.0.100-rc.3.26522.148`. A csproj
  with both `Microsoft.Playwright.NUnit` `1.64.1` and `Deque.AxeCore.Playwright` `4.14.0` gives
  exactly `1.64.1`. Both are read from the bare clone at the commit's SHA, and from a working
  tree at `HEAD`.
- `PackageVersion Include="Microsoft.Playwright" Version="1.65.0"` in `Directory.Packages.props`
  gives `1.65.0`.
- `Version` before `Include` gives the version.
- Two files with 1.64.1 and 1.63.0 return 2, and the message names both files.
- A `PackageReference` split over three lines (`Include` on one, `Version` on another) gives its
  version; `Update="Microsoft.Playwright" VersionOverride="1.66.0"` gives `1.66.0`.
- `Version="$(PlaywrightVersion)"` returns 2 with the bad-version message; a reference with no
  version anywhere returns 2 with the no-version message.
- A file whose path has a space and one with a newline in it are both read (the `-z` listing).
- The functions run inside `$( )` and as plain calls: a 2 never exits the caller's shell.
- Two files that both say 1.64.1 give `1.64.1` once.
- No `global.json`, and no Playwright reference: status 1 and empty output each.
- A `global.json` with a `//` comment returns 2 with the message above.
- A file changed in a later commit is read at the earlier REV with its old value. This proves
  that REV is honoured, not the working tree.

**Break-it-once:** drop the `.<Word>` suffix from the package match. The Croft-shape test must
then fail with status 1. Separately, widen the match to any name containing `Playwright`. The
same test must then fail (4.14.0 joins and the versions differ).

## Item 2: `build.sh --from`, and the image records its versions

**Now:** `images/build.sh runner --sdk <v> --playwright <v> --browsers "<list>" --tag <ref>`.
The built image does not say what it contains.

**Do:**
- `build.sh` gains `--from <repo> [--rev <rev>]`, with REV defaulting to `HEAD`. It fills
  `--sdk` and `--playwright` from `pins_sdk` and `pins_playwright`. Rules:
  - `--from` together with `--sdk` or `--playwright` is a usage error (exit 2):
    `--from reads the versions; do not pass --sdk or --playwright with it`.
  - `--rev` without `--from` is a usage error (exit 2).
  - A pin function's status 2 dies (exit 2) with its message plus `(pass --sdk / --playwright
    by hand)`.
  - A pin that is missing (status 1) dies (exit 2) with
    `<repo> at <rev7> pins no .NET SDK (global.json sdk.version)`, or
    `… no Microsoft.Playwright version`.
  - The existing version checks still apply to values that come from `--from`.
- `build.sh` prints the versions it used on stderr before building, on every path:
  `build.sh: .NET SDK 11.0.100-rc.3.26522.148, Playwright 1.64.1`, followed by
  ` (from <repo> at <rev7>)` only with `--from`.
- Update the usage text (lines 4–15, and the `sed` range in `usage()` if it grows) and the exit
  line: 2 now also covers a repo whose pins cannot be read.
- `images/runner/Containerfile` gets one `LABEL`, after the `ARG` lines:
  ```
  LABEL org.chargehand.runner.dotnet-sdk="$DOTNET_SDK_VERSION" \
        org.chargehand.runner.playwright="$PLAYWRIGHT_VERSION" \
        org.chargehand.runner.browsers="$PLAYWRIGHT_BROWSERS"
  ```

**Tests:** in `tests/test_images_build.sh`, against the fake runtime as now:
- `--from` with a throwaway repo (Item 1's helper; share it through `tests/lib.sh` if both files
  need it) passes `DOTNET_SDK_VERSION=` and `PLAYWRIGHT_VERSION=` with the repo's values in the
  logged build command.
- `--rev` picks an older commit's values.
- `--from` with `--sdk` exits 2 with the message.
- A repo without `global.json` dies with the message.
- The stderr line names both versions, with and without `--from`.
- `--rev` without `--from` exits 2.
- A repo whose `global.json` says `"version": "banana"` dies with `bad SDK version "banana"`
  (the existing check applies to pinned values).

The Containerfile `LABEL` is checked statically, as no test builds the real runner image. A test
reads `images/runner/Containerfile`. It asserts that each of the three label keys is set from
its own `ARG`, and that the `LABEL` line comes after the `ARG` lines. (Before them the values
would be empty.) Item 3's real-runtime test covers reading labels from a real image.

**Break-it-once:** have `--from` ignore `--rev` (always `HEAD`). The `--rev` test must fail.
Separately, move `LABEL` above the `ARG` lines. The static test must fail.

## Item 3: verify refuses an image that does not match the commit's pins (exit 5)

**Now:** `scripts/lane.sh` `verify` runs whatever image `runner_image` names. A mismatch shows
up later as a restore, build or browser failure (exit 10, blamed on the commit).

**Do:**
- `scripts/lib/runtime.sh`: new `rt_image_label IMAGE KEY`. It prints the label's value, empty
  when the label is not set.
  - podman and docker: `image inspect --format '{{json .Config.Labels}}' IMAGE`, then jq. A
    `null` map gives empty.
  - `container` (Apple): return 3 and print nothing. No inspect output from that runtime is
    recorded in this repo, and guessing its JSON shape is how a check silently passes.
- `scripts/lane.sh` `verify`: a new step right after the commit is resolved in the lane's repo
  (`sha` and `sha7` set), **before** the `Verifying <sha7> <subject>` line, so a refused run never
  looks started to `agent-sync.sh`. Step 2's sweep of leftovers has run by then; no container of
  this run has started.
  1. Read `pins_sdk` and `pins_playwright` for `$repo` at `$sha`. A status 2 from either: print
     `chargehand-lane: <sha7>'s version pins cannot be read: <its message>` and exit 5.
  2. If neither is pinned, skip the check (a project that is not .NET).
  3. If `rt_image_label` returns 3 at any read (the Apple `container` runtime): print
     `chargehand-lane: warning: runtime container: the runner image's versions are not checked`
     and go on. This comes first: no pull, no exit 5 on that runtime.
  4. Make sure the image is local: `rt_image_label` fails otherwise →
     `rt_pull "$runner_image"` once, then read again. It is pinned by digest, so the pull is
     exactly the image `rt_run` would pull.
  5. Read the image's `org.chargehand.runner.dotnet-sdk` and `org.chargehand.runner.playwright`.
  6. When a pinned version differs from the label, or the label is empty (an image built before
     this brief), print to stderr exactly (values substituted; `<…>` in backticks below stays
     literal, as the owner fills it in):
     ```
     chargehand-lane: the runner image does not match <sha7>'s pins:
       .NET SDK: image <label, or "not recorded">, commit <pin> (global.json)
       Playwright: image <label, or "not recorded">, commit <pin>
     Rebuild it from the lane's repo:
       images/build.sh runner --from <repos_dir>/<project>.git --rev <full sha> --browsers "<browsers>" --tag <registry/repo:tag> --push
     then set projects.<project>.runner_image in lane.json to <registry/repo>@<the digest it prints>.
     ```
     `<repos_dir>/<project>.git`, `<full sha>` and `<project>` are the real values. `<browsers>` is
     the image's `org.chargehand.runner.browsers` label; on an image without it, the literal text
     `<the browsers the project's tests need>` (never a guessed `chromium`).
     `<registry/repo:tag>` and `<registry/repo>` stay literal: the owner chooses the tag.
     List only the version lines that differ (both when both differ). Then exit 5.
- Header of `lane.sh` (lines 8–11): add `5 the runner image does not match the commit's pinned
  .NET SDK or Playwright version, or those pins cannot be read (see the message)`. `usage()`
  prints `sed -n '4,13p'`: extend the range to the header's new last line.
- `scripts/lib/runtime.sh`'s header says every function returns the CLI's exit code: note the
  exception (`rt_image_label`, 3 on `container`).
- `skills/verifying-and-accepting/scripts/agent-sync.sh`, in the exit `case`: add `5)` before
  `*)`. It prints `chargehand: verify not run: the lane's runner image does not match the
  commit's pins, or they cannot be read (see above)` and exits 5. It does not depend on `--lane`:
  only the lane controller exits 5. Today 5 would fall into "could not reach or run the
  lane controller". Also update the "Same exit codes" header line.

**Tests:**
- `tests/test_lane_verify.sh`, fake runtime. Set `FAKE_RT_OUT_image` to the inspect JSON; the
  fake's verb is the first argument, `image`. Throwaway repos come from Item 1's helper.
  - Labels equal to the pins: verify goes on, and `rt.log` shows the restore `run`.
  - SDK differs: exit 5. stderr equals the whole message above with this test's real values
    (assert the full text, line by line), has no `Playwright:` line, and has no `Verifying` line;
    `rt.log` has no `run`.
  - Playwright differs: exit 5, and the Playwright line only.
  - No labels (`{}` and `null`): exit 5 with `not recorded` on both lines and the literal
    `<the browsers the project's tests need>` in the hint.
  - A `global.json` with a `//` comment, and two Playwright versions across files: exit 5 with
    `cannot be read` and the pin function's message; no inspect call.
  - `--help` output includes the exit-5 line (the `usage()` range).
  - A commit with neither pin: no inspect call, and verify goes on.
  - The image is not local (inspect fails once, then succeeds): exactly one `pull` with the
    pinned reference is logged before the second inspect.
  - `CHARGEHAND_RUNTIME=container`: the warning line, no `pull`, and verify goes on.
- `tests/test_runtime.sh`: `rt_image_label`:
  - podman and docker print a set label;
  - a missing label and `null` labels print empty;
  - `container` returns 3.
- `tests/test_sync.sh`: extend `test_lane_verify_exit_codes_and_wait` so that a fake ssh
  returning 5 gives exit 5 and the new message, not "could not reach".
- `tests/test_lane_real.sh` (opt-in, `HARNESS_TESTS_REAL_RUNTIME=1` and a rootless Podman
  socket):
  - the demo image it builds (from the test's own context in `$REAL_TMP/ctx`, not the runner
    Containerfile) gets the three `org.chargehand.runner.*` `LABEL`s. This is the only place the
    `{{json .Config.Labels}}` template meets real Podman, so it must run before deploying;
  - one new case gives the demo repo a `global.json` that pins another SDK and expects exit 5
    from real Podman.

  If your sandbox has no Podman socket, say so in the report: the owner runs it.

**Break-it-once:** make the comparison always succeed. The SDK-differs test must fail. Delete the
`5)` branch in `agent-sync.sh`. The `test_sync.sh` case must fail.

## Item 4: Renovate pins the base image and merges digest updates

**Now:** `renovate.json` is only `config:recommended`. `FROM docker.io/library/debian:trixie-slim`
moves silently, so two builds a week apart differ, and nothing says when a rebuild would pick up
security fixes.

**Do:** add `packageRules` to `renovate.json`:
```json
"packageRules": [
  { "matchManagers": ["dockerfile"], "matchFileNames": ["images/**"], "pinDigests": true },
  { "matchManagers": ["dockerfile"], "matchFileNames": ["images/**"], "matchUpdateTypes": ["digest", "pinDigest"],
    "automerge": true, "automergeType": "pr", "ignoreTests": true }
]
```
- Renovate's `dockerfile` manager matches `Containerfile` by default. That is the owner's
  understanding; if you cannot confirm it from material already in the repo, say so rather than
  adding a `managerFilePatterns` entry on a guess.
- `ignoreTests`: this repo has no CI, so a PR would otherwise never be "green". A base digest
  bump is only built when the owner runs `build.sh`, and that build is its test. Put this reason
  in a `"description"` on the rule.
- `matchFileNames` keeps test fixtures and examples out: only the images Chargehand ships.
- Major and minor updates (a new Debian release, e.g. `forky`) are not automerged; they stay
  ordinary PRs.

**Tests:** config, not code, so show evidence instead:
- `jq -e` on the file in the commit message (valid JSON, both rules present);
- a test in `tests/test_images_build.sh` asserting that the `FROM` line names a tag, with or
  without `@sha256:`, so Renovate's pin PR keeps the suite green.

What the owner will see after the merge: a "Pin dependencies" PR for the Debian base from
Renovate, merged by itself. Say so in the report; you cannot observe it.

## Item 5: docs

- README "Container lane" and `skills/setting-up-agent-sandbox/SKILL.md` "Container lane":
  - building the runner image is now `images/build.sh runner --from <project repo> --browsers
    "<list>" --tag <ref> --push`;
  - the image records its versions;
  - after a project's Renovate bumps its SDK or Playwright, the next lane verify exits 5 with
    the rebuild command, and the owner rebuilds and updates `runner_image`;
  - an image built before this brief has no labels, so expect one rebuild after deploying it;
  - the Debian base updates through Renovate, and a rebuild picks it up.
- `skills/verifying-and-accepting/SKILL.md` "Verifying on a lane": exit 5 means "verify not run:
  ask the owner to rebuild the runner image", never "the commit failed".
- A line for each changed skill in `tests/skills/`.

## Final

- `bash tests/run.sh` from a clean tree; quote the summary line.
- `HARNESS_TESTS_REAL_RUNTIME=1 bash tests/test_lane_real.sh` if a rootless Podman socket is
  available; otherwise say it was not run.
- Then the final review (an external reviewer, not you).

## Out of scope

- Rebuilding or pushing images automatically (a CI job or a lane timer), and updating
  `lane.json` automatically.
- Telling a stale Debian base apart in verify (only the SDK and Playwright are checked).
- `rollForward`-aware SDK matching: equal versions only. A lane serving branches with different
  pins needs an image per pin set.
- Reading labels on the Apple `container` runtime (needs a recorded inspect output from a Mac).
- Any change in the project repos (Croft, tswap), their Renovate configs or their lanes'
  `lane.json`.
