#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# H-тест teleport-openwrt: слой procd поверх общего ядра (lib/teleport-core.sh,
# в staged-копии расширения — files/teleport-core.sh) на подменённом корне
# (tools/hooktest.sh). procd, ubus, jsonfilter, logread, uname, curl, cream —
# подставные: служба /etc/init.d/teleport пишет журнал вызовов и «поднимает» агента
# (pid в ответе `ubus call service list`); агент по $FAKE/agent регистрируется
# (host_uuid), отказывает (строка в своём журнале /opt/teleport/log/teleport.log)
# или молчит; строки, которые любой процесс пишет в syslog (`logger`), решений не меняют. Отдельный раздел гоняет
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

# make_set <version> [<build>]: the set teleport-v<v>-openwrt-<arch>-bin.tar.gz in
# $FAKE/set; its teleport prints the version and logs whether LD_PRELOAD reached
# it. <build> (a rebuild of the fork: stvor.3, stvor.4) is a comment line of the
# binary — the same version, another sum.
make_set(){
    local d; d="$(mktemp -d "$HT_TMP/set.XXXXXX")"
    mkdir -p "$d/teleport/lib"
    printf '#!/usr/bin/env bash\necho "${LD_PRELOAD+set}" >> "${CREAM_ROOT:-/nonexistent}/fake/preload.log" 2>/dev/null\necho "Teleport v%s git:fake go1.25"\n' "$1" > "$d/teleport/teleport"
    [[ -z "${2:-}" ]] || echo "# build $2" >> "$d/teleport/teleport"
    printf '#!/bin/sh\necho fdpass\n' > "$d/teleport/fdpass-teleport"
    echo glibc > "$d/teleport/lib/libc.so.6"
    chmod 0755 "$d/teleport/teleport" "$d/teleport/fdpass-teleport"
    # Reproducible: the same set made twice has the same sum (mtimes and the gzip
    # stamp would differ across a second boundary on a loaded host).
    tar --mtime=@0 --sort=name --owner=0 --group=0 --numeric-owner -cf - -C "$d" teleport | gzip -n > "$FAKE/set"
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
    # curl: -o downloads the set (-C - continues the partial file; while
    # $FAKE/cuts > 0 a call writes half of what is left and fails as a cut HTTP/2
    # stream, 92); else /webapi/find by $FAKE/net (up — a proxy).
    ht_fake curl '[[ "${1:-}" == --version ]] && { echo "curl 8.12.1 (x86_64-openwrt-linux-musl)"; exit 0; }
out=""; prev=""
for a in "$@"; do [[ "$prev" == -o ]] && out="$a"; prev="$a"; done
if [[ -n "$out" ]]; then
    [[ -f "$FAKE/set" ]] || exit 22
    [[ " $* " == *" -C - "* && -f "$out" ]] || : > "$out"
    have="$(stat -c %s "$out")"; total="$(stat -c %s "$FAKE/set")"
    cuts="$(cat "$FAKE/cuts" 2>/dev/null || echo 0)"
    if (( cuts > 0 )); then
        echo $((cuts - 1)) > "$FAKE/cuts"
        tail -c +$((have + 1)) "$FAKE/set" | head -c $(( (total - have) / 2 )) >> "$out"; exit 92
    fi
    tail -c +$((have + 1)) "$FAKE/set" >> "$out"; exit 0
fi
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
        refuse) printf '%s INFO [PROC:1] Failed to establish connection to cluster. error:[token expired or not found]\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" >> "$R/opt/teleport/log/teleport.log" ;;
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
sed -e "s|^TP_STATE=.*|TP_STATE=$fn/st|" -e "s|^TP_LOG=.*|TP_LOG=$fn/home/log/teleport.log|" \
    -e "s|/var/run/|$fn/run/|g" -e 's|/usr/bin/cream|cream_stub|' "$I" > "$fn/init.sh"
