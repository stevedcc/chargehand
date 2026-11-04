# OpenCode server calls. Source after harness.sh.
#
# oc_api METHOD PATH [BODY_FILE]: prints the response body; returns curl's status (22 for a
# non-2xx answer, 7 when the server is down). The password comes from config.json's
# "server_password" in one of four forms (env, file, command, wrapper). In the first three it
# reaches curl on stdin as a config line, never on a command line; "wrapper" hands the call to a
# token-substituting tool (e.g. a secret manager's "run" command), which then owns that exposure.
# Wrapper calls queue on one lock; HARNESS_API_LOCK_WAIT (seconds, default 120) bounds the wait and
# a timeout returns 75 (watch.sh sets it below its poll interval).
oc_api() {
    local method="$1" path="$2" body="${3:-}" url user kind pw
    url="$(config_get server_url http://127.0.0.1:4096)$path" || return 2
    user="$(config_get server_user opencode)" || return 2
    local args=(-sS -f --max-time 30 -X "$method" -H 'Content-Type: application/json')
    [ -n "$body" ] && args+=(--data-binary "@$body")
    kind="$(server_password_form)" || exit 2
    if [ "$kind" = wrapper ]; then
        local wrap tok; mapfile -t wrap < <(_server_password_json | jq -r '.wrapper[]'); tok="$(_server_password_json | jq -r .token)"
        # TEMPORARY workaround for tswap (stevedcc/TokenSwap#173): overlapping unlocks make
        # `ykman list` return no serials ("No YubiKey detected"), so callers queue on a lock.
        # Remove once tswap serialises its own ykman calls.
        mkdir -p "$HARNESS_STATE_DIR"
        ( flock -w "${HARNESS_API_LOCK_WAIT:-120}" 9 || { echo "chargehand: timed out waiting for the API lock" >&2; exit 75; }
          "${wrap[@]}" curl "${args[@]}" -u "$user:$tok" "$url" ) 9>"$HARNESS_STATE_DIR/api.lock"
        return
    fi
    # The "x" keeps a value's own trailing newlines, which $(...) would strip (an env value keeps them).
    pw="$(server_password_value && printf x)" || exit 2; pw="${pw%x}"
    pw="${pw//\\/\\\\}"; pw="${pw//\"/\\\"}"
    printf 'user = "%s:%s"\n' "$user" "$pw" | curl -K - "${args[@]}" "$url"
}

# _server_password_json: config.json's "server_password" object, compact; dies when it is missing.
_server_password_json() {
    local form
    form="$(jq -c '.server_password // empty' "$HARNESS_CONFIG_DIR/config.json" 2>/dev/null)"
    [ -n "$form" ] || die "config.json: missing key \"server_password\""
    printf '%s\n' "$form"
}

# server_password_form: which form "server_password" uses: env, file, command or wrapper (wrapper
# wins when an object names several). Dies on anything else.
server_password_form() {
    local form kind
    form="$(_server_password_json)" || exit 2
    kind="$(jq -r 'if has("wrapper") then "wrapper" elif has("env") then "env"
                   elif has("file") then "file" elif has("command") then "command" else "" end' <<<"$form")"
    [ -n "$kind" ] || die "server_password: use one of env, file, command, wrapper"
    printf '%s\n' "$kind"
}

# server_password_value: the password itself on stdout (no newline added), for the env, file and command forms. Callers
# capture it into a variable and hand it on without a command line (curl's stdin, an environment
# variable). The wrapper form never yields the value to Chargehand, so it dies here.
server_password_value() {
    local form kind pw
    kind="$(server_password_form)" || exit 2
    form="$(_server_password_json)" || exit 2
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
        wrapper) die "server_password: the wrapper form has no value to read (the wrapper substitutes it into a command)" ;;
    esac
    printf '%s' "$pw"
}

# oc_answers: whether server_url answers HTTP at all (any status, a 401 included); sends no
# credentials. Used to tell "not running" from "running".
oc_answers() {
    local url; url="$(config_get server_url http://127.0.0.1:4096)" || return 2
    curl -s -o /dev/null --max-time 5 "$url" && return 0
    return 1
}

# oc_launch DIR: create the session from DIR/session-request.json, send DIR/launch.txt to it, and
# only then record it as DIR/sid, so a sid always names a session that has its brief (a watcher on
# a sid that never got a prompt would run silently to its timeout). When the prompt fails the
# session is kept as DIR/sid.failed-<n> (brief-cost.sh counts it; resume can find it) and its id
# is in the error. Prints the session id. Needs harness.sh.
oc_launch() {
    local dir="$1" sid n
    sid="$(oc_api POST /api/session "$dir/session-request.json" | jq -r '.data.id // empty')"
    [ -n "$sid" ] || die "creating the session failed"
    jq -n --rawfile t "$dir/launch.txt" '{text: $t}' > "$dir/prompt-request.json"
    if ! oc_api POST "/api/session/$sid/prompt" "$dir/prompt-request.json" | jq -e '.data.id' >/dev/null; then
        n=1; while [ -e "$dir/sid.failed-$n" ]; do n=$((n + 1)); done
        printf '%s\n' "$sid" > "$dir/sid.failed-$n"
        die "sending the launch message to session $sid failed; the session is kept as $dir/sid.failed-$n (no sid written, so you can launch again)"
    fi
    printf '%s\n' "$sid" > "$dir/sid"
    echo "$sid"
}

# oc_sessions: the session list ({data: [...]}) on stdout, with oc_api's status. The server returns
# at most HARNESS_SESSION_LIMIT (1000) sessions; a list of exactly that size may have cut off
# children, so stderr says so (watching, busy counts and costs would miss them). oc_api's own stderr
# is discarded, as the callers did.
oc_sessions() {
    local limit="${HARNESS_SESSION_LIMIT:-1000}" out rc=0
    out="$(oc_api GET "/api/session?limit=$limit" 2>/dev/null)" || rc=$?
    printf '%s\n' "$out"
    if [ "$rc" -eq 0 ] && [ "$(jq '.data | length' <<<"$out" 2>/dev/null)" = "$limit" ]; then
        echo "chargehand: session list may be truncated: the server returned the limit of $limit sessions, so briefs and subagents beyond it are not seen" >&2
    fi
    return "$rc"
}

# oc_newest_first: filter a message-list response ({data: [...]}) to newest-first by time.created
# (stable: messages without a time keep their order). The watcher and models_busy read ".data[0]"
# and "everything before the last prompt" and so must not depend on the order the server answers in
# (not verified against a real server).
oc_newest_first() {
    jq -c 'if (.data | type) == "array" then .data |= sort_by(-(.time.created // 0 | tonumber? // 0)) else . end'
}
