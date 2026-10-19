#!/usr/bin/env bash
# wallpaper.sh — the wallpaper as a system default. Run by the hooks from the
# tree of the extension (/opt/cream/ext/wallpaper/files/wallpaper.sh); the keys
# come from the hook environment (config.keys of the manifest, checked by cream
# and checked again here before any write).
#
#   wallpaper.sh check    the picture exists in images/ (install)
#   wallpaper.sh apply    writes the defaults (configure)
#   wallpaper.sh remove   takes them away (remove)
#
# WHY SYSTEM DEFAULTS AND NOT gsettings OF THE USER. The former firstboot
# service, run by root, wrote the user's dconf (~/.config/dconf/user) and
# dropped markers into ~/.local/share/applications — root reaching into a home
# directory the user controls. Defaults under /etc reach the same screen:
#   GNOME — the system dconf db `local` (profile rule shared with desktop and
#     locale) WITH LOCKS. The lock is what beats /etc/xdg/autostart/nvbackground.sh
#     of L4T: it runs `gsettings set … NVIDIA_Wallpaper.jpg` at every session
#     start (measured 2026-09-12 and 2026-09-15 on Jetson boards: our values
#     overwritten a minute later), and a locked key is not writable for it. The
#     same lock keeps an older value in the user's database from winning.
#   Xfce — the system xfconf channel xfce4-desktop in the layout Xubuntu ships
#     (monitor0…3/image-path): xfdesktop takes it over for whatever the monitor
#     is called. A default, not a lock: the user's own channel wins.
#   LXDE — [desktop] wallpaper/wallpaper_mode of the pcmanfm.conf of lxde-common
#     (lxsession does not hold the wallpaper; pcmanfm draws the desktop).
#
# Every write goes to a temporary file in the same directory and is renamed
# over the target: a symlink planted at the target is replaced, never followed;
# a package file that IS a symlink is left alone with a warning.
set -euo pipefail

R="${CREAM_ROOT:-}"; R="${R%/}"
IMAGES=/opt/cream/ext/wallpaper/images
STATE="${CREAM_STATE_DIR:-$R/var/lib/cream/ext/wallpaper}"
CLOUD_USER_LIB="$R/opt/cream/ext/cloud-user/get_cloud_user.sh"
# ${…-…}, not ${…:-…}: an empty value passed in is refused, not defaulted.
WALLPAPER_IMAGE="${WALLPAPER_IMAGE-dst_1080.jpg}"
WALLPAPER_MODE="${WALLPAPER_MODE-zoom}"
IMAGE_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.(jpg|jpeg|png|svg)$'

DCONF_BIN="$R/usr/bin/dconf"
DCONF_PROFILE="$R/etc/dconf/profile/user"
DCONF_KF="$R/etc/dconf/db/local.d/50-wallpaper"
DCONF_LK="$R/etc/dconf/db/local.d/locks/50-wallpaper"
XFCONF_DIR="$R/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
XFCONF="$XFCONF_DIR/xfce4-desktop.xml"
XFCONF_MARK='<!-- cream extension wallpaper: system default, removed by `cream remove wallpaper` -->'
PCMANFM="$R/etc/xdg/pcmanfm/LXDE/pcmanfm.conf"
PCMANFM_ORIG="$STATE/pcmanfm.orig"

DCONF_CHANGED=0

log_info(){ >&2 echo "[INFO] wallpaper: $*"; }
log_warn(){ >&2 echo "[WARN] wallpaper: $*"; }
die(){ >&2 echo "[ERROR] wallpaper: $*"; exit 1; }

