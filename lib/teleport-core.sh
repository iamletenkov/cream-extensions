# shellcheck shell=bash disable=SC2034  # variables are the interface with the layer
# teleport-core.sh — the init-independent core of the Teleport extensions of the
# catalog (spec cream 2026-10-20-openwrt §4.2, rulings Р3, Р11): the knobs, the
# render of /etc/teleport.yaml, join with its retry and refusal, labels, apps.d,
# command labels, bound_keypair, the managed labels of stvor-agent (set-managed,
# managed-status — contract schema 1), status and the dispatch of the actions.
#
# ONE COPY IN GIT: lib/teleport-core.sh. tools/catalog-snapshot.sh (the release
# snapshot) and tools/stage-catalog.sh (cream validate, tests, path source) lay it
# into files/teleport-core.sh of every consumer of lib/teleport-core.consumers;
# tools/check-teleport-core.sh keeps copies out of git, tools/check-version-bump.sh
# makes a change of it raise every consumer. Tests of the core — lib/tests/;
# tests of a layer — in its extension.
#
# A layer — files/teleport.sh of a consumer — sets before `source`:
#   TELEPORT_EXT           the name of the extension (cream set/run/show, hints)
#   TELEPORT_DATA_GUEST    data_dir of the agent (/var/lib/teleport, /opt/teleport/data)
#   TELEPORT_BIN_GUEST     the binary (/usr/local/bin/teleport, /opt/teleport/bin/teleport)
#   INIT_NAME              the init in messages ("systemd", "procd")
#   AGENT_UNIT             the agent's service in messages ("teleport.service")
#   AGENT_LOG_HINT         where its journal is ("journalctl -u teleport")
#   AGENT_LOG_FOLLOW       how to follow it ("journalctl -u teleport -f")
#   LOG_OUTPUT             log.output of teleport.yaml (stderr, syslog)
# and defines, before core_main "$@" (core_require_layer checks it):
#   init_running           the init runs (not an image build or a chroot)
#   agent_active           the agent runs now
#   agent_start, agent_stop, agent_enable, agent_disable, agent_disable_now
#   retry_arm, retry_disarm  the retry of a waiting join (boot + every minute)
#   retry_status_line, service_status_line   lines of `status`
#   agent_log_since <epoch>  the agent's journal since then (refusals of join)
#   app_role_missing       the agent reports a token without the App role
#   apply_running          render and reload a running agent (idempotent join)
#   restart_agent          restart with confirmation (set-managed), 0 — confirmed
#   render_ssh_extra       extra lines of ssh_service in teleport.yaml
#   teleport_tarball <version> <arch>   the file name of the tarball
#   cmd_apply, cmd_reload_apps, cmd_hup, hook_install <install|upgrade>, hook_remove
#
# The binary is run only as `env -u LD_PRELOAD "$TELEPORT_BIN"`: harmless on
# Debian, on OpenWrt it keeps the musl libsetlbf.so of procd out of the glibc
# process (spec §3 p. 1).

LAYER_FUNCS=(init_running agent_active agent_start agent_stop agent_enable agent_disable
             agent_disable_now retry_arm retry_disarm retry_status_line service_status_line
             agent_log_since app_role_missing apply_running restart_agent render_ssh_extra
             teleport_tarball cmd_apply cmd_reload_apps cmd_hup hook_install hook_remove)
LAYER_VARS=(TELEPORT_EXT TELEPORT_DATA_GUEST TELEPORT_BIN_GUEST INIT_NAME AGENT_UNIT
            AGENT_LOG_HINT AGENT_LOG_FOLLOW LOG_OUTPUT)

# core_require_layer: every point of the layer is there — a layer that forgot one
# fails on any command, not in the middle of a join.
core_require_layer(){
    local f v missing=""
    for v in "${LAYER_VARS[@]}"; do [[ -n "${!v:-}" ]] || missing+=" $v"; done
    for f in "${LAYER_FUNCS[@]}"; do declare -F "$f" >/dev/null || missing+=" $f()"; done
    if [[ -n "$missing" ]]; then
        echo "teleport: ОШИБКА: слой ${TELEPORT_EXT:-?} не задал:$missing" >&2
        exit 1
    fi
}
ROOT="${CREAM_ROOT:-}"
ROOT="${ROOT%/}"
ETC="${CREAM_ETC_DIR:-$ROOT/etc/cream/$TELEPORT_EXT}"
STATE="${CREAM_STATE_DIR:-$ROOT/var/lib/cream/ext/$TELEPORT_EXT}"
CONF="${CREAM_CONFIG_FILE:-$ETC/config}"
# The core lies in files/ of the extension, next to the layer.
EXT_DIR="${CREAM_EXT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
APPS_DIR="$ETC/apps.d"
CMD_LABELS_DIR="$ETC/command-labels.d"
YAML="$ROOT/etc/teleport.yaml"
PROC="$ROOT/proc"
# data_dir of the agent: the identity (host_uuid) lives there.
DATA="$ROOT$TELEPORT_DATA_GUEST"
ROLLBACK="$STATE/rollback"
# The path the agent reads (teleport.yaml), and the same file under the root.
REG_SECRET="$STATE/registration-secret"
# The installed pin — what the install hook put in place: two lines
# TELEPORT_VERSION=<X.Y.Z> and TELEPORT_SHA256=<64 hex> (the sum of the tarball
# or the set). A rebuild of the fork keeps X.Y.Z and changes the sum
# (v18.10.0-stvor.3 -> stvor.4), so the hook compares both. A stable interface:
# /etc/stvor/restore.sh of Stvor (OpenWrt) reads the version and the sum of the
# set from it after a sysupgrade (keep.d of teleport-openwrt keeps the file).
INSTALLED_PIN="$STATE/installed-pin"
REG_SECRET_GUEST="${REG_SECRET#"$ROOT"}"
# The path Teleport execs for the os_logins label.
OS_LOGINS_CMD="${EXT_DIR#"$ROOT"}/files/os-logins"
# bound_keypair joining for agents (not only bots) appeared in Teleport 18.8.
BOUND_KEYPAIR_MIN=18.8.0
TELEPORT_BIN="$ROOT$TELEPORT_BIN_GUEST"
TELEPORT_DEFAULT_VERSION=18.10.0
# The wait for the identity after the agent starts, s.
JOIN_TIMEOUT=120

