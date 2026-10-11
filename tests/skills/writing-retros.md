# writing-retros — skill test
Scenario: retro for 03h (accepted; ~1 h lost: dead subagent, watcher watched only the parent; GLM plan).
## Baseline (no skill): PARTIAL
- Good: owns the watcher gap, traces the hour to it, blameless.
- Missing: no measured cost ("a small unknown"), no Outcome/Cost/Tripped on/Why/Change structure, no concrete changed script, suggestions only ("restart automatically", "tell agents to avoid empty shell calls").
Classification: wrong shape → recipe (entry template, cost command, where it lives).
## Green (with skill):
- PASS: cost via `brief-cost.sh --project example --tag 03h` (expects "blended" for GLM); full Outcome/Cost/Tripped on/Why/Change entry in records/example; Why = the watcher design; Change = watch.sh exit 6/7 with commit; Open actions row; ledger to records.
