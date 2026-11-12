#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the cloud-user-desktop extension (cream/v1): manifest, hooks install
# and remove on a scratch root (CREAM_ROOT) the way cream runs them. getent, id
# and userdel are fakes over $FAKE/passwd; no root, no real accounts.
#
# Held here: the vendor account is removed only when named, only a regular
# account (uid >= 1000) and only by a name of the right form; an account that
# survives userdel fails the hook (an image must not carry a known password);
# the desktop settings are the desktop extension's (depends), not a copy here.
# 6.0.0: live: confirm (userdel -r is irreversible); the autologin of gdm3 and
# LightDM is taken away only where it names the removed account — another
# account's autologin, a commented key and a link are left alone.
#
#   extensions/debian/cloud-user-desktop/tests/test-cloud-user-desktop.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

fresh() {
    ht_root "$EXT"
    printf '%s\n' 'root:x:0:0::/root:/bin/bash' 'daemon:x:1:1::/usr/sbin:/usr/sbin/nologin' \
        'jetson:x:1000:1000::/home/jetson:/bin/bash' 'alice:x:1001:1001::/home/alice:/bin/bash' > "$FAKE/passwd"
    ht_fake getent '[[ "$1" == passwd ]] || exit 2; [[ -z "${2-}" ]] && { cat "$FAKE/passwd"; exit 0; }
grep -E "^${2}:" "$FAKE/passwd" || exit 2'
    ht_fake id 'grep -qE "^${*: -1}:" "$FAKE/passwd"'
    # userdel [-r] NAME: $FAKE/userdel-busy — the account is in use (exit 8),
    # $FAKE/userdel-r-fails — only the form with -r fails.
    ht_fake userdel '[[ -f "$FAKE/userdel-busy" ]] && exit 8
[[ "$1" == -r && -f "$FAKE/userdel-r-fails" ]] && exit 12
sed -i "/^${*: -1}:/d" "$FAKE/passwd"'
}
has_user() { grep -qE "^$1:" "$FAKE/passwd"; }

echo "== манифест =="
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 6 (live: confirm, автологин удалённой учётки)" 6.0.0 "$(mf 'm["version"]')"
eq "desktop <3 (desktop 2.0.0)" ">=1.0.0 <3" "$(mf 'next(d["version"] for d in m["depends"] if d["name"] == "desktop")')"
eq "cream >= 1.0.0" '>=1.0.0' "$(mf 'm["cream"]')"
eq "build: exec" exec "$(mf 'm["targets"]["build"]')"
eq "live: confirm (userdel -r необратим)" confirm "$(mf 'm["targets"]["live"]')"
check "live_note: userdel -r" grep -q 'userdel -r' <<< "$(mf 'm["targets"]["live_note"]')"
check "live_note: автологин" grep -q 'автологин' <<< "$(mf 'm["targets"]["live_note"]')"
eq "depends desktop и cloud-user" "cloud-user,desktop" "$(mf '",".join(sorted(d["name"] for d in m["depends"]))')"
eq "provides без изменений" "['cloud-user-desktop']" "$(mf 'm["provides"]')"
eq "хуки install и remove, своей службы нет" "['install', 'remove']" "$(mf 'sorted(m["hooks"])')"
eq "ключ учётки — scope install" install "$(mf 'm["config"]["keys"]["CLOUD_USER_DESKTOP_REMOVE"]["scope"]')"
eq "ключ учётки — пустой по умолчанию" "" "$(mf 'm["config"]["keys"]["CLOUD_USER_DESKTOP_REMOVE"]["default"]')"
check "ключ учётки — форма имени" grep -qF '^[a-z_][a-z0-9_-]{0,31}$' <<< "$(mf 'm["config"]["keys"]["CLOUD_USER_DESKTOP_REMOVE"]["type"]')"
check_not "files не нужны" grep -q files <<< "$(mf 'list(m)')"
for old in install.sh lib; do check_not "layout 2: $old убран" test -e "$EXT/$old"; done
check_not "без юнитов в дереве" bash -c 'find "$1" -name "*.service" | grep -q .' _ "$EXT"

