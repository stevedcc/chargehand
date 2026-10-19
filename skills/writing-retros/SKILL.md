---
name: writing-retros
description: Use after accepting an agent brief, or at the end of a day with no accepted brief
---

# Writing retros

## Overview
A short, blameless entry per brief: every problem traced to an input (a brief, the rules, a
script, a model choice) and fixed there, with the brief's measured cost. "The model failed" is
never a cause; what let the failure cost time is.

## Where
`bash scripts/records-dir.sh --project <p>` prints the records folder (config.json `records_dir`,
default `~/.local/state/chargehand/<project>/records`). The retro goes in `retrospectives.md`
there (newest first, below an Open actions table; create the file with that table if missing),
the agent's Ledger section in `ledger.md`. Never in the project repo: commits there break the
next accept's fast-forward.

## Cost
`bash scripts/brief-cost.sh --project <p> --tag <tag>`: plan dollars per provider and model,
with the pricing form used (metered is exact; blended is an estimate). Add wall time (session
created → idle) and review rounds.

## Entry
```
## YYYY-MM-DD: brief <tag> (<topic>) accepted
- **Outcome:** commits, what changed for the user, final review verdict, verify summary lines.
- **Cost:** wall time; table from brief-cost.sh (form per line); review rounds.
- **Tripped on:** numbered, facts only (what happened, how long it cost).
- **Why:** same numbers; the input that produced each (your own mistakes stated plainly).
- **Change:** same numbers; the file, script or rule changed (with commit), or "none" and why.
```
Then update **Open actions**: new rows for changes not made yet; mark done rows with the brief
that did them; drop rows only on purpose, saying why.

## Example
- Tripped on: 1. A subagent died on an empty shell call; the brief stalled ~1 h.
- Why: 1. The watcher polled only the parent session, which stayed "busy".
- Change: 1. `watch.sh` walks every child session and exits 6 on a child error, 7 on no new
  message for 15 min (commit <sha>).
