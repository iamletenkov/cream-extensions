#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# H-тест stvor-agent-openwrt на подменённом корне (tools/hooktest.sh): манифест
# сверен с debian/stvor-agent (контракт ключей со скриптом установки Stvor), выбор
# версии и источника tar.gz, сверка sha256, состав tar.gz, раскладка (бинарь,
# init-скрипты procd, состояние /opt/stvor-agent), пользователь stvor-telemetry
# через помощники /lib/functions.sh, procd и ubus — подставные: init-скрипты из
# tar.gz пишут журнал вызовов, `running` отвечает по $FAKE/running-<служба>.
# Настоящие busybox, rc.common, /lib/functions.sh и cream — L (make test-openwrt).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(dirname "$HERE")"
REPO="$(cd "$SRC/../../.." && pwd)"
DEB="$REPO/extensions/debian/stvor-agent"
# shellcheck source=../../../../tools/hooktest.sh
. "$HERE/../../../../tools/hooktest.sh"
ht_init

GH=https://github.com/iamletenkov/stvor-agent/releases/download
MIRROR=https://stvor.example.org/dist/teleport
TOKEN="tok-$RANDOM$RANDOM-label-secret"

# make_tgz <version> [без <член>]: stvor-agent_<v>_linux_<arch>.tar.gz в $FAKE/tgz:
# бинарь-подделка (version, disable) и init-скрипты, пишущие журнал вызовов.
make_tgz(){
    local d m; d="$(mktemp -d "$HT_TMP/tgz.XXXXXX")"
    mkdir -p "$d/init.d"
    {
        echo '#!/usr/bin/env bash'
        printf 'FAKE=%q\n' "$FAKE"
        echo 'echo "agent $*" >> "$FAKE/calls"; env > "$FAKE/agent.env"'
        printf '[[ "$1" == version ]] && echo "stvor-agent %s"\n' "$1"
        echo '[[ "$1" == disable && -e "$FAKE/disable-fails" ]] && exit 1'
        echo '[[ "$*" == "status --json" ]] && { cat "$FAKE/status.json" 2>/dev/null; exit "$(cat "$FAKE/status-rc" 2>/dev/null || echo 0)"; }'
        echo 'exit 0'
    } > "$d/stvor-agent"
    for m in stvor-agent stvor-agent-telemetry; do
        {
            echo '#!/usr/bin/env bash'
            printf 'FAKE=%q\nme=%q\n' "$FAKE" "$m"
            echo 'echo "init $me $*" >> "$FAKE/calls"'
            echo '[[ "$1" == running ]] && { [[ -e "$FAKE/running-$me" ]]; exit; }'
            echo 'exit 0'
        } > "$d/init.d/$m"
    done
    echo man > "$d/stvor-agent.8.gz"
    echo license > "$d/LICENSE"
    chmod 0755 "$d/stvor-agent" "$d/init.d/"*
    [[ -n "${2:-}" ]] && rm -f -- "$d/${2#без }"
    tar -czf "$FAKE/tgz" -C "$d" .
    TGZ_SHA="$(sha256sum "$FAKE/tgz" | cut -d' ' -f1)"
}

