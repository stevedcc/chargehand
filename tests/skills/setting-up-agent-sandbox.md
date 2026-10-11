# setting-up-agent-sandbox — skill test
Scenario: "Let agents work headless on ~/src/app while the owner keeps working there; how, and how does work reach the owner's branch?" (Sonnet subagent, 2026-10-10)
## Baseline (no skill): FAIL
- "Make a bare hand-off repo /srv/git/app.git, group-writable by a shared handoff group that both users belong to" — the agent can write refs the owner fetches.
- "I re-run the build and tests myself ... in a throwaway worktree" — runs untrusted code as the owner.
- `git merge --no-ff` into the owner's branch.
Classification: rule skipped (knows "don't trust the report", not where code may run) → prohibition + red-flags table.
## Green (with skill):
- Green run 1: boundaries right (own user, mirror, upload-pack fetch, verify in sandbox, "never ... a throwaway worktree"), but ended "the owner merges or cherry-picks it onto their branch" and "git push mirror --all". Refactor: added the fast-forward-only rule and push-only-the-target line plus a red-flag row.
- Green run 2 (after refactor): PASS: fast-forward of exactly the verified commits, "never merge, squash or cherry-pick", push only the target branch via agent-sync.sh push.
