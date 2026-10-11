#!/usr/bin/env bash
# Answer what watch.sh reported.
# Usage: answer.sh list
#        answer.sh permission <session> <request> once|always|reject [message to the agent]
#        answer.sh form <session> <form> '<answer JSON, e.g. {"q0": "Use option B"}>'
set -euo pipefail
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$HARNESS_ROOT/scripts/lib/harness.sh"
. "$HARNESS_ROOT/scripts/lib/api.sh"
usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; }
body="$(mktemp)"; trap 'rm -f "$body"' EXIT
case "${1:-}" in
    list)
        oc_api GET /api/permission/request | jq -r '(.data // [])[] | "\(.sessionID) \(.id) \(.action) \(.resources | join(" "))"' ;;
    permission)
        [ "$#" -ge 4 ] || die "usage: answer.sh permission <session> <request> once|always|reject [message]"
        case "$4" in once|always|reject) ;; *) die "decision must be once, always or reject" ;; esac
        jq -n --arg d "$4" --arg m "${5:-}" '{decision: $d} + (if $m == "" then {} else {message: $m} end)' > "$body"
        oc_api POST "/api/session/$2/permission/$3/reply" "$body" >/dev/null && echo "answered $3: $4" ;;
    form)
        [ "$#" -eq 4 ] || die "usage: answer.sh form <session> <form> '<answer JSON>'"
        jq -e 'type == "object"' <<<"$4" >/dev/null 2>&1 || die "the answer must be a JSON object, e.g. {\"q0\": \"...\"}"
        jq -n --argjson a "$4" '{answer: $a}' > "$body"
        oc_api POST "/api/session/$2/form/$3/reply" "$body" >/dev/null && echo "answered $3" ;;
    -h|--help) usage ;;
    *) usage; exit 2 ;;
esac