setup(){
    ht_root "$SRC"
    S="$ROOT/var/lib/cream/ext/stvor-agent-openwrt"
    mkdir -p "$ROOT/etc/init.d" "$ROOT/var/run" "$ROOT/usr/bin" "$ROOT/lib" "$ROOT/etc/stvor-agent"
    echo x86_64 > "$FAKE/uname"
    ht_fake uname 'cat "$FAKE/uname"'
    ht_fake chown
    ht_fake lock
    # curl: -o — копия $FAKE/tgz; окружение — в $FAKE/curl.env.
    ht_fake curl 'env > "$FAKE/curl.env"; out=""; prev=""
for a in "$@"; do [[ "$prev" == -o ]] && out="$a"; prev="$a"; done
[[ -f "$FAKE/curl-fails" || ! -f "$FAKE/tgz" ]] && exit 22
cp "$FAKE/tgz" "$out"'
    ht_fake cream 'env > "$FAKE/cream.env"'
    # /lib/functions.sh: помощники OpenWrt в том же виде (sh), без lock.
    cat > "$ROOT/lib/functions.sh" <<'EOF'
group_exists() { grep -qs "^${1}:" ${IPKG_INSTROOT}/etc/group; }
group_add_next() {
	gid=$(grep -s "^${1}:" ${IPKG_INSTROOT}/etc/group | cut -d: -f3)
	[ -n "$gid" ] && { echo $gid; return; }
	gids=$(cut -d: -f3 ${IPKG_INSTROOT}/etc/group); gid=32768
	while echo "$gids" | grep -q "^$gid$"; do gid=$((gid + 1)); done
	echo "${1}:x:${gid}:" >> ${IPKG_INSTROOT}/etc/group; echo $gid
}
user_exists() { grep -qs "^${1}:" ${IPKG_INSTROOT}/etc/passwd; }
user_add() {
	uids=$(cut -d: -f3 ${IPKG_INSTROOT}/etc/passwd); uid=32768
	while echo "$uids" | grep -q "^$uid$"; do uid=$((uid + 1)); done
	echo "${1}:x:${uid}:${3}:${4}:${5}:${6}" >> ${IPKG_INSTROOT}/etc/passwd
	echo "${1}:x:0:0:99999:7:::" >> ${IPKG_INSTROOT}/etc/shadow
}
EOF
    printf 'root:x:0:0:root:/root:/bin/ash\nnobody:*:65534:65534:nobody:/var:/bin/false\n' > "$ROOT/etc/passwd"
    printf 'root:x:0:\nnogroup:x:65534:\n' > "$ROOT/etc/group"
    printf 'root:::0:99999:7:::\n' > "$ROOT/etc/shadow"
    # The labels token of an enabled agent: install and apply never touch it.
    printf 'url=https://stvor.example.org/robot-api/v1/labels\ntoken=%s\n' "$TOKEN" > "$ROOT/etc/stvor-agent/token"
    mkdir -p "$ROOT/etc/cream/teleport-openwrt/command-labels.d"
    cp "$SRC/files/stvor_agent.command-label" "$ROOT/etc/cream/teleport-openwrt/command-labels.d/stvor_agent"
    make_tgz 4.1.0
}
procd_up(){ mkdir -p "$ROOT/var/run/ubus"; : > "$ROOT/var/run/ubus/ubus.sock"; }
pin(){ printf 'STVOR_AGENT_PIN_VERSION=%s\nSTVOR_AGENT_PIN_SHA256_AMD64=%s\nSTVOR_AGENT_PIN_SHA256_ARM64=%s\n' "$@" > "$HT_EXT/files/pin.env"; }
mode(){ ls -ld "$1" | cut -c1-10; }
nothing_installed(){ [[ ! -e "$ROOT/usr/bin/stvor-agent" && ! -e "$ROOT/etc/init.d/stvor-agent" && ! -e "$S/installed" ]]; }
installed(){ ht_hook install STVOR_AGENT_VERSION=4.1.0 STVOR_AGENT_SHA256="$TGZ_SHA" STVOR_AGENT_MIRROR="$MIRROR"; }

echo "== манифест: ключи debian/stvor-agent, зависимость, файлы =="
python3 - "$SRC/extension.yaml" "$DEB/extension.yaml" <<'PY' || bad "манифест не сходится с debian/stvor-agent"
import sys, yaml
o, d = (yaml.safe_load(open(p, encoding="utf-8")) for p in sys.argv[1:])
ok, dk = o["config"]["keys"], d["config"]["keys"]
assert o["name"] == "stvor-agent-openwrt" and o["platform"]["family"] == "openwrt", o
assert o["cream"] == ">=1.3.0", o["cream"]
assert o["depends"] == [{"name": "teleport-openwrt", "version": ">=1.0.0 <2"}], o["depends"]
assert set(ok) == (set(dk) - {"STVOR_AGENT_DEB"}) | {"STVOR_AGENT_TARBALL"}, sorted(ok)
for k in set(ok) & set(dk):
    for f in ("type", "default", "empty", "scope"):
        assert ok[k].get(f) == dk[k].get(f), (k, f)
