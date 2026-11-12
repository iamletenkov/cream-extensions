#!/usr/bin/env bash
# existing-desktop.sh — the desktop of the machine, read and never changed. Run
# by hooks/install, hooks/check and the action status from the tree of the
# extension (/opt/cream/ext/existing-desktop/files/existing-desktop.sh).
#
#   existing-desktop.sh verify   the three parts as files (Xorg, display manager,
#                                X session), each named in the log (stderr);
#                                0 — all there, 1 — a part is missing
#   existing-desktop.sh check    Xorg and the display manager; 0 / 1
#   existing-desktop.sh status   the diagnosis to stdout: the display manager and
#                                `systemctl is-active`, WaylandEnable of gdm3, the
#                                autologin (gdm3, LightDM, SDDM), the session of
#                                seat0 (lib/x-session.sh) — or "нет logind"; 0
#
# verify and check look only at files and call nothing: they run at image build
# too. Everything read from the machine (names of units, sessions, users) is
# data for the log: printable characters only. Paths go under $CREAM_ROOT
# (tests on a substituted root).
set -euo pipefail

R="${CREAM_ROOT:-}"; R="${R%/}"

log_info(){ >&2 echo "[INFO] existing-desktop: $*"; }
log_error(){ >&2 echo "[ERROR] existing-desktop: $*"; }

printable(){ printf '%s' "$1" | tr -cd '[:print:]'; }

# find_xorg: the path of the X server binary.
find_xorg(){
    local x
    for x in /usr/lib/xorg/Xorg /usr/bin/Xorg; do
        if [[ -x "$R$x" ]]; then echo "$x"; return 0; fi
    done
    return 1
}

