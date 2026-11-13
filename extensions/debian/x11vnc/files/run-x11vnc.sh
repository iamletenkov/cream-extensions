#!/usr/bin/env bash
# Start x11vnc for a session, resolving the display and the X authority at
# runtime.
#
# 6.0.0: the display (X11VNC_DISPLAY auto: logind Display of the user's X11
# session on seat0, else his Xorg, else :0 confirmed by his own authority) and
# the authority candidates below live in lib/x-session.sh (files/x-session.sh,
# xs_find_display / xs_find_authority), shared with selkies. The measurements
# that follow are why the candidates are what they are.
#
# WHY A WRAPPER AND NOT A PATH IN THE UNIT. The unit used to hardcode
#
#     -auth /var/run/lightdm/%i/:0
#
# and that path does not exist under ANY display manager. It is a splice of
# two different LightDM schemes (measured 2026-09-03 against lightdm sources,
# 1.2 through 1.32 — unchanged throughout):
#
#   * src/x-server-local.c, write_authority_file() → <run-dir>/root/:0.
#     That is the X SERVER's authority: directory `root`, owner root, 0600.
#     A `User=%i` unit cannot read it. This is where the `:0` filename came
#     from.
#   * src/session.c → the USER's authority is ~/.Xauthority by default, and
#     <run-dir>/<user>/xauthority only when user-authority-in-system-dir=true.
#     Debian ships that setting commented out, i.e. false.
#
# So the old unit was broken for xfce4 and lxde too, not just for GNOME —
# and it failed silently: XOpenDisplay fails, Restart=on-failure fires every
# five seconds forever, nothing ever listens on the port.
#
# Under GDM the file is somewhere else again — /run/user/<uid>/gdm/Xauthority
# (gdm/daemon/gdm-x-session.c, same in gdm 43/46/48).
#
# ЗАМЕРЕНО НА ЖИВОЙ ВМ (debian 12, 2026-09-03), оба дисплей-менеджера подряд
# на одной машине — сначала GDM, потом LightDM после переключения симлинка
# display-manager.service:
#
#                        GDM                        LightDM
#   Xorg -auth           /run/user/1000/gdm/…       /var/run/lightdm/root/:0
#   authority юзера      то же                      /home/check/.Xauthority
#   /var/run/lightdm/<user>/:0   нет                НЕТ  ← старый путь юнита
#   выбор обёртки        кандидат 2                 кандидат 1
#   NRestarts            0                          0
#
# Каталог `root` под LightDM существует — это authority X-СЕРВЕРА, 0600 root.
# Каталога с именем пользователя нет ни под одним менеджером. Склейка
# подтверждена: юнит был сломан и под GNOME, и под Xfce.
#
# WHY NOT `-auth guess`. It looks like the answer, but its FINDDISPLAY script
# (extracted from the binary) globs only ~/.Xauthority, /tmp/.gdm*,
# /tmp/.Xauth*, /var/run/gdm*/auth-for-*/database and auth-cookie-*. The
# GDM >= 42 path is not in that list, and auth-for-* is the legacy layout that
# modern GDM does not use. `man x11vnc` also warns FINDDISPLAY can hang
# forever on xdpyinfo when a greeter holds the server — exactly the broken
# autologin case.
#
# Это тоже замерено, а не выведено. На той же ВМ под GDM:
#
#     $ sudo -u check x11vnc -findauth
#     xauth:  file /home/check/.Xauthority does not exist
#     XAUTHORITY=
#
# Пусто. `-auth guess` под GDM не находит ничего, то есть обёртка обязательна,
# а не сделана про запас.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} x11vnc: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} x11vnc: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} x11vnc: $*"; }

# Paths of the machine go under $CREAM_ROOT (hooktest); empty on a machine.
R="${CREAM_ROOT:-}"; R="${R%/}"

# The password decision, built by configure (files/x11vnc.sh): the rfbauth file
# (0600, owned by this user), or -nopw — only with the marker nopw (derived by
# configure) AND X11VNC_ALLOW_NO_PASSWORD=1 in the root-owned config, with a
# warning on every start. Anything else, or a file this user cannot read: a
# refusal, never -nopw.
PASSFILE="$R/etc/x11vnc/passwd"
NOPW="$R/etc/x11vnc/nopw"