assert ok["STVOR_AGENT_TARBALL"]["type"] == "path" and ok["STVOR_AGENT_TARBALL"]["scope"] == "install"
dst = {f["dst"]: f for f in o["files"]}
assert "/etc/cream/teleport-openwrt/command-labels.d/stvor_agent" in dst, dst
assert "/lib/upgrade/keep.d/stvor-agent" in dst, dst
assert o["hooks"]["configure"] == {"stage": "system", "every_boot": True, "timeout": "1m"}, o["hooks"]
assert o["actions"] == d["actions"], (o.get("actions"), d.get("actions"))
PY
check "actions/status исполняемый" test -x "$SRC/actions/status"
ok
eq "метка — как у debian" "$(cat "$DEB/files/stvor_agent.command-label")" "$(cat "$SRC/files/stvor_agent.command-label")"
# Спека §4.3/§4.7, Р4: токены и их след (telemetry-token.src), state.json и буфер телеметрии
# sysupgrade не переживают; machine-id — опознание машины детектором клонов портала.
eq "keep.d — только machine-id агента" "/opt/stvor-agent/machine-id" "$(grep -v '^#' "$SRC/files/keep.d")"
# Пин в git — полный (выпуск с tar.gz есть) или пустой целиком (до него): половины не бывает.
pinv(){ sed -n "s/^$1=//p" "$SRC/files/pin.env"; }
check "пин в git: полный или пустой целиком" python3 -c '
import re, sys
v, a, b = sys.argv[1:]
sys.exit(0 if (v, a, b) == ("", "", "") or (re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", v)
    and all(re.fullmatch("[0-9a-f]{64}", x) for x in (a, b))) else 1)' \
    "$(pinv STVOR_AGENT_PIN_VERSION)" "$(pinv STVOR_AGENT_PIN_SHA256_AMD64)" "$(pinv STVOR_AGENT_PIN_SHA256_ARM64)"

echo "== install: явная пара и зеркало — tar.gz, sha256, раскладка, пользователь =="
setup
installed; eq "install — 0" 0 "$?"
check "скачан tar.gz amd64 с зеркала" grep -qx "curl -fL --retry 5 --retry-delay 5 --connect-timeout 30 --speed-limit 10240 --speed-time 60 -o .*/stvor-agent_4.1.0_linux_amd64.tar.gz $MIRROR/stvor-agent_4.1.0_linux_amd64.tar.gz" "$FAKE/calls"
eq "бинарь 0755" -rwxr-xr-x "$(mode "$ROOT/usr/bin/stvor-agent")"
eq "init stvor-agent 0755" -rwxr-xr-x "$(mode "$ROOT/etc/init.d/stvor-agent")"
eq "init телеметрии 0755" -rwxr-xr-x "$(mode "$ROOT/etc/init.d/stvor-agent-telemetry")"
check "init-скрипт из tar.gz" grep -q 'echo "init $me $\*"' "$ROOT/etc/init.d/stvor-agent"
check "man не ставится" test ! -e "$ROOT/usr/bin/stvor-agent.8.gz"
check "enable агента" ht_called '^init stvor-agent enable$'
check "enable телеметрии" ht_called '^init stvor-agent-telemetry enable$'
check_not "без procd — ничего не стартует" ht_called '^init .* (start|restart)$'
check_not "без procd — reload-apps не зовётся" ht_called '^cream '
check "группа stvor-telemetry" grep -qE '^stvor-telemetry:x:32768:$' "$ROOT/etc/group"
check "пользователь stvor-telemetry без входа" grep -qxE 'stvor-telemetry:x:32768:32768:Stvor agent telemetry:/var/run/stvor-agent-telemetry:/bin/false' "$ROOT/etc/passwd"
check "строка shadow" grep -q '^stvor-telemetry:' "$ROOT/etc/shadow"
check "маркер «пользователь наш»" test -e "$S/user-created"
eq "/opt/stvor-agent 0750" drwxr-x--- "$(mode "$ROOT/opt/stvor-agent")"
eq "/etc/stvor-agent-telemetry 0750" drwxr-x--- "$(mode "$ROOT/etc/stvor-agent-telemetry")"
check "chown root:stvor-telemetry" grep -qx "0:stvor-telemetry -- $ROOT/opt/stvor-agent" "$FAKE/chown.argv"
eq "запись установленного" "4.1.0 $TGZ_SHA" "$(cat "$S/installed")"
check "токен меток на месте" grep -q "token=$TOKEN" "$ROOT/etc/stvor-agent/token"
check_not "токен не в окружении curl" grep -q "$TOKEN" "$FAKE/curl.env"
check_not "окружение curl — своё (без CREAM_*)" grep -q '^CREAM_' "$FAKE/curl.env"

