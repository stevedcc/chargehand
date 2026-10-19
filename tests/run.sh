#!/usr/bin/env bash
# Runs every tests/test_*.sh. Exit 0 only if all pass.
# A test that cannot run here (no bubblewrap, no Podman socket) prints a "  skip  <why>" line;
# the last line then says SKIPPED and how many, so a green run never hides an unrun layer.
# HARNESS_TESTS_STRICT=1 turns any skip into a failure (use it where the tools should exist).
cd "$(dirname "$0")" || exit 1
status=0 skipped=0 log="$(mktemp)"
for f in test_*.sh; do
    echo "== $f"
    bash "$f" 2>&1 | tee -a "$log"
    [ "${PIPESTATUS[0]}" -eq 0 ] || status=1
done
skipped="$(grep -c '^  skip  ' "$log")"; rm -f "$log"
if [ "$status" -ne 0 ]; then echo "FAILURES"
elif [ "$skipped" -gt 0 ] && [ "${HARNESS_TESTS_STRICT:-0}" = 1 ]; then echo "FAILURES: $skipped test(s) SKIPPED and HARNESS_TESTS_STRICT=1"; status=1
elif [ "$skipped" -gt 0 ]; then echo "PASSED, but $skipped SKIPPED (see the skip lines above): the layers they cover did not run"
else echo "ALL PASSED"; fi
exit "$status"
