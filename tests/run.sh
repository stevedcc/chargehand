#!/usr/bin/env bash
# Runs every tests/test_*.sh. Exit 0 only if all pass.
cd "$(dirname "$0")" || exit 1
status=0
for f in test_*.sh; do echo "== $f"; bash "$f" || status=1; done
if [ "$status" -eq 0 ]; then echo "ALL PASSED"; else echo "FAILURES"; fi
exit "$status"
