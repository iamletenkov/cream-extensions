#!/usr/bin/env bash
# Path of the verified cream .deb by the pin tools/cream-pin.env (stdout, one line).
#
# CREAM_DEB=<local .deb> overrides the pin (the pin is NOT checked then — a
# warning on stderr says so). Otherwise the .deb is taken from the cache
# (.cache/cream/cream_<v>_amd64.deb) when its sha256 matches the pin, or
# downloaded (CREAM_URL or the GitHub release asset) and checked before it
# lands in the cache.
#
# Exit: 0 — path printed; 3 — the pin is empty (no cream release pinned);
# 2 — setup failure (malformed pin, download, sha256 mismatch).
#
# Used by tools/catalog-snapshot.sh and tools/test-snapshot.sh.
# Test overrides: CREAM_PIN_FILE, CREAM_CACHE_DIR.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
PIN_FILE="${CREAM_PIN_FILE:-$HERE/cream-pin.env}"
CACHE_DIR="${CREAM_CACHE_DIR:-$REPO/.cache/cream}"

die() { echo "cream-deb: $*" >&2; exit 2; }

# pin KEY: value of KEY= from the pin file (no sourcing: it is data).
pin() {
    local line
    line="$(grep -E "^$1=" "$PIN_FILE" | tail -n1)" || true
    printf '%s' "${line#*=}"
}

if [[ -n "${CREAM_DEB:-}" ]]; then
    [[ -f "$CREAM_DEB" ]] || die "CREAM_DEB=$CREAM_DEB: файла нет"
    echo "ВНИМАНИЕ: cream из CREAM_DEB=$CREAM_DEB — пин tools/cream-pin.env не проверяется" >&2
    printf '%s/%s\n' "$(cd "$(dirname "$CREAM_DEB")" && pwd)" "$(basename "$CREAM_DEB")"
    exit 0
fi

[[ -f "$PIN_FILE" ]] || die "$PIN_FILE: файла пина нет"
version="$(pin CREAM_VERSION)"
sha="$(pin CREAM_SHA256)"
url="$(pin CREAM_URL)"
if [[ -z "$version" && -z "$sha" ]]; then
    echo "cream-deb: пин cream не задан (tools/cream-pin.env; локально — CREAM_DEB=<.deb>)" >&2
    exit 3
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
printf '%s\n' "$deb"