echo "== install: учётка не задана — ничего не удаляется =="
fresh
ht_hook install; eq "install — 0" 0 "$?"
check_not "userdel не звали" ht_called '^userdel'
check "jetson на месте" has_user jetson
check "сказано, что не запрошено" grep -q 'не запрошено' <<< "$(ht_out)"

echo "== install: вендорская учётка удаляется вместе с домом =="
fresh
HT_PHASE=build ht_hook install CLOUD_USER_DESKTOP_REMOVE=jetson; eq "install — 0" 0 "$?"
check "userdel -r jetson" ht_called '^userdel -r (-- )?jetson$'
check_not "jetson удалён" has_user jetson
check "alice не тронута" has_user alice

echo "== install: повтор — учётки уже нет, 0 и без userdel =="
: > "$FAKE/calls"
HT_PHASE=build ht_hook install CLOUD_USER_DESKTOP_REMOVE=jetson; eq "повтор — 0" 0 "$?"
check_not "повтор: userdel не звали" ht_called '^userdel'

echo "== install: -r отказал — удаление без дома =="
fresh
: > "$FAKE/userdel-r-fails"
ht_hook install CLOUD_USER_DESKTOP_REMOVE=jetson; eq "install — 0" 0 "$?"
check "второй заход без -r" ht_called '^userdel (-- )?jetson$'
check_not "jetson удалён" has_user jetson

echo "== install: учётка занята и осталась — отказ, а не предупреждение =="
fresh
: > "$FAKE/userdel-busy"
ht_hook install CLOUD_USER_DESKTOP_REMOVE=jetson; rc=$?
check "install — не 0" test "$rc" -ne 0
check "jetson остался" has_user jetson
check "отказ назван" grep -q 'осталась' <<< "$(ht_out)"

echo "== install: системные учётки и root не удаляются =="
for u in root daemon; do
    fresh
    ht_hook install CLOUD_USER_DESKTOP_REMOVE="$u"; rc=$?
    check "$u: install — не 0" test "$rc" -ne 0
    check_not "$u: userdel не звали" ht_called '^userdel'
    check "$u: на месте" has_user "$u"
done

echo "== install: имя чужой формы — отказ до любых команд =="
for bad in '../etc' 'a b' '-r' 'Jetson' '$(id)' 'x;rm'; do
    fresh
    ht_hook install CLOUD_USER_DESKTOP_REMOVE="$bad"; rc=$?
    check "[$bad]: install — не 0" test "$rc" -ne 0
    check_not "[$bad]: userdel не звали" ht_called '^userdel'
    check_not "[$bad]: getent не звали" ht_called '^getent'
done

