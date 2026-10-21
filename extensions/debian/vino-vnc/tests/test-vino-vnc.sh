#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the vino-vnc extension (cream/v1): manifest, hooks install, configure
# and remove on a scratch root (CREAM_ROOT) the way cream runs them. Nothing is
# written into the home directory: the settings are system dconf databases with
# locks (/etc/dconf/db/vino-vnc, the password apart in vino-vnc-secret, 0640
# root:<group of the session user>), the autostart is /etc/xdg/autostart. The
# password comes from a fake `cream config get --secret`; dconf (compile: the
# keyfiles concatenated), chgrp, getent, id, apt-get are fakes, the cloud-user
# library is a stub. The password never reaches an argv nor a child's
# environment.
#
#   extensions/debian/vino-vnc/tests/test-vino-vnc.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

PASS='vin0-Pass'
B64="$(printf '%s' "$PASS" | base64 -w0)"

fresh() {
    ht_root "$EXT"
    DB="$ROOT/etc/dconf/db"
    PROFILE="$ROOT/etc/dconf/profile/user"
    PUB="$DB/vino-vnc"
    SEC="$DB/vino-vnc-secret"
    AUTO="$ROOT/etc/xdg/autostart/vino-server.desktop"
    mkdir -p "$ROOT/opt/cream/ext/cloud-user" "$ROOT/home/alice" "$ROOT/usr/share/applications"
    printf '#!/bin/sh\ncat %q 2>/dev/null\n' "$FAKE/user" > "$ROOT/opt/cream/ext/cloud-user/get_cloud_user.sh"
    chmod +x "$ROOT/opt/cream/ext/cloud-user/get_cloud_user.sh"
    echo alice > "$FAKE/user"
    printf '[Desktop Entry]\nName=Desktop Sharing\nExec=/usr/libexec/vino-server\nNoDisplay=true\n' \
        > "$ROOT/usr/share/applications/vino-server.desktop"
    ht_fake cream '
if [[ "$*" == "config get --secret vino-vnc VINO_PASSWORD" ]]; then
    cat "$FAKE/secret" 2>/dev/null; echo; exit 0
fi
exit 64'
    # dconf compile OUT DIR: the keyfiles and locks, sorted, as the "database".
    ht_fake dconf '
env > "$FAKE/dconf.env"
[[ "$1" == compile ]] || exit 0
[[ -f "$FAKE/dconf-fail" ]] && exit 1
( cd "$3" && find . -type f | LC_ALL=C sort | while read -r f; do echo "## $f"; cat "$f"; done ) > "$2"'
    # passwd/group of the fakes: $FAKE/passwd, $FAKE/group (alice — personal group).
    printf '%s\n' 'alice:x:1000:1000::/home/alice:/bin/bash' 'bob:x:1001:100::/home/bob:/bin/bash' > "$FAKE/passwd"
    printf '%s\n' 'alice:x:1000:' 'users:x:100:' > "$FAKE/group"
    ht_fake getent '
f="$FAKE/$1"; [[ -f "$f" ]] || exit 2
if [[ -z "${2-}" ]]; then cat "$f"; exit 0; fi
grep -E "^$2:" "$f" || exit 2'
    ht_fake id '
u="${*: -1}"; line="$(grep -E "^$u:" "$FAKE/passwd")" || exit 1
gid="$(cut -d: -f4 <<< "$line")"
case "$1" in
    -gn) grep -E "^[^:]*:[^:]*:$gid:" "$FAKE/group" | cut -d: -f1 ;;
    -g) echo "$gid" ;;
    *) cut -d: -f3 <<< "$line" ;;
esac'
    ht_fake chgrp
    ht_fake apt-get 'if [[ "$1" == -s ]]; then v=Remv; [[ "$2" == purge ]] && v=Purg
    for a in "${@:3}"; do echo "$v $a [1.0]"; done; cat "$FAKE/sim-extra" 2>/dev/null; exit 0; fi
