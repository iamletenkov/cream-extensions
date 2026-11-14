#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the desktop extension (cream/v1): manifest, hooks install, configure
# and remove, actions apply, status and defaults on a scratch root (CREAM_ROOT)
# the way cream runs them. gdm3 (daemon.conf, custom.conf), lightdm (Seat:*,
# SeatDefaults), xfconf and lxsession are fixture files; getent, id, usermod,
# systemctl, loginctl, dconf, chown, sleep and cream are fakes, the cloud-user
# library is a stub. root, systemd and a display manager are not needed.
#
#   extensions/debian/desktop/tests/test-desktop.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

# desk_root: fresh root; passwd/group of the fakes in $FAKE; user alice (home
# /home/alice) from the cloud-user library stub ($FAKE/user).
desk_root() {
    ht_root "$EXT"
    mkdir -p "$ROOT/etc" "$ROOT/home/alice" "$ROOT/home/bob"
    printf '%s\n' 'alice:x:1000:1000::/home/alice:/bin/bash' 'bob:x:1001:1001::/home/bob:/bin/bash' > "$FAKE/passwd"
    printf '%s\n' 'video:x:44:' 'audio:x:29:' 'plugdev:x:46:alice' 'alice:x:1000:' 'bob:x:1001:' > "$FAKE/group"
    echo alice > "$FAKE/user"
    ht_fake getent '
db="$1"; key="${2-}"
f="$FAKE/$db"
[[ -f "$f" ]] || exit 2
if [[ -z "$key" ]]; then cat "$f"; exit 0; fi
grep -E "^${key}:" "$f" || exit 2'
    ht_fake id '
if [[ "$1" == -nG ]]; then
    u="$2"; out="$u"
    while IFS=: read -r g _ _ m; do
        [[ "$g" == "$u" ]] && continue
        [[ ",$m," == *",$u,"* ]] && out="$out $g"
    done < "$FAKE/group"
    echo "$out"; exit 0
fi
[[ "$1" == -u ]] && shift
grep -qE "^$1:" "$FAKE/passwd"'
    ht_fake usermod '
[[ "$1" == -aG ]] || exit 2
g="$2"; u="$3"
awk -F: -v OFS=: -v g="$g" -v u="$u" "\$1 == g { \$4 = (\$4 == \"\" ? u : \$4 \",\" u) } { print }" "$FAKE/group" > "$FAKE/group.new"
mv "$FAKE/group.new" "$FAKE/group"'
    ht_fake systemctl '
if [[ "$1" == is-active ]]; then
    for a in "$@"; do [[ -e "$FAKE/active-${a%.service}" ]] && exit 0; done
    exit 3
fi
exit 0'
    ht_fake loginctl '
case "$1" in
    list-sessions) [[ -e "$FAKE/session" ]] && echo "2 1000 alice seat0 tty2" ;;
    show-session) case "$*" in *Class*) echo user ;; *Type*) echo x11 ;; esac ;;
esac
exit 0'
    ht_fake chown
    # runuser: the tests cannot drop privileges — the fake logs the user and runs
    # the command as is (the caller of the hook is not root anyway).
    # It also records whether the lock descriptor of cream (fd 9 in the tests)
    # reached it and what its stdin is; $FAKE/runuser-fails makes it fail.
    ht_fake runuser '
