#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the selkies extension (cream/v1): manifest, unit, hooks install,
# configure, apply and remove, and the wrapper run-selkies.sh on a scratch root
# (CREAM_ROOT) the way cream and systemd run them. getent, id, systemctl,
# loginctl, xdpyinfo, pgrep, pactl, sleep, dpkg, curl and apt-get are fakes; the
# cloud-user library is a stub, the AppImage is a fake extracted tree. root,
# systemd, a display manager and the network are not needed.
#
# Security is the point: no start without authentication unless
# SELKIES_ALLOW_NO_AUTH=1 (fail-closed), secrets never in argv, the output or
# the environment of helper processes, the Teleport declaration written without
# following symlinks. 7.0.0 (spec 2026-11-12-existing-desktop §4.4): the user
# (SELKIES_USER or cloud-user) only with 1000 <= uid < 65534, the display by
# lib/x-session.sh (SELKIES_DISPLAY=auto), the machine check (Xorg and an
# enabled display manager) in install and configure; loginctl answers from
# files $FAKE/user.<name>, session.<sid>, seat.seat0.
#
#   extensions/debian/selkies/tests/test-selkies.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

PW='Pw-Basic-7f3a9c1e'
VO='Pw-View-2b8d4e6f'
TOKEN='Tok-Master-9e1c5a7b'
VER=2.0.0

# sk_root: fresh root; user alice (uid 1000, home /home/alice) from the
# cloud-user library stub ($FAKE/user); Xorg is there, the display manager is
# enabled (display-manager.service) and active; logind has no session (the
# fake loginctl answers from files, none yet).
sk_root() {
    ht_root "$EXT"
    mkdir -p "$ROOT/home/alice" "$ROOT/home/root" "$ROOT/usr/lib/xorg" "$ROOT/etc/systemd/system" \
        "$ROOT/lib/systemd/system"
    printf '#!/bin/sh\n' > "$ROOT/usr/lib/xorg/Xorg"; chmod 0755 "$ROOT/usr/lib/xorg/Xorg"
    : > "$ROOT/lib/systemd/system/lightdm.service"
    ln -s /lib/systemd/system/lightdm.service "$ROOT/etc/systemd/system/display-manager.service"
    printf '%s\n' 'root:x:0:0::/root:/bin/bash' 'alice:x:1000:1000::/home/alice:/bin/bash' \
        'bob:x:1001:1001::/home/bob:/bin/bash' 'carol:x:1002:1002::/home/carol:/bin/bash' \
        'gdm:x:120:125:Gnome Display Manager:/var/lib/gdm3:/bin/false' \
        'nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin' > "$FAKE/passwd"
    ht_fake loginctl 'env > "$FAKE/loginctl.env"
cmd="$1"; target="${!#}"
case "$cmd" in
    show-user) f="$FAKE/user.$target" ;;
    show-session) f="$FAKE/session.$target" ;;
    show-seat) f="$FAKE/seat.$target" ;;
    *) exit 1 ;;
esac
[[ -f "$f" ]] || exit 1
cat "$f"' 
    echo alice > "$FAKE/user"
    : > "$FAKE/active-display-manager"
    : > "$FAKE/units"
    ht_fake getent '
f="$FAKE/$1"; [[ -f "$f" ]] || exit 2
[[ -z "${2-}" ]] && { cat "$f"; exit 0; }
grep -E "^${2}:" "$f" || exit 2'
    ht_fake id '
[[ "$1" == -u ]] || exit 2
line="$(grep -E "^$2:" "$FAKE/passwd")" || exit 1
echo "$line" | cut -d: -f3'
    ht_fake systemctl '
case "$1" in
    is-active)
        for a in "$@"; do [[ -e "$FAKE/active-${a%.service}" ]] && exit 0; done
        exit 3 ;;
    list-units) cat "$FAKE/units" ;;
esac
exit 0'
    ht_fake sleep
    LIB="$ROOT/opt/cream/ext/cloud-user/get_cloud_user.sh"
    mkdir -p "$(dirname "$LIB")"
    printf '#!/usr/bin/env bash\ncat %q 2>/dev/null || { echo "Error: no user" >&2; exit 1; }\n' "$FAKE/user" > "$LIB"
    chmod +x "$LIB"
    APPS="$ROOT/etc/cream/teleport/apps.d"
    DECL="$APPS/selkies.conf"
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
# fake_appimage: an extracted AppImage already in /opt/selkies/<ver>; its
# selkies binary dumps its environment and argv into $FAKE.
fake_appimage() {
    local bin="$ROOT/opt/selkies/$VER/usr/conda/bin/selkies"
    mkdir -p "$(dirname "$bin")"
    printf '#!/usr/bin/env bash\n[[ "${1-}" == --help ]] && exit 0\nenv > %q\nprintf "%%s\\n" "$*" > %q\nexit 0\n' \
        "$FAKE/selkies.env" "$FAKE/selkies.args" > "$bin"
    chmod +x "$bin"
}
mf() { python3 -c 'import sys,yaml; m=yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
started() { ht_called "^systemctl (start|restart) --no-block selkies@$1\\.service"; }
leaked() { grep -rqF -e "$PW" -e "$VO" -e "$TOKEN" "$@" 2>/dev/null; }
blocking_systemctl() { grep -E '^systemctl (start|restart|stop|reload|enable --now|disable --now)' "$FAKE/calls" | grep -qv -- '--no-block'; }

# mask_dm: display-manager.service masked — a link to /dev/null (systemctl mask).
mask_dm() {
    mkdir -p "$ROOT/dev"; : > "$ROOT/dev/null"
    ln -sfn /dev/null "$ROOT/etc/systemd/system/display-manager.service"
}
# x0srv: an X server really on :0 for lib/x-session.sh fallback 2 — the lock
# with its pid, a live Xorg (/proc/<pid>/comm), the socket /tmp/.X11-unix/X0,
# and both listeners of X0 (file, abstract) among its fds in /proc/net/unix.
x0srv() {
    mkdir -p "$ROOT/tmp/.X11-unix" "$ROOT/proc/4300/fd" "$ROOT/proc/net"
    printf '%10d\n' 4300 > "$ROOT/tmp/.X0-lock"; chmod 0444 "$ROOT/tmp/.X0-lock"
    echo Xorg > "$ROOT/proc/4300/comm"
    python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$ROOT/tmp/.X11-unix/X0"
    ln -sfn 'socket:[61000]' "$ROOT/proc/4300/fd/3"; ln -sfn 'socket:[61001]' "$ROOT/proc/4300/fd/4"
    { echo "Num       RefCount Protocol Flags    Type St Inode Path"
      echo "0000000000000000: 00000002 00000000 00010000 0001 01 61000 /tmp/.X11-unix/X0"
      echo "0000000000000000: 00000002 00000000 00010000 0001 01 61001 @/tmp/.X11-unix/X0"
    } > "$ROOT/proc/net/unix"
}

echo "== манифест и раскладка =="
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "name" selkies "$(mf 'm["name"]')"
eq "версия 7.0.0 (SELKIES_USER, SELKIES_DISPLAY=auto, проверка машины)" 7.0.0 "$(mf 'm["version"]')"
eq "SELKIES_USER: имя, пусто — cloud-user" "re:^[a-z_][a-z0-9_-]{0,31}\$||True" \
    "$(mf '(lambda k: k["type"] + "|" + k["default"] + "|" + str(k.get("empty")))(m["config"]["keys"]["SELKIES_USER"])')"
eq "SELKIES_DISPLAY: auto или :N, умолчание auto" "re:^(auto|:[0-9]+(\.[0-9]+)?)\$|auto|True" \
    "$(mf '(lambda k: k["type"] + "|" + k["default"] + "|" + str(k.get("empty")))(m["config"]["keys"]["SELKIES_DISPLAY"])')"
check "умолчание манифеста = запасное значение обёртки (auto)" \
    grep -qF 'WANT_DISPLAY="${SELKIES_DISPLAY:-auto}"' "$EXT/files/run-selkies.sh"
check "selkies — потребитель lib/x-session.sh" grep -qx 'debian/selkies' "$EXT/../../../lib/x-session.consumers"
check "обёртка берёт files/x-session.sh" grep -q 'files/x-session.sh' "$EXT/files/run-selkies.sh"
check "configure берёт files/x-session.sh" grep -q 'files/x-session.sh' "$EXT/files/selkies.sh"
eq "cream >=1.2.0 (every_boot, спека cream §10.9)" ">=1.2.0" "$(mf 'm["cream"]')"
eq "configure на каждой загрузке (аудит 2026-10-21)" True "$(mf 'm["hooks"]["configure"].get("every_boot")')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "стадия graphical" graphical "$(mf 'm["hooks"]["configure"]["stage"]')"
eq "хуки" "apply configure install remove" "$(mf '" ".join(sorted(m["hooks"]))')"
eq "depends только cloud-user (fetch не нужен)" "cloud-user >=1.0.0 <2" "$(mf '" ".join(d["name"]+" "+d["version"] for d in m["depends"])')"
eq "provides" "web-remote-desktop" "$(mf '" ".join(m["provides"])')"
eq "requires" "display-manager x11-server" "$(mf '" ".join(sorted(m["requires"]))')"
eq "секреты — secret: file" "SELKIES_BASIC_AUTH_PASSWORD SELKIES_BASIC_AUTH_VIEWONLY_PASSWORD SELKIES_MASTER_TOKEN" \
    "$(mf '" ".join(sorted(k for k, v in m["config"]["keys"].items() if v.get("secret") == "file"))')"
eq "Р8: SELKIES_ALLOW_NO_AUTH — bool, 0" "bool 0" \
    "$(mf 'm["config"]["keys"]["SELKIES_ALLOW_NO_AUTH"]["type"] + " " + m["config"]["keys"]["SELKIES_ALLOW_NO_AUTH"]["default"]')"
eq "шаблон SELKIES_*" True "$(mf 'm["config"]["keys"]["SELKIES_*"]["pattern"]')"
eq "SELKIES_ENABLE_BASIC_AUTH — не ручка: ставит обёртка по паролю" False \
    "$(mf '"SELKIES_ENABLE_BASIC_AUTH" in m["config"]["keys"]')"
eq "SELKIES_ENCODER: пусто — выбор клиента (одно значение Selkies запирает)" ":True" \
    "$(mf 'm["config"]["keys"]["SELKIES_ENCODER"]["default"] + ":" + str(m["config"]["keys"]["SELKIES_ENCODER"].get("empty"))')"
eq "files: юнит" "files/selkies@.service /etc/systemd/system/selkies@.service 0644" \
    "$(mf '" ".join(f["src"]+" "+f["dst"]+" "+f["mode"] for f in m["files"])')"
# Every value reaches an EnvironmentFile and a Teleport declaration: the types
# admit no newline, quote, $, backquote, backslash or space (re checked with
# Python; the classes used are the common subset of RE2 and re).
bad_types="$(python3 - "$EXT/extension.yaml" <<'PY'
import re, sys, yaml
m = yaml.safe_load(open(sys.argv[1]))
bad = []
for k, s in m["config"]["keys"].items():
    t = s["type"]
    if t in ("bool", "port") or t.startswith("enum:"):
        continue
    if not t.startswith("re:"):
        bad.append(f"{k}:{t}")
        continue
    rx = re.compile("^(?:" + t[3:] + ")$")
    for v in ("a\nb", 'a"b', "a'b", "a$b", "a`b", "a\\b", "a b"):
        if rx.match(v):
            bad.append(f"{k}:{v!r}")
print(" ".join(bad))
PY
)"
eq "типы ключей: без \\n, кавычек, \$, \`, \\, пробела" "" "$bad_types"
eq "фиктивный пароль (буквы, цифры, дефис) подходит под тип" True \
    "$(mf 'bool(__import__("re").fullmatch(m["config"]["keys"]["SELKIES_BASIC_AUTH_PASSWORD"]["type"][3:], "fake-pass-0123456789abcdef"))')"
