#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the code-server extension (cream/v1): manifest, unit, hooks install,
# configure, apply and remove, the user-side config writer and the start
# wrapper on a scratch root (CREAM_ROOT) the way cream and systemd run them.
# getent, systemctl, runuser, timeout, sleep, dpkg, dpkg-query, curl and apt-get
# are fakes; the cloud-user library is a stub; the Teleport declaration is read
# by the real parser of the teleport extension (files/teleport.sh render).
# root, systemd and the network are not needed.
#
# Security is the point: no start without a password unless
# CODE_SERVER_ALLOW_NO_AUTH=1 (fail-closed); the password never in argv, the
# output or the environment of helper processes; the user's config written as
# the user, 0600, never through a symlink; the declaration atomic, not through
# symlinks.
#
#   extensions/debian/code-server/tests/test-code-server.sh   code 0 — all checks passed
set -uo pipefail
umask 022
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
TELEPORT_EXT="$(cd "$EXT/../teleport" && pwd)"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

PW='Pw-Code-7f3a9c1e!x'
PW2='Pw-Code-2b8d4e6f'
VER=4.135.0
UID_ME="$(id -u)"

# cs_root: fresh root; user alice (home /home/alice, owned by whoever runs the
# test — runuser cannot drop privileges here) from the cloud-user library stub.
cs_root() {
    ht_root "$EXT"
    mkdir -p "$ROOT/home/alice" "$ROOT/home/bob"
    printf '%s\n' 'root:x:0:0::/root:/bin/bash' "alice:x:$UID_ME:$UID_ME::/home/alice:/bin/bash" \
        "bob:x:$UID_ME:$UID_ME::/home/bob:/bin/bash" "eve:x:1002:1002::/nonexistent:/bin/bash" > "$FAKE/passwd"
    echo alice > "$FAKE/user"
    : > "$FAKE/units"
    ht_fake getent '
f="$FAKE/$1"; [[ -f "$f" ]] || exit 2
[[ -z "${2-}" ]] && { cat "$f"; exit 0; }
grep -E "^${2}:" "$f" || exit 2'
    ht_fake systemctl '
case "$1" in
    list-units) cat "$FAKE/units" ;;
    is-active) exit 3 ;;
esac
exit 0'
    # runuser: logs the user, its env and whether fd 9 (the lock of cream in
    # these tests) and stdin reached it; runs the command as is.
    ht_fake runuser '
