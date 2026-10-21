#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the wallpaper extension (cream/v1): manifest, hooks install,
# configure and remove on a scratch root (CREAM_ROOT) the way cream runs them.
# apt-get, dconf, getent, runuser and sleep are fakes; the cloud-user library
# is a stub. No root, display, dconf or desktop is needed.
#
# Held here: the wallpaper is a system default under /etc (dconf with locks for
# GNOME, an xfconf channel for Xfce, pcmanfm.conf for LXDE) — root writes
# nothing into a home directory and runs nothing as the user; the picture is
# only a file of the extension's own images/ (form of the name, no symlink, no
# way out of the directory); the mode is one of a fixed set; every write goes
# through a temporary file and a rename, a symlinked package file is left
# alone; a repeat changes nothing; remove puts back what was there.
#
#   extensions/debian/wallpaper/tests/test-wallpaper.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

IMG=/opt/cream/ext/wallpaper/images/dst_1080.jpg
KF_REL=etc/dconf/db/local.d/50-wallpaper
LK_REL=etc/dconf/db/local.d/locks/50-wallpaper
XF_REL=etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml
PC_REL=etc/xdg/pcmanfm/LXDE/pcmanfm.conf

# fresh [gnome|xfce|lxde…]: a root with fakes and the named desktops present.
#   gnome — /usr/bin/dconf under the root (dconf-cli; the fake on PATH runs);
#   xfce — the xfconf system directory; lxde — the pcmanfm.conf of lxde-common.
#   apt-get installing dconf-cli puts /usr/bin/dconf in place.
fresh() {
    ht_root "$EXT"
    KF="$ROOT/$KF_REL"; LK="$ROOT/$LK_REL"; XF="$ROOT/$XF_REL"; PC="$ROOT/$PC_REL"
    STATE="$ROOT/var/lib/cream/ext/wallpaper"
    mkdir -p "$ROOT/home/alice" "$ROOT/opt/cream/ext/cloud-user"
    printf '#!/bin/sh\necho alice\n' > "$ROOT/opt/cream/ext/cloud-user/get_cloud_user.sh"
    chmod +x "$ROOT/opt/cream/ext/cloud-user/get_cloud_user.sh"
    printf '%s\n' "alice:x:1000:1000::/home/alice:/bin/bash" > "$FAKE/passwd"
    ht_fake getent '[[ "$1" == passwd ]] || exit 2; grep -E "^${2}:" "$FAKE/passwd" || exit 2'
    ht_fake runuser 'exit 0'
    ht_fake sleep
    mkdir -p "$ROOT/usr/bin"
    ht_fake apt-get '[[ " $* " == *" install "* && " $* " == *" dconf-cli "* ]] && { : > "'"$ROOT"'/usr/bin/dconf"; chmod +x "'"$ROOT"'/usr/bin/dconf"; }; exit 0'
    ht_fake dconf '[[ "$1" == update ]] && : > "'"$ROOT"'/etc/dconf/db/local"; exit 0'
    local d
    for d in "$@"; do
        case "$d" in
            gnome) : > "$ROOT/usr/bin/dconf"; chmod +x "$ROOT/usr/bin/dconf" ;;
            xfce) mkdir -p "${XF%/*}" ;;
            lxde)
                mkdir -p "${PC%/*}"
                printf '[config]\nbm_open_method=0\n\n[desktop]\nwallpaper_mode=crop\nwallpaper=/etc/alternatives/desktop-background\ndesktop_bg=#000000\n' > "$PC"
                chmod 0644 "$PC" ;;
        esac
    done
}
home_empty() { [[ -z "$(find "$ROOT/home/alice" -mindepth 1 -print -quit)" ]]; }
sum_etc() { find "$ROOT/etc" -type f -print0 | sort -z | xargs -0 -r sha256sum; }
ini_get() { awk -F= -v s="$2" -v k="$3" '/^\[/{c=($0=="["s"]")} c && $1==k {print substr($0, length(k)+2)}' "$1"; }