# decide_auth: prints the -rfbauth/-nopw argument, or "refuse" with status 78:
# every refusal is a state configure fixes (it builds the file or the marker and
# restarts the instance), so the unit does not loop (RestartPreventExitStatus=78).
decide_auth(){
    if [[ -e "$PASSFILE" || -L "$PASSFILE" ]]; then
        if [[ -f "$PASSFILE" && -r "$PASSFILE" ]]; then
            echo "-rfbauth $PASSFILE"; return 0
        fi
        log_error "файл пароля $PASSFILE не читается пользователем $(id -un)"
        log_error "сервер без пароля не поднимаю: пароль задан X11VNC_PASSWORD"
        log_error "починить: sudo cream configure x11vnc"
        echo refuse; return 78
    fi
    if [[ -f "$NOPW" && "${X11VNC_ALLOW_NO_PASSWORD:-0}" == 1 ]]; then
        # Owner's ruling 2026-11-12: without a password only on the loopback;
        # 78 — the unit does not restart it (RestartPreventExitStatus=78).
        if [[ "${X11VNC_LISTEN:-localhost}" != localhost ]]; then
            log_error "без пароля x11vnc допустим только на петле, а X11VNC_LISTEN=$X11VNC_LISTEN — не запускаюсь"
            log_error "задайте пароль (echo 'пароль' | sudo cream set x11vnc X11VNC_PASSWORD=-) или верните sudo cream set x11vnc X11VNC_LISTEN=localhost"
            echo refuse; return 78
        fi
        log_warn "сервер БЕЗ ПАРОЛЯ: X11VNC_ALLOW_NO_PASSWORD=1 (снять: cream set x11vnc X11VNC_ALLOW_NO_PASSWORD=0)"
        echo "-nopw"; return 0
    fi
    if [[ -f "$NOPW" ]]; then
        log_error "есть $NOPW, но X11VNC_ALLOW_NO_PASSWORD не 1 — без пароля не поднимаю"
        echo refuse; return 78
    fi
    log_error "нет ни $PASSFILE, ни решения «без пароля» ($NOPW) — configure x11vnc не отработал"
    echo refuse; return 78
}

# Test entry: the password decision alone, on given paths.
if [[ "${1:-}" == --decide-auth ]]; then
    PASSFILE="${2:?}"; NOPW="${3:?}"
    decide_auth
    exit
fi

# X11VNC_USER is the key of configure (whose instance to start), not x11vnc's.
unset X11VNC_USER

USERNAME="${1:?usage: run-x11vnc.sh <user>}"
# The uid rule (spec 2026-11-12-existing-desktop, ruling Р3) — before logind
# or X are asked anything, and the name is checked before it is logged: 78, a
# unit of a system account is a setting to fix, not a restart loop.
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
    || { log_error "x11vnc@<имя>: имя пользователя не подходит — не запускаюсь"; exit 78; }
PW_LINE="$(getent passwd "$USERNAME" 2>/dev/null)" \
    || { log_error "нет пользователя $USERNAME в passwd — не запускаюсь"; exit 78; }
UID_OF_USER="$(cut -d: -f3 <<< "$PW_LINE")"
if [[ ! "$UID_OF_USER" =~ ^[0-9]+$ ]] || (( UID_OF_USER < 1000 || UID_OF_USER >= 65534 )); then
    log_error "x11vnc@$USERNAME: uid $UID_OF_USER вне 1000..65533 — системная учётка (root, менеджер входа), её экран не показываю"
    log_error "пользователь сеанса: sudo cream set x11vnc X11VNC_USER=<имя>"
    exit 78
fi

# Параметры приходят из EnvironmentFile /etc/cream/x11vnc/config (домен x11vnc,
# config.keys манифеста; секретов там нет — пароль только в файле выше).
# Умолчания здесь — последний рубеж на случай отсутствующего файла; они равны
# умолчаниям манифеста (рулинг Р4): cream пишет в config только заданные ключи.
PORT="${X11VNC_PORT:-5900}"
WANT_DISPLAY="${X11VNC_DISPLAY:-auto}"
LISTEN="${X11VNC_LISTEN:-localhost}"
[[ "$WANT_DISPLAY" =~ ^(auto|:[0-9]+(\.[0-9]+)?)$ ]] \
    || { log_error "X11VNC_DISPLAY=$(printf '%q' "$WANT_DISPLAY"): нужно auto или :N — не запускаюсь"; exit 78; }

# The password first: without it there is nothing to wait for.
auth="$(decide_auth)" || exit "$?"

XS_LIB="$R/opt/cream/ext/x11vnc/files/x-session.sh"
[[ -f "$XS_LIB" ]] || { log_error "нет $XS_LIB — дерево расширения неполное (снимок каталога кладёт lib/x-session.sh)"; exit 1; }
# shellcheck source=../../../../lib/x-session.sh
source "$XS_LIB"

