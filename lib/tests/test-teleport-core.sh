#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in the fixture layer is the test data
# Tests of the shared core lib/teleport-core.sh through a fixture layer (no
# systemd, no procd): the contract of the layer (a missing point is named before
# any work), the name of the extension in every hint and in cream set/show
# (TELEPORT_EXT), the points of teleport.yaml (data_dir, log.output, extra
# ssh_service keys), the binary only as `env -u LD_PRELOAD` and nothing of an
# init system in the core. The behaviour of join, render, labels and the managed
# labels is tested through the layers: extensions/debian/teleport/tests,
# extensions/openwrt/teleport-openwrt/tests.
#
#   lib/tests/test-teleport-core.sh     code 0 — every check passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$(dirname "$HERE")/teleport-core.sh"

TMP="$(mktemp -d)"
trap 'rm -r -f -- "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&2; }
check(){ local what="$1"; shift; if "$@"; then ok; else bad "$what"; fi; }
check_not(){ local what="$1"; shift; if "$@"; then bad "$what"; else ok; fi; }
eq(){ if [[ "$2" == "$3" ]]; then ok; else bad "$1: ждали [$2], получили [$3]"; fi; }
has(){ if grep -qF -- "$2" <<< "$3"; then ok; else bad "$1: нет [$2] в [$3]"; fi; }

# A fixture extension tp-x: files/teleport.sh — a layer whose init points log
# their calls to $FAKE/layer.log; files/teleport-core.sh — the core.
EXT="$TMP/ext/tp-x"
mkdir -p "$EXT/files"
cp "$CORE" "$EXT/files/teleport-core.sh"
cat > "$EXT/files/teleport.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
TELEPORT_EXT=tp-x
TELEPORT_DATA_GUEST=/srv/tp/data
TELEPORT_BIN_GUEST=/srv/tp/bin/teleport
INIT_NAME=fakeinit
AGENT_UNIT=tp-agent
AGENT_LOG_HINT="fakelog tp"
AGENT_LOG_FOLLOW="fakelog -f tp"
LOG_OUTPUT=syslog
. "$(dirname "${BASH_SOURCE[0]}")/teleport-core.sh"
L(){ echo "$*" >> "$CREAM_ROOT/fake/layer.log"; }
init_running(){ [[ -e "$ROOT/fake/init" ]]; }
agent_active(){ [[ -e "$ROOT/fake/active" ]]; }
agent_start(){ L agent_start; }
agent_stop(){ L agent_stop; }
agent_enable(){ L agent_enable; }
agent_disable(){ L agent_disable; }
agent_disable_now(){ L agent_disable_now; }
retry_arm(){ L retry_arm; }
retry_disarm(){ L retry_disarm; }
retry_status_line(){ echo "  повтор: fake"; }
service_status_line(){ echo "Служба: fake"; }
agent_log_since(){ :; }
app_role_missing(){ return 1; }
apply_running(){ L apply_running; }
restart_agent(){ L restart_agent; }
render_ssh_extra(){ echo "  pam:"; echo "    enabled: false"; }
teleport_tarball(){ echo "tp-$1-$2.tar.gz"; }
cmd_apply(){ L cmd_apply; }
cmd_reload_apps(){ L cmd_reload_apps; }
cmd_hup(){ L cmd_hup; }
hook_install(){ L "hook_install $1"; }
hook_remove(){ L hook_remove; }
[[ -n "${DROP:-}" ]] && unset -f "$DROP"
[[ -n "${DROPV:-}" ]] && unset "$DROPV"
# A substitute apps_resolve: the lines of $FAKE/apps_resolve as is (the re-check
# of app_line_ok is what is tested).
if [[ -e "$ROOT/fake/apps_resolve" ]]; then apps_resolve(){ cat "$ROOT/fake/apps_resolve"; }; fi
core_main "$@"
EOF
chmod +x "$EXT/files/teleport.sh"

