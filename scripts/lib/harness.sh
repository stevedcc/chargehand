# Config, state and error helpers shared by every harness script. Source it, don't run it.
# Config: $HARNESS_CONFIG_DIR (default ~/.config/chargehand): config.json, models.json,
# projects/<name>.json. State: $HARNESS_STATE_DIR (default ~/.local/state/chargehand).
# bash 5.2 turned on patsub_replacement: an "&" in the replacement of ${v//pat/rep} then stands for
# the matched text, which corrupts values like "a && b" substituted into launch messages. Off here
# so every script that sources this file substitutes literally.
shopt -u patsub_replacement 2>/dev/null || true
HARNESS_CONFIG_DIR="${HARNESS_CONFIG_DIR:-$HOME/.config/chargehand}"
HARNESS_STATE_DIR="${HARNESS_STATE_DIR:-$HOME/.local/state/chargehand}"

die() { echo "chargehand: $*" >&2; exit 2; }
NOT_CONFIGURED_HINT='chargehand is not configured for this: ask Claude to configure chargehand (skill configuring-chargehand).'

expand_home() {
    case "$1" in
        "~") printf '%s\n' "$HOME" ;;
        "~/"*) printf '%s\n' "$HOME/${1#\~/}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# json_get FILE KEY [DEFAULT]: a top-level key as text (strings raw, anything else as compact JSON).
json_get() {
    local file="$1" key="$2" v
    if [ -f "$file" ] && v="$(jq -er --arg k "$key" \
            'if .[$k] == null then empty else .[$k] | (if type == "string" then . else tojson end) end' \
            "$file" 2>/dev/null)"; then
        printf '%s\n' "$v"
    elif [ "$#" -ge 3 ]; then
        printf '%s\n' "$3"
    elif [ ! -f "$file" ]; then
        die "missing config file $file. $NOT_CONFIGURED_HINT"
    else
        die "$file: missing key \"$key\". $NOT_CONFIGURED_HINT"
    fi
}

valid_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$1" != *..* ]]; }

project_file() {
    valid_name "$1" || die "bad project name \"$1\""
    printf '%s\n' "$HARNESS_CONFIG_DIR/projects/$1.json"
}

project_get() {
    local f v
    f="$(project_file "$1")" || exit 2
    v="$(json_get "$f" "$2" "${@:3}")" || exit 2
    expand_home "$v"
}

config_get() {
    local v
    v="$(json_get "$HARNESS_CONFIG_DIR/config.json" "$1" "${@:2}")" || exit 2
    expand_home "$v"
}

brief_dir() {
    valid_name "$1" || die "bad project name \"$1\""
    valid_name "$2" || die "bad brief tag \"$2\""
    printf '%s\n' "$HARNESS_STATE_DIR/$1/briefs/$2"
}

forbidden_tools() { jq -r '(.forbidden_tools // [])[]' "$HARNESS_CONFIG_DIR/config.json" 2>/dev/null || true; }

# agent_text: filter for anything agent-authored before it reaches the orchestrator's screen
# (commit subjects, test output, permission resources, questions). An agent controls that text, so
# it must not be able to move the cursor, clear the screen, retitle the terminal or hide lines:
# strips ANSI/OSC escape sequences, C0 controls except tab and newline, DEL and C1 controls.
agent_text() {
    LC_ALL=C sed -e 's/\x1b\[[0-9;?]*[ -/]*[@-~]//g' \
                 -e 's/\x1b[]PX^_][^\x07\x1b]*\(\x07\|\x1b\\\)//g' \
                 -e 's/\xc2[\x80-\x9f]//g' \
        | LC_ALL=C tr -d '\000-\010\013-\037\177'
}

# record_name REF: a file name for a per-ref record (verified commits) that is unique per ref:
# "%" and "/" are both encoded, so "a/b" and "a%b" can never share a record.
record_name() { printf '%s' "$1" | sed -e 's/%/%25/g' -e 's|/|%2F|g'; }
