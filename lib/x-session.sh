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
#       empty — fallback 1, an Xorg owned by USER: :N bound to it by
#       /tmp/.X<N>-lock holding its pid, owned by root or USER and writable by
#       nobody else — :N from its argv (startx) or the lock alone (ruling П13);
#       no lock holds it (GDM runs `Xorg vtN -displayfd 3` and writes none —
#       measured, ruling П27б) — :N of its own listening sockets, exactly one
#       N among them and no inode of its on two lines (_xs_own_display); then
#       both listeners of X<N>, the file and the abstract name xcb tries
#       first, its fds and nobody else's (_xs_x_held; a socket name alone
#       proves nothing — /proc/net/unix prints any abstract name, newlines
#       included). Then an Xorg of ROOT under USER's x11 session on seat0
#       (GDM through Xorg.wrap: L4T, no KMS — _xs_root_xorgs): /proc/<pid>
#       root's, a descendant of the session's Leader (logind), its -auth a
#       file of USER nobody else writes. Its fds are not readable by USER: the
#       proof that binds X<N> to it is the kernel's — the socket file of X<N>
#       is root's or USER's, both listeners answer and SO_PEERCRED of each is
#       its pid with the uid owning /proc/<pid> (_xs_peer_held, perl Socket;
#       the probe writes nothing), N the one display it serves so (lock-file
#       first, as above);
#       nothing — fallback 2, :0, only when a real X server of root or USER
#       serves it (_xs_served: lock, live Xorg, socket, both listeners its
#       fds — only by fds: no cookie for a fake server on a free :0, a taken
#       abstract name, or a root Xorg of another console session).
#       A display of either fallback counts only when USER's own authority
#       opens it over unix:N (no TCP fallback) and it has access control
#       (_xs_confirm). The path taken goes to stderr. 0 — printed; 1 — none
#       (yet); 2 — USER's seat0 session is Wayland (no display is looked for:
#       it cannot be captured).
#   xs_find_authority USER DISPLAY
#       The first X authority that opens DISPLAY for USER (xdpyinfo on unix:N):
#       ~/.Xauthority, /run/user/<uid>/gdm/Xauthority,
#       /run/lightdm/<user>/xauthority, /tmp/xauth_* of SDDM (only a regular
#       file of USER's uid, mode 0600 or narrower — _xs_private, ruling П27б),
#       then the -auth of every Xorg. 0 — printed; 1 — none (said in the
#       journal).
#
# USER arrives checked by the consumer (its key pattern, the uid rule); here it
# is checked again only as a name — never an option, a path or a word for a
# shell — and goes to every command as a separate argument. Paths of the machine
# go under $CREAM_ROOT (tests on a substituted root). The caller's
# log_info is used when defined, plain stderr otherwise; XS_QUIET non-empty —
# no journal at all (a wrapper waiting for the session asks every 5 s and lets
# one try in 5 minutes speak, ruling П27б). Library code sets no shell options
# and prints nothing but its result to stdout.

_xs_root(){ local r="${CREAM_ROOT:-}"; printf '%s' "${r%/}"; }

