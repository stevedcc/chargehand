# Chargehand

A Claude Code plugin for handing implementation work to headless
[OpenCode](https://opencode.ai) agents, and taking back only what passes.

Claude Code is the site manager: it writes a brief, launches an OpenCode session with pinned
models, watches that session and every subagent under it, answers its questions, then verifies the
result in a sandbox and accepts it by fast-forward. The agents (any models OpenCode can reach,
typically cheaper subscription models) do the implementing and reviewing. They run as their own
user, in their own clone, and never get write access to anything of yours.

> **Status: early.** It has run one real project (a .NET/Blazor blog, a few dozen briefs) for one
> person on Linux. It works, and it has rough edges. Expect to read the scripts.

## Why

Letting agents run unattended for hours is useful, and unsafe by default: an agent with your
shell can push, delete, read your keys, or quietly weaken the tests that are supposed to catch
it. Chargehand's answer is a pipeline where the checks are out of the agent's reach:

- **The agent can't touch your work.** It commits to its own clone. Its branch reaches you only
  through `accept`, a fast-forward to the exact commit that passed verification.
- **The agent can't change how it is judged.** Verification runs a clean checkout in the sandbox
  with build and test commands from a root-owned file that setup writes. Nothing in the
  repository, and nothing the agent can edit, decides what "passed" means.
- **The agent can't plant code for you to run.** Its clone shares no `.git` with yours, so there
  are no hooks or git config for it to leave behind. You fetch its work through `upload-pack`,
  which runs no hooks and ignores the clone's config, and verification starts from a fresh clone
  with `core.hooksPath=/dev/null`. Until you accept, you never build, test or run agent-written
  code as yourself; reading diffs is safe.
- **The orchestrator never trusts a status.** The watcher follows the whole session tree and
  reports stalls, subagent errors, questions and permission requests, so a session that looks
  busy but is stuck gets noticed.

## How a brief runs

```
 you ──▶ Claude Code ── writes brief ──▶ start-brief ──▶ OpenCode session (agent user, sandbox)
                                                          ├─ implementer subagents
               ▲                                           ├─ task reviewers
               │                                           └─ final reviewer
         watch ┤◀── stalls, errors, questions, permissions ┘
               │
               ▼
        verify (clean checkout, root-owned commands, in the sandbox)
               │ passed: SHA recorded
               ▼
        accept (fast-forward to that SHA only)  ──▶  retro (what went wrong, cost per model)
```

## The skills

| Skill | Does |
|---|---|
| `configuring-chargehand` | Writes your three config files, asking for what it can't find |
| `setting-up-agent-sandbox` | Creates the agent user, its clone and mirror, and installs the sandbox launcher (one `sudo` run) |
| `writing-briefs` | How to write a brief an agent can't misread: measured tests, a check that must fail when the fix is removed, no estimates |
| `running-briefs` | Launches with pinned models and a launch message, watches the tree, answers questions and permission requests |
| `verifying-and-accepting` | Sandboxed verification and the fast-forward accept |
| `writing-retros` | A blameless retro per brief, with cost per model (`brief-cost.sh`) |

The implementer side (`implementer/`) holds the rules every agent session reads, and two cheap
subagents: a test runner, and a pattern applier for repeated mechanical changes.

## The sandbox

`chargehand-sandbox` runs OpenCode's server (and verification) in
[bubblewrap](https://github.com/containers/bubblewrap) as the agent user. Inside, it can see:

- each project's agent clone (read-write; read-only when verifying) and a read-only mirror;
- a private `/tmp`, the project's toolchain folders, OpenCode's own state;
- the agent user's rootless Podman socket (for Testcontainers);
- `/usr` and `/etc` read-only.

Every other home directory does not exist, and `$HOME` is in memory. On top of that, the session
permissions deny `sudo`, `git push`, `git remote` and any tool you list as forbidden, and file
access outside the clone and the toolchain needs an answer from the orchestrator. The server
password never appears on a command line.

**What it does not do:** the sandbox has network access (the agents need their model APIs), so an
agent could send what it can read (its clone) somewhere. Treat the clone as something an agent may
leak, and keep secrets out of the repository, which you should anyway.

## Models and cost

`models.json` names your subscriptions and assigns models to four roles: implementer, task
review, final review and low-level work, each with fallbacks used only on quota, rate-limit or
authentication errors. The launch message pins them, so a session can't drift to another model.
Each subscription declares how it's priced (metered against a plan, per token, or a blended
rate), and `brief-cost.sh` turns a brief's session tree into cost per model.

In the author's use, a typical brief (a few hundred lines of code and tests, three to five task
reviews, a final review, the end-to-end suite run twice) costs one to two dollars of subscription
value.

## Requirements

- Linux with `bubblewrap`, `sudo` (once, for setup), `git`, `jq`, `curl`, `python3`
- [Claude Code](https://claude.com/claude-code), and OpenCode 2.x with at least one provider
- A way to supply the OpenCode server password: an environment variable, a file, a command that
  prints it, or a wrapper that substitutes a token (for example a secrets manager's `run`)

## Install

```
/plugin marketplace add stevedcc/chargehand
/plugin install chargehand@chargehand
```

Then ask Claude to "configure Chargehand". It writes three files under `~/.config/chargehand/`:

- `config.json`: the OpenCode server, how its password is supplied, the agent user, forbidden
  tools;
- `models.json`: subscriptions, pricing, and which model does which job;
- `projects/<name>.json`: one per project (paths, branches, build, test and E2E commands,
  toolchain).

`examples/` has one of each. Then ask it to set up the sandbox for a project; it shows you the one
`sudo` command to run.

## Tests

```
bash tests/run.sh
```

Plain bash against a fake OpenCode API and throwaway git repositories; no network, no root.
`tests/skills/` has the scenarios each skill was checked against.

## Name

A chargehand is the working foreman of a small crew on a building site: they hand out the jobs,
check the work, and answer to the site manager.

## License

MIT