if [[ -e /proc/$$/fd/9 ]]; then echo open; else echo closed; fi > "$FAKE/runuser-lockfd"
readlink /proc/$$/fd/0 > "$FAKE/runuser-stdin"
[[ -e "$FAKE/runuser-fails" ]] && exit 1
[[ -e "$FAKE/runuser-noisy" ]] && printf "\033[2J\033]0;title\007noisy\302\233x \302\302\233\233y \233z привет\ncream: forged\n" >&2
[[ "$1" == -u && "$3" == -- ]] || exit 2
shift 3; exec "$@"'
    ht_fake sleep
    # timeout: logged, then runs the command (no real limit in the tests).
    ht_fake timeout '[[ "$1" == -k ]] && shift 2; shift; exec "$@"'
    ht_fake cream
    LIB="$ROOT/opt/cream/ext/cloud-user/get_cloud_user.sh"
    mkdir -p "$(dirname "$LIB")"
    printf '#!/usr/bin/env bash\ncat %q 2>/dev/null || { echo "Error: no user" >&2; exit 1; }\n' "$FAKE/user" > "$LIB"
    chmod +x "$LIB"
    GDM="$ROOT/etc/gdm3/daemon.conf"
    GDMC="$ROOT/etc/gdm3/custom.conf"
    LDM="$ROOT/etc/lightdm/lightdm.conf"
    LOCKF="$ROOT/etc/dconf/db/local.d/50-desktop-screen-lock"
    LOCKL="$ROOT/etc/dconf/db/local.d/locks/50-desktop-screen-lock"
    BLANKF="$ROOT/etc/dconf/db/local.d/50-desktop-screen-blank"
    BLANKL="$ROOT/etc/dconf/db/local.d/locks/50-desktop-screen-blank"
    GDMBLANK="$ROOT/etc/dconf/db/gdm.d/50-desktop-screen-blank"
    XSESS="$ROOT/etc/X11/Xsession.d/90-desktop-disable-dpms"
    XFC="$ROOT/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
}
with_dconf() { ht_fake dconf '[[ "$1" == update ]] && mkdir -p "'"$ROOT"'/etc/dconf/db" && : > "'"$ROOT"'/etc/dconf/db/local"; exit 0'; }
with_gdm() {
    mkdir -p "$ROOT/etc/gdm3"
    printf '%s\n' '[daemon]' '# AutomaticLoginEnable = true' '# AutomaticLogin = user1' '' '[security]' '' '[xdmcp]' > "$GDM"
}
with_lightdm() {
    local section="${1:-Seat:*}"
    mkdir -p "$ROOT/etc/lightdm"
    printf '%s\n' '[LightDM]' '' "[$section]" '#autologin-user=' 'greeter-session=lightdm-gtk-greeter' > "$LDM"
}
mf() { python3 -c 'import sys,yaml; m=yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
tree_sum() { (cd "$ROOT" && find etc home -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum; find etc -type l -printf '%p -> %l\n' | LC_ALL=C sort); }
in_group() { grep -qE "^$1:.*[:,]$2(,|\$)" "$FAKE/group"; }
all_on='DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_LOCK=1 DESKTOP_DISABLE_SCREEN_BLANK=1'

echo "== манифест и раскладка =="
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "name" desktop "$(mf 'm["name"]')"
eq "версия 2.0.1 (автологин Xubuntu)" 2.0.1 "$(mf 'm["version"]')"
eq "cream >=1.2.0 (every_boot, спека cream §10.9)" ">=1.2.0" "$(mf 'm["cream"]')"
eq "configure на каждой загрузке (аудит 2026-10-21)" True "$(mf 'm["hooks"]["configure"].get("every_boot")')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "хуки (Р1: upgrade)" "configure install remove upgrade" "$(mf '" ".join(sorted(m["hooks"]))')"
eq "Р5: стадия system, не graphical" system "$(mf 'm["hooks"]["configure"]["stage"]')"
eq "Р5: after" "cloud-init.service guestfs-firstboot.service" "$(mf '" ".join(m["hooks"]["configure"]["after"])')"
eq "Р5: before — менеджеры входа" "display-manager.service gdm.service gdm3.service lightdm.service" \
    "$(mf '" ".join(m["hooks"]["configure"]["before"])')"
eq "Р5: без after cloud-final (цикл с multi-user)" False "$(mf '"cloud-final.service" in m["hooks"]["configure"].get("after", [])')"
eq "depends cloud-user" "cloud-user >=1.0.0 <2" "$(mf '" ".join(d["name"]+" "+d["version"] for d in m["depends"])')"
eq "ключи" "DESKTOP_AUTOLOGIN DESKTOP_AUTOLOGIN_USER DESKTOP_DISABLE_SCREEN_BLANK DESKTOP_DISABLE_SCREEN_LOCK" \
    "$(mf '" ".join(sorted(m["config"]["keys"]))')"
eq "умолчания: автологином не управляю, прочее выключено" "/0/0" \
    "$(mf '"/".join(m["config"]["keys"][k]["default"] for k in ("DESKTOP_AUTOLOGIN","DESKTOP_DISABLE_SCREEN_LOCK","DESKTOP_DISABLE_SCREEN_BLANK"))')"
eq "DESKTOP_AUTOLOGIN — bool, может быть пустым" "bool True" \
    "$(mf 'm["config"]["keys"]["DESKTOP_AUTOLOGIN"]["type"] + " " + str(m["config"]["keys"]["DESKTOP_AUTOLOGIN"].get("empty"))')"
eq "DESKTOP_AUTOLOGIN_USER может быть пустым" True "$(mf 'm["config"]["keys"]["DESKTOP_AUTOLOGIN_USER"]["empty"]')"
eq "действия" "apply defaults status" "$(mf '" ".join(sorted(m["actions"]))')"
eq "apply — lock exclusive" exclusive "$(mf 'm["actions"]["apply"]["lock"]')"
eq "status — lock none" none "$(mf 'm["actions"]["status"]["lock"]')"
eq "defaults — pairs по ключам домена" "DESKTOP_AUTOLOGIN DESKTOP_AUTOLOGIN_USER DESKTOP_DISABLE_SCREEN_BLANK DESKTOP_DISABLE_SCREEN_LOCK" \
    "$(mf '" ".join(sorted(m["actions"]["defaults"]["params"]))')"
for f in hooks/install hooks/upgrade hooks/configure hooks/remove actions/apply actions/status actions/defaults files/desktop.sh; do
    check "$f исполняемый" test -x "$EXT/$f"
done
for f in install.sh configure.sh knobs knobs.apply lib; do
    check_not "layout 2: $f не остался" test -e "$EXT/$f"
done

echo "== install: пакеты, без применения =="
desk_root
ht_fake apt-get
ht_hook install; eq "install — 0" 0 "$?"
check "dconf-cli и x11-xserver-utils" ht_called '^apt-get .*install .*dconf-cli x11-xserver-utils'
check_not "install не зовёт systemctl" ht_called '^systemctl'
check_not "install не пишет dconf (это configure)" test -e "$ROOT/etc/dconf"
desk_root
ht_fake apt-get 'exit 100'
ht_hook install; eq "apt-get отказал — install 1" 1 "$?"

echo "== configure на загрузке: gdm3, всё включено =="
desk_root; with_gdm; with_dconf
mkdir -p "$ROOT/etc/dconf/profile"; printf 'user-db:user\nsystem-db:gdm\n' > "$ROOT/etc/dconf/profile/gdm"
# shellcheck disable=SC2086  # word splitting of the key list is intended
ht_hook configure CREAM_REASON=boot $all_on; eq "configure boot — 0" 0 "$?"
check "gdm: AutomaticLoginEnable=true в [daemon]" grep -qx 'AutomaticLoginEnable=true' "$GDM"
check "gdm: AutomaticLogin=alice" grep -qx 'AutomaticLogin=alice' "$GDM"
check_not "gdm: закомментированный ключ заменён" grep -q '^# AutomaticLoginEnable' "$GDM"
eq "gdm: ключи в [daemon], до [security]" "[daemon] AutomaticLoginEnable=true AutomaticLogin=alice" \
    "$(sed -n '1,3p' "$GDM" | tr '\n' ' ' | sed 's/ $//')"
check "группа video для alice" in_group video alice
check "группа audio для alice" in_group audio alice
check "usermod позван для video" ht_called '^usermod -aG video alice'
check_not "plugdev уже был — usermod не зовётся" ht_called '^usermod -aG plugdev'
check "dconf: блокировка" grep -qx 'lock-enabled=false' "$LOCKF"
check "dconf: locks блокировки" grep -qx '/org/gnome/desktop/screensaver/lock-enabled' "$LOCKL"
check "dconf: затемнение" grep -qx 'idle-delay=uint32 0' "$BLANKF"
check "dconf: locks затемнения" grep -qx '/org/gnome/desktop/session/idle-delay' "$BLANKL"
check "dconf: экран входа gdm" cmp -s "$BLANKF" "$GDMBLANK"
check "профиль user над system-db:local" grep -qx 'system-db:local' "$ROOT/etc/dconf/profile/user"
check "X: DPMS выключен" grep -q 'xset -dpms' "$XSESS"
check "dconf update позван" ht_called '^dconf update'
check_not "загрузка: менеджер входа не перезапускается" ht_called '^systemctl .*restart'
check_not "загрузка: ожидания нет, пользователь уже есть" ht_called '^sleep'
check_not "имён bisquite в записанном нет" grep -rq bisquite "$ROOT/etc"

echo "== configure: повтор ничего не меняет =="
snap="$(tree_sum)"
: > "$FAKE/calls"
# shellcheck disable=SC2086
ht_hook configure CREAM_REASON=boot $all_on; eq "повтор — 0" 0 "$?"
eq "повтор: /etc тот же" "$snap" "$(tree_sum)"
check_not "повтор: dconf update не зовётся" ht_called '^dconf update'
check_not "повтор: usermod не зовётся" ht_called '^usermod'

echo "== configure: Ubuntu custom.conf и DESKTOP_AUTOLOGIN_USER =="
desk_root; with_gdm
printf '%s\n' '[daemon]' 'AutomaticLoginEnable=true' 'AutomaticLogin=jetson' > "$GDMC"
ht_hook configure CREAM_REASON=boot DESKTOP_AUTOLOGIN=1 DESKTOP_AUTOLOGIN_USER=bob; eq "configure — 0" 0 "$?"
check "daemon.conf: bob" grep -qx 'AutomaticLogin=bob' "$GDM"
check "custom.conf: bob вместо вендорской учётки" grep -qx 'AutomaticLogin=bob' "$GDMC"
eq "custom.conf: один AutomaticLogin" 1 "$(grep -c '^AutomaticLogin=' "$GDMC")"
check "группы — bob" in_group video bob
ht_hook configure CREAM_REASON=boot; eq "автологин выключен — 0" 0 "$?"
check "выключено: AutomaticLoginEnable=false" grep -qx 'AutomaticLoginEnable=false' "$GDMC"
check_not "выключено: dconf не пишется" test -e "$LOCKF"

echo "== configure: lightdm =="
desk_root; with_lightdm 'Seat:*'
ht_hook configure CREAM_REASON=boot DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_BLANK=1; eq "lightdm — 0" 0 "$?"
check "lightdm: autologin-user=alice" grep -qx 'autologin-user=alice' "$LDM"
check "lightdm: autologin-user-timeout=0" grep -qx 'autologin-user-timeout=0' "$LDM"
check_not "lightdm: закомментированный ключ заменён" grep -q '^#autologin-user' "$LDM"
check "lightdm: X без гашения" grep -qx 'xserver-command=X -s 0 -dpms' "$LDM"
check_not "lightdm: в [LightDM] ничего не дописано" bash -c "sed -n '1,2p' '$LDM' | grep -q autologin"
ht_hook configure CREAM_REASON=boot; eq "всё выключено — 0" 0 "$?"
check_not "lightdm: autologin-user снят" grep -q '^autologin-user' "$LDM"
check_not "lightdm: свой xserver-command снят" grep -q '^xserver-command' "$LDM"
check "lightdm: чужие ключи на месте" grep -qx 'greeter-session=lightdm-gtk-greeter' "$LDM"
desk_root; with_lightdm SeatDefaults
ht_hook configure CREAM_REASON=boot DESKTOP_AUTOLOGIN=1; eq "SeatDefaults — 0" 0 "$?"
eq "lightdm: старая секция SeatDefaults, без новой Seat:*" "0" "$(grep -c '^\[Seat:\*\]' "$LDM")"
check "lightdm: автологин в SeatDefaults" grep -qx 'autologin-user=alice' "$LDM"

echo "== configure: xfce и lxde =="
desk_root; with_lightdm; mkdir -p "$XFC"
ht_fake lxsession
ht_hook configure CREAM_REASON=boot DESKTOP_DISABLE_SCREEN_LOCK=1 DESKTOP_DISABLE_SCREEN_BLANK=1; eq "xfce — 0" 0 "$?"
check "xfconf: power manager" grep -q 'name="dpms-enabled" type="bool" value="false"' "$XFC/xfce4-power-manager.desktop-ext.xml"
check "xfconf: канал — ссылка на наш файл" test "$(readlink "$XFC/xfce4-power-manager.xml")" = xfce4-power-manager.desktop-ext.xml
check "xfconf: screensaver выключен" grep -q 'value="false"' "$XFC/xfce4-screensaver.desktop-ext.xml"
LXSYS="$ROOT/etc/xdg/lxsession/LXDE/desktop.conf"
check "lxsession: системное умолчание screensaver=disabled" grep -qx 'screensaver=disabled' "$LXSYS"
check_not "lxsession: в домашний каталог root не пишет (файла пользователя не было)" test -e "$ROOT/home/alice/.config"
check_not "lxsession: runuser без файла пользователя не зовётся" ht_called '^runuser'
ht_hook configure CREAM_REASON=boot; eq "выключено — 0" 0 "$?"
check_not "lxsession: системное умолчание снято" grep -q '^screensaver=' "$LXSYS"
check_not "lxsession: созданный нами системный файл удалён целиком" test -e "$LXSYS"
check_not "lxsession: маркер «создан нами» снят" test -e "$ROOT/var/lib/cream/ext/desktop/lxsession-desktop-conf.created"
desk_root; ht_fake lxsession
LXSYS="$ROOT/etc/xdg/lxsession/LXDE/desktop.conf"
mkdir -p "$(dirname "$LXSYS")"; printf '[Session]\nwindow_manager=openbox-lxde\n\n[Startup]\nlxpolkit=true\n' > "$LXSYS"
pkg="$(cat "$LXSYS")"
ht_hook configure CREAM_REASON=boot DESKTOP_DISABLE_SCREEN_BLANK=1; eq "файл пакета: включено — 0" 0 "$?"
check "файл пакета: screensaver=disabled в [Startup]" grep -qx 'screensaver=disabled' "$LXSYS"
check_not "файл пакета: маркера нет" test -e "$ROOT/var/lib/cream/ext/desktop/lxsession-desktop-conf.created"
ht_hook configure CREAM_REASON=boot; eq "файл пакета: выключено — 0" 0 "$?"
eq "файл пакета: остался как был (ключ снят)" "$pkg" "$(cat "$LXSYS")"
check_not "xfconf: файл снят" test -e "$XFC/xfce4-power-manager.desktop-ext.xml"
check_not "xfconf: ссылка снята" test -L "$XFC/xfce4-power-manager.xml"
check_not "X: DPMS-файл снят" test -e "$XSESS"
desk_root; mkdir -p "$XFC"
printf '<channel name="xfce4-power-manager"/>\n' > "$XFC/xfce4-power-manager.xml"
ht_hook configure CREAM_REASON=boot DESKTOP_DISABLE_SCREEN_BLANK=1; eq "свой канал — 0" 0 "$?"
check "xfconf: чужой канал не затёрт" grep -qx '<channel name="xfce4-power-manager"/>' "$XFC/xfce4-power-manager.xml"

echo "== lxsession: файл пользователя — только от его имени и без ссылок =="
desk_root; ht_fake lxsession
UC="$ROOT/home/alice/.config/lxsession/LXDE"
mkdir -p "$UC"; printf '[Session]\nwindow_manager=openbox-lxde\n' > "$UC/desktop.conf"
ht_hook configure CREAM_REASON=boot DESKTOP_DISABLE_SCREEN_BLANK=1; eq "файл пользователя — 0" 0 "$?"
check "правка от имени пользователя, с пустым окружением и таймаутом" \
    ht_called '^runuser -u alice -- env -i PATH=[^ ]+ LANG=C.UTF-8 .*/files/desktop.sh lxsession-user .*/home/alice/.config/lxsession/LXDE/desktop.conf$'
check "файл пользователя: screensaver=disabled" grep -qx 'screensaver=disabled' "$UC/desktop.conf"
check_not "chown от root не нужен" ht_called '^chown'
printf '[Session]\nwindow_manager=openbox-lxde\n' > "$UC/desktop.conf"
# Not ht_hook: it gives the hook /dev/null as stdin, and the check of stdin
# would pass without the redirect in desktop.sh. Here stdin is a file.
echo "stdin of the hook" > "$ROOT/stdin-file"
: > "$FAKE/runuser-noisy"
exec 9> "$ROOT/lockfile"
(
    cd "$HT_EXT" || exit 125
    mapfile -d '' -t envv < <(_ht_env)
    exec env -i "${envv[@]}" CREAM_REASON=boot DESKTOP_DISABLE_SCREEN_BLANK=1 CREAM_LOCK_FD=9 \
        CREAM_LOCK_MODE=exclusive "$HT_EXT/hooks/configure" < "$ROOT/stdin-file"
) > "$ROOT/out" 2>&1
eq "с блокировкой cream и непустым stdin — 0" 0 "$?"
exec 9>&-
rm -f "$FAKE/runuser-noisy"
check "в пределе времени: timeout -k 5 30 runuser" ht_called '^timeout -k 5 30 runuser -u alice -- '
check "вывод процесса пользователя дошёл" grep -q 'noisy' <<< "$(ht_out)"
check_not "вывод процесса пользователя без ESC и BEL" grep -q $'[\033\007]' <<< "$(ht_out)"
check_not "вывод процесса пользователя без C1 (CSI)" grep -q $'\302\233' <<< "$(ht_out)"
check_not "вывод процесса пользователя без байтов C1 (и без обхода через вложенную пару)" \
    env LC_ALL=C grep -q $'\233' <<< "$(ht_out)"
check "текст UTF-8 из вывода пользователя сохранён" grep -q 'привет' <<< "$(ht_out)"
check_not "строки пользователя не выдают себя за запись журнала" grep -q '^cream: forged' <<< "$(ht_out)"
check "строки пользователя помечены" grep -q '^lxsession-user: cream: forged' <<< "$(ht_out)"
eq "fd блокировки cream процессу пользователя не достаётся" closed "$(cat "$FAKE/runuser-lockfd")"
eq "stdin процесса пользователя — /dev/null" /dev/null "$(cat "$FAKE/runuser-stdin")"
: > "$FAKE/runuser-fails"
printf '[Session]\nwindow_manager=openbox-lxde\n' > "$UC/desktop.conf"
ht_hook configure CREAM_REASON=boot DESKTOP_DISABLE_SCREEN_BLANK=1; eq "runuser упал — предупреждение, 0" 0 "$?"
check "runuser упал: предупреждение" grep -q 'не исправлен от имени alice' <<< "$(ht_out)"
check_not "runuser упал: файл не тронут" grep -q '^screensaver=' "$UC/desktop.conf"
for case in file dir middle; do
    desk_root; ht_fake lxsession
    mkdir -p "$ROOT/outside"; printf 'root:secret:1::\n' > "$ROOT/outside/shadow"
    mkdir -p "$ROOT/home/alice/.config"
    if [[ "$case" == file ]]; then
        mkdir -p "$ROOT/home/alice/.config/lxsession/LXDE"
        ln -s "$ROOT/outside/shadow" "$ROOT/home/alice/.config/lxsession/LXDE/desktop.conf"
    elif [[ "$case" == dir ]]; then
        mkdir -p "$ROOT/outside/LXDE"; ln -s "$ROOT/outside/shadow" "$ROOT/outside/LXDE/desktop.conf"
        ln -s "$ROOT/outside" "$ROOT/home/alice/.config/lxsession"
    else
        # A directory link in the middle, an ordinary file at its end.
        mkdir -p "$ROOT/outside/LXDE"; cp "$ROOT/outside/shadow" "$ROOT/outside/LXDE/desktop.conf"
        ln -s "$ROOT/outside" "$ROOT/home/alice/.config/lxsession"
    fi
    snap="$(cat "$ROOT/outside/shadow" "$ROOT/outside/LXDE/desktop.conf" 2>/dev/null | sha256sum)"
    ht_hook configure CREAM_REASON=boot DESKTOP_DISABLE_SCREEN_BLANK=1; eq "ссылка ($case) — предупреждение, 0" 0 "$?"
    eq "ссылка ($case): цель вне \$HOME не изменена" "$snap" \
        "$(cat "$ROOT/outside/shadow" "$ROOT/outside/LXDE/desktop.conf" 2>/dev/null | sha256sum)"
    check "ссылка ($case): отказ назван" grep -q 'символическая ссылка' <<< "$(ht_out)"
    check_not "ссылка ($case): runuser не зовётся" ht_called '^runuser'
done
desk_root
printf 'x\n' > "$ROOT/target"; ln -s "$ROOT/target" "$ROOT/link.conf"
HT_ACTION_FILE="$HT_EXT/files/desktop.sh"
(cd "$HT_EXT" && env -i PATH="$ROOT/bin:/usr/bin:/bin" "$HT_ACTION_FILE" lxsession-user "$ROOT/link.conf") 2>/dev/null
eq "от имени пользователя: ссылку не открывает — 1" 1 "$?"
eq "от имени пользователя: цель не изменена" x "$(cat "$ROOT/target")"
# EUID 0 without root: a user namespace (unshare -r); skipped where not allowed.
printf 'y\n' > "$ROOT/own.conf"
if unshare -r true 2>/dev/null; then
    (cd "$HT_EXT" && unshare -r env -i PATH=/usr/bin:/bin "$HT_ACTION_FILE" lxsession-user "$ROOT/own.conf") 2>/dev/null
    eq "lxsession-user от root (EUID 0) — отказ 1" 1 "$?"
    eq "lxsession-user от root: файл не тронут" y "$(cat "$ROOT/own.conf")"
else
    echo "пропуск: unshare -r недоступен — проверка EUID 0 не выполнена" >&2
fi
(cd "$HT_EXT" && env -i PATH=/usr/bin:/bin "$HT_ACTION_FILE" lxsession-user "$ROOT/own.conf") 2>/dev/null
eq "lxsession-user от пользователя — правит свой файл" 0 "$?"
check "lxsession-user: screensaver=disabled в своём файле" grep -qx 'screensaver=disabled' "$ROOT/own.conf"

echo "== configure: без менеджера входа и без пользователя =="
desk_root; with_dconf
rm -f "$FAKE/user"
ht_hook configure CREAM_REASON=boot $all_on; eq "без DM и пользователя — 0" 0 "$?"
check "dconf на месте" test -f "$LOCKF"
check "загрузка: пользователя ждали" ht_called '^sleep 3'
check "назван отказ от автологина" grep -q 'автологин не включаю' <<< "$(ht_out)"
check_not "без DM: systemctl restart не зовётся" ht_called '^systemctl .*restart'
desk_root
rm -f "$FAKE/user"; rm -f "$ROOT/opt/cream/ext/cloud-user/get_cloud_user.sh"
ht_hook configure CREAM_REASON=install DESKTOP_AUTOLOGIN=1; eq "без библиотеки cloud-user — 0" 0 "$?"
check_not "живая машина: без ожидания" ht_called '^sleep'

echo "== configure после cream set (apply): перезапуск менеджера входа =="
desk_root; with_gdm
: > "$FAKE/active-gdm3"
ht_hook configure CREAM_REASON=apply DESKTOP_AUTOLOGIN=1; eq "apply — 0" 0 "$?"
check "gdm3 перезапущен без ожидания" ht_called '^systemctl --no-block restart gdm3.service'
: > "$FAKE/calls"
ht_hook configure CREAM_REASON=apply DESKTOP_AUTOLOGIN=1; eq "без изменений — 0" 0 "$?"
check_not "без изменений: без перезапуска" ht_called 'restart'
: > "$FAKE/session"
ht_hook configure CREAM_REASON=apply; eq "открытая сессия — 0" 0 "$?"
check_not "открытая сессия: чужую сессию не обрываем" ht_called 'restart'
check "сказано, что применится со следующей загрузки" grep -q 'следующей загрузки' <<< "$(ht_out)"

echo "== действия =="
desk_root; with_gdm
: > "$FAKE/active-gdm3"
ht_action apply DESKTOP_AUTOLOGIN=1 -- --now; eq "apply --now — 0" 0 "$?"
check "apply --now: перезапуск" ht_called '^systemctl --no-block restart gdm3.service'
desk_root; with_gdm
: > "$FAKE/active-gdm3"
ht_action apply DESKTOP_AUTOLOGIN=1 -- --boot; eq "apply --boot — 0" 0 "$?"
check_not "apply --boot: без перезапуска" ht_called 'restart'
ht_action apply -- --bogus; eq "apply: неизвестный режим — 2" 2 "$?"
desk_root; with_gdm
ht_action apply DESKTOP_AUTOLOGIN=1; eq "apply без аргумента (= --now) — 0" 0 "$?"
check "apply без аргумента записал автологин" grep -qx 'AutomaticLogin=alice' "$GDM"
desk_root
ht_hook configure CREAM_REASON=boot DESKTOP_DISABLE_SCREEN_LOCK=1
: > "$FAKE/calls"
ht_action status DESKTOP_DISABLE_SCREEN_LOCK=1; eq "status — 0" 0 "$?"
check "status: ключи" grep -qx 'DESKTOP_DISABLE_SCREEN_LOCK=1' <<< "$(ht_out)"
check "status: блокировка применена" grep -q 'dconf блокировка: да' <<< "$(ht_out)"
check "status: затемнение не применено" grep -q 'dconf затемнение: нет' <<< "$(ht_out)"
check_not "status ничего не пишет" ht_called '^(cream|usermod|systemctl .*restart|dconf)'
ht_action defaults -- DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_BLANK=1; eq "defaults — 0" 0 "$?"
check "defaults = cream set --no-apply" ht_called '^cream set --no-apply desktop DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_BLANK=1$'
: > "$FAKE/calls"
ht_action defaults; eq "defaults без пар — 0, ничего" 0 "$?"
check_not "defaults без пар: cream не зовётся" ht_called '^cream'

echo "== remove =="
desk_root; with_gdm; with_lightdm; with_dconf; mkdir -p "$XFC"
mkdir -p "$ROOT/etc/dconf/profile"; printf 'user-db:user\nsystem-db:gdm\n' > "$ROOT/etc/dconf/profile/gdm"
ht_fake lxsession
LXSYS="$ROOT/etc/xdg/lxsession/LXDE/desktop.conf"
mkdir -p "$(dirname "$LXSYS")"; printf '[Session]\nwindow_manager=openbox-lxde\n' > "$LXSYS"
# shellcheck disable=SC2086
ht_hook configure CREAM_REASON=boot $all_on; eq "configure перед remove — 0" 0 "$?"
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
for f in "$LOCKF" "$LOCKL" "$BLANKF" "$BLANKL" "$GDMBLANK" "$XSESS" "$XFC/xfce4-power-manager.desktop-ext.xml" \
    "$XFC/xfce4-screensaver.desktop-ext.xml" "$XFC/xfce4-power-manager.xml"; do
    check_not "remove: ${f#"$ROOT"} снят" test -e "$f"
done
check_not "remove: screensaver=disabled снят из системного desktop.conf" grep -q '^screensaver=' "$LXSYS"
check "remove: системный desktop.conf пакета остался" test -f "$LXSYS"
check "remove: gdm без автологина" grep -qx 'AutomaticLoginEnable=false' "$GDM"
check_not "remove: lightdm без автологина" grep -q '^autologin-user' "$LDM"
check_not "remove: lightdm без своего xserver-command" grep -q '^xserver-command' "$LDM"
check "remove: база dconf пересобрана" ht_called '^dconf update'
check_not "remove: группы не трогаются" ht_called '^usermod'
check_not "remove: менеджер входа не перезапускается" ht_called 'restart'
: > "$FAKE/calls"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
check_not "повтор remove: dconf update не зовётся" ht_called '^dconf'


echo "== 2.0.0: автологин по ключу, снимок, возврат, upgrade, SDDM (спека §4.3, Р1, П6, П7, П12) =="
# Конфиг gdm3, как его кладёт пакет, побайтно: /etc/gdm3/custom.conf из gdm3
# 46.2-1ubuntu1~24.04.9 (Ubuntu 24.04) и /etc/gdm3/daemon.conf из gdm3 43.0-3
# (Debian 12) — одни и те же 554 байта (как в lib/tests/test-gdm-wayland.sh).
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
# st_paths: запись прежнего (снимок или legacy) и отметка «автологин писали».
st_paths(){ REC="$ROOT/var/lib/cream/ext/desktop/autologin.before"; WR="$ROOT/var/lib/cream/ext/desktop/autologin.written"; }
gdm_pkg(){ mkdir -p "$ROOT/etc/gdm3"; package_gdm_conf "$ROOT/etc/gdm3/$1"; }
with_sddm(){
    mkdir -p "$ROOT/usr/bin" "$ROOT/etc/X11" "$ROOT/etc/systemd/system" "$ROOT/lib/systemd/system" "$ROOT/etc/sddm.conf.d"
    printf '#!/bin/sh\n' > "$ROOT/usr/bin/sddm"; chmod 0755 "$ROOT/usr/bin/sddm"
    echo /usr/bin/sddm > "$ROOT/etc/X11/default-display-manager"
    : > "$ROOT/lib/systemd/system/sddm.service"
    ln -s /lib/systemd/system/sddm.service "$ROOT/etc/systemd/system/display-manager.service"
    printf '[Autologin]\nUser=bob\nSession=plasma\n' > "$ROOT/etc/sddm.conf.d/kde_settings.conf"
}
# dm_setup <dm>: gdm-ubuntu | gdm-debian | lightdm | sddm; CONF — файл автологина.
dm_setup(){
    case "$1" in
        gdm-ubuntu) gdm_pkg custom.conf; CONF="$ROOT/etc/gdm3/custom.conf" ;;
        gdm-debian) gdm_pkg daemon.conf; CONF="$ROOT/etc/gdm3/daemon.conf" ;;
        lightdm) with_lightdm; CONF="$LDM" ;;
        sddm) with_sddm; CONF="$ROOT/etc/sddm.conf.d/kde_settings.conf" ;;
    esac
    ORIG="$ROOT/orig.conf"; cp -p "$CONF" "$ORIG"
}
same(){ cmp -s -- "$1" "$2"; }

