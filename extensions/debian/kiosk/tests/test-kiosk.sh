#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the kiosk extension (cream/v1): manifest, hooks install, configure
# and remove, and the browser wrapper files/run-kiosk.sh, on a scratch root
# (CREAM_ROOT) the way cream runs them. apt-get, dpkg-query, getent, id,
# systemctl, dconf, sleep, xdpyinfo, pgrep and chromium are fakes, the
# cloud-user library is a stub. No root, systemd, X or display manager.
#
# Held here: nothing is written into the user's home (the panel and the desktop
# of Xfce4 are system defaults — `files`; the on-screen keyboard of GNOME is a
# system dconf keyfile); the browser runs as the session user, never as root;
# configuration values reach the browser only after a form check, and the unit
# runs the wrapper without a shell.
#
#   extensions/debian/kiosk/tests/test-kiosk.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

PKGS="chromium x11-utils x11-xserver-utils xauth dbus-x11"
UNIT=kiosk-chromium@.service

# kroot: a fresh root; users alice (1000) and bob (1001), root (0); the
# cloud-init user from $FAKE/user; a display manager enabled.
kroot() {
    ht_root "$EXT"
    SD="$ROOT/etc/systemd/system"
    WANTS="$SD/graphical.target.wants"
    STATE="$ROOT/var/lib/cream/ext/kiosk"
    KBD="$ROOT/etc/dconf/db/local.d/50-kiosk-keyboard"
    mkdir -p "$SD" "$ROOT/home/alice" "$ROOT/home/bob"
    ln -s /lib/systemd/system/lightdm.service "$SD/display-manager.service"
    install -m 0644 "$EXT/files/$UNIT" "$SD/$UNIT"
    printf '%s\n' 'root:x:0:0::/root:/bin/bash' 'alice:x:1000:1000::/home/alice:/bin/bash' \
        'bob:x:1001:1001::/home/bob:/bin/bash' > "$FAKE/passwd"
    echo alice > "$FAKE/user"
    ht_fake getent 'f="$FAKE/$1"; [[ -f "$f" ]] || exit 2; [[ -z "${2-}" ]] && { cat "$f"; exit 0; }; grep -E "^${2}:" "$f" || exit 2'
    ht_fake id '
[[ "$*" == -u ]] && { cat "$FAKE/self-uid" 2>/dev/null || echo 1000; exit 0; }
u="${*: -1}"
line="$(grep -E "^${u}:" "$FAKE/passwd")" || exit 1
case "$1" in -u) cut -d: -f3 <<< "$line" ;; *) ;; esac'
    ht_fake systemctl 'exit 0'
    ht_fake dpkg-query 'p="${*: -1}"; [[ -f "$FAKE/pkg-$p" ]] && printf installed; exit 0'
    ht_fake apt-get 'if [[ " $* " == *" install "* ]]; then
  for a in "$@"; do case "$a" in -*|install|Dpkg::*) ;; *) : > "$FAKE/pkg-$a" ;; esac; done
fi; exit 0'
    ht_fake dconf 'exit 0'
    ht_fake sleep
    LIB="$ROOT/opt/cream/ext/cloud-user/get_cloud_user.sh"
    mkdir -p "$(dirname "$LIB")"
    printf '#!/usr/bin/env bash\ncat %q 2>/dev/null || { echo "no user" >&2; exit 1; }\n' "$FAKE/user" > "$LIB"
    chmod +x "$LIB"
}
live_systemd() { mkdir -p "$ROOT/run/systemd/system"; }
link_of() { readlink "$WANTS/kiosk-chromium@$1.service" 2>/dev/null; }
no_home_writes() { [[ -z "$(find "$ROOT/home" -mindepth 2 -print -quit)" ]]; }

echo "== манифест =="
# eval: test-only literal expressions over our own manifest, as in nvidia-jetpack.
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 4" 4.0.0 "$(mf 'm["version"]')"
eq "cream >=1.1.0 (стадия graphical)" ">=1.1.0" "$(mf 'm["cream"]')"
eq "live: confirm" confirm "$(mf 'm["targets"]["live"]')"
check "live_note про захват экрана" grep -q 'экран' <<< "$(mf 'm["targets"]["live_note"]')"
eq "стадия graphical" graphical "$(mf 'm["hooks"]["configure"]["stage"]')"
eq "хуки" "['configure', 'install', 'remove']" "$(mf 'sorted(m["hooks"])')"
eq "depends cloud-user" "cloud-user >=1.0.0 <2" "$(mf '" ".join(d["name"]+" "+d["version"] for d in m["depends"])')"
eq "конфликт с chromium-kiosk" "['chromium-kiosk']" "$(mf 'm["conflicts"]["extensions"]')"
eq "requires" "['x11-server', 'display-manager']" "$(mf 'm["requires"]')"
eq "files" "files/kiosk-chromium@.service:/etc/systemd/system/kiosk-chromium@.service files/run-kiosk.sh:/usr/local/lib/kiosk/run-kiosk.sh files/xfce4-desktop.xml:/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml files/xfce4-panel.xml:/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml" \
    "$(mf '" ".join(sorted(f["src"]+":"+f["dst"] for f in m["files"]))')"