echo "== манифест =="
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "версия 3.0.2" 3.0.2 "$(mf 'm["version"]')"
eq "configure по отметке — every_boot нет (аудит 2026-10-21)" None "$(mf 'm["hooks"]["configure"].get("every_boot")')"
check "исключение every-boot в хуке" grep -q "^# cream-lint: every-boot-not-needed " "$EXT/hooks/configure"
eq "cream >= 1.1.1 (стадия cloud-user, Р14)" '>=1.1.1' "$(mf 'm["cream"]')"
eq "build: exec" exec "$(mf 'm["targets"]["build"]')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "стадия cloud-user" cloud-user "$(mf 'm["hooks"]["configure"]["stage"]')"
eq "без after/before (порядок — сама стадия)" "[]" "$(mf 'sorted(k for k in m["hooks"]["configure"] if k in ("after", "before"))')"
eq "depends cloud-user" cloud-user "$(mf '",".join(d["name"] for d in m["depends"])')"
eq "requires desktop-session" "['desktop-session']" "$(mf 'm["requires"]')"
eq "provides без изменений" "['wallpaper']" "$(mf 'm["provides"]')"
eq "хуки install, configure, remove" "['configure', 'install', 'remove']" "$(mf 'sorted(m["hooks"])')"
eq "картинка по умолчанию" dst_1080.jpg "$(mf 'm["config"]["keys"]["WALLPAPER_IMAGE"]["default"]')"
eq "режим по умолчанию" zoom "$(mf 'm["config"]["keys"]["WALLPAPER_MODE"]["default"]')"
check "режим — перечисление" grep -q '^enum:' <<< "$(mf 'm["config"]["keys"]["WALLPAPER_MODE"]["type"]')"
check "картинка — форма имени без /" grep -q '^re:' <<< "$(mf 'm["config"]["keys"]["WALLPAPER_IMAGE"]["type"]')"
check "картинка в дереве: images/dst_1080.jpg" test -f "$EXT/images/dst_1080.jpg"
for old in install.sh configure.sh configure-wallpaper.service lib; do check_not "layout 2: $old убран" test -e "$EXT/$old"; done
check_not "без eval в хуках и файлах" grep -rqwE 'eval' "$EXT/hooks" "$EXT/files"
check_not "без runuser: в дом не ходим" grep -rqw 'runuser' "$EXT/hooks" "$EXT/files"

echo "== install: dconf нет — ставится dconf-cli =="
fresh
ht_hook install; eq "install — 0" 0 "$?"
check "apt-get install dconf-cli" ht_called '^apt-get .*install.* dconf-cli'
ht_hook install; eq "повтор — 0" 0 "$?"
check "повтор: dconf-cli один раз" test "$(grep -c 'install.* dconf-cli' "$FAKE/calls")" -eq 1

echo "== install: dconf есть — apt не нужен; build тоже 0 =="
fresh gnome
HT_PHASE=build ht_hook install; eq "install (build) — 0" 0 "$?"
check_not "apt-get не звали" ht_called '^apt-get'

echo "== install: картинки нет в дереве — отказ сборки =="
fresh gnome
rm -f "$HT_EXT/images/dst_1080.jpg"
ht_hook install; rc=$?
check "install без картинки — не 0" test "$rc" -ne 0
check "отказ называет картинку" grep -q 'dst_1080.jpg' <<< "$(ht_out)"

echo "== configure: GNOME — системный dconf с замками =="
fresh gnome
ht_hook configure; eq "configure — 0" 0 "$?"
check "keyfile есть" test -f "$KF"
eq "picture-uri" "'file://$IMG'" "$(ini_get "$KF" org/gnome/desktop/background picture-uri)"
eq "picture-uri-dark" "'file://$IMG'" "$(ini_get "$KF" org/gnome/desktop/background picture-uri-dark)"
eq "picture-options" "'zoom'" "$(ini_get "$KF" org/gnome/desktop/background picture-options)"
for k in picture-uri picture-uri-dark picture-options; do
    check "замок $k" grep -qx "/org/gnome/desktop/background/$k" "$LK"
done
check "профиль user: system-db:local" grep -qx 'system-db:local' "$ROOT/etc/dconf/profile/user"
check "профиль user: user-db первым" test "$(head -1 "$ROOT/etc/dconf/profile/user")" = user-db:user
check "dconf update" ht_called '^dconf update'
eq "keyfile 0644" 644 "$(stat -c %a "$KF")"
check "дом пользователя не тронут" home_empty
check_not "runuser не звали" ht_called '^runuser'
check_not "временных файлов не осталось" bash -c 'find "$1/etc" -name ".wallpaper.*" | grep -q .' _ "$ROOT"

echo "== configure: повтор ничего не меняет и dconf update не зовёт =="
before="$(sum_etc)"
: > "$FAKE/calls"
ht_hook configure; eq "повтор — 0" 0 "$?"
eq "повтор: /etc без изменений" "$before" "$(sum_etc)"
check_not "повтор: без dconf update" ht_called '^dconf update'

echo "== configure: профиль dconf уже есть — дописывается только system-db:local =="
fresh gnome
mkdir -p "$ROOT/etc/dconf/profile"; printf 'user-db:user\nsystem-db:site\n' > "$ROOT/etc/dconf/profile/user"
ht_hook configure; eq "configure — 0" 0 "$?"
eq "профиль дописан" "$(printf 'user-db:user\nsystem-db:site\nsystem-db:local')" "$(cat "$ROOT/etc/dconf/profile/user")"