echo "== install: автологин gdm3 и LightDM на удалённую учётку снят (6.0.0) =="
# dm_confs: the vendor's configs — gdm3 daemon.conf (Debian) and custom.conf
# (Ubuntu), LightDM lightdm.conf and a drop-in — all with the autologin of jetson.
dm_confs() {
    mkdir -p "$ROOT/etc/gdm3" "$ROOT/etc/lightdm/lightdm.conf.d"
    printf '%s\n' '# GDM configuration' '[daemon]' 'AutomaticLoginEnable=true' 'AutomaticLogin=jetson' \
        'WaylandEnable=false' '' '[security]' '' '[debug]' > "$ROOT/etc/gdm3/custom.conf"
    printf '%s\n' '[daemon]' 'TimedLoginEnable = true' 'TimedLogin = jetson' 'TimedLoginDelay=10' \
        '#AutomaticLogin=jetson' > "$ROOT/etc/gdm3/daemon.conf"
    printf '%s\n' '[Seat:*]' 'greeter-session=lightdm-gtk-greeter' 'autologin-user=jetson' \
        'autologin-user-timeout=0' 'user-session=ubuntu' > "$ROOT/etc/lightdm/lightdm.conf"
    printf '%s\n' '[SeatDefaults]' 'autologin-user=jetson' > "$ROOT/etc/lightdm/lightdm.conf.d/50-vendor.conf"
    chmod 0640 "$ROOT/etc/gdm3/custom.conf"
}
fresh; dm_confs
HT_PHASE=build ht_hook install CLOUD_USER_DESKTOP_REMOVE=jetson; eq "install — 0" 0 "$?"
check_not "jetson удалён" has_user jetson
check_not "gdm3 custom.conf: AutomaticLogin=jetson снят" grep -q '^AutomaticLogin=' "$ROOT/etc/gdm3/custom.conf"
check_not "gdm3 custom.conf: AutomaticLoginEnable снят" grep -q '^AutomaticLoginEnable' "$ROOT/etc/gdm3/custom.conf"
check "gdm3 custom.conf: чужие ключи на месте" grep -qx 'WaylandEnable=false' "$ROOT/etc/gdm3/custom.conf"
check "gdm3 custom.conf: секции на месте" grep -qx '\[security\]' "$ROOT/etc/gdm3/custom.conf"
eq "gdm3 custom.conf: права файла те же" 640 "$(stat -c %a "$ROOT/etc/gdm3/custom.conf")"
check_not "gdm3 daemon.conf: TimedLogin=jetson снят" grep -qE '^TimedLogin[[:space:]]*=' "$ROOT/etc/gdm3/daemon.conf"
check_not "gdm3 daemon.conf: TimedLoginEnable снят" grep -q '^TimedLoginEnable' "$ROOT/etc/gdm3/daemon.conf"
check_not "gdm3 daemon.conf: TimedLoginDelay снят" grep -q '^TimedLoginDelay' "$ROOT/etc/gdm3/daemon.conf"
check "gdm3 daemon.conf: закомментированный ключ не тронут" grep -qx '#AutomaticLogin=jetson' "$ROOT/etc/gdm3/daemon.conf"
check_not "lightdm.conf: autologin-user снят" grep -q '^autologin-user' "$ROOT/etc/lightdm/lightdm.conf"
check "lightdm.conf: чужие ключи на месте" grep -qx 'user-session=ubuntu' "$ROOT/etc/lightdm/lightdm.conf"
check_not "lightdm.conf.d: autologin-user снят" grep -q '^autologin-user' "$ROOT/etc/lightdm/lightdm.conf.d/50-vendor.conf"
check "сказано, где снят" grep -q 'автологин' <<< "$(ht_out)"

echo "== install: повтор — учётки нет, автологин на неё всё равно снимается =="
fresh; dm_confs
sed -i '/^jetson:/d' "$FAKE/passwd"
ht_hook install CLOUD_USER_DESKTOP_REMOVE=jetson; eq "install — 0" 0 "$?"
check_not "userdel не звали" ht_called '^userdel'
check_not "автологин jetson снят" grep -q '^AutomaticLogin=jetson' "$ROOT/etc/gdm3/custom.conf"
before="$(cat "$ROOT/etc/gdm3/custom.conf")"
ht_hook install CLOUD_USER_DESKTOP_REMOVE=jetson; eq "ещё повтор — 0" 0 "$?"
eq "ещё повтор: файл не меняется" "$before" "$(cat "$ROOT/etc/gdm3/custom.conf")"

echo "== install: автологин другой учётки не тронут =="
fresh
mkdir -p "$ROOT/etc/gdm3" "$ROOT/etc/lightdm"
printf '%s\n' '[daemon]' 'AutomaticLoginEnable=true' 'AutomaticLogin=alice' > "$ROOT/etc/gdm3/custom.conf"
printf '%s\n' '[Seat:*]' 'autologin-user=alice' 'autologin-user-timeout=0' > "$ROOT/etc/lightdm/lightdm.conf"
printf '%s\n' '[daemon]' 'AutomaticLoginEnable=true' 'AutomaticLogin=jetson2' > "$ROOT/etc/gdm3/daemon.conf"
cp "$ROOT/etc/gdm3/custom.conf" "$ROOT/gdm.orig"; cp "$ROOT/etc/lightdm/lightdm.conf" "$ROOT/lightdm.orig"
cp "$ROOT/etc/gdm3/daemon.conf" "$ROOT/daemon.orig"
ht_hook install CLOUD_USER_DESKTOP_REMOVE=jetson; eq "install — 0" 0 "$?"
check "gdm3: автологин alice побайтно тот же" cmp -s "$ROOT/gdm.orig" "$ROOT/etc/gdm3/custom.conf"
check "lightdm: автологин alice побайтно тот же" cmp -s "$ROOT/lightdm.orig" "$ROOT/etc/lightdm/lightdm.conf"
check "gdm3: jetson2 — не jetson, не тронут" cmp -s "$ROOT/daemon.orig" "$ROOT/etc/gdm3/daemon.conf"

