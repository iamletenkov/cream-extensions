#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Тесты network-manager (cream/v1): хуки install и remove на подменённом корне,
# как их зовёт cream. «Уже стоит и включён» — apt не трогается; недостающее
# ставится и юнит проверяется; нет пакета в репозитории или юнит не включился —
# отказ; предупреждения про systemd-networkd и прошивку Wi-Fi; remove снимает
# только поставленное этим расширением. apt-get, apt-cache, dpkg-query,
# systemctl — подставные; root и сеть не нужны.
#
#   extensions/debian/network-manager/tests/test-network-manager.sh   код 0 — все проверки прошли
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../../tools/hooktest.sh
. "$HERE/../../../../tools/hooktest.sh"
EXT="$(dirname "$HERE")"

ht_init

# fresh: a root with fakes. $FAKE/pkg-<name> — dpkg-query reports it installed;
# $FAKE/no-candidate — apt-cache has no candidate; $FAKE/enable-broken —
# neither apt-get install nor systemctl enable creates the unit link.
fresh() {
    ht_root "$EXT"
    WANTS="$ROOT/etc/systemd/system/multi-user.target.wants"
    STATE="$ROOT/var/lib/cream/ext/network-manager/installed"
    mkdir -p "$WANTS" "$ROOT/lib/firmware"
    ht_fake dpkg-query 'p="${*: -1}"; [[ -f "$FAKE/pkg-$p" ]] || exit 1
case "$*" in *Version*) printf 1.0-1 ;; *) printf "installed\n" ;; esac'
    ht_fake apt-cache 'if [[ -f "$FAKE/no-candidate" ]]; then c="(none)"; else c=1.0-1; fi
printf "%s:\n  Installed: (none)\n  Candidate: %s\n" "${*: -1}" "$c"'
    ht_fake apt-get 'if [[ " $* " == *" install "* ]]; then
  for a in "$@"; do case "$a" in -*|install) ;; *) : > "$FAKE/pkg-$a" ;; esac; done
  [[ -f "$FAKE/enable-broken" ]] || ln -sf /lib/systemd/system/NetworkManager.service \
    "'"$ROOT"'/etc/systemd/system/multi-user.target.wants/NetworkManager.service"
fi; exit 0'
    ht_fake systemctl 'if [[ "$1" == enable && ! -f "$FAKE/enable-broken" ]]; then
  ln -sf /lib/systemd/system/NetworkManager.service \
    "'"$ROOT"'/etc/systemd/system/multi-user.target.wants/NetworkManager.service"
fi; exit 0'
    ht_fake sleep
}
enabled() { ln -sf /lib/systemd/system/NetworkManager.service "$WANTS/NetworkManager.service"; }

echo "== манифест =="
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 2" 2.0.0 "$(mf 'm["version"]')"
eq "build: exec" exec "$(mf 'm["targets"]["build"]')"
eq "live: confirm" confirm "$(mf 'm["targets"]["live"]')"
check "live_note про сетевой стек" grep -q 'сет' <<< "$(mf 'm["targets"]["live_note"]')"
eq "хуки install и remove" "['install', 'remove']" "$(mf 'sorted(m["hooks"])')"
check "install с явным timeout" test -n "$(mf 'm["hooks"]["install"].get("timeout", "")')"
eq "платформа: debian и ubuntu" "['debian', 'ubuntu']" "$(mf 'sorted(o["id"] for o in m["platform"]["os"])')"
check_not "install.sh layout 2 убран" test -e "$EXT/install.sh"

echo "== уже стоит и включён =="
fresh
: > "$FAKE/pkg-network-manager"; : > "$FAKE/pkg-wpasupplicant"; enabled
ht_hook install; eq "install — 0" 0 "$?"
check_not "apt-get не звали" ht_called '^apt-get '
check_not "systemctl не звали" ht_called '^systemctl '
check "сообщение «не трогаю»" grep -q 'не трогаю' <(ht_out)
check_not "состояния нет: ничего не ставили" test -s "$STATE"
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "remove не удаляет чужие пакеты" ht_called '^apt-get '

echo "== ставит недостающее =="
fresh
: > "$FAKE/pkg-network-manager"
ht_hook install; eq "install — 0" 0 "$?"
check "apt-get update" ht_called '^apt-get .*update$'
check "ставит только wpasupplicant" ht_called '^apt-get .*install wpasupplicant$'
check "юнит включён" test -L "$WANTS/NetworkManager.service"
eq "состояние: wpasupplicant" wpasupplicant "$(cat "$STATE")"
: > "$FAKE/calls"
ht_hook install; eq "повтор install — 0" 0 "$?"
check_not "повтор: apt-get не звали" ht_called '^apt-get '
eq "повтор не теряет «поставлено нами»" wpasupplicant "$(cat "$STATE")"
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check "remove: только wpasupplicant" ht_called '^apt-get .*remove wpasupplicant$'
check_not "remove: network-manager не трогается" ht_called 'remove .*network-manager'
check_not "состояние снято" test -e "$STATE"
: > "$FAKE/calls"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
check_not "повтор remove ничего не удаляет" ht_called '^apt-get '

fresh
ht_hook install; eq "ничего нет — install 0" 0 "$?"
check "ставит оба пакета" ht_called '^apt-get .*install network-manager wpasupplicant$'
eq "состояние: оба" "network-manager wpasupplicant" "$(tr '\n' ' ' < "$STATE" | sed 's/ $//')"

fresh
: > "$FAKE/pkg-network-manager"; : > "$FAKE/pkg-wpasupplicant"
ht_hook install; eq "пакеты есть, юнит выключен — 0" 0 "$?"
check_not "apt-get не звали" ht_called '^apt-get '
check "systemctl enable" ht_called '^systemctl enable NetworkManager\.service$'

echo "== отказы =="
fresh
: > "$FAKE/no-candidate"
ht_hook install; eq "нет пакета в репозитории — 1" 1 "$?"
check_not "install не звали" ht_called '^apt-get .*install'
check "сообщение про sources.list" grep -q 'sources.list' <(ht_out)
check_not "состояния нет" test -s "$STATE"

fresh
: > "$FAKE/enable-broken"
ht_hook install; eq "юнит не включился — 1" 1 "$?"
check "сообщение про юнит" grep -q 'не включён' <(ht_out)

echo "== предупреждения =="
fresh
: > "$FAKE/pkg-network-manager"; : > "$FAKE/pkg-wpasupplicant"; enabled
ln -sf /lib/systemd/system/systemd-networkd.service "$WANTS/systemd-networkd.service"
ht_hook install; eq "networkd рядом — 0" 0 "$?"
check "предупреждение про systemd-networkd" grep -q 'systemd-networkd' <(ht_out)
check "прошивки нет — предупреждение" grep -q 'не нашлось прошивки' <(ht_out)

fresh
: > "$FAKE/pkg-network-manager"; : > "$FAKE/pkg-wpasupplicant"; enabled
mkdir -p "$ROOT/lib/firmware/brcm"
ht_hook install; eq "прошивка есть — 0" 0 "$?"
check "прошивка опознана" grep -q 'прошивка Wi-Fi в образе есть: brcm' <(ht_out)
check_not "без предупреждения про networkd" grep -q 'systemd-networkd' <(ht_out)

ht_done
