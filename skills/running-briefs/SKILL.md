---
name: running-briefs
description: Use when launching an agent brief session, watching running briefs, when a watcher reports, or when an agent session asks a question, needs a permission, stalls or errors
---

# Running briefs

## Overview
Launch with the scripts, watch the whole session tree in the background, and act on what the
watcher reports. A parent session that looks busy proves nothing: a watcher that polls only the
parent misses a dead subagent.

## Launch
1. `bash scripts/models.sh --project <p>`: the allocation must print with no problems
   (per-brief changes: `--role role=provider/model`).
2. `bash scripts/start-brief.sh --project <p> --tag <tag> --brief <path>` (the brief must be
   committed on `brief/<tag>` in the owner repo, see `writing-briefs`; pushes the target branch
   and `brief/<tag>` first, pins models, sends the launch message, saves the session id). `--help` for the
   rest; `--dry-run` shows the message.

## Resume a dead brief
A parent session whose provider refuses it (402, quota, authentication) cannot be moved to another
model: its model is pinned, and a "continue" prompt fails the same way. The way on is a new
session that carries on from the worktree and `state.md` (implementer rules: "Resumable from
disk"):
`bash scripts/start-brief.sh --project <p> --tag <tag> --brief <path> --resume --role implementer=<provider/model>`
(add `--no-push` if the target branch is unchanged). The old session id becomes `sid.prev<n>`, so
`brief-cost.sh` keeps counting it and the watcher follows the new `sid`; the old launch message is
kept as `launch.txt.prev<n>`. Restart the watcher afterwards. Check first that the worktree
exists in the agent clone and that the fallback's subscription is live (`models.sh`). If the
session never got its launch message, the launcher keeps it as `sid.failed-<n>` and writes no
`sid`: just launch again.

## Branches implemented outside the sandbox
A Claude subagent implements in the owner's repo (rules: `implementer/claude-subagent-rules.md`).
This implementer is trusted like you: its builds and tests run with your rights. Use it only on
repos whose tests you would run yourself.
`bash scripts/start-claude-brief.sh --project <p> --tag <tag> --brief <path> --first-instance K`
creates its worktree on `brief/<tag>` and prints the prompt to give to the Agent tool (stderr
has the review base). Its reviews run sandboxed: `bash scripts/start-review.sh --project <p>
--tag <tag> --branch brief/<tag> --base <sha> --role task_review|final_review --brief <path>
[--extra "<what to judge in particular>"]` (`--prompt <file>` for your own prompt; `--help`). The
review session fetches the tip into the agent clone as `review/<tag>-<sha7>`; the script prints
`verify and accept: review/<tag>-<sha7>` on stderr and writes it to `review-ref.txt` in the
`<tag>-review` state folder. Use that name, never a guess: `agent-sync.sh fetch`, `diff` and `verify`
take `agent/review/<tag>-<sha7>`, `accept` takes `review/<tag>-<sha7>`. (An OpenCode implementer's
branch is `agent/brief/<tag>` / `accept brief/<tag>`.) After the implementer fixes findings, never
start a second review for the new tip: run `bash scripts/start-review.sh --refetch --project <p>
--tag <tag> --branch brief/<tag>`, which pushes it and has the existing review session only fetch
it, and use the new ref it prints (the old one is stale).

**Busy limits:** a subscription with `"max_busy_sessions"` in models.json (Z.ai: 1, its 5-hour
window can't take two heavy sessions) is skipped while that many of its sessions are busy;
start-brief.sh and start-review.sh take the role's next model and say so.

## Watch
Run `bash scripts/watch.sh --project <p> <tag>...` with Claude Code's **`run_in_background`**
and **`timeout: 7200000`** (the default background limit is 30 min; the watcher runs 115), never with `&` (a `&` job is invisible to the harness and dies with the shell). It covers every
running brief and every subagent below it. Restart it after every exit you have handled.
Claude Code stops background commands at 2 hours (the maximum `timeout`) and then advises not to
restart; for a watcher, ignore that advice. If a brief's latest session or subagent has activity
in the last 15 minutes (the watcher's stall threshold, `--stall-min`), restart the watcher at
once, without asking, as often as needed until the brief finishes; mention the restart in one
line. If nothing has moved for 15 minutes, treat it as exit 7 (stalled) instead.

Never `sleep` or poll in a foreground call to wait for an agent, the watcher or verify; start
the watcher or verify with `run_in_background` and act when it exits. The harness wakes you.

Only tags that are still running: drop a tag that has gone idle (exit 0, 9) or been accepted
before restarting, or the watcher exits again at once on its idle. One watcher per brief: a second
one for the same tag refuses to start (exit 2, pid file `watch.pid` in the brief's state folder);
stop the old one first. The watcher reads messages newest-first by `time.created`, so it does not
depend on the order the server lists them in.

| 0 idle | The outcome is a success (`succeeded`): `verifying-and-accepting`. Exit 0 is never an idle that ended in an error: those are exit 9. |
| 1 timeout | nothing happened; restart the watcher |
| 2 usage error | the watcher did not start: no `sid` for a tag, a bad tag or project, bad config, or the brief is already being watched. The message says which; fix it, then start the watcher. (A script `die` anywhere uses 2.) |
| 4 permission | (only requests from the watched briefs' sessions stop the watcher; a request from any other session is printed once as information and answered by whoever runs that session) read the resource; `bash scripts/answer.sh permission <s> <id> once\|reject "<why>"`. Never allow paths outside the clone and `/tmp`. These rules are guard rails, not a boundary: the agent runs as the same user as the OpenCode server and can read its password, so it could answer its own requests. The boundary is the agent user, the sandbox and your diff review. |
| 5 question | answer from the brief and the rules with `answer.sh form`; ask the owner only for decisions below |
| 6 subagent error | read that child's last messages first, then prompt the brief's session: "Subagent `<s>` ended with `<error>` at `<time>`; check its work in git and continue." Quota errors: the fallback model in the launch message applies. |
| 7 stalled | inspect the children. A child whose last tool calls completed with no model reply since is a hung model request: `bash scripts/answer.sh interrupt <child>`; the parent sees the subagent cancelled and retries. A tool call shown as `running` for 15 minutes is usually an unanswered permission request or question: run `bash scripts/answer.sh pending <brief's session>` first and answer what it lists (only `watch.sh` reports permissions; a home-made watcher misses them). Only if nothing is pending and the tool's process is gone: `answer.sh interrupt` the session, wait for `idle`, then prompt it; a prompt sent while it is busy is queued and dropped by the interrupt. Otherwise as 6. |
| 8 server down | tell the owner; nothing else works until it is back. If the report says `API LOCK STUCK`, the server is fine: another script (a second watcher, a `brief-cost.sh`, a hung wrapper) holds `<state dir>/api.lock`; find and end it, then restart. |
| 9 brief session error | The brief's own session failed (provider error such as 402, quota or authentication) or went idle with an outcome that is not a success. **Never verify it.** Show the owner the provider and the message from the report. On 402 or a quota error tell the owner at once: the session's model is pinned and the provider refuses it, so prompting the same session fails again; resume on the fallback model from the launch message (see Resume a dead brief); a pay-per-use fallback needs the owner's yes and `--allow-paid`. Other errors: read the last messages, then prompt the session to continue (if it errors again, resume). |
| 10 watcher blind | The watcher could not read the brief's messages for 3 polls (the report says why: session not on the server, empty message list, list fetch failing). The brief may be fine; restarting will not help until the cause is fixed. Check the server and `sid` (`start-brief.sh` writes `sid` only after the launch message is accepted), then restart. |

Send prompts with the API (`POST /api/session/<sid>/prompt` `{text}`, via `oc_api` in
`scripts/lib/api.sh`).

## Parallel briefs: integrate early
While two or more briefs run, run `bash scripts/integrate.sh --project <p>` after each watcher
exit (it exits 1 on a conflict, 2 when it could not run, e.g. the fetch failed; it shares a lock with `agent-sync.sh fetch`). It checks, in git's object database only (no build,
no agent code run), that each brief merges into the target and every pair merges with each other.
On a conflict: tell both agents which files and lines clash and how to keep their changes apart,
before either is accepted.

## Decide or ask
Decide yourself: anything the brief, the project's AGENTS.md or the harness rules answer.
Ask the owner: outward or irreversible steps (pushes to shared remotes, merges to main,
deleting data), pay-per-use models (`--allow-paid` only with their yes), design changes the brief didn't settle.

## Updating a brief's branch
When the target branch moved: the agent runs `git fetch origin` and
`git merge --no-edit origin/<target>` into its branch, re-runs the suites, and reports.
**Never tell an agent to rebase**: rebase is denied by the session rules, and accept needs the
agent's commits unchanged.
