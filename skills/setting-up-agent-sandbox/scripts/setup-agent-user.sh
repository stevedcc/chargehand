#!/usr/bin/env bash
# One-time (and after-any-change) setup of the dedicated, unprivileged agent user and its sandbox,
# using a "fork" model: the agent works in its OWN clone and never gets write access to anything
# of yours (no shared .git, so no git hooks or config it could plant for you to run).
#
#   your repo  --push-->  <mirror>  (bare, owned by you, read-only to the agent)
#                            |  agent pulls
#                            v
#                       <agent clone>  (owned by the agent user)
#   your repo  <--fetch--  (you fetch its commits, review, verify as the agent, then fast-forward)
#
# Run from your own account, after configuring chargehand (~/.config/chargehand):
#   sudo bash setup-agent-user.sh --project <name> [--project <name>...] [--remove-old-launcher]
# Safe to re-run; re-run after editing the launcher, the implementer rules or a project's config.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo bash $0 --project <name>" >&2; exit 1; }
OWNER="${SUDO_USER:?Run via sudo from your own account, not as root directly}"
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(cd "$here/../../.." && pwd)"
HARNESS_CONFIG_DIR="$OWNER_HOME/.config/chargehand"
# harness.sh expands ~ with $HOME: config paths are the owner's.
HOME="$OWNER_HOME"
. "$HARNESS_ROOT/scripts/lib/harness.sh"
. "$HARNESS_ROOT/scripts/lib/render.sh"

projects=() remove_old=0
while [ $# -gt 0 ]; do
    case "$1" in
        --project) projects+=("$2"); shift 2 ;;
        --remove-old-launcher) remove_old=1; shift ;;
        *) die "unknown argument \"$1\"" ;;
    esac
done
[ "${#projects[@]}" -gt 0 ] || die "--project <name> is required"

AGENT="$(config_get agent_user opencode)"
LAUNCHER=/usr/local/bin/chargehand-sandbox
ETC=/etc/chargehand
SHARE=/usr/local/share/chargehand
SUDOERS=/etc/sudoers.d/chargehand

step() { echo; echo "==> $*"; }
as_owner() { sudo -u "$OWNER" -H "$@"; }
as_agent() { sudo -u "$AGENT" -H "$@"; }
# Commands run as the agent inherit the current directory; the agent can't access the owner's home.
cd /

step "1. user '$AGENT'"
id "$AGENT" &>/dev/null || useradd --create-home --shell /bin/bash --comment "Coding agents" "$AGENT"
passwd -l "$AGENT" >/dev/null
AGENT_HOME="$(getent passwd "$AGENT" | cut -d: -f6)"
chmod 0700 "$AGENT_HOME"
AGENT_UID="$(id -u "$AGENT")"
echo "uid $AGENT_UID, password login locked, home 0700"

step "2. subordinate UID/GID range (rootless Podman; no groups needed)"
if ! grep -q "^$AGENT:" /etc/subuid || ! grep -q "^$AGENT:" /etc/subgid; then
    start="$(awk -F: '{e=$2+$3; if (e>m) m=e} END {print (m ? m : 100000)}' /etc/subuid /etc/subgid)"
    usermod --add-subuids "$start-$((start + 65535))" --add-subgids "$start-$((start + 65535))" "$AGENT"
fi
grep "^$AGENT:" /etc/subuid /etc/subgid

step "3. linger + rootless Podman socket for '$AGENT'"
loginctl enable-linger "$AGENT"
for _ in $(seq 1 40); do [ -S "/run/user/$AGENT_UID/bus" ] && break; sleep 0.25; done
systemctl --user -M "$AGENT@" enable --now podman.socket
systemctl --user -M "$AGENT@" is-active podman.socket

as_agent git config --global user.name  "Coding agent"
as_agent git config --global user.email "$AGENT@$(hostname -s).localdomain"
# Reuse recorded conflict resolutions on merges, but never stage them unseen: the agent checks
# each "Resolved ... using previous resolution" file before committing (AGENTS.md).
as_agent git config --global rerere.enabled true
as_agent git config --global --unset rerere.autoUpdate 2>/dev/null || true

