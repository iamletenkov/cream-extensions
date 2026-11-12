# shellcheck shell=bash
# x-session.sh — the X session of a user on seat0: which logind session, which
# display, which X authority. Sourced, never executed.
#
# ONE COPY IN GIT: lib/x-session.sh (spec 2026-11-12-existing-desktop §4.2). The
# snapshot and tools/stage-catalog.sh lay it into files/x-session.sh of every
# consumer of lib/x-session.consumers; a hook or a wrapper does
#
#   source "${CREAM_EXT_DIR:?run by cream}/files/x-session.sh"
#
# WHY. A desktop the installer of the OS put there (GDM, LightDM, SDDM) opens
# the session of the person who logs in, not necessarily on :0, and only an X11
# session can be captured. logind knows the session; its properties are read
# one by one (`show-user -p Sessions`, `show-session -p …`) — the columns of
# `list-sessions` differ between systemd versions and are never parsed.
#
#   xs_seat0_session USER
#       "<sid> <type> <display> <state>" of USER's local session on seat0
#       (Seat=seat0, Class=user, Remote=no); an active one before an online one,
#       a closing one never. An empty field is "-". 0 — found; 1 — none, or no
#       logind (nothing printed).
#   xs_seat0_active
#       "<user> <type> <class>" of the active session of seat0 — for a diagnosis
#       ("bob is on the screen", "the greeter is"). 0 — found; 1 — none.
#   xs_find_display USER
#       The display of USER's X session: logind Display of an x11 session;
#       empty — fallback 1, an Xorg owned by USER whose first argument is :N;
#       nothing — fallback 2, :0 when an authority of USER opens it. The path
#       taken goes to stderr. 0 — printed; 1 — none (yet); 2 — USER's seat0
#       session is Wayland (no display is looked for: it cannot be captured).
#   xs_find_authority USER DISPLAY
#       The first X authority that opens DISPLAY for USER (xdpyinfo):
#       ~/.Xauthority, /run/user/<uid>/gdm/Xauthority,
#       /run/lightdm/<user>/xauthority, then the -auth of every Xorg. 0 —
#       printed; 1 — none.
#
# USER arrives checked by the consumer (its key pattern, the uid rule); here it
# is checked again only as a name — never an option, a path or a word for a
# shell — and goes to every command as a separate argument. Paths of the machine
# go under $CREAM_ROOT (tests on a substituted root). The caller's
# log_info is used when defined, plain stderr otherwise. Library code sets no
# shell options and prints nothing but its result to stdout.

_xs_root(){ local r="${CREAM_ROOT:-}"; printf '%s' "${r%/}"; }

_xs_info(){
    if declare -F log_info >/dev/null; then log_info "$@"; else >&2 echo "[INFO] ${CREAM_EXT:-x-session}: $*"; fi
}

