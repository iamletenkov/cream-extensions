#!/usr/bin/env bash
# Gate of bisquite names in cream/v1 extensions (plan 2026-10-19, Task 3).
#
#   tools/check-names.sh            every extensions/<family>/<name>/ whose
#                                   extension.yaml says `schema: cream/v1`
#   tools/check-names.sh DIR...     the given extension directories
#
# A cream/v1 extension lives under /opt/cream/ext, /etc/cream, /var/lib/cream/ext
# and takes its settings from the hook environment: the layout 2 paths, the
# bisquite-conf library, the bisquite-* CLIs and units, the BISQUITE_ keys and the
# nft names of bisquite must not survive the conversion. The list of covered
# extensions grows by itself: an extension is checked as soon as its manifest
# turns cream/v1. The word "bisquite" alone (the image builder, `EXTENSION` in a
# README) is allowed.
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

dirs=()
if (( $# )); then
    for d in "$@"; do
        [[ -f "$d/extension.yaml" ]] || { echo "check-names: $d: нет extension.yaml" >&2; exit 2; }
        dirs+=("$d")
    done
else
    while IFS= read -r m; do
        if grep -Eq "^schema:[[:space:]]*[\"']?cream/v1[\"']?[[:space:]]*(#.*)?$" "$m"; then
            dirs+=("$(dirname "$m")")
        fi
    done < <(find "$REPO/extensions" -mindepth 3 -maxdepth 3 -name extension.yaml | sort)
fi
if (( ${#dirs[@]} == 0 )); then
    echo "check-names: расширений cream/v1 нет, проверять нечего"
    exit 0
fi

pattern_file="$(mktemp)"
trap 'rm -f -- "$pattern_file"' EXIT
printf '%s\n' "${FORBIDDEN[@]}" > "$pattern_file"

found=0
for d in "${dirs[@]}"; do
    while IFS= read -r -d '' f; do
        # awk: drop exception lines and blocks, print file:line: text of the rest
        # that carry a forbidden name (fixed strings from the pattern file).
        hits="$(awk -v file="${f#"$REPO"/}" -v pf="$pattern_file" '
            BEGIN { while ((getline p < pf) > 0) if (p != "") pats[++n] = p }
            /check-names: off/ { off = 1; next }
            /check-names: on/  { off = 0; next }
            off || /check-names: allow/ { next }
            { for (i = 1; i <= n; i++) if (index($0, pats[i])) { print file ":" FNR ": " $0; break } }
        ' "$f")"
        if [[ -n "$hits" ]]; then
            printf '%s\n' "$hits"
            found=1
        fi
    done < <(find "$d" -type f -print0 | sort -z)
done

if (( found )); then
    echo "check-names: в расширениях cream/v1 остались имена bisquite (см. выше; исключения — check-names: allow / off…on)" >&2
    exit 1
fi
echo "check-names: ок, расширений cream/v1: ${#dirs[@]}"
