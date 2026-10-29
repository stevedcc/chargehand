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
    local name="$1" internal="$2" flags=()
    case "$internal" in
        yes) [ "$bin" = container ] && die "internal networks are not supported by the container runtime"
             flags=(--internal) ;;
        no) ;;
        *) die "rt_network_create: internal must be yes or no, got \"$internal\"" ;;
    esac
    "$bin" network create "${flags[@]}" --label chargehand=1 "$name"
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

# rt_run NAME IMAGE NETWORK CPUS MEMORY [--mount h:c[:ro]]... [--env K=V]... [--workdir D] [--label k=v]... -- CMD...
rt_run() {
    local bin; bin="$(rt_bin)" || return $?
    local name="$1" image="$2" network="$3" cpus="$4" memory="$5"; shift 5
    local mounts=() envs=() workdir=() labels=(--label chargehand=1)
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --mount) mounts+=(-v "$2"); shift 2 ;;
            --env) envs+=(-e "$2"); shift 2 ;;
            --workdir) workdir=(--workdir "$2"); shift 2 ;;
            --label) labels+=(--label "$2"); shift 2 ;;
            --) shift; break ;;
            *) die "rt_run: unexpected argument \"$1\"" ;;
        esac
    done
    "$bin" run -d --name "$name" --network "$network" --cpus "$cpus" --memory "$memory" \
        "${mounts[@]}" "${envs[@]}" "${workdir[@]}" "${labels[@]}" "$image" "$@"
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
    digest="$(grep -o 'sha256:[0-9a-f]\{64\}' <<<"$out" | head -n 1)"
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
