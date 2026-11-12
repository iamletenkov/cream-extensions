#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the gnome extension (cream/v1): manifest, hooks install and remove on
# a scratch root (CREAM_ROOT) the way cream runs them. The gdm3 configs are
# fixtures as the packages ship them (Debian 13/12 — daemon.conf, Ubuntu —
# custom.conf); apt-get and systemctl are fakes: systemctl keeps the default
# target in $FAKE/default and the display-manager.service alias as a real link
# under the root. root, systemd, apt and gdm are not needed.
#
#   extensions/debian/gnome/tests/test-gnome.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

NAME=gnome

# fresh: a root with fakes; WB — the record of lib/gdm-wayland.sh. $FAKE/default — what get-default answers
# (multi-user.target unless a test says otherwise); $FAKE/apt-fail — the main
# apt-get install fails; $FAKE/no-browser — chromium does not install.
fresh() {
    ht_root "$EXT"
    SYSD="$ROOT/etc/systemd/system"
    STATE="$ROOT/var/lib/cream/ext/$NAME"
    GDM="$ROOT/etc/gdm3"
    WB="$STATE/wayland.before"
    ORIG="$ROOT/tmp/orig"
    mkdir -p "$SYSD" "$GDM" "$ORIG"
    echo multi-user.target > "$FAKE/default"
    ht_fake apt-get '
if [[ " $* " == *" install "* ]]; then
    case " $* " in
        *" chromium "*) [[ -f "$FAKE/no-browser" ]] && exit 100 ;;
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
# Fixtures: the [daemon] section as gdm3 ships it.
debian_conf() {
    printf '%s\n' '# GDM configuration storage' '' '[daemon]' \
        '# Uncomment the line below to force the login screen to use Xorg' '#WaylandEnable=false' '' \
        '# Enabling automatic login' '#  AutomaticLoginEnable = true' '#  AutomaticLogin = user1' '' \
        '[security]' '' '[xdmcp]' '' '[chooser]' '' '[debug]' '#Enable=true' > "$1"
}
# wayland_in <file>: the WaylandEnable line that counts — the last uncommented
# one of the [daemon] section.
wayland_in() {
    awk '/^[[:space:]]*\[/{s=$0} s=="[daemon]" && /^[[:space:]]*WaylandEnable/{v=$0} END{print v}' "$1"
}
# package_conf <file> [absent|commented|true|false]: the 554 bytes of gdm3 as
# the packages ship them (custom.conf of Ubuntu 24.04, daemon.conf of Debian 12
# — the same text, lib/tests/test-gdm-wayland.sh), the WaylandEnable line in
# the given state (commented — as shipped).
package_conf() {
    mkdir -p "$(dirname "$1")"
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
    case "${2:-commented}" in
        absent) sed -i '/^#WaylandEnable=false$/d' "$1" ;;
        true) sed -i 's/^#WaylandEnable=false$/WaylandEnable=true/' "$1" ;;
        false) sed -i 's/^#WaylandEnable=false$/WaylandEnable=false/' "$1" ;;
    esac
}
# same <a> <b>: byte for byte and the same mode.
same() { cmp -s -- "$1" "$2" && [[ "$(stat -c %a "$1")" == "$(stat -c %a "$2")" ]]; }

echo "== манифест =="
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "версия 5.1.0" 5.1.0 "$(mf 'm["version"]')"
eq "desktop <3 (desktop 2.0.0)" ">=1.0.0 <3" "$(mf 'next(d["version"] for d in m["depends"] if d["name"] == "desktop")')"
eq "cream >= 1.0.0" '>=1.0.0' "$(mf 'm["cream"]')"
eq "build: exec" exec "$(mf 'm["targets"]["build"]')"
eq "live: confirm" confirm "$(mf 'm["targets"]["live"]')"
check "live_note про менеджер входа" grep -q 'менеджер входа' <<< "$(mf 'm["targets"]["live_note"]')"
eq "depends desktop" "desktop" "$(mf '",".join(d["name"] for d in m["depends"])')"
eq "conflicts: способность desktop-session и gdm-xorg" \
    "{'capabilities': ['desktop-session'], 'extensions': ['gdm-xorg']}" "$(mf 'm["conflicts"]')"
