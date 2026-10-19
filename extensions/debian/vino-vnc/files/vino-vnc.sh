#!/usr/bin/env bash
# vino-vnc of cream: the settings of vino (org.gnome.Vino, dconf path
# /org/gnome/desktop/remote-access/) as SYSTEM dconf databases with locks.
# Called by the hooks configure (`configure`) and remove (`remove`). Paths of
# the machine go under $CREAM_ROOT (hooktest).
#
# NOTHING IS WRITTEN INTO THE HOME DIRECTORY. Layout 2 ran gsettings as the user
# and wrote ~/.config/autostart as root (through whatever links the user had
# planted). Now: the settings are the system databases below, locked so the
# user database cannot override them; the autostart is /etc/xdg/autostart
# (install). The session reads both when it opens — configure runs before the
# display manager (stage system, plan ruling R5); on a working machine a change
# reaches vino at the next login.
#
#   /etc/dconf/db/vino-vnc         port, interface, encryption, auth method,
#                                  prompt off — 0644, no secret in it
#   /etc/dconf/db/vino-vnc-secret  vnc-password (base64, as the key wants it,
#                                  i.e. the password itself) — 0640
#                                  root:<primary group of the session user>
#   /etc/dconf/profile/user        + system-db:vino-vnc-secret, system-db:vino-vnc
#
# Both are built by `dconf compile` from keyfiles in a 0700 directory made under
# umask 077, given their group and mode there, and renamed into place: the
# password never sits in a file wider than its final rights, never in an argv
# (printf and base64 read it from a pipe) nor a child's environment. No .d
# directory is left, so `dconf update` of other extensions never recompiles
# them (it would write 0644). A link at a target is a refusal.
#
# No session user (a container): the secret database stays root's only — vino
# then finds no password and refuses everyone — a warning and 0 (rule R11).
set -euo pipefail

R="${CREAM_ROOT:-}"; R="${R%/}"
DB="$R/etc/dconf/db"
PUB="$DB/vino-vnc"
SEC="$DB/vino-vnc-secret"
PROFILE="$R/etc/dconf/profile/user"
PROFILE_OURS="${CREAM_STATE_DIR:?run by cream}/profile.created"
CLOUD_USER_LIB="$R/opt/cream/ext/cloud-user/get_cloud_user.sh"
KEYPATH=/org/gnome/desktop/remote-access
NAME_RE='^[a-z_][a-z0-9_-]{0,31}$'

log(){ >&2 echo "vino-vnc: $*"; }
die(){ log "ОШИБКА: $*"; exit 1; }

VINO_PORT="${VINO_PORT:-5900}"
VINO_LISTEN="${VINO_LISTEN:-localhost}"
VINO_ENCRYPTION="${VINO_ENCRYPTION:-false}"
[[ "$VINO_PORT" =~ ^[0-9]{4,5}$ ]] || die "VINO_PORT «$VINO_PORT» — не порт"
[[ "$VINO_LISTEN" == localhost || "$VINO_LISTEN" == all ]] || die "VINO_LISTEN «$VINO_LISTEN»"
[[ "$VINO_ENCRYPTION" == true || "$VINO_ENCRYPTION" == false ]] || die "VINO_ENCRYPTION «$VINO_ENCRYPTION»"

# resolve_user <wait seconds>: the cloud-init user (library cloud-user).
resolve_user(){
    local wait_s="$1" waited=0 user
    while :; do
        user=""
        [[ -x "$CLOUD_USER_LIB" ]] && user="$("$CLOUD_USER_LIB" 2>/dev/null || true)"
        if [[ -n "$user" && "$user" =~ $NAME_RE ]] && id -u "$user" >/dev/null 2>&1; then
            printf '%s\n' "$user"; return 0
        fi
        [[ "$waited" -ge "$wait_s" ]] && return 1
        sleep 3; waited=$((waited + 3))
    done
}

# not_link <path>: a link (or anything but a regular file) at a target is a refusal.
not_link(){
    if [[ -L "$1" || ( -e "$1" && ! -f "$1" ) ]]; then
        die "${1#"$R"} — не обычный файл (ссылка?); не пишу"
    fi
}

safe_db_dir(){
    [[ ! -L "$DB" && ! -L "${DB%/*}" ]] || die "${DB#"$R"} — ссылка; не пишу"
    install -d -m 0755 "$DB"
}

# compile_db <target> <mode> <group or empty> <keyfile> <locks>: dconf compile
# in a private directory, group and mode set there, renamed when different.
compile_db(){
    local target="$1" mode="$2" group="$3" keyfile="$4" locks="$5" tmp
    safe_db_dir
    not_link "$target"
    tmp="$(umask 077; mktemp -d "$DB/.vino-vnc.XXXXXX")" || die "временный каталог в ${DB#"$R"} не создан"
    # shellcheck disable=SC2064  # the path is fixed now
    trap "rm -r -f -- '$tmp'" EXIT
    (
        umask 077
        mkdir -p "$tmp/keyfiles/locks"
        printf '%s' "$keyfile" > "$tmp/keyfiles/50-vino-vnc"
        printf '%s' "$locks" > "$tmp/keyfiles/locks/50-vino-vnc"
    ) || die "ключи dconf не записаны"
    dconf compile "$tmp/db" "$tmp/keyfiles" || die "dconf compile ${target#"$R"} не прошёл"
    if [[ -n "$group" ]]; then
        chgrp "$group" -- "$tmp/db" || die "группа $group не назначена ${target#"$R"}"
    fi
    chmod "$mode" -- "$tmp/db"
    if [[ -f "$target" ]] && cmp -s "$tmp/db" "$target" \
        && [[ "$(stat -c %G:%a "$tmp/db")" == "$(stat -c %G:%a "$target")" ]]; then
        :
    else
        mv -f -T -- "$tmp/db" "$target"
        log "${target#"$R"} записана"
    fi
    rm -r -f -- "$tmp"
    trap - EXIT
}