# wayland_exit: 78 (EX_CONFIG) — the session type is a setting of the display
# manager, a restart every 5 s would not change it (RestartPreventExitStatus=78).
# x11vnc's own guard looks at $WAYLAND_DISPLAY, absent from a system unit, and
# the socket X0 is there under Wayland too (mutter's Xwayland): logind's
# session Type is asked instead (lib/x-session.sh).
wayland_exit(){
    log_error "сессия '$USERNAME' на Wayland — x11vnc обслуживает только X.Org, служба остановлена"
    log_error "включите Xorg у менеджера входа (расширение gdm-xorg — Xorg у GDM; gnome пишет WaylandEnable=false), войдите заново"
    log_error "и запустите: sudo systemctl restart x11vnc@$USERNAME"
    exit 78
}

# seat0_note: one line on who is on seat0 while we wait.
seat0_note(){
    local a name type class
    if ! a="$(xs_seat0_active)"; then
        log_info "на seat0 нет активного сеанса (или нет logind) — жду вход '$USERNAME'"
        return 0
    fi
    read -r name type class <<< "$a"
    if [[ "$class" != user ]]; then
        log_info "на seat0 экран входа ($class) — жду вход '$USERNAME' (или DESKTOP_AUTOLOGIN=1 расширения desktop)"
    elif [[ "$name" != "$USERNAME" ]]; then
        log_info "на seat0 сеанс $name ($type), x11vnc ждёт $USERNAME: sudo cream set x11vnc X11VNC_USER=$name"
    else
        log_info "на seat0 сеанс $name ($type) — его дисплей пока не открывается"
    fi
}

# find_session: sets DISPLAY_NUM and AUTH; 1 — not (yet); exits 78 on Wayland.
# The library journals its path and why an authority is missing; a try every
# 5 s would put a line there every 5 s, so one try in 5 minutes speaks and the
# rest are XS_QUIET (ruling П27б). QUIET_TRY — the last try was silent.
find_session(){
    local s rc=0
    QUIET_TRY=1
    if (( waited % 300 == 0 )); then QUIET_TRY=""; fi
    if [[ "$WANT_DISPLAY" == auto ]]; then
        DISPLAY_NUM="$(XS_QUIET="$QUIET_TRY" xs_find_display "$USERNAME")" || rc=$?
        (( rc != 2 )) || wayland_exit
        (( rc == 0 )) || return 1
    else
        if s="$(xs_seat0_session "$USERNAME")" && [[ "$(cut -d' ' -f2 <<< "$s")" == wayland ]]; then
            wayland_exit
        fi
        DISPLAY_NUM="$WANT_DISPLAY"
    fi
    AUTH="$(XS_QUIET="$QUIET_TRY" xs_find_authority "$USERNAME" "$DISPLAY_NUM")"
}

# Until the user's X session is there — waiting, a line in the journal every
# 5 minutes (not a restart loop of the unit).
DISPLAY_NUM=""; AUTH=""; waited=0; QUIET_TRY=""
until find_session; do
    if (( waited % 300 == 0 )); then
        log_info "жду X-сессию '$USERNAME' (дисплей $WANT_DISPLAY; без DESKTOP_AUTOLOGIN=1 она появится после входа человека)"
        seat0_note
    fi
    sleep 5; waited=$((waited + 5))
done
# Found on a silent try: the path the library took goes to the journal once.
if [[ -n "$QUIET_TRY" && "$WANT_DISPLAY" == auto ]]; then
    xs_find_display "$USERNAME" > /dev/null || true
fi
log_info "дисплей $DISPLAY_NUM, authority $AUTH"

# No -loop: x11vnc ends with its X session, the unit restarts the wrapper
# (Restart=always), and the wrapper finds the new session — after a logout and
# login it may be on another display, which -loop would never look for.
#
# -display unix:N, not :N: libX11 with ":N" falls back to TCP 6000+N when the
# unix socket is missing, and someone else's listener there would get our
# cookie (issue #139 item 2, defence in depth).
args=(
    -display "unix$DISPLAY_NUM"
    -auth "$AUTH"
    -forever -noxdamage -repeat -shared
    -rfbport "$PORT"
)

# Слушать только петлю — умолчание, и это СМЕНА поведения.
#
# Раньше сервер поднимался на всех интерфейсах без пароля, а compose-примеры
# ставят `firewall: false`. Позиция проекта на этот счёт записана в
# examples/build/ubuntu1804/README.md: только loopback, доступ через
# SSH-туннель. Расширение с ней расходилось.
if [[ "$LISTEN" == "localhost" ]]; then
    args+=(-localhost)
else
    log_warn "слушаю ВСЕ интерфейсы (X11VNC_LISTEN=$LISTEN)"
fi
if [[ "$auth" == -nopw ]]; then
    args+=(-nopw)
else
    args+=(-rfbauth "$PASSFILE")
    log_info "пароль из $PASSFILE"
fi

exec "$R/usr/bin/x11vnc" "${args[@]}"
