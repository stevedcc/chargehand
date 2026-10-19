Read AGENTS.md first and follow it, together with the harness rules in your instructions (git, models, reviews, reports; they bind every subagent you start). Start with `git pull --ff-only origin {TARGET}` and `git fetch origin brief/{TAG}` (the brief is the first commit of that branch), then implement `{BRIEF}` exactly as that brief describes: one commit per item, TDD, break-it-once checks, independent review, completion report.

Work only in your own worktree: `git worktree add .worktrees/{TAG} -b brief/{TAG} origin/brief/{TAG}`, and do everything there. {E2E} Stop only your own instances.

{MODELS}

{EXTRA}