echo "== configure: режим scaled — во всех трёх столах =="
fresh gnome xfce lxde
ht_hook configure WALLPAPER_MODE=scaled; eq "configure — 0" 0 "$?"
eq "dconf: scaled" "'scaled'" "$(ini_get "$KF" org/gnome/desktop/background picture-options)"
check "xfconf: image-style 4" grep -q 'name="image-style" type="int" value="4"' "$XF"
eq "pcmanfm: fit" fit "$(ini_get "$PC" desktop wallpaper_mode)"

echo "== configure: Xfce — системный канал xfce4-desktop =="
fresh xfce
ht_hook configure; eq "configure — 0" 0 "$?"
check "канал есть" test -f "$XF"
for n in 0 1 2 3; do
    check "monitor$n: image-path" grep -q "<property name=\"monitor$n\"" "$XF"
done
eq "image-path на картинку ×4" 4 "$(grep -c "name=\"image-path\" type=\"string\" value=\"$IMG\"" "$XF")"
check "image-style 5 (zoom)" grep -q 'name="image-style" type="int" value="5"' "$XF"
check "XML разбирается" python3 -c 'import sys, xml.dom.minidom as d; d.parse(sys.argv[1])' "$XF"
check "дом не тронут" home_empty

echo "== configure: чужой xfce4-desktop.xml не перезаписывается =="
fresh xfce
printf '<?xml version="1.0"?>\n<channel name="xfce4-desktop" version="1.0"/>\n' > "$XF"
foreign="$(cat "$XF")"
ht_hook configure; eq "configure — 0" 0 "$?"
eq "чужой канал цел" "$foreign" "$(cat "$XF")"
check "предупреждение о чужом канале" grep -q 'xfce4-desktop.xml' <<< "$(ht_out)"

echo "== configure: LXDE — pcmanfm.conf правится через rename, режим файла сохранён =="
fresh lxde
chmod 0640 "$PC"
ht_hook configure; eq "configure — 0" 0 "$?"
eq "wallpaper" "$IMG" "$(ini_get "$PC" desktop wallpaper)"
eq "wallpaper_mode crop (zoom)" crop "$(ini_get "$PC" desktop wallpaper_mode)"
eq "остальное цело" '#000000' "$(ini_get "$PC" desktop desktop_bg)"
eq "режим файла сохранён" 640 "$(stat -c %a "$PC")"
check "исходные значения запомнены" test -s "$STATE/pcmanfm.orig"
before="$(sum_etc)"
ht_hook configure; eq "повтор — 0" 0 "$?"
eq "повтор: /etc без изменений" "$before" "$(sum_etc)"
check "remove (LXDE) — 0" ht_hook remove
eq "remove вернул wallpaper" /etc/alternatives/desktop-background "$(ini_get "$PC" desktop wallpaper)"
eq "remove вернул wallpaper_mode" crop "$(ini_get "$PC" desktop wallpaper_mode)"

echo "== configure: pcmanfm.conf — ссылка: не пишем по ней =="
fresh
mkdir -p "${PC%/*}" "$ROOT/target"
printf '[desktop]\nwallpaper=/x\n' > "$ROOT/target/real.conf"
ln -s "$ROOT/target/real.conf" "$PC"
ht_hook configure; eq "configure — 0" 0 "$?"
eq "цель ссылки не тронута" "$(printf '[desktop]\nwallpaper=/x')" "$(cat "$ROOT/target/real.conf")"
check "ссылка осталась ссылкой" test -L "$PC"
check "предупреждение о ссылке" grep -q 'ссылк' <<< "$(ht_out)"

echo "== configure: на месте нашего файла — ссылка: заменяется файлом, цель цела =="
fresh gnome
mkdir -p "${KF%/*}" "$ROOT/target"
echo secret > "$ROOT/target/victim"
ln -s "$ROOT/target/victim" "$KF"
ht_hook configure; eq "configure — 0" 0 "$?"
eq "цель ссылки цела" secret "$(cat "$ROOT/target/victim")"
check "keyfile — обычный файл" bash -c '[[ -f "$1" && ! -L "$1" ]]' _ "$KF"

echo "== configure: картинка — только файл из images/ расширения =="
for bad in '../../../../etc/shadow' '/etc/shadow' 'images/dst_1080.jpg' '.hidden.jpg' 'a b.jpg' 'x.exe' "\$(id).jpg"; do
    fresh gnome xfce lxde
    pc_before="$(cat "$PC")"
    ht_hook configure WALLPAPER_IMAGE="$bad"; rc=$?
    check "[$bad]: configure — не 0" test "$rc" -ne 0
    check_not "[$bad]: dconf не записан" test -e "$KF"
    check_not "[$bad]: xfconf не записан" test -e "$XF"
    eq "[$bad]: pcmanfm не тронут" "$pc_before" "$(cat "$PC")"
