#!/usr/bin/env bash
# code-server — the code of the hooks and of the unit (cream/v1).
#
#   code-server.sh install     the .deb of the pinned version by sha256
#   code-server.sh configure   CREAM_REASON=boot|install|upgrade|apply
#   code-server.sh apply       after `cream set code-server …` (own apply hook)
#   code-server.sh remove
#   code-server.sh write-config <home> <bind> <port> <password|none>
#                              AS THE USER (runuser from configure): the
#                              password on stdin, ~/.config/code-server/config.yaml
#   code-server.sh start       ExecStart of code-server@.service, as the user
#
# The hooks run as root under the domain lock of cream with the non-secret keys
# in the environment. The password is read from CREAM_SECRETS_FILE into a shell
# variable that is never exported, printed or put into argv: it leaves only on
# the stdin of the writer run as the user.
#
# FAIL-CLOSED. Without CODE_SERVER_PASSWORD and without an explicit
# CODE_SERVER_ALLOW_NO_AUTH=1 the service is not started — and a running
# instance is stopped, the Teleport declaration taken away; a warning, exit 0
# (a failing configure at boot helps nobody). CODE_SERVER_ALLOW_NO_AUTH=1
# without a password writes `auth: none` with a warning every time; the wrapper
# (start) checks the same once more at every start, so a config edited to
# `auth: none` by hand does not start either. A password that does not fit its
# type is a failure (exit 1), never "no password".
#
# THE HOME DIRECTORY IS THE USER'S. config.yaml is written by this script run
# as the user (runuser, env -i, every descriptor above stderr closed — the lock
# of cream among them —, killed after USER_TIMEOUT), with umask 077, through a
# temporary file and rename in the config directory: never through a symlink,
# and not at all when ~/.config or ~/.config/code-server is one or is not the
# user's. The worst a planted link reaches is what the user could write anyway.
#
# TLS: `cert: true` — code-server issues a self-signed certificate itself
# (openssl, in its data directory). Teleport reaches it on the loopback with
# insecure_skip_verify, as for any loopback https app.
#
# Teleport declaration /etc/cream/teleport/apps.d/code-server.conf (the contract
# of the teleport extension, files/teleport.sh: NAME, URI on the loopback, ICON;
# root's, 0644): written only when the service may run and listens on the
# loopback (or on all addresses); atomically through a temporary file in apps.d
# and rename — never through a symlink, and not at all when /etc/cream,
# /etc/cream/teleport or apps.d is one. Harmless without the teleport extension.
#
# LEFTOVERS OF 4.x (units, enablement links, the mkcert CA — root-owned paths
# only): install, configure and apply refuse with the list — see below.
#
# systemctl in configure and apply: start/restart/stop only with --no-block
# (configure runs at boot inside a systemd job, apply inside `cream set`). The
# instance is not enabled: configure starts it on every boot after the checks.
set -euo pipefail

R="${CREAM_ROOT:-}"; R="${R%/}"
SELF="${BASH_SOURCE[0]}"
SECRETS="${CREAM_SECRETS_FILE:-$R/etc/cream/code-server/secrets}"
CLOUD_USER_LIB="$R/opt/cream/ext/cloud-user/get_cloud_user.sh"
TP_DIR="$R/etc/cream/teleport"
APPS_DIR="$TP_DIR/apps.d"
DECL="$APPS_DIR/code-server.conf"
CS_BIN="$R/usr/bin/code-server"
OPENSSL_BIN="$R/usr/bin/openssl"

# The .deb of the GitHub release; sha256 from the release's asset digests.
CS_VERSION=4.135.0
declare -A DEB_SHA256=(
    [amd64]=f87d0d49c6c0a59d41214c9510f506e4123991f2d27b41f6d56f3f5c96458d3e
    [arm64]=565e77cf74820d1cc3f473a17f41adb0703bbb07dc1243ded66a4740c595fdad
)
RELEASES="https://github.com/coder/code-server/releases/download"

