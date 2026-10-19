# OpenCode server calls. Source after harness.sh.
#
# oc_api METHOD PATH [BODY_FILE]: prints the response body; returns curl's status (22 for a
# non-2xx answer, 7 when the server is down). The password comes from config.json's
# "server_password" in one of four forms (env, file, command, wrapper). In the first three it
# reaches curl on stdin as a config line, never on a command line; "wrapper" hands the call to a
# token-substituting tool (e.g. a secret manager's "run" command), which then owns that exposure.
oc_api() {
    local method="$1" path="$2" body="${3:-}" url user form kind pw
    url="$(config_get server_url http://127.0.0.1:4096)$path" || return 2
    user="$(config_get server_user opencode)" || return 2
    local args=(-sS -f --max-time 30 -X "$method" -H 'Content-Type: application/json')
    [ -n "$body" ] && args+=(--data-binary "@$body")
    form="$(jq -c '.server_password // empty' "$HARNESS_CONFIG_DIR/config.json" 2>/dev/null)"
    [ -n "$form" ] || die "config.json: missing key \"server_password\""
    kind="$(jq -r 'if has("wrapper") then "wrapper" elif has("env") then "env"
                   elif has("file") then "file" elif has("command") then "command" else "" end' <<<"$form")"
    case "$kind" in
        env)
            local name; name="$(jq -r .env <<<"$form")"
            pw="${!name:-}"; [ -n "$pw" ] || die "server_password: \$$name is empty" ;;
        file)
            local f; f="$(expand_home "$(jq -r .file <<<"$form")")"
            [ -f "$f" ] || die "server_password: no file $f"
            [ "$(stat -c '%a %u' "$f")" = "600 $(id -u)" ] || die "server_password: $f must be mode 600 and yours"
            pw="$(<"$f")" ;;
        command)
            local cmd; mapfile -t cmd < <(jq -r '.command[]' <<<"$form")
            pw="$("${cmd[@]}")" || die "server_password: the command failed" ;;
        wrapper)
            local wrap tok; mapfile -t wrap < <(jq -r '.wrapper[]' <<<"$form"); tok="$(jq -r .token <<<"$form")"
            # TEMPORARY workaround for tswap (stevedcc/TokenSwap#173): overlapping unlocks make
            # `ykman list` return no serials ("No YubiKey detected"), so callers queue on a lock.
            # Remove once tswap serialises its own ykman calls.
            mkdir -p "$HARNESS_STATE_DIR"
            ( flock -w 120 9 || { echo "chargehand: timed out waiting for the API lock" >&2; exit 75; }
              "${wrap[@]}" curl "${args[@]}" -u "$user:$tok" "$url" ) 9>"$HARNESS_STATE_DIR/api.lock"
            return ;;
        *) die "server_password: use one of env, file, command, wrapper" ;;
    esac
    pw="${pw//\\/\\\\}"; pw="${pw//\"/\\\"}"
    printf 'user = "%s:%s"\n' "$user" "$pw" | curl -K - "${args[@]}" "$url"
}
