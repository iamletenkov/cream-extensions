#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Тесты расширения teleport (cream/v1): join без сети при первой загрузке
# (сеть — ждать, отказ кластера — не повторять), файлы состояния 0600,
# стирание секрета первого входа, тик повтора (join-retry), идемпотентность,
# блокировка cream вместо своей, status, render, хуки install/upgrade/remove/
# apply — на подменённом корне (CREAM_ROOT) с поддельными systemctl,
# journalctl, curl, teleport, dpkg и cream. root, systemd и сеть не нужны.
#
# Перенос stvor-agent tests/test-join.sh (3.x) на пути и имена cream: действия
# зовутся напрямую (actions/<имя>) с окружением, которое дал бы `cream run`;
# поддельный `cream set` пишет файл домена и журнал вызовов.
#
#   extensions/debian/teleport/tests/test-join.sh     код 0 — все проверки прошли

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"

TMP="$(mktemp -d)"
PWN_DIR=""
trap 'rm -r -f -- "$TMP" ${PWN_DIR:+"$PWN_DIR"}' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
# fd 3: the real stderr — a check called with 2>/dev/null must still report.
exec 3>&2
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&3; }
check(){ local what="$1"; shift; if "$@"; then ok; else bad "$what"; fi; }
check_not(){ local what="$1"; shift; if "$@"; then bad "$what"; else ok; fi; }
eq(){ local what="$1" want="$2" got="$3"; if [[ "$want" == "$got" ]]; then ok; else bad "$what: ждали [$want], получили [$got]"; fi; }

SECRET='Zk3_q9-RobotSecret-0123456789abcdef'
JOIN_TOKEN='abcdefgh1-join-token'
PROXY=teleport.example.org:443
# The arguments of the firstboot line of Stvor, as is (ruling РТ1: one secret
# on stdin, TELEPORT_TOKEN — the bound_keypair token name).
STVOR_ARGS=(TELEPORT_PROXY="$PROXY" TELEPORT_JOIN_METHOD=bound_keypair TELEPORT_TOKEN=robot-lab-1
            TELEPORT_REGISTRATION_SECRET=- TELEPORT_ENV=dev TELEPORT_NODENAME=lab-1
            TELEPORT_LABELS=space=sp-0123abcd)

# ---------------------------------------------------------------------------
# Scratch root and fakes
# ---------------------------------------------------------------------------
# FAKE: switches and logs of the fakes.
#   net          curl: a code (6 DNS, 7 connect, 28 timeout, 60 TLS), "up" or
#                "html" (200 without server_version: a captive portal)
#   agent        what `systemctl start teleport.service` does:
#                  join   — the agent registers (host_uuid appears)
#                  refuse — the agent logs a refusal (journal.refuse)
#                  hang   — the agent logs a network error and keeps trying
#                  fail   — the start fails
#   active       exists — teleport.service is active
#   find         the body of /webapi/find with net=up (default: server 18.10.0)
#   journal      what journalctl prints
#   tarball      what curl -o downloads; cdn.sha256 — the .sha256 of the CDN
#   *.log        every call of systemctl, curl, cream, flock; ps.log — `ps`
#                snapshots taken by the fake teleport
BASE_PATH="$PATH"
new_root(){
    ROOT="$(mktemp -d "$TMP/root.XXXXXX")"
    FAKE="$ROOT/fake"
    mkdir -p "$ROOT/bin" "$FAKE" "$ROOT/opt/cream/ext" "$ROOT/usr/local/bin" \
        "$ROOT/etc/cream/teleport" "$ROOT/var/lib/cream/ext/teleport"
    cp -a "$EXT" "$ROOT/opt/cream/ext/teleport"
    rm -r -f -- "$ROOT/opt/cream/ext/teleport/tests"
    fake_teleport 18.10.0 "$ROOT/usr/local/bin/teleport"
    echo 7 > "$FAKE/net"
    echo join > "$FAKE/agent"
    cat > "$ROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/curl.log"
out=""; prev=""
for a in "$@"; do [[ "$prev" == -o ]] && out="$a"; prev="$a"; done
if [[ -n "$out" ]]; then
    [[ -f "$FAKE/tarball" ]] || exit 22
    cp "$FAKE/tarball" "$out"; exit 0
fi
if [[ "${!#}" == *.sha256 ]]; then
    [[ -f "$FAKE/cdn.sha256" ]] || exit 22
    echo "$(cat "$FAKE/cdn.sha256")  teleport.tar.gz"; exit 0
fi
net="$(cat "$FAKE/net")"
if [[ "$net" == up ]]; then
    if [[ -f "$FAKE/find" ]]; then cat "$FAKE/find"; else echo '{"server_version":"18.10.0"}'; fi
    exit 0
fi
if [[ "$net" == html ]]; then echo '<html>captive portal</html>'; exit 0; fi
exit "$net"
EOF
    cat > "$ROOT/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/journalctl.log"
cat "$FAKE/journal" 2>/dev/null
exit 0
EOF
    cat > "$ROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/systemctl.log"
args=" $* "
case "${1:-}" in
    is-active)
        [[ "${2:-}" == --quiet ]] && shift
        if [[ "${2:-}" == teleport.service ]]; then [[ -f "$FAKE/active" ]]; exit; fi
        echo active; exit 0 ;;
    is-enabled) echo disabled; exit 1 ;;
    show) exit 0 ;;
    start)
        [[ "$args" == *" teleport.service "* ]] || exit 0
        case "$(cat "$FAKE/agent")" in
            fail) exit 1 ;;
            join) mkdir -p "$CREAM_ROOT/var/lib/teleport"
                  echo 55555555-6666 > "$CREAM_ROOT/var/lib/teleport/host_uuid" ;;
            refuse) cp "$FAKE/journal.refuse" "$FAKE/journal" ;;
            hang) printf '%s\n' 'ERRO Failed to establish connection to cluster. identity:Instance error:[dial tcp 10.0.0.1:443: connect: connection refused]' > "$FAKE/journal" ;;
        esac
        touch "$FAKE/active" ;;
    stop) [[ "$args" == *" teleport.service "* ]] && rm -f "$FAKE/active" ;;
    disable) [[ "$args" == *" --now "* && "$args" == *" teleport.service "* ]] && rm -f "$FAKE/active" ;;
esac
exit 0
EOF
    # cream: only `set` is used by the extension. It writes the domain file
    # in the grammar of cream (bare or "…" with \" \\) and logs argv and the
    # inherited lock descriptor; KEY=- reads stdin (one trailing newline off).
    cat > "$ROOT/bin/cream" <<'EOF'
#!/usr/bin/env bash
printf 'cream %s lock_fd=%s\n' "$*" "${CREAM_LOCK_FD:-}" >> "$FAKE/cream.log"
[[ "${1:-}" == set ]] || { echo "fake cream: ${1:-} не поддержан" >&2; exit 64; }
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
for p in "$@"; do
    k="${p%%=*}"; v="${p#*=}"
    if [[ "$v" == - ]]; then v="$(cat)"; fi
    V[$k]="$v"
