# shellcheck shell=bash
# stvor-agent on OpenWrt: which delivery, where from, how it goes on and off.
# Sourced by the hooks (hooks/install, upgrade, configure, remove, apply); the pure
# functions are called by tests/test-stvor-agent-openwrt.sh. The agent lives in
# its own repository and ships for OpenWrt as stvor-agent_<version>_linux_<arch>.tar.gz:
# the static binary `stvor-agent` and the procd init scripts
# `init.d/stvor-agent` and `init.d/stvor-agent-telemetry` (plus the manual page
# and the licenses, not installed here: OpenWrt has no man).
# https://github.com/iamletenkov/stvor-agent
#
# Keys of the domain (cream passes them as environment) — those of
# debian/stvor-agent, the contract with the install script of Stvor:
#   STVOR_AGENT_VERSION + STVOR_AGENT_SHA256  explicit version and sha256 of
#       the tar.gz of this machine's architecture; both or neither — neither
#       means the catalog pin files/pin.env
#   STVOR_AGENT_MIRROR   base URL, the file lies flat: <base>/<tar.gz name>
#   STVOR_AGENT_TARBALL  absolute path of a local tar.gz (offline)
#   default source — the GitHub release of the version
# The labels token is never an input here: `stvor-agent enable` takes it on
# stdin. Children (curl, tar, stvor-agent) get a minimal environment of their
# own, so nothing the caller had in its environment reaches them; the nested
# cream (reload-apps of teleport-openwrt) keeps the environment cream gave the
# hook (its lock and phase).
#
# Layout (the agent picks the OpenWrt paths by /etc/os-release itself):
#   /usr/bin/stvor-agent, /etc/init.d/stvor-agent{,-telemetry} — from the tar.gz
#   /opt/stvor-agent         state.json, machine-id, telemetry/ (0750 root:stvor-telemetry;
#                            /var is tmpfs on OpenWrt)
#   /etc/stvor-agent-telemetry  the telemetry token directory (0750 root:stvor-telemetry)
#   user and group stvor-telemetry — the telemetry service runs as it
# No test switches in the environment: the tests substitute commands through
# PATH and the root through CREAM_ROOT — "procd runs" is the ubus socket
# $CREAM_ROOT/var/run/ubus/ubus.sock.

SA_RELEASES=https://github.com/iamletenkov/stvor-agent/releases/download
RE_SA_VERSION='^[0-9]+\.[0-9]+\.[0-9]+$'
RE_SA_SHA256='^[0-9a-f]{64}$'
RE_SA_URL='^https?://[A-Za-z0-9._~:/%+-]+$'
SA_SERVICES=(stvor-agent stvor-agent-telemetry)
SA_USER=stvor-telemetry

SA_ROOT="${CREAM_ROOT:-}"
SA_ROOT="${SA_ROOT%/}"
SA_BIN="$SA_ROOT/usr/bin/stvor-agent"
SA_INIT_DIR="$SA_ROOT/etc/init.d"
SA_HOME="$SA_ROOT/opt/stvor-agent"
SA_ETC="$SA_ROOT/etc/stvor-agent"
SA_TELEMETRY_ETC="$SA_ROOT/etc/stvor-agent-telemetry"
SA_RUN_TELEMETRY="$SA_ROOT/var/run/stvor-agent-telemetry"
SA_STATE="${CREAM_STATE_DIR:-$SA_ROOT/opt/cream/var/ext/stvor-agent-openwrt}"
# "version sha256" of the tar.gz in place; the marker of the user this extension made.
SA_INSTALLED="$SA_STATE/installed"
SA_USER_MARK="$SA_STATE/user-created"
# The drop-in of the label stvor_agent (files of the manifest): cream lays it
# before install and removes it after remove.
SA_LABEL="$SA_ROOT/etc/cream/teleport-openwrt/command-labels.d/stvor_agent"

sa_log(){ >&2 echo "stvor-agent: $*"; }
sa_die(){ >&2 echo "stvor-agent: ОШИБКА: $*"; exit 1; }

