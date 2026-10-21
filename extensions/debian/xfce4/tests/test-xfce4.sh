#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the xfce4 extension (cream/v1): manifest, hooks install and remove on
# a scratch root (CREAM_ROOT) the way cream runs them. apt-get and systemctl are
# fakes: systemctl keeps the default target in $FAKE/default and the
# display-manager.service alias as a real link under the root. root, systemd,
# apt and a display manager are not needed.
#
#   extensions/debian/xfce4/tests/test-xfce4.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

NAME=xfce4
SESSION=xfce
PKGS='xfce4 xfce4-goodies lightdm lightdm-gtk-greeter'

# fresh: a root with fakes. $FAKE/default — what get-default answers
# (multi-user.target unless a test says otherwise); $FAKE/apt-fail — the main
# apt-get install fails; $FAKE/no-browser — no browser package installs.
fresh() {
    ht_root "$EXT"
    SYSD="$ROOT/etc/systemd/system"
    STATE="$ROOT/var/lib/cream/ext/$NAME"
    LCONF="$ROOT/etc/lightdm/lightdm.conf"
    mkdir -p "$SYSD"
    echo multi-user.target > "$FAKE/default"
    ht_fake apt-get '
if [[ " $* " == *" install "* ]]; then
    case " $* " in
        *" firefox-esr "*|*" firefox "*) [[ -f "$FAKE/no-browser" ]] && exit 100 ;;
        *) [[ -f "$FAKE/apt-fail" ]] && exit 100 ;;
    esac
fi
exit 0'
    ht_fake systemctl '
sysd="'"$SYSD"'"
case "$1" in
    get-default) cat "$FAKE/default" ;;
    set-default) echo "$2" > "$FAKE/default" ;;
    enable)
        if [[ -L "$sysd/display-manager.service" && "$(readlink "$sysd/display-manager.service")" != */"$2" ]]; then
            echo "Failed to enable unit: display-manager.service already exists" >&2; exit 1
        fi
        ln -sfn "/lib/systemd/system/$2" "$sysd/display-manager.service" ;;
    disable)
        [[ "$(readlink "$sysd/display-manager.service" 2>/dev/null)" == */"$2" ]] && rm -f "$sysd/display-manager.service"
        exit 0 ;;
esac
exit 0'
    ht_fake sleep
}
dm_link() { readlink "$SYSD/display-manager.service" 2>/dev/null; }

echo "== манифест =="
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 5" 5.0.1 "$(mf 'm["version"]')"
eq "cream >= 1.0.0" '>=1.0.0' "$(mf 'm["cream"]')"
eq "build: exec" exec "$(mf 'm["targets"]["build"]')"
eq "live: confirm" confirm "$(mf 'm["targets"]["live"]')"
check "live_note про менеджер входа" grep -q 'менеджер входа' <<< "$(mf 'm["targets"]["live_note"]')"
eq "depends desktop" "desktop" "$(mf '",".join(d["name"] for d in m["depends"])')"
eq "conflicts по способности desktop-session" "{'capabilities': ['desktop-session']}" "$(mf 'm["conflicts"]')"
eq "provides без изменений" "['x11-server', 'display-manager', 'desktop-session']" "$(mf 'm["provides"]')"
eq "хуки install и remove, без configure" "['install', 'remove']" "$(mf 'sorted(m["hooks"])')"
eq "платформа: debian и ubuntu" "['debian', 'ubuntu']" "$(mf 'sorted(o["id"] for o in m["platform"]["os"])')"
eq "files: сессия lightdm drop-in'ом" "/etc/xdg/lightdm/lightdm.conf.d/60-$NAME.conf" "$(mf '",".join(f["dst"] for f in m["files"])')"
src="$EXT/$(mf 'm["files"][0]["src"]')"
check "files: src есть" test -f "$src"
check "сессия $SESSION в drop-in" grep -qx "user-session=$SESSION" "$src"
check "приветствие gtk в drop-in" grep -qx 'greeter-session=lightdm-gtk-greeter' "$src"
check "drop-in в секции Seat:*" grep -qx '\[Seat:\*\]' "$src"
check_not "drop-in без автологина (его пишет desktop)" grep -q "^autologin" "$src"
for old in install.sh lightdm.conf; do check_not "layout 2: $old убран" test -e "$EXT/$old"; done

echo "== install: живая машина, multi-user, lightdm.conf нет (Ubuntu) =="
fresh
ht_hook install; eq "install — 10 (перезагрузка)" 10 "$?"
check "apt-get update" ht_called '^apt-get .*update'
for p in $PKGS xorg xinput x11-xserver-utils dconf-cli; do
    check "ставит $p" grep -qE "^apt-get .*install( .*)? $p( |\$)" "$FAKE/calls"
done
check "firefox-esr пробуется" ht_called '^apt-get .*install .*firefox-esr'
check_not "firefox (переходник на snap в Ubuntu) не пробуется" grep -qE '^apt-get .*install .* firefox( |$)' "$FAKE/calls"
check "lightdm включён" ht_called '^systemctl enable lightdm.service'
eq "display-manager → lightdm" /lib/systemd/system/lightdm.service "$(dm_link)"
eq "default: graphical.target" graphical.target "$(cat "$FAKE/default")"
check "xorg.conf.d есть" test -d "$ROOT/etc/X11/xorg.conf.d"
check "lightdm.conf создан для ручек desktop" grep -qx '\[Seat:\*\]' "$LCONF"
check_not "lightdm.conf без сессии (она в drop-in)" grep -q 'user-session' "$LCONF"
eq "lightdm.conf 0644" 644 "$(stat -c %a "$LCONF")"
check "состояние: прежний default" grep -qx 'default=multi-user.target' "$STATE/before"
check "состояние: менеджера входа не было" grep -qx 'dm=' "$STATE/before"
check "состояние: lightdm.conf создан нами" test -f "$STATE/created-lightdm-conf"
check_not "xdg drop-in хук не пишет (его раскладывает cream)" test -e "$ROOT/etc/xdg/lightdm/lightdm.conf.d/60-$NAME.conf"