for f in hooks/install hooks/configure hooks/apply hooks/remove files/selkies.sh files/run-selkies.sh; do
    check "$f исполняемый" test -x "$EXT/$f"
done
for f in install.sh configure.sh configure-selkies.service knobs knobs.apply teleport-app.sh run-selkies.sh selkies@.service lib; do
    check_not "layout 2: $f не остался в корне" test -e "$EXT/$f"
done
UNIT="$EXT/files/selkies@.service"
# Orin 2026-11-12: config holds only the keys set explicitly, so the defaults of
# the manifest come from the effective file configure writes; config after it
# (an explicit key wins), secrets last; config is optional (a password alone
# creates no config).
eq "юнит: действующие значения → config → secrets" \
    "-/var/lib/cream/ext/selkies/env -/etc/cream/selkies/config -/etc/cream/selkies/secrets" \
    "$(sed -n 's/^EnvironmentFile=//p' "$UNIT" | tr '\n' ' ' | sed 's/ $//')"
check "юнит: от имени пользователя" grep -qx 'User=%i' "$UNIT"
check "юнит: обёртка из дерева расширения" grep -qx 'ExecStart=/bin/bash /opt/cream/ext/selkies/files/run-selkies.sh %i' "$UNIT"
check "юнит: отказ по аутентификации не перезапускается" grep -qx 'RestartPreventExitStatus=78' "$UNIT"
check "юнит: комментарий к 78 — uid-правило" grep -qE '^#.*uid outside 1000\.\.65533' "$UNIT"
check "юнит: комментарий к 78 — SELKIES_DISPLAY" grep -qE '^#.*SELKIES_DISPLAY that is neither auto nor :N' "$UNIT"
check "манифест: 78 у configure — только за SELKIES_USER" grep -qE '^#.*SELKIES_USER not in passwd or with a uid' "$EXT/extension.yaml"
check_not "юнит: не включается сам (стартует configure)" grep -q '^WantedBy=' "$UNIT"

echo "== install: AppImage уже распакован =="
sk_root; fake_appimage
ht_fake dpkg 'echo amd64'
ht_fake apt-get
ht_hook install; eq "install — 0" 0 "$?"
eq "current → $VER" "$ROOT/opt/selkies/$VER" "$(readlink "$ROOT/opt/selkies/current")"
check_not "сеть не нужна" ht_called '^curl'
check "x11-utils и xauth" ht_called '^apt-get .*install .*x11-utils xauth'
check "x11-xserver-utils (xhost, П15)" ht_called '^apt-get .*install .*x11-xserver-utils'
eq "apt-get update — ровно один раз (curl уже был)" 1 "$(grep -c '^apt-get .*update' "$FAKE/calls")"
check "update — до установки x11-utils" \
    test "$(grep -n '^apt-get .*update' "$FAKE/calls" | head -1 | cut -d: -f1)" -lt \
         "$(grep -n '^apt-get .*install .*x11-utils' "$FAKE/calls" | head -1 | cut -d: -f1)"
check_not "install не трогает службы" ht_called '^systemctl'
check_not "install не пишет объявление (это configure)" test -e "$DECL"
link1="$(stat -c '%i %Y' "$ROOT/opt/selkies/current")"
ht_hook install; eq "повтор — 0" 0 "$?"
eq "повтор: ссылка та же" "$link1" "$(stat -c '%i %Y' "$ROOT/opt/selkies/current")"

echo "== install: живая машина без Xorg или без менеджера входа — 20 (Р2) =="
sk_root; fake_appimage
ht_fake dpkg 'echo amd64'
ht_fake apt-get
rm -f "$ROOT/usr/lib/xorg/Xorg"
ht_hook install; eq "нет Xorg — 20" 20 "$?"
check "текст: поставьте стол или existing-desktop" grep -q 'нет X-сервера / менеджера входа: поставьте стол или `existing-desktop`' "$ROOT/out"
check_not "ничего не качается и не ставится" ht_called '^(curl|apt-get)'
check_not "ссылки current нет" test -L "$ROOT/opt/selkies/current"
mkdir -p "$ROOT/usr/bin"; printf '#!/bin/sh\n' > "$ROOT/usr/bin/Xorg"
ht_hook install; eq "Xorg в /usr/bin — 0" 0 "$?"
sk_root; fake_appimage
ht_fake dpkg 'echo amd64'
ht_fake apt-get
rm -f "$ROOT/etc/systemd/system/display-manager.service"
ht_hook install; eq "нет display-manager.service — 20" 20 "$?"
check "текст про менеджер входа" grep -q 'менеджера входа' "$ROOT/out"
rm -f "$ROOT/usr/lib/xorg/Xorg"
HT_PHASE=build ht_hook install; eq "сборка образа: без Xorg и DM — 0 (стол ставит та же сборка)" 0 "$?"
sk_root; fake_appimage
ht_fake dpkg 'echo amd64'
ht_fake apt-get
rm -f "$ROOT/lib/systemd/system/lightdm.service"
ht_hook install; eq "display-manager.service висит (цели нет) — 20" 20 "$?"
check_not "висячая ссылка: ничего не качается" ht_called '^(curl|apt-get)'
rm -f "$ROOT/usr/lib/xorg/Xorg"
HT_PHASE=build ht_hook install; eq "сборка образа: висячая ссылка, без Xorg — 0" 0 "$?"
sk_root; fake_appimage
ht_fake dpkg 'echo amd64'
ht_fake apt-get
mask_dm
ht_hook install; eq "display-manager.service замаскирован — 20" 20 "$?"
check_not "замаскирован: ничего не качается" ht_called '^(curl|apt-get)'

