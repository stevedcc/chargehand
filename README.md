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

Ever hit your coding plan's limit halfway through a task, and found the next tier costs two or
five times as much? Ever wondered whether a second, cheaper plan from another provider would do,
if only switching between them weren't such a hassle? Or whether you should be paying for API
tokens at all, when flat-rate coding plans (Z.ai's GLM, Kimi, OpenCode Go, Xiaomi's MiMo, ...)
cost a fraction of that?

Chargehand takes the hassle out of using several plans, so you can grow by adding a small one
instead of upgrading the one you have:

- **Your subscriptions, combined, without babysitting.** You describe your plans once
  (`models.json`): what each costs, how it's metered, when it ends. Every role has a first choice
  and fallbacks across plans; when one plan hits its quota or rate limit mid-brief, the session
  carries on with the next, and the switch is recorded. A plan past its end date drops out by
  itself. You don't watch meters; you read the retro. Outgrow a plan? Add another small one as
  a fallback; it's used from the next brief.
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

### Other implementers, parallel briefs and busy plans

- **A Claude Code subagent can implement instead of an OpenCode session** (for example when a
  plan's allowance is spent, or for work that needs a stronger model). It works in its own
  worktree under `implementer/claude-subagent-rules.md`; `start-review.sh` pushes its branch to
  the agents' mirror and starts an OpenCode review of it, so verify and accept stay the same.
- **Briefs can run side by side.** `integrate.sh` test-merges their branches early (`git merge-tree`),
  so a conflict shows up while both briefs are still running, not at accept time.
- **Plans with a short window** (for example a 5-hour quota) can declare `max_busy_sessions`;
  the model choice then passes to the next model in the role's list instead of queueing.
- **Interrupted sessions resume:** implementers keep `state.md` and work-in-progress notes, and
  the running-briefs skill says how to restart a stuck parent, a dead tool call or a watcher at
  its time limit.

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

Once per machine; steps 4 and 5 again for each further project.

1. **Prerequisites** (your account): `bubblewrap`, `git`, `jq`, `curl`, `python3`, and rootless
   Podman if your tests use Testcontainers. Claude Code, ideally with Superpowers for writing
   briefs:
   ```
   /plugin install superpowers@claude-plugins-official
   ```
2. **Install Chargehand** in Claude Code:
   ```
   /plugin marketplace add stevedcc/chargehand
   /plugin install chargehand@chargehand
   ```
3. **Configure it.** Ask Claude to "configure Chargehand". The `configuring-chargehand` skill asks
   for what it can't find and writes three files under `~/.config/chargehand/` (`examples/` has
   one of each):
   - `config.json`: the OpenCode server URL, how its password is supplied (environment variable,
     file, command, or a secret manager's wrapper), the agent user's name, and tools agents must
     never run. `"superpowers": false` opts out of step 4's Superpowers plugin;
   - `models.json`: your subscriptions, how each is priced, and which models do which job, with
     fallbacks;
   - `projects/<name>.json`: the project's paths, branches, build, test and E2E commands, and
     toolchain folders.
4. **Create the agent user and sandbox.** Ask Claude to "set up the agent sandbox for <project>";
   it checks the config and gives you one command to run yourself:
   ```
   sudo bash <plugin>/skills/setting-up-agent-sandbox/scripts/setup-agent-user.sh --project <name>
   ```
   It creates the agent user, its clone of your repository and the read-only mirror it pulls
   from, the root-owned launcher `/usr/local/bin/chargehand-sandbox` and project settings
   (`/etc/chargehand/`), a sudoers entry allowing only the launcher's fixed forms, and the agent's
   OpenCode config: Chargehand's rules, the two pinned helper subagents, and the
   [Superpowers](https://github.com/obra/superpowers) plugin (added if missing; if your own
   `~/.config/opencode/opencode.json` exists, it is the starting point, providers included).
5. **Give the agent user OpenCode and your subscriptions** (first time only; setup prints these):
   ```
   sudo -iu <agent>
   curl -fsSL https://opencode.ai/v2/install | bash
   source ~/.bashrc
   opencode auth login --standalone <provider>     # once per subscription
   exit
   ```
6. **Prove the boundaries:**
   ```
   sudo -n -u <agent> /usr/local/bin/chargehand-sandbox --selftest --project <name>
   ```
   Every line must say `ok`. A `FAIL` is a hole in the sandbox, not noise.
7. **Start the OpenCode server** in the sandbox, with its password from wherever you keep secrets:
   ```
   OPENCODE_SERVER_PASSWORD="$(secret-tool lookup service opencode)" sudo -n -u <agent> /usr/local/bin/chargehand-sandbox
   ```
8. **Run a brief.** Ask Claude to write one (`writing-briefs`) and run it (`running-briefs`); it
   launches, watches, answers, verifies (`verifying-and-accepting`) and writes the retro
   (`writing-retros`).

Re-run step 4 (and 6) after changing a project's config, `implementer/` or the launcher: agents
only ever see the root-owned installed copies.

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