echo "== повтор той же пары — пропуск без сети, пользователь не двоится =="
: > "$FAKE/calls"
installed; eq "повтор — 0" 0 "$?"
check "«уже установлен»" grep -q 'stvor-agent 4.1.0 уже установлен' "$ROOT/out"
check_not "curl не звался" ht_called '^curl '
eq "один пользователь" 1 "$(grep -c '^stvor-telemetry:' "$ROOT/etc/passwd")"
eq "одна группа" 1 "$(grep -c '^stvor-telemetry:' "$ROOT/etc/group")"

echo "== arm64, релиз GitHub по умолчанию =="
setup
echo aarch64 > "$FAKE/uname"
ht_hook install STVOR_AGENT_VERSION=4.1.0 STVOR_AGENT_SHA256="$TGZ_SHA"; eq "install — 0" 0 "$?"
check "URL релиза arm64" ht_called "^curl .* $GH/v4.1.0/stvor-agent_4.1.0_linux_arm64.tar.gz$"
echo mips > "$FAKE/uname"
ht_hook install STVOR_AGENT_VERSION=4.1.0 STVOR_AGENT_SHA256="$TGZ_SHA"; check "mips — отказ" test "$?" -ne 0
check "сообщение об архитектуре" grep -q 'архитектура mips не поддерживается' "$ROOT/out"

echo "== пин каталога: пустой — отказ до сети, полный — по архитектуре =="
setup
pin "" "" ""
ht_hook install; check "пустой пин — отказ" test "$?" -ne 0
check "сообщение о пине" grep -q 'пин каталога неполон' "$ROOT/out"
check_not "до сети" ht_called '^curl '
check "ничего не поставлено" nothing_installed
pin 4.1.0 "$TGZ_SHA" "$(printf 'b%.0s' {1..64})"
ht_hook install STVOR_AGENT_MIRROR="$MIRROR"; eq "пин — 0" 0 "$?"
check "пин назван" grep -q 'пин каталога: 4.1.0' "$ROOT/out"
eq "запись по пину" "4.1.0 $TGZ_SHA" "$(cat "$S/installed")"

echo "== половина пары и неверные значения — отказ до сети =="
setup
ht_hook install STVOR_AGENT_VERSION=4.1.0; check "версия без суммы — отказ" test "$?" -ne 0
ht_hook install STVOR_AGENT_SHA256="$TGZ_SHA"; check "сумма без версии — отказ" test "$?" -ne 0
ht_hook install STVOR_AGENT_VERSION=4.1 STVOR_AGENT_SHA256="$TGZ_SHA"; check "версия не X.Y.Z — отказ" test "$?" -ne 0
ht_hook install STVOR_AGENT_VERSION=4.1.0 STVOR_AGENT_SHA256="$TGZ_SHA" STVOR_AGENT_MIRROR="$MIRROR" \
    STVOR_AGENT_TARBALL=/x.tar.gz; check "зеркало и файл — отказ" test "$?" -ne 0