USER_WAIT_BOOT=30
USER_TIMEOUT=30
USER_PATH=/usr/sbin:/usr/bin:/sbin:/bin
RE_USER='^[a-z_][a-z0-9_-]{0,31}$'
RE_ADDR='^[A-Za-z0-9.:-]{1,253}$'
# The type of CODE_SERVER_PASSWORD in extension.yaml, in POSIX bracket syntax
# (`]` first, `-` last; a backslash is no escape in a bracket here).
RE_PASSWORD='^[]A-Za-z0-9!#%&()*+,./:;<=>?@^_{|}~[-]{8,128}$'

log(){ >&2 echo "code-server: $*"; }
warn(){ >&2 echo "code-server: ВНИМАНИЕ: $*"; }
die(){ >&2 echo "code-server: ОШИБКА: $*"; exit 1; }

valid_port(){ [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

# The values reach a YAML file, a unit name and a declaration: check their form
# here too, not only in cream (an older config file, a hand edit).
check_values(){
    [[ "${CODE_SERVER_BIND:=127.0.0.1}" =~ $RE_ADDR ]] || die "CODE_SERVER_BIND: недопустимое значение"
    valid_port "${CODE_SERVER_PORT:=9001}" || die "CODE_SERVER_PORT: недопустимое значение"
    CODE_SERVER_PORT=$((10#$CODE_SERVER_PORT))
    case "${CODE_SERVER_ALLOW_NO_AUTH:=0}" in 0|1) ;; *) die "CODE_SERVER_ALLOW_NO_AUTH: 0 или 1" ;; esac
    [[ -z "${CODE_SERVER_USER:=}" || "$CODE_SERVER_USER" =~ $RE_USER ]] || die "CODE_SERVER_USER: недопустимое имя"
}

is_loopback(){ case "$1" in 127.*|::1|localhost) return 0 ;; esac; return 1; }

# read_password: PW — the value of CODE_SERVER_PASSWORD in the secrets file
# (cream's grammar: bare, or "…" with \" and \\ escaped), empty when unset.
# PW is a plain shell variable: never exported, printed or passed in argv.
PW=""
read_password(){
    local line v out i ch
    PW=""
    [[ -e "$SECRETS" || -L "$SECRETS" ]] || return 0
    [[ -f "$SECRETS" && ! -L "$SECRETS" ]] || { warn "${SECRETS#"$R"} — не обычный файл, пароль не читаю"; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*CODE_SERVER_PASSWORD=(.*)$ ]] || continue
        v="${BASH_REMATCH[1]}"
        if (( ${#v} >= 2 )) && [[ "$v" == \"*\" ]]; then
            v="${v:1:${#v}-2}"; out=""
            for (( i = 0; i < ${#v}; i++ )); do
                ch="${v:i:1}"
                if [[ "$ch" == "\\" ]]; then i=$((i + 1)); ch="${v:i:1}"; fi
                out+="$ch"
            done
            v="$out"
        fi
        PW="$v"
    done < "$SECRETS"
    BASH_REMATCH=()
}

# decide_auth: AUTH=password|none and 0 — the service may run; 1 — refused
# (no password, not allowed); 2 — the password does not fit its type.
AUTH=""
decide_auth(){
    read_password || return 2
    if [[ -n "$PW" ]]; then
        if [[ ! "$PW" =~ $RE_PASSWORD ]]; then
            PW=""
            warn "CODE_SERVER_PASSWORD не подходит под тип (8–128 знаков без пробелов, кавычек, \$ и обратной косой) — code-server не запускаю"
            return 2
        fi
        AUTH=password
        return 0
    fi
    if [[ "$CODE_SERVER_ALLOW_NO_AUTH" == 1 ]]; then
        warn "БЕЗ АУТЕНТИФИКАЦИИ (CODE_SERVER_ALLOW_NO_AUTH=1): шелл пользователя — любому, кто достаёт до ${CODE_SERVER_BIND}:${CODE_SERVER_PORT}"
        is_loopback "$CODE_SERVER_BIND" || warn "адрес $CODE_SERVER_BIND — не петля: шелл открыт сети"
        AUTH=none
        return 0
    fi
    warn "нет CODE_SERVER_PASSWORD — code-server без аутентификации не запускается"
    warn "  пароль: echo <пароль> | sudo cream set code-server CODE_SERVER_PASSWORD=-"
    warn "  или осознанно без пароля: sudo cream set code-server CODE_SERVER_ALLOW_NO_AUTH=1"
    return 1
}

# ---------------------------------------------------------------------------
# Leftovers of the layout 2 code-server (4.x)
# ---------------------------------------------------------------------------
# There is no transition (plan ruling R1). The 4.x extension left things that
# start code-server around this extension's password check, or keep a trusted
# root CA: its own instance units and their enablement links, the
# configure-code-server.service with its link, and the mkcert CA in the system
# trust store. Only root-owned paths are looked at: nothing in a home directory
# is opened by root (any user could plant a file there to block install or stop
# the service, or a FIFO to hang the hook). An old config.yaml of the user is
# harmless — write-config replaces it (as the user) and the wrapper refuses
# `auth: none` without CODE_SERVER_ALLOW_NO_AUTH=1. install refuses before
# changing anything, configure and apply refuse (the service is not started)
# while any of them is there — the operator cleans up by the listed commands.
CONFIG_HEADER="# Written by cream (extension code-server)"
SYSTEMD_ETC="$R/etc/systemd/system"
CA_DIR="$R/usr/local/share/ca-certificates"

# legacy_leftovers: one line per leftover (path on the machine), nothing when clean.
legacy_leftovers(){
    local f
    shopt -s nullglob
    # Instance units and drop-ins; the template code-server@.service is ours (files).
    for f in "$SYSTEMD_ETC"/code-server@?*.service "$SYSTEMD_ETC"/code-server@*.service.d \
             "$SYSTEMD_ETC"/configure-code-server.service "$SYSTEMD_ETC"/configure-code-server.service.d; do
        [[ -e "$f" || -L "$f" ]] && echo "${f#"$R"}"
    done
    # Enablement links: this extension never enables an instance.
    for f in "$SYSTEMD_ETC"/*.wants/code-server@*.service "$SYSTEMD_ETC"/*.requires/code-server@*.service \
             "$SYSTEMD_ETC"/*.wants/configure-code-server.service "$SYSTEMD_ETC"/*.requires/configure-code-server.service; do
        echo "${f#"$R"}"
    done
    for f in "$CA_DIR"/mkcert_development_CA_*.crt; do echo "${f#"$R"}"; done
    shopt -u nullglob
}

# refuse_on_leftovers: 0 — clean; otherwise the list and the cleanup to stderr, 1.
refuse_on_leftovers(){
    local found
    found="$(legacy_leftovers)"
    [[ -n "$found" ]] || return 0
    log "ОШИБКА: остатки прежнего code-server (4.x) — они запускают code-server в обход проверки пароля или держат доверенный корневой CA:"
    printf '%s\n' "$found" | sed 's/^/code-server:   /' >&2
    log "уберите их и повторите (подробно — README расширения, «Остатки 4.x»):"
    log "  sudo systemctl disable --now configure-code-server.service 'code-server@*.service'"
    log "  sudo rm -r -f -- /etc/systemd/system/configure-code-server.service* /etc/systemd/system/code-server@?*.service* \\"
    log "      /etc/systemd/system/*.wants/configure-code-server.service /etc/systemd/system/*.wants/code-server@*.service"
    log "  sudo systemctl daemon-reload"
    log "  CA mkcert: sudo CAROOT=<домашний каталог>/.local/share/code-server/certs mkcert -uninstall,"
    log "      или sudo rm /usr/local/share/ca-certificates/mkcert_development_CA_*.crt && sudo update-ca-certificates --fresh"
    return 1
}

# ---------------------------------------------------------------------------
# The Teleport declaration
# ---------------------------------------------------------------------------
decl_uri(){
    case "$CODE_SERVER_BIND" in
        127.0.0.1|localhost|0.0.0.0) echo "https://127.0.0.1:$CODE_SERVER_PORT" ;;
        ::1|::) echo "https://[::1]:$CODE_SERVER_PORT" ;;
        *) return 1 ;;
    esac
}

# no_symlink_chain: 0 — none of /etc, /etc/cream, /etc/cream/teleport, apps.d is a symlink.
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
        log "объявление для Teleport снято: apps.d/code-server.conf"
    fi
}

decl_write(){
    local uri content tmp d
    uri="$(decl_uri)" || { decl_remove; return 0; }
    no_symlink_chain || return 0
    content="$(printf 'NAME=code-server\nURI=%s\nICON=laptop' "$uri")"
    if [[ -f "$DECL" && ! -L "$DECL" ]] && [[ "$(cat -- "$DECL")" == "$content" ]]; then
        return 0
    fi
    for d in "$R/etc/cream" "$TP_DIR" "$APPS_DIR"; do
        [[ -d "$d" ]] || mkdir -m 0755 -- "$d" || { warn "не создать ${d#"$R"}"; return 0; }
    done
    # mktemp: O_EXCL, 0600, never follows; rename replaces a symlink, not its target.
    tmp="$(mktemp "$APPS_DIR/.code-server.XXXXXX")" || { warn "не создать временный файл в apps.d"; return 0; }
    printf '%s\n' "$content" > "$tmp" && chmod 0644 "$tmp" && mv -f -T -- "$tmp" "$DECL" \
        || { rm -f -- "$tmp"; warn "объявление для Teleport не записано"; return 0; }
    log "объявлен для Teleport: apps.d/code-server.conf ($uri)"
}

# ---------------------------------------------------------------------------
# The instances
# ---------------------------------------------------------------------------
instances(){
    systemctl list-units --all --plain --no-legend 'code-server@*.service' 2>/dev/null \
        | awk '{print $1}' | grep -E '^code-server@[a-z_][a-z0-9_-]*\.service$' || true
}

# stop_instances [keep]: stop every loaded instance but code-server@<keep>.
stop_instances(){
    local keep="${1:-}" u
    while IFS= read -r u; do
        [[ -n "$u" && "$u" != "code-server@${keep}.service" ]] || continue
        systemctl stop --no-block "$u" || warn "не остановить $u"
        log "$u: останов поставлен в очередь"
    done < <(instances)
}

# resolve_user <wait seconds>: CODE_SERVER_USER or the cloud-init user — an
# existing account that is not root; prints "user<TAB>home" (home as in passwd).
resolve_user(){
    local wait_s="$1" waited=0 user="" ent uid home
    while :; do
        if [[ -n "$CODE_SERVER_USER" ]]; then
            user="$CODE_SERVER_USER"
        else
            user=""
            [[ -x "$CLOUD_USER_LIB" ]] && user="$("$CLOUD_USER_LIB" 2>/dev/null || true)"
        fi
        if [[ "$user" =~ $RE_USER ]] && ent="$(getent passwd "$user" 2>/dev/null)"; then
            IFS=: read -r _ _ uid _ _ home _ <<< "$ent"
            if [[ "$uid" == 0 ]]; then warn "пользователь $user — root: code-server от root не запускается"; return 1; fi
            printf '%s\t%s\n' "$user" "$home"; return 0
        fi
        (( waited < wait_s )) || break
        sleep 3; waited=$((waited + 3))
    done
    if [[ -n "$user" && ! "$user" =~ $RE_USER ]]; then
        warn "имя пользователя cloud-init не подходит для имени юнита — пропускаю"
    else
        local waited_note=""
        (( wait_s > 0 )) && waited_note=" (ждал ${wait_s} с)"
        warn "нет пользователя${user:+ $user}${waited_note} — code-server не запущен"
    fi
    return 1
}

# close_fds: close every descriptor above 2 of this (sub)shell.
close_fds(){
    local fd fds=()
    # The lock of cream explicitly: without /proc the loop below sees nothing.
    if [[ "${CREAM_LOCK_FD:-}" =~ ^[0-9]+$ ]] && (( CREAM_LOCK_FD > 2 )); then
        eval "exec ${CREAM_LOCK_FD}>&-" 2>/dev/null || true
    fi
    [[ -d /proc/self/fd ]] || return 0
    for fd in /proc/self/fd/*; do fds+=("${fd##*/}"); done
    for fd in "${fds[@]}"; do
        [[ "$fd" =~ ^[0-9]+$ ]] && (( fd > 2 )) || continue
        # fd is digits only (checked above): safe for eval.
        eval "exec ${fd}>&-" 2>/dev/null || true
    done
}

# write_user_config <user> <home>: config.yaml written by write-config run as
# the user; the password only on its stdin. 0 — written or unchanged.
write_user_config(){
    local user="$1" home="$2" out rc=0
    out="$(mktemp)"
    (
        close_fds
        printf '%s\n' "$PW" | timeout -k 5 "$USER_TIMEOUT" runuser -u "$user" -- \
            env -i "PATH=$USER_PATH" LANG=C.UTF-8 \
            /bin/bash "$SELF" write-config "$home" "$CODE_SERVER_BIND" "$CODE_SERVER_PORT" "$AUTH" \
            > "$out" 2>&1
    ) || rc=$?
    # The output is the user's process's: no control characters into the
    # journal, every line marked.
    head -c 4096 "$out" | LC_ALL=C tr -d '\000-\011\013-\037\177' | sed 's/^/  [от имени пользователя] /' >&2 || true
    rm -f -- "$out"
    return "$rc"
}

# scrub_user_config: authentication refused — a config.yaml written before
# (with the password now taken away) is rewritten with `auth: none` and no
# password, so the old password does not linger in the home directory and a
# manual `systemctl start` is refused by the wrapper (78). Best effort, quiet:
# only an existing config of a user known right now.
scrub_user_config(){
    local ent user home
    [[ -x "$CS_BIN" ]] || return 0
    ent="$(resolve_user 0 2>/dev/null)" || return 0
    IFS=$'\t' read -r user home <<< "$ent"
    [[ "$home" == /* && -d "$R$home" && ! -L "$R$home" ]] || return 0
    [[ -f "$R$home/.config/code-server/config.yaml" ]] || return 0
    PW=""; AUTH=none
    if write_user_config "$user" "$R$home"; then
        log "из ~/.config/code-server/config.yaml пользователя $user пароль убран (auth: none — обёртка не запустит)"
    else
        warn "config.yaml пользователя $user не переписан — прежний пароль в нём остался"
    fi
}

# run <boot|now>: the whole decision; boot — start, wait for the user; now — restart.
run(){
    local mode="$1" ent user home wait_s=0 verb=restart rc=0
    check_values
    if ! refuse_on_leftovers; then
        decl_remove
        stop_instances
        exit 1
    fi
    decide_auth || rc=$?
    if (( rc != 0 )); then
        decl_remove
        stop_instances
        scrub_user_config
        (( rc == 2 )) && exit 1
        return 0
    fi
    if [[ ! -x "$CS_BIN" ]]; then
        warn "нет /usr/bin/code-server — пакет не установлен (cream install code-server)"
        return 0
    fi
    if [[ "$mode" == boot ]]; then wait_s=$USER_WAIT_BOOT; verb=start; fi
    if ! ent="$(resolve_user "$wait_s")"; then
        decl_remove
        stop_instances
        return 0
    fi
    IFS=$'\t' read -r user home <<< "$ent"
    if [[ "$home" != /* || ! -d "$R$home" || -L "$R$home" ]]; then
        warn "у пользователя $user нет домашнего каталога (или это ссылка) — code-server не запущен"
        decl_remove
        stop_instances
        return 0
    fi
    if ! write_user_config "$user" "$R$home"; then
        warn "конфигурация code-server для $user не записана — code-server не запущен"
        decl_remove
        stop_instances
        return 0
    fi
    PW=""
    decl_write
    # Another user's instance would fight for the same port.
    stop_instances "$user"
    systemctl "$verb" --no-block "code-server@${user}.service" || warn "code-server@${user}: $verb не поставлен в очередь"
    log "code-server@${user}: $verb поставлен в очередь — journalctl -u code-server@${user}"
}

# ---------------------------------------------------------------------------
# As the user
# ---------------------------------------------------------------------------
# cmd_write_config <home> <bind> <port> <auth>: the password on stdin.
cmd_write_config(){
    local home="${1:-}" bind="${2:-}" port="${3:-}" auth="${4:-}" pw="" me d dir conf host content tmp
    umask 077
    (( EUID != 0 )) || die "write-config — только от имени пользователя, не от root"
    [[ "$bind" =~ $RE_ADDR ]] || die "адрес не по форме"
    valid_port "$port" || die "порт не по форме"
    case "$auth" in password|none) ;; *) die "auth: password или none" ;; esac
    IFS= read -r pw || true
    if [[ "$auth" == password && ! "$pw" =~ $RE_PASSWORD ]]; then
        die "пароль не по форме"
    fi
    me="$(id -u)"
    [[ "$home" == /* && -d "$home" && ! -L "$home" ]] || die "домашний каталог — не каталог или ссылка"
    [[ "$(stat -c %u -- "$home")" == "$me" ]] || die "домашний каталог принадлежит не мне"
    for d in "$home/.config" "$home/.config/code-server"; do
        [[ ! -L "$d" ]] || die "${d#"$home"/} — символическая ссылка, не пишу через неё"
        [[ -e "$d" ]] || mkdir -m 0700 -- "$d" || die "не создать ${d#"$home"/}"
        [[ -d "$d" && ! -L "$d" ]] || die "${d#"$home"/} — не каталог"
        [[ "$(stat -c %u -- "$d")" == "$me" ]] || die "${d#"$home"/} принадлежит не мне"
    done
    dir="$home/.config/code-server"
    chmod 0700 -- "$dir"
    conf="$dir/config.yaml"
    host="$bind"; [[ "$bind" == *:* ]] && host="[$bind]"
    content="$CONFIG_HEADER on every configure: change the
# domain with \`cream set code-server …\`, not this file.
bind-addr: $host:$port
auth: $auth"
    [[ "$auth" == password ]] && content+=$'\n'"password: \"$pw\""
    content+=$'\ncert: true\ndisable-update-check: true'
    if [[ -f "$conf" && ! -L "$conf" && "$(stat -c %a -- "$conf")" == 600 ]] \
        && [[ "$(cat -- "$conf")" == "$content" ]]; then
        log "config.yaml без изменений"
        return 0
    fi
    # mktemp: O_EXCL, 0600, never follows; rename replaces a symlink, not its target.
    tmp="$(mktemp "$dir/.config.yaml.XXXXXX")" || die "не создать временный файл"
    if ! { printf '%s\n' "$content" > "$tmp" && chmod 0600 -- "$tmp" && mv -f -T -- "$tmp" "$conf"; }; then
        rm -f -- "$tmp"
        die "config.yaml не записан"
    fi
    log "config.yaml записан (auth: $auth)"
}

# cmd_start: ExecStart of code-server@.service (User=%i). Refuses with 78 a
# config without authentication unless CODE_SERVER_ALLOW_NO_AUTH=1 (from the
# EnvironmentFile); code-server gets a clean environment and only --config.
cmd_start(){
    local conf auth
    if (( EUID == 0 )); then log "ОШИБКА: от root code-server не запускается"; exit 78; fi
    conf="${HOME:?нет HOME}/.config/code-server/config.yaml"
    if [[ ! -f "$conf" || -L "$conf" ]]; then
        log "ОШИБКА: нет ~/.config/code-server/config.yaml (или это ссылка) — его пишет configure расширения"
        exit 78
    fi
    auth="$(sed -n 's/^auth:[[:space:]]*//p' -- "$conf" | tail -n 1)"
    case "$auth" in
        password)
            if ! grep -qE '^(hashed-)?password:[[:space:]]*"?[^"[:space:]]' -- "$conf"; then
                log "ОШИБКА: auth: password без пароля — не запускаю"
                exit 78
            fi ;;
        none)
            if [[ "${CODE_SERVER_ALLOW_NO_AUTH:-0}" != 1 ]]; then
                log "ОШИБКА: auth: none, а CODE_SERVER_ALLOW_NO_AUTH не 1 — без аутентификации не запускаю"
                log "  пароль: echo <пароль> | sudo cream set code-server CODE_SERVER_PASSWORD=-"
                exit 78
            fi
            warn "БЕЗ АУТЕНТИФИКАЦИИ (CODE_SERVER_ALLOW_NO_AUTH=1)" ;;
        *)
            log "ОШИБКА: auth: '${auth//[^a-z-]/}' — ждали password или none"
            exit 78 ;;
    esac
    exec env -i "HOME=$HOME" "USER=${USER:-}" "LOGNAME=${LOGNAME:-${USER:-}}" "SHELL=${SHELL:-/bin/bash}" \
        "PATH=/usr/local/bin:/usr/bin:/bin" "LANG=${LANG:-C.UTF-8}" \
        "$CS_BIN" --config "$conf"
}

# ---------------------------------------------------------------------------
# install, remove
# ---------------------------------------------------------------------------
apt_retry(){
    local i
    for i in 1 2 3; do
        "$@" && return 0
        warn "попытка $i: $* — не удалась, повтор через 10 с"
        sleep 10
    done
    return 1
}

# installed_version: the version of the installed package, empty otherwise.
installed_version(){
    local s
    s="$(dpkg-query -W -f='${db:Status-Status} ${Version}' code-server 2>/dev/null || true)"
    [[ "$s" == "installed "* ]] && echo "${s#installed }"
    return 0
}

cmd_install(){
    local arch work have=0 url
    local -a need=()
    refuse_on_leftovers || exit 1
    arch="$(dpkg --print-architecture)"
    [[ -n "${DEB_SHA256[$arch]:-}" ]] || die "архитектура $arch — .deb code-server закреплён только для amd64 и arm64"
    export DEBIAN_FRONTEND=noninteractive
    [[ "$(installed_version)" == "$CS_VERSION" ]] && have=1
    # openssl: code-server issues its self-signed certificate with it (cert: true).
    [[ -x "$OPENSSL_BIN" ]] || need+=(openssl)
    if (( ! have )) && ! command -v curl >/dev/null 2>&1; then need+=(curl ca-certificates); fi
    if (( ${#need[@]} )); then
        apt_retry apt-get update -q || die "apt-get update не прошёл"
        apt_retry apt-get install -y -q --no-install-recommends "${need[@]}" || die "${need[*]} не установились"
    fi
    if (( have )); then
        log "code-server $CS_VERSION уже установлен"
        return 0
    fi
    work="$(mktemp -d)"
    # shellcheck disable=SC2064  # expand now: the path is fixed
    trap "rm -r -f -- '$work'" EXIT
    url="$RELEASES/v$CS_VERSION/code-server_${CS_VERSION}_${arch}.deb"
    log "скачиваю $url"
    # --speed-limit/--speed-time turn a stalled transfer into a retry.
    curl -fsSL --retry 5 --retry-delay 5 --connect-timeout 30 --speed-limit 10240 --speed-time 60 \
        -o "$work/code-server.deb" "$url" || die ".deb не скачался: $url"
    if ! echo "${DEB_SHA256[$arch]}  $work/code-server.deb" | sha256sum -c --quiet - >/dev/null 2>&1; then
        die "sha256 .deb не совпал с закреплённым для $arch — не ставлю"
    fi
    apt_retry apt-get install -y -q --no-install-recommends "$work/code-server.deb" \
        || die "code-server $CS_VERSION не установился"
    [[ -x "$CS_BIN" ]] || die "после установки нет /usr/bin/code-server"
    log "code-server $CS_VERSION установлен ($arch); пароль — echo <пароль> | sudo cream set code-server CODE_SERVER_PASSWORD=-"
}

cmd_remove(){
    local u
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        systemctl stop "$u" || warn "не остановить $u"
        systemctl reset-failed "$u" 2>/dev/null || true
    done < <(instances)
    decl_remove
    if [[ -n "$(installed_version)" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get purge -y -q code-server || die "пакет code-server не удалился"
        log "пакет code-server удалён; ~/.config/code-server и ~/.local/share/code-server пользователя остаются"
    fi
}

case "${1:-}" in
    install) cmd_install ;;
    configure)
        case "${CREAM_REASON:-boot}" in
            boot) run boot ;;
            *) run now ;;
        esac ;;
    apply) run now ;;
    remove) cmd_remove ;;
    write-config) shift; cmd_write_config "$@" ;;
    start) cmd_start ;;
    *) die "использование: code-server.sh install|configure|apply|remove|write-config|start" ;;
esac