echo "== install: sha256 не совпал — отказ, ничего не распаковано =="
sk_root
ht_fake dpkg 'echo arm64'
ht_fake apt-get
ht_fake curl 'while (( $# )); do [[ "$1" == -o ]] && { echo bogus > "$2"; }; shift; done; exit 0'
ht_hook install; check_not "install не 0" test "$?" -eq 0
check "скачивался AppImage aarch64" ht_called "^curl .*selkies-$VER-aarch64\\.AppImage"
check_not "ничего не распаковано" test -e "$ROOT/opt/selkies/$VER"
check_not "ссылки current нет" test -L "$ROOT/opt/selkies/current"

echo "== install: curl 56 дважды (focal, curl 7.68) — третья попытка того же адреса =="
sk_root
ht_fake dpkg 'echo arm64'
ht_fake apt-get
ht_fake curl '
n=$(( $(cat "$FAKE/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/n"
(( n <= 2 )) && { echo "curl: (56) Recv failure: Connection reset by peer" >&2; exit 56; }
while (( $# )); do [[ "$1" == -o ]] && { echo bogus > "$2"; }; shift; done; exit 0'
ht_hook install; check_not "install не 0 (сумма подставного файла не сходится)" test "$?" -eq 0
eq "три вызова curl, все по первому адресу" 3 "$(grep -c "^curl .*/download/$VER/selkies-$VER-aarch64\.AppImage$" "$FAKE/calls")"
check "между попытками пауза" ht_called '^sleep 10$'
check "отказ — по sha256, а не по сети" grep -q 'sha256' "$ROOT/out"
check_not "ничего не распаковано" test -e "$ROOT/opt/selkies/$VER"
check_not "рабочий каталог убран" compgen -G "$ROOT/opt/selkies/.install.*"
check_not "без библиотеки fetch: /opt/cream/ext/fetch на корне нет" test -e "$ROOT/opt/cream/ext/fetch"
check "fetch_verified — своя files/fetch.sh = lib/fetch.sh" cmp -s "$EXT/../../../lib/fetch.sh" "$HT_EXT/files/fetch.sh"

echo "== install: без библиотеки fetch — скачано, проверено, распаковано =="
sk_root
ht_fake dpkg 'echo amd64'
ht_fake apt-get
APPIMG_OK='appimage-payload'
sed -i -E "s/\[x86_64\]=\"[0-9a-f]{64}\"/[x86_64]=\"$(printf '%s' "$APPIMG_OK" | sha256sum | cut -d' ' -f1)\"/" "$HT_EXT/hooks/install"
ht_fake curl 'while (( $# )); do [[ "$1" == -o ]] && { printf %s '"$APPIMG_OK"' > "$2"; }; shift; done; exit 0'
ht_hook install
check "AppImage скачан через fetch_verified (сумма сошлась, дальше — распаковка)" ht_called "^curl .*selkies-$VER-x86_64\.AppImage"
check_not "отказа по sha256 нет" grep -q 'sha256 AppImage не совпал' "$ROOT/out"
check_not "нет жалобы на отсутствующую библиотеку" grep -q 'fetch' "$ROOT/out"
check_not "без библиотеки fetch: /opt/cream/ext/fetch на корне нет" test -e "$ROOT/opt/cream/ext/fetch"
check "fetch_verified — своя files/fetch.sh = lib/fetch.sh" cmp -s "$EXT/../../../lib/fetch.sh" "$HT_EXT/files/fetch.sh"

echo "== configure: нет пароля и нет SELKIES_ALLOW_NO_AUTH — не стартует =="
sk_root
ht_fake systemctl '
case "$1" in
    is-active) [[ -e "$FAKE/active-display-manager" ]] && exit 0; exit 3 ;;
    list-units) echo "selkies@alice.service loaded active running Selkies" ;;
esac
exit 0'
mkdir -p "$APPS"; echo 'NAME=selkies' > "$DECL"
ht_hook configure CREAM_REASON=boot; eq "configure — 0 (предупреждение, не сбой)" 0 "$?"
check "предупреждение про аутентификацию" grep -q 'SELKIES_ALLOW_NO_AUTH' "$ROOT/out"
check_not "selkies@alice не запускается" started alice
check "запущенный экземпляр гасится (--no-block)" ht_called '^systemctl stop --no-block selkies@alice\.service'
check_not "объявление для Teleport снято" test -e "$DECL"
check_not "блокирующих systemctl нет" blocking_systemctl

echo "== configure: только пароль просмотра — не аутентификация =="
sk_root; ht_secret SELKIES_BASIC_AUTH_VIEWONLY_PASSWORD "$VO"
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
check_not "без основного пароля не стартует" started alice
check_not "пароль не в выводе" leaked "$ROOT/out" "$FAKE"

echo "== configure: пустой пароль — нет пароля =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD '""'
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
check_not "пустой пароль не открывает" started alice

echo "== configure: пароль задан — старт, объявление =="
sk_root
ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"; ht_secret SELKIES_BASIC_AUTH_VIEWONLY_PASSWORD "$VO"
ht_secret SELKIES_MASTER_TOKEN "$TOKEN"
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
check "загрузка: start --no-block selkies@alice" ht_called '^systemctl start --no-block selkies@alice\.service'
check_not "в selkies@ ничего не включается навсегда" ht_called '^systemctl enable'
eq "объявление" "NAME=selkies URI=http://127.0.0.1:8080 ICON=desktop" "$(tr '\n' ' ' < "$DECL" | sed 's/ $//')"
eq "объявление 0644" 644 "$(stat -c %a "$DECL")"
check_not "секреты не в выводе, argv, журнале вызовов" leaked "$ROOT/out" "$FAKE"
check_not "секреты не в объявлении" leaked "$APPS"
check_not "блокирующих systemctl нет" blocking_systemctl
check_not "ожидания нет: пользователь есть" ht_called '^sleep'
check_not "предупреждения про открытый доступ нет" grep -q 'SELKIES_ALLOW_NO_AUTH=1' "$ROOT/out"
decl1="$(stat -c '%i %Y' "$DECL")"
ht_hook configure CREAM_REASON=boot; eq "повтор — 0" 0 "$?"
eq "повтор: объявление не переписано" "$decl1" "$(stat -c '%i %Y' "$DECL")"

echo "== configure: действующие значения — с умолчаниями манифеста (Orin 2026-11-12) =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
EFF="$ROOT/var/lib/cream/ext/selkies/env"
# What cream show reports: every non-secret key of the manifest with a
# non-empty default, sorted.
want_eff="$(python3 - "$EXT/extension.yaml" <<'PY'
import sys, yaml
keys = yaml.safe_load(open(sys.argv[1]))["config"]["keys"]
print("\n".join(sorted(f"{k}={v['default']}" for k, v in keys.items()
                       if not v.get("pattern") and not v.get("secret") and v.get("default"))))
PY
)"
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
check "файл действующих значений — обычный файл" test -f "$EFF" -a ! -L "$EFF"
eq "файл 0644 (секретов нет)" 644 "$(stat -c %a "$EFF")"
eq "файл = непустые умолчания манифеста" "$want_eff" "$(cat "$EFF")"
check "SELKIES_ENABLE_RESIZE=false — монитор не меняется" grep -qx 'SELKIES_ENABLE_RESIZE=false' "$EFF"
check_not "пустые умолчания не пишутся (пусто у Selkies — своё умолчание)" \
    grep -qE '^SELKIES_(USER|ENCODER|HTTPS_CERT|HTTPS_KEY)=' "$EFF"
check "SELKIES_DISPLAY=auto — обёртке (7.0.0: умолчание auto)" grep -qx 'SELKIES_DISPLAY=auto' "$EFF"
check_not "секретов нет" leaked "$EFF"
check_not "только SELKIES_*" grep -qv '^SELKIES_' "$EFF"
eff1="$(stat -c '%i %Y' "$EFF")"
ht_hook configure CREAM_REASON=boot; eq "повтор — 0" 0 "$?"
eq "повтор: файл не переписан" "$eff1" "$(stat -c '%i %Y' "$EFF")"
ht_hook configure CREAM_REASON=boot SELKIES_PORT=9090 SELKIES_SCALING_DPI=96; eq "заданные — 0" 0 "$?"
check "заданное значение" grep -qx 'SELKIES_PORT=9090' "$EFF"
check "ключ шаблона SELKIES_*" grep -qx 'SELKIES_SCALING_DPI=96' "$EFF"
ht_hook configure CREAM_REASON=boot 'SELKIES_SCALING_DPI=9 6'; eq "значение с пробелом — 0" 0 "$?"
check_not "значение не для EnvironmentFile не пишется" grep -q '^SELKIES_SCALING_DPI=' "$EFF"
check "предупреждение про пропущенный ключ" grep -q 'SELKIES_SCALING_DPI' "$ROOT/out"
sk_root
ht_hook configure CREAM_REASON=boot; eq "без аутентификации — 0" 0 "$?"
check "без аутентификации файл тоже пишется" grep -qx 'SELKIES_ENABLE_RESIZE=false' "$EFF"
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
EFF="$ROOT/var/lib/cream/ext/selkies/env"
mkdir -p "$ROOT/victim"; echo keep > "$ROOT/victim/file"; ln -s "$ROOT/victim/file" "$EFF"
ht_hook configure CREAM_REASON=boot; eq "файл — ссылка: configure 0" 0 "$?"
eq "цель ссылки не тронута" keep "$(cat "$ROOT/victim/file")"
check "файл — обычный, на месте ссылки" test -f "$EFF" -a ! -L "$EFF"
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
rmdir "$ROOT/var/lib/cream/ext/selkies"; mkdir -p "$ROOT/victim"
ln -s "$ROOT/victim" "$ROOT/var/lib/cream/ext/selkies"
ht_hook configure CREAM_REASON=boot; eq "каталог состояния — ссылка: configure 0" 0 "$?"
check_not "через ссылку каталога ничего не легло" test -e "$ROOT/victim/env"
check "предупреждение про ссылку каталога" grep -q 'символическая ссылка' "$ROOT/out"
check "служба всё равно стартует" started alice

echo "== configure: после install — restart; HTTPS и порт в объявлении =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
ht_hook configure CREAM_REASON=install SELKIES_PORT=8443 SELKIES_ENABLE_HTTPS=true; eq "configure — 0" 0 "$?"
check "restart --no-block selkies@alice" ht_called '^systemctl restart --no-block selkies@alice\.service'
check "URI https с портом" grep -qx 'URI=https://127.0.0.1:8443' "$DECL"

echo "== configure: SELKIES_ALLOW_NO_AUTH=1 — старт с предупреждением =="
sk_root
ht_hook configure CREAM_REASON=boot SELKIES_ALLOW_NO_AUTH=1; eq "configure — 0" 0 "$?"
check "стартует" started alice
check "предупреждение при каждом configure" grep -q 'SELKIES_ALLOW_NO_AUTH=1' "$ROOT/out"
for a in ::1 localhost 127.0.0.1; do
    ht_hook configure CREAM_REASON=boot SELKIES_ALLOW_NO_AUTH=1 "SELKIES_ADDR=$a"; eq "без пароля на петле $a — 0" 0 "$?"
done

echo "== configure: без пароля — только на петле (решение владельца 2026-11-12) =="
# no_auth_refused <what> <pairs…>: no password, SELKIES_ALLOW_NO_AUTH=1 and a
# listener beyond the loopback: 78, the instance stopped, no declaration.
no_auth_refused() {
    local what="$1"; shift
    sk_root
    printf '%s\n' 'selkies@alice.service loaded active running Selkies' > "$FAKE/units"
    mkdir -p "$APPS"; echo 'NAME=selkies' > "$DECL"
    ht_hook configure CREAM_REASON=boot SELKIES_ALLOW_NO_AUTH=1 "$@"; eq "$what: configure — 78" 78 "$?"
    check_not "$what: не стартует" started alice
    check "$what: запущенный экземпляр гасится" ht_called '^systemctl stop --no-block selkies@alice\.service'
    check_not "$what: объявление снято" test -e "$DECL"
    check "$what: сказано, что без пароля — только петля" grep -q 'только на петле' "$ROOT/out"
    : > "$FAKE/calls"
    ht_hook apply CREAM_CHANGED_KEYS=SELKIES_ADDR SELKIES_ALLOW_NO_AUTH=1 "$@"; eq "$what: apply — 78" 78 "$?"
    check_not "$what: apply не перезапускает" started alice
}
no_auth_refused "0.0.0.0" SELKIES_ADDR=0.0.0.0
no_auth_refused "192.0.2.10" SELKIES_ADDR=192.0.2.10
no_auth_refused "SELKIES_PUBLIC=true" SELKIES_PUBLIC=true
no_auth_refused "SELKIES_PUBLIC=1" SELKIES_PUBLIC=1
no_auth_refused "Computer-Use на 0.0.0.0" SELKIES_COMPUTER_USE_BIND=9500,0.0.0.0:9501
no_auth_refused "::" SELKIES_ADDR=::
# WebRTC binds its ICE sockets (UDP, mux ports, mDNS) on every host address.
no_auth_refused "SELKIES_MODE=webrtc" SELKIES_MODE=webrtc
no_auth_refused "SELKIES_ENABLE_DUAL_MODE=true" SELKIES_ENABLE_DUAL_MODE=true
# Owner's ruling 2026-11-12: Computer-Use only explicitly and only with a password.
no_auth_refused "Computer-Use на петле без пароля" SELKIES_COMPUTER_USE_BIND=9500
no_auth_refused "Computer-Use 127.0.0.1 без пароля" SELKIES_COMPUTER_USE_BIND=127.0.0.1:9500

# Commas only: no address — not written to the effective values of the unit.
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
ht_hook configure CREAM_REASON=boot "SELKIES_COMPUTER_USE_BIND=,,"; eq "Computer-Use из запятых — 0" 0 "$?"
check "действующие значения записаны" test -s "$ROOT/var/lib/cream/ext/selkies/env"
check_not "Computer-Use из запятых не попал в действующие значения" grep -q '^SELKIES_COMPUTER_USE_BIND=' "$ROOT/var/lib/cream/ext/selkies/env"

echo "== configure: Computer-Use pixelflux без пароля всегда — только на петле =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
printf '%s\n' 'selkies@alice.service loaded active running Selkies' > "$FAKE/units"
ht_hook configure CREAM_REASON=boot SELKIES_COMPUTER_USE_BIND=0.0.0.0:9500
eq "с паролем, Computer-Use на 0.0.0.0 — 78" 78 "$?"
check_not "не стартует" started alice
check "экземпляр гасится" ht_called '^systemctl stop --no-block selkies@alice\.service'
check "сказано про петлю" grep -q 'только на петле' "$ROOT/out"
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
ht_hook configure CREAM_REASON=boot SELKIES_MODE=webrtc SELKIES_ADDR=0.0.0.0 SELKIES_COMPUTER_USE_BIND=9500
eq "с паролем: webrtc, 0.0.0.0, Computer-Use на петле — 0" 0 "$?"
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
ht_hook configure CREAM_REASON=boot SELKIES_PUBLIC=true; eq "с паролем, PUBLIC=true — 0" 0 "$?"
check "с паролем, PUBLIC=true — стартует" started alice
check "с паролем, PUBLIC=true без HTTPS — предупреждение про открытый текст" grep -q 'открытым текстом' "$ROOT/out"
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
ht_hook configure CREAM_REASON=boot SELKIES_COMPUTER_USE_BIND=9500,127.0.0.1:9501,localhost:9502
eq "с паролем, Computer-Use на петле — 0" 0 "$?"
check "с паролем, Computer-Use на петле — стартует" started alice
# SELKIES_PUBLIC as Selkies reads it: on only by true/1 (before "|").
for pub in false yes on; do
    sk_root
    ht_hook configure CREAM_REASON=boot SELKIES_ALLOW_NO_AUTH=1 "SELKIES_PUBLIC=$pub"
    eq "без пароля, PUBLIC=$pub (для Selkies выключен) — 0" 0 "$?"
    check "без пароля, PUBLIC=$pub — стартует" started alice
done
no_auth_refused "SELKIES_PUBLIC=TRUE|locked" "SELKIES_PUBLIC=TRUE|locked"
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
ht_hook configure CREAM_REASON=boot SELKIES_PUBLIC=yes
check_not "с паролем, PUBLIC=yes — не все интерфейсы, предупреждения нет" grep -q 'открытым текстом' "$ROOT/out"
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
ht_hook configure CREAM_REASON=boot SELKIES_ALLOW_NO_AUTH=1 SELKIES_ADDR=0.0.0.0; eq "с паролем не на петле — 0" 0 "$?"
check "с паролем не на петле — стартует" started alice

echo "== configure: адрес не петли =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
ht_hook configure CREAM_REASON=boot SELKIES_ADDR=0.0.0.0; eq "0.0.0.0 — 0" 0 "$?"
check "0.0.0.0: объявление на петле" grep -qx 'URI=http://127.0.0.1:8080' "$DECL"
check "пароль по http в сеть — предупреждение" grep -q 'SELKIES_ENABLE_HTTPS' "$ROOT/out"
ht_hook configure CREAM_REASON=boot SELKIES_ADDR=192.0.2.10; eq "192.0.2.10 — 0" 0 "$?"
check_not "адрес без петли — объявления нет" test -e "$DECL"
ht_hook configure CREAM_REASON=boot SELKIES_ADDR=::1; eq "::1 — 0" 0 "$?"
check "::1 — объявление на [::1]" grep -qxF 'URI=http://[::1]:8080' "$DECL"

echo "== configure: значения проверяются до записи =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
ht_hook configure CREAM_REASON=boot 'SELKIES_PORT=8080"x'; check_not "порт с кавычкой — сбой" test "$?" -eq 0
check_not "объявления нет" test -e "$DECL"
check_not "не стартует" started alice
ht_hook configure CREAM_REASON=boot 'SELKIES_ADDR=127.0.0.1$x'; check_not "адрес с \$ — сбой" test "$?" -eq 0
ht_hook configure CREAM_REASON=boot 'SELKIES_ENABLE_HTTPS=yes'; check_not "HTTPS не true/false — сбой" test "$?" -eq 0

echo "== configure: объявление не идёт по ссылкам =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
mkdir -p "$APPS" "$ROOT/victim"; echo keep > "$ROOT/victim/file"
ln -s "$ROOT/victim/file" "$DECL"
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
eq "цель ссылки не тронута" keep "$(cat "$ROOT/victim/file")"
check "объявление — обычный файл" test -f "$DECL" -a ! -L "$DECL"
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
mkdir -p "$ROOT/etc/cream/teleport" "$ROOT/victim"; ln -s "$ROOT/victim" "$APPS"
ht_hook configure CREAM_REASON=boot; eq "apps.d — ссылка: configure 0" 0 "$?"
check_not "в цель ссылки каталога ничего не легло" test -e "$ROOT/victim/selkies.conf"
check "предупреждение про ссылку" grep -q 'ссылк' "$ROOT/out"
check "служба всё равно стартует" started alice
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
mkdir -p "$ROOT/etc/cream" "$ROOT/victim"; ln -s "$ROOT/victim" "$ROOT/etc/cream/teleport"
ht_hook configure CREAM_REASON=boot; eq "teleport — ссылка: configure 0" 0 "$?"
check_not "через ссылку /etc/cream/teleport ничего не создано" test -e "$ROOT/victim/apps.d"

echo "== configure: без менеджера входа — предупреждение и 0 (Р11) =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"; rm -f "$FAKE/active-display-manager"
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
check "предупреждение про менеджер входа" grep -q 'менеджер входа' "$ROOT/out"
check_not "не стартует" started alice
check_not "пользователя не ждёт" ht_called '^sleep'

echo "== configure: без пользователя — предупреждение и 0 =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"; rm -f "$FAKE/user"
ht_hook configure CREAM_REASON=boot; eq "загрузка — 0" 0 "$?"
check "на загрузке ждёт пользователя" ht_called '^sleep'
check "предупреждение про пользователя" grep -q 'пользовател' "$ROOT/out"
check_not "не стартует" ht_called '^systemctl (start|restart) --no-block selkies@'
: > "$FAKE/calls"
ht_hook configure CREAM_REASON=install; eq "install — 0" 0 "$?"
check_not "после install не ждёт" ht_called '^sleep'
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"; echo root > "$FAKE/user"
ht_hook configure CREAM_REASON=boot; eq "root — 0" 0 "$?"
check_not "от root не стартует" started root
echo 'bad;name' > "$FAKE/user"
ht_hook configure CREAM_REASON=boot; eq "кривое имя — 0" 0 "$?"
check_not "кривое имя не идёт в имя юнита" ht_called 'selkies@bad'

echo "== configure: SELKIES_USER — этот пользователь, без cloud-user =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
ht_hook configure CREAM_REASON=boot SELKIES_USER=carol; eq "SELKIES_USER=carol — 0" 0 "$?"
check "стартует selkies@carol" started carol
check_not "selkies@alice не стартует" started alice
check_not "cloud-user не ждали" ht_called '^sleep'

echo "== apply: SELKIES_USER снят, пользователь cloud-init не годится — прежний экземпляр гасится =="
for cu in none root 'bad;name' gdm; do
    sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
    if [[ "$cu" == none ]]; then rm -f "$FAKE/user"; else echo "$cu" > "$FAKE/user"; fi
    printf '%s\n' 'selkies@carol.service loaded active running Selkies' > "$FAKE/units"
    ht_hook apply CREAM_CHANGED_KEYS=SELKIES_USER SELKIES_USER=; eq "cloud-init «$cu»: apply — 0" 0 "$?"
    check "cloud-init «$cu»: selkies@carol гасится" ht_called '^systemctl stop --no-block selkies@carol\.service'
    check_not "cloud-init «$cu»: ничего не стартует" ht_called '^systemctl (start|restart) --no-block selkies@'
done

echo "== configure/apply: SELKIES_USER — системная учётка, root, nobody, нет в passwd — 78 (Р3) =="
for u in gdm root nobody ghost; do
    sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
    printf '%s\n' 'selkies@alice.service loaded active running Selkies' > "$FAKE/units"
    ht_hook configure CREAM_REASON=boot "SELKIES_USER=$u"; eq "configure SELKIES_USER=$u — 78" 78 "$?"
    check_not "$u: экземпляр не стартует" ht_called '^systemctl (start|restart) --no-block selkies@'
    check "$u: прежний экземпляр гасится" ht_called '^systemctl stop --no-block selkies@alice\.service'
    check "$u: причина в журнале (uid 1000..65533)" grep -q '1000' "$ROOT/out"
    check_not "$u: объявление не пишется" test -e "$DECL"
    : > "$FAKE/calls"
    ht_hook apply CREAM_CHANGED_KEYS=SELKIES_USER "SELKIES_USER=$u"; eq "apply SELKIES_USER=$u — 78" 78 "$?"
    check_not "$u: apply не перезапускает" ht_called '^systemctl (start|restart) --no-block selkies@'
done

echo "== configure/apply: нет Xorg или менеджера входа — 1 (Р2); DM не активен — 0 (Р11) =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
rm -f "$ROOT/usr/lib/xorg/Xorg"
printf '%s\n' 'selkies@alice.service loaded active running Selkies' > "$FAKE/units"
ht_hook configure CREAM_REASON=boot; eq "нет Xorg: configure — 1" 1 "$?"
check "текст: existing-desktop" grep -q 'нет X-сервера / менеджера входа: поставьте стол или `existing-desktop`' "$ROOT/out"
check_not "не стартует" started alice
check "прежний экземпляр гасится" ht_called '^systemctl stop --no-block selkies@alice\.service'
ht_hook apply CREAM_CHANGED_KEYS=SELKIES_PORT; eq "нет Xorg: apply — 1" 1 "$?"
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
rm -f "$ROOT/etc/systemd/system/display-manager.service"
ht_hook configure CREAM_REASON=boot; eq "нет display-manager.service: configure — 1" 1 "$?"
check_not "не стартует" started alice
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
rm -f "$ROOT/lib/systemd/system/lightdm.service"
ht_hook configure CREAM_REASON=boot; eq "display-manager.service висит: configure — 1" 1 "$?"
check "висячая ссылка: текст existing-desktop" grep -qF 'поставьте стол или `existing-desktop`' "$ROOT/out"
check_not "висячая ссылка: не стартует" started alice
ht_hook apply CREAM_CHANGED_KEYS=SELKIES_PORT; eq "display-manager.service висит: apply — 1" 1 "$?"
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
mask_dm
ht_hook configure CREAM_REASON=boot; eq "display-manager.service замаскирован: configure — 1" 1 "$?"
check_not "замаскирован: не стартует" started alice
ht_hook apply CREAM_CHANGED_KEYS=SELKIES_PORT; eq "display-manager.service замаскирован: apply — 1" 1 "$?"
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
rm -f "$ROOT/usr/lib/xorg/Xorg" "$ROOT/etc/systemd/system/display-manager.service"
HT_PHASE=build ht_hook configure CREAM_REASON=install; eq "сборка образа: configure без Xorg и DM — 0" 0 "$?"
check_not "сборка: текста про existing-desktop нет" grep -q 'existing-desktop' "$ROOT/out"

echo "== configure: SELKIES_DISPLAY проверяется =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
ht_hook configure CREAM_REASON=boot SELKIES_DISPLAY=:1; eq "SELKIES_DISPLAY=:1 — 0" 0 "$?"
check "SELKIES_DISPLAY=:1 в действующих значениях" grep -qx 'SELKIES_DISPLAY=:1' "$ROOT/var/lib/cream/ext/selkies/env"
ht_hook configure CREAM_REASON=boot 'SELKIES_DISPLAY=:0;x'; eq "SELKIES_DISPLAY с мусором — 1" 1 "$?"
ht_hook configure CREAM_REASON=boot 'SELKIES_USER=-x'; eq "SELKIES_USER не имя — 78" 78 "$?"
ESC="$(printf '\033')"
ht_hook configure CREAM_REASON=boot "SELKIES_USER=Bad${ESC}[2J"; eq "SELKIES_USER с управляющим символом — 78" 78 "$?"
check_not "управляющий символ не попадает в журнал как есть" grep -qF "$ESC" "$ROOT/out"
check "имя в журнале экранировано (%q)" grep -qF "SELKIES_USER=\$'Bad\E[2J'" "$ROOT/out"

echo "== configure: диагноз seat0 одной строкой (xs_seat0_active) =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
seat0 3 bob x11 :0
ht_hook configure CREAM_REASON=boot; eq "на экране bob — 0" 0 "$?"
check "диагноз: сеанс bob, Selkies ждёт alice" grep -q 'на seat0 сеанс bob (x11), Selkies ждёт alice' "$ROOT/out"
check "подсказка: SELKIES_USER=bob" grep -q 'SELKIES_USER=bob' "$ROOT/out"
check "всё равно стартует (ждёт сеанс alice)" started alice
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
seat0 c1 gdm x11 :0 greeter
ht_hook configure CREAM_REASON=boot; eq "на экране вход — 0" 0 "$?"
check "диагноз: экран входа" grep -q 'экран входа' "$ROOT/out"
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
seat0 2 alice x11 :1
ht_hook configure CREAM_REASON=boot; eq "на экране alice — 0" 0 "$?"
check "диагноз: сеанс alice (x11)" grep -q 'на seat0 сеанс alice (x11)' "$ROOT/out"
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
ht_hook configure CREAM_REASON=boot; eq "logind без сеанса — 0" 0 "$?"
check "диагноз: активного сеанса нет" grep -q 'на seat0 нет активного сеанса' "$ROOT/out"

echo "== configure: прежний экземпляр другого пользователя гасится =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
printf '%s\n' 'selkies@bob.service loaded active running Selkies' 'selkies@alice.service loaded inactive dead Selkies' > "$FAKE/units"
ht_fake systemctl '
case "$1" in
    is-active) [[ -e "$FAKE/active-display-manager" ]] && exit 0; exit 3 ;;
    list-units) cat "$FAKE/units" ;;
