#!/usr/bin/env bash
# Installs a container verify lane for ONE project, as the lane's dedicated user. No sudo.
#   bash setup-lane.sh --project <name>
# Needs $HARNESS_CONFIG_DIR/lane.json (default ~/.config/chargehand/lane.json; shape:
# examples/lane.json) with <name> under "projects". Safe to re-run (also after updating Chargehand).
# It: checks lane.json (lane_check) and that the container runtime answers; installs the
# controller and its libraries to ~/.local/share/chargehand-lane/ and the wrapper
# ~/.local/bin/chargehand-lane (the requester runs `chargehand-lane verify` over ssh); creates
# repos_dir/<name>.git (bare) and work_dir; prints the requester's lanes.json entry.
# Exit: 0 done; 2 usage or config; 4 the runtime does not answer.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(cd "$here/../../.." && pwd)"
. "$HARNESS_ROOT/scripts/lib/harness.sh"
. "$HARNESS_ROOT/scripts/lib/lane.sh"
. "$HARNESS_ROOT/scripts/lib/runtime.sh"

usage() { sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
[ "${1:-}" = --project ] && [ "$#" -eq 2 ] || { usage >&2; exit 2; }
project="$2"
valid_name "$project" || die "bad project name \"$project\""

lane_check
jq -e --arg p "$project" '.projects | has($p)' "$(lane_file)" >/dev/null \
    || die "no project \"$project\" in $(lane_file)"
export CHARGEHAND_RUNTIME; CHARGEHAND_RUNTIME="$(lane_get .runtime)"
repos_dir="$(lane_get .repos_dir)"; work_dir="$(lane_get .work_dir)"

# The runtime must answer for this user (rootless Podman: its socket, a lingering user session).
rt_ls_labelled chargehand=1 >/dev/null 2>&1 \
    || { echo "chargehand-lane: the container runtime is unavailable ($CHARGEHAND_RUNTIME) for $(id -un)" >&2; exit 4; }

share="$HOME/.local/share/chargehand-lane"
mkdir -p "$share/lib" "$HOME/.local/bin" "$repos_dir" "$work_dir"
install -m 0755 "$HARNESS_ROOT/scripts/lane.sh" "$share/lane.sh"
install -m 0644 "$HARNESS_ROOT"/scripts/lib/*.sh "$share/lib/"
# $HOME is read when the wrapper runs, so it follows whichever user runs it.
cat > "$HOME/.local/bin/chargehand-lane" <<'WRAP'
#!/usr/bin/env bash
exec "${HOME:?}/.local/share/chargehand-lane/lane.sh" "$@"
WRAP
chmod 0755 "$HOME/.local/bin/chargehand-lane"
[ -d "$repos_dir/$project.git" ] || git init -q --bare "$repos_dir/$project.git"

echo "Lane installed for project $project (runtime $CHARGEHAND_RUNTIME)."
echo "The wrapper is $HOME/.local/bin/chargehand-lane: it must be on the PATH of a non-interactive ssh"
echo "session for this user (e.g. in ~/.bashrc above the interactive-shell return)."
echo "Add to the requester's lanes.json (ssh: the lane user and box, as in the requester's ~/.ssh/config):"
jq -n --arg repos "$repos_dir" '{"<lane-name>": {ssh: "<lane-user>@<box>", repos_dir: $repos}}'