# image: the guest path of the chosen picture, or exit 1. Only a regular file
# directly in images/ of this extension, by a name of a fixed form.
image(){
    local name="$WALLPAPER_IMAGE" dir="$R$IMAGES" file
    [[ "$name" =~ $IMAGE_RE ]] \
        || die "WALLPAPER_IMAGE: имя файла из $IMAGES (буквы, цифры, . _ -; .jpg .jpeg .png .svg), без каталогов"
    file="$dir/$name"
    [[ -d "$dir" && ! -L "$dir" ]] || die "нет каталога картинок $IMAGES"
    [[ -f "$file" && ! -L "$file" ]] || die "нет картинки $IMAGES/$name (или это ссылка)"
    [[ "$(realpath -e -- "$file")" == "$(realpath -e -- "$dir")/$name" ]] \
        || die "$IMAGES/$name ведёт за пределы $IMAGES"
    printf '%s\n' "$IMAGES/$name"
}

# mode: "<gnome> <xfce image-style> <pcmanfm wallpaper_mode>", or exit 1.
mode(){
    case "$WALLPAPER_MODE" in
        zoom)      echo "zoom 5 crop" ;;
        scaled)    echo "scaled 4 fit" ;;
        centered)  echo "centered 1 center" ;;
        stretched) echo "stretched 3 stretch" ;;
        spanned)   echo "spanned 6 screen" ;;
        wallpaper) echo "wallpaper 2 tile" ;;
        *) die "WALLPAPER_MODE: zoom, scaled, centered, stretched, spanned или wallpaper" ;;
    esac
}

