#!/usr/bin/env bash
# Тесты tools/agent-bump.sh: пин пакета stvor-agent в обёртке stvor-agent
# (files/pin.env) и patch-подъём версии расширения по SHA256SUMS релиза.
# Скрипт и обёртка копируются в подменённое дерево — рабочее дерево
# репозитория не трогается. Сеть, gh и root не нужны.
#
#   tools/test-agent-bump.sh        код 0 — все проверки прошли

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"

TMP="$(mktemp -d)"
trap 'rm -r -f -- "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&2; }
check(){ local what="$1"; shift; if "$@"; then ok; else bad "$what"; fi; }
check_not(){ local what="$1"; shift; if "$@"; then bad "$what"; else ok; fi; }
eq(){ local what="$1" want="$2" got="$3"; if [[ "$want" == "$got" ]]; then ok; else bad "$what: ждали [$want], получили [$got]"; fi; }

A64="$(printf 'a%.0s' {1..64})"
B64="$(printf 'b%.0s' {1..64})"
C64="$(printf 'c%.0s' {1..64})"
D64="$(printf 'd%.0s' {1..64})"
ZERO="$(printf '0%.0s' {1..64})"

# A scratch tree: tools/agent-bump.sh and a copy of the wrapper; the pin is
# replaced by the one a scenario needs (version, amd64 sum, arm64 sum).
new_tree(){
    T="$(mktemp -d "$TMP/tree.XXXXXX")"
    mkdir -p "$T/tools" "$T/extensions/debian"
    cp "$REPO/tools/agent-bump.sh" "$T/tools/"
    cp -a "$REPO/extensions/debian/stvor-agent" "$T/extensions/debian/"
    PIN="$T/extensions/debian/stvor-agent/files/pin.env"
    MANIFEST="$T/extensions/debian/stvor-agent/extension.yaml"
    if (( $# )); then
        sed -i -E \
            -e "s/^STVOR_AGENT_PIN_VERSION=.*/STVOR_AGENT_PIN_VERSION=$1/" \
            -e "s/^STVOR_AGENT_PIN_SHA256_AMD64=.*/STVOR_AGENT_PIN_SHA256_AMD64=$2/" \
            -e "s/^STVOR_AGENT_PIN_SHA256_ARM64=.*/STVOR_AGENT_PIN_SHA256_ARM64=$3/" \
            -e '/^# FICTITIOUS TEST PIN/,/^# release puts/d' \
            "$PIN"
    fi
    # FICT=1 — пин в виде до первого релиза (фикстура: нули и пометка
    # FICTITIOUS); настоящий пин каталога после релиза 4.0.0 уже не фиктивный.
    if [[ "${FICT:-0}" == 1 ]]; then
        cp "$REPO/tools/testdata/agent-bump/pin.fictitious.env" "$PIN"
    fi
    sed -i -E "s/^version: .*/version: ${EXT_VERSION:-4.0.0}/" "$MANIFEST"
    cp "$PIN" "$T/pin.before"
    cp "$MANIFEST" "$T/manifest.before"
}
# sums <file> <line>... — a SHA256SUMS file.
sums(){ local f="$1"; shift; printf '%s\n' "$@" > "$f"; }
run(){ OUT="$("$T/tools/agent-bump.sh" "$@" 2>"$T/err")"; RC=$?; ERR="$(cat "$T/err")"; }
pin(){ sed -n "s/^$1=//p" "$PIN"; }
untouched(){ cmp -s "$PIN" "$T/pin.before" && cmp -s "$MANIFEST" "$T/manifest.before"; }

echo "== фиктивный пин 4.0.0 → релиз v4.0.0: настоящие суммы на месте нулей =="
FICT=1 new_tree
eq "до релиза — фиктивный пин" "$ZERO" "$(pin STVOR_AGENT_PIN_SHA256_AMD64)"
sums "$T/SHA256SUMS" "$A64  stvor-agent_4.0.0_amd64.deb" "$B64  stvor-agent_4.0.0_arm64.deb" \
    "$C64  stvor-agent_4.0.0_source.tar.gz"
run v4.0.0 "$T/SHA256SUMS"
eq "код 0" 0 "$RC"
eq "версия пина" 4.0.0 "$(pin STVOR_AGENT_PIN_VERSION)"
eq "сумма amd64" "$A64" "$(pin STVOR_AGENT_PIN_SHA256_AMD64)"
eq "сумма arm64" "$B64" "$(pin STVOR_AGENT_PIN_SHA256_ARM64)"
check_not "пометка фиктивного пина убрана" grep -q 'FICTITIOUS' "$PIN"
check "шапка пина осталась" grep -q '^# Catalog pin of the stvor-agent package' "$PIN"
eq "версия расширения — patch-подъём" "version: 4.0.1" "$(grep '^version: ' "$MANIFEST")"
check "строка истории в манифесте" grep -qx '# 4.0.1: пин пакета stvor-agent 4.0.0.' "$MANIFEST"
check "вывод: changed=true" grep -qx 'changed=true' <<< "$OUT"
check "вывод: version" grep -qx 'version=4.0.0' <<< "$OUT"
check "вывод: sha256_amd64" grep -qx "sha256_amd64=$A64" <<< "$OUT"
check "вывод: sha256_arm64" grep -qx "sha256_arm64=$B64" <<< "$OUT"
check "вывод: ext_version" grep -qx 'ext_version=4.0.1' <<< "$OUT"
check "манифест — по-прежнему YAML с той же схемой" python3 -c '
import sys, yaml
m = yaml.safe_load(open(sys.argv[1]))
assert m["schema"] == "cream/v1" and m["name"] == "stvor-agent" and m["version"] == "4.0.1", m
' "$MANIFEST"
# A second run on the same release has nothing left to do.
run v4.0.0 "$T/SHA256SUMS"
eq "повтор: код 0" 0 "$RC"
check "повтор: changed=false" grep -qx 'changed=false' <<< "$OUT"
eq "повтор: версия расширения не поднята" "version: 4.0.1" "$(grep '^version: ' "$MANIFEST")"

echo "== настоящий пин 4.0.0 → релиз v4.1.2 (сумма в двоичном виде «*файл») =="
EXT_VERSION=4.0.3 new_tree 4.0.0 "$A64" "$B64"
sums "$T/SHA256SUMS" "$C64 *stvor-agent_4.1.2_amd64.deb" "$D64 *stvor-agent_4.1.2_arm64.deb"
run v4.1.2 "$T/SHA256SUMS"
eq "код 0" 0 "$RC"
eq "версия пина" 4.1.2 "$(pin STVOR_AGENT_PIN_VERSION)"
eq "сумма amd64" "$C64" "$(pin STVOR_AGENT_PIN_SHA256_AMD64)"
eq "сумма arm64" "$D64" "$(pin STVOR_AGENT_PIN_SHA256_ARM64)"
eq "версия расширения 4.0.3 → 4.0.4" "version: 4.0.4" "$(grep '^version: ' "$MANIFEST")"
check "строка истории" grep -qx '# 4.0.4: пин пакета stvor-agent 4.1.2.' "$MANIFEST"
eq "строка истории — одна" 1 "$(grep -c '^# 4\.0\.4: ' "$MANIFEST")"
eq "история сразу под version:" '# 4.0.4: пин пакета stvor-agent 4.1.2.' \
    "$(grep -A1 -x 'version: 4.0.4' "$MANIFEST" | tail -n 1)"
eq "строк в пине не прибавилось" "$(wc -l < "$T/pin.before")" "$(wc -l < "$PIN")"

echo "== нет одной архитектуры — отказ, файлы не тронуты =="
new_tree 4.0.0 "$A64" "$B64"
sums "$T/SHA256SUMS" "$C64  stvor-agent_4.1.0_amd64.deb"
run v4.1.0 "$T/SHA256SUMS"
check "код не 0" test "$RC" -ne 0
check "сообщение называет arm64" grep -q 'stvor-agent_4.1.0_arm64.deb' <<< "$ERR"
check "пин и манифест не тронуты" untouched
check_not "changed=true не напечатан" grep -qx 'changed=true' <<< "$OUT"

echo "== две суммы на один .deb — отказ =="
new_tree 4.0.0 "$A64" "$B64"
sums "$T/SHA256SUMS" "$C64  stvor-agent_4.1.0_amd64.deb" "$A64  stvor-agent_4.1.0_amd64.deb" \
    "$D64  stvor-agent_4.1.0_arm64.deb"
run v4.1.0 "$T/SHA256SUMS"
check "код не 0" test "$RC" -ne 0
check "пин и манифест не тронуты" untouched

echo "== сумма не из 64 hex — отказ =="
new_tree 4.0.0 "$A64" "$B64"
sums "$T/SHA256SUMS" "${C64:0:63}  stvor-agent_4.1.0_amd64.deb" "$D64  stvor-agent_4.1.0_arm64.deb"
run v4.1.0 "$T/SHA256SUMS"
check "код не 0" test "$RC" -ne 0
check "пин и манифест не тронуты" untouched

echo "== релиз старше пина — «нечего делать» =="
new_tree 4.2.0 "$A64" "$B64"
sums "$T/SHA256SUMS" "$C64  stvor-agent_4.1.9_amd64.deb" "$D64  stvor-agent_4.1.9_arm64.deb"
run v4.1.9 "$T/SHA256SUMS"
eq "код 0" 0 "$RC"
check "changed=false" grep -qx 'changed=false' <<< "$OUT"
check "сообщение «нечего делать»" grep -q 'nothing to do' <<< "$ERR"
check "пин и манифест не тронуты" untouched
# 4.10.0 is newer than 4.9.0: versions compare as versions, not as strings.
new_tree 4.9.0 "$A64" "$B64"
sums "$T/SHA256SUMS" "$C64  stvor-agent_4.10.0_amd64.deb" "$D64  stvor-agent_4.10.0_arm64.deb"
run v4.10.0 "$T/SHA256SUMS"
eq "4.10.0 новее 4.9.0" 4.10.0 "$(pin STVOR_AGENT_PIN_VERSION)"

echo "== та же версия, те же суммы — «уже стоит» =="
new_tree 4.0.0 "$A64" "$B64"
sums "$T/SHA256SUMS" "$A64  stvor-agent_4.0.0_amd64.deb" "$B64  stvor-agent_4.0.0_arm64.deb"
run v4.0.0 "$T/SHA256SUMS"
eq "код 0" 0 "$RC"
check "changed=false" grep -qx 'changed=false' <<< "$OUT"
check "пин и манифест не тронуты" untouched

echo "== та же версия с другой суммой — отказ =="
new_tree 4.0.0 "$A64" "$B64"
sums "$T/SHA256SUMS" "$A64  stvor-agent_4.0.0_amd64.deb" "$C64  stvor-agent_4.0.0_arm64.deb"
run v4.0.0 "$T/SHA256SUMS"
check "код не 0" test "$RC" -ne 0
check "сообщение называет arm64" grep -q 'arm64' <<< "$ERR"
check "пин и манифест не тронуты" untouched
check_not "changed= не напечатан" grep -q '^changed=' <<< "$OUT"

echo "== неверные аргументы — код 2 =="
new_tree 4.0.0 "$A64" "$B64"
sums "$T/SHA256SUMS" "$C64  stvor-agent_4.1.0_amd64.deb" "$D64  stvor-agent_4.1.0_arm64.deb"
run 4.1.0 "$T/SHA256SUMS"
eq "тег без v — код 2" 2 "$RC"
run v4.1.0 "$T/missing"
eq "нет SHA256SUMS — код 2" 2 "$RC"
check "пин и манифест не тронуты" untouched

echo
echo "agent-bump: прошло $pass, упало $fail"
(( fail == 0 ))
