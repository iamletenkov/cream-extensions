#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Тесты расширения teleport (cream/v1): управляемые метки (TELEPORT_MANAGED_LABELS,
# действия set-managed и managed-status — контракт stvor-agent, схема 1) и
# командные метки command-labels.d (спека stvor-agent §10.3, §10.5, §10.7).
# Проверки «переехало в T» из docs/test-map.md stvor-agent (раздел «Для CE»)
# помечены его номерами (№N); строки №215–217 (join) — в test-join.sh.
#
# Подменённый корень CREAM_ROOT, поддельные systemctl (свойства юнита и исход
# restart), cream (set пишет файл домена и журнал вызовов), stat (чужой
# владелец), sleep. root, systemd и сеть не нужны.
#
#   extensions/debian/teleport/tests/test-managed.sh     код 0 — все проверки прошли

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
REPO="$(cd "$EXT/../../.." && pwd)"
FIXTURES="$HERE/fixtures"

TMP="$(mktemp -d)"
trap 'rm -r -f -- "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
exec 3>&2
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&3; }
check(){ local what="$1"; shift; if "$@"; then ok; else bad "$what"; fi; }
check_not(){ local what="$1"; shift; if "$@"; then bad "$what"; else ok; fi; }
eq(){ local what="$1" want="$2" got="$3"; if [[ "$want" == "$got" ]]; then ok; else bad "$what: ждали [$want], получили [$got]"; fi; }

# ---------------------------------------------------------------------------
# Scratch root and fakes
# ---------------------------------------------------------------------------
# FAKE:
#   active          exists — teleport.service is active
#   unit.<Prop>     what `systemctl show -p <Prop> --value teleport.service` prints
#   restart         what `systemctl restart teleport.service` does:
#                     ok        new run (all three properties change), active
#                     fail      exit 1, nothing changes
#                     noop      exit 0, no new run
#                     pid       only MainPID changes
#                     inv-empty InvocationID empty, MainPID changes
#                     ts        only ActiveEnterTimestampMonotonic changes
#                     dead      new run, but the unit is not active
#                     gone      InvocationID empty, MainPID 0, nothing else
#   foreign         paths whose owner the fake stat reports as uid 4242
#   *.log           systemctl, cream (with "marker=yes|no": managed-pending at
#                   the time of the call), sleep
BASE_PATH="$PATH"
new_root(){
    ROOT="$(mktemp -d "$TMP/root.XXXXXX")"
    FAKE="$ROOT/fake"
    mkdir -p "$ROOT/bin" "$FAKE" "$ROOT/opt/cream/ext" "$ROOT/etc/cream/teleport/apps.d" \
        "$ROOT/etc/cream/teleport/command-labels.d" "$ROOT/var/lib/cream/ext/teleport" \
        "$ROOT/run/systemd/system" "$ROOT/usr/bin"
    chmod 0755 "$ROOT/etc/cream/teleport/command-labels.d"
    chmod 0700 "$ROOT/var/lib/cream/ext/teleport"
    cp -a "$EXT" "$ROOT/opt/cream/ext/teleport"
    rm -r -f -- "$ROOT/opt/cream/ext/teleport/tests"
    echo ok > "$FAKE/restart"
    echo inv-1 > "$FAKE/unit.InvocationID"
    echo 100 > "$FAKE/unit.MainPID"
    echo 5000 > "$FAKE/unit.ActiveEnterTimestampMonotonic"
    : > "$FAKE/foreign"
    cat > "$ROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/systemctl.log"
bump(){ local v; v="$(cat "$FAKE/unit.$1")"; echo "${v}x" > "$FAKE/unit.$1"; }
case "${1:-}" in
    is-active)
        [[ "${2:-}" == --quiet ]] && shift
        if [[ "${2:-}" == teleport.service ]]; then [[ -f "$FAKE/active" ]]; exit; fi
        exit 0 ;;
    is-enabled) echo enabled; exit 0 ;;
    show)
        # show -p <Prop> --value teleport.service
        cat "$FAKE/unit.$3" 2>/dev/null; exit 0 ;;
    restart)
        case "$(cat "$FAKE/restart")" in
            fail) exit 1 ;;
            noop) ;;
            pid) bump MainPID ;;
            inv-empty) : > "$FAKE/unit.InvocationID"; bump MainPID ;;
            gone) : > "$FAKE/unit.InvocationID"; echo 0 > "$FAKE/unit.MainPID" ;;
            ts) bump ActiveEnterTimestampMonotonic ;;
            dead) bump InvocationID; bump MainPID; bump ActiveEnterTimestampMonotonic; rm -f "$FAKE/active"; exit 0 ;;
            *) bump InvocationID; bump MainPID; bump ActiveEnterTimestampMonotonic ;;
        esac
        touch "$FAKE/active" ;;
    stop) rm -f "$FAKE/active" ;;
    disable) [[ " $* " == *" --now "* && " $* " == *" teleport.service "* ]] && rm -f "$FAKE/active" ;;
esac
exit 0
EOF
    cat > "$ROOT/bin/cream" <<'EOF'