esac
exit 0'
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
check "selkies@bob — stop --no-block" ht_called '^systemctl stop --no-block selkies@bob\.service'
check_not "selkies@alice не гасится" ht_called '^systemctl stop --no-block selkies@alice'
check "selkies@alice стартует" started alice

echo "== apply: перезапуск и объявление; без аутентификации — останов =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
ht_hook apply CREAM_CHANGED_KEYS=SELKIES_PORT SELKIES_PORT=9090; eq "apply — 0" 0 "$?"
check "restart --no-block selkies@alice" ht_called '^systemctl restart --no-block selkies@alice\.service'
check "порт доехал до объявления" grep -qx 'URI=http://127.0.0.1:9090' "$DECL"
check "порт доехал до действующих значений" grep -qx 'SELKIES_PORT=9090' "$ROOT/var/lib/cream/ext/selkies/env"
check_not "apply не ждёт" ht_called '^sleep'
check_not "блокирующих systemctl нет" blocking_systemctl
check_not "секреты не в выводе" leaked "$ROOT/out" "$FAKE"
sk_root
printf '%s\n' 'selkies@alice.service loaded active running Selkies' > "$FAKE/units"
ht_hook apply CREAM_CHANGED_KEYS=SELKIES_BASIC_AUTH_PASSWORD; eq "пароль снят: apply — 0" 0 "$?"
check "экземпляр гасится" ht_called '^systemctl stop --no-block selkies@alice\.service'
check_not "не перезапускается" started alice
check "предупреждение" grep -q 'SELKIES_ALLOW_NO_AUTH' "$ROOT/out"

