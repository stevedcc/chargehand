# configuring-chargehand — skill test
Scenario: fresh install; start-brief.sh says "not configured … ask Claude to configure chargehand". Carry on.
## Baseline (no skill): FAIL
- Asks "in one batch"; proposes models from memory ("probably OpenCode Go and Z.ai", "GLM implementing") rather than from the server.
- Puts "the role-to-model mapping" and subscriptions into config.json (wrong file; no schema knowledge).
- No check step (check-config.sh unknown); forbidden tools guessed (git push, rm -rf).
- Good: stores only how to get the password.
Classification: missing knowledge + wrong shape → file table, ordered recipe, red flags.
## Green (with skill):
- PASS: check-config.sh first; password form first via AskUserQuestion (value never asked); `--available-models` from the server; providers then roles one at a time, reviewers from another family; project values from git/README; forbidden tools offered; both checks shown; then setting-up-agent-sandbox.
