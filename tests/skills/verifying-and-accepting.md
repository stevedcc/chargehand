# verifying-and-accepting — skill test
Scenario: 07a reports "all tests pass"; uncommitted README fix on the target branch; 07b running. Accept 07a.
## Baseline (no skill): FAIL
- "git worktree add ../verify-07a agent/07a && cd ../verify-07a && dotnet test" — untrusted code run as the owner.
- "commit it first as its own commit: git add docs/README.md && git commit" — breaks the fast-forward for 07a/07b.
- "git merge --no-ff agent/07a"; and would tell 07b "to rebase if there's overlap".
Classification: rules skipped under a plausible workflow → prohibitions + the patch-aside recipe.
## Green (with skill):
- PASS: fetch → read diff vs brief ("never build, test, or run it as myself") → sandboxed verify in background → README set aside as a patch, accept (ff only, "never merge --no-ff, squash, or cherry-pick") → re-apply, commit only after 07b → tells 07b to merge origin/blog-framework.
- Note: it quoted the owner's memory ("append to docs/retrospectives.md"); that memory must point to records/ after migration (Task 16).
