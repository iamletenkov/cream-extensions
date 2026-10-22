#!/usr/bin/env bash
# H-тесты библиотеки fetch (cream/v1, kind: library) на подменённом корне:
# fetch_verified с подставным curl — обрыв «Connection reset by peer» (curl 56)
# дважды и успех третьей попыткой, исчерпанные попытки и переход к следующему
# адресу, несовпавший sha256 (отказ без повторов), неверный вызов, никаких
# .part после себя. root и сеть не нужны; sleep подставной.
#
#   extensions/debian/fetch/tests/test-fetch.sh        код 0 — все проверки прошли
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../../tools/hooktest.sh
. "$HERE/../../../../tools/hooktest.sh"
EXT="$(dirname "$HERE")"

ht_init

echo "== манифест =="
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "name" fetch "$(mf 'm["name"]')"
eq "kind: library" library "$(mf 'm["kind"]')"
eq "хуков нет" None "$(mf 'm.get("hooks")')"
check_not "каталога hooks/ нет" test -e "$EXT/hooks"
eq "обе архитектуры" "['amd64', 'arm64']" "$(mf 'm["platform"]["arch"]')"
eq "curl не требуется до потребителя (тот ставит его сам)" None "$(mf 'm["platform"].get("commands")')"

PAYLOAD='payload-of-the-asset'
SHA="$(printf '%s' "$PAYLOAD" | sha256sum | cut -d' ' -f1)"

# fetch_root: fresh root; the fake curl fails with the code from $FAKE/fail.<N>
# on its N-th call (N counts every call, a partial file is left at -o), else
# writes $PAYLOAD ($FAKE/content overrides it) to -o.
fetch_root() {
    ht_root "$EXT"
    ht_fake sleep 'exit 0'
    ht_fake curl '
n=$(( $(cat "$FAKE/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/n"
out=""; while (( $# )); do [[ "$1" == -o ]] && { out="$2"; shift; }; shift; done
if [[ -f "$FAKE/fail.$n" ]]; then
    [[ -n "$out" ]] && echo partial > "$out"
    echo "curl: ($(cat "$FAKE/fail.$n")) Recv failure: Connection reset by peer" >&2
    exit "$(cat "$FAKE/fail.$n")"
fi
if [[ -f "$FAKE/content" ]]; then cat "$FAKE/content" > "$out"; else printf "%s" '"$PAYLOAD"' > "$out"; fi'
    mkdir -p "$ROOT/dl"
}

# lib <code>: source the library in a clean shell like a consumer hook
# (set -euo pipefail, CREAM_EXT=demo, PATH with the fakes first).
lib() {
    env -i PATH="$ROOT/bin:$HT_PATH_TAIL" LANG=C.UTF-8 CREAM_ROOT="$ROOT" CREAM_EXT=demo \
        ${FETCH_ATTEMPTS+FETCH_ATTEMPTS="$FETCH_ATTEMPTS"} \
        bash -c 'set -euo pipefail; source "$1"; eval "$2"' lib "$HT_EXT/fetch.sh" "$1" \
        > "$ROOT/out" 2>&1
}
curl_calls() { grep -c '^curl ' "$FAKE/calls"; }

echo "== curl 56 дважды, третья попытка — успех (curl 7.68 сам не повторяет) =="
fetch_root
echo 56 > "$FAKE/fail.1"; echo 56 > "$FAKE/fail.2"
lib "fetch_verified '$ROOT/dl/a.bin' $SHA https://example.test/a.bin"; eq "код 0" 0 "$?"
eq "три вызова curl" 3 "$(curl_calls)"
eq "файл — то, что скачано" "$PAYLOAD" "$(cat "$ROOT/dl/a.bin")"
check_not "без .part" test -e "$ROOT/dl/a.bin.part"
check "пауза между попытками" ht_called '^sleep 10$'
check "попытка названа в журнале" grep -q 'попытка 1/5.*curl 56' "$ROOT/out"
check "--fail и таймаут соединения" ht_called '^curl -fsSL .*--connect-timeout 30'
check "зависание — повтор (speed-limit)" ht_called '^curl .*--speed-limit 10240 --speed-time 60'
check "только https и http" ht_called '^curl .*--proto =https,http'

echo "== исчерпанные попытки на первом адресе — второй адрес =="
fetch_root
for n in 1 2 3 4 5; do echo 56 > "$FAKE/fail.$n"; done
lib "fetch_verified '$ROOT/dl/b.bin' $SHA https://one.test/b.bin https://two.test/b.bin"; eq "код 0" 0 "$?"
eq "пять попыток первого + одна второго" 6 "$(curl_calls)"
check "второй адрес" ht_called '^curl .*https://two\.test/b\.bin$'
eq "файл" "$PAYLOAD" "$(cat "$ROOT/dl/b.bin")"

echo "== все адреса и попытки исчерпаны — 1 =="
fetch_root
for n in 1 2 3; do echo 56 > "$FAKE/fail.$n"; done
FETCH_ATTEMPTS=3 lib "fetch_verified '$ROOT/dl/c.bin' $SHA https://example.test/c.bin"; eq "код 1" 1 "$?"
eq "FETCH_ATTEMPTS=3 — три попытки" 3 "$(curl_calls)"
check_not "файла нет" test -e "$ROOT/dl/c.bin"
check_not "без .part" test -e "$ROOT/dl/c.bin.part"
check "отказ назван" grep -q 'не скачался' "$ROOT/out"

echo "== sha256 не совпал — 2, без повторов =="
fetch_root
echo other > "$FAKE/content"
lib "fetch_verified '$ROOT/dl/d.bin' $SHA https://one.test/d.bin https://two.test/d.bin"; eq "код 2" 2 "$?"
eq "один вызов curl" 1 "$(curl_calls)"
check_not "файла нет" test -e "$ROOT/dl/d.bin"
check_not "без .part" test -e "$ROOT/dl/d.bin.part"
check "отказ назван" grep -q 'sha256' "$ROOT/out"

echo "== неверный вызов — 3, curl не зовётся =="
fetch_root
lib "fetch_verified '$ROOT/dl/e.bin' not-a-sum https://example.test/e.bin"; eq "сумма не sha256 — 3" 3 "$?"
lib "fetch_verified '$ROOT/dl/e.bin' $SHA"; eq "без адресов — 3" 3 "$?"
FETCH_ATTEMPTS=0 lib "fetch_verified '$ROOT/dl/e.bin' $SHA https://example.test/e.bin"; eq "FETCH_ATTEMPTS=0 — 3" 3 "$?"
check_not "curl не звался" ht_called '^curl '

ht_done
