#!/usr/bin/env bash
# Deterministic catalog snapshot: dist/cream-extensions-<v>.tar.gz + dist/SHA256SUMS.
#
#   tools/catalog-snapshot.sh [OUT]     OUT — output directory (default dist/)
#
# The snapshot is taken from a commit, not from the working tree: REF (default
# HEAD) is exported with `git archive`, so uncommitted edits never leak into a
# release asset (a dirty tree gets a warning). The snapshot is the catalog of
# the commit as it is: cream-catalog.yaml, LICENSE, NOTICE and the roots listed
# in cream-catalog.yaml (without the tests/ of the extensions), at the same
# paths as in the repository; tools/, docs/ and the rest stay out. Every
# extension under extensions/ must lie under a root, otherwise it would vanish
# from the snapshot silently — that is an error here. Every shared library
# lib/<lib>.sh of the commit (the Teleport core teleport-core.sh, the downloader
# fetch.sh) goes into files/<lib>.sh (0644) of every consumer of
# lib/<lib>.consumers of the commit — one copy in git, one per consumer in the
# snapshot (spec 2026-10-20-openwrt §4.2, ruling Р11; tools/stage-catalog.sh does
# the same for the working tree).
#
# `cream catalog pack` (cream by the pin tools/cream-pin.env, see
# tools/cream-deb.sh; CREAM_DEB=<.deb> for local runs) runs in debian:12 with
# no network; SOURCE_DATE_EPOCH is the commit time of REF, so two builds of one
# commit give the same bytes (tools/test-snapshot.sh checks it).
#
# Exit: 0 — written; 2 — setup failure; cream's code when the catalog is invalid.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
OUT="${1:-$REPO/dist}"
REF="${REF:-HEAD}"
IMAGE="debian:12"

die() { echo "catalog-snapshot: $*" >&2; exit 2; }

command -v docker >/dev/null 2>&1 || die "нужен docker"
commit="$(git -C "$REPO" rev-parse --verify --quiet "$REF^{commit}")" || die "REF=$REF: нет такого коммита"
catalog="$(git -C "$REPO" show "$commit:cream-catalog.yaml" 2>/dev/null)" \
    || die "$REF: нет cream-catalog.yaml в корне"

