# Container Verify Lane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A machine with rootless Podman (or Docker, or Apple's `container`) becomes a verify lane.
`agent-sync.sh verify --lane <name> <ref>` then builds and tests an exact SHA there, in an untrusted
runner container with no credentials and no outbound network during the build and tests. It
reports the same exit codes as today's sandbox verify.

**Architecture:**
- **Runtime layer:** a bash library, `scripts/lib/runtime.sh`, hides the container runtime behind
  `rt_*` functions.
- **Controller:** a per-machine script, `scripts/lane.sh`, installed as `chargehand-lane` for the
  lane's dedicated user. It is the only process that touches that machine's runtime. Per verify it:
  1. clones the SHA from the lane's own bare repo;
  2. creates a private network and starts the project's service containers;
  3. runs the runner image twice: restore with outbound network, then build and tests on the
     internal network only;
  4. judges the result from the summary lines the runner writes to an output directory.
- **Requester:** `agent-sync.sh` on the requesting machine pushes the SHA to the lane over SSH and
  calls the controller there.

**Tech Stack:**
- bash, jq, git, ssh;
- Podman / Docker / Apple `container` CLIs;
- the repo's bash test harness (`tests/lib.sh`, `tests/run.sh`, `tests/fake_*`).

**Spec:** `docs/superpowers/specs/2026-10-29-container-mode-design.md`, the dependency order steps
1–3. This plan is the first of several (see "Later plans" at the end).

## Global Constraints

- Runtime is a setting: `docker`, `podman` or `container` (Apple). Nothing outside
  `scripts/lib/runtime.sh` may call a runtime CLI directly.
- No Podman pods and no compose. A verify's containers share a per-run private network.
- The runner holds no credentials, gets no runtime socket and no host mounts other than its
  per-run checkout and output directories, and has outbound network **only in the restore phase**.
- Only the lane's controller talks to that machine's runtime. The requester reaches it over SSH
  as the lane's dedicated user, not an admin user.
- Images run by digest. Every verify records the digests it ran on.
- One suite at a time per machine: the controller holds a machine-wide lock for the whole verify.
- Exit codes match `chargehand-sandbox --verify`:
  - 0: passed;
  - 10: the build or a suite failed or timed out;
  - 3: another verify on this machine is running;
  - 4: the runtime is unavailable;
  - 2: usage or config;
  - anything else: could not run.
- Runner output is agent-authored text. The requester prints it through `agent_text`.
- Public repo: no host names, addresses or user names in code, tests, examples or docs. Lanes
  are configured in the owner's private config.
- Arm64 and amd64: the runner image builds for both. Nothing may assume one architecture.

## Review Focus

1. **A killed verify leaves containers and a network behind.** The next verify on that machine
   must remove them (by label) before starting, not fail on a name clash or a full disk. Test in
   Task 3.
2. **A service that never becomes ready** (a bad image, a crash loop). The verify must fail with
   "service <name> not ready after <n> s" and clean up, not hang until the overall timeout. Test in
   Task 3.
3. **A SHA the lane's repo doesn't have** (the requester forgot to push it). The controller exits
   2 with "commit <sha> not in <repo>", not a git stack trace. Test in Task 3.
4. **A runner image reference that is a tag, not a digest, in the lane config.** The controller
   refuses it (exit 2) so runs stay traceable. Test in Task 2.
5. **A runner that prints `Passed!` and exits 0 without running anything,** or prints nothing.
   The verdict needs at least one summary line per configured suite (the same guard as Croft's
   `dev/lib/test-summary.sh`), otherwise exit 10. Test in Task 4.

---

### Task 1: The runtime layer

**Files:**
- Create: `scripts/lib/runtime.sh`
- Create: `tests/fake_runtime.sh` (a fake CLI that records its argv and replays scripted output)
- Test: `tests/test_runtime.sh`

