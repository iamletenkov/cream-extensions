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
eq "версия 1.0.0 (новое расширение)" 1.0.0 "$(mf 'm["version"]')"
eq "cream 1.0" ">=1.0.0" "$(mf 'm["cream"]')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "хуки" "configure install remove" "$(mf '" ".join(sorted(m["hooks"]))')"
eq "Р5: стадия system, не graphical" system "$(mf 'm["hooks"]["configure"]["stage"]')"
eq "Р5: after" "cloud-init.service guestfs-firstboot.service" "$(mf '" ".join(m["hooks"]["configure"]["after"])')"
eq "Р5: before — менеджеры входа" "display-manager.service gdm.service gdm3.service lightdm.service" \
    "$(mf '" ".join(m["hooks"]["configure"]["before"])')"
eq "Р5: без after cloud-final (цикл с multi-user)" False "$(mf '"cloud-final.service" in m["hooks"]["configure"].get("after", [])')"
eq "depends cloud-user" "cloud-user >=1.0.0 <2" "$(mf '" ".join(d["name"]+" "+d["version"] for d in m["depends"])')"
eq "ключи" "DESKTOP_AUTOLOGIN DESKTOP_AUTOLOGIN_USER DESKTOP_DISABLE_SCREEN_BLANK DESKTOP_DISABLE_SCREEN_LOCK" \
    "$(mf '" ".join(sorted(m["config"]["keys"]))')"
eq "умолчания — всё выключено" "0 0 0" \
    "$(mf '" ".join(m["config"]["keys"][k]["default"] for k in ("DESKTOP_AUTOLOGIN","DESKTOP_DISABLE_SCREEN_LOCK","DESKTOP_DISABLE_SCREEN_BLANK"))')"
eq "DESKTOP_AUTOLOGIN_USER может быть пустым" True "$(mf 'm["config"]["keys"]["DESKTOP_AUTOLOGIN_USER"]["empty"]')"
eq "действия" "apply defaults status" "$(mf '" ".join(sorted(m["actions"]))')"
eq "apply — lock exclusive" exclusive "$(mf 'm["actions"]["apply"]["lock"]')"
eq "status — lock none" none "$(mf 'm["actions"]["status"]["lock"]')"
eq "defaults — pairs по ключам домена" "DESKTOP_AUTOLOGIN DESKTOP_AUTOLOGIN_USER DESKTOP_DISABLE_SCREEN_BLANK DESKTOP_DISABLE_SCREEN_LOCK" \
    "$(mf '" ".join(sorted(m["actions"]["defaults"]["params"]))')"
for f in hooks/install hooks/configure hooks/remove actions/apply actions/status actions/defaults files/desktop.sh; do
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

ht_done