eq "run-kiosk.sh исполняемый (files)" 0755 "$(mf '[f["mode"] for f in m["files"] if f["src"].endswith("run-kiosk.sh")][0]')"
for f in install.sh configure.sh knobs knobs.apply configure-kiosk.service run-kiosk.sh kiosk-chromium@.service; do
    check_not "layout 2: нет $f" test -e "$EXT/$f"
done

echo "== юнит: без оболочки, от пользователя, EnvironmentFile =="
U="$EXT/files/$UNIT"
check "User=%i" grep -qx 'User=%i' "$U"
check "EnvironmentFile домена" grep -qx 'EnvironmentFile=-/etc/cream/kiosk/config' "$U"
check "ExecStart — обёртка напрямую" grep -qx 'ExecStart=/usr/local/lib/kiosk/run-kiosk.sh %i' "$U"
check_not "без bash -c и \$ в ExecStart" grep -qE '^ExecStart=.*(bash|sh -c|\$)' "$U"
check "WantedBy graphical.target" grep -qx 'WantedBy=graphical.target' "$U"

echo "== install =="
kroot
ht_hook install; eq "install — 0" 0 "$?"
check "ставит браузер и утилиты X" ht_called '^apt-get .*install .*chromium .*x11-utils'
eq "состояние: пакеты" "$PKGS" "$(tr '\n' ' ' < "$STATE/packages" | sed 's/ $//')"
check_not "install экземпляр не включает" test -e "$WANTS"
: > "$FAKE/calls"
ht_hook install; eq "повтор — 0" 0 "$?"
check_not "повтор: apt не звали" ht_called '^apt-get '
eq "повтор: состояние то же" "$PKGS" "$(tr '\n' ' ' < "$STATE/packages" | sed 's/ $//')"

echo "== configure: менеджера входа нет — предупреждение, 0 =="
kroot
rm -f -- "$SD/display-manager.service"
ht_hook configure CREAM_REASON=boot; eq "без DM — 0" 0 "$?"
check "предупреждение про менеджер входа" grep -q 'менеджер' <(ht_out)
check_not "экземпляр не включён" test -e "$WANTS/kiosk-chromium@alice.service"
kroot
rm -f -- "$FAKE/user"
ht_hook configure CREAM_REASON=boot; eq "нет пользователя — 0" 0 "$?"
check "предупреждение про пользователя" grep -q 'пользовател' <(ht_out)
check_not "экземпляр не включён" test -e "$WANTS"

echo "== configure: включает экземпляр пользователя cloud-init =="
kroot
ht_hook configure CREAM_REASON=boot; eq "boot — 0" 0 "$?"
eq "экземпляр alice" "/etc/systemd/system/$UNIT" "$(link_of alice)"
check_not "build/без systemd: не запускает" ht_called '^systemctl '
check "без записей в /home" no_home_writes
kroot; live_systemd
ht_hook configure CREAM_REASON=install; eq "live — 0" 0 "$?"
check "перезапуск --no-block" ht_called '^systemctl --no-block restart kiosk-chromium@alice\.service$'
check_not "блокирующего systemctl нет" ht_called '^systemctl (start|restart|stop) '

echo "== configure: KIOSK_USER и смена пользователя =="
kroot; live_systemd
ht_hook configure CREAM_REASON=apply; eq "alice — 0" 0 "$?"
: > "$FAKE/calls"
ht_hook configure CREAM_REASON=apply KIOSK_USER=bob; eq "KIOSK_USER=bob — 0" 0 "$?"
eq "экземпляр bob" "/etc/systemd/system/$UNIT" "$(link_of bob)"
check_not "прежний экземпляр alice выключен" test -e "$WANTS/kiosk-chromium@alice.service"
check "прежний остановлен --no-block" ht_called '^systemctl --no-block stop kiosk-chromium@alice\.service$'
ht_hook configure CREAM_REASON=apply KIOSK_USER=carol; eq "KIOSK_USER нет в системе — 0" 0 "$?"
check "предупреждение про carol" grep -q 'carol' <(ht_out)
ht_hook configure CREAM_REASON=apply KIOSK_USER=root; eq "KIOSK_USER=root — 0, отказ" 0 "$?"
check_not "от root браузер не включается" test -e "$WANTS/kiosk-chromium@root.service"
check "сообщение про root" grep -q 'root' <(ht_out)
ht_hook configure CREAM_REASON=apply 'KIOSK_USER=a;b'; eq "KIOSK_USER не имя — 0, отказ" 0 "$?"
check_not "экземпляр с мусором не создан" test -e "$WANTS/kiosk-chromium@a;b.service"

