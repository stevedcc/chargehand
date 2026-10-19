# Model allocation: models.json (subscriptions and roles), optional per-project "roles", and
# per-brief role=provider/model overrides. Source after harness.sh.
ROLES=(implementer task_review final_review low_level)

models_effective() {
    local project="$1"; shift
    local models="$HARNESS_CONFIG_DIR/models.json" pfile overrides='{}' o
    [ -f "$models" ] || die "missing config file $models"
    pfile="$(project_file "$project")" || exit 2
    [ -f "$pfile" ] || die "missing config file $pfile"
    for o in "$@"; do
        [[ "$o" =~ ^([a-z_]+)=([^/=]+/[^/=]+)$ ]] || die "bad role override \"$o\" (want role=provider/model)"
        overrides="$(jq -c --arg r "${BASH_REMATCH[1]}" --arg m "${BASH_REMATCH[2]}" '.[$r] = [$m]' <<<"$overrides")"
    done
    jq -c --argjson o "$overrides" --slurpfile p "$pfile" '.roles * ($p[0].roles // {}) * $o' "$models"
}

# jq definitions shared by check and render: provider, family, and "still running today".
_MODELS_JQ_DEFS='
  def prov: split("/")[0];
  def fam: . as $m | (($fams[$m] // ($m | split("/")[1])) | ascii_downcase | split("-")[0]);
  def live($s; $today): [ .[] | select(($s[prov].ends // "9999-12-31") >= $today) ];
'

# models_check EFFECTIVE [FAMILIES]: problems, one per line; no output means usable. FAMILIES maps
# provider/model to the server's model family; without it the id's first word stands in.
models_check() {
    local eff="$1" fams="${2:-}" today="${HARNESS_TODAY:-$(date +%F)}" roles
    [ -n "$fams" ] || fams='{}'
    roles="$(printf '%s\n' "${ROLES[@]}" | jq -R . | jq -sc .)"
    jq -r --argjson e "$eff" --arg today "$today" --argjson roles "$roles" --argjson fams "$fams" "$_MODELS_JQ_DEFS"'
      .subscriptions as $s
      | ( $roles[] as $r | select(($e[$r] // []) | length == 0) | "role \($r): no model" ),
        ( $e | to_entries[] | .key as $r | .value[] as $m
          | select($s[$m | prov] == null)
          | "role \($r): \($m): provider \($m | prov) is not one of your subscriptions" ),
        ( $e | to_entries[] | .key as $r | (.value[0] // empty) as $m
          | ($s[$m | prov].ends // empty) as $end | select($end < $today)
          | "role \($r): subscription \($m | prov) ended on \($end); put another model first" ),
        ( ["task_review", "final_review"][] as $r
          | select((($e[$r][0] // "x/x") | fam) == (($e.implementer[0] // "y/y") | fam))
          | "role \($r): \($e[$r][0]) is the same model family as the implementer" )
    ' "$HARNESS_CONFIG_DIR/models.json"
}

# models_render EFFECTIVE: the model block of a launch message.
models_render() {
    local eff="$1" today="${HARNESS_TODAY:-$(date +%F)}"
    jq -r --argjson e "$eff" --arg today "$today" --argjson fams '{}' "$_MODELS_JQ_DEFS"'
      .subscriptions as $s
      | def line($label; $r): ($e[$r] | live($s; $today)) as $l
          | "- \($label): `\($l[0])`"
            + (if ($l | length) > 1 then "; fallback: " + ([$l[1:][] | "`\(.)`"] | join(", ")) else "" end);
        "Models for this brief. Use exactly these; switch to a fallback only on a quota, rate-limit or authentication error, and record the switch and the error in your completion report:",
        line("this session and its implementer subagents"; "implementer"),
        line("per-task reviews and re-reviews"; "task_review"),
        line("final whole-branch review"; "final_review"),
        "- test-runner and pattern-applier: pinned in their agent definitions; do not override them.",
        "Allowed providers: " + ([$s | to_entries[] | select((.value.ends // "9999-12-31") >= $today) | "`\(.key)/`"] | join(", ")) + ". Never any other provider."
    ' "$HARNESS_CONFIG_DIR/models.json"
}

# models_busy PROVIDER: how many of PROVIDER's sessions updated in the last 6 hours are busy (no
# "idle" message since their last prompt, the test watch.sh uses). Needs api.sh.
models_busy() {
    local provider="$1" since s n=0
    since=$(( ($(date +%s) - 6 * 3600) * 1000 ))
    while read -r s; do
        [ -n "$s" ] || continue
        oc_api GET "/api/session/$s/message" 2>/dev/null | jq -e '.data | (map(.type) | index("user")) as $u
            | .[0:$u] | map(select(.type == "idle")) | length == 0' >/dev/null && n=$((n + 1))
    done < <(oc_api GET '/api/session?limit=1000' 2>/dev/null | jq -r --arg p "$provider" --argjson t "$since" \
        '.data[]? | select(.model.providerID == $p and (.time.updated // 0) >= $t) | .id')
    echo "$n"
}

# models_pick EFFECTIVE ROLE: the role's first live model whose provider is under its
# "max_busy_sessions" (a subscription with a short usage window, e.g. Z.ai's 5 hours, can't take
# two heavy sessions at once). All capped: the first model anyway, with a warning. Needs api.sh.
models_pick() {
    local eff="$1" role="$2" today="${HARNESS_TODAY:-$(date +%F)}" m p max busy first=
    while read -r m; do
        [ -n "$m" ] || continue
        [ -n "$first" ] || first="$m"
        p="${m%%/*}"
        max="$(jq -r --arg p "$p" '.subscriptions[$p].max_busy_sessions // empty' "$HARNESS_CONFIG_DIR/models.json")"
        if [ -n "$max" ]; then
            busy="$(models_busy "$p")"
            if [ "$busy" -ge "$max" ]; then
                echo "chargehand: skipping $m for $role: $p: $busy busy session(s), limit $max" >&2
                continue
            fi
        fi
        echo "$m"; return 0
    done < <(jq -r --argjson e "$eff" --arg r "$role" --arg today "$today" "$_MODELS_JQ_DEFS"'
        .subscriptions as $s | ($e[$r] // []) | live($s; $today)[]' "$HARNESS_CONFIG_DIR/models.json")
    [ -n "$first" ] || die "no live model for $role"
    echo "chargehand: every model for $role is at its busy limit; using $first anyway" >&2
    echo "$first"
}