echo "== remove: службы, объявление, AppImage =="
sk_root; fake_appimage; ln -s "$ROOT/opt/selkies/$VER" "$ROOT/opt/selkies/current"
mkdir -p "$APPS"; echo 'NAME=selkies' > "$DECL"; echo 'NAME=other' > "$APPS/other.conf"
echo 'SELKIES_ENABLE_RESIZE=false' > "$ROOT/var/lib/cream/ext/selkies/env"
printf '%s\n' 'selkies@alice.service loaded active running Selkies' > "$FAKE/units"
ht_hook remove; eq "remove — 0" 0 "$?"
check "экземпляры остановлены" ht_called '^systemctl stop .*selkies@alice\.service'
check_not "объявление снято" test -e "$DECL"
check "чужое объявление на месте" test -f "$APPS/other.conf"
check_not "AppImage удалён" test -e "$ROOT/opt/selkies/$VER"
check_not "ссылка current удалена" test -L "$ROOT/opt/selkies/current"
check_not "файл действующих значений снят" test -e "$ROOT/var/lib/cream/ext/selkies/env"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
sk_root; mkdir -p "$ROOT/victim/$VER"; echo keep > "$ROOT/victim/$VER/f"
mkdir -p "$ROOT/opt"; ln -s "$ROOT/victim" "$ROOT/opt/selkies"
ht_hook remove; eq "/opt/selkies — ссылка: remove 0" 0 "$?"
check "по ссылке не удаляет" test -f "$ROOT/victim/$VER/f"

