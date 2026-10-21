#!/usr/bin/env bash
# Gate of bisquite names (plan 2026-10-19, Tasks 3 and 28).
#
#   tools/check-names.sh            the whole repository: every file git tracks
#                                   or would track (.gitignore is honoured),
#                                   except the history (CHANGELOG.md, docs/history/,
#                                   docs/research/, docs/plans/) and this gate
#                                   with its test and fixtures
#   tools/check-names.sh DIR...     the given extension directories
#
# The catalog is cream/v1: extensions live under /opt/cream/ext, /etc/cream,
# /var/lib/cream/ext and take their settings from the hook environment. The
# layout 2 paths, the old shared library, the bisquite-* CLIs and units, the
# old settings keys and the nft names of bisquite must not come back — neither
# in an extension nor in the tools and documents describing the format. The
# word "bisquite" alone (the name of the image builder) is allowed.
# Binary files (images, archives) are skipped.
#
# Exceptions, for text that has to name the old thing (rename tables of a
# README, a test asserting absence):
#   a line containing `check-names: allow`              — that line;
#   lines between `check-names: off` and `check-names: on` — that block.
#
# Exit: 0 — clean; 1 — forbidden names found (file:line: text); 2 — usage.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"

FORBIDDEN=(
    /opt/bisquite /etc/bisquite /var/lib/bisquite
    bisquite-conf bisquite-desktop bisquite-firewall bisquite-sensing bisquite-l4t
    BISQUITE_ 'inet bisquite' BISQUITE-INPUT
    zz-bisquite 10-bisquite 99-bisquite
    lib/get_cloud_user lib/l4t
)

# History and the gate itself (paths from the repository root; a trailing /
# is a directory).
EXCLUDE=(
    CHANGELOG.md docs/history/ docs/research/ docs/plans/
    tools/check-names.sh tools/test-check-names.sh tools/testdata/check-names/
)

excluded() {
    local e
    for e in "${EXCLUDE[@]}"; do
        if [[ "$e" == */ ]]; then [[ "$1" == "$e"* ]] && return 0
        else [[ "$1" == "$e" ]] && return 0; fi
    done
    return 1
}

# files: NUL-separated absolute paths to check.
files=()
if (( $# )); then
    for d in "$@"; do
        [[ -f "$d/extension.yaml" ]] || { echo "check-names: $d: нет extension.yaml" >&2; exit 2; }
        while IFS= read -r -d '' f; do files+=("$f"); done < <(find "$d" -type f -print0 | sort -z)
    done
    what="расширений cream/v1: $#"
else
    git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || { echo "check-names: $REPO — не рабочее дерево git" >&2; exit 2; }
    while IFS= read -r -d '' rel; do
        excluded "$rel" && continue
        [[ -f "$REPO/$rel" ]] && files+=("$REPO/$rel")
    done < <(git -C "$REPO" ls-files -z --cached --others --exclude-standard | sort -zu)
    what="файлов: ${#files[@]}"
fi

pattern_file="$(mktemp)"
trap 'rm -f -- "$pattern_file"' EXIT
printf '%s\n' "${FORBIDDEN[@]}" > "$pattern_file"

found=0
for f in "${files[@]}"; do
    # Binary (NUL bytes or invalid text): nothing to read; empty: nothing to find.
    grep -Iq . "$f" 2>/dev/null || continue
    rel="${f#"$REPO"/}"
    # awk: drop exception lines and blocks, print file:line: text of the rest
    # that carry a forbidden name (fixed strings from the pattern file).
    hits="$(awk -v file="$rel" -v pf="$pattern_file" '
        BEGIN { while ((getline p < pf) > 0) if (p != "") pats[++n] = p }
        # A line naming both markers documents them and opens no block.
        /check-names: off/ && !/check-names: on/ { off = 1; next }
        /check-names: on/ && !/check-names: off/ { off = 0; next }
        off || /check-names: allow/ { next }
        { for (i = 1; i <= n; i++) if (index($0, pats[i])) { print file ":" FNR ": " $0; break } }
    ' "$f")"
    if [[ -n "$hits" ]]; then
        printf '%s\n' "$hits"
        found=1
    fi
done

if (( found )); then
    echo "check-names: остались имена bisquite (см. выше; исключения — check-names: allow / off…on)" >&2
    exit 1
fi
echo "check-names: ок, $what"
