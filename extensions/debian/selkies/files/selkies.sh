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
# time. The wrapper (run-selkies.sh) checks the same once more at its start.
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
# Never writes into a home directory: that is the wrapper's, as the user.
set -euo pipefail

R="${CREAM_ROOT:-}"; R="${R%/}"
SECRETS="${CREAM_SECRETS_FILE:-$R/etc/cream/selkies/secrets}"
CLOUD_USER_LIB="$R/opt/cream/ext/cloud-user/get_cloud_user.sh"
TP_DIR="$R/etc/cream/teleport"
APPS_DIR="$TP_DIR/apps.d"
DECL="$APPS_DIR/selkies.conf"
OPT="$R/opt/selkies"
USER_WAIT_BOOT=60
RE_USER='^[a-z_][a-z0-9_-]{0,31}$'
RE_ADDR='^[A-Za-z0-9.:-]{1,253}$'

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
}

# secret_set <key>: 0 — the key has a non-empty value in the secrets file.
# Matches the line only; the value never leaves grep.
secret_set(){
    [[ -f "$SECRETS" && ! -L "$SECRETS" ]] || return 1
    grep -qE "^[[:space:]]*$1=([^\"'[:space:]]|\"[^\"]|'[^'])" "$SECRETS" 2>/dev/null
}

is_loopback(){ case "$SELKIES_ADDR" in 127.*|::1|localhost) return 0 ;; esac; return 1; }

# auth_ok: 0 — the service may run; the warnings of the decision to stderr.
auth_ok(){
    if secret_set SELKIES_BASIC_AUTH_PASSWORD; then
        if ! is_loopback && [[ "$SELKIES_ENABLE_HTTPS" != true ]]; then
            warn "SELKIES_ADDR=$SELKIES_ADDR без SELKIES_ENABLE_HTTPS=true — пароль basic auth пойдёт по сети открытым текстом"
        fi
        return 0
    fi
    if [[ "$SELKIES_ALLOW_NO_AUTH" == 1 ]]; then
        warn "БЕЗ АУТЕНТИФИКАЦИИ (SELKIES_ALLOW_NO_AUTH=1): рабочий стол, буфер обмена и файлы — любому, кто достаёт до ${SELKIES_ADDR}:${SELKIES_PORT}"
        is_loopback || warn "адрес $SELKIES_ADDR — не петля: стол открыт сети"
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
    local wait_s="$1" waited=0 user uid
    while :; do
        user=""
        [[ -x "$CLOUD_USER_LIB" ]] && user="$("$CLOUD_USER_LIB" 2>/dev/null || true)"
        if [[ "$user" =~ $RE_USER ]] && uid="$(id -u "$user" 2>/dev/null)"; then
            if [[ "$uid" == 0 ]]; then warn "пользователь cloud-init — root: Selkies от root не запускается"; return 1; fi
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
    local mode="$1" user wait_s=0 verb=restart
    check_values
    if ! auth_ok; then
        decl_remove
        stop_instances
        return 0
    fi
    decl_write
    if ! dm_active; then
        warn "менеджер входа не запущен — Selkies не запускаю (стартует на загрузке после него)"
        return 0
    fi
    if [[ "$mode" == boot ]]; then wait_s=$USER_WAIT_BOOT; verb=start; fi
    user="$(resolve_user "$wait_s")" || return 0
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
