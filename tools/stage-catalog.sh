#!/usr/bin/env bash
# Staged catalog: the catalog of the working tree with the shared files laid in,
# as the snapshot (tools/catalog-snapshot.sh) lays them from a commit.
#
#   tools/stage-catalog.sh OUT              cream-catalog.yaml, LICENSE, NOTICE and
#                                           the roots of cream-catalog.yaml, without
#                                           the tests/ of the extensions, into OUT
#   tools/stage-catalog.sh --ext DIR OUT    one extension directory, without tests/,
#                                           into OUT/<basename>; prints that path
#
# The shared core of the Teleport extensions lives once in git, lib/teleport-core.sh
# (spec cream 2026-10-20-openwrt §4.2, ruling Р11); its consumers — one
# <family>/<name> under extensions/ per line of lib/teleport-core.consumers (#
# comments) — get it as files/teleport-core.sh (0644, byte-equal). Everything that
# works on the catalog as cream sees it uses this tree: cream validate
# (cream-validate.sh), cream check (cream-check.sh), the H-tests of the consumers,
# the live tests (live-test.sh), the OpenWrt scenario (test-openwrt.sh) and a path
# source (`cream source add --path OUT`). tools/check-teleport-core.sh keeps the
# copies out of git.
#
# OUT must not exist or be empty (with --ext: OUT/<basename> must not exist). Exit: 0 — staged; 2 — setup failure (no core, a
# consumer without its directory, OUT busy).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
CORE="$REPO/lib/teleport-core.sh"
CONSUMERS="$REPO/lib/teleport-core.consumers"

die() { echo "stage-catalog: $*" >&2; exit 2; }

ext=""
if [[ "${1:-}" == --ext ]]; then
    ext="${2:?--ext требует каталог расширения}"; shift 2
fi
(( $# == 1 )) || die "использование: stage-catalog.sh [--ext DIR] OUT"
out="$1"

[[ -f "$CORE" ]] || die "нет $CORE"
[[ -f "$CONSUMERS" ]] || die "нет $CONSUMERS"
consumers=()
while IFS= read -r c || [[ -n "$c" ]]; do
    c="${c%%#*}"; c="${c//[[:space:]]/}"
    [[ -n "$c" ]] || continue
    [[ "$c" =~ ^[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9._-]*$ ]] || die "$CONSUMERS: «$c» — не <семейство>/<имя>"
    [[ -f "$REPO/extensions/$c/extension.yaml" ]] || die "$CONSUMERS: потребитель $c — нет extensions/$c/extension.yaml"
    consumers+=("$c")
done < "$CONSUMERS"

if [[ -z "$ext" && -e "$out" ]]; then
    [[ -d "$out" && -z "$(ls -A -- "$out")" ]] || die "$out уже есть и не пуст"
fi
mkdir -p -- "$out"
out="$(cd "$out" && pwd)"

# lay_core <consumer> <staged extension dir>
lay_core() {
    mkdir -p -- "$2/files"
    cp -- "$CORE" "$2/files/teleport-core.sh"
    chmod 0644 -- "$2/files/teleport-core.sh"
}

# copy_ext <src> <dst>: the extension without tests/.
copy_ext() {
    cp -a -- "$1" "$2"
    rm -r -f -- "$2/tests"
}

if [[ -n "$ext" ]]; then
    [[ -f "$ext/extension.yaml" ]] || die "$ext: нет extension.yaml"
    src="$(cd "$ext" && pwd)"
    dst="$out/$(basename "$src")"
    [[ ! -e "$dst" ]] || die "$dst уже есть"
    copy_ext "$src" "$dst"
    rel="${src#"$REPO"/extensions/}"
    for c in "${consumers[@]}"; do
        [[ "$src" == "$REPO/extensions/$rel" && "$rel" == "$c" ]] && lay_core "$c" "$dst"
    done
    printf '%s\n' "$dst"
    exit 0
fi

catalog="$REPO/cream-catalog.yaml"
[[ -f "$catalog" ]] || die "нет $catalog"
roots_raw="$(sed -nE 's/^roots:[[:space:]]*(\[[^]]*\]).*$/\1/p' "$catalog" | head -n1)"
[[ "$roots_raw" =~ ^\[(.*)\]$ ]] || die "cream-catalog.yaml: roots — ждали список вида [a, b]"
IFS=',' read -r -a roots <<< "${BASH_REMATCH[1]}"
cp -p -- "$catalog" "$out/"
for f in LICENSE NOTICE; do
    [[ -f "$REPO/$f" ]] && cp -p -- "$REPO/$f" "$out/"
done
for r in "${roots[@]}"; do
    r="${r//[[:space:]]/}"; r="${r%/}"
    [[ -n "$r" ]] || continue
    [[ -d "$REPO/$r" ]] || continue
    mkdir -p -- "$out/$r"
    for d in "$REPO/$r"/*/; do
        [[ -f "$d/extension.yaml" ]] || continue
        copy_ext "${d%/}" "$out/$r/$(basename "$d")"
    done
done
for c in "${consumers[@]}"; do
    [[ -d "$out/extensions/$c" ]] || die "потребитель $c не лежит под roots cream-catalog.yaml"
    lay_core "$c" "$out/extensions/$c"
done