**Interfaces:**
- Produces (all read the lane's runtime from `$CHARGEHAND_RUNTIME`; each returns the CLI's exit
  code):
  - `rt_bin` prints the CLI name (`docker`, `podman`, `container`); dies on anything else.
  - `rt_network_create <name> <internal:yes|no>`, `rt_network_rm <name>`.
  - `rt_run <name> <image> <network> <cpus> <memory> [--mount host:ctr[:ro]]... [--env K=V]... [--workdir dir] [--label k=v]... -- <cmd...>`
    starts detached and prints nothing.
  - `rt_exec <name> -- <cmd...>`, `rt_wait <name>` (prints the exit code), `rt_logs <name>`,
    `rt_rm <name>` (force; succeeds if absent).
  - `rt_pull <image>`, `rt_image_digest <image>` (prints `sha256:...`).
  - `rt_ls_labelled <label=value>` prints container names; `rt_networks_labelled <label=value>`
    prints network names.

- [ ] **Step 1: Write the failing tests.** `tests/fake_runtime.sh`, installed in tests as
  `docker`, `podman` and `container` in `$TEST_TMP/bin`, appends `"$0 $*"` to `$TEST_TMP/rt.log`.
  It prints `$FAKE_RT_OUT_<verb>` if set and exits with `$FAKE_RT_RC` (default 0). Tests:
  - `test_podman_internal_network`: `rt_network_create v1 yes` logs `podman network create --internal --label chargehand=1 v1`.
  - `test_docker_run_flags`: `rt_run r1 img@sha256:aa net1 2 6g --mount /a:/w --mount /b:/o:ro --env X=1 --label chargehand.verify=s1 -- bash -lc go` logs exactly `docker run -d --name r1 --network net1 --cpus 2 --memory 6g -v /a:/w -v /b:/o:ro -e X=1 --label chargehand=1 --label chargehand.verify=s1 img@sha256:aa bash -lc go`.
  - `test_apple_container_uses_its_own_verbs`: with `CHARGEHAND_RUNTIME=container`, `rt_rm r1` logs `container delete --force r1`, and `rt_network_create v1 no` logs `container network create v1`. Apple's tool has no `--internal`, so `rt_network_create v1 yes` must die with "internal networks are not supported by the container runtime".
  - `test_unknown_runtime_dies`: `CHARGEHAND_RUNTIME=lxc rt_bin` exits non-zero with "unknown runtime \"lxc\"".
  - `test_rm_absent_is_ok`: `FAKE_RT_RC=1 rt_rm gone` returns 0.
  - `test_digest_is_parsed`: with `FAKE_RT_OUT_inspect='sha256:abc'`, `rt_image_digest x` prints `sha256:abc`.
- [ ] **Step 2: Run them to see them fail.** Run: `bash tests/test_runtime.sh`. Expected: FAIL (`rt_bin: command not found`).
- [ ] **Step 3: Implement `scripts/lib/runtime.sh`.**
  - **Docker and Podman** share one flag set. For Podman, `--internal` is a network-create flag;
    Docker's is the same.
  - **Apple `container`:**
    - verbs: `run -d --name`, `delete --force`, `network create|delete`, `logs`, `exec`, `inspect`,
      `image pull`;
    - no `--internal`: die loudly, never silently create a network with outbound access;
    - `wait`: poll `container inspect` for the status until it is stopped, then read the exit code.
  - **Labels:** every created object carries `--label chargehand=1` plus the caller's labels.
  - **Header:** a comment says the Apple verbs follow its documentation and are unverified until
    an Apple lane is added (spec: "to check during the build").
- [ ] **Step 4: Run the tests to see them pass.** Run: `bash tests/test_runtime.sh`. Expected: all `ok`.
- [ ] **Step 5: Commit.** `git commit -m "runtime.sh: one layer over docker, podman and Apple container" -- scripts/lib/runtime.sh tests/fake_runtime.sh tests/test_runtime.sh`

### Task 2: Lane configuration

**Files:**
- Create: `scripts/lib/lane.sh` (config reading only, sourced by the controller)
- Create: `examples/lane.json`
- Test: `tests/test_lane_config.sh`

**Interfaces:**
- Consumes: `harness.sh` (`die`, `HARNESS_CONFIG_DIR`).
- Produces:
  - `lane_get <jq-path> [default]` reads `$HARNESS_CONFIG_DIR/lane.json`.
  - `lane_project_get <project> <jq-path> [default]`.
  - `lane_check` validates the file, prints nothing on success, and dies with a named reason.
- File shape (`examples/lane.json`; every value an example):

