#!/usr/bin/env bash
# H-тесты existing-desktop (cream/v1, спека 2026-11-12-existing-desktop §4.1, план
# Task 6): хуки и действие status на подменённом корне, как их зовёт cream
# (tools/hooktest.sh). Расширение проверяет готовый стол машины и ничего в нём не
# меняет: фикстуры gdm3 Ubuntu (custom.conf: нет ключа, закомментирован, false),
# gdm3 Debian (daemon.conf), LightDM, SDDM, нет DM, только Wayland-сессии, L4T
# R32; в build — ни одного вызова loginctl и systemctl; status — на подставном
# loginctl; дерево корня до и после — то же (кроме x11-xserver-utils, П15, его
# ставит apt-get — подставной).
#
#   extensions/debian/existing-desktop/tests/test-existing-desktop.sh   код 0 — все проверки прошли
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../../tools/hooktest.sh
. "$HERE/../../../../tools/hooktest.sh"
EXT="$(dirname "$HERE")"

ht_init

R32='# R32 (release), REVISION: 6.1, GCID: 27863751, BOARD: t210ref, EABI: aarch64, DATE: Mon Jul 26 19:20:30 UTC 2021'

# Конфиг gdm3, как его кладёт пакет, побайтно (gdm3 46.2 Ubuntu 24.04 —
# custom.conf, 43.0-3 Debian 12 — daemon.conf; как в lib/tests/test-gdm-wayland.sh).
package_gdm_conf(){
    cat > "$1" <<'EOF'
# GDM configuration storage
#
# See /usr/share/gdm/gdm.schemas for a list of available options.

[daemon]
# Uncomment the line below to force the login screen to use Xorg
#WaylandEnable=false

# Enabling automatic login
#  AutomaticLoginEnable = true
#  AutomaticLogin = user1

# Enabling timed login
#  TimedLoginEnable = true
#  TimedLogin = user1
#  TimedLoginDelay = 10

[security]

[xdmcp]

[chooser]

[debug]
# Uncomment the line below to turn on debugging
# More verbose logs
# Additionally lets the X server dump core if it crashes
#Enable=true

EOF
}

exe(){ mkdir -p "$(dirname "$1")"; printf '#!/bin/sh\n' > "$1"; chmod 0755 "$1"; }

# ed_root <dm>: корень с Xorg, X-сессией, xhost и менеджером входа <dm>:
# gdm3-ubuntu | gdm3-debian | lightdm | sddm | none. Подставные loginctl (ответы —
# файлы $FAKE/user.<имя>, session.<sid>, seat.seat0; $FAKE/no-logind — без шины) и
# systemctl (is-active печатает $FAKE/is-active или active).
ed_root(){
    local dm="$1" unit="" bin=""
    ht_root "$EXT"
    exe "$ROOT/usr/lib/xorg/Xorg"
    exe "$ROOT/usr/bin/xhost"
    mkdir -p "$ROOT/usr/share/xsessions" "$ROOT/etc/X11" "$ROOT/etc/systemd/system"
    printf '[Desktop Entry]\nName=Ubuntu on Xorg\nExec=gnome-session\n' > "$ROOT/usr/share/xsessions/ubuntu-xorg.desktop"
    case "$dm" in
        gdm3-ubuntu)
            bin=/usr/sbin/gdm3; unit=/usr/lib/systemd/system/gdm3.service
            mkdir -p "$ROOT/etc/gdm3"; package_gdm_conf "$ROOT/etc/gdm3/custom.conf" ;;
        gdm3-debian)
            bin=/usr/sbin/gdm3; unit=/lib/systemd/system/gdm.service
            mkdir -p "$ROOT/etc/gdm3"; package_gdm_conf "$ROOT/etc/gdm3/daemon.conf" ;;
        lightdm)
            bin=/usr/sbin/lightdm; unit=/lib/systemd/system/lightdm.service
            mkdir -p "$ROOT/etc/lightdm"
            printf '[LightDM]\n\n[Seat:*]\n#autologin-user=\n' > "$ROOT/etc/lightdm/lightdm.conf" ;;
        sddm)
            bin=/usr/bin/sddm; unit=/lib/systemd/system/sddm.service ;;
        none) ;;
    esac
    if [[ -n "$bin" ]]; then
        exe "$ROOT$bin"
        echo "$bin" > "$ROOT/etc/X11/default-display-manager"
        mkdir -p "$ROOT$(dirname "$unit")"; : > "$ROOT$unit"
        ln -s "$unit" "$ROOT/etc/systemd/system/display-manager.service"
    fi
    # shellcheck disable=SC2016  # the body is code of the fake, expanded there
    ht_fake loginctl '[[ -e "$FAKE/no-logind" ]] && { echo "Failed to connect to bus: No such file or directory" >&2; exit 1; }
