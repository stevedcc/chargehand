# One layer over the container CLIs a verify lane can use: docker, podman and Apple's `container`.
# Source it, don't run it. The runtime comes from $CHARGEHAND_RUNTIME; every function returns the
# CLI's exit code. Every object created here carries --label chargehand=1 plus the caller's labels.
# The Apple `container` verbs follow its documentation and are UNVERIFIED until an Apple lane is
# added (spec: "to check during the build"). Docker and Podman share one flag set.
. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

rt_bin() {
    case "${CHARGEHAND_RUNTIME:-}" in
        docker|podman|container) printf '%s\n' "$CHARGEHAND_RUNTIME" ;;
        *) die "unknown runtime \"${CHARGEHAND_RUNTIME:-}\" (expected docker, podman or container)" ;;
    esac
}

rt_network_create() {
    local bin; bin="$(rt_bin)" || return $?
    local name="$1" internal="$2" flags=() extra=()
    shift 2
    while [ "$#" -gt 0 ]; do extra+=(--label "$1"); shift; done
    case "$internal" in
        yes) [ "$bin" = container ] && die "internal networks are not supported by the container runtime"
             flags=(--internal) ;;
        no) ;;
        *) die "rt_network_create: internal must be yes or no, got \"$internal\"" ;;
    esac
    "$bin" network create "${flags[@]}" --label chargehand=1 "${extra[@]}" "$name"
}

# rt_default_network: the runtime's built-in network, the one with outbound access. Apple's name is
# UNVERIFIED.
rt_default_network() {
    local bin; bin="$(rt_bin)" || return $?
    case "$bin" in
        podman) echo podman ;;
        docker) echo bridge ;;
        container) echo default ;;
    esac
}

rt_network_rm() {
    local bin; bin="$(rt_bin)" || return $?
    if [ "$bin" = container ]; then "$bin" network delete "$1"; else "$bin" network rm "$1"; fi
}

# rt_mount_spec BIN HOST:CONTAINER[:OPTS]: the -v value for BIN. Docker and Podman take OPTS as they
# are, z/Z (SELinux relabel, ruling R8) included; Apple's CLI has no SELinux, so z and Z are dropped.
rt_mount_spec() {
    [ "$1" = container ] || { printf '%s\n' "$2"; return; }
    local host="${2%%:*}" rest="${2#*:}" target opts kept="" o
    target="${rest%%:*}"
    [ "$target" != "$rest" ] || { printf '%s\n' "$2"; return; }
    IFS=, read -ra opts <<<"${rest#*:}"
    for o in "${opts[@]}"; do case "$o" in z|Z|'') ;; *) kept+="${kept:+,}$o" ;; esac; done
    printf '%s\n' "$host:$target${kept:+:$kept}"
}

# rt_run NAME IMAGE NETWORK CPUS MEMORY [--mount h:c[:opts]]... [--env K=V]... [--workdir D] [--user U:G] [--label k=v]... -- CMD...
rt_run() {
    local bin; bin="$(rt_bin)" || return $?
    local name="$1" image="$2" network="$3" cpus="$4" memory="$5"; shift 5
    local mounts=() envs=() workdir=() user=() labels=(--label chargehand=1)
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --mount) mounts+=(-v "$(rt_mount_spec "$bin" "$2")"); shift 2 ;;
            --env) envs+=(-e "$2"); shift 2 ;;
            --workdir) workdir=(--workdir "$2"); shift 2 ;;
            --user) user=(--user "$2"); shift 2 ;;
            --label) labels+=(--label "$2"); shift 2 ;;
            --) shift; break ;;
            *) die "rt_run: unexpected argument \"$1\"" ;;
        esac
    done
    "$bin" run -d --name "$name" --network "$network" --cpus "$cpus" --memory "$memory" \
        "${mounts[@]}" "${envs[@]}" "${workdir[@]}" "${user[@]}" "${labels[@]}" "$image" "$@"
}

