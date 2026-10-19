#!/usr/bin/env bash
# x11vnc of cream: the password file, the server instance of the session user.
# Called by the hooks configure and apply (`configure`) and remove (`remove`).
# Paths of the machine go under $CREAM_ROOT (hooktest).
#
#   x11vnc.sh configure   — /etc/x11vnc/passwd from the secret X11VNC_PASSWORD
#                           (or the marker /etc/x11vnc/nopw when it is empty),
#                           then x11vnc@<user>.service on, other instances off
#   x11vnc.sh remove      — instances off, the password file and marker gone
#
# THE PASSWORD. It is read from cream (`cream config get --secret`: the hook
# environment never carries secrets) into a shell variable and leaves it only
# through a pipe: printf is a builtin, so it is in no argv (`ps`), no
# environment of a child and no log line. The -rfbauth format is the VNC
# password DES-encrypted with a fixed, public key — that is, the file IS the
# password. `x11vnc -storepasswd` takes the password in argv only, so the file is
# built by openssl from stdin: the same 8 bytes (checked against x11vnc
# -storepasswd on Debian 12, Ubuntu 22.04 and 24.04, 2026-10-19).
#
# The file is 0600 and belongs to the session user, the one the server runs as
# (`x11vnc@<user>`, User=%i) — hand_over_passfile. It is born under umask 077 in
# the root-owned /etc/x11vnc, given to the user and renamed into place: never a
# moment with wider rights, never a write through a link (a link at either path
# is a refusal). A password that cannot be built is a failure of configure, and
# the marker nopw is gone first.
#
# FAIL-CLOSED. An empty password is NOT "no password": the server stays off
# ("пароль не задан — x11vnc выключен"). -nopw only with the explicit key
# X11VNC_ALLOW_NO_PASSWORD=1 (rule R8 of the plan): configure then derives the
# marker nopw (and removes it in every other case — a marker made by hand does
# not survive), and the wrapper wants the marker AND the key, warning on every
# start. A password file this configure did not build ($CREAM_STATE_DIR/
# passfile.sha256 — e.g. left by layout 2) with no secret in cream is neither
# removed nor used: the server stays off with a hint how to set the password.
#
# No user or no display manager (a container, a server without a desktop): a
# warning and 0, rule R11 — the password decision is still written.
set -euo pipefail

R="${CREAM_ROOT:-}"; R="${R%/}"
SYSD="$R/etc/systemd/system"
WANTS="$SYSD/graphical.target.wants"
DIR="$R/etc/x11vnc"
PASSFILE="$DIR/passwd"
NOPW="$DIR/nopw"
# sha256 of the password file this configure built: what is not ours is kept.
OURS="${CREAM_STATE_DIR:?run by cream}/passfile.sha256"
CLOUD_USER_LIB="$R/opt/cream/ext/cloud-user/get_cloud_user.sh"
# The VNC DES key {23,82,107,6,35,78,88,7} with the bits of every byte reversed
# (the RFB quirk). Public, in every VNC implementation; not a secret.
VNC_DES_KEY=e84ad660c4721ae0
USER_RE='^[a-z_][a-z0-9_-]{0,31}$'

log(){ >&2 echo "x11vnc: $*"; }
die(){ log "ОШИБКА: $*"; exit 1; }

# instances: the user names of the enabled x11vnc@<user> instances.
instances(){
    local unit u
    shopt -s nullglob
    for unit in "$WANTS"/x11vnc@*.service; do
        u="${unit##*/x11vnc@}"; printf '%s\n' "${u%.service}"
    done
    shopt -u nullglob
}

# resolve_user <wait seconds>: the cloud-init user (library cloud-user), an
# existing account with a name fit for a unit name.
resolve_user(){
    local wait_s="$1" waited=0 user
    while :; do
        user=""
        [[ -x "$CLOUD_USER_LIB" ]] && user="$("$CLOUD_USER_LIB" 2>/dev/null || true)"
        if [[ -n "$user" ]]; then
            if [[ ! "$user" =~ $USER_RE ]]; then
                log "имя пользователя cloud-init негодно для имени юнита — не включаю сервер"
                return 1
            fi
            id -u "$user" >/dev/null 2>&1 && { printf '%s\n' "$user"; return 0; }
        fi
        [[ "$waited" -ge "$wait_s" ]] && return 1
        sleep 3; waited=$((waited + 3))
    done
}

# safe_dir: /etc/x11vnc is a real directory of root (created 0755 when absent):
# the server user walks through it to the file; the secret is closed by the
# file's mode, not the directory's.
safe_dir(){
    if [[ -L "$DIR" ]]; then
        die "${DIR#"$R"} — символическая ссылка; файл пароля не пишу"
    fi
    install -d -m 0755 "$DIR"
}

read_password(){
    cream config get --secret x11vnc X11VNC_PASSWORD
}

# hand_over_passfile <file> <user>: the reader of the file is the session user.
hand_over_passfile(){
    chown "$2" -- "$1" || return 1
    chmod 0600 -- "$1"
}

