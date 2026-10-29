# Reads and validates a verify lane's config, $HARNESS_CONFIG_DIR/lane.json (shape: examples/lane.json).
# Source it after harness.sh, don't run it. Config reading only: nothing here starts a container.
. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

LANE_DIGEST_RE='@sha256:[0-9a-f]{64}$'

lane_file() { printf '%s\n' "$HARNESS_CONFIG_DIR/lane.json"; }

# lane_get JQ_PATH [DEFAULT]: a value from lane.json (strings raw, anything else as compact JSON),
# with a leading ~ expanded. Dies when the file or value is missing and there is no default.
lane_get() {
    local file v; file="$(lane_file)"
    if [ -f "$file" ] && v="$(jq -er "$1 | select(. != null) | if type == \"string\" then . else tojson end" "$file" 2>/dev/null)"; then
        expand_home "$v"
    elif [ "$#" -ge 2 ]; then
        printf '%s\n' "$2"
    elif [ ! -f "$file" ]; then
        die "missing lane config $file"
    else
        die "$file: missing value $1"
    fi
}

# lane_project_get PROJECT JQ_PATH [DEFAULT]: JQ_PATH is relative to .projects.<PROJECT>, e.g. .build.
lane_project_get() {
    valid_name "$1" || die "bad project name \"$1\""
    local project="$1" sub="$2"; shift 2
    lane_get ".projects[\"$project\"]$sub" "$@"
}

# lane_check: validates lane.json. Prints nothing on success; dies naming the first problem.
lane_check() {
    local file msg; file="$(lane_file)"
    [ -f "$file" ] || die "missing lane config $file"
    jq -e . "$file" >/dev/null 2>&1 || die "$file: not valid JSON"
    msg="$(jq -r --arg re "$LANE_DIGEST_RE" '
        def str: type == "string" and length > 0;
        def pinned: str and test($re);
        def problems:
          (if (.runtime | IN("docker", "podman", "container")) then empty
           else "runtime must be docker, podman or container" end),
          (if (.cpus | type == "number" and . > 0) then empty else "cpus must be a positive number" end),
          (if (.memory | str) then empty else "memory must be a non-empty string" end),
          (if (.repos_dir | str) then empty else "repos_dir must be a non-empty string" end),
          (if (.work_dir | str) then empty else "work_dir must be a non-empty string" end),
          (if (.verify_timeout_min | type == "number" and . > 0) then empty else "verify_timeout_min must be a positive number" end),
          (if (.projects | type == "object" and length > 0) then empty else "projects must be a non-empty object" end),
          ((.projects // {}) | if type == "object" then to_entries[] else empty end
            | .key as $p | .value as $v
            | (if ($v.runner_image | pinned) then empty
               else "runner_image for \($p) must be pinned by digest (…@sha256:…)" end),
              ($v | (if (.restore | str) then empty else "\($p): restore must be a non-empty string" end),
                    (if (.build | str) then empty else "\($p): build must be a non-empty string" end),
                    (if (.tests | type == "array" and length > 0 and all(.[]; str)) then empty
                     else "\($p): tests must be a non-empty list" end),
                    (if (.test_filter // "" | type == "string") then empty else "\($p): test_filter must be a string" end),
                    (if (.summary_pattern | str) then empty else "\($p): summary_pattern must be a non-empty string" end),
                    (if (.env // {} | type == "object" and all(.[]; type == "string")) then empty
                     else "\($p): env must be an object of strings" end),
                    (if (.services // [] | type == "array") then empty else "\($p): services must be a list" end),
                    ((.services // []) | if type == "array" then .[] else empty end
                      | (.name // "?") as $n
                      | (if (.name | str) then empty else "\($p): every service needs a name" end),
                        (if (.image | pinned) then empty
                         else "image for service \($n) of \($p) must be pinned by digest (…@sha256:…)" end),
                        (if (.memory // "" | type == "string") then empty
                         else "\($p): memory of service \($n) must be a string" end),
                        (if (.env // {} | type == "object" and all(.[]; type == "string")) then empty
                         else "\($p): env of service \($n) must be an object of strings" end),
                        (if (.ready // [] | type == "array" and all(.[]; type == "string")) then empty
                         else "\($p): ready of service \($n) must be a list of strings" end),
                        (if (.ready_timeout_sec // 60 | type == "number" and . > 0) then empty
                         else "\($p): ready_timeout_sec of service \($n) must be a positive number" end))));
        [problems] | first // empty' "$file")" || die "$file: could not be checked"
    [ -z "$msg" ] || die "$msg"
}