env > "$FAKE/runuser.env"
if [[ -e /proc/$$/fd/9 ]]; then echo open; else echo closed; fi > "$FAKE/runuser-lockfd"
[[ -e "$FAKE/runuser-fails" ]] && exit 1
[[ "$1" == -u && "$3" == -- ]] || exit 2
shift 3; exec "$@"'
    ht_fake timeout 'env > "$FAKE/timeout.env"; [[ "$1" == -k ]] && shift 2; shift; exec "$@"'
    ht_fake sleep
    LIB="$ROOT/opt/cream/ext/cloud-user/get_cloud_user.sh"
    mkdir -p "$(dirname "$LIB")"
    printf '#!/usr/bin/env bash\ncat %q 2>/dev/null || { echo "Error: no user" >&2; exit 1; }\n' "$FAKE/user" > "$LIB"
    chmod +x "$LIB"
    APPS="$ROOT/etc/cream/teleport/apps.d"
    DECL="$APPS/code-server.conf"
    CONF="$ROOT/home/alice/.config/code-server/config.yaml"
    # code-server installed: the binary exists.
    mkdir -p "$ROOT/usr/bin"
    printf '#!/usr/bin/env bash\nenv > %q\nprintf "%%s\\n" "$*" > %q\n' "$FAKE/code-server.env" "$FAKE/code-server.args" \
        > "$ROOT/usr/bin/code-server"
    chmod +x "$ROOT/usr/bin/code-server"
    printf '#!/bin/sh\nexit 0\n' > "$ROOT/usr/bin/openssl"; chmod +x "$ROOT/usr/bin/openssl"
}
mf() { python3 -c 'import sys,yaml; m=yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
started() { ht_called "^systemctl (start|restart) --no-block code-server@$1\\.service"; }
leaked() { grep -rqF -e "$PW" "$@" 2>/dev/null; }
blocking_systemctl() { grep -E '^systemctl (start|restart|stop|reload|enable --now|disable --now)' "$FAKE/calls" | grep -qv -- '--no-block'; }
# hook_fd9 <hook> <env…>: the hook with fd 9 open, as cream holds its lock.
hook_fd9() { exec 9> "$ROOT/tmp/lock"; ht_hook "$@"; local rc=$?; exec 9>&-; return "$rc"; }

# teleport_render: the real teleport.sh renders teleport.yaml from apps.d of
# this root; stderr in $ROOT/teleport.err.
teleport_render() {
    mkdir -p "$ROOT/etc/cream/teleport" "$ROOT/var/lib/cream/ext/teleport"
    printf '%s\n' TELEPORT_PROXY=proxy.example.com TELEPORT_NODENAME=node1 TELEPORT_OS_LOGINS=0 \
        > "$ROOT/etc/cream/teleport/config"
    (
        cd / || exit 125
        exec env -i "PATH=$HT_PATH_TAIL" LANG=C.UTF-8 "CREAM_ROOT=$ROOT" \
            "CREAM_ETC_DIR=$ROOT/etc/cream/teleport" "CREAM_CONFIG_FILE=$ROOT/etc/cream/teleport/config" \
            "CREAM_STATE_DIR=$ROOT/var/lib/cream/ext/teleport" "CREAM_EXT_DIR=$TELEPORT_EXT" \
            /bin/bash "$TELEPORT_EXT/files/teleport.sh" render < /dev/null
    ) > /dev/null 2> "$ROOT/teleport.err"
}

echo "== манифест и раскладка =="
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "name" code-server "$(mf 'm["name"]')"
eq "мажор +1 (Р1)" 5.0.0 "$(mf 'm["version"]')"
eq "cream 1.1.1 (стадия cloud-user, Р14)" ">=1.1.1" "$(mf 'm["cream"]')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "стадия cloud-user" cloud-user "$(mf 'm["hooks"]["configure"]["stage"]')"
eq "хуки" "apply configure install remove" "$(mf '" ".join(sorted(m["hooks"]))')"
eq "depends cloud-user" "cloud-user >=1.0.0 <2" "$(mf '" ".join(d["name"]+" "+d["version"] for d in m["depends"])')"
eq "provides" "web-ide" "$(mf '" ".join(m["provides"])')"
eq "arch" "amd64 arm64" "$(mf '" ".join(m["platform"]["arch"])')"
eq "секрет — только пароль, secret: file" "CODE_SERVER_PASSWORD" \
    "$(mf '" ".join(sorted(k for k, v in m["config"]["keys"].items() if v.get("secret") == "file"))')"
eq "CODE_SERVER_ALLOW_NO_AUTH — bool, 0" "bool 0" \
    "$(mf 'm["config"]["keys"]["CODE_SERVER_ALLOW_NO_AUTH"]["type"] + " " + m["config"]["keys"]["CODE_SERVER_ALLOW_NO_AUTH"]["default"]')"
eq "адрес по умолчанию — петля" 127.0.0.1 "$(mf 'm["config"]["keys"]["CODE_SERVER_BIND"]["default"]')"
eq "порт по умолчанию" 9001 "$(mf 'm["config"]["keys"]["CODE_SERVER_PORT"]["default"]')"
eq "версия — не ручка (пин по sha256)" False "$(mf '"CODE_SERVER_VERSION" in m["config"]["keys"]')"
eq "files: юнит" "files/code-server@.service /etc/systemd/system/code-server@.service 0644" \
    "$(mf '" ".join(f["src"]+" "+f["dst"]+" "+f["mode"] for f in m["files"])')"
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
    # The old "none" meant "no password": now it does not fit the type at all.
    if k == "CODE_SERVER_PASSWORD" and rx.match("none"):
        bad.append(f"{k}:'none'")
print(" ".join(bad))
PY
)"
eq "типы ключей: без \\n, кавычек, \$, \`, \\, пробела; none — не пароль" "" "$bad_types"
eq "пароль из live-test подходит под тип" True \
    "$(mf 'bool(__import__("re").fullmatch(m["config"]["keys"]["CODE_SERVER_PASSWORD"]["type"][3:], "live-CODE_SERVER_PASSWORD-0123456789abcdef"))')"
for f in hooks/install hooks/configure hooks/apply hooks/remove files/code-server.sh; do
    check "$f исполняемый" test -x "$EXT/$f"
done
for f in install.sh configure.sh configure-code-server.service knobs knobs.apply teleport-app.sh lib; do
    check_not "layout 2: $f не остался" test -e "$EXT/$f"
done
UNIT="$EXT/files/code-server@.service"
check "юнит: от имени пользователя" grep -qx 'User=%i' "$UNIT"
check "юнит: EnvironmentFile config (без секретов)" grep -qx 'EnvironmentFile=-/etc/cream/code-server/config' "$UNIT"
check_not "юнит: секреты в окружение не читаются" grep -q 'secrets' "$UNIT"
check "юнит: обёртка из дерева расширения" grep -qx 'ExecStart=/bin/bash /opt/cream/ext/code-server/files/code-server.sh start' "$UNIT"
check "юнит: отказ по аутентификации не перезапускается" grep -qx 'RestartPreventExitStatus=78' "$UNIT"
check_not "юнит: не включается сам (стартует configure)" grep -q '^WantedBy=' "$UNIT"

echo "== install: пакет закреплённой версии уже стоит =="
cs_root
ht_fake dpkg 'echo amd64'
ht_fake dpkg-query "echo installed $VER"
ht_fake apt-get
ht_hook install; eq "install — 0" 0 "$?"
check_not "сеть не нужна" ht_called '^curl'
check_not "apt-get не зовётся" ht_called '^apt-get'
check_not "install не трогает службы" ht_called '^systemctl'
check_not "install не пишет объявление (это configure)" test -e "$DECL"
rm -f "$ROOT/usr/bin/openssl"
ht_hook install; eq "без openssl — install 0" 0 "$?"
check "openssl доставляется (сертификат code-server)" ht_called '^apt-get .*install .*openssl'
check_not "сеть для .deb не нужна" ht_called '^curl'

