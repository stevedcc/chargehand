#!/usr/bin/env bash
# images/build.sh: builds a Chargehand image for linux/amd64 and linux/arm64 (or the --platforms
# given) into one manifest list and prints its digest.
# Usage: images/build.sh runner (--sdk <dotnet-sdk-version> --playwright <version> | --from <repo> [--rev <rev>]) --browsers "<list>" --tag <ref> [--platforms <list>] [--push]
#   runner      the verify lane's runner image (images/runner/Containerfile): the .NET SDK, Node and
#               the Playwright CLI with the listed browsers (chromium, firefox, webkit), git and
#               chargehand-run, user runner (UID 1000). The image records the versions in its labels
#               org.chargehand.runner.dotnet-sdk, .playwright and .browsers.
#   --from      reads both versions from the project's repo (bare or not) at <rev> (default HEAD):
#   --rev       the SDK from global.json's sdk.version, Playwright from the Microsoft.Playwright(.*)
#               package version in its *.csproj, *.props and *.targets files. Not with --sdk or
#               --playwright. The versions used are printed on stderr before the build.
#   --platforms comma-separated, from linux/amd64 and linux/arm64 (default both): one architecture
#               skips the slow emulated build when every lane has the same one.
#   --push      pushes the manifest list to <ref>'s registry (log in first). The digest printed is then
#               the registry's, the one a lane pins (lane.json runner_image <ref-repo>@<digest>);
#               without --push it is the local list's, which a registry may store under another.
#   Runtime: $CHARGEHAND_RUNTIME, podman (default) or docker (buildx). The other architecture builds
#   under emulation (qemu-user-static / binfmt), which is slow.
#   Exit 0 built (and pushed); 2 usage, or the repo's pins cannot be read; other: the build or the
#   push failed.
set -uo pipefail
IMAGES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$IMAGES_DIR/../scripts/lib/runtime.sh"
. "$IMAGES_DIR/../scripts/lib/pins.sh"

usage() { sed -n '4,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ "${1:-}" = runner ] || usage
shift
sdk="" playwright="" from="" rev="" browsers="" tag="" push=no platforms=linux/amd64,linux/arm64
while [ "$#" -gt 0 ]; do
    case "$1" in
        --sdk|--playwright|--from|--rev|--browsers|--tag|--platforms) [ "$#" -ge 2 ] || usage ;;&
        --sdk) sdk="$2"; shift 2 ;;
        --from) from="$2"; shift 2 ;;
        --rev) rev="$2"; shift 2 ;;
        --playwright) playwright="$2"; shift 2 ;;
        --browsers) browsers="$2"; shift 2 ;;
        --tag) tag="$2"; shift 2 ;;
        --platforms) platforms="$2"; shift 2 ;;
        --push) push=yes; shift ;;
        *) usage ;;
    esac
done
[ -n "$rev" ] && [ -z "$from" ] && usage
from_note=""
if [ -n "$from" ]; then
    [ -z "$sdk" ] && [ -z "$playwright" ] || die "--from reads the versions; do not pass --sdk or --playwright with it"
    rev="${rev:-HEAD}"
    # pin FN WHAT: FN's value, or death: its own message plus the hint (2), or nothing pinned (1).
    pin() {
        local value rc sha
        value="$("$1" "$from" "$rev" 2>"$pin_err")"; rc=$?
        case "$rc" in
            0) printf '%s\n' "$value" ;;
            1) sha="$(git -C "$from" rev-parse --verify --quiet "$rev^{commit}")"
               die "$from at ${sha:0:7} pins no $2" ;;
            *) die "$(head -n 1 "$pin_err") (pass --sdk / --playwright by hand)" ;;
        esac
    }
    pin_err="$(mktemp)"; trap 'rm -f "$pin_err"' EXIT
    sdk="$(pin pins_sdk ".NET SDK (global.json sdk.version)")" || exit $?
    playwright="$(pin pins_playwright "Microsoft.Playwright version")" || exit $?
    from_sha="$(git -C "$from" rev-parse --verify --quiet "$rev^{commit}")"
    from_note=" (from $from at ${from_sha:0:7})"
fi
[ -n "$sdk" ] && [ -n "$playwright" ] && [ -n "$tag" ] || usage
[[ "$sdk" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "bad SDK version \"$sdk\""
[[ "$playwright" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "bad Playwright version \"$playwright\""
[[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]] || die "bad tag \"$tag\""
read -ra list <<<"$browsers"
[ "${#list[@]}" -gt 0 ] || die "--browsers needs at least one browser"
for b in "${list[@]}"; do
    case "$b" in chromium|firefox|webkit) ;; *) die "unknown browser \"$b\" (expected chromium, firefox or webkit)" ;; esac
done
[ -n "$platforms" ] && [ "${platforms%,}" = "$platforms" ] || usage
IFS=, read -ra plist <<<"$platforms"
for p in "${plist[@]}"; do
    case "$p" in linux/amd64|linux/arm64) ;; *) die "unknown platform \"$p\" (expected linux/amd64 or linux/arm64)" ;; esac
done

echo "build.sh: .NET SDK $sdk, Playwright $playwright$from_note" >&2
export CHARGEHAND_RUNTIME="${CHARGEHAND_RUNTIME:-podman}"
digest="$(rt_build_multiarch "$tag" "$IMAGES_DIR/runner/Containerfile" "$IMAGES_DIR/runner" "$platforms" "$push" \
    --build-arg "DOTNET_SDK_VERSION=$sdk" --build-arg "PLAYWRIGHT_VERSION=$playwright" \
    --build-arg "PLAYWRIGHT_BROWSERS=${list[*]}")" || exit $?
[ "$push" = yes ] || echo "build.sh: $tag built, not pushed; the digest below is the local digest of its manifest list" >&2
printf '%s\n' "$digest"
