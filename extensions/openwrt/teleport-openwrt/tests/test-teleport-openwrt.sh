#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# H-тест teleport-openwrt: слой procd поверх общего ядра (lib/teleport-core.sh,
# в staged-копии расширения — files/teleport-core.sh) на подменённом корне
# (tools/hooktest.sh). procd, ubus, jsonfilter, logread, uname, curl, cream —
# подставные: служба /etc/init.d/teleport пишет журнал вызовов и «поднимает» агента
# (pid в ответе `ubus call service list`); агент по $FAKE/agent регистрируется
# (host_uuid), отказывает (строка в logread) или молчит. Отдельный раздел гоняет
# действия с набором команд busybox OpenWrt (без stat, install, hostname, paste) —
# заглушки слоя. Настоящий busybox, uci и cream — L (make test-openwrt).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(dirname "$HERE")"
REPO="$(cd "$SRC/../../.." && pwd)"
DEB="$REPO/extensions/debian/teleport"
# shellcheck source=../../../../tools/hooktest.sh
. "$HERE/../../../../tools/hooktest.sh"
ht_init

SECRET='abcdefgh1-join-token'
PROXY=teleport.example.org:443

# make_set <version>: the set teleport-v<v>-openwrt-<arch>-bin.tar.gz in $FAKE/set;
# its teleport prints the version and logs whether LD_PRELOAD reached it.
make_set(){
    local d; d="$(mktemp -d "$HT_TMP/set.XXXXXX")"
    mkdir -p "$d/teleport/lib"
    printf '#!/usr/bin/env bash\necho "${LD_PRELOAD+set}" >> "${CREAM_ROOT:-/nonexistent}/fake/preload.log" 2>/dev/null\necho "Teleport v%s git:fake go1.25"\n' "$1" > "$d/teleport/teleport"
    printf '#!/bin/sh\necho fdpass\n' > "$d/teleport/fdpass-teleport"
    echo glibc > "$d/teleport/lib/libc.so.6"
    chmod 0755 "$d/teleport/teleport" "$d/teleport/fdpass-teleport"
    tar -czf "$FAKE/set" -C "$d" teleport
    SET_SHA="$(sha256sum "$FAKE/set" | cut -d' ' -f1)"
}

setup(){
    ht_root "$SRC"
    S="$ROOT/var/lib/cream/ext/teleport-openwrt"
    D="$ROOT/opt/teleport/data"
    Y="$ROOT/etc/teleport.yaml"
    mkdir -p "$ROOT/etc/init.d" "$ROOT/var/run" "$ROOT/usr/bin"
    echo x86_64 > "$FAKE/uname"
    echo 7 > "$FAKE/net"
    echo join > "$FAKE/agent"
    echo 100 > "$FAKE/pid"
    ht_fake uname 'cat "$FAKE/uname"'
    ht_fake hostname 'echo owrt-lab'
    ht_fake sleep
    # curl: -o downloads the set; else /webapi/find by $FAKE/net (up — a proxy).
    ht_fake curl 'out=""; prev=""
for a in "$@"; do [[ "$prev" == -o ]] && out="$a"; prev="$a"; done
if [[ -n "$out" ]]; then [[ -f "$FAKE/set" ]] || exit 22; cp "$FAKE/set" "$out"; exit 0; fi
net="$(cat "$FAKE/net")"
[[ "$net" == up ]] && { echo "{\"server_version\":\"18.10.0\"}"; exit 0; }
exit "$net"'
    # cream set: the pairs into the domain file (the grammar of cream).
    ht_fake cream '[[ "$1" == set ]] || exit 0
shift; while [[ "$1" == --* ]]; do shift; done; shift
f="$CREAM_CONFIG_FILE"; touch "$f"
for p in "$@"; do
    k="${p%%=*}"; v="${p#*=}"; v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
    sed -i "/^$k=/d" "$f"; printf "%s=\"%s\"\n" "$k" "$v" >> "$f"
done'
    # ubus: the service list from $FAKE/ubus.list; delete — the agent stops.
    ht_fake ubus 'case "$*" in
"call service list"*) [[ -f "$FAKE/ubus.list" ]] && cat "$FAKE/ubus.list" || echo "{}" ;;
"call service delete"*) rm -f "$FAKE/ubus.list" ;;
*) exit 1 ;;
esac'
    ht_fake jsonfilter 'python3 -c "