# build_passfile <user or empty>: the rfbauth file or the nopw marker.
build_passfile(){
    local user="$1" pass tmp
    safe_dir
    if [[ -L "$PASSFILE" || ( -e "$PASSFILE" && ! -f "$PASSFILE" ) ]]; then
        rm -f -- "$NOPW"
        die "${PASSFILE#"$R"} — не обычный файл (ссылка?); пароль не пишу, сервер без пароля не поднимется"
    fi
    pass="$(read_password)" || { rm -f -- "$NOPW"; die "пароль не прочитан из cream"; }
    if [[ -z "$pass" ]]; then
        rm -f -- "$NOPW"
        if [[ -f "$PASSFILE" ]]; then
            if [[ -f "$OURS" ]] && [[ "$(sha256sum < "$PASSFILE")" == "$(cat "$OURS")" ]]; then
                rm -f -- "$PASSFILE" "$OURS"
            else
                log "есть ${PASSFILE#"$R"}, но не из секрета cream (прежняя версия?) — не трогаю и не использую; x11vnc выключен"
                log "перенести пароль: echo 'пароль' | sudo cream set x11vnc X11VNC_PASSWORD=-"
                return 2
            fi
        fi
        if [[ "${X11VNC_ALLOW_NO_PASSWORD:-0}" != 1 ]]; then
            log "пароль не задан — x11vnc выключен (задать: echo 'пароль' | sudo cream set x11vnc X11VNC_PASSWORD=-;"
            log "сервер без пароля — только явно: cream set x11vnc X11VNC_ALLOW_NO_PASSWORD=1)"
            return 2
        fi
        (umask 022; : > "$NOPW")
        log "ВНИМАНИЕ: X11VNC_ALLOW_NO_PASSWORD=1 — сервер поднимется БЕЗ ПАРОЛЯ (-nopw)"
        return 0
    fi
    # From here on a failure leaves no way to -nopw.
    rm -f -- "$NOPW"
    tmp="$(umask 077; mktemp "$DIR/.passwd.XXXXXX")" || die "временный файл в ${DIR#"$R"} не создан"
    # shellcheck disable=SC2064  # the path is fixed now
    trap "rm -f -- '$tmp'" EXIT
    # RFB uses the first 8 bytes, zero-padded. No truncating stage after the
    # padding: a reader that quits early would SIGPIPE the writer (pipefail).
    local first8 len
    first8="$(printf '%s' "$pass" | LC_ALL=C head -c 8)"
    pass=""
    len="$(LC_ALL=C; printf '%s' "${#first8}")"
    { printf '%s' "$first8"; head -c "$((8 - len))" /dev/zero; } \
        | openssl enc -des-ecb -nopad -K "$VNC_DES_KEY" -provider legacy -provider default > "$tmp" \
        || die "openssl не построил файл пароля (нужен legacy-провайдер OpenSSL 3)"
    first8=""
    [[ "$(stat -c %s "$tmp")" == 8 ]] || die "файл пароля не 8 байт — не пишу"
    if [[ -n "$user" ]]; then
        hand_over_passfile "$tmp" "$user" || die "файл пароля не передан '$user'"
    fi
    if [[ -f "$PASSFILE" ]] && cmp -s "$tmp" "$PASSFILE" \
        && [[ "$(stat -c %U:%a "$tmp")" == "$(stat -c %U:%a "$PASSFILE")" ]]; then
        rm -f -- "$tmp"
    else
        mv -f -T -- "$tmp" "$PASSFILE"
        log "файл пароля ${PASSFILE#"$R"} записан${user:+ (владелец $user, 0600)}"
    fi
    trap - EXIT
    install -d -m 0755 "${OURS%/*}"
    sha256sum < "$PASSFILE" > "$OURS"
}

configure(){
    local wait_s=0 user="" u
    [[ "${CREAM_REASON:-boot}" == boot ]] && wait_s=30
    user="$(resolve_user "$wait_s")" || user=""
    [[ -n "$user" ]] || log "пользователь cloud-init не найден — сервер не включаю (файл пароля без владельца)"
    local auth_rc=0
    build_passfile "$user" || auth_rc=$?
    if [[ "$auth_rc" == 2 ]]; then
        while read -r u; do
            [[ -n "$u" ]] || continue
            systemctl disable "x11vnc@$u.service" || log "x11vnc@$u.service не выключился"
            systemctl --no-block stop "x11vnc@$u.service" || true
        done < <(instances)
        return 0
    fi
    [[ -n "$user" ]] || return 0
    if [[ ! -L "$SYSD/display-manager.service" ]]; then
        log "менеджера входа нет (display-manager.service) — сервер не включаю"
        return 0
    fi
    while read -r u; do
        [[ -n "$u" && "$u" != "$user" ]] || continue
        log "гашу прежний экземпляр x11vnc@$u.service"
        systemctl disable "x11vnc@$u.service" || log "x11vnc@$u.service не выключился"
        systemctl --no-block stop "x11vnc@$u.service" || true
    done < <(instances)
    systemctl enable "x11vnc@$user.service" || die "x11vnc@$user.service не включился"
    systemctl --no-block restart "x11vnc@$user.service" \
        || die "x11vnc@$user.service не поставлен в очередь перезапуска"
    log "x11vnc@$user.service: перезапуск поставлен в очередь (journalctl -u x11vnc@$user)"
    if [[ "${X11VNC_LISTEN:-localhost}" != localhost && -f "$NOPW" ]]; then
        log "X11VNC_LISTEN=${X11VNC_LISTEN} без пароля: рабочий стол открыт всей сети"
    fi
}

remove(){
    local u
    while read -r u; do
        [[ -n "$u" ]] || continue
        systemctl disable "x11vnc@$u.service" || log "x11vnc@$u.service не выключился"
        systemctl --no-block stop "x11vnc@$u.service" || true
    done < <(instances)
    if [[ ! -L "$DIR" ]]; then
        rm -f -- "$NOPW"
        # Only the file this configure built; one left by an older version stays.
        if [[ -f "$PASSFILE" && ! -L "$PASSFILE" && -f "$OURS" ]] \
            && [[ "$(sha256sum < "$PASSFILE")" == "$(cat "$OURS")" ]]; then
            rm -f -- "$PASSFILE"
        fi
        rmdir -- "$DIR" 2>/dev/null || true
    fi
    rm -f -- "$OURS"
}

case "${1:-}" in
    configure) configure ;;
    remove) remove ;;
    *) die "usage: x11vnc.sh configure|remove" ;;
esac