ht_hook install STVOR_AGENT_VERSION=4.1.0 STVOR_AGENT_SHA256="$TGZ_SHA" STVOR_AGENT_MIRROR='ftp://x'
check "зеркало не http(s) — отказ" test "$?" -ne 0
ht_hook install STVOR_AGENT_VERSION=4.1.0 STVOR_AGENT_SHA256="$TGZ_SHA" STVOR_AGENT_TARBALL=rel.tar.gz
check "относительный файл — отказ" test "$?" -ne 0
check_not "сети не было" ht_called '^curl '
check "ничего не поставлено" nothing_installed

echo "== sha256 не совпала, нет файла в tar.gz, сеть упала — ничего не поставлено =="
setup
ht_hook install STVOR_AGENT_VERSION=4.1.0 STVOR_AGENT_SHA256="$(printf 'c%.0s' {1..64})" STVOR_AGENT_MIRROR="$MIRROR"
check "чужая сумма — отказ" test "$?" -ne 0
check "сообщение о сумме" grep -q 'sha256 tar.gz не совпал' "$ROOT/out"
check "ничего не поставлено" nothing_installed
make_tgz 4.1.0 "без init.d/stvor-agent-telemetry"
installed; check "нет init телеметрии — отказ" test "$?" -ne 0
check "сообщение называет файл" grep -q 'нет файла init.d/stvor-agent-telemetry' "$ROOT/out"
check "ничего не поставлено" nothing_installed
make_tgz 4.1.0
: > "$FAKE/curl-fails"
installed; check "сеть упала — отказ" test "$?" -ne 0
check "ничего не поставлено" nothing_installed
check "рабочий каталог убран" test -z "$(ls -A "$ROOT/tmp")"

echo "== офлайн: STVOR_AGENT_TARBALL без сети =="
setup
cp "$FAKE/tgz" "$ROOT/agent.tar.gz"
ht_hook install STVOR_AGENT_VERSION=4.1.0 STVOR_AGENT_SHA256="$TGZ_SHA" STVOR_AGENT_TARBALL="$ROOT/agent.tar.gz"
eq "файл — 0" 0 "$?"
check_not "без curl" ht_called '^curl '
check "бинарь на месте" test -x "$ROOT/usr/bin/stvor-agent"

echo "== живая машина: reload-apps метки, обновление перезапускает работающее =="
setup
procd_up
installed; eq "install — 0" 0 "$?"
check "reload-apps teleport-openwrt" ht_called '^cream run teleport-openwrt reload-apps$'
check "вложенный cream — с окружением cream" grep -q '^CREAM_PHASE=live$' "$FAKE/cream.env"
check_not "первая установка — без restart" ht_called '^init .* restart$'
: > "$FAKE/running-stvor-agent"
: > "$FAKE/calls"
make_tgz 4.2.0
ht_hook install STVOR_AGENT_VERSION=4.2.0 STVOR_AGENT_SHA256="$TGZ_SHA" STVOR_AGENT_MIRROR="$MIRROR"
eq "upgrade до 4.2.0 — 0" 0 "$?"
wait
sleep 0.2
check "работающий агент перезапущен" ht_called '^init stvor-agent restart$'
check_not "неработающая телеметрия не стартует" ht_called '^init stvor-agent-telemetry restart$'
check "сказано «было 4.1.0»" grep -q '(было 4.1.0)' "$ROOT/out"
check "токен меток на месте" grep -q "token=$TOKEN" "$ROOT/etc/stvor-agent/token"
setup
procd_up
HT_PHASE=build installed; eq "фаза build — 0" 0 "$?"
check_not "фаза build — без reload-apps" ht_called '^cream '