cmd="$1"; target="${!#}"
case "$cmd" in
    show-user) f="$FAKE/user.$target" ;;
    show-session) f="$FAKE/session.$target" ;;
    show-seat) f="$FAKE/seat.$target" ;;
    *) exit 1 ;;
esac
[[ -f "$f" ]] || exit 1
cat "$f"'
    # shellcheck disable=SC2016
    ht_fake systemctl '[[ "$1" == is-active ]] || exit 0
cat "$FAKE/is-active" 2>/dev/null || echo active'
    ht_fake apt-get
}

# seat0_user <name> <type> <display> [class]: на seat0 активен сеанс 2 пользователя.
seat0_user(){
    printf 'ActiveSession=2\n' > "$FAKE/seat.seat0"
    printf 'Name=%s\nType=%s\nClass=%s\n' "$1" "$2" "${4:-user}" > "$FAKE/session.2"
    printf 'Sessions=2\n' > "$FAKE/user.$1"
    # show-session для xs_seat0_session читает тот же файл: допишем его поля.
    printf 'Seat=seat0\nDisplay=%s\nState=active\nRemote=no\n' "$3" >> "$FAKE/session.2"
}

# snap: дерево корня — путь, режим, цель ссылки, sha256 файла; без журналов теста.
snap(){
    (cd "$ROOT" && find . \( -path ./out -o -path ./fake -o -path ./tmp \) -prune -o -printf '%p %m %l\n' | sort
     cd "$ROOT" && find . \( -path ./out -o -path ./fake -o -path ./tmp \) -prune -o -type f -exec sha256sum {} + | sort)
}

no_session_calls(){ ! ht_called '^loginctl' && ! ht_called '^systemctl'; }

echo "== манифест =="
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "name" existing-desktop "$(mf 'm["name"]')"
eq "версия" 1.0.0 "$(mf 'm["version"]')"
eq "cream" ">=1.2.0" "$(mf 'm["cream"]')"
eq "Debian и Ubuntu" "debian ubuntu" "$(mf '" ".join(o["id"] for o in m["platform"]["os"])')"
eq "amd64 и arm64" "amd64 arm64" "$(mf '" ".join(m["platform"]["arch"])')"
eq "build: exec" exec "$(mf 'm["targets"]["build"]')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "даёт способности стола" "desktop-session display-manager x11-server" "$(mf '" ".join(sorted(m["provides"]))')"
eq "исключает другой стол" desktop-session "$(mf '" ".join(m["conflicts"]["capabilities"])')"
eq "хуки (hooks.check cream 1.4.0 отвергает — рулинг П18)" "install remove" "$(mf '" ".join(sorted(m["hooks"]))')"
eq "install — 10m (apt с ожиданием блокировки dpkg, П19)" 10m "$(mf 'm["hooks"]["install"]["timeout"]')"
eq "действия check и status" "check status" "$(mf '" ".join(sorted(m["actions"]))')"
eq "check — lock none" none "$(mf 'm["actions"]["check"]["lock"]')"
eq "check — при сборке и на живой (только файлы)" "build live" "$(mf '" ".join(m["actions"]["check"]["phases"])')"
eq "status — lock none" none "$(mf 'm["actions"]["status"]["lock"]')"
eq "status — только live" live "$(mf '" ".join(m["actions"]["status"]["phases"])')"
eq "ключей нет" 0 "$(mf 'len((m.get("config") or {}).get("keys", {}))')"
eq "зависимостей нет" 0 "$(mf 'len(m.get("depends") or [])')"
for f in hooks/install hooks/remove actions/check actions/status; do
    check "$f исполняемый" test -x "$EXT/$f"
done
check_not "hooks/check нет (П18)" test -e "$EXT/hooks/check"

echo "== библиотека x-session разложена =="
ed_root gdm3-ubuntu
check "files/x-session.sh на месте" test -f "$HT_EXT/files/x-session.sh"