# write_if_changed <target> [mode] < content: temporary file + rename; status
# 1 — unchanged. A symlink at the target is replaced, not followed.
write_if_changed(){
    local target="$1" fmode="${2:-0644}" tmp
    install -d -m 0755 "${target%/*}"
    tmp="$(mktemp "${target%/*}/.wallpaper.XXXXXX")"
    cat > "$tmp"
    chmod "$fmode" "$tmp"
    if [[ -f "$target" && ! -L "$target" ]] && cmp -s "$tmp" "$target"; then
        rm -f -- "$tmp"; return 1
    fi
    mv -f -- "$tmp" "$target"
}

# remove_files <file>…: status 0 — something was removed.
remove_files(){
    local f removed=1
    for f in "$@"; do
        if [[ -e "$f" || -L "$f" ]]; then rm -f -- "$f"; removed=0; fi
    done
    return "$removed"
}

# ---------------------------------------------------------------------------
# GNOME: the system dconf database with locks
# ---------------------------------------------------------------------------
apply_dconf(){
    local uri="$1" opt="$2" profile
    # The profile rule of desktop and locale: a user db over the system db local.
    if [[ -f "$DCONF_PROFILE" && ! -L "$DCONF_PROFILE" ]]; then
        if ! grep -qx 'system-db:local' "$DCONF_PROFILE"; then
            profile="$(cat "$DCONF_PROFILE")"
            printf '%s\nsystem-db:local\n' "$profile" | write_if_changed "$DCONF_PROFILE" || true
        fi
    elif [[ ! -e "$DCONF_PROFILE" ]]; then
        printf 'user-db:user\nsystem-db:local\n' | write_if_changed "$DCONF_PROFILE" || true
    else
        log_warn "${DCONF_PROFILE#"$R"} — ссылка, не правлю; обои GNOME могут не примениться"
    fi
    if write_if_changed "$DCONF_KF" <<EOF
[org/gnome/desktop/background]
picture-uri='file://$uri'
picture-uri-dark='file://$uri'
picture-options='$opt'
EOF
    then DCONF_CHANGED=1; fi
    if write_if_changed "$DCONF_LK" <<'EOF'
/org/gnome/desktop/background/picture-uri
/org/gnome/desktop/background/picture-uri-dark
/org/gnome/desktop/background/picture-options
EOF
    then DCONF_CHANGED=1; fi
}

dconf_update(){
    [[ -x "$DCONF_BIN" ]] || return 0
    (( DCONF_CHANGED )) || [[ ! -f "$R/etc/dconf/db/local" ]] || return 0
    dconf update || die "dconf update не прошёл — обои GNOME не применятся"
}

# ---------------------------------------------------------------------------
# Xfce: the system xfconf channel xfce4-desktop
# ---------------------------------------------------------------------------
xfconf_ours(){ [[ -f "$XFCONF" && ! -L "$XFCONF" ]] && grep -qxF "$XFCONF_MARK" "$XFCONF"; }

apply_xfconf(){
    local uri="$1" style="$2" n
    if [[ -e "$XFCONF" || -L "$XFCONF" ]] && ! xfconf_ours; then
        log_warn "${XFCONF#"$R"} уже есть и не наш — обои Xfce не задаю"
        return 0
    fi
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n%s\n' "$XFCONF_MARK"
        printf '<channel name="xfce4-desktop" version="1.0">\n'
        printf '  <property name="backdrop" type="empty">\n    <property name="screen0" type="empty">\n'
        for n in 0 1 2 3; do
            printf '      <property name="monitor%s" type="empty">\n' "$n"
            printf '        <property name="image-path" type="string" value="%s"/>\n' "$uri"
            printf '        <property name="image-style" type="int" value="%s"/>\n' "$style"
            printf '        <property name="image-show" type="bool" value="true"/>\n'
            printf '      </property>\n'
        done
        printf '    </property>\n  </property>\n</channel>\n'
    } | write_if_changed "$XFCONF" || true
}

# ---------------------------------------------------------------------------
# LXDE: [desktop] of pcmanfm.conf (a conffile of lxde-common)
# ---------------------------------------------------------------------------
# ini_get <file> <section> <key>: the value; status 1 — no such key.
ini_get(){
    SECTION="$2" KEY="$3" awk '
        /^[[:space:]]*\[/ { line = $0; sub(/^[[:space:]]*\[/, "", line); sub(/\].*$/, "", line); cur = line; next }
        cur == ENVIRON["SECTION"] && index($0, ENVIRON["KEY"] "=") == 1 {
            print substr($0, length(ENVIRON["KEY"]) + 2); found = 1; exit
        }
        END { exit !found }' "$1"
}

# ini_edit <file> <section> <key> [value]: sets the key in its section (adds the
# section when absent); without a value deletes the key. Values go through
# ENVIRON (awk -v would expand backslashes). Temporary file + rename, the mode
# and owner of the package's file kept.
ini_edit(){
    local file="$1" tmp
    tmp="$(mktemp "${file%/*}/.wallpaper.XXXXXX")"
    SECTION="$2" KEY="$3" VALUE="${4-}" DEL="$(( $# < 4 ))" awk '
        function emit() { if (ENVIRON["DEL"] == "0") print ENVIRON["KEY"] "=" ENVIRON["VALUE"]; done = 1 }
        /^[[:space:]]*\[/ {
            if (cur == ENVIRON["SECTION"] && !done) emit()
            line = $0; sub(/^[[:space:]]*\[/, "", line); sub(/\].*$/, "", line)
            cur = line; print; next
        }
        cur == ENVIRON["SECTION"] && index($0, ENVIRON["KEY"] "=") == 1 { if (!done) emit(); next }
        { print }
        END {
            if (!done && ENVIRON["DEL"] == "0") {
                if (cur != ENVIRON["SECTION"]) { print ""; print "[" ENVIRON["SECTION"] "]" }
                emit()
            }
        }' "$file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    if cmp -s "$tmp" "$file"; then rm -f -- "$tmp"; return 0; fi
    chmod --reference="$file" "$tmp"
    chown --reference="$file" "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$file"
}

pcmanfm_usable(){
    [[ -e "$PCMANFM" || -L "$PCMANFM" ]] || return 1
    if [[ -L "$PCMANFM" || ! -f "$PCMANFM" ]]; then
        log_warn "${PCMANFM#"$R"} — ссылка или не обычный файл, не правлю"
        return 1
    fi
}

# The values pcmanfm.conf had before us, once (first record wins): one line
# per key, "<key> <0|1> <value>" — 0 means the key was absent.
pcmanfm_remember(){
    local k v out=""
    [[ -s "$PCMANFM_ORIG" ]] && return 0
    for k in wallpaper wallpaper_mode; do
        if v="$(ini_get "$PCMANFM" desktop "$k")"; then
            out+="$k 1 $v"$'\n'
        else
            out+="$k 0 "$'\n'
        fi
    done
    install -d -m 0755 "$STATE"
    printf '%s' "$out" | write_if_changed "$PCMANFM_ORIG" 0600 || true
}

apply_pcmanfm(){
    local uri="$1" pmode="$2"
    pcmanfm_usable || return 0
    pcmanfm_remember
    ini_edit "$PCMANFM" desktop wallpaper "$uri"
    ini_edit "$PCMANFM" desktop wallpaper_mode "$pmode"
}

remove_pcmanfm(){
    local k has v cur
    if [[ -s "$PCMANFM_ORIG" ]] && pcmanfm_usable; then
        cur="$(ini_get "$PCMANFM" desktop wallpaper || true)"
        if [[ "$cur" == "$IMAGES"/* ]]; then
            while read -r k has v; do
                case "$k" in wallpaper|wallpaper_mode) ;; *) continue ;; esac
                if [[ "$has" == 1 ]]; then
                    ini_edit "$PCMANFM" desktop "$k" "$v"
                else
                    ini_edit "$PCMANFM" desktop "$k"
                fi
            done < "$PCMANFM_ORIG"
        else
            log_info "обои в ${PCMANFM#"$R"} сменил не wallpaper — оставляю"
        fi
    fi
    rm -f -- "$PCMANFM_ORIG"
}

# ---------------------------------------------------------------------------
# The user: only looked at, never written
# ---------------------------------------------------------------------------
# warn_user_overrides: the cloud-init user's own Xfce/LXDE settings win over a
# system default (GNOME is locked). Existence only — nothing is read or written
# in the home directory.
warn_user_overrides(){
    local user="" home f
    [[ -x "$CLOUD_USER_LIB" ]] && user="$("$CLOUD_USER_LIB" 2>/dev/null || true)"
    [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 0
    home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
    [[ "$home" == /* ]] || return 0
    for f in .config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml .config/pcmanfm/LXDE/desktop-items-0.conf; do
        if [[ -e "$R$home/$f" ]]; then
            log_warn "у пользователя $user свои настройки стола (~/$f) — системные обои для него не действуют, пока он их не сбросит"
        fi
    done
}

cmd_apply(){
    local uri m gnome style pmode any=0
    uri="$(image)"
    m="$(mode)"
    read -r gnome style pmode <<< "$m"
    if [[ -x "$DCONF_BIN" ]]; then apply_dconf "$uri" "$gnome"; any=1; fi
    if [[ -d "$XFCONF_DIR" || -x "$R/usr/bin/xfdesktop" ]]; then apply_xfconf "$uri" "$style"; any=1; fi
    if [[ -e "$PCMANFM" || -L "$PCMANFM" ]]; then apply_pcmanfm "$uri" "$pmode"; any=1; fi
    dconf_update
    if (( ! any )); then
        log_warn "рабочего стола не нашлось (dconf, xfconf, pcmanfm) — обои задавать некому"
        return 0
    fi
    warn_user_overrides
    log_info "обои: $uri ($WALLPAPER_MODE)"
}

cmd_remove(){
    if remove_files "$DCONF_KF" "$DCONF_LK"; then DCONF_CHANGED=1; fi
    if xfconf_ours; then rm -f -- "$XFCONF"; fi
    remove_pcmanfm
    if (( DCONF_CHANGED )) && [[ -x "$DCONF_BIN" ]]; then
        dconf update || die "dconf update не прошёл"
    fi
    log_info "обои сняты"
}

case "${1:-}" in
    check) image > /dev/null ;;
    apply) cmd_apply ;;
    remove) cmd_remove ;;
    *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