echo "== пользователь уже есть — не трогается и при remove =="
setup
printf 'stvor-telemetry:x:900:\n' >> "$ROOT/etc/group"
printf 'stvor-telemetry:x:900:900::/var:/bin/false\n' >> "$ROOT/etc/passwd"
installed; eq "install — 0" 0 "$?"
check "маркера нет" test ! -e "$S/user-created"
ht_hook remove; eq "remove — 0" 0 "$?"
check "чужой пользователь остался" grep -q '^stvor-telemetry:x:900:' "$ROOT/etc/passwd"

echo "== была только группа — пользователь создаётся, но remove их не снимает =="
setup
printf 'stvor-telemetry:x:901:\n' >> "$ROOT/etc/group"
installed; eq "install — 0" 0 "$?"
check "пользователь создан" grep -q '^stvor-telemetry:x:[0-9]*:901:' "$ROOT/etc/passwd"
check "маркера нет" test ! -e "$S/user-created"
ht_hook remove; eq "remove — 0" 0 "$?"
check "чужая группа осталась" grep -q '^stvor-telemetry:x:901:' "$ROOT/etc/group"

echo "== та же пара, но init-скрипт пропал — ставится заново =="
setup
installed
rm -f "$ROOT/etc/init.d/stvor-agent-telemetry"
: > "$FAKE/calls"
installed; eq "install — 0" 0 "$?"
check "скачано заново" ht_called '^curl '
check "init телеметрии вернулся" test -x "$ROOT/etc/init.d/stvor-agent-telemetry"

echo "== remove: disable, службы, файлы, токены, состояние, пользователь, метка =="
setup
procd_up
installed
mkdir -p "$ROOT/opt/stvor-agent/telemetry" "$ROOT/var/run/stvor-agent-telemetry"
echo id > "$ROOT/opt/stvor-agent/machine-id"
echo t > "$ROOT/etc/stvor-agent-telemetry/token"
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check "stvor-agent disable" ht_called '^agent disable$'
check "служба остановлена" ht_called '^init stvor-agent stop$'
check "служба выключена" ht_called '^init stvor-agent disable$'
check "телеметрия выключена" ht_called '^init stvor-agent-telemetry disable$'
for p in usr/bin/stvor-agent etc/init.d/stvor-agent etc/init.d/stvor-agent-telemetry etc/stvor-agent \
    etc/stvor-agent-telemetry opt/stvor-agent var/run/stvor-agent-telemetry \
    etc/cream/teleport-openwrt/command-labels.d/stvor_agent; do
    check "снято /$p" test ! -e "$ROOT/$p"
done
check_not "пользователь снят" grep -q '^stvor-telemetry:' "$ROOT/etc/passwd"
check_not "группа снята" grep -q '^stvor-telemetry:' "$ROOT/etc/group"
check_not "shadow очищен" grep -q '^stvor-telemetry:' "$ROOT/etc/shadow"
check "root на месте" grep -q '^root:' "$ROOT/etc/passwd"
check "метка снята с узла: reload-apps" ht_called '^cream run teleport-openwrt reload-apps$'
check "запись установленного снята" test ! -e "$S/installed"
setup
installed
: > "$FAKE/disable-fails"
ht_hook remove; eq "disable упал — remove всё равно 0" 0 "$?"
check "предупреждение" grep -q 'stvor-agent disable не прошёл' "$ROOT/out"
check "токен снят" test ! -e "$ROOT/etc/stvor-agent"
ht_hook remove; eq "повтор remove на пустом — 0" 0 "$?"

