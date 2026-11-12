#!/usr/bin/env bash
# H-тесты gdm-xorg (cream/v1, спека 2026-11-12-existing-desktop §4.5, план Task 8):
# хуки на подменённом корне, как их зовёт cream (tools/hooktest.sh). Код правки —
# lib/gdm-wayland.sh (files/gdm-wayland.sh, раскладывает stage-catalog); здесь —
# что делают хуки: четыре исходных состояния строки WaylandEnable в обоих файлах
# gdm3 (Debian — daemon.conf, Ubuntu — custom.conf), нет gdm3 — 20, ссылка вместо
# файла — отказ без записи, побайтный возврат (cmp, режим), код 10 только на
# живой машине и только при изменении, systemctl не зовётся никогда.
#
#   extensions/debian/gdm-xorg/tests/test-gdm-xorg.sh        код 0 — все проверки прошли
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../../tools/hooktest.sh
. "$HERE/../../../../tools/hooktest.sh"
EXT="$(dirname "$HERE")"

ht_init

# Файл, как его кладут пакеты, побайтно: /etc/gdm3/custom.conf из gdm3
# 46.2-1ubuntu1~24.04.9 (Ubuntu 24.04) и /etc/gdm3/daemon.conf из gdm3 43.0-3
# (Debian 12) — одни и те же 554 байта (как в lib/tests/test-gdm-wayland.sh).
package_conf(){
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
# conf_in <state> <file>: файл пакета в состоянии строки WaylandEnable.
conf_in(){
    mkdir -p "$(dirname "$2")"
    package_conf "$2"
    case "$1" in
        absent) sed -i '/^#WaylandEnable=false$/d' "$2" ;;
        commented) ;;
        true) sed -i 's/^#WaylandEnable=false$/WaylandEnable=true/' "$2" ;;
        false) sed -i 's/^#WaylandEnable=false$/WaylandEnable=false/' "$2" ;;
    esac
}
# daemon_wayland <file>: последняя незакомментированная строка WaylandEnable в [daemon].
daemon_wayland(){ awk '/^[[:space:]]*\[/{s=$0} s=="[daemon]" && /^[[:space:]]*WaylandEnable/{v=$0} END{print v}' "$1"; }
# same <a> <b>: побайтно и тот же режим.
same(){ cmp -s -- "$1" "$2" && [[ "$(stat -c %a "$1")" == "$(stat -c %a "$2")" ]]; }

# gdm_root: свежий корень с расширением и подставным systemctl (не должен звониться).
gdm_root(){
    ht_root "$EXT"
    ht_fake systemctl
    GDM="$ROOT/etc/gdm3"
    STATE="$ROOT/var/lib/cream/ext/gdm-xorg/wayland.before"
    ORIG="$ROOT/tmp/orig"
    mkdir -p "$ORIG"
}
no_systemctl(){ ! ht_called '^systemctl'; }

echo "== манифест =="
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "name" gdm-xorg "$(mf 'm["name"]')"
eq "версия" 1.0.0 "$(mf 'm["version"]')"
eq "build: exec" exec "$(mf 'm["targets"]["build"]')"
eq "live: confirm" confirm "$(mf 'm["targets"]["live"]')"
check "live_note называет WaylandEnable=false и cream remove" \
    grep -q 'WaylandEnable=false.*cream remove' <<< "$(mf 'm["targets"]["live_note"]')"
eq "конфликт с gnome" "['gnome']" "$(mf 'm["conflicts"]["extensions"]')"
eq "хуки — install и remove" "['install', 'remove']" "$(mf 'sorted(m["hooks"])')"
eq "ключей нет" "{}" "$(mf '(m.get("config") or {}).get("keys", {})')"
eq "способностей не даёт" "[]" "$(mf 'm.get("provides", [])')"
eq "семейство deb" deb "$(mf 'm["platform"]["family"]')"

echo "== библиотека разложена =="
gdm_root
check "files/gdm-wayland.sh на месте" test -f "$HT_EXT/files/gdm-wayland.sh"
check "install берёт files/gdm-wayland.sh" grep -q 'files/gdm-wayland.sh' "$EXT/hooks/install"
check "remove берёт files/gdm-wayland.sh" grep -q 'files/gdm-wayland.sh' "$EXT/hooks/remove"

echo "== нет gdm3 — 20, ничего не пишется =="
gdm_root
ht_hook install; eq "install без gdm3 — 20" 20 "$?"
check "сказано «не GDM»" grep -q 'не GDM' <<< "$(ht_out)"
check_not "записи нет" test -e "$STATE"
check_not "/etc/gdm3 не создан" test -e "$GDM"
HT_PHASE=build ht_hook install; eq "install без gdm3 в build — 20" 20 "$?"
ht_hook remove; eq "remove без записи — 0" 0 "$?"
check "systemctl не звали" no_systemctl