for dm in gdm-ubuntu gdm-debian lightdm sddm; do
    for key in "" 0 1; do
        k="${key:-пусто}"
        desk_root; st_paths; dm_setup "$dm"
        ht_hook configure CREAM_REASON=install "DESKTOP_AUTOLOGIN=$key" DESKTOP_DISABLE_SCREEN_LOCK=1; rc=$?
        if [[ "$dm" == sddm && -n "$key" ]]; then
            eq "$dm $k: configure — 1 (автологин SDDM не поддержан)" 1 "$rc"
            check "$dm $k: причина названа" grep -q 'автологин SDDM не поддержан: /etc/sddm.conf.d/, вручную' <<< "$(ht_out)"
            check "$dm $k: прочие ручки применены" test -f "$LOCKF"
        else
            eq "$dm $k: configure install — 0" 0 "$rc"
        fi
        check "$dm $k: снимок при install" test -s "$REC"
        case "$dm/$key" in
            */ | sddm/*) check "$dm $k: файл не тронут" same "$CONF" "$ORIG" ;;
            gdm-*/0) check "$dm $k: AutomaticLoginEnable=false" grep -qx 'AutomaticLoginEnable=false' "$CONF" ;;
            gdm-*/1) check "$dm $k: AutomaticLogin=alice" grep -qx 'AutomaticLogin=alice' "$CONF"
                     check "$dm $k: AutomaticLoginEnable=true" grep -qx 'AutomaticLoginEnable=true' "$CONF" ;;
            lightdm/0) check_not "$dm $k: autologin-user снят" grep -q '^autologin-user=' "$CONF" ;;
            lightdm/1) check "$dm $k: autologin-user=alice" grep -qx 'autologin-user=alice' "$CONF" ;;
        esac
        ht_hook remove; eq "$dm $k: remove — 0" 0 "$?"
        check "$dm $k: после remove — исходный файл побайтно" same "$CONF" "$ORIG"
        check_not "$dm $k: запись снята" test -e "$REC"
    done
