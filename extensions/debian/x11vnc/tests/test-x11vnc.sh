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
    mkdir -p "$WANTS" "$ROOT/opt/cream/ext/cloud-user" "$ROOT/home/alice" "$ROOT/usr/lib/xorg" \
        "$ROOT/lib/systemd/system"
    printf '#!/bin/sh\n' > "$ROOT/usr/lib/xorg/Xorg"; chmod 0755 "$ROOT/usr/lib/xorg/Xorg"
    : > "$ROOT/lib/systemd/system/lightdm.service"
    ln -s /lib/systemd/system/lightdm.service "$SYSD/display-manager.service"
    printf '#!/bin/sh\ncat %q 2>/dev/null\n' "$FAKE/user" > "$ROOT/opt/cream/ext/cloud-user/get_cloud_user.sh"
    chmod +x "$ROOT/opt/cream/ext/cloud-user/get_cloud_user.sh"
    echo alice > "$FAKE/user"
    printf '%s\n' 'root:x:0:0::/root:/bin/bash' 'alice:x:1000:1000::/home/alice:/bin/bash' \
        'bob:x:1001:1001::/home/bob:/bin/bash' 'carol:x:1002:1002::/home/carol:/bin/bash' \
        'gdm:x:120:125:Gnome Display Manager:/var/lib/gdm3:/bin/false' \
        'nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin' > "$FAKE/passwd"
    : > "$FAKE/active-display-manager"
    ht_fake loginctl '
cmd="$1"; target="${!#}"
case "$cmd" in
    show-user) f="$FAKE/user.$target" ;;
    show-session) f="$FAKE/session.$target" ;;
    show-seat) f="$FAKE/seat.$target" ;;
    *) exit 1 ;;
esac
[[ -f "$f" ]] || exit 1
cat "$f"'
    ht_fake cream '
if [[ "$*" == "config get --secret x11vnc X11VNC_PASSWORD" ]]; then
    cat "$FAKE/secret" 2>/dev/null; echo; exit 0
fi
exit 64'
    ht_fake openssl '
env > "$FAKE/openssl.env"
[[ -f "$FAKE/openssl-fail" ]] && exit 1
tr "a-z" "A-Z"'
    ht_fake getent '
[[ "$1" == passwd ]] || exit 2
[[ -z "${2-}" ]] && { cat "$FAKE/passwd"; exit 0; }
grep -E "^${2}:" "$FAKE/passwd" || exit 2'
    ht_fake id '
[[ "$1" == -u ]] || exit 2
line="$(grep -E "^${2}:" "$FAKE/passwd")" || exit 1
echo "$line" | cut -d: -f3'
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
    is-active)
        for a in "$@"; do [[ -e "$FAKE/active-${a%.service}" ]] && exit 0; done
        exit 3 ;;
esac
exit 0'
    ht_fake sleep
}
# seat0 <sid> <user> <type> <display> [class] [active]: a local session of <user>
# on seat0 in logind; active (default yes) — the active session of seat0.
seat0() {
    printf 'Name=%s\nSeat=seat0\nClass=%s\nType=%s\nDisplay=%s\nState=active\nRemote=no\n' \
        "$2" "${5:-user}" "$3" "$4" > "$FAKE/session.$1"
    [[ "${5:-user}" == user ]] && printf 'Sessions=%s\n' "$1" > "$FAKE/user.$2"
    [[ "${6:-yes}" == yes ]] && printf 'ActiveSession=%s\n' "$1" > "$FAKE/seat.seat0"
    return 0
}
# enabled <user>: x11vnc@<user> is enabled (graphical.target.wants).
enabled() { test -L "$WANTS/x11vnc@$1.service"; }
# restarted <user>: configure put x11vnc@<user> to a restart.
restarted() { ht_called "^systemctl --no-block restart x11vnc@$1\\.service"; }
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
eq "версия 6.0.0 (X11VNC_USER, X11VNC_DISPLAY=auto)" 6.0.0 "$(mf 'm["version"]')"
eq "X11VNC_USER: имя, пусто — cloud-user" "re:^[a-z_][a-z0-9_-]{0,31}\$||True" \
    "$(mf 'm["config"]["keys"]["X11VNC_USER"]["type"] + "|" + m["config"]["keys"]["X11VNC_USER"]["default"] + "|" + str(m["config"]["keys"]["X11VNC_USER"].get("empty"))')"