import json, sys
a = sys.argv[1:]
data = json.loads(a[a.index(\"-s\") + 1])
for k in a[a.index(\"-e\") + 1].lstrip(\"@.\").split(\".\"):
    data = data.get(k) if isinstance(data, dict) else None
if data is None: sys.exit(1)
print(str(data).lower() if isinstance(data, bool) else data)
" "$@"'
    ht_fake logread 'cat "$FAKE/logread" 2>/dev/null'
    # The service: start/restart bring the agent up when it is enabled or started.
    cat > "$ROOT/etc/init.d/teleport" <<EOF
#!/usr/bin/env bash
FAKE="$FAKE"; S="$S"; R="$ROOT"
EOF
    cat >> "$ROOT/etc/init.d/teleport" <<'EOF'
echo "init $*" >> "$FAKE/calls"
up(){
    [[ -e "$S/agent-enabled" || -e "$R/var/run/teleport.start" ]] || return 0
    [[ "$1" == restart || ! -f "$FAKE/ubus.list" ]] || return 0
    p=$(( $(cat "$FAKE/pid") + 1 )); echo "$p" > "$FAKE/pid"
    [[ -e "$FAKE/agent.dead" ]] || printf '{"teleport":{"instances":{"teleport":{"running":true,"pid":%s}}}}\n' "$p" > "$FAKE/ubus.list"
    case "$(cat "$FAKE/agent")" in
        join) mkdir -p "$R/opt/teleport/data"; echo 55555555-6666 > "$R/opt/teleport/data/host_uuid" ;;
        refuse) printf 'Thu Oct 22 10:00:00 2026 [%s.123] daemon.err teleport[%s]: Failed to establish connection to cluster. error:[token expired or not found]\n' "$(date +%s)" "$p" >> "$FAKE/logread" ;;
    esac
}
case "$1" in
    start) up start ;;
    restart) [[ -e "$FAKE/restart.stuck" ]] || up restart ;;
    stop) rm -f "$FAKE/ubus.list" ;;
esac
exit 0
EOF
    chmod 0755 "$ROOT/etc/init.d/teleport"
    printf 'root:x:0:0:root:/root:/bin/ash\ndaemon:*:1:1:daemon:/var:/bin/false\nnobody:*:65534:65534:nobody:/var:/bin/false\n' > "$ROOT/etc/passwd"
    chmod -R go-w "$ROOT"
}
procd_up(){ mkdir -p "$ROOT/var/run/ubus"; : > "$ROOT/var/run/ubus/ubus.sock"; }
# act <action> [args…] [<<< stdin]: an action as `cream run` gives it, stdin passed.
act(){
    local a="$1"; shift
    local -a envv=()
    mapfile -d '' -t envv < <(_ht_env)
    ( cd "$HT_EXT" && umask 022 && exec env -i "${envv[@]}" LD_PRELOAD= "$HT_EXT/actions/$a" "$@" ) > "$ROOT/out" 2>&1
}
installed(){
    make_set 18.10.0
    ht_hook install TELEPORT_SHA256="$SET_SHA" TELEPORT_MIRROR=https://stvor.example.org/dist/teleport
}
join_line(){ act join TELEPORT_PROXY="$PROXY" TELEPORT_REGISTRATION_SECRET=- TELEPORT_ENV=dev "$@" <<< "$SECRET"; }
json(){ grep -E '^\{' "$ROOT/out" | tail -n1; }
calls(){ grep -E "^$1" "$FAKE/calls" | tr '\n' '|'; }

echo "== манифест: те же ключи и действия, что у debian/teleport =="
cmp_out="$(python3 - "$SRC/extension.yaml" "$DEB/extension.yaml" <<'PY'
import sys, yaml
o = yaml.safe_load(open(sys.argv[1])); d = yaml.safe_load(open(sys.argv[2]))
bad = []
ok = lambda k, v: (k, {x: v.get(x) for x in ("type", "default", "empty", "readonly", "scope", "secret")})
if [ok(k, v) for k, v in o["config"]["keys"].items()] != [ok(k, v) for k, v in d["config"]["keys"].items()]:
    bad.append("config.keys")