# The runner image runs as runner (UID 1000), not as the lane user who owns the bind-mounted
# directories (ruling R9; no user-namespace run flags).
# rt_own_dir DIR UID GID: gives DIR, recursively, to UID:GID as containers see them. Rootless Podman:
# chown inside its user namespace. Docker: nothing; the runner runs as the host user instead
# (rt_runner_user). Apple: nothing, UNVERIFIED.
rt_own_dir() {
    local bin; bin="$(rt_bin)" || return $?
    [ "$bin" = podman ] || return 0
    "$bin" unshare chown -R "$2:$3" "$1"
}

# rt_remove_dir DIR: removes DIR, also what a container wrote there (Podman: inside its user namespace).
rt_remove_dir() {
    local bin; bin="$(rt_bin)" || return $?
    if [ "$bin" = podman ]; then "$bin" unshare rm -rf "$1"; else rm -rf "$1"; fi
}

# rt_runner_user: the --user value for a runner, empty for the image's own user. Docker: the host
# user, who owns the mounts (rt_own_dir does nothing there).
rt_runner_user() {
    local bin; bin="$(rt_bin)" || return $?
    [ "$bin" != docker ] || printf '%s:%s\n' "$(id -u)" "$(id -g)"
}

# rt_exec NAME -- CMD...
rt_exec() {
    local bin; bin="$(rt_bin)" || return $?
    local name="$1"; shift
    [ "${1:-}" = -- ] && shift
    "$bin" exec "$name" "$@"
}

# rt_wait NAME: blocks until the container stops, prints its exit code.
rt_wait() {
    local bin; bin="$(rt_bin)" || return $?
    if [ "$bin" != container ]; then "$bin" wait "$1"; return; fi
    local json
    while :; do
        json="$("$bin" inspect "$1")" || return $?
        [ "$(jq -r '.[0].status // .status' <<<"$json")" = stopped ] && break
        sleep 1
    done
    # A missing exit code must not read as 0 ("passed"): print nothing and fail.
    jq -er '(.[0] // .) | .exitCode | select(. != null)' <<<"$json" 2>/dev/null || return 1
}

rt_logs() { local bin; bin="$(rt_bin)" || return $?; "$bin" logs "$1"; }

# rt_logs_follow NAME: streams the container's output until it stops. Apple's --follow is UNVERIFIED.
rt_logs_follow() {
    local bin; bin="$(rt_bin)" || return $?
    if [ "$bin" = container ]; then "$bin" logs --follow "$1"; else "$bin" logs -f "$1"; fi
}

# rt_rm NAME: force-remove; succeeds when the container is already gone.
rt_rm() {
    local bin; bin="$(rt_bin)" || return $?
    if [ "$bin" = container ]; then "$bin" delete --force "$1"; else "$bin" rm -f "$1"; fi >/dev/null 2>&1
    return 0
}

rt_pull() {
    local bin; bin="$(rt_bin)" || return $?
    if [ "$bin" = container ]; then "$bin" image pull "$1"; else "$bin" pull "$1"; fi
}

# rt_image_digest IMAGE: prints the repo (manifest) digest sha256:...; fails with no output when the
# image has none (a locally built image, or an unexpected CLI output). The image ID is not used: it is
# the config digest (docker) or bare hex (podman), not what a pin is made of.
rt_image_digest() {
    local bin; bin="$(rt_bin)" || return $?
    local out digest
    if [ "$bin" = container ]; then out="$("$bin" image inspect "$1")" || return $?
    else out="$("$bin" image inspect --format '{{json .RepoDigests}}' "$1")" || return $?; fi
    # The digest the image was pinned by (IMAGE@sha256:...) when the runtime lists it: a
    # multi-platform image also has its platform manifest's digest, which may come first.
    local pinned="${1##*@}"
    if [[ "$1" == *@sha256:* ]] && grep -qx "$pinned" <(grep -o 'sha256:[0-9a-f]\{64\}' <<<"$out"); then
        digest="$pinned"
    else
        digest="$(grep -o 'sha256:[0-9a-f]\{64\}' <<<"$out" | head -n 1)"
    fi
    [ -n "$digest" ] || return 1
    printf '%s\n' "$digest"
}