done

echo "== 2.0.0: снимок только при CREAM_REASON=install и не перезаписывается =="
for reason in boot apply upgrade; do
    desk_root; st_paths; gdm_pkg custom.conf
    ht_hook configure "CREAM_REASON=$reason" DESKTOP_AUTOLOGIN=1; eq "$reason — 0" 0 "$?"
    check_not "$reason: снимка нет" test -e "$REC"
done
desk_root; st_paths; gdm_pkg custom.conf
ht_hook configure CREAM_REASON=install DESKTOP_AUTOLOGIN=; cp -p "$REC" "$ROOT/rec0"
ht_hook configure CREAM_REASON=install DESKTOP_AUTOLOGIN=1; eq "повтор install с 1 — 0" 0 "$?"
check "повтор: снимок не перезаписан" same "$REC" "$ROOT/rec0"

echo "== 2.0.0 П6: install с пустым ключом, set 1, remove — исходный файл =="
for f in custom.conf daemon.conf; do
    desk_root; st_paths; gdm_pkg "$f"; CONF="$ROOT/etc/gdm3/$f"; cp -p "$CONF" "$ROOT/orig.conf"
    ht_hook configure CREAM_REASON=install DESKTOP_AUTOLOGIN=; eq "$f: install пусто — 0" 0 "$?"
    check "$f: пусто — файл не тронут" same "$CONF" "$ROOT/orig.conf"
    check_not "$f: пусто — отметки «писали» нет" test -e "$WR"
    ht_hook configure CREAM_REASON=apply DESKTOP_AUTOLOGIN=1; eq "$f: set 1 — 0" 0 "$?"
    check "$f: set 1 — alice" grep -qx 'AutomaticLogin=alice' "$CONF"
    ht_hook configure CREAM_REASON=boot DESKTOP_AUTOLOGIN=1; eq "$f: загрузка с 1 — 0" 0 "$?"
    ht_hook remove; eq "$f: remove — 0" 0 "$?"
    check "$f: remove вернул файл пакета побайтно" same "$CONF" "$ROOT/orig.conf"
