---
name: writing-briefs
description: Use when handing implementation work to another agent, or planning several briefs to run in parallel
---

# Writing briefs

## Overview
A brief is the agent's whole plan: the design is decided, every item has a test that measures
what the owner will see, and anything not asked for is out of scope. Agents implement exactly
what it says, so every number in it must be right.

## Shape
```
# Brief <id>: <outcome>
Read AGENTS.md first. One commit per item, TDD, break-it-once, E2E twice at the end, final review.
## Item 1: <one outcome>
  What is wrong now (evidence: screenshot, measured value, file:line).
  What to do (the design, exact values).
  Tests: what is measured, at which sizes/inputs, the tolerance. Break-it-once: what to revert, which test must fail.
## Item 2 ...
## Out of scope
```

## Rules
- **Work numbers out, never estimate.** Viewports: CSS px = physical px ÷ scaling
  (3840 × 2160 at 150 % = 2560 × 1440). Show the arithmetic in the brief.
- **Measure what the user perceives**: characters per line, gaps in px, marker positions,
  boxes inside boxes; never only "the CSS has value X" or "looks right".
- **Tests never depend on database state**: each test creates the data it asserts on, scoped so
  other tests' rows can't change the answer (the 03i sidebar test failed for that).
- **Break-it-once per key test**: name the line to revert and the test that must then fail.
- **Owner-visible facts first**: reproduce the owner's report in the brief; if you guessed a
  cause, say so and make the agent confirm it before fixing.

## Sets of briefs in parallel
- Design like a team: contracts (interfaces, names, files) decided first, in the briefs.
- **File ownership**: no two briefs edit the same file; if they must, serialise them.
- Serialise only on real dependencies; everything else runs at once in separate worktrees.
- Repeated changes: brief the first instance, then items "apply pattern from commit `<sha>`
  to <targets>" for the cheap pattern-applier subagent.

## Before handing over
Commit and push the brief (`agent-sync.sh push`), then `running-briefs`.
