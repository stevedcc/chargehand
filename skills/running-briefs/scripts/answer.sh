#!/usr/bin/env bash
# Answer what watch.sh reported.
# Usage: answer.sh list                       (every pending permission, server-wide)
#        answer.sh pending <session>          (pending permissions and forms of that session and its subagents)
#        answer.sh interrupt <session>        (stop what it is doing; POST .../interrupt?resume=false,
#                                              the path used by hand in real runs, unverified here)
#        answer.sh permission <session> <request> once|always|reject [message to the agent]
#        answer.sh form <session> <form> '<answer JSON, e.g. {"q0": "Use option B"}>'
set -euo pipefail
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$HARNESS_ROOT/scripts/lib/harness.sh"
. "$HARNESS_ROOT/scripts/lib/api.sh"
usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; }
body="$(mktemp)"; trap 'rm -f "$body"' EXIT
case "${1:-}" in
    list)
        oc_api GET /api/permission/request | jq -r '(.data // [])[] | "\(.sessionID) \(.id) \(.action) \(.resources | join(" "))"' | agent_text ;;
    pending)
        [ "$#" -eq 2 ] || die "usage: answer.sh pending <session>"
        all="$(oc_api GET '/api/session?limit=1000')" || die "could not list the sessions"
        tree="$(jq -r --arg r "$2" '.data as $d | def kids($id): $d[] | select(.parentID == $id) | .id, kids(.id); $r, kids($r)' <<<"$all")"
        found="$( { oc_api GET /api/permission/request | jq -r --argjson t "$(jq -R . <<<"$tree" | jq -sc .)" \
                '(.data // [])[] | select(.sessionID as $s | $t | index($s))
                 | "permission \(.sessionID) \(.id) \(.action) \(.resources | join(" "))"'
            while IFS= read -r s; do
                oc_api GET "/api/session/$s/form" | jq -r --arg s "$s" \
                    '(.data // [])[] | "form \(.sessionID // $s) \(.id) \(.title): \([.fields[]?.title] | join(", "))"'
            done <<<"$tree"; } | agent_text)"
        echo "${found:-nothing pending for $2 or its subagents}" ;;
    interrupt)
        [ "$#" -eq 2 ] || die "usage: answer.sh interrupt <session>"
        oc_api POST "/api/session/$2/interrupt?resume=false" >/dev/null && echo "interrupted $2" ;;
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
