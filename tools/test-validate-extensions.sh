#!/usr/bin/env bash
# Tests of tools/validate-extensions.py on a mixed catalog (layout 2 and
# cream/v1 side by side, the pilot branch state). The validator is copied
# into a temporary repository together with lib/ (it finds the repository by
# its own path), so the real extensions/ is not touched.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
fails=0; total=0
ok()  { total=$((total+1)); echo "  ok   $1"; }
bad() { total=$((total+1)); fails=$((fails+1)); echo "  FAIL $1"; }
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT

# repo DIR: a fresh repository with the layout 2 fixture btop (tools/testdata/layout2-min) and the cream/v1 fixture
# `ok`; btop requires the capability that only `ok` provides.
repo() {
    local d="$1"
    mkdir -p "$d/tools" "$d/extensions/debian"
    cp "$HERE/validate-extensions.py" "$d/tools/"
    cp -a "$REPO/lib" "$d/lib"
    cp -a "$HERE/testdata/layout2-min/btop" "$d/extensions/debian/btop"
    cp -a "$HERE/testdata/cream-v1-min/ok" "$d/extensions/debian/ok"
    sed -i 's/^requires: \[\]$/requires: [cream-v1-min]/' "$d/extensions/debian/btop/extension.yaml"
}
run() { python3 "$1/tools/validate-extensions.py" 2>&1; }

# 1. Mixed catalog passes; cream/v1 is listed as left to cream validate.
repo "$T/a"
out="$(run "$T/a")"; rc=$?
if (( rc == 0 )); then ok "смешанный каталог: код 0"; else bad "смешанный каталог: код $rc: $out"; fi
if grep -Eq '^  extensions/debian/ok$' <<<"$out" && grep -qF "cream/v1" <<<"$out"; then
    ok "cream/v1 перечислен отдельно"
else
    bad "cream/v1 не перечислен: $out"
fi
if grep -qF "расширений с манифестом: 1" <<<"$out"; then
    ok "layout 2 по-прежнему проверяется (1 манифест)"
else
    bad "счёт layout 2: $out"
fi

# 2. Layout 2 is still checked as before: an unknown field fails.
repo "$T/b"
echo "bogus: 1" >> "$T/b/extensions/debian/btop/extension.yaml"
out="$(run "$T/b")"; rc=$?
if (( rc == 1 )) && grep -qF "bogus" <<<"$out"; then
    ok "layout 2: лишнее поле — ошибка"
else
    bad "layout 2: лишнее поле, код $rc: $out"
fi

# 3. A requirement nobody provides still fails (cream/v1 provides do count,
#    but only what they actually declare).
repo "$T/c"
sed -i 's/^requires: \[cream-v1-min\]$/requires: [nobody-has-it]/' "$T/c/extensions/debian/btop/extension.yaml"
out="$(run "$T/c")"; rc=$?
if (( rc == 1 )) && grep -qF "nobody-has-it" <<<"$out"; then
    ok "requires без поставщика — ошибка"
else
    bad "requires без поставщика, код $rc: $out"
fi

# 4. An unknown schema is an error, not a silent skip.
repo "$T/d"
sed -i 's|^schema: cream/v1$|schema: cream/v2|' "$T/d/extensions/debian/ok/extension.yaml"
out="$(run "$T/d")"; rc=$?
if (( rc == 1 )) && grep -qF "cream/v2" <<<"$out"; then
    ok "неизвестная схема — ошибка"
else
    bad "неизвестная схема, код $rc: $out"
fi

# 5. A cream/v1 directory named differently from its manifest is an error
#    here too: the layout 2 neighbours resolve capabilities by it.
repo "$T/e"
mv "$T/e/extensions/debian/ok" "$T/e/extensions/debian/other"
out="$(run "$T/e")"; rc=$?
if (( rc == 1 )); then ok "cream/v1: имя каталога ≠ name — ошибка"; else bad "имя каталога, код $rc: $out"; fi

echo "test-validate-extensions: $((total-fails))/$total"
(( fails == 0 ))