done
mkdir -p "$(dirname "$conf")"
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
chmod 0644 "$tmp"; mv -f "$tmp" "$conf"
echo "teleport: изменено"
EOF
    printf '#!/bin/sh\necho flock "$@" >> "$FAKE/flock.log"\nexit 0\n' > "$ROOT/bin/flock"
    printf '#!/bin/sh\necho amd64\n' > "$ROOT/bin/dpkg"
    # Waits count their sleeps: a fake sleep makes the 120 s join wait instant.
    printf '#!/bin/sh\necho sleep "$@" >> "$FAKE/sleep.log"\nexit 0\n' > "$ROOT/bin/sleep"
    chmod +x "$ROOT/bin/"*
    use_root "$ROOT"
}
# fake_teleport <version> <path>: `teleport version` that also snapshots argv
# of every process (the secret must never be in one).
fake_teleport(){
    cat > "$2" <<EOF
#!/bin/sh
ps -eo args >> "\$FAKE/ps.log" 2>/dev/null
echo "Teleport v$1 git: go1.25"
EOF
    chmod +x "$2"
}
# Switch to a scratch root made earlier by new_root.
use_root(){
    ROOT="$1"; FAKE="$ROOT/fake"
    STAGED="$ROOT/opt/cream/ext/teleport"
    export FAKE CREAM_ROOT="$ROOT"
    export PATH="$ROOT/bin:$BASE_PATH"
    CONF="$ROOT/etc/cream/teleport/config"
    STATE="$ROOT/var/lib/cream/ext/teleport"
    PENDING="$STATE/join-pending"
    REFUSED="$STATE/join-refused"
    SECRET_FILE="$STATE/registration-secret"
    HOST_UUID="$ROOT/var/lib/teleport/host_uuid"
}
SYSTEMD=1
PHASE=live
# The environment `cream run` / a hook gets (cream spec §6.3, §7.2); lock/teleport
# as descriptor 9 for exclusive actions.
cream_env=()
mk_env(){
    cream_env=(CREAM_PHASE="$PHASE" CREAM_EXT=teleport CREAM_EXT_VERSION=4.0.0
        CREAM_EXT_DIR="$STAGED" CREAM_ETC_DIR="$ROOT/etc/cream/teleport" CREAM_STATE_DIR="$STATE"
        CREAM_ROOT="$ROOT" CREAM_CONFIG_FILE="$CONF" CREAM_SECRETS_FILE="$ROOT/etc/cream/teleport/secrets")
    # systemd "runs" in the scratch root: the sd_booted marker under it.
    if (( SYSTEMD )); then mkdir -p "$ROOT/run/systemd/system"; else rm -r -f -- "$ROOT/run"; fi
}
# tp <action> [args…] — `cream run teleport <action>`.
tp(){
    local a="$1"; shift
    mk_env
    case "$a" in
        join|join-retry|leave|scrub-token) cream_env+=(CREAM_LOCK_FD=9 CREAM_LOCK_MODE=exclusive) ;;
    esac
    env "${cream_env[@]}" CREAM_ACTION="$a" "$STAGED/actions/$a" "$@" 9>"$TMP/lock"
}
# hk <hook> [KEY=VALUE…] — a hook with these domain keys in the environment.
hk(){
    local h="$1"; shift
    mk_env
    env "${cream_env[@]}" "$@" "$STAGED/hooks/$h" 9>"$TMP/lock"
}
# The firstboot line of Stvor: printf without a newline into join.
stvor_line(){ printf '%s' "$SECRET" | tp join "${STVOR_ARGS[@]}" "$@"; }
# get KEY — the value in the domain file (the grammar of the fake cream).
get(){
    local v
    v="$(sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -n 1)"
    if [[ "$v" == \"*\" ]]; then v="${v:1:${#v}-2}"; fi
    printf '%s' "$v"
}
field(){ sed -n "s/^$1=//p" "$2"; }
slog(){ cat "$FAKE/systemctl.log" 2>/dev/null; }
clog(){ cat "$FAKE/cream.log" 2>/dev/null; }
refusal_journal(){ printf '%s\n' "INFO Starting Teleport" "$1" > "$FAKE/journal.refuse"; }
# manifest_action <name> — the block of one action in extension.yaml.
manifest_action(){ sed -n "/^  $1:\$/,/^  [a-z-]*:\$/p" "$EXT/extension.yaml"; }
# json_ok <text> — exactly one JSON object.
json_ok(){ python3 -c 'import json,sys; o=json.loads(sys.stdin.read()); sys.exit(0 if isinstance(o, dict) else 1)' <<< "$1" 2>/dev/null; }
# json_get <text> <key>
json_get(){ python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get(sys.argv[1]))' "$2" <<< "$1" 2>/dev/null; }

# ===========================================================================
echo "== нет сети при первой загрузке: строка Stvor выходит с кодом 0 =="
for code in 6 7 28 60; do
    new_root
    echo "$code" > "$FAKE/net"
    msg="$(stvor_line 2>&1)"; rc=$?
    eq "curl $code: код 0" 0 "$rc"
    check "curl $code: файл ожидания есть" test -f "$PENDING"
done
# The last root of the loop is curl 60: a fresh machine's clock may be wrong.
check "curl 60: причина — TLS/часы" grep -q 'TLS' "$PENDING"

new_root
echo 6 > "$FAKE/net"
out="$(stvor_line 2>"$TMP/err")"; rc=$?
msg="$(cat "$TMP/err")"
eq "DNS: код 0" 0 "$rc"
check "DNS: понятное сообщение" grep -q 'сеть или прокси .* недоступны' <<< "$msg"
check "DNS: сообщение называет status" grep -q 'cream run teleport status' <<< "$msg"
check_not "секрет не попал в вывод" grep -qF "$SECRET" <<< "$msg$out"
check "DNS: stdout — один JSON-объект" json_ok "$out"
eq "DNS: JSON result" pending "$(json_get "$out" result)"
eq "DNS: JSON pending" True "$(json_get "$out" pending)"
eq "секрет сохранён" "$SECRET" "$(cat "$SECRET_FILE")"
eq "файл секрета 0600" 600 "$(stat -c %a "$SECRET_FILE")"
eq "файл ожидания 0600" 600 "$(stat -c %a "$PENDING")"
eq "каталог состояния 0700" 700 "$(stat -c %a "$(dirname "$PENDING")")"
check_not "секрета нет в домене: файла secrets нет" test -e "$ROOT/etc/cream/teleport/secrets"
check_not "секрета нет в файле ожидания" grep -qF "$SECRET" "$PENDING"
check_not "секрета нет в config" grep -qF "$SECRET" "$CONF"
eq "параметры: прокси" "$PROXY" "$(get TELEPORT_PROXY)"
eq "параметры: метод" bound_keypair "$(get TELEPORT_JOIN_METHOD)"
eq "параметры: имя токена" robot-lab-1 "$(get TELEPORT_TOKEN)"
eq "параметры: env" dev "$(get TELEPORT_ENV)"
eq "параметры: имя ноды" lab-1 "$(get TELEPORT_NODENAME)"
eq "параметры: метки" space=sp-0123abcd "$(get TELEPORT_LABELS)"
eq "попытка 1" 1 "$(field attempts "$PENDING")"
SINCE1="$(field since "$PENDING")"
check "причина — DNS" grep -q '^error=.*DNS' "$PENDING"
check "teleport.yaml ссылается на секрет" grep -q "registration_secret_path: \"/var/lib/cream/ext/teleport/registration-secret\"" "$ROOT/etc/teleport.yaml"
check "юниты повтора включены" grep -qx 'enable teleport-join.service teleport-join.timer' <<< "$(slog)"
check "таймер запущен без ожидания" grep -qx 'start --no-block teleport-join.timer' <<< "$(slog)"
check_not "агент не стартовал" grep -qx 'start teleport.service' <<< "$(slog)"
check_not "агент не включён" grep -qx 'enable teleport.service' <<< "$(slog)"
check_not "rollback убран" test -e "$STATE/rollback"
msg="$(tp status 2>&1)"
check "status: ждёт сети" grep -q 'Регистрация: ждёт сети — попыток 1' <<< "$msg"
check "status: последняя ошибка" grep -q 'последняя попытка: .*DNS' <<< "$msg"
check_not "status не печатает секрет" grep -qF "$SECRET" <<< "$msg"
# Новое (риск R4): запись ручек — вложенный cream set под унаследованной
# блокировкой, без своей flock; секрет не в argv ни одного процесса.
check "домен пишет вложенный cream set --no-apply --allow-readonly" \
    grep -q '^cream set --no-apply --allow-readonly teleport ' <<< "$(clog)"
check "вложенный cream set наследует блокировку (CREAM_LOCK_FD)" \
    grep -q '^cream set .* lock_fd=9$' <<< "$(clog)"
check_not "секрета нет в argv cream" grep -qF "$SECRET" <<< "$(clog)"
check "ps-снимок поддельного teleport сделан" test -s "$FAKE/ps.log"
check_not "секрета нет в argv процессов (ps)" grep -qF "$SECRET" "$FAKE/ps.log"
check_not "своей flock нет" test -e "$FAKE/flock.log"
check_not "файла .join.lock нет" test -n "$(find "$ROOT" -name '.join.lock' 2>/dev/null)"

DNS_ROOT="$ROOT"
new_root
echo html > "$FAKE/net"
msg="$(stvor_line 2>&1)"; rc=$?
eq "ответ не от Teleport: код 0" 0 "$rc"
check "ответ не от Teleport: ждёт" grep -q '^error=.*не от прокси Teleport' "$PENDING"
check_not "ответ не от Teleport: агент не стартовал" grep -qx 'start teleport.service' <<< "$(slog)"

echo "== тик повтора: сети всё ещё нет =="
# Back to the DNS root of above.
use_root "$DNS_ROOT"
: > "$FAKE/systemctl.log"
msg="$(tp join-retry 2>&1)"; rc=$?
eq "тик без сети — код 0" 0 "$rc"
eq "попытка 2" 2 "$(field attempts "$PENDING")"
check "тик пишет номер попытки" grep -q 'попыток: 2' <<< "$msg"
check_not "тик без сети агента не стартует" grep -q 'start teleport.service' <<< "$(slog)"
echo 28 > "$FAKE/net"
tp join-retry 2>/dev/null
eq "попытка 3" 3 "$(field attempts "$PENDING")"
check "последняя ошибка — таймаут" grep -q '^error=.*таймаут' "$PENDING"
eq "since — время первой попытки" "$SINCE1" "$(field since "$PENDING")"
eq "секрет на месте" "$SECRET" "$(cat "$SECRET_FILE")"

echo "== тик повтора: сеть появилась, регистрация =="
echo up > "$FAKE/net"; echo join > "$FAKE/agent"; : > "$FAKE/systemctl.log"
msg="$(tp join-retry 2>&1)"; rc=$?
eq "тик с сетью — код 0" 0 "$rc"
check "зарегистрирован" test -s "$HOST_UUID"
check_not "секрет стёрт" test -e "$SECRET_FILE"
check_not "файл ожидания убран" test -e "$PENDING"
check_not "отказа нет" test -e "$REFUSED"
check_not "teleport.yaml без пути секрета" grep -q 'registration_secret_path' "$ROOT/etc/teleport.yaml"
check "teleport.yaml: имя токена bound_keypair осталось" grep -q 'token_name: "robot-lab-1"' "$ROOT/etc/teleport.yaml"
check "агент стартовал" grep -qx 'start teleport.service' <<< "$(slog)"
check "агент включён" grep -qx 'enable teleport.service' <<< "$(slog)"
check "таймер выключен" grep -qx 'disable --now teleport-join.timer' <<< "$(slog)"
check "служба повтора выключена (без --now)" grep -qx 'disable teleport-join.service' <<< "$(slog)"
eq "имя токена осталось" robot-lab-1 "$(get TELEPORT_TOKEN)"
check "status: зарегистрирован" grep -q 'Регистрация: есть' <<< "$(tp status 2>&1)"

echo "== идемпотентность =="
: > "$FAKE/systemctl.log"
msg="$(tp join-retry 2>&1)"; rc=$?
eq "тик без ожидания — код 0" 0 "$rc"
check "тик без ожидания — нечего повторять" grep -q 'ждущего подключения нет' <<< "$msg"
check_not "тик без ожидания агента не трогает" grep -q 'teleport.service' <<< "$(slog)"
out="$(stvor_line 2>"$TMP/err")"; rc=$?
msg="$(cat "$TMP/err")"
eq "повтор строки Stvor на зарегистрированном — код 0" 0 "$rc"
check "повтор — уже зарегистрирован" grep -q 'уже зарегистрирован' <<< "$msg"
eq "повтор — JSON result" registered "$(json_get "$out" result)"
check_not "повтор не пишет секрет заново" test -e "$SECRET_FILE"
eq "регистрация цела" 55555555-6666 "$(cat "$HOST_UUID")"

echo "== агент зарегистрировался сам, пока join ждал =="
new_root
echo 7 > "$FAKE/net"
stvor_line >/dev/null 2>&1
mkdir -p "$ROOT/var/lib/teleport"; echo 77777777-8888 > "$HOST_UUID"
: > "$FAKE/systemctl.log"
check "scrub-token (path-юнит)" tp scrub-token 2>/dev/null
check_not "scrub-token: секрет стёрт" test -e "$SECRET_FILE"
check_not "scrub-token: ожидание снято" test -e "$PENDING"
check "scrub-token: таймер выключен" grep -qx 'disable --now teleport-join.timer' <<< "$(slog)"
new_root
echo 7 > "$FAKE/net"
stvor_line >/dev/null 2>&1
mkdir -p "$ROOT/var/lib/teleport"; echo 77777777-8888 > "$HOST_UUID"
msg="$(tp join-retry 2>&1)"; rc=$?
eq "тик после регистрации — код 0" 0 "$rc"
check_not "тик: секрет стёрт" test -e "$SECRET_FILE"
check_not "тик: ожидание снято" test -e "$PENDING"
check_not "тик не перезапускал агента" grep -qx 'start teleport.service' <<< "$(slog)"

echo "== отказ кластера при первом join: не повторять =="
refusals=(
    'ERRO Failed to establish connection to cluster. identity:Instance error:[a valid registration secret is required]|секрет регистрации неверен или истёк'
    'ERRO Can not join the cluster, the token is expired or not found. Regenerate the token and try again.|токен регистрации не найден'
    'ERRO Failed to establish connection to cluster. error:[access denied: no recovery attempts remaining]|токен уже использован'
    'ERRO Failed to establish connection to cluster. error:[can not join the cluster, the token does not allow role Node]|токен не подходит'
)
for entry in "${refusals[@]}"; do
    new_root
    echo up > "$FAKE/net"; echo refuse > "$FAKE/agent"
    refusal_journal "${entry%|*}"
    : > "$FAKE/systemctl.log"
    out="$(stvor_line 2>"$TMP/err")"; rc=$?
    msg="$(cat "$TMP/err")"
    want="${entry##*|}"
    check "отказ «$want»: код ≠ 0" test "$rc" -ne 0
    check "отказ «$want»: причина в выводе" grep -qF "$want" <<< "$msg"
    check "отказ «$want»: подсказка про новый секрет в Stvor" grep -q 'карточке робота Stvor' <<< "$msg"
    check "отказ «$want»: причина записана" grep -qF "reason=$want" "$REFUSED"
    eq "отказ «$want»: файл отказа 0600" 600 "$(stat -c %a "$REFUSED")"
    check_not "отказ «$want»: ожидания нет" test -e "$PENDING"
    check_not "отказ «$want»: секрет стёрт" test -e "$SECRET_FILE"
    check_not "отказ «$want»: повторы не включены" grep -q 'enable teleport-join' <<< "$(slog)"
    check "отказ «$want»: агент выключен" grep -qx 'disable --now teleport.service' <<< "$(slog)"
    check_not "отказ «$want»: агент не активен" test -e "$FAKE/active"
done
eq "отказ: JSON result" refused "$(json_get "$out" result)"
check "отказ: JSON reason — причина" grep -q 'токен не подходит' <<< "$(json_get "$out" reason)"
msg="$(tp status 2>&1)"
check "status: отказ и причина" grep -q 'Регистрация: отказ кластера — токен не подходит' <<< "$msg"
check "status: ответ агента" grep -q 'ответ агента: .*does not allow role' <<< "$msg"
check "status: что делать" grep -q 'карточке робота Stvor' <<< "$msg"

echo "== сеть, потом отказ: тик не повторяет =="
new_root
echo 6 > "$FAKE/net"
stvor_line >/dev/null 2>&1
echo up > "$FAKE/net"; echo refuse > "$FAKE/agent"
refusal_journal 'ERRO Failed to establish connection to cluster. error:[a valid registration secret is required]'
: > "$FAKE/systemctl.log"
msg="$(tp join-retry 2>&1)"; rc=$?
check "тик с отказом — код ≠ 0" test "$rc" -ne 0
check "тик: причина записана" grep -q 'reason=секрет регистрации неверен или истёк' "$REFUSED"
check_not "тик: ожидание снято" test -e "$PENDING"
check_not "тик: секрет стёрт" test -e "$SECRET_FILE"
check "тик: таймер выключен" grep -qx 'disable --now teleport-join.timer' <<< "$(slog)"
check "тик: агент выключен" grep -qx 'disable --now teleport.service' <<< "$(slog)"

echo "== прокси отвечает, регистрация не подтвердилась, отказа нет: ждать =="
new_root
echo up > "$FAKE/net"; echo hang > "$FAKE/agent"
msg="$(stvor_line 2>&1)"; rc=$?
eq "без подтверждения — код 0" 0 "$rc"
check "без подтверждения — ожидание" test -f "$PENDING"
check "ошибка агента записана" grep -q '^error=прокси отвечает, регистрация не подтвердилась.*connection refused' "$PENDING"
eq "без подтверждения — секрет на месте" "$SECRET" "$(cat "$SECRET_FILE")"
check "без подтверждения — повторы включены" grep -qx 'enable teleport-join.service teleport-join.timer' <<< "$(slog)"
check "агент оставлен работать" test -e "$FAKE/active"
: > "$FAKE/systemctl.log"
tp join-retry 2>/dev/null
check_not "тик не стартует работающий агент заново" grep -qx 'start teleport.service' <<< "$(slog)"
eq "тик: попытка 2" 2 "$(field attempts "$PENDING")"
# The agent registers on its own between the ticks.
mkdir -p "$ROOT/var/lib/teleport"; echo 99999999-0000 > "$HOST_UUID"
tp join-retry 2>/dev/null
check_not "после регистрации ожидание снято" test -e "$PENDING"
check_not "после регистрации секрет стёрт" test -e "$SECRET_FILE"

echo "== агент не стартовал: ждать, не отказ =="
new_root
echo up > "$FAKE/net"; echo fail > "$FAKE/agent"
msg="$(stvor_line 2>&1)"; rc=$?
eq "старт не удался — код 0" 0 "$rc"
check "старт не удался — ожидание" grep -q 'teleport.service не стартовал' "$PENDING"
check_not "старт не удался — не отказ" test -e "$REFUSED"

echo "== новый join снимает отказ =="
new_root
echo up > "$FAKE/net"; echo refuse > "$FAKE/agent"
refusal_journal 'ERRO Failed to establish connection to cluster. error:[a valid registration secret is required]'
stvor_line >/dev/null 2>&1
check "отказ записан" test -f "$REFUSED"
rm -f "$FAKE/journal"; echo join > "$FAKE/agent"
out="$(stvor_line 2>/dev/null)"; rc=$?
eq "join с новым секретом — код 0" 0 "$rc"
eq "join с новым секретом — JSON result" registered "$(json_get "$out" result)"
eq "join с новым секретом — JSON joined" True "$(json_get "$out" joined)"
check_not "отказ снят" test -e "$REFUSED"
check "зарегистрирован" test -s "$HOST_UUID"
check_not "секрет стёрт" test -e "$SECRET_FILE"

echo "== тик без секрета и без кластера =="
new_root
echo 7 > "$FAKE/net"
stvor_line >/dev/null 2>&1
rm -f "$SECRET_FILE"
msg="$(tp join-retry 2>&1)"; rc=$?
check "тик без секрета — код ≠ 0" test "$rc" -ne 0
check "тик без секрета — отказ записан" grep -q 'reason=секрета регистрации на машине нет' "$REFUSED"
check_not "тик без секрета — ожидание снято" test -e "$PENDING"

echo "== блокировка — cream: join и тик без своей flock =="
# Было: свой .join.lock, тик под чужой блокировкой — пропуск. Стало: cream
# держит lock/teleport (действия lock: exclusive, спека §10.6); у расширения
# ни flock, ни файла блокировки.
new_root
echo 7 > "$FAKE/net"
stvor_line >/dev/null 2>&1
msg="$(tp join-retry 2>&1)"; rc=$?
eq "тик — код 0" 0 "$rc"
eq "тик засчитан" 2 "$(field attempts "$PENDING")"
check_not "join и тик не зовут flock" test -e "$FAKE/flock.log"
check_not "в состоянии нет файла блокировки" test -n "$(find "$ROOT" -name '*.lock' 2>/dev/null)"
check_not "в коде нет flock" grep -q 'flock' "$EXT/files/teleport.sh"
for a in join join-retry leave scrub-token; do
    check "манифест: $a — lock: exclusive" grep -qx '    lock: exclusive' <<< "$(manifest_action "$a")"
done
for a in render reload-apps status; do
    check "манифест: $a — lock: none" grep -qx '    lock: none' <<< "$(manifest_action "$a")"
done

echo "== leave снимает ожидание =="
: > "$FAKE/systemctl.log"
out="$(tp leave 2>/dev/null)"; rc=$?
eq "leave — код 0" 0 "$rc"
check "leave: stdout — один JSON-объект" json_ok "$out"
check_not "leave: ожидание снято" test -e "$PENDING"
check_not "leave: секрет стёрт" test -e "$SECRET_FILE"
check "leave: таймер повтора выключен" grep -qx 'disable --now teleport-join.timer' <<< "$(slog)"
eq "leave: прокси стёрт" "" "$(get TELEPORT_PROXY)"
eq "leave: имя токена стёрто" "" "$(get TELEPORT_TOKEN)"
check "status после leave: нет" grep -q 'Регистрация: нет' <<< "$(tp status 2>&1)"

echo "== без systemd (сборка образа): как раньше =="
new_root
SYSTEMD=0
echo 7 > "$FAKE/net"
out="$(stvor_line 2>"$TMP/err")"; rc=$?
msg="$(cat "$TMP/err")"
eq "без systemd — код 0" 0 "$rc"
check "без systemd — агент стартует при загрузке" grep -q 'systemd не запущен' <<< "$msg"
eq "без systemd — JSON result" written "$(json_get "$out" result)"
check_not "без systemd — ожидания нет" test -e "$PENDING"
check_not "без systemd — systemctl не зовётся" test -s "$FAKE/systemctl.log"
SYSTEMD=1

echo "== зарегистрированная машина: недоступный прокси — отказ, как раньше =="
new_root
echo up > "$FAKE/net"; echo join > "$FAKE/agent"
stvor_line >/dev/null 2>&1
echo 7 > "$FAKE/net"
msg="$(stvor_line TELEPORT_FORCE=1 2>&1)"; rc=$?
check "FORCE без сети на зарегистрированной — код ≠ 0" test "$rc" -ne 0
check "FORCE без сети — регистрацию не трогает" grep -q 'рабочую регистрацию не трогаю' <<< "$msg"
check_not "FORCE без сети — ожидания нет" test -e "$PENDING"
eq "FORCE без сети — регистрация цела" 55555555-6666 "$(cat "$HOST_UUID")"

echo "== версия кластера из /webapi/find — внешний ввод, не арифметика bash =="
# bash evaluates a[$(cmd)] inside (( )): a hostile proxy would run cmd as root.
# The marker path has no dots: the version is split on them.
PWN_DIR="$(mktemp -d /tmp/pwnXXXXXX)"
for v in 'a[$(touch PWN)]' '1.2.3$(touch PWN)' '18.10.0+x[$(touch PWN)]' '18.x.0' '99999999999.0.0'; do
    new_root
    pwn="$PWN_DIR/pwn"; rm -f -- "$pwn"
    printf '{"server_version":"%s"}\n' "${v//PWN/$pwn}" > "$FAKE/find"
    echo up > "$FAKE/net"; echo join > "$FAKE/agent"
    out="$(stvor_line 2>"$TMP/err")"; rc=$?
    msg="$(cat "$TMP/err")"
    check_not "версия '$v': команда не выполнена" test -e "$pwn"
    eq "версия '$v': код 0, ждём" 0 "$rc"
    eq "версия '$v': JSON result" pending "$(json_get "$out" result)"
    check "версия '$v': строка журнала о версии" grep -q 'версию не по форме X.Y.Z' <<< "$msg"
    check_not "версия '$v': агент не стартовал" grep -qx 'start teleport.service' <<< "$(slog)"
    tp join-retry >/dev/null 2>&1
    check_not "версия '$v': тик — команда не выполнена" test -e "$pwn"
    check "версия '$v': тик — ждёт дальше" grep -q '^error=.*не по форме' "$PENDING"
done
new_root
printf '{"server_version":"18.10.0-rc.1+abc"}\n' > "$FAKE/find"
echo up > "$FAKE/net"; echo join > "$FAKE/agent"
msg="$(stvor_line 2>&1)"; rc=$?
eq "версия с суффиксом -rc.1+abc — код 0" 0 "$rc"
check "версия с суффиксом — зарегистрирован" test -s "$HOST_UUID"
check "версия с суффиксом — в журнале X.Y.Z" grep -q 'кластер 18.10.0, агент' <<< "$msg"
new_root
printf '{"server_version":"20.0.0"}\n' > "$FAKE/find"
echo up > "$FAKE/net"
msg="$(stvor_line 2>&1)"; rc=$?
check "кластер 20.0.0 при агенте 18 — отказ" test "$rc" -ne 0
check "кластер 20.0.0 — текст про мажор" grep -q 'больше чем на мажор' <<< "$msg"
# Leading zeros are decimal: 18.09.0 is older than the agent 18.10.0 (no octal
# error), 18.010.0 is the same version.
new_root
printf '{"server_version":"18.09.0"}\n' > "$FAKE/find"
echo up > "$FAKE/net"; echo join > "$FAKE/agent"
msg="$(stvor_line 2>&1)"; rc=$?
check "кластер 18.09.0 при агенте 18.10.0 — отказ" test "$rc" -ne 0
check "кластер 18.09.0 — агент новее" grep -q 'новее кластера 18.09.0' <<< "$msg"
check_not "кластер 18.09.0 — без ошибки арифметики" grep -q 'value too great\|syntax error' <<< "$msg"
new_root
printf '{"server_version":"18.010.0"}\n' > "$FAKE/find"
echo up > "$FAKE/net"; echo join > "$FAKE/agent"
msg="$(stvor_line 2>&1)"; rc=$?
eq "кластер 18.010.0 (десятичная) — код 0" 0 "$rc"
check "кластер 18.010.0 — зарегистрирован" test -s "$HOST_UUID"
rm -r -f -- "$PWN_DIR"; PWN_DIR=""

echo "== метод token: join-токен — секрет первого входа (рулинг РТ1) =="
new_root
echo up > "$FAKE/net"; echo hang > "$FAKE/agent"
out="$(printf '%s\n' "$JOIN_TOKEN" | tp join TELEPORT_PROXY=teleport.example.org \
    TELEPORT_REGISTRATION_SECRET=- TELEPORT_NODENAME=robot-1 TELEPORT_ENV=dev \
    "TELEPORT_LABELS=site=lab space=sp-aaaaaaaa" 2>/dev/null)"; rc=$?
eq "token: код 0" 0 "$rc"
eq "token: метод" token "$(get TELEPORT_JOIN_METHOD)"
eq "token: TELEPORT_TOKEN пуст" "" "$(get TELEPORT_TOKEN)"
check_not "token: токена нет в домене" grep -qF "$JOIN_TOKEN" "$CONF"
check_not "token: токена нет в argv cream" grep -qF "$JOIN_TOKEN" <<< "$(clog)"
check_not "token: токена нет в argv процессов (ps)" grep -qF "$JOIN_TOKEN" "$FAKE/ps.log"
eq "token: токен в файле секрета" "$JOIN_TOKEN" "$(cat "$SECRET_FILE")"
eq "token: файл секрета 0600" 600 "$(stat -c %a "$SECRET_FILE")"
check "token: teleport.yaml — token_name" grep -q "token_name: \"$JOIN_TOKEN\"" "$ROOT/etc/teleport.yaml"
check "token: teleport.yaml — method token" grep -q 'method: token' "$ROOT/etc/teleport.yaml"
# test-map SA №215–217: join со старым набором ключей; списки — через пробел.
eq "join: метки записаны (№216)" "site=lab space=sp-aaaaaaaa" "$(get TELEPORT_LABELS)"
check "join: teleport.yaml собран со space (№217)" grep -q '"space": "sp-aaaaaaaa"' "$ROOT/etc/teleport.yaml"
check "join: teleport.yaml с site (№215)" grep -q '"site": "lab"' "$ROOT/etc/teleport.yaml"
mkdir -p "$ROOT/var/lib/teleport"; echo 11111111-2222 > "$HOST_UUID"
tp scrub-token 2>/dev/null
check_not "token: после регистрации секрет стёрт" test -e "$SECRET_FILE"
check_not "token: после регистрации токена нет в teleport.yaml" grep -qF "$JOIN_TOKEN" "$ROOT/etc/teleport.yaml"
check_not "token: после регистрации join_params нет" grep -q 'join_params' "$ROOT/etc/teleport.yaml"
new_root
msg="$(printf '%s' "$JOIN_TOKEN" | tp join TELEPORT_PROXY=teleport.example.org TELEPORT_TOKEN=abcdefgh1 \
    TELEPORT_REGISTRATION_SECRET=- 2>&1)"; rc=$?
check "token: TELEPORT_TOKEN у метода token — отказ" test "$rc" -ne 0
check "token: текст про секрет первого входа" grep -q 'TELEPORT_REGISTRATION_SECRET=-' <<< "$msg"
check_not "token: при отказе домен не тронут" test -e "$CONF"
msg="$(tp join TELEPORT_PROXY=teleport.example.org TELEPORT_REGISTRATION_SECRET="$JOIN_TOKEN" 2>&1 </dev/null)"; rc=$?
check "секрет значением в argv — отказ" test "$rc" -ne 0
check_not "секрет в argv — не записан" test -e "$SECRET_FILE"
msg="$(tp join TELEPORT_PROXY=teleport.example.org 2>&1 </dev/null)"; rc=$?
check "join без секрета первого входа — отказ" test "$rc" -ne 0
check "join без секрета — текст" grep -q 'нужен секрет первого входа' <<< "$msg"

echo "== TELEPORT_DEFER=1: записать, ничего не включать =="
new_root
echo up > "$FAKE/net"
out="$(stvor_line TELEPORT_DEFER=1 2>/dev/null)"; rc=$?
eq "defer: код 0" 0 "$rc"
eq "defer: JSON result" deferred "$(json_get "$out" result)"
check "defer: ожидание записано" test -f "$PENDING"
eq "defer: секрет записан" "$SECRET" "$(cat "$SECRET_FILE")"
check "defer: teleport.yaml собран" test -f "$ROOT/etc/teleport.yaml"
check_not "defer: systemctl не зовётся" test -s "$FAKE/systemctl.log"
check_not "defer: прокси не опрашивался" grep -qs webapi "$FAKE/curl.log"
msg="$(tp join-retry 2>&1)"; rc=$?
eq "defer: join-retry — код 0" 0 "$rc"
check "defer: join-retry зарегистрировал" test -s "$HOST_UUID"
check_not "defer: после регистрации ожидания нет" test -e "$PENDING"

echo "== имя ноды и метки по итоговым ручкам — в preflight, до записей =="
# fake_hostname <name>: `hostname -s` of the machine.
fake_hostname(){ printf '#!/bin/sh\necho %s\n' "$1" > "$ROOT/bin/hostname"; chmod +x "$ROOT/bin/hostname"; }
# A machine registered in old.example.org without TELEPORT_NODENAME (the name
# came from a good hostname); then the hostname turns bad_host and Stvor moves
# it to another proxy: join must fail with JSON before it touches anything.
moved_root(){
    new_root
    echo up > "$FAKE/net"; echo join > "$FAKE/agent"
    fake_hostname good-host
    printf '%s' "$SECRET" | tp join TELEPORT_PROXY=old.example.org TELEPORT_JOIN_METHOD=bound_keypair \
        TELEPORT_TOKEN=robot-lab-1 TELEPORT_REGISTRATION_SECRET=- TELEPORT_ENV=dev >/dev/null 2>&1 \
        || bad "moved_root: первый join"
    test -s "$HOST_UUID" || bad "moved_root: не зарегистрирован"
    cp -a "$CONF" "$TMP/conf.before"
    cp -a "$ROOT/etc/teleport.yaml" "$TMP/yaml.before"
    : > "$FAKE/systemctl.log"; : > "$FAKE/cream.log"
}
# untouched <what>: domain, teleport.yaml, registration and state as before.
untouched(){
    check "$1: домен не тронут" cmp -s "$TMP/conf.before" "$CONF"
    check "$1: teleport.yaml не тронут" cmp -s "$TMP/yaml.before" "$ROOT/etc/teleport.yaml"
    eq "$1: регистрация цела" 55555555-6666 "$(cat "$HOST_UUID" 2>/dev/null)"
    check_not "$1: rollback не создан" test -e "$STATE/rollback"
    check_not "$1: секрет не записан" test -e "$SECRET_FILE"
    check_not "$1: cream set не звался" test -s "$FAKE/cream.log"
    check_not "$1: агент не останавливался" grep -q 'stop teleport.service' <<< "$(slog)"
}
moved_root
fake_hostname bad_host
out="$(printf '%s' "$SECRET" | tp join TELEPORT_PROXY=new.example.org TELEPORT_JOIN_METHOD=bound_keypair \
    TELEPORT_TOKEN=robot-lab-1 TELEPORT_REGISTRATION_SECRET=- TELEPORT_ENV=dev 2>"$TMP/err")"; rc=$?
eq "hostname bad_host — код 1" 1 "$rc"
check "hostname bad_host — stdout один JSON-объект" json_ok "$out"
eq "hostname bad_host — JSON result" failed "$(json_get "$out" result)"
check "hostname bad_host — причина про имя ноды" grep -q 'имя ноды' <<< "$(json_get "$out" reason)"
untouched "hostname bad_host"
out="$(printf '%s' "$SECRET" | tp join TELEPORT_PROXY=new.example.org TELEPORT_JOIN_METHOD=bound_keypair \
    TELEPORT_TOKEN=robot-lab-1 TELEPORT_REGISTRATION_SECRET=- TELEPORT_NODENAME=lab-9 2>/dev/null)"; rc=$?
eq "hostname bad_host, но TELEPORT_NODENAME задан — код 0" 0 "$rc"
eq "TELEPORT_NODENAME задан — переезд состоялся" new.example.org:443 "$(get TELEPORT_PROXY)"

# The labels in the domain (a hand edit) are the final ones when join does not
# pass TELEPORT_LABELS: a reserved key fails before any write.
moved_root
sed -i '/^TELEPORT_LABELS=/d' "$CONF"; echo 'TELEPORT_LABELS=env=x' >> "$CONF"
cp -a "$CONF" "$TMP/conf.before"
out="$(printf '%s' "$SECRET" | tp join TELEPORT_PROXY=new.example.org TELEPORT_JOIN_METHOD=bound_keypair \
    TELEPORT_TOKEN=robot-lab-1 TELEPORT_REGISTRATION_SECRET=- 2>/dev/null)"; rc=$?
eq "метка env в домене — код 1" 1 "$rc"
eq "метка env в домене — JSON result" failed "$(json_get "$out" result)"
check "метка env в домене — причина" grep -q "TELEPORT_LABELS: ключ 'env' зарезервирован" <<< "$(json_get "$out" reason)"
untouched "метка env в домене"

echo "== секрет регистрации: граница 1000 знаков в манифесте и в скрипте =="
# RE2 of cream allows at most 1000 repetitions: both sides say {8,1000}.
eq "манифест: тип TELEPORT_REGISTRATION_SECRET" "TELEPORT_REGISTRATION_SECRET: {type: 're:^[[:graph:]]{8,1000}\$', secret: true}" \
    "$(manifest_action join | grep -o 'TELEPORT_REGISTRATION_SECRET: .*')"
check "скрипт: RE_REG_SECRET той же границы" grep -qx "RE_REG_SECRET='^\[\[:graph:\]\]{8,1000}\\\$'" "$EXT/files/teleport.sh"
for n in 1000 1001; do
    new_root
    echo 7 > "$FAKE/net"
    long="$(printf 'k%.0s' $(seq "$n"))"
    out="$(printf '%s' "$long" | tp join "${STVOR_ARGS[@]}" 2>/dev/null)"; rc=$?
    if (( n == 1000 )); then
        eq "секрет 1000 знаков — код 0" 0 "$rc"
    else
        eq "секрет 1001 знак — код 1" 1 "$rc"
        eq "секрет 1001 знак — JSON failed" failed "$(json_get "$out" result)"
        check_not "секрет 1001 знак — не записан" test -e "$SECRET_FILE"
    fi
done

echo "== TELEPORT_FORCE и TELEPORT_DEFER — bool до арифметики =="
PWN_DIR="$(mktemp -d /tmp/pwnXXXXXX)"
for key in TELEPORT_FORCE TELEPORT_DEFER; do
    for v in 'a[$(touch PWN)]' 2 yes ' 1' ''; do
        new_root
        echo up > "$FAKE/net"; echo join > "$FAKE/agent"
        pwn="$PWN_DIR/pwn"; rm -f -- "$pwn"
        out="$(stvor_line "$key=${v//PWN/$pwn}" 2>"$TMP/err")"; rc=$?
        check_not "$key='$v': команда не выполнена" test -e "$pwn"
        eq "$key='$v': код 1" 1 "$rc"
        eq "$key='$v': JSON result" failed "$(json_get "$out" result)"
        check "$key='$v': причина называет ключ" grep -q "$key" <<< "$(json_get "$out" reason)"
        check_not "$key='$v': домен не тронут" test -e "$CONF"
        check_not "$key='$v': агент не тронут" test -s "$FAKE/systemctl.log"
    done
done
rm -r -f -- "$PWN_DIR"; PWN_DIR=""
new_root
echo up > "$FAKE/net"; echo join > "$FAKE/agent"
out="$(stvor_line TELEPORT_FORCE=0 TELEPORT_DEFER=0 2>/dev/null)"; rc=$?
eq "TELEPORT_FORCE=0 TELEPORT_DEFER=0 — код 0" 0 "$rc"
eq "TELEPORT_FORCE=0 TELEPORT_DEFER=0 — registered" registered "$(json_get "$out" result)"

echo "== render: без меток агента 3.x, os_logins из дерева расширения =="
new_root
echo up > "$FAKE/net"
stvor_line >/dev/null 2>&1
Y="$ROOT/etc/teleport.yaml"
check_not "render: нет managed_by" grep -q managed_by "$Y"
check_not "render: нет bisquite_agent_version" grep -q bisquite_agent_version "$Y"
check "render: os_logins — files/os-logins" grep -q 'command: \["/opt/cream/ext/teleport/files/os-logins"\]' "$Y"
check "render: env узла" grep -q '"env": "dev"' "$Y"
eq "render: teleport.yaml 0600" 600 "$(stat -c %a "$Y")"
mkdir -p "$ROOT/etc/cream/teleport/apps.d"
printf 'NAME=code-server\nURI=https://127.0.0.1:9002\nICON=mcpVscode\n' > "$ROOT/etc/cream/teleport/apps.d/code-server.conf"
chmod 0644 "$ROOT/etc/cream/teleport/apps.d/code-server.conf"
check "render из apps.d" tp render 2>/dev/null
check "render: приложение из /etc/cream/teleport/apps.d" grep -q 'name: "code-server-lab-1"' "$Y"
check "render: метки узла копируются в приложение" grep -q '"space": "sp-0123abcd"' <<< "$(sed -n '/name: "code-server-lab-1"/,$p' "$Y")"
echo 'TELEPORT_LABELS="app=x"' >> "$CONF"
check_not "render: зарезервированный ключ app — отказ" tp render 2>/dev/null
echo 'TELEPORT_LABELS="a=b\"c"' >> "$CONF"
check_not "render: значение не по типу — отказ" tp render 2>/dev/null
printf '%s\n' 'root:x:0:0::/root:/bin/bash' 'svc:x:999:999::/:/bin/bash' 'ann:x:1000:1000::/home/ann:/bin/bash' \
    'nob:x:65534:65534::/:/bin/bash' 'bot:x:1001:1001::/:/usr/sbin/nologin' > "$ROOT/etc/passwd"
eq "os-logins: root и uid ≥ 1000 с shell" "ann,root" "$(CREAM_ROOT="$ROOT" "$EXT/files/os-logins")"
# The uid field meets (( )): a[$(cmd)] there would run cmd; 01000 is decimal.
PWN_DIR="$(mktemp -d /tmp/pwnXXXXXX)"
printf '%s\n' 'root:x:0:0::/root:/bin/bash' "evil:x:a[\$(touch $PWN_DIR/pwn)]:0::/:/bin/bash" \
    'zed:x:01000:1000::/:/bin/bash' 'big:x:99999999999999999999:1:::/bin/bash' > "$ROOT/etc/passwd"
eq "os-logins: uid не цифрами — пропущен, 01000 — десятичный" "root,zed" "$(CREAM_ROOT="$ROOT" "$EXT/files/os-logins" 2>&1)"
check_not "os-logins: команда из uid не выполнена" test -e "$PWN_DIR/pwn"
rm -r -f -- "$PWN_DIR"; PWN_DIR=""

echo "== боевой скрипт без тестовых переключателей =="
check_not "teleport.sh: нет TELEPORT_TEST_*" grep -q 'TELEPORT_TEST_' "$EXT/files/teleport.sh"
check "ожидание регистрации — 120 с, константа" grep -qx 'JOIN_TIMEOUT=120' "$EXT/files/teleport.sh"
new_root
echo up > "$FAKE/net"; echo hang > "$FAKE/agent"
msg="$(stvor_line 2>&1)"
check "join ждёт до 120 с" grep -q 'жду регистрации (до 120 с)' <<< "$msg"
eq "join ждёт 60 снов по 2 с" 60 "$(grep -c '^sleep 2$' "$FAKE/sleep.log")"

echo "== хук apply: render и reload без ожидания =="
new_root
echo up > "$FAKE/net"
stvor_line >/dev/null 2>&1
: > "$FAKE/systemctl.log"
check "apply: код 0" hk apply 2>/dev/null
check "apply: reload-or-restart без ожидания" grep -qx -- '--no-block reload-or-restart teleport.service' <<< "$(slog)"
check_not "apply: в хуке нет systemctl без --no-block" \
    grep -nE '^[[:space:]]*systemctl (reload|restart|reload-or-restart) ' <(sed -n '/^cmd_apply(){/,/^}/p' "$EXT/files/teleport.sh")

echo "== хук install: бинарь Teleport =="
# make_tarball <version> — a tarball with teleport/teleport of that version.
make_tarball(){
    local d; d="$(mktemp -d "$TMP/tar.XXXXXX")"
    mkdir -p "$d/teleport"
    fake_teleport "$1" "$d/teleport/teleport"
    tar -czf "$FAKE/tarball" -C "$d" teleport
    TB_SHA="$(sha256sum "$FAKE/tarball" | cut -d' ' -f1)"
}
new_root
rm -f "$ROOT/usr/local/bin/teleport"
make_tarball 18.11.0
: > "$FAKE/systemctl.log"
msg="$(hk install TELEPORT_VERSION=18.11.0 TELEPORT_SHA256="$TB_SHA" TELEPORT_MIRROR=https://mirror.example.org 2>&1)"; rc=$?
eq "install: код 0" 0 "$rc"
check "install: бинарь на месте" grep -q 'v18.11.0' <<< "$("$ROOT/usr/local/bin/teleport" version)"
check "install: тарбол с зеркала" grep -q 'https://mirror.example.org/binaries/teleport/18.11.0/teleport-v18.11.0-linux-amd64-bin.tar.gz' "$FAKE/curl.log"
eq "install: apps.d 0755" 755 "$(stat -c %a "$ROOT/etc/cream/teleport/apps.d")"
eq "install: command-labels.d 0755" 755 "$(stat -c %a "$ROOT/etc/cream/teleport/command-labels.d")"
check "install: daemon-reload" grep -qx 'daemon-reload' <<< "$(slog)"
check "install: path-юниты включены" grep -qx 'enable --now teleport-apps.path teleport-token.path' <<< "$(slog)"
check_not "install: агент не стартует" grep -q 'teleport.service' <<< "$(slog)"
check_not "install: не регистрирует" test -e "$ROOT/etc/teleport.yaml"
: > "$FAKE/curl.log"
msg="$(hk install TELEPORT_VERSION=18.11.0 TELEPORT_SHA256="$TB_SHA" 2>&1)"; rc=$?
eq "install повторно: код 0" 0 "$rc"
check "install повторно: уже установлен" grep -q 'уже установлен' <<< "$msg"
check_not "install повторно: ничего не скачивал" test -s "$FAKE/curl.log"
make_tarball 18.12.0
: > "$FAKE/systemctl.log"
hk install TELEPORT_VERSION=18.12.0 TELEPORT_SHA256="$TB_SHA" >/dev/null 2>&1
check "install новой версии: бинарь сменился" grep -q 'v18.12.0' <<< "$("$ROOT/usr/local/bin/teleport" version)"
check "install новой версии: try-restart агента" grep -qx -- '--no-block try-restart teleport.service' <<< "$(slog)"
make_tarball 18.13.0
: > "$FAKE/curl.log"
echo "$TB_SHA" > "$FAKE/cdn.sha256"
check "install без суммы: .sha256 с CDN" hk install TELEPORT_VERSION=18.13.0 2>/dev/null
check "install без суммы: запрошен .sha256" grep -q 'teleport-v18.13.0-linux-amd64-bin.tar.gz.sha256' "$FAKE/curl.log"

new_root
rm -f "$ROOT/usr/local/bin/teleport"
make_tarball 18.11.0
msg="$(hk install TELEPORT_VERSION=18.11.0 TELEPORT_SHA256="$(printf '0%.0s' {1..64})" 2>&1)"; rc=$?
check "install: сумма не та — отказ" test "$rc" -ne 0
check "install: сумма не та — текст" grep -q 'sha256 не совпал' <<< "$msg"
check_not "install: сумма не та — бинаря нет" test -e "$ROOT/usr/local/bin/teleport"
: > "$FAKE/curl.log"
cp "$FAKE/tarball" "$TMP/local.tar.gz"
msg="$(hk install TELEPORT_VERSION=18.11.0 TELEPORT_SHA256="$TB_SHA" TELEPORT_MIRROR=https://mirror.example.org \
    TELEPORT_TARBALL="$TMP/local.tar.gz" 2>&1)"; rc=$?
check "install: TARBALL и MIRROR вместе — отказ" test "$rc" -ne 0
check "install: TARBALL и MIRROR — текст" grep -q 'взаимоисключимы' <<< "$msg"
check_not "install: TARBALL и MIRROR — без скачивания" test -s "$FAKE/curl.log"
msg="$(hk install TELEPORT_VERSION=18.11.0 TELEPORT_TARBALL="$TMP/local.tar.gz" 2>&1)"; rc=$?
check "install: TARBALL без суммы — отказ" test "$rc" -ne 0
msg="$(hk install TELEPORT_VERSION=18.11.0 TELEPORT_SHA256="$TB_SHA" TELEPORT_TARBALL="$TMP/local.tar.gz" 2>&1)"; rc=$?
eq "install: офлайн из TARBALL — код 0" 0 "$rc"
check "install: офлайн — бинарь на месте" grep -q 'v18.11.0' <<< "$("$ROOT/usr/local/bin/teleport" version)"
check_not "install: офлайн — curl не зовётся" test -s "$FAKE/curl.log"

new_root
mkdir -p "$ROOT/var/lib/teleport"; echo 12345678-0000 > "$HOST_UUID"
PHASE=build; SYSTEMD=0
msg="$(hk install 2>&1)"; rc=$?
PHASE=live; SYSTEMD=1
check "install в build с регистрацией — отказ" test "$rc" -ne 0
check "install в build с регистрацией — текст" grep -q 'одной нодой на все копии' <<< "$msg"

echo "== хук remove: регистрация, бинарь и состояние стёрты =="
new_root
echo up > "$FAKE/net"; echo join > "$FAKE/agent"
stvor_line >/dev/null 2>&1
: > "$FAKE/systemctl.log"
check "remove: код 0" hk remove 2>/dev/null
check_not "remove: регистрации нет" test -e "$HOST_UUID"
check_not "remove: бинаря нет" test -e "$ROOT/usr/local/bin/teleport"
check_not "remove: состояния нет" test -e "$STATE"
check_not "remove: teleport.yaml нет" test -e "$ROOT/etc/teleport.yaml"
check "remove: агент выключен" grep -qx 'disable --now teleport.service' <<< "$(slog)"
check "remove: path-юниты выключены" grep -qx 'disable --now teleport-apps.path teleport-token.path' <<< "$(slog)"

echo "== типы ручек: teleport.sh и extension.yaml совпадают =="
while IFS= read -r line; do
    key="${line%%]=*}"; key="${key#*[}"; t="${line#*]=}"
    t="${t#\'}"; t="${t%\'}"
    if [[ "$t" == bool ]]; then
        check "тип $key — bool в манифесте" grep -qE "^    $key: \{type: bool" "$EXT/extension.yaml"
    else
        check "тип $key совпадает с манифестом" grep -qF "$key: {type: '$t'" "$EXT/extension.yaml"
    fi
done < <(sed -n '/^declare -A KEY_TYPE=(/,/^)/p' "$EXT/files/teleport.sh" | grep -E '^\s+\[TELEPORT_')

echo "== юниты =="
U="$EXT/files"
check "служба повтора: после network-online" grep -qx 'After=network-online.target' "$U/teleport-join.service"
check "служба повтора: Wants network-online" grep -qx 'Wants=network-online.target' "$U/teleport-join.service"
check "служба повтора: условие — файл ожидания" grep -qx 'ConditionPathExists=/var/lib/cream/ext/teleport/join-pending' "$U/teleport-join.service"
check "служба повтора: зовёт join-retry через cream, ждёт блокировку join (≥ 6m)" \
    grep -qx 'ExecStart=/usr/bin/cream run --lock-timeout 6m teleport join-retry' "$U/teleport-join.service"
# The wait for the lock (6 min) plus the action itself (timeout 5m) fit the unit.
eq "служба повтора: TimeoutStartSec вмещает ожидание и действие" "TimeoutStartSec=12min" \
    "$(grep '^TimeoutStartSec=' "$U/teleport-join.service")"
check "служба повтора: при каждой загрузке" grep -qx 'WantedBy=multi-user.target' "$U/teleport-join.service"
check "таймер: раз в минуту" grep -qx 'OnCalendar=minutely' "$U/teleport-join.timer"
check "путь файла ожидания — тот же, что в библиотеке" grep -q 'JOIN_PENDING="$STATE/join-pending"' "$EXT/files/teleport.sh"
check "teleport.service: ExecStartPre — render через cream" grep -qx 'ExecStartPre=/usr/bin/cream run teleport render' "$U/teleport.service"
check "teleport.service: ExecReload — render через cream" grep -qx 'ExecReload=/usr/bin/cream run teleport render' "$U/teleport.service"
# A restart inside set-managed: lock ≤ 20 s + restart + confirmation ≤ 30 s
# within the 90 s of the stvor-agent adapter; the default stop is 90 s alone.
check "teleport.service: TimeoutStopSec=30s" grep -qx 'TimeoutStopSec=30s' "$U/teleport.service"
check "teleport-apps.path: apps.d" grep -qx 'PathChanged=/etc/cream/teleport/apps.d' "$U/teleport-apps.path"
check "teleport-apps.path: command-labels.d" grep -qx 'PathChanged=/etc/cream/teleport/command-labels.d' "$U/teleport-apps.path"
check "teleport-apps.service: reload-apps" grep -qx 'ExecStart=/usr/bin/cream run teleport reload-apps' "$U/teleport-apps.service"
check "teleport-token.service: RemainAfterExit" grep -qx 'RemainAfterExit=yes' "$U/teleport-token.service"
check "teleport-token.service: scrub-token ждёт блокировку join" \
    grep -qx 'ExecStart=/usr/bin/cream run --lock-timeout 6m teleport scrub-token' "$U/teleport-token.service"
check_not "юниты без путей bisquite" grep -q bisquite "$U"/teleport*.service "$U"/teleport*.path "$U"/teleport*.timer
if command -v systemd-analyze >/dev/null 2>&1; then
    check "systemd-analyze verify юнитов" bash -c '
        d="$(mktemp -d)"; cp "$1"/teleport*.service "$1"/teleport*.path "$1"/teleport*.timer "$d/"
        sed -i "s|/usr/bin/cream|/bin/true|; s|/usr/local/bin/teleport|/bin/true|" "$d"/*
        out="$(cd "$d" && systemd-analyze verify --man=no ./teleport.service ./teleport-join.service ./teleport-join.timer \
            ./teleport-apps.path ./teleport-apps.service ./teleport-token.path ./teleport-token.service 2>&1)"
        rc=$?; rm -r -f -- "$d"; [[ $rc -eq 0 ]] || { echo "$out" >&2; exit 1; }' _ "$U"
fi

echo
echo "проверок: $((pass + fail)), не прошло: $fail"
(( fail == 0 ))
