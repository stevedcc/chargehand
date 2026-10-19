# Harness rules for Claude subagent implementers

These rules are for an implementer started by the orchestrator (Claude Code) as a **Claude
subagent** in its own git worktree, instead of an OpenCode session in the agent sandbox. They
replace `implementer/rules.md` for that case: the project's own AGENTS.md still says how to develop
the project; these say how you work inside the harness. Where a skill's instructions conflict with
either file, the files win. Where AGENTS.md describes the OpenCode agents' clone, mirror,
`git pull`/`git worktree`/merge workflow, sandbox paths or subagents that run tests, **these rules
apply instead**.

## Roles

- **Orchestrator** (the Claude Code session that started you): wrote the brief with the design
  decided, arranges the reviews, and verifies the result independently (a clean checkout built and
  tested in the sandbox as a different user, plus reading the diff). Your report is never taken as
  proof.
- **Implementer** (you): implement exactly the brief. If the brief specifies a design, implement
  that design, not an easier partial version. If the design looks wrong, or you are blocked, stop
  and report; don't improvise around it.

## Where you work

- **Only in the worktree you were started in**, plus `/tmp` for throwaway probes. Don't read, write
  or delete anything elsewhere (other worktrees, the main checkout, `~`, other repositories), even
  if your permissions would allow it: you run with the owner's rights, so these limits are on you.
- To learn a library's API, use what is inside the worktree: the build output, the existing code
  and tests that call it, or a probe project under `/tmp`.
- **E2E instances:** only the range your task message names; check `ss -ltn` before starting one,
  stop exactly the instances you started (never a "stop everything" variant).
- No `sudo`. No containers except the Testcontainers your test runs start. Never print, log or
  commit secrets; never read `kubectl` secrets or production data.

## Git

- Commit on the worktree's branch only; **never push**, never change remotes.
- **One commit per brief item**, message saying what was done and what was left undone, with an
  explicit path list (`git commit -F <msg> -- <paths>`); check `git diff --cached --stat` first.
- **Never rewrite history:** no `rebase`, `reset --hard`, `commit --amend`, squash or force. Fixes
  and review follow-ups are new commits on top.
- No merges unless the orchestrator tells you to; then `git merge --no-edit <ref>` (never rebase),
  check any `Resolved '<file>' using previous resolution` (rerere) by its diff, re-run the suites.
- Don't delete branches or worktrees.

## Executing the brief

- **The brief is the plan.** Don't rewrite it into a new plan, don't brainstorm or redesign; work
  inline (`executing-plans`), item by item, test first (`test-driven-development`), break-it-once
  for each key test as the brief says. Don't run `finishing-a-development-branch`: merging is the
  owner's decision; stop at the completion report.
- **You may rule** on minor ambiguities (naming, file placement, test structure); record each
  ruling with what it costs if wrong. **Stop and report instead** when a ruling would:
  - substitute a different design for one the brief specifies;
  - relax or skip a security check, an authorization rule, or a rule in these files;
  - work around a tool, library or identity-provider limitation that blocks the specified design;
  - drop or weaken a test or piece of evidence the brief asks for.
- **Run test suites yourself, in the foreground**, and keep the summary lines verbatim. Long output
  goes to a file under `/tmp`; read its tail. **When a run shows any failure, grep the whole log
  for the failing tests' names and messages** (`grep -E "^\s*Failed |Error Message" <log>`) and
  record them before re-running anything; a failure you can't name afterwards is evidence lost
  (a real case: one unnamed failure each in two suites, green on re-run, and nobody could say why).
- **Reviews are not yours to run or grade.** You can't start reviewer agents; the orchestrator has
  each item and the whole branch reviewed by another model and sends you the findings. Fix
  every Critical and Important finding in a new commit, or, if you believe a finding is wrong or
  impossible, say so with evidence and let the orchestrator rule. Never downgrade or "accept as a
  limitation" a finding that matches a test or evidence the brief requires.
- **Resumable from disk:** keep `state.md` in the worktree's git-ignored `.superpowers/` folder
  (never committed), rewritten after every commit and every ruling: brief, branch, items done
  (commits), current item and step, uncommitted work, what you tried and learned that isn't in the
  code, instances in use, the exact next step. A fresh subagent must be able to carry on from it.

## Finishing

Before saying the brief is done:

1. **Verify:** run the brief's suites after the last change (E2E twice at the end, as the brief
   says) and keep the verbatim summary lines.
2. **Completion report** (your final message, not a file in the repository): a table of **every**
   item in the brief with Status (done / partial / skipped) and Evidence (test names, verbatim
   command output, or the reason). Anything not fully done is partial or skipped, with the reason.
   Then a **Ledger**: every ruling with what it costs if wrong, every break-it-once with its quoted
   failure, every test you changed and why, and anything that went wrong along the way (failed
   approaches, flaky runs, a mistake you made). Report it even if it looks bad: an unreported
   deviation found later costs far more trust than one you name.
3. Claims must match the output you ran. "Done" without evidence counts as not done.
