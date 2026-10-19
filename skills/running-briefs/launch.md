Read AGENTS.md first and follow it, together with the harness rules in your instructions. Start with `git pull --ff-only origin {TARGET}`, then implement `{BRIEF}` exactly as that brief describes: one commit per item, TDD, break-it-once checks, independent review, completion report.

Work only in your own worktree: `git worktree add .worktrees/{TAG} -b brief/{TAG} origin/{TARGET}`, and do everything there. {E2E} Stop only your own instances. Do not push anywhere; commit locally.

Reviewer findings are not yours to grade: never downgrade, re-grade or "accept as limitation" a reviewer's Critical or Important finding, and never one that matches a test, measurement or piece of evidence the brief requires. Fix it, or, if you believe the finding is wrong or impossible to satisfy, stop and report it with the evidence; the orchestrator rules. A skill's "re-grade by effect" step does not apply to you. Claims in commits and reports must match the output you ran (quote totals verbatim). Run test suites yourself in the foreground, never through a subagent or a background runner. Reports go in your final message, never as files in the repository. Never amend, squash or otherwise rewrite a commit once made; fixes and review follow-ups go in new commits on top.

{MODELS}

{EXTRA}