echo "== install: .deb по sha256 =="
cs_root
ht_fake dpkg 'echo arm64'
ht_fake dpkg-query 'exit 1'
ht_fake apt-get
ht_fake curl 'while (( $# )); do [[ "$1" == -o ]] && { echo bogus > "$2"; }; shift; done; exit 0'
ht_hook install; check_not "sha256 не совпал — install не 0" test "$?" -eq 0
check "качался .deb arm64 закреплённой версии" ht_called "^curl .*/v$VER/code-server_${VER}_arm64\\.deb"
check_not "непроверенный .deb не ставится" ht_called '^apt-get .*install .*\.deb'
cs_root
ht_fake dpkg 'echo amd64'
ht_fake dpkg-query 'exit 1'
ht_fake apt-get 'printf "%s\n" "$*" >> "$FAKE/apt.log"; for a in "$@"; do [[ "$a" == *.deb ]] && cp "$a" "$FAKE/installed.deb"; done; exit 0'
# The fake download is the file whose sha256 the test pins into a copy of the hook.
ht_fake curl 'while (( $# )); do [[ "$1" == -o ]] && { echo good-deb > "$2"; }; shift; done; exit 0'
good="$(echo good-deb | sha256sum | cut -d" " -f1)"
sed -i -E "s/\[amd64\]=[0-9a-f]{64}/[amd64]=$good/" "$HT_EXT/files/code-server.sh"
ht_hook install; eq "sha256 совпал — install 0" 0 "$?"
check "ставится проверенный .deb" grep -q 'install .*\.deb' "$FAKE/apt.log"
eq "поставлено то, что скачано и проверено" good-deb "$(cat "$FAKE/installed.deb" 2>/dev/null)"
check_not "install не трогает службы" ht_called '^systemctl'
check_not "install не трогает домашние каталоги" test -e "$ROOT/home/alice/.config"

echo "== остатки layout 2: install и configure отказывают =="
# plant <kind>: one leftover of the layout 2 code-server on the root.
# check-names: off
plant() {
    local sd="$ROOT/etc/systemd/system"
    case "$1" in
        instance) mkdir -p "$sd"; printf '[Service]\nExecStart=/usr/bin/code-server\n' > "$sd/code-server@alice.service" ;;
        instance-dropin) mkdir -p "$sd/code-server@alice.service.d"; : > "$sd/code-server@alice.service.d/x.conf" ;;
        instance-wants) mkdir -p "$sd/multi-user.target.wants"; ln -s /lib/systemd/system/code-server@.service "$sd/multi-user.target.wants/code-server@alice.service" ;;
        configure-unit) mkdir -p "$sd"; printf '[Service]\nExecStart=/bin/bash /opt/bisquite/code-server/configure.sh\n' > "$sd/configure-code-server.service" ;;
        configure-wants) mkdir -p "$sd/cloud-init.target.wants"; ln -s ../configure-code-server.service "$sd/cloud-init.target.wants/configure-code-server.service" ;;
        old-config) mkdir -p "$(dirname "$CONF")"; printf 'bind-addr: 0.0.0.0:9001\nauth: none\ncert: /home/alice/.local/share/code-server/certs/localhost.crt\n' > "$CONF" ;;
        mkcert-ca) mkdir -p "$ROOT/usr/local/share/ca-certificates"; : > "$ROOT/usr/local/share/ca-certificates/mkcert_development_CA_1234.crt" ;;
    esac
}
# check-names: on
LEFTOVERS="instance instance-dropin instance-wants configure-unit configure-wants old-config mkcert-ca"
for k in $LEFTOVERS; do
    cs_root; plant "$k"
    ht_fake dpkg 'echo amd64'; ht_fake dpkg-query 'exit 1'; ht_fake apt-get; ht_fake curl
    ht_hook install; check_not "install, $k — отказ" test "$?" -eq 0
    check_not "install, $k — до любых изменений (сеть, apt)" ht_called '^(curl|apt-get)'
    check "install, $k — сказано, что убрать" grep -q 'остатки' "$ROOT/out"
    cs_root; plant "$k"; ht_secret CODE_SERVER_PASSWORD "$PW"
    mkdir -p "$APPS"; echo 'NAME=code-server' > "$DECL"
    ht_hook configure CREAM_REASON=boot; check_not "configure, $k — отказ" test "$?" -eq 0
    check_not "configure, $k — не стартует" started alice
    check_not "configure, $k — объявления нет" test -e "$DECL"
    check "configure, $k — сказано, что убрать" grep -q 'остатки' "$ROOT/out"
