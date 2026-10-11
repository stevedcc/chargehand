---
name: verifying-and-accepting
description: Use when an agent brief reports done, before accepting, merging or building its commits
---

# Verifying and accepting

## Overview
An agent's "all tests pass" is a claim from an untrusted contributor. You read its diff, the
sandbox verifies it as the agent user, and accept is a fast-forward. Running the agent's code as
yourself, trusting the report, and committing on the target branch while a brief waits are the
three mistakes this skill prevents.

## Steps
1. `bash scripts/agent-sync.sh --project <p> fetch` (upload-pack only; safe).
2. **Read the diff against the brief, not against the report**:
   `git diff <target>...agent/brief/<tag>`. Every item done as specified, tests measure what
   the brief says, no assertion weakened, nothing outside the brief's scope.
3. `bash scripts/agent-sync.sh --project <p> verify agent/brief/<tag>` with
   `run_in_background`: a clean checkout built and tested **as the agent user, in the sandbox**.
   Its summary lines are the evidence.
4. `bash scripts/agent-sync.sh --project <p> accept brief/<tag>`: fast-forward only, and only to
   the exact commit the last passing verify ran (it refuses if a later fetch moved the branch).
   - "not a fast-forward": the agent merges `origin/<target>` into its branch (never rebase),
     then fetch, read the new diff, verify again.
5. `writing-retros`.

## While any brief is running or waiting to be accepted
**Commit nothing on the target branch.** Every commit makes the next accept a non-fast-forward
and costs a merge round. For your own pending changes:
```
git diff > /tmp/pending.patch && git checkout -- <files>   # set aside
bash scripts/agent-sync.sh --project <p> accept brief/<tag>
git apply /tmp/pending.patch                               # then commit
```
No "harmless file" exceptions: docs count.

## Never
- `build`, `test`, `run`, or open in an IDE that builds, any `agent/*` commit as yourself; not in
  a worktree, not "just once". It executes untrusted code with your rights.
- `merge --no-ff`, squash or cherry-pick agent work: accept is the fast-forward of exactly what
  was verified.
- Accept on the report alone, or with verify still running.
