---
name: setting-up-agent-sandbox
description: Use when giving headless coding agents their own user and sandbox for a repo, adding a project to it, or after editing the sandbox launcher, the implementer rules or a project's config
---

# Setting up the agent sandbox

## Overview
Agents are untrusted contributors. They run as their own unprivileged user, in their own clone,
inside bubblewrap, and **nothing they write is ever executed as the owner before accept**.
Shared repos the agent can write to, and running the agent's tests as yourself, are the two
mistakes this skill prevents.

## The fork model
```
owner repo --push--> mirror (bare, owned by the owner, read-only to the agent)
                       | agent pulls (origin)
                       v
                  agent clone (owned by the agent user; agent commits here, never pushes)
owner repo <--fetch-- agent clone   (git fetch with upload-pack only: no hooks, no config)
```
- The owner fetches agent branches into `agent/*` and **reads** diffs; that is safe.
- Agent code runs only inside the sandbox: OpenCode's server, and `verify` (a separate clean
  checkout, as the agent user). Never `build`/`test`/start agent commits as the owner, not even
  in a throwaway worktree: the code runs with the owner's rights.
- No shared group-writable repo, no shared `.git`, no agent push anywhere.
- Work reaches the owner's branch only through `verifying-and-accepting`: fetch, read, sandboxed
  verify, then a **fast-forward** of exactly the verified commits. Never merge, squash or
  cherry-pick agent work. The owner pushes only the target branch to the mirror
  (`agent-sync.sh push`), never `--all`.

## Steps
1. Config first: `bash ../configuring-chargehand/scripts/check-config.sh --project <name>`
   must pass.
2. The owner runs (one `sudo` step; give it ready to paste, never run sudo yourself):
   `sudo bash <plugin>/skills/setting-up-agent-sandbox/scripts/setup-agent-user.sh --project <name>`
   It creates the user, mirror, clone, root-owned launcher (`/usr/local/bin/chargehand-sandbox`),
   root-owned project env (`/etc/chargehand/`), rules (`/usr/local/share/chargehand/`),
   sudoers (launcher's fixed forms only) and the agent's OpenCode config. If the owner has an
   `opencode.json`, it is copied without credentials (setup lists the dropped paths): providers log
   in as the agent user, step 3.
3. First time only, as the agent user: install OpenCode and log in to each subscription provider
   (setup prints the commands).
4. Proof: `sudo -n -u <agent> /usr/local/bin/chargehand-sandbox --selftest --project <name>`
   must print only `ok` lines. Read every line; a `FAIL` is a broken boundary, not noise.
5. The owner starts the server with `OPENCODE_SERVER_PASSWORD` set, however they keep secrets.

**Re-run step 2 and 4 after any change** (the launcher's verify exit codes, lock and timeout, and `verify_timeout_min` in a project's config, only reach the agent after step 2) to `sandbox.sh`, `implementer/` or a project config:
agents only see the root-owned installed copies.

## Red flags
| Thought | Reality |
|---|---|
| "I'll just run their tests in a worktree" | That executes untrusted code as the owner. Use `verify`. |
| "A shared hand-off repo is simpler" | The agent could then write refs and hooks the owner fetches. |
| "Self-test mostly passed" | Every FAIL is a hole. Fix before any brief. |
| "I'll merge or cherry-pick their branch" | Accept is a fast-forward of what verify ran, nothing else. |