done
fresh gnome
ht_hook configure WALLPAPER_IMAGE=nope.jpg; rc=$?
check "нет файла — не 0" test "$rc" -ne 0
check "отказ называет файл" grep -q 'nope.jpg' <<< "$(ht_out)"
fresh gnome
mkdir -p "$ROOT/target"; echo x > "$ROOT/target/evil.jpg"
ln -s "$ROOT/target/evil.jpg" "$HT_EXT/images/evil.jpg"
ht_hook configure WALLPAPER_IMAGE=evil.jpg; rc=$?
check "картинка-ссылка — не 0" test "$rc" -ne 0
check_not "картинка-ссылка: dconf не записан" test -e "$KF"
fresh gnome
cp "$HT_EXT/images/dst_1080.jpg" "$HT_EXT/images/other-1.png"
ht_hook configure WALLPAPER_IMAGE=other-1.png; eq "своя картинка из images/ — 0" 0 "$?"
eq "picture-uri — своя картинка" "'file:///opt/cream/ext/wallpaper/images/other-1.png'" \
    "$(ini_get "$KF" org/gnome/desktop/background picture-uri)"

echo "== configure: режим вне набора — отказ =="
for bad in 'zoom; rm -rf /' 'tile' 'ZOOM' ''; do
    fresh gnome
    ht_hook configure WALLPAPER_MODE="$bad"; rc=$?
    check "[$bad]: configure — не 0" test "$rc" -ne 0
    check_not "[$bad]: dconf не записан" test -e "$KF"
done

echo "== configure: свои обои пользователя в Xfce — предупреждение, дом не правится =="
fresh xfce
mkdir -p "$ROOT/home/alice/.config/xfce4/xfconf/xfce-perchannel-xml"
echo '<channel name="xfce4-desktop"/>' > "$ROOT/home/alice/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
own="$(cat "$ROOT/home/alice/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml")"
ht_hook configure; eq "configure — 0" 0 "$?"
check "предупреждение про alice" grep -q 'alice' <<< "$(ht_out)"
eq "файл пользователя не тронут" "$own" "$(cat "$ROOT/home/alice/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml")"

echo "== configure: стола нет (ни dconf, ни xfconf, ни pcmanfm) — предупреждение, 0 =="
fresh
ht_hook configure; eq "configure без стола — 0" 0 "$?"
check "предупреждение" grep -q 'WARN' <<< "$(ht_out)"

echo "== configure: пользователя нет — обои всё равно системные, 0 =="
fresh gnome
rm -f "$ROOT/opt/cream/ext/cloud-user/get_cloud_user.sh"
ht_hook configure; eq "configure без пользователя — 0" 0 "$?"
check "keyfile есть" test -f "$KF"

echo "== remove: снимает своё, возвращает чужое, повтор — 0 =="
fresh gnome xfce lxde
ht_hook configure; eq "configure — 0" 0 "$?"
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "keyfile снят" test -e "$KF"
check_not "замки сняты" test -e "$LK"
check_not "xfconf снят" test -e "$XF"
check "dconf update после снятия" ht_called '^dconf update'
eq "pcmanfm вернулся" /etc/alternatives/desktop-background "$(ini_get "$PC" desktop wallpaper)"
check_not "состояние pcmanfm снято" test -e "$STATE/pcmanfm.orig"
check "профиль dconf остаётся (общий с desktop и locale)" test -f "$ROOT/etc/dconf/profile/user"
: > "$FAKE/calls"
ht_hook remove; eq "remove повтор — 0" 0 "$?"
check_not "повтор: без dconf update" ht_called '^dconf update'

echo "== remove: ключа wallpaper в pcmanfm.conf не было — удаляется, а не пустеет =="
fresh
mkdir -p "${PC%/*}"; printf '[desktop]\ndesktop_bg=#000000\n' > "$PC"
ht_hook configure; eq "configure — 0" 0 "$?"
ht_hook remove; eq "remove — 0" 0 "$?"
eq "pcmanfm как был" "$(printf '[desktop]\ndesktop_bg=#000000')" "$(cat "$PC")"

echo "== remove: администратор сменил обои в pcmanfm.conf — не возвращаем =="
fresh lxde
ht_hook configure; eq "configure — 0" 0 "$?"
sed -i 's|^wallpaper=.*|wallpaper=/srv/admin.png|' "$PC"
ht_hook remove; eq "remove — 0" 0 "$?"
eq "обои администратора целы" /srv/admin.png "$(ini_get "$PC" desktop wallpaper)"

ht_done
