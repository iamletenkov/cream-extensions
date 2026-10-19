#!/usr/bin/env bash
# H-тесты библиотеки apt-guard (cream/v1, kind: library) на подменённом корне:
# apt_guard_check и apt_guard_remove с подставным apt-get — симуляция только
# своих пакетов, чужой пакет в симуляции (remove и purge), провал симуляции,
# не имя пакета в записи, суффикс :arch, пустой список, подсказка вызывающего.
# root и сеть не нужны.
#
#   extensions/debian/apt-guard/tests/test-apt-guard.sh        код 0 — все проверки прошли
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../../tools/hooktest.sh
. "$HERE/../../../../tools/hooktest.sh"
EXT="$(dirname "$HERE")"

ht_init

echo "== манифест =="
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "name" apt-guard "$(mf 'm["name"]')"
eq "kind: library" library "$(mf 'm["kind"]')"
eq "хуков нет" None "$(mf 'm.get("hooks")')"
check_not "каталога hooks/ нет" test -e "$EXT/hooks"
eq "обе архитектуры" "['amd64', 'arm64']" "$(mf 'm["platform"]["arch"]')"

# guard_root: fresh root; the fake apt-get prints, for -s, a Remv/Purg line per
# package asked plus $FAKE/sim-extra (lines as apt prints them); -s fails when
# $FAKE/sim-fail exists; the real verb fails when $FAKE/apt-fail exists.
guard_root() {
    ht_root "$EXT"
    ht_fake apt-get '
if [[ "$1" == -s ]]; then
    [[ -e "$FAKE/sim-fail" ]] && exit 100
    v=Remv; [[ "$2" == purge ]] && v=Purg
    for p in "${@:3}"; do echo "$v $p [1.0]"; done
    cat "$FAKE/sim-extra" 2>/dev/null
    exit 0
fi
[[ -e "$FAKE/apt-fail" ]] && exit 100
exit 0'
}

# lib <code>: source the library in a clean shell like a consumer hook
# (set -euo pipefail, CREAM_EXT=demo, PATH with the fakes first).
lib() {
    env -i PATH="$ROOT/bin:$HT_PATH_TAIL" LANG=C.UTF-8 CREAM_ROOT="$ROOT" CREAM_EXT=demo \
        ${APT_GUARD_HINT:+APT_GUARD_HINT="$APT_GUARD_HINT"} \
        bash -c 'set -euo pipefail; source "$1"; eval "$2"' lib "$HT_EXT/apt-guard.sh" "$1" \
        > "$ROOT/out" 2>&1
}

echo "== только свои пакеты =="
guard_root
lib 'apt_guard_remove remove foo bar'; eq "remove — 0" 0 "$?"
check "симуляция" ht_called '^apt-get -s remove foo bar$'
check "удаление" ht_called '^apt-get -q -y remove foo bar$'
guard_root
lib 'apt_guard_remove purge foo'; eq "purge — 0" 0 "$?"
check "симуляция purge" ht_called '^apt-get -s purge foo$'
check "purge" ht_called '^apt-get -q -y purge foo$'
guard_root
lib 'apt_guard_check remove foo'; eq "check — 0" 0 "$?"
check_not "check не удаляет" ht_called '^apt-get -q -y'

echo "== чужой пакет в симуляции — отказ =="
guard_root
echo 'Remv network-manager-gnome [1.30.0-2]' > "$FAKE/sim-extra"
lib 'apt_guard_remove remove network-manager'; eq "remove — 1" 1 "$?"
check "чужой пакет назван" grep -q 'network-manager-gnome' "$ROOT/out"
check "подсказка --forget" grep -q 'cream remove --forget demo' "$ROOT/out"
check_not "ничего не снято" ht_called '^apt-get -q -y'
guard_root
echo 'Purg firefox-l10n-ru [1.0]' > "$FAKE/sim-extra"
lib 'apt_guard_remove purge firefox'; eq "purge с чужим — 1" 1 "$?"
check "чужой из Purg назван" grep -q 'firefox-l10n-ru' "$ROOT/out"
check_not "purge не выполнен" ht_called '^apt-get -q -y'
guard_root
echo 'Remv task-desktop [3.73]' > "$FAKE/sim-extra"
lib 'apt_guard_check remove foo'; eq "check с чужим — 1" 1 "$?"
guard_root
echo 'Remv task-desktop [3.73]' > "$FAKE/sim-extra"
APT_GUARD_HINT="см. README, «Как снять»" lib 'apt_guard_check remove foo'
check "своя подсказка" grep -q 'README, «Как снять»' "$ROOT/out"
check_not "своя подсказка вместо умолчания" grep -q 'cream remove --forget' "$ROOT/out"
guard_root
echo 'Remv task-desktop [3.73]' > "$FAKE/sim-extra"
lib 'if apt_guard_check remove foo; then echo yes; else echo no; fi'
check "в условии — ложь, без выхода" grep -qx no "$ROOT/out"

echo "== суффикс архитектуры =="
guard_root
echo 'Remv foo:arm64 [1.0]' > "$FAKE/sim-extra"
lib 'apt_guard_remove remove foo'; eq "foo:arm64 — свой" 0 "$?"
guard_root
echo 'Remv libbar:i386 [1.0]' > "$FAKE/sim-extra"
lib 'apt_guard_remove remove foo'; eq "libbar:i386 — чужой" 1 "$?"

echo "== провалы и мусор =="
guard_root
touch "$FAKE/sim-fail"
lib 'apt_guard_remove remove foo'; eq "симуляция упала — 1" 1 "$?"
check_not "после провала симуляции не удаляет" ht_called '^apt-get -q -y'
guard_root
touch "$FAKE/apt-fail"
lib 'apt_guard_remove remove foo'; eq "apt-get упал — 1" 1 "$?"
check "провал назван" grep -q 'apt-get remove foo не прошёл' "$ROOT/out"
guard_root
lib 'apt_guard_remove remove foo -oDebug::x=1'; eq "опция в записи — 1" 1 "$?"
check_not "опция не уходит в apt" ht_called '^apt-get'
guard_root
lib "apt_guard_remove remove \$'bad\\e[31m'"; eq "управляющие символы — 1" 1 "$?"
check_not "ESC не печатается" grep -q $'\e' "$ROOT/out"
guard_root
lib 'apt_guard_remove autoremove foo'; eq "неизвестное действие — 1" 1 "$?"
check_not "неизвестное действие — apt не зовётся" ht_called '^apt-get'
guard_root
lib 'apt_guard_remove remove'; eq "пустой список — 0" 0 "$?"
check_not "пустой список — apt не зовётся" ht_called '^apt-get'

ht_done
