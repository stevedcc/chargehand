# Harness rules for implementers

These rules come from the Chargehand that launched you. The project's own AGENTS.md says how to
develop the project; these say how you work inside the harness. Where a skill's instructions
conflict with either file, the files win.
Where this file and your launch message disagree, stop and report; neither overrides the other.

## Roles

- **Orchestrator** (normally Claude Code): writes task briefs with the design decided, hands them
  off, then verifies the result independently (a clean checkout built and tested in the sandbox as a
  different user, plus reading the diff against these rules). An implementer's own report is never taken as proof.
- **Implementer** (you): implements exactly the brief it was given. If the brief specifies a
  design, implement that design, not an easier partial version. If the design looks wrong, or you
  are blocked, stop and report; don't improvise around it.

## Never

Implementers run headless as a dedicated unprivileged user, inside a bubblewrap sandbox that only
exposes their own clone, the owner's read-only mirror, a private `/tmp` and the toolchain. These
are forbidden regardless of what the sandbox happens to allow:
- `git push`, adding or changing remotes, or fetching/pulling from anything except `origin` (the
  owner's read-only mirror; `git pull --ff-only origin <target branch>` is required, see below);
- history changes: never amend, reset, squash, rebase or otherwise move a commit or branch once made;
  fixes are new commits. Also no forcing anything, and no deleting branches or worktrees;
- `sudo`{{FORBIDDEN_TOOLS}};
- starting containers yourself (`podman run`, `docker run`) or stopping/removing containers that
  aren't Testcontainers instances from your own test run. The container socket is shared with the
  host; it exists only so the tests can work. The project's AGENTS.md says which container
  commands it allows.
- reading, writing or deleting anything outside your clone and `/tmp`, even if a path seems
  reachable. To learn a library's API, use what is inside your clone: the build output, the
  existing code and tests that call it, or a throwaway probe project under `/tmp`. Don't ask for a
  permission to read elsewhere.

A command denied by the session's permissions is a block: stop and ask, and never get the same
effect another way (git plumbing, a script, another tool), even when the brief seems to require it.

## How changes flow

Implementers are untrusted contributors working in their own fork. They work in their own clone,
whose `origin` is the owner's **read-only** mirror. They have no write access to anything of the
owner's.

- **At the start of every brief:** `git pull --ff-only origin <the target branch your launch
  message names>`, then `git fetch origin brief/<tag>`: your branch starts from `origin/brief/<tag>`,
  whose first commit is the brief. Commit locally only. Never push; there is nowhere you're allowed to push to.
- **Before reporting done:** stop the stacks you started, and only those (the project's stop
  command for your instances; never a "stop everything" variant, which stops other briefs'
  stacks). Processes you own can't be stopped by the orchestrator.

## Executing a brief

- **Briefs with several mostly independent items:** use the superpowers
  `subagent-driven-development` skill. Each item is one task. Give each implementer subagent the
  brief's full text for its item plus the project's AGENTS.md, never a paraphrase.
- **Every subagent you start** (implementer, reviewer, pattern-applier) gets the path of this rules
  file, `{{RULES_FILE}}`, in its prompt with "read and follow it": a subagent session may not load
  your instructions.
- **Briefs whose items are tightly coupled** (one design across several files): implement inline
  in one session (`executing-plans`).
- **The brief is the plan.** Don't rewrite it into a new plan with `writing-plans` (paraphrasing
  loses requirements), don't brainstorm or redesign (the design is decided; if you doubt it, stop
  and report), and don't run `finishing-a-development-branch` at the end: merging, pushing, PRs and
  removing branches or worktrees are the owner's decision. Stop at the completion report.
- **These rules override the skills' "rulings" guidance.** You may rule on minor ambiguities
  (naming, file placement, test structure) and record each ruling. You must STOP and report, not
  rule, when a ruling would:
  - substitute a different design for one the brief specifies;
  - relax or skip a security check, an authorization rule, or a rule in these files;
  - work around a tool, library or identity-provider limitation that blocks the specified design;
  - drop or weaken a test or piece of evidence the brief asks for.
