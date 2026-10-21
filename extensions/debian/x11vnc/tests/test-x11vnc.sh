#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the x11vnc extension (cream/v1): manifest, hooks install, configure,
# apply and remove, and the wrapper's password choice, on a scratch root
# (CREAM_ROOT) the way cream runs them. The password comes from a fake
# `cream config get --secret`; openssl, systemctl, apt-get, chown, getent and id
# are fakes, the cloud-user library is a stub. The main property: the password
# never reaches an argv (the call log of every fake) nor the environment of a
# child (openssl dumps its environment).
#
#   extensions/debian/x11vnc/tests/test-x11vnc.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

PASS='s3cret-Pw'
SYSD_REL=etc/systemd/system

# fresh: a root with fakes. $FAKE/secret — the value of X11VNC_PASSWORD (absent —
# empty); $FAKE/user — what the cloud-user stub prints; $FAKE/openssl-fail —
# openssl fails. The display manager is enabled (display-manager.service link).
fresh() {
    ht_root "$EXT"
    SYSD="$ROOT/$SYSD_REL"
    WANTS="$SYSD/graphical.target.wants"
    PF="$ROOT/etc/x11vnc/passwd"
    NOPW="$ROOT/etc/x11vnc/nopw"
    STATE="$ROOT/var/lib/cream/ext/x11vnc"
    mkdir -p "$WANTS" "$ROOT/opt/cream/ext/cloud-user" "$ROOT/home/alice"
    ln -s /lib/systemd/system/lightdm.service "$SYSD/display-manager.service"
    printf '#!/bin/sh\ncat %q 2>/dev/null\n' "$FAKE/user" > "$ROOT/opt/cream/ext/cloud-user/get_cloud_user.sh"
    chmod +x "$ROOT/opt/cream/ext/cloud-user/get_cloud_user.sh"
    echo alice > "$FAKE/user"
    ht_fake cream '
if [[ "$*" == "config get --secret x11vnc X11VNC_PASSWORD" ]]; then
    cat "$FAKE/secret" 2>/dev/null; echo; exit 0
fi
exit 64'
    ht_fake openssl '
env > "$FAKE/openssl.env"
[[ -f "$FAKE/openssl-fail" ]] && exit 1
tr "a-z" "A-Z"'
    ht_fake getent '[[ "$1" == passwd && "$2" == alice ]] && echo "alice:x:1000:1000::/home/alice:/bin/bash"'
    ht_fake id '[[ "${*: -1}" == alice ]] || exit 1; echo 1000'
    ht_fake chown
    ht_fake apt-get 'if [[ "$1" == -s ]]; then v=Remv; [[ "$2" == purge ]] && v=Purg
    for a in "${@:3}"; do echo "$v $a [1.0]"; done; cat "$FAKE/sim-extra" 2>/dev/null; exit 0; fi
exit 0'
    ht_fake dpkg-query 'exit 1'
    ht_fake systemctl '
wants="'"$WANTS"'"
case "$1" in
    enable) ln -sf "/etc/systemd/system/x11vnc@.service" "$wants/$2" ;;
    disable) rm -f "$wants/$2" ;;
