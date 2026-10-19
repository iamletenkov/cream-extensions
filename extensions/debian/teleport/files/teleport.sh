#!/usr/bin/env bash
# teleport.sh — the shared library of the cream extension `teleport`: hooks
# and actions are thin entries that exec this file with their name.
#
#   hook-install | hook-upgrade   the Teleport binary (scope: install keys),
#                                 path units; never registers
#   hook-remove                   leave, units off, binary and state gone
#   hook-apply                    operator's `cream set teleport …`: render +
#                                 reload of a running agent, non-blocking
#   join KEY=VALUE…               register (first boot, a move); JSON in stdout
#   join-retry                    one tick of teleport-join.timer
#   scrub-token                   teleport-token.service: the agent has an
#                                 identity — the first-join secret goes
#   leave                         off: agent disabled, registration erased
#   render                        /etc/teleport.yaml (ExecStartPre/ExecReload)
#   reload-apps                   teleport-apps.service: reload or render
#   status                        what is configured and registered, as text
#
# Moved from bisquite-teleport-agent 3.x (src/bisquite-teleport) with the
# paths, unit names and variables of cream (spec stvor-agent §10.1):
#   knobs           config.keys of extension.yaml, the domain
#                   /etc/cream/teleport/config; read from CREAM_CONFIG_FILE,
#                   written only by the nested `cream set --no-apply
#                   --allow-readonly teleport …` (inherits lock/teleport
#                   through CREAM_LOCK_FD)
#   .join.lock      gone: cream holds lock/teleport for join, join-retry,
#                   leave, scrub-token and the apply hook
#   state           CREAM_STATE_DIR (/var/lib/cream/ext/teleport)
#
# Lists of the domain (TELEPORT_LABELS, TELEPORT_APPS, …) are space-separated,
# as cream's `list:` type is.
#
# The first-join secret (ruling РТ1): the only secret parameter of join,
# TELEPORT_REGISTRATION_SECRET=- on stdin. Method token — the join token
# itself; bound_keypair — the registration secret (TELEPORT_TOKEN is then the
# token name, not a secret). It lives in $CREAM_STATE_DIR/registration-secret
# (0600) until the registration is confirmed: render takes it from there,
# scrub-token erases it. It never reaches the domain, argv or the log.
#
# Declarations of other extensions — /etc/cream/teleport/apps.d/<name>.conf,
# root:root, not wider than 0644:
#
#   NAME=code-server
#   URI=https://127.0.0.1:9002      loopback only
#   ICON=mcpVscode                  icon name in the proxy's web UI
#
# ACCESS IS GRANTED BY THE OPERATOR ONLY. Cluster roles match node labels (env,
# app) against user traits. An app gets the node labels plus app=<name>; the
# only label a declaration sets itself is teleport.icon, which is no access
# decision. So a file dropped by an extension or anyone else does not open the
# app to another env.
#
# No test switches in the environment: the tests substitute commands through
# PATH (systemctl, journalctl, curl, sleep…) and the root through CREAM_ROOT —
# "systemd runs" is the marker directory $CREAM_ROOT/run/systemd/system, as
# sd_booted(3) checks it. Waits count their own sleeps, so a fake `sleep` makes
# them instant; their bounds are constants, not knobs.
set -uo pipefail

ROOT="${CREAM_ROOT:-}"
ROOT="${ROOT%/}"
ETC="${CREAM_ETC_DIR:-$ROOT/etc/cream/teleport}"
STATE="${CREAM_STATE_DIR:-$ROOT/var/lib/cream/ext/teleport}"
CONF="${CREAM_CONFIG_FILE:-$ETC/config}"
EXT_DIR="${CREAM_EXT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
APPS_DIR="$ETC/apps.d"
CMD_LABELS_DIR="$ETC/command-labels.d"
YAML="$ROOT/etc/teleport.yaml"
DATA="$ROOT/var/lib/teleport"
ROLLBACK="$STATE/rollback"
# The path the agent reads (teleport.yaml), and the same file under the root.
REG_SECRET="$STATE/registration-secret"
REG_SECRET_GUEST="${REG_SECRET#"$ROOT"}"
# The path Teleport execs for the os_logins label.
OS_LOGINS_CMD="${EXT_DIR#"$ROOT"}/files/os-logins"
# bound_keypair joining for agents (not only bots) appeared in Teleport 18.8.
BOUND_KEYPAIR_MIN=18.8.0
TELEPORT_BIN="$ROOT/usr/local/bin/teleport"
TELEPORT_DEFAULT_VERSION=18.10.0
# The wait for the identity after the agent starts, s.
JOIN_TIMEOUT=120

# The knob values are validated by cream; render checks them again (a hand
# edit may put anything into the file) with the same types — KEY_TYPE equals
# config.keys of extension.yaml (tests/test-join.sh compares them).
KEYS=(TELEPORT_PROXY TELEPORT_JOIN_METHOD TELEPORT_TOKEN TELEPORT_CA_PIN TELEPORT_ENV
      TELEPORT_NODENAME TELEPORT_LABELS TELEPORT_APPS TELEPORT_APPS_DISABLE
      TELEPORT_APPS_ICONS TELEPORT_APPS_DISCOVERY TELEPORT_OS_LOGINS)
declare -A KEY_TYPE=(
    [TELEPORT_PROXY]='re:^[a-z0-9][a-z0-9.-]{0,252}(:[0-9]{1,5})?$'
    [TELEPORT_JOIN_METHOD]='enum:token,bound_keypair'
    [TELEPORT_TOKEN]='re:^[A-Za-z0-9._-]{8,256}$'
    [TELEPORT_CA_PIN]='re:^sha256:[0-9a-f]{64}$'
    [TELEPORT_ENV]='re:^[a-zA-Z0-9][a-zA-Z0-9_./ -]{0,127}$'
    [TELEPORT_NODENAME]='re:^[a-z0-9][a-z0-9-]{1,62}$'
    [TELEPORT_LABELS]='list:re:^[a-zA-Z0-9][a-zA-Z0-9_./-]{0,63}=[a-zA-Z0-9][a-zA-Z0-9_./-]{0,127}$'
    [TELEPORT_APPS]='list:re:^[a-z0-9][a-z0-9-]{0,62}=([0-9]{1,5}|https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?)$'
    [TELEPORT_APPS_DISABLE]='list:re:^[a-z0-9][a-z0-9-]{0,62}$'
    [TELEPORT_APPS_ICONS]='list:re:^[a-z0-9][a-z0-9-]{0,62}=[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
    [TELEPORT_APPS_DISCOVERY]=bool
    [TELEPORT_OS_LOGINS]=bool
)
# Keys with a non-empty default; the others default to empty (empty: true).
declare -A KEY_DEFAULT=([TELEPORT_JOIN_METHOD]=token [TELEPORT_APPS_DISCOVERY]=1 [TELEPORT_OS_LOGINS]=1)

# What is not a knob: the hostname fallback of the node name and apps.d files.
RE_NODENAME='^[a-z0-9][a-z0-9-]{1,62}$'
RE_APP_NAME='^[a-z0-9][a-z0-9-]{0,62}$'
# The icon name is a key of the proxy's compiled-in icon set, which this
# script cannot see; only the alphabet of real keys is checked (there are
# `apollo.io`, `mcpVscode`, `1password` among them). An unknown name is not an
# error for the proxy — it falls back to guessing by app name. See README.
RE_APP_ICON='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
RE_LOOPBACK_URI='^https?://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$'
# The first-join secret: bound_keypair — one printable word; token — a join
# token of Teleport (it lands in teleport.yaml in double quotes).
RE_REG_SECRET='^[[:graph:]]{8,1024}$'
RE_JOIN_TOKEN='^[A-Za-z0-9._-]{8,256}$'
RE_VERSION='^[0-9]+\.[0-9]+\.[0-9]+$'

# A join that waits for the network or the proxy. join-pending exists while it
# waits (`since=`, `attempts=`, `last=`, `error=`) and is the condition of the
# retry service; join-refused holds the cluster's refusal (`at=`, `reason=`,
# `detail=`). Both 0600 in the 0700 state directory.
JOIN_PENDING="$STATE/join-pending"
JOIN_REFUSED="$STATE/join-refused"
JOIN_SERVICE=teleport-join.service
JOIN_TIMER=teleport-join.timer
PATH_UNITS=(teleport-apps.path teleport-token.path)

log(){ >&2 echo "teleport: $*"; }
warn(){ log "ВНИМАНИЕ: $*"; }
die(){ log "ОШИБКА: $*"; exit 1; }

