# shellcheck shell=bash
# stvor-agent on OpenWrt: which delivery, where from, how it goes on and off.
# Sourced by the hooks (hooks/install, upgrade, remove, apply); the pure
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
    sa_dir "$SA_HOME" 0750 || sa_die "не создать ${SA_HOME#"$SA_ROOT"}"
    sa_dir "$SA_TELEMETRY_ETC" 0750 || sa_die "не создать ${SA_TELEMETRY_ETC#"$SA_ROOT"}"
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
    local s
    if [[ -x "$SA_BIN" ]]; then
        sa_run "$SA_BIN" disable >/dev/null 2>&1 || sa_log "предупреждение: stvor-agent disable не прошёл — службы и токены снимаются здесь"
    fi
    for s in "${SA_SERVICES[@]}"; do
        if sa_procd_running; then sa_svc "$s" stop || true; fi
        sa_svc "$s" disable || true
        rm -f -- "$SA_INIT_DIR/$s"
    done
    rm -f -- "$SA_BIN"
    rm -r -f -- "$SA_ETC" "$SA_TELEMETRY_ETC" "$SA_HOME" "$SA_RUN_TELEMETRY" "$SA_ROOT/var/run/stvor-agent.lock"
    sa_drop_user
    rm -f -- "$SA_INSTALLED"
    if [[ -e "$SA_LABEL" ]]; then
        rm -f -- "$SA_LABEL"
        sa_reload_label
    fi
    sa_log "stvor-agent снят: службы, бинарь, токены и состояние"
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