echo "== install: два сиденья LightDM — снят только автологин jetson =="
fresh
mkdir -p "$ROOT/etc/lightdm"
printf '%s\n' '[Seat:seat0]' 'autologin-user=jetson' 'autologin-user-timeout=0' \
    '[Seat:seat1]' 'autologin-user=alice' 'autologin-user-timeout=5' > "$ROOT/etc/lightdm/lightdm.conf"
ht_hook install CLOUD_USER_DESKTOP_REMOVE=jetson; eq "install — 0" 0 "$?"
check_not "seat0: jetson снят" grep -qx 'autologin-user=jetson' "$ROOT/etc/lightdm/lightdm.conf"
check_not "seat0: таймаут снят" grep -qx 'autologin-user-timeout=0' "$ROOT/etc/lightdm/lightdm.conf"
check "seat1: alice на месте" grep -qx 'autologin-user=alice' "$ROOT/etc/lightdm/lightdm.conf"
check "seat1: таймаут на месте" grep -qx 'autologin-user-timeout=5' "$ROOT/etc/lightdm/lightdm.conf"

echo "== install: нет конфигов менеджера входа — 0 =="
fresh
HT_PHASE=build ht_hook install CLOUD_USER_DESKTOP_REMOVE=jetson; eq "install — 0" 0 "$?"
check_not "jetson удалён" has_user jetson
check_not "конфигов не создано" test -e "$ROOT/etc/gdm3"
check_not "конфигов lightdm не создано" test -e "$ROOT/etc/lightdm"

echo "== install: конфиг — ссылка — не идём по ней =="
fresh
mkdir -p "$ROOT/etc/gdm3" "$ROOT/victim"
printf '%s\n' '[daemon]' 'AutomaticLogin=jetson' > "$ROOT/victim/custom.conf"
ln -s "$ROOT/victim/custom.conf" "$ROOT/etc/gdm3/custom.conf"
ht_hook install CLOUD_USER_DESKTOP_REMOVE=jetson; eq "install — 0 (учётки нет, ссылка — предупреждение)" 0 "$?"
check "цель ссылки не тронута" grep -qx 'AutomaticLogin=jetson' "$ROOT/victim/custom.conf"
check "ссылка осталась ссылкой" test -L "$ROOT/etc/gdm3/custom.conf"
check "предупреждение про ссылку" grep -q 'ссылка' <<< "$(ht_out)"

echo "== install: ключ пуст или учётка осталась — конфиги не трогаются =="
fresh; dm_confs; cp "$ROOT/etc/gdm3/custom.conf" "$ROOT/gdm.orig"
ht_hook install; eq "пустой ключ — 0" 0 "$?"
check "пустой ключ: gdm3 тот же" cmp -s "$ROOT/gdm.orig" "$ROOT/etc/gdm3/custom.conf"
fresh; dm_confs; cp "$ROOT/etc/gdm3/custom.conf" "$ROOT/gdm.orig"
: > "$FAKE/userdel-busy"
ht_hook install CLOUD_USER_DESKTOP_REMOVE=jetson; rc=$?
check "занятая учётка — не 0" test "$rc" -ne 0
check "занятая учётка: gdm3 тот же" cmp -s "$ROOT/gdm.orig" "$ROOT/etc/gdm3/custom.conf"

echo "== remove: ничего не возвращает и не падает =="
fresh
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "remove: userdel не звали" ht_called '^userdel'
ht_hook remove; eq "remove повтор — 0" 0 "$?"

ht_done