echo "== права состояния: восстановленный буфер пересоздаётся, содержимое root не трогает =="
# Восстановленное (keep.d 1.1.0, резервная копия) приходит 0:0 0755: служба телеметрии
# (stvor-telemetry) падала с permission denied. Дерево — пользователя: жёсткая ссылка
# или симлинк в буфере на файл root не должны отдать этот файл пользователю.
T="opt/stvor-agent/telemetry"
spoil_state(){
    local t="$ROOT/$T"
    mkdir -p "$t/buffer/q"
    chmod 0755 "$t" "$t/buffer" "$t/buffer/q"
    echo seg > "$t/buffer/q/0001"
    echo marker > "$t/token-rejected"
    echo 'root:secret' > "$ROOT/etc/root-file"; chmod 0600 "$ROOT/etc/root-file"
    ln -f "$ROOT/etc/root-file" "$t/buffer/hard"
    ln -sfn "$ROOT/etc/root-file" "$t/buffer/soft"
    echo id > "$ROOT/opt/stvor-agent/machine-id"; chmod 0600 "$ROOT/opt/stvor-agent/machine-id"
    rm -f "$FAKE/chown.argv"
}
owned(){ grep -qx -- "$1" "$FAKE/chown.argv"; }
check_reset(){
    local t="$ROOT/$T"
    eq "$1: telemetry 0700" drwx------ "$(mode "$t")"
    eq "$1: новый пустой buffer 0700" "drwx------ " "$(mode "$t/buffer") $(ls -A "$t/buffer")"
    eq "$1: machine-id 0640" -rw-r----- "$(mode "$ROOT/opt/stvor-agent/machine-id")"
    check "$1: machine-id root:stvor-telemetry" owned "0:stvor-telemetry -- $ROOT/opt/stvor-agent/machine-id"
    eq "$1: файл root цел" "-rw------- root:secret" "$(mode "$ROOT/etc/root-file") $(cat "$ROOT/etc/root-file")"
    check_not "$1: файл root не перевладевается" grep -q 'root-file' "$FAKE/chown.argv"
    check_not "$1: содержимое буфера не перевладевается" grep -q -- "$t/buffer/" "$FAKE/chown.argv"
    check_not "$1: без chown -R и -h" grep -qE -- '(^| )-[Rh]( |$)' "$FAKE/chown.argv"
    check "$1: маркер агента в telemetry остался" test -f "$t/token-rejected"
    check "$1: корзины не осталось" test -z "$(find "$ROOT/opt/stvor-agent" -maxdepth 1 -name '.trash.*')"
    # Порядок: telemetry закрыт root, buffer создан и отдан, telemetry отдан последним.
    eq "$1: chown по порядку" "0:0 -- $t
stvor-telemetry:stvor-telemetry -- $t/buffer
stvor-telemetry:stvor-telemetry -- $t" "$(grep -- " $t" "$FAKE/chown.argv")"
}
setup
installed
spoil_state
installed
eq "повторная установка — 0" 0 "$?"
check_reset "переустановка"
check "сказано о пересоздании" grep -q 'буфер телеметрии пересоздаётся' "$ROOT/out"
spoil_state
: > "$FAKE/calls"
ht_hook configure; eq "configure — 0" 0 "$?"
check_reset "configure"
check_not "configure — без сети" ht_called '^curl '
check_not "configure без procd — службы не трогаются" ht_called '^init '

echo "== права состояния: живая машина — служба телеметрии остановлена и запущена вновь =="
setup
procd_up
installed
spoil_state
: > "$FAKE/running-stvor-agent-telemetry"
: > "$FAKE/calls"
ht_hook configure; eq "configure — 0" 0 "$?"
wait
sleep 0.2
check "телеметрия остановлена" ht_called '^init stvor-agent-telemetry stop$'
check "телеметрия запущена" ht_called '^init stvor-agent-telemetry start$'
check_reset "живая машина"

echo "== права состояния: процессы пользователя не завершились — ничего не трогается =="
setup
installed
spoil_state
mkdir -p "$ROOT/proc/4242"
printf 'Name:\tstvor-agent\nUid:\t32768\t32768\t32768\t32768\n' > "$ROOT/proc/4242/status"
ht_fake sleep
ht_hook configure; check "configure — отказ" test "$?" -ne 0
check "сказано о процессах" grep -q 'процессы stvor-telemetry не завершились' "$ROOT/out"
check "буфер на месте" test -f "$ROOT/$T/buffer/q/0001"
check_not "telemetry не трогался" grep -q -- " $ROOT/$T" "$FAKE/chown.argv"

