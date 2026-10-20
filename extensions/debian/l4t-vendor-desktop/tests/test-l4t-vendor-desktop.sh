#!/usr/bin/env bash
# H-тесты l4t-vendor-desktop (cream/v1): хук install на подменённом корне, как
# его зовёт cream (tools/hooktest.sh). Расширение ничего не ставит — проверяет
# рабочий стол образа вендора; apt/dpkg не зовутся вовсе (сторож hooktest).
#
#   extensions/debian/l4t-vendor-desktop/tests/test-l4t-vendor-desktop.sh   код 0 — все проверки прошли
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../../tools/hooktest.sh
. "$HERE/../../../../tools/hooktest.sh"
EXT="$(dirname "$HERE")"

ht_init

R32='# R32 (release), REVISION: 6.1, GCID: 27863751, BOARD: t210ref, EABI: aarch64, DATE: Mon Jul 26 19:20:30 UTC 2021'
R36='# R36 (release), REVISION: 4.3, GCID: 38968081, BOARD: generic, EABI: aarch64, DATE: Wed Jan  8 01:49:37 UTC 2025'

# vd_root [release]: a vendor L4T root with Xorg, gdm3 as the display manager
# and a GNOME session — what the Q-engineering Nano image carries.
vd_root() {
    ht_root "$EXT"
    mkdir -p "$ROOT/etc/X11" "$ROOT/usr/lib/xorg" "$ROOT/usr/sbin" "$ROOT/usr/share/xsessions" \
        "$ROOT/etc/systemd/system" "$ROOT/lib/systemd/system"
    printf '%s\n' "${1:-$R32}" > "$ROOT/etc/nv_tegra_release"
    printf '#!/bin/sh\n' > "$ROOT/usr/lib/xorg/Xorg"; chmod 0755 "$ROOT/usr/lib/xorg/Xorg"
    printf '#!/bin/sh\n' > "$ROOT/usr/sbin/gdm3"; chmod 0755 "$ROOT/usr/sbin/gdm3"
    echo /usr/sbin/gdm3 > "$ROOT/etc/X11/default-display-manager"
    : > "$ROOT/lib/systemd/system/gdm3.service"
    ln -s /lib/systemd/system/gdm3.service "$ROOT/etc/systemd/system/display-manager.service"
    printf '[Desktop Entry]\nName=Ubuntu\nExec=gnome-session\n' > "$ROOT/usr/share/xsessions/ubuntu.desktop"
}

echo "== манифест =="
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "name" l4t-vendor-desktop "$(mf 'm["name"]')"
eq "мажор 1" 1 "$(mf 'm["version"].split(".")[0]')"
eq "только arm64" arm64 "$(mf '" ".join(m["platform"]["arch"])')"
eq "Ubuntu вендора L4T" "ubuntu>=18.04" "$(mf '" ".join(o["id"] + o.get("version", "") for o in m["platform"]["os"])')"
eq "даёт способности рабочего стола" "desktop-session display-manager x11-server" \
    "$(mf '" ".join(sorted(m["provides"]))')"
eq "исключает другой рабочий стол" desktop-session "$(mf '" ".join(m["conflicts"]["capabilities"])')"
eq "ничего не требует" 0 "$(mf 'len(m.get("requires", []))')"
eq "без зависимостей" 0 "$(mf 'len(m.get("depends", []))')"
eq "без ключей" 0 "$(mf 'len(m.get("config", {}).get("keys", {}))')"
eq "хуки" "install remove" "$(mf '" ".join(sorted(m["hooks"]))')"
check "hooks/install исполняемый" test -x "$EXT/hooks/install"

echo "== рабочий стол вендора на R32 =="
vd_root
ht_hook install; eq "всё на месте — 0" 0 "$?"
check_not "apt не зовётся" ht_called '^apt'
check_not "dpkg не зовётся" ht_called '^dpkg'
check "в журнале менеджер входа" grep -q gdm3 "$ROOT/out"
check "в журнале сессия" grep -q ubuntu.desktop "$ROOT/out"
ht_hook install; eq "повтор — 0" 0 "$?"
ht_hook remove; eq "remove — 0" 0 "$?"
check "remove: Xorg вендора на месте" test -x "$ROOT/usr/lib/xorg/Xorg"
check "remove: менеджер входа на месте" test -L "$ROOT/etc/systemd/system/display-manager.service"

echo "== Xorg в /usr/bin =="
vd_root
rm -f "$ROOT/usr/lib/xorg/Xorg"; mkdir -p "$ROOT/usr/bin"
printf '#!/bin/sh\n' > "$ROOT/usr/bin/Xorg"; chmod 0755 "$ROOT/usr/bin/Xorg"
ht_hook install; eq "Xorg в /usr/bin — 0" 0 "$?"

echo "== менеджер входа только по default-display-manager =="
vd_root
rm -f "$ROOT/etc/systemd/system/display-manager.service"
ht_hook install; eq "без ссылки юнита, с default-display-manager — 0" 0 "$?"

echo "== не Jetson и не R32 — 20 =="
vd_root
rm -f "$ROOT/etc/nv_tegra_release"
ht_hook install; eq "нет nv_tegra_release — 20" 20 "$?"
vd_root "$R36"
ht_hook install; eq "R36 — 20 (рабочий стол там ставят gnome/xfce4/lxde)" 20 "$?"

echo "== отказы: рабочего стола нет — 1, с названной причиной =="
vd_root
rm -f "$ROOT/usr/lib/xorg/Xorg"
ht_hook install; eq "нет Xorg — 1" 1 "$?"
check "причина: Xorg" grep -q Xorg "$ROOT/out"
vd_root
rm -f "$ROOT/etc/systemd/system/display-manager.service" "$ROOT/etc/X11/default-display-manager"
ht_hook install; eq "нет менеджера входа — 1" 1 "$?"
check "причина: менеджер входа" grep -q 'менеджер' "$ROOT/out"
vd_root
echo /usr/sbin/lightdm > "$ROOT/etc/X11/default-display-manager"
rm -f "$ROOT/etc/systemd/system/display-manager.service"
ht_hook install; eq "default-display-manager на несуществующий — 1" 1 "$?"
vd_root
rm -f "$ROOT/usr/share/xsessions/ubuntu.desktop"
ht_hook install; eq "нет X-сессии — 1" 1 "$?"
check "причина: xsessions" grep -q xsessions "$ROOT/out"
vd_root
ln -sfn /nonexistent "$ROOT/etc/systemd/system/display-manager.service"
rm -f "$ROOT/etc/X11/default-display-manager"
ht_hook install; eq "битая ссылка display-manager.service — 1" 1 "$?"

echo "== журнал: имена из образа — данные =="
vd_root
printf '[Desktop Entry]\n' > "$ROOT/usr/share/xsessions/"$'x\033[31mred.desktop'
ht_hook install; eq "странное имя сессии — 0" 0 "$?"
check_not "в журнале нет управляющих символов" grep -q $'\033\[31' "$ROOT/out"

ht_done