need_root(){ [[ -n "$ROOT" || "$(id -u)" -eq 0 ]] || die "нужен root (sudo)"; }
# systemd is PID 1 (sd_booted): the marker under the root. A build root (an
# image, a chroot) has an empty /run.
has_systemd(){ [[ -d "$ROOT/run/systemd/system" ]]; }

# ---------------------------------------------------------------------------
# Ручки: читаются из файла домена, пишутся вложенным `cream set`.
# ---------------------------------------------------------------------------
declare -A C=()

# split_list <value> — the items of a space-separated list, one per line.
split_list(){
    local -a items=()
    [[ -n "$1" ]] && read -r -a items <<< "$1"
    (( ${#items[@]} )) && printf '%s\n' "${items[@]}"
    return 0
}

# check_value <key> <value> — the value fits the type of the key.
check_value(){
    local t="${KEY_TYPE[$1]:-}" v="$2" re item
    [[ -n "$t" ]] || return 1
    if [[ -z "$v" ]]; then
        [[ -z "${KEY_DEFAULT[$1]:-}" ]]; return
    fi
    [[ "$v" != *[[:cntrl:]]* ]] || return 1
    case "$t" in
        bool) [[ "$v" == 0 || "$v" == 1 ]] ;;
        enum:*) [[ ",${t#enum:}," == *",$v,"* ]] ;;
        re:*) re="${t#re:}"; [[ "$v" =~ $re ]] ;;
        list:re:*)
            re="${t#list:re:}"
            while IFS= read -r item; do
                [[ "$item" =~ $re ]] || return 1
            done < <(split_list "$v")
            return 0 ;;
        *) return 1 ;;
    esac
}