_xs_info(){
    [[ -z "${XS_QUIET:-}" ]] || return 0
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

# _xs_trusted FILE UID…: FILE is a regular file (not a link) owned by one of
# the UIDs and not writable by its group or others. /tmp is writable by
# everyone: a file there counts only when nobody else could have put it.
_xs_trusted(){
    local f="$1" owner mode u
    shift
    [[ -f "$f" && ! -L "$f" ]] || return 1
    read -r owner mode < <(stat -c '%u %a' -- "$f" 2>/dev/null) || return 1
    [[ "$owner" =~ ^[0-9]+$ && "$mode" =~ ^[0-7]+$ ]] || return 1
    (( (8#$mode & 8#022) == 0 )) || return 1
    for u in "$@"; do [[ "$owner" == "$u" ]] && return 0; done
    return 1
}

# _xs_private FILE UID: FILE is a regular file (not a link) of UID alone —
# owned by UID, nothing for its group or others (0600 or narrower). The
# /tmp/xauth_* of SDDM lies in /tmp, where anyone creates files: only UID (or
# root) could have made a file UID owns, and a cookie others may read is not
# the session's own.
_xs_private(){
    local f="$1" uid="$2" owner mode
    [[ -f "$f" && ! -L "$f" && "$uid" =~ ^[0-9]+$ ]] || return 1
    read -r owner mode < <(stat -c '%u %a' -- "$f" 2>/dev/null) || return 1
    [[ "$owner" == "$uid" && "$mode" =~ ^[0-7]+$ ]] || return 1
    (( (8#$mode & 8#077) == 0 ))
}

# _xs_pid_sockets PID: the socket inodes among the fds of PID, one per line;
# 1 — /proc/PID/fd is not readable (a process of another uid).
_xs_pid_sockets(){
    local r f line
    r="$(_xs_root)"
    [[ "$1" =~ ^[0-9]+$ && -d "$r/proc/$1/fd" && -r "$r/proc/$1/fd" && -x "$r/proc/$1/fd" ]] || return 1
    for f in "$r/proc/$1/fd"/*; do
        line="$(readlink -- "$f" 2>/dev/null)" || continue
        [[ "$line" =~ ^socket:\[([0-9]+)\]$ ]] && printf '%s\n' "${BASH_REMATCH[1]}"
    done
    return 0
}

# _xs_x_listeners N: "<inode> <path>" of every listening unix socket
# /tmp/.X11-unix/X<N> or abstract @/tmp/.X11-unix/X<N> in /proc/net/unix.
# The kernel prints a socket name as it is: an abstract name with a newline
# adds a line of anyone's choice, and the inodes of all sockets are there to
# copy. A line is never proof alone (the caller binds the inode to the fds of
# its Xorg), and an inode of X<N> on two lines means a forged one — 1, as when
# /proc/net/unix is not readable.
_xs_x_listeners(){
    local want="$1" r line i
    local -a fields=() lines=()
    local -A seen=()
    r="$(_xs_root)"
    [[ "$want" =~ ^[0-9]+$ && -r "$r/proc/net/unix" ]] || return 1
    mapfile -t lines < "$r/proc/net/unix" || return 1
    for line in "${lines[@]}"; do
        read -r -a fields <<< "$line"
        (( ${#fields[@]} >= 7 )) || continue
        i="${fields[6]}"
        [[ "$i" =~ ^[0-9]+$ ]] || continue
        seen[$i]=$(( ${seen[$i]:-0} + 1 ))
    done
    for line in "${lines[@]}"; do
        read -r -a fields <<< "$line"
        (( ${#fields[@]} >= 8 )) || continue
        # __SO_ACCEPTCON and SS_UNCONNECTED: a listening socket.
        [[ "${fields[3]}" == 00010000 && "${fields[5]}" == 01 && "${fields[6]}" =~ ^[0-9]+$ ]] || continue
        [[ "${fields[7]}" =~ ^@?/tmp/\.X11-unix/X([0-9]+)$ && "${BASH_REMATCH[1]}" == "$want" ]] || continue
        (( ${seen[${fields[6]}]} == 1 )) || return 1
        printf '%s %s\n' "${fields[6]}" "${fields[7]}"
    done
    return 0
}

# _xs_peer NAME: "<pid> <uid>" of the process that listens on the unix socket
# NAME (a path, or @name — abstract), as the kernel tells (SO_PEERCRED of a
# connection: the credentials the listener had at listen()). Readable by
# anyone, unlike the fds of a root process. The probe connects and closes —
# it writes nothing, so no cookie and no request goes anywhere. perl: perl-base
# is Essential on Debian and Ubuntu, its Socket has SO_PEERCRED; PERL5LIB and
# PERL5OPT are dropped. An abstract name goes under $CREAM_ROOT like a path
# (tests on a substituted root; on a machine the root is empty). 1 — no
# perl, nobody listens, no answer in 3 s, or pid 0 (another pid namespace).
_xs_peer(){
    local name="$1" out
    [[ "$name" == /* || "$name" == @/* ]] || return 1
    if ! command -v perl >/dev/null 2>&1; then
        _xs_info "нет perl — слушателя ${name##*/} не спросить (SO_PEERCRED), Xorg root не принимаю"
        return 1
    fi
    # shellcheck disable=SC2016  # perl code, not shell
    out="$(env -u PERL5LIB -u PERL5OPT -u PERLLIB perl -e '
        use strict; use warnings;
        use Socket qw(PF_UNIX SOCK_STREAM SOL_SOCKET SO_PEERCRED pack_sockaddr_un);
        my $n = $ARGV[0];
        $n =~ s/^\@/\0/;
        $SIG{ALRM} = sub { exit 1 };
        alarm 3;
        socket(my $s, PF_UNIX, SOCK_STREAM, 0) or exit 1;
        connect($s, pack_sockaddr_un($n)) or exit 1;
        my $c = getsockopt($s, SOL_SOCKET, SO_PEERCRED) or exit 1;
        my ($pid, $uid) = unpack("l L", $c);
        close($s);
        print "$pid $uid\n";
    ' -- "$name" 2>/dev/null)" || return 1
    [[ "$out" =~ ^[1-9][0-9]*\ [0-9]+$ ]] || return 1
    printf '%s\n' "$out"
}

# _xs_peer_held N PID UID: PID serves X<N>, proven by the kernel — the socket
# file /tmp/.X11-unix/X<N> (a socket, not a link, of root or UID) and the
# abstract @/tmp/.X11-unix/X<N> both answer, and SO_PEERCRED of each is PID
# with the uid that owns /proc/PID (root or UID) (_xs_peer). For a root Xorg
# whose fds USER cannot read. SO_PEERCRED keeps the pid of listen() after the
# listener is gone: a stranger's listeners may carry the pid of the Xorg
# (pid_max wrap) — but not its uid, and the file of X<N> is not root's or
# UID's. The owner is checked before any probe: a socket file of another user
# is not even connected to (nor are hundreds of them). While PID lives, nobody
# else can bind its abstract name, and its socket file lies in the sticky
# /tmp/.X11-unix, where only its owner or root may remove it. 1 — a listener
# missing, one of another process or uid, a foreign socket file, no UID, no
# perl.
_xs_peer_held(){
    local n="$1" pid="$2" uid="${3:-}" r sock out owner who
    r="$(_xs_root)"
    [[ "$n" =~ ^[0-9]+$ && "$pid" =~ ^[1-9][0-9]*$ && "$uid" =~ ^[0-9]+$ ]] || return 1
    sock="$r/tmp/.X11-unix/X$n"
    [[ -S "$sock" && ! -L "$sock" ]] || return 1
    read -r owner _ < <(stat -c '%u %a' -- "$sock" 2>/dev/null) || return 1
    [[ "$owner" == 0 || "$owner" == "$uid" ]] || return 1
    read -r who _ < <(stat -c '%u %a' -- "$r/proc/$pid" 2>/dev/null) || return 1
    [[ "$who" == 0 || "$who" == "$uid" ]] || return 1
    out="$(_xs_peer "$sock")" || return 1
    [[ "$out" == "$pid $who" ]] || return 1
    out="$(_xs_peer "@$sock")" || return 1
    [[ "$out" == "$pid $who" ]]
}

# _xs_peer_display PID UID: ":<N>" — the one display PID serves by both its
# listeners, by SO_PEERCRED (_xs_peer_held), N from the socket files of
# /tmp/.X11-unix (a name there proves nothing, the kernel's answer does). 1 —
# none, or two (which one is the session is not known).
_xs_peer_display(){
    local pid="$1" uid="${2:-}" r f n found=""
    r="$(_xs_root)"
    for f in "$r"/tmp/.X11-unix/X*; do
        n="${f##*/X}"
        [[ "$n" =~ ^[0-9]{1,4}$ ]] || continue
        _xs_peer_held "$n" "$pid" "$uid" || continue
        [[ -z "$found" ]] || return 1
        found="$n"
    done
    [[ -n "$found" ]] || return 1
    printf ':%s\n' "$found"
}

# _xs_x_held N PID [UID]: PID serves X<N> by its sockets — X<N> has listeners,
# every one is among PID's fds (inode in /proc/net/unix against /proc/PID/fd),
# and they are both: the socket file and the abstract @/tmp/.X11-unix/X<N>.
# xcb connects to the abstract name first, and with no unix listener at all it
# would go to TCP 127.0.0.1:6000+N — whoever listens there gets the cookie.
# The fds of PID not readable (a root Xorg, USER's wrapper) — the kernel is
# asked instead (_xs_peer_held, SO_PEERCRED), only when UID is given: the
# caller has already bound PID to USER's session (_xs_root_xorgs). 1 — no
# listener, one of another process, one kind missing, or nothing to check them
# against (no /proc/net/unix, a forged line, no UID, no perl).
_xs_x_held(){
    local n="$1" pid="$2" uid="${3:-}" out ln inode path file="" abstract=""
    local -a mine=() listeners=()
    if ! _xs_pid_sockets "$pid" >/dev/null; then
        _xs_peer_held "$n" "$pid" "$uid"
        return
    fi
    out="$(_xs_x_listeners "$n")" || return 1
    [[ -n "$out" ]] || return 1
    mapfile -t listeners <<< "$out"
    out="$(_xs_pid_sockets "$pid")" || return 1
    mapfile -t mine <<< "$out"
    for ln in "${listeners[@]}"; do
        read -r inode path <<< "$ln"
        [[ " ${mine[*]} " == *" $inode "* ]] || return 1
        if [[ "$path" == @* ]]; then abstract=1; else file=1; fi
    done
    [[ -n "$file" && -n "$abstract" ]]
}

# _xs_lock_holds N PID UID: /tmp/.X<N>-lock is trusted (_xs_trusted: a regular
# file of root or UID nobody else writes) and holds PID — the only proof that
# binds N to the process: /tmp is everyone's, /proc/net/unix prints any name.
_xs_lock_holds(){
    local n="$1" pid="$2" uid="$3" r lock c
    r="$(_xs_root)"
    [[ "$n" =~ ^[0-9]+$ && "$pid" =~ ^[0-9]+$ && "$uid" =~ ^[0-9]+$ ]] || return 1
    lock="$r/tmp/.X$n-lock"
    _xs_trusted "$lock" 0 "$uid" || return 1
    c="$(head -c 32 -- "$lock" 2>/dev/null | tr -d ' \n')" || return 1
    [[ "$c" =~ ^[0-9]+$ && "$c" == "$pid" ]]
}

# _xs_own_display PID: ":<N>" — the one display PID listens on by its own
# sockets: the listening lines of /proc/net/unix at /tmp/.X11-unix/X<N> or
# @/tmp/.X11-unix/X<N> whose inode is among the fds of PID. The name of a line
# alone proves nothing (an abstract name with a newline adds a line of
# anyone's choice), the inode does: only PID holds its fds. A forged line may
# still carry an inode of PID — of its listener (then the inode is on two
# lines) or of a socket the list does not show (netlink: then a second N
# appears, the real X<N> is there too). 1 — no such listener, the fds or
# /proc/net/unix not readable, a second N, an inode of PID on two lines.
_xs_own_display(){
    local pid="$1" r out line i n=""
    local -a fields=() lines=()
    local -A mine=() seen=()
    r="$(_xs_root)"
    [[ -r "$r/proc/net/unix" ]] || return 1
    out="$(_xs_pid_sockets "$pid")" || return 1
    [[ -n "$out" ]] || return 1
    while IFS= read -r i; do mine[$i]=1; done <<< "$out"
    mapfile -t lines < "$r/proc/net/unix" || return 1
    for line in "${lines[@]}"; do
        read -r -a fields <<< "$line"
        (( ${#fields[@]} >= 7 )) || continue
        i="${fields[6]}"
        [[ "$i" =~ ^[0-9]+$ && -n "${mine[$i]:-}" ]] || continue
        seen[$i]=$(( ${seen[$i]:-0} + 1 ))
        (( ${seen[$i]} == 1 )) || return 1
        (( ${#fields[@]} >= 8 )) || continue
        # __SO_ACCEPTCON and SS_UNCONNECTED: a listening socket.
        [[ "${fields[3]}" == 00010000 && "${fields[5]}" == 01 ]] || continue
        [[ "${fields[7]}" =~ ^@?/tmp/\.X11-unix/X([0-9]+)$ ]] || continue
        if [[ -z "$n" ]]; then
            n="${BASH_REMATCH[1]}"
        elif [[ "$n" != "${BASH_REMATCH[1]}" ]]; then
            return 1
        fi
    done
    [[ -n "$n" ]] || return 1
    printf ':%s\n' "$n"
}

# _xs_xorg_display PID UID: "<:N> <how>" — the display the Xorg PID of UID
# serves. N is bound to the process by /tmp/.X<N>-lock holding PID
# (_xs_lock_holds: Xorg writes "%10d\n", mode 0444, owned by root or UID and
# writable by nobody else): a) :N anywhere in its argv (startx, an explicit
# display) when its lock holds PID; b) else the lock that holds PID. c) No lock
# holds PID — GDM starts `Xorg vtN -displayfd 3` and writes no lock (measured
# on Ubuntu 24.04, ruling П27б): the one N of its own listening sockets
# (_xs_own_display). d) The fds of PID not readable (a root Xorg, USER's
# wrapper; GDM through Xorg.wrap on L4T, no lock either — measured on Jetson
# AGX Orin 2026-11-16): the one N whose both listeners are PID's by
# SO_PEERCRED (_xs_peer_display). A socket name alone proves nothing:
# /proc/net/unix prints whatever an abstract name holds. 1 — none.
_xs_xorg_display(){
    local pid="$1" uid="$2" r arg f n
    r="$(_xs_root)"
    [[ "$uid" =~ ^[0-9]+$ && -r "$r/proc/$pid/cmdline" ]] || return 1
    while IFS= read -r arg; do
        if [[ "$arg" =~ ^:([0-9]+)$ ]] && _xs_lock_holds "${BASH_REMATCH[1]}" "$pid" "$uid"; then
            printf '%s argv\n' "$arg"
            return 0
        fi
    done < <(tr '\0' '\n' < "$r/proc/$pid/cmdline" 2>/dev/null | tail -n +2)
    for f in "$r"/tmp/.X*-lock; do
        n="${f##*/.X}"; n="${n%-lock}"
        [[ "$n" =~ ^[0-9]+$ ]] || continue
        if _xs_lock_holds "$n" "$pid" "$uid"; then
            printf ':%s lock %s\n' "$n" "${f#"$r"}"
            return 0
        fi
    done
    if _xs_pid_sockets "$pid" >/dev/null; then
        if n="$(_xs_own_display "$pid")"; then
            printf '%s сокеты Xorg (lock-файла нет)\n' "$n"
            return 0
        fi
    elif n="$(_xs_peer_display "$pid" "$uid")"; then
        printf '%s слушатели X по SO_PEERCRED (lock-файла нет, fd Xorg не читаются)\n' "$n"
        return 0
    fi
    return 1
}

# _xs_session_leader SID: the pid of the Leader of a logind session (GDM:
# gdm-x-session of the user; a console login: login). 1 — none.
_xs_session_leader(){
    local out pid
    [[ "${1:-}" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    out="$(loginctl show-session -p Leader -- "$1" 2>/dev/null)" || return 1
    pid="$(sed -n 's/^Leader=//p' <<< "$out")"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "$pid"
}

# _xs_ppid PID: the parent of PID by /proc/PID/stat — the fields after the
# last ")" (comm may hold spaces and parentheses). 1 — none.
_xs_ppid(){
    local r line ppid
    r="$(_xs_root)"
    [[ "${1:-}" =~ ^[0-9]+$ ]] || return 1
    line="$(head -c 4096 -- "$r/proc/$1/stat" 2>/dev/null)" || return 1
    [[ "$line" == *")"* ]] || return 1
    read -r _ ppid _ <<< "${line##*)}"
    [[ "$ppid" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$ppid"
}

# _xs_descends PID ANCESTOR: ANCESTOR is the parent of PID, or its parent's…
# (16 steps at most; pid 1 ends the walk).
_xs_descends(){
    local p="$1" i
    [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || return 1
    for (( i = 0; i < 16; i++ )); do
        p="$(_xs_ppid "$p")" || return 1
        [[ "$p" == "$2" ]] && return 0
        (( p > 1 )) || return 1
    done
    return 1
}

# _xs_root_xorgs SID UID: the Xorg processes of root that serve the session
# SID of UID, one pid per line: /proc/<pid> owned by root, a descendant of the
# Leader of SID (logind — GDM: gdm-x-session of the user, needs_root_rights of
# Xorg.wrap), and its -auth a file of UID nobody else writes (_xs_trusted: the
# server was started for this user — GDM's /run/user/<uid>/gdm/Xauthority,
# startx's ~/.serverauth.*). Which display it serves — _xs_xorg_display.
_xs_root_xorgs(){
    local sid="$1" uid="$2" r leader pids pid owner auth
    local -a pidv=()
    r="$(_xs_root)"
    [[ "$uid" =~ ^[0-9]+$ ]] || return 1
    leader="$(_xs_session_leader "$sid")" || return 1
    pids="$(pgrep -u 0 -x Xorg 2>/dev/null)" || return 1
    mapfile -t pidv <<< "$pids"
    for pid in "${pidv[@]}"; do
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
        read -r owner _ < <(stat -c '%u %a' -- "$r/proc/$pid" 2>/dev/null) || continue
        [[ "$owner" == 0 ]] || continue
        _xs_descends "$pid" "$leader" || continue
        auth="$(tr '\0' '\n' < "$r/proc/$pid/cmdline" 2>/dev/null | awk '/^-auth$/{getline; print; exit}')" || auth=""
        [[ "$auth" == /* ]] || continue
        _xs_trusted "$r$auth" "$uid" || continue
        printf '%s\n' "$pid"
    done
    return 0
}

xs_seat0_session(){
    local user="${1:-}" out sid line k v seat class type display state remote online=""
    local -a sids=()
    _xs_name_ok "$user" || return 1
    command -v loginctl >/dev/null 2>&1 || return 1
    out="$(loginctl show-user -p Sessions -- "$user" 2>/dev/null)" || return 1
    out="$(sed -n 's/^Sessions=//p' <<< "$out")"
    read -r -a sids <<< "$out" || true
    for sid in "${sids[@]}"; do
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

# _xs_served DISPLAY UID: DISPLAY is served by a real X server of root or UID —
# /tmp/.X<N>-lock trusted (_xs_trusted root|UID) holds the pid of a live Xorg
# (comm Xorg or X) whose /proc entry is root's or UID's, and /tmp/.X11-unix/X<N>
# is a socket (not a link) of root or UID. Anyone may create files in /tmp:
# without this, a fake server on a free :0 answering "access control enabled"
# would get USER's MIT cookie from _xs_confirm. 0 — served.
_xs_served(){
    local display="$1" uid="$2" r n lock pid comm sock owner
    r="$(_xs_root)"
    [[ "$uid" =~ ^[0-9]+$ ]] || return 1
    [[ "$display" =~ ^:([0-9]+)(\.[0-9]+)?$ ]] || return 1
    n="${BASH_REMATCH[1]}"
    lock="$r/tmp/.X$n-lock"
    _xs_trusted "$lock" 0 "$uid" || return 1
    pid="$(head -c 32 -- "$lock" 2>/dev/null | tr -d ' \n')" || return 1
    _xs_lock_holds "$n" "$pid" "$uid" || return 1
    [[ -d "$r/proc/$pid" ]] || return 1
    comm="$(head -c 32 -- "$r/proc/$pid/comm" 2>/dev/null)" || return 1
    [[ "$comm" == Xorg || "$comm" == X ]] || return 1
    read -r owner _ < <(stat -c '%u %a' -- "$r/proc/$pid" 2>/dev/null) || return 1
    [[ "$owner" == 0 || "$owner" == "$uid" ]] || return 1
    sock="$r/tmp/.X11-unix/X$n"
    [[ -S "$sock" && ! -L "$sock" ]] || return 1
    read -r owner _ < <(stat -c '%u %a' -- "$sock" 2>/dev/null) || return 1
    [[ "$owner" == 0 || "$owner" == "$uid" ]] || return 1
    # Bound to the process: both listeners of X<N> are this Xorg's fds and
    # nobody else listens there — a free abstract name would be anyone's. Only
    # by fds: a root Xorg here is under no session of USER's — another console
    # user's `startx -- :0` (Xorg.wrap, needs_root_rights) plus `xhost
    # +si:localuser:USER` would pass _xs_confirm. A root Xorg of USER's own
    # session is found by fallback 1 (_xs_root_xorgs), never here.
    _xs_pid_sockets "$pid" >/dev/null || return 1
    _xs_x_held "$n" "$pid"
}

# _xs_confirm USER DISPLAY: a display found without logind is USER's only when
# an authority of USER himself opens it — $XAUTHORITY, ~/.Xauthority, the files
# of his runtime dir (/run/user/<uid>/gdm/Xauthority, xauth_*),
# /run/lightdm/<user>/xauthority — each a regular file of his uid nobody else
# may write — and /tmp/xauth_* of SDDM 0.20, only of his uid and 0600 or
# narrower (_xs_private; never the -auth of some Xorg) — and the display has access control
# (xhost): a server started with -ac opens with any authority, so it proves
# nothing. No xhost — not confirmed. Both connect to unix:N, never :N: with no
# unix listener libxcb falls back to TCP 127.0.0.1:6000+N, an unprivileged
# port anyone may hold, and would hand it the cookie. 0 — confirmed.
_xs_confirm(){
    local user="$1" display="$2" r pw uid home c ac
    _xs_display_ok "$display" || return 1
    local -a candidates=()
    pw="$(_xs_passwd "$user")" || return 1
    uid="${pw%% *}"; home="${pw#* }"
    r="$(_xs_root)"
    [[ "${XAUTHORITY:-}" == /* ]] && candidates+=("$XAUTHORITY")
    candidates+=("$r$home/.Xauthority" "$r/run/user/$uid/gdm/Xauthority")
    for c in "$r/run/user/$uid"/xauth_*; do candidates+=("$c"); done
    candidates+=("$r/run/lightdm/$user/xauthority")
    for c in "$r/tmp"/xauth_*; do candidates+=("$c"); done
    for c in "${candidates[@]}"; do
        # SDDM's /tmp/xauth_*: in /tmp, so the session's uid alone, 0600.
        if [[ "$c" == "$r/tmp/xauth_"* ]]; then
            _xs_private "$c" "$uid" || continue
        elif ! _xs_trusted "$c" "$uid"; then
            continue
        fi
        [[ -r "$c" ]] || continue
        env XAUTHORITY="$c" xdpyinfo -display "unix$display" >/dev/null 2>&1 || continue
        if ! command -v xhost >/dev/null 2>&1; then
            _xs_info "дисплей $display: нет xhost — контроль доступа не проверить, не принимаю"
            return 1
        fi
        # The whole output, then its first line: head would cut xhost with
        # SIGPIPE, and the caller's pipefail would read that as a failure.
        ac="$(env XAUTHORITY="$c" DISPLAY="unix$display" LC_ALL=C xhost 2>/dev/null)" || ac=""
        ac="${ac%%$'\n'*}"
        if [[ "$ac" == "access control enabled"* ]]; then
            return 0
        fi
        _xs_info "дисплей $display: контроль доступа выключен (xhost: ${ac:-нет ответа}) — открывается любым, не принимаю"
        return 1
    done
    return 1
}

xs_find_display(){
    local user="${1:-}" s sid="" type="" display state pw uid pids pid found how n whose
    local -a pidv=()
    local -A rootpid=()
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
    # Fallback 1: an Xorg owned by the user (rootless GDM, startx) — its display
    # bound to it by its lock file (from argv or the lock alone) or its own
    # sockets, served by both its listeners, confirmed by an authority. Then an
    # Xorg of root under the user's seat0 session (GDM through Xorg.wrap: L4T,
    # no KMS) — _xs_root_xorgs; its fds are not readable, the kernel tells who
    # listens (SO_PEERCRED).
    pids="$(pgrep -u "$uid" -x Xorg 2>/dev/null)" || pids=""
    if [[ -n "$sid" && "$type" == x11 ]] && s="$(_xs_root_xorgs "$sid" "$uid")" && [[ -n "$s" ]]; then
        while IFS= read -r pid; do rootpid[$pid]=1; done <<< "$s"
        pids+=$'\n'"$s"
    fi
    mapfile -t pidv <<< "$pids"
    for pid in "${pidv[@]}"; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        found="$(_xs_xorg_display "$pid" "$uid")" || continue
        read -r display how <<< "$found"
        _xs_display_ok "$display" || continue
        n="${display#:}"; n="${n%%.*}"
        if ! _xs_x_held "$n" "$pid" "$uid"; then
            _xs_info "дисплей $display: сокеты X$n (файл и абстрактный) — не оба у Xorg $pid или их не проверить — не принимаю"
            continue
        fi
        whose="пользователя $user"
        [[ -n "${rootpid[$pid]:-}" ]] && whose="(root) сеанса $sid пользователя $user"
        if _xs_confirm "$user" "$display"; then
            _xs_info "дисплей $display: Xorg $pid $whose, $how (в logind Display пуст)"
            printf '%s\n' "$display"
            return 0
        fi
    done
    # Fallback 2: what the wrappers did before — :0, when it opens; the cookie
    # is offered only to a real server of root or the user (_xs_served).
    if ! _xs_served :0 "$uid"; then
        return 1
    fi
    if _xs_confirm "$user" :0; then
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
    # SDDM 0.20: the session's XAUTHORITY is /tmp/xauth_XXXXXX, the -auth of
    # its root Xorg is not readable by the user (measured on Kubuntu 24.04).
    for c in "$r/tmp"/xauth_*; do candidates+=("$c"); done
    pids="$(pgrep -x Xorg 2>/dev/null)" || pids=""
    for pid in $pids; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        auth="$(tr '\0' '\n' < "$r/proc/$pid/cmdline" 2>/dev/null | awk '/^-auth$/{getline; print; exit}')" || auth=""
        [[ "$auth" == /* ]] && candidates+=("$r$auth")
    done
    for c in "${candidates[@]}"; do
        # /tmp is everyone's: an xauth_* there counts only as USER's alone.
        if [[ "$c" == "$r/tmp/xauth_"* ]]; then
            _xs_private "$c" "$uid" || continue
        fi
        [[ -f "$c" && -r "$c" ]] || continue
        # unix:N — no fallback to TCP 6000+N (see _xs_confirm).
        if env XAUTHORITY="$c" xdpyinfo -display "unix$display" >/dev/null 2>&1; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    _xs_info "дисплей $display: ни одна authority пользователя $user его не открывает (~/.Xauthority, /run/user/$uid/gdm, /run/lightdm/$user, /tmp/xauth_* SDDM, -auth Xorg)"
    return 1
}
