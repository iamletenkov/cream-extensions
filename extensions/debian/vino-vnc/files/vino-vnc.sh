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
# FAIL-CLOSED. An empty password is NOT "no authentication": the method stays
# 'vnc' (nobody gets in) and the autostart goes ("пароль не задан — vino
# выключен"). No authentication only with the explicit key
# VINO_ALLOW_NO_PASSWORD=1 (rule R8 of the plan), warned at every configure. The
# layout 2 file /etc/vino/vnc-password.b64 with no secret in cream is neither
# removed nor used: vino stays off with a hint how to set the password.
#
# The password database is readable by the primary group of the session user
# only when that group is personal (named after the user, nobody else in it);
# otherwise configure fails — never a weaker file. No session user (a
# container): the database stays root's only — vino finds no password and
# refuses everyone — a warning and 0 (rule R11).
set -euo pipefail

R="${CREAM_ROOT:-}"; R="${R%/}"
DB="$R/etc/dconf/db"
PUB="$DB/vino-vnc"
SEC="$DB/vino-vnc-secret"
PROFILE="$R/etc/dconf/profile/user"
PROFILE_OURS="${CREAM_STATE_DIR:?run by cream}/profile.created"
CLOUD_USER_LIB="$R/opt/cream/ext/cloud-user/get_cloud_user.sh"
SRC="$R/usr/share/applications/vino-server.desktop"
AUTO="$R/etc/xdg/autostart/vino-server.desktop"
# The password file of layout 2 (secret:hook): kept and never used silently.
LEGACY="$R/etc/vino/vnc-password.b64"
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

# personal_group <user>: the primary group of the user, only when it is the
# user's own — named after the user, nobody else in it (members in /etc/group or
# the same primary gid). Otherwise the members would read the password: a
# failure of configure, never a weaker file.
personal_group(){
    local user="$1" group gid members others
    group="$(id -gn "$user")" || die "основная группа '$user' не определилась"
    gid="$(id -g "$user")" || die "gid '$user' не определился"
    if [[ "$group" != "$user" || ! "$group" =~ $NAME_RE ]]; then
        die "основная группа '$user' — '$group', не личная: её члены прочли бы пароль vino; нужна личная группа '$user'"
    fi
    members="$(getent group "$group" | cut -d: -f4)" || members=""
    if [[ -n "$members" && "$members" != "$user" ]]; then
        die "в личной группе '$group' есть другие члены ($members) — они прочли бы пароль vino"
    fi
    others="$(getent passwd | awk -F: -v g="$gid" -v u="$user" '$4 == g && $1 != u {print $1}')"
    [[ -z "$others" ]] || die "группа '$group' — основная и у других ($others): не личная, пароль vino не пишу"
    printf '%s\n' "$group"
}

# autostart <on|off>: /etc/xdg/autostart/vino-server.desktop — a copy of the
# package's .desktop (the binary path differs between releases) with
# X-GNOME-Autostart-enabled=true; off removes it, so vino does not start.
autostart(){
    local tmp
    if [[ -L "$AUTO" || -L "${AUTO%/*}" || ( -e "$AUTO" && ! -f "$AUTO" ) ]]; then
        die "${AUTO#"$R"} — ссылка или не файл; не пишу"
    fi
    if [[ "$1" == off ]]; then
        rm -f -- "$AUTO"
        return 0
    fi
    [[ -f "$SRC" ]] || die "нет ${SRC#"$R"} — пакет vino не установлен"
    install -d -m 0755 "${AUTO%/*}"
    tmp="$(mktemp "${AUTO%/*}/.vino-server.XXXXXX")"
    { grep -v '^X-GNOME-Autostart-enabled=' "$SRC"; echo "X-GNOME-Autostart-enabled=true"; } > "$tmp"
    chmod 0644 "$tmp"
    if [[ -f "$AUTO" ]] && cmp -s "$tmp" "$AUTO"; then
        rm -f -- "$tmp"
    else
        mv -f -T -- "$tmp" "$AUTO"
        log "автозапуск: ${AUTO#"$R"}"
    fi
}

configure(){
    local wait_s=0 user="" group="" pass auth iface alt keyfile locks k on=off
    [[ "${CREAM_REASON:-boot}" == boot ]] && wait_s=30
    user="$(resolve_user "$wait_s")" || user=""
    ensure_profile

    pass="$(cream config get --secret vino-vnc VINO_PASSWORD)" || die "пароль не прочитан из cream"
    # Fail-closed: without a password the method stays 'vnc' (nobody gets in)
    # and vino does not autostart, unless VINO_ALLOW_NO_PASSWORD=1 says so.
    auth="['vnc']"
    if [[ -n "$pass" ]]; then
        [[ -z "$user" ]] || group="$(personal_group "$user")"
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
        on=on
    else
        not_link "$SEC"
        rm -f -- "$SEC"
        if [[ -e "$LEGACY" || -L "$LEGACY" ]]; then
            log "есть ${LEGACY#"$R"} прежней версии, а секрета в cream нет — не трогаю и не использую; vino выключен"
            log "перенести пароль: echo 'пароль' | sudo cream set vino-vnc VINO_PASSWORD=-"
        elif [[ "${VINO_ALLOW_NO_PASSWORD:-0}" == 1 ]]; then
            auth="['none']"
            on=on
            log "ВНИМАНИЕ: VINO_ALLOW_NO_PASSWORD=1 — vino БЕЗ ПАРОЛЯ, аутентификации нет"
        else
            log "пароль не задан — vino выключен (задать: echo 'пароль' | sudo cream set vino-vnc VINO_PASSWORD=-;"
            log "без пароля — только явно: cream set vino-vnc VINO_ALLOW_NO_PASSWORD=1)"
        fi
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
    autostart "$on"

    [[ "$on" == on ]] || return 0
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
