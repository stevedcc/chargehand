#!/usr/bin/env bash
# Print the model allocation a brief would get, and any problem with it.
# Usage: models.sh --project <name> [--role role=provider/model]...
# Exit 0 when usable, 3 when not (the problems are listed).
set -euo pipefail
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$HARNESS_ROOT/scripts/lib/harness.sh"
. "$HARNESS_ROOT/scripts/lib/models.sh"
project=; roles=()
while [ $# -gt 0 ]; do
    case "$1" in
        --project) project="$2"; shift 2 ;;
        --role) roles+=("$2"); shift 2 ;;
        -h|--help) sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument \"$1\"" ;;
    esac
done
[ -n "$project" ] || die "--project is required"
eff="$(models_effective "$project" "${roles[@]}")"
models_render "$eff"
problems="$(models_check "$eff" "$(bash "$HARNESS_ROOT/skills/configuring-chargehand/scripts/check-config.sh" --families)")"
if [ -n "$problems" ]; then
    echo; echo "Problems:"; sed 's/^/  /' <<<"$problems"; exit 3
fi
