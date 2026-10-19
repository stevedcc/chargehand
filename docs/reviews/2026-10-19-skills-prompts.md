# Review: the skills and implementer rules as prompts (2026-10-19)

Reviewed at commit a54b94b (0.2.1). Scope: every `skills/*/SKILL.md`, `skills/running-briefs/launch.md`
and `resume.md`, `implementer/rules.md`, `implementer/claude-subagent-rules.md`, the two helper agent
prompts, and the scripts they point at, read as instructions a model will follow under pressure.
Method: read everything, ran `bash tests/run.sh` (all pass; `test_sandbox.sh` skipped, no bubblewrap
here), and ran scratch experiments with bash, git and jq where a claim could be checked. There is no
OpenCode server or YubiKey in this environment; anything that depends on them is marked
**unverified**.

Severity: **Critical** = a rule the harness depends on does not hold or contradicts itself so that a
model can pick the convenient reading; **Important** = a real run will lose work, money or trust;
**Minor** = friction, wasted tokens, or a hole behind a stated guard rail.

---

## Findings

### 1. Critical: the launch message forbids what the rules require (test runs through a subagent)

- `skills/running-briefs/launch.md:5` — "Run test suites yourself in the foreground, never through a
  subagent or a background runner." Repeated in `resume.md:3`.
- `implementer/rules.md:73-77` — `test-runner` "(a subagent with its own pinned model): full-suite
  runs and builds, for implementers *and* reviewers. Give it the exact commands".
- `implementer/agents/pattern-applier.md:18` — "Run the full suites through the `test-runner`
  subagent".
- `implementer/rules.md:4-5` sets precedence only between *skills* and *files*; nothing says whether
  the launch message or `rules.md` wins when they disagree.

**Scenario.** The implementer has run the unit suite three times inline and its context is filling.
It reads the rules, dispatches `test-runner`, and reports its summary lines. A reviewer reads the
launch message and marks "ran tests through a subagent against the launch rules" as Important. The
implementer, also reading the rules, re-grades the finding as "the rules file wins" — which
`launch.md:5` says it must never do. Every reading is defensible, so the rule is unenforceable.
Reviewers are told to use `test-runner` too, while the launch message says the opposite to the same
session.

