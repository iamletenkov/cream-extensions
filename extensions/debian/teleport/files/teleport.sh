#!/usr/bin/env bash
# shellcheck disable=SC2034  # the points of the layer are read by the sourced core
# teleport.sh — the systemd layer of the cream extension `teleport` (Debian,
# Ubuntu): hooks and actions are thin entries that exec this file with their
# name. The init-independent part — knobs, render, join, labels, apps.d,
# managed labels, status, the dispatch — is the shared core files/teleport-core.sh
# (one copy in git: lib/teleport-core.sh of the catalog; the snapshot lays it
# here). This file sets the points of the layer (the header of the core lists
# them): paths, systemd units, the journal, the binary from the linux tarball.
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
#   reload-apps                   teleport-apps.service: render, addressed HUP or restart
#   hup                           ExecReload: addressed HUP, reload-pending if unconfirmed
#   status                        what is configured and registered, as text
#   set-managed k=v…              the full set of managed labels (stvor-agent);
#                                 restart only when the config changed; JSON
#   managed-status                managed labels, marker, registration; JSON
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
# Managed labels (spec stvor-agent §10.3): TELEPORT_MANAGED_LABELS, readonly,
# written only by set-managed — the labels of one external manager (the agent
# of the portal: env, space). They win over TELEPORT_LABELS key by key; a
# managed env wins over TELEPORT_ENV. Command labels — files
# /etc/cream/teleport/command-labels.d/<key> of other extensions, one line
# `command=<absolute path> [arg…]`: Teleport runs the command every 5 min and
# publishes its output as the node label <key> (like os_logins).
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

TELEPORT_EXT=teleport
TELEPORT_DATA_GUEST=/var/lib/teleport
TELEPORT_BIN_GUEST=/usr/local/bin/teleport
INIT_NAME=systemd
AGENT_UNIT=teleport.service
AGENT_LOG_HINT="journalctl -u teleport"
AGENT_LOG_FOLLOW="journalctl -u teleport -f"
LOG_OUTPUT=stderr

# shellcheck source=lib/teleport-core.sh
. "$(dirname "${BASH_SOURCE[0]}")/teleport-core.sh" || { echo "teleport: ОШИБКА: нет files/teleport-core.sh" >&2; exit 1; }

# --pid-file of teleport.service; written by every Teleport process after a
# successful start (a HUP forks a child that writes its own).
PID_FILE="$ROOT/run/teleport.pid"
# reload-apps started an apply that did not finish: the next one HUPs even
# when teleport.yaml did not change.
RELOAD_PENDING="$STATE/reload-pending"
# reload-apps: seconds for the child forked on HUP to write its pid file.
RELOAD_TIMEOUT=60
JOIN_SERVICE=teleport-join.service
JOIN_TIMER=teleport-join.timer
PATH_UNITS=(teleport-apps.path teleport-token.path)

# systemd is PID 1 (sd_booted): the marker under the root. A build root (an
# image, a chroot) has an empty /run.
has_systemd(){ [[ -d "$ROOT/run/systemd/system" ]]; }

# ---------------------------------------------------------------------------
# Точки слоя для ядра: init — systemd
# ---------------------------------------------------------------------------
init_running(){ has_systemd; }
agent_start(){ systemctl start teleport.service >/dev/null 2>&1; }
agent_stop(){ systemctl stop teleport.service >/dev/null 2>&1; }
agent_enable(){ systemctl enable teleport.service >/dev/null 2>&1 || true; }
agent_disable(){ systemctl disable teleport.service >/dev/null 2>&1 || true; }
agent_disable_now(){ systemctl disable --now teleport.service >/dev/null 2>&1 || true; }
# The retry: teleport-join.service at every boot and teleport-join.timer every
# minute. `start --no-block`: join may run inside a unit ordered before
# network-online.target, and a waiting start job would deadlock it.
retry_arm(){
    systemctl enable "$JOIN_SERVICE" "$JOIN_TIMER" >/dev/null 2>&1 \
        || warn "$JOIN_TIMER не включён — юнитов повтора нет? cream install teleport --reinstall"
    systemctl start --no-block "$JOIN_TIMER" >/dev/null 2>&1 || true
}
# The service is disabled without --now — the tick that calls this runs inside it.
retry_disarm(){
    systemctl disable "$JOIN_SERVICE" >/dev/null 2>&1 || true
    systemctl disable --now "$JOIN_TIMER" >/dev/null 2>&1 || true
}
retry_status_line(){
    if has_systemd; then
        echo "  повтор: при загрузке и раз в минуту ($JOIN_TIMER: $(systemctl is-active "$JOIN_TIMER" 2>/dev/null))"
    fi
}
service_status_line(){
    if has_systemd; then
        echo "Служба teleport: $(systemctl is-active teleport.service 2>/dev/null), $(systemctl is-enabled teleport.service 2>/dev/null)"
    fi
}
# Debian keeps the ssh_service of Teleport's defaults (PAM off by default).
render_ssh_extra(){ :; }

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