eq "X11VNC_DISPLAY: auto или :N, умолчание auto" "re:^(auto|:[0-9]+(\\.[0-9]+)?)\$|auto" \
    "$(mf 'm["config"]["keys"]["X11VNC_DISPLAY"]["type"] + "|" + m["config"]["keys"]["X11VNC_DISPLAY"]["default"]')"
check "сохранённое :0 валидно по типу X11VNC_DISPLAY" python3 -c 'import re, sys; sys.exit(0 if re.fullmatch(sys.argv[1][3:], ":0") else 1)' \
    "$(mf 'm["config"]["keys"]["X11VNC_DISPLAY"]["type"]')"
check "запасное значение обёртки — auto (Р4)" grep -qF 'WANT_DISPLAY="${X11VNC_DISPLAY:-auto}"' "$EXT/files/run-x11vnc.sh"
check "x11vnc — потребитель lib/x-session.sh" grep -qx 'debian/x11vnc' "$EXT/../../../lib/x-session.consumers"
check "обёртка берёт files/x-session.sh" grep -q 'files/x-session.sh' "$EXT/files/run-x11vnc.sh"
check "configure берёт files/x-session.sh" grep -q 'files/x-session.sh' "$EXT/files/x11vnc.sh"
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
check "юнит: 78 (Wayland) не перезапускается" grep -qx 'RestartPreventExitStatus=78' "$unit"
check "юнит: перезапуск всегда (x11vnc выходит с X — обёртка найдёт новый сеанс)" grep -qx 'Restart=always' "$unit"
check_not "юнит: DISPLAY не зашит" grep -q 'DISPLAY=' "$unit"
check_not "юнит: не ждёт сокет X0 (дисплей ищет обёртка)" grep -q 'X11-unix/X0' "$unit"
check "юнит: комментарий к 78 — uid-правило" grep -qE '^#.*uid outside 1000\.\.65533' "$unit"
check "юнит: комментарий к 78 — X11VNC_DISPLAY" grep -qE '^#.*X11VNC_DISPLAY that is neither auto nor :N' "$unit"
# config holds only the keys set explicitly (cream show — with the defaults):
# the wrapper's fallback of every non-secret key it reads is its default in the
# manifest (selkies, Orin 2026-11-12: a diverging fallback silently wins).
# X11VNC_USER is configure's (whose instance), the wrapper has its %i.
while IFS=' ' read -r k d; do
    check "обёртка: умолчание $k = манифест ($d)" grep -qF "\${$k:-$d}" "$EXT/files/run-x11vnc.sh"
done < <(mf '"\n".join(k + " " + v["default"] for k, v in m["config"]["keys"].items() if not v.get("secret") and k != "X11VNC_USER")')
for old in install.sh configure.sh knobs knobs.apply knobs.secret configure-x11vnc.service run-x11vnc.sh x11vnc@.service; do
    check_not "layout 2: $old убран" test -e "$EXT/$old"
done

echo "== install =="
fresh
mkdir -p "$ROOT/etc/default"; : > "$ROOT/etc/default/bisquite-x11vnc"
ht_hook install; eq "install — 0" 0 "$?"
for p in x11vnc xauth x11-utils x11-xserver-utils openssl; do
    check "ставит $p" grep -qE "^apt-get .*install( .*)? $p( |\$)" "$FAKE/calls"
done
eq "apt-get update — один раз" 1 "$(grep -cE '^apt-get .*update' "$FAKE/calls")"
check_not "legacy /etc/default/bisquite-x11vnc удалён" test -e "$ROOT/etc/default/bisquite-x11vnc"
check "состояние: x11vnc поставлен нами" grep -qx x11vnc "$STATE/installed"

echo "== install на живой машине: нет Xorg или менеджера входа — 20 (Р2), на сборке — 0 =="
fresh; rm -f "$ROOT/usr/lib/xorg/Xorg"
ht_hook install; eq "нет Xorg — 20" 20 "$?"
check "текст: поставьте стол или existing-desktop" grep -qF 'нет X-сервера / менеджера входа: поставьте стол или `existing-desktop`' <(ht_out)
check_not "нет Xorg: apt не звали" ht_called '^apt-get'
check_not "нет Xorg: записи «наш пакет» нет" test -e "$STATE/installed"
fresh; mkdir -p "$ROOT/usr/bin"; rm -f "$ROOT/usr/lib/xorg/Xorg"; : > "$ROOT/usr/bin/Xorg"
ht_hook install; eq "Xorg в /usr/bin — 0" 0 "$?"
fresh; rm -f "$SYSD/display-manager.service"
ht_hook install; eq "нет display-manager.service — 20" 20 "$?"
check "сказано, чего нет" grep -q 'менеджера входа' <(ht_out)
fresh; rm -f "$ROOT/lib/systemd/system/lightdm.service"
ht_hook install; eq "display-manager.service висит (цели нет) — 20" 20 "$?"
fresh; rm -f "$ROOT/usr/lib/xorg/Xorg" "$SYSD/display-manager.service"
HT_PHASE=build ht_hook install; eq "сборка образа: без проверки — 0" 0 "$?"
check "сборка: пакеты ставятся" ht_called '^apt-get .*install'

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

