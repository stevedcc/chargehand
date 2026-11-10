# The version pins a project's own repo holds at a commit: the .NET SDK in global.json and the
# Microsoft.Playwright package version. Source it after harness.sh, don't run it.
# Files are read with `git show REV:<path>` and listed with `git grep -z -l ... REV`, so a bare repo
# works and nothing is checked out. Everything read comes from an untrusted commit: it is only ever
# compared and printed (quoted), never evaluated.
# Contract (no function here dies): the value on stdout and status 0; status 1 and no output when
# nothing is pinned; status 2 and one line on stderr naming the problem (callers add their hints).

# _pins_commit REPO REV: the full SHA of REV in REPO, or status 2 with a message.
_pins_commit() {
    local sha
    if ! sha="$(git -C "$1" rev-parse --verify --quiet "$2^{commit}" 2>/dev/null)" || [ -z "$sha" ]; then
        printf '%s\n' "\"$(_pins_printable "$2")\" is not a commit in $1" >&2
        return 2
    fi
    printf '%s\n' "$sha"
}

# _pins_printable TEXT: TEXT with control characters (a newline in a path, say; C1 bytes too, as
# agent_text strips them) shown as "?", so a message stays one line on the terminal.
_pins_printable() { printf '%s' "$1" | LC_ALL=C tr '\000-\037\177-\237' '?'; }

# pins_sdk REPO REV: global.json's sdk.version at REV.
pins_sdk() {
    local repo="$1" rev="$2" sha rev7 out
    sha="$(_pins_commit "$repo" "$rev")" || return 2
    rev7="${sha:0:7}"
    git -C "$repo" cat-file -e "$sha:global.json" 2>/dev/null || return 1
    # Exactly one JSON document; comments (which dotnet allows) make jq fail, and that is a refusal.
    if ! out="$(git -C "$repo" show "$sha:global.json" | jq -r -s '
            if length != 1 then error("not one document") else .[0] end
            | if type == "object" and (.sdk | type) == "object" and (.sdk | has("version"))
              then (.sdk.version | if type == "string" then "v:" + . else "t:" + type end)
              else "none" end' 2>/dev/null)"; then
        printf '%s\n' "global.json at $rev7 is not plain JSON" >&2
        return 2
    fi
    case "$out" in
        none) return 1 ;;
        v:) printf '%s\n' "global.json at $rev7 has an empty sdk.version" >&2; return 2 ;;
        v:*) printf '%s\n' "${out#v:}" ;;
        *) printf '%s\n' "global.json at $rev7 has a sdk.version that is not a string" >&2; return 2 ;;
    esac
}

# _pins_attr TAG NAME...: the value of the first NAME attribute set on TAG (one element's text,
# newlines already flattened), in double or single quotes. Status 1 when none is set.
_pins_attr() {
    local tag="$1" name re; shift
    for name in "$@"; do
        re="[[:space:]]${name}[[:space:]]*=[[:space:]]*(\"([^\"]*)\"|'([^']*)')"
        if [[ "$tag" =~ $re ]]; then
            printf '%s' "${BASH_REMATCH[2]-}${BASH_REMATCH[3]-}"
            return 0
        fi
    done
    return 1
}

# pins_playwright REPO REV: the one version of Microsoft.Playwright or Microsoft.Playwright.<Word>
# set by a PackageReference or PackageVersion element in a *.csproj, *.props or *.targets file.
pins_playwright() {
    local repo="$1" rev="$2" sha rev7 path text tag name version referenced=no i
    local -a versions=() where=() tags=()
    sha="$(_pins_commit "$repo" "$rev")" || return 2
    rev7="${sha:0:7}"
    while IFS= read -r -d '' path; do
        path="${path#"$sha":}"
        # The whole file on one line, XML comments removed, so an element split over lines (or one
        # commented out) is seen as it is; then one PackageReference/PackageVersion tag per line.
        text="$(git -C "$repo" show "$sha:$path" | LC_ALL=C tr '\r\n\t' '   ' | awk '{
                    out = ""
                    while ((i = index($0, "<!--")) > 0) {
                        out = out substr($0, 1, i - 1); $0 = substr($0, i + 4)
                        j = index($0, "-->"); if (j == 0) { $0 = ""; break }
                        $0 = substr($0, j + 3)
                    }
                    print out $0 }')"
        mapfile -t tags < <(grep -oE '<Package(Reference|Version)[[:space:]][^>]*>' <<<"$text")
        for tag in "${tags[@]}"; do
            name="$(_pins_attr "$tag" Include Update)" || continue
            name="${name,,}"
            [[ "$name" =~ ^microsoft\.playwright(\.[a-z]+)?$ ]] || continue
            referenced=yes
            version="$(_pins_attr "$tag" VersionOverride Version)" || continue
            if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                printf 'bad Playwright version "%s" in %s\n' "$(_pins_printable "$version")" "$(_pins_printable "$path")" >&2
                return 2
            fi
            for i in "${!versions[@]}"; do [ "${versions[$i]}" = "$version" ] && continue 2; done
            versions+=("$version"); where+=("$path")
        done
    done < <(git -C "$repo" grep -z -l -i --full-name -e playwright "$sha" -- '*.csproj' '*.props' '*.targets' 2>/dev/null)
    if [ "${#versions[@]}" -eq 0 ]; then
        [ "$referenced" = no ] && return 1
        printf '%s\n' "$rev7 references Microsoft.Playwright but no version was found" >&2
        return 2
    fi
    if [ "${#versions[@]}" -gt 1 ]; then
        local list=""
        for i in "${!versions[@]}"; do
            list+="${list:+, }${versions[$i]} ($(_pins_printable "${where[$i]}"))"
        done
        printf '%s\n' "Playwright versions differ at $rev7: $list" >&2
        return 2
    fi
    printf '%s\n' "${versions[0]}"
}