echo "== gdm3 Ubuntu, автологин alice, alice на Wayland: install 0, ничего не меняет =="
ed_root gdm3-ubuntu
sed -i 's/^#  AutomaticLoginEnable = true$/AutomaticLoginEnable=true/; s/^#  AutomaticLogin = user1$/AutomaticLogin=alice/' \
    "$ROOT/etc/gdm3/custom.conf"
seat0_user alice wayland -
before="$(snap)"
ht_hook install; eq "gdm3 Ubuntu — 0" 0 "$?"
eq "дерево не изменилось" "$before" "$(snap)"
check_not "xhost есть — apt не зовётся" ht_called '^apt-get'
out="$(ht_out)"
check "в журнале менеджер входа gdm3" grep -q 'менеджер входа: gdm3' <<< "$out"
check "диагноз: WaylandEnable не задан, сеансы на Wayland" grep -q 'WaylandEnable.*не задан.*Wayland' <<< "$out"
check "диагноз: автологин alice" grep -q 'автологин: alice' <<< "$out"
check "диагноз: seat0 — alice, wayland" grep -q 'seat0: alice, wayland' <<< "$out"
check "подсказка gdm-xorg при Wayland" grep -q 'gdm-xorg' <<< "$out"
ht_hook install; eq "повтор — 0" 0 "$?"
eq "повтор — дерево то же" "$before" "$(snap)"
ht_hook remove; eq "remove — 0" 0 "$?"
eq "remove — дерево то же" "$before" "$(snap)"

echo "== gdm3 Ubuntu: WaylandEnable закомментирован и false =="
ed_root gdm3-ubuntu
ht_action status; eq "status — 0" 0 "$?"
check "закомментирован — Wayland" grep -q 'WaylandEnable.*закомментирован.*Wayland' <<< "$(ht_out)"
check "автологина нет" grep -q 'автологина нет' <<< "$(ht_out)"
ed_root gdm3-ubuntu
sed -i 's/^#WaylandEnable=false$/WaylandEnable=false/' "$ROOT/etc/gdm3/custom.conf"
ht_action status; eq "status false — 0" 0 "$?"
check "false — Xorg" grep -q 'WaylandEnable.*false.*Xorg' <<< "$(ht_out)"
check_not "false — без подсказки gdm-xorg" grep -q 'gdm-xorg' <<< "$(ht_out)"
ed_root gdm3-ubuntu
sed -i 's/^#WaylandEnable=false$/WaylandEnable=true/' "$ROOT/etc/gdm3/custom.conf"
ht_action status
check "true — Wayland" grep -q 'WaylandEnable.*true.*Wayland' <<< "$(ht_out)"

echo "== gdm3 Debian (daemon.conf, юнит gdm.service) =="
ed_root gdm3-debian
printf 'ActiveSession=\n' > "$FAKE/seat.seat0"
before="$(snap)"
ht_hook install; eq "gdm3 Debian — 0" 0 "$?"
eq "дерево не изменилось" "$before" "$(snap)"
check "менеджер входа gdm3 (gdm.service)" grep -q 'менеджер входа: gdm3' <<< "$(ht_out)"
check "daemon.conf назван" grep -q '/etc/gdm3/daemon.conf' <<< "$(ht_out)"
check "экрана входа нет — seat0 пуст" grep -q 'seat0: активного сеанса нет' <<< "$(ht_out)"

echo "== LightDM: автологин из [Seat:*], без gdm-строк =="
ed_root lightdm
mkdir -p "$ROOT/etc/lightdm/lightdm.conf.d"
printf '[Seat:*]\nautologin-user=carol\n' > "$ROOT/etc/lightdm/lightdm.conf.d/50-auto.conf"
seat0_user carol x11 :0
before="$(snap)"
ht_hook install; eq "LightDM — 0" 0 "$?"
eq "дерево не изменилось" "$before" "$(snap)"
out="$(ht_out)"
check "менеджер входа lightdm" grep -q 'менеджер входа: lightdm' <<< "$out"
check "автологин carol" grep -q 'автологин: carol' <<< "$out"
check "seat0: carol, x11, :0, active" grep -q 'seat0: carol, x11, :0, active' <<< "$out"
check_not "строки WaylandEnable нет" grep -q 'WaylandEnable' <<< "$out"
ed_root lightdm
printf '[LightDM]\nautologin-user=nobody-here\n[Seat:*]\n' > "$ROOT/etc/lightdm/lightdm.conf"
ht_action status
check "autologin-user вне [Seat:*] не считается" grep -q 'автологина нет' <<< "$(ht_out)"

