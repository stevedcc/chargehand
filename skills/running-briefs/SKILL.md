---
name: running-briefs
description: Use when launching an agent brief session, watching running briefs, when a watcher reports, or when an agent session asks a question, needs a permission, stalls or errors
---

# Running briefs

## Overview
Launch with the scripts, watch the whole session tree in the background, and act on what the
watcher reports. A parent session that looks busy proves nothing: in 03h a subagent died on an
empty shell call and the parent waited an hour.

## Launch
1. `bash scripts/models.sh --project <p>`: the allocation must print with no problems
   (per-brief changes: `--role role=provider/model`).
2. `bash scripts/start-brief.sh --project <p> --tag <tag> --brief <path>` (pushes the target
   branch first, pins models, sends the launch message, saves the session id). `--help` for the
   rest; `--dry-run` shows the message.

## Watch
Run `bash scripts/watch.sh --project <p> <tag>...` with Claude Code's **`run_in_background`**
and **`timeout: 7200000`** (the default background limit is 30 min; the watcher runs 115), never with `&` (a `&` job is invisible to the harness and dies with the shell). It covers every
running brief and every subagent below it. Restart it after every exit you have handled.

| Exit | Do |
|---|---|
| 0 idle | `verifying-and-accepting` |
| 1 timeout | nothing happened; restart the watcher |
| 4 permission | read the resource; `bash scripts/answer.sh permission <s> <id> once\|reject "<why>"`. Never allow paths outside the clone and `/tmp`. |
| 5 question | answer from the brief and the rules with `answer.sh form`; ask the owner only for decisions below |
| 6 subagent error | read that child's last messages first, then prompt the brief's session: "Subagent `<s>` ended with `<error>` at `<time>`; check its work in git and continue." Quota errors: the fallback model in the launch message applies. |
| 7 stalled | inspect the children. A child whose last tool calls completed with no model reply since is a hung model request: `POST /api/session/<child>/interrupt?resume=false`; the parent sees the subagent cancelled and retries (07c, 2026-10-10). Otherwise as 6. |
| 8 server down | tell the owner; nothing else works until it is back |

Send prompts with the API (`POST /api/session/<sid>/prompt` `{text}`, via `oc_api` in
`scripts/lib/api.sh`).

## Decide or ask
Decide yourself: anything the brief, the project's AGENTS.md or the harness rules answer.
Ask the owner: outward or irreversible steps (pushes to shared remotes, merges to main,
deleting data), paid pay-per-use models, design changes the brief didn't settle.

## Updating a brief's branch
When the target branch moved: the agent runs `git fetch origin` and
`git merge --no-edit origin/<target>` into its branch, re-runs the suites, and reports.
**Never tell an agent to rebase**: rebase is denied by the session rules, and accept needs the
agent's commits unchanged.