for name in "${projects[@]}"; do
    pfile="$(project_file "$name")"
    [ -f "$pfile" ] || die "missing config file $pfile ${NOT_CONFIGURED_HINT:-}"
    repo="$(project_get "$name" repo)"
    target="$(project_get "$name" target_branch)"
    clone="$(project_get "$name" agent_clone)"
    mirror="$(project_get "$name" mirror)"
    sdk_src="$(project_get "$name" sdk_source "")"
    sdk_dst="$(project_get "$name" sdk_dest "")"

    step "4. [$name] toolchain"
    if [ -n "$sdk_src" ] && [ -n "$sdk_dst" ]; then
        [ -e "$sdk_dst" ] || cp -a "$sdk_src" "$sdk_dst"
        chown -R root:root "$sdk_dst"; chmod -R a+rX,go-w "$sdk_dst"
        echo "$sdk_src copied to $sdk_dst (root-owned, read-only)"
    else
        echo "no sdk_source/sdk_dest: nothing to copy"
    fi

    step "5. [$name] exchange area"
    install -d -o root -g root -m 0755 "$(dirname "$clone")"
    install -d -o "$OWNER" -g "$OWNER" -m 0755 "$(dirname "$mirror")"

    step "6. [$name] mirror $mirror (owned by $OWNER, read-only to everyone else)"
    [ -d "$mirror" ] || as_owner git clone -q --bare "$repo" "$mirror"
    as_owner git -C "$repo" remote get-url agent-upstream &>/dev/null \
        || as_owner git -C "$repo" remote add agent-upstream "$mirror"
    as_owner git -C "$repo" push -q agent-upstream "$target"
    as_owner git -C "$mirror" log --oneline -1 "$target"

    step "7. [$name] agent clone $clone (owned by $AGENT)"
    as_agent git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$mirror" \
        || as_agent git config --global --add safe.directory "$mirror"   # agent trusts your mirror (read-only)
    # Not world-readable: the owner reads it (git fetch runs as the owner, through upload-pack), so
    # the owner's group gets read access and the setgid bit keeps new files in that group.
    install -d -o "$AGENT" -g "$OWNER" -m 2750 "$clone"
    [ -d "$clone/.git" ] || as_agent git clone -q --branch "$target" "$mirror" "$clone"
    as_agent git -C "$clone" log --oneline -1
    as_agent sh -c "$CLONE_EXCLUDE_SH" sh "$clone"   # resume notes stay out of git (.git/info/exclude)
    # Your repo gets a fetch-only remote for the agent's clone (agent-sync.sh fetches it safely).
    as_owner git -C "$repo" remote get-url agent &>/dev/null || as_owner git -C "$repo" remote add agent "$clone"
    as_owner git -C "$repo" remote set-url --push agent "DISABLED-never-push-into-agent-repos"

    step "8. [$name] project settings $ETC/$name.env (root-owned)"
    install -d -o root -g root -m 0755 "$ETC"
    render_env "$pfile" "$name" > "$ETC/$name.env.tmp"
    install -o root -g root -m 0644 "$ETC/$name.env.tmp" "$ETC/$name.env"; rm -f "$ETC/$name.env.tmp"
    grep -E '^(PROJECT|AGENT_CLONE|MIRROR|TARGET_BRANCH)=' "$ETC/$name.env"
done

step "9. root-owned launcher $LAUNCHER"
install -o root -g root -m 0755 "$here/sandbox.sh" "$LAUNCHER"
sed -i -e "s|^HARNESS_ETC=.*|HARNESS_ETC=$ETC|" -e "s|^HARNESS_SHARE=.*|HARNESS_SHARE=$SHARE|" "$LAUNCHER"
grep -E '^HARNESS_(ETC|SHARE)=' "$LAUNCHER"