echo "== SDDM: [Autologin] User из /etc/sddm.conf.d и /etc/sddm.conf =="
ed_root sddm
mkdir -p "$ROOT/etc/sddm.conf.d"
printf '[Autologin]\nUser=dave\nSession=plasma\n' > "$ROOT/etc/sddm.conf.d/kde_settings.conf"
before="$(snap)"
ht_hook install; eq "SDDM — 0" 0 "$?"
eq "дерево не изменилось" "$before" "$(snap)"
check "менеджер входа sddm" grep -q 'менеджер входа: sddm' <<< "$(ht_out)"
check "автологин dave" grep -q 'автологин: dave' <<< "$(ht_out)"
printf '[Autologin]\nUser=erin\n' > "$ROOT/etc/sddm.conf"
ht_action status
check "/etc/sddm.conf перекрывает conf.d" grep -q 'автологин: erin' <<< "$(ht_out)"

echo "== экран входа на seat0 =="
ed_root gdm3-ubuntu
seat0_user gdm x11 :0 greeter
ht_action status
check "seat0: экран входа" grep -q 'seat0: экран входа' <<< "$(ht_out)"

echo "== нет logind =="
ed_root gdm3-ubuntu
touch "$FAKE/no-logind"
ht_action status; eq "без logind — 0" 0 "$?"
check "строка «нет logind»" grep -q 'нет logind' <<< "$(ht_out)"

echo "== DM не активен =="
ed_root gdm3-ubuntu
echo inactive > "$FAKE/is-active"
ht_action status
check "is-active inactive" grep -q 'менеджер входа: gdm3 (inactive)' <<< "$(ht_out)"

echo "== build: ни loginctl, ни systemctl =="
ed_root gdm3-ubuntu
seat0_user alice x11 :0
before="$(snap)"
HT_PHASE=build ht_hook install; eq "build — 0" 0 "$?"
check "build — без loginctl и systemctl" no_session_calls
check_not "build — без диагноза seat0" grep -q 'seat0' <<< "$(ht_out)"
eq "build — дерево то же" "$before" "$(snap)"

echo "== xhost нет — ставится x11-xserver-utils (П15) =="
ed_root lightdm
rm -f "$ROOT/usr/bin/xhost"
ht_hook install; eq "без xhost — 0" 0 "$?"
check "apt-get update" ht_called '^apt-get( -q)? update'
check "apt-get install x11-xserver-utils" ht_called '^apt-get install .*--no-install-recommends.* x11-xserver-utils$'
ed_root lightdm
rm -f "$ROOT/usr/bin/xhost"
ht_fake apt-get 'exit 100'
ht_fake sleep
ht_hook install; eq "apt отказал — 1" 1 "$?"
check "причина: x11-xserver-utils" grep -q 'x11-xserver-utils' <<< "$(ht_out)"
eq "apt отказал: три попытки update" 3 "$(grep -c '^apt-get update' "$FAKE/calls")"