exit 0'
    ht_fake dpkg-query 'exit 1'
    ht_fake systemctl
    ht_fake sleep
}
leaked() {
    local f
    for f in "$FAKE/calls" "$FAKE"/*.argv "$FAKE/dconf.env"; do
        [[ -f "$f" ]] || continue
        grep -qF -e "$PASS" -e "$B64" "$f" && return 0
    done
    grep -qF -e "$PASS" -e "$B64" <(ht_out) && return 0
    return 1
}

echo "== манифест =="
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "версия 5.1.0 (every_boot)" 5.1.0 "$(mf 'm["version"]')"
eq "cream >=1.2.0 (every_boot, спека cream §10.9)" ">=1.2.0" "$(mf 'm["cream"]')"
eq "configure на каждой загрузке (аудит 2026-10-21)" True "$(mf 'm["hooks"]["configure"].get("every_boot")')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "depends cloud-user, apt-guard" cloud-user,apt-guard "$(mf '",".join(d["name"] for d in m["depends"])')"
eq "хуки" "['configure', 'install', 'remove']" "$(mf 'sorted(m["hooks"])')"
eq "стадия system (Р5)" system "$(mf 'm["hooks"]["configure"]["stage"]')"
eq "after cloud-init" "['cloud-init.service']" "$(mf 'm["hooks"]["configure"]["after"]')"
eq "before менеджеров входа" "['display-manager.service', 'gdm.service', 'gdm3.service', 'lightdm.service']" "$(mf 'm["hooks"]["configure"]["before"]')"
eq "пароль — secret: file" file "$(mf 'm["config"]["keys"]["VINO_PASSWORD"]["secret"]')"
eq "VINO_PASSWORD_FILE больше нет" False "$(mf '"VINO_PASSWORD_FILE" in m["config"]["keys"]')"
eq "без пароля — только явным ключом, по умолчанию 0" "bool 0" "$(mf 'm["config"]["keys"]["VINO_ALLOW_NO_PASSWORD"]["type"] + " " + m["config"]["keys"]["VINO_ALLOW_NO_PASSWORD"]["default"]')"
for old in install.sh configure.sh knobs knobs.apply knobs.secret configure-vino-vnc.service; do
    check_not "layout 2: $old убран" test -e "$EXT/$old"
done

echo "== install: пакеты =="
fresh
ht_hook install; eq "install — 0" 0 "$?"
for p in vino dconf-cli; do check "ставит $p" grep -qE "^apt-get .*install( .*)? $p( |\$)" "$FAKE/calls"; done
check_not "автозапуск пишет configure, не install" test -e "$AUTO"
check_not "в домашний каталог ничего" compgen -G "$ROOT/home/alice/*"

echo "== configure: пароля нет, ключа нет — vino выключен, аутентификация не снята =="
fresh
mkdir -p "${AUTO%/*}"; : > "$AUTO"
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
check "authentication-methods=['vnc'] (без пароля — никто)" grep -qxF "authentication-methods=['vnc']" "$PUB"
check_not "автозапуска нет" test -e "$AUTO"
check_not "секретной базы нет" test -e "$SEC"
check "предупреждение «vino выключен»" grep -q 'пароль не задан — vino выключен' <(ht_out)

echo "== configure: пароля нет, VINO_ALLOW_NO_PASSWORD=1 — без аутентификации, с предупреждением =="
fresh
ht_hook configure CREAM_REASON=boot VINO_ALLOW_NO_PASSWORD=1; eq "configure — 0" 0 "$?"
check "предупреждение БЕЗ ПАРОЛЯ" grep -q 'БЕЗ ПАРОЛЯ' <(ht_out)
check "автозапуск в /etc/xdg/autostart" grep -qx 'X-GNOME-Autostart-enabled=true' "$AUTO"
check "автозапуск — копия файла пакета" grep -qx 'Exec=/usr/libexec/vino-server' "$AUTO"
eq "автозапуск 0644" 644 "$(stat -c %a "$AUTO")"
check "профиль: user-db первым" test "$(head -n1 "$PROFILE")" = user-db:user
check "профиль: system-db:vino-vnc" grep -qx 'system-db:vino-vnc' "$PROFILE"
check "база настроек есть" test -f "$PUB"
eq "база настроек 0644" 644 "$(stat -c %a "$PUB")"
check "prompt-enabled=false" grep -qx 'prompt-enabled=false' "$PUB"
check "authentication-methods=['none']" grep -qxF "authentication-methods=['none']" "$PUB"
check "только петля" grep -qxF "network-interface='lo'" "$PUB"
check "use-alternative-port=false на 5900" grep -qx 'use-alternative-port=false' "$PUB"
check "ключи заблокированы" grep -qx '/org/gnome/desktop/remote-access/authentication-methods' "$PUB"
check_not "секретной базы нет" test -e "$SEC"
check_not "в домашний каталог ничего" compgen -G "$ROOT/home/alice/*"

echo "== configure: пароль есть — секретная база 0640 root:группа пользователя =="
fresh
printf '%s' "$PASS" > "$FAKE/secret"
ht_hook configure CREAM_REASON=boot VINO_PORT=5901 VINO_LISTEN=all VINO_ENCRYPTION=true; eq "configure — 0" 0 "$?"
check "authentication-methods=['vnc']" grep -qxF "authentication-methods=['vnc']" "$PUB"
check "все интерфейсы" grep -qxF "network-interface=''" "$PUB"
check "порт 5901" grep -qx 'alternative-port=uint16 5901' "$PUB"
check "require-encryption=true" grep -qx 'require-encryption=true' "$PUB"
check_not "пароля в общей базе нет" grep -qF "$B64" "$PUB"
check "секретная база есть" test -f "$SEC"
eq "секретная база 0640" 640 "$(stat -c %a "$SEC")"
check "автозапуск есть" test -f "$AUTO"
check "группа — пользователя сессии" ht_called '^chgrp alice '
check "пароль в секретной базе base64" grep -qxF "vnc-password='$B64'" "$SEC"
check "пароль заблокирован" grep -qx '/org/gnome/desktop/remote-access/vnc-password' "$SEC"
check "профиль: system-db:vino-vnc-secret" grep -qx 'system-db:vino-vnc-secret' "$PROFILE"
check_not "пароль не утёк в argv, окружение и журнал" leaked
check_not "временных каталогов не осталось" compgen -G "$DB/.vino-vnc*"
check_not "в домашний каталог ничего" compgen -G "$ROOT/home/alice/*"

echo "== повтор configure: без изменений =="
ip="$(stat -c %i "$PUB")"; is="$(stat -c %i "$SEC")"; pr="$(sha256sum "$PROFILE")"; ia="$(stat -c %i "$AUTO")"
ht_hook configure CREAM_REASON=apply VINO_PORT=5901 VINO_LISTEN=all VINO_ENCRYPTION=true; eq "повтор — 0" 0 "$?"
eq "база настроек не переписана" "$ip" "$(stat -c %i "$PUB")"
eq "секретная база не переписана" "$is" "$(stat -c %i "$SEC")"
eq "профиль тот же" "$pr" "$(sha256sum "$PROFILE")"
eq "автозапуск не переписан" "$ia" "$(stat -c %i "$AUTO")"

echo "== пароль снят без ключа — секретная база снимается, vino выключен =="
: > "$FAKE/secret"
ht_hook configure CREAM_REASON=apply; eq "configure — 0" 0 "$?"
check_not "секретной базы нет" test -e "$SEC"
check "authentication-methods=['vnc']" grep -qxF "authentication-methods=['vnc']" "$PUB"
check_not "автозапуска нет" test -e "$AUTO"

echo "== общая группа пользователя — сбой, без ослабления =="
fresh
printf '%s' "$PASS" > "$FAKE/secret"
printf '%s\n' 'alice:x:1000:100::/home/alice:/bin/bash' > "$FAKE/passwd"
ht_hook configure CREAM_REASON=boot; rc=$?
check "основная группа users — сбой configure" test "$rc" -ne 0
check_not "секретная база не записана" test -e "$SEC"
check "сообщение про личную группу" grep -q 'личн' <(ht_out)
fresh
printf '%s' "$PASS" > "$FAKE/secret"
printf '%s\n' 'alice:x:1000:bob' 'users:x:100:' > "$FAKE/group"
ht_hook configure CREAM_REASON=boot; rc=$?
check "в группе alice есть bob — сбой configure" test "$rc" -ne 0
check_not "секретная база не записана" test -e "$SEC"
fresh
printf '%s' "$PASS" > "$FAKE/secret"
printf '%s\n' 'alice:x:1000:1000::/home/alice:/bin/bash' 'carol:x:1002:1000::/home/carol:/bin/bash' > "$FAKE/passwd"
ht_hook configure CREAM_REASON=boot; rc=$?
check "группа alice — основная и у carol — сбой configure" test "$rc" -ne 0

echo "== унаследованный /etc/vino/vnc-password.b64 без секрета — выключено, файл не тронут =="
fresh
mkdir -p "$ROOT/etc/vino"; printf 'bGVnYWN5' > "$ROOT/etc/vino/vnc-password.b64"
sum="$(sha256sum "$ROOT/etc/vino/vnc-password.b64")"
ht_hook configure CREAM_REASON=boot VINO_ALLOW_NO_PASSWORD=1; eq "configure — 0" 0 "$?"
eq "файл не тронут" "$sum" "$(sha256sum "$ROOT/etc/vino/vnc-password.b64")"
check_not "автозапуска нет и с ключом" test -e "$AUTO"
check "authentication-methods=['vnc']" grep -qxF "authentication-methods=['vnc']" "$PUB"
check "подсказка, как перенести пароль" grep -qF 'cream set vino-vnc VINO_PASSWORD=-' <(ht_out)

echo "== подмена ссылкой — отказ =="
fresh
printf '%s' "$PASS" > "$FAKE/secret"
mkdir -p "$DB" "$ROOT/outside"
ln -s "$ROOT/outside/target" "$SEC"
ht_hook configure CREAM_REASON=boot; rc=$?
check "секретная база — ссылка: сбой configure" test "$rc" -ne 0
check_not "по ссылке ничего не записано" test -e "$ROOT/outside/target"
fresh
mkdir -p "$ROOT/etc/dconf/profile" "$ROOT/outside"
printf 'user-db:user\n' > "$ROOT/outside/prof"
ln -s "$ROOT/outside/prof" "$PROFILE"
ht_hook configure CREAM_REASON=boot; rc=$?
check "профиль — ссылка: сбой configure" test "$rc" -ne 0
eq "цель ссылки профиля не тронута" "user-db:user" "$(cat "$ROOT/outside/prof")"

echo "== профиль desktop сохраняется =="
fresh
mkdir -p "$ROOT/etc/dconf/profile"
printf 'user-db:user\nsystem-db:local\n' > "$PROFILE"
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
check "system-db:local на месте" grep -qx 'system-db:local' "$PROFILE"
ht_hook remove; eq "remove — 0" 0 "$?"
eq "remove: профиль desktop как был" "$(printf 'user-db:user\nsystem-db:local')" "$(cat "$PROFILE")"

echo "== dconf compile отказал — сбой configure =="
fresh
printf '%s' "$PASS" > "$FAKE/secret"
: > "$FAKE/dconf-fail"
ht_hook configure CREAM_REASON=boot; rc=$?
check "configure — сбой" test "$rc" -ne 0
check_not "временных каталогов не осталось" compgen -G "$ROOT/etc/dconf/db/.vino-vnc*"

echo "== без пользователя: пароль только root, предупреждение, 0 =="
fresh
: > "$FAKE/user"
printf '%s' "$PASS" > "$FAKE/secret"
ht_hook configure CREAM_REASON=apply; eq "configure — 0" 0 "$?"
check "секретная база есть" test -f "$SEC"
check_not "группа не передана" ht_called '^chgrp '
check "предупреждение" grep -q 'пользовател' <(ht_out)

echo "== remove =="
fresh
printf '%s' "$PASS" > "$FAKE/secret"
ht_hook install >/dev/null; ht_hook configure CREAM_REASON=boot >/dev/null
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "база настроек снята" test -e "$PUB"
check_not "секретная база снята" test -e "$SEC"
check_not "автозапуск снят" test -e "$AUTO"
check_not "профиль, созданный нами, снят" test -e "$PROFILE"
ht_hook remove; eq "повтор remove — 0" 0 "$?"

echo "== remove: симуляция снимает чужой пакет — отказ =="
fresh
S="$ROOT/var/lib/cream/ext/vino-vnc"
mkdir -p "$S" "$ROOT/etc/xdg/autostart"; echo vino > "$S/installed"
: > "$ROOT/etc/xdg/autostart/vino-server.desktop"
echo 'Remv gnome-remote-desktop-compat [1.0]' > "$FAKE/sim-extra"
ht_hook remove; eq "симуляция снимает чужой пакет — 1" 1 "$?"
check "симуляция спрошена" ht_called '^apt-get -s remove vino$'
check "чужой пакет назван" grep -q 'gnome-remote-desktop-compat' "$ROOT/out"
check_not "ничего не снято" ht_called '^apt-get -q -y remove'
check "автозапуск на месте" test -e "$ROOT/etc/xdg/autostart/vino-server.desktop"
check "запись осталась" test -s "$S/installed"

ht_done
