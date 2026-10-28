#!/usr/bin/env bash
# shellcheck disable=SC2034  # the points of the layer are read by the sourced core
# teleport.sh — the procd layer of the cream extension `teleport-openwrt` (OpenWrt
# 25.12+, spec cream 2026-10-20-openwrt, variant A): hooks and actions are thin
# entries that exec this file with their name. The init-independent part — knobs,
# render, join, labels, apps.d, managed labels, status, the dispatch — is the
# shared core files/teleport-core.sh (one copy in git: lib/teleport-core.sh of the
# catalog; the snapshot lays it here). Commands and keys are those of
# debian/teleport; this file sets what differs on OpenWrt:
#
#   layout     /opt/teleport/bin/{teleport,fdpass-teleport} (patchelf'd to the glibc
#              runtime /opt/teleport/lib), data_dir /opt/teleport/data, TMPDIR
#              /opt/teleport/tmp (/tmp and /var are RAM), the marker
#              /opt/teleport/.cream-owned, the link /usr/bin/teleport
#   binary     the set teleport-v<ver>-openwrt-<arch>-bin.tar.gz (teleport/teleport,
#              teleport/fdpass-teleport, teleport/lib/) built by the Stvor stand
#              (ruling Р7) — from TELEPORT_DIST, TELEPORT_MIRROR or TELEPORT_TARBALL, always by
#              TELEPORT_SHA256 (no such set on cdn.teleport.dev); the architecture —
#              `uname -m`
#   init       /etc/init.d/teleport (procd, files/teleport.init): the instance
#              teleport (enabled: $STATE/agent-enabled; started now:
#              /var/run/teleport.start), the instance join (while
#              $STATE/join-pending exists). The agent alone is stopped by
#              `ubus call service delete` of its instance — the retry may be the
#              caller. No HUP: a Teleport parent that forks on HUP and exits would
#              be respawned by procd next to its child, so changes restart the node.
#   journal    the file /opt/teleport/log/teleport.log (log.output; directory 0700,
#              file 0600, size-limited by the service before a start), cut by the
#              time of its lines. Not syslog: any local process writes there any
#              tag with any pid (`logger -t 'teleport[1234]'`), and a refusal of
#              the cluster ends a registration
#   yaml       log.output — that file, ssh_service.pam and enhanced_recording off
#
# Busybox of OpenWrt has no stat, install, hostname or paste: the functions below
# stand in for the forms the core uses, only where the command is missing.
#
# No test switches in the environment: the tests substitute commands through
# PATH (ubus, jsonfilter, uname, curl, sleep…) and the root through
# CREAM_ROOT — "procd runs" is the ubus socket $CREAM_ROOT/var/run/ubus/ubus.sock.
set -uo pipefail

TELEPORT_EXT=teleport-openwrt
TELEPORT_HOME_GUEST=/opt/teleport
TELEPORT_DATA_GUEST=/opt/teleport/data
TELEPORT_BIN_GUEST=/opt/teleport/bin/teleport
INIT_NAME=procd
AGENT_UNIT=/etc/init.d/teleport
AGENT_LOG_HINT="tail /opt/teleport/log/teleport.log"
AGENT_LOG_FOLLOW="tail -f /opt/teleport/log/teleport.log"
LOG_OUTPUT=/opt/teleport/log/teleport.log