# The knob values are validated by cream; render checks them again (a hand
# edit may put anything into the file) with the same types — KEY_TYPE equals
# config.keys of extension.yaml of every consumer (their tests compare them).
KEYS=(TELEPORT_PROXY TELEPORT_JOIN_METHOD TELEPORT_TOKEN TELEPORT_CA_PIN TELEPORT_ENV
      TELEPORT_NODENAME TELEPORT_LABELS TELEPORT_APPS TELEPORT_APPS_DISABLE
      TELEPORT_APPS_ICONS TELEPORT_APPS_DISCOVERY TELEPORT_OS_LOGINS TELEPORT_MANAGED_LABELS)
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
    [TELEPORT_MANAGED_LABELS]='list:re:^[a-z][a-z0-9_]{0,62}=[a-z0-9][a-z0-9._-]{0,62}$'
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
RE_REG_SECRET='^[[:graph:]]{8,1000}$'
RE_JOIN_TOKEN='^[A-Za-z0-9._-]{8,256}$'
RE_VERSION='^[0-9]+\.[0-9]+\.[0-9]+$'

# Managed labels: at most 16, keys not reserved (as in TELEPORT_LABELS; the
# key alphabet already has no `.` of teleport.icon). managed-pending: a
# restart with them is owed — written before the knob, removed only by a
# confirmed restart (or when nothing is to restart).
MANAGED_MAX=16
MANAGED_PENDING="$STATE/managed-pending"
# The wait for a new run of the agent after the restart, s.
RESTART_TIMEOUT=30
# Command labels: at most 8 files, 8 arguments each; no shell is involved.
CMD_LABELS_MAX=8
CMD_ARGS_MAX=8
RE_CMD_KEY='^[a-z][a-z0-9_]{0,62}$'
RE_CMD_PATH='^/[A-Za-z0-9._+/-]{1,255}$'
RE_CMD_ARG='^[A-Za-z0-9._=-]{1,255}$'

# A join that waits for the network or the proxy. join-pending exists while it
# waits (`since=`, `attempts=`, `last=`, `error=`) and is the condition of the
# retry service; join-refused holds the cluster's refusal (`at=`, `reason=`,
# `detail=`). Both 0600 in the 0700 state directory.
JOIN_PENDING="$STATE/join-pending"
JOIN_REFUSED="$STATE/join-refused"

log(){ >&2 echo "teleport: $*"; }
warn(){ log "ВНИМАНИЕ: $*"; }
# Actions with `output: json` print exactly one object on every exit (cream
# turns a missing one into code 76): DIE_JSON names the function that prints
# it, DIE_CODE is the exit code of a failure. Only the main shell prints: a die
# inside $(…) ends that subshell, and the caller handles its status.
DIE_JSON=""; DIE_CODE=1
die(){
    log "ОШИБКА: $*"
    if [[ -n "$DIE_JSON" && "$BASHPID" == "$$" ]]; then "$DIE_JSON" "$*"; fi
    exit "$DIE_CODE"
}

need_root(){ [[ -n "$ROOT" || "$(id -u)" -eq 0 ]] || die "нужен root (sudo)"; }


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