# _xs_name_ok NAME: a user name as passwd keeps it — not an option, no path.
_xs_name_ok(){ [[ "${1:-}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}$ ]]; }

_xs_display_ok(){ [[ "${1:-}" =~ ^:[0-9]+(\.[0-9]+)?$ ]]; }

# _xs_passwd USER: "<uid> <home>" from passwd; 1 — no such user.
_xs_passwd(){
    local line uid home
    line="$(getent passwd "$1" 2>/dev/null)" || return 1
    uid="$(cut -d: -f3 <<< "$line")"
    home="$(cut -d: -f6 <<< "$line")"
    [[ "$uid" =~ ^[0-9]+$ && "$home" == /* ]] || return 1
    printf '%s %s\n' "$uid" "$home"
}

# _xs_cmdline_arg PID N: argument N (0 — the program) of a process.
_xs_cmdline_arg(){
    local f
    f="$(_xs_root)/proc/$1/cmdline"
    [[ -r "$f" ]] || return 1
    tr '\0' '\n' < "$f" 2>/dev/null | sed -n "$(( $2 + 1 ))p"
}

xs_seat0_session(){
    local user="${1:-}" out sid line k v seat class type display state remote online=""
    _xs_name_ok "$user" || return 1
    command -v loginctl >/dev/null 2>&1 || return 1
    out="$(loginctl show-user -p Sessions -- "$user" 2>/dev/null)" || return 1
    out="$(sed -n 's/^Sessions=//p' <<< "$out")"
    for sid in $out; do
        [[ "$sid" =~ ^[A-Za-z0-9_-]+$ ]] || continue
        line="$(loginctl show-session -p Seat -p Class -p Type -p Display -p State -p Remote -- "$sid" 2>/dev/null)" \
            || continue
        seat=""; class=""; type=""; display=""; state=""; remote=""
        while IFS='=' read -r k v; do
            case "$k" in
                Seat) seat="$v" ;;
                Class) class="$v" ;;
                Type) type="$v" ;;
                Display) display="$v" ;;
                State) state="$v" ;;
                Remote) remote="$v" ;;
            esac
        done <<< "$line"
        [[ "$seat" == seat0 && "$class" == user && "$remote" == no ]] || continue
        _xs_display_ok "$display" || display=-
        [[ "$type" =~ ^[a-z0-9_-]+$ ]] || type=-
        case "$state" in
            active)
                printf '%s %s %s %s\n' "$sid" "$type" "$display" "$state"
                return 0
                ;;
            online) [[ -n "$online" ]] || online="$sid $type $display $state" ;;
        esac
    done
    [[ -n "$online" ]] || return 1
    printf '%s\n' "$online"
}

xs_seat0_active(){
    local out sid line k v name="" type="" class=""
    command -v loginctl >/dev/null 2>&1 || return 1
    out="$(loginctl show-seat -p ActiveSession -- seat0 2>/dev/null)" || return 1
    sid="$(sed -n 's/^ActiveSession=//p' <<< "$out")"
    [[ "$sid" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    line="$(loginctl show-session -p Name -p Type -p Class -- "$sid" 2>/dev/null)" || return 1
    while IFS='=' read -r k v; do
        case "$k" in
            Name) name="$v" ;;
            Type) type="$v" ;;
            Class) class="$v" ;;
        esac
    done <<< "$line"
    _xs_name_ok "$name" || return 1
    [[ "$type" =~ ^[a-z0-9_-]+$ ]] || type=-
    [[ "$class" =~ ^[a-z0-9_-]+$ ]] || class=-
    printf '%s %s %s\n' "$name" "$type" "$class"
}

xs_find_display(){
    local user="${1:-}" s sid type display state pw uid pids pid arg
    _xs_name_ok "$user" || return 1
    if s="$(xs_seat0_session "$user")"; then
        read -r sid type display state <<< "$s"
        if [[ "$type" == wayland ]]; then
            return 2
        fi
        if [[ "$type" == x11 ]] && _xs_display_ok "$display"; then
            _xs_info "дисплей $display: сеанс $sid пользователя $user на seat0 (logind Display)"
            printf '%s\n' "$display"
            return 0
        fi
    fi
    pw="$(_xs_passwd "$user")" || return 1
    uid="${pw%% *}"
    # Fallback 1: an Xorg of the user (rootless GDM, startx) with :N first.
    pids="$(pgrep -u "$uid" -x Xorg 2>/dev/null)" || pids=""
    for pid in $pids; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        arg="$(_xs_cmdline_arg "$pid" 1)" || continue
        if [[ "$arg" =~ ^:[0-9]+$ ]]; then
            _xs_info "дисплей $arg: Xorg $pid пользователя $user (в logind Display пуст)"
            printf '%s\n' "$arg"
            return 0
        fi
    done
    # Fallback 2: what the wrappers did before — :0, when it opens.
    if xs_find_authority "$user" :0 >/dev/null; then
        _xs_info "дисплей :0: запасной путь — authority пользователя $user открывает :0 (logind и Xorg не дали дисплея)"
        printf ':0\n'
        return 0
    fi
    return 1
}

xs_find_authority(){
    local user="${1:-}" display="${2:-}" r pw uid home pids pid c auth
    _xs_name_ok "$user" || return 1
    _xs_display_ok "$display" || return 1
    pw="$(_xs_passwd "$user")" || return 1
    uid="${pw%% *}"; home="${pw#* }"
    r="$(_xs_root)"
    local -a candidates=(
        "$r$home/.Xauthority"
        "$r/run/user/$uid/gdm/Xauthority"
        "$r/run/lightdm/$user/xauthority"
    )
    pids="$(pgrep -x Xorg 2>/dev/null)" || pids=""
    for pid in $pids; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        auth="$(tr '\0' '\n' < "$r/proc/$pid/cmdline" 2>/dev/null | awk '/^-auth$/{getline; print; exit}')" || auth=""
        [[ "$auth" == /* ]] && candidates+=("$r$auth")
    done
    for c in "${candidates[@]}"; do
        [[ -f "$c" && -r "$c" ]] || continue
        if env XAUTHORITY="$c" xdpyinfo -display "$display" >/dev/null 2>&1; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}
