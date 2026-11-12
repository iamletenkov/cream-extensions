#!/usr/bin/env bash
# selkies — the code of the hooks configure, apply and remove (cream/v1).
#
#   selkies.sh configure   CREAM_REASON=boot|install|upgrade|apply
#   selkies.sh apply       after `cream set selkies …` (own apply hook)
#   selkies.sh remove
#
# Runs as root under the domain lock of cream with the non-secret keys in the
# environment; the secrets are only looked at in CREAM_SECRETS_FILE for being
# set, never read into a variable, printed or passed on.
#
# FAIL-CLOSED. Without SELKIES_BASIC_AUTH_PASSWORD and without an explicit
# SELKIES_ALLOW_NO_AUTH=1 the service is not started — and a running instance
# is stopped; a warning, exit 0 (a failing configure at boot helps nobody).
# SELKIES_ALLOW_NO_AUTH=1 without a password starts it with a warning every
# time — but only on the loopback (owner's ruling 2026-11-12): SELKIES_ADDR
# beyond it, SELKIES_PUBLIC on or SELKIES_COMPUTER_USE_BIND beyond it stop the
# instance, remove the declaration and exit 78. The wrapper (run-selkies.sh)
# checks the same once more at its start.
#
# Teleport declaration /etc/cream/teleport/apps.d/selkies.conf (the contract of
# the teleport extension, files/teleport.sh: NAME, URI on the loopback, ICON;
# root's, 0644): written only when the service may run and listens on the
# loopback; atomically through a temporary file in apps.d and rename — never
# through a symlink, and not at all when /etc/cream, /etc/cream/teleport or
# apps.d is one. Harmless without the teleport extension.
#
# systemctl: start/restart/stop only with --no-block (configure runs at boot
# inside a systemd job, apply inside `cream set`). The instance is not enabled:
# configure starts it on every boot after checking the authentication.
#
# EFFECTIVE SETTINGS (Orin 2026-11-12). The domain config holds only the keys
# set explicitly, while cream gives a hook every non-secret key with its
# default. The unit reads $CREAM_STATE_DIR/env before config, so configure and
# apply write there the SELKIES_* of their environment with a non-empty value
# (an empty one means Selkies' own default) — what `cream show selkies`
# reports. Otherwise a default of the manifest such as SELKIES_ENABLE_RESIZE=false
# never reaches Selkies, and Selkies resizes the monitor to the browser window.
# Root's, 0644, no secrets; atomically through a temporary file and rename,
# never through a symlink.
#
# THE USER (7.0.0, spec 2026-11-12-existing-desktop §4.4, ruling Р3): SELKIES_USER,
# or the cloud-init user when it is empty. Only an account of passwd with
# 1000 <= uid < 65534 (the rule of cloud-user/get_cloud_user.sh): root, gdm,
# lightdm, sddm and other system accounts are refused — for gdm the second
# authority candidate is the greeter's, and the login screen would be
# streamed. A refused SELKIES_USER — the instances stop, the declaration goes,
# exit 78 (a setting to fix, as the loopback rule).
#
# THE MACHINE (ruling Р2), on a live machine only — at image build the desktop
# may come with the same build: no Xorg (/usr/lib/xorg/Xorg, /usr/bin/Xorg) or
# no enabled display manager (the display-manager.service link to a unit that
# is there) — the instances stop, the declaration goes, exit 1 with "put a
# desktop or existing-desktop". Enabled but not running yet — a warning and 0
# (R11).
#
# THE DIAGNOSIS: one line on who is on seat0 (xs_seat0_active of
# lib/x-session.sh — files/x-session.sh): "на seat0 сеанс bob (x11), Selkies
# ждёт alice", the greeter, no session.
#
# Never writes into a home directory: that is the wrapper's, as the user.
set -euo pipefail

