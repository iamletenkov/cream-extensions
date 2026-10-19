#!/usr/bin/env bash
# `cream validate` over the cream/v1 extensions of this catalog.
#
#   tools/cream-validate.sh            every extensions/<family>/<name>/ whose
#                                      extension.yaml says `schema: cream/v1`
#   tools/cream-validate.sh DIR...     the given extension directories
#
# The catalog is transitional (cream spec §16 step 2): layout 2 and cream/v1
# live side by side, and `cream validate --catalog .` would reject the layout 2
# manifests. So the cream/v1 extensions are copied into a temporary catalog
# (its own cream-catalog.yaml, roots: [extensions]) and validated as a catalog:
# duplicate names and cross-extension unit/action checks work as on the real one.
#
# cream comes from the pin tools/cream-pin.env (version + sha256 of
# cream_<v>_amd64.deb), checked before use; it runs inside debian:12 with no
# network. CREAM_DEB=<local .deb> overrides the pin for local runs (the pin is
# NOT checked then — a warning says so). Empty pin and no CREAM_DEB: the check
# is skipped with a fixed line and exit 0 (no cream release pinned).
#
# Exit: 0 — valid or skipped; cream's code when invalid (65 — bad manifest,
# see cream docs/cli.md); 2 — setup failure (pin, download, docker).
#
# Test overrides: CREAM_PIN_FILE, CREAM_CACHE_DIR.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
PIN_FILE="${CREAM_PIN_FILE:-$HERE/cream-pin.env}"
CACHE_DIR="${CREAM_CACHE_DIR:-$REPO/.cache/cream}"
IMAGE="debian:12"

die() { echo "cream-validate: $*" >&2; exit 2; }

# pin KEY: value of KEY= from the pin file (no sourcing: it is data).
pin() {
    local line
    line="$(grep -E "^$1=" "$PIN_FILE" | tail -n1)" || true
    printf '%s' "${line#*=}"
}

# cream/v1 directories: arguments or discovery under extensions/.
dirs=()
if (( $# )); then
    for d in "$@"; do
        [[ -f "$d/extension.yaml" ]] || die "$d: нет extension.yaml"
        dirs+=("$(cd "$d" && pwd)")
    done
else
    while IFS= read -r m; do
        if grep -Eq "^schema:[[:space:]]*[\"']?cream/v1[\"']?[[:space:]]*(#.*)?$" "$m"; then
            dirs+=("$(dirname "$m")")
        fi
    done < <(find "$REPO/extensions" -mindepth 3 -maxdepth 3 -name extension.yaml | sort)
fi
if (( ${#dirs[@]} == 0 )); then
    echo "cream/v1: расширений нет, проверять нечего"
    exit 0
fi

# The .deb: CREAM_DEB or the pin.
if [[ -n "${CREAM_DEB:-}" ]]; then
    [[ -f "$CREAM_DEB" ]] || die "CREAM_DEB=$CREAM_DEB: файла нет"
    deb="$(cd "$(dirname "$CREAM_DEB")" && pwd)/$(basename "$CREAM_DEB")"
    echo "ВНИМАНИЕ: cream из CREAM_DEB=$deb — пин tools/cream-pin.env не проверяется" >&2
else
    [[ -f "$PIN_FILE" ]] || die "$PIN_FILE: файла пина нет"
    version="$(pin CREAM_VERSION)"
    sha="$(pin CREAM_SHA256)"
    url="$(pin CREAM_URL)"
    if [[ -z "$version" && -z "$sha" ]]; then
        echo "cream/v1 пропущен: пин cream не задан (tools/cream-pin.env; локально — CREAM_DEB=<.deb>)"
        exit 0
    fi
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] \
        || die "пин: CREAM_VERSION=\"$version\" — не semver"
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "пин: CREAM_SHA256 — не 64 hex-знака"
    url="${url:-https://github.com/iamletenkov/cream/releases/download/v$version/cream_${version}_amd64.deb}"
    deb="$CACHE_DIR/cream_${version}_amd64.deb"
    if [[ ! -f "$deb" ]] || ! echo "$sha  $deb" | sha256sum -c --status -; then
        mkdir -p "$CACHE_DIR"
        tmp="$(mktemp "$CACHE_DIR/.download.XXXXXX")"
        trap 'rm -f -- "$tmp"' EXIT
        curl -fsSL --retry 3 -o "$tmp" "$url" || die "не скачался $url"
        if ! echo "$sha  $tmp" | sha256sum -c --status -; then
            die "sha256 скачанного $url не совпал с пином CREAM_SHA256"
        fi
        mv -f -- "$tmp" "$deb"
    fi
fi

command -v docker >/dev/null 2>&1 || die "нужен docker"

# Mount every extension read-only under /src/<i>; the container copies them
# into /cat/extensions/<basename> (cp -a keeps the executable bits) and runs
# `cream validate --catalog /cat`.
mounts=(-v "$deb:/cream.deb:ro")
names=()
for i in "${!dirs[@]}"; do
    mounts+=(-v "${dirs[$i]}:/src/$i:ro")
    names+=("$(basename "${dirs[$i]}")")
done
echo "cream validate: ${names[*]}"

# shellcheck disable=SC2016  # expanded inside the container
inner='set -eu
dpkg-deb -x /cream.deb /tmp/cream
mkdir -p /tmp/cat/extensions
printf "schema: cream/v1\nname: cream-extensions-check\nversion: 0.0.0\nroots: [extensions]\n" \
    > /tmp/cat/cream-catalog.yaml
i=0
for name in "$@"; do
    if [ -e "/tmp/cat/extensions/$name" ]; then
        echo "cream-validate: имя каталога $name встречается дважды" >&2
        exit 65
    fi
    cp -a "/src/$i" "/tmp/cat/extensions/$name"
    i=$((i + 1))
done
/tmp/cream/usr/bin/cream --version
exec /tmp/cream/usr/bin/cream validate --catalog /tmp/cat'

rc=0
docker run --rm --network none -u "$(id -u):$(id -g)" "${mounts[@]}" \
    "$IMAGE" sh -c "$inner" sh "${names[@]}" || rc=$?
if (( rc == 0 )); then
    echo "cream validate: ок"
else
    echo "cream validate: не прошла (код $rc)" >&2
fi
exit "$rc"
