#!/usr/bin/env bash
# Tests of tools/catalog-snapshot.sh (`make snapshot-check`).
#
# Reproducibility: two builds of one commit into different directories (the
# second under another umask) give the same SHA256SUMS. Contents: only
# cream-catalog.yaml, LICENSE, NOTICE and the cream/v1 extensions, without
# tests/. The catalog version equals the release-please version. Acceptance by
# the same cream (pin tools/cream-pin.env), as Stvor and bisquite consume it:
# `cream source add --archive file://… --sha256 … --sync`, `cream validate` of
# the synced cache, `cream resolve` (phase build) of teleport and of
# stvor-agent with its dependency; a wrong sha256 is refused. Without a cream
# pin and CREAM_DEB the test is skipped with a line, not silently.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
SCRIPT="$HERE/catalog-snapshot.sh"
fails=0; total=0
ok()  { total=$((total+1)); echo "  ok   $1"; }
bad() { total=$((total+1)); fails=$((fails+1)); echo "  FAIL $1"; }
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT

deb="$("$HERE/cream-deb.sh" 2>"$T/deb.err")"; rc=$?
if (( rc == 3 )); then
    echo "  skip снимок каталога: нет CREAM_DEB и пин cream не задан"
    exit 0
elif (( rc != 0 )); then
    cat "$T/deb.err" >&2
    echo "test-snapshot: cream не получен (код $rc)" >&2
    exit 1
fi

# 0. Catalog version = release-please version.
cat_ver="$(sed -nE 's/^version:[[:space:]]*([0-9.]+).*/\1/p' "$REPO/cream-catalog.yaml")"
rp_ver="$(sed -nE 's/^[[:space:]]*"\."[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
    "$REPO/.github/release_please/.release-please-manifest.json")"
if [[ -n "$cat_ver" && "$cat_ver" == "$rp_ver" ]]; then
    ok "версия каталога $cat_ver = версии release-please"
else
    bad "версия каталога '$cat_ver' ≠ release-please '$rp_ver'"
fi
# The version inside the snapshot is the committed one.
version="$(git -C "$REPO" show HEAD:cream-catalog.yaml | sed -nE 's/^version:[[:space:]]*([0-9.]+).*/\1/p')"
asset="cream-extensions-$version.tar.gz"

# 1. Two builds, same bytes.
if "$SCRIPT" "$T/a" >"$T/a.log" 2>&1; then ok "сборка 1"; else bad "сборка 1: $(tail -n5 "$T/a.log")"; fi
if (umask 077 && "$SCRIPT" "$T/b") >"$T/b.log" 2>&1; then ok "сборка 2 (umask 077)"; else bad "сборка 2: $(tail -n5 "$T/b.log")"; fi
if [[ -s "$T/a/SHA256SUMS" ]] && cmp -s "$T/a/SHA256SUMS" "$T/b/SHA256SUMS"; then
    ok "воспроизводимость: $(cut -d' ' -f1 "$T/a/SHA256SUMS")"
else
    bad "воспроизводимость: $(cat "$T/a/SHA256SUMS" "$T/b/SHA256SUMS" 2>&1 | tr '\n' ' ')"
fi
if (cd "$T/a" && sha256sum -c --status SHA256SUMS); then
    ok "SHA256SUMS сходится с $asset"
else
    bad "SHA256SUMS не сходится с $T/a/$asset"
fi
sha="$(cut -d' ' -f1 "$T/a/SHA256SUMS" 2>/dev/null)"

# 2. Contents: no layout 2 extension, no tests/.
listing="$(tar -tzf "$T/a/$asset" 2>/dev/null)"
for want in cream-catalog.yaml LICENSE NOTICE extensions/debian/teleport/extension.yaml \
            extensions/debian/stvor-agent/extension.yaml; do
    if grep -qxF "$want" <<<"$listing"; then ok "в снимке $want"; else bad "в снимке нет $want"; fi
done
if grep -q '^extensions/debian/btop/' <<<"$listing"; then
    bad "в снимке расширение layout 2 (btop)"
else
    ok "расширений layout 2 в снимке нет"
fi
if grep -q '/tests/' <<<"$listing"; then bad "в снимке есть tests/"; else ok "tests/ в снимок не попадают"; fi

# 3. Acceptance by cream, as the consumers do it.
# shellcheck disable=SC2016  # expanded inside the container
inner='set -u
dpkg-deb -x /cream.deb /tmp/c
C="/tmp/c/usr/bin/cream -root /tmp/r"
rc=0
$C -root /tmp/bad source add cream-extensions --archive "file:///snap/$1" \
    --sha256 0000000000000000000000000000000000000000000000000000000000000000 --sync \
    >/dev/null 2>&1 && { echo "FAIL чужой sha256 принят"; rc=1; } || echo "ok чужой sha256: отказ"
$C source add cream-extensions --archive "file:///snap/$1" --sha256 "$2" --sync || { echo "FAIL source add"; exit 1; }
echo "ok source add --archive --sync"
/tmp/c/usr/bin/cream validate --catalog /tmp/r/var/cache/cream/sources/cream-extensions \
    && echo "ok cream validate" || { echo "FAIL cream validate"; rc=1; }
B="--phase build --family deb --target-arch amd64 --host-arch amd64"
$C resolve $B teleport && echo "ok resolve teleport" || { echo "FAIL resolve teleport"; rc=1; }
$C resolve $B teleport stvor-agent && echo "ok resolve stvor-agent" || { echo "FAIL resolve stvor-agent"; rc=1; }
exit $rc'
if [[ -n "$sha" ]]; then
    out="$(docker run --rm --network none -u "$(id -u):$(id -g)" \
        -v "$deb:/cream.deb:ro" -v "$T/a:/snap:ro" debian:12 \
        sh -c "$inner" sh "$asset" "$sha" 2>&1)"; rc=$?
    while IFS= read -r line; do
        case "$line" in
            "ok "*) ok "cream: ${line#ok }" ;;
            "FAIL "*) bad "cream: ${line#FAIL }" ;;
        esac
    done <<<"$out"
    if (( rc != 0 )); then bad "приёмка cream: код $rc"; echo "$out" | tail -n 15; fi
else
    bad "приёмка cream: снимка нет"
fi

echo "test-snapshot: $((total-fails))/$total"
(( fails == 0 ))