done
cs_root; plant mkcert-ca; ht_fake dpkg 'echo amd64'; ht_hook install
check "инструкция: CA mkcert — update-ca-certificates" grep -q 'update-ca-certificates' "$ROOT/out"
check "инструкция: mkcert -uninstall" grep -q 'mkcert -uninstall' "$ROOT/out"
cs_root; plant configure-unit; plant instance-wants; ht_fake dpkg 'echo amd64'; ht_hook install
check "перечень: configure-code-server.service" grep -q 'configure-code-server.service' "$ROOT/out"
check "перечень: ссылка включения" grep -q 'multi-user.target.wants/code-server@alice.service' "$ROOT/out"
check "инструкция: systemctl disable" grep -q 'systemctl disable' "$ROOT/out"
echo "== остатки: свой шаблон и свой config.yaml — не остатки =="
cs_root; mkdir -p "$ROOT/etc/systemd/system"; cp "$EXT/files/code-server@.service" "$ROOT/etc/systemd/system/"
ht_hook configure CREAM_REASON=boot CODE_SERVER_ALLOW_NO_AUTH=1; eq "свой шаблон юнита — configure 0" 0 "$?"
check "auth: none от нас" grep -qx 'auth: none' "$CONF"
ht_hook configure CREAM_REASON=boot CODE_SERVER_ALLOW_NO_AUTH=1; eq "свой config.yaml с auth: none — повтор 0" 0 "$?"
check "стартует" started alice
ht_fake dpkg 'echo amd64'; ht_fake dpkg-query "echo installed $VER"
ht_hook install; eq "свой config.yaml — install 0" 0 "$?"

echo "== configure: нет пароля и нет CODE_SERVER_ALLOW_NO_AUTH — не стартует =="
cs_root
echo 'code-server@alice.service loaded active running code-server' > "$FAKE/units"
mkdir -p "$APPS"; echo 'NAME=code-server' > "$DECL"
ht_hook configure CREAM_REASON=boot; eq "configure — 0 (предупреждение, не сбой)" 0 "$?"
check "предупреждение и как открыть" grep -q 'CODE_SERVER_ALLOW_NO_AUTH' "$ROOT/out"
check_not "code-server@alice не запускается" started alice
check "запущенный экземпляр гасится (--no-block)" ht_called '^systemctl stop --no-block code-server@alice\.service'
check_not "объявление для Teleport снято" test -e "$DECL"
check_not "конфигурация пользователя не пишется" test -e "$CONF"
check_not "блокирующих systemctl нет" blocking_systemctl

echo "== configure: пароль снят — прежний убирается из config.yaml =="
cs_root; ht_secret CODE_SERVER_PASSWORD "$PW"
ht_hook configure CREAM_REASON=boot
check "сначала пароль в config.yaml" leaked "$CONF"
: > "$ROOT/etc/cream/code-server/secrets"; : > "$FAKE/calls"
ht_hook apply CREAM_CHANGED_KEYS=CODE_SERVER_PASSWORD; eq "apply — 0" 0 "$?"
check_not "прежнего пароля в config.yaml нет" leaked "$CONF"
check "auth: none — обёртка не запустит без ключа" grep -qx 'auth: none' "$CONF"
check "переписан от имени пользователя" ht_called '^runuser -u alice -- '
check_not "не стартует" started alice
cs_root; rm -f "$FAKE/user"
ht_hook configure CREAM_REASON=boot; eq "нет ни пароля, ни пользователя — 0" 0 "$?"
check_not "пользователя не ждёт" ht_called '^sleep'
check_not "runuser не зовётся" ht_called '^runuser'
cs_root
ht_hook configure CREAM_REASON=boot; eq "нет пароля, нет config.yaml — 0" 0 "$?"
check_not "config.yaml не заводится" test -e "$CONF"

echo "== configure: пустой пароль — нет пароля =="
cs_root; ht_secret CODE_SERVER_PASSWORD '""'
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
check_not "пустой пароль не открывает" started alice

echo "== configure: пароль не по форме — сбой, не старт =="
cs_root; ht_secret CODE_SERVER_PASSWORD 'short'
echo 'code-server@alice.service loaded active running code-server' > "$FAKE/units"
ht_hook configure CREAM_REASON=boot CODE_SERVER_ALLOW_NO_AUTH=1; check_not "configure не 0" test "$?" -eq 0
check_not "и с CODE_SERVER_ALLOW_NO_AUTH=1 кривой пароль не открывает" started alice
check "экземпляр гасится" ht_called '^systemctl stop --no-block code-server@alice\.service'
check_not "значение не в выводе" grep -q 'short' "$ROOT/out"