echo "== права состояния: дерево уже пользователя — не трогается =="
setup
printf 'stvor-telemetry:x:%s:\n' "$(id -g)" >> "$ROOT/etc/group"
printf 'stvor-telemetry:x:%s:%s::/var:/bin/false\n' "$(id -u)" "$(id -g)" >> "$ROOT/etc/passwd"
installed
mkdir -p "$ROOT/$T/buffer/q"; chmod 0700 "$ROOT/$T" "$ROOT/$T/buffer" "$ROOT/$T/buffer/q"
echo seg > "$ROOT/$T/buffer/q/0001"
rm -f "$FAKE/chown.argv"
ht_hook configure; eq "configure — 0" 0 "$?"
check "буфер сохранён" test -f "$ROOT/$T/buffer/q/0001"
check_not "telemetry не трогался" grep -q -- " $ROOT/$T" "$FAKE/chown.argv"
check_not "без сообщения о пересоздании" grep -q 'пересоздаётся' "$ROOT/out"

echo "== configure до install: пользователя нет — ничего =="
setup
rm -f "$FAKE/chown.argv"
ht_hook configure; eq "configure до install (нет пользователя) — 0" 0 "$?"
check "configure до install — сказано" grep -q 'пользователя stvor-telemetry нет' "$ROOT/out"
check "configure до install — chown не звался" test ! -e "$FAKE/chown.argv"

echo "== действие status: блок telemetry в stvor-agent status --json =="
status_doc(){
    {
        printf '{\n  "schema": 1,\n  "version": "4.1.0",\n  "service": "%s",\n  "enabled": %s,\n  "token": "ok",\n' "$2" "$1"
        printf '  "restart": {\n    "attempts": 0,\n    "paused_until": null\n  }'
        [[ -z "${3:-}" ]] || printf ',\n  "telemetry": {\n    "service": "%s",\n    "token": "%s",\n    "buffer": null\n  }' "$3" "$4"
        printf '\n}\n'
    } > "$FAKE/status.json"
}
# st: eval only over this file's own literal expressions, never outside input.
st(){ python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); v = eval(sys.argv[2], {"d": d}); print(v if isinstance(v, str) else json.dumps(v))' "$ROOT/out" "$1"; }
setup
installed
status_doc true active active ok
ht_action status; eq "здоров — 0" 0 "$?"
eq "здоров — healthy, проблем нет, документ внутри" 'true [] 4.1.0' "$(st 'd["healthy"]') $(st 'd["problems"]') $(st 'd["agent"]["version"]')"
status_doc true active inactive absent
ht_action status; eq "телеметрия не работает — 1" 1 "$?"
eq "проблемы телеметрии" '["telemetry.service:inactive", "telemetry.token:absent"]' "$(st 'd["problems"]')"
status_doc false inactive active ok; echo 1 > "$FAKE/status-rc"
ht_action status; eq "агент не включён — 1" 1 "$?"
eq "проблемы агента" '["agent.enabled:false", "agent.service:inactive"]' "$(st 'd["problems"]')"
setup
ht_action status; eq "агента нет — 1" 1 "$?"
eq "not_installed" '["agent.not_installed"] null' "$(st 'd["problems"]') $(st 'd["agent"]')"

echo "== apply: перезапуск работающих фоном, без procd — ничего =="
setup
installed
: > "$FAKE/calls"
ht_hook apply; eq "apply без procd — 0" 0 "$?"
check_not "без procd — без restart" ht_called 'restart'
procd_up
: > "$FAKE/running-stvor-agent"
: > "$FAKE/running-stvor-agent-telemetry"
ht_hook apply STVOR_AGENT_INTERVAL=120; eq "apply — 0" 0 "$?"
wait
sleep 0.2
check "агент перезапущен" ht_called '^init stvor-agent restart$'
check "телеметрия перезапущена" ht_called '^init stvor-agent-telemetry restart$'
HT_PHASE=build ht_hook apply; eq "apply в build — 0" 0 "$?"
check "apply в build — сказано" grep -q 'фаза build' "$ROOT/out"

ht_done