eq "provides без изменений" "['x11-server', 'display-manager', 'desktop-session']" "$(mf 'm["provides"]')"
eq "хуки install и remove, без configure" "['install', 'remove']" "$(mf 'sorted(m["hooks"])')"
eq "платформа: debian и ubuntu" "['debian', 'ubuntu']" "$(mf 'sorted(o["id"] for o in m["platform"]["os"])')"
eq "files нет: конфиги gdm3 — conffile пакета" None "$(mf 'm.get("files")')"
for old in install.sh daemon.conf; do check_not "layout 2: $old убран" test -e "$EXT/$old"; done

echo "== библиотека gdm-wayland разложена =="
fresh
check "files/gdm-wayland.sh на месте" test -f "$HT_EXT/files/gdm-wayland.sh"
check "install берёт files/gdm-wayland.sh" grep -q 'files/gdm-wayland.sh' "$EXT/hooks/install"
check "remove берёт files/gdm-wayland.sh" grep -q 'files/gdm-wayland.sh' "$EXT/hooks/remove"
check "gnome в lib/gdm-wayland.consumers" grep -qx 'debian/gnome' "$EXT/../../../lib/gdm-wayland.consumers"

echo "== install: Debian, daemon.conf пакета =="
fresh
debian_conf "$GDM/daemon.conf"
chmod 0644 "$GDM/daemon.conf"
ht_hook install; eq "install — 10 (перезагрузка)" 10 "$?"
check "apt-get update" ht_called '^apt-get .*update'
for p in task-gnome-desktop gdm3 gnome-shell gnome-session xorg xinput x11-xserver-utils dconf-cli; do
    check "ставит $p" grep -qE "^apt-get .*install( .*)? $p( |\$)" "$FAKE/calls"
done
check "chromium пробуется" grep -qE '^apt-get .*install chromium$' "$FAKE/calls"
check_not "chromium-browser (переходник на snap) не пробуется" ht_called 'chromium-browser'
eq "Wayland выключен в [daemon]" "WaylandEnable=false" "$(wayland_in "$GDM/daemon.conf")"
check "запись прежнего: закомментирован" grep -qx 'state commented' "$WB"
check "прочие строки пакета на месте" grep -qxF '#  AutomaticLogin = user1' "$GDM/daemon.conf"
check "секция [debug] на месте" grep -qx '\[debug\]' "$GDM/daemon.conf"
eq "режим 0644 сохранён" 644 "$(stat -c %a "$GDM/daemon.conf")"
check_not "custom.conf не создаётся" test -e "$GDM/custom.conf"
check "gdm включён" ht_called '^systemctl enable gdm'
check "display-manager → gdm" grep -qE '/gdm3?\.service$' <<< "$(dm_link)"
eq "default: graphical.target" graphical.target "$(cat "$FAKE/default")"
check "xorg.conf.d есть" test -d "$ROOT/etc/X11/xorg.conf.d"
check "состояние: прежний default" grep -qx 'default=multi-user.target' "$STATE/before"
check "состояние: менеджера входа не было" grep -qx 'dm=' "$STATE/before"

echo "== повтор install: ничего не меняется =="
sum1="$(sha256sum "$GDM/daemon.conf" "$STATE/before")"
ino1="$(stat -c %i "$GDM/daemon.conf")"
: > "$FAKE/calls"
ht_hook install; eq "повтор — 0" 0 "$?"
check_not "повтор: set-default не звали" ht_called '^systemctl set-default'
eq "повтор: daemon.conf и состояние те же" "$sum1" "$(sha256sum "$GDM/daemon.conf" "$STATE/before")"
eq "повтор: daemon.conf не перезаписан" "$ino1" "$(stat -c %i "$GDM/daemon.conf")"

echo "== install: Ubuntu, custom.conf; ключ уже включён, раскомментирован =="
fresh
printf '%s\n' '[daemon]' 'WaylandEnable=true' 'AutomaticLoginEnable=false' '' '[security]' 'WaylandEnable=keep' > "$GDM/custom.conf"
ht_hook install; eq "install — 10" 10 "$?"
eq "true → false в [daemon]" "WaylandEnable=false" "$(wayland_in "$GDM/custom.conf")"
check "ключ чужой секции не тронут" grep -qx 'WaylandEnable=keep' "$GDM/custom.conf"
check_not "daemon.conf не создаётся" test -e "$GDM/daemon.conf"