```json
{
  "runtime": "podman",
  "cpus": 3,
  "memory": "14g",
  "repos_dir": "~/lane/repos",
  "work_dir": "~/lane/work",
  "verify_timeout_min": 90,
  "projects": {
    "example": {
      "runner_image": "registry.example/runner-dotnet@sha256:<digest>",
      "restore": "dotnet restore Example.slnx --locked-mode",
      "build": "dotnet build Example.slnx --no-restore -nologo -v quiet",
      "tests": ["dotnet test tests/Example.Tests --no-build"],
      "test_filter": "Passed!|Failed!|^\\s+Failed \\S+ \\[|Error Message",
      "summary_pattern": "^(Passed|Failed)!",
      "env": { "EXAMPLE_TEST_POSTGRES": "Host=db;Username=postgres;Password=postgres" },
      "services": [
        { "name": "db", "image": "docker.io/library/postgres@sha256:<digest>",
          "env": { "POSTGRES_PASSWORD": "postgres" },
          "ready": ["pg_isready", "-U", "postgres"], "ready_timeout_sec": 60 }
      ]
    }
  }
}
```

  The service password is a throwaway for a per-run database. It is not a secret.

- [ ] **Step 1: Write the failing tests:**
  - `test_valid_example_passes`: `lane_check` on the example file returns 0.
  - `test_tag_image_is_refused`: `runner_image` `"x/runner:latest"` makes `lane_check` die with
    "runner_image for example must be pinned by digest (…@sha256:…)". The same goes for a service
    image (Review Focus 4).
  - `test_unknown_runtime_is_refused`: `"runtime": "lxc"` dies with "runtime must be docker, podman or container".
  - `test_tests_list_required`: a project without `tests` dies with "example: tests must be a non-empty list".
  - `test_home_paths_expand`: `lane_get .repos_dir` prints `$HOME/lane/repos`.
- [ ] **Step 2: Run them to see them fail.** Run: `bash tests/test_lane_config.sh`. Expected: FAIL.
- [ ] **Step 3: Implement `scripts/lib/lane.sh`** with jq. The digest check is the regex `@sha256:[0-9a-f]{64}$`.
- [ ] **Step 4: Run them to see them pass.** Run: `bash tests/test_lane_config.sh`. Expected: all `ok`.
- [ ] **Step 5: Commit.** `git commit -m "lane.json: a lane's runtime, limits and per-project verify recipe" -- scripts/lib/lane.sh examples/lane.json tests/test_lane_config.sh`

### Task 3: The controller's verify

**Files:**
- Create: `scripts/lane.sh` (installed as `chargehand-lane`)
- Test: `tests/test_lane_verify.sh` (with the fake runtime)

**Interfaces:**
- Consumes: Task 1's `rt_*` and Task 2's `lane_*`.
- Produces: the command line `chargehand-lane verify --project <p> <sha>`.
  - **Exit codes:** as in Global Constraints.
  - **Stdout:**
    - the line `Verifying <sha7> <subject>` once it holds the lock (the same line
      `announce_start` in `agent-sync.sh` waits for);
    - the runner's filtered output;
    - at the end, `digests: runner=<sha256> <service>=<sha256> ...`.
  - **Repository:** the lane's bare repo for a project is `<repos_dir>/<project>.git`. The
    requester pushes to it (Task 5).

Behaviour, in order:
1. **Lock:** take the machine lock `flock -n` on `<work_dir>/suite.lock`. If it's busy, exit 3.
2. **Clean up:** remove containers and networks labelled `chargehand=1` that a killed run left
   behind (Review Focus 1). Only the lane uses `runtime.sh` on its machine, so that label is the
   lane's.
3. **Check the commit:** `git -C <repo> cat-file -e <sha>^{commit}`, else exit 2 with
   `commit <sha> not in <repo>` (Review Focus 3).
4. **Fresh checkout:** clone into `<work_dir>/run-<sha7>/src` with `core.hooksPath=/dev/null` (as
   the sandbox does), detached at the SHA. Create the output directory `<work_dir>/run-<sha7>/out`
   and the recipe directory `<work_dir>/run-<sha7>/recipe`.