# read_conf_file <file> — values of the known keys into C. The grammar is the
# one cream writes: KEY=bare or KEY="…" with \" and \\ escaped.
read_conf_file(){
    local line k v out i ch
    [[ -f "$1" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
        [[ -n "${KEY_TYPE[$k]+x}" ]] || continue
        if (( ${#v} >= 2 )) && [[ "$v" == \"*\" ]]; then
            v="${v:1:${#v}-2}"; out=""
            for (( i = 0; i < ${#v}; i++ )); do
                ch="${v:i:1}"
                if [[ "$ch" == "\\" ]]; then i=$((i + 1)); ch="${v:i:1}"; fi
                out+="$ch"
            done
            v="$out"
        fi
        C[$k]="$v"
    done < "$1"
}

load_conf(){
    local k
    C=()
    for k in "${KEYS[@]}"; do C[$k]="${KEY_DEFAULT[$k]:-}"; done
    read_conf_file "$CONF"
}

# Every value is checked before it lands in YAML.
conf_check(){
    local k bad=0
    for k in "${KEYS[@]}"; do
        if ! check_value "$k" "${C[$k]}"; then
            log "ОШИБКА: $k в $CONF не подходит под тип ${KEY_TYPE[$k]}"; bad=1
        fi
    done
    (( ! bad ))
}

# Write through cream: validation, an atomic write, readonly keys allowed —
# this extension is their owner. No apply hook: the caller renders itself.
save_conf(){
    (( $# )) || return 0
    cream set --no-apply --allow-readonly teleport "$@" >&2 || die "не записано в домен teleport (cream set)"
}

# The one rule the schema cannot express: env, app, os_logins and
# teleport.icon are set by this extension, and a label may not override the
# access decision or pose as the agent's own report of the OS logins.
check_labels(){
    local item
    while IFS= read -r item; do
        case "${item%%=*}" in
            env|app)
                die "TELEPORT_LABELS: ключ '${item%%=*}' зарезервирован (env задаётся TELEPORT_ENV)" ;;
            # A static label and a dynamic one of the same name: the dynamic
            # one wins in Teleport, so the operator's value would be lost.
            os_logins)
                die "TELEPORT_LABELS: ключ 'os_logins' зарезервирован — динамическая метка ставится агентом (выключить: TELEPORT_OS_LOGINS=0)" ;;
            # A node-wide icon label would land in the same YAML map as the
            # app's own one — a duplicate key, teleport.yaml would not parse.
            teleport.icon)
                die "TELEPORT_LABELS: ключ 'teleport.icon' зарезервирован — иконка задаётся ICON= в apps.d или ручкой TELEPORT_APPS_ICONS" ;;
        esac
    done < <(split_list "$1")
}

proxy_with_port(){ [[ "$1" == *:* ]] && echo "$1" || echo "$1:443"; }
proxy_host(){ echo "${1%%:*}"; }

nodename(){
    local n="${C[TELEPORT_NODENAME]}"
    [[ -n "$n" ]] || n="$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    [[ "$n" =~ $RE_NODENAME ]] || die "имя ноды '$n' (hostname) не метка DNS — задайте TELEPORT_NODENAME"
    echo "$n"
}

# ---------------------------------------------------------------------------
# Приложения: apps.d + TELEPORT_APPS − TELEPORT_APPS_DISABLE
# Выход: строки "имя<TAB>URI<TAB>источник<TAB>иконка", пропуски — в stderr.
# ---------------------------------------------------------------------------
read_decl(){
    local f="$1" line key val name="" uri="" icon="" owner mode
    # A symlink would pass the owner check while pointing at anyone's file.
    if [[ -L "$f" ]]; then
        warn "пропускаю $f: символическая ссылка"; return 1
    fi
    owner="$(stat -c %u "$f")"; mode="$(stat -c %a "$f")"
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || { warn "пропускаю $f: права не прочитаны"; return 1; }
    if [[ -z "$ROOT" && "$owner" != 0 ]]; then
        warn "пропускаю $f: владелец не root"; return 1
    fi
    if (( (8#$mode & 8#022) != 0 )); then
        warn "пропускаю $f: права $mode, запись группе или всем"; return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
        if [[ ! "$line" =~ ^([A-Z]+)=(.*)$ ]]; then
            warn "пропускаю $f: строка не KEY=VALUE"; return 1
        fi
        key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
        case "$key" in
            NAME) name="$val" ;;
            URI) uri="$val" ;;
            ICON) icon="$val" ;;
            *) warn "пропускаю $f: неизвестный ключ $key (разрешены NAME, URI и ICON)"; return 1 ;;
        esac
    done < "$f"
    [[ "$name" =~ $RE_APP_NAME ]] || { warn "пропускаю $f: NAME='$name' не метка DNS"; return 1; }
    [[ "$uri" =~ $RE_LOOPBACK_URI ]] || { warn "пропускаю $f: URI='$uri' — в apps.d только петля"; return 1; }
    if [[ -n "$icon" && ! "$icon" =~ $RE_APP_ICON ]]; then
        warn "пропускаю $f: ICON='$icon' не имя иконки"; return 1
    fi
    # The icon goes last: an empty field between two tabs collapses on read.
    printf '%s\t%s\t%s\t%s\n' "$name" "$uri" "$f" "$icon"
}

collect_apps(){
    local -A uri=() src=() disabled=() icon=()
    local order=() f line name u ic item
    if [[ "${C[TELEPORT_APPS_DISCOVERY]}" == 1 && -d "$APPS_DIR" ]]; then
        for f in "$APPS_DIR"/*.conf; do
            [[ -f "$f" ]] || continue
            line="$(read_decl "$f")" || continue
            IFS=$'\t' read -r name u _ ic <<< "$line"
            if [[ -n "${uri[$name]:-}" ]]; then
                warn "пропускаю $f: приложение '$name' уже объявлено в ${src[$name]}"; continue
            fi
            uri[$name]="$u"; src[$name]="$f"; icon[$name]="$ic"; order+=("$name")
        done
    fi
    while IFS= read -r item; do
        name="${item%%=*}"; u="${item#*=}"
        [[ "$u" =~ ^[0-9]+$ ]] && u="http://127.0.0.1:$u"
        # The operator's entry wins over a declaration of the same name.
        [[ -n "${uri[$name]:-}" ]] || order+=("$name")
        uri[$name]="$u"; src[$name]="TELEPORT_APPS"
    done < <(split_list "${C[TELEPORT_APPS]}")
    # The operator's icon wins over the declaration's, the same way the
    # operator's URI does. A name that nothing publishes is ignored.
    while IFS= read -r item; do icon[${item%%=*}]="${item#*=}"; done < <(split_list "${C[TELEPORT_APPS_ICONS]}")
    while IFS= read -r item; do disabled[$item]=1; done < <(split_list "${C[TELEPORT_APPS_DISABLE]}")
    for name in "${order[@]}"; do
        [[ -n "${disabled[$name]:-}" ]] && continue
        printf '%s\t%s\t%s\t%s\n' "$name" "${uri[$name]}" "${src[$name]}" "${icon[$name]:-}"
    done
}

node_labels(){
    local -A l=() ; local item k
    while IFS= read -r item; do l[${item%%=*}]="${item#*=}"; done < <(split_list "${C[TELEPORT_LABELS]}")
    # env last and never from TELEPORT_LABELS: it is the access decision.
    [[ -n "${C[TELEPORT_ENV]}" ]] && l[env]="${C[TELEPORT_ENV]}"
    for k in $(printf '%s\n' "${!l[@]}" | sort); do printf '%s\t%s\n' "$k" "${l[$k]}"; done
}

# ---------------------------------------------------------------------------
# teleport.yaml — узел, приложения, метки
# ---------------------------------------------------------------------------
cmd_render(){
    need_root
    load_conf
    conf_check || die "в $CONF неверные значения — cream show teleport"
    check_labels "${C[TELEPORT_LABELS]}"
    [[ -n "${C[TELEPORT_PROXY]}" ]] || die "TELEPORT_PROXY не задан — сначала cream run teleport join"
    local node proxy host apps labels tmp name uri icon first=""
    node="$(nodename)"
    proxy="$(proxy_with_port "${C[TELEPORT_PROXY]}")"
    host="$(proxy_host "$proxy")"
    labels="$(node_labels)"
    apps="$(collect_apps)"
    if [[ -s "$REG_SECRET" ]]; then
        first="$(< "$REG_SECRET")"
        # A token lands in YAML in double quotes: its alphabet is checked again.
        if [[ "${C[TELEPORT_JOIN_METHOD]}" != bound_keypair && ! "$first" =~ $RE_JOIN_TOKEN ]]; then
            die "$REG_SECRET: join-токен не по форме — выполните join заново"
        fi
    fi

    install -d -m 0755 "$(dirname "$YAML")" || die "не создать $(dirname "$YAML")"
    tmp="$(mktemp "$(dirname "$YAML")/.teleport.yaml.XXXXXX")" || die "не создать файл рядом с $YAML"
    chmod 0600 "$tmp"
    {
        echo "# Сгенерирован cream run teleport render из /etc/cream/teleport. Не править:"
        echo "# перезаписывается на каждом старте teleport.service."
        echo "version: v3"
        echo "teleport:"
        echo "  nodename: \"$node\""
        echo "  data_dir: /var/lib/teleport"
        echo "  log:"
        echo "    output: stderr"
        echo "    severity: INFO"
        [[ -n "${C[TELEPORT_CA_PIN]}" ]] && echo "  ca_pin: \"${C[TELEPORT_CA_PIN]}\""
        echo "  proxy_server: \"$proxy\""
        if [[ "${C[TELEPORT_JOIN_METHOD]}" == bound_keypair ]]; then
            # The token name stays: a re-join (a new system role, a CA
            # rotation) authenticates with the bound key under it. Only the
            # first join reads the secret; the scrubbed secret leaves no path
            # to a missing file behind.
            if [[ -n "${C[TELEPORT_TOKEN]}" ]]; then
                echo "  join_params:"
                echo "    token_name: \"${C[TELEPORT_TOKEN]}\""
                echo "    method: bound_keypair"
                if [[ -n "$first" ]]; then
                    echo "    bound_keypair:"
                    echo "      registration_secret_path: \"$REG_SECRET_GUEST\""
                fi
            fi
        elif [[ -n "$first" ]]; then
            # Method token: the join token itself, until the registration; a
            # joined agent reads its identity from data_dir.
            echo "  join_params:"
            echo "    token_name: \"$first\""
            echo "    method: token"
        fi
        echo "ssh_service:"
        echo "  enabled: yes"
        # Reached through the proxy's reverse tunnel; nothing needs 3022 from
        # the network.
        echo "  listen_addr: 127.0.0.1:3022"
        echo "  labels:"
        while IFS=$'\t' read -r k v; do [[ -n "$k" ]] && echo "    \"$k\": \"$v\""; done <<< "$labels"
        # Dynamic label: the agent runs the command every period and puts its
        # trimmed stdout into the label. Node only — apps do not get it.
        if [[ "${C[TELEPORT_OS_LOGINS]}" == 1 ]]; then
            echo "  commands:"
            echo "    - name: \"os_logins\""
            echo "      command: [\"$OS_LOGINS_CMD\"]"
            echo "      period: 5m0s"
        fi
        if [[ -n "$apps" ]]; then
            echo "app_service:"
            echo "  enabled: yes"
            echo "  apps:"
            while IFS=$'\t' read -r name uri _ icon; do
                echo "    - name: \"$name-$node\""
                echo "      uri: \"$uri\""
                echo "      public_addr: \"$name.$node.$host\""
                # Loopback https carries a localhost certificate (mkcert,
                # self-signed); nobody outside can sit on the loopback path.
                if [[ "$uri" =~ ^https://(127\.0\.0\.1|localhost|\[::1\])([:/]|$) ]]; then
                    echo "      insecure_skip_verify: true"
                fi
                # Loopback apps see the public Host, as behind any reverse
                # proxy: apps guarding WebSocket by Origin == Host reject the
                # browser otherwise (Selkies, AGX Orin, 2026-09-14). Remote
                # operator apps keep their Host — it may select a vhost there.
                if [[ "$uri" =~ ^https?://(127\.0\.0\.1|localhost|\[::1\])([:/]|$) ]]; then
                    echo "      rewrite:"
                    echo "        headers:"
                    echo "          - \"Host: $name.$node.$host\""
                fi
                echo "      labels:"
                while IFS=$'\t' read -r k v; do [[ -n "$k" ]] && echo "        \"$k\": \"$v\""; done <<< "$labels"
                echo "        \"app\": \"$name\""
                # No icon — no label: the proxy then guesses by app name.
                [[ -n "$icon" ]] && echo "        \"teleport.icon\": \"$icon\""
            done <<< "$apps"
        else
            echo "app_service:"
            echo "  enabled: no"
        fi
        echo "auth_service:"
        echo "  enabled: no"
        echo "proxy_service:"
        echo "  enabled: no"
    } > "$tmp"
    mv -f "$tmp" "$YAML"
}

# ---------------------------------------------------------------------------
# Служба
# ---------------------------------------------------------------------------
joined(){ [[ -s "$DATA/host_uuid" ]]; }

# Teleport 18 joins roles separately: a token without App still registers the
# SSH node, and app_service keeps retrying with this error (seen on AGX Orin
# 2026-09-14). The identity cannot gain App without a new provision token.
APP_ROLE_ERROR='token does not allow role App'
app_role_missing(){
    has_systemd || return 1
    local inv log
    inv="$(systemctl show teleport.service -p InvocationID --value 2>/dev/null)"
    [[ -n "$inv" ]] || return 1
    # Into a variable, not `| grep -q`: grep exits on the first match, the
    # writer gets SIGPIPE, and pipefail turns the match into a failure.
    log="$(journalctl -u teleport.service "_SYSTEMD_INVOCATION_ID=$inv" --no-pager -o cat 2>/dev/null)"
    grep -q "$APP_ROLE_ERROR" <<< "$log"
}
APP_ROLE_HINT="у токена не было роли App: SSH работает, приложения не опубликованы. Выдайте токен с ролями node,app (в админке — «Разрешить веб-приложения») и выполните join с TELEPORT_FORCE=1"
agent_active(){ has_systemd && systemctl is-active --quiet teleport.service; }

# join waits on purpose: it reports the registration. The hook below does not.
apply_running(){
    has_systemd || return 0
    if agent_active; then
        cmd_render
        systemctl reload teleport.service >/dev/null 2>&1 || systemctl restart teleport.service >/dev/null 2>&1
    fi
}

# Apply hook: render synchronously — a bad value fails loudly here — and hand
# the reload to systemd without waiting: `cream set` may run inside a boot job.
cmd_apply(){
    need_root
    load_conf
    if [[ -z "${C[TELEPORT_PROXY]}" ]]; then
        log "записано; кластер не задан — cream run teleport join"
        return 0
    fi
    if agent_active; then
        cmd_render
        systemctl --no-block reload-or-restart teleport.service || die "teleport.service не принял reload"
        log "применено к работающему агенту"
    else
        log "записано; применится при старте агента"
    fi
}

# The first-join secret becomes inert once used. The token name and the
# method stay: they are not secret.
scrub_token(){
    load_conf
    joined || return 0
    [[ -e "$REG_SECRET" ]] || return 0
    rm -f -- "$REG_SECRET"
    [[ -n "${C[TELEPORT_PROXY]}" ]] && cmd_render
    log "агент зарегистрирован — секрет первого входа стёрт, ключ агента — в $DATA"
}

write_secret(){
    local tmp
    install -d -m 0700 "$STATE" || die "не создать $STATE"
    # mktemp creates the file 0600: the secret is never readable by others.
    tmp="$(mktemp "$STATE/.registration-secret.XXXXXX")" || die "не создать файл в $STATE"
    printf '%s\n' "$1" > "$tmp" || { rm -f -- "$tmp"; die "секрет первого входа не записан"; }
    mv -f -- "$tmp" "$REG_SECRET"
}

# ---------------------------------------------------------------------------
# join
# ---------------------------------------------------------------------------
version_of_agent(){ "$TELEPORT_BIN" version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d v; }

# Versions meet bash arithmetic, and (( )) evaluates a[$(cmd)] in its operand
# — a command. So every version, even a local one, is X.Y.Z of at most 9
# digits each before any arithmetic, and goes in as base 10 (18.09.0 is no
# octal error).
RE_SEMVER='^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$'

# 0 — a is newer than b; 1 — not newer; 2 — one of them is not X.Y.Z.
semver_gt(){
    [[ "$1" =~ $RE_SEMVER && "$2" =~ $RE_SEMVER ]] || return 2
    local -a a b; local i
    IFS=. read -r -a a <<< "$1"
    IFS=. read -r -a b <<< "$2"
    for i in 0 1 2; do
        (( 10#${a[i]} > 10#${b[i]} )) && return 0
        (( 10#${a[i]} < 10#${b[i]} )) && return 1
    done
    return 1
}

# Echo the server version; on failure return curl's exit code — the proxy is
# not reachable over verified TLS. Any failure here is "not yet": DNS, connect,
# timeout, TLS (the clock of a fresh machine may still be wrong), an HTTP
# error of a balancer in front of the proxy, an answer without server_version
# (a captive portal, not a Teleport proxy) — code 100; a server_version that
# is not X.Y.Z[-pre][+build] — code 101. The answer comes from the network:
# only the checked X.Y.Z leaves this function (see RE_SEMVER).
probe_proxy(){
    local proxy="$1" body rc version
    body="$(curl -fsS --max-time 15 "https://$proxy/webapi/find" 2>/dev/null)" || { rc=$?; return "$rc"; }
    version="$(grep -oE '"server_version":"[^"]+"' <<< "$body" | head -1 | cut -d'"' -f4)"
    [[ -n "$version" ]] || return 100
    [[ "$version" =~ ^([0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9})([-+][A-Za-z0-9.+-]*)?$ ]] || return 101
    printf '%s\n' "${BASH_REMATCH[1]}"
}

# What the curl code of probe_proxy means, for the journal and `status`.
net_reason(){
    case "$1" in
        5|6) echo "имя не разрешается — DNS (curl $1)" ;;
        7) echo "соединение не установлено (curl 7)" ;;
        28) echo "таймаут (curl 28)" ;;
        22) echo "прокси ответил ошибкой HTTP (curl 22)" ;;
        35|51|53|54|58|59|60|64|66|77|80|83|90|91)
            echo "TLS не сошёлся — часы ещё не синхронизированы? (curl $1)" ;;
        52|55|56) echo "соединение оборвано (curl $1)" ;;
        100) echo "ответ не от прокси Teleport — нет server_version в /webapi/find" ;;
        101) echo "прокси назвал версию не по форме X.Y.Z в /webapi/find — не прокси Teleport?" ;;
        *) echo "curl $1" ;;
    esac
}

# The agent may not be newer than the cluster nor older by more than a major.
# Echo the reason and return 0 on a mismatch.
version_mismatch(){
    local agent="$1" server="$2"
    if [[ ! "$agent" =~ $RE_SEMVER || ! "$server" =~ $RE_SEMVER ]]; then
        echo "версия агента или кластера не по форме X.Y.Z — сверить нельзя"; return 0
    fi
    if semver_gt "$agent" "$server"; then
        echo "агент $agent новее кластера $server — Teleport такую связку не поддерживает"; return 0
    fi
    if (( 10#${server%%.*} - 10#${agent%%.*} > 1 )); then
        echo "агент $agent старше кластера $server больше чем на мажор"; return 0
    fi
    return 1
}

# The join service of Teleport 18 (lib/join) sends its refusal to the agent,
# and the agent logs it on every retry — "Failed to establish connection to
# cluster." with the error, or "Can not join the cluster, the token is expired
# or not found." None of these is ever a network error, so a match is final:
# retrying only hammers the auth server. Anything else (connection refused, no
# such host, i/o timeout, TLS) is "not yet".
#   pattern (ERE, case-insensitive) | reason for `status`
JOIN_REFUSALS=(
    'a valid registration secret is required|секрет регистрации неверен или истёк'
    'token (is )?expired or not found|токен регистрации не найден или истёк (робот удалён или секрет перевыпущен)'
    'no recovery attempts remaining|failed to complete challenge|invalid challenge document|join state (verification failed|could not be verified)|токен уже использован: робот подключён с другой машины или её ключ потерян'
    'does not allow role|is not for .bound_keypair. method|ambiguous token name|bad backend state|токен не подходит этой машине (метод или роли)'
)

# refusal_reason <agent log> — echo the reason of the first refusal found.
refusal_reason(){
    local entry
    for entry in "${JOIN_REFUSALS[@]}"; do
        if grep -qiE -- "${entry%|*}" <<< "$1"; then
            printf '%s' "${entry##*|}"; return 0
        fi
    done
    return 1
}

# The last line in which the agent reports a failed join, one line, at most
# 300 characters, control characters dropped (it goes to a state file).
last_join_error(){
    local line
    line="$(grep -iE 'establish connection to cluster|can not join the cluster|registration secret' <<< "$1" | tail -n 1)"
    line="$(printf '%s' "$line" | tr -d '\000-\037\177')"
    printf '%s' "${line:0:300}"
}

# The journal of teleport.service since an epoch. Into a variable, not a pipe
# into grep -q (see app_role_missing).
agent_log_since(){
    has_systemd || return 0
    journalctl -u teleport.service --since "@$1" --no-pager -o cat 2>/dev/null || true
}

# A one-line value for a state file.
one_line(){ printf '%s' "$1" | tr -d '\000-\037\177' | cut -c 1-300; }
now_epoch(){ date +%s; }

write_state(){ # write_state <file> <content>
    local tmp
    install -d -m 0700 "$STATE" || return 1
    tmp="$(mktemp "$STATE/.state.XXXXXX")" || return 1
    printf '%s\n' "$2" > "$tmp" && mv -f -- "$tmp" "$1"
}

read_pending(){
    local line
    PEND_SINCE=""; PEND_ATTEMPTS=0; PEND_LAST=""; PEND_ERROR=""
    [[ -f "$JOIN_PENDING" ]] || return 1
    while IFS= read -r line; do
        case "$line" in
            since=*) [[ "${line#since=}" =~ ^[0-9]{1,12}$ ]] && PEND_SINCE="${line#since=}" ;;
            attempts=*) [[ "${line#attempts=}" =~ ^[0-9]{1,9}$ ]] && PEND_ATTEMPTS="${line#attempts=}" ;;
            last=*) [[ "${line#last=}" =~ ^[0-9]{1,12}$ ]] && PEND_LAST="${line#last=}" ;;
            error=*) PEND_ERROR="${line#error=}" ;;
        esac
    done < "$JOIN_PENDING"
    return 0
}

read_refused(){
    local line
    REF_AT=""; REF_REASON=""; REF_DETAIL=""
    [[ -f "$JOIN_REFUSED" ]] || return 1
    while IFS= read -r line; do
        case "$line" in
            at=*) [[ "${line#at=}" =~ ^[0-9]{1,12}$ ]] && REF_AT="${line#at=}" ;;
            reason=*) REF_REASON="${line#reason=}" ;;
            detail=*) REF_DETAIL="${line#detail=}" ;;
        esac
    done < "$JOIN_REFUSED"
    return 0
}

# One more failed attempt of a waiting join: the counter, the time, the error.
join_wait_record(){
    local now
    now="$(now_epoch)"
    read_pending || true
    write_state "$JOIN_PENDING" "since=${PEND_SINCE:-$now}"$'\n'"attempts=$((PEND_ATTEMPTS + 1))"$'\n'"last=$now"$'\n'"error=$(one_line "$1")" \
        || die "не записано $JOIN_PENDING"
}

# The join waits: record the attempt, retry at every boot and every minute.
# `start --no-block`: join may run inside a unit ordered before
# network-online.target, and a waiting start job would deadlock it.
join_defer(){
    rm -f -- "$JOIN_REFUSED"
    join_wait_record "$1"
    has_systemd || return 0
    systemctl enable "$JOIN_SERVICE" "$JOIN_TIMER" >/dev/null 2>&1 \
        || warn "$JOIN_TIMER не включён — юнитов повтора нет? cream install teleport --reinstall"
    systemctl start --no-block "$JOIN_TIMER" >/dev/null 2>&1 || true
}

# Registered: no more retries, the agent starts at every boot. The service is
# disabled without --now — the tick that calls this runs inside it.
join_settle(){
    rm -f -- "$JOIN_PENDING" "$JOIN_REFUSED"
    has_systemd || return 0
    systemctl enable teleport.service >/dev/null 2>&1 || true
    systemctl disable "$JOIN_SERVICE" >/dev/null 2>&1 || true
    systemctl disable --now "$JOIN_TIMER" >/dev/null 2>&1 || true
}

# The cluster refused: no retries, the agent off (it would repeat the refusal
# every 90 s forever), the secret gone — it is spent or wrong either way, the
# way out is a new one. join_refuse <reason> <agent's line>
join_refuse(){
    rm -f -- "$JOIN_PENDING" "$REG_SECRET"
    if has_systemd; then
        systemctl disable --now teleport.service >/dev/null 2>&1 || true
        systemctl disable "$JOIN_SERVICE" >/dev/null 2>&1 || true
        systemctl disable --now "$JOIN_TIMER" >/dev/null 2>&1 || true
    fi
    # The YAML drops the scrubbed secret.
    [[ -n "${C[TELEPORT_PROXY]}" ]] && cmd_render
    write_state "$JOIN_REFUSED" "at=$(now_epoch)"$'\n'"reason=$(one_line "$1")"$'\n'"detail=$(one_line "$2")" \
        || warn "не записано $JOIN_REFUSED"
}

JOIN_HINT="новый секрет — в карточке робота Stvor («Новый секрет»), затем выполните строку подключения снова (вручную или через RustDesk)"

# One attempt with the agent: start it unless it runs, wait for the identity
# or a refusal. 0 — registered; 1 — refused (REFUSAL, REFUSAL_DETAIL);
# 2 — not yet (ATTEMPT_ERROR).
attempt_register(){
    local since waited=0 agent_log="" line
    REFUSAL=""; REFUSAL_DETAIL=""; ATTEMPT_ERROR=""
    since="$(date +%s)"
    if ! agent_active; then
        if ! systemctl start teleport.service >/dev/null 2>&1; then
            ATTEMPT_ERROR="teleport.service не стартовал — journalctl -u teleport"
            return 2
        fi
    fi
    log "жду регистрации (до ${JOIN_TIMEOUT} с)…"
    while :; do
        joined && return 0
        agent_log="$(agent_log_since "$since")"
        if REFUSAL="$(refusal_reason "$agent_log")"; then
            REFUSAL_DETAIL="$(last_join_error "$agent_log")"
            return 1
        fi
        (( waited < JOIN_TIMEOUT )) || break
        sleep 2; waited=$((waited + 2))
    done
    line="$(last_join_error "$agent_log")"
    ATTEMPT_ERROR="прокси отвечает, регистрация не подтвердилась за ${JOIN_TIMEOUT} с${line:+: $line}"
    return 2
}

# The domain values of a saved config file, back through cream.
restore_conf(){
    local k
    local -a pairs=()
    load_conf
    C=()
    for k in "${KEYS[@]}"; do C[$k]="${KEY_DEFAULT[$k]:-}"; done
    read_conf_file "$1"
    for k in "${KEYS[@]}"; do pairs+=("$k=${C[$k]}"); done
    save_conf "${pairs[@]}"
}

# Put the previous registration back (join with a working registration failed).
restore_rollback(){
    systemctl stop teleport.service >/dev/null 2>&1
    find "$DATA" -mindepth 1 -maxdepth 1 -exec rm -r -f -- {} +
    find "$ROLLBACK/data" -mindepth 1 -maxdepth 1 -exec mv -t "$DATA" -- {} +
    [[ -f "$ROLLBACK/config" ]] && restore_conf "$ROLLBACK/config"
    [[ -f "$ROLLBACK/teleport.yaml" ]] && cp -a "$ROLLBACK/teleport.yaml" "$YAML"
    # The restored registration has its own identity; the new secret goes.
    rm -f -- "$REG_SECRET"
    systemctl start teleport.service >/dev/null 2>&1
    rm -r -f -- "$ROLLBACK"
}

# The JSON result of join on stdout (output: json): exactly one object.
# J_RESULT: registered | pending | deferred | written | refused | failed.
J_RESULT=""; J_REASON=""
json_str(){
    local s
    s="$(printf '%s' "$1" | tr -d '\000-\037\177')"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
    printf '"%s"' "$s"
}
emit_join(){
    local j=false p=false r=false
    joined && j=true
    [[ -f "$JOIN_PENDING" ]] && p=true
    [[ -f "$JOIN_REFUSED" ]] && r=true
    printf '{"result":%s,"joined":%s,"pending":%s,"refused":%s,"reason":%s}\n' \
        "$(json_str "$J_RESULT")" "$j" "$p" "$r" "$(json_str "$J_REASON")"
}
# A final failure of join after the work began: the JSON first, then code 1.
join_fail(){ # join_fail <result> <reason> <message>
    J_RESULT="$1"; J_REASON="$2"
    log "ОШИБКА: $3"
    emit_join
    exit 1
}

# Keys join takes besides the domain ones (the parameters of the action).
JOIN_ONLY_KEYS=" TELEPORT_REGISTRATION_SECRET TELEPORT_FORCE TELEPORT_DEFER "

cmd_join(){
    need_root
    local -A N=()
    local -a pairs=()
    local pair key val secret="" has_secret=0
    for pair in "$@"; do
        [[ "$pair" == *=* ]] || die "ожидали KEY=VALUE, получили '$pair'"
        key="${pair%%=*}"; val="${pair#*=}"
        if [[ -z "${KEY_TYPE[$key]+x}" && "$JOIN_ONLY_KEYS" != *" $key "* ]]; then
            die "join не принимает $key"
        fi
        [[ -z "${N[$key]+x}" ]] || die "ключ $key задан дважды"
        N[$key]="$val"
    done
    [[ -n "${N[TELEPORT_PROXY]:-}" ]] || die "нужен TELEPORT_PROXY=host[:port]"
    local force="${N[TELEPORT_FORCE]:-0}" defer="${N[TELEPORT_DEFER]:-0}"
    unset 'N[TELEPORT_FORCE]' 'N[TELEPORT_DEFER]'
    # The method follows this join, not the history: a join without it is a
    # token join even on a machine that was bound_keypair before.
    local method="${N[TELEPORT_JOIN_METHOD]:-token}"
    N[TELEPORT_JOIN_METHOD]="$method"
    # The first-join secret is not a knob: it leaves N here and never reaches
    # the domain, argv of children or the log. cream hands it over on stdin.
    if [[ -n "${N[TELEPORT_REGISTRATION_SECRET]+x}" ]]; then
        [[ "${N[TELEPORT_REGISTRATION_SECRET]}" == - ]] \
            || die "TELEPORT_REGISTRATION_SECRET — только TELEPORT_REGISTRATION_SECRET=- (значение со stdin)"
        has_secret=1
        secret="$(cat)"
    fi
    unset 'N[TELEPORT_REGISTRATION_SECRET]'
    # Surrounding whitespace (a newline from echo or a file) is not the secret;
    # Teleport trims the file the same way.
    secret="${secret#"${secret%%[![:space:]]*}"}"; secret="${secret%"${secret##*[![:space:]]}"}"
    if [[ "$method" == bound_keypair ]]; then
        [[ -n "${N[TELEPORT_TOKEN]:-}" ]] || die "bound_keypair: нужен TELEPORT_TOKEN — имя токена"
        if (( has_secret )) && [[ ! "$secret" =~ $RE_REG_SECRET ]]; then
            die "секрет регистрации: ожидали 8–1024 печатных знаков без пробелов"
        fi
    else
        [[ -z "${N[TELEPORT_TOKEN]:-}" ]] \
            || die "TELEPORT_TOKEN — имя токена bound_keypair; join-токен метода token передаётся TELEPORT_REGISTRATION_SECRET=- (stdin)"
        if (( has_secret )) && [[ ! "$secret" =~ $RE_JOIN_TOKEN ]]; then
            die "join-токен: ожидали 8–256 знаков [A-Za-z0-9._-]"
        fi
        # A token join leaves no bound_keypair name behind.
        N[TELEPORT_TOKEN]=""
    fi
    for key in "${!N[@]}"; do
        check_value "$key" "${N[$key]}" || die "$key: значение не подходит под тип ${KEY_TYPE[$key]}"
    done
    check_labels "${N[TELEPORT_LABELS]:-}"
    N[TELEPORT_PROXY]="$(proxy_with_port "${N[TELEPORT_PROXY]}")"

    load_conf
    local old_proxy="${C[TELEPORT_PROXY]}"
    [[ -n "$old_proxy" ]] && old_proxy="$(proxy_with_port "$old_proxy")"

    # 1. Idempotent: a rerun of runcmd (cloned card, cloud-init clean) must
    #    not wipe a working identity with the stale secret from the seed.
    if joined && [[ "$old_proxy" == "${N[TELEPORT_PROXY]}" && "$force" != 1 ]]; then
        log "уже зарегистрирован в ${N[TELEPORT_PROXY]} — переподключение не нужно (TELEPORT_FORCE=1 — принудительно)"
        pairs=()
        for key in "${!N[@]}"; do
            [[ "$key" == TELEPORT_PROXY || "$key" == TELEPORT_TOKEN || "$key" == TELEPORT_JOIN_METHOD ]] && continue
            pairs+=("$key=${N[$key]}")
        done
        save_conf "${pairs[@]}"
        # The agent registered on its own while the join waited for the network.
        if [[ -f "$JOIN_PENDING" ]]; then scrub_token; join_settle; fi
        apply_running
        J_RESULT=registered
        return 0
    fi
    # Past the idempotent exit: a registered robot needs no secret to rerun.
    [[ -n "$secret" ]] \
        || die "нужен секрет первого входа — TELEPORT_REGISTRATION_SECRET=- (stdin): для token — join-токен, для bound_keypair — секрет регистрации"
    [[ -n "${C[TELEPORT_ENV]}${N[TELEPORT_ENV]:-}" ]] || \
        warn "TELEPORT_ENV не задан: ноду и приложения увидят только роли access/editor"
    if (( defer )) && joined; then
        die "машина уже зарегистрирована: TELEPORT_DEFER=1 — только для первой регистрации"
    fi

    # 2. Preflight before touching anything.
    local was_joined=0 server="" agent prc=0 mismatch
    joined && was_joined=1
    agent="$(version_of_agent)"
    [[ -n "$agent" ]] || die "$TELEPORT_BIN не отвечает на version — Teleport не установлен? cream install teleport"
    # The agent may not be newer than the cluster (below), so an agent of
    # 18.8+ also guarantees the cluster side of bound_keypair.
    if [[ "$method" == bound_keypair ]] && semver_gt "$BOUND_KEYPAIR_MIN" "$agent"; then
        die "bound_keypair: нужен агент версии не ниже $BOUND_KEYPAIR_MIN, установлен $agent — cream install teleport TELEPORT_VERSION=…"
    fi
    if (( ! defer )); then
        server="$(probe_proxy "${N[TELEPORT_PROXY]}")" || prc=$?
        if (( prc == 0 )); then
            if [[ -n "$server" ]]; then
                mismatch="$(version_mismatch "$agent" "$server")" && die "$mismatch"
                log "прокси ${N[TELEPORT_PROXY]} отвечает, кластер $server, агент $agent"
            fi
        elif (( was_joined )); then
            die "прокси ${N[TELEPORT_PROXY]} недоступен по https ($(net_reason "$prc")) — рабочую регистрацию не трогаю"
        fi
    fi

    # 3. Keep the previous state for a rollback.
    if has_systemd && (( ! defer )); then systemctl stop teleport.service >/dev/null 2>&1 || true; fi
    rm -r -f -- "$ROLLBACK"
    install -d -m 0700 "$STATE" "$ROLLBACK" "$ROLLBACK/data" || die "не создать $ROLLBACK"
    [[ -f "$CONF" ]] && cp -a "$CONF" "$ROLLBACK/config"
    [[ -f "$YAML" ]] && cp -a "$YAML" "$ROLLBACK/teleport.yaml"
    if [[ -d "$DATA" ]]; then
        find "$DATA" -mindepth 1 -maxdepth 1 -exec mv -t "$ROLLBACK/data" -- {} +
    fi
    install -d -m 0750 "$DATA" || die "не создать $DATA"
    # This join replaces whatever an earlier one left: a wait or a refusal.
    rm -f -- "$JOIN_PENDING" "$JOIN_REFUSED"

    # A new cluster invalidates the old pin unless a new one came with it.
    pairs=()
    if [[ "$old_proxy" != "${N[TELEPORT_PROXY]}" && -z "${N[TELEPORT_CA_PIN]+x}" ]]; then
        pairs+=(TELEPORT_CA_PIN=)
    fi
    for key in "${!N[@]}"; do pairs+=("$key=${N[$key]}"); done
    save_conf "${pairs[@]}"
    write_secret "$secret"
    cmd_render

    # 3a. Deferred (a workstation set up without starting): everything is on
    #     disk, nothing is enabled; `cream run teleport join-retry` registers.
    if (( defer )); then
        rm -r -f -- "$ROLLBACK"
        join_wait_record "регистрация отложена (TELEPORT_DEFER=1) — cream run teleport join-retry"
        log "конфиг и секрет записаны, регистрация отложена — зарегистрировать: cream run teleport join-retry"
        J_RESULT=deferred
        return 0
    fi

    if ! has_systemd; then
        rm -r -f -- "$ROLLBACK"
        log "systemd не запущен — конфиг записан, агент стартует при загрузке"
        J_RESULT=written
        return 0
    fi

    # 3b. No network or proxy (first boot): everything is on disk — the knobs
    #     in the domain, the secret in $REG_SECRET (0600). The retry units
    #     take over; the agent itself stays off until the proxy answers, so a
    #     refusal is seen by them and not repeated forever.
    if (( prc )); then
        rm -r -f -- "$ROLLBACK"
        systemctl disable teleport.service >/dev/null 2>&1 || true
        join_defer "прокси ${N[TELEPORT_PROXY]} недоступен: $(net_reason "$prc")"
        log "сеть или прокси ${N[TELEPORT_PROXY]} недоступны ($(net_reason "$prc")) — параметры и секрет сохранены, регистрация повторится после появления сети: при каждой загрузке и раз в минуту. Ход — cream run teleport status"
        J_RESULT=pending
        return 0
    fi

    # 4. Wait for the identity or a refusal.
    attempt_register
    case $? in
        0)
            rm -r -f -- "$ROLLBACK"
            scrub_token
            join_settle
            log "нода $(nodename) зарегистрирована в ${C[TELEPORT_PROXY]}"
            J_RESULT=registered
            # Apps join after the node; give app_service a moment to fail.
            if [[ -n "$(collect_apps 2>/dev/null)" ]]; then
                sleep 15
                if app_role_missing; then warn "$APP_ROLE_HINT"; J_REASON="$APP_ROLE_HINT"; return 2; fi
            fi
            return 0 ;;
        1)
            if [[ -s "$ROLLBACK/data/host_uuid" ]]; then
                warn "кластер отказал: $REFUSAL — возвращаю прежнее подключение"
                restore_rollback
                join_fail failed "$REFUSAL" "join не удался (${REFUSAL_DETAIL:-$REFUSAL}), прежняя регистрация восстановлена"
            fi
            rm -r -f -- "$ROLLBACK"
            join_refuse "$REFUSAL" "$REFUSAL_DETAIL"
            log "ответ агента: ${REFUSAL_DETAIL:-—}"
            join_fail refused "$REFUSAL" "кластер отказал в регистрации: $REFUSAL. Повторов не будет: $JOIN_HINT" ;;
    esac

    # 5. Not confirmed in time, no refusal seen.
    if [[ -s "$ROLLBACK/data/host_uuid" ]]; then
        warn "регистрация не подтвердилась за ${JOIN_TIMEOUT} с — возвращаю прежнее подключение"
        restore_rollback
        join_fail failed "$ATTEMPT_ERROR" "join не удался, прежняя регистрация восстановлена — journalctl -u teleport"
    fi
    rm -r -f -- "$ROLLBACK"
    # The agent keeps trying on its own; the retry units watch it for a
    # refusal and finish the registration (scrub, enable) when it comes.
    join_defer "$ATTEMPT_ERROR"
    log "$ATTEMPT_ERROR — агент продолжает попытки, повтор включён. Ход — cream run teleport status, journalctl -u teleport -f"
    J_RESULT=pending
    return 0
}

# One tick of teleport-join.{service,timer} (and the manual "register now" of
# a deferred join): retry a join that waits. 0 — registered or still waiting
# (the next tick retries); 1 — the cluster refused (no more retries). cream
# holds lock/teleport: a tick never meets a running join.
cmd_join_retry(){
    need_root
    load_conf
    if [[ ! -f "$JOIN_PENDING" ]]; then
        log "ждущего подключения нет — повторы выключаю"
        if has_systemd; then
            systemctl disable "$JOIN_SERVICE" >/dev/null 2>&1 || true
            systemctl disable --now "$JOIN_TIMER" >/dev/null 2>&1 || true
        fi
        return 0
    fi
    if joined; then
        scrub_token
        join_settle
        log "нода $(nodename 2>/dev/null || echo '?') зарегистрирована в ${C[TELEPORT_PROXY]} — повторы выключены"
        return 0
    fi
    if [[ -z "${C[TELEPORT_PROXY]}" ]]; then
        join_refuse "кластер не задан (TELEPORT_PROXY пуст)" ""
        die "кластер не задан — повторять нечего; выполните cream run teleport join заново"
    fi
    if [[ ! -s "$REG_SECRET" ]]; then
        join_refuse "секрета регистрации на машине нет" ""
        die "секрета первого входа нет — повторять нечем: $JOIN_HINT"
    fi
    local proxy server prc=0 agent mismatch
    proxy="$(proxy_with_port "${C[TELEPORT_PROXY]}")"
    server="$(probe_proxy "$proxy")" || prc=$?
    if (( prc )); then
        join_wait_record "прокси $proxy недоступен: $(net_reason "$prc")"
        log "прокси $proxy недоступен ($(net_reason "$prc")) — повтор на следующем тике (попыток: $((PEND_ATTEMPTS + 1)))"
        return 0
    fi
    agent="$(version_of_agent)"
    if [[ -n "$server" && -n "$agent" ]] && mismatch="$(version_mismatch "$agent" "$server")"; then
        # Not final: the cluster or the image may be updated.
        join_wait_record "$mismatch"
        log "ОШИБКА: $mismatch — повтор на следующем тике"
        return 0
    fi
    attempt_register
    case $? in
        0)
            scrub_token
            join_settle
            log "нода $(nodename) зарегистрирована в ${C[TELEPORT_PROXY]} — секрет стёрт, повторы выключены"
            return 0 ;;
        1)
            join_refuse "$REFUSAL" "$REFUSAL_DETAIL"
            log "ответ агента: ${REFUSAL_DETAIL:-—}"
            die "кластер отказал в регистрации: $REFUSAL. Повторов не будет: $JOIN_HINT" ;;
    esac
    join_wait_record "$ATTEMPT_ERROR"
    log "$ATTEMPT_ERROR — повтор на следующем тике"
    return 0
}

# The registration, its secret and the retries go; the domain keeps the
# operator's knobs. leave_wipe is shared with the remove hook.
leave_wipe(){
    if has_systemd; then
        systemctl disable --now teleport.service >/dev/null 2>&1 || true
        systemctl disable "$JOIN_SERVICE" >/dev/null 2>&1 || true
        systemctl disable --now "$JOIN_TIMER" >/dev/null 2>&1 || true
    fi
    [[ -d "$DATA" ]] && find "$DATA" -mindepth 1 -maxdepth 1 -exec rm -r -f -- {} +
    rm -f -- "$YAML"
    rm -r -f -- "$ROLLBACK"
    rm -f -- "$REG_SECRET" "$JOIN_PENDING" "$JOIN_REFUSED"
}

cmd_leave(){
    need_root
    leave_wipe
    save_conf TELEPORT_PROXY= TELEPORT_TOKEN= TELEPORT_CA_PIN= TELEPORT_JOIN_METHOD=token
    log "отключено: агент выключен, состояние стёрто. Запись ноды в кластере исчезнет по истечении heartbeat или удаляется в админке."
    printf '{"result":"left"}\n'
}

fmt_time(){ date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$1"; }

# Registered / refused / waiting for the network / not registered.
join_status(){
    if joined; then
        echo "Регистрация: есть (host_uuid $(cat "$DATA/host_uuid"))"
        if [[ -f "$JOIN_PENDING" ]]; then
            echo "  повторы ещё включены — выключит ближайший тик (cream run teleport join-retry)"
        fi
    elif read_refused; then
        echo "Регистрация: отказ кластера — ${REF_REASON:-причина не записана}${REF_AT:+ ($(fmt_time "$REF_AT"))}"
        [[ -n "$REF_DETAIL" ]] && echo "  ответ агента: $REF_DETAIL"
        echo "  повторов нет: $JOIN_HINT"
    elif read_pending; then
        echo "Регистрация: ждёт сети — попыток ${PEND_ATTEMPTS}${PEND_SINCE:+ с $(fmt_time "$PEND_SINCE")}"
        echo "  последняя попытка: ${PEND_LAST:+$(fmt_time "$PEND_LAST") — }${PEND_ERROR:-—}"
        if has_systemd; then
            echo "  повтор: при загрузке и раз в минуту ($JOIN_TIMER: $(systemctl is-active "$JOIN_TIMER" 2>/dev/null))"
        fi
    else
        echo "Регистрация: нет"
    fi
}

cmd_status(){
    load_conf
    local k v host="" node=""
    echo "Ручки ($CONF):"
    for k in "${KEYS[@]}"; do
        v="${C[$k]}"
        printf '  %-24s %s\n' "$k" "${v:-—}"
    done
    echo
    echo "Агент: $("$TELEPORT_BIN" version 2>/dev/null | head -1 || echo 'не установлен')"
    if has_systemd; then
        echo "Служба teleport: $(systemctl is-active teleport.service 2>/dev/null), $(systemctl is-enabled teleport.service 2>/dev/null)"
    fi
    join_status
    if [[ -s "$REG_SECRET" ]]; then
        echo "Секрет первого входа: задан (стирается после регистрации)"
    elif joined; then
        echo "Секрет первого входа: нет — подключения идут по ключу агента в $DATA"
    else
        echo "Секрет первого входа: нет"
    fi
    app_role_missing && echo "ВНИМАНИЕ: $APP_ROLE_HINT"
    if [[ -n "${C[TELEPORT_PROXY]}" ]]; then
        host="$(proxy_host "$(proxy_with_port "${C[TELEPORT_PROXY]}")")"
        node="$(nodename 2>/dev/null || echo '?')"
        echo "Нода: $node, метки: $(node_labels | tr '\t\n' '= ' )"
    fi
    echo
    echo "Приложения:"
    local out src icon; out="$(collect_apps)"
    if [[ -z "$out" ]]; then
        echo "  —"
    else
        while IFS=$'\t' read -r k v src icon; do
            [[ -n "$icon" ]] && src="$src, иконка $icon"
            if [[ -n "$host" ]]; then
                printf '  %-16s %-32s https://%s.%s.%s  (%s)\n' "$k" "$v" "$k" "$node" "$host" "$src"
            else
                printf '  %-16s %-32s (%s)\n' "$k" "$v" "$src"
            fi
        done <<< "$out"
    fi
}

# reload-apps (teleport-apps.service): a running agent reloads (render + HUP,
# sessions survive); a stopped one only gets the file for its next start.
cmd_reload_apps(){
    need_root
    if agent_active; then
        systemctl reload teleport.service || die "teleport.service не принял reload"
    else
        load_conf
        [[ -n "${C[TELEPORT_PROXY]}" ]] && cmd_render
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Хуки жизненного цикла: бинарь Teleport (ключи scope: install) и юниты
# ---------------------------------------------------------------------------
# dpkg architecture -> Teleport tarball architecture.
teleport_arch(){
    case "$1" in
        amd64) echo amd64 ;;
        arm64) echo arm64 ;;
        *) return 1 ;;
    esac
}
teleport_tarball(){ echo "teleport-v$1-linux-$2-bin.tar.gz"; }
# teleport_url <version> <arch> <mirror>
teleport_url(){
    if [[ -n "$3" ]]; then
        echo "${3%/}/binaries/teleport/$1/$(teleport_tarball "$1" "$2")"
    else
        echo "https://cdn.teleport.dev/$(teleport_tarball "$1" "$2")"
    fi
}
teleport_sha256_url(){ echo "https://cdn.teleport.dev/$(teleport_tarball "$1" "$2").sha256"; }

# fetch_teleport <version> <arch> <sha256> <mirror> <tarball> — the binary in
# place, checked by sha256 before it is unpacked.
fetch_teleport(){
    local version="$1" arch="$2" sha="$3" mirror="$4" tarball="$5" work file src url sha_url from_cdn=0
    install -d -m 0755 "$ROOT/var/tmp" || die "не создать $ROOT/var/tmp"
    work="$(mktemp -d "$ROOT/var/tmp/teleport-install.XXXXXX")" || die "не создать каталог в $ROOT/var/tmp"
    # shellcheck disable=SC2064  # the path is fixed now, on purpose
    trap "rm -r -f -- '$work'" EXIT
    file="$(teleport_tarball "$version" "$arch")"
    if [[ -n "$tarball" ]]; then
        [[ -f "$tarball" ]] || die "TELEPORT_TARBALL=$tarball: файла нет"
        [[ -n "$sha" ]] || die "TELEPORT_TARBALL без TELEPORT_SHA256: офлайн второго канала нет — задайте сумму тарбола"
        src="$tarball"
    else
        command -v curl >/dev/null 2>&1 || die "нужен curl"
        url="$(teleport_url "$version" "$arch" "$mirror")"
        sha_url="$(teleport_sha256_url "$version" "$arch")"
        if [[ -z "$sha" ]]; then
            sha="$(curl -fsSL --retry 5 --retry-delay 3 "$sha_url" | awk '{print $1}')" || true
            [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "не получить $sha_url — задайте TELEPORT_SHA256 явно"
            from_cdn=1
            log "sha256 взят с cdn.teleport.dev"
        fi
        log "скачиваю $url"
        # Stalls become retries instead of an endless wait.
        curl -fL --retry 5 --retry-delay 5 \
            --connect-timeout 30 --speed-limit 10240 --speed-time 60 \
            -o "$work/$file" "$url" || die "тарбол не скачался"
        src="$work/$file"
    fi
    if ! echo "$sha  $src" | sha256sum -c --quiet - >/dev/null 2>&1; then
        # A mirror may carry a rebuilt fork of the same version: its tarball
        # is not the vanilla one the CDN hash describes.
        if (( from_cdn )) && [[ -n "$mirror" ]]; then
            die "тарбол с зеркала не совпал с .sha256 cdn.teleport.dev — на зеркале своя сборка? задайте TELEPORT_SHA256 её хешем"
        fi
        die "sha256 не совпал: $src"
    fi
    # Only the agent: tsh, tctl, tbot and teleport-update are ~370 MB more and
    # a node needs none of them.
    tar -xzf "$src" -C "$work" teleport/teleport || die "в тарболе нет teleport/teleport"
    install -d -m 0755 "$(dirname "$TELEPORT_BIN")" || die "не создать $(dirname "$TELEPORT_BIN")"
    install -m 0755 "$work/teleport/teleport" "$TELEPORT_BIN" || die "не установить $TELEPORT_BIN"
    [[ "$(version_of_agent)" == "$version" ]] || die "teleport version не совпал с $version"
    log "установлен $("$TELEPORT_BIN" version | head -1)"
}

# hook-install | hook-upgrade: the binary by the scope: install keys (cream
# puts them into the environment), directories, path units. Never registers
# and never starts the agent. A new binary on a running machine —
# try-restart; an upgrade without one — render and reload.
hook_install(){
    local mode="$1" version="${TELEPORT_VERSION:-$TELEPORT_DEFAULT_VERSION}" sha="${TELEPORT_SHA256:-}"
    local mirror="${TELEPORT_MIRROR:-}" tarball="${TELEPORT_TARBALL:-}" dpkg_arch arch prev changed=0
    need_root
    [[ "$version" =~ $RE_VERSION ]] || die "TELEPORT_VERSION='$version': ожидали X.Y.Z"
    [[ -z "$sha" || "$sha" =~ ^[0-9a-f]{64}$ ]] || die "TELEPORT_SHA256: ожидали 64 hex"
    [[ -z "$mirror" || "$mirror" =~ ^https?://[A-Za-z0-9.:/-]+$ ]] || die "TELEPORT_MIRROR='$mirror': ожидали URL"
    if [[ -n "$mirror" && -n "$tarball" ]]; then
        die "TELEPORT_MIRROR и TELEPORT_TARBALL взаимоисключимы — задайте одно"
    fi
    # In a build a registration would make every copy of the image one node.
    if [[ "${CREAM_PHASE:-live}" == build ]] && joined; then
        die "в /var/lib/teleport уже есть регистрация — образ стал бы одной нодой на все копии"
    fi
    dpkg_arch="$(dpkg --print-architecture)" || die "dpkg --print-architecture не ответил"
    arch="$(teleport_arch "$dpkg_arch")" || die "архитектура $dpkg_arch не поддерживается"

    install -d -m 0755 "$ETC" "$APPS_DIR" "$CMD_LABELS_DIR" || die "не создать каталоги $ETC"
    install -d -m 0700 "$STATE" || die "не создать $STATE"

    prev="$(version_of_agent)"
    if [[ "$prev" == "$version" ]]; then
        log "Teleport $version уже установлен"
    else
        fetch_teleport "$version" "$arch" "$sha" "$mirror" "$tarball"
        changed=1
    fi

    if has_systemd; then
        systemctl daemon-reload >/dev/null 2>&1 || warn "daemon-reload не удался"
        systemctl enable --now "${PATH_UNITS[@]}" >/dev/null 2>&1 || warn "${PATH_UNITS[*]} не включены"
        if (( changed )) && [[ -n "$prev" ]]; then
            systemctl --no-block try-restart teleport.service >/dev/null 2>&1 || true
            log "бинарь сменился ($prev → $version) — агент перезапускается, если работал"
        elif [[ "$mode" == upgrade ]] && agent_active; then
            load_conf
            if [[ -n "${C[TELEPORT_PROXY]}" ]]; then
                cmd_render
                systemctl --no-block reload teleport.service >/dev/null 2>&1 || true
            fi
        fi
    elif [[ -z "$ROOT" ]] && command -v systemctl >/dev/null 2>&1; then
        # A build or a chroot: links only, nothing starts.
        systemctl enable "${PATH_UNITS[@]}" >/dev/null 2>&1 || warn "${PATH_UNITS[*]} не включены"
    fi
    log "готово: регистрация — printf '%s' '<секрет>' | cream run teleport join TELEPORT_PROXY=… TELEPORT_REGISTRATION_SECRET=- TELEPORT_ENV=…"
}

# hook-remove: leave, units off, the binary and the state gone. The domain,
# the units themselves and (with --purge) /etc/cream/teleport are cream's.
hook_remove(){
    need_root
    leave_wipe
    if has_systemd; then
        systemctl disable --now "${PATH_UNITS[@]}" >/dev/null 2>&1 || true
    fi
    rm -f -- "$TELEPORT_BIN"
    rm -r -f -- "$STATE"
    log "удалено: агент выключен, регистрация и бинарь стёрты"
}

case "${1:-}" in
    join)
        shift
        cmd_join "$@"; rc=$?
        emit_join
        exit "$rc" ;;
    join-retry) cmd_join_retry ;;
    leave) cmd_leave ;;
    status) cmd_status ;;
    render) cmd_render ;;
    reload-apps) cmd_reload_apps ;;
    # The token path unit: the agent registered — on its own, too, while the
    # join waited for the network; then the retries end here as well.
    scrub-token)
        need_root; scrub_token
        if joined && [[ -f "$JOIN_PENDING" ]]; then join_settle; fi ;;
    hook-install) hook_install install ;;
    hook-upgrade) hook_install upgrade ;;
    hook-remove) hook_remove ;;
    hook-apply) cmd_apply ;;
    *) die "неизвестная команда '${1:-}' (join|join-retry|leave|status|render|reload-apps|scrub-token|hook-*)" ;;
esac
