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

## Branches implemented outside the sandbox
A Claude subagent implements in the owner's repo (rules: `implementer/claude-subagent-rules.md`).
Its reviews run sandboxed: `bash scripts/start-review.sh --project <p> --tag <tag> --branch <b>
--base <sha> --role task_review|final_review --prompt <file>` (`--help`). The review session
fetches the branch into the agent clone, so `agent-sync.sh fetch`/`verify` then work as usual.

**Busy limits:** a subscription with `"max_busy_sessions"` in models.json (Z.ai: 1, its 5-hour
window can't take two heavy sessions) is skipped while that many of its sessions are busy;
start-brief.sh and start-review.sh take the role's next model and say so.

## Watch
Run `bash scripts/watch.sh --project <p> <tag>...` with Claude Code's **`run_in_background`**
and **`timeout: 7200000`** (the default background limit is 30 min; the watcher runs 115), never with `&` (a `&` job is invisible to the harness and dies with the shell). It covers every
running brief and every subagent below it. Restart it after every exit you have handled.
Claude Code stops background commands at 2 hours (the maximum `timeout`) and then advises not to
restart; for a watcher, ignore that advice. If a brief's latest session or subagent has activity
in the last 20 minutes, restart the watcher at once, without asking, as often as needed until the
brief finishes; mention the restart in one line. If nothing has moved for 20 minutes, treat it as
exit 7 (stalled) instead.

| Exit | Do |
|---|---|
| 0 idle | `verifying-and-accepting` |
| 1 timeout | nothing happened; restart the watcher |
| 4 permission | read the resource; `bash scripts/answer.sh permission <s> <id> once\|reject "<why>"`. Never allow paths outside the clone and `/tmp`. These rules are guard rails, not a boundary: the agent runs as the same user as the OpenCode server and can read its password, so it could answer its own requests. The boundary is the agent user, the sandbox and your diff review. |
| 5 question | answer from the brief and the rules with `answer.sh form`; ask the owner only for decisions below |
| 6 subagent error | read that child's last messages first, then prompt the brief's session: "Subagent `<s>` ended with `<error>` at `<time>`; check its work in git and continue." Quota errors: the fallback model in the launch message applies. |
| 7 stalled | inspect the children. A child whose last tool calls completed with no model reply since is a hung model request: `POST /api/session/<child>/interrupt?resume=false`; the parent sees the subagent cancelled and retries (07c, 2026-10-10). A tool call shown as `running` for 20 minutes is usually an unanswered permission request: check `GET /api/session/<s>/permission` first and answer it (only `watch.sh` reports permissions; a home-made watcher missed two in 09a, 2026-10-12). Only if none is pending and the tool's process is gone: `interrupt` the session, wait for `idle`, then prompt it; a prompt sent while it is busy is queued and dropped by the interrupt. Otherwise as 6. |
| 8 server down | tell the owner; nothing else works until it is back |

Send prompts with the API (`POST /api/session/<sid>/prompt` `{text}`, via `oc_api` in
`scripts/lib/api.sh`).

## Parallel briefs: integrate early
While two or more briefs run, run `bash scripts/integrate.sh --project <p>` in the background
every 10 minutes (it exits 1 on a conflict). It checks, in git's object database only (no build,
no agent code run), that each brief merges into the target and every pair merges with each other.
On a conflict: tell both agents which files and lines clash and how to keep their changes apart,
before either is accepted.

## Decide or ask
Decide yourself: anything the brief, the project's AGENTS.md or the harness rules answer.
Ask the owner: outward or irreversible steps (pushes to shared remotes, merges to main,
deleting data), paid pay-per-use models, design changes the brief didn't settle.

## Updating a brief's branch
When the target branch moved: the agent runs `git fetch origin` and
`git merge --no-edit origin/<target>` into its branch, re-runs the suites, and reports.
**Never tell an agent to rebase**: rebase is denied by the session rules, and accept needs the
agent's commits unchanged.
