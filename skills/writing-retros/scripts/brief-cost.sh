#!/usr/bin/env bash
# Cost of a brief in subscription dollars. Takes the brief's session tree (plus any session in the
# brief's worktree), groups it by provider and model, and prices each group with that
# subscription's "pricing" in models.json: metered (OpenCode's reported cost against the model's
# monthly limit), per token kind, or one blended rate.
# Usage: brief-cost.sh --project <name> --tag <tag>
# Prints a table and writes cost.json in the brief's state folder.
set -euo pipefail
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$HARNESS_ROOT/scripts/lib/harness.sh"
. "$HARNESS_ROOT/scripts/lib/api.sh"
project= tag=
while [ $# -gt 0 ]; do
    case "$1" in
        --project) project="$2"; shift 2 ;;
        --tag) tag="$2"; shift 2 ;;
        -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument \"$1\"" ;;
    esac
done
dir="$(brief_dir "$project" "$tag")"; [ -s "$dir/sid" ] || die "no session for brief $tag ($dir/sid)"
# The session list easily exceeds the 128 KB argument limit, so it goes to jq on stdin.
oc_api GET '/api/session?limit=1000' \
| jq --slurpfile m "$HARNESS_CONFIG_DIR/models.json" --arg r "$(<"$dir/sid")" --arg wt "/.worktrees/$tag" '
    def sum(f): map(f) | add // 0;
    def r2: if . == null then null else (. * 100 | round) / 100 end;
    .data as $d
    | def kids($id): $d[] | select(.parentID == $id) | .id, kids(.id);
      ([$r, kids($r)]) as $tree
    | [ $d[] | select(. as $s | ($tree | index($s.id)) != null or (($s.location.directory // "") | endswith($wt))) ]
    | group_by([.model.providerID, .model.id])
    | map({provider: .[0].model.providerID, model: .[0].model.id, sessions: length,
           cost: sum(.cost // 0), input: sum(.tokens.input),
           output: sum(.tokens.output + (.tokens.reasoning // 0)),
           cache_read: sum(.tokens.cache.read // 0), cache_write: sum(.tokens.cache.write // 0)})
    | map(. as $g | ($m[0].subscriptions[$g.provider].pricing // null) as $p
          | . + ( if $p == null then {form: "no rate", usd: null}
                  elif $p.metered != null then
                      ($p.metered.model_limit_usd[$g.model] // null) as $lim
                      | if $lim == null then {form: "no limit for \($g.model)", usd: null}
                        else {form: "metered", usd: ($g.cost / $lim * $p.metered.plan_usd)} end
                  elif ($p.per_mtok | type) == "number" then
                      {form: "blended", usd: (($g.input + $g.output + $g.cache_read + $g.cache_write) / 1e6 * $p.per_mtok)}
                  else
                      {form: "per kind", usd: (($g.input * ($p.per_mtok.input // 0) + $g.output * ($p.per_mtok.output // 0)
                          + $g.cache_read * ($p.per_mtok.cache_read // 0) + $g.cache_write * ($p.per_mtok.cache_write // 0)) / 1e6)}
                  end ))
    | map(.usd |= r2)
    | {lines: ., total_usd: (sum(.usd // 0) | r2)}' > "$dir/cost.json"
jq -r '(.lines[] | "\(.provider)/\(.model)\t\(.sessions) sessions\t"
          + "\(((.input + .output + .cache_read + .cache_write) / 1e4 | round) / 100) M tokens\t\(.form)\t"
          + (if .usd == null then "-" else "$\(.usd)" end)),
       "Total\t\t\t\t$\(.total_usd)"' "$dir/cost.json" | column -t -s $'\t'