step "10. implementer rules and subagents in $SHARE (root-owned, read-only to the agent)"
install -d -o root -g root -m 0755 "$SHARE" "$SHARE/agents"
render_rules "$HARNESS_ROOT/implementer/rules.md" "$SHARE/rules.md" > "$SHARE/rules.md.tmp"
install -o root -g root -m 0644 "$SHARE/rules.md.tmp" "$SHARE/rules.md"; rm -f "$SHARE/rules.md.tmp"
install -o root -g root -m 0644 "$HARNESS_ROOT"/implementer/agents/*.md "$SHARE/agents/"
ls -l "$SHARE" "$SHARE/agents"

step "11. sudoers: $OWNER may run only the launcher's fixed forms, as $AGENT"
mapfile -t all < <(for f in "$ETC"/*.env; do basename "$f" .env; done)
render_sudoers "$OWNER" "$AGENT" "$LAUNCHER" "${all[@]}" > "$SUDOERS.tmp"
chmod 0440 "$SUDOERS.tmp"
visudo -cf "$SUDOERS.tmp"
mv "$SUDOERS.tmp" "$SUDOERS"

step "12. OpenCode config for '$AGENT' (rules in instructions, subagents pinned)"
# Everything under the agent's home is the agent's to control (it could plant symlinks there), so
# root only renders into its own temp files; reads and writes in that home run as the agent.
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
as_agent mkdir -p "$AGENT_HOME/.config/opencode" "$AGENT_HOME/.bashrc.d"
as_agent chmod 0700 "$AGENT_HOME/.config" "$AGENT_HOME/.config/opencode"
oc="$AGENT_HOME/.config/opencode/opencode.json"
if as_agent test -f "$oc"; then
    as_agent cat "$oc" > "$work/base.json"
elif [ -f "$OWNER_HOME/.config/opencode/opencode.json" ]; then
    as_owner cat "$OWNER_HOME/.config/opencode/opencode.json" > "$work/base.json"
fi
low="$(jq -r '.roles.low_level[0] // empty' "$HARNESS_CONFIG_DIR/models.json")"
[ -n "$low" ] || die "models.json has no low_level role ${NOT_CONFIGURED_HINT:-}"
# The implementer rules use Superpowers skills; add its plugin unless config.json says
# "superpowers": false (for someone who supplies equivalent skills another way).
sp="$(jq -r 'if .superpowers == false then "no" else "yes" end' "$HARNESS_CONFIG_DIR/config.json")"
render_opencode_config "$work/base.json" "$SHARE" "$low" "$sp" > "$work/opencode.json"
if [ "$sp" = yes ] && ! jq -e '(.plugins // []) | any(test("superpowers"))' "$work/base.json" >/dev/null 2>&1; then
    echo "  added the Superpowers plugin for '$AGENT' (opencode.json \"plugins\"; set \"superpowers\": false in config.json to opt out)"
fi
as_agent sh -c 'umask 077; cat > "$1"' sh "$oc" < "$work/opencode.json"
jq -c '{instructions, agents: (.agents | map_values(.model))}' "$work/opencode.json"

step "13. shell environment for '$AGENT' (toolchain PATH and variables)"
{
    echo "# Managed by chargehand setup-agent-user.sh"
    for name in "${projects[@]}"; do
        pfile="$(project_file "$name")"
        jq -r '(.sandbox_env // {}) | to_entries[] | "export \(.key)=\(.value | @sh)"' "$pfile"
        jq -r '(.path_prepend // [])[] | sub("^~"; "$HOME") | "export PATH=\"\(.):$PATH\""' "$pfile"
    done
} > "$work/env.sh"
as_agent sh -c 'cat > "$1"' sh "$AGENT_HOME/.bashrc.d/chargehand.sh" < "$work/env.sh"

if [ "$remove_old" -eq 1 ]; then
    step "14. removing the pre-harness launcher and its sudoers entry"
    rm -f /usr/local/bin/opencode-agent-sandbox /etc/sudoers.d/opencode-agent
fi

cat <<EOF

Done. If OpenCode isn't installed for '$AGENT' yet (as that user, not root):

  sudo -iu $AGENT
  curl -fsSL https://opencode.ai/v2/install | bash
  source ~/.bashrc
  opencode auth login --standalone <provider>      # once per subscription provider
  exit

Then, from your own account:

  sudo -n -u $AGENT $LAUNCHER --selftest --project ${projects[0]}   # must print only "ok" lines

and start the server with its password in OPENCODE_SERVER_PASSWORD, however you keep secrets, e.g.

  OPENCODE_SERVER_PASSWORD="\$(secret-tool lookup service opencode)" sudo -n -u $AGENT $LAUNCHER
EOF
