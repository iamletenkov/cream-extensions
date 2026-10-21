#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Тесты btop (cream/v1): хуки install и remove на подменённом корне, как их
# зовёт cream. Пакет из apt (свой и уже стоявший до cream), статическая сборка
# релиза там, где пакета нет (focal), отказ по sha256 и чужой архитектуре,
# повтор install не теряет «кто поставил», remove снимает только своё.
# apt-get, apt-cache, dpkg-query, curl, sha256sum, tar, uname — подставные;
# root и сеть не нужны.
#
#   extensions/debian/btop/tests/test-btop.sh        код 0 — все проверки прошли
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../../tools/hooktest.sh
. "$HERE/../../../../tools/hooktest.sh"
EXT="$(dirname "$HERE")"
SUM_AARCH64=e8845d3f69f6a32d00258a1f79c093970666ece3d05a430c7b24a16c56577bf5

ht_init

# fresh <candidate>: a root with fakes. $FAKE/installed exists — dpkg-query
# reports btop installed; $FAKE/machine — uname -m; $FAKE/sum-bad — sha256sum fails.
fresh() {
    ht_root "$EXT"
    printf 'aarch64\n' > "$FAKE/machine"
    ht_fake apt-get 'if [[ "$1" == -s ]]; then v=Remv; [[ "$2" == purge ]] && v=Purg
    for a in "${@:3}"; do echo "$v $a [1.0]"; done; cat "$FAKE/sim-extra" 2>/dev/null; exit 0; fi
if [[ "$*" == *" install "* || "$*" == install* ]]; then : > "$FAKE/installed"; fi; exit 0'
    ht_fake apt-cache "printf 'btop:\n  Installed: (none)\n  Candidate: %s\n' '$1'"
    ht_fake dpkg-query '[[ -f "$FAKE/installed" ]] || exit 1; case "$*" in *Version*) printf 1.2.3-2 ;; *) printf installed ;; esac'
    ht_fake uname 'cat "$FAKE/machine"'
    ht_fake curl 'while (( $# )); do [[ "$1" == -o ]] && { echo tarball > "$2"; shift; }; shift; done'
    ht_fake sha256sum 'cat > "$FAKE/sha256sum.stdin"; [[ ! -f "$FAKE/sum-bad" ]]'
    ht_fake tar 'dir=""; while (( $# )); do [[ "$1" == -C ]] && dir="$2"; shift; done
mkdir -p "$dir/btop/bin"; printf "#!/bin/sh\necho btop 1.4.4\n" > "$dir/btop/bin/btop"; chmod 0755 "$dir/btop/bin/btop"'
    ht_fake sleep
    STATE="$ROOT/var/lib/cream/ext/btop/method"
    BIN="$ROOT/usr/local/bin/btop"
}

echo "== манифест =="
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 2" 2.0.2 "$(mf 'm["version"]')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "хуки install и remove" "['install', 'remove']" "$(mf 'sorted(m["hooks"])')"
check "install с явным timeout" test -n "$(mf 'm["hooks"]["install"].get("timeout", "")')"
check_not "install.sh layout 2 убран" test -e "$EXT/install.sh"

echo "== apt: свой пакет =="
fresh 1.2.3-2
ht_hook install; eq "install — 0" 0 "$?"
check "apt-get install btop" ht_called '^apt-get install .*btop$'
check_not "curl не звали" ht_called '^curl '
eq "состояние: apt" apt "$(cat "$STATE")"
ht_hook install; eq "повтор install — 0" 0 "$?"
eq "повтор не теряет «поставлено нами»" apt "$(cat "$STATE")"
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check "remove: apt-get remove btop" ht_called '^apt-get -q -y remove btop$'
check_not "состояние снято" test -e "$STATE"
: > "$FAKE/calls"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
check_not "повтор remove ничего не удаляет" ht_called '^apt-get .*remove'

fresh 1.2.3-2
ht_hook install; eq "install — 0" 0 "$?"
echo 'Remv btop-themes [1.0]' > "$FAKE/sim-extra"
: > "$FAKE/calls"
ht_hook remove; eq "симуляция снимает чужой пакет — 1" 1 "$?"
check "чужой пакет назван" grep -q 'btop-themes' "$ROOT/out"
check_not "ничего не снято" ht_called '^apt-get -q -y remove'
eq "состояние осталось" apt "$(cat "$STATE")"

echo "== apt: пакет стоял до cream =="
fresh 1.2.3-2
: > "$FAKE/installed"
ht_hook install; eq "install — 0" 0 "$?"
eq "состояние: preexisting" preexisting "$(cat "$STATE")"
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "чужой пакет не удаляется" ht_called '^apt-get .*remove'

echo "== статическая сборка (нет пакета) =="
fresh '(none)'
ht_hook install; eq "install — 0" 0 "$?"
check "curl: релиз v1.4.4 aarch64" ht_called '^curl .*/v1.4.4/btop-aarch64-linux-musl\.tbz$'
check "sha256 закреплённый" grep -q "^$SUM_AARCH64 " "$FAKE/sha256sum.stdin"
check "бинарь под корнем" test -x "$BIN"
eq "режим 0755" 755 "$(stat -c %a "$BIN")"
eq "состояние: static" static "$(cat "$STATE")"
check_not "apt-get install не звали" ht_called '^apt-get install'
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "remove: бинарь удалён" test -e "$BIN"
check_not "remove: apt-get remove не звали" ht_called '^apt-get .*remove'

fresh ''
ht_hook install; eq "пустой Candidate — тоже статическая" 0 "$?"
check "бинарь под корнем" test -x "$BIN"

echo "== отказы =="
fresh '(none)'
: > "$FAKE/sum-bad"
ht_hook install; eq "sha256 не совпал — 1" 1 "$?"
check_not "бинаря нет" test -e "$BIN"
check_not "состояния нет" test -e "$STATE"
check "сообщение про сумму" grep -q 'контрольная сумма' <(ht_out)

fresh '(none)'
printf 'riscv64\n' > "$FAKE/machine"
ht_hook install; eq "чужая архитектура — 1" 1 "$?"
check_not "curl не звали" ht_called '^curl '
check_not "бинаря нет" test -e "$BIN"

ht_done
