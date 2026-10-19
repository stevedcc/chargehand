# Review: scripts under real failure (2026-10-19)

Scope: every script in `scripts/lib/` and `skills/*/scripts/`, `tests/`, read against README.md and
every SKILL.md. Checked for: `set -euo pipefail` pitfalls, quoting and word splitting, races (two
watchers, two briefs, concurrent verify and fetch), provider errors (402, 429, quota), a suspended
host or a stalled tool call, the API lock, clock and timeout handling, exit-code contracts between
scripts and skills, and what `tests/run.sh` does and does not catch.

Method: code reading, `bash tests/run.sh`, and scratch experiments against the repo's own fake API
and throwaway git repositories (git 2.43, bash 5.2, jq 1.7, Ubuntu 24.04). No OpenCode server,
bubblewrap, Podman or YubiKey here: anything that needs them is marked **unverified**.

Known incidents checked against the design: (1) a provider's 402 errors looked like a session going
idle; (2) a host suspend left a shell call hanging and the watcher only noticed at its timeout;
(3) a subagent stalled mid-reasoning for 10+ minutes with no error. Incident 1 is still open
(finding 1). Incident 2 is handled on the watcher path and not on the verify path (finding 10).
Incident 3 is caught at the 15-minute stall threshold and cannot be caught sooner with the data the
watcher reads (finding 2 says what data would).

---

## Findings

### 1. Critical: the brief's own session is never checked for a provider error, and an errored idle exits 0

`skills/running-briefs/scripts/watch.sh:60-74`, `skills/running-briefs/SKILL.md:42`.

The root session branch (`if [ "$s" = "$r" ]`) looks only for an `idle` message; the `.error`
check runs only for children. On idle, any `outcome` exits 0, and the skill's table sends exit 0
straight to `verifying-and-accepting`.

Scenario (incident 1): the implementer's provider starts returning 402 "insufficient funds". The
parent's next model call fails; OpenCode writes an assistant message with `error` on the root
session. Reproduced with the fake API:

- error on the root, no idle yet: watcher reports nothing (`TIMEOUT` with max 0; in production
  `STALLED` after 15 min, exit 7, whose skill row says to interrupt children for a hung model
  request, which is the wrong diagnosis);
- error on the root, then idle with `outcome=error`: **exit 0, "07a IDLE: outcome=error"**, and the
  orchestrator goes to fetch, read and verify a brief that stopped at item 2.

With a 402 nothing the orchestrator can send to that session helps: its model is pinned and the
provider refuses; a "continue" prompt errors again and the loop repeats (see finding 7).

Fix: check `.data[0].error` for the root as well and exit with its own code (e.g. 9 `BRIEF SESSION
ERROR`, printing error type, message and time, as for children); on idle, exit 0 only when the
outcome is a success value and the newest assistant message has no error, otherwise exit 9. In the
skill: row 0 reads the outcome; row 9 says "quota/402: resume on the fallback model (finding 7);
other errors: read the message, then prompt". Add both fixtures to `tests/test_watch.sh`.

### 2. Important: a failed message fetch is skipped silently, so every failure except "session list down" degrades to "TIMEOUT, nothing happened"

`watch.sh:57` (`msgs="$(oc_api ...)" || continue`), `watch.sh:77` (`newest -gt 0`).

Reproduced (exit 1, `TIMEOUT`, no other output) for: the root's message list empty (launch prompt
never arrived, finding 3); the root id no longer on the server (server data reset); every
per-session message fetch failing (404, 401 after a password change, curl 28 on a slow server, API
lock timeout 75 under the wrapper form). The skill's row 1 says "restart the watcher", so the
orchestrator restarts a blind watcher every 115 minutes for the rest of the day. This is the
"noticed only at its timeout" shape of incident 2, reachable without a suspend.

The stall check also has no finer signal than message `time.created`: a child "stalled
mid-reasoning" (incident 3) and a child streaming a long reply look identical for 15 minutes.