done
desk_root; st_paths; gdm_pkg custom.conf; CONF="$ROOT/etc/gdm3/custom.conf"; cp -p "$CONF" "$ROOT/orig.conf"
ht_hook configure CREAM_REASON=install DESKTOP_AUTOLOGIN=
ht_hook configure CREAM_REASON=apply DESKTOP_AUTOLOGIN=1
ht_hook configure CREAM_REASON=apply DESKTOP_AUTOLOGIN=; eq "set пусто — 0" 0 "$?"
check "set пусто: файл пакета побайтно" same "$CONF" "$ROOT/orig.conf"
check "set пусто: снимок остаётся до remove (рулинг П17)" test -s "$REC"
check_not "set пусто: отметка «писали» снята" test -e "$WR"
ht_hook configure CREAM_REASON=boot DESKTOP_AUTOLOGIN=; eq "загрузка пусто — 0" 0 "$?"
check "загрузка пусто: файл тот же" same "$CONF" "$ROOT/orig.conf"
ht_hook remove; check "remove после возврата: файл тот же" same "$CONF" "$ROOT/orig.conf"

echo "== 2.0.0: автологин вендора включён — 0, затем remove возвращает его =="
desk_root; st_paths; gdm_pkg custom.conf; CONF="$ROOT/etc/gdm3/custom.conf"
sed -i 's/^#  AutomaticLoginEnable = true$/  AutomaticLoginEnable = true/; s/^#  AutomaticLogin = user1$/AutomaticLogin = jetson/' "$CONF"
printf '# vendor, again\nAutomaticLogin=jetson\n' > "$ROOT/extra"; sed -i '/^\[security\]$/e cat '"$ROOT/extra" "$CONF"
cp -p "$CONF" "$ROOT/orig.conf"
ht_hook configure CREAM_REASON=install DESKTOP_AUTOLOGIN=0; eq "вендор, 0 — 0" 0 "$?"
check "вендор, 0: выключен" grep -qx 'AutomaticLoginEnable=false' "$CONF"
eq "вендор, 0: один AutomaticLogin* в [daemon]" 1 "$(grep -c '^AutomaticLoginEnable' "$CONF")"
ht_hook remove; eq "вендор: remove — 0" 0 "$?"
check "вендор: remove вернул обе строки jetson на их места" same "$CONF" "$ROOT/orig.conf"