echo "== install: секции [daemon] нет — дописывается =="
fresh
printf '%s\n' '[security]' > "$GDM/custom.conf"
ht_hook install; eq "install — 10" 10 "$?"
eq "[daemon] дописана" "WaylandEnable=false" "$(wayland_in "$GDM/custom.conf")"

echo "== install: оба файла — правит оба =="
fresh
debian_conf "$GDM/daemon.conf"; debian_conf "$GDM/custom.conf"
ht_hook install; eq "install — 10" 10 "$?"
eq "daemon.conf" "WaylandEnable=false" "$(wayland_in "$GDM/daemon.conf")"
eq "custom.conf" "WaylandEnable=false" "$(wayland_in "$GDM/custom.conf")"

echo "== install: конфига gdm3 нет — отказ =="
fresh
ht_hook install; rc=$?
check "без конфига gdm3 — отказ (не 0, не 10)" test "$rc" -ne 0 -a "$rc" -ne 10
check "сообщение про Wayland" grep -q 'Wayland' <(ht_out)

echo "== install: конфиг — ссылка: отказ до любой записи (lib/gdm-wayland.sh) =="
fresh
mkdir -p "$ROOT/outside"
debian_conf "$ROOT/outside/daemon.conf"
before="$(sha256sum "$ROOT/outside/daemon.conf")"
ln -s "$ROOT/outside/daemon.conf" "$GDM/daemon.conf"
debian_conf "$GDM/custom.conf"
cp -p "$GDM/custom.conf" "$ORIG/custom.conf"
ht_hook install; eq "ссылка рядом с обычным файлом — 1" 1 "$?"
eq "цель ссылки не тронута" "$before" "$(sha256sum "$ROOT/outside/daemon.conf")"
check "ссылка осталась ссылкой" test -L "$GDM/daemon.conf"
check "сказано про ссылку" grep -q 'ссылка' <(ht_out)
check "custom.conf не тронут" same "$GDM/custom.conf" "$ORIG/custom.conf"
check_not "записи прежнего нет" test -s "$WB"
check_not "gdm не включали" ht_called '^systemctl enable'
eq "default не тронут" multi-user.target "$(cat "$FAKE/default")"
fresh
mkdir -p "$ROOT/outside"; debian_conf "$ROOT/outside/daemon.conf"
ln -s "$ROOT/outside/daemon.conf" "$GDM/daemon.conf"
ht_hook install; rc=$?
check "только ссылка — отказ: Wayland не выключен" test "$rc" -ne 0 -a "$rc" -ne 10

echo "== install: уже graphical и gdm включён до нас, WaylandEnable меняется — 10 =="
fresh
debian_conf "$GDM/daemon.conf"
echo graphical.target > "$FAKE/default"
ln -s /lib/systemd/system/gdm.service "$SYSD/display-manager.service"
ht_hook install; eq "install — 10 (WaylandEnable изменился, gdm читает его на старте)" 10 "$?"
check_not "set-default не звали" ht_called '^systemctl set-default'
check "состояние: gdm был" grep -qx 'dm=gdm.service' "$STATE/before"
check "сказано о перезагрузке" grep -q 'перезагруз' <(ht_out)

echo "== install: уже graphical, gdm и false до нас — 0 =="
fresh
package_conf "$GDM/custom.conf" false
cp -p "$GDM/custom.conf" "$ORIG/custom.conf"
echo graphical.target > "$FAKE/default"
ln -s /lib/systemd/system/gdm.service "$SYSD/display-manager.service"
ht_hook install; eq "install — 0 (перезагрузка не нужна)" 0 "$?"
check "custom.conf не тронут" same "$GDM/custom.conf" "$ORIG/custom.conf"
check "запись: было false, ничего не меняли" grep -qx 'op none' "$WB"

