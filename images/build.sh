#!/usr/bin/env bash
# images/build.sh: builds a Chargehand image for linux/amd64 and linux/arm64 into one manifest list
# and prints its digest.
# Usage: images/build.sh runner --sdk <dotnet-sdk-version> --playwright <version> --browsers "<list>" --tag <ref> [--push]
#   runner      the verify lane's runner image (images/runner/Containerfile): the .NET SDK, Node and
#               the Playwright CLI with the listed browsers (chromium, firefox, webkit), git and
#               chargehand-run, user runner (UID 1000).
#   --push      pushes the manifest list to <ref>'s registry (log in first). The digest printed is then
#               the registry's, the one a lane pins (lane.json runner_image <ref-repo>@<digest>);
#               without --push it is the local list's, which a registry may store under another.
#   Runtime: $CHARGEHAND_RUNTIME, podman (default) or docker (buildx). The other architecture builds
#   under emulation (qemu-user-static / binfmt), which is slow.
#   Exit 0 built (and pushed); 2 usage; other: the build or the push failed.
set -uo pipefail
IMAGES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$IMAGES_DIR/../scripts/lib/runtime.sh"

usage() { sed -n '4,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ "${1:-}" = runner ] || usage
shift
sdk="" playwright="" browsers="" tag="" push=no
while [ "$#" -gt 0 ]; do
    case "$1" in
        --sdk|--playwright|--browsers|--tag) [ "$#" -ge 2 ] || usage ;;&
        --sdk) sdk="$2"; shift 2 ;;
        --playwright) playwright="$2"; shift 2 ;;
        --browsers) browsers="$2"; shift 2 ;;
        --tag) tag="$2"; shift 2 ;;
        --push) push=yes; shift ;;
        *) usage ;;
    esac
done
[ -n "$sdk" ] && [ -n "$playwright" ] && [ -n "$tag" ] || usage
[[ "$sdk" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "bad SDK version \"$sdk\""
[[ "$playwright" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "bad Playwright version \"$playwright\""
[[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]] || die "bad tag \"$tag\""
read -ra list <<<"$browsers"
[ "${#list[@]}" -gt 0 ] || die "--browsers needs at least one browser"
for b in "${list[@]}"; do
    case "$b" in chromium|firefox|webkit) ;; *) die "unknown browser \"$b\" (expected chromium, firefox or webkit)" ;; esac
done

export CHARGEHAND_RUNTIME="${CHARGEHAND_RUNTIME:-podman}"
digest="$(rt_build_multiarch "$tag" "$IMAGES_DIR/runner/Containerfile" "$IMAGES_DIR/runner" linux/amd64,linux/arm64 "$push" \
    --build-arg "DOTNET_SDK_VERSION=$sdk" --build-arg "PLAYWRIGHT_VERSION=$playwright" \
    --build-arg "PLAYWRIGHT_BROWSERS=${list[*]}")" || exit $?
[ "$push" = yes ] || echo "build.sh: $tag built, not pushed; the digest below is the local digest of its manifest list" >&2
printf '%s\n' "$digest"