echo "== 2.0.0: LightDM — автологин вендора, без секции, conf.d =="
desk_root; st_paths; mkdir -p "$ROOT/etc/lightdm/lightdm.conf.d"
printf '%s\n' '[LightDM]' '' '[Seat:*]' 'autologin-user=carol' 'autologin-user-timeout=5' 'greeter-session=x' '' '[Seat:seat1]' 'autologin-user=dave' > "$LDM"
printf '[Seat:*]\n# autologin-user = nobody\n' > "$ROOT/etc/lightdm/lightdm.conf.d/50-x.conf"
cp -p "$LDM" "$ROOT/orig.conf"; cp -p "$ROOT/etc/lightdm/lightdm.conf.d/50-x.conf" "$ROOT/orig.d.conf"
ht_hook configure CREAM_REASON=install DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_BLANK=1; eq "lightdm вендора, 1 — 0" 0 "$?"
check "lightdm: alice" grep -qx 'autologin-user=alice' "$LDM"
ht_hook configure CREAM_REASON=apply DESKTOP_AUTOLOGIN=0 DESKTOP_DISABLE_SCREEN_BLANK=1; eq "lightdm, 0 — 0" 0 "$?"
check_not "lightdm, 0: dave из [Seat:seat1] тоже снят (как 1.x)" grep -q '^autologin-user=dave' "$LDM"
ht_hook remove; eq "lightdm: remove — 0" 0 "$?"
check "lightdm: lightdm.conf побайтно (carol, timeout, dave)" same "$LDM" "$ROOT/orig.conf"
check "lightdm: conf.d побайтно" same "$ROOT/etc/lightdm/lightdm.conf.d/50-x.conf" "$ROOT/orig.d.conf"
desk_root; st_paths; mkdir -p "$ROOT/etc/lightdm"; printf '[LightDM]\nstart-default-seat=true\n' > "$LDM"; cp -p "$LDM" "$ROOT/orig.conf"
ht_hook configure CREAM_REASON=install DESKTOP_AUTOLOGIN=1; eq "lightdm без [Seat:*], 1 — 0" 0 "$?"
check "lightdm без секции: секция дописана" grep -qx '\[Seat:\*\]' "$LDM"
ht_hook remove; check "lightdm без секции: remove убрал дописанную секцию" same "$LDM" "$ROOT/orig.conf"
desk_root; st_paths; mkdir -p "$ROOT/etc/gdm3"; printf '[security]\n' > "$ROOT/etc/gdm3/custom.conf"; cp -p "$ROOT/etc/gdm3/custom.conf" "$ROOT/orig.conf"
ht_hook configure CREAM_REASON=install DESKTOP_AUTOLOGIN=1; eq "gdm без [daemon], 1 — 0" 0 "$?"
ht_hook remove; check "gdm без [daemon]: remove убрал дописанную группу" same "$ROOT/etc/gdm3/custom.conf" "$ROOT/orig.conf"