echo "== run-selkies.sh: fail-closed и секреты =="
# run_wrapper <env pairs…>: the wrapper as systemd starts it for alice (User=%i):
# config and secrets in the environment, nothing else.
# WR_USER — the instance (selkies@<user>), alice by default.
run_wrapper() {
    (
        cd / || exit 125
        exec env -i "PATH=$ROOT/bin:$HT_PATH_TAIL" LANG=C.UTF-8 "CREAM_ROOT=$ROOT" \
            SELKIES_AUDIO_ENABLED=false "$@" /bin/bash "$EXT/files/run-selkies.sh" "${WR_USER:-alice}" < /dev/null
    ) > "$ROOT/out" 2>&1
}
# wr_root: alice is logged in on seat0, an X11 session on :0 (logind Display);
# xdpyinfo opens every display; sleep is counted, and the 2000th kills the
# wrapper (a test that would wait for ever fails instead of hanging).
wr_root() {
    sk_root; fake_appimage; ln -s "$ROOT/opt/selkies/$VER" "$ROOT/opt/selkies/current"
    : > "$ROOT/home/alice/.Xauthority"
    for c in xdpyinfo pactl pgrep; do
        ht_fake "$c" "env > \"\$FAKE/$c.env\"; [[ $c == pgrep ]] && exit 1; exit 0"
    done
    seat0 2 alice x11 :0
    ht_fake sleep 'n=$(( $(cat "$FAKE/sleeps" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/sleeps"
(( n < 2000 )) || kill -TERM "$PPID"
exit 0'
}
wr_root
run_wrapper; eq "без пароля и ключа — 78" 78 "$?"
check_not "selkies не запущен" test -e "$FAKE/selkies.env"
check "сказано, как открыть" grep -q 'SELKIES_ALLOW_NO_AUTH' "$ROOT/out"
wr_root
run_wrapper "SELKIES_BASIC_AUTH_VIEWONLY_PASSWORD=$VO"; eq "только пароль просмотра — 78" 78 "$?"
check_not "selkies не запущен" test -e "$FAKE/selkies.env"
wr_root
run_wrapper SELKIES_ENABLE_BASIC_AUTH=false; eq "SELKIES_ENABLE_BASIC_AUTH=false без пароля — 78" 78 "$?"