echo "== configure: без пароля — только на петле (решение владельца 2026-11-12) =="
fresh
mkdir -p "$ROOT/etc/x11vnc"; : > "$NOPW"
ln -s /etc/systemd/system/x11vnc@.service "$WANTS/x11vnc@alice.service"
ht_hook configure CREAM_REASON=apply X11VNC_ALLOW_NO_PASSWORD=1 X11VNC_LISTEN=all
eq "X11VNC_LISTEN=all без пароля — 78" 78 "$?"
check_not "маркер nopw снят" test -e "$NOPW"
check_not "x11vnc@alice выключен" test -L "$WANTS/x11vnc@alice.service"
check "x11vnc@alice гасится" ht_called '^systemctl --no-block stop x11vnc@alice.service'
check_not "перезапуска нет" ht_called '^systemctl --no-block restart'
check "сказано, что без пароля — только петля" grep -q 'только на петле' <(ht_out)
ht_hook apply X11VNC_ALLOW_NO_PASSWORD=1 X11VNC_LISTEN=all; eq "apply: X11VNC_LISTEN=all без пароля — 78" 78 "$?"
check_not "apply: маркера nopw нет" test -e "$NOPW"
fresh; printf '%s' "$PASS" > "$FAKE/secret"
ht_hook configure CREAM_REASON=apply X11VNC_ALLOW_NO_PASSWORD=1 X11VNC_LISTEN=all
eq "X11VNC_LISTEN=all с паролем — 0" 0 "$?"
check "с паролем на всех интерфейсах — включён" test -L "$WANTS/x11vnc@alice.service"

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

echo "== без пользователя — предупреждение, 0, прежний экземпляр гасится =="
fresh
: > "$FAKE/user"
ln -s /etc/systemd/system/x11vnc@.service "$WANTS/x11vnc@carol.service"
ht_hook configure CREAM_REASON=apply; eq "без пользователя — 0" 0 "$?"
check_not "ничего не включено" ht_called '^systemctl enable'
check_not "прежний x11vnc@carol выключен" enabled carol
check "прежний x11vnc@carol гасится" ht_called '^systemctl --no-block stop x11vnc@carol\.service'

echo "== configure/apply: нет Xorg или менеджера входа — 1 (Р2), на сборке — без проверки =="
for what in xorg dm dangling; do
    fresh
    case "$what" in
        xorg) rm -f "$ROOT/usr/lib/xorg/Xorg" ;;
        dm) rm -f "$SYSD/display-manager.service" ;;
        dangling) rm -f "$ROOT/lib/systemd/system/lightdm.service" ;;
    esac
    ln -s /etc/systemd/system/x11vnc@.service "$WANTS/x11vnc@alice.service"
    ht_hook configure CREAM_REASON=boot X11VNC_ALLOW_NO_PASSWORD=1; eq "$what: configure — 1" 1 "$?"
    check "$what: текст про existing-desktop" grep -qF 'поставьте стол или `existing-desktop`' <(ht_out)
    check_not "$what: экземпляр выключен" enabled alice
    check "$what: экземпляр гасится" ht_called '^systemctl --no-block stop x11vnc@alice\.service'
    check_not "$what: перезапуска нет" ht_called '^systemctl --no-block restart'
    ht_hook apply X11VNC_ALLOW_NO_PASSWORD=1; eq "$what: apply — 1" 1 "$?"
done
fresh; rm -f "$ROOT/usr/lib/xorg/Xorg" "$SYSD/display-manager.service"
HT_PHASE=build ht_hook configure CREAM_REASON=install X11VNC_ALLOW_NO_PASSWORD=1
eq "сборка образа: без Xorg и DM — 0" 0 "$?"