echo "== экранная клавиатура GNOME — системный dconf =="
kroot
mkdir -p "$ROOT/usr/bin"; : > "$ROOT/usr/bin/gnome-shell"; chmod +x "$ROOT/usr/bin/gnome-shell"
ht_hook configure CREAM_REASON=boot; eq "gnome — 0" 0 "$?"
check "keyfile dconf" grep -qx 'screen-keyboard-enabled=true' "$KBD"
check "профиль dconf с system-db:local" grep -qx 'system-db:local' "$ROOT/etc/dconf/profile/user"
check "dconf update" ht_called '^dconf update$'
check "без записей в /home" no_home_writes
cp "$KBD" "$ROOT/kbd1"; : > "$FAKE/calls"
ht_hook configure CREAM_REASON=boot; eq "повтор — 0" 0 "$?"
check_not "повтор: dconf update не нужен" ht_called '^dconf update'
ht_hook configure CREAM_REASON=apply KIOSK_KEYBOARD_ENABLED=false; eq "клавиатура выкл — 0" 0 "$?"
check_not "keyfile снят" test -e "$KBD"
kroot
ht_hook configure CREAM_REASON=boot; eq "не gnome — 0" 0 "$?"
check_not "не gnome: keyfile не пишется" test -e "$KBD"

echo "== remove =="
kroot; live_systemd
ht_hook install; ht_hook configure CREAM_REASON=install
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "экземпляры выключены" test -e "$WANTS/kiosk-chromium@alice.service"
check "остановлен --no-block" ht_called '^systemctl --no-block stop kiosk-chromium@alice\.service$'
check "свои пакеты сняты" ht_called '^apt-get .*remove .*chromium'
check_not "состояние снято" test -e "$STATE/packages"
: > "$FAKE/calls"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
check_not "повтор: apt не звали" ht_called '^apt-get '

# --- files/run-kiosk.sh ------------------------------------------------------
echo "== обёртка: проверка формы и запуск без оболочки =="
W="$EXT/files/run-kiosk.sh"
kroot
ht_fake xdpyinfo 'exit 0'
ht_fake pgrep 'exit 1'
ht_fake chromium 'printf "%s\n" "$@" > "$FAKE/chromium.args"; exit 0'
mkdir -p "$ROOT/home/alice"; : > "$ROOT/home/alice/.Xauthority"
# rk [VAR=VALUE…]: the wrapper the way the unit runs it (EnvironmentFile keys).
rk() {
    (cd "$ROOT" && exec env -i PATH="$ROOT/bin:/usr/bin:/bin" XAUTHORITY="$ROOT/home/alice/.Xauthority" \
        "$@" "$W" alice) > "$ROOT/out" 2>&1
}
rk; eq "умолчания — 0" 0 "$?"
eq "адрес — последний аргумент" "https://github.com/iamletenkov/bisquite" "$(tail -1 "$FAKE/chromium.args")"
check "--kiosk" grep -qx -- '--kiosk' "$FAKE/chromium.args"
check "флаги по умолчанию" grep -qx -- '--disable-pinch' "$FAKE/chromium.args"
rk 'KIOSK_URL=https://example.org/a?b=1&c=$(id)'; eq "\$ в адресе — отказ 1" 1 "$?"
rk "KIOSK_URL=https://example.org/'x"; eq "кавычка в адресе — отказ 1" 1 "$?"
rk 'KIOSK_URL=javascript:alert(1)'; eq "не http(s)/file — отказ 1" 1 "$?"
rk 'KIOSK_URL=https://example.org/kiosk?id=7&mode=full'; eq "адрес с & и ? — 0" 0 "$?"
eq "адрес передан как есть" 'https://example.org/kiosk?id=7&mode=full' "$(tail -1 "$FAKE/chromium.args")"
rk 'KIOSK_DISPLAY=:0;id'; eq "дисплей не по форме — отказ 1" 1 "$?"
rk 'KIOSK_CHROMIUM_FLAGS=--a $(id)'; eq "флаг не по форме — отказ 1" 1 "$?"
rk 'KIOSK_CHROMIUM_FLAGS=--force-device-scale-factor=1.5 --incognito'; eq "флаги по форме — 0" 0 "$?"
check "флаг передан" grep -qx -- '--force-device-scale-factor=1.5' "$FAKE/chromium.args"
check_not "умолчание флагов заменено, не дописано" grep -qx -- '--disable-pinch' "$FAKE/chromium.args"
echo 0 > "$FAKE/self-uid"
rk; eq "от root — отказ 1" 1 "$?"
check "сообщение про root" grep -q 'root' "$ROOT/out"
check "умолчания обёртки = умолчания манифеста" bash -c '
    m="$(python3 -c "import sys,yaml; k=yaml.safe_load(open(sys.argv[1]))[\"config\"][\"keys\"]; print(k[\"KIOSK_URL\"][\"default\"]); print(k[\"KIOSK_DISPLAY\"][\"default\"]); print(k[\"KIOSK_CHROMIUM_FLAGS\"][\"default\"])" "$1/extension.yaml")"
    w="$(sed -n "s/^DEFAULT_\(URL\|DISPLAY\|FLAGS\)=\"\(.*\)\"$/\2/p" "$1/files/run-kiosk.sh")"
    [[ "$m" == "$w" ]]' _ "$EXT"

ht_done