sa_tarball_name(){ echo "stvor-agent_$1_linux_$2.tar.gz"; }
# sa_url <version> <arch> <mirror>
sa_url(){
    if [[ -n "$3" ]]; then
        echo "${3%/}/$(sa_tarball_name "$1" "$2")"
    else
        echo "$SA_RELEASES/v$1/$(sa_tarball_name "$1" "$2")"
    fi
}
# sa_pin_get <file> <KEY>: the value of KEY= (data, not sourced).
sa_pin_get(){
    local line
    line="$(grep -E "^$2=" "$1" | tail -n1)" || true
    printf '%s' "${line#*=}"
}
# sa_run <command…>: a child with a minimal environment of its own.
sa_run(){ env -i "PATH=$PATH" LANG=C.UTF-8 "$@"; }
# sa_arch: uname -m as the architecture of the release.
sa_arch(){
    local m
    m="$(sa_run uname -m)" || return 1
    case "$m" in
        x86_64|amd64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        *) sa_log "ОШИБКА: архитектура $m не поддерживается (amd64, arm64)"; return 1 ;;
    esac
}
sa_procd_running(){ [[ -e "$SA_ROOT/var/run/ubus/ubus.sock" ]]; }
# sa_svc <service> <verb>: the init script; rc.common takes /var/lock/procd_<svc>.lock,
# and an image build (or a container) has no /var/lock yet.
sa_svc(){
    [[ -d "$SA_ROOT/var/lock" ]] || mkdir -p -- "$SA_ROOT/var/lock" 2>/dev/null
    [[ -x "$SA_INIT_DIR/$1" ]] || return 1
    sa_run "$SA_INIT_DIR/$1" "$2" >/dev/null 2>&1
}

# sa_select <arch>: sets SA_VERSION and SA_SHA256 — the explicit pair or the
# catalog pin. Exits on a half pair or an incomplete pin, before any network.
sa_select(){
    local arch="$1" v="${STVOR_AGENT_VERSION:-}" s="${STVOR_AGENT_SHA256:-}" pin key
    if [[ -n "$v" && -z "$s" ]]; then
        sa_die "STVOR_AGENT_VERSION=$v задан без STVOR_AGENT_SHA256 — задайте обе или ни одной (тогда пин каталога)"
    elif [[ -z "$v" && -n "$s" ]]; then
        sa_die "STVOR_AGENT_SHA256 задан без STVOR_AGENT_VERSION — задайте обе или ни одной (тогда пин каталога)"
    elif [[ -z "$v" ]]; then
        pin="$CREAM_EXT_DIR/files/pin.env"
        [[ -f "$pin" ]] || sa_die "нет пина каталога $pin — задайте STVOR_AGENT_VERSION и STVOR_AGENT_SHA256"
        key="STVOR_AGENT_PIN_SHA256_${arch^^}"
        v="$(sa_pin_get "$pin" STVOR_AGENT_PIN_VERSION)"
        s="$(sa_pin_get "$pin" "$key")"
        [[ -n "$v" && -n "$s" ]] \
            || sa_die "пин каталога неполон (STVOR_AGENT_PIN_VERSION, $key) — задайте STVOR_AGENT_VERSION и STVOR_AGENT_SHA256"
        sa_log "пин каталога: $v"
    fi
    [[ "$v" =~ $RE_SA_VERSION ]] || sa_die "версия агента '$v': ожидали X.Y.Z"
    [[ "$s" =~ $RE_SA_SHA256 ]] || sa_die "sha256 tar.gz агента: ожидали 64 hex"
    SA_VERSION="$v"
    SA_SHA256="$s"
}