echo "== повтор install: ничего не меняется =="
sum1="$(sha256sum "$LCONF" "$STATE/before")"
: > "$FAKE/calls"
ht_hook install; eq "повтор — 0" 0 "$?"
check_not "повтор: set-default не звали" ht_called '^systemctl set-default'
eq "повтор: lightdm.conf и состояние те же" "$sum1" "$(sha256sum "$LCONF" "$STATE/before")"

echo "== install: сборка — 0 и при смене default =="
fresh
HT_PHASE=build ht_hook install; eq "build — 0" 0 "$?"
eq "build: default graphical" graphical.target "$(cat "$FAKE/default")"

echo "== install: уже graphical и lightdm включён до нас =="
fresh
echo graphical.target > "$FAKE/default"
ln -s /lib/systemd/system/lightdm.service "$SYSD/display-manager.service"
mkdir -p "$ROOT/etc/lightdm"; printf '[Seat:*]\n#autologin-user=\n' > "$LCONF"
before="$(sha256sum "$LCONF")"
ht_hook install; eq "install — 0 (перезагрузка не нужна)" 0 "$?"
check_not "set-default не звали" ht_called '^systemctl set-default'
eq "lightdm.conf пакета не тронут" "$before" "$(sha256sum "$LCONF")"
check_not "lightdm.conf не помечен как наш" test -e "$STATE/created-lightdm-conf"
check "состояние: lightdm был" grep -qx 'dm=lightdm.service' "$STATE/before"

echo "== install: другой менеджер входа занят =="
fresh
ln -s /lib/systemd/system/gdm.service "$SYSD/display-manager.service"
ht_hook install; rc=$?
eq "install — 10, не отказ" 10 "$rc"
eq "чужой display-manager не перехвачен" /lib/systemd/system/gdm.service "$(dm_link)"
check "предупреждение про gdm" grep -q 'gdm.service' <(ht_out)

echo "== install: lightdm.conf — ссылка, по ней не пишем =="
fresh
mkdir -p "$ROOT/etc/lightdm" "$ROOT/outside"
ln -s "$ROOT/outside/target.conf" "$LCONF"
ht_hook install; eq "install — 10" 10 "$?"
check_not "по ссылке ничего не записано" test -e "$ROOT/outside/target.conf"
check "ссылка осталась ссылкой" test -L "$LCONF"
check "предупреждение про ссылку" grep -q 'ссылка' <(ht_out)

echo "== install: сбои apt =="
fresh
: > "$FAKE/no-browser"
ht_hook install; eq "без браузера — всё равно 10" 10 "$?"
check "предупреждение про браузер" grep -qi 'браузер' <(ht_out)
fresh
: > "$FAKE/apt-fail"
ht_hook install; rc=$?
check "основной apt упал — отказ (не 0, не 10)" test "$rc" -ne 0 -a "$rc" -ne 10
check_not "после отказа apt default не тронут" grep -qx graphical.target "$FAKE/default"

echo "== remove: возвращает как было =="
fresh
ht_hook install >/dev/null
: > "$FAKE/calls"
ht_hook remove; eq "remove — 10 (default меняется)" 10 "$?"
eq "default снова multi-user" multi-user.target "$(cat "$FAKE/default")"
check "lightdm выключен" ht_called '^systemctl disable lightdm.service'
check_not "display-manager снят" test -L "$SYSD/display-manager.service"
check_not "созданный нами lightdm.conf снят" test -e "$LCONF"
check_not "состояние снято" test -e "$STATE/before"
check_not "apt-get remove не зовётся: пакеты остаются" ht_called '^apt-get'
: > "$FAKE/calls"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
check_not "повтор remove: systemctl не звали" ht_called '^systemctl (set-default|disable)'

echo "== remove: было graphical и lightdm до нас — не трогает =="
fresh
echo graphical.target > "$FAKE/default"
ln -s /lib/systemd/system/lightdm.service "$SYSD/display-manager.service"
mkdir -p "$ROOT/etc/lightdm"; printf '[Seat:*]\n' > "$LCONF"
ht_hook install >/dev/null
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "set-default не звали" ht_called '^systemctl set-default'
check_not "lightdm не выключен" ht_called '^systemctl disable'
check "lightdm.conf пакета на месте" test -f "$LCONF"

echo "== remove: испорченное состояние не исполняется =="
fresh
ht_hook install >/dev/null
printf 'default=x.target; touch %s/pwned\ndm=$(touch %s/pwned2)\n' "$ROOT" "$ROOT" > "$STATE/before"
ht_hook remove; rc=$?
check "remove не падает с синтаксисом" test "$rc" -eq 0 -o "$rc" -eq 10
check_not "значение из состояния не исполнено" test -e "$ROOT/pwned"
check_not "подстановка из состояния не исполнена" test -e "$ROOT/pwned2"
eq "негодный default заменён на multi-user" multi-user.target "$(cat "$FAKE/default")"
check "предупреждение про негодное значение" grep -q 'негодн' <(ht_out)

ht_done