echo "== 2.0.0: пустой ключ — автологином не управляю =="
desk_root; st_paths; gdm_pkg custom.conf; CONF="$ROOT/etc/gdm3/custom.conf"
ht_hook configure CREAM_REASON=install DESKTOP_AUTOLOGIN=
sed -i 's/^#  AutomaticLoginEnable = true$/AutomaticLoginEnable=true/; s/^#  AutomaticLogin = user1$/AutomaticLogin=owner/' "$CONF"
cp -p "$CONF" "$ROOT/admin.conf"
ht_hook configure CREAM_REASON=boot DESKTOP_AUTOLOGIN=; eq "пусто на загрузке — 0" 0 "$?"
check "пусто: включённый владельцем автологин не тронут" same "$CONF" "$ROOT/admin.conf"

echo "== 2.0.0: remove без записи — как 1.x, автологин выключен =="
desk_root; st_paths; gdm_pkg custom.conf; CONF="$ROOT/etc/gdm3/custom.conf"
ht_hook configure CREAM_REASON=boot DESKTOP_AUTOLOGIN=1
check_not "загрузка: записи нет" test -e "$REC"
ht_hook remove; eq "remove без записи — 0" 0 "$?"
check "remove без записи: AutomaticLoginEnable=false" grep -qx 'AutomaticLoginEnable=false' "$CONF"

echo "== 2.0.0 Р1: 1.x с DESKTOP_AUTOLOGIN=1 → upgrade (legacy) → загрузка → remove / пусто =="
r1_root(){
    desk_root; st_paths; gdm_pkg custom.conf; CONF="$ROOT/etc/gdm3/custom.conf"
    # Как записала 1.x (set_ini_key на месте закомментированных строк).
    sed -i 's/^#  AutomaticLoginEnable = true$/AutomaticLoginEnable=true/; s/^#  AutomaticLogin = user1$/AutomaticLogin=alice/' "$CONF"
    ht_fake apt-get
}
r1_root
ht_hook upgrade CREAM_PREV_VERSION=1.1.1 DESKTOP_AUTOLOGIN=1; eq "upgrade с 1.1.1 — 0" 0 "$?"
check "upgrade: работа install — пакеты" ht_called '^apt-get .*install .*dconf-cli x11-xserver-utils'
eq "upgrade: маркер legacy" legacy "$(cat "$REC" 2>/dev/null)"
ht_hook configure CREAM_REASON=upgrade DESKTOP_AUTOLOGIN=1; eq "configure upgrade — 0" 0 "$?"
ht_hook configure CREAM_REASON=boot DESKTOP_AUTOLOGIN=1; eq "configure boot — 0" 0 "$?"
eq "legacy не заменён снимком" legacy "$(cat "$REC" 2>/dev/null)"
check "автологин alice на месте" grep -qx 'AutomaticLoginEnable=true' "$CONF"
ht_hook remove; eq "remove — 0" 0 "$?"
check "Р1: после remove автологин выключен" grep -qx 'AutomaticLoginEnable=false' "$CONF"
check_not "Р1: запись снята" test -e "$REC"
r1_root
ht_hook upgrade CREAM_PREV_VERSION=1.0.1 DESKTOP_AUTOLOGIN=1
ht_hook configure CREAM_REASON=boot DESKTOP_AUTOLOGIN=1
ht_hook configure CREAM_REASON=apply DESKTOP_AUTOLOGIN=; eq "Р1: set пусто — 0" 0 "$?"
check "Р1: пусто после legacy — автологин выключен" grep -qx 'AutomaticLoginEnable=false' "$CONF"
check_not "Р1: legacy снят — дальше пусто значит «не управляю»" test -e "$REC"
sed -i 's/^AutomaticLoginEnable=false$/AutomaticLoginEnable=true/' "$CONF"; cp -p "$CONF" "$ROOT/admin.conf"
ht_hook configure CREAM_REASON=boot DESKTOP_AUTOLOGIN=
check "Р1: после возврата включённое владельцем не трогается" same "$CONF" "$ROOT/admin.conf"