echo "== configure: менеджер входа включён, но не запущен — 0, экземпляр включён без перезапуска (R11) =="
fresh; rm -f "$FAKE/active-display-manager"
printf '%s' "$PASS" > "$FAKE/secret"
ht_hook configure CREAM_REASON=install; eq "DM не запущен — 0" 0 "$?"
check "x11vnc@alice включён (поднимется на загрузке)" enabled alice
check_not "перезапуска нет (Requires= поднял бы менеджер входа)" ht_called '^systemctl --no-block restart'
check "предупреждение" grep -q 'менеджер входа не запущен' <(ht_out)

echo "== configure: X11VNC_USER — этот пользователь, без cloud-user =="
fresh; printf '%s' "$PASS" > "$FAKE/secret"
mkdir -p "$ROOT/home/carol"
ht_hook configure CREAM_REASON=boot X11VNC_USER=carol; eq "X11VNC_USER=carol — 0" 0 "$?"
check "x11vnc@carol включён" enabled carol
check "x11vnc@carol перезапущен" restarted carol
check_not "x11vnc@alice не включён" enabled alice
check "файл пароля — carol" ht_called '^chown carol '
check_not "cloud-user не ждали" ht_called '^sleep'

echo "== configure/apply: X11VNC_USER — системная учётка, root, nobody, нет в passwd — 78 (Р3) =="
for u in gdm root nobody ghost; do
    fresh; printf '%s' "$PASS" > "$FAKE/secret"
    ln -s /etc/systemd/system/x11vnc@.service "$WANTS/x11vnc@alice.service"
    ht_hook configure CREAM_REASON=boot "X11VNC_USER=$u"; eq "configure X11VNC_USER=$u — 78" 78 "$?"
    check_not "$u: экземпляр не включён" enabled "$u"
    check_not "$u: перезапуска нет" ht_called '^systemctl --no-block restart'
    check_not "$u: прежний x11vnc@alice выключен" enabled alice
    check "$u: прежний экземпляр гасится" ht_called '^systemctl --no-block stop x11vnc@alice\.service'
    check "$u: причина в журнале (uid 1000..65533)" grep -q '1000' <(ht_out)
    ht_hook apply "X11VNC_USER=$u"; eq "apply X11VNC_USER=$u — 78" 78 "$?"
done

echo "== configure: пользователь cloud-init — системный или root — предупреждение, 0, экземпляры гасятся =="
for cu in root gdm 'x;rm -rf /'; do
    fresh; printf '%s' "$PASS" > "$FAKE/secret"
    echo "$cu" > "$FAKE/user"
    ln -s /etc/systemd/system/x11vnc@.service "$WANTS/x11vnc@carol.service"
    ht_hook configure CREAM_REASON=apply; eq "cloud-init «$cu» — 0" 0 "$?"
    check_not "cloud-init «$cu»: ничего не включено" ht_called '^systemctl enable'
    check "cloud-init «$cu»: x11vnc@carol гасится" ht_called '^systemctl --no-block stop x11vnc@carol\.service'
done

echo "== configure: X11VNC_DISPLAY проверяется =="
fresh
ht_hook configure CREAM_REASON=apply X11VNC_ALLOW_NO_PASSWORD=1 'X11VNC_DISPLAY=:0;x'; rc=$?
check "X11VNC_DISPLAY с мусором — отказ" test "$rc" -ne 0
check_not "X11VNC_DISPLAY с мусором: не включён" ht_called '^systemctl enable'
fresh
ht_hook configure CREAM_REASON=apply X11VNC_ALLOW_NO_PASSWORD=1 X11VNC_DISPLAY=:1; eq "X11VNC_DISPLAY=:1 — 0" 0 "$?"
ht_hook configure CREAM_REASON=apply X11VNC_ALLOW_NO_PASSWORD=1 'X11VNC_USER=-x'; eq "X11VNC_USER не имя — 78" 78 "$?"

