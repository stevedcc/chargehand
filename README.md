# Chargehand

A Claude Code plugin that puts your coding subscriptions to work as one crew: headless
[OpenCode](https://opencode.ai) agents implement and review on the plans you already pay for,
each job on the model best suited to it, and you take back only what passes.

Claude Code is the site manager: it writes a brief, launches an OpenCode session with pinned
models, watches that session and every subagent under it, answers its questions, then verifies the
result in a sandbox and accepts it by fast-forward. The agents (any models OpenCode can reach,
typically cheaper subscription models) do the implementing and reviewing. They run as their own
user, in their own clone, and never get write access to anything of yours.

> **Status: early.** It has run one real project (a .NET/Blazor blog, a few dozen briefs) for one
> person on Linux. It works, and it has rough edges. Expect to read the scripts.

## Why

Most developers who use coding agents a lot end up with several subscriptions: a Claude plan, and
one or more flat-rate coding plans (Z.ai's GLM, Kimi, OpenCode Go, Xiaomi's MiMo, ...). Each has
its own quota windows, its own strengths, and its own tooling. Paying API rates instead is the
expensive way to get the same work done, and running out of a plan's window mid-task wastes the
rest of your evening. Chargehand turns that pile of subscriptions into one crew:

- **Your subscriptions, combined, without babysitting.** You describe your plans once
  (`models.json`): what each costs, how it's metered, when it ends. Every role has a first choice
  and fallbacks across plans; when one plan hits its quota or rate limit mid-brief, the session
  carries on with the next, and the switch is recorded. A plan past its end date drops out by
  itself. You don't watch meters; you read the retro. And when you outgrow a plan, you don't
  have to jump to its next tier (often several times the price): add another small plan from a
  different provider, list it as a fallback, and the extra capacity is used from the next brief.
- **Flat-rate plans instead of API bills.** All the agent work (implementing, reviewing, running
  tests) runs on subscriptions you already pay for, through OpenCode. Claude Code only plans,
  watches and accepts. Nothing is billed per token, and nothing runs into overage. Each brief's
  cost is still measured, per model, as a share of each plan, so you know what a feature costs.
- **The right model for each job.** A strong model implements; task reviews and the final review
  go to models from a **different family** than the implementer (Chargehand refuses an allocation
  where they match, so a model never grades its own work); test runs and repetitive mechanical
  edits go to a cheap, fast model. Change any role per project or per brief.
- **Briefs that hold up when nobody is watching.** Each brief is a written plan with measured
  tests, a check that must fail when the fix is removed, and an independent review before you
  see it. You come back to finished, reviewed, verified work, or to one clear question.

Running agents unattended for hours is also unsafe by default: an agent with your shell can push,
delete, read your keys, or quietly weaken the tests meant to catch it. So the checks sit out of
the agents' reach:

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

## Built on Superpowers

Chargehand handles the plumbing: subscriptions, models, sandbox, watching, verification. **How
the agents work** comes from [Superpowers](https://github.com/obra/superpowers), a skills library
for coding agents. The implementer rules Chargehand installs (`implementer/rules.md`) send every
brief through Superpowers' `subagent-driven-development` (each item a task with a fresh
implementer and its own reviewer) and `requesting-code-review` (the independent task and final
reviews), and those workflows bring in its `test-driven-development` and
`verification-before-completion` skills. Projects can require more of them in their own
`AGENTS.md`. The rules stop agents short of `finishing-a-development-branch`: merging is yours,
through `accept`. On the orchestrating side, Claude Code with Superpowers' `brainstorming` and
`writing-plans` is a good way to get to a brief worth handing over.

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
- [Superpowers](https://github.com/obra/superpowers) installed for the agent user's OpenCode (the
  implementer rules name its skills); recommended in Claude Code too
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