**Fix.** Decide once. If `test-runner` stays, delete the sentence from `launch.md` and `resume.md`
and put the one condition that matters in `rules.md` ("the summary lines must be verbatim; if the
runner's report lacks them, run the command yourself" is already there). If the foreground rule stays,
delete `test-runner` from `rules.md`, `pattern-applier.md` and `render_opencode_config`. Either way add
one line to `rules.md`: "Where this file and your launch message disagree, stop and report; neither
overrides the other."

### 2. Critical: "a model never grades its own work" holds only for first choices

- `scripts/lib/models.sh:40-42` compares the *first* `task_review`/`final_review` model's family with
  the *first* implementer's. Fallbacks are not checked.
- `README.md` ("Chargehand refuses an allocation where they match, so a model never grades its own
  work") and `implementer/rules.md:71-72` ("the launch message's allocation already ensures that")
  both promise more than the code does.
- Checked: with `implementer: ["zai/glm-4.6", "moonshot/kimi-k2"]`, `task_review:
  ["moonshot/kimi-k2-thinking"]`, `models_check` prints nothing and `models_render` emits that
  allocation unchanged.

**Scenario.** Z.ai hits its 5-hour quota at item 2. The implementer falls back to `moonshot/kimi-k2`
as the launch message allows, records the switch, and dispatches task reviews on
`moonshot/kimi-k2-thinking`. Items 2 to 5 are reviewed by the implementer's own family. The ledger
says "fallback recorded", the retro says nothing was wrong, and the independent-review guarantee the
README leads with was silently off for most of the brief.

**Fix.** In `models_check`, test every implementer model (not just `[0]`) against every reviewer
model and report "role task_review: `<m>` shares a family with implementer fallback `<f>`". In
`models_render`, say explicitly: "If you switch to a fallback, the reviewer must still be from a
different family than the model that wrote the code; if the list leaves none, stop and report."
Correct the README sentence until the check covers fallbacks.

### 3. Important: `state.md` has no defined location for OpenCode implementers, so resume cannot find it

- `implementer/rules.md:95-96` — "Keep `state.md` next to your ledger (git-ignored, never
  committed)".
- `implementer/rules.md:121` — "Don't write a ledger file in the repo." The ledger is a section of
  the final message, so "next to your ledger" names nothing.
- `skills/running-briefs/resume.md:3` — "Start by reading the `state.md` next to your ledger".
- `implementer/claude-subagent-rules.md:66` does name a path (`.superpowers/state.md` in the
  worktree); the OpenCode rules do not.

**Scenario.** The first session writes `state.md` wherever Superpowers' conventions or its own guess
put it (the worktree root, the clone root, `/tmp`). The resumed session looks "next to the ledger",
finds nothing, follows the fallback ("reconstruct the state from the commits") and loses exactly
what `state.md` was for: uncommitted work, the running subagent, the E2E instances in use, the failed
approaches. If it was written to the worktree root unignored, `git add` of an explicit path list
avoids it only as long as nobody runs `git add -A`.

**Fix.** Name the path in `rules.md` and `resume.md`: `.worktrees/<tag>/.superpowers/state.md`
(matching the Claude rules). Have `setup-agent-user.sh` append `.superpowers/` and `wip-*.md` to the
agent clone's `.git/info/exclude`, so it is git-ignored for every project without touching the
project's `.gitignore`.

### 4. Important: history rewriting is forbidden three different ways and denied by none of them

- `implementer/rules.md:23` — "`commit --amend` on commits you didn't just make" (so amending the
  last commit is allowed).
- `launch.md:5`, `resume.md:3`, `claude-subagent-rules.md:38` — never amend, full stop.
- `skills/running-briefs/permissions.json` denies `git rebase*`, `git reset --hard*`,
  `git filter-*`, `git update-ref -d*`, but not `git commit --amend`, `git reset` (soft/mixed),
  `git branch -f`, `git update-ref` without `-d`, `git checkout -B`, `git switch -C`, `git stash
  drop`, or `git clean` (which deletes the git-ignored `state.md` and `wip-*.md` from finding 3).

**Scenario.** A task reviewer finds a typo in the commit the implementer made two minutes ago. The
implementer reads `rules.md:23`, amends ("I just made it"), and continues. The orchestrator has
already fetched and read the diff, or verify is running on the old SHA: accept then refuses with
"moved since verify", a verify round is lost, and the orchestrator must re-read a diff whose history
no longer matches its notes. Nothing in the permission layer stopped the amend, and the rules
sanctioned it.

**Fix.** One rule, in `rules.md` only: "Never amend, reset, squash, rebase or otherwise move a
commit or branch once made; fixes are new commits." Drop the "you didn't just make" clause. Add deny
patterns for `git commit --amend*`, `git commit* --amend*`, `git reset --soft*`, `git reset
--mixed*`, `git reset HEAD~*`, `git branch -f*`, `git branch --force*`, `git update-ref*`, `git
checkout -B*`, `git switch -C*`, `git clean*`, `git stash drop*`, `git stash clear*` (pattern
semantics **unverified** without a server).

### 5. Important: re-grading is forbidden in the launch message and permitted in the rules

- `launch.md:5` — "never downgrade, re-grade or 'accept as limitation' a reviewer's Critical or
  Important finding ... Fix it, or ... stop and report it".
- `implementer/rules.md:110-112` — "Fix what it finds, or record why not (`receiving-code-review`:
  never silently skip a finding)". "Record why not" is the loophole the launch message closes.
- The launch message reaches the parent session only. Implementer subagents get "the brief's full
  text for its item plus the project's AGENTS.md" (`rules.md:53-54`); the rules file reaches them via
  `instructions` (**unverified** that OpenCode applies `instructions` to subagent sessions). So the
  rules the author considered important enough to put in every launch message are the ones the
  subagents never see.