esac
exit 0'
    ht_fake sleep
}
leaked() {
    grep -rqF -- "$PASS" "$FAKE/calls" "$FAKE"/*.argv 2>/dev/null && return 0
    grep -qF -- "$PASS" "$FAKE/openssl.env" 2>/dev/null && return 0
    grep -qF -- "$PASS" <(ht_out) && return 0
    return 1
}
mode_of() { stat -c %a "$1"; }

echo "== манифест =="
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "версия 5.1.1 (every_boot)" 5.1.1 "$(mf 'm["version"]')"
eq "cream >=1.2.0 (every_boot, спека cream §10.9)" ">=1.2.0" "$(mf 'm["cream"]')"
eq "configure на каждой загрузке (аудит 2026-10-21)" True "$(mf 'm["hooks"]["configure"].get("every_boot")')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "depends cloud-user, apt-guard" cloud-user,apt-guard "$(mf '",".join(d["name"] for d in m["depends"])')"
eq "requires" "['x11-server', 'display-manager']" "$(mf 'm["requires"]')"
eq "хуки" "['apply', 'configure', 'install', 'remove']" "$(mf 'sorted(m["hooks"])')"
eq "стадия graphical" graphical "$(mf 'm["hooks"]["configure"]["stage"]')"
eq "after display-manager" "['display-manager.service']" "$(mf 'm["hooks"]["configure"]["after"]')"
eq "пароль — secret: file" file "$(mf 'm["config"]["keys"]["X11VNC_PASSWORD"]["secret"]')"
eq "X11VNC_PASSFILE больше нет" False "$(mf '"X11VNC_PASSFILE" in m["config"]["keys"]')"
eq "без пароля — только явным ключом, по умолчанию 0" "bool 0" "$(mf 'm["config"]["keys"]["X11VNC_ALLOW_NO_PASSWORD"]["type"] + " " + m["config"]["keys"]["X11VNC_ALLOW_NO_PASSWORD"]["default"]')"
eq "юнит — files" /etc/systemd/system/x11vnc@.service "$(mf '",".join(f["dst"] for f in m["files"])')"
unit="$EXT/files/x11vnc@.service"
check "юнит зовёт обёртку из дерева cream" grep -q 'ExecStart=/bin/bash /opt/cream/ext/x11vnc/files/run-x11vnc.sh %i' "$unit"
check "юнит читает config домена" grep -qx 'EnvironmentFile=-/etc/cream/x11vnc/config' "$unit"
check_not "юнит НЕ читает secrets (пароль не в окружении сервера)" grep -qE '^EnvironmentFile=.*secrets' "$unit"
for old in install.sh configure.sh knobs knobs.apply knobs.secret configure-x11vnc.service run-x11vnc.sh x11vnc@.service; do
    check_not "layout 2: $old убран" test -e "$EXT/$old"
done

echo "== install =="
fresh
mkdir -p "$ROOT/etc/default"; : > "$ROOT/etc/default/bisquite-x11vnc"
ht_hook install; eq "install — 0" 0 "$?"
for p in x11vnc xauth x11-utils openssl; do
    check "ставит $p" grep -qE "^apt-get .*install( .*)? $p( |\$)" "$FAKE/calls"
done
check_not "legacy /etc/default/bisquite-x11vnc удалён" test -e "$ROOT/etc/default/bisquite-x11vnc"
check "состояние: x11vnc поставлен нами" grep -qx x11vnc "$STATE/installed"

echo "== configure: пароля нет и ключа нет — сервер не включается =="
fresh
mkdir -p "$ROOT/etc/x11vnc"; : > "$NOPW"   # a marker made by hand is not the truth
ln -s /etc/systemd/system/x11vnc@.service "$WANTS/x11vnc@alice.service"
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
check_not "файла пароля нет" test -e "$PF"
check_not "маркер, сделанный руками, снят" test -e "$NOPW"
check_not "x11vnc@alice выключен" test -L "$WANTS/x11vnc@alice.service"
check_not "перезапуска нет" ht_called '^systemctl --no-block restart'
check "предупреждение про ключ" grep -q 'X11VNC_ALLOW_NO_PASSWORD' <(ht_out)

echo "== configure: пароля нет, X11VNC_ALLOW_NO_PASSWORD=1 — явный отказ от пароля =="
fresh
ht_hook configure CREAM_REASON=boot X11VNC_ALLOW_NO_PASSWORD=1; eq "configure — 0" 0 "$?"
check_not "файла пароля нет" test -e "$PF"
check "маркер nopw есть" test -f "$NOPW"
check "x11vnc@alice включён" test -L "$WANTS/x11vnc@alice.service"
check "перезапуск без блокировки" ht_called '^systemctl --no-block restart x11vnc@alice.service'

echo "== configure: пароль есть — файл 0600, владелец — пользователь =="
fresh
printf '%s' "$PASS" > "$FAKE/secret"
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
check "файл пароля есть" test -f "$PF"
eq "файл пароля 0600" 600 "$(mode_of "$PF")"
eq "файл — 8 байт rfbauth из openssl" 8 "$(stat -c %s "$PF")"
check "владелец — alice" ht_called '^chown alice '
check_not "маркера nopw нет" test -e "$NOPW"
eq "каталог /etc/x11vnc 0755" 755 "$(mode_of "$ROOT/etc/x11vnc")"
check "openssl: VNC DES с постоянным ключом" grep -q -- '-des-ecb .*-K e84ad660c4721ae0' "$FAKE/openssl.argv"
check_not "пароль не утёк в argv, окружение и журнал" leaked
check_not "временных файлов не осталось" compgen -G "$ROOT/etc/x11vnc/.passwd.*"

echo "== повтор configure: без изменений =="
ino="$(stat -c %i "$PF")"; sum="$(sha256sum "$PF")"
ht_hook configure CREAM_REASON=apply; eq "повтор — 0" 0 "$?"
eq "файл не переписан" "$ino" "$(stat -c %i "$PF")"
eq "содержимое то же" "$sum" "$(sha256sum "$PF")"

echo "== вход openssl — ровно 8 байт: короткий дополняется, длинный и UTF-8 режутся =="
for pw in a 'пароль-длинный' '12345678'; do
    fresh
    printf '%s' "$pw" > "$FAKE/secret"
    ht_fake openssl 'cat > "$FAKE/openssl.in"; head -c 8 /dev/zero'
    ht_hook configure CREAM_REASON=apply >/dev/null
    eq "«$pw»: на вход openssl 8 байт" 8 "$(stat -c %s "$FAKE/openssl.in")"
done
eq "короткий дополнен нулями" "$(printf 'a\0\0\0\0\0\0\0' | od -An -tx1)" "$(fresh; printf a > "$FAKE/secret"; ht_fake openssl 'cat > "$FAKE/openssl.in"; head -c 8 /dev/zero'; ht_hook configure CREAM_REASON=apply >/dev/null; od -An -tx1 "$FAKE/openssl.in")"
fresh
printf '%s' "$PASS" > "$FAKE/secret"
ht_hook configure CREAM_REASON=apply >/dev/null

echo "== пароль есть и ключ разрешает без пароля — побеждает пароль =="
ht_hook configure CREAM_REASON=apply X11VNC_ALLOW_NO_PASSWORD=1; eq "configure — 0" 0 "$?"
check "файл пароля на месте" test -f "$PF"
check_not "маркера nopw нет" test -e "$NOPW"

echo "== пароль снят — файл снимается =="
: > "$FAKE/secret"
ht_hook configure CREAM_REASON=apply X11VNC_ALLOW_NO_PASSWORD=1; eq "configure — 0" 0 "$?"
check_not "файла пароля нет" test -e "$PF"
check "маркер nopw есть" test -f "$NOPW"

echo "== унаследованный файл пароля без секрета cream — выключено, файл не тронут =="
fresh
mkdir -p "$ROOT/etc/x11vnc"; printf 'legacy01' > "$PF"; chmod 0600 "$PF"
ln -s /etc/systemd/system/x11vnc@.service "$WANTS/x11vnc@alice.service"
sum="$(sha256sum "$PF")"
ht_hook configure CREAM_REASON=boot X11VNC_ALLOW_NO_PASSWORD=1; eq "configure — 0" 0 "$?"
eq "унаследованный файл не тронут" "$sum" "$(sha256sum "$PF")"
check_not "маркера nopw нет и с ключом" test -e "$NOPW"
check_not "сервер выключен" test -L "$WANTS/x11vnc@alice.service"
check_not "перезапуска нет" ht_called '^systemctl --no-block restart'
check "подсказка, как перенести пароль" grep -qF 'cream set x11vnc X11VNC_PASSWORD=-' <(ht_out)
printf '%s' "$PASS" > "$FAKE/secret"
ht_hook configure CREAM_REASON=apply; eq "секрет задан — configure 0" 0 "$?"
check_not "файл построен из секрета, не унаследованный" grep -q legacy01 "$PF"
: > "$FAKE/secret"
ht_hook configure CREAM_REASON=apply; eq "секрет снят — configure 0" 0 "$?"
check_not "свой файл при пустом пароле снимается" test -e "$PF"

echo "== подмена ссылкой — отказ, по ссылке не пишем =="
fresh
printf '%s' "$PASS" > "$FAKE/secret"
mkdir -p "$ROOT/etc/x11vnc" "$ROOT/outside"
: > "$NOPW"
ln -s "$ROOT/outside/target" "$PF"
ht_hook configure CREAM_REASON=boot; rc=$?
check "файл пароля — ссылка: сбой configure" test "$rc" -ne 0
check_not "по ссылке ничего не записано" test -e "$ROOT/outside/target"
check_not "маркер nopw снят (сервер без пароля не поднимется)" test -e "$NOPW"
check_not "экземпляр не перезапущен" ht_called '^systemctl --no-block restart'
fresh
printf '%s' "$PASS" > "$FAKE/secret"
mkdir -p "$ROOT/outside"
ln -s "$ROOT/outside" "$ROOT/etc/x11vnc"
ht_hook configure CREAM_REASON=boot; rc=$?
check "/etc/x11vnc — ссылка: сбой configure" test "$rc" -ne 0
check_not "в цель ссылки ничего не записано" compgen -G "$ROOT/outside/*"

echo "== openssl отказал — сбой, а не сервер без пароля =="
fresh
printf '%s' "$PASS" > "$FAKE/secret"
: > "$FAKE/openssl-fail"
mkdir -p "$ROOT/etc/x11vnc"; : > "$NOPW"
ht_hook configure CREAM_REASON=boot; rc=$?
check "configure — сбой" test "$rc" -ne 0
check_not "маркер nopw снят" test -e "$NOPW"
check_not "файла пароля нет" test -e "$PF"
check_not "временных файлов не осталось" compgen -G "$ROOT/etc/x11vnc/.passwd.*"

echo "== смена пользователя гасит прежний экземпляр =="
fresh
ln -s /etc/systemd/system/x11vnc@.service "$WANTS/x11vnc@bob.service"
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
check "bob выключен" ht_called '^systemctl disable x11vnc@bob.service'
check "bob остановлен без блокировки" ht_called '^systemctl --no-block stop x11vnc@bob.service'

echo "== без пользователя и без менеджера входа — предупреждение, 0 =="
fresh
: > "$FAKE/user"
ht_hook configure CREAM_REASON=apply; eq "без пользователя — 0" 0 "$?"
check_not "ничего не включено" ht_called '^systemctl enable'
fresh
rm -f "$SYSD/display-manager.service"
ht_hook configure CREAM_REASON=apply X11VNC_ALLOW_NO_PASSWORD=1; eq "без менеджера входа — 0" 0 "$?"
check_not "экземпляр не включён" ht_called '^systemctl enable'
check "файл решения о пароле всё равно записан" test -f "$NOPW"

echo "== негодное имя пользователя — не в имя юнита =="
fresh
echo 'x;rm -rf /' > "$FAKE/user"
ht_fake id 'exit 0'
ht_hook configure CREAM_REASON=apply; eq "configure — 0" 0 "$?"
check_not "юнит с негодным именем не включён" ht_called '^systemctl enable'

echo "== apply: пароль меняется в работающем экземпляре =="
fresh
ln -s /etc/systemd/system/x11vnc@.service "$WANTS/x11vnc@alice.service"
printf '%s' "$PASS" > "$FAKE/secret"
ht_hook apply CREAM_CHANGED_KEYS=X11VNC_PASSWORD; eq "apply — 0" 0 "$?"
check "файл пароля построен" test -f "$PF"
check "экземпляр перезапущен без блокировки" ht_called '^systemctl --no-block restart x11vnc@alice.service'
check_not "пароль не утёк" leaked

echo "== remove =="
ht_hook remove; eq "remove — 0" 0 "$?"
check "экземпляр выключен" ht_called '^systemctl disable x11vnc@alice.service'
check_not "файла пароля нет" test -e "$PF"
check_not "каталога /etc/x11vnc нет" test -e "$ROOT/etc/x11vnc"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
fresh
mkdir -p "$ROOT/etc/x11vnc"; printf 'legacy01' > "$PF"
ht_hook remove; eq "remove с унаследованным файлом — 0" 0 "$?"
check "remove не снимает чужой (унаследованный) файл пароля" test -f "$PF"

echo "== обёртка: пароль задан, файла нет — отказ, а не -nopw =="
wrap() { # wrap <passfile> <nopw> [allow]: the -rfbauth/-nopw decision of the wrapper
    X11VNC_ALLOW_NO_PASSWORD="${3:-0}" "$EXT/files/run-x11vnc.sh" --decide-auth "$1" "$2" 2>&1
}
fresh
mkdir -p "$ROOT/etc/x11vnc"
eq "нет ни файла, ни маркера — отказ" "refuse" "$(wrap "$PF" "$NOPW" | tail -n1)"
: > "$NOPW"
eq "маркер без ключа — отказ" "refuse" "$(wrap "$PF" "$NOPW" 0 | tail -n1)"
eq "маркер и X11VNC_ALLOW_NO_PASSWORD=1 — -nopw" "-nopw" "$(wrap "$PF" "$NOPW" 1 | tail -n1)"
check "-nopw — предупреждение в журнал при каждом старте" grep -q 'БЕЗ ПАРОЛЯ' <(wrap "$PF" "$NOPW" 1)
eq "ключ без маркера — отказ" "refuse" "$(rm -f "$NOPW"; wrap "$PF" "$NOPW" 1 | tail -n1; : > "$NOPW")"
printf 'xxxxxxxx' > "$PF"; chmod 0600 "$PF"
eq "файл есть — -rfbauth" "-rfbauth $PF" "$(wrap "$PF" "$NOPW" | tail -n1)"
chmod 0000 "$PF"
if [[ "$(id -u)" != 0 ]]; then
    eq "файл не читается — отказ" "refuse" "$(wrap "$PF" "$NOPW" | tail -n1)"
fi

echo "== remove: симуляция снимает чужой пакет — отказ =="
fresh
mkdir -p "$STATE" "$ROOT/etc/x11vnc"; echo x11vnc > "$STATE/installed"; printf 'secret01' > "$PF"
echo 'Remv x11vnc-data [0.9.16-9]' > "$FAKE/sim-extra"
ht_hook remove; eq "симуляция снимает чужой пакет — 1" 1 "$?"
check "симуляция спрошена" ht_called '^apt-get -s remove x11vnc$'
check "чужой пакет назван" grep -q 'x11vnc-data' "$ROOT/out"
check_not "ничего не снято" ht_called '^apt-get -q -y remove'
check "файл пароля на месте" test -e "$PF"
check "запись осталась" test -s "$STATE/installed"

ht_done
