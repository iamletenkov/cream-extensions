#!/usr/bin/env bash
# Tests of tools/cream-check.sh (`cream check` over the catalog).
#
# Without cream: an empty pin skips the check with a fixed line and exit 0.
# With cream (CREAM_DEB=<local .deb> or a filled tools/cream-pin.env), on
# throw-away catalogs: a capability in requires is closed by its provider —
# green; a missing depends — red with cream's answer; a capability nobody
# provides — red from the matrix; platform.os narrows the OS matrix; a
# `cream:` range above the pinned cream — red. Without cream that half is
# skipped with a line, not silently.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/cream-check.sh"
fails=0; total=0
ok()  { total=$((total+1)); echo "  ok   $1"; }
bad() { total=$((total+1)); fails=$((fails+1)); echo "  FAIL $1"; }
has() { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1: нет «$2» в выводе:"; sed 's/^/      /' <<<"$3"; fi; }
code() { if [[ "$2" == "$3" ]]; then ok "$1: код $3"; else bad "$1: код $3, ждали $2"; fi; }
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT

# catalog DIR: an empty catalog with roots: [extensions].
catalog() {
    mkdir -p "$1/extensions"
    printf 'schema: cream/v1\nname: test-check\nversion: 0.0.0\nroots: [extensions]\n' > "$1/cream-catalog.yaml"
}
# ext DIR NAME EXTRA-YAML: a minimal extension with an install hook.
ext() {
    local d="$1/extensions/$2"
    mkdir -p "$d/hooks"
    printf '#!/bin/sh\nexit 0\n' > "$d/hooks/install"; chmod +x "$d/hooks/install"
    {
        printf 'schema: cream/v1\nname: %s\nversion: 1.0.0\nsummary: фикстура cream-check\n' "$2"
        printf 'cream: ">=1.0.0"\n'
        printf '%s\n' "$3"
        printf 'hooks:\n  install: {}\n'
    } > "$d/extension.yaml"
}
PLAT='platform: {family: deb, arch: [amd64, arm64], os: [{id: debian}, {id: ubuntu}]}'

# 1. Empty pin, no CREAM_DEB: skip line, exit 0.
printf 'CREAM_VERSION=\nCREAM_SHA256=\n' > "$T/pin-empty.env"
catalog "$T/skip"; ext "$T/skip" a "$PLAT"
out="$(env -u CREAM_DEB CREAM_PIN_FILE="$T/pin-empty.env" "$SCRIPT" "$T/skip" 2>&1)"; rc=$?
code "пустой пин" 0 "$rc"
has "пустой пин: строка пропуска" "cream check пропущен: пин cream не задан" "$out"

have_cream=0
if [[ -n "${CREAM_DEB:-}" ]] || grep -Eq '^CREAM_SHA256=[0-9a-f]{64}$' "$HERE/cream-pin.env" 2>/dev/null; then
    have_cream=1
fi
if (( have_cream )); then
    # 2. requires closed by a provider; 4 OS of the matrix x 2 extensions.
    catalog "$T/ok"
    ext "$T/ok" app "$PLAT
requires: [cap-x]"
    ext "$T/ok" prov "$PLAT
provides: [cap-x]"
    out="$("$SCRIPT" "$T/ok" 2>&1)"; rc=$?
    code "requires закрыт поставщиком" 0 "$rc"
    has "все случаи матрицы" "случаев 8, не прошло 0" "$out"

    # 2b. requires of a depends: its provider comes first too.
    catalog "$T/deprq"
    ext "$T/deprq" app "$PLAT
depends:
  - {name: base, version: \">=1.0.0\"}"
    ext "$T/deprq" base "$PLAT
requires: [cap-x]"
    ext "$T/deprq" prov "$PLAT
provides: [cap-x]"
    out="$("$SCRIPT" "$T/deprq" 2>&1)"; rc=$?
    code "requires зависимости закрыт поставщиком" 0 "$rc"

    # 3. Missing depends: cream answers deps.missing.
    catalog "$T/dep"
    ext "$T/dep" app "$PLAT
depends:
  - {name: nope, version: \">=1.0.0\"}"
    out="$("$SCRIPT" "$T/dep" 2>&1)"; rc=$?
    code "нет зависимости" 1 "$rc"
    has "нет зависимости: случай назван" "FAIL app debian:12 amd64" "$out"
    has "нет зависимости: ответ cream" "deps.missing" "$out"

    # 4. A capability nobody provides: the matrix itself says so.
    catalog "$T/cap"
    ext "$T/cap" app "$PLAT
requires: [cap-none]"
    out="$("$SCRIPT" "$T/cap" 2>&1)"; rc=$?
    code "способность без поставщика" 1 "$rc"
    has "способность без поставщика: названа" "способность cap-none" "$out"

    # 5. A provider for another OS does not count; platform.os narrows the matrix.
    catalog "$T/os"
    ext "$T/os" app 'platform: {family: deb, arch: [amd64], os: [{id: ubuntu, version: ">=24.04"}]}
requires: [cap-x]'
    ext "$T/os" prov 'platform: {family: deb, arch: [amd64], os: [{id: debian}]}
provides: [cap-x]'
    out="$("$SCRIPT" "$T/os" 2>&1)"; rc=$?
    code "поставщик другой ОС" 1 "$rc"
    has "поставщик другой ОС: случай ubuntu:24.04" "FAIL app ubuntu:24.04 amd64" "$out"
    has "поставщик только для debian — свои случаи" "случаев 2," "$out"

    # 6. `cream:` above the pinned cream.
    catalog "$T/cream"
    ext "$T/cream" app "$PLAT"
    sed -i 's/^cream: .*/cream: ">=99.0.0"/' "$T/cream/extensions/app/extension.yaml"
    out="$("$SCRIPT" "$T/cream" 2>&1)"; rc=$?
    code "cream: выше пина" 1 "$rc"
    has "cream: выше пина — случай назван" "FAIL app" "$out"
else
    echo "  --   cream не задан (пин пуст, нет CREAM_DEB): проверки с cream пропущены"
fi

echo "проверок: $total, не прошло: $fails"
(( fails == 0 ))