**Scenario.** A reviewer marks "the brief's 2560 px test is missing" Important. The implementer
subagent, holding only the brief and `rules.md`, records "not reproducible on this machine; accepted
as limitation" in its return message. The parent, which did read the launch message, forwards the
table. The orchestrator catches it only if it re-reads every reviewer finding against every ledger
line.

**Fix.** Move the four launch-only rules (no re-grading, verbatim claims, no report files, no amend)
into `rules.md`, so every session gets them; make `launch.md` carry only what changes per brief
(target, tag, E2E, models, extra). Replace "or record why not" with "or stop and report with
evidence; the orchestrator rules". Tell the dispatcher to pass the rules file path to each subagent
explicitly rather than rely on `instructions`.

### 6. Important: nothing records which providers are pay-per-use, yet two rules depend on knowing

- `skills/configuring-chargehand/SKILL.md:30` — "Ask which providers are flat-rate subscriptions
  (a pay-per-use provider never is)". No key in `models.json` stores the answer (grep: nothing in
  `scripts/`, `skills/*/scripts/`, `examples/`).
- `skills/running-briefs/SKILL.md:84-85` — ask the owner before "paid pay-per-use models"; `:69`
  "ask first only if that fallback is a pay-per-use model".
- `scripts/lib/models.sh:54,59` — the launch message tells the *agent* to switch to a fallback on a
  quota error and lists every live subscription as allowed, with no marker for pay-per-use.
- `models_pick` (`models.sh:83-103`) silently passes to the next model when a plan is at
  `max_busy_sessions`, and to the first anyway when all are capped.

**Scenario.** `final_review` is `openai/gpt-5` on an API key; the implementer's fallback is the
same provider. At 03:00 Z.ai returns 429; the agent switches per the launch message and runs
E2E twice plus the final review on metered tokens. The orchestrator's "ask the owner" rule never
fires because the agent decided, and in the morning the only record is a ledger line and a
`brief-cost.sh` total nobody can compare with a budget. The README's "nothing is billed per token"
holds only while every fallback happens to be flat-rate.

**Fix.** Add `"pay_per_use": true` to a subscription in `models.json` (or derive it: `per_mtok`
pricing without `plan_usd`). `models_render` then prints those models as "only after the
orchestrator says so in a prompt; on a quota error with no flat-rate fallback left, stop and report".
`models_pick` never auto-selects a pay-per-use model (a `--allow-paid` flag for the owner's explicit
yes), and `start-brief.sh` refuses an allocation whose only fallback is pay-per-use without it.

### 7. Important: the brief must be on the target branch, but the two skills that touch it disagree and the launcher does not check

- `skills/writing-briefs/SKILL.md:44` — "Commit and push the brief (`agent-sync.sh push`)".
- `skills/verifying-and-accepting/SKILL.md:43-50` — "**Commit nothing on the target branch** [while
  any brief is running or waiting]. No 'harmless file' exceptions: docs count."
- `skills/running-briefs/scripts/start-brief.sh:43` checks only `[ -f "$repo/$brief" ]`, the working
  tree. Checked: with the brief written but uncommitted, `--dry-run` produces the full launch message
  naming `docs/briefs/01.md`, while `git cat-file -e main:docs/briefs/01.md` fails.

**Scenario A.** Brief 01 runs; the orchestrator writes brief 02 and follows `writing-briefs`: commit,
push, launch. Brief 01's accept is now a non-fast-forward; one merge round, one re-verify.
**Scenario B.** It follows `verifying-and-accepting` instead: no commit. `start-brief.sh` pushes the
target without the brief; the agent pulls, cannot find the file the message names, and either asks
(exit 5, after a 60 s poll) or implements from the title and the AGENTS.md. The second outcome looks
like progress for an hour.

