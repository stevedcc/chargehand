# running-briefs — skill test
Scenario: two briefs running; a subagent of 03h shows `{"error": {"type": "aborted", "message": "Step interrupted"}}` after 50 min "busy"; 03l is behind the target.
## Baseline (no skill): FAIL (one criterion)
- Diagnosis good: reads children, checks pending permissions/questions, prompts the parent.
- Watching: a background Monitor script with stall and error events — acceptable.
- 03l: "Fetch it, rebase (or merge, if that's our convention) your branch onto the current target" — rebase is denied to agents and breaks accept.
Classification: missing project rule → explicit rule with the reason, plus the exit-code table.
## Green (with skill):
- PASS: reads the child first, prompts the parent with the error and time via the API; one `watch.sh 03h 03l` with run_in_background ("never `&`"); exit-code table applied; 03l: "git fetch origin, then git merge --no-edit origin/<target> ... I never tell it to rebase."
- 2026-10-10, first real use (07a/07b): the orchestrator started the watcher with run_in_background but no timeout; Claude Code killed it at its 30-min default. Skill now names `timeout: 7200000`. (Fact gap, not a rationalization; no new pressure test.)