# The journal of teleport.service since an epoch. Into a variable, not a pipe
# into grep -q (see app_role_missing).
agent_log_since(){
    has_systemd || return 0
    journalctl -u teleport.service --since "@$1" --no-pager -o cat 2>/dev/null || true
}

# Restart, not reload: on HUP Teleport keeps the open SSH sessions of people
# of the old labels while the apps already answer by the new ones. One
# restart moves the node and every app together. Success is a restart systemd
# accepted AND a new run of the unit that is active — an agent that stayed
# active through a failed restart still runs the old teleport.yaml. A new run
# is a changed InvocationID, MainPID or ActiveEnterTimestampMonotonic
# (whichever this systemd reports; an empty or zero value is no evidence).
unit_prop(){ systemctl show -p "$1" --value teleport.service 2>/dev/null || true; }
unit_run(){
    local p v out=""
    for p in InvocationID MainPID ActiveEnterTimestampMonotonic; do
        v="$(unit_prop "$p")"
        [[ "$v" == 0 ]] && v=""
        out+="$v|"
    done
    printf '%s' "$out"
}
new_run(){ # new_run <before> <now> — some field present now and changed
    local -a b n
    local i
    IFS='|' read -r -a b <<< "$1"
    IFS='|' read -r -a n <<< "$2"
    for i in 0 1 2; do
        [[ -n "${n[i]:-}" && "${n[i]:-}" != "${b[i]:-}" ]] && return 0
    done
    return 1
}
restart_agent(){
    local waited=0 before now
    before="$(unit_run)"
    systemctl restart teleport.service >/dev/null 2>&1 || return 1
    while :; do
        now="$(unit_run)"
        if new_run "$before" "$now" && agent_active; then
            return 0
        fi
        (( waited < RESTART_TIMEOUT )) || return 1
        sleep 1; waited=$((waited + 1))
    done
}