**Fix.** `start-brief.sh`: `git -C "$repo" cat-file -e "$target:$brief"` and refuse otherwise. Then
remove the contradiction: either (a) write a whole batch of briefs in one commit *before* launching
the first, and say so in both skills, or (b) stop putting briefs on the target branch at all: push
them as `refs/briefs/<tag>` to the mirror (`git push agent-upstream HEAD:refs/briefs/<tag>` from a
scratch commit) and have the launch message say `git fetch origin refs/briefs/<tag>` and read the
file from that tree. (b) removes the conflict for good and keeps briefs out of the project's history.

### 8. Important: a Claude subagent implementer runs untrusted code as the owner, and no skill says the boundary is gone

- `skills/setting-up-agent-sandbox/SKILL.md:10` — "**nothing they write is ever executed as the
  owner before accept**"; `skills/verifying-and-accepting/SKILL.md:61-62` — never build, test or
  run `agent/*` commits as yourself.
- `implementer/claude-subagent-rules.md:23-24,56` — the subagent works in the owner's repo "with the
  owner's rights" and "Run test suites yourself, in the foreground".
- `README.md` ("Other implementers") presents this as "verify and accept stay the same". The
  verification does, but the implementation phase runs every build, test and E2E of agent-written
  code with the owner's user, keys and SSH agent.

**Scenario.** The project's test fixtures (or a dependency's build script, or a code comment the
subagent reads) carry an instruction. The Claude subagent is a model, and the harness's own
`verifying-and-accepting` says agent text is hostile input, but here the "agent" is trusted like the
owner. The owner reads the README's boundary story, assumes it applies, and lets the subagent run
overnight on a repo whose tests they would not run blind themselves.

