#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Тесты firefox (cream/v1): хуки install и remove на подменённом корне, как их
# зовёт cream. Ключ Mozilla принимается только с закреплённым отпечатком и
# ровно одним основным ключом, источник и пин apt, языковой пакет по ключу
# FIREFOX_LANGPACK, отказ при оставшемся транзитном snap-пакете, повтор install
# не меняет файлы, remove снимает только поставленное этим расширением.
# apt-get, curl, gpg, gpgconf, dpkg, dpkg-query — подставные; root и сеть не нужны.
#
#   extensions/debian/firefox/tests/test-firefox.sh        код 0 — все проверки прошли
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../../tools/hooktest.sh
. "$HERE/../../../../tools/hooktest.sh"
EXT="$(dirname "$HERE")"
FPR=35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3

ht_init

# fresh: a root with fakes.
#   $FAKE/pkg-<name>  — dpkg-query reports the package installed
#   $FAKE/fpr         — fingerprints gpg lists, one primary key per line
#   $FAKE/version     — what dpkg -s firefox reports
fresh() {
    ht_root "$EXT"
    printf '%s\n' "$FPR" > "$FAKE/fpr"
    printf '155.0.1~build1\n' > "$FAKE/version"
    ht_fake apt-get 'if [[ "$1" == -s ]]; then v=Remv; [[ "$2" == purge ]] && v=Purg
    for a in "${@:3}"; do echo "$v $a [1.0]"; done; cat "$FAKE/sim-extra" 2>/dev/null; exit 0; fi
case "$*" in *install*) for a in "$@"; do case "$a" in -*|install) ;; *) : > "$FAKE/pkg-$a" ;; esac; done
    [[ " $* " == *" firefox "* ]] && { mkdir -p "$ROOTDIR/usr/lib/firefox"; printf "#!/bin/sh\n" > "$ROOTDIR/usr/lib/firefox/firefox"; chmod +x "$ROOTDIR/usr/lib/firefox/firefox"; } ;;
  *purge*|*remove*) for a in "$@"; do rm -f "$FAKE/pkg-$a"; done ;;
esac; exit 0'
    sed -i "2i ROOTDIR=$(printf '%q' "$ROOT")" "$ROOT/bin/apt-get"
    ht_fake dpkg-query 'for a in "$@"; do last="$a"; done; [[ -f "$FAKE/pkg-$last" ]] && printf installed; exit 0'
    ht_fake dpkg 'printf "Package: firefox\nVersion: %s\n" "$(cat "$FAKE/version")"'
    ht_fake curl 'while (( $# )); do [[ "$1" == -o ]] && { echo KEYFILE > "$2"; shift; }; shift; done'
    ht_fake gpgconf
    ht_fake gpg 'case "$*" in
  *--import*) exit 0 ;;
  *--list-keys*) while read -r f; do echo "pub:-:4096:1:ABCDEF:1:::-:::scSC::::::23::0:"; echo "fpr:::::::::$f:"; done < "$FAKE/fpr" ;;
  *--export*) echo "ARMORED $*" | sed "s/--homedir [^ ]* //" ;;
esac'
    ht_fake sleep
    K="$ROOT/etc/apt/keyrings/packages.mozilla.org.asc"
    L="$ROOT/etc/apt/sources.list.d/mozilla.list"
    P="$ROOT/etc/apt/preferences.d/mozilla"
    S="$ROOT/var/lib/cream/ext/firefox/packages"
}
sum() { sha256sum "$@" | awk '{print $1}'; }

echo "== манифест =="
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "версия 2.0.3" 2.0.3 "$(mf 'm["version"]')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "хуки install и remove" "['install', 'remove']" "$(mf 'sorted(m["hooks"])')"
eq "FIREFOX_LANGPACK — scope install" install "$(mf 'm["config"]["keys"]["FIREFOX_LANGPACK"]["scope"]')"
eq "FIREFOX_LANGPACK — пустое можно" True "$(mf 'm["config"]["keys"]["FIREFOX_LANGPACK"]["empty"]')"
check_not "install.sh layout 2 убран" test -e "$EXT/install.sh"