# Top-level scalar / flow list of cream-catalog.yaml (the format is fixed by cream).
field() { sed -nE "s/^$1:[[:space:]]*[\"']?([^\"'#]*[^\"'#[:space:]])[\"']?[[:space:]]*(#.*)?$/\1/p" <<<"$catalog" | head -n1; }
name="$(field name)"
version="$(field version)"
[[ "$name" == "cream-extensions" ]] || die "cream-catalog.yaml: name=\"$name\", ждали cream-extensions"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "cream-catalog.yaml: version=\"$version\" — не X.Y.Z"
roots_raw="$(field roots)"
[[ "$roots_raw" =~ ^\[(.*)\]$ ]] || die "cream-catalog.yaml: roots — ждали список вида [a, b]"
IFS=',' read -r -a roots <<<"${BASH_REMATCH[1]}"
for i in "${!roots[@]}"; do
    r="${roots[$i]}"; r="${r#"${r%%[![:space:]]*}"}"; r="${r%"${r##*[![:space:]]}"}"
    roots[i]="${r%/}"
done

# Extensions of the commit: extensions/<family>/<name>/extension.yaml.
dirs=()
while IFS= read -r m; do
    dirs+=("$(dirname "$m")")
done < <(git -C "$REPO" ls-tree -r --name-only "$commit" -- extensions \
            | awk -F/ 'NF == 4 && $4 == "extension.yaml"' | sort)
(( ${#dirs[@]} )) || die "$REF: расширений нет — снимок пуст"
for d in "${dirs[@]}"; do
    covered=0
    for r in "${roots[@]}"; do
        [[ "$(dirname "$d")" == "$r" ]] && covered=1
    done
    (( covered )) || die "$d не лежит под roots cream-catalog.yaml (${roots[*]})"
done

# The shared libraries and their consumers of the commit: pairs "<lib>/<consumer>".
pairs=()
while IFS= read -r list; do
    lib="${list#lib/}"; lib="${lib%.consumers}"
    [[ "$lib" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "$list: имя библиотеки «$lib» — не [a-z0-9-]"
    git -C "$REPO" cat-file -e "$commit:lib/$lib.sh" 2>/dev/null || die "$REF: есть $list, нет lib/$lib.sh"
    while IFS= read -r c || [[ -n "$c" ]]; do
        c="${c%%#*}"; c="${c//[[:space:]]/}"
        [[ -n "$c" ]] || continue
        [[ "$c" =~ ^[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9._-]*$ ]] || die "$list: «$c» — не <семейство>/<имя>"
        covered=0
        for d in "${dirs[@]}"; do [[ "$d" == "extensions/$c" ]] && covered=1; done
        (( covered )) || die "$list: потребитель $c — нет extensions/$c в $REF"
        pairs+=("$lib/$c")
    done < <(git -C "$REPO" show "$commit:$list")
done < <(git -C "$REPO" ls-tree --name-only "$commit" -- lib/ | grep -E '^lib/[^/]+\.consumers$' || true)

if [[ "$REF" == "HEAD" ]] && [[ -n "$(git -C "$REPO" status --porcelain -- cream-catalog.yaml LICENSE NOTICE lib "${roots[@]}")" ]]; then
    echo "ВНИМАНИЕ: в рабочем дереве есть незакоммиченные правки — снимок берётся из коммита ${commit:0:12}" >&2
fi

deb="$("$HERE/cream-deb.sh")" || { rc=$?; (( rc == 3 )) && die "без пина cream снимок не собрать"; exit 2; }
core_dir="$(mktemp -d)"
trap 'rm -r -f -- "$core_dir"' EXIT
for p in ${pairs[@]+"${pairs[@]}"}; do
    lib="${p%%/*}"
    [[ -f "$core_dir/$lib.sh" ]] || git -C "$REPO" show "$commit:lib/$lib.sh" > "$core_dir/$lib.sh"
done
epoch="$(git -C "$REPO" log -1 --format=%ct "$commit")"
asset="cream-extensions-$version.tar.gz"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
rm -f -- "$OUT/$asset" "$OUT/SHA256SUMS"

echo "снимок $name $version из ${commit:0:12} (SOURCE_DATE_EPOCH=$epoch): ${roots[*]}, расширений ${#dirs[@]}"

# shellcheck disable=SC2016  # expanded inside the container
inner='set -eu
umask 022
dpkg-deb -x /cream.deb /tmp/cream
mkdir /tmp/cat
tar -x -C /tmp/cat
asset="$1"; shift
for p in "$@"; do
    lib="${p%%/*}"; c="${p#*/}"
    mkdir -p "/tmp/cat/extensions/$c/files"
    cp "/core/$lib.sh" "/tmp/cat/extensions/$c/files/$lib.sh"
    chmod 0644 "/tmp/cat/extensions/$c/files/$lib.sh"
done
/tmp/cream/usr/bin/cream --version
/tmp/cream/usr/bin/cream catalog pack /tmp/cat --out "/out/$asset"'

git -C "$REPO" archive --format=tar "$commit" -- cream-catalog.yaml LICENSE NOTICE "${roots[@]}" \
        ':(exclude,glob)extensions/*/*/tests/**' \
    | docker run --rm -i --network none -u "$(id -u):$(id -g)" \
        -e SOURCE_DATE_EPOCH="$epoch" \
        -v "$deb:/cream.deb:ro" -v "$OUT:/out" -v "$core_dir:/core:ro" \
        "$IMAGE" sh -c "$inner" sh "$asset" ${pairs[@]+"${pairs[@]}"}

(cd "$OUT" && sha256sum -- "$asset" > SHA256SUMS)
cat "$OUT/SHA256SUMS"
echo "записано: $OUT/$asset, $OUT/SHA256SUMS"