Fix: count a failed or empty root message fetch as a miss (three in a row: exit 8 with the reason,
or a distinct code); never let a tag finish a poll with `newest=0`. Use the session list's own
`time.updated` (already fetched once per poll, already used by `models_busy`) for the stall check:
it moves on every part write, so a streaming step is distinguishable from a dead one, and the
per-session message fetches shrink to the root (idle) and sessions whose `updated` changed. Pass a
`limit` on message lists: a six-hour brief's unbounded list is parsed in full every minute per
session.

### 3. Important: `start-brief.sh` records the session before the launch prompt is confirmed

`skills/running-briefs/scripts/start-brief.sh:76-81`.

`sid` is written at line 78; the prompt POST at line 80 can fail (server 5xx, curl 28 after 30 s,
lock timeout). Reproduced: exit 2 "sending the launch message failed", `sid` left pointing at a
session that never received the brief; a relaunch is refused ("already has a session; remove sid to
launch again"); `watch.sh` on that tag runs silently to timeout (finding 2). Removing `sid` orphans
the session (and its cost, since `brief-cost.sh` reads only `sid` and `sid.prev*`).

Fix: write `sid` last, after the prompt is accepted; on prompt failure print the session id and
write `sid.failed-<n>` so cost and a later resume can find it. Combine with finding 7's `--resume`.

### 4. Important: `&` in a substituted value corrupts the launch message (bash 5.2)

`start-brief.sh:45,50,54-55`; `start-review.sh:50`; `scripts/lib/render.sh:18`.

bash 5.2 enables `patsub_replacement` by default: in `${msg//pat/$rep}` with `$rep` unquoted, every
`&` in the value is replaced by the matched text. Reproduced with `--dry-run`:

- `"e2e_command": "dev/start.sh && dev/run-e2e.sh ..."` becomes
  ``Run E2E with `dev/start.sh {E2E}{E2E} dev/run-e2e.sh ...` `` in the message the agent receives;
- `--extra "Q&A: ask before touching Program.cs"` becomes `Q{EXTRA}A: ...`.

The project JSON is the owner's; `&&` in a command is ordinary. The agent then runs a broken E2E
command or asks what `{E2E}` means. `start-review.sh:50` has the same bug through `sed`: a branch
named `feat/a&b` (legal in git) renders as `feat/a{BRANCH}b`, and a `|` in any value breaks the
expression. `render_rules` is exposed only through tool names and is fine in practice.

Fix (both verified): quote the replacement, `"${msg//\{E2E\}/"$e2e_text"}"`, or put
`shopt -u patsub_replacement 2>/dev/null || true` next to `set -euo pipefail` in every script. In
`start-review.sh` replace the `sed` with the same bash substitutions. Add `&&` to the test
project's `e2e_command` in `tests/test_start_brief.sh`.

### 5. Important: `accept` misreports two unrelated failures as "not a fast-forward"

`skills/verifying-and-accepting/scripts/agent-sync.sh:47-48`.

`git merge --ff-only -q "$sha" 2>/dev/null || die "... not a fast-forward ... ask the agent to merge
origin/<target> into it, then fetch and verify again"`. Any merge failure gets that diagnosis.
Reproduced with a branch that *is* a fast-forward (`merge-base --is-ancestor` true):

- an untracked `new.cs` in the owner's worktree at a path the agent's commit adds (the dirty-tree
  check uses `--untracked-files=no`): git says "untracked working tree files would be overwritten";
  accept says "not a fast-forward";
- a stale `.git/index.lock` (an IDE's git status, an interrupted command): same wrong message.

The skill then has the orchestrator tell the agent to merge the target, which costs a review round,
a fetch, a verify and (by `verified` bookkeeping) a second accept, and does not fix the cause.

Fix: test `git merge-base --is-ancestor "$target" "$sha"` first and keep the merge message for that
case only; run the merge without `2>/dev/null` and die with git's own text otherwise. Test both
cases in `tests/test_sync.sh`.

### 6. Important: `integrate.sh` fails silently with an undocumented exit code when its fetch fails, and concurrent fetches fail often

`skills/running-briefs/scripts/integrate.sh:18`; `agent-sync.sh:28`.

`bash agent-sync.sh fetch >/dev/null 2>&1` under `set -e`: when the fetch fails, the script exits
with git's status (reproduced: 128, no output at all). The header and the skill document 0/1/2 and
"exits 1 on a conflict". The realistic trigger: the skill has `integrate.sh` running every ten
minutes in the background while the orchestrator runs `agent-sync.sh fetch` for a verify. Two
fetches into the same owner repo fail about half the time under contention (30 paired runs: 29 of
60 failed with "cannot lock ref 'refs/remotes/agent/main'"); the `fetch` side dies with git's
message, the `integrate` side dies silently.

Fix: `|| die "fetch failed"` with stderr kept; serialise fetches with `flock` on
`$HARNESS_STATE_DIR/<project>/repo.lock` in both scripts (one lock around the fetch, held
seconds). `integrate.sh` has no tests; add the clean, conflict and fetch-failure cases.

### 7. Important: there is no resume path for a brief whose parent session died

`start-brief.sh:31`; `skills/running-briefs/SKILL.md` (no row for it); README "Interrupted sessions
resume ... the running-briefs skill says how to restart a stuck parent" and "the session carries on
with the next [plan]".

The fallback in the launch message is advisory: a parent can give a subagent another model, but
cannot change its own pinned model once the provider refuses it (402, quota, auth). After finding
1's event the only way on is a new session, and `start-brief.sh` refuses while `sid` exists;
removing `sid` drops the earlier session from cost. `brief-cost.sh` already expects `sid.prev*`
("a resumed brief ... keeps its earlier sessions"), but only `start-review.sh` ever writes them.
The implementer rules invest in `state.md` for exactly this case, and nothing on the orchestrator
side uses it.

Fix: `start-brief.sh --resume [--role implementer=<fallback>]`: rotate `sid` to `sid.prev<n>` as
`start-review.sh` does, launch with the same permissions and a message "continue brief X from
`.worktrees/<tag>` and its `state.md`; items done are committed", and record the switch in
`launch.txt`. Skill: a row for exit 9 (finding 1) that names it. **Unverified:** whether
`POST /api/session/<sid>/prompt` accepts a per-message `model`; if it does, a resume without a new
session is possible and cheaper.

### 8. Important: one provider error blocks a `max_busy_sessions` provider for six hours

`scripts/lib/models.sh:65-75` (`models_busy`), `models_pick`.

"Busy" is "no idle message since the last prompt" among sessions updated in the last six hours. A
session that died on a provider error has no idle message (that is finding 1's shape, and also a
server restart mid-turn). Reproduced: one dead session on provider `z` with `max_busy_sessions: 1`
makes `models_pick` skip `z` for the implementer and take the fallback, with the only notice on
stderr. A 429 or 402 at 09:00 therefore moves every brief and review until 15:00 to the second
plan, which is probably the one the owner wanted to spare.

Fix: a session whose newest assistant message has `.error` is not busy; cap "busy" by
`time.updated` within the last 20 minutes rather than six hours (a busy session updates
constantly); print the chosen model on stdout in `start-brief.sh` as `start-review.sh` does.

### 9. Important: a pending permission in any session on the server stops the watcher

`watch.sh:46-47`.

`GET /api/permission/request` is server-wide and checked before the tree walk; the result is not
filtered by the watched trees. Reproduced: a request from session `x9` (not in any tag's tree)
exits 4 with that request. Until someone answers it the watcher exits 4 on every restart, and the
skill's row 4 has the orchestrator read and answer it: a review session it did not include in the
tags (plausible: the same brief's `<tag>-review` folder), another project's brief, or a session the
owner opened by hand. Idle, errors and stalls in the watched briefs are masked meanwhile.

Fix: keep only requests whose `sessionID` is in a watched tree; print foreign ones once as
information and carry on.

### 10. Important: verify has no timeout, no lock and no cleanup on kill

`skills/setting-up-agent-sandbox/scripts/sandbox.sh:131-136,203-228`; `agent-sync.sh:31-38`;
`skills/verifying-and-accepting/SKILL.md:19-21`.

- No `timeout` anywhere in the build, test or E2E commands. A hung test (incident 2's class, a stuck
  Testcontainer, a suspend) is noticed only when Claude Code kills the background command at two
  hours; the skill does not tell the orchestrator to pass `timeout: 7200000` here as it does for
  the watcher, so the default 30-minute kill applies to a verify that legitimately runs E2E twice.
- The `trap stop_e2e EXIT` does not run on SIGKILL, so the E2E instances on the verify range
  (`E2E_VERIFY_FIRST..+N`) stay up and the next verify's E2E fails on ports in use.
- Two verifies of one project at once share `$HOME/verify/<project>` (the second's `rm -rf` empties
  the first's checkout under it), `/tmp/chargehand-<user>-verify` and the E2E instance range, so
  the first can pass its E2E against the second's instances. Nothing refuses the second run; the
  sudoers form allows any number. **Unverified:** whether a sudo with `use_pty` (Ubuntu 24.04's
  default) lets the bwrap child outlive Claude Code's kill of the shell; if it does, "restart the
  verify that timed out" is exactly how two end up running.

Fix: in verify mode `flock -n "$HOME/verify/$project.lock" || { echo "verify already running"; exit 3; }`;
wrap each build/test/E2E command in `timeout --foreground -k 30 "${VERIFY_TIMEOUT_MIN:-60}m"` with
the value in the project JSON and rendered into the env file; run `stop_e2e` before starting too;
in the skill, name the `timeout` to pass. `agent-sync.sh` should distinguish "tests failed" from
"sandbox could not start" (both are exit 1 today: missing Podman socket, sudoers out of date).

### 11. Important (wrapper form only): the API lock serialises every call, times out longer than the poll, and its failures are misread

`scripts/lib/api.sh:35-38`; `watch.sh:40-44,57`.

Every `oc_api` under the `wrapper` password form takes one global `flock -w 120`, including the
watcher's two calls per session per poll. Reproduced: a GET blocks while any other caller holds the
lock. With two watchers (finding 12), a ten-minute `integrate.sh`, `models_pick` (one call per
provider session in six hours) and a `brief-cost.sh` all queuing, a call can wait up to 120 s plus
30 s of curl, longer than the 60 s poll. A lock timeout returns 75: on the session list, three in
a row print `SERVER DOWN` (exit 8) and the skill tells the owner the server is down; on a message
fetch it is the silent skip of finding 2. The 120 s is hard-coded. The lock-timeout path has no
test.

Fix: fewer calls per poll (finding 2's design), a configurable wait shorter than the poll, treat 75
as "lock contention" in the watcher's message, and a test that holds the lock.

### 12. Minor: watcher contract gaps in the skill

`skills/running-briefs/SKILL.md:31-48`; `watch.sh:3,14`.

- Nothing prevents two watchers (the skill says restart after every exit and after the two-hour
  kill; a restart while the old one still runs is one message away). Both report the same event; the
  `seen-errors` grep-then-append is not atomic (one trial did not double-report; the window is
  small). A pid file under the brief folder, refused when its owner is alive, is enough.
- A watcher restarted with a tag that is already idle exits 0 at once, every time (reproduced with
  two tags); the skill should say to drop idle and accepted tags.
- The skill says 20 minutes for a stall; the script's default is 15; the retro example says 15.
- Exit 2 (`die`: no `sid`, bad tag, bad config) is not in the table; a `die` inside `oc_api` with
  stderr dropped shows as "server did not answer".
- A message `time.created` that is not an integer makes `[ -gt ]` print "integer expression
  expected" and skips the stall check for that session.
- The idle and error checks assume newest-first message order (`.data[0]`, `.[0:$u]`); in
  oldest-first order neither fires (reproduced). The real server's order is **unverified**; the
  assumption is not written down and no test pins it.

### 13. Minor: `check-config.sh` says "config complete" with a wrong server password

`skills/configuring-chargehand/scripts/check-config.sh:17,35-38`.

`--families` turns every failure into `{}`, including 401. Reproduced: wrong password, exit 0,
"chargehand config complete". The first sign is `curl: (22)` from `start-brief.sh` after it has
already pushed to the mirror. One authenticated GET (`/api/agent`) in the check, reported as a
problem on 401 and as a note on connection refused, would catch it.

### 14. Minor: `tests/run.sh` reports FAILURES for a missing tool and PASSED for a skipped layer

`skills/writing-retros/scripts/brief-cost.sh:60`; `tests/test_sandbox.sh:3`; `tests/test_api.sh:50`.

- `brief-cost.sh` needs `column` (not in the README's requirements; absent on this Ubuntu 24.04
  image). `cost.json` is written, then exit 127; `tests/run.sh` prints FAILURES, which hides real
  regressions behind a packaging gap. Format with `printf`/`awk` or list the package.
- Without bubblewrap or a Podman socket, `test_sandbox.sh` prints `skip` and exits 0, so the entire
  sandbox layer (mounts, self-test, fresh checkout, password absence) passes on any machine that
  cannot run it. The final line should say SKIPPED, and an opt-in variable should make skips fail.
- `test_password_never_in_output_or_argv` snapshots `ps` 50 ms after starting curl; in five trials
  curl had already exited every time, so the argv assertion is vacuous. Use a fake server that
  delays, or check `/proc/<pid>/cmdline` of the curl child directly.

### 15. Minor: untested scripts and paths

- `integrate.sh` and `start-review.sh` have no tests at all.
- Untested in tested scripts: root-session error and errored idle (finding 1); message fetch
  failure, empty root, server data reset (2); prompt failure after session creation (3); `&` in
  values (4); untracked collision and index lock at accept (5); the lock timeout (11); two tags
  with one idle (12); `models_busy` with an errored session (8); a slow server (curl 28, anything
  but instant answers); 5xx from the server (the fake answers 200, 401 or 404 only).
- `setup-agent-user.sh` is covered by two greps. Its step 13 writes `~/.bashrc.d/chargehand.sh`,
  which Ubuntu's default `.bashrc` never sources (checked `/etc/skel/.bashrc`): `PATH_PREPEND`
  and `sandbox_env` are missing from the agent's interactive shell (only the owner's manual
  `sudo -iu <agent>` steps are affected; the sandbox sets its own PATH).
- `start-brief.sh --dry-run` prints `.implementer[0]`; the real run uses `models_pick`, so the
  message shown is not always the one sent, and the real run prints the chosen model only on
  stderr.

### 16. Important, unverified (needs OpenCode): sessions are never told which project they belong to

`start-brief.sh:66-68`, `start-review.sh:43-45`, `sandbox.sh:143` (`--chdir "${clones[0]}"`).

The session request carries title, agent, model and permissions, no directory. Serve mode mounts
every project's clone and starts the server in the first one. With one project (the author's use)
that is the right clone. With two, the launch message's `git worktree add .worktrees/<tag>` and
`git pull --ff-only origin <target>` run wherever the server's session directory defaults to.
`brief-cost.sh` reads `.location.directory` from sessions, so the server does track a directory
per session; check how a session's directory is chosen (a request field, a header or a query
parameter) and pass the project's `agent_clone`.

### 17. Important, unverified (needs OpenCode): the permission layer is agent-editable

`sandbox.sh:108-111,246-250`; `setup-agent-user.sh:165`; README "The agent can't change how it is
judged".

Verification stays root-owned and that claim holds. Two things below it do not:

- `~/.config/opencode` is bind-mounted read-write in serve and verify modes and `opencode.json` is
  agent-owned. From a shell tool call the agent can rewrite it: the permission rules it will get
  next session, the "pinned" test-runner and pattern-applier models (cost), the `instructions`
  list, and the `plugins` list (a plugin can hook `permission.ask`). The self-test does not probe
  it.
- Serve mode puts the password in the server's environment; if OpenCode's bash tool inherits
  `process.env` (unverified), `echo $OPENCODE_SERVER_PASSWORD` in a tool call gives the agent its
  own server's API on 127.0.0.1:4096 (the sandbox does not unshare the network), with which it can
  answer its own permission requests and prompt other briefs' sessions.

Neither crosses the user or mount boundary, so the fast-forward accept and the mirror stay safe.
Fix: mount `~/.config/opencode` read-only and keep `opencode.json` root-owned (setup already
renders it; write it to `/etc/chargehand/` and bind it in); add "write opencode.json" and "read the
server password" to the self-test's "must be blocked" list; check whether OpenCode strips the
variable from tool subprocesses, and if not, pass the password through a file the server reads
once and that the sandbox then unmounts, or run the server with a separate `--password-file`.

### Exit-code contract, scripts against skills

| Script | Exits | Skill or caller expects |
|---|---|---|
| `watch.sh` | 0 1 2 4 5 6 7 8 | 0 1 4 5 6 7 8 (2 missing; 0 means "verify" regardless of outcome) |
| `integrate.sh` | 0 1 2, and git's code silently on fetch failure | 0 1 2 |
| `start-brief.sh` | 2 for a bad allocation | `models.sh` gives 3 for the same problems |
| `agent-sync.sh verify` | the launcher's: 1 for tests failed, 1 for no Podman socket, 1 for sudo refused, 2 usage | "summary lines are the evidence" |
| `answer.sh` | 22 (curl) when the server refuses, 2 usage | not documented |
| `oc_api` | 2 7 22 28 75 | callers treat every non-zero alike |

---

## Checked and found sound

- **The upload-pack claim.** The README says a fetch through `upload-pack` runs no hooks and ignores
  the agent clone's config. Tested the two config keys that execute commands: `uploadpack.packObjectsHook`
  is protected configuration and ignored at repository level; `core.alternateRefsCommand` is read
  by the fetch client (the owner's repo), not by the serving side. With both set in the agent's
  clone and an alternates file present, the owner's fetch (protocol v0 and v2) and a local
  `git clone` of the agent clone ran neither. The `-c safe.directory` is command scope, as
  required.
- **The verify-then-accept race.** The sha is resolved before the sandbox starts, the sandbox
  checks out that sha, the record is written only on success, and accept compares the record with
  the branch as fetched now. A fetch that moves the branch during or after a verify is refused with
  both shas (the existing test covers it). A fresh checkout with `core.hooksPath=/dev/null` and
  `rm -rf` of a possibly symlinked verify directory are safe.
- **`set -e` and `pipefail` idioms.** `read -r -d '' ... || true`, `out="$(...)" && rc=0 || rc=$?`,
  `getent ... | cut ... || true`, `[ -n "$body" ] && args+=(...)` (not fatal before `&&`), and the
  watcher deliberately running without `-e`. The verify loop's second `PIPESTATUS` check is
  redundant but harmless; a passing suite whose output matches no filter line fails verify, which
  is the right direction and is visible as an empty summary.
- **Password handling.** curl reads credentials from stdin as a config line; `"` and `\` are
  escaped (tested with both); the file form insists on 0600 and ownership; the launcher hands the
  password to serve mode on fd 3 and drops it (`--clearenv`, `unset`) before self-test and verify;
  the sudoers `env_keep` is therefore harmless for the non-serve forms.
- **Suspend on the watcher path.** Stall uses wall-clock time and runs before the timeout check, so
  the first poll after a resume reports `STALLED` for a brief that produced nothing meanwhile; curl's
  `--max-time` and `sleep` use the monotonic clock, so neither hangs across a suspend. (The verify
  path is finding 10.)
- **Error de-duplication** across watcher restarts (`seen-errors` keyed by message id; a new error
  in the same child has a new id and is reported again).
- **Model allocation.** Date comparison on `ends`, the live filter in the launch message, project and
  per-brief overrides, the different-family rule (with the server's families preferred); refusal of
  an unknown provider.
- **Input validation.** `valid_name` on project names and tags, the launcher's `$#` and sha checks
  behind the sudoers wildcard, the env file's mode and ownership checks, `render_env`'s `%q`
  round trip.
- **Setup's handling of the agent home** (reads and writes as the agent, never as root; umask 077
  for `opencode.json`), `visudo -cf` before installing sudoers, the push-disabled `agent` remote.

## What to do first

1, 2 and 3 together (one change to `watch.sh` and `start-brief.sh` plus two fixtures) close
incident 1 and the "blind watcher" class. 4 and 5 are small and each costs an agent round when they
hit. 6 needs a lock that 10 also needs. 7 is the missing half of the README's resume promise.