echo "== configure: диагноз seat0 одной строкой =="
fresh; printf '%s' "$PASS" > "$FAKE/secret"
seat0 3 bob x11 :0
ht_hook configure CREAM_REASON=apply; eq "configure — 0" 0 "$?"
check "диагноз: на seat0 bob" grep -q 'на seat0 сеанс bob (x11)' <(ht_out)
check "подсказка: X11VNC_USER=bob" grep -q 'X11VNC_USER=bob' <(ht_out)
fresh; printf '%s' "$PASS" > "$FAKE/secret"
seat0 2 alice wayland -
ht_hook configure CREAM_REASON=apply; eq "Wayland у alice: configure — 0" 0 "$?"
check "диагноз: Wayland и gdm-xorg" grep -q 'gdm-xorg' <(ht_out)

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
# Without a password only on the loopback (owner's ruling 2026-11-12).
X11VNC_ALLOW_NO_PASSWORD=1 X11VNC_LISTEN=all "$EXT/files/run-x11vnc.sh" --decide-auth "$PF" "$NOPW" > "$ROOT/out" 2>&1
eq "-nopw и X11VNC_LISTEN=all — 78" 78 "$?"
eq "-nopw и X11VNC_LISTEN=all — отказ" "refuse" "$(tail -n1 "$ROOT/out")"
check "сказано, что без пароля — только петля" grep -q 'только на петле' "$ROOT/out"
X11VNC_ALLOW_NO_PASSWORD=1 X11VNC_LISTEN=localhost "$EXT/files/run-x11vnc.sh" --decide-auth "$PF" "$NOPW" > "$ROOT/out" 2>&1
eq "-nopw на петле — 0" 0 "$?"
printf 'xxxxxxxx' > "$PF"; chmod 0600 "$PF"
eq "файл есть — -rfbauth" "-rfbauth $PF" "$(wrap "$PF" "$NOPW" | tail -n1)"
chmod 0000 "$PF"
if [[ "$(id -u)" != 0 ]]; then
    eq "файл не читается — отказ" "refuse" "$(wrap "$PF" "$NOPW" | tail -n1)"
fi

# run_wrapper <env pairs…>: the wrapper as systemd starts it for x11vnc@<WR_USER>
# (alice by default): config in the environment, nothing else.
run_wrapper() {
    (
        cd / || exit 125
        exec env -i "PATH=$ROOT/bin:$HT_PATH_TAIL" LANG=C.UTF-8 "CREAM_ROOT=$ROOT" "$@" \
            /bin/bash "$EXT/files/run-x11vnc.sh" "${WR_USER:-alice}" < /dev/null
    ) > "$ROOT/out" 2>&1
}
# wr_root: alice is logged in on seat0, an X11 session on :0 (logind Display),
# her ~/.Xauthority opens every display (xdpyinfo); the password file is there;
# the x11vnc binary is a fake that dumps its argv. sleep is counted, and the
# 2000th kills the wrapper (a test that would wait for ever fails instead).
wr_root() {
    fresh
    mkdir -p "$ROOT/etc/x11vnc" "$ROOT/usr/bin"
    printf 'xxxxxxxx' > "$PF"; chmod 0600 "$PF"
    : > "$ROOT/home/alice/.Xauthority"
    ht_fake xdpyinfo 'exit 0'
    ht_fake pgrep 'exit 1'
    printf '#!/bin/sh\nprintf "%%s\\n" "$@" > %q\nexit 0\n' "$FAKE/x11vnc.args" > "$ROOT/usr/bin/x11vnc"
    chmod +x "$ROOT/usr/bin/x11vnc"
    seat0 2 alice x11 :0
    ht_fake sleep 'n=$(( $(cat "$FAKE/sleeps" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/sleeps"
(( n < 2000 )) || kill -TERM "$PPID"
exit 0'
}
# arg_after <flag>: the argument x11vnc got after <flag>.
arg_after() { awk -v f="$1" 'p { print; exit } $0 == f { p = 1 }' "$FAKE/x11vnc.args" 2>/dev/null; }

echo "== обёртка: X11VNC_DISPLAY — auto по logind, :N жёстко, без ключа — auto (Р4) =="
wr_root; seat0 2 alice x11 :1
run_wrapper; eq "ключ не задан — 0" 0 "$?"
eq "ключ не задан: дисплей из logind — :1" :1 "$(arg_after -display)"
eq "authority — ~/.Xauthority alice" "$ROOT/home/alice/.Xauthority" "$(arg_after -auth)"
check "путь назван в журнале (logind)" grep -q 'logind' "$ROOT/out"
check "пароль — -rfbauth" grep -qx -- '-rfbauth' "$FAKE/x11vnc.args"
check "только петля" grep -qx -- '-localhost' "$FAKE/x11vnc.args"
check_not "-loop нет: пропажу X ловит юнит (Restart=always), обёртка найдёт новый сеанс" grep -qx -- '-loop' "$FAKE/x11vnc.args"
wr_root; seat0 2 alice x11 :1
run_wrapper X11VNC_DISPLAY=auto
eq "auto: дисплей :1" :1 "$(arg_after -display)"
wr_root; seat0 2 alice x11 :1
run_wrapper X11VNC_DISPLAY=:0
eq "сохранённое :0 не меняется" :0 "$(arg_after -display)"
wr_root
run_wrapper 'X11VNC_DISPLAY=:0;x'; eq "негодный X11VNC_DISPLAY — 78" 78 "$?"
check_not "x11vnc не запущен" test -e "$FAKE/x11vnc.args"