wr_root
run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW" "SELKIES_MASTER_TOKEN=$TOKEN" SELKIES_ENABLE_BASIC_AUTH=false
check "selkies запущен" test -e "$FAKE/selkies.env"
check "basic auth включён принудительно" grep -qx 'SELKIES_ENABLE_BASIC_AUTH=true' "$FAKE/selkies.env"
check "пароль дошёл до selkies через окружение" grep -qxF "SELKIES_BASIC_AUTH_PASSWORD=$PW" "$FAKE/selkies.env"
check "токен дошёл до selkies" grep -qxF "SELKIES_MASTER_TOKEN=$TOKEN" "$FAKE/selkies.env"
eq "argv selkies пуст" "" "$(cat "$FAKE/selkies.args")"
check_not "секретов нет у xdpyinfo, pactl, loginctl, pgrep" leaked "$FAKE"/{xdpyinfo,pactl,loginctl,pgrep}.env
check_not "секретов нет в argv вызовов" leaked "$FAKE/calls" "$FAKE"/*.argv
check_not "секретов нет в выводе обёртки" leaked "$ROOT/out"

wr_root
run_wrapper SELKIES_ALLOW_NO_AUTH=1
check "SELKIES_ALLOW_NO_AUTH=1 — запущен" test -e "$FAKE/selkies.env"
check "basic auth выключен явно" grep -qx 'SELKIES_ENABLE_BASIC_AUTH=false' "$FAKE/selkies.env"
check "предупреждение при старте" grep -q 'SELKIES_ALLOW_NO_AUTH=1' "$ROOT/out"
# Without a password only the loopback (owner's ruling 2026-11-12).
for pair in SELKIES_ADDR=0.0.0.0 SELKIES_ADDR=192.0.2.10 SELKIES_ADDR=:: SELKIES_PUBLIC=true \
    SELKIES_COMPUTER_USE_BIND=0.0.0.0:9500 SELKIES_MODE=webrtc SELKIES_ENABLE_DUAL_MODE=true; do
    wr_root
    run_wrapper SELKIES_ALLOW_NO_AUTH=1 "$pair"; eq "без пароля, $pair — 78" 78 "$?"
    check_not "без пароля, $pair — selkies не запущен" test -e "$FAKE/selkies.env"
    check "без пароля, $pair — сказано про петлю" grep -q 'только на петле' "$ROOT/out"
done
wr_root
run_wrapper SELKIES_ALLOW_NO_AUTH=1 SELKIES_ADDR=::1
check "без пароля на ::1 — запущен" test -e "$FAKE/selkies.env"
check_not "по умолчанию Computer-Use выключен" grep -q '^SELKIES_COMPUTER_USE_BIND=' "$FAKE/selkies.env"
check "Selkies получил SELKIES_MODE=websockets" grep -qx 'SELKIES_MODE=websockets' "$FAKE/selkies.env"
# Owner's ruling 2026-11-12: Computer-Use only explicitly and only with a password.
for cu in 9500 127.0.0.1:9500; do
    wr_root
    run_wrapper SELKIES_ALLOW_NO_AUTH=1 "SELKIES_COMPUTER_USE_BIND=$cu"; eq "без пароля, Computer-Use $cu — 78" 78 "$?"
    check_not "без пароля, Computer-Use $cu — selkies не запущен" test -e "$FAKE/selkies.env"
    check "без пароля, Computer-Use $cu — сказано, что нужен пароль" grep -q 'только с паролем' "$ROOT/out"
done
wr_root
run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW" SELKIES_COMPUTER_USE_BIND=9500
check "с паролем, Computer-Use 9500 — запущен" test -e "$FAKE/selkies.env"
check "с паролем — Computer-Use дошёл до Selkies" grep -qx 'SELKIES_COMPUTER_USE_BIND=9500' "$FAKE/selkies.env"
# A list of commas only names no address: Computer-Use is off, as if unset — the
# variable does not reach Selkies (it starts its server for any non-empty value).
for cu in "," ", ," " , "; do
    wr_root
    run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW" "SELKIES_COMPUTER_USE_BIND=$cu"
    check "с паролем, Computer-Use '$cu' — запущен" test -e "$FAKE/selkies.env"
    check_not "с паролем, Computer-Use '$cu' — Selkies не получил ключ" grep -q '^SELKIES_COMPUTER_USE_BIND=' "$FAKE/selkies.env"
    wr_root
    run_wrapper SELKIES_ALLOW_NO_AUTH=1 "SELKIES_COMPUTER_USE_BIND=$cu"
    check "без пароля, Computer-Use '$cu' — запущен, как выключенный" test -e "$FAKE/selkies.env"
    check_not "без пароля, Computer-Use '$cu' — Selkies не получил ключ" grep -q '^SELKIES_COMPUTER_USE_BIND=' "$FAKE/selkies.env"
done
# SELKIES_PUBLIC as Selkies reads it (true/1 before "|"); handed on normalized.
for pub in yes on; do
    wr_root
    run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW" "SELKIES_PUBLIC=$pub"
    check "с паролем, PUBLIC=$pub — Selkies получил SELKIES_PUBLIC=false" grep -qx 'SELKIES_PUBLIC=false' "$FAKE/selkies.env"
    check "с паролем, PUBLIC=$pub — адрес остаётся" grep -qx 'SELKIES_ADDR=127.0.0.1' "$FAKE/selkies.env"
    check_not "с паролем, PUBLIC=$pub — нет ложного «все интерфейсы»" grep -q 'все интерфейсы' "$ROOT/out"
    wr_root
    run_wrapper SELKIES_ALLOW_NO_AUTH=1 "SELKIES_PUBLIC=$pub"
    check "без пароля, PUBLIC=$pub (для Selkies выключен) — запущен" test -e "$FAKE/selkies.env"
done
wr_root
run_wrapper SELKIES_ALLOW_NO_AUTH=1 "SELKIES_PUBLIC=True|locked"; eq "без пароля, PUBLIC=True|locked — 78" 78 "$?"
wr_root
run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW" SELKIES_ADDR=0.0.0.0
check "с паролем на 0.0.0.0 — запущен" test -e "$FAKE/selkies.env"
# The address checked is the address Selkies gets: absent or empty — 127.0.0.1.
for pair in SELKIES_ALLOW_NO_AUTH=1 "SELKIES_BASIC_AUTH_PASSWORD=$PW"; do
    for addr in absent SELKIES_ADDR=; do
        wr_root
        if [[ "$addr" == absent ]]; then run_wrapper "$pair"; else run_wrapper "$pair" "$addr"; fi
        check "${pair%%=*}, адрес $addr — запущен" test -e "$FAKE/selkies.env"
        check "${pair%%=*}, адрес $addr — Selkies получил SELKIES_ADDR=127.0.0.1" \
            grep -qx 'SELKIES_ADDR=127.0.0.1' "$FAKE/selkies.env"
    done
done
wr_root
run_wrapper SELKIES_ALLOW_NO_AUTH=1
check "без пароля, без ключа — Selkies получил SELKIES_ENABLE_DUAL_MODE=false" \
    grep -qx 'SELKIES_ENABLE_DUAL_MODE=false' "$FAKE/selkies.env"
# pixelflux starts its Computer-Use server (no authentication of its own) at
# import from PIXELFLUX_CU: only SELKIES_COMPUTER_USE_BIND, checked, may start it.
wr_root
run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW" PIXELFLUX_CU=0.0.0.0:9500
check "PIXELFLUX_CU — запущен" test -e "$FAKE/selkies.env"
check_not "PIXELFLUX_CU не доходит до Selkies" grep -q '^PIXELFLUX_CU=' "$FAKE/selkies.env"
check "PIXELFLUX_CU — предупреждение" grep -q 'PIXELFLUX_CU' "$ROOT/out"
wr_root
run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW" SELKIES_COMPUTER_USE_BIND=0.0.0.0:9500
eq "с паролем, Computer-Use на 0.0.0.0 — 78" 78 "$?"
check_not "с паролем, Computer-Use на 0.0.0.0 — selkies не запущен" test -e "$FAKE/selkies.env"
# Selkies refuses --public together with --addr: with a password and
# SELKIES_PUBLIC on the wrapper passes no SELKIES_ADDR (the env file has one).
for pub in true 1; do
    for addr in absent SELKIES_ADDR=127.0.0.1; do
        wr_root
        if [[ "$addr" == absent ]]; then
            run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW" "SELKIES_PUBLIC=$pub"
        else
            run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW" "SELKIES_PUBLIC=$pub" "$addr"
        fi
        check "с паролем, PUBLIC=$pub, адрес $addr — запущен" test -e "$FAKE/selkies.env"
        check "с паролем, PUBLIC=$pub — Selkies получил SELKIES_PUBLIC=true" grep -qx "SELKIES_PUBLIC=true" "$FAKE/selkies.env"
        check_not "с паролем, PUBLIC=$pub, адрес $addr — без SELKIES_ADDR" grep -q '^SELKIES_ADDR=' "$FAKE/selkies.env"
        eq "с паролем, PUBLIC=$pub — argv пуст (без --addr)" "" "$(cat "$FAKE/selkies.args" 2>/dev/null)"
        check "с паролем, PUBLIC=$pub без HTTPS — предупреждение про открытый текст" grep -q 'открытым текстом' "$ROOT/out"
    done
done
wr_root
run_wrapper SELKIES_ALLOW_NO_AUTH=1 SELKIES_PUBLIC=true SELKIES_ADDR=127.0.0.1; eq "без пароля, PUBLIC=true из env — 78" 78 "$?"
check_not "без пароля, PUBLIC=true — selkies не запущен" test -e "$FAKE/selkies.env"

wr_root
run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW" SELKIES_ENABLE_HTTPS=true
d="$ROOT/home/alice/.local/state/selkies"
eq "каталог TLS 0700" 700 "$(stat -c %a "$d")"
check "сертификат — в состоянии пользователя" grep -qxF "SELKIES_HTTPS_CERT=$d/selkies.pem" "$FAKE/selkies.env"

echo "== run-selkies.sh: SELKIES_ENABLE_RESIZE=false и без файла действующих значений =="
wr_root
run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW"
check "selkies запущен" test -e "$FAKE/selkies.env"
check "резерв обёртки: SELKIES_ENABLE_RESIZE=false" grep -qx 'SELKIES_ENABLE_RESIZE=false' "$FAKE/selkies.env"
wr_root
run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW" SELKIES_ENABLE_RESIZE=
check "пусто — тоже false (пусто у Selkies — его true)" grep -qx 'SELKIES_ENABLE_RESIZE=false' "$FAKE/selkies.env"
wr_root
run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW" SELKIES_ENABLE_RESIZE=true
check "явный true остаётся" grep -qx 'SELKIES_ENABLE_RESIZE=true' "$FAKE/selkies.env"

echo "== юнит → обёртка → Selkies: умолчания манифеста доходят до Selkies (Orin 2026-11-12) =="
# unit_env: KEY=VALUE lines systemd gives the wrapper — the EnvironmentFile
# files of the unit in their order under $ROOT (a later one overrides: env
# applies the pairs in order); "-" — an absent file is skipped, without it
# the unit would not start (UNIT-FAILED).
unit_env() {
    local f opt
    while IFS= read -r f; do
        opt=0; [[ "$f" == -* ]] && { opt=1; f="${f#-}"; }
        if [[ ! -f "$ROOT$f" ]]; then (( opt )) || echo UNIT-FAILED; continue; fi
        grep -E '^[A-Z][A-Z0-9_]*=' "$ROOT$f"
    done < <(sed -n 's/^EnvironmentFile=//p' "$UNIT")
}
wr_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
mapfile -t uenv < <(unit_env)
check_not "только пароль, config нет — юнит стартует" grep -qx UNIT-FAILED <(printf '%s\n' "${uenv[@]}")
run_wrapper "${uenv[@]}" SELKIES_AUDIO_ENABLED=false
check "selkies запущен" test -e "$FAKE/selkies.env"
check "у Selkies SELKIES_ENABLE_RESIZE=false" grep -qx 'SELKIES_ENABLE_RESIZE=false' "$FAKE/selkies.env"
check "у Selkies SELKIES_FRAMERATE=30,8-60" grep -qx 'SELKIES_FRAMERATE=30,8-60' "$FAKE/selkies.env"
check "у Selkies SELKIES_ENABLE_DUAL_MODE=false" grep -qx 'SELKIES_ENABLE_DUAL_MODE=false' "$FAKE/selkies.env"
check_not "SELKIES_ENCODER не задан — кодер выбирает клиент" grep -q '^SELKIES_ENCODER=' "$FAKE/selkies.env"
check "пароль дошёл" grep -qxF "SELKIES_BASIC_AUTH_PASSWORD=$PW" "$FAKE/selkies.env"
printf '%s\n' SELKIES_ENABLE_RESIZE=true > "$ROOT/etc/cream/selkies/config"
mapfile -t uenv < <(unit_env)
run_wrapper "${uenv[@]}" SELKIES_AUDIO_ENABLED=false
check "явный ключ config побеждает файл действующих значений" grep -qx 'SELKIES_ENABLE_RESIZE=true' "$FAKE/selkies.env"

echo "== run-selkies.sh: сессия на Wayland — 78, без цикла перезапусков =="
wr_root
seat0 2 alice wayland -
run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW"; eq "Wayland — 78 (EX_CONFIG)" 78 "$?"
check "сказано про Wayland" grep -q 'Wayland' "$ROOT/out"
check "сказано, как вернуть" grep -q 'systemctl restart selkies@alice' "$ROOT/out"
check "подсказка: gdm-xorg" grep -q 'gdm-xorg' "$ROOT/out"
check_not "selkies не запущен" test -e "$FAKE/selkies.env"
check_not "list-sessions не разбирается" ht_called '^loginctl list-sessions'
wr_root
seat0 2 alice wayland -
run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW" SELKIES_DISPLAY=:0; eq "Wayland при жёстком :0 — тоже 78" 78 "$?"
check_not "selkies не запущен" test -e "$FAKE/selkies.env"

echo "== run-selkies.sh: пользователь — uid 1000..65533, иначе 78 (Р3) =="
for u in gdm root nobody ghost -x; do
    wr_root
    WR_USER="$u" run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW"; eq "selkies@$u — 78" 78 "$?"
    check_not "$u: selkies не запущен" test -e "$FAKE/selkies.env"
    check_not "$u: дисплей не искали" ht_called '^(loginctl|xdpyinfo)'
done
wr_root
WR_USER='Bad\x41\e[2J' run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW"; eq "негодное имя — 78" 78 "$?"
check_not "негодное имя не попадает в журнал (echo -e)" grep -qE 'Bad|BadA' "$ROOT/out"
wr_root; seat0 2 carol x11 :0; mkdir -p "$ROOT/home/carol"; : > "$ROOT/home/carol/.Xauthority"
WR_USER=carol run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW"
check "selkies@carol (uid 1002) запущен" test -e "$FAKE/selkies.env"
check "USER=carol у Selkies" grep -qx 'USER=carol' "$FAKE/selkies.env"

echo "== run-selkies.sh: SELKIES_USER не доходит до Selkies (П8) =="
wr_root
run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW" SELKIES_USER=alice
check "selkies запущен" test -e "$FAKE/selkies.env"
check_not "SELKIES_USER нет в окружении Selkies" grep -q '^SELKIES_USER=' "$FAKE/selkies.env"

echo "== run-selkies.sh: SELKIES_DISPLAY — auto по logind, :N жёстко, без ключа — auto (Р4) =="
wr_root; seat0 2 alice x11 :1
run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW"
check "ключ не задан: дисплей из logind — :1" grep -qx 'DISPLAY=:1' "$FAKE/selkies.env"
check "Selkies получает найденный дисплей, не auto" grep -qx 'SELKIES_DISPLAY=:1' "$FAKE/selkies.env"
check "путь назван в журнале (logind)" grep -q 'logind' "$ROOT/out"
wr_root; seat0 2 alice x11 :1
run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW" SELKIES_DISPLAY=auto
check "auto: дисплей :1" grep -qx 'DISPLAY=:1' "$FAKE/selkies.env"
wr_root; seat0 2 alice x11 :1
run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW" SELKIES_DISPLAY=
check "пусто — как auto: :1" grep -qx 'DISPLAY=:1' "$FAKE/selkies.env"
wr_root; seat0 2 alice x11 :1
run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW" SELKIES_DISPLAY=:0
check "сохранённое :0 не меняется" grep -qx 'DISPLAY=:0' "$FAKE/selkies.env"
wr_root
run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW" 'SELKIES_DISPLAY=:0;x'; eq "негодный SELKIES_DISPLAY — 78" 78 "$?"
check_not "selkies не запущен" test -e "$FAKE/selkies.env"

echo "== run-selkies.sh: logind не отдаёт сеанс — запасной путь 2 (:0) =="
wr_root
rm -f "$FAKE"/user.* "$FAKE"/session.* "$FAKE/seat.seat0"
ht_fake stat 'echo "1000 600"'
ht_fake xhost 'echo "access control enabled, only authorized clients can connect"'
x0srv
run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW"
check "selkies запущен" test -e "$FAKE/selkies.env"
check "дисплей :0 (как 6.x)" grep -qx 'DISPLAY=:0' "$FAKE/selkies.env"
check "путь назван: запасной" grep -q 'запасной путь' "$ROOT/out"

echo "== run-selkies.sh: ожидание сеанса — диагноз раз в 5 минут =="
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
run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW"
check "selkies запущен, когда alice вошла" test -e "$FAKE/selkies.env"
eq "строка ожидания — на 0, 5 и 10 минуте" 3 "$(grep -c 'жду X-сессию' "$ROOT/out")"
check "диагноз: на seat0 bob" grep -q 'на seat0 сеанс bob (x11)' "$ROOT/out"
check "подсказка: SELKIES_USER=bob" grep -q 'SELKIES_USER=bob' "$ROOT/out"

echo "== имена layout 2 =="
# check-names: off
check_not "нет /opt/bisquite, bisquite-conf, BISQUITE_ в коде" \
    grep -rqE '/opt/bisquite|/etc/bisquite|bisquite-conf|BISQUITE_' "$EXT/hooks" "$EXT/files" "$EXT/extension.yaml"
# check-names: on

ht_done