echo "== install: другой менеджер входа занят =="
fresh
debian_conf "$GDM/daemon.conf"
ln -s /lib/systemd/system/lightdm.service "$SYSD/display-manager.service"
ht_hook install; eq "install — 10, не отказ" 10 "$?"
eq "чужой display-manager не перехвачен" /lib/systemd/system/lightdm.service "$(dm_link)"
check "предупреждение про lightdm" grep -q 'lightdm.service' <(ht_out)

echo "== install: сбои apt =="
fresh
debian_conf "$GDM/daemon.conf"
: > "$FAKE/no-browser"
ht_hook install; eq "без браузера — всё равно 10" 10 "$?"
check "предупреждение про браузер" grep -qi 'браузер' <(ht_out)
fresh
debian_conf "$GDM/daemon.conf"
: > "$FAKE/apt-fail"
ht_hook install; rc=$?
check "основной apt упал — отказ (не 0, не 10)" test "$rc" -ne 0 -a "$rc" -ne 10
check_not "после отказа apt default не тронут" grep -qx graphical.target "$FAKE/default"

echo "== remove: возвращает как было =="
fresh
debian_conf "$GDM/daemon.conf"
cp -p "$GDM/daemon.conf" "$ORIG/daemon.conf"
ht_hook install >/dev/null
: > "$FAKE/calls"
ht_hook remove; eq "remove — 10 (default меняется)" 10 "$?"
check "daemon.conf побайтно как до install" same "$GDM/daemon.conf" "$ORIG/daemon.conf"
check_not "запись WaylandEnable снята" test -e "$WB"
eq "default снова multi-user" multi-user.target "$(cat "$FAKE/default")"
check "gdm выключен" ht_called '^systemctl disable gdm'
check_not "display-manager снят" test -L "$SYSD/display-manager.service"
check_not "состояние снято" test -e "$STATE/before"
check_not "apt-get remove не зовётся: пакеты остаются" ht_called '^apt-get'
: > "$FAKE/calls"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
check_not "повтор remove: systemctl не звали" ht_called '^systemctl (set-default|disable)'

echo "== remove: было graphical и gdm до нас — цель и gdm не трогает, WaylandEnable — 10 =="
fresh
debian_conf "$GDM/daemon.conf"
cp -p "$GDM/daemon.conf" "$ORIG/daemon.conf"
echo graphical.target > "$FAKE/default"
ln -s /lib/systemd/system/gdm.service "$SYSD/display-manager.service"
ht_hook install >/dev/null
: > "$FAKE/calls"
ht_hook remove; eq "remove — 10 (WaylandEnable вернулся)" 10 "$?"
check_not "set-default не звали" ht_called '^systemctl set-default'
check_not "gdm не выключен" ht_called '^systemctl disable'
check "daemon.conf побайтно" same "$GDM/daemon.conf" "$ORIG/daemon.conf"
HT_PHASE=build ht_hook install >/dev/null
HT_PHASE=build ht_hook remove; eq "то же в build — 0" 0 "$?"
check "build: daemon.conf побайтно" same "$GDM/daemon.conf" "$ORIG/daemon.conf"

echo "== remove: было graphical, gdm и false до нас — 0, файл тот же =="
fresh
package_conf "$GDM/daemon.conf" false
cp -p "$GDM/daemon.conf" "$ORIG/daemon.conf"
echo graphical.target > "$FAKE/default"
ln -s /lib/systemd/system/gdm.service "$SYSD/display-manager.service"
ht_hook install >/dev/null
ht_hook remove; eq "remove — 0" 0 "$?"
check "daemon.conf тот же" same "$GDM/daemon.conf" "$ORIG/daemon.conf"