5. **Network:** `rt_network_create chv-<sha7> yes`.
6. **Services:** start each service on that network, labelled. Poll `rt_exec <svc> -- <ready...>`
   once a second until `ready_timeout_sec`. On timeout, exit 10 with
   `service <name> not ready after <n> s`, after cleanup (Review Focus 2).
7. **Restore phase:** run the runner on the runtime's default network, with outbound access:
   - mounts: `src` read-write at `/work`, `recipe` read-only at `/recipe`, the per-project package
     cache `<work_dir>/cache/<project>` at `/cache`;
   - environment: `NUGET_PACKAGES=/cache/nuget`;
   - command: `chargehand-run restore`.
   A non-zero exit means `RESTORE FAILED`, exit 10.
8. **Test phase:** run the runner on `chv-<sha7>` only:
   - mounts: `src` at `/work`, `recipe` read-only at `/recipe`, the cache read-only, `out` at `/out`;
   - environment: the project's `env`;
   - command: `chargehand-run suites`.
   Then `rt_wait` and `rt_logs`.
9. **Verdict** (Task 4).
10. **Clean up:** remove the containers, the network and the run directory (an `EXIT` trap, so
    every path cleans up). Print the digests line.

The recipe reaches the runner through files the controller writes into `recipe/`: `restore`,
`build`, `tests` (one per line), `filter`, `summary`, `timeout_min`. It never goes on the command
line.

- [ ] **Step 1: Write the failing tests** (fake runtime; a temp bare repo with one commit):
  - `test_busy_lock_exits_3`: holding `suite.lock` from the test makes the controller exit 3 with "another verify is running on this machine".
  - `test_missing_commit_exits_2`: an unknown SHA gives exit 2 with `not in`.
  - `test_runner_phases_use_the_right_networks`: `rt.log` shows the restore `run` with no `--network chv-` and the suites `run` with `--network chv-<sha7>`. The suites run has no cache mount without `:ro`.
  - `test_service_never_ready_fails_and_cleans_up`: with `FAKE_RT_RC_exec=1` and `ready_timeout_sec: 2`, exit 10, the output contains `service db not ready after 2 s`, and `rt.log` ends with `rm` of `db` and `network rm chv-`.
  - `test_leftovers_are_removed_first`: with `FAKE_RT_OUT_ps='old-runner'`, the first runtime call removes `old-runner` before `network create`.
  - `test_no_socket_or_home_mounted_in_runner`: no `-v` argument of either runner `run` contains `.sock`, `$HOME` outside `work_dir`, or `/etc`.