rt_ls_labelled() {
    local bin; bin="$(rt_bin)" || return $?
    if [ "$bin" = container ]; then
        "$bin" ls -a --format json | jq -r --arg l "$1" '.[] | select(.configuration.labels // {} | to_entries | any("\(.key)=\(.value)" == $l)) | .configuration.id'
    else
        "$bin" ps -a --filter "label=$1" --format '{{.Names}}'
    fi
}

rt_networks_labelled() {
    local bin; bin="$(rt_bin)" || return $?
    if [ "$bin" = container ]; then
        "$bin" network ls --format json | jq -r --arg l "$1" '.[] | select(.config.labels // {} | to_entries | any("\(.key)=\(.value)" == $l)) | .id'
    else
        "$bin" network ls --filter "label=$1" --format '{{.Name}}'
    fi
}

# rt_build_multiarch TAG CONTAINERFILE CONTEXT PLATFORMS PUSH [--build-arg K=V]...: builds PLATFORMS
# (comma-separated) into one manifest list TAG; PUSH=yes also pushes it to TAG's registry. The build
# output goes to stderr, the digest to stdout: the pushed one with PUSH=yes, else the local list's (a
# registry may store the list under another digest, so a lane pins what a push prints). Podman: build
# --manifest, a stale list of the same name removed first (a build adds to it). Docker: buildx; its
# local multi-architecture --load needs the containerd image store. UNVERIFIED (no Docker lane yet).
# Apple's container is refused.
rt_build_multiarch() {
    local bin; bin="$(rt_bin)" || return $?
    local tag="$1" file="$2" context="$3" platforms="$4" push="$5"; shift 5
    local args=() tmp rc=0 digest="" out
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --build-arg) args+=(--build-arg "$2"); shift 2 ;;
            *) die "rt_build_multiarch: unexpected argument \"$1\"" ;;
        esac
    done
    case "$push" in yes|no) ;; *) die "rt_build_multiarch: push must be yes or no, got \"$push\"" ;; esac
    [ "$bin" != container ] || die "multi-architecture builds need docker or podman, not the container runtime"
    tmp="$(mktemp)" || return 1
    if [ "$bin" = docker ]; then
        out=--load; [ "$push" = yes ] && out=--push
        "$bin" buildx build --platform "$platforms" -f "$file" -t "$tag" "${args[@]}" --metadata-file "$tmp" \
            "$out" "$context" >&2 || rc=$?
        [ "$rc" -eq 0 ] && digest="$(jq -r '."containerimage.digest" // empty' "$tmp" 2>/dev/null)"
    else
        if "$bin" manifest exists "$tag"; then "$bin" manifest rm "$tag" >/dev/null || rc=$?; fi
        if [ "$rc" -eq 0 ]; then
            "$bin" build --platform "$platforms" --manifest "$tag" -f "$file" "${args[@]}" "$context" >&2 || rc=$?
        fi
        if [ "$rc" -eq 0 ] && [ "$push" = yes ]; then
            "$bin" manifest push --all --digestfile "$tmp" "$tag" "docker://$tag" >&2 || rc=$?
            [ "$rc" -eq 0 ] && digest="$(cat "$tmp")"
        elif [ "$rc" -eq 0 ]; then
            # The tagged entry is the list (its per-architecture images carry no name). Its Digest
            # field is the empty list `build --manifest` starts from; the list as built is its last
            # repo digest (Podman 5.8: equal to the sha256 of `skopeo inspect --raw`).
            digest="$("$bin" images --format json "$tag" \
                | jq -r '[.[] | select((.Names // []) | length > 0) | .RepoDigests // [] | last][0] // empty | sub("^.*@"; "")' 2>/dev/null)"
        fi
    fi
    rm -f "$tmp"
    [ "$rc" -eq 0 ] || return "$rc"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "chargehand: could not read the digest of $tag" >&2; return 1; }
    printf '%s\n' "$digest"
}