# procd_running: the agent runs when $fn/running exists.
init_run(){
    FN="$fn" sh -c '. "$1"; procd_open_instance(){ echo "open $1"; }; procd_set_param(){ echo "param $*"; }
           procd_close_instance(){ echo close; }; cream_stub(){ echo "cream $*"; }
           procd_running(){ [ -e "$FN/running" ]; }; start_service' sh "$fn/init.sh"
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
eq "журнал: каталог 0700" 700 "$(stat -c %a "$fn/home/log")"
eq "журнал: файл 0600" 600 "$(stat -c %a "$fn/home/log/teleport.log")"
check "log.output — файл, не syslog" grep -q 'TP_LOG=$TP_HOME/log/teleport.log' "$I"
out="$(init_run)"
check "рядом с агентом — экземпляр logcap" grep -qx 'open logcap' <<< "$out"
check "logcap — раз в 10 мин зовёт log_cap службы" \
    grep -qx 'param command /bin/sh -c while sleep 600; do /etc/init.d/teleport log_cap; done' <<< "$out"
check "log_cap — команда rc.common" grep -qx 'EXTRA_COMMANDS="log_cap"' "$I"
# The limit holds under a running writer: the agent appends (O_APPEND, as
# Teleport opens its log); copy-truncate leaves no hole and keeps the old text in .1.
log_cap_run(){ FN="$fn" sh -c '. "$1"; log_cap' sh "$fn/init.sh"; }
L="$fn/home/log/teleport.log"
exec 5>>"$L"
head -c 1048577 /dev/zero | tr '\0' x >&5
log_cap_run
eq "работающий писатель — копия в .1" 1048577 "$(wc -c < "$L.1")"
echo "after cap" >&5
eq "работающий писатель — пишет с нового конца, без дыры" 10 "$(wc -c < "$L")"
eq "работающий писатель — текст после усечения" "after cap" "$(cat "$L")"
head -c 1048566 /dev/zero | tr '\0' y >&5
log_cap_run
eq "ровно предел — не трогается" 1048576 "$(wc -c < "$L")"
exec 5>&-
eq "старый журнал 0600" 600 "$(stat -c %a "$L.1")"
eq "журнал 0600" 600 "$(stat -c %a "$L")"
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

echo "== keep.d: идентичность, флаг и домен (Р4, решение владельца 2026-10-23) =="
eq "keep.d — data, маркер, флаг agent-enabled, pin набора, config и apps.d домена" \
    "/opt/teleport/data/|/opt/teleport/.cream-owned|/opt/cream/var/ext/teleport-openwrt/agent-enabled|/opt/cream/var/ext/teleport-openwrt/installed-pin|/etc/cream/teleport-openwrt/config|/etc/cream/teleport-openwrt/apps.d/|" \
    "$(grep -v '^#' "$SRC/files/keep.d" | tr '\n' '|')"
# Restored paths are on disk before cream installs again: a file that an extension
# lays by `files` there would be refused (conflict.file_unowned, cream ruling Р21).
check "keep.d не пересекается с files расширений OpenWrt" python3 - "$SRC/files/keep.d" "$REPO/extensions/openwrt" <<'PY2'
import pathlib, sys, yaml
keep = [l.strip() for l in open(sys.argv[1]) if l.strip() and not l.startswith("#")]
bad = []
for m in pathlib.Path(sys.argv[2]).glob("*/extension.yaml"):
    for f in yaml.safe_load(m.read_text()).get("files") or []:
        if any(f["dst"] == k.rstrip("/") or f["dst"].startswith(k.rstrip("/") + "/") for k in keep):
            bad.append(f"{m.parent.name}: {f['dst']}")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY2

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
eq "каталог журнала 0700" 700 "$(stat -c %a "$ROOT/opt/teleport/log")"
check "служба включена (rc.d)" grep -qx 'init enable' "$FAKE/calls"
check_not "install не стартует агента" grep -qE '^init (start|restart)' "$FAKE/calls"
check_not "черновика скачивания не осталось" bash -c 'compgen -G "$1/opt/teleport/teleport-install.*" >/dev/null' _ "$ROOT"
check "подсказка называет teleport-openwrt" grep -q 'cream run teleport-openwrt join' "$ROOT/out"
check_not "LD_PRELOAD до бинаря не дошёл" grep -qx set "$ROOT/fake/preload.log"
: > "$FAKE/curl.argv"
installed; eq "повторный install — 0" 0 "$?"
check "та же версия — без скачивания" test ! -s "$FAKE/curl.argv"
check "та же версия — сказано" grep -q 'уже установлен' "$ROOT/out"
eq "pin набора: версия и сумма" "TELEPORT_VERSION=18.10.0|TELEPORT_SHA256=$SET_SHA|" "$(tr '\n' '|' < "$S/installed-pin")"
eq "pin набора: 0600" 600 "$(stat -c %a "$S/installed-pin")"

echo "== та же версия, другая сумма набора — набор заново и перезапуск =="
# 2026-10-26: форк v18.10.0-stvor.3 -> stvor.4 — X.Y.Z та же, TELEPORT_SHA256 другая;
# хук отвечал «уже установлен». Сумму поставленного набора хранит $S/installed-pin
# (его же читает /etc/stvor/restore.sh Stvor после sysupgrade).
pin(){ cat "$S/installed-pin" 2>/dev/null | tr '\n' '|'; }
# install, not upgrade: an upgrade of a joined node restarts it anyway (render).
reinstall(){ ht_hook install TELEPORT_SHA256="$1" TELEPORT_MIRROR=https://stvor.example.org/dist/teleport; }
setup
make_set 18.10.0 stvor.3; sha3="$SET_SHA"
ht_hook install TELEPORT_SHA256="$sha3" TELEPORT_MIRROR=https://stvor.example.org/dist/teleport
procd_up; echo up > "$FAKE/net"
join_line; eq "join — 0" 0 "$?"
check "агент работает" test -f "$FAKE/ubus.list"
make_set 18.10.0 stvor.4; sha4="$SET_SHA"
check "фикстура: у сборок разные суммы" test "$sha3" != "$sha4"
: > "$FAKE/calls"; : > "$FAKE/curl.argv"
reinstall "$sha4"; eq "другая сумма — 0" 0 "$?"
check_not "другая сумма — не «уже установлен»" grep -q 'уже установлен' "$ROOT/out"
check "другая сумма — набор скачан заново" grep -q 'teleport-v18.10.0-openwrt-amd64-bin.tar.gz' "$FAKE/curl.argv"
check "другая сумма — бинарь новой сборки" grep -qx '# build stvor.4' "$ROOT/opt/teleport/bin/teleport"
check "другая сумма — агент перезапущен" grep -qx 'init restart' "$FAKE/calls"
check "другая сумма — сказано" grep -q 'сумма набора сменилась' "$ROOT/out"
eq "другая сумма — pin новый" "TELEPORT_VERSION=18.10.0|TELEPORT_SHA256=$sha4|" "$(pin)"
: > "$FAKE/calls"; : > "$FAKE/curl.argv"
reinstall "$sha4"; eq "та же сумма — 0" 0 "$?"
check "та же сумма — уже установлен" grep -q 'уже установлен' "$ROOT/out"
check_not "та же сумма — без скачивания" test -s "$FAKE/curl.argv"
eq "та же сумма — pin тот же" "TELEPORT_VERSION=18.10.0|TELEPORT_SHA256=$sha4|" "$(pin)"
# Installed before the pin was recorded: the sum of the set is unknown — once anew.
rm -f "$S/installed-pin"
: > "$FAKE/curl.argv"
reinstall "$sha4"; eq "pin нет — 0" 0 "$?"
check "pin нет — набор скачан" test -s "$FAKE/curl.argv"
eq "pin нет — pin записан" "TELEPORT_VERSION=18.10.0|TELEPORT_SHA256=$sha4|" "$(pin)"
# The sum does not match: the pin is not the new one — dropped before the download,
# so a replacement cut short never looks done (restore.sh of Stvor falls back to its recipe).
bad_sha="$(printf 'e%.0s' {1..64})"
reinstall "$bad_sha"; check "сумма не совпала — отказ" test "$?" -ne 0
check_not "сумма не совпала — в pin нет чужой суммы" grep -qs "$bad_sha" "$S/installed-pin"
check "сумма не совпала — pin снят до скачивания" test ! -e "$S/installed-pin"
check "сумма не совпала — бинарь прежней сборки" grep -qx '# build stvor.4' "$ROOT/opt/teleport/bin/teleport"

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

echo "== install: раздача портала TELEPORT_DIST + TELEPORT_TAG, обрыв на LTE =="
DIST=https://stvor.example.org/dist
TAG=v18.10.0-stvor.5
setup
make_set 18.10.0 stvor.5
echo 2 > "$FAKE/cuts"
ht_hook install TELEPORT_SHA256="$SET_SHA" TELEPORT_DIST="$DIST" TELEPORT_TAG="$TAG"; eq "dist — 0" 0 "$?"
dl="$(grep -- ' -o ' "$FAKE/curl.argv")"
eq "dist — три вызова curl (два обрыва)" 3 "$(grep -c . <<< "$dl")"
check "dist — URL <база>/teleport/<тег>/<набор>" \
    grep -qE " https://stvor\.example\.org/dist/teleport/v18\.10\.0-stvor\.5/teleport-v18\.10\.0-openwrt-amd64-bin\.tar\.gz$" <<< "$dl"
check "dist — по редиректу, только https" bash -c '! grep -v -- "^-fL .*--proto =https --proto-redir =https" <<< "$1"' _ "$dl"
check "dist — повтор на любой ошибке" bash -c '! grep -v -- "--retry 5 --retry-all-errors" <<< "$1"' _ "$dl"
check "dist — докачка частичного файла" bash -c '! grep -v -- " -C - -o " <<< "$1"' _ "$dl"
check "dist — набор из частей на месте" grep -qx '# build stvor.5' "$ROOT/opt/teleport/bin/teleport"
eq "dist — pin: сумма и тег сборки" "TELEPORT_VERSION=18.10.0|TELEPORT_SHA256=$SET_SHA|TELEPORT_TAG=$TAG|" "$(tr '\n' '|' < "$S/installed-pin")"
# A pin written before the tag was kept: the same set gains the tag without a download
# (/etc/stvor/restore.sh of Stvor reads it after sysupgrade).
printf 'TELEPORT_VERSION=18.10.0\nTELEPORT_SHA256=%s\n' "$SET_SHA" > "$S/installed-pin"
: > "$FAKE/curl.argv"
ht_hook install TELEPORT_SHA256="$SET_SHA" TELEPORT_DIST="$DIST" TELEPORT_TAG="$TAG"; eq "dist, старый pin — 0" 0 "$?"
check_not "dist, старый pin — без скачивания" test -s "$FAKE/curl.argv"
eq "dist, старый pin — тег дописан" "TELEPORT_VERSION=18.10.0|TELEPORT_SHA256=$SET_SHA|TELEPORT_TAG=$TAG|" "$(tr '\n' '|' < "$S/installed-pin")"
eq "dist — паузы перед докачкой" "5|10" "$(paste -s -d '|' "$FAKE/sleep.argv")"
# refuse <what> <text> KEY=VALUE… — install refused before any download.
refuse(){
    local what="$1" text="$2"; shift 2
    setup
    make_set 18.10.0
    ht_hook install TELEPORT_SHA256="$SET_SHA" "$@"; eq "$what — 1" 1 "$?"
    check "$what — причина" grep -qF -- "$text" "$ROOT/out"
    check_not "$what — без скачивания" test -s "$FAKE/curl.argv"
}
refuse "DIST без TAG" "задаются вместе" TELEPORT_DIST="$DIST"
refuse "TAG без DIST и TARBALL" "только с TELEPORT_DIST или TELEPORT_TARBALL" TELEPORT_TAG="$TAG"
refuse "MIRROR и TAG" "только с TELEPORT_DIST или TELEPORT_TARBALL" TELEPORT_TAG="$TAG" TELEPORT_MIRROR=https://stvor.example.org/dist/teleport
refuse "DIST и TARBALL" "взаимоисключим" TELEPORT_DIST="$DIST" TELEPORT_TAG="$TAG" TELEPORT_TARBALL="$HT_TMP/local-set.tar.gz"
refuse "TARBALL и тег другой версии" "TELEPORT_VERSION=18.10.0" TELEPORT_TAG=v18.11.0-stvor.1 TELEPORT_TARBALL="$HT_TMP/local-set.tar.gz"
setup
make_set 18.10.0 stvor.5
cp "$FAKE/set" "$HT_TMP/local-set.tar.gz"
ht_hook install TELEPORT_TARBALL="$HT_TMP/local-set.tar.gz" TELEPORT_TAG="$TAG"; eq "TARBALL и TAG без суммы — 1" 1 "$?"
check "TARBALL и TAG без суммы — причина" grep -q 'TELEPORT_SHA256' "$ROOT/out"
check_not "TARBALL и TAG без суммы — бинаря нет" test -e "$ROOT/opt/teleport/bin/teleport"

echo "== install: локальный TELEPORT_TARBALL + TELEPORT_TAG (тег — только происхождение) =="
setup
make_set 18.10.0 stvor.5
cp "$FAKE/set" "$HT_TMP/local-set.tar.gz"
ht_hook install TELEPORT_SHA256="$SET_SHA" TELEPORT_TARBALL="$HT_TMP/local-set.tar.gz" TELEPORT_TAG="$TAG"
eq "tarball+tag — 0" 0 "$?"
check "tarball+tag — без сети" test ! -s "$FAKE/curl.argv"
check "tarball+tag — набор сборки форка" grep -qx '# build stvor.5' "$ROOT/opt/teleport/bin/teleport"
eq "tarball+tag — pin: сумма и тег сборки" "TELEPORT_VERSION=18.10.0|TELEPORT_SHA256=$SET_SHA|TELEPORT_TAG=$TAG|" "$(tr '\n' '|' < "$S/installed-pin")"
# The same set under a new tag: the pin is rewritten, the set stays (no unpack).
rm -f "$HT_TMP/local-set.tar.gz"
before="$(stat -c %Y.%i "$ROOT/opt/teleport/bin/teleport")"
ht_hook install TELEPORT_SHA256="$SET_SHA" TELEPORT_TARBALL="$HT_TMP/local-set.tar.gz" TELEPORT_TAG=v18.10.0-stvor.6
eq "tarball+новый тег — 0" 0 "$?"
eq "tarball+новый тег — набор не переставлен" "$before" "$(stat -c %Y.%i "$ROOT/opt/teleport/bin/teleport")"
eq "tarball+новый тег — pin переписан" "TELEPORT_VERSION=18.10.0|TELEPORT_SHA256=$SET_SHA|TELEPORT_TAG=v18.10.0-stvor.6|" "$(tr '\n' '|' < "$S/installed-pin")"
refuse "DIST и MIRROR" "взаимоисключим" TELEPORT_DIST="$DIST" TELEPORT_TAG="$TAG" TELEPORT_MIRROR=https://stvor.example.org/dist/teleport
refuse "DIST по http" "ожидали https" TELEPORT_DIST=http://stvor.example.org/dist TELEPORT_TAG="$TAG"
refuse "тег другой версии" "TELEPORT_VERSION=18.10.0" TELEPORT_DIST="$DIST" TELEPORT_TAG=v18.11.0-stvor.1
setup
make_set 18.10.0
echo 9 > "$FAKE/cuts"
ht_hook install TELEPORT_SHA256="$SET_SHA" TELEPORT_DIST="$DIST" TELEPORT_TAG="$TAG"; eq "попытки кончились — 1" 1 "$?"
eq "попытки кончились — пять вызовов curl" 5 "$(grep -c -- ' -o ' "$FAKE/curl.argv")"
check "попытки кончились — причина" grep -q 'не скачался' "$ROOT/out"
check_not "попытки кончились — пина нет" test -e "$S/installed-pin"
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

echo "== sysupgrade с сохранением конфигурации: тот же узел без join =="
# sysupgrade_sim: what sysupgrade -b archives — the files and links under the paths
# of keep.d (find -type f -o -type l: directories are not archived), a new firmware
# without the set, the domain and the state of cream (the tree of the extension
# stays: cream lays it again), the archive unpacked at boot (tar makes the
# missing directories by umask, 0755). The state of cream is /opt/cream/var on
# OpenWrt and var/lib/cream under hooktest — the list is mapped.
sysupgrade_sim(){
    local list="$HT_TMP/keep.list" p
    : > "$list"
    while IFS= read -r p; do
        [[ -n "$p" && "$p" != \#* ]] || continue
        p="${p%/}"; p="${p/#\/opt\/cream\/var\//\/var\/lib\/cream\/}"
        ( cd "$ROOT" && find ".$p" \( -type f -o -type l \) 2>/dev/null ) >> "$list"
    done < "$SRC/files/keep.d"
    tar -czf "$HT_TMP/backup.tgz" -C "$ROOT" -T "$list"
    rm -rf -- "$ROOT/opt/teleport" "$ROOT/etc/cream" "$ROOT/var/lib/cream" "$ROOT/usr/bin/teleport" "$ROOT/etc/teleport.yaml" \
        "$ROOT/var/run/teleport.start" "$ROOT/var/run/teleport.started" "$FAKE/ubus.list"
    ( umask 022; tar -xzf "$HT_TMP/backup.tgz" -C "$ROOT" )
}
tree_sum(){ ( cd "$1" && find . -type f -exec sha256sum {} + | sort ) | sha256sum | cut -c1-64; }
setup; installed; procd_up
echo up > "$FAKE/net"
join_line; eq "join до sysupgrade — 0" 0 "$?"
printf 'NAME=web\nURI=http://127.0.0.1:8080\n' > "$ROOT/etc/cream/teleport-openwrt/apps.d/web.conf"
uuid="$(cat "$D/host_uuid")"; before="$(tree_sum "$D")"
chmod 0600 "$S/agent-enabled"
sysupgrade_sim
eq "архив: каталог состояния 0755 (tar)" 755 "$(stat -c %a "$S")"
check "архив: флаг agent-enabled" test -e "$S/agent-enabled"
check "архив: pin набора (restore.sh Stvor берёт сумму из него)" grep -qx "TELEPORT_SHA256=$SET_SHA" "$S/installed-pin"
check "архив: домен с прокси" grep -q '^TELEPORT_PROXY=' "$ROOT/etc/cream/teleport-openwrt/config"
check "архив: apps.d" test -f "$ROOT/etc/cream/teleport-openwrt/apps.d/web.conf"
check_not "архив: секрета первого входа нет" test -e "$S/registration-secret"
chmod 0644 "$S/agent-enabled"
: > "$FAKE/calls"; : > "$FAKE/curl.argv"
installed; eq "install после sysupgrade — 0" 0 "$?"
check "набор скачан вновь" test -s "$FAKE/curl.argv"
eq "каталог состояния снова 0700" 700 "$(stat -c %a "$S")"
eq "флаг agent-enabled 0600" 600 "$(stat -c %a "$S/agent-enabled")"
eq "data_dir 0750" 750 "$(stat -c %a "$D")"
eq "host_uuid тот же" "$uuid" "$(cat "$D/host_uuid")"
eq "data не тронута" "$before" "$(tree_sum "$D")"
check_not "install не стартует агента" grep -qE '^init (start|restart)' "$FAKE/calls"
# The command of the portal again (no secret, no FORCE): the idempotent branch.
act join TELEPORT_PROXY="$PROXY" TELEPORT_ENV=dev; eq "повтор join после sysupgrade — 0" 0 "$?"
eq "повтор join — registered" registered "$(json | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])')"
check "повтор join — уже зарегистрирован" grep -q 'уже зарегистрирован' "$ROOT/out"
check_not "повтор join — агент не стартовал (join не вызывался)" grep -qE '^init (start|restart)' "$FAKE/calls"
check_not "повтор join — секрета нет" test -e "$S/registration-secret"
eq "повтор join — host_uuid тот же" "$uuid" "$(cat "$D/host_uuid")"
eq "повтор join — data не тронута" "$before" "$(tree_sum "$D")"
# The service of the node starts it by the restored flag.
"$ROOT/etc/init.d/teleport" start
check "служба по флагу — агент поднят" test -f "$FAKE/ubus.list"
eq "служба — тот же host_uuid" "$uuid" "$(cat "$D/host_uuid")"

echo "== render: teleport.yaml OpenWrt (§3) =="
setup; installed
join_line TELEPORT_DEFER=1; eq "join отложенный — 0" 0 "$?"
eq "join отложенный — JSON" deferred "$(json | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])')"
check "подсказка join-retry называет teleport-openwrt" grep -q 'cream run teleport-openwrt join-retry' "$ROOT/out"
check "data_dir /opt/teleport/data" grep -qx '  data_dir: /opt/teleport/data' "$Y"
check "log.output — файл журнала" grep -qx '    output: /opt/teleport/log/teleport.log' "$Y"
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
act apps-status; eq "apps-status — 0" 0 "$?"
eq "apps-status: ext, apps.d, зарегистрирован, journal известен" \
    "teleport-openwrt /etc/cream/teleport-openwrt/apps.d True True False" \
    "$(json | python3 -c 'import json,sys; o=json.load(sys.stdin); print(o["ext"], o["apps_dir"], o["registered"], o["app_role_known"], o["app_role_missing"])')"
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

echo "== join: отказ кластера — из журнала узла с отсечкой по времени =="
setup; installed; procd_up
echo up > "$FAKE/net"; echo refuse > "$FAKE/agent"
# An old refusal before this join is not this join's answer.
printf '2000-01-01T00:00:00Z INFO Can not join the cluster, the token is expired or not found.\n' > "$ROOT/opt/teleport/log/teleport.log"
join_line; eq "отказ — 1" 1 "$?"
eq "отказ — refused" refused "$(json | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])')"
check "отказ — агент снят отдельным экземпляром" grep -q 'ubus call service delete {"name":"teleport","instance":"teleport"}' "$FAKE/calls"
check_not "отказ — syslog не читается" ht_called '^logread'
check "отказ — причина" grep -q 'токен регистрации не найден' "$ROOT/out"
check_not "отказ — не включён" test -e "$S/agent-enabled"

echo "== журнал: syslog не решает ничего, только файл узла (0700/0600) =="
# Any local process writes to syslog any tag with any pid (busybox
# `logger -t 'teleport[<pid>]'`): such a line changes no decision.
spoof(){
    local now; now="$(date +%s)"
    {
        printf 'Thu Oct 22 10:00:00 2026 [%s.1] user.notice teleport[%s]: Can not join the cluster, the token is expired or not found.\n' "$now" "$1"
        printf 'Thu Oct 22 10:00:00 2026 [%s.1] user.notice teleport: Can not join the cluster, the token is expired or not found.\n' "$now"
    } >> "$FAKE/logread"
}
setup; installed; procd_up
echo up > "$FAKE/net"; echo hang > "$FAKE/agent"
spoof 101
join_line; eq "logger teleport[<pid экземпляра>] — не отказ (0)" 0 "$?"
eq "logger — pending, не refused" pending "$(json | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])')"
check_not "logger — отказ не записан" test -e "$S/join-refused"
check "logger — секрет цел для повтора" test -s "$S/registration-secret"
# The file of the node, writable by others — not trusted either.
setup; installed; procd_up
echo up > "$FAKE/net"; echo refuse > "$FAKE/agent"
: > "$ROOT/opt/teleport/log/teleport.log"; chmod 0666 "$ROOT/opt/teleport/log/teleport.log"
join_line; eq "журнал с записью для всех — не отказ (0)" 0 "$?"
check "журнал с записью для всех — секрет цел" test -s "$S/registration-secret"
# The same refusal in the file of the node, in local time with an offset, is the
# answer (dated a minute ahead: the attempt starts after this line is written).
setup; installed; procd_up
echo up > "$FAKE/net"; echo hang > "$FAKE/agent"
printf '%s INFO Can not join the cluster, the token is expired or not found.\n' "$(TZ=Etc/GMT-3 date -d "@$(( $(date +%s) + 60 ))" +%Y-%m-%dT%H:%M:%S+03:00)" >> "$ROOT/opt/teleport/log/teleport.log"
join_line; eq "строка журнала узла — отказ (1)" 1 "$?"
eq "строка журнала узла — refused" refused "$(json | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])')"

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
cp "$Y" "$HT_TMP/y.before"
bbrun apps-status; eq "apps-status без stat — 0" 0 "$?"
eq "apps-status: web опубликован, wide (0666) — untrusted_path" \
    "[('web', 'http://127.0.0.1:8080', 'extension', '/etc/cream/teleport-openwrt/apps.d/web.conf')] [('/etc/cream/teleport-openwrt/apps.d/wide.conf', 'untrusted_path')]" \
    "$(grep -E '^\{' "$ROOT/out" | python3 -c 'import json,sys; o=json.load(sys.stdin); print([(a["name"], a["uri"], a["source"], a.get("file")) for a in o["apps"]], [(d["file"], d["reason"]) for d in o["dropped"]])')"
check "apps-status не трогает teleport.yaml" cmp -s "$HT_TMP/y.before" "$Y"
# One label <name>-<node>.<proxy> of at most 63: the node bb-node (7) — a name of
# 55 is published, of 56 is not (TELEPORT_APPS and apps.d alike).
check "web: public_addr — одна метка web-bb-node" grep -qx '      public_addr: "web-bb-node.teleport.example.org"' "$Y"
check "web: Host — та же метка" grep -qx '          - "Host: web-bb-node.teleport.example.org"' "$Y"
O55="$(printf 'o%.0s' $(seq 55))"; O56="$(printf 'p%.0s' $(seq 56))"
X55="$(printf 'x%.0s' $(seq 55))"; X56="$(printf 'y%.0s' $(seq 56))"
printf 'NAME=%s\nURI=http://127.0.0.1:9001\n' "$X55" > "$ROOT/etc/cream/teleport-openwrt/apps.d/x55.conf"
printf 'NAME=%s\nURI=http://127.0.0.1:9002\n' "$X56" > "$ROOT/etc/cream/teleport-openwrt/apps.d/x56.conf"
chmod 0644 "$ROOT/etc/cream/teleport-openwrt/apps.d/x55.conf" "$ROOT/etc/cream/teleport-openwrt/apps.d/x56.conf"
echo "TELEPORT_APPS=\"$O55=8081 $O56=8082\"" >> "$ROOT/etc/cream/teleport-openwrt/config"
bbrun render; eq "render с длинными именами — 0" 0 "$?"
check "метка 63 из apps.d — опубликована" grep -qx "      public_addr: \"$X55-bb-node.teleport.example.org\"" "$Y"
check "метка 63 оператора — опубликована" grep -qx "      public_addr: \"$O55-bb-node.teleport.example.org\"" "$Y"
check_not "метка 64 из apps.d — нет" grep -q "$X56" "$Y"
check_not "метка 64 оператора — нет" grep -q "$O56" "$Y"
check "метка 64 — строка журнала" grep -qF "пропускаю приложение '$O56': адрес $O56-bb-node — метка DNS длиннее 63" "$ROOT/out"
bbrun apps-status; eq "apps-status с длинными именами — 0" 0 "$?"
eq "apps-status: метка 64 — invalid, name_too_long" \
    "[('/etc/cream/teleport-openwrt/apps.d/x56.conf', '$X56', 'invalid', 'name_too_long'), ('TELEPORT_APPS', '$O56', 'invalid', 'name_too_long')]" \
    "$(grep -E '^\{' "$ROOT/out" | python3 -c 'import json,sys; o=json.load(sys.stdin); print([(d["file"], d.get("name"), d["reason"], d.get("detail")) for d in o["dropped"] if d["reason"] == "invalid"])')"
rm -f "$ROOT/etc/cream/teleport-openwrt/apps.d/x55.conf" "$ROOT/etc/cream/teleport-openwrt/apps.d/x56.conf"
sed -i '/^TELEPORT_APPS=/d' "$ROOT/etc/cream/teleport-openwrt/config"
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