# reload-apps (teleport-apps.service): the one point where a change of apps.d
# or command-labels.d reaches the agent. lock: exclusive — serialized with
# join, set-managed, apply and itself; nobody holding the lock waits for
# teleport-apps.service, so §7.3 does not bite.
#   1. wait while teleport.service is activating, reloading or deactivating
#      (a restart in progress already read an older file);
#   2. render; a stopped agent only gets the file for its next start; an
#      unchanged teleport.yaml needs no HUP (unless a previous apply did not
#      finish — the marker reload-pending);
#   3. HUP (sessions survive) with the bash builtin kill to the live process of
#      the pid file — the newest Teleport: after a HUP the parent drains open
#      sessions and stays the MainPID for as long as they last, the child that
#      wrote the pid file is the one to signal. No pid file — the MainPID. Only
#      a Teleport process of the system unit is signalled (teleport_proc:
#      exact cgroup, the binary, MainPID or its descendant), checked again
#      right before kill. Confirmed by a new pid file of such a process: the
#      forked child read the new config and started;
#   4. restart (open sessions drop) only when no live Teleport process is in
#      the cgroup at all, or the HUP is not confirmed in RELOAD_TIMEOUT.
unit_state(){ systemctl show -p ActiveState --value teleport.service 2>/dev/null || true; }
settle_agent(){
    local waited=0
    while :; do
        case "$(unit_state)" in
            activating|reloading|deactivating) ;;
            *) return 0 ;;
        esac
        (( waited < RESTART_TIMEOUT )) || return 1
        sleep 1; waited=$((waited + 1))
    done
}
# unit_main: the MainPID of teleport.service (digits, not 0) or 1.
unit_main(){
    local m
    m="$(unit_prop MainPID)"
    [[ "$m" =~ ^[1-9][0-9]{0,9}$ ]] || return 1
    printf '%s\n' "$m"
}
# descends <pid> <main>: pid is main or its descendant within 8 generations
# (PPid of /proc/<pid>/status; a HUP forks one generation per reload).
# Status 2 — the chain ends at PID 1 first: an orphan (its parent exited).
descends(){
    local p="$1" i ppid
    for i in 0 1 2 3 4 5 6 7 8; do
        [[ "$p" == "$2" ]] && return 0
        ppid="$(sed -n 's/^PPid:[[:space:]]*\([0-9][0-9]*\)$/\1/p' "$PROC/$p/status" 2>/dev/null)"
        [[ "$ppid" =~ ^[1-9][0-9]{0,9}$ ]] || return 1
        [[ "$ppid" == 1 ]] && return 2
        p="$ppid"
    done
    return 1
}
# unit_cgroup: the cgroup of the system unit teleport.service as systemd
# reports it (ControlGroup) — the same string /proc/<pid>/cgroup shows for its
# processes: /system.slice/teleport.service on a machine, the full path under
# the scope of a container whose cgroup namespace is the host's (seen live,
# docker --cgroupns=host, 2026-10-19). A user unit of the same name lives under
# user@<uid>.service and never has this path.
unit_cgroup(){
    local cg
    cg="$(unit_prop ControlGroup)"
    [[ "$cg" =~ ^/[A-Za-z0-9._@/-]{1,512}$ && "$cg" == */system.slice/teleport.service ]] || return 1
    printf '%s\n' "$cg"
}
# teleport_proc <pid> <main> <cgroup> [orphan]: 0 — a live Teleport process of
# the system unit: its cgroup line is exactly <cgroup> (v2 `0::…`, or the
# name=systemd line of v1 — a user unit user@…/app.slice/teleport.service is
# not ours), its executable is the binary the unit runs (" (deleted)" after an
# update of the binary still counts), and it is the MainPID or descends from
# it. With [orphan] (only for the process of the pid file) a chain that ends
# at PID 1 counts too: when an intermediate child finished draining before the
# old parent, the newest Teleport is reparented to PID 1 while the parent is
# still the MainPID — the exact cgroup and the binary keep strangers out.
teleport_proc(){
    local pid="$1" main="$2" cg="$3" orphan="${4:-}" exe line ok=1 rc=0
    [[ "$pid" =~ ^[1-9][0-9]{0,9}$ && -d "$PROC/$pid" && -n "$cg" ]] || return 1
    while IFS= read -r line; do
        if [[ "$line" == "0::$cg" ]] || { [[ "$line" == *":name=systemd:$cg" ]] && [[ "${line%%:name=systemd:*}" =~ ^[0-9]+$ ]]; }; then
            ok=0; break
        fi
    done < "$PROC/$pid/cgroup" 2>/dev/null
    (( ok == 0 )) || return 1
    exe="$(readlink -- "$PROC/$pid/exe" 2>/dev/null)" || return 1
    exe="${exe% (deleted)}"
    [[ "$exe" == "$TELEPORT_BIN" ]] || return 1
    descends "$pid" "$main" || rc=$?
    (( rc == 0 )) || [[ "$rc" == 2 && -n "$orphan" ]]
}
# pidfile_pid <main> <cgroup>: the pid of the pid file when it is a Teleport process of the unit.
pidfile_pid(){
    local pid=""
    [[ -f "$PID_FILE" && ! -L "$PID_FILE" ]] && pid="$(head -c 32 -- "$PID_FILE" 2>/dev/null | tr -d '[:space:]')"
    teleport_proc "$pid" "$1" "$2" orphan || return 1
    printf '%s\n' "$pid"
}
# hup_target <main> <cgroup>: the process a HUP must reach — the pid file, else the MainPID.
hup_target(){
    pidfile_pid "$1" "$2" && return 0
    teleport_proc "$1" "$1" "$2" || return 1
    printf '%s\n' "$1"
}
# hup_confirm <wait for a target, s>: the addressed HUP shared by reload-apps
# and ExecReload (`cream run teleport hup`). 0 — confirmed: a new pid file of a
# Teleport process of the unit that is neither the one before nor the target
# (the target writing its own pid file late is not a new run); 1 — no Teleport
# process of the unit to signal; 2 — the signal was not delivered; 3 — not
# confirmed in RELOAD_TIMEOUT.
#
# The window between the check and the signal: teleport_proc runs again right
# before kill, so a pid that died and was reused in between is caught unless
# the reuse falls into those two lines — by a process of the same cgroup, the
# same binary and descending from the MainPID, i.e. Teleport itself. The shells
# of SSH sessions live in the cgroup of the unit too: the binary and the
# descent from the MainPID keep them out. A pidfd would close the window, but
# bash has none; the confirmation by a new pid file stays the proof.
hup_confirm(){
    local wait_s="$1" target before now main="" cg="" waited=0
    until main="$(unit_main)" && cg="$(unit_cgroup)" && target="$(hup_target "$main" "$cg")"; do
        (( waited < wait_s )) || return 1
        sleep 1; waited=$((waited + 1))
    done
    before="$(pidfile_pid "$main" "$cg" || true)"
    # The builtin kill: procps is not in minimal images. target is digits only.
    if ! teleport_proc "$target" "$main" "$cg" orphan || ! kill -HUP "$target" 2>/dev/null; then
        HUP_TARGET="$target"; return 2
    fi
    HUP_TARGET="$target"
    waited=0
    while :; do
        if now="$(pidfile_pid "$main" "$cg")" && [[ "$now" != "$before" && "$now" != "$target" ]] && agent_active; then
            HUP_NEW="$now"; return 0
        fi
        (( waited < RELOAD_TIMEOUT )) || return 3
        sleep 1; waited=$((waited + 1))
    done
}
HUP_TARGET="" HUP_NEW=""
reload_agent(){
    local rc=0
    hup_confirm "$RESTART_TIMEOUT" || rc=$?
    case "$rc" in
        0) log "агент перечитал конфиг (HUP процессу $HUP_TARGET, новый процесс $HUP_NEW)"; return 0 ;;
        1) log "живого процесса Teleport в teleport.service нет — перезапуск" ;;
        2) log "HUP процессу $HUP_TARGET не доставлен — перезапуск" ;;
        *) log "после HUP процессу $HUP_TARGET нового процесса за ${RELOAD_TIMEOUT} с нет — перезапуск" ;;
    esac
    restart_agent
}
# hup (ExecReload of teleport.service, after render; lock: none): the same
# addressed HUP. It runs inside the reload job of the unit, so it never
# restarts it; an unconfirmed HUP leaves the marker reload-pending (state, not
# the domain) and the next reload-apps sends it again even when teleport.yaml
# did not change. Exit 0 either way: the change is recorded, not lost.
cmd_hup(){
    local rc=0
    need_root
    hup_confirm 0 || rc=$?
    if (( rc == 0 )); then
        rm -f -- "$RELOAD_PENDING"
        log "агент перечитал конфиг (HUP процессу $HUP_TARGET, новый процесс $HUP_NEW)"
        return 0
    fi
    : > "$RELOAD_PENDING" 2>/dev/null || true
    case "$rc" in
        1) log "живого процесса Teleport для HUP нет — reload-pending: дошлёт reload-apps" ;;
        2) log "HUP процессу $HUP_TARGET не доставлен — reload-pending: дошлёт reload-apps" ;;
        *) log "HUP процессу $HUP_TARGET не подтвердился за ${RELOAD_TIMEOUT} с — reload-pending: дошлёт reload-apps" ;;
    esac
    return 0
}
yaml_sum(){ [[ -f "$YAML" ]] && sha256sum < "$YAML" | cut -c1-64; }
cmd_reload_apps(){
    local before
    need_root
    load_conf
    [[ -n "${C[TELEPORT_PROXY]}" ]] || return 0
    if ! has_systemd; then cmd_render; return 0; fi
    settle_agent || log "teleport.service не вышел из перехода за ${RESTART_TIMEOUT} с"
    before="$(yaml_sum || true)"
    cmd_render
    if ! agent_active; then
        rm -f -- "$RELOAD_PENDING"
        log "агент не запущен — конфиг применится при старте"
        return 0
    fi
    if [[ "$(yaml_sum || true)" == "$before" && ! -e "$RELOAD_PENDING" ]]; then
        log "teleport.yaml не изменился — HUP не нужен"
        return 0
    fi
    : > "$RELOAD_PENDING" || die "не записано $RELOAD_PENDING"
    reload_agent || die "teleport.service не перечитал конфиг: ни HUP, ни перезапуск не подтвердились"
    rm -f -- "$RELOAD_PENDING"
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

# fetch_teleport <version> <arch> <sha256> <mirror> <tarball> <dist> <tag> — the
# binary in place, checked by sha256 before it is unpacked.
fetch_teleport(){
    local version="$1" work src
    fetch_tarball "${@:1:5}" "$ROOT/var/tmp" "${@:6:2}"
    work="$FETCH_WORK" src="$FETCH_SRC"
    # Only the agent: tsh, tctl, tbot and teleport-update are ~370 MB more and
    # a node needs none of them.
    tar -xzf "$src" -C "$work" teleport/teleport || die "в тарболе нет teleport/teleport"
    install -d -m 0755 "$(dirname "$TELEPORT_BIN")" || die "не создать $(dirname "$TELEPORT_BIN")"
    install -m 0755 "$work/teleport/teleport" "$TELEPORT_BIN" || die "не установить $TELEPORT_BIN"
    [[ "$(version_of_agent)" == "$version" ]] || die "teleport version не совпал с $version"
    log "установлен $(env -u LD_PRELOAD "$TELEPORT_BIN" version | head -1)"
}


# hook-install | hook-upgrade: the binary by the scope: install keys (cream
# puts them into the environment), directories, path units. Never registers
# and never starts the agent. A new binary on a running machine —
# try-restart; an upgrade without one — render and reload.
hook_install(){
    local mode="$1" version="${TELEPORT_VERSION:-$TELEPORT_DEFAULT_VERSION}" sha="${TELEPORT_SHA256:-}"
    local mirror="${TELEPORT_MIRROR:-}" tarball="${TELEPORT_TARBALL:-}" dpkg_arch arch prev changed=0
    local dist="${TELEPORT_DIST:-}" tag="${TELEPORT_TAG:-}"
    need_root
    [[ "$version" =~ $RE_VERSION ]] || die "TELEPORT_VERSION='$version': ожидали X.Y.Z"
    [[ -z "$sha" || "$sha" =~ ^[0-9a-f]{64}$ ]] || die "TELEPORT_SHA256: ожидали 64 hex"
    check_source "$version" "$sha" "$mirror" "$tarball" "$dist" "$tag"
    # In a build a registration would make every copy of the image one node.
    if [[ "${CREAM_PHASE:-live}" == build ]] && joined; then
        die "в /var/lib/teleport уже есть регистрация — образ стал бы одной нодой на все копии"
    fi
    dpkg_arch="$(dpkg --print-architecture)" || die "dpkg --print-architecture не ответил"
    arch="$(teleport_arch "$dpkg_arch")" || die "архитектура $dpkg_arch не поддерживается"

    install -d -m 0755 "$ETC" "$APPS_DIR" "$CMD_LABELS_DIR" || die "не создать каталоги $ETC"
    install -d -m 0700 "$STATE" || die "не создать $STATE"

    prev="$(version_of_agent)"
    if binary_current "$version" "$sha"; then
        log "Teleport $version уже установлен"
        pin_tag_current "$tag" || write_installed_pin "$version" "$sha" "$tag"
    else
        [[ "$prev" == "$version" ]] && pin_change_line "$version" "$sha"
        drop_installed_pin
        fetch_teleport "$version" "$arch" "$sha" "$mirror" "$tarball" "$dist" "$tag"
        write_installed_pin "$version" "$FETCH_SHA" "$tag"
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

core_main "$@"
