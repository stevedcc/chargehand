#!/usr/bin/env bash
# What is missing or wrong in chargehand's config, one problem per line.
# Usage: check-config.sh [--project <name>]   exit 0 when complete, 3 when not
#        check-config.sh --available-models   provider/model<TAB>family, from the OpenCode server
#        check-config.sh --families           {"provider/model": "family"} JSON ({} if the server is down)
set -uo pipefail
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$HARNESS_ROOT/scripts/lib/harness.sh"
. "$HARNESS_ROOT/scripts/lib/api.sh"
. "$HARNESS_ROOT/scripts/lib/models.sh"
models_list() {
    oc_api GET /api/model 2>/dev/null | jq -c '[(.data // [])[] | select(.enabled != false)
        | {key: "\(.providerID)/\(.modelID)", value: .family}] | from_entries'
}
case "${1:-}" in
    --available-models) models_list | jq -r 'to_entries[] | "\(.key)\t\(.value)"'; exit ;;
    --families) out="$( (models_list) 2>/dev/null)"; echo "${out:-{\}}"; exit 0 ;;
    -h|--help) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
problems=()
c="$HARNESS_CONFIG_DIR/config.json"; m="$HARNESS_CONFIG_DIR/models.json"
if [ ! -f "$c" ]; then problems+=("config.json: missing ($c)")
elif ! jq -e '.server_password | type == "object"' "$c" >/dev/null 2>&1; then problems+=("config.json: missing key \"server_password\"")
fi
if [ ! -f "$m" ]; then problems+=("models.json: missing ($m)")
elif ! jq -e '.subscriptions | type == "object" and length > 0' "$m" >/dev/null 2>&1; then problems+=("models.json: no subscriptions")
fi
if [ "${1:-}" = --project ]; then
    p="$HARNESS_CONFIG_DIR/projects/${2:-}.json"
    if [ ! -f "$p" ]; then problems+=("projects/${2:-}.json: missing ($p)")
    else
        for k in owner_worktree target_branch agent_clone mirror; do
            jq -e --arg k "$k" '.[$k] != null' "$p" >/dev/null || problems+=("$2.json: missing key \"$k\"")
        done
        if [ -f "$m" ] && eff="$( (models_effective "$2") 2>/dev/null)"; then
            while IFS= read -r l; do
                if [ -n "$l" ]; then problems+=("models: $l"); fi
            done < <(models_check "$eff" "$(bash "$0" --families)")
        fi
    fi
fi
# One authenticated call: --families hides a 401 as {}, so a wrong server_password would pass.
note=
if [ -f "$c" ] && jq -e '.server_password | type == "object"' "$c" >/dev/null 2>&1; then
    oc_api GET /api/model >/dev/null 2>&1 && src=0 || src=$?
    case "$src" in
        0) ;;
        22) problems+=("config.json: the server refused the request (wrong server_password, or this is not an OpenCode server)") ;;
        2) problems+=("config.json: server_password cannot be read (see: bash $0 --available-models)") ;;
        *) note=" (note: the server did not answer, status $src; password and model families not checked)" ;;
    esac
fi
if [ "${#problems[@]}" -eq 0 ]; then echo "chargehand config complete$note"; exit 0; fi
printf '%s\n' "${problems[@]}"; exit 3