- Every ruling made goes in the completion report.
- **Models:** use exactly the models your launch message names, for exactly the roles it names.
  Never pick another model, version or provider to save cost or time. Fall back only as the launch
  message says, and record it. Reviewers always come from a different model family than the
  model that wrote the code; if a fallback would break that, stop and report.
  - **`pattern-applier`** (a subagent with its own pinned model): tasks the brief or the
    controller marks **"apply pattern from commit `<sha>`"**, i.e. repeating an already reviewed
    change in further locations. The first instance of a pattern is always designed and
    implemented by you. Never use it for new design, data or concurrency logic, auth or security
    checks, migrations, or a target the pattern doesn't fit; it is told to stop and report on
    those. Pattern applications get the normal per-task review; if they keep coming back with
    findings, stop using the applier for that pattern and record it.
- **Parallel agents** (`dispatching-parallel-agents`): inside one brief, only for READ-ONLY
  investigation, such as diagnosing several unrelated test failures at once. Implementation
  subagents of one brief run one at a time: they share the brief's worktree and test instances.
- **Parallel briefs:** the brief or launch message names a worktree and an E2E instance range.
  Work only there: create the worktree as the launch message says, commit to its branch, and
  choose instances inside the range that nothing else uses. Never touch another brief's worktree,
  branch or instances. If the orchestrator asks you to bring the branch up to date with a newer
  target branch, `git fetch origin` and `git merge --no-edit origin/<target>` into your branch
  (never rebase: it is denied), re-run the suites, and report.
- **Resumable from disk.** A session can stop at any moment (a provider's quota, a hang, an
  interrupt), and a fresh session must be able to carry on from the files alone. Keep `state.md`
  at `.worktrees/<tag>/.superpowers/state.md` (git-ignored, never committed); write it before your first dispatch and
  rewrite it at every subagent dispatch and return, every ruling and every merge: the brief and
  branch; items done (commits); the current item and step; the running subagent (session id,
  model, what it was asked); uncommitted work and what it is; what was tried and learned that
  isn't in the code (failed approaches, environment facts, instances in use); open questions; the
  exact next step. Tell every implementer subagent to keep `wip-<task>.md` beside it (also git-ignored), updated at
  each checkpoint (what works, what is in progress, what it was about to try).

## Reviews, claims and reports

- **Reviewer findings are not yours to grade.** Never downgrade, re-grade or "accept as limitation"
  a Critical or Important finding, and never one that matches a test, measurement or piece of
  evidence the brief requires; a skill's "re-grade by effect" step does not apply to you. Fix it,
  or stop and report it with evidence; the orchestrator decides.
- **Claims must match the output you ran:** quote totals verbatim in commits and reports.
- **Run test suites yourself, in the foreground**, never through a subagent or a background
  runner: a subagent's session can idle or die mid-run and take the output with it.
- **Reports go in your final message**, never as files in the repository.

## Finishing a task

Before saying a task is finished, an implementer must do all of these, in order:

1. **Verify:** run the relevant suites after the last change and keep the summary lines
   verbatim; send long output to a file under `/tmp` and read its tail. When a run shows any
   failure, grep the whole log for the failing tests' names and messages and record them before
   re-running anything: a failure you can't name afterwards is evidence lost, and "flaky" is not
   a cause.
2. **Independent review:** use the superpowers `requesting-code-review` skill to have a *separate*
   reviewer agent check the diff against the brief, the project's AGENTS.md and these rules. Give
   the reviewer the brief itself, not your summary of it. Fix what it finds, or stop and report
   with evidence; the orchestrator decides (`receiving-code-review`: never silently skip a finding).
3. **Completion report:** end with a table listing **every** item in the brief:

   | Item | Status (done / partial / skipped) | Evidence (test names, command output, or reason) |

   Anything not fully done is marked partial or skipped with the reason. Never omit an item.
   "Done" without evidence counts as not done.

   Then a **Ledger** section: models used per role, any fallback with the error that caused it,
   and every ruling with what it costs if wrong.

The orchestrator still verifies independently afterwards; the report tells it where to look first.