echo "== install без языкового пакета =="
fresh
ht_hook install; eq "install — 0" 0 "$?"
eq "ключ — экспорт закреплённого" "ARMORED --batch --armor --export $FPR" "$(cat "$K")"
eq "ключ 0644" 644 "$(stat -c %a "$K")"
eq "источник apt" "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" "$(cat "$L")"
check "пин только firefox*" grep -qx 'Package: firefox\*' "$P"
check "пин origin" grep -qx 'Pin: origin packages.mozilla.org' "$P"
check "пин 1000" grep -qx 'Pin-Priority: 1000' "$P"
check "apt-get install firefox с --allow-downgrades" ht_called '^apt-get install -y --allow-downgrades firefox$'
eq "состояние: поставлен firefox" firefox "$(cat "$S")"
before="$(sum "$K" "$L" "$P" "$S")"
ht_hook install; eq "повтор install — 0" 0 "$?"
eq "повтор не меняет файлы" "$before" "$(sum "$K" "$L" "$P" "$S")"
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check "remove: purge firefox" ht_called '^apt-get -q -y purge firefox$'
check_not "remove: ключ снят" test -e "$K"
check_not "remove: источник снят" test -e "$L"
check_not "remove: пин снят" test -e "$P"
check "remove: apt-get update после снятия источника" ht_called '^apt-get update'
check_not "remove: состояние снято" test -e "$S"
: > "$FAKE/calls"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
check_not "повтор remove ничего не удаляет" ht_called '^apt-get .*purge'

echo "== языковой пакет =="
fresh
ht_hook install FIREFOX_LANGPACK=ru; eq "install ru — 0" 0 "$?"
check "firefox-l10n-ru" ht_called '^apt-get install -y --allow-downgrades firefox firefox-l10n-ru$'
eq "состояние: оба пакета" "$(printf 'firefox\nfirefox-l10n-ru')" "$(cat "$S")"
ht_hook install FIREFOX_LANGPACK=de; eq "смена на de — 0" 0 "$?"
eq "состояние копит пакеты" "$(printf 'firefox\nfirefox-l10n-de\nfirefox-l10n-ru')" "$(cat "$S")"
ht_hook remove; eq "remove — 0" 0 "$?"
check "remove: все свои пакеты" ht_called '^apt-get -q -y purge firefox firefox-l10n-de firefox-l10n-ru$'

fresh
ht_hook install 'FIREFOX_LANGPACK=ru;rm'; eq "кривой код языка — 1" 1 "$?"
check_not "до apt-get не дошло" ht_called '^apt-get '

echo "== симуляция снимает чужой пакет =="
fresh
ht_hook install; eq "install — 0" 0 "$?"
echo 'Purg thunderbird-firefox-bridge [1.0]' > "$FAKE/sim-extra"
: > "$FAKE/calls"
ht_hook remove; eq "remove с чужим пакетом — 1" 1 "$?"
check "симуляция purge" ht_called '^apt-get -s purge firefox$'
check "чужой пакет назван" grep -q 'thunderbird-firefox-bridge' "$ROOT/out"
check_not "ничего не снято" ht_called '^apt-get -q -y purge'
check "firefox на месте" test -e "$FAKE/pkg-firefox"
check "состояние осталось" test -s "$S"
check "источник не тронут" test -e "$L"

echo "== пакет стоял до cream =="
fresh
: > "$FAKE/pkg-firefox"
ht_hook install; eq "install — 0" 0 "$?"
check_not "чужой firefox не записан своим" grep -qsx firefox "$S"
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "чужой firefox не удаляется" ht_called '^apt-get .*purge'
check_not "источник всё равно снят" test -e "$L"

echo "== отказы =="
fresh
printf 'DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF\n' > "$FAKE/fpr"
ht_hook install; eq "чужой отпечаток — 1" 1 "$?"
check_not "ключ не записан" test -e "$K"
check_not "firefox не ставился" ht_called '^apt-get install -y --allow-downgrades'

fresh
printf '%s\nDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF\n' "$FPR" > "$FAKE/fpr"
ht_hook install; eq "два основных ключа — 1" 1 "$?"
check "…отказ называет число ключей" grep -q '2 основных ключей' <(ht_out)
# Many keys in the listing: the parse must not close gpg's pipe early (was 141).
fresh
{ echo "$FPR"; for i in $(seq 1 3000); do printf 'DEADBEEF%032d\n' "$i"; done; } > "$FAKE/fpr"
ht_hook install; eq "длинный список ключей — отказ 1, не SIGPIPE 141" 1 "$?"
check_not "статический скан: нет awk с exit на канале gpg" grep -qE "list-keys.*\\\$|exit \}'\)\"" "$EXT/hooks/install"
check_not "ключ не записан" test -e "$K"

fresh
printf '1:1snap1-0ubuntu2\n' > "$FAKE/version"
ht_hook install; eq "остался snap-пакет — 1" 1 "$?"
check "сообщение про snap" grep -q 'snap' <(ht_out)

ht_done