echo "== configure: пароль задан — конфигурация от имени пользователя, старт, объявление =="
cs_root; ht_secret CODE_SERVER_PASSWORD "$PW"
hook_fd9 configure CREAM_REASON=boot CREAM_LOCK_FD=9; eq "configure — 0" 0 "$?"
check "загрузка: start --no-block code-server@alice" ht_called '^systemctl start --no-block code-server@alice\.service'
check_not "экземпляр не включается навсегда" ht_called '^systemctl enable'
check "конфигурация пишется через runuser -u alice" ht_called '^runuser -u alice -- env -i '
check "в пределе времени: timeout -k 5 30 runuser" ht_called '^timeout -k 5 30 runuser -u alice -- '
eq "fd блокировки cream процессу пользователя не достаётся" closed "$(cat "$FAKE/runuser-lockfd" 2>/dev/null)"
check "config.yaml есть" test -f "$CONF"
eq "config.yaml 0600" 600 "$(stat -c %a "$CONF" 2>/dev/null)"
eq "каталог конфигурации 0700" 700 "$(stat -c %a "$(dirname "$CONF")" 2>/dev/null)"
check "auth: password" grep -qx 'auth: password' "$CONF"
check "пароль в конфигурации" grep -qxF "password: \"$PW\"" "$CONF"
check "bind-addr на петле" grep -qx 'bind-addr: 127.0.0.1:9001' "$CONF"
check "TLS: сертификат выпускает сам code-server" grep -qx 'cert: true' "$CONF"
eq "объявление" "NAME=code-server URI=https://127.0.0.1:9001 ICON=laptop" "$(tr '\n' ' ' < "$DECL" | sed 's/ $//')"
eq "объявление 0644" 644 "$(stat -c %a "$DECL")"
check_not "пароль не в выводе" leaked "$ROOT/out"
check_not "пароль не в argv и журнале вызовов" leaked "$FAKE/calls" "$FAKE"/*.argv
check_not "пароль не в окружении runuser и timeout" leaked "$FAKE/runuser.env" "$FAKE/timeout.env"
check_not "пароль не в объявлении" leaked "$APPS"
check_not "блокирующих systemctl нет" blocking_systemctl
check_not "ожидания нет: пользователь есть" ht_called '^sleep'
check_not "предупреждения про открытый доступ нет" grep -q 'CODE_SERVER_ALLOW_NO_AUTH=1' "$ROOT/out"
conf1="$(stat -c '%i %Y' "$CONF")"; decl1="$(stat -c '%i %Y' "$DECL")"
ht_hook configure CREAM_REASON=boot; eq "повтор — 0" 0 "$?"
eq "повтор: config.yaml не переписан" "$conf1" "$(stat -c '%i %Y' "$CONF")"
eq "повтор: объявление не переписано" "$decl1" "$(stat -c '%i %Y' "$DECL")"

echo "== teleport: объявление читает настоящий разборщик teleport.sh =="
teleport_render; eq "teleport.sh render — 0" 0 "$?"
Y="$ROOT/etc/teleport.yaml"
check "приложение code-server-node1" grep -qF -- '- name: "code-server-node1"' "$Y"
check "uri из объявления" grep -qF 'uri: "https://127.0.0.1:9001"' "$Y"
check "иконка laptop" grep -qF '"teleport.icon": "laptop"' "$Y"
check "петля https — insecure_skip_verify" grep -qF 'insecure_skip_verify: true' "$Y"
check_not "teleport ничего не пропустил" grep -q 'пропускаю' "$ROOT/teleport.err"
check_not "пароль не в teleport.yaml" leaked "$Y"

echo "== configure: после install — restart; порт в конфигурации и объявлении =="
cs_root; ht_secret CODE_SERVER_PASSWORD "$PW"
ht_hook configure CREAM_REASON=install CODE_SERVER_PORT=9443; eq "configure — 0" 0 "$?"
check "restart --no-block code-server@alice" ht_called '^systemctl restart --no-block code-server@alice\.service'
check "URI с портом" grep -qx 'URI=https://127.0.0.1:9443' "$DECL"
check "bind-addr с портом" grep -qx 'bind-addr: 127.0.0.1:9443' "$CONF"

echo "== configure: смена пароля переписывает конфигурацию =="
cs_root; ht_secret CODE_SERVER_PASSWORD "$PW"
ht_hook configure CREAM_REASON=boot
printf 'CODE_SERVER_PASSWORD=%s\n' "$PW2" > "$ROOT/etc/cream/code-server/secrets"
ht_hook apply CREAM_CHANGED_KEYS=CODE_SERVER_PASSWORD; eq "apply — 0" 0 "$?"
check "новый пароль" grep -qxF "password: \"$PW2\"" "$CONF"
check_not "старого нет" leaked "$CONF"
check "restart --no-block" ht_called '^systemctl restart --no-block code-server@alice\.service'
check_not "новый пароль не в выводе" grep -qF "$PW2" "$ROOT/out" "$FAKE/calls"
eq "по-прежнему 0600" 600 "$(stat -c %a "$CONF")"

echo "== configure: пароль в кавычках (формат cream) =="
cs_root; ht_secret CODE_SERVER_PASSWORD "\"$PW\""
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
check "пароль без кавычек файла секретов" grep -qxF "password: \"$PW\"" "$CONF"

echo "== configure: CODE_SERVER_ALLOW_NO_AUTH=1 — старт с предупреждением =="
cs_root
ht_hook configure CREAM_REASON=boot CODE_SERVER_ALLOW_NO_AUTH=1; eq "configure — 0" 0 "$?"
check "стартует" started alice
check "auth: none" grep -qx 'auth: none' "$CONF"
check_not "строки пароля нет" grep -q '^password' "$CONF"
check "предупреждение при каждом configure" grep -q 'CODE_SERVER_ALLOW_NO_AUTH=1' "$ROOT/out"
ht_hook configure CREAM_REASON=boot CODE_SERVER_ALLOW_NO_AUTH=1 CODE_SERVER_BIND=0.0.0.0
check "адрес не петли без пароля — громче: открыт сети" grep -q 'сети' "$ROOT/out"
cs_root; ht_secret CODE_SERVER_PASSWORD "$PW"
ht_hook configure CREAM_REASON=boot CODE_SERVER_ALLOW_NO_AUTH=1; eq "пароль и ключ — 0" 0 "$?"
check "пароль сильнее ключа: auth: password" grep -qx 'auth: password' "$CONF"

echo "== configure: адреса =="
cs_root; ht_secret CODE_SERVER_PASSWORD "$PW"
ht_hook configure CREAM_REASON=boot CODE_SERVER_BIND=0.0.0.0; eq "0.0.0.0 — 0" 0 "$?"
check "0.0.0.0: объявление на петле" grep -qx 'URI=https://127.0.0.1:9001' "$DECL"
check "bind-addr 0.0.0.0" grep -qx 'bind-addr: 0.0.0.0:9001' "$CONF"
ht_hook configure CREAM_REASON=boot CODE_SERVER_BIND=192.0.2.10; eq "192.0.2.10 — 0" 0 "$?"
check_not "адрес без петли — объявления нет" test -e "$DECL"
check "служба всё равно стартует" started alice
ht_hook configure CREAM_REASON=boot CODE_SERVER_BIND=::1; eq "::1 — 0" 0 "$?"
check "::1 — объявление на [::1]" grep -qxF 'URI=https://[::1]:9001' "$DECL"
check "::1 — bind-addr в скобках" grep -qxF 'bind-addr: [::1]:9001' "$CONF"

echo "== configure: значения проверяются до записи =="
cs_root; ht_secret CODE_SERVER_PASSWORD "$PW"
ht_hook configure CREAM_REASON=boot 'CODE_SERVER_PORT=9001"x'; check_not "порт с кавычкой — сбой" test "$?" -eq 0
check_not "объявления нет" test -e "$DECL"
check_not "конфигурации нет" test -e "$CONF"
check_not "не стартует" started alice
ht_hook configure CREAM_REASON=boot CODE_SERVER_PORT=70000; check_not "порт > 65535 — сбой" test "$?" -eq 0
ht_hook configure CREAM_REASON=boot 'CODE_SERVER_BIND=127.0.0.1$x'; check_not "адрес с \$ — сбой" test "$?" -eq 0
ht_hook configure CREAM_REASON=boot $'CODE_SERVER_BIND=127.0.0.1\nauth: none'; check_not "адрес с переводом строки — сбой" test "$?" -eq 0
ht_hook configure CREAM_REASON=boot CODE_SERVER_ALLOW_NO_AUTH=yes; check_not "ключ отказа не 0/1 — сбой" test "$?" -eq 0
ht_hook configure CREAM_REASON=boot 'CODE_SERVER_USER=a;b'; check_not "имя пользователя не по форме — сбой" test "$?" -eq 0
check_not "конфигурации так и нет" test -e "$CONF"

echo "== configure: пользователь =="
cs_root; ht_secret CODE_SERVER_PASSWORD "$PW"
ht_hook configure CREAM_REASON=boot CODE_SERVER_USER=bob; eq "CODE_SERVER_USER=bob — 0" 0 "$?"
check "явный пользователь сильнее cloud-init" ht_called '^runuser -u bob -- '
check "code-server@bob" started bob
cs_root; ht_secret CODE_SERVER_PASSWORD "$PW"; rm -f "$FAKE/user"
ht_hook configure CREAM_REASON=boot; eq "нет пользователя на загрузке — 0" 0 "$?"
check "на загрузке ждёт пользователя" ht_called '^sleep'
check "предупреждение про пользователя" grep -q 'пользовател' "$ROOT/out"
check_not "не стартует" ht_called '^systemctl (start|restart) --no-block code-server@'
check_not "объявления нет" test -e "$DECL"
: > "$FAKE/calls"
ht_hook configure CREAM_REASON=install; eq "после install — 0" 0 "$?"
check_not "после install не ждёт" ht_called '^sleep'
cs_root; ht_secret CODE_SERVER_PASSWORD "$PW"; echo root > "$FAKE/user"
ht_hook configure CREAM_REASON=boot; eq "root — 0" 0 "$?"
check_not "от root не стартует" started root
check_not "от root конфигурация не пишется" ht_called '^runuser'
cs_root; ht_secret CODE_SERVER_PASSWORD "$PW"; echo eve > "$FAKE/user"
ht_hook configure CREAM_REASON=boot; eq "нет домашнего каталога — 0" 0 "$?"
check_not "без домашнего каталога не стартует" started eve
cs_root; ht_secret CODE_SERVER_PASSWORD "$PW"; echo 'bad;name' > "$FAKE/user"
ht_hook configure CREAM_REASON=boot; eq "кривое имя — 0" 0 "$?"
check_not "кривое имя не идёт в имя юнита" ht_called 'code-server@bad'

echo "== configure: runuser упал — не стартует =="
cs_root; ht_secret CODE_SERVER_PASSWORD "$PW"; : > "$FAKE/runuser-fails"
ht_hook configure CREAM_REASON=boot; eq "configure — 0 (предупреждение)" 0 "$?"
check_not "без конфигурации не стартует" started alice
check "предупреждение" grep -q 'не записан' "$ROOT/out"

echo "== configure: домашний каталог — ссылки не проходят =="
cs_root; ht_secret CODE_SERVER_PASSWORD "$PW"
mkdir -p "$(dirname "$CONF")" "$ROOT/victim"; echo keep > "$ROOT/victim/file"
ln -s "$ROOT/victim/file" "$CONF"
ht_hook configure CREAM_REASON=boot; eq "config.yaml — ссылка: 0" 0 "$?"
eq "цель ссылки не тронута" keep "$(cat "$ROOT/victim/file")"
check "config.yaml — обычный файл" test -f "$CONF" -a ! -L "$CONF"
check_not "пароль не ушёл в цель ссылки" leaked "$ROOT/victim"
cs_root; ht_secret CODE_SERVER_PASSWORD "$PW"
mkdir -p "$ROOT/home/alice/.config" "$ROOT/victim"; ln -s "$ROOT/victim" "$ROOT/home/alice/.config/code-server"
ht_hook configure CREAM_REASON=boot; eq "каталог конфигурации — ссылка: 0" 0 "$?"
check_not "в цель ссылки каталога ничего не легло" test -e "$ROOT/victim/config.yaml"
check_not "не стартует" started alice
check "предупреждение" grep -q 'не записан' "$ROOT/out"
cs_root; ht_secret CODE_SERVER_PASSWORD "$PW"
mkdir -p "$ROOT/victim"; ln -s "$ROOT/victim" "$ROOT/home/alice/.config"
ht_hook configure CREAM_REASON=boot; eq ".config — ссылка: 0" 0 "$?"
check_not "через ссылку .config ничего не создано" test -e "$ROOT/victim/code-server"

echo "== configure: объявление не идёт по ссылкам =="
cs_root; ht_secret CODE_SERVER_PASSWORD "$PW"
mkdir -p "$APPS" "$ROOT/victim"; echo keep > "$ROOT/victim/file"
ln -s "$ROOT/victim/file" "$DECL"
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
eq "цель ссылки не тронута" keep "$(cat "$ROOT/victim/file")"
check "объявление — обычный файл" test -f "$DECL" -a ! -L "$DECL"
cs_root; ht_secret CODE_SERVER_PASSWORD "$PW"
mkdir -p "$ROOT/etc/cream/teleport" "$ROOT/victim"; ln -s "$ROOT/victim" "$APPS"
ht_hook configure CREAM_REASON=boot; eq "apps.d — ссылка: configure 0" 0 "$?"
check_not "в цель ссылки каталога ничего не легло" test -e "$ROOT/victim/code-server.conf"
check "предупреждение про ссылку" grep -q 'ссылк' "$ROOT/out"
check "служба всё равно стартует" started alice
cs_root; ht_secret CODE_SERVER_PASSWORD "$PW"
mkdir -p "$ROOT/etc/cream" "$ROOT/victim"; ln -s "$ROOT/victim" "$ROOT/etc/cream/teleport"
ht_hook configure CREAM_REASON=boot; eq "teleport — ссылка: configure 0" 0 "$?"
check_not "через ссылку /etc/cream/teleport ничего не создано" test -e "$ROOT/victim/apps.d"

echo "== configure: прежний экземпляр другого пользователя гасится =="
cs_root; ht_secret CODE_SERVER_PASSWORD "$PW"
printf '%s\n' 'code-server@bob.service loaded active running code-server' \
    'code-server@alice.service loaded inactive dead code-server' > "$FAKE/units"
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
check "code-server@bob — stop --no-block" ht_called '^systemctl stop --no-block code-server@bob\.service'
check_not "code-server@alice не гасится" ht_called '^systemctl stop --no-block code-server@alice'
check "code-server@alice стартует" started alice

echo "== apply: без аутентификации — останов =="
cs_root
echo 'code-server@alice.service loaded active running code-server' > "$FAKE/units"
ht_hook apply CREAM_CHANGED_KEYS=CODE_SERVER_PASSWORD; eq "пароль снят: apply — 0" 0 "$?"
check "экземпляр гасится" ht_called '^systemctl stop --no-block code-server@alice\.service'
check_not "не перезапускается" started alice
check_not "apply не ждёт" ht_called '^sleep'
check_not "блокирующих systemctl нет" blocking_systemctl

echo "== remove: службы, объявление, пакет =="
cs_root
mkdir -p "$APPS"; echo 'NAME=code-server' > "$DECL"; echo 'NAME=other' > "$APPS/other.conf"
echo 'code-server@alice.service loaded active running code-server' > "$FAKE/units"
ht_fake dpkg-query "echo installed $VER"
ht_fake apt-get
ht_hook remove; eq "remove — 0" 0 "$?"
check "экземпляры остановлены" ht_called '^systemctl stop .*code-server@alice\.service'
check "упавший экземпляр не остаётся в --failed" ht_called '^systemctl reset-failed code-server@alice\.service'
check_not "объявление снято" test -e "$DECL"
check "чужое объявление на месте" test -f "$APPS/other.conf"
check "пакет удаляется" ht_called '^apt-get .*(remove|purge) .*code-server'
ht_fake dpkg-query 'exit 1'
: > "$FAKE/calls"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
check_not "повтор: удалять нечего" ht_called '^apt-get'

echo "== обёртка start: fail-closed и окружение =="
# run_start <env pairs…>: the wrapper as systemd starts it for alice (User=%i,
# EnvironmentFile=config): HOME of the user, the domain keys, nothing else.
run_start() {
    (
        cd / || exit 125
        exec env -i "PATH=$ROOT/bin:$HT_PATH_TAIL" LANG=C.UTF-8 "CREAM_ROOT=$ROOT" \
            "HOME=$ROOT/home/alice" USER=alice "$@" \
            /bin/bash "$EXT/files/code-server.sh" start < /dev/null
    ) > "$ROOT/out" 2>&1
}
write_conf() { mkdir -p "$(dirname "$CONF")"; printf '%s\n' "$@" > "$CONF"; chmod 0600 "$CONF"; }
cs_root
run_start; eq "нет конфигурации — 78" 78 "$?"
check_not "code-server не запущен" test -e "$FAKE/code-server.env"
cs_root; write_conf 'bind-addr: 127.0.0.1:9001' 'auth: none' 'cert: true'
run_start CODE_SERVER_ALLOW_NO_AUTH=0; eq "auth: none без ключа — 78" 78 "$?"
check_not "code-server не запущен" test -e "$FAKE/code-server.env"
check "сказано, как открыть" grep -q 'CODE_SERVER_ALLOW_NO_AUTH' "$ROOT/out"
cs_root; write_conf 'bind-addr: 127.0.0.1:9001' 'auth: password' 'cert: true'
run_start; eq "auth: password без пароля — 78" 78 "$?"
cs_root; write_conf 'bind-addr: 127.0.0.1:9001' 'auth: password' 'password: ""' 'cert: true'
run_start; eq "auth: password с пустым паролем — 78" 78 "$?"
cs_root; mkdir -p "$ROOT/victim"; printf 'auth: password\npassword: "x12345678"\n' > "$ROOT/victim/c"
mkdir -p "$(dirname "$CONF")"; ln -s "$ROOT/victim/c" "$CONF"
run_start; eq "config.yaml — ссылка: 78" 78 "$?"
cs_root; write_conf 'bind-addr: 127.0.0.1:9001' 'auth: password' "password: \"$PW\"" 'cert: true'
run_start CODE_SERVER_PORT=9001 CODE_SERVER_ALLOW_NO_AUTH=0 PASSWORD=from-env HASHED_PASSWORD=x; eq "с паролем — 0" 0 "$?"
check "code-server запущен" test -e "$FAKE/code-server.env"
eq "argv code-server — только путь конфигурации" "--config $CONF" "$(cat "$FAKE/code-server.args")"
check_not "ключи домена не доходят до code-server" grep -q '^CODE_SERVER_' "$FAKE/code-server.env"
check_not "PASSWORD из окружения не доходит" grep -qE '^(HASHED_)?PASSWORD=' "$FAKE/code-server.env"
check_not "пароль не в окружении и argv" leaked "$FAKE/code-server.env" "$FAKE/code-server.args"
check_not "пароль не в выводе обёртки" leaked "$ROOT/out"
cs_root; write_conf 'bind-addr: 127.0.0.1:9001' 'auth: none' 'cert: true'
run_start CODE_SERVER_ALLOW_NO_AUTH=1; eq "auth: none с ключом — 0" 0 "$?"
check "code-server запущен" test -e "$FAKE/code-server.env"
check "предупреждение при старте" grep -q 'CODE_SERVER_ALLOW_NO_AUTH=1' "$ROOT/out"

echo "== write-config: только не от root, по форме =="
cs_root
out="$(printf '%s\n' "$PW" | env -i "PATH=$HT_PATH_TAIL" /bin/bash "$EXT/files/code-server.sh" write-config \
    "$ROOT/home/alice" '127.0.0.1;x' 9001 password 2>&1)"; rc=$?
check_not "адрес не по форме — отказ" test "$rc" -eq 0
check_not "конфигурации нет" test -e "$CONF"
check_not "пароль не в выводе" grep -qF "$PW" <<< "$out"
out="$(printf '%s\n' 'bad pass"word' | env -i "PATH=$HT_PATH_TAIL" /bin/bash "$EXT/files/code-server.sh" write-config \
    "$ROOT/home/alice" 127.0.0.1 9001 password 2>&1)"; rc=$?
check_not "пароль не по форме — отказ" test "$rc" -eq 0
check_not "конфигурации нет" test -e "$CONF"
mkdir -p "$ROOT/home/other"
if [[ "$UID_ME" != 0 ]]; then
    # A home that is not the caller's (root's here, simulated by a chmod-less check
    # on the owner): a directory owned by someone else is refused.
    out="$(printf '%s\n' "$PW" | env -i "PATH=$HT_PATH_TAIL" /bin/bash "$EXT/files/code-server.sh" write-config \
        /tmp 127.0.0.1 9001 password 2>&1)"; rc=$?
    check_not "чужой каталог (/tmp — root) — отказ" test "$rc" -eq 0
    check_not "в /tmp ничего не легло" test -e /tmp/.config/code-server/config.yaml
fi

echo "== имена layout 2 =="
# check-names: off
check_not "нет /opt/bisquite, bisquite-conf, BISQUITE_ в коде" \
    grep -rqE '/opt/bisquite|/etc/bisquite|bisquite-conf|BISQUITE_' "$EXT/hooks" "$EXT/files" "$EXT/extension.yaml"
# check-names: on

ht_done
