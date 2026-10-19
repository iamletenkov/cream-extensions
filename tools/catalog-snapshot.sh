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
# from the snapshot silently — that is an error here.
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

if [[ "$REF" == "HEAD" ]] && [[ -n "$(git -C "$REPO" status --porcelain -- cream-catalog.yaml LICENSE NOTICE "${roots[@]}")" ]]; then
    echo "ВНИМАНИЕ: в рабочем дереве есть незакоммиченные правки — снимок берётся из коммита ${commit:0:12}" >&2
fi

deb="$("$HERE/cream-deb.sh")" || { rc=$?; (( rc == 3 )) && die "без пина cream снимок не собрать"; exit 2; }
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
/tmp/cream/usr/bin/cream --version
/tmp/cream/usr/bin/cream catalog pack /tmp/cat --out "/out/$1"'

git -C "$REPO" archive --format=tar "$commit" -- cream-catalog.yaml LICENSE NOTICE "${roots[@]}" \
        ':(exclude,glob)extensions/*/*/tests/**' \
    | docker run --rm -i --network none -u "$(id -u):$(id -g)" \
        -e SOURCE_DATE_EPOCH="$epoch" \
        -v "$deb:/cream.deb:ro" -v "$OUT:/out" \
        "$IMAGE" sh -c "$inner" sh "$asset"

(cd "$OUT" && sha256sum -- "$asset" > SHA256SUMS)
cat "$OUT/SHA256SUMS"
echo "записано: $OUT/$asset, $OUT/SHA256SUMS"