# find_dm: the name of the display manager — the enabled unit (a link that
# resolves inside the root) or Debian's /etc/X11/default-display-manager naming a
# binary that exists. gdm.service and gdm3 are both "gdm3".
find_dm(){
    local unit="$R/etc/systemd/system/display-manager.service" target bin name=""
    if [[ -L "$unit" ]]; then
        target="$(readlink -- "$unit")"
        [[ "$target" == /* ]] || target="/etc/systemd/system/$target"
        if [[ -f "$R$target" ]]; then name="$(basename -- "$target" .service)"; fi
    fi
    if [[ -z "$name" && -f "$R/etc/X11/default-display-manager" ]]; then
        bin="$(head -n 1 -- "$R/etc/X11/default-display-manager")"
        if [[ "$bin" == /* && -x "$R$bin" ]]; then name="$(basename -- "$bin")"; fi
    fi
    [[ -n "$name" ]] || return 1
    case "$name" in
        gdm | gdm3) echo gdm3 ;;
        *) printable "$name"; echo ;;
    esac
}

# names_in DIR: the printable names of DIR/*.desktop, space separated.
names_in(){
    local s out=()
    for s in "$R$1"/*.desktop; do
        [[ -f "$s" ]] && out+=("$(printable "$(basename -- "$s")")")
    done
    (( ${#out[@]} )) || return 1
    echo "${out[*]}"
}

cmd_verify(){
    local missing=0 x dm xs ws
    if x="$(find_xorg)"; then
        log_info "X-сервер: $x"
    else
        log_error "нет Xorg (/usr/lib/xorg/Xorg, /usr/bin/Xorg) — на машине нет X-сервера"
        missing=1
    fi
    if dm="$(find_dm)"; then
        log_info "менеджер входа: $dm"
    else
        log_error "нет менеджера входа: ни display-manager.service, ни /etc/X11/default-display-manager с существующим бинарём"
        missing=1
    fi
    if xs="$(names_in /usr/share/xsessions)"; then
        log_info "X-сессии: $xs"
    elif ws="$(names_in /usr/share/wayland-sessions)"; then
        log_error "только Wayland-сессии ($ws в /usr/share/wayland-sessions), X-сессии в /usr/share/xsessions нет: selkies и x11vnc захватывают только X — поставьте сеанс стола «на Xorg»"
        missing=1
    else
        log_error "нет X-сессии в /usr/share/xsessions — менеджеру входа нечего открыть"
        missing=1
    fi
    if (( missing )); then
        log_error "готового стола на машине нет целиком — способности x11-server, display-manager, desktop-session не даю"
        log_error "неудачная запись держит конфликт desktop-session: сначала \`cream remove existing-desktop\`, затем gnome, xfce4 или lxde (--accept-risk)"
        return 1
    fi
}

cmd_check(){
    local x dm
    if ! x="$(find_xorg)"; then log_error "нет Xorg"; return 1; fi
    if ! dm="$(find_dm)"; then log_error "нет менеджера входа"; return 1; fi
    log_info "Xorg $x, менеджер входа $dm"
}

# ini_get SECTIONS KEY FILE…: the value of KEY in any of SECTIONS ("a|b") — the
# last assignment over the files in order (later files override), comments
# skipped; nothing printed when there is none. Files that are not there are
# skipped.
ini_get(){
    local secs="$1" key="$2" f
    local -a files=()
    shift 2
    for f in "$@"; do [[ -f "$f" ]] && files+=("$f"); done
    (( ${#files[@]} )) || return 0
    awk -v secs="$secs" -v key="$key" '
        BEGIN { n = split(secs, a, "|"); for (i = 1; i <= n; i++) want[a[i]] = 1 }
        FNR == 1 { insec = 0 }
        /^[[:space:]]*\[/ { s = $0; sub(/^[[:space:]]*\[/, "", s); sub(/\].*$/, "", s); insec = (s in want); next }
        insec && /^[[:space:]]*[^#;[:space:]]/ && index($0, "=") {
            k = $0; sub(/=.*/, "", k); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            if (k != key) next
            v = $0; sub(/^[^=]*=/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            val = v; found = 1
        }
        END { if (found) print val }
    ' "${files[@]}"
}

# wayland_state FILE: absent | commented | true | false of WaylandEnable in
# [daemon] (GKeyFile: the last uncommented line counts; false and 0 are false).
wayland_state(){
    awk '
        /^[[:space:]]*\[/ { s = $0; sub(/^[[:space:]]*\[/, "", s); sub(/\].*$/, "", s); next }
        s != "daemon" { next }
        /^[[:space:]]*WaylandEnable[[:space:]]*=/ {
            v = $0; sub(/^[^=]*=/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); on = 1; next
        }
        /^[[:space:]]*#+[[:space:]]*WaylandEnable[[:space:]]*=/ { com = 1 }
        END {
            if (on) print ((v == "false" || v == "0") ? "false" : "true")
            else if (com) print "commented"
            else print "absent"
        }
    ' "$1"
}

status_gdm(){
    local rel st hint=0 user enable
    local -a confs=()
    for rel in /etc/gdm3/daemon.conf /etc/gdm3/custom.conf; do
        [[ -f "$R$rel" ]] || continue
        confs+=("$R$rel")
        st="$(wayland_state "$R$rel")"
        case "$st" in
            absent) echo "WaylandEnable в $rel: не задан (ключа нет) — сеансы GNOME на Wayland"; hint=1 ;;
            commented) echo "WaylandEnable в $rel: не задан (закомментирован) — сеансы GNOME на Wayland"; hint=1 ;;
            true) echo "WaylandEnable в $rel: true — сеансы GNOME на Wayland"; hint=1 ;;
            false) echo "WaylandEnable в $rel: false — экран входа и сеансы GNOME на Xorg" ;;
        esac
    done
    if (( ${#confs[@]} == 0 )); then
        echo "WaylandEnable: нет /etc/gdm3/daemon.conf и /etc/gdm3/custom.conf — умолчание gdm3, Wayland"
        hint=1
    fi
    if (( hint )); then
        echo "подсказка: Wayland у GDM выключает gdm-xorg (sudo cream install --accept-risk gdm-xorg); прежнее значение вернёт cream remove gdm-xorg"
    fi
    enable="$(ini_get daemon AutomaticLoginEnable "${confs[@]}")"
    user="$(ini_get daemon AutomaticLogin "${confs[@]}")"
    enable="${enable,,}"
    if [[ ( "$enable" == true || "$enable" == 1 ) && -n "$user" ]]; then
        echo "автологин: $(printable "$user")"
    else
        echo "автологина нет"
    fi
}

status_lightdm(){
    local user
    local -a files=("$R"/usr/share/lightdm/lightdm.conf.d/*.conf "$R"/etc/lightdm/lightdm.conf.d/*.conf
        "$R/etc/lightdm/lightdm.conf")
    user="$(ini_get 'Seat:*|Seat:seat0|SeatDefaults' autologin-user "${files[@]}")"
    if [[ -n "$user" ]]; then echo "автологин: $(printable "$user")"; else echo "автологина нет"; fi
}

status_sddm(){
    local user
    local -a files=("$R"/usr/lib/sddm/sddm.conf.d/*.conf "$R"/etc/sddm.conf.d/*.conf "$R/etc/sddm.conf")
    user="$(ini_get Autologin User "${files[@]}")"
    if [[ -n "$user" ]]; then echo "автологин: $(printable "$user")"; else echo "автологина нет"; fi
}

status_seat0(){
    local active u t c s t2 d st
    # shellcheck source=../../../../lib/x-session.sh
    source "${CREAM_EXT_DIR:?run by cream}/files/x-session.sh"
    if active="$(xs_seat0_active)"; then
        read -r u t c <<< "$active"
        if [[ "$c" == greeter ]]; then
            echo "seat0: экран входа ($u)"
        elif s="$(xs_seat0_session "$u")"; then
            read -r _ t2 d st <<< "$s"
            echo "seat0: $u, $t2, $d, $st"
            t="$t2"
        else
            echo "seat0: $u, $t"
        fi
        if [[ "$t" == wayland ]]; then
            echo "сеанс seat0 на Wayland — selkies и x11vnc его не захватят"
        fi
    elif command -v loginctl >/dev/null 2>&1 && loginctl show-seat -p ActiveSession -- seat0 >/dev/null 2>&1; then
        echo "seat0: активного сеанса нет"
    else
        echo "seat0: нет logind"
    fi
}

cmd_status(){
    local x dm act
    if x="$(find_xorg)"; then echo "X-сервер: $x"; else echo "X-сервер: нет Xorg"; fi
    if dm="$(find_dm)"; then
        act="$(systemctl is-active display-manager.service 2>/dev/null | head -n 1)" || true
        [[ "$act" =~ ^[a-z-]+$ ]] || act="неизвестно"
        echo "менеджер входа: $dm ($act)"
        case "$dm" in
            gdm3) status_gdm ;;
            lightdm) status_lightdm ;;
            sddm) status_sddm ;;
            *) echo "автологин: где его хранит $dm — не знаю" ;;
        esac
    else
        echo "менеджер входа: нет"
    fi
    status_seat0
}

case "${1:-}" in
    verify) cmd_verify ;;
    check) cmd_check ;;
    status) cmd_status ;;
    *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