echo "== обёртка: logind не отдаёт сеанс — запасной путь 2 (:0) =="
wr_root
rm -f "$FAKE"/user.* "$FAKE"/session.* "$FAKE/seat.seat0"
ht_fake stat 'echo "1000 600"'
ht_fake xhost 'echo "access control enabled, only authorized clients can connect"'
run_wrapper; eq "запасной путь — 0" 0 "$?"
eq "дисплей :0 (как 5.x)" :0 "$(arg_after -display)"
check "путь назван: запасной" grep -q 'запасной путь' "$ROOT/out"

echo "== обёртка: сессия на Wayland — 78, юнит не крутит перезапуски =="
wr_root
seat0 2 alice wayland -
run_wrapper; eq "Wayland — 78 (EX_CONFIG)" 78 "$?"
check "сказано про Wayland" grep -q 'Wayland' "$ROOT/out"
check "сказано, как вернуть" grep -q 'systemctl restart x11vnc@alice' "$ROOT/out"
check "подсказка: gdm-xorg" grep -q 'gdm-xorg' "$ROOT/out"
check_not "x11vnc не запущен" test -e "$FAKE/x11vnc.args"
check_not "list-sessions не разбирается" ht_called '^loginctl list-sessions'
wr_root
seat0 2 alice wayland -
run_wrapper X11VNC_DISPLAY=:0; eq "Wayland при жёстком :0 — тоже 78" 78 "$?"

echo "== обёртка: пользователь — uid 1000..65533, иначе 78 (Р3) =="
for u in gdm root nobody ghost -x; do
    wr_root
    WR_USER="$u" run_wrapper; eq "x11vnc@$u — 78" 78 "$?"
    check_not "$u: x11vnc не запущен" test -e "$FAKE/x11vnc.args"
    check_not "$u: дисплей не искали" ht_called '^(loginctl|xdpyinfo)'
done
wr_root
WR_USER='Bad\x41\e[2J' run_wrapper; eq "негодное имя — 78" 78 "$?"
check_not "негодное имя не попадает в журнал (echo -e)" grep -qE 'Bad|BadA' "$ROOT/out"
wr_root; seat0 2 carol x11 :0; mkdir -p "$ROOT/home/carol"; : > "$ROOT/home/carol/.Xauthority"
WR_USER=carol run_wrapper; eq "x11vnc@carol (uid 1002) — 0" 0 "$?"
eq "x11vnc@carol: authority carol" "$ROOT/home/carol/.Xauthority" "$(arg_after -auth)"

echo "== обёртка: решение о пароле — до ожидания сеанса =="
wr_root; rm -f "$PF"
run_wrapper; eq "нет ни файла, ни маркера — 1" 1 "$?"
check_not "сеанс не искали" ht_called '^(loginctl|xdpyinfo)'
check_not "x11vnc не запущен" test -e "$FAKE/x11vnc.args"

echo "== обёртка: ожидание сеанса — диагноз раз в 5 минут =="
wr_root
rm -f "$FAKE"/user.alice "$FAKE"/session.2
seat0 3 bob x11 :0
ht_fake xdpyinfo '[[ -e "$FAKE/x-up" ]]'
ht_fake sleep 'n=$(( $(cat "$FAKE/sleeps" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/sleeps"
if (( n == 130 )); then
    printf "Name=alice\nSeat=seat0\nClass=user\nType=x11\nDisplay=:0\nState=active\nRemote=no\n" > "$FAKE/session.2"
    printf "Sessions=2\n" > "$FAKE/user.alice"; printf "ActiveSession=2\n" > "$FAKE/seat.seat0"; : > "$FAKE/x-up"
fi
(( n < 2000 )) || kill -TERM "$PPID"
exit 0'
run_wrapper; eq "дождался — 0" 0 "$?"
check "x11vnc запущен, когда alice вошла" test -e "$FAKE/x11vnc.args"
eq "строка ожидания — на 0, 5 и 10 минуте" 3 "$(grep -c 'жду X-сессию' "$ROOT/out")"
check "диагноз: на seat0 bob" grep -q 'на seat0 сеанс bob (x11)' "$ROOT/out"
check "подсказка: X11VNC_USER=bob" grep -q 'X11VNC_USER=bob' "$ROOT/out"

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
