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
assert "configure" not in o["hooks"], o["hooks"]
PY
ok
eq "метка — как у debian" "$(cat "$DEB/files/stvor_agent.command-label")" "$(cat "$SRC/files/stvor_agent.command-label")"
eq "keep.d — только состояние агента" "/opt/stvor-agent/" "$(grep -v '^#' "$SRC/files/keep.d")"
eq "пин в git пуст до выпуска с tar.gz" "" "$(sed -n 's/^STVOR_AGENT_PIN_VERSION=//p' "$SRC/files/pin.env")"

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