new_root(){
    ROOT="$(mktemp -d "$TMP/root.XXXXXX")"
    mkdir -p "$ROOT/bin" "$ROOT/fake" "$ROOT/etc/cream/tp-x" "$ROOT/var/lib/cream/ext/tp-x" "$ROOT/srv/tp/bin"
    printf '#!/bin/sh\necho lab-host\n' > "$ROOT/bin/hostname"
    printf '#!/bin/sh\nexit 6\n' > "$ROOT/bin/curl"
    # cream set: the pairs into the domain file, the call into the journal.
    cat > "$ROOT/bin/cream" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CREAM_ROOT/fake/cream.log"
[[ "$1" == set ]] || exit 0
shift; while [[ "$1" == --* ]]; do shift; done; shift
for p in "$@"; do
    k="${p%%=*}"; sed -i "/^$k=/d" "$CREAM_ROOT/etc/cream/tp-x/config" 2>/dev/null
    printf '%s="%s"\n' "$k" "${p#*=}" >> "$CREAM_ROOT/etc/cream/tp-x/config"
done
EOF
    # The binary: its version, and whether LD_PRELOAD reached it.
    cat > "$ROOT/srv/tp/bin/teleport" <<'EOF'
#!/usr/bin/env bash
echo "${LD_PRELOAD+set}" >> "$CREAM_ROOT/fake/preload.log"
echo "Teleport v18.10.0 git:fake"
EOF
    chmod +x "$ROOT/bin/hostname" "$ROOT/bin/curl" "$ROOT/bin/cream" "$ROOT/srv/tp/bin/teleport"
    chmod -R go-w "$ROOT"
}
# tp <command> [args]: the layer as cream runs it; LD_PRELOAD set, as procd sets it.
tp(){
    env -i PATH="$ROOT/bin:/usr/bin:/bin" CREAM_ROOT="$ROOT" CREAM_EXT_DIR="$EXT" \
        LD_PRELOAD= ${DROP:+DROP="$DROP"} ${DROPV:+DROPV="$DROPV"} "$EXT/files/teleport.sh" "$@"
}

echo "== контракт слоя: недостающая точка названа до работы =="
new_root
for f in init_running agent_start retry_arm render_ssh_extra teleport_tarball hook_remove cmd_hup; do
    out="$(DROP="$f" tp render 2>&1)"; rc=$?
    eq "без $f — код 1" 1 "$rc"
    has "без $f — названа" "$f()" "$out"
done
for v in TELEPORT_EXT LOG_OUTPUT AGENT_LOG_HINT; do
    out="$(DROPV="$v" tp status 2>&1)"; rc=$?
    eq "без $v — код 1" 1 "$rc"
    has "без $v — названа" "$v" "$out"
done
check_not "без точки слоя — ничего не записано" test -e "$ROOT/etc/teleport.yaml"

echo "== имя расширения в подсказках и в cream set/show (TELEPORT_EXT) =="
new_root
out="$(tp render 2>&1)"; rc=$?
eq "render без кластера — код 1" 1 "$rc"
has "render без кластера — подсказка join" "cream run tp-x join" "$out"
printf 'TELEPORT_PROXY=bad proxy\n' > "$ROOT/etc/cream/tp-x/config"
out="$(tp render 2>&1)"
has "неверные ручки — cream show tp-x" "cream show tp-x" "$out"
printf 'TELEPORT_PROXY=tp.example.org\n' > "$ROOT/etc/cream/tp-x/config"
out="$(tp leave 2>&1)"
has "leave — cream set своего расширения" "set --no-apply --allow-readonly tp-x TELEPORT_PROXY=" "$(cat "$ROOT/fake/cream.log")"
has "leave — JSON" '{"result":"left"}' "$out"
check "leave без init — слой не трогает агент" test ! -e "$ROOT/fake/layer.log"
touch "$ROOT/fake/init"
tp leave >/dev/null 2>&1
eq "leave с init — агент выключен, повтор снят" "agent_disable_now retry_disarm" "$(tr '\n' ' ' < "$ROOT/fake/layer.log" | sed 's/ $//')"

echo "== join: подсказки и точки слоя =="
new_root
out="$(printf 'abcdefgh-join-token' | tp join TELEPORT_PROXY=tp.example.org TELEPORT_REGISTRATION_SECRET=- TELEPORT_DEFER=1 2>&1)"; rc=$?
eq "join отложенный — код 0" 0 "$rc"
has "отложенный — подсказка join-retry своего расширения" "cream run tp-x join-retry" "$out"
has "отложенный — JSON" '"result":"deferred"' "$out"
check_not "нигде не названо чужое расширение" grep -qE 'cream (run|set|show|install) teleport( |$)' <<< "$out"
out="$(printf 'abcdefgh-join-token' | tp join TELEPORT_PROXY=tp.example.org TELEPORT_REGISTRATION_SECRET=- TELEPORT_FORCE=1 2>&1)"; rc=$?
has "без init — сообщение называет init слоя" "fakeinit не запущен" "$out"
has "без init — JSON written" '"result":"written"' "$out"