ensure_profile(){
    local line tmp
    [[ ! -L "${PROFILE%/*}" ]] || die "${PROFILE%/*} — ссылка; не пишу"
    not_link "$PROFILE"
    install -d -m 0755 "${PROFILE%/*}"
    if [[ ! -f "$PROFILE" ]]; then
        tmp="$(mktemp "${PROFILE%/*}/.user.XXXXXX")"
        printf 'user-db:user\nsystem-db:vino-vnc-secret\nsystem-db:vino-vnc\n' > "$tmp"
        chmod 0644 "$tmp"; mv -f -T -- "$tmp" "$PROFILE"
        install -d -m 0755 "${PROFILE_OURS%/*}"; : > "$PROFILE_OURS"
        return 0
    fi
    for line in system-db:vino-vnc-secret system-db:vino-vnc; do
        grep -qxF "$line" "$PROFILE" && continue
        tmp="$(mktemp "${PROFILE%/*}/.user.XXXXXX")"
        { cat "$PROFILE"; printf '%s\n' "$line"; } > "$tmp"
        chmod 0644 "$tmp"; mv -f -T -- "$tmp" "$PROFILE"
    done
}

configure(){
    local wait_s=0 user="" group="" pass auth iface alt keyfile locks k
    [[ "${CREAM_REASON:-boot}" == boot ]] && wait_s=30
    user="$(resolve_user "$wait_s")" || user=""
    if [[ -n "$user" ]]; then
        group="$(id -gn "$user")" || group=""
        [[ "$group" =~ $NAME_RE ]] || { log "основная группа '$user' негодна — секретная база только для root"; group=""; }
    fi
    ensure_profile

    pass="$(cream config get --secret vino-vnc VINO_PASSWORD)" || die "пароль не прочитан из cream"
    if [[ -n "$pass" ]]; then
        auth="['vnc']"
        # vnc-password holds base64 (its schema says so). The value goes through
        # a pipe into a 0700 directory only.
        keyfile="[${KEYPATH#/}]
vnc-password='$(printf '%s' "$pass" | base64 -w0)'
"
        pass=""
        compile_db "$SEC" 0640 "$group" "$keyfile" "$KEYPATH/vnc-password
"
        keyfile=""
        [[ -n "$group" ]] || log "пользователь сессии не найден — пароль vino читает только root, подключиться нельзя"
    else
        auth="['none']"
        not_link "$SEC"
        rm -f -- "$SEC"
        log "пароль не задан: аутентификации не будет"
    fi

    iface="'lo'"
    [[ "$VINO_LISTEN" == localhost ]] || iface="''"
    alt=false
    [[ "$VINO_PORT" == 5900 ]] || alt=true
    keyfile="[${KEYPATH#/}]
prompt-enabled=false
require-encryption=$VINO_ENCRYPTION
authentication-methods=$auth
network-interface=$iface
use-alternative-port=$alt
"
    [[ "$alt" == true ]] && keyfile+="alternative-port=uint16 $VINO_PORT
"
    locks=""
    for k in prompt-enabled require-encryption authentication-methods network-interface \
             use-alternative-port alternative-port; do
        locks+="$KEYPATH/$k
"
    done
    compile_db "$PUB" 0644 "" "$keyfile" "$locks"

    if [[ "$VINO_LISTEN" != localhost ]]; then
        log "слушаю ВСЕ интерфейсы (VINO_LISTEN=all)"
        [[ "$auth" == "['vnc']" ]] || log "и без пароля — рабочий стол получит кто угодно в этой сети"
        [[ "$VINO_ENCRYPTION" == true ]] || log "и без шифрования — нажатия клавиш идут открытым текстом"
    fi
    log "готово; vino поднимется с сессией на порту $VINO_PORT${user:+ (пользователь $user)}"
}

remove(){
    local f tmp
    for f in "$PUB" "$SEC"; do
        [[ -L "$f" ]] || rm -f -- "$f"
    done
    [[ -f "$PROFILE" && ! -L "$PROFILE" ]] || { rm -f -- "$PROFILE_OURS"; return 0; }
    tmp="$(mktemp "${PROFILE%/*}/.user.XXXXXX")"
    grep -vxF -e system-db:vino-vnc-secret -e system-db:vino-vnc "$PROFILE" > "$tmp" || true
    if [[ -f "$PROFILE_OURS" && "$(cat "$tmp")" == user-db:user ]]; then
        rm -f -- "$tmp" "$PROFILE"
    elif cmp -s "$tmp" "$PROFILE"; then
        rm -f -- "$tmp"
    else
        chmod 0644 "$tmp"; mv -f -T -- "$tmp" "$PROFILE"
    fi
    rm -f -- "$PROFILE_OURS"
}

case "${1:-}" in
    configure) configure ;;
    remove) remove ;;
    *) die "usage: vino-vnc.sh configure|remove" ;;
esac