# ---------------------------------------------------------------------------
# Busybox: stand-ins for the forms the core uses (stat -c %u|%a|%s, install -d
# -m / install -m, hostname -s, paste -s -d ' ' -)
# ---------------------------------------------------------------------------
# owrt_mode <ls permissions> — the octal of stat %a: 755, 600, 1777.
owrt_mode(){
    local p="$1" i c o=0 s=0
    local -a bits=(256 128 64 32 16 8 4 2 1)
    for i in 0 1 2 3 4 5 6 7 8; do
        c="${p:$((i + 1)):1}"
        case "$c" in r|w|x|s|t) o=$((o + bits[i])) ;; esac
        case "$i$c" in 2s|2S) s=$((s | 4)) ;; 5s|5S) s=$((s | 2)) ;; 8t|8T) s=$((s | 1)) ;; esac
    done
    if (( s )); then printf '%o%03o\n' "$s" "$o"; else printf '%o\n' "$o"; fi
}
# owrt_stat -c %u|%a|%s [--] <path>
owrt_stat(){
    local fmt="" path="" line perms uid size
    while (( $# )); do
        case "$1" in
            -c) fmt="${2:-}"; shift 2 ;;
            --) path="${2:-}"; break ;;
            *) path="$1"; shift ;;
        esac
    done
    line="$(ls -ldn -- "$path" 2>/dev/null)" || return 1
    read -r perms _ uid _ size _ <<< "$line"
    case "$fmt" in
        %u) printf '%s\n' "$uid" ;;
        %s) printf '%s\n' "$size" ;;
        %a) owrt_mode "$perms" ;;
        *) return 1 ;;
    esac
}
# owrt_install -d [-m MODE] DIR… | owrt_install [-m MODE] SRC DST
owrt_install(){
    local dir=0 mode="" tmp
    local -a args=()
    while (( $# )); do
        case "$1" in
            -d) dir=1; shift ;;
            -m) mode="${2:-}"; shift 2 ;;
            --) shift; args+=("$@"); break ;;
            *) args+=("$1"); shift ;;
        esac
    done
    (( ${#args[@]} )) || return 1
    if (( dir )); then
        mkdir -p -- "${args[@]}" || return 1
        [[ -z "$mode" ]] || chmod "$mode" -- "${args[@]}"
        return
    fi
    (( ${#args[@]} == 2 )) || return 1
    tmp="${args[1]}.install.$$"
    cp -- "${args[0]}" "$tmp" || return 1
    if [[ -n "$mode" ]] && ! chmod "$mode" -- "$tmp"; then rm -f -- "$tmp"; return 1; fi
    mv -f -- "$tmp" "${args[1]}"
}
# owrt_hostname -s — the short kernel hostname.
owrt_hostname(){
    local h
    h="$(cat /proc/sys/kernel/hostname 2>/dev/null)" || return 1
    printf '%s\n' "${h%%.*}"
}
# owrt_paste -s -d ' ' - — the lines of stdin joined by a space.
owrt_paste(){
    local line out="" first=1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if (( first )); then out="$line"; first=0; else out+=" $line"; fi
    done
    printf '%s\n' "$out"
}
command -v stat >/dev/null 2>&1 || stat(){ owrt_stat "$@"; }
command -v install >/dev/null 2>&1 || install(){ owrt_install "$@"; }
command -v hostname >/dev/null 2>&1 || hostname(){ owrt_hostname "$@"; }
command -v paste >/dev/null 2>&1 || paste(){ owrt_paste "$@"; }

# shellcheck source=lib/teleport-core.sh
. "$(dirname "${BASH_SOURCE[0]}")/teleport-core.sh" || { echo "teleport: ОШИБКА: нет files/teleport-core.sh" >&2; exit 1; }

TELEPORT_HOME="$ROOT$TELEPORT_HOME_GUEST"
TELEPORT_LIB="$TELEPORT_HOME/lib"
TELEPORT_TMP="$TELEPORT_HOME/tmp"
LOG_FILE="$ROOT$LOG_OUTPUT"
FDPASS_BIN="$TELEPORT_HOME/bin/fdpass-teleport"
OWNED="$TELEPORT_HOME/.cream-owned"
LINK="$ROOT/usr/bin/teleport"
INIT_SCRIPT="$ROOT/etc/init.d/teleport"
# Enabled: the node starts at every boot. Started: this boot only (tmpfs).
AGENT_ENABLED="$STATE/agent-enabled"
RUN_FLAG="$ROOT/var/run/teleport.start"
STARTED="$ROOT/var/run/teleport.started"

# ---------------------------------------------------------------------------
# Точки слоя для ядра: init — procd
# ---------------------------------------------------------------------------
init_running(){ [[ -e "$ROOT/var/run/ubus/ubus.sock" ]]; }
# rc.common takes /var/lock/procd_teleport.lock; an image build (or a container)
# has no /var/lock yet — S10boot makes it on a machine, so it is made here.
svc(){
    [[ -d "$ROOT/var/lock" ]] || mkdir -p -- "$ROOT/var/lock" 2>/dev/null
    "$INIT_SCRIPT" "$@" >/dev/null 2>&1
}

# agent_pid: the pid of the running instance teleport of the service, or 1.
agent_pid(){
    local out run pid
    out="$(ubus call service list '{"name":"teleport"}' 2>/dev/null)" || return 1
    run="$(jsonfilter -s "$out" -e '@.teleport.instances.teleport.running' 2>/dev/null)"
    pid="$(jsonfilter -s "$out" -e '@.teleport.instances.teleport.pid' 2>/dev/null)"
    [[ "$run" == true && "$pid" =~ ^[1-9][0-9]{0,9}$ ]] || return 1
    printf '%s\n' "$pid"
}
agent_active(){ init_running && agent_pid >/dev/null; }

# Started now (not enabled): the flag of this boot, then the service evaluated
# again — procd adds the instance teleport and keeps an unchanged join running.
agent_start(){
    install -d -m 0755 "$(dirname "$RUN_FLAG")" 2>/dev/null
    : > "$RUN_FLAG" 2>/dev/null
    svc start
}
# The instance teleport alone (the retry may be the caller), and the wait for its
# exit: a new agent next to a draining one would share data_dir.
agent_stop(){
    local waited=0
    rm -f -- "$RUN_FLAG"
    ubus call service delete '{"name":"teleport","instance":"teleport"}' >/dev/null 2>&1
    while agent_pid >/dev/null; do
        (( waited < RESTART_TIMEOUT )) || return 1
        sleep 1; waited=$((waited + 1))
    done
    return 0
}
agent_enable(){ install -d -m 0700 "$STATE" && : > "$AGENT_ENABLED" && chmod 0600 -- "$AGENT_ENABLED"; }
agent_disable(){ rm -f -- "$AGENT_ENABLED"; }
agent_disable_now(){ rm -f -- "$AGENT_ENABLED"; agent_stop || true; }
# The retry: the instance join while join-pending exists (boot + every minute).
retry_arm(){ svc start || warn "$AGENT_UNIT start не прошёл — повтор поднимется при загрузке"; }
# Nothing to stop: the instance join ends by itself once join-pending is gone, and
# the tick that settles the join runs inside it.
retry_disarm(){ :; }
retry_status_line(){
    if init_running; then
        echo "  повтор: при загрузке и раз в минуту (экземпляр join службы $AGENT_UNIT)"
    fi
}
service_status_line(){
    local act=inactive en=disabled
    init_running || return 0
    agent_active && act=active
    [[ -e "$AGENT_ENABLED" ]] && en=enabled
    echo "Служба teleport (procd): $act, $en"
}
# The journal of the node since an epoch: the lines of the log file of the agent
# (log.output; only root writes in its 0700 directory) whose leading timestamp
# — RFC 3339, Z or ±hh:mm — is not before the epoch. A line without one is not
# taken. The file must be a trusted regular file (root's, no write for others).
agent_log_since(){
    init_running || return 0
    [[ -f "$LOG_FILE" && ! -L "$LOG_FILE" ]] || return 0
    trusted_path "$LOG_FILE" "журнал" >/dev/null || return 0
    awk -v since="$1" '
        function days(y, m, d,   era, yoe, doy) {
            y -= (m <= 2); era = int((y >= 0 ? y : y - 399) / 400); yoe = y - era * 400
            doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
            return era * 146097 + yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy - 719468
        }
        match($0, /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9](\.[0-9]+)?(Z|[+-][0-9][0-9]:?[0-9][0-9])/) {
            ts = substr($0, 1, RLENGTH)
            t = days(substr(ts, 1, 4) + 0, substr(ts, 6, 2) + 0, substr(ts, 9, 2) + 0) * 86400 \
                + substr(ts, 12, 2) * 3600 + substr(ts, 15, 2) * 60 + substr(ts, 18, 2)
            z = substr(ts, length(ts), 1)
            if (z != "Z") {
                off = substr(ts, match(ts, /[+-][0-9][0-9]:?[0-9][0-9]$/))
                gsub(/:/, "", off)
                sec = substr(off, 2, 2) * 3600 + substr(off, 4, 2) * 60
                t -= (substr(off, 1, 1) == "-" ? -sec : sec)
            }
            if (t >= since + 0) print
        }' "$LOG_FILE" 2>/dev/null || true
}
# Since the last start of the instance (start_service writes the epoch).
app_role_missing(){
    local since log
    init_running && agent_active || return 1
    since="$(head -c 16 -- "$STARTED" 2>/dev/null | tr -cd '0-9')"
    log="$(agent_log_since "${since:-0}")"
    grep -q "$APP_ROLE_ERROR" <<< "$log"
}
# Idempotent join: a running agent reads the knobs only on a restart.
apply_running(){
    init_running || return 0
    if agent_active; then
        cmd_render
        restart_agent || warn "агент не подтвердил перезапуск — $AGENT_LOG_HINT"
    fi
}
# restart_agent: the service restarted, confirmed by a new pid of a running instance.
restart_agent(){
    local waited=0 before now
    before="$(agent_pid || true)"
    svc restart || return 1
    while :; do
        if now="$(agent_pid)" && [[ "$now" != "$before" ]]; then
            return 0
        fi
        (( waited < RESTART_TIMEOUT )) || return 1
        sleep 1; waited=$((waited + 1))
    done
}
render_ssh_extra(){
    echo "  pam:"
    echo "    enabled: false"
    echo "  enhanced_recording:"
    echo "    enabled: false"
}
teleport_tarball(){ echo "teleport-v$1-openwrt-$2-bin.tar.gz"; }

# Apply hook: render synchronously — a bad value fails loudly here — and restart
# a running agent in the background (`cream set` may run inside a boot script;
# validate.apply_blocking).
cmd_apply(){
    need_root
    load_conf
    if [[ -z "${C[TELEPORT_PROXY]}" ]]; then
        log "записано; кластер не задан — cream run $TELEPORT_EXT join"
        return 0
    fi
    if agent_active; then
        cmd_render
        "$INIT_SCRIPT" restart >/dev/null 2>&1 &
        log "применено: агент перезапускается"
    else
        log "записано; применится при старте агента"
    fi
}

# reload-apps: the one point where a change of apps.d or command-labels.d reaches
# the agent — the extension that laid it calls `cream run teleport-openwrt
# reload-apps` (no path units on OpenWrt). An unchanged teleport.yaml — nothing;
# a changed one — a confirmed restart (open sessions drop; no HUP, see the header).
yaml_sum(){ [[ -f "$YAML" ]] && sha256sum < "$YAML" | cut -c1-64; }
cmd_reload_apps(){
    local before
    need_root
    load_conf
    [[ -n "${C[TELEPORT_PROXY]}" ]] || return 0
    before="$(yaml_sum || true)"
    cmd_render
    init_running || return 0
    if ! agent_active; then
        log "агент не запущен — конфиг применится при старте"
        return 0
    fi
    if [[ "$(yaml_sum || true)" == "$before" ]]; then
        log "teleport.yaml не изменился — перезапуск не нужен"
        return 0
    fi
    restart_agent || die "агент не подтвердил перезапуск за ${RESTART_TIMEOUT} с — $AGENT_LOG_HINT"
    log "агент перезапущен с новым teleport.yaml"
}
cmd_hup(){
    log "hup — только для ExecReload systemd; на OpenWrt изменения применяет cream run $TELEPORT_EXT reload-apps"
    exit 2
}

# ---------------------------------------------------------------------------
# Хуки жизненного цикла: набор openwrt-<arch> (ключи scope: install) и служба
# ---------------------------------------------------------------------------
# uname -m -> the architecture of the set.
teleport_arch(){
    case "$1" in
        x86_64|amd64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        *) return 1 ;;
    esac
}

# Teleport under /opt/teleport that cream did not put there: refuse, never adopt.
foreign_teleport(){
    [[ -e "$OWNED" ]] && return 1
    [[ -e "$TELEPORT_BIN" || -s "$DATA/host_uuid" ]]
}

# fetch_set <version> <arch> <sha256> <mirror> <tarball> <dist> <tag> — the set in
# place: runtime first (the binaries are patched to it), then the binaries, each
# by a rename on the same file system (no second copy of 370 MB).
fetch_set(){
    local version="$1" work src b
    # Scratch on the same file system as the set (renames, not copies); not in
    # TMPDIR of the agent, whose mode the scratch parent would get.
    fetch_tarball "${@:1:5}" "$TELEPORT_HOME" "${@:6:2}"
    work="$FETCH_WORK" src="$FETCH_SRC"
    tar -xzf "$src" -C "$work" teleport || die "в наборе нет каталога teleport/"
    for b in teleport fdpass-teleport; do
        [[ -f "$work/teleport/$b" ]] || die "в наборе нет teleport/$b"
    done
    [[ -d "$work/teleport/lib" && -n "$(ls -A -- "$work/teleport/lib")" ]] \
        || die "в наборе нет glibc-рантайма teleport/lib/ — набор openwrt-<arch> собирает стенд Stvor"
    # A downloaded set goes before the move (space); a local one is the operator's.
    [[ "$src" == "$work"/* ]] && rm -f -- "$src"
    install -d -m 0755 "$TELEPORT_HOME/bin" || die "не создать $TELEPORT_HOME/bin"
    chmod -R go-w -- "$work/teleport/lib"
    chmod 0755 -- "$work/teleport/lib"
    rm -r -f -- "$TELEPORT_LIB.old"
    [[ -d "$TELEPORT_LIB" ]] && { mv -- "$TELEPORT_LIB" "$TELEPORT_LIB.old" || die "не убрать прежний $TELEPORT_LIB"; }
    mv -- "$work/teleport/lib" "$TELEPORT_LIB" || die "не положить $TELEPORT_LIB"
    rm -r -f -- "$TELEPORT_LIB.old"
    for b in teleport fdpass-teleport; do
        chmod 0755 -- "$work/teleport/$b"
        mv -f -- "$work/teleport/$b" "$TELEPORT_HOME/bin/$b" || die "не установить $TELEPORT_HOME/bin/$b"
    done
    [[ "$(version_of_agent)" == "$version" ]] || die "teleport version не совпал с $version"
    log "установлен $(env -u LD_PRELOAD "$TELEPORT_BIN" version | head -1)"
}

# hook-install | hook-upgrade: the set by the scope: install keys, the layout, the
# marker, the link, the service enabled (its instances follow the state files).
# Never registers and never starts the agent; a new set on a running machine —
# restart; an upgrade without one — render and restart.
hook_install(){
    local mode="$1" version="${TELEPORT_VERSION:-$TELEPORT_DEFAULT_VERSION}" sha="${TELEPORT_SHA256:-}"
    local mirror="${TELEPORT_MIRROR:-}" tarball="${TELEPORT_TARBALL:-}" machine arch prev changed=0
    local dist="${TELEPORT_DIST:-}" tag="${TELEPORT_TAG:-}"
    need_root
    [[ "$version" =~ $RE_VERSION ]] || die "TELEPORT_VERSION='$version': ожидали X.Y.Z"
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] \
        || die "TELEPORT_SHA256: нужен sha256 набора openwrt-<arch> (64 hex) — на cdn.teleport.dev такого набора нет"
    check_source "$version" "$sha" "$mirror" "$tarball" "$dist" "$tag"
    [[ -n "$dist" || -n "$mirror" || -n "$tarball" ]] \
        || die "нужен TELEPORT_DIST (раздача портала Stvor), TELEPORT_MIRROR или TELEPORT_TARBALL — набор openwrt-<arch> есть только там"
    if [[ "${CREAM_PHASE:-live}" == build ]] && joined; then
        die "в $TELEPORT_DATA_GUEST уже есть регистрация — образ стал бы одной нодой на все копии"
    fi
    machine="$(uname -m)" || die "uname -m не ответил"
    arch="$(teleport_arch "$machine")" || die "архитектура $machine не поддерживается (amd64, arm64)"
    foreign_teleport && die "Teleport не от cream: в $TELEPORT_HOME_GUEST есть узел без маркера ${OWNED#"$ROOT"} — снимите его вручную"

    install -d -m 0755 "$ETC" "$APPS_DIR" "$CMD_LABELS_DIR" "$TELEPORT_HOME" || die "не создать каталоги $ETC"
    install -d -m 0700 "$STATE" "$TELEPORT_TMP" "$(dirname "$LOG_FILE")" || die "не создать $STATE"
    # sysupgrade (keep.d) archives files only: the flag comes back in a state
    # directory tar made 0755 — narrowed above, the flag here.
    if [[ -f "$AGENT_ENABLED" && ! -L "$AGENT_ENABLED" ]]; then
        chmod 0600 -- "$AGENT_ENABLED" || die "не выставить права ${AGENT_ENABLED#"$ROOT"}"
    fi
    install -d -m 0750 "$DATA" || die "не создать $DATA"
    : > "$OWNED" || die "не записан маркер $OWNED"

    prev="$(version_of_agent)"
    if binary_current "$version" "$sha" && [[ -x "$FDPASS_BIN" && -d "$TELEPORT_LIB" ]]; then
        log "Teleport $version уже установлен"
        pin_tag_current "$tag" || write_installed_pin "$version" "$sha" "$tag"
    else
        [[ "$prev" == "$version" ]] && pin_change_line "$version" "$sha"
        drop_installed_pin
        fetch_set "$version" "$arch" "$sha" "$mirror" "$tarball" "$dist" "$tag"
        write_installed_pin "$version" "$FETCH_SHA" "$tag"
        changed=1
    fi
    if ! { install -d -m 0755 "$(dirname "$LINK")" && ln -sfn "$TELEPORT_BIN_GUEST" "$LINK"; }; then
        warn "ссылка ${LINK#"$ROOT"} не создана"
    fi
    [[ -x "$INIT_SCRIPT" ]] || die "нет ${INIT_SCRIPT#"$ROOT"} — cream кладёт его из files до хука"
    svc enable || warn "${INIT_SCRIPT#"$ROOT"} enable не прошёл"

    if init_running && agent_active; then
        if (( changed )) && [[ -n "$prev" ]]; then
            restart_agent || warn "агент не подтвердил перезапуск — $AGENT_LOG_HINT"
            log "набор сменился ($prev → $version) — агент перезапущен"
        elif [[ "$mode" == upgrade ]]; then
            load_conf
            if [[ -n "${C[TELEPORT_PROXY]}" ]]; then
                cmd_render
                restart_agent || warn "агент не подтвердил перезапуск — $AGENT_LOG_HINT"
            fi
        fi
    fi
    log "готово: регистрация — printf '%s' '<секрет>' | cream run $TELEPORT_EXT join TELEPORT_PROXY=… TELEPORT_REGISTRATION_SECRET=- TELEPORT_ENV=…"
}

# hook-remove: leave, the service off, the set, the link and the state gone.
# /etc/init.d/teleport and keep.d are files of cream (it removes them).
hook_remove(){
    need_root
    leave_wipe
    if init_running; then svc stop || true; fi
    svc disable || true
    rm -f -- "$RUN_FLAG" "$STARTED"
    [[ -L "$LINK" && "$(readlink -- "$LINK")" == "$TELEPORT_BIN_GUEST" ]] && rm -f -- "$LINK"
    if [[ -e "$OWNED" ]]; then
        rm -r -f -- "$TELEPORT_HOME"
    fi
    rm -r -f -- "$STATE"
    log "удалено: агент выключен, регистрация и набор стёрты"
}

core_main "$@"
