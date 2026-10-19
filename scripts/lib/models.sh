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

# models_check EFFECTIVE [FAMILIES]: problems, one per line; no output means usable. Every live
# reviewer model is compared with every live implementer model, fallbacks included, so a fallback
# switch cannot put a model's own family on its review. FAMILIES maps
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
          | ($e[$r] // [] | live($s; $today))[] as $m
          | ($e.implementer // [] | live($s; $today) | to_entries[]) as $i
          | select(($m | fam) == ($i.value | fam))
          | if $i.key == 0 then "role \($r): \($m) is the same model family as the implementer"
            else "role \($r): \($m) shares a family with implementer fallback \($i.value)" end )
    ' "$HARNESS_CONFIG_DIR/models.json"
}

# models_render EFFECTIVE [--allow-paid]: the model block of a launch message. A model of a
# subscription with "pay_per_use": true is marked: not to be used until the orchestrator says so
# (or, with --allow-paid, allowed by the owner for this brief).
models_render() {
    local eff="$1" allow=false today="${HARNESS_TODAY:-$(date +%F)}"
    [ "${2:-}" != --allow-paid ] || allow=true
    jq -r --argjson e "$eff" --arg today "$today" --argjson fams '{}' --argjson allow "$allow" "$_MODELS_JQ_DEFS"'
      .subscriptions as $s
      | def mark: "`\(.)`" + (if $s[prov].pay_per_use == true
            then (if $allow then " (pay-per-use, allowed by the owner for this brief)"
                  else " (pay-per-use: only after the orchestrator says so in a prompt)" end) else "" end);
        def line($label; $r): ($e[$r] | live($s; $today)) as $l
          | "- \($label): \($l[0] | mark)"
            + (if ($l | length) > 1 then "; fallback: " + ([$l[1:][] | mark] | join(", ")) else "" end);
        "Models for this brief. Use exactly these; switch to a fallback only on a quota, rate-limit or authentication error, and record the switch and the error in your completion report:",
        line("this session and its implementer subagents"; "implementer"),
        line("per-task reviews and re-reviews"; "task_review"),
        line("final whole-branch review"; "final_review"),
        "- If you switch to a fallback, the reviewer must still be from a different family than the model that wrote the code; if none is left, stop and report. On a quota error with no flat-rate fallback left, stop and report.",
        "- pattern-applier: pinned in its agent definition; do not override it.",
        "Allowed providers: " + ([$s | to_entries[] | select((.value.ends // "9999-12-31") >= $today) | "`\(.key)/`"] | join(", ")) + ". Never any other provider."
    ' "$HARNESS_CONFIG_DIR/models.json"
}

# models_busy PROVIDER: how many of PROVIDER's sessions are busy: updated in the last
# MODELS_BUSY_WINDOW_MIN minutes (20; a working session updates constantly), no "idle" message since
# its last prompt (the test watch.sh uses), and its newest reply not an error (a session that died on
# a 402 or a quota error holds no capacity). Needs api.sh.
models_busy() {
    local provider="$1" since s n=0
    since=$(( ($(date +%s) - ${MODELS_BUSY_WINDOW_MIN:-20} * 60) * 1000 ))
    while read -r s; do
        [ -n "$s" ] || continue
        oc_api GET "/api/session/$s/message" 2>/dev/null | oc_newest_first | jq -e '.data | (map(.type) | index("user")) as $u
            | .[0:$u] | (map(select(.type == "idle")) | length == 0)
              and ((map(select(.type == "assistant")) | first // {} | .error) == null)' >/dev/null && n=$((n + 1))
    done < <(oc_api GET '/api/session?limit=1000' 2>/dev/null | jq -r --arg p "$provider" --argjson t "$since" \
        '.data[]? | select(.model.providerID == $p and (.time.updated // 0) >= $t) | .id')
    echo "$n"
}

# models_pick EFFECTIVE ROLE [--allow-paid]: the role's first live model whose provider is under its
# "max_busy_sessions" (a subscription with a short usage window, e.g. Z.ai's 5 hours, can't take
# two heavy sessions at once). All capped: the first model anyway, with a warning. A pay-per-use
# model ("pay_per_use": true) is never picked unless --allow-paid (the owner's explicit yes).
# Needs api.sh.
models_pick() {
    local eff="$1" role="$2" allow=false today="${HARNESS_TODAY:-$(date +%F)}" m p max busy first=
    [ "${3:-}" != --allow-paid ] || allow=true
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
    done < <(jq -r --argjson e "$eff" --arg r "$role" --arg today "$today" --argjson allow "$allow" "$_MODELS_JQ_DEFS"'
        .subscriptions as $s | ($e[$r] // []) | live($s; $today)[]
        | select($allow or ($s[. | prov].pay_per_use != true))' "$HARNESS_CONFIG_DIR/models.json")
    [ -n "$first" ] || die "no live flat-rate model for $role (a pay-per-use model needs --allow-paid, with the owner's yes)"
    echo "chargehand: every model for $role is at its busy limit; using $first anyway" >&2
    echo "$first"
}