**Fix.** Say the trust decision out loud in `README.md`, `running-briefs` ("Branches implemented
outside the sandbox") and the top of `claude-subagent-rules.md`: "This implementer is trusted like
you: its tests run with your rights. Use it only on repos whose tests you would run yourself." Better:
have the subagent commit test-first without running the suites, and run them through
`start-review.sh` plus `agent-sync.sh verify` (both already exist for this path), so the sandbox
promise holds for both implementers.

### 9. Important: steps that depend on the orchestrator's memory instead of a script or template

1. **The review prompt.** `start-review.sh --prompt <file>` ships no template (contrast `launch.md`).
   The prompt must tell the reviewer to `git fetch origin <branch>` *and* create a local branch under
   `refs/heads/` in the agent clone, or `agent-sync.sh fetch` (`+refs/heads/*:refs/remotes/agent/*`)
   never sees the commit and verify cannot run. None of that is written anywhere
   (`skills/running-briefs/SKILL.md:35-39` says only "the review session fetches the branch").
2. **Launching a Claude subagent.** No prompt template, no script to create the worktree, no
   instance allocation, no `.superpowers/` exclusion. The orchestrator assembles rules + brief +
   worktree + instance range from memory each time.
3. **`integrate.sh` "every 10 minutes"** (`SKILL.md:76`). There is no loop. The model either forgets
   between watcher exits, or writes `while :; do bash integrate.sh; sleep 600; done &`, the `&` the
   same skill bans thirty lines above (`:47`).
4. **Exit 7 handling** (`SKILL.md:67`): four manual API steps with endpoints
   (`GET /api/session/<s>/permission`, `POST /api/session/<child>/interrupt?resume=false`) that no
   script wraps. `watch.sh:80` reads permissions from `/api/permission/request` (server-wide); the
   skill tells the orchestrator to read `/api/session/<s>/permission`. Two different endpoints for the
   same fact; which is right is **unverified** here, and a model given two will try both.

**Fix.** Ship `skills/running-briefs/review.md` (with `{TAG}`, `{BRANCH}`, `{BASE}` and the fetch +
branch lines) and `claude-implementer.md`; add `start-claude-brief.sh` that creates the worktree,
writes `.superpowers/` to `.git/info/exclude`, picks instances and prints the Agent prompt. Give
`integrate.sh` `--every <min>` (or run the check inside `watch.sh` when two or more tags are
watched). Add `answer.sh pending <s>` and `answer.sh interrupt <s>`, and cite only those in the table.

### 10. Important: the rules say "never `&`" but nothing says "never `sleep`"

- `skills/running-briefs/SKILL.md:46-48` bans `&` for the watcher and requires `run_in_background`.
- Nothing in any skill says not to wait on a condition with a foreground `sleep` or a poll loop.
- `skills/verifying-and-accepting/SKILL.md:21-23` says `run_in_background` for verify, but not what
  to do while it runs.

**Scenario.** After an exit 7 the orchestrator prompts the session, then runs
`sleep 300; curl .../message | jq ...` "to see whether it picked up", blocking the turn for five
minutes with nothing else watched. Or it restarts the watcher as `sleep 900 && bash watch.sh ...`
to "give it time", which defeats the stall threshold. Both are natural moves the skill does not
forbid.

**Fix.** One sentence in `running-briefs` (Watch) and `verifying-and-accepting` (step 3): "Never
`sleep` or poll in a foreground call to wait for an agent, the watcher or verify; start the watcher
or verify with `run_in_background` and act when it exits. The harness wakes you."

### 11. Important: "name the failing tests before re-running" exists only for the Claude implementer

- `implementer/claude-subagent-rules.md:57-60` — grep the log for failing test names and messages
  before re-running anything, with the real case that motivated it.
- `implementer/rules.md` — nothing equivalent. `agents/test-runner.md:20` says "never rerun a
  failing test to make it pass", which binds the runner, not the implementer who re-dispatches it.

**Scenario.** The OpenCode implementer sees `Failed! - Failed: 1, Passed: 211`, dispatches
`test-runner` again, gets `Passed!`, and reports green. Nobody can say which test failed or why; the
retro records "flaky run", which the retro skill says is never a cause.

**Fix.** Port the paragraph to `rules.md` ("Finishing a task", step 1) and tell `test-runner` to
include the failing names it already captures *before* the implementer may re-run.

### 12. Important: setup copies the owner's `opencode.json`, API keys included, into the agent's home

- `skills/setting-up-agent-sandbox/scripts/setup-agent-user.sh:155-156` uses the owner's
  `~/.config/opencode/opencode.json` as the base when the agent has none; `README.md` says
  "providers included". OpenCode provider blocks can hold `options.apiKey`.
- The sandbox has network (`README.md`, "What it does not do"); the agent reads its own config.

**Scenario.** The owner has an OpenAI API key in their OpenCode config for occasional use. Setup
hands it to the agent user. The agent now has a pay-per-use provider it can reach regardless of the
"Allowed providers" line (finding 6), and a secret the README says to keep out of the agent's reach.

**Fix.** Strip `.provider[].options.apiKey` (and any `*key*`/`*token*` under `provider`) when copying,
print what was dropped, and tell the owner to `opencode auth login` as the agent instead (the skill
already lists that step). State it in the setup skill's step 2.

### 13. Minor: the patch-aside recipe does not set aside staged changes

- `skills/verifying-and-accepting/SKILL.md:46-48`: `git diff > /tmp/pending.patch && git checkout
  -- <files>`.
- Checked: with a staged edit, `git diff` writes an empty patch, `git checkout --` leaves the index
  as it was, and `git status --porcelain --untracked-files=no` still shows `M  f`, so `accept`
  refuses with "has uncommitted changes". Binary changes also do not survive `git diff` without
  `--binary`.

**Fix.** `git stash push -u -m pending-<tag>` before accept and `git stash pop` after, or
`git diff HEAD --binary > patch && git checkout HEAD -- <files>`.

### 14. Minor: the diff the owner reads in step 2 carries control characters unfiltered

- `skills/verifying-and-accepting/SKILL.md:16-17` names `git diff <target>...agent/brief/<tag>` as
  the security boundary; `:56-58` warns that `git log`/`git show` output can carry control
  characters, but the step-2 command is the same kind of output. Checked: a committed file containing
  `ESC[2J ESC[H` comes through `git diff` and `git diff --no-color` byte for byte.

**Fix.** Add `agent-sync.sh --project <p> diff <ref>` that runs the diff through `agent_text`, and cite
that in step 2.

### 15. Minor: `answer.sh` accepts `always`; the skill lists only `once|reject`, and nothing forbids `always`

- `skills/running-briefs/scripts/answer.sh:17` allows `once|always|reject`; `SKILL.md:64` shows
  `once\|reject`. A model answering the fourth identical read request will reach for `always`.

**Fix.** Drop `always` from the script, or add "never `always`: each request is read on its own" to
the table row.

### 16. Minor: the example `models.json` fails its own family check when the server is down

- `scripts/lib/models.sh:21` falls back to the model id's first word as its family;
  `examples/models.json` names every model `model-...`. Checked: `models_check` on the example with
  `{}` families reports both reviewer roles as "same model family as the implementer".

**Fix.** Give the example ids distinct first words (`alpha-pro`, `beta-z`, `gamma-w`), and say in
`configuring-chargehand` that the family check degrades to the id prefix when the server is
unreachable.

### 17. Minor: `--resume` accepts a different `--brief` without comment

- `start-brief.sh:36-37,62-66`: resume requires a `sid` but never compares `--brief` with the
  previous `launch.txt`. Checked: `--resume --brief docs/briefs/02.md` on a brief launched with
  `01.md` renders "You are resuming brief `docs/briefs/02.md`".

**Fix.** Parse the brief path out of `launch.txt` (or store it in `brief.txt` at launch) and die on
a mismatch.

### 18. Minor: `git remote*` is denied as a whole, so a harmless `git remote -v` becomes a "block: stop and ask"

- `permissions.json:7-11` plus `rules.md:35-36` ("A command denied ... is a block: stop and ask").
  A confused agent checking where `origin` points is stopped for nothing, costing an exit 5 round.

**Fix.** Deny `git remote add*`, `set-url*`, `remove*`, `rm*`, `rename*`, `prune*` and leave reads.

### 19. Minor: the rules describe an orchestrator that runs tests itself

- `implementer/rules.md:9-11`: the orchestrator "verifies the result independently (runs tests,
  probes the live stack ...)". The owner-side skills forbid exactly that; `claude-subagent-rules.md:14-15`
  has the correct description ("a clean checkout built and tested in the sandbox as a different
  user"). A reviewer model reading `rules.md` may write "the orchestrator will run this".

**Fix.** Copy the sentence from the Claude rules.

### 20. Minor: tokens spent on history the reader cannot use

- `skills/running-briefs/SKILL.md:10-11` (03h anecdote), `:31-33` ("is untested ... only session
  creation and prompts as the scripts send them are used here": a development note, not an
  instruction), `:67` ("07c, 2026-10-10", "09a, 2026-10-12"), `:77` ("so the two no longer
  collide"); `skills/writing-briefs/SKILL.md:30` ("the 03i sidebar test"). A plugin user has no 03h,
  07c or 09a. `running-briefs` is 1,387 words; these are about a tenth of it.
- `implementer/agents/test-runner.md:4` assumes AGENTS.md has a "Running things" section with SDK and
  `--no-build` advice (the author's .NET project), and `:10` lists `Passed!`/`Build succeeded`
  summary shapes that only `dotnet test` produces.
- `skills/writing-retros/SKILL.md:14`: "`records/<project>/retrospectives.md` in the harness repo".
  After `/plugin install` there is no "harness repo" the user edits, and `records/` is git-ignored
  here; where retros go is undefined for everyone but the author.

**Fix.** Keep each anecdote as a one-clause reason ("a watcher that polls only the parent misses a
dead subagent") without the tag and date; move dates to the retros. Make `test-runner.md` take the
summary pattern from the project's `test_filter`. Name a records location that exists for a plugin
user (for example `~/.local/state/chargehand/<project>/records/`, or a repo the config names).

### 21. Minor, unverified: session list `limit=1000` and the mount-flag deny patterns

- `watch.sh:59`, `models.sh:75`, `brief-cost.sh:26` fetch `/api/session?limit=1000` and walk the
  tree in that page. After weeks of briefs with many subagents each, a child outside the page is
  invisible: the watcher reports a stall (or nothing) and `brief-cost.sh` under-counts. Which 1000 the
  server returns is **unverified**.
- `permissions.json:133-135,183-185`: `docker run --rm * -v *` needs a space after `-v`;
  `docker run --rm --name x -v/src:/dst` passes. The README already calls these guard rails, so this
  is a note, not a hole in the boundary.

**Fix.** Page the session list (or filter by `parentID` server-side if the API allows), and add
`*-v/*` and `*-v.*`-style patterns if OpenCode's matcher supports them.

---

## Checked and found sound

- **Skill descriptions** all say *when* to use the skill, not what it does (`configuring-chargehand`,
  `running-briefs`, `setting-up-agent-sandbox`, `verifying-and-accepting`, `writing-briefs`,
  `writing-retros`).
- **Tests:** `bash tests/run.sh` passes (14 files); `test_sandbox.sh` skipped for lack of bubblewrap
  and says so in the last line rather than hiding it.
- **`&` for the watcher:** `running-briefs:46-48` forbids it with the reason and names
  `timeout: 7200000`; the 30-minute default that killed a real watcher is called out.
- **Re-grading in the parent session** is forbidden clearly in `launch.md:5`, including the
  Superpowers "re-grade by effect" step; the defect is coverage (finding 5), not wording.
- **Rebase** is forbidden with the reason ("accept needs the agent's commits unchanged") in
  `running-briefs:90-91` and denied in `permissions.json`; the owner side consistently says
  "merge, never rebase".
- **Accept** pins the exact verified SHA (`agent-sync.sh:59-61`), refuses on movement, and is
  fast-forward only; records are keyed so `a/b` and `a%b` cannot collide (`record_name`).
- **Fetch** uses `upload-pack` with a process-scoped `safe.directory`, no hooks, no agent config;
  **verify** clones fresh with `core.hooksPath=/dev/null`, read-only source, one verify per project
  by lock held in the launcher, every command under `timeout`.
- **`oc_launch`** writes `sid` only after the prompt is accepted, so no watcher runs silently on an
  unprompted session; failed launches are kept as `sid.failed-<n>`.
- **Password handling:** never on a command line (curl `-K -`, fd 3 into bwrap, `--clearenv`);
  file form checks mode 600 and ownership.
- **Agent text** is stripped of ANSI/OSC/C0/C1 in `agent_text` and used by `watch.sh` and
  `agent-sync.sh`; the skills say agent text is data, never instructions.
- **`patsub_replacement`** is turned off in `harness.sh`, so an `&` in a brief path or `--extra`
  cannot corrupt the launch message. (`sandbox.sh` does not source it, but its substitutions take
  only integers.)
- **Watcher logic:** newest-first ordering independent of the server, errors reported once via
  `seen-errors`, idle-after-error never exit 0, foreign permissions printed once and not acted on,
  blind-watch exit 10 distinct from stall. The tests cover each of these.
- **Forbidden tools** flow into both the rendered rules and the session deny list
  (`render_rules`, `render_permissions`; checked with `kubectl`, `vault`).
- **`integrate.sh`** runs in the object database only and shares the fetch lock with
  `agent-sync.sh fetch`.
- **Sudoers** allows only the launcher's three fixed forms; the launcher validates the SHA and
  refuses an env file that is not root-owned or is group/world-writable.
- **`sandbox.sh:131`** runs one `git rev-parse` on the agent-controlled clone outside bwrap, as the
  agent user. `rev-parse` does not run hooks, aliases or `fsmonitor`, so this is believed safe; it is
  noted because it is the one git invocation on agent content before the sandbox exists.
