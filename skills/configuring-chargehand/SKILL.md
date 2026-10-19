---
name: configuring-chargehand
description: Use when a Chargehand script says it is not configured, or when a subscription, a model choice, a forbidden tool or a project changes
---

# Configuring chargehand

## Overview
The config is three files the owner never writes by hand. You find what's missing, offer
choices you have looked up, and write and check the files. Guessing a model or a path is the
failure this skill exists to prevent.

## The files (`~/.config/chargehand/`)
| File | Holds |
|---|---|
| `config.json` | `server_url`, `server_user`, `server_password` (how to get it), `agent_user`, `launcher`, `forbidden_tools`, `superpowers` (default true: setup adds the Superpowers plugin for the agent) |
| `models.json` | `subscriptions` (provider → `pricing`, optional `ends`, `max_busy_sessions`, `"pay_per_use": true` for a provider billed per token), `roles` (implementer, task_review, final_review, low_level → ordered model lists) |
| `projects/<name>.json` | paths, branch, E2E and verify commands, toolchain, self-test extras, optional `roles` override |

Every key is shown in `examples/` at the plugin root. Roles never go in `config.json`.

## Steps
1. `bash scripts/check-config.sh [--project <name>]`: the list of what is missing.
2. **Password source first** (everything else needs the server). Ask which form: an environment
   variable, a 0600 file, a command that prints it, or a wrapper that substitutes a token
   (e.g. `{"wrapper": ["tswap", "run"], "token": "{{name}}"}`). Never write, echo or ask for the
   value itself.
3. **Subscriptions and models from the server, not memory:**
   `bash scripts/check-config.sh --available-models` lists `provider/model<TAB>family`. Ask which
   providers are flat-rate subscriptions and set `"pay_per_use": true` on every other one: the
   scripts never pick such a model unless the owner says so (`--allow-paid`). Then fill each role
   by offering that list's models. Reviewers must come from a different family than the
   implementer. `pricing` is optional at first; costing shows "no rate" until a retro measures it.
4. **Project values from the repo:** propose `repo`, `target_branch`
   (`git -C <repo> branch --show-current`), test and E2E commands (read its README/AGENTS.md),
   toolchain paths. Ask only for what you couldn't find.
5. **Forbidden tools:** offer the deployment and secret tools you saw on the machine (cluster
   CLIs, secret managers). `sudo` is always forbidden; git push and history rewrites are already
   denied by the rules.
6. Ask **one question at a time** (AskUserQuestion, found values as options).
7. Write the files, run `check-config.sh --project <name>` and
   `bash ../running-briefs/scripts/models.sh --project <name>`, show the owner both outputs.
8. New machine? Continue with `setting-up-agent-sandbox`. Changed a project or the rules? The
   owner re-runs setup (the launcher reads root-owned copies).

Re-running edits the existing files; never start over and lose the owner's earlier answers.

## Red flags
| Thought | Instead |
|---|---|
| "I remember their plans" | Plans change. List them from the server and ask. |
| "One batch of questions is faster" | One at a time, with options. |
| "I'll put the password in config.json" | Only how to get it. |
