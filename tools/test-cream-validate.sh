#!/usr/bin/env bash
# Tests of tools/cream-validate.sh.
#
# Without cream: an empty pin skips the check with a fixed line and exit 0;
# a pin whose sha256 does not match the downloaded .deb is a failure (the
# download goes through file:// — no network). With cream (CREAM_DEB=<local
# .deb> or a filled tools/cream-pin.env): the minimal valid fixture passes,
# the deliberately invalid one fails; without arguments the script runs
# `cream validate --catalog` over the repository root (a copy of it in a fake
# repository): a valid catalog passes, a manifest without `schema: cream/v1`
# fails it — there is no filtering. Without cream that half is skipped with a
# line, not silently.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/cream-validate.sh"
FIX="$HERE/testdata/cream-v1-min"
fails=0; total=0
ok()  { total=$((total+1)); echo "  ok   $1"; }
bad() { total=$((total+1)); fails=$((fails+1)); echo "  FAIL $1"; }
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT

# 1. Empty pin, no CREAM_DEB: skip line, exit 0.
printf 'CREAM_VERSION=\nCREAM_SHA256=\n' > "$T/pin-empty.env"
out="$(env -u CREAM_DEB CREAM_PIN_FILE="$T/pin-empty.env" "$SCRIPT" "$FIX/ok" 2>&1)"; rc=$?
if (( rc == 0 )); then ok "пустой пин: код 0"; else bad "пустой пин: код $rc"; fi
if grep -qF "cream/v1 пропущен: пин cream не задан" <<<"$out"; then
    ok "пустой пин: строка пропуска"
else
    bad "пустой пин: нет строки пропуска: $out"
fi

# 2. Pin with a wrong sha256: refused before any use of the file.
printf 'not a deb\n' > "$T/fake.deb"
cat > "$T/pin-wrong.env" <<EOF
CREAM_VERSION=9.9.9
CREAM_SHA256=$(printf '0%.0s' {1..64})
CREAM_URL=file://$T/fake.deb
EOF
out="$(env -u CREAM_DEB CREAM_PIN_FILE="$T/pin-wrong.env" CREAM_CACHE_DIR="$T/cache" \
    "$SCRIPT" "$FIX/ok" 2>&1)"; rc=$?
if (( rc != 0 )); then ok "чужой sha256: отказ"; else bad "чужой sha256: код 0"; fi
if grep -qF "sha256" <<<"$out"; then ok "чужой sha256: причина названа"; else bad "чужой sha256: $out"; fi
if [[ ! -e "$T/cache/cream_9.9.9_amd64.deb" ]]; then
    ok "чужой sha256: файл не остаётся в кеше"
else
    bad "чужой sha256: файл остался в кеше"
fi

# 3. Malformed pin: version without sha256 is an error, not a skip.
printf 'CREAM_VERSION=1.0.0\nCREAM_SHA256=\n' > "$T/pin-half.env"
out="$(env -u CREAM_DEB CREAM_PIN_FILE="$T/pin-half.env" "$SCRIPT" "$FIX/ok" 2>&1)"; rc=$?
if (( rc != 0 )); then ok "пин без sha256: отказ"; else bad "пин без sha256: код 0 ($out)"; fi

# 4. Real cream: valid fixture passes, invalid one fails.
have_cream=0
if [[ -n "${CREAM_DEB:-}" ]]; then
    have_cream=1
elif grep -Eq '^CREAM_SHA256=[0-9a-f]{64}$' "$HERE/cream-pin.env" 2>/dev/null; then
    have_cream=1
fi
if (( have_cream )); then
    out="$("$SCRIPT" "$FIX/ok" 2>&1)"; rc=$?
    if (( rc == 0 )); then ok "cream validate: ok зелёный"; else bad "cream validate: ok код $rc: $out"; fi
    out="$("$SCRIPT" "$FIX/bad" 2>&1)"; rc=$?
    if (( rc == 65 )); then
        ok "cream validate: bad красный (65)"
    else
        bad "cream validate: bad код $rc (ждали 65): $out"
    fi
    out="$("$SCRIPT" "$FIX/ok" "$FIX/bad" 2>&1)"; rc=$?
    if (( rc != 0 )); then ok "cream validate: ok+bad красный"; else bad "cream validate: ok+bad код 0"; fi

    # No arguments: the catalog is the repository root, as it is.
    R="$T/repo"
    mkdir -p "$R/tools" "$R/extensions/debian"
    cp "$SCRIPT" "$HERE/cream-pin.env" "$HERE/stage-catalog.sh" "$R/tools/"
    printf 'schema: cream/v1\nname: cream-extensions\nversion: 0.0.0\nroots: [extensions/debian]\n' \
        > "$R/cream-catalog.yaml"
    cp -a "$FIX/ok" "$R/extensions/debian/ok"
    out="$(CREAM_CACHE_DIR="$HERE/../.cache/cream" "$R/tools/cream-validate.sh" 2>&1)"; rc=$?
    if (( rc == 0 )); then ok "по корню: каталог зелёный"; else bad "по корню: код $rc: $out"; fi
    if grep -qF -- "--catalog ." <<<"$out"; then ok "по корню: --catalog ."; else bad "по корню: не --catalog .: $out"; fi
    mkdir -p "$R/extensions/debian/old"
    printf 'name: old\nversion: 1.0.0\n' > "$R/extensions/debian/old/extension.yaml"
    out="$(CREAM_CACHE_DIR="$HERE/../.cache/cream" "$R/tools/cream-validate.sh" 2>&1)"; rc=$?
    if (( rc == 65 )); then
        ok "по корню: манифест без schema — красный (65)"
    else
        bad "по корню: манифест без schema — код $rc (ждали 65): $out"
    fi
else
    echo "  skip cream validate на фикстурах: нет CREAM_DEB и пин cream не задан"
fi

echo "test-cream-validate: $((total-fails))/$total"
(( fails == 0 ))
