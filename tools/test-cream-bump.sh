#!/usr/bin/env bash
# Тесты tools/cream-bump.sh: пин исполнителя cream (tools/cream-pin.env —
# версия и суммы cream_<v>_amd64.deb и _arm64.deb) по SHA256SUMS выпуска.
# Скрипт и пин копируются в подменённое дерево — рабочее дерево репозитория
# не трогается. Сеть, gh и root не нужны.
#
#   tools/test-cream-bump.sh        код 0 — все проверки прошли

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"

TMP="$(mktemp -d)"
trap 'rm -r -f -- "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&2; }
check(){ local what="$1"; shift; if "$@"; then ok; else bad "$what"; fi; }
eq(){ local what="$1" want="$2" got="$3"; if [[ "$want" == "$got" ]]; then ok; else bad "$what: ждали [$want], получили [$got]"; fi; }

A64="$(printf 'a%.0s' {1..64})"
B64="$(printf 'b%.0s' {1..64})"
C64="$(printf 'c%.0s' {1..64})"

# Подменённое дерево: скрипт и копия пина с версией $1 и суммами $2/$3.
new_tree(){
    T="$(mktemp -d "$TMP/tree.XXXXXX")"
    mkdir -p "$T/tools"
    cp "$REPO/tools/cream-bump.sh" "$T/tools/"
    PIN="$T/tools/cream-pin.env"
    sed -E \
        -e "s/^CREAM_VERSION=.*/CREAM_VERSION=$1/" \
        -e "s/^CREAM_SHA256=.*/CREAM_SHA256=$2/" \
        -e "s/^CREAM_SHA256_ARM64=.*/CREAM_SHA256_ARM64=$3/" \
        "$REPO/tools/cream-pin.env" > "$PIN"
    cp "$PIN" "$T/pin.before"
}
sums(){ local f="$1"; shift; printf '%s\n' "$@" > "$f"; }
run(){ OUT="$("$T/tools/cream-bump.sh" "$@" 2>"$T/err")"; RC=$?; ERR="$(cat "$T/err")"; }
pin(){ sed -n "s/^$1=//p" "$PIN"; }
untouched(){ cmp -s "$PIN" "$T/pin.before"; }

echo "== 1.1.3 → 1.2.0: версия и обе суммы =="
new_tree 1.1.3 "$C64" "$C64"
sums "$TMP/S" "$A64  cream_1.2.0_amd64.deb" "$B64 *cream_1.2.0_arm64.deb" "$C64  cream_1.2.0_linux_amd64.tar.gz"
run v1.2.0 "$TMP/S"
eq "код" 0 "$RC"
eq "версия" 1.2.0 "$(pin CREAM_VERSION)"
eq "amd64" "$A64" "$(pin CREAM_SHA256)"
eq "arm64" "$B64" "$(pin CREAM_SHA256_ARM64)"
eq "CREAM_URL цел" "" "$(pin CREAM_URL)"
check "changed=true" grep -qx changed=true <<<"$OUT"
check "version=" grep -qx version=1.2.0 <<<"$OUT"
eq "диф — три строки" 3 "$(diff "$T/pin.before" "$PIN" | grep -c '^>')"

echo "== повтор на той же версии — changed=false, файл цел =="
new_tree 1.2.0 "$A64" "$B64"
run v1.2.0 "$TMP/S"
eq "код" 0 "$RC"
check "changed=false" grep -qx changed=false <<<"$OUT"
check "не тронут" untouched

echo "== та же версия, другая сумма — отказ =="
new_tree 1.2.0 "$C64" "$B64"
run v1.2.0 "$TMP/S"
eq "код" 1 "$RC"
check "сообщение про сумму" grep -q 'sha256' <<<"$ERR"
check "не тронут" untouched

echo "== выпуск старее пина — changed=false =="
new_tree 1.10.0 "$C64" "$C64"
run v1.2.0 "$TMP/S"
eq "код" 0 "$RC"
check "changed=false" grep -qx changed=false <<<"$OUT"
check "не тронут" untouched

echo "== в SHA256SUMS нет arm64 — отказ =="
new_tree 1.1.3 "$C64" "$C64"
sums "$TMP/S2" "$A64  cream_1.2.0_amd64.deb"
run v1.2.0 "$TMP/S2"
eq "код" 1 "$RC"
check "не тронут" untouched

echo "== неверный тег и нет файла сумм — код 2 =="
new_tree 1.1.3 "$C64" "$C64"
run 1.2.0 "$TMP/S"
eq "тег без v" 2 "$RC"
run v1.2.0 "$T/nope"
eq "нет SHA256SUMS" 2 "$RC"
check "не тронут" untouched

echo "test-cream-bump: прошло $pass, упало $fail"
(( fail == 0 ))
