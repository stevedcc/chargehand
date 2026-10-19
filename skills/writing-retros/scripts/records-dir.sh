#!/usr/bin/env bash
# Print (and create) the folder where a project's retrospectives and ledgers go.
# Usage: records-dir.sh --project <name>
# config.json "records_dir" sets it ("~" and "{project}" are expanded);
# the default is ~/.local/state/chargehand/<project>/records.
set -euo pipefail
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$HARNESS_ROOT/scripts/lib/harness.sh"
[ "${1:-}" = --project ] && [ "$#" -eq 2 ] || { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
records_dir "$2"