- [ ] **Step 2: Run them to see them fail.** Run: `bash tests/test_lane_verify.sh`. Expected: FAIL.
- [ ] **Step 3: Implement `scripts/lane.sh`** following the order above. Stream the runner's
  output and keep the original exit code (the sandbox's `PIPESTATUS` pattern).
- [ ] **Step 4: Run them to see them pass.** Run: `bash tests/test_lane_verify.sh`. Expected: all `ok`.
- [ ] **Step 5: Commit.** `git commit -m "chargehand-lane verify: services and runner on a per-run network, restore then offline suites" -- scripts/lane.sh tests/test_lane_verify.sh`

### Task 4: The runner's entry point and the verdict

**Files:**
- Create: `images/runner/chargehand-run` (bash, copied into the runner image)
- Modify: `scripts/lane.sh` (the verdict)
- Test: `tests/test_runner_entry.sh`, plus additions to `tests/test_lane_verify.sh`

**Interfaces:**
- Consumes: the recipe files from Task 3.
- Produces:
  - `chargehand-run restore` runs `/recipe/restore` under `timeout`.
  - `chargehand-run suites` runs the build, then each test command under `timeout -k 30 <min>m`,
    filtered through `grep -E -A1 <filter>`. It writes the filtered lines to `/out/filtered.txt`,
    the full log to `/out/full.log`, and one line per suite to `/out/suites.txt`:
    `<index> <exit-code> <summary-line-count>`.
  - Exit codes: 0, or 10 on a build or suite failure or a timeout (`TIMED OUT after <n> min: <cmd>`).
- Verdict in `lane.sh`: pass only if the runner exited 0 **and** every suite in `suites.txt`
  has exit code 0 **and** exactly one line matching `summary_pattern`. Otherwise exit 10, naming
  the suite and the reason: `suite 2: no summary line` or `suite 1: 2 summary lines` (Review
  Focus 5).

- [ ] **Step 1: Write the failing tests:**
  - `test_runner_filters_like_the_sandbox`: the recipe's test command prints a mixed log
    (`Failed executing DbCommand`, `  Failed Ns.Cls.Name [5 s]`, `  Error Message:`, `   boom`,
    `Failed!  - Failed: 1, Passed: 2`). `filtered.txt` keeps the test name, `boom` and the summary,
    and drops `DbCommand`. These are the sandbox selftest's own fixture lines.
  - `test_runner_timeout_is_a_failure`: `timeout_min` of `0.02` with `sleep 5` gives exit 10 and `TIMED OUT after`.
  - `test_verdict_needs_one_summary_per_suite`: a runner that exits 0, with `suites.txt` = `1 0 0`, makes the controller exit 10 with `suite 1: no summary line`.
  - `test_verdict_passes_on_clean_summaries`: `suites.txt` = `1 0 1` and `2 0 1` with exit 0 gives controller exit 0.
- [ ] **Step 2: Run them to see them fail.** Run: `bash tests/test_runner_entry.sh && bash tests/test_lane_verify.sh`. Expected: FAIL.
- [ ] **Step 3: Implement** `images/runner/chargehand-run` and the verdict in `scripts/lane.sh`.
- [ ] **Step 4: Run them to see them pass.** Run: `bash tests/test_runner_entry.sh && bash tests/test_lane_verify.sh`. Expected: all `ok`.
- [ ] **Step 5: Commit.** `git commit -m "Runner entry point and a verdict that needs one summary line per suite" -- images/runner/chargehand-run scripts/lane.sh tests/test_runner_entry.sh tests/test_lane_verify.sh`

### Task 5: Requesting a verify on a lane

**Files:**
- Modify: `skills/verifying-and-accepting/scripts/agent-sync.sh` (the `verify` case)
- Modify: `scripts/lib/harness.sh` (add `lane_remote_get`)
- Test: additions to `tests/test_sync.sh` (a fake `ssh` and `git` remote)

**Interfaces:**
- Consumes: the controller's command line and output from Tasks 3–4.
- Produces:
  - `agent-sync.sh --project <p> verify [--wait] [--lane <name>] [ref]`. Without `--lane`,
    behaviour is unchanged.
  - Requester config `~/.config/chargehand/lanes.json`:
    `{ "<name>": { "ssh": "<ssh destination>", "repos_dir": "<path on the lane>" } }`.
    `lane_remote_get <name> <key>` reads it.
  - The verified record stays `$HARNESS_STATE_DIR/<p>/verified/<record>`. Its content becomes
    `<sha> lane=<name>` for a lane verify. `accept` reads only the first field, so old records
    still work.

Behaviour of `--lane`:
1. **Push:** `git push <ssh>:<repos_dir>/<p>.git <sha>:refs/verify/<sha>`.
2. **Verify:** `ssh -o BatchMode=yes <ssh> chargehand-lane verify --project <p> <sha>`, piped
   through `agent_text | announce_start` exactly like the sandbox path.
3. **Same exit-code mapping**, with exit 4's message saying "the lane's container runtime is
   unavailable".
4. **`--wait`** retries on exit 3, as now.

- [ ] **Step 1: Write the failing tests:**
  - `test_lane_verify_pushes_then_calls_the_controller`: a fake `ssh` logs its argv and prints
    `Verifying abc1234 x` then `Passed!  - Failed: 0, Passed: 1`, exit 0. Assert that the push
    went to the configured lane, that the ssh argv ends with
    `chargehand-lane verify --project demo <sha>`, that the output contains
    `verify of <sha7> started`, and that the record contains `lane=box`.
  - `test_lane_verify_strips_control_characters`: an ESC sequence in the fake output does not reach stdout.
  - `test_unknown_lane_dies`: `--lane nope` dies with `no lane "nope" in lanes.json`.
  - `test_accept_reads_a_lane_record`: after a lane verify, `accept` fast-forwards as with a sandbox record.
- [ ] **Step 2: Run them to see them fail.** Run: `bash tests/test_sync.sh`. Expected: the new tests FAIL, the old ones pass.
- [ ] **Step 3: Implement** in `agent-sync.sh`. The usage text (lines 2–18) gains the `--lane` line.
- [ ] **Step 4: Run them to see them pass.** Run: `bash tests/test_sync.sh`. Expected: all `ok`.
- [ ] **Step 5: Commit.** `git commit -m "agent-sync verify --lane: push the SHA to a lane and verify it there" -- skills/verifying-and-accepting/scripts/agent-sync.sh scripts/lib/harness.sh tests/test_sync.sh`

### Task 6: The runner image and a real-runtime test

**Files:**
- Create: `images/runner/Containerfile`
- Create: `images/build.sh`
- Create: `tests/test_lane_real.sh` (skips unless a rootless Podman socket exists and
  `HARNESS_TESTS_REAL_RUNTIME=1`)
- Create: `tests/fixtures/lane-demo/` (a tiny project whose "tests" are shell scripts printing summary lines)

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces:
  - `images/build.sh runner --sdk <dotnet-sdk-version> --playwright <version> --browsers "<list>" --tag <ref> [--push]`
    builds `linux/amd64` and `linux/arm64` into one manifest, and prints the manifest digest.
  - The image contains:
    - the .NET SDK at that version (official install script, `--version`, into `/usr/share/dotnet`);
    - Node and the Playwright CLI at that version, browsers installed with system deps;
    - git and `chargehand-run` at `/usr/local/bin/chargehand-run`;
    - a non-root user `runner` (UID 1000).

- [ ] **Step 1: Write the failing real-runtime tests** (they build a throwaway `alpine`-based test image from `tests/fixtures/lane-demo/Containerfile` with `chargehand-run`, not the full SDK image):
  - `test_real_pass`: the demo project's tests print `Passed!`; `chargehand-lane verify` exits 0.
  - `test_real_no_outbound_in_suites`: a demo test runs `wget -q -T 5 https://example.com` and
    prints `Passed!` only if it **fails**. Exit 0 proves the suites phase is offline.
  - `test_real_restore_has_outbound`: the restore recipe runs `wget -q -T 10 https://example.com`;
    a restore failure would make the verify exit 10, so exit 0 proves restore is online.
  - `test_real_service_reachable`: a service `db` (alpine running `nc -lk -p 5432`) is reached
    from a demo test by name `db:5432`.
  - `test_real_no_leftovers`: after each run, no container or network with the label `chargehand=1` remains.
- [ ] **Step 2: Run them to see them fail.** Run: `HARNESS_TESTS_REAL_RUNTIME=1 bash tests/test_lane_real.sh`. Expected: FAIL. Without the variable: one `  skip  ` line.
- [ ] **Step 3: Implement** `images/runner/Containerfile` and `images/build.sh`. Use
  `podman build --platform linux/amd64,linux/arm64 --manifest`, with the Docker equivalent
  `buildx --platform` when `CHARGEHAND_RUNTIME=docker`.
- [ ] **Step 4: Run them to see them pass.** Run: `HARNESS_TESTS_REAL_RUNTIME=1 bash tests/test_lane_real.sh`. Expected: all `ok`. Then `bash tests/run.sh`. Expected: `ALL PASSED`, or `PASSED, but N SKIPPED` only for the real-runtime file on a machine without Podman.
- [ ] **Step 5: Build the runner image for the reference project once.** Run:
  `images/build.sh runner --sdk 11.0.100-rc.3.26522.148 --playwright 1.64.1 --browsers "chromium firefox" --tag <owner's registry>/chargehand-runner-dotnet:11.0.100-rc.3`.
  Expected: a manifest digest printed, and both architectures listed in
  `podman manifest inspect`. Pushing needs the owner's registry login: stop and ask if it's absent.
- [ ] **Step 6: Commit.** `git commit -m "Runner image (both architectures) and real-runtime lane tests" -- images/ tests/test_lane_real.sh tests/fixtures/lane-demo`

### Task 7: Installing a lane, docs, and the first comparison

**Files:**
- Create: `skills/setting-up-agent-sandbox/scripts/setup-lane.sh`
- Modify: `skills/verifying-and-accepting/SKILL.md` (a "Verifying on a lane" section)
- Modify: `skills/setting-up-agent-sandbox/SKILL.md` (a "Container lane" section)
- Modify: `README.md` (a short "Container lanes" section under "The sandbox")
- Test: `tests/test_setup_lane.sh`

**Interfaces:**
- Produces: `setup-lane.sh --project <p>`, run **as the lane's dedicated user** (no sudo). It:
  - installs `scripts/lane.sh` and its libs to `~/.local/share/chargehand-lane/` and a
    `~/.local/bin/chargehand-lane` wrapper;
  - creates `repos_dir/<p>.git` (bare) and `work_dir`;
  - checks that the runtime answers (`rt_bin` plus a ping) and that `lane.json` passes
    `lane_check`;
  - prints the requester's `lanes.json` entry to add.

- [ ] **Step 1: Write the failing tests:**
  - `test_setup_creates_repo_and_wrapper`: in a temp HOME with the fake runtime and a valid `lane.json`, the bare repo and `~/.local/bin/chargehand-lane` exist, and the wrapper runs `verify` usage on `--help`.
  - `test_setup_refuses_bad_config`: a tag-pinned image makes setup exit 2 with `lane_check`'s message.
- [ ] **Step 2: Run them to see them fail.** Run: `bash tests/test_setup_lane.sh`. Expected: FAIL.
- [ ] **Step 3: Implement `setup-lane.sh` and write the docs sections.** The docs say:
  - **What the runner can and cannot do:** no credentials and no socket; outbound only during
    restore.
  - **The project-side requirement:** an external database through an environment variable,
    instead of Testcontainers.
  - **Trusted-only categories don't run on a lane:** for the reference project, `Container` and
    `ReadyToRun`.
- [ ] **Step 4: Run all tests.** Run: `bash tests/run.sh`. Expected: `ALL PASSED` (the real-runtime file may skip, and says so).
- [ ] **Step 5: Commit.** `git commit -m "setup-lane.sh and docs for container verify lanes" -- skills/ README.md tests/test_setup_lane.sh`
- [ ] **Step 6: First comparison (operational, needs the owner).** Once these exist:
  - the owner's steps: the dedicated user with rootless Podman on the box, the extra RAM, the
    runner image pushed;
  - the reference project's external-database brief, accepted.
  Then run `agent-sync.sh --project croft verify --lane box <ref>` and
  `agent-sync.sh --project croft verify <ref>` on the same SHA. Record both summaries, wall times
  and the box's peak memory (`podman stats --no-stream` sampled during the run) in the retro.
  - **Expected:** identical pass/fail and suite counts. If they differ, debug before anyone
    relies on the lane.
  - **Until the E2E prerequisite lands**, the lane's recipe runs build, API and Web suites only;
    the E2E needs the project-side change described under "Dependencies".

## Dependencies outside this plan

- **Croft brief (separate, in the Croft repo):**
  - `PostgresDatabaseFixture` / `SharedPostgresContainer` use `CROFT_TEST_POSTGRES` when set,
    with Testcontainers unchanged when unset.
  - `start-local.sh --e2e` accepts the Postgres host and the mock IdP's URL from the environment,
    instead of `localhost:5432` / `localhost:5556`, so the E2E can run in the runner against
    service containers.
  - Without the first part, the lane can run the build only. Without the second, it can't run E2E.
- **Owner steps (sudo):**
  - the box's dedicated user with rootless Podman;
  - the extra RAM;
  - a registry login for pushing the runner image;
  - adding the box to the requester's `lanes.json` and `~/.ssh/config`.

## Later plans (written when this one lands)

2. **Implementer and OpenCode containers.** Implementers become watched headless sessions in
   their own containers, push to the box's mirror, and get a scoped login (the spec's stop point
   if Claude Code has none).
3. **The orchestrator container and the night:**
   - hardware-key passthrough and the duplicate vault;
   - the queue and brief states on disk;
   - the merge gates;
   - phone questions with a timeout;
   - release, canary and the morning summary.
4. **Updating the images:** image definitions in a repo, CI builds for both architectures,
   rollout between briefs, proving each lane with a verify of `main`, and rollback.
5. **The multi-lane scheduler:** several machines at once, lanes coming and going, the desktop
   and the Mac as lanes.