for file in custom.conf daemon.conf; do
    for st in absent commented true; do
        echo "== $file: $st — live =="
        gdm_root
        conf_in "$st" "$GDM/$file"
        chmod 0640 "$GDM/$file"
        cp -p "$GDM/$file" "$ORIG/$file"
        ht_hook install; eq "$file $st: install в live — 10" 10 "$?"
        eq "$file $st: WaylandEnable=false в [daemon]" WaylandEnable=false "$(daemon_wayland "$GDM/$file")"
        check "$file $st: запись есть" test -s "$STATE"
        check "$file $st: запись помнит $st" grep -qx "state $st" "$STATE"
        check "$file $st: сказано о перезагрузке" grep -q 'перезагруз' <<< "$(ht_out)"
        eq "$file $st: режим сохранён" 640 "$(stat -c %a "$GDM/$file")"
        cp -p "$STATE" "$ORIG/state"
        ht_hook install; eq "$file $st: повтор install — 0" 0 "$?"
        check "$file $st: повтор не переписал запись" same "$STATE" "$ORIG/state"
        ht_hook remove; eq "$file $st: remove в live — 10" 10 "$?"
        check "$file $st: возврат побайтно" same "$GDM/$file" "$ORIG/$file"
        check_not "$file $st: запись снята" test -e "$STATE"
        ht_hook remove; eq "$file $st: повтор remove — 0" 0 "$?"
        check "$file $st: повтор не тронул файл" same "$GDM/$file" "$ORIG/$file"
        check "$file $st: systemctl не звали" no_systemctl

        echo "== $file: $st — build =="
        gdm_root
        conf_in "$st" "$GDM/$file"
        cp -p "$GDM/$file" "$ORIG/$file"
        HT_PHASE=build ht_hook install; eq "$file $st: install в build — 0" 0 "$?"
        eq "$file $st: build — WaylandEnable=false" WaylandEnable=false "$(daemon_wayland "$GDM/$file")"
        HT_PHASE=build ht_hook remove; eq "$file $st: remove в build — 0" 0 "$?"
        check "$file $st: build — возврат побайтно" same "$GDM/$file" "$ORIG/$file"
        check "$file $st: build — systemctl не звали" no_systemctl
    done

    echo "== $file: уже false — 0, ничего не пишется =="
    gdm_root
    conf_in false "$GDM/$file"
    cp -p "$GDM/$file" "$ORIG/$file"
    ht_hook install; eq "$file false: install — 0" 0 "$?"
    check "$file false: файл не тронут" same "$GDM/$file" "$ORIG/$file"
    check "$file false: в записи «было false»" grep -qx 'state false' "$STATE"
    check "$file false: в записи — ничего не меняли" grep -qx 'op none' "$STATE"
    ht_hook remove; eq "$file false: remove — 0" 0 "$?"
    check "$file false: после remove файл тот же" same "$GDM/$file" "$ORIG/$file"
    check_not "$file false: запись снята" test -e "$STATE"
    check "$file false: systemctl не звали" no_systemctl
done

echo "== оба файла: daemon.conf true, custom.conf закомментирован =="
gdm_root
conf_in true "$GDM/daemon.conf"
conf_in commented "$GDM/custom.conf"
cp -p "$GDM/daemon.conf" "$GDM/custom.conf" "$ORIG/"
ht_hook install; eq "оба: install — 10" 10 "$?"
eq "оба: daemon.conf — false" WaylandEnable=false "$(daemon_wayland "$GDM/daemon.conf")"
eq "оба: custom.conf — false" WaylandEnable=false "$(daemon_wayland "$GDM/custom.conf")"
ht_hook remove; eq "оба: remove — 10" 10 "$?"
check "оба: daemon.conf побайтно" same "$GDM/daemon.conf" "$ORIG/daemon.conf"
check "оба: custom.conf побайтно" same "$GDM/custom.conf" "$ORIG/custom.conf"

echo "== ссылка вместо файла — отказ, ничего не пишется =="
gdm_root
conf_in true "$ROOT/srv/real.conf"
cp -p "$ROOT/srv/real.conf" "$ORIG/real.conf"
mkdir -p "$GDM"
ln -s ../../srv/real.conf "$GDM/custom.conf"
ht_hook install; eq "ссылка: install — 1" 1 "$?"
check "ссылка: цель не тронута" same "$ROOT/srv/real.conf" "$ORIG/real.conf"
check "ссылка: всё ещё ссылка" test -L "$GDM/custom.conf"
check_not "ссылка: записи нет" test -s "$STATE"
check "ссылка: сказано «ссылка»" grep -q 'ссылка' <<< "$(ht_out)"
check "ссылка: systemctl не звали" no_systemctl

echo "== remove: запись не своя — отказ, файл не тронут =="
gdm_root
conf_in true "$GDM/custom.conf"
cp -p "$GDM/custom.conf" "$ORIG/custom.conf"
printf 'garbage\n' > "$STATE"
ht_hook remove; eq "чужая запись: remove — 1" 1 "$?"
check "чужая запись: файл не тронут" same "$GDM/custom.conf" "$ORIG/custom.conf"
check "чужая запись: запись оставлена" test -e "$STATE"

ht_done