echo "== блокировка dpkg занята (unattended-upgrades, packagekit) — ждёт и повторяет (П19) =="
ed_root lightdm
rm -f "$ROOT/usr/bin/xhost"
ht_fake sleep
# Первый install — «Could not get lock», как при чужом apt; второй — успех.
ht_fake apt-get '
if [[ "$*" == *" install "* || "$1" == install ]]; then
    n=$(( $(cat "$FAKE/apt-n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/apt-n"
    if (( n == 1 )); then echo "E: Could not get lock /var/lib/dpkg/lock-frontend" >&2; exit 100; fi
fi
exit 0'
ht_hook install; eq "блокировка: install — 0" 0 "$?"
eq "блокировка: install повторён" 2 "$(grep -c '^apt-get install' "$FAKE/calls")"
check "блокировка: пауза перед повтором" ht_called '^sleep '
check "update ждёт блокировку dpkg" ht_called '^apt-get update .*-o DPkg::Lock::Timeout=120'
check "install ждёт блокировку dpkg" ht_called '^apt-get install .*-o DPkg::Lock::Timeout=120'

echo "== отказы: части стола нет — 1, с причиной и подсказкой =="
ed_root none
before="$(snap)"
ht_hook install; eq "нет DM — 1" 1 "$?"
out="$(ht_out)"
check "причина: нет менеджера входа" grep -q 'нет менеджера входа' <<< "$out"
check "подсказка: сначала cream remove existing-desktop" grep -q 'сначала `cream remove existing-desktop`' <<< "$out"
check_not "отказ — apt не зовётся" ht_called '^apt-get'
eq "отказ — дерево то же" "$before" "$(snap)"
ed_root gdm3-ubuntu
rm -f "$ROOT/usr/lib/xorg/Xorg"
ht_hook install; eq "нет Xorg — 1" 1 "$?"
check "причина: Xorg" grep -q 'нет Xorg' <<< "$(ht_out)"
ed_root gdm3-ubuntu
rm -f "$ROOT/usr/lib/xorg/Xorg"; exe "$ROOT/usr/bin/Xorg"
ht_hook install; eq "Xorg в /usr/bin — 0" 0 "$?"
ed_root gdm3-ubuntu
rm -f "$ROOT/etc/systemd/system/display-manager.service"
ht_hook install; eq "без ссылки юнита, с default-display-manager — 0" 0 "$?"
ed_root gdm3-ubuntu
rm -f "$ROOT/etc/X11/default-display-manager"
ln -sfn /nonexistent.service "$ROOT/etc/systemd/system/display-manager.service"
ht_hook install; eq "битая ссылка display-manager.service — 1" 1 "$?"
ed_root gdm3-ubuntu
rm -f "$ROOT/etc/systemd/system/display-manager.service"
echo /usr/sbin/nodm > "$ROOT/etc/X11/default-display-manager"
ht_hook install; eq "default-display-manager на несуществующий — 1" 1 "$?"
ed_root gdm3-ubuntu
rm -f "$ROOT"/usr/share/xsessions/*.desktop
ht_hook install; eq "нет X-сессии — 1" 1 "$?"
check "причина: xsessions" grep -q 'xsessions' <<< "$(ht_out)"
check_not "без Wayland-сессий — не текст про Wayland" grep -q 'только Wayland' <<< "$(ht_out)"

echo "== только Wayland-сессии — отдельный текст =="
ed_root gdm3-ubuntu
rm -f "$ROOT"/usr/share/xsessions/*.desktop
mkdir -p "$ROOT/usr/share/wayland-sessions"
printf '[Desktop Entry]\nName=Ubuntu\n' > "$ROOT/usr/share/wayland-sessions/ubuntu.desktop"
ht_hook install; eq "только Wayland — 1" 1 "$?"
check "текст: только Wayland-сессии" grep -q 'только Wayland-сессии' <<< "$(ht_out)"

echo "== L4T R32 с рабочим столом вендора =="
ed_root gdm3-ubuntu
printf '%s\n' "$R32" > "$ROOT/etc/nv_tegra_release"
ht_hook install; eq "L4T R32 — 0 (условия R32 нет)" 0 "$?"

echo "== check =="
ed_root gdm3-ubuntu
ht_action check; eq "check: всё на месте — 0" 0 "$?"
check "check — без loginctl и systemctl" no_session_calls
rm -f "$ROOT"/usr/share/xsessions/*.desktop
ht_action check; eq "check: X-сессия не проверяется — 0" 0 "$?"
ed_root none
ht_action check; eq "check: нет DM — 1" 1 "$?"
ed_root lightdm
rm -f "$ROOT/usr/lib/xorg/Xorg"
ht_action check; eq "check: нет Xorg — 1" 1 "$?"

echo "== журнал: имена из машины — данные =="
ed_root lightdm
printf '[Desktop Entry]\n' > "$ROOT/usr/share/xsessions/"$'x\033[31mred.desktop'
printf '[Seat:*]\nautologin-user=ev\033[31mil\n' > "$ROOT/etc/lightdm/lightdm.conf"
ht_hook install; eq "странные имена — 0" 0 "$?"
check_not "в журнале нет управляющих символов" grep -q $'\033' <<< "$(ht_out)"
ht_action status
check_not "в status нет управляющих символов" grep -q $'\033' <<< "$(ht_out)"

ht_done
