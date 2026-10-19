Read AGENTS.md first and follow it, together with the harness rules in your instructions. You are resuming brief `{BRIEF}`: the previous session ({PREVIOUS}) stopped before it finished (a provider error, quota or an interruption), and you carry on from the files alone.

Work only in the existing worktree `.worktrees/{TAG}` (branch `brief/{TAG}`); do not create a new one. Start by reading `.worktrees/{TAG}/.superpowers/state.md` (see the implementer rules: "Resumable from disk"), then `git status` and `git log origin/{TARGET}..HEAD` in that worktree. Items that are committed are done; do not redo them. Continue with the current item at the step `state.md` names, treating uncommitted work as unreviewed. Never amend, squash or otherwise rewrite a commit once made; new work goes in new commits on top. If `state.md` is missing, reconstruct the state from the commits against the brief and say so in your report. The rest of the launch rules still apply: reviewers' findings are not yours to grade, test suites run in the foreground yourself, reports go in your final message, nothing is pushed. {E2E} Stop only your own instances.

{MODELS}

{EXTRA}