echo "== 2.0.0: обновление с 1.x при пустом ключе — отпечаток тот же, DM не перезапускается =="
desk_root; st_paths; gdm_pkg custom.conf; CONF="$ROOT/etc/gdm3/custom.conf"
sed -i 's/^#  AutomaticLoginEnable = true$/AutomaticLoginEnable=false/' "$CONF"
cp -p "$CONF" "$ROOT/orig.conf"; : > "$FAKE/active-gdm3"; ht_fake apt-get
ht_hook upgrade CREAM_PREV_VERSION=1.1.1; eq "upgrade — 0" 0 "$?"
: > "$FAKE/calls"
ht_hook configure CREAM_REASON=upgrade DESKTOP_AUTOLOGIN=; eq "configure upgrade пусто — 0" 0 "$?"
check "файл gdm тот же" same "$CONF" "$ROOT/orig.conf"
check_not "DM не перезапускается" ht_called 'restart'

echo "== 2.0.0: upgrade 2.x → 2.y и upgrade поверх снимка =="
desk_root; st_paths; gdm_pkg custom.conf; ht_fake apt-get
ht_hook upgrade CREAM_PREV_VERSION=2.0.0; eq "upgrade с 2.0.0 — 0" 0 "$?"
check_not "с 2.0.0 — маркера legacy нет" test -e "$REC"
ht_hook configure CREAM_REASON=install DESKTOP_AUTOLOGIN=; cp -p "$REC" "$ROOT/rec0"
ht_hook upgrade CREAM_PREV_VERSION=1.1.1; eq "upgrade поверх снимка — 0" 0 "$?"
check "снимок не заменён на legacy" same "$REC" "$ROOT/rec0"
desk_root; ht_fake apt-get 'exit 100'
ht_hook upgrade CREAM_PREV_VERSION=1.1.1; eq "upgrade: apt-get отказал — 1" 1 "$?"

echo "== 2.0.0: чужая запись — remove отказывает, файлы не тронуты =="
desk_root; st_paths; gdm_pkg custom.conf; CONF="$ROOT/etc/gdm3/custom.conf"; cp -p "$CONF" "$ROOT/orig.conf"
mkdir -p "$(dirname "$REC")"; printf 'garbage\n' > "$REC"
ht_hook remove; eq "чужая запись: remove — 1" 1 "$?"
check "чужая запись: файл не тронут" same "$CONF" "$ROOT/orig.conf"
check "чужая запись: запись оставлена" test -e "$REC"

echo "== 2.0.0: status знает sddm =="
desk_root; with_sddm; : > "$FAKE/active-sddm"
ht_action status; eq "status с sddm — 0" 0 "$?"
check "status: менеджер входа sddm" grep -q 'менеджер входа: sddm' <<< "$(ht_out)"
check "status: автологин SDDM — вручную" grep -q 'SDDM' <<< "$(ht_out)"
desk_root; with_sddm
ht_hook configure CREAM_REASON=boot DESKTOP_AUTOLOGIN=; eq "SDDM, пусто — 0" 0 "$?"
desk_root; st_paths; gdm_pkg custom.conf
ht_hook configure CREAM_REASON=install DESKTOP_AUTOLOGIN=
ht_action status; check "status: запись установки названа" grep -q 'прежний автологин: записан при установке' <<< "$(ht_out)"
mkdir -p "$(dirname "$REC")"; printf 'legacy\n' > "$REC"
ht_action status; check "status: legacy назван" grep -q 'прежний автологин: неизвестен' <<< "$(ht_out)"

echo "== 2.0.0: возврат побайтно — без перевода строки в конце, табуляция и повтор секции =="
desk_root; st_paths; mkdir -p "$ROOT/etc/lightdm"
printf '[Seat:*]\ngreeter=x\n\n[LightDM]\n\n[Seat:*]\n\tautologin-user =\tcarol\t\nautologin-user-timeout=3' > "$LDM"
cp -p "$LDM" "$ROOT/orig.conf"
ht_hook configure CREAM_REASON=install DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_BLANK=1; eq "1 — 0" 0 "$?"
ht_hook configure CREAM_REASON=apply DESKTOP_AUTOLOGIN=0 DESKTOP_DISABLE_SCREEN_BLANK=1; eq "0 — 0" 0 "$?"
check_not "0: carol снята" grep -q 'carol' "$LDM"
ht_hook configure CREAM_REASON=apply DESKTOP_AUTOLOGIN=; eq "пусто — 0" 0 "$?"
check "пусто: файл как был — вторая [Seat:*], табуляции, нет \\n в конце" same "$LDM" "$ROOT/orig.conf"
ht_hook remove; eq "remove — 0" 0 "$?"
check "remove: файл как был" same "$LDM" "$ROOT/orig.conf"

echo "== #156: Xubuntu — только системный conf.d LightDM, без /etc/lightdm =="
desk_root; st_paths
mkdir -p "$ROOT/usr/share/lightdm/lightdm.conf.d"
printf '[Seat:*]\nuser-session=xubuntu\ngreeter-session=lightdm-gtk-greeter\n' > "$ROOT/usr/share/lightdm/lightdm.conf.d/60-xubuntu.conf"
cp "$ROOT/usr/share/lightdm/lightdm.conf.d/60-xubuntu.conf" "$ROOT/vendor.orig"
AUTO="$ROOT/etc/lightdm/lightdm.conf.d/90-cream-desktop-autologin.conf"
ht_hook configure CREAM_REASON=install DESKTOP_AUTOLOGIN=1; eq "Xubuntu install — 0" 0 "$?"
check "автологин alice записан в локальный слой" grep -qx 'autologin-user=alice' "$AUTO"
check "вендорский слой цел" same "$ROOT/vendor.orig" "$ROOT/usr/share/lightdm/lightdm.conf.d/60-xubuntu.conf"
ht_hook configure CREAM_REASON=apply DESKTOP_AUTOLOGIN=0; eq "Xubuntu set 0 — 0" 0 "$?"
check "явно пустой autologin-user перекрывает вендора" grep -qx 'autologin-user=' "$AUTO"
ht_hook configure CREAM_REASON=apply DESKTOP_AUTOLOGIN=1; eq "Xubuntu set 1 — 0" 0 "$?"
ht_hook remove; eq "Xubuntu remove — 0" 0 "$?"
check_not "созданный локальный файл снят" test -e "$AUTO"
check "вендорский файл исходный" same "$ROOT/vendor.orig" "$ROOT/usr/share/lightdm/lightdm.conf.d/60-xubuntu.conf"
ht_hook remove; eq "Xubuntu remove повтор — 0" 0 "$?"
ht_hook configure CREAM_REASON=install DESKTOP_AUTOLOGIN=1; eq "Xubuntu reinstall — 0" 0 "$?"
check "reinstall включает автологин" grep -qx 'autologin-user=alice' "$AUTO"
ht_hook configure CREAM_REASON=apply DESKTOP_AUTOLOGIN=; eq "Xubuntu пустой ключ — 0" 0 "$?"
check_not "пустой ключ вернул отсутствие файла" test -e "$AUTO"

ht_done