echo "== teleport.yaml: точки слоя =="
Y="$ROOT/etc/teleport.yaml"
check "render: yaml есть" test -s "$Y"
check "шапка — render своего расширения" grep -qx '# Сгенерирован cream run tp-x render из /etc/cream/tp-x. Не править:' "$Y"
check "шапка — служба слоя" grep -qx '# перезаписывается на каждом старте tp-agent.' "$Y"
check "data_dir слоя" grep -qx '  data_dir: /srv/tp/data' "$Y"
check "log.output слоя" grep -qx '    output: syslog' "$Y"
eq "доп. ключи ssh_service — внутри ssh_service" "  pam:|    enabled: false" \
    "$(sed -n '/^ssh_service:/,/^[a-z]/p' "$Y" | grep -A1 '^  pam:' | paste -s -d '|' -)"

echo "== app_line_ok: render и apps-status проверяют записи apps_resolve одним правилом =="
new_root
printf 'TELEPORT_PROXY=tp.example.org\n' > "$ROOT/etc/cream/tp-x/config"
A="/etc/cream/tp-x/apps.d"
{
    printf 'app\tgood\thttp://127.0.0.1:8080\t%s/good.conf\t\n' "$ROOT$A"
    printf 'app\top\thttps://10.0.0.5:8443\tTELEPORT_APPS\t\n'
    printf 'app\tremote\thttp://10.0.0.1:80\t%s/remote.conf\t\n' "$ROOT$A"
    printf 'app\tBad_Name\thttp://127.0.0.1:1\tTELEPORT_APPS\t\n'
    printf 'app\textra\thttp://127.0.0.1:2\tTELEPORT_APPS\t\tmore\n'
    printf 'app\tforeign\thttp://127.0.0.1:3\t/tmp/x.conf\t\n'
    printf 'app\ticon\thttp://127.0.0.1:4\tTELEPORT_APPS\tbad icon\n'
} > "$ROOT/fake/apps_resolve"
tp render >/dev/null 2>&1
Y="$ROOT/etc/teleport.yaml"
eq "render: только записи по форме" "good-lab-host op-lab-host" \
    "$(sed -n 's/^    - name: "\(.*-lab-host\)"$/\1/p' "$Y" | paste -s -d ' ' -)"
out="$(tp apps-status 2>/dev/null)"; rc=$?
eq "apps-status — 0" 0 "$rc"
eq "apps-status: опубликованы те же, что в render" "['good', 'op']" \
    "$(python3 -c 'import json,sys; print([a["name"] for a in json.loads(sys.argv[1])["apps"]])' "$out" 2>&1)"
eq "apps-status: не по форме — dropped invalid" \
    "[('/etc/cream/tp-x/apps.d/remote.conf', 'remote', 'invalid'), ('TELEPORT_APPS', None, 'invalid'), ('TELEPORT_APPS', 'extra', 'invalid'), ('/tmp/x.conf', 'foreign', 'invalid'), ('TELEPORT_APPS', 'icon', 'invalid')]" \
    "$(python3 -c 'import json,sys; print([(d["file"], d.get("name"), d["reason"]) for d in json.loads(sys.argv[1])["dropped"]])' "$out" 2>&1)"

echo "== apps-status: apps.d — символическая ссылка: одна запись каталога =="
new_root
printf 'TELEPORT_PROXY=tp.example.org\n' > "$ROOT/etc/cream/tp-x/config"
mkdir -p "$ROOT/srv/real"
printf 'NAME=a\nURI=http://127.0.0.1:1\n' > "$ROOT/srv/real/a.conf"
printf 'NAME=b\nURI=http://127.0.0.1:2\n' > "$ROOT/srv/real/b.conf"
ln -s "$ROOT/srv/real" "$ROOT/etc/cream/tp-x/apps.d"
out="$(tp apps-status 2>/dev/null)"
eq "ссылка: одна запись untrusted_path, файлы не перечислены" "[('/etc/cream/tp-x/apps.d', 'untrusted_path')]" \
    "$(python3 -c 'import json,sys; print([(d["file"], d["reason"]) for d in json.loads(sys.argv[1])["dropped"]])' "$out" 2>&1)"