for file in custom.conf daemon.conf; do
    for st in absent commented true; do
        echo "== $file: $st — install, remove побайтно =="
        fresh
        package_conf "$GDM/$file" "$st"
        chmod 0640 "$GDM/$file"
        cp -p "$GDM/$file" "$ORIG/$file"
        echo graphical.target > "$FAKE/default"
        ln -s /lib/systemd/system/gdm.service "$SYSD/display-manager.service"
        ht_hook install; eq "$file $st: install в live — 10 (только WaylandEnable)" 10 "$?"
        eq "$file $st: WaylandEnable=false" WaylandEnable=false "$(wayland_in "$GDM/$file")"
        check "$file $st: запись помнит $st" grep -qx "state $st" "$WB"
        eq "$file $st: режим сохранён" 640 "$(stat -c %a "$GDM/$file")"
        cp -p "$WB" "$ORIG/wb"
        ht_hook install; eq "$file $st: повтор install — 0" 0 "$?"
        check "$file $st: повтор не переписал запись" same "$WB" "$ORIG/wb"
        ht_hook remove; eq "$file $st: remove — 10" 10 "$?"
        check "$file $st: возврат побайтно" same "$GDM/$file" "$ORIG/$file"
        check_not "$file $st: запись снята" test -e "$WB"
    done
    echo "== $file: false — install 0, remove 0, файл тот же =="
    fresh
    package_conf "$GDM/$file" false
    cp -p "$GDM/$file" "$ORIG/$file"
    echo graphical.target > "$FAKE/default"
    ln -s /lib/systemd/system/gdm.service "$SYSD/display-manager.service"
    ht_hook install; eq "$file false: install — 0" 0 "$?"
    check "$file false: запись помнит false" grep -qx "state false" "$WB"
    ht_hook remove; eq "$file false: remove — 0" 0 "$?"
    check "$file false: файл тот же" same "$GDM/$file" "$ORIG/$file"
done

echo "== remove: установка 5.0.x (записи WaylandEnable нет) — строка остаётся =="
fresh
package_conf "$GDM/custom.conf" commented
ht_hook install >/dev/null
rm -f -- "$WB"
cp -p "$GDM/custom.conf" "$ORIG/custom.conf"
ht_hook remove; eq "remove — 10 (default меняется)" 10 "$?"
check "custom.conf тот же: WaylandEnable=false остаётся" same "$GDM/custom.conf" "$ORIG/custom.conf"
eq "строка false на месте" WaylandEnable=false "$(wayland_in "$GDM/custom.conf")"

echo "== обновление 5.0.x → 5.1.0: install при false от 5.0.x — remove оставляет false =="
fresh
package_conf "$GDM/custom.conf" false
echo graphical.target > "$FAKE/default"
ln -s /lib/systemd/system/gdm.service "$SYSD/display-manager.service"
printf 'default=multi-user.target\ndm=\n' > "$STATE/before"
ht_hook install; eq "install при обновлении — 0 (ничего не меняется)" 0 "$?"
check "запись: было false" grep -qx 'state false' "$WB"
cp -p "$GDM/custom.conf" "$ORIG/custom.conf"
ht_hook remove >/dev/null
check "после remove false остаётся" same "$GDM/custom.conf" "$ORIG/custom.conf"

echo "== remove: запись WaylandEnable не своя — отказ, ничего не тронуто =="
fresh
package_conf "$GDM/custom.conf" false
ht_hook install >/dev/null
printf 'garbage\n' > "$WB"
cp -p "$GDM/custom.conf" "$ORIG/custom.conf"
: > "$FAKE/calls"
ht_hook remove; eq "чужая запись — 1" 1 "$?"
check "custom.conf не тронут" same "$GDM/custom.conf" "$ORIG/custom.conf"
check "запись оставлена" test -e "$WB"
check "состояние before оставлено" test -e "$STATE/before"
check_not "systemctl не звали" ht_called '^systemctl (set-default|disable)'

echo "== remove: испорченное состояние не исполняется =="
fresh
debian_conf "$GDM/daemon.conf"
ht_hook install >/dev/null
printf 'default=x.target; touch %s/pwned\ndm=$(touch %s/pwned2)\n' "$ROOT" "$ROOT" > "$STATE/before"
ht_hook remove; rc=$?
check "remove не падает с синтаксисом" test "$rc" -eq 0 -o "$rc" -eq 10
check_not "значение из состояния не исполнено" test -e "$ROOT/pwned"
check_not "подстановка из состояния не исполнена" test -e "$ROOT/pwned2"
eq "негодный default заменён на multi-user" multi-user.target "$(cat "$FAKE/default")"
check "предупреждение про негодное значение" grep -q 'негодн' <(ht_out)

ht_done