R="${CREAM_ROOT:-}"; R="${R%/}"
SECRETS="${CREAM_SECRETS_FILE:-$R/etc/cream/selkies/secrets}"
STATE="${CREAM_STATE_DIR:-$R/var/lib/cream/ext/selkies}"
EFFECTIVE="$STATE/env"
RE_SECRET_KEY='^SELKIES_(BASIC_AUTH_PASSWORD|BASIC_AUTH_VIEWONLY_PASSWORD|MASTER_TOKEN)$'
# The union of the value types of the manifest: no quote, space, $, backquote
# or backslash — a plain KEY=VALUE line of an EnvironmentFile.
RE_ENV_VALUE='^[A-Za-z0-9_.,:/@%+=-]+$'
CLOUD_USER_LIB="$R/opt/cream/ext/cloud-user/get_cloud_user.sh"
TP_DIR="$R/etc/cream/teleport"
APPS_DIR="$TP_DIR/apps.d"
DECL="$APPS_DIR/selkies.conf"
OPT="$R/opt/selkies"
USER_WAIT_BOOT=60
RE_USER='^[a-z_][a-z0-9_-]{0,31}$'
RE_ADDR='^[A-Za-z0-9.:-]{1,253}$'
RE_DISPLAY='^(auto|:[0-9]+(\.[0-9]+)?)$'
XS_LIB="${CREAM_EXT_DIR:-$R/opt/cream/ext/selkies}/files/x-session.sh"
DM_LINK="$R/etc/systemd/system/display-manager.service"
NO_DESKTOP='нет X-сервера / менеджера входа: поставьте стол или `existing-desktop`'

log(){ >&2 echo "selkies: $*"; }
warn(){ >&2 echo "selkies: ВНИМАНИЕ: $*"; }
die(){ >&2 echo "selkies: ОШИБКА: $*"; exit 1; }

# The values reach a declaration and a unit environment: check their form here
# too, not only in cream (an older config file, a hand edit).
check_values(){
    [[ "${SELKIES_ADDR:=127.0.0.1}" =~ $RE_ADDR ]] || die "SELKIES_ADDR: недопустимое значение"
    [[ "${SELKIES_PORT:=8080}" =~ ^[0-9]{1,5}$ ]] && (( SELKIES_PORT >= 1 && SELKIES_PORT <= 65535 )) \
        || die "SELKIES_PORT: недопустимое значение"
    case "${SELKIES_ENABLE_HTTPS:=false}" in true|false) ;; *) die "SELKIES_ENABLE_HTTPS: true или false" ;; esac
    case "${SELKIES_ALLOW_NO_AUTH:=0}" in 0|1) ;; *) die "SELKIES_ALLOW_NO_AUTH: 0 или 1" ;; esac
    [[ -z "${SELKIES_DISPLAY:-}" || "$SELKIES_DISPLAY" =~ $RE_DISPLAY ]] \
        || die "SELKIES_DISPLAY: auto или :N"
}