printf 'TELEPORT_APPS_DISCOVERY=0\n' >> "$ROOT/etc/cream/tp-x/config"
out="$(tp apps-status 2>/dev/null)"
eq "ссылка, discovery 0: одна запись discovery_off" "[('/etc/cream/tp-x/apps.d', 'discovery_off')]" \
    "$(python3 -c 'import json,sys; print([(d["file"], d["reason"]) for d in json.loads(sys.argv[1])["dropped"]])' "$out" 2>&1)"

echo "== бинарь — только env -u LD_PRELOAD =="
new_root
: > "$ROOT/fake/preload.log"
tp status >/dev/null 2>&1
printf 'abcdefgh-join-token' | tp join TELEPORT_PROXY=tp.example.org TELEPORT_REGISTRATION_SECRET=- >/dev/null 2>&1
check "бинарь вызывался" test -s "$ROOT/fake/preload.log"
check_not "LD_PRELOAD до бинаря не дошёл" grep -qx set "$ROOT/fake/preload.log"
# Every command position of "$TELEPORT_BIN" in the core goes through env -u.
bare="$(grep -nE '(^|[;&|({]|\$\()[[:space:]]*"\$TELEPORT_BIN"' "$CORE" | grep -v 'env -u LD_PRELOAD "\$TELEPORT_BIN"' || true)"
eq "в ядре нет вызова бинаря без env -u LD_PRELOAD" "" "$bare"
check "в ядре есть env -u LD_PRELOAD" grep -q 'env -u LD_PRELOAD "$TELEPORT_BIN"' "$CORE"

echo "== регулярные выражения и musl: граница > 255 (RE_DUP_MAX) =="
# A bound over 255 is an invalid regex for musl (bash on OpenWrt); re_ok handles
# exactly the anchored ^<bracket expression>{m,n}$ form — every such regex has it.
n=0
form='^\^(\[\[:[a-z]+:\]\]|\[[^]]+\])\{[0-9]+,[0-9]+\}\$$'
while IFS= read -r re; do
    n=$((n + 1))
    if [[ "$re" =~ $form ]]; then ok; else bad "граница > 255 не в форме ^[класс]{m,n}\$: $re"; fi
done < <(grep -oE "'(list:)?(re:)?\^[^']*'" "$CORE" | tr -d "'" | sed -E 's/^(list:)?re://' \
            | grep -E '\{[0-9]+,([0-9]{4,}|[3-9][0-9]{2}|2[6-9][0-9]|25[6-9])\}')
check "такие выражения есть (токен, секрет)" test "$n" -ge 3
new_root
tok256="$(printf '%0256d' 0)"; tok257="$(printf '%0257d' 0)"
out="$(printf '%s' "$tok256" | tp join TELEPORT_PROXY=tp.example.org TELEPORT_REGISTRATION_SECRET=- TELEPORT_DEFER=1 2>&1)"; rc=$?
eq "join-токен 256 знаков — принят" 0 "$rc"
check "токен 256 — в teleport.yaml" grep -q "token_name: \"$tok256\"" "$ROOT/etc/teleport.yaml"
new_root
out="$(printf '%s' "$tok257" | tp join TELEPORT_PROXY=tp.example.org TELEPORT_REGISTRATION_SECRET=- TELEPORT_DEFER=1 2>&1)"; rc=$?
eq "join-токен 257 знаков — отказ" 1 "$rc"
has "токен 257 — причина" "8–256" "$out"
new_root
out="$(printf '%s' "$(printf '%01001d' 0)" | tp join TELEPORT_PROXY=tp.example.org TELEPORT_JOIN_METHOD=bound_keypair TELEPORT_TOKEN=robot-lab-1 TELEPORT_REGISTRATION_SECRET=- TELEPORT_DEFER=1 2>&1)"; rc=$?
eq "секрет 1001 знак — отказ" 1 "$rc"

echo "== в ядре нет init-системы и чужого имени =="
code="$(grep -vE '^[[:space:]]*#' "$CORE")"
check_not "ядро не зовёт systemctl/journalctl/procd" grep -qE 'systemctl|journalctl|has_systemd|/etc/init\.d|logread' <<< "$code"
check_not "ядро не называет расширение teleport" grep -qE 'cream (run|set|show|install)( --[a-z-]+)* teleport([^-A-Za-z_]|$)' <<< "$code"
check_not "ядро не исполняемое само" test -x "$CORE"

echo "test-teleport-core: $pass/$((pass + fail))"
(( fail == 0 ))
