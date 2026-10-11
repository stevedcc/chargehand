# Helpers for the harness's bash tests. A test file sources this, defines test_* functions and
# ends with `run_tests`. Each test gets a throwaway HOME and config (setup_home).
set -uo pipefail
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILS=0
ok()   { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; FAILS=$((FAILS + 1)); }
assert_eq()           { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected [$3], got [$2])"; fi; }
assert_contains()     { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else fail "$1 (missing [$3] in: ${2:0:600})"; fi; }
assert_not_contains() { if grep -qF -- "$3" <<<"$2"; then fail "$1 (found [$3])"; else ok "$1"; fi; }

setup_home() {
    TEST_TMP="$(mktemp -d)"
    export HOME="$TEST_TMP/home"
    export HARNESS_CONFIG_DIR="$HOME/.config/chargehand" HARNESS_STATE_DIR="$HOME/.local/state/chargehand"
    mkdir -p "$HARNESS_CONFIG_DIR/projects"
}
write_config()  { printf '%s\n' "$1" > "$HARNESS_CONFIG_DIR/config.json"; }
write_project() { printf '%s\n' "$2" > "$HARNESS_CONFIG_DIR/projects/$1.json"; }
write_models()  { printf '%s\n' "$1" > "$HARNESS_CONFIG_DIR/models.json"; }

# start_api [password]: the fake server, plus a config.json using the env password form.
start_api() {
    API_DIR="$TEST_TMP/api"; mkdir -p "$API_DIR/fixtures"
    FAKE_API_PASSWORD="${1:-test-password}" python3 "$HARNESS_ROOT/tests/fake_api.py" "$API_DIR" &
    API_PID=$!
    for _ in $(seq 50); do [ -s "$API_DIR/port" ] && break; sleep 0.1; done
    API_URL="http://127.0.0.1:$(cat "$API_DIR/port")"
    export TEST_SERVER_PASSWORD="${1:-test-password}"
    write_config "{\"server_url\": \"$API_URL\", \"server_password\": {\"env\": \"TEST_SERVER_PASSWORD\"}}"
}
stop_api() { if [ -n "${API_PID:-}" ]; then kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null; API_PID=; fi; }
fixture()  { local f="$API_DIR/fixtures/$1$2.json"; mkdir -p "$(dirname "$f")"; printf '%s\n' "$3" > "$f"; }
requests() { cat "$API_DIR/requests.jsonl" 2>/dev/null; }
now_ms()   { echo $(( $(date +%s) * 1000 )); }

run_tests() {
    local t
    for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
        echo "$t"
        setup_home
        "$t"
        declare -F stop_api >/dev/null && stop_api
        rm -rf "$TEST_TMP"
    done
    [ "$FAILS" -eq 0 ]
}