if list(o["actions"]) != list(d["actions"]):
    bad.append("actions")
for a in o["actions"]:
    for f in ("lock", "output", "phases", "args", "stdin", "params"):
        if o["actions"][a].get(f) != d["actions"][a].get(f):
            bad.append(f"actions.{a}.{f}")
for f in ("provides", "conflicts", "targets"):
    if o.get(f) != d.get(f): bad.append(f)
p = o["platform"]
if p != {"family": "openwrt", "arch": ["amd64", "arm64"], "os": [{"id": "openwrt", "version": ">=25.12"}],
         "commands": ["bash", "curl", "tar", "sha256sum"]}: bad.append("platform")
if o["cream"] != ">=1.3.0": bad.append("cream")
if "configure" in o.get("hooks", {}): bad.append("configure")
files = {f["src"]: (f["dst"], f.get("mode")) for f in o["files"]}
if files != {"files/teleport-core.sh": ("/usr/lib/teleport-openwrt/teleport-core.sh", "0644"),
             "files/teleport.init": ("/etc/init.d/teleport", "0755"),
             "files/keep.d": ("/lib/upgrade/keep.d/teleport", "0644")}: bad.append("files")
print(" ".join(bad))
PY
)"
eq "манифест сверен с debian/teleport" "" "$cmp_out"
for a in "$SRC"/actions/* "$SRC"/hooks/*; do
    check "$(basename "$a") — вход в files/teleport.sh" grep -q 'files/teleport.sh" ' "$a"
done
# The types of the core equal the manifest (as in debian/teleport/tests).
while IFS= read -r line; do
    key="${line%%]=*}"; key="${key#*[}"; t="${line#*]=}"; t="${t#\'}"; t="${t%\'}"
    if [[ "$t" == bool ]]; then
        check "тип $key — bool" grep -qE "^    $key: \{type: bool" "$SRC/extension.yaml"
    else
        check "тип $key совпадает с ядром" grep -qF "$key: {type: '$t'" "$SRC/extension.yaml"
    fi
done < <(sed -n '/^declare -A KEY_TYPE=(/,/^)/p' "$REPO/lib/teleport-core.sh" | grep -E '^\s+\[TELEPORT_')
check "потребитель ядра" grep -qx 'openwrt/teleport-openwrt' "$REPO/lib/teleport-core.consumers"
check_not "копии ядра в git нет" test -e "$SRC/files/teleport-core.sh"

echo "== init-скрипт procd: без stdout/stderr, TMPDIR на диске, respawn =="
I="$SRC/files/teleport.init"
check "rc.common" grep -qx '#!/bin/sh /etc/rc.common' "$I"
check "USE_PROCD=1" grep -qx 'USE_PROCD=1' "$I"
check "START=95" grep -qx 'START=95' "$I"
check_not "нет stdout/stderr у procd (LD_PRELOAD musl)" grep -qE '^[^#]*procd_set_param[[:space:]]+(stdout|stderr)' "$I"
check "TMPDIR=/opt/teleport/tmp" grep -q 'procd_set_param env TMPDIR="$TP_HOME/tmp"' "$I"
check "состояние cream на OpenWrt" grep -qx 'TP_STATE=/opt/cream/var/ext/teleport-openwrt' "$I"
check "render через cream до старта" grep -q '/usr/bin/cream run teleport-openwrt render' "$I"
# start_service with recording stubs of procd, the paths moved under a scratch root.
fn="$HT_TMP/init"; mkdir -p "$fn/st" "$fn/run"
sed -e "s|^TP_STATE=.*|TP_STATE=$fn/st|" -e "s|/var/run/|$fn/run/|g" -e 's|/usr/bin/cream|cream_stub|' "$I" > "$fn/init.sh"
init_run(){
    sh -c '. "$1"; procd_open_instance(){ echo "open $1"; }; procd_set_param(){ echo "param $*"; }
           procd_close_instance(){ echo close; }; cream_stub(){ echo "cream $*"; }; start_service' sh "$fn/init.sh"
}
eq "ни включён, ни ждёт — экземпляров нет" "" "$(init_run)"
: > "$fn/st/agent-enabled"
out="$(init_run)"
check "включён — экземпляр teleport" grep -qx 'open teleport' <<< "$out"
check "включён — render до старта" grep -qx 'cream run teleport-openwrt render' <<< "$out"
check "команда — бинарь набора с /etc/teleport.yaml" grep -qx 'param command /opt/teleport/bin/teleport start --config /etc/teleport.yaml' <<< "$out"
check "respawn без предела попыток" grep -qx 'param respawn 3600 5 0' <<< "$out"
check "TMPDIR в окружении" grep -qx 'param env TMPDIR=/opt/teleport/tmp' <<< "$out"
check_not "нет stdout/stderr" grep -qE '^param (stdout|stderr)' <<< "$out"
check "время старта записано" test -s "$fn/run/teleport.started"
rm "$fn/st/agent-enabled"; : > "$fn/run/teleport.start"
check "запущен сейчас — экземпляр teleport" grep -qx 'open teleport' <<< "$(init_run)"
rm "$fn/run/teleport.start"; : > "$fn/st/join-pending"
out="$(init_run)"
check "ждёт join — экземпляр join" grep -qx 'open join' <<< "$out"
check_not "ждёт join — агента нет" grep -qx 'open teleport' <<< "$out"
check "повтор — join-retry через cream с ожиданием блокировки" grep -q 'cream_stub run --lock-timeout 6m teleport-openwrt join-retry' <<< "$out"
check_not "повтор без respawn (заканчивается сам)" grep -q '^param respawn' <<< "$out"
# The loop ends once the marker is gone.
loop="$(grep -o "'while .*done'" "$I" | tr -d "'")"
eq "цикл повтора — пока есть маркер" 'while [ -e "$1" ]; do /usr/bin/cream run --lock-timeout 6m teleport-openwrt join-retry; sleep 60; done' "$loop"

echo "== keep.d: только состояние (Р4) =="
eq "keep.d — data и маркер" "/opt/teleport/data/|/opt/teleport/.cream-owned|" "$(grep -v '^#' "$SRC/files/keep.d" | tr '\n' '|')"

echo "== install: набор openwrt-<arch> с зеркала по sha256 =="
setup
installed; eq "install — 0" 0 "$?"
check "url — набор openwrt-amd64 по раскладке зеркала" \
    grep -q 'https://stvor.example.org/dist/teleport/binaries/teleport/18.10.0/teleport-v18.10.0-openwrt-amd64-bin.tar.gz' "$FAKE/curl.argv"
check "бинарь в /opt/teleport/bin" test -x "$ROOT/opt/teleport/bin/teleport"
check "fdpass-teleport в /opt/teleport/bin" test -x "$ROOT/opt/teleport/bin/fdpass-teleport"
check "glibc-рантайм в /opt/teleport/lib" test -f "$ROOT/opt/teleport/lib/libc.so.6"
eq "ссылка /usr/bin/teleport" /opt/teleport/bin/teleport "$(readlink "$ROOT/usr/bin/teleport")"
check "маркер владения" test -e "$ROOT/opt/teleport/.cream-owned"
eq "data_dir 0750" 750 "$(stat -c %a "$D")"
eq "TMPDIR узла 0700" 700 "$(stat -c %a "$ROOT/opt/teleport/tmp")"
check "служба включена (rc.d)" grep -qx 'init enable' "$FAKE/calls"
check_not "install не стартует агента" grep -qE '^init (start|restart)' "$FAKE/calls"
check_not "черновика скачивания не осталось" bash -c 'compgen -G "$1/opt/teleport/teleport-install.*" >/dev/null' _ "$ROOT"
check "подсказка называет teleport-openwrt" grep -q 'cream run teleport-openwrt join' "$ROOT/out"
check_not "LD_PRELOAD до бинаря не дошёл" grep -qx set "$ROOT/fake/preload.log"
: > "$FAKE/curl.argv"
installed; eq "повторный install — 0" 0 "$?"
check "та же версия — без скачивания" test ! -s "$FAKE/curl.argv"
check "та же версия — сказано" grep -q 'уже установлен' "$ROOT/out"

setup
echo aarch64 > "$FAKE/uname"
installed
check "aarch64 — набор openwrt-arm64" grep -q 'openwrt-arm64-bin.tar.gz' "$FAKE/curl.argv"
setup
echo mips > "$FAKE/uname"
installed; eq "mips — 1" 1 "$?"
check "mips — не поддерживается" grep -q 'не поддерживается' "$ROOT/out"
setup
make_set 18.10.0
ht_hook install TELEPORT_MIRROR=https://stvor.example.org/dist/teleport; eq "без sha256 — 1" 1 "$?"
check "без sha256 — причина" grep -q 'TELEPORT_SHA256' "$ROOT/out"
check_not "без sha256 — ничего не скачано" test -s "$FAKE/curl.argv"
setup
make_set 18.10.0
ht_hook install TELEPORT_SHA256="$SET_SHA"; eq "без зеркала и файла — 1" 1 "$?"
check "без зеркала — зеркало Stvor" grep -q 'Stvor' "$ROOT/out"
setup
make_set 18.10.0
ht_hook install TELEPORT_SHA256="$(printf '%064d' 0)" TELEPORT_MIRROR=https://stvor.example.org/x; eq "чужой sha256 — 1" 1 "$?"
check_not "чужой sha256 — бинаря нет" test -e "$ROOT/opt/teleport/bin/teleport"
setup
make_set 18.10.0
cp "$FAKE/set" "$HT_TMP/local-set.tar.gz"
ht_hook install TELEPORT_SHA256="$SET_SHA" TELEPORT_TARBALL="$HT_TMP/local-set.tar.gz"; eq "локальный набор — 0" 0 "$?"
check "локальный набор — без сети" test ! -s "$FAKE/curl.argv"
check "локальный набор — файл оператора цел" test -f "$HT_TMP/local-set.tar.gz"
setup
mkdir -p "$ROOT/opt/teleport/bin"; printf '#!/bin/sh\necho "Teleport v17.0.0"\n' > "$ROOT/opt/teleport/bin/teleport"; chmod +x "$ROOT/opt/teleport/bin/teleport"
installed; eq "Teleport без маркера — 1" 1 "$?"
check "Teleport без маркера — «не от cream»" grep -q 'Teleport не от cream' "$ROOT/out"
eq "чужой бинарь не тронут" "Teleport v17.0.0" "$("$ROOT/opt/teleport/bin/teleport")"
setup
mkdir -p "$D"; echo 1111 > "$D/host_uuid"; : > "$ROOT/opt/teleport/.cream-owned"
make_set 18.10.0
HT_PHASE=build ht_hook install TELEPORT_SHA256="$SET_SHA" TELEPORT_MIRROR=https://m.example.org; eq "сборка с регистрацией — 1" 1 "$?"
# After sysupgrade: keep.d kept data and the marker — install takes them as its own.
setup
mkdir -p "$D"; echo 1111 > "$D/host_uuid"; : > "$ROOT/opt/teleport/.cream-owned"
installed; eq "после sysupgrade (data + маркер) — 0" 0 "$?"
eq "host_uuid сохранён" 1111 "$(cat "$D/host_uuid")"

echo "== render: teleport.yaml OpenWrt (§3) =="
setup; installed
join_line TELEPORT_DEFER=1; eq "join отложенный — 0" 0 "$?"
eq "join отложенный — JSON" deferred "$(json | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])')"
check "подсказка join-retry называет teleport-openwrt" grep -q 'cream run teleport-openwrt join-retry' "$ROOT/out"
check "data_dir /opt/teleport/data" grep -qx '  data_dir: /opt/teleport/data' "$Y"
check "log.output syslog" grep -qx '    output: syslog' "$Y"
ssh="$(sed -n '/^ssh_service:/,/^[a-z]/p' "$Y")"
eq "pam выключен в ssh_service" "    enabled: false" "$(sed -n '/^  pam:$/{n;p;}' <<< "$ssh")"
eq "enhanced_recording выключен в ssh_service" "    enabled: false" "$(sed -n '/^  enhanced_recording:$/{n;p;}' <<< "$ssh")"
check "шапка — render teleport-openwrt" grep -qx '# Сгенерирован cream run teleport-openwrt render из /etc/cream/teleport-openwrt. Не править:' "$Y"
check "os_logins — files/os-logins дерева" grep -q "command: \[\"${HT_EXT#"$ROOT"}/files/os-logins\"\]" "$Y"
check "nodename — hostname" grep -qx '  nodename: "owrt-lab"' "$Y"
eq "teleport.yaml 0600" 600 "$(stat -c %a "$Y")"
eq "os-logins: root, без системных" root "$(CREAM_ROOT="$ROOT" "$SRC/files/os-logins")"

echo "== join: procd работает, прокси отвечает — регистрация =="
setup; installed; procd_up
echo up > "$FAKE/net"
join_line; eq "join — 0" 0 "$?"
eq "join — registered" registered "$(json | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])')"
check "агент стартован службой" grep -qx 'init start' "$FAKE/calls"
check "включён на загрузку" test -e "$S/agent-enabled"
check "секрет стёрт" test ! -e "$S/registration-secret"
check_not "LD_PRELOAD до бинаря не дошёл" grep -qx set "$ROOT/fake/preload.log"
act managed-status; eq "managed-status — 0" 0 "$?"
check "managed-status: joined и active" grep -q '"joined":true,"active":true' <<< "$(json)"
act status
check "status: служба procd активна и включена" grep -q 'Служба teleport (procd): active, enabled' "$ROOT/out"
# Idempotent rerun: the agent restarts with the knobs, no secret needed.
: > "$FAKE/calls"
act join TELEPORT_PROXY="$PROXY" TELEPORT_ENV=prod
eq "повтор join — registered" registered "$(json | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])')"
check "повтор join — перезапуск агента" grep -qx 'init restart' "$FAKE/calls"

echo "== join: сети нет — ждёт, повтор — экземпляр join =="
setup; installed; procd_up
join_line; eq "join без сети — 0" 0 "$?"
eq "join без сети — pending" pending "$(json | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])')"
check "маркер ожидания" test -e "$S/join-pending"
check "повтор включён — служба пересчитана" grep -qx 'init start' "$FAKE/calls"
check_not "агент не включён" test -e "$S/agent-enabled"
check "подсказка: статус своего расширения" grep -q 'Ход — cream run teleport-openwrt status' "$ROOT/out"
act status
check "status: повтор — экземпляр join" grep -q 'экземпляр join службы /etc/init.d/teleport' "$ROOT/out"
# The tick: the network is back, the agent registers.
echo up > "$FAKE/net"
: > "$FAKE/calls"
act join-retry; eq "тик — 0" 0 "$?"
check "тик: маркер снят — цикл повтора кончится сам" test ! -e "$S/join-pending"
check "тик: агент включён" test -e "$S/agent-enabled"
check_not "тик не останавливает службу (он внутри неё)" grep -qE '^init (stop|restart)|^ubus call service delete' "$FAKE/calls"

echo "== join: отказ кластера — из logread с отсечкой по времени =="
setup; installed; procd_up
echo up > "$FAKE/net"; echo refuse > "$FAKE/agent"
# An old refusal before this join is not this join's answer.
printf 'Thu Oct 22 09:00:00 2026 [1000.1] daemon.err teleport[3]: Can not join the cluster, the token is expired or not found.\n' > "$FAKE/logread"
join_line; eq "отказ — 1" 1 "$?"
eq "отказ — refused" refused "$(json | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])')"
check "отказ — агент снят отдельным экземпляром" grep -q 'ubus call service delete {"name":"teleport","instance":"teleport"}' "$FAKE/calls"
check "отказ — журнал logread -t" grep -q 'logread -t -e teleport' "$FAKE/calls"
check "отказ — причина" grep -q 'токен регистрации не найден' "$ROOT/out"
check_not "отказ — не включён" test -e "$S/agent-enabled"

echo "== журнал: решение только по строкам процесса службы (тег teleport[<pid экземпляра>]) =="
# Any local process can write to syslog (logger -t teleport …): a refusal from
# another pid, or the tag inside the message, is no answer of the cluster.
spoof(){
    local now; now="$(date +%s)"
    {
        printf 'Thu Oct 22 10:00:00 2026 [%s.1] user.notice teleport[1]: Can not join the cluster, the token is expired or not found.\n' "$now"
        printf 'Thu Oct 22 10:00:00 2026 [%s.1] user.notice teleport: Can not join the cluster, the token is expired or not found.\n' "$now"
        printf 'Thu Oct 22 10:00:00 2026 [%s.1] user.notice evil[7]: teleport[%s]: Can not join the cluster, the token is expired or not found.\n' "$now" "$1"
    } >> "$FAKE/logread"
}
setup; installed; procd_up
echo up > "$FAKE/net"; echo hang > "$FAKE/agent"
spoof 101
join_line; eq "чужие строки — не отказ (0)" 0 "$?"
eq "чужие строки — pending, не refused" pending "$(json | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])')"
check_not "чужие строки — повтор не снят" test -e "$S/join-refused"
check "секрет цел для повтора" test -s "$S/registration-secret"
# The same refusal from the pid of the instance is the answer.
setup; installed; procd_up
echo up > "$FAKE/net"; echo hang > "$FAKE/agent"
printf 'Thu Oct 22 10:00:00 2026 [%s.1] daemon.err teleport[101]: Can not join the cluster, the token is expired or not found.\n' "$(date +%s)" >> "$FAKE/logread"
join_line; eq "строка процесса службы — отказ (1)" 1 "$?"
eq "строка процесса службы — refused" refused "$(json | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])')"

echo "== set-managed: перезапуск с подтверждением нового pid =="
setup; installed; procd_up
echo up > "$FAKE/net"; join_line
: > "$FAKE/calls"
act set-managed env=prod space=sp-1; eq "set-managed — 0" 0 "$?"
check "set-managed — applied" grep -q '"result":"applied"' <<< "$(json)"
check "set-managed — restart службы" grep -qx 'init restart' "$FAKE/calls"
check "метки в teleport.yaml" grep -qx '    "space": "sp-1"' "$Y"
act set-managed env=prod space=sp-1
check "те же метки — unchanged" grep -q '"result":"unchanged"' <<< "$(json)"
: > "$FAKE/restart.stuck"
act set-managed env=prod space=sp-2; eq "не подтвердился — 1" 1 "$?"
check "не подтвердился — unconfirmed" grep -q '"result":"unconfirmed"' <<< "$(json)"
check "маркер managed-pending" test -e "$S/managed-pending"

echo "== reload-apps, apply, hup =="
setup; installed; procd_up
echo up > "$FAKE/net"; join_line
: > "$FAKE/calls"
act reload-apps; eq "reload-apps без изменений — 0" 0 "$?"
check_not "без изменений — без перезапуска" grep -qx 'init restart' "$FAKE/calls"
printf 'NAME=web\nURI=http://127.0.0.1:8080\n' > "$ROOT/etc/cream/teleport-openwrt/apps.d/web.conf"
chmod 0644 "$ROOT/etc/cream/teleport-openwrt/apps.d/web.conf"
act reload-apps; eq "reload-apps с новым приложением — 0" 0 "$?"
check "новое приложение — перезапуск" grep -qx 'init restart' "$FAKE/calls"
check "приложение в teleport.yaml" grep -q 'name: "web-owrt-lab"' "$Y"
: > "$FAKE/calls"
ht_hook apply; eq "apply — 0" 0 "$?"
sleep 0.3
check "apply — перезапуск фоном" grep -qx 'init restart' "$FAKE/calls"
check "apply — в хуке перезапуск только фоном" grep -qE '"\$INIT_SCRIPT" restart >/dev/null 2>&1 &$' "$SRC/files/teleport.sh"
act hup; eq "hup — 2" 2 "$?"
check "hup — подсказка reload-apps" grep -q 'cream run teleport-openwrt reload-apps' "$ROOT/out"

echo "== remove: служба выключена, набор и состояние стёрты =="
setup; installed; procd_up
echo up > "$FAKE/net"; join_line
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check "remove — служба остановлена и выключена" grep -qx 'init disable' "$FAKE/calls"
check_not "remove — /opt/teleport нет" test -e "$ROOT/opt/teleport"
check_not "remove — ссылки нет" test -L "$ROOT/usr/bin/teleport"
check_not "remove — состояния нет" test -e "$S"
check_not "remove — teleport.yaml нет" test -e "$Y"
# Not ours: a Teleport without the marker stays.
setup
mkdir -p "$ROOT/opt/teleport/bin"; : > "$ROOT/opt/teleport/bin/teleport"
ht_hook remove
check "remove — чужой /opt/teleport цел" test -e "$ROOT/opt/teleport/bin/teleport"

echo "== набор команд busybox OpenWrt: без stat, install, hostname, paste =="
setup; installed
BB="$ROOT/bb"; mkdir -p "$BB"
for c in bash env sh cat cp mv rm mkdir chmod ls ln readlink find grep sed awk cut tr sort head tail \
         wc mktemp date sha256sum cmp id dirname basename touch tar gzip sleep uname python3 cream curl; do
    p="$(PATH="$ROOT/bin:$PATH" command -v "$c")" && ln -sf "$p" "$BB/$c"
done
bbrun(){
    ( cd "$HT_EXT" && exec env -i PATH="$BB" LANG=C.UTF-8 CREAM_ROOT="$ROOT" CREAM_EXT_DIR="$HT_EXT" CREAM_PHASE=live \
        CREAM_ETC_DIR="$ROOT/etc/cream/teleport-openwrt" CREAM_STATE_DIR="$S" \
        CREAM_CONFIG_FILE="$ROOT/etc/cream/teleport-openwrt/config" "$HT_EXT/actions/$1" "${@:2}" ) > "$ROOT/out" 2>&1
}
for c in stat install hostname paste; do check_not "в наборе нет $c" test -e "$BB/$c"; done
printf 'NAME=web\nURI=http://127.0.0.1:8080\n' > "$ROOT/etc/cream/teleport-openwrt/apps.d/web.conf"
printf 'NAME=wide\nURI=http://127.0.0.1:9090\n' > "$ROOT/etc/cream/teleport-openwrt/apps.d/wide.conf"
chmod 0644 "$ROOT/etc/cream/teleport-openwrt/apps.d/web.conf"; chmod 0666 "$ROOT/etc/cream/teleport-openwrt/apps.d/wide.conf"
printf 'TELEPORT_PROXY=teleport.example.org\nTELEPORT_NODENAME=bb-node\nTELEPORT_MANAGED_LABELS="space=sp-1 env=dev"\n' > "$ROOT/etc/cream/teleport-openwrt/config"
bbrun render; eq "render без stat/install — 0" 0 "$?"
check "приложение 0644 опубликовано (stat %u/%a)" grep -q 'name: "web-bb-node"' "$Y"
check_not "приложение 0666 пропущено (запись всем)" grep -q 'wide-bb-node' "$Y"
check "пропуск 0666 назван по правам" grep -q 'права 666' "$ROOT/out"
eq "teleport.yaml 0600" 600 "$(stat -c %a "$Y")"
bbrun managed-status; eq "managed-status — 0" 0 "$?"
check "управляемые метки из домена" grep -q '"managed":{"space":"sp-1","env":"dev"}' "$ROOT/out"
bbrun set-managed space=sp-2 env=dev; eq "set-managed без paste — 0" 0 "$?"
check "set-managed — без init: deferred" grep -q '"result":"deferred"' "$ROOT/out"
eq "отсортированный набор в домене" 'TELEPORT_MANAGED_LABELS="env=dev space=sp-2"' "$(grep '^TELEPORT_MANAGED_LABELS=' "$ROOT/etc/cream/teleport-openwrt/config")"
sed -i '/^TELEPORT_NODENAME=/d' "$ROOT/etc/cream/teleport-openwrt/config"
bbrun render
host="$(cut -d. -f1 /proc/sys/kernel/hostname | tr '[:upper:]' '[:lower:]')"
check "без hostname — имя ядра" grep -qx "  nodename: \"$host\"" "$Y"
rm -f "$ROOT/etc/cream/teleport-openwrt/apps.d/wide.conf"
bbrun join TELEPORT_PROXY="$PROXY" TELEPORT_REGISTRATION_SECRET=- TELEPORT_DEFER=1 TELEPORT_NODENAME=bb-node <<< "$SECRET"
eq "join без install — 0" 0 "$?"
eq "состояние 0700 (install -d -m)" 700 "$(stat -c %a "$S")"
eq "секрет 0600" 600 "$(stat -c %a "$S/registration-secret")"

ht_done