# sa_check_source: STVOR_AGENT_MIRROR and STVOR_AGENT_TARBALL, before any network.
sa_check_source(){
    local mirror="${STVOR_AGENT_MIRROR:-}" tarball="${STVOR_AGENT_TARBALL:-}"
    if [[ -n "$mirror" && -n "$tarball" ]]; then
        sa_die "STVOR_AGENT_MIRROR и STVOR_AGENT_TARBALL взаимоисключающие — задайте один"
    fi
    [[ -z "$mirror" || "$mirror" =~ $RE_SA_URL ]] || sa_die "STVOR_AGENT_MIRROR='$mirror': ожидали http(s) URL"
    if [[ -n "$tarball" ]]; then
        [[ "$tarball" == /* ]] || sa_die "STVOR_AGENT_TARBALL=$tarball: нужен абсолютный путь"
        [[ -f "$tarball" ]] || sa_die "STVOR_AGENT_TARBALL=$tarball: файла нет"
    fi
    return 0
}

# sa_fetch <work dir> <arch>: the checked tar.gz, its path on stdout.
sa_fetch(){
    local work="$1" arch="$2" file url
    file="$work/$(sa_tarball_name "$SA_VERSION" "$arch")"
    if [[ -n "${STVOR_AGENT_TARBALL:-}" ]]; then
        cp -- "$STVOR_AGENT_TARBALL" "$file" || return 1
    else
        command -v curl >/dev/null 2>&1 || { sa_log "ОШИБКА: нет curl — поставьте его (apk add curl) или задайте STVOR_AGENT_TARBALL"; return 1; }
        url="$(sa_url "$SA_VERSION" "$arch" "${STVOR_AGENT_MIRROR:-}")"
        sa_log "скачиваю $url"
        # Stalls become retries instead of an endless wait.
        sa_run curl -fL --retry 5 --retry-delay 5 \
            --connect-timeout 30 --speed-limit 10240 --speed-time 60 \
            -o "$file" "$url" || { sa_log "ОШИБКА: tar.gz агента не скачался"; return 1; }
    fi
    if [[ "$(sha256sum < "$file" | cut -c1-64)" != "$SA_SHA256" ]]; then
        sa_log "ОШИБКА: sha256 tar.gz не совпал (ждали $SA_SHA256)"
        return 1
    fi
    echo "$file"
}

# sa_unpack <tar.gz> <dir>: the members this extension installs, each a regular
# file (not a link) — a release without them is refused before anything changes.
sa_unpack(){
    local m
    sa_run tar -xzf "$1" -C "$2" || { sa_log "ОШИБКА: tar.gz агента не распаковался"; return 1; }
    for m in stvor-agent "${SA_SERVICES[@]/#/init.d/}"; do
        if [[ ! -f "$2/$m" || -L "$2/$m" ]]; then
            sa_log "ОШИБКА: в tar.gz нет файла $m — нужен выпуск stvor-agent с поставкой для OpenWrt"
            return 1
        fi
    done
}

# sa_put <src> <dst>: 0755 by a rename on the destination file system — a running
# binary or script is never written in place.
sa_put(){
    local tmp="$2.cream-new.$$"
    mkdir -p -- "$(dirname "$2")" || return 1
    cp -- "$1" "$tmp" && chmod 0755 -- "$tmp" && mv -f -- "$tmp" "$2" || { rm -f -- "$tmp"; return 1; }
}

# sa_functions <shell code>: the code with the helpers of OpenWrt's
# /lib/functions.sh (group_add_next, user_add, …) in its own sh — the file is
# busybox sh, not bash. IPKG_INSTROOT is the root (cream sets it to / in the
# build phase; empty — the helpers take /var/lock/passwd).
sa_functions(){
    local inst="${IPKG_INSTROOT:-}"
    [[ -n "$SA_ROOT" ]] && inst="$SA_ROOT"
    [[ -f "$SA_ROOT/lib/functions.sh" ]] || { sa_log "ОШИБКА: нет /lib/functions.sh — это не OpenWrt"; return 1; }
    [[ -n "$inst" ]] || mkdir -p -- /var/lock 2>/dev/null
    env -i "PATH=$PATH" LANG=C.UTF-8 "IPKG_INSTROOT=$inst" SA_USER="$SA_USER" \
        sh -c ". \"\${IPKG_INSTROOT%/}/lib/functions.sh\" || exit 1; $1"
}
sa_user_exists(){ grep -qs "^$SA_USER:" "$SA_ROOT/etc/passwd"; }
sa_group_exists(){ grep -qs "^$SA_USER:" "$SA_ROOT/etc/group"; }

# sa_ensure_user: the system user and group stvor-telemetry (sysusers.d on
# Debian), no login. Both made here — the marker says so, and remove takes them
# away; either found — the marker is not written, nothing of them is removed.
sa_ensure_user(){
    local fresh=1
    sa_user_exists && sa_group_exists && return 0
    if sa_user_exists || sa_group_exists; then fresh=0; fi
    # shellcheck disable=SC2016  # expanded by the inner sh
    sa_functions 'gid="$(group_add_next "$SA_USER")" || exit 1
user_exists "$SA_USER" || user_add "$SA_USER" "" "$gid" "Stvor agent telemetry" /var/run/stvor-agent-telemetry /bin/false' \
        || { sa_log "ОШИБКА: пользователь $SA_USER не создан"; return 1; }
    sa_user_exists && sa_group_exists || { sa_log "ОШИБКА: пользователь $SA_USER не создан"; return 1; }
    if (( fresh )); then mkdir -p -- "$SA_STATE" && : > "$SA_USER_MARK"; fi
    sa_log "создан пользователь $SA_USER"
}
# sa_drop_user: the user and group, only if this extension made them.
sa_drop_user(){
    [[ -e "$SA_USER_MARK" ]] || return 0
    # shellcheck disable=SC2016  # expanded by the inner sh
    sa_functions '[ -n "$IPKG_INSTROOT" ] || lock /var/lock/passwd
sed -i "/^$SA_USER:/d" "${IPKG_INSTROOT%/}/etc/passwd" "${IPKG_INSTROOT%/}/etc/group"
[ ! -f "${IPKG_INSTROOT%/}/etc/shadow" ] || sed -i "/^$SA_USER:/d" "${IPKG_INSTROOT%/}/etc/shadow"
rc=$?
[ -n "$IPKG_INSTROOT" ] || lock -u /var/lock/passwd
exit $rc' || sa_log "предупреждение: пользователь $SA_USER не удалён"
    rm -f -- "$SA_USER_MARK"
}

# sa_dir <dir> <mode>: root:stvor-telemetry with the mode.
sa_dir(){
    mkdir -p -- "$1" && chown "0:$SA_USER" -- "$1" && chmod "$2" -- "$1"
}

# sa_own_state: the owners and modes of the state, every time (install, upgrade,
# configure on every boot). A restore (keep.d of 1.1.0, a backup) brought the
# telemetry tree back as 0:0 0755 and the telemetry service (stvor-telemetry)
# died on permission denied; its init script fixes only the top directory.
#   /opt/stvor-agent             0750 root:stvor-telemetry
#   /opt/stvor-agent/machine-id  0640 root:stvor-telemetry (telemetry hashes it)
#   /opt/stvor-agent/telemetry   0700 stvor-telemetry (the root agent may keep its
#                                token-rejected marker there)
#   …/telemetry/buffer           0700 stvor-telemetry, everything in it the user's
# The tree is the unprivileged user's, so root never walks it to change
# anything: a link (soft or hard) to a root file there would hand that file
# over. A buffer that is not the user's is transient data: the service is
# stopped, the buffer moved into a directory only root can reach and deleted
# unread, an empty one made in its place. Owners and modes change only on the
# directories root has just closed or made.
sa_own_state(){
    local t="$SA_HOME/telemetry" b="$SA_HOME/telemetry/buffer" uid stopped=0
    sa_dir "$SA_HOME" 0750 || return 1
    if [[ -f "$SA_HOME/machine-id" && ! -L "$SA_HOME/machine-id" ]]; then
        chown "0:$SA_USER" -- "$SA_HOME/machine-id" && chmod 0640 -- "$SA_HOME/machine-id" || return 1
    fi
    sa_own_secrets || return 1
    [[ -e "$t" || -L "$t" ]] || return 0
    uid="$(sa_uid)" || { sa_log "ОШИБКА: нет uid пользователя $SA_USER"; return 1; }
    if sa_user_dir "$t" "$uid" && { [[ ! -e "$b" && ! -L "$b" ]] || sa_user_tree "$b" "$uid"; }; then
        return 0
    fi
    sa_log "${t#"$SA_ROOT"}: владелец или права не те — буфер телеметрии пересоздаётся"
    if sa_procd_running && sa_svc stvor-agent-telemetry running; then
        sa_svc stvor-agent-telemetry stop || true
        stopped=1
    fi
    sa_wait_user_gone "$uid" || { sa_log "ОШИБКА: процессы $SA_USER не завершились — права не трогаю"; return 1; }
    sa_reset_telemetry "$t" "$b" || return 1
    if (( stopped )); then
        "$SA_INIT_DIR/stvor-agent-telemetry" start >/dev/null 2>&1 &
        sa_log "служба stvor-agent-telemetry запускается"
    fi
    return 0
}
# sa_own_secrets: the tokens and the root files of the state as the agent writes
# them. sysupgrade (keep.d) archives files only: tar makes their directories
# again 0755 root, and the agent refuses a labels token in a directory wider than
# 0700. Every path lies in a directory only root writes (nothing there is the
# telemetry user's to swap); a link is never followed — the agent refuses it too.
#   /etc/stvor-agent                 0700 root, token 0600 root
#   /etc/stvor-agent-telemetry       0750 root:stvor-telemetry, token 0640 the same
#   /opt/stvor-agent/state.json, telemetry-token.src  0600 root
sa_own_secrets(){
    local f
    if [[ -d "$SA_ETC" && ! -L "$SA_ETC" ]]; then
        chown 0:0 -- "$SA_ETC" && chmod 0700 -- "$SA_ETC" || return 1
        sa_own_file "$SA_ETC/token" 0 0600 || return 1
    fi
    if [[ -d "$SA_TELEMETRY_ETC" && ! -L "$SA_TELEMETRY_ETC" ]]; then
        sa_dir "$SA_TELEMETRY_ETC" 0750 || return 1
        sa_own_file "$SA_TELEMETRY_ETC/token" "$SA_USER" 0640 || return 1
    fi
    for f in state.json telemetry-token.src; do
        sa_own_file "$SA_HOME/$f" 0 0600 || return 1
    done
}
# sa_own_file <file> <group> <mode>: a regular file (not a link) — root:<group>, mode.
sa_own_file(){
    [[ -f "$1" && ! -L "$1" ]] || return 0
    chown "0:$2" -- "$1" && chmod "$3" -- "$1"
}
# sa_uid: the uid of the telemetry user (numeric: find -user takes it everywhere).
sa_uid(){
    local u
    u="$(awk -F: -v n="$SA_USER" '$1 == n { print $3; exit }' "$SA_ROOT/etc/passwd")"
    [[ "$u" =~ ^[0-9]+$ ]] && echo "$u"
}
# sa_user_dir <dir> <uid>: a directory (not a link) of the user, mode 0700.
sa_user_dir(){
    [[ -d "$1" && ! -L "$1" ]] && [[ -n "$(find "$1" -maxdepth 0 -type d -user "$2" -perm 0700 2>/dev/null)" ]]
}
# sa_user_tree <dir> <uid>: the user's directory and nothing in it of another
# owner — a read-only look (find never follows links), nothing is changed.
sa_user_tree(){
    sa_user_dir "$1" "$2" || return 1
    [[ -z "$(find "$1" -xdev ! -user "$2" -print 2>/dev/null | head -n 1)" ]]
}
# sa_wait_user_gone <uid>: no process of the user is left (procd stops the
# service asynchronously, term_timeout 30 s).
sa_wait_user_gone(){
    local i
    for (( i = 0; i < 40; i++ )); do
        sa_user_procs "$1" || return 0
        sleep 1
    done
    return 1
}
sa_user_procs(){
    local f
    for f in "$SA_ROOT"/proc/[0-9]*/status; do
        [[ -r "$f" ]] || continue
        awk -v u="$1" '$1 == "Uid:" && $2 == u { found = 1 } END { exit !found }' "$f" 2>/dev/null && return 0
    done
    return 1
}
# sa_reset_telemetry <telemetry> <buffer>: the user has no process left. The
# telemetry directory is closed to the user (or put aside, if it is not a
# directory), the buffer goes aside and is deleted unread, an empty buffer is
# made, and the directory is handed back last.
sa_reset_telemetry(){
    local t="$1" b="$2" trash
    trash="$(mktemp -d "$SA_HOME/.trash.XXXXXX")" || return 1
    chmod 0700 -- "$trash" || return 1
    if [[ -L "$t" || ! -d "$t" ]]; then
        mv -f -- "$t" "$trash/telemetry" || return 1
        mkdir -m 0700 -- "$t" || return 1
    fi
    chown 0:0 -- "$t" && chmod 0700 -- "$t" || return 1
    if [[ -e "$b" || -L "$b" ]]; then
        mv -f -- "$b" "$trash/buffer" || return 1
    fi
    rm -r -f -- "$trash"
    mkdir -m 0700 -- "$b" && chown "$SA_USER:$SA_USER" -- "$b" && chmod 0700 -- "$b" || return 1
    chown "$SA_USER:$SA_USER" -- "$t" && chmod 0700 -- "$t"
}

# hooks/configure (every boot, stage system — before procd starts the services):
# the owners and modes of the state, no network, no services.
sa_hook_configure(){
    if ! sa_user_exists || ! sa_group_exists; then
        sa_log "пользователя $SA_USER нет — права состояния выставит install"
        return 0
    fi
    sa_own_state || sa_die "не выставить права ${SA_HOME#"$SA_ROOT"}"
}

# sa_reload_label: teleport-openwrt applies command-labels.d only when told
# (no path units on OpenWrt) — on a live machine with procd; reload-apps itself
# does nothing before join and restarts the node only when teleport.yaml changed.
sa_reload_label(){
    [[ "${CREAM_PHASE:-live}" == live ]] && sa_procd_running || return 0
    cream run teleport-openwrt reload-apps || sa_log "предупреждение: cream run teleport-openwrt reload-apps не прошёл — метка stvor_agent применится при старте узла"
}

# sa_restart_running: services that run now restart onto the new binary or
# settings, in the background (never waits for procd, cream convention).
sa_restart_running(){
    local s
    sa_procd_running || { sa_log "procd не запущен — службы подхватят изменения при старте"; return 0; }
    for s in "${SA_SERVICES[@]}"; do
        if sa_svc "$s" running; then
            "$SA_INIT_DIR/$s" restart >/dev/null 2>&1 &
            sa_log "служба $s перезапускается"
        fi
    done
}

# hooks/install, hooks/upgrade: tar.gz → sha256 → the binary and the init
# scripts, the user, the directories, the services enabled (each starts only
# with its token). A new version on a live machine restarts what runs.
sa_hook_install(){
    local arch work file have="" s
    arch="$(sa_arch)" || exit 1
    sa_select "$arch"
    sa_check_source
    [[ -f "$SA_INSTALLED" ]] && have="$(cat -- "$SA_INSTALLED")"
    if [[ "$have" == "$SA_VERSION $SA_SHA256" && -x "$SA_BIN" && -x "$SA_INIT_DIR/stvor-agent" \
        && -x "$SA_INIT_DIR/stvor-agent-telemetry" ]]; then
        sa_log "stvor-agent $SA_VERSION уже установлен"
    else
        work="$(mktemp -d "${TMPDIR:-/tmp}/stvor-agent.XXXXXX")"
        # shellcheck disable=SC2064  # the path is fixed now, on purpose
        trap "rm -r -f -- '$work'" EXIT
        file="$(sa_fetch "$work" "$arch")" || exit 1
        mkdir -p -- "$work/x"
        sa_unpack "$file" "$work/x" || exit 1
        sa_put "$work/x/stvor-agent" "$SA_BIN" || sa_die "не установить ${SA_BIN#"$SA_ROOT"}"
        for s in "${SA_SERVICES[@]}"; do
            sa_put "$work/x/init.d/$s" "$SA_INIT_DIR/$s" || sa_die "не установить /etc/init.d/$s"
        done
        mkdir -p -- "$SA_STATE" && echo "$SA_VERSION $SA_SHA256" > "$SA_INSTALLED"
        sa_log "установлен $(sa_tarball_name "$SA_VERSION" "$arch")${have:+ (было ${have%% *})}"
    fi
    sa_ensure_user || exit 1
    sa_dir "$SA_TELEMETRY_ETC" 0750 || sa_die "не создать ${SA_TELEMETRY_ETC#"$SA_ROOT"}"
    sa_own_state || sa_die "не выставить права ${SA_HOME#"$SA_ROOT"}"
    for s in "${SA_SERVICES[@]}"; do
        sa_svc "$s" enable || sa_log "предупреждение: /etc/init.d/$s enable не прошёл"
    done
    [[ "$have" == "$SA_VERSION $SA_SHA256" ]] || [[ -z "$have" ]] || sa_restart_running
    sa_reload_label
    sa_log "включение: printf '%s' '<токен>' | stvor-agent enable 'URL=https://<портал>/robot-api/v1/labels'"
}

# hooks/remove: the agent forgets its token and stops, then everything this
# extension put goes: services off, the binary, the init scripts, tokens, the
# state, the user it made. The drop-in of the label goes first, so the node
# drops the label now (reload-apps) — cream would remove it only after the hook.
sa_hook_remove(){
    local s uid=""
    if [[ -x "$SA_BIN" ]]; then
        sa_run "$SA_BIN" disable >/dev/null 2>&1 || sa_log "предупреждение: stvor-agent disable не прошёл — службы и токены снимаются здесь"
    fi
    if sa_procd_running; then
        for s in "${SA_SERVICES[@]}"; do sa_svc "$s" stop || true; done
    fi
    # The trees of the telemetry user go only when no process of it is left:
    # busybox rm walks by path, a live process could swap a directory for a link.
    if sa_user_exists; then
        uid="$(sa_uid)" || sa_die "нет uid пользователя $SA_USER — ничего не снято"
        sa_wait_user_gone "$uid" || sa_die "процессы $SA_USER не завершились — ничего не снято, повторите cream remove"
    fi
    for s in "${SA_SERVICES[@]}"; do
        sa_svc "$s" disable || true
        rm -f -- "$SA_INIT_DIR/$s"
    done
    rm -f -- "$SA_BIN"
    sa_trash "$SA_HOME" || sa_die "не снять ${SA_HOME#"$SA_ROOT"}"
    sa_trash "$SA_RUN_TELEMETRY" || sa_die "не снять ${SA_RUN_TELEMETRY#"$SA_ROOT"}"
    rm -r -f -- "$SA_ETC" "$SA_TELEMETRY_ETC" "$SA_ROOT/var/run/stvor-agent.lock"
    sa_drop_user
    rm -f -- "$SA_INSTALLED"
    if [[ -e "$SA_LABEL" ]]; then
        rm -f -- "$SA_LABEL"
        sa_reload_label
    fi
    sa_log "stvor-agent снят: службы, бинарь, токены и состояние"
}

# sa_trash <path>: a tree the telemetry user could write goes first into a
# directory only root reaches (on the same file system — a rename, no copy),
# then is deleted there.
sa_trash(){
    local trash
    [[ -e "$1" || -L "$1" ]] || return 0
    trash="$(mktemp -d "$(dirname -- "$1")/.stvor-agent-trash.XXXXXX")" || return 1
    chmod 0700 -- "$trash" && mv -f -- "$1" "$trash/x" || { rmdir -- "$trash" 2>/dev/null; return 1; }
    rm -r -f -- "$trash"
}

# hooks/apply: the services reread /etc/cream/stvor-agent-openwrt/config on
# restart. Never waits for procd; nothing without it.
sa_hook_apply(){
    if [[ "${CREAM_PHASE:-live}" == build ]]; then
        sa_log "фаза build — настройки подхватят службы при старте"
        return 0
    fi
    sa_restart_running
}

# action status: `stvor-agent status --json` with the wrapper's verdict on
# stdout — {"schema":1,"healthy":…,"problems":[…],"agent":<document or null>}.
# Healthy: the agent is enabled and its service active and, when the document
# has the block `telemetry` (agent >= 4.1.0), the telemetry service active with
# its token ok. 0 — healthy, 1 — not (cream v1 has no check hook: health is the
# action status). The agent's own exit code (1 — not enabled) is not the verdict.
sa_status(){
    local doc="" problems=""
    if [[ ! -x "$SA_BIN" ]]; then
        problems="agent.not_installed"
    else
        doc="$(sa_run "$SA_BIN" status --json 2>/dev/null)" || true
        if [[ "$doc" == "{"*"}" ]]; then
            problems="$(sa_status_problems <<< "$doc")"
        else
            doc=""
            problems="agent.status_failed"
        fi
    fi
    sa_status_json "$problems" "$doc"
    [[ -z "$problems" ]]
}

# sa_status_problems: the document of `status --json` (json.MarshalIndent of
# the agent, two spaces) on stdin → one problem per line. Top-level keys are
# the lines indented by two spaces, the keys of `telemetry` by four.
sa_status_problems(){
    awk '
        function val(l) { sub(/^[^:]*: */, "", l); sub(/,$/, "", l); gsub(/[^A-Za-z0-9_.-]/, "", l); return l == "" ? "unknown" : l }
        /^  "telemetry": \{/ { tel = 1; seen = 1; next }
        tel && /^  \}/ { tel = 0; next }
        !tel && /^  "enabled": / { en = val($0) }
        !tel && /^  "service": / { svc = val($0) }
        tel && /^    "service": / { tsvc = val($0) }
        tel && /^    "token": / { ttok = val($0) }
        END {
            if (en != "true") print "agent.enabled:" (en == "" ? "unknown" : en)
            if (svc != "active") print "agent.service:" (svc == "" ? "unknown" : svc)
            if (seen && tsvc != "active") print "telemetry.service:" (tsvc == "" ? "unknown" : tsvc)
            if (seen && ttok != "ok") print "telemetry.token:" (ttok == "" ? "unknown" : ttok)
        }'
}

# sa_status_json <problems, one per line> <document or empty>.
sa_status_json(){
    local list="" p healthy=true
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        list+="${list:+,}\"$p\""
        healthy=false
    done <<< "$1"
    printf '{"schema":1,"healthy":%s,"problems":[%s],"agent":%s}\n' "$healthy" "$list" "${2:-null}"
}