# re_ok <value> <ERE> — `[[ value =~ ERE ]]` that holds on the regex engine of
# musl (OpenWrt) too: a bound over RE_DUP_MAX (255) is an invalid regex there,
# and the types keep the bounds of cream (RE2): {8,256}, {8,1000}. The anchored
# form ^<bracket expression>{m,n}$ with n > 255 is checked as a length and
# ^<bracket expression>+$ — the same answer glibc gives for the original.
RE_BOUNDED_CLASS='^\^(\[\[:[a-z]+:\]\]|\[[^]]+\])\{([0-9]+),([0-9]+)\}\$$'
re_ok(){
    local v="$1" re="$2" cls one
    if [[ "$re" =~ $RE_BOUNDED_CLASS ]] && (( 10#${BASH_REMATCH[3]} > 255 )); then
        cls="${BASH_REMATCH[1]}"
        (( ${#v} >= 10#${BASH_REMATCH[2]} && ${#v} <= 10#${BASH_REMATCH[3]} )) || return 1
        one="^${cls}+\$"
        [[ "$v" =~ $one ]]
        return
    fi
    [[ "$v" =~ $re ]]
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
        re:*) re="${t#re:}"; re_ok "$v" "$re" ;;
        list:re:*)
            re="${t#list:re:}"
            while IFS= read -r item; do
                re_ok "$item" "$re" || return 1
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
    local k bad=0 why
    for k in "${KEYS[@]}"; do
        if ! check_value "$k" "${C[$k]}"; then
            log "ОШИБКА: $k в $CONF не подходит под тип ${KEY_TYPE[$k]}"; bad=1
        fi
    done
    if (( ! bad )) && ! why="$(managed_problem "${C[TELEPORT_MANAGED_LABELS]}")"; then
        log "ОШИБКА: TELEPORT_MANAGED_LABELS в $CONF: $why"; bad=1
    fi
    (( ! bad ))
}

managed_reserved(){
    case "$1" in app|os_logins|teleport.icon) return 0 ;; esac
    return 1
}

# managed_problem <list> — echo what is wrong beyond the type and return 1:
# too many, a key twice, a reserved key. Return 0 silently when fine.
managed_problem(){
    local item k n=0
    local -A seen=()
    while IFS= read -r item; do
        k="${item%%=*}"; n=$((n + 1))
        if managed_reserved "$k"; then echo "ключ '$k' зарезервирован"; return 1; fi
        if [[ -n "${seen[$k]+x}" ]]; then echo "ключ '$k' задан дважды"; return 1; fi
        seen[$k]=1
    done < <(split_list "$1")
    if (( n > MANAGED_MAX )); then echo "больше $MANAGED_MAX меток"; return 1; fi
    return 0
}

# sorted_list <list> — the same items sorted, space-separated: the stored form
# of the managed labels (a set, so the comparison ignores the order).
sorted_list(){ split_list "$1" | LC_ALL=C sort | paste -s -d ' ' -; }

# Write through cream: validation, an atomic write, readonly keys allowed —
# this extension is their owner. No apply hook: the caller renders itself.
save_conf(){
    (( $# )) || return 0
    cream set --no-apply --allow-readonly "$TELEPORT_EXT" "$@" >&2 || die "не записано в домен $TELEPORT_EXT (cream set)"
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

# resolve_nodename [TELEPORT_NODENAME] — NODE: the knob (by default the loaded
# one) or the hostname. Called in the main shell, so a die there prints the
# JSON of an action (DIE_JSON); nodename is the same for $(…) of a log line.
resolve_nodename(){
    local n="${1-${C[TELEPORT_NODENAME]}}"
    [[ -n "$n" ]] || n="$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    [[ "$n" =~ $RE_NODENAME ]] || die "имя ноды '$n' (hostname) не метка DNS — задайте TELEPORT_NODENAME"
    NODE="$n"
}
nodename(){ resolve_nodename && echo "$NODE"; }

# ---------------------------------------------------------------------------
# Приложения: apps.d + TELEPORT_APPS − TELEPORT_APPS_DISABLE
# Выход: строки "имя<TAB>URI<TAB>источник<TAB>иконка", пропуски — в stderr.
# ---------------------------------------------------------------------------
read_decl(){
    local f="$1" line key val name="" uri="" icon="" why
    # A symlink would pass the owner check while pointing at anyone's file.
    # The directory chain is checked once by collect_apps.
    why="$(trusted_node "$f" "файл")" || { warn "пропускаю $f: $why"; return 1; }
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

# apps.d and every directory above it: root's, not writable by others, no
# symlink — otherwise no declaration is read (a journal line says why).
apps_dir_trusted(){
    local why
    why="$(trusted_path "$APPS_DIR" "каталог")" || { warn "пропускаю $APPS_DIR: $why"; return 1; }
}

collect_apps(){
    local -A uri=() src=() disabled=() icon=()
    local order=() f line name u ic item
    if [[ "${C[TELEPORT_APPS_DISCOVERY]}" == 1 && ( -d "$APPS_DIR" || -L "$APPS_DIR" ) ]] \
       && apps_dir_trusted; then
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

# The static labels of the node and of every app: TELEPORT_LABELS, over them
# TELEPORT_MANAGED_LABELS (the managed one wins by key), then env — the
# managed env if set, else TELEPORT_ENV. env never comes from TELEPORT_LABELS:
# it is the access decision. Sorted by key.
node_labels(){
    local -A l=() ; local item k
    while IFS= read -r item; do l[${item%%=*}]="${item#*=}"; done < <(split_list "${C[TELEPORT_LABELS]}")
    while IFS= read -r item; do l[${item%%=*}]="${item#*=}"; done < <(split_list "${C[TELEPORT_MANAGED_LABELS]}")
    [[ -z "${l[env]:-}" && -n "${C[TELEPORT_ENV]}" ]] && l[env]="${C[TELEPORT_ENV]}"
    for k in $(printf '%s\n' "${!l[@]}" | LC_ALL=C sort); do printf '%s\t%s\n' "$k" "${l[$k]}"; done
}

# Operator values the managed labels override: "key<TAB>operator<TAB>managed".
overridden_labels(){
    local -A m=() ; local item k
    while IFS= read -r item; do m[${item%%=*}]="${item#*=}"; done < <(split_list "${C[TELEPORT_MANAGED_LABELS]}")
    while IFS= read -r item; do
        k="${item%%=*}"
        [[ -n "${m[$k]+x}" ]] && printf '%s\t%s\t%s\n' "$k" "${item#*=}" "${m[$k]}"
    done < <(split_list "${C[TELEPORT_LABELS]}")
    if [[ -n "${C[TELEPORT_ENV]}" && -n "${m[env]+x}" ]]; then
        printf '%s\t%s\t%s\n' env "${C[TELEPORT_ENV]}" "${m[env]}"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Командные метки: /etc/cream/teleport/command-labels.d/<ключ>
# Выход: строки "ключ<TAB>файл<TAB>путь<TAB>аргументы через пробел", пропуски —
# в stderr. Файл кладёт другое расширение (files своего манифеста).
# ---------------------------------------------------------------------------
# The owner a file must have: root on a machine; under a scratch root (tests,
# fixtures) — whoever runs this, the "root" of that tree.
expected_uid(){ if [[ -n "$ROOT" ]]; then id -u; else echo 0; fi; }

# trusted_node <path> <what> — not a symlink, owned by the expected uid, no
# write for group or others. Echo the reason and return 1 otherwise.
trusted_node(){
    local owner mode
    if [[ -L "$1" ]]; then echo "$2: символическая ссылка"; return 1; fi
    owner="$(stat -c %u -- "$1" 2>/dev/null)"; mode="$(stat -c %a -- "$1" 2>/dev/null)"
    if [[ ! "$owner" =~ ^[0-9]+$ || ! "$mode" =~ ^[0-7]{3,4}$ ]]; then echo "$2: владелец и права не прочитаны"; return 1; fi
    if [[ "$owner" != "$(expected_uid)" ]]; then echo "$2: владелец не root"; return 1; fi
    if (( (8#$mode & 8#022) != 0 )); then echo "$2: права $mode, запись группе или всем"; return 1; fi
    return 0
}

# trusted_path <path> <what> — trusted_node for the path and for every
# directory above it up to the root ($CREAM_ROOT for a path under it, else /):
# whoever may write any of them may swap what Teleport runs as root.
trusted_path(){
    local p="$1" what="$2" base="" rel d node why
    local -a dirs=()
    if [[ -n "$ROOT" && "$p" == "$ROOT"/* ]]; then base="$ROOT"; rel="${p#"$ROOT"}"; else rel="$p"; fi
    [[ "$rel" == /* ]] || { echo "$what: путь не абсолютный"; return 1; }
    d="${rel%/*}"
    while [[ -n "$d" ]]; do dirs=("$d" "${dirs[@]}"); d="${d%/*}"; done
    for d in "" "${dirs[@]}"; do
        node="$base$d"; [[ -n "$node" ]] || node=/
        why="$(trusted_node "$node" "$what: каталог ${d:-/}")" || { echo "$why"; return 1; }
    done
    trusted_node "$p" "$what"
}

# read_cmd_label <file> <taken keys, "|k1|k2|"> — one checked line or 1.
read_cmd_label(){
    local f="$1" taken="$2" key line="" l n=0 path why arg
    local -a words
    key="${f##*/}"
    if [[ -L "$f" || ! -f "$f" ]]; then warn "пропускаю $f: не обычный файл"; return 1; fi
    [[ "$key" =~ $RE_CMD_KEY ]] || { warn "пропускаю $f: имя файла — ключ метки ^[a-z][a-z0-9_]{0,62}\$"; return 1; }
    case "$key" in
        env|space|app|os_logins)
            warn "пропускаю $f: ключ '$key' зарезервирован"; return 1 ;;
    esac
    # Teleport and Stvor put command labels over the static ones: a command
    # label of a static key could replace space.
    if [[ "$taken" == *"|$key|"* ]]; then
        warn "пропускаю $f: ключ '$key' уже задан статической меткой (TELEPORT_LABELS или управляемой)"; return 1
    fi
    why="$(trusted_node "$f" "файл")" || { warn "пропускаю $f: $why"; return 1; }
    if (( $(stat -c %s -- "$f") > 4096 )); then warn "пропускаю $f: больше 4 КиБ"; return 1; fi
    while IFS= read -r l || [[ -n "$l" ]]; do
        [[ -z "$l" ]] && continue
        n=$((n + 1)); line="$l"
    done < "$f"
    if (( n != 1 )) || [[ ! "$line" =~ ^command=(.+)$ ]]; then
        warn "пропускаю $f: ожидали одну строку command=<путь> [аргумент…]"; return 1
    fi
    read -r -a words <<< "${BASH_REMATCH[1]}"
    path="${words[0]:-}"
    if [[ ! "$path" =~ $RE_CMD_PATH || "/$path/" == */../* || "/$path/" == */./* || "$path" == *//* ]]; then
        warn "пропускаю $f: путь — абсолютный, знаки [A-Za-z0-9._+/-], без . и .. и //"; return 1
    fi
    # A user may own these, and stvor-agent.service does not see them
    # (ProtectHome, PrivateTmp).
    case "$path" in
        /home/*|/tmp/*|/var/tmp/*|/run/user/*)
            warn "пропускаю $f: $path — под /home, /tmp, /var/tmp или /run/user"; return 1 ;;
    esac
    # The command may not exist yet: cream lays a drop-in from `files` before
    # the install hook of its extension unpacks the binary (cream spec §6.5),
    # and a render then must not drop the label for good. Teleport runs the
    # command itself every period. A missing command is kept only directly in
    # a package binary directory — /usr/bin, /usr/sbin, /usr/local/bin — whose
    # chain up to / is trusted (root's, no write for group or others, no
    # symlink): only root can put a file there later. Anywhere else the
    # command must exist now: a regular executable with a trusted chain.
    if [[ -e "$ROOT$path" || -L "$ROOT$path" ]]; then
        if [[ -L "$ROOT$path" || ! -f "$ROOT$path" || ! -x "$ROOT$path" ]]; then
            warn "пропускаю $f: $path — не исполняемый файл"; return 1
        fi
        why="$(trusted_path "$ROOT$path" "$path")" || { warn "пропускаю $f: $why"; return 1; }
    else
        case "${path%/*}" in
            /usr/bin|/usr/sbin|/usr/local/bin) ;;
            *) warn "пропускаю $f: $path — нет файла (без файла допустимы только /usr/bin, /usr/sbin, /usr/local/bin)"; return 1 ;;
        esac
        [[ -d "$ROOT${path%/*}" && ! -L "$ROOT${path%/*}" ]] \
            || { warn "пропускаю $f: ${path%/*} — не каталог"; return 1; }
        why="$(trusted_path "$ROOT${path%/*}" "${path%/*}")" || { warn "пропускаю $f: $why"; return 1; }
    fi
    if (( ${#words[@]} - 1 > CMD_ARGS_MAX )); then
        warn "пропускаю $f: больше $CMD_ARGS_MAX аргументов"; return 1
    fi
    for arg in "${words[@]:1}"; do
        [[ "$arg" =~ $RE_CMD_ARG ]] || { warn "пропускаю $f: аргумент не из [A-Za-z0-9._=-]"; return 1; }
    done
    printf '%s\t%s\t%s\t%s\n' "$key" "$f" "$path" "${words[*]:1}"
}

collect_cmd_labels(){
    local f line n=0 taken="|" item why
    [[ -d "$CMD_LABELS_DIR" || -L "$CMD_LABELS_DIR" ]] || return 0
    why="$(trusted_path "$CMD_LABELS_DIR" "каталог")" || { warn "пропускаю $CMD_LABELS_DIR: $why"; return 0; }
    while IFS= read -r item; do taken+="${item%%=*}|"; done \
        < <(split_list "${C[TELEPORT_LABELS]}"; split_list "${C[TELEPORT_MANAGED_LABELS]}")
    for f in "$CMD_LABELS_DIR"/*; do
        [[ -e "$f" || -L "$f" ]] || continue
        if (( n >= CMD_LABELS_MAX )); then
            warn "пропускаю $f: в $CMD_LABELS_DIR не больше $CMD_LABELS_MAX командных меток"; continue
        fi
        line="$(read_cmd_label "$f" "$taken")" || continue
        printf '%s\n' "$line"; n=$((n + 1))
    done
}

# ---------------------------------------------------------------------------
# teleport.yaml — узел, приложения, метки
# ---------------------------------------------------------------------------
cmd_render(){
    need_root
    load_conf
    render_file "$YAML"
}

# render_file <file> — teleport.yaml from C (loaded by the caller), apps.d and
# command-labels.d, atomically into <file> (0600). Every check (and so every
# die) comes before anything is written.
render_file(){
    conf_check || die "в $CONF неверные значения — cream show $TELEPORT_EXT"
    check_labels "${C[TELEPORT_LABELS]}"
    [[ -n "${C[TELEPORT_PROXY]}" ]] || die "TELEPORT_PROXY не задан — сначала cream run $TELEPORT_EXT join"
    local node proxy host apps labels cmds name uri icon first="" key path args a
    resolve_nodename
    node="$NODE"
    proxy="$(proxy_with_port "${C[TELEPORT_PROXY]}")"
    host="$(proxy_host "$proxy")"
    labels="$(node_labels)"
    apps="$(collect_apps)"
    cmds="$(collect_cmd_labels)"
    if [[ -s "$REG_SECRET" ]]; then
        first="$(< "$REG_SECRET")"
        # A token lands in YAML in double quotes: its alphabet is checked again.
        if [[ "${C[TELEPORT_JOIN_METHOD]}" != bound_keypair ]] && ! re_ok "$first" "$RE_JOIN_TOKEN"; then
            die "$REG_SECRET: join-токен не по форме — выполните join заново"
        fi
    fi

    local dest="$1" tmp
    install -d -m 0755 "$(dirname "$dest")" || die "не создать $(dirname "$dest")"
    # mktemp creates the file 0600: the first-join secret may be in it.
    tmp="$(mktemp "$(dirname "$dest")/.teleport.yaml.XXXXXX")" || die "не создать файл рядом с $dest"
    {
        echo "# Сгенерирован cream run $TELEPORT_EXT render из /etc/cream/$TELEPORT_EXT. Не править:"
        echo "# перезаписывается на каждом старте $AGENT_UNIT."
        echo "version: v3"
        echo "teleport:"
        echo "  nodename: \"$node\""
        echo "  data_dir: $TELEPORT_DATA_GUEST"
        echo "  log:"
        echo "    output: $LOG_OUTPUT"
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
        # The layer's own ssh_service keys (OpenWrt: PAM and BPF off).
        render_ssh_extra
        # Dynamic labels: the agent runs the command every period and puts
        # its trimmed stdout into the label. Node only — apps do not get them.
        if [[ "${C[TELEPORT_OS_LOGINS]}" == 1 || -n "$cmds" ]]; then
            echo "  commands:"
        fi
        if [[ "${C[TELEPORT_OS_LOGINS]}" == 1 ]]; then
            echo "    - name: \"os_logins\""
            echo "      command: [\"$OS_LOGINS_CMD\"]"
            echo "      period: 5m0s"
        fi
        while IFS=$'\t' read -r key _ path args; do
            [[ -n "$key" ]] || continue
            a="\"$path\""
            for name in $args; do a+=", \"$name\""; done
            echo "    - name: \"$key\""
            echo "      command: [$a]"
            echo "      period: 5m0s"
        done <<< "$cmds"
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
    mv -f -- "$tmp" "$dest"
}

# ---------------------------------------------------------------------------
# Служба
# ---------------------------------------------------------------------------
joined(){ [[ -s "$DATA/host_uuid" ]]; }

# Teleport 18 joins roles separately: a token without App still registers the
# SSH node, and app_service keeps retrying with this error (seen on AGX Orin
# 2026-09-14). The identity cannot gain App without a new provision token.
APP_ROLE_ERROR='token does not allow role App'
APP_ROLE_HINT="у токена не было роли App: SSH работает, приложения не опубликованы. Выдайте токен с ролями node,app (в админке — «Разрешить веб-приложения») и выполните join с TELEPORT_FORCE=1"


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
# The binary runs without LD_PRELOAD: on OpenWrt procd may set the musl
# libsetlbf.so, and a glibc process must not load a second libc (spec §3 p. 1).
version_of_agent(){ env -u LD_PRELOAD "$TELEPORT_BIN" version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d v; }

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

# The join waits: record the attempt, retry at every boot and every minute
# (retry_arm of the layer).
join_defer(){
    rm -f -- "$JOIN_REFUSED"
    join_wait_record "$1"
    init_running || return 0
    retry_arm
}

# Registered: no more retries, the agent starts at every boot. retry_disarm
# must not stop the retry that calls this — the tick runs inside it.
join_settle(){
    rm -f -- "$JOIN_PENDING" "$JOIN_REFUSED"
    init_running || return 0
    agent_enable
    retry_disarm
}

# The cluster refused: no retries, the agent off (it would repeat the refusal
# every 90 s forever), the secret gone — it is spent or wrong either way, the
# way out is a new one. join_refuse <reason> <agent's line>
join_refuse(){
    rm -f -- "$JOIN_PENDING" "$REG_SECRET"
    if init_running; then
        agent_disable_now
        retry_disarm
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
        if ! agent_start; then
            ATTEMPT_ERROR="$AGENT_UNIT не стартовал — $AGENT_LOG_HINT"
            return 2
        fi
    fi
    log "жду регистрации (до ${JOIN_TIMEOUT} с)…"
    while :; do
        joined && return 0
        agent_log="$(agent_log_since "$since")"
        if REFUSAL="$(refusal_reason "$agent_log")"; then
            # A refusal ends the registration and erases the secret: a log line
            # alone is not enough — the node must still have no identity.
            joined && return 0
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
    agent_stop
    find "$DATA" -mindepth 1 -maxdepth 1 -exec rm -r -f -- {} +
    find "$ROLLBACK/data" -mindepth 1 -maxdepth 1 -exec mv -t "$DATA" -- {} +
    [[ -f "$ROLLBACK/config" ]] && restore_conf "$ROLLBACK/config"
    [[ -f "$ROLLBACK/teleport.yaml" ]] && cp -a "$ROLLBACK/teleport.yaml" "$YAML"
    # The restored registration has its own identity; the new secret goes.
    rm -f -- "$REG_SECRET"
    agent_start
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
# die inside join: the JSON of a failure (DIE_JSON).
join_die_json(){ J_RESULT=failed; J_REASON="$1"; emit_join; }
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
        if [[ -z "${KEY_TYPE[$key]+x}" && "$JOIN_ONLY_KEYS" != *" $key "* ]] \
           || [[ "$key" == TELEPORT_MANAGED_LABELS ]]; then
            die "join не принимает $key"
        fi
        [[ -z "${N[$key]+x}" ]] || die "ключ $key задан дважды"
        N[$key]="$val"
    done
    [[ -n "${N[TELEPORT_PROXY]:-}" ]] || die "нужен TELEPORT_PROXY=host[:port]"
    # Both meet (( )), which evaluates a[$(cmd)] in its operand: bool is
    # checked here, not trusted to the caller.
    for key in TELEPORT_FORCE TELEPORT_DEFER; do
        if [[ -n "${N[$key]+x}" && ! "${N[$key]}" =~ ^[01]$ ]]; then
            die "$key: ожидали 0 или 1"
        fi
    done
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
        if (( has_secret )) && ! re_ok "$secret" "$RE_REG_SECRET"; then
            die "секрет регистрации: ожидали 8–1000 печатных знаков без пробелов"
        fi
    else
        [[ -z "${N[TELEPORT_TOKEN]:-}" ]] \
            || die "TELEPORT_TOKEN — имя токена bound_keypair; join-токен метода token передаётся TELEPORT_REGISTRATION_SECRET=- (stdin)"
        if (( has_secret )) && ! re_ok "$secret" "$RE_JOIN_TOKEN"; then
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
    # What render will check, by the final knobs (this join over the domain),
    # before anything is written: a failure after step 3 would leave the
    # registration in rollback/.
    check_labels "${N[TELEPORT_LABELS]-${C[TELEPORT_LABELS]}}"
    resolve_nodename "${N[TELEPORT_NODENAME]-${C[TELEPORT_NODENAME]}}"

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
    [[ -n "$agent" ]] || die "$TELEPORT_BIN не отвечает на version — Teleport не установлен? cream install $TELEPORT_EXT"
    # The agent may not be newer than the cluster (below), so an agent of
    # 18.8+ also guarantees the cluster side of bound_keypair.
    if [[ "$method" == bound_keypair ]] && semver_gt "$BOUND_KEYPAIR_MIN" "$agent"; then
        die "bound_keypair: нужен агент версии не ниже $BOUND_KEYPAIR_MIN, установлен $agent — cream install $TELEPORT_EXT TELEPORT_VERSION=…"
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
    if init_running && (( ! defer )); then agent_stop || true; fi
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
    #     disk, nothing is enabled; `cream run <ext> join-retry` registers.
    if (( defer )); then
        rm -r -f -- "$ROLLBACK"
        join_wait_record "регистрация отложена (TELEPORT_DEFER=1) — cream run $TELEPORT_EXT join-retry"
        log "конфиг и секрет записаны, регистрация отложена — зарегистрировать: cream run $TELEPORT_EXT join-retry"
        J_RESULT=deferred
        return 0
    fi

    if ! init_running; then
        rm -r -f -- "$ROLLBACK"
        log "$INIT_NAME не запущен — конфиг записан, агент стартует при загрузке"
        J_RESULT=written
        return 0
    fi

    # 3b. No network or proxy (first boot): everything is on disk — the knobs
    #     in the domain, the secret in $REG_SECRET (0600). The retry units
    #     take over; the agent itself stays off until the proxy answers, so a
    #     refusal is seen by them and not repeated forever.
    if (( prc )); then
        rm -r -f -- "$ROLLBACK"
        agent_disable
        join_defer "прокси ${N[TELEPORT_PROXY]} недоступен: $(net_reason "$prc")"
        log "сеть или прокси ${N[TELEPORT_PROXY]} недоступны ($(net_reason "$prc")) — параметры и секрет сохранены, регистрация повторится после появления сети: при каждой загрузке и раз в минуту. Ход — cream run $TELEPORT_EXT status"
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
        join_fail failed "$ATTEMPT_ERROR" "join не удался, прежняя регистрация восстановлена — $AGENT_LOG_HINT"
    fi
    rm -r -f -- "$ROLLBACK"
    # The agent keeps trying on its own; the retry units watch it for a
    # refusal and finish the registration (scrub, enable) when it comes.
    join_defer "$ATTEMPT_ERROR"
    log "$ATTEMPT_ERROR — агент продолжает попытки, повтор включён. Ход — cream run $TELEPORT_EXT status, $AGENT_LOG_FOLLOW"
    J_RESULT=pending
    return 0
}

# One tick of the retry of the layer (and the manual "register now" of
# a deferred join): retry a join that waits. 0 — registered or still waiting
# (the next tick retries); 1 — the cluster refused (no more retries). cream
# holds lock/teleport: a tick never meets a running join.
cmd_join_retry(){
    need_root
    load_conf
    if [[ ! -f "$JOIN_PENDING" ]]; then
        log "ждущего подключения нет — повторы выключаю"
        if init_running; then retry_disarm; fi
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
        die "кластер не задан — повторять нечего; выполните cream run $TELEPORT_EXT join заново"
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
    if init_running; then
        agent_disable_now
        retry_disarm
    fi
    [[ -d "$DATA" ]] && find "$DATA" -mindepth 1 -maxdepth 1 -exec rm -r -f -- {} +
    rm -f -- "$YAML"
    rm -r -f -- "$ROLLBACK"
    rm -f -- "$REG_SECRET" "$JOIN_PENDING" "$JOIN_REFUSED" "$MANAGED_PENDING"
}

leave_die_json(){ printf '{"result":"failed","reason":%s}\n' "$(json_str "$1")"; }

# The managed labels go too: the next registration may be another robot.
cmd_leave(){
    DIE_JSON=leave_die_json
    need_root
    leave_wipe
    save_conf TELEPORT_PROXY= TELEPORT_TOKEN= TELEPORT_CA_PIN= TELEPORT_JOIN_METHOD=token TELEPORT_MANAGED_LABELS=
    log "отключено: агент выключен, состояние и управляемые метки стёрты. Запись ноды в кластере исчезнет по истечении heartbeat или удаляется в админке."
    printf '{"result":"left"}\n'
}


# ---------------------------------------------------------------------------
# Управляемые метки: set-managed, managed-status (контракт stvor-agent §5.7)
# ---------------------------------------------------------------------------
# The object of schema 1; set-managed adds "result" last. Values are printed
# only after the type check (their alphabet needs no escaping).
managed_json(){
    local item out=""
    while IFS= read -r item; do
        out+="${out:+,}\"${item%%=*}\":\"${item#*=}\""
    done < <(split_list "${C[TELEPORT_MANAGED_LABELS]}")
    printf '{%s}' "$out"
}
emit_managed(){ # emit_managed [result]
    local pend=false reg=false act=false
    [[ -f "$MANAGED_PENDING" ]] && pend=true
    joined && reg=true
    agent_active && act=true
    printf '{"schema":1,"managed":%s,"pending":%s,"joined":%s,"active":%s%s}\n' \
        "$(managed_json)" "$pend" "$reg" "$act" "${1:+,\"result\":\"$1\"}"
}
# A failure: an object without the state (it may be what failed).
managed_die_json(){ printf '{"schema":1,"error":%s}\n' "$(json_str "$1")"; }
# set-managed: a refused input — the object, code 2, nothing touched.
managed_input(){
    log "ОШИБКА: set-managed: $1"
    managed_die_json "$1"
    exit 2
}



# set-managed k=v… — the full set (a replacement: no args = no managed
# labels). Exit 0 — applied | unchanged | deferred, 1 — unconfirmed (the
# marker stays), 2 — refused input, 3 — another failure; one JSON object in
# stdout on each of them. cream holds lock/teleport; the knob is written by the
# nested `cream set --no-apply` (no apply hook: its HUP is not the restart).
cmd_set_managed(){
    DIE_JSON=managed_die_json; DIE_CODE=3
    need_root
    local pair key item_re new="" old changed=0 had_marker=0 why="" cand result
    local -A seen=()
    item_re="${KEY_TYPE[TELEPORT_MANAGED_LABELS]#list:re:}"
    for pair in "$@"; do
        # The value is not echoed: it is external input; the key is, once checked.
        if [[ "$pair" == *[[:cntrl:]]* || ! "$pair" =~ $item_re ]]; then
            managed_input "метка не по типу TELEPORT_MANAGED_LABELS: ключ ^[a-z][a-z0-9_]{0,62}\$, значение ^[a-z0-9][a-z0-9._-]{0,62}\$"
        fi
        key="${pair%%=*}"
        managed_reserved "$key" && managed_input "ключ '$key' зарезервирован"
        [[ -z "${seen[$key]+x}" ]] || managed_input "ключ '$key' задан дважды"
        seen[$key]=1
        new+="${new:+ }$pair"
    done
    (( ${#seen[@]} <= MANAGED_MAX )) || managed_input "больше $MANAGED_MAX управляемых меток"
    new="$(sorted_list "$new")"

    load_conf
    conf_check || die "в $CONF неверные значения — cream show $TELEPORT_EXT"
    old="$(sorted_list "${C[TELEPORT_MANAGED_LABELS]}")"
    [[ "$new" != "$old" ]] && changed=1

    # Not registered (or no init running — an image): the knob only; join renders it.
    if ! init_running || ! joined || [[ -z "${C[TELEPORT_PROXY]}" ]]; then
        (( changed )) && save_conf "TELEPORT_MANAGED_LABELS=$new"
        C[TELEPORT_MANAGED_LABELS]="$new"
        rm -f -- "$MANAGED_PENDING"
        if init_running; then
            log "узел не зарегистрирован — управляемые метки записаны, применятся при регистрации"
        else
            log "$INIT_NAME не запущен — управляемые метки записаны, применятся при старте агента"
        fi
        emit_managed deferred
        return 0
    fi

    # Before the write: whatever happens after it, the restart is owed.
    [[ -f "$MANAGED_PENDING" ]] && had_marker=1
    write_state "$MANAGED_PENDING" "since=$(now_epoch)" || die "не записан $MANAGED_PENDING"
    (( changed )) && save_conf "TELEPORT_MANAGED_LABELS=$new"
    C[TELEPORT_MANAGED_LABELS]="$new"
    cand="$(dirname "$YAML")/.teleport.yaml.candidate"
    render_file "$cand"
    if ! cmp -s -- "$cand" "$YAML"; then why="итоговый конфиг изменился"
    elif (( had_marker )); then why="прошлый перезапуск не подтверждён (managed-pending)"
    elif ! agent_active; then why="агент не активен"
    fi
    if [[ -z "$why" ]]; then
        # teleport.yaml already says this: no restart, nothing to owe.
        rm -f -- "$cand" "$MANAGED_PENDING"
        if (( changed )); then result=applied; else result=unchanged; fi
        log "управляемые метки: ${new:-—} — итоговый конфиг тот же, перезапуск не нужен ($result)"
        emit_managed "$result"
        return 0
    fi
    mv -f -- "$cand" "$YAML"
    log "перезапуск агента с управляемыми метками ${new:-—}: $why"
    if ! restart_agent; then
        log "ОШИБКА: агент не подтвердил перезапуск за ${RESTART_TIMEOUT} с — маркер managed-pending остаётся, следующий set-managed перезапустит снова; $AGENT_LOG_HINT"
        emit_managed unconfirmed
        return 1
    fi
    rm -f -- "$MANAGED_PENDING"
    log "агент перезапущен: узел и приложения — с новыми метками"
    emit_managed applied
    return 0
}

# managed-status — reads only (lock: none): the knob, the marker, the
# registration and the unit. A knob out of type is an error (code 3), not a
# state: the agent must not act on it.
cmd_managed_status(){
    DIE_JSON=managed_die_json; DIE_CODE=3
    local why
    load_conf
    check_value TELEPORT_MANAGED_LABELS "${C[TELEPORT_MANAGED_LABELS]}" \
        || die "TELEPORT_MANAGED_LABELS в $CONF не подходит под тип"
    why="$(managed_problem "${C[TELEPORT_MANAGED_LABELS]}")" || die "TELEPORT_MANAGED_LABELS в $CONF: $why"
    emit_managed
}

fmt_time(){ date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$1"; }

# Registered / refused / waiting for the network / not registered.
join_status(){
    if joined; then
        echo "Регистрация: есть (host_uuid $(cat "$DATA/host_uuid"))"
        if [[ -f "$JOIN_PENDING" ]]; then
            echo "  повторы ещё включены — выключит ближайший тик (cream run $TELEPORT_EXT join-retry)"
        fi
    elif read_refused; then
        echo "Регистрация: отказ кластера — ${REF_REASON:-причина не записана}${REF_AT:+ ($(fmt_time "$REF_AT"))}"
        [[ -n "$REF_DETAIL" ]] && echo "  ответ агента: $REF_DETAIL"
        echo "  повторов нет: $JOIN_HINT"
    elif read_pending; then
        echo "Регистрация: ждёт сети — попыток ${PEND_ATTEMPTS}${PEND_SINCE:+ с $(fmt_time "$PEND_SINCE")}"
        echo "  последняя попытка: ${PEND_LAST:+$(fmt_time "$PEND_LAST") — }${PEND_ERROR:-—}"
        retry_status_line
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
    echo "Агент: $(env -u LD_PRELOAD "$TELEPORT_BIN" version 2>/dev/null | head -1 || echo 'не установлен')"
    service_status_line
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
    echo "Управляемые метки: ${C[TELEPORT_MANAGED_LABELS]:-—}"
    [[ -f "$MANAGED_PENDING" ]] && echo "  перезапуск с ними не подтверждён (managed-pending) — повторит следующий set-managed"
    local ok ov mv src icon
    while IFS=$'\t' read -r k ov mv; do
        [[ -n "$k" ]] && echo "  $k=$ov оператора — перекрыто управляемой меткой ($k=$mv)"
    done <<< "$(overridden_labels)"
    echo "Командные метки:"
    ok=0
    if [[ "${C[TELEPORT_OS_LOGINS]}" == 1 ]]; then
        printf '  %-16s %s  (TELEPORT_OS_LOGINS)\n' os_logins "$OS_LOGINS_CMD"; ok=1
    fi
    while IFS=$'\t' read -r k src v icon; do
        [[ -n "$k" ]] || continue
        printf '  %-16s %s  (%s)\n' "$k" "$v${icon:+ $icon}" "$src"; ok=1
    done <<< "$(collect_cmd_labels)"
    (( ok )) || echo "  —"
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

# teleport_url <version> <arch> <mirror>
teleport_url(){
    if [[ -n "$3" ]]; then
        echo "${3%/}/binaries/teleport/$1/$(teleport_tarball "$1" "$2")"
    else
        echo "https://cdn.teleport.dev/$(teleport_tarball "$1" "$2")"
    fi
}
teleport_sha256_url(){ echo "https://cdn.teleport.dev/$(teleport_tarball "$1" "$2").sha256"; }

# fetch_tarball <version> <arch> <sha256> <mirror> <tarball> <work parent> — the
# tarball of the layer (teleport_tarball) checked by sha256: FETCH_SRC is its
# path, FETCH_WORK the scratch directory under <work parent> (removed on exit).
# The layer unpacks it. An empty sha256 is taken from cdn.teleport.dev;
# FETCH_SHA is the sum the tarball was checked by.
FETCH_SRC="" FETCH_WORK="" FETCH_SHA=""
fetch_tarball(){
    local version="$1" arch="$2" sha="$3" mirror="$4" tarball="$5" parent="$6" work file src url sha_url from_cdn=0
    install -d -m 0755 "$parent" || die "не создать $parent"
    work="$(mktemp -d "$parent/teleport-install.XXXXXX")" || die "не создать каталог в $parent"
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
    # By value, not `sha256sum -c --quiet`: busybox (OpenWrt) has no --quiet.
    if [[ "$(sha256sum < "$src" 2>/dev/null | cut -c1-64)" != "$sha" ]]; then
        # A mirror may carry a rebuilt fork of the same version: its tarball
        # is not the vanilla one the CDN hash describes.
        if (( from_cdn )) && [[ -n "$mirror" ]]; then
            die "тарбол с зеркала не совпал с .sha256 cdn.teleport.dev — на зеркале своя сборка? задайте TELEPORT_SHA256 её хешем"
        fi
        die "sha256 не совпал: $src"
    fi
    FETCH_SRC="$src" FETCH_WORK="$work" FETCH_SHA="$sha"
}

# pin_field <KEY> — a line of the installed pin, by the form of its value.
pin_field(){
    local line re
    case "$1" in
        TELEPORT_VERSION) re="$RE_VERSION" ;;
        TELEPORT_SHA256) re='^[0-9a-f]{64}$' ;;
        *) return 1 ;;
    esac
    [[ -f "$INSTALLED_PIN" ]] || return 1
    while IFS= read -r line; do
        if [[ "$line" == "$1="* && "${line#*=}" =~ $re ]]; then
            printf '%s\n' "${line#*=}"
            return 0
        fi
    done < "$INSTALLED_PIN"
    return 1
}

# binary_current <version> <sha256> — the binary of <version> is in place and,
# with a sum given, the installed pin says it came from the tarball of that sum
# (no pin — unknown, so not current). Without a sum (the .sha256 of the CDN) —
# the version alone, as before.
binary_current(){
    [[ "$(version_of_agent)" == "$1" ]] || return 1
    [[ -n "$2" ]] || return 0
    [[ "$(pin_field TELEPORT_VERSION)" == "$1" && "$(pin_field TELEPORT_SHA256)" == "$2" ]]
}

# pin_change_line <version> <sha256> — why the same version is installed again.
pin_change_line(){
    local was
    was="$(pin_field TELEPORT_SHA256)" || was=""
    if [[ -n "$was" && "$(pin_field TELEPORT_VERSION)" == "$1" ]]; then
        log "Teleport $1: сумма набора сменилась (${was:0:12}… → ${2:0:12}…) — ставлю заново"
    else
        log "Teleport $1: сумма поставленного набора неизвестна — ставлю заново по TELEPORT_SHA256"
    fi
}

# write_installed_pin <version> <sha256> — after the binary is in place.
write_installed_pin(){
    write_state "$INSTALLED_PIN" "$(printf 'TELEPORT_VERSION=%s\nTELEPORT_SHA256=%s' "$1" "$2")" \
        || warn "не записан ${INSTALLED_PIN#"$ROOT"} — следующий install поставит набор заново"
}

core_main(){
    core_require_layer
case "${1:-}" in
    join)
        shift
        DIE_JSON=join_die_json
        cmd_join "$@"; rc=$?
        emit_join
        exit "$rc" ;;
    join-retry) cmd_join_retry ;;
    leave) cmd_leave ;;
    status) cmd_status ;;
    set-managed) shift; cmd_set_managed "$@" ;;
    managed-status) cmd_managed_status ;;
    render) cmd_render ;;
    reload-apps) cmd_reload_apps ;;
    hup) cmd_hup ;;
    # The token path unit: the agent registered — on its own, too, while the
    # join waited for the network; then the retries end here as well.
    scrub-token)
        need_root; scrub_token
        if joined && [[ -f "$JOIN_PENDING" ]]; then join_settle; fi ;;
    hook-install) hook_install install ;;
    hook-upgrade) hook_install upgrade ;;
    hook-remove) hook_remove ;;
    hook-apply) cmd_apply ;;
    *) die "неизвестная команда '${1:-}' (join|join-retry|leave|status|set-managed|managed-status|render|reload-apps|hup|scrub-token|hook-*)" ;;
esac
}