#!/usr/bin/env bash
m=no; [[ -f "$CREAM_ROOT/var/lib/cream/ext/teleport/managed-pending" ]] && m=yes
printf 'cream %s lock_fd=%s marker=%s\n' "$*" "${CREAM_LOCK_FD:-}" "$m" >> "$FAKE/cream.log"
[[ "${1:-}" == set ]] || exit 64
shift
while [[ "${1:-}" == --* ]]; do shift; done
[[ "${1:-}" == teleport ]] || exit 66
shift
conf="$CREAM_ROOT/etc/cream/teleport/config"
declare -A V=()
if [[ -f "$conf" ]]; then
    while IFS= read -r line; do
        k="${line%%=*}"; v="${line#*=}"
        if [[ "$v" == \"*\" ]]; then v="${v:1:${#v}-2}"; v="${v//\\\"/\"}"; v="${v//\\\\/\\}"; fi
        V[$k]="$v"
    done < "$conf"
fi
for p in "$@"; do V[${p%%=*}]="${p#*=}"; done
tmp="$conf.tmp"
for k in $(printf '%s\n' "${!V[@]}" | sort); do
    v="${V[$k]}"
    if [[ "$v" =~ ^[A-Za-z0-9_./:,@%+=-]*$ ]]; then
        printf '%s=%s\n' "$k" "$v"
    else
        v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
        printf '%s="%s"\n' "$k" "$v"
    fi
done > "$tmp"
mv -f "$tmp" "$conf"
EOF
    cat > "$ROOT/bin/stat" <<'EOF'
#!/usr/bin/env bash
# A path from $FAKE/foreign belongs to uid 4242; anything else — the real stat.
last="${!#}"
if [[ " $* " == *" %u "* ]] && grep -qxF -- "$last" "$FAKE/foreign" 2>/dev/null; then echo 4242; exit 0; fi
exec /usr/bin/stat "$@"
EOF
    printf '#!/bin/sh\necho sleep "$@" >> "$FAKE/sleep.log"\nexit 0\n' > "$ROOT/bin/sleep"
    chmod +x "$ROOT/bin/"*
    export FAKE CREAM_ROOT="$ROOT" PATH="$ROOT/bin:$BASE_PATH"
    STAGED="$ROOT/opt/cream/ext/teleport"
    CONF="$ROOT/etc/cream/teleport/config"
    STATE="$ROOT/var/lib/cream/ext/teleport"
    MARKER="$STATE/managed-pending"
    CMDS="$ROOT/etc/cream/teleport/command-labels.d"
    Y="$ROOT/etc/teleport.yaml"
    HOST_UUID="$ROOT/var/lib/teleport/host_uuid"
}
# tp <action> [args…] — `cream run teleport <action>` with the environment of cream.
tp(){
    local a="$1"; shift
    local -a env=(CREAM_PHASE=live CREAM_EXT=teleport CREAM_EXT_VERSION=4.0.0 CREAM_EXT_DIR="$STAGED"
        CREAM_ETC_DIR="$ROOT/etc/cream/teleport" CREAM_STATE_DIR="$STATE" CREAM_ROOT="$ROOT"
        CREAM_CONFIG_FILE="$CONF" CREAM_SECRETS_FILE="$ROOT/etc/cream/teleport/secrets" CREAM_ACTION="$a")
    case "$a" in
        set-managed|leave) env+=(CREAM_LOCK_FD=9 CREAM_LOCK_MODE=exclusive CREAM_OUTPUT=json) ;;
        managed-status) env+=(CREAM_OUTPUT=json) ;;
    esac
    env "${env[@]}" "$STAGED/actions/$a" "$@" 9>"$TMP/lock"
}
# conf KEY=VALUE… — the domain as join and the operator left it (fake cream set).
conf(){ cream set --no-apply --allow-readonly teleport "$@"; }
get(){
    local v
    v="$(sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -n 1)"
    if [[ "$v" == \"*\" ]]; then v="${v:1:${#v}-2}"; fi
    printf '%s' "$v"
}
# registered — what join from Stvor leaves: knobs, identity, a running agent
# with the rendered teleport.yaml. Two apps: a loopback port and a remote URL.
registered(){
    new_root
    conf TELEPORT_PROXY=teleport.example.org:443 TELEPORT_JOIN_METHOD=bound_keypair TELEPORT_TOKEN=robot-lab-1 \
        TELEPORT_ENV=prod TELEPORT_NODENAME=lab-1 "TELEPORT_LABELS=space=sp-1 site=lab" \
        "TELEPORT_APPS=web=8080 api=https://10.0.0.5:8443"
    mkdir -p "$ROOT/var/lib/teleport"; echo 11111111-2222 > "$HOST_UUID"
    touch "$FAKE/active"
    tp render 2>/dev/null || bad "registered: render"
    : > "$FAKE/systemctl.log"; : > "$FAKE/cream.log"
}
slog(){ cat "$FAKE/systemctl.log" 2>/dev/null; }
clog(){ cat "$FAKE/cream.log" 2>/dev/null; }
restarts(){ grep -cx 'restart teleport.service' "$FAKE/systemctl.log" 2>/dev/null; }
# yq <python expression over y> — a value from teleport.yaml parsed by PyYAML.
# eval is over the fixed expressions of this file only, never over input.
yq(){ python3 -c 'import sys, yaml; y = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$Y" "$1" 2>&1; }
node_labels(){ yq 'sorted(y["ssh_service"]["labels"].items())'; }
app_labels(){ yq "sorted(next(a for a in y['app_service']['apps'] if a['name'] == '$1')['labels'].items())"; }
node_cmds(){ yq '[(c["name"], c["command"]) for c in y["ssh_service"].get("commands", [])]'; }
json_ok(){ python3 -c 'import json,sys; o=json.loads(sys.stdin.read()); sys.exit(0 if isinstance(o, dict) else 1)' <<< "$1" 2>/dev/null; }
json_get(){ python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get(sys.argv[1]))' "$2" <<< "$1" 2>/dev/null; }
# same_as_fixture <output> <fixture> — the output is the fixture: the keys put
# in the order of the fixture (the reference sets it), then compared as bytes.
SAME_AS_FIXTURE='
import json, sys
ref_text = open(sys.argv[1]).read()
ref = json.loads(ref_text)
out = json.loads(sys.argv[2])
def order(o, r):
    if isinstance(o, dict) and isinstance(r, dict):
        keys = [k for k in r if k in o] + [k for k in o if k not in r]
        return {k: order(o[k], r.get(k)) for k in keys}
    return o
got = json.dumps(order(out, ref), separators=(",", ":"), ensure_ascii=False) + "\n"
if got != ref_text:
    sys.stderr.write("got " + got + "want " + ref_text)
    sys.exit(1)
'
same_as_fixture(){ python3 -c "$SAME_AS_FIXTURE" "$FIXTURES/$2" "$1"; }

# ===========================================================================
echo "== манифест: действия и ручка управляемых меток =="
manifest_action(){ sed -n "/^  $1:\$/,/^  [a-z-]*:\$/p" "$EXT/extension.yaml"; }
check "set-managed: args free" grep -qx '    args: free' <<< "$(manifest_action set-managed)"
check "set-managed: lock exclusive" grep -qx '    lock: exclusive' <<< "$(manifest_action set-managed)"
check "set-managed: output json" grep -qx '    output: json' <<< "$(manifest_action set-managed)"
check "managed-status: lock none" grep -qx '    lock: none' <<< "$(manifest_action managed-status)"
check "managed-status: output json" grep -qx '    output: json' <<< "$(manifest_action managed-status)"
check "TELEPORT_MANAGED_LABELS — readonly" grep -A1 -E '^    TELEPORT_MANAGED_LABELS:' "$EXT/extension.yaml" -q
check "TELEPORT_MANAGED_LABELS: readonly: true в манифесте" \
    bash -c 'sed -n "/^    TELEPORT_MANAGED_LABELS:/,/description/p" "$1" | grep -q "readonly: true"' _ "$EXT/extension.yaml"
check "действия-входы исполняемые" test -x "$EXT/actions/set-managed" -a -x "$EXT/actions/managed-status"

echo "== render: управляемые метки поверх операторских =="
registered
conf "TELEPORT_MANAGED_LABELS=env=stage space=sp-2"
check "render с управляемыми метками" tp render 2>/dev/null
eq "№2 space перекрыт, прочие метки оператора целы" "[('env', 'stage'), ('site', 'lab'), ('space', 'sp-2')]" "$(node_labels)"
eq "№3 управляемый env перекрывает TELEPORT_ENV" stage "$(yq 'y["ssh_service"]["labels"]["env"]')"
eq "№4/№65 копия в приложение web" "[('app', 'web'), ('env', 'stage'), ('site', 'lab'), ('space', 'sp-2')]" "$(app_labels web-lab-1)"
eq "№4/№65 копия в приложение api" "[('app', 'api'), ('env', 'stage'), ('site', 'lab'), ('space', 'sp-2')]" "$(app_labels api-lab-1)"
check_not "№5 прежнего space в teleport.yaml нет" grep -q 'sp-1' "$Y"
check_not "№6 env оператора в teleport.yaml не остался" grep -q '"prod"' "$Y"
eq "№6 env у узла и у каждого приложения" 3 "$(grep -c '"env": "stage"' "$Y")"
conf "TELEPORT_MANAGED_LABELS=space=sp-2"
tp render 2>/dev/null
eq "без управляемого env — TELEPORT_ENV" prod "$(yq 'y["ssh_service"]["labels"]["env"]')"
conf "TELEPORT_LABELS=site=lab" "TELEPORT_MANAGED_LABELS=space=sp-3 zone=a"
tp render 2>/dev/null
eq "№27 управляемый space без операторского" sp-3 "$(yq 'y["ssh_service"]["labels"]["space"]')"
eq "№28 порядок меток — по ключу" '"env": "prod"|"site": "lab"|"space": "sp-3"|"zone": "a"|' \
    "$(sed -n '/^ssh_service:/,/^  commands:/p' "$Y" | grep -E '^    "' | sed 's/^ *//' | tr '\n' '|')"
conf TELEPORT_LABELS= "TELEPORT_MANAGED_LABELS=space=sp-4"
check "№29 render при пустых TELEPORT_LABELS" tp render 2>/dev/null
eq "№30 метки из пустого списка" "[('env', 'prod'), ('space', 'sp-4')]" "$(node_labels)"
conf "TELEPORT_MANAGED_LABELS=app=x"
check_not "render: управляемый app (правка руками) — отказ" tp render 2>/dev/null
conf "TELEPORT_MANAGED_LABELS=os_logins=x"
check_not "render: управляемый os_logins — отказ" tp render 2>/dev/null
conf "TELEPORT_MANAGED_LABELS=space=a space=b"
check_not "render: ключ дважды — отказ" tp render 2>/dev/null
conf "TELEPORT_MANAGED_LABELS=$(for i in $(seq 1 17); do printf 'k%s=v ' "$i"; done)"
check_not "render: 17 управляемых меток — отказ" tp render 2>/dev/null
conf "TELEPORT_MANAGED_LABELS=$(for i in $(seq 1 16); do printf 'k%s=v ' "$i"; done)"
check "render: 16 управляемых меток — можно" tp render 2>/dev/null
conf "TELEPORT_MANAGED_LABELS=Space=x"
check_not "render: значение не по типу — отказ" tp render 2>/dev/null

echo "== set-managed: запись, один restart, без хука apply =="
registered
out="$(tp set-managed env=prod space=sp-2 2>"$TMP/err")"; rc=$?
eq "№1 set-managed — код 0" 0 "$rc"
check "set-managed: stdout — один JSON-объект" json_ok "$out"
eq "set-managed: result" applied "$(json_get "$out" result)"
eq "№1 управляемые метки записаны" "env=prod space=sp-2" "$(get TELEPORT_MANAGED_LABELS)"
eq "№7/№66 ровно один restart" 1 "$(restarts)"
check_not "№7 без reload" grep -q 'reload' <<< "$(slog)"
check "№8 вложенный cream set — --no-apply --allow-readonly" \
    grep -q '^cream set --no-apply --allow-readonly teleport TELEPORT_MANAGED_LABELS=env=prod space=sp-2 ' <<< "$(clog)"
check "№8 вложенный cream set — под унаследованной блокировкой" grep -q 'lock_fd=9' <<< "$(clog)"
check "№170 маркер записан до ручки" grep -q 'marker=yes' <<< "$(clog)"
check_not "№178 после подтверждённого restart маркера нет" test -e "$MARKER"
eq "teleport.yaml с новым space" sp-2 "$(yq 'y["ssh_service"]["labels"]["space"]')"
eq "teleport.yaml 0600" 600 "$(stat -c %a "$Y")"
check_not "кандидат не остался" test -e "$ROOT/etc/.teleport.yaml.candidate"
check_not "временных файлов рядом с teleport.yaml нет" compgen -G "$ROOT/etc/.teleport.yaml.*"
check "журнал: перезапуск" grep -q 'агент перезапущен' "$TMP/err"
check "set-managed applied — по образцу" same_as_fixture "$(tp set-managed env=prod space=sp-1 2>/dev/null)" set-managed-applied.json

echo "== set-managed: без изменений — unchanged, без restart =="
cp "$CONF" "$TMP/conf.before"; cp "$Y" "$TMP/yaml.before"
: > "$FAKE/systemctl.log"; : > "$FAKE/cream.log"
out="$(tp set-managed space=sp-1 env=prod 2>/dev/null)"; rc=$?
eq "№9 без изменений — код 0" 0 "$rc"
eq "№9 result unchanged" unchanged "$(json_get "$out" result)"
check "set-managed unchanged — по образцу" same_as_fixture "$out" set-managed-unchanged.json
eq "№10 без изменений — restart нет" 0 "$(restarts)"
check_not "№10 без изменений — systemctl только читает" grep -qvE '^(is-active|show) ' <<< "$(slog)"
check "№11 config тот же" cmp -s "$CONF" "$TMP/conf.before"
check "teleport.yaml не тронут" cmp -s "$Y" "$TMP/yaml.before"
check_not "без изменений — cream set не зовётся" test -s "$FAKE/cream.log"
check_not "без изменений — маркера нет" test -e "$MARKER"

echo "== первый тик после join: те же env и space — запись без restart, applied =="
registered
cp "$Y" "$TMP/yaml.before"
out="$(tp set-managed env=prod space=sp-1 2>/dev/null)"; rc=$?
eq "после join — код 0" 0 "$rc"
eq "после join — applied (ручка изменилась)" applied "$(json_get "$out" result)"
eq "после join — restart нет" 0 "$(restarts)"
check "после join — teleport.yaml не тронут" cmp -s "$Y" "$TMP/yaml.before"
eq "после join — ручка записана" "env=prod space=sp-1" "$(get TELEPORT_MANAGED_LABELS)"
check_not "после join — маркера нет" test -e "$MARKER"
check "после join — по образцу applied" same_as_fixture "$out" set-managed-applied.json

echo "== set-managed: полный набор — замена, а не слияние =="
registered
tp set-managed env=stage space=sp-2 >/dev/null 2>&1
out="$(tp set-managed space=sp-3 2>/dev/null)"; rc=$?
eq "№12 только space — код 0" 0 "$rc"
eq "№12 только space — набор заменён" space=sp-3 "$(get TELEPORT_MANAGED_LABELS)"
eq "№13 ручка TELEPORT_ENV не тронута" prod "$(get TELEPORT_ENV)"
eq "№13 env — снова TELEPORT_ENV" prod "$(yq 'y["ssh_service"]["labels"]["env"]')"
eq "№14 метки после частичной записи" "[('env', 'prod'), ('site', 'lab'), ('space', 'sp-3')]" "$(node_labels)"
out="$(tp set-managed 2>/dev/null)"; rc=$?
eq "без аргументов — снять все, код 0" 0 "$rc"
eq "без аргументов — набор пуст" "" "$(get TELEPORT_MANAGED_LABELS)"
eq "без аргументов — метки оператора вернулись" "[('env', 'prod'), ('site', 'lab'), ('space', 'sp-1')]" "$(node_labels)"
eq "без аргументов — managed пуст в JSON" "{}" "$(json_get "$out" managed)"
tp set-managed space=b env=a >/dev/null 2>&1
eq "набор хранится по ключу" "env=a space=b" "$(get TELEPORT_MANAGED_LABELS)"

echo "== set-managed: отказ на ввод — код 2 с JSON, ничего не тронуто =="
registered
tp set-managed env=prod space=sp-1 >/dev/null 2>&1
cp "$CONF" "$TMP/conf.before"; cp "$Y" "$TMP/yaml.before"
: > "$FAKE/systemctl.log"; : > "$FAKE/cream.log"
refuse(){ # refuse <№ and name> <args…>
    local what="$1" out rc; shift
    out="$(tp set-managed "$@" 2>"$TMP/err")"; rc=$?
    eq "$what — код 2" 2 "$rc"
    check "$what — JSON в stdout" json_ok "$out"
    check_not "$what — значение не в выводе" grep -qF 'EVIL' <<< "$out$(cat "$TMP/err")"
}
refuse "№15 чужой ключ app" app=x
refuse "№16 чужой ключ вместе с допустимым" space=sp-2 app=x
refuse "зарезервирован os_logins" os_logins=x
refuse "зарезервирован teleport.icon" teleport.icon=x
refuse "№17 ключ ручки" TELEPORT_ENV=prod
refuse "№19 space=A\"b" 'space=A"bEVIL'
refuse "№20 пустой space" space=
refuse "№21 перевод строки в значении" $'space=sp-2\nEVIL'
refuse "№22 заглавные" space=EVIL
refuse "№23 запятая" 'space=a,bEVIL'
refuse "№24 ключ дважды" space=a space=b
refuse "не KEY=VALUE" space
many=(); for i in $(seq 1 17); do many+=("k$i=v"); done
refuse "17 меток" "${many[@]}"
refuse "значение длиннее 63" "space=$(printf 'a%.0s' $(seq 1 64))"
check "№25 после отказов config не тронут" cmp -s "$CONF" "$TMP/conf.before"
check "после отказов teleport.yaml не тронут" cmp -s "$Y" "$TMP/yaml.before"
check_not "№26 после отказов systemctl не вызывался" test -s "$FAKE/systemctl.log"
check_not "после отказов cream set не вызывался" test -s "$FAKE/cream.log"
check_not "после отказов маркера нет" test -e "$MARKER"
out="$(tp set-managed space=x 2>/dev/null)"
echo 'TELEPORT_LABELS="app=x"' >> "$CONF"
out="$(tp set-managed space=y 2>"$TMP/err")"; rc=$?
eq "неверный домен — код 3" 3 "$rc"
check "неверный домен — JSON в stdout" json_ok "$out"

echo "== set-managed: restart не подтверждён — unconfirmed, маркер остаётся =="
registered
echo dead > "$FAKE/restart"
out="$(tp set-managed env=prod space=sp-2 2>"$TMP/err")"; rc=$?
eq "№31 агент не поднялся — код 1" 1 "$rc"
eq "№31 result unconfirmed" unconfirmed "$(json_get "$out" result)"
check "№32 текст: не подтвердил" grep -q 'не подтвердил перезапуск' "$TMP/err"
check "unconfirmed — маркер остался" test -e "$MARKER"
check "ожидание подтверждения — 30 снов по 1 с" test "$(grep -cx 'sleep 1' "$FAKE/sleep.log")" -eq 30
registered
rm -f "$FAKE/active"; echo dead > "$FAKE/restart"
out="$(tp set-managed env=prod space=sp-1 2>/dev/null)"; rc=$?
eq "неактивный агент не поднялся — код 1" 1 "$rc"
check "set-managed unconfirmed — по образцу" same_as_fixture "$out" set-managed-unconfirmed.json

registered
echo fail > "$FAKE/restart"
out="$(tp set-managed env=prod space=sp-2 2>/dev/null)"; rc=$?
eq "№169 restart упал, агент активен — код 1" 1 "$rc"
eq "№169 result unconfirmed" unconfirmed "$(json_get "$out" result)"
eq "№169 JSON: агент активен" True "$(json_get "$out" active)"
check "№170 restart упал — маркер остался" test -e "$MARKER"
eq "№172 restart упал — конфиг уже новый" "env=prod space=sp-2" "$(get TELEPORT_MANAGED_LABELS)"
eq "№172 teleport.yaml уже новый" sp-2 "$(yq 'y["ssh_service"]["labels"]["space"]')"
check "managed-status: pending после неудачи" grep -q '"pending":true' <<< "$(tp managed-status 2>/dev/null)"
echo ok > "$FAKE/restart"; : > "$FAKE/systemctl.log"
out="$(tp set-managed env=prod space=sp-2 2>/dev/null)"; rc=$?
eq "№177 следующий вызов — код 0" 0 "$rc"
eq "№177 при маркере — restart, хотя конфиг записан и агент активен" 1 "$(restarts)"
eq "№177 result applied" applied "$(json_get "$out" result)"
check_not "№178/№203 после перезапуска маркера нет" test -e "$MARKER"

registered
echo noop > "$FAKE/restart"
out="$(tp set-managed env=prod space=sp-2 2>/dev/null)"; rc=$?
eq "№181 restart без нового запуска — код 1" 1 "$rc"
eq "№181 result unconfirmed" unconfirmed "$(json_get "$out" result)"
check "№182 без нового запуска — маркер остался" test -e "$MARKER"

echo "== подтверждение по каждому из трёх свойств юнита =="
for mode in pid inv-empty ts; do
    registered
    echo "$mode" > "$FAKE/restart"
    out="$(tp set-managed env=prod space=sp-2 2>/dev/null)"; rc=$?
    eq "№188/№190 подтверждение ($mode) — код 0" 0 "$rc"
    eq "подтверждение ($mode) — applied" applied "$(json_get "$out" result)"
    check_not "№189 подтверждение ($mode) — маркера нет" test -e "$MARKER"
done
registered
echo gone > "$FAKE/restart"
out="$(tp set-managed env=prod space=sp-2 2>/dev/null)"; rc=$?
eq "свойство опустело или стало 0 — не новый запуск: код 1" 1 "$rc"
check "опустевшие свойства — маркер остался" test -e "$MARKER"

echo "== тик умер между записью и restart: следующий вызов рестартует =="
registered
# The knob and the marker are written, the restart never happened.
touch "$MARKER"; conf "TELEPORT_MANAGED_LABELS=env=prod space=sp-9"
out="$(tp set-managed env=prod space=sp-9 2>/dev/null)"; rc=$?
eq "№184 следующий вызов — код 0" 0 "$rc"
eq "№184 перезапуск на следующем вызове" 1 "$(restarts)"
eq "№185 teleport.yaml с новым space" sp-9 "$(yq 'y["ssh_service"]["labels"]["space"]')"
check_not "№187 маркера нет" test -e "$MARKER"

echo "== агент неактивен: restart (старт) даже без изменений =="
registered
tp set-managed env=prod space=sp-1 >/dev/null 2>&1
rm -f "$FAKE/active"; : > "$FAKE/systemctl.log"
out="$(tp set-managed env=prod space=sp-1 2>/dev/null)"; rc=$?
eq "неактивный агент — код 0" 0 "$rc"
eq "неактивный агент — restart" 1 "$(restarts)"
eq "неактивный агент — applied" applied "$(json_get "$out" result)"

echo "== deferred: не зарегистрирован — только запись =="
new_root
conf TELEPORT_PROXY=teleport.example.org:443 TELEPORT_ENV=prod TELEPORT_NODENAME=lab-1
out="$(tp set-managed env=prod space=sp-1 2>"$TMP/err")"; rc=$?
eq "№33 кластер есть, регистрации нет — код 0" 0 "$rc"
eq "№33 result deferred" deferred "$(json_get "$out" result)"
check "set-managed deferred — по образцу" same_as_fixture "$out" set-managed-deferred.json
eq "№34 deferred — restart нет" 0 "$(restarts)"
eq "№35 deferred — ручка записана" "env=prod space=sp-1" "$(get TELEPORT_MANAGED_LABELS)"
check_not "deferred — маркера нет" test -e "$MARKER"
check_not "deferred — teleport.yaml не создан" test -e "$Y"
new_root
out="$(tp set-managed env=prod space=sp-1 2>/dev/null)"; rc=$?
eq "кластер не задан — deferred" deferred "$(json_get "$out" result)"
eq "кластер не задан — restart нет" 0 "$(restarts)"

registered
rm -r -f -- "$ROOT/run"; : > "$FAKE/systemctl.log"
out="$(tp set-managed env=prod space=sp-2 2>"$TMP/err")"; rc=$?
eq "№36 без systemd — только запись, код 0" 0 "$rc"
eq "№36 без systemd — deferred" deferred "$(json_get "$out" result)"
eq "№36 без systemd — ручка записана" "env=prod space=sp-2" "$(get TELEPORT_MANAGED_LABELS)"
check_not "№37 без systemd — systemctl не вызывается" test -s "$FAKE/systemctl.log"
check "без systemd — журнал" grep -q 'systemd не запущен' "$TMP/err"

echo "== managed-status: образцы контракта, без побочных эффектов =="
new_root
out="$(tp managed-status 2>/dev/null)"; rc=$?
eq "managed-status: код 0" 0 "$rc"
check "managed-status not-joined — по образцу" same_as_fixture "$out" managed-status-not-joined.json
registered
tp set-managed env=prod space=sp-1 >/dev/null 2>&1
find "$ROOT" -path "$FAKE" -prune -o -printf '%p %s %T@\n' | sort > "$TMP/tree.before"
: > "$FAKE/systemctl.log"; : > "$FAKE/cream.log"
out="$(tp managed-status 2>/dev/null)"
check "managed-status joined — по образцу" same_as_fixture "$out" managed-status-joined.json
find "$ROOT" -path "$FAKE" -prune -o -printf '%p %s %T@\n' | sort > "$TMP/tree.after"
check "managed-status ничего не пишет" cmp -s "$TMP/tree.before" "$TMP/tree.after"
check_not "managed-status: systemctl только читает" grep -qvE '^(is-active|show) ' <<< "$(slog)"
check_not "managed-status: cream set не зовётся" test -s "$FAKE/cream.log"
touch "$MARKER"
check "managed-status pending — по образцу" same_as_fixture "$(tp managed-status 2>/dev/null)" managed-status-pending.json
rm -f "$MARKER" "$FAKE/active"
check "managed-status inactive — по образцу" same_as_fixture "$(tp managed-status 2>/dev/null)" managed-status-inactive.json
echo 'TELEPORT_MANAGED_LABELS="app=x"' >> "$CONF"
out="$(tp managed-status 2>/dev/null)"; rc=$?
eq "managed-status: зарезервированный ключ в домене — код 3" 3 "$rc"
check "managed-status: ошибка — тоже JSON" json_ok "$out"
check_not "managed-status: ошибка — без состояния" grep -q '"managed"' <<< "$out"
for f in "$FIXTURES"/*.json; do
    check "образец $(basename "$f") — JSON-объект" json_ok "$(cat "$f")"
done
eq "образцов 8" 8 "$(find "$FIXTURES" -maxdepth 1 -name '*.json' | wc -l)"

echo "== leave стирает управляемые метки и маркер =="
registered
tp set-managed env=prod space=sp-2 >/dev/null 2>&1
touch "$MARKER"; : > "$FAKE/cream.log"
out="$(tp leave 2>/dev/null)"; rc=$?
eq "№207 leave — код 0" 0 "$rc"
eq "№207 leave: управляемые метки стёрты" "" "$(get TELEPORT_MANAGED_LABELS)"
check "leave: через cream set --no-apply" grep -q '^cream set --no-apply --allow-readonly teleport .*TELEPORT_MANAGED_LABELS= ' <<< "$(clog)"
check_not "№212 leave: managed-pending удалён" test -e "$MARKER"
eq "leave: JSON" left "$(json_get "$out" result)"
check "после leave — managed-status not-joined" same_as_fixture "$(tp managed-status 2>/dev/null)" managed-status-not-joined.json

echo "== join не пишет управляемые метки =="
new_root
out="$(printf 'x' | tp join TELEPORT_PROXY=a.example.org "TELEPORT_MANAGED_LABELS=space=x" 2>"$TMP/err")"; rc=$?
check "join с TELEPORT_MANAGED_LABELS — отказ" test "$rc" -ne 0
check "join: отказ называет ключ" grep -q 'join не принимает TELEPORT_MANAGED_LABELS' "$TMP/err"
check "join: отказ — тоже JSON в stdout" json_ok "$out"
eq "join: отказ — result failed" failed "$(json_get "$out" result)"

echo "== командные метки command-labels.d =="
# mklabel <key> <line> — a label file 0644; the command exists under the root.
mklabel(){ printf '%s\n' "$2" > "$CMDS/$1"; chmod 0644 "$CMDS/$1"; }
mkcmd(){ printf '#!/bin/sh\necho 1\n' > "$ROOT$1"; chmod 0755 "$ROOT$1"; }
registered
mkcmd /usr/bin/stvor-agent
mklabel stvor_agent 'command=/usr/bin/stvor-agent version --label'
check "render с командной меткой" tp render 2>"$TMP/err"
eq "командная метка в ssh_service.commands" \
    "[('os_logins', ['/opt/cream/ext/teleport/files/os-logins']), ('stvor_agent', ['/usr/bin/stvor-agent', 'version', '--label'])]" \
    "$(node_cmds)"
eq "командная метка — период 5 мин" 5m0s "$(yq '[c["period"] for c in y["ssh_service"]["commands"]][1]')"
check_not "командной метки нет у приложений" grep -q 'stvor_agent' <<< "$(sed -n '/^app_service:/,$p' "$Y")"
check_not "допустимый файл — без строки журнала" grep -q 'пропускаю' "$TMP/err"
st="$(tp status 2>&1)"
check "status: командная метка с файлом" grep -qE "stvor_agent +/usr/bin/stvor-agent version --label +\\($CMDS/stvor_agent\\)" <<< "$st"
check "status: os_logins среди командных" grep -q 'os_logins .*TELEPORT_OS_LOGINS' <<< "$st"

# skipped <name> <key> — the file is skipped with a journal line, the rest is whole.
skipped(){
    local what="$1" key="$2"
    tp render 2>"$TMP/err"; local rc=$?
    eq "$what — render цел, код 0" 0 "$rc"
    check "$what — строка журнала" grep -q "пропускаю $CMDS/$key" "$TMP/err"
    check_not "$what — метки нет в teleport.yaml" grep -q "name: \"$key\"" "$Y"
    check "$what — прочие командные метки на месте" grep -q 'name: "stvor_agent"' "$Y"
    rm -f -- "$CMDS/$key"
}
mkcmd /usr/bin/probe
mklabel site 'command=/usr/bin/probe'
skipped "ключ-коллизия со статической меткой TELEPORT_LABELS" site
mklabel space 'command=/usr/bin/probe'
skipped "ключ space (управляемый/статический)" space
mklabel env 'command=/usr/bin/probe'
skipped "ключ env зарезервирован" env
conf TELEPORT_OS_LOGINS=0
mklabel os_logins 'command=/usr/bin/probe'
skipped "ключ os_logins зарезервирован" os_logins
conf TELEPORT_OS_LOGINS=1
conf "TELEPORT_MANAGED_LABELS=zone=a"
mklabel zone 'command=/usr/bin/probe'
skipped "ключ-коллизия с управляемой меткой" zone
conf TELEPORT_MANAGED_LABELS=
mklabel Bad_Key 'command=/usr/bin/probe'
skipped "ключ не по алфавиту" Bad_Key
echo "$ROOT/usr/bin/probe" >> "$FAKE/foreign"
mklabel probe1 'command=/usr/bin/probe'
skipped "путь — владелец не root" probe1
: > "$FAKE/foreign"
chmod 0775 "$ROOT/usr/bin/probe"
mklabel probe2 'command=/usr/bin/probe'
skipped "путь с записью группе" probe2
chmod 0755 "$ROOT/usr/bin/probe"
mklabel probe3 'command=/usr/bin/probe'; chmod 0664 "$CMDS/probe3"
skipped "файл метки с записью группе" probe3
mklabel probe4 'command=/usr/bin/probe'; echo "$CMDS/probe4" >> "$FAKE/foreign"
skipped "файл метки — владелец не root" probe4
: > "$FAKE/foreign"
mklabel probe5 'command=/usr/bin/probe a b c d e f g h i'
skipped "лишние аргументы (9)" probe5
mklabel probe6 'command=/usr/bin/probe a;id'
skipped "аргумент с ;" probe6
mklabel probe7 'command=/usr/bin/probe $(id)'
skipped "аргумент с \$(…)" probe7
mklabel probe8 'command=usr/bin/probe'
skipped "путь не абсолютный" probe8
mklabel probe9 'command=/usr/bin/../bin/probe'
skipped "путь с .." probe9
mklabel probe10 'command=/usr/bin/missing'
skipped "путь не существует" probe10
printf '#!/bin/sh\n' > "$ROOT/usr/bin/noexec"; chmod 0644 "$ROOT/usr/bin/noexec"
mklabel probe11 'command=/usr/bin/noexec'
skipped "путь не исполняемый" probe11
printf '%s\n' 'command=/usr/bin/probe' 'command=/usr/bin/probe' > "$CMDS/probe12"; chmod 0644 "$CMDS/probe12"
skipped "две строки" probe12
mklabel probe13 'cmd=/usr/bin/probe'
skipped "не command=" probe13
ln -s stvor_agent "$CMDS/probe14"
skipped "символическая ссылка" probe14
mklabel probe15 'command=/usr/bin/probe a b c d e f g h'
check "8 аргументов — можно" tp render 2>/dev/null
check "8 аргументов — в teleport.yaml" grep -q '"/usr/bin/probe", "a", "b", "c", "d", "e", "f", "g", "h"' "$Y"
rm -f "$CMDS/probe15"
# The whole chain up to the root: every directory above the command is root's,
# without write for group or others, and no symlink anywhere (the file too).
mkdir -p "$ROOT/opt/tool/bin"; chmod 0755 "$ROOT/opt" "$ROOT/opt/tool" "$ROOT/opt/tool/bin"
mkcmd /opt/tool/bin/probe
mklabel probe16 'command=/opt/tool/bin/probe'
check "команда в /opt/tool/bin — можно" tp render 2>/dev/null
check "команда в /opt/tool/bin — в teleport.yaml" grep -q 'name: "probe16"' "$Y"
chmod 0777 "$ROOT/opt/tool"
skipped "каталог над командой с записью всем" probe16
chmod 0755 "$ROOT/opt/tool"
chmod 0775 "$ROOT/opt"
mklabel probe17 'command=/opt/tool/bin/probe'
skipped "каталог-предок с записью группе" probe17
chmod 0755 "$ROOT/opt"
echo "$ROOT/opt/tool/bin" >> "$FAKE/foreign"
mklabel probe18 'command=/opt/tool/bin/probe'
skipped "каталог команды — владелец не root" probe18
: > "$FAKE/foreign"
ln -s bin "$ROOT/usr/lbin"
mklabel probe19 'command=/usr/lbin/probe'
skipped "каталог в пути — символическая ссылка" probe19
ln -s probe "$ROOT/usr/bin/probe-link"
mklabel probe20 'command=/usr/bin/probe-link'
skipped "команда — символическая ссылка" probe20
chmod 0777 "$ROOT"
tp render 2>"$TMP/err"; rc=$?
eq "корень с записью всем — render цел" 0 "$rc"
check "корень с записью всем — command-labels.d пропущен строкой журнала" grep -q "пропускаю $CMDS: каталог: каталог /: права" "$TMP/err"
check_not "корень с записью всем — командных меток нет" grep -q 'stvor_agent' "$Y"
chmod 0700 "$ROOT"
# Under these stvor-agent.service has ProtectHome/PrivateTmp, and a user may
# own them: no command from there, whatever the modes say.
for d in /home/u /tmp /var/tmp /run/user/0; do
    mkdir -p "$ROOT$d"; chmod 0755 "$ROOT$d" "$ROOT${d%/*}" 2>/dev/null
    mkcmd "$d/probe"
    mklabel probe22 "command=$d/probe"
    skipped "команда под $d" probe22
done
mklabel probe23 'command=//home/u/probe'
skipped "команда под //home" probe23
chmod 0775 "$ROOT/etc/cream/teleport"
tp render 2>"$TMP/err"; rc=$?
eq "каталог над command-labels.d с записью группе — render цел" 0 "$rc"
check "каталог над command-labels.d — строка журнала" grep -q "пропускаю $CMDS:" "$TMP/err"
check_not "каталог над command-labels.d — командных меток нет" grep -q 'stvor_agent' "$Y"
chmod 0755 "$ROOT/etc/cream/teleport"
echo "$ROOT/etc/cream" >> "$FAKE/foreign"
tp render 2>"$TMP/err"
check "предок command-labels.d не root — строка журнала" grep -q "пропускаю $CMDS:" "$TMP/err"
check_not "предок command-labels.d не root — командных меток нет" grep -q 'stvor_agent' "$Y"
: > "$FAKE/foreign"
tp render 2>/dev/null
check "цепочка снова цела — метка на месте" grep -q 'name: "stvor_agent"' "$Y"

echo "== apps.d: файл, каталог и цепочка до корня =="
APPS="$ROOT/etc/cream/teleport/apps.d"
chmod 0755 "$APPS"
printf 'NAME=code-server\nURI=https://127.0.0.1:9002\n' > "$APPS/code-server.conf"; chmod 0644 "$APPS/code-server.conf"
has_decl(){ tp render 2>"$TMP/err" && grep -q 'name: "code-server-lab-1"' "$Y"; }
check "apps.d: объявление опубликовано" has_decl
chmod 0775 "$APPS"
check_not "apps.d с записью группе — объявлений нет" has_decl
check "apps.d с записью группе — строка журнала" grep -q "пропускаю $APPS" "$TMP/err"
check "apps.d с записью группе — приложения оператора целы" grep -q 'name: "web-lab-1"' "$Y"
chmod 0755 "$APPS"
chmod 0777 "$ROOT/etc/cream/teleport"
check_not "каталог над apps.d с записью всем — объявлений нет" has_decl
chmod 0755 "$ROOT/etc/cream/teleport"
echo "$APPS" >> "$FAKE/foreign"
check_not "apps.d не root — объявлений нет" has_decl
: > "$FAKE/foreign"
echo "$APPS/code-server.conf" >> "$FAKE/foreign"
check_not "файл apps.d не root (и под корнем стенда) — пропущен" has_decl
check "файл apps.d не root — строка журнала" grep -q "пропускаю $APPS/code-server.conf" "$TMP/err"
: > "$FAKE/foreign"
mv "$APPS" "$ROOT/etc/cream/teleport/apps.real"; ln -s apps.real "$APPS"
check_not "apps.d — символическая ссылка: объявлений нет" has_decl
rm -f -- "$APPS"; mv "$ROOT/etc/cream/teleport/apps.real" "$APPS"
check "apps.d снова цел — объявление опубликовано" has_decl
rm -f -- "$APPS/code-server.conf"
tp render 2>/dev/null

for i in 1 2 3 4 5 6 7 8; do mklabel "m$i" 'command=/usr/bin/probe'; done
tp render 2>"$TMP/err"
eq "9 файлов — в teleport.yaml 8 командных меток (кроме os_logins)" 8 \
    "$(yq 'len([c for c in y["ssh_service"]["commands"] if c["name"] != "os_logins"])')"
check "9-й файл пропущен строкой журнала" grep -q "пропускаю $CMDS/stvor_agent: в $CMDS не больше 8" "$TMP/err"
rm -f "$CMDS"/m*
chmod 0775 "$CMDS"
tp render 2>"$TMP/err"; rc=$?
eq "каталог с записью группе — render цел" 0 "$rc"
check "каталог с записью группе — строка журнала" grep -q "пропускаю $CMDS: каталог: права" "$TMP/err"
check_not "каталог с записью группе — командных меток нет" grep -q 'stvor_agent' "$Y"
chmod 0755 "$CMDS"
conf TELEPORT_OS_LOGINS=0
tp render 2>/dev/null
eq "без os_logins — только командная метка" "[('stvor_agent', ['/usr/bin/stvor-agent', 'version', '--label'])]" "$(node_cmds)"
rm -f "$CMDS/stvor_agent"
tp render 2>/dev/null
check_not "ни os_logins, ни файлов — секции commands нет" grep -q 'commands:' "$Y"
check "teleport.yaml разбирается YAML-парсером" yq 'y["version"]' >/dev/null

echo "== status: управляемые и перекрытые метки =="
registered
tp set-managed env=stage space=sp-2 >/dev/null 2>&1
st="$(tp status 2>&1)"
check "status: управляемые метки" grep -q 'Управляемые метки: env=stage space=sp-2' <<< "$st"
check "status: space оператора перекрыт" grep -q 'space=sp-1 оператора — перекрыто управляемой меткой (space=sp-2)' <<< "$st"
check "status: env оператора перекрыт" grep -q 'env=prod оператора — перекрыто управляемой меткой (env=stage)' <<< "$st"
check_not "status: site не перекрыт" grep -q 'site=lab оператора' <<< "$st"
touch "$MARKER"
check "status: маркер managed-pending" grep -q 'managed-pending' <<< "$(tp status 2>&1)"

echo "== пин образцов контракта: tools/check-contract-fixtures.sh =="
CHK="$REPO/tools/check-contract-fixtures.sh"
check "пин набора совпадает" env -u CI STVOR_AGENT_DIR="$TMP/none" "$CHK" >/dev/null 2>&1
eq "пин — sha256 набора" "$(grep -oE '^[0-9a-f]{64}' "$REPO/tools/contract-fixtures.sha256")" "$("$CHK" --print)"
cp -a "$FIXTURES" "$TMP/fx"
printf 'X' | dd of="$TMP/fx/managed-status-joined.json" bs=1 seek=3 conv=notrunc status=none
check_not "порча байта образца — красный" env -u CI FIXTURES_DIR="$TMP/fx" STVOR_AGENT_DIR="$TMP/none" "$CHK" >/dev/null 2>&1
mkdir -p "$TMP/sa/internal/teleport/testdata"
cp "$FIXTURES"/*.json "$TMP/sa/internal/teleport/testdata/"
check "соседняя копия stvor-agent с тем же набором — зелёный" env -u CI STVOR_AGENT_DIR="$TMP/sa" "$CHK" >/dev/null 2>&1
printf ' ' >> "$TMP/sa/internal/teleport/testdata/set-managed-applied.json"
check_not "соседняя копия расходится — красный" env -u CI STVOR_AGENT_DIR="$TMP/sa" "$CHK" >/dev/null 2>&1
cp "$FIXTURES/set-managed-applied.json" "$TMP/sa/internal/teleport/testdata/"
echo '{}' > "$TMP/sa/internal/teleport/testdata/extra.json"
check_not "в соседней копии лишний образец — красный" env -u CI STVOR_AGENT_DIR="$TMP/sa" "$CHK" >/dev/null 2>&1
out="$(env -u CI STVOR_AGENT_DIR="$TMP/none" "$CHK" 2>&1)"; rc=$?
eq "нет соседней копии локально — пропуск, код 0" 0 "$rc"
check "нет соседней копии — предупреждение" grep -q 'сверка с stvor-agent пропущена' <<< "$out"
check_not "нет соседней копии в CI — красный" env CI=true STVOR_AGENT_DIR="$TMP/none" "$CHK" >/dev/null 2>&1

echo
echo "проверок: $((pass + fail)), не прошло: $fail"
(( fail == 0 ))