# dm_enabled: 0 — display-manager.service is a link to a unit file that is
# there; masked (a link to /dev/null) or dangling — not enabled.
dm_enabled(){
    local t
    [[ -L "$DM_LINK" ]] || return 1
    t="$(readlink "$DM_LINK")" || return 1
    [[ "$t" != /dev/null ]] || return 1
    if [[ "$t" == /* ]]; then t="$R$t"; else t="${DM_LINK%/*}/$t"; fi
    [[ -f "$t" ]]
}

# machine_ok: prints what is missing; 0 — Xorg and an enabled display manager
# are on the machine (files, not their state).
machine_ok(){
    local missing=()
    [[ -e "$R/usr/lib/xorg/Xorg" || -e "$R/usr/bin/Xorg" ]] || missing+=("X-сервера (Xorg)")
    dm_enabled || missing+=("включённого менеджера входа (display-manager.service)")
    (( ${#missing[@]} == 0 )) && return 0
    echo "${missing[*]}"
    return 1
}

# user_ok <user>: prints why not; 0 — a name of passwd with 1000 <= uid < 65534.
user_ok(){
    local uid
    if [[ ! "$1" =~ $RE_USER ]]; then echo "имя не подходит для юнита"; return 1; fi
    if ! uid="$(id -u "$1" 2>/dev/null)" || [[ ! "$uid" =~ ^[0-9]+$ ]]; then
        echo "нет в passwd"; return 1
    fi
    if (( uid < 1000 || uid >= 65534 )); then
        echo "uid $uid вне 1000..65533 — системная учётка (root, менеджер входа), её экран не транслирую"
        return 1
    fi
}

# diagnose <user>: one line on who is on seat0 (logind).
diagnose(){
    local want="$1" a name type class
    [[ -f "$XS_LIB" ]] || return 0
    # shellcheck source=../../../../lib/x-session.sh
    source "$XS_LIB"
    if ! a="$(xs_seat0_active)"; then
        log "на seat0 нет активного сеанса (или нет logind) — Selkies ждёт сеанс $want"
        return 0
    fi
    read -r name type class <<< "$a"
    if [[ "$class" != user ]]; then
        log "на seat0 экран входа ($class) — Selkies ждёт входа $want (или DESKTOP_AUTOLOGIN=1 расширения desktop)"
    elif [[ "$name" == "$want" ]]; then
        log "на seat0 сеанс $name ($type) — Selkies подключится к нему"
        [[ "$type" != wayland ]] \
            || warn "сеанс $name — Wayland: Selkies видит только X.Org (gdm-xorg — Xorg у GDM), обёртка выйдет с 78"
    else
        log "на seat0 сеанс $name ($type), Selkies ждёт $want: sudo cream set selkies SELKIES_USER=$name"
    fi
}

# refuse <rc>: stop every instance and take the declaration away, then exit rc.
refuse(){
    decl_remove
    stop_instances
    exit "$1"
}

# secret_set <key>: 0 — the key has a non-empty value in the secrets file.
# Matches the line only; the value never leaves grep.
secret_set(){
    [[ -f "$SECRETS" && ! -L "$SECRETS" ]] || return 1
    grep -qE "^[[:space:]]*$1=([^\"'[:space:]]|\"[^\"]|'[^'])" "$SECRETS" 2>/dev/null
}

RE_LOOPBACK='^(127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|::1|\[::1\]|localhost)$'
loopback_host(){ [[ "$1" =~ $RE_LOOPBACK ]]; }
is_loopback(){ loopback_host "$SELKIES_ADDR"; }

# The listeners of Selkies 2.0.0 and pixelflux 2.1.0 (their sources, checked
# 2026-11-12): the aiohttp server on SELKIES_ADDR (SELKIES_PUBLIC turns it into
# 0.0.0.0,::) — /api/metrics is a route of it, websockets mode opens no other
# port; WebRTC (SELKIES_MODE=webrtc, or switched to from the UI with
# SELKIES_ENABLE_DUAL_MODE) binds its ICE sockets — UDP, the mux ports, mDNS —
# on every host address, no setting confines them to the loopback; pixelflux's
# Computer-Use HTTP server (input injection, no authentication of its own) on
# SELKIES_COMPUTER_USE_BIND — a bare port is the loopback, host:port the host;
# owner's ruling 2026-11-12: off by default, only explicitly and only with a
# password of Selkies (beyond the loopback — refused even then).

# bool_on <value>: 0 — on, the way Selkies reads a bool (settings.parse_bool:
# the part before "|", trimmed, lowercase, is true or 1); yes/on are off for it.
# Empty DUAL_MODE is off: the wrapper exports its default false (the manifest's).
bool_on(){
    local v="${1%%|*}"
    v="${v//[[:space:]]/}"
    [[ "${v,,}" == true || "$v" == 1 ]]
}
bool_off(){ ! bool_on "$1"; }

# cu_enabled: 0 — SELKIES_COMPUTER_USE_BIND names something (Selkies starts the
# Computer-Use server for any non-empty value). Off by default: not a key of the
# manifest, Selkies' default is empty; PIXELFLUX_CU the wrapper never passes on.
cu_enabled(){ local v="${SELKIES_COMPUTER_USE_BIND:-}"; [[ -n "${v//[[:space:],]/}" ]]; }

# cu_beyond_loopback: prints SELKIES_COMPUTER_USE_BIND, 0 — an entry is beyond
# the loopback.
cu_beyond_loopback(){
    local e entries=()
    IFS=, read -ra entries <<< "${SELKIES_COMPUTER_USE_BIND:-}"
    for e in "${entries[@]}"; do
        e="${e//[[:space:]]/}"
        [[ -z "$e"|| "$e" =~ ^[0-9]+$ ]] && continue
        loopback_host "${e%:*}" || { echo "SELKIES_COMPUTER_USE_BIND=$SELKIES_COMPUTER_USE_BIND"; return 0; }
    done
    return 1
}

# beyond_loopback: prints what listens beyond the loopback, 0 — something does.
beyond_loopback(){
    if ! is_loopback; then echo "SELKIES_ADDR=$SELKIES_ADDR"; return 0; fi
    bool_off "${SELKIES_PUBLIC:-}" || { echo "SELKIES_PUBLIC=$SELKIES_PUBLIC"; return 0; }
    case "${SELKIES_MODE:-}" in
        ''|websockets) ;;
        *) echo "SELKIES_MODE=$SELKIES_MODE (сокеты ICE WebRTC на всех адресах)"; return 0 ;;
    esac
    bool_off "${SELKIES_ENABLE_DUAL_MODE:-}" \
        || { echo "SELKIES_ENABLE_DUAL_MODE=$SELKIES_ENABLE_DUAL_MODE (переход на WebRTC, сокеты ICE на всех адресах)"; return 0; }
    return 1
}

# auth_ok: 0 — the service may run; 1 — no authentication (stopped, exit 0);
# 2 — no password beyond the loopback (stopped, exit 78). Warnings to stderr.
auth_ok(){
    local what
    # The Computer-Use server is without a password whatever Selkies' is.
    if what="$(cu_beyond_loopback)"; then
        warn "сервер Computer-Use pixelflux (ввод без аутентификации) допустим только на петле, а $what слушает сеть — Selkies остановлен"
        warn "  оставьте в SELKIES_COMPUTER_USE_BIND голый порт (это петля) или уберите ключ из /etc/cream/selkies/config"
        return 2
    fi
    if secret_set SELKIES_BASIC_AUTH_PASSWORD; then
        if [[ "$SELKIES_ENABLE_HTTPS" != true ]]; then
            # SELKIES_PUBLIC with a password: all interfaces — the wrapper drops
            # SELKIES_ADDR of the env file (Selkies refuses --public with --addr).
            if ! bool_off "${SELKIES_PUBLIC:-}"; then
                warn "SELKIES_PUBLIC=$SELKIES_PUBLIC без SELKIES_ENABLE_HTTPS=true — пароль basic auth пойдёт по сети открытым текстом"
            elif ! is_loopback; then
                warn "SELKIES_ADDR=$SELKIES_ADDR без SELKIES_ENABLE_HTTPS=true — пароль basic auth пойдёт по сети открытым текстом"
            fi
        fi
        return 0
    fi
    if [[ "$SELKIES_ALLOW_NO_AUTH" == 1 ]]; then
        # Owner's ruling 2026-11-12: Computer-Use only with a password, on any
        # address; without a password only on the loopback.
        if cu_enabled; then
            warn "SELKIES_COMPUTER_USE_BIND=$SELKIES_COMPUTER_USE_BIND: сервер Computer-Use pixelflux (ввод без аутентификации) включается только с паролем Selkies; без пароля Selkies допустим только на петле и без него — Selkies остановлен"
            warn "  задайте пароль: echo <пароль> | sudo cream set selkies SELKIES_BASIC_AUTH_PASSWORD=- или уберите ключ из /etc/cream/selkies/config"
            return 2
        fi
        if what="$(beyond_loopback)"; then
            warn "SELKIES_ALLOW_NO_AUTH=1 допустим только на петле (127.0.0.1, ::1, localhost), а $what слушает сеть — Selkies остановлен"
            warn "  задайте пароль: echo <пароль> | sudo cream set selkies SELKIES_BASIC_AUTH_PASSWORD=-"
            warn "  или верните петлю: sudo cream set selkies SELKIES_ADDR=127.0.0.1"
            return 2
        fi
        warn "БЕЗ АУТЕНТИФИКАЦИИ (SELKIES_ALLOW_NO_AUTH=1): рабочий стол, буфер обмена и файлы — любому, кто достаёт до ${SELKIES_ADDR}:${SELKIES_PORT}"
        return 0
    fi
    if secret_set SELKIES_BASIC_AUTH_VIEWONLY_PASSWORD; then
        warn "задан только пароль просмотра — это не аутентификация"
    fi
    warn "нет SELKIES_BASIC_AUTH_PASSWORD — Selkies без аутентификации не запускается"
    warn "  пароль: echo <пароль> | sudo cream set selkies SELKIES_BASIC_AUTH_PASSWORD=-"
    warn "  или осознанно без пароля: sudo cream set selkies SELKIES_ALLOW_NO_AUTH=1"
    return 1
}

# ---------------------------------------------------------------------------
# The effective settings for the unit
# ---------------------------------------------------------------------------
# effective_content: KEY=VALUE lines of the effective non-secret settings, sorted.
effective_content(){
    local k v
    while IFS= read -r k; do
        [[ "$k" =~ ^SELKIES_[A-Z0-9_]+$ && ! "$k" =~ $RE_SECRET_KEY ]] || continue
        v="${!k}"
        [[ -n "$v" ]] || continue
        # Commas only: no address, Computer-Use is off — the key is not written.
        [[ "$k" != SELKIES_COMPUTER_USE_BIND ]] || cu_enabled || continue
        if [[ ! "$v" =~ $RE_ENV_VALUE ]]; then
            warn "$k: значение не годится для EnvironmentFile — Selkies его не получит"
            continue
        fi
        printf '%s=%s\n' "$k" "$v"
    done < <(compgen -e | LC_ALL=C sort)
}

effective_write(){
    local content tmp
    content="$(effective_content)"
    if [[ -L "$STATE" ]]; then
        warn "${STATE#"$R"} — символическая ссылка, действующие значения не пишу"
        return 0
    fi
    # cream runs hooks with umask 022: the directory is 0755.
    [[ -d "$STATE" ]] || mkdir -p -- "$STATE" || { warn "не создать ${STATE#"$R"}"; return 0; }
    if [[ -f "$EFFECTIVE" && ! -L "$EFFECTIVE" ]] && [[ "$(cat -- "$EFFECTIVE")" == "$content" ]]; then
        return 0
    fi
    # mktemp: O_EXCL, 0600, never follows; rename replaces a symlink, not its target.
    tmp="$(mktemp "$STATE/.env.XXXXXX")" || { warn "не создать временный файл в ${STATE#"$R"}"; return 0; }
    { [[ -z "$content" ]] || printf '%s\n' "$content"; } > "$tmp" && chmod 0644 "$tmp" \
        && mv -f -T -- "$tmp" "$EFFECTIVE" \
        || { rm -f -- "$tmp"; warn "действующие значения не записаны"; return 0; }
    log "действующие значения для юнита: ${EFFECTIVE#"$R"}"
}

effective_remove(){
    [[ -L "$STATE" ]] && return 0
    rm -f -- "$EFFECTIVE"
}

# ---------------------------------------------------------------------------
# The Teleport declaration
# ---------------------------------------------------------------------------
decl_uri(){
    local scheme=http
    [[ "$SELKIES_ENABLE_HTTPS" == true ]] && scheme=https
    case "$SELKIES_ADDR" in
        127.0.0.1|localhost|0.0.0.0) echo "$scheme://127.0.0.1:$SELKIES_PORT" ;;
        ::1) echo "$scheme://[::1]:$SELKIES_PORT" ;;
        *) return 1 ;;
    esac
}

# no_symlink_chain: 0 — none of /etc/cream, /etc/cream/teleport, apps.d is a symlink.
no_symlink_chain(){
    local d
    for d in "$R/etc" "$R/etc/cream" "$TP_DIR" "$APPS_DIR"; do
        if [[ -L "$d" ]]; then warn "${d#"$R"} — символическая ссылка, объявление для Teleport не трогаю"; return 1; fi
    done
}

decl_remove(){
    no_symlink_chain || return 0
    if [[ -e "$DECL" || -L "$DECL" ]]; then
        rm -f -- "$DECL"
        log "объявление для Teleport снято: apps.d/selkies.conf"
    fi
}

decl_write(){
    local uri content tmp d
    uri="$(decl_uri)" || { decl_remove; return 0; }
    no_symlink_chain || return 0
    content="$(printf 'NAME=selkies\nURI=%s\nICON=desktop' "$uri")"
    if [[ -f "$DECL" && ! -L "$DECL" ]] && [[ "$(cat -- "$DECL")" == "$content" ]]; then
        return 0
    fi
    for d in "$R/etc/cream" "$TP_DIR" "$APPS_DIR"; do
        [[ -d "$d" ]] || mkdir -m 0755 -- "$d" || { warn "не создать ${d#"$R"}"; return 0; }
    done
    # mktemp: O_EXCL, 0600, never follows; rename replaces a symlink, not its target.
    tmp="$(mktemp "$APPS_DIR/.selkies.XXXXXX")" || { warn "не создать временный файл в apps.d"; return 0; }
    printf '%s\n' "$content" > "$tmp" && chmod 0644 "$tmp" && mv -f -T -- "$tmp" "$DECL" \
        || { rm -f -- "$tmp"; warn "объявление для Teleport не записано"; return 0; }
    log "объявлен для Teleport: apps.d/selkies.conf ($uri)"
}

# ---------------------------------------------------------------------------
# The instances
# ---------------------------------------------------------------------------
instances(){
    systemctl list-units --all --plain --no-legend 'selkies@*.service' 2>/dev/null \
        | awk '{print $1}' | grep -E '^selkies@[a-z_][a-z0-9_-]*\.service$' || true
}

# stop_instances [keep]: stop every loaded instance but selkies@<keep>.
stop_instances(){
    local keep="${1:-}" u
    while IFS= read -r u; do
        [[ -n "$u" && "$u" != "selkies@${keep}.service" ]] || continue
        systemctl stop --no-block "$u" || warn "не остановить $u"
        log "$u: останов поставлен в очередь"
    done < <(instances)
}

dm_active(){ systemctl is-active --quiet display-manager.service 2>/dev/null; }

# resolve_user <wait seconds>: the cloud-init user — an account that is not root.
resolve_user(){
    local wait_s="$1" waited=0 user uid why
    while :; do
        user=""
        [[ -x "$CLOUD_USER_LIB" ]] && user="$("$CLOUD_USER_LIB" 2>/dev/null || true)"
        if [[ "$user" =~ $RE_USER ]] && uid="$(id -u "$user" 2>/dev/null)"; then
            if [[ "$uid" == 0 ]]; then warn "пользователь cloud-init — root: Selkies от root не запускается"; return 1; fi
            if ! why="$(user_ok "$user")"; then warn "пользователь cloud-init $user: $why — Selkies не запущен"; return 1; fi
            echo "$user"; return 0
        fi
        (( waited < wait_s )) || break
        sleep 3; waited=$((waited + 3))
    done
    if [[ -n "$user" && ! "$user" =~ $RE_USER ]]; then
        warn "имя пользователя cloud-init не подходит для имени юнита — пропускаю"
    else
        local waited_note=""
        (( wait_s > 0 )) && waited_note=" (ждал ${wait_s} с)"
        warn "нет пользователя cloud-init${waited_note} — Selkies не запущен"
    fi
    return 1
}

# run <boot|now>: the whole decision; boot — start, wait for the user; now — restart.
run(){
    local mode="$1" user wait_s=0 verb=restart rc=0 why
    check_values
    effective_write
    if [[ "${CREAM_PHASE:-live}" == live ]] && ! why="$(machine_ok)"; then
        warn "$NO_DESKTOP"
        warn "  на машине нет: $why — Selkies остановлен"
        refuse 1
    fi
    if [[ -n "${SELKIES_USER:-}" ]] && ! why="$(user_ok "$SELKIES_USER")"; then
        warn "SELKIES_USER=$(printf '%q' "$SELKIES_USER"): $why — Selkies остановлен"
        warn "  нужен пользователь сеанса с uid 1000..65533: sudo cream set selkies SELKIES_USER=<имя>"
        refuse 78
    fi
    auth_ok || rc=$?
    if (( rc != 0 )); then
        decl_remove
        stop_instances
        (( rc == 2 )) && exit 78
        return 0
    fi
    decl_write
    if ! dm_active; then
        warn "менеджер входа не запущен — Selkies не запускаю (стартует на загрузке после него)"
        return 0
    fi
    if [[ "$mode" == boot ]]; then wait_s=$USER_WAIT_BOOT; verb=start; fi
    if [[ -n "${SELKIES_USER:-}" ]]; then
        user="$SELKIES_USER"
    else
        # No usable cloud-init user: an instance started earlier for a
        # SELKIES_USER now unset keeps a valid uid — the wrapper would not stop it.
        if ! user="$(resolve_user "$wait_s")"; then
            stop_instances
            return 0
        fi
    fi
    diagnose "$user"
    # Another user's instance would fight for the same port.
    stop_instances "$user"
    systemctl "$verb" --no-block "selkies@${user}.service" || warn "selkies@${user}: $verb не поставлен в очередь"
    log "selkies@${user}: $verb поставлен в очередь — journalctl -u selkies@${user}"
}

cmd_remove(){
    local u
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        systemctl stop "$u" || warn "не остановить $u"
    done < <(instances)
    decl_remove
    effective_remove
    if [[ -L "$OPT" ]]; then
        warn "${OPT#"$R"} — символическая ссылка, AppImage не удаляю"
    elif [[ -d "$OPT" ]]; then
        rm -f -- "$OPT/current"
        local v
        for v in "$OPT"/*; do
            [[ -d "$v" && ! -L "$v" ]] || continue
            rm -r -f -- "$v"
        done
        rmdir -- "$OPT" 2>/dev/null || true
        log "AppImage удалён из ${OPT#"$R"}"
    fi
}

case "${1:-}" in
    configure)
        case "${CREAM_REASON:-boot}" in
            boot) run boot ;;
            *) run now ;;
        esac ;;
    apply) run now ;;
    remove) cmd_remove ;;
    *) die "использование: selkies.sh configure|apply|remove" ;;
esac
