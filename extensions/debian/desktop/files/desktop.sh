#!/usr/bin/env bash
# desktop.sh — the settings of the desktop extension applied to the machine.
# Run by hooks/configure, hooks/remove and the actions apply and status, from
# the tree of the extension (/opt/cream/ext/desktop/files/desktop.sh); the keys
# come from the hook environment (config.keys of the manifest, checked by cream).
#
#   desktop.sh apply --boot   at boot, before the display manager: waits up to
#                             30 s for the cloud-init user, never restarts the DM
#   desktop.sh apply --now    on a working machine: restarts the DM (no-block)
#                             when the autologin changed and no graphical
#                             session is open
#   desktop.sh status         the keys and what of them is applied
#   desktop.sh remove         takes away the files and the autologin
#
# Keys:
#   DESKTOP_AUTOLOGIN=0             1 — login without a password
#   DESKTOP_AUTOLOGIN_USER=         empty — the cloud-init user
#   DESKTOP_DISABLE_SCREEN_LOCK=0   1 — no auto-lock (manual lock stays)
#   DESKTOP_DISABLE_SCREEN_BLANK=0  1 — no dimming, blanking, DPMS and sleep
#
# A key turned off means "our file is absent": the behaviour of the OS applies,
# not our "off". One code for gdm3 and lightdm, so gnome, xfce4, lxde and
# cloud-user-desktop cannot diverge the way their copies of
# disable_powersave.sh once did.
set -euo pipefail

R="${CREAM_ROOT:-}"; R="${R%/}"
DESKTOP_AUTOLOGIN="${DESKTOP_AUTOLOGIN:-0}"
DESKTOP_AUTOLOGIN_USER="${DESKTOP_AUTOLOGIN_USER:-}"
DESKTOP_DISABLE_SCREEN_LOCK="${DESKTOP_DISABLE_SCREEN_LOCK:-0}"
DESKTOP_DISABLE_SCREEN_BLANK="${DESKTOP_DISABLE_SCREEN_BLANK:-0}"

CLOUD_USER_LIB="$R/opt/cream/ext/cloud-user/get_cloud_user.sh"
DCONF_PROFILE="$R/etc/dconf/profile"
DCONF_LOCAL="$R/etc/dconf/db/local.d"
DCONF_LOCK="$DCONF_LOCAL/50-desktop-screen-lock"
DCONF_LOCK_LOCKS="$DCONF_LOCAL/locks/50-desktop-screen-lock"
DCONF_BLANK="$DCONF_LOCAL/50-desktop-screen-blank"
DCONF_BLANK_LOCKS="$DCONF_LOCAL/locks/50-desktop-screen-blank"
DCONF_GDM_BLANK="$R/etc/dconf/db/gdm.d/50-desktop-screen-blank"
XSESSION_BLANK="$R/etc/X11/Xsession.d/90-desktop-disable-dpms"
XFCONF_DIR="$R/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
# xfconf reads only <channel>.xml: ours carry a suffix, and a link
# <channel>.xml -> ours is made only when the channel is absent (link_xfconf).
XFCE_SUFFIX=.desktop-ext.xml
XFCE_POWER="$XFCONF_DIR/xfce4-power-manager$XFCE_SUFFIX"
XFCE_SAVER="$XFCONF_DIR/xfce4-screensaver$XFCE_SUFFIX"
LIGHTDM_BLANK_CMD="X -s 0 -dpms"

# Set when a dconf keyfile changed: `dconf update` only then (a repeat changes
# nothing, the binary database included).
DCONF_CHANGED=0

log(){ >&2 echo "desktop: $*"; }
die(){ log "ОШИБКА: $*"; exit 1; }

# write_if_changed <target> < content: atomic; status 1 — unchanged.
write_if_changed(){
    local target="$1" tmp
    install -d -m 0755 "${target%/*}"
    tmp="$(mktemp "${target%/*}/.desktop.XXXXXX")"
    cat > "$tmp"
    chmod 0644 "$tmp"
    if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
        rm -f "$tmp"; return 1
    fi
    mv -f "$tmp" "$target"
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
# The user
# ---------------------------------------------------------------------------
home_of(){ getent passwd "$1" 2>/dev/null | cut -d: -f6; }

# resolve_user <wait seconds>: DESKTOP_AUTOLOGIN_USER or the cloud-init user,
# an existing account with a home directory. The library's stderr is kept: it
# says when it took the fallback path and which account it picked.
resolve_user(){
    local wait_s="$1" user="" waited=0 home
    while :; do
        user=""
        if [[ -n "$DESKTOP_AUTOLOGIN_USER" ]]; then
            user="$DESKTOP_AUTOLOGIN_USER"
        elif [[ -x "$CLOUD_USER_LIB" ]]; then
            user="$("$CLOUD_USER_LIB" || true)"
        fi
        if [[ -n "$user" ]] && id "$user" >/dev/null 2>&1; then
            home="$(home_of "$user")"
            if [[ -n "$home" && -d "$R$home" ]]; then
                echo "$user"; return 0
            fi
        fi
        (( waited >= wait_s )) && return 1
        sleep 3; waited=$((waited + 3))
    done
}

# The groups — BEFORE the session, and that is the main reason configure runs
# before the display manager. Xorg of the autologin runs as the user; without
# `video` it does not open the GPU ("NVIDIA(GPU-0): Failed to initialize the
# NVIDIA graphics device!", 52 attempts, and gdm drops the autologin: first boot
# of an AGX Orin 2026-09-14, when the groups were added after cloud-final, i.e.
# after gdm started). And `systemd --user` keeps the group list it had at its
# start for good (measured 2026-09-12: a session without `video` gives "Oh no!
# Something has gone wrong"). A user added beforehand knows no such race.
ensure_groups(){
    local user="$1" grp
    for grp in video render audio pulse input dialout plugdev; do
        getent group "$grp" >/dev/null 2>&1 || continue
        id -nG "$user" | tr ' ' '\n' | grep -qx "$grp" && continue
        if usermod -aG "$grp" "$user"; then
            log "'$user' внесён в группу $grp"
        else
            log "'$user' не внесён в группу $grp"
        fi
    done
}

# ---------------------------------------------------------------------------
# INI: a key in its own section. The three former defects (a commented key
# left in place, a key appended to a foreign section, "success" by the fact of
# the call rather than of the write) are covered by the tests.
# ---------------------------------------------------------------------------
set_ini_key(){
    local file="$1" section="$2" key="$3" value="$4" tmp
    tmp="$(mktemp "${file%/*}/.desktop.XXXXXX")" || return 1
    awk -v want="$section" -v key="$key" -v value="$value" '
        function emit() { print key "=" value; done = 1 }
        /^[[:space:]]*\[/ {
            if (cur == want && !done) emit()
            line = $0; sub(/^[[:space:]]*\[/, "", line); sub(/\].*$/, "", line)
            cur = line; print; next
        }
        {
            if (cur == want && $0 ~ "^[[:space:]]*#*[[:space:]]*" key "[[:space:]]*=") {
                if (!done) emit()
                next
            }
            print
        }
        END { if (!done) { if (cur == want) emit(); else { print ""; print "[" want "]"; emit() } } }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    # In place (cat, not mv): the mode and owner of the package's file stay.
    cmp -s "$tmp" "$file" || cat "$tmp" > "$file"
    rm -f "$tmp"
    grep -qxF "${key}=${value}" "$file"
}

del_ini_key(){
    local file="$1" key="$2"
    grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$file" || return 0
    sed -i -E "/^[[:space:]]*${key}[[:space:]]*=/d" "$file"
}

lightdm_seat_section(){
    if grep -q '^[[:space:]]*\[SeatDefaults\]' "$1" && ! grep -q '^[[:space:]]*\[Seat:\*\]' "$1"; then
        echo 'SeatDefaults'
    else
        echo 'Seat:*'
    fi
}

# Which file gdm reads is decided when the package is built: Debian 13 —
# daemon.conf, Ubuntu — custom.conf (measured 2026-09-03). Edit every one there is.
gdm_confs(){
    local c
    for c in "$R/etc/gdm3/daemon.conf" "$R/etc/gdm3/custom.conf"; do
        if [[ -f "$c" ]]; then echo "$c"; fi
    done
}
lightdm_confs(){
    local c
    for c in "$R/etc/lightdm/lightdm.conf" "$R"/etc/lightdm/lightdm.conf.d/*.conf; do
        if [[ -f "$c" ]]; then echo "$c"; fi
    done
}

# ---------------------------------------------------------------------------
# The three keys
# ---------------------------------------------------------------------------
apply_autologin(){
    local user="$1" on="$2" conf section
    while read -r conf; do
        [[ -n "$conf" ]] || continue
        if [[ "$on" == 1 ]]; then
            { set_ini_key "$conf" daemon AutomaticLoginEnable true \
                && set_ini_key "$conf" daemon AutomaticLogin "$user"; } \
                || die "gdm: не записался автологин в ${conf#"$R"}"
        else
            set_ini_key "$conf" daemon AutomaticLoginEnable false \
                || die "gdm: не записался отказ от автологина в ${conf#"$R"}"
        fi
    done < <(gdm_confs)
    while read -r conf; do
        [[ -n "$conf" ]] || continue
        section="$(lightdm_seat_section "$conf")"
        if [[ "$on" == 1 ]]; then
            { set_ini_key "$conf" "$section" autologin-user "$user" \
                && set_ini_key "$conf" "$section" autologin-user-timeout 0; } \
                || die "lightdm: не записался автологин в ${conf#"$R"}"
        else
            del_ini_key "$conf" autologin-user
            del_ini_key "$conf" autologin-user-timeout
        fi
    done < <(lightdm_confs)
}

# The system dconf database + locks: the user database does not override these
# keys, so "off" means off, not until the first change in Settings. The same
# profile rule as the extension locale: a user db over the system db `local`.
dconf_profile(){
    install -d -m 0755 "$DCONF_LOCAL/locks" "$DCONF_PROFILE"
    if [[ ! -f "$DCONF_PROFILE/user" ]]; then
        printf 'user-db:user\nsystem-db:local\n' > "$DCONF_PROFILE/user"
    elif ! grep -q '^system-db:local$' "$DCONF_PROFILE/user"; then
        printf 'system-db:local\n' >> "$DCONF_PROFILE/user"
    fi
}

dconf_write(){ if write_if_changed "$1"; then DCONF_CHANGED=1; fi; }
dconf_remove(){ if remove_files "$@"; then DCONF_CHANGED=1; fi; }

apply_screen_lock(){
    if [[ "$DESKTOP_DISABLE_SCREEN_LOCK" == 1 ]]; then
        dconf_profile
        # Only the AUTO-lock. org/gnome/desktop/lockdown/disable-lock-screen is
        # left alone: it forbids the manual lock too, and that is the user's
        # right. apps/light-locker — the locker of xfce/lxde on Debian and
        # Ubuntu, it reads GSettings too.
        dconf_write "$DCONF_LOCK" <<'EOF'
[org/gnome/desktop/screensaver]
lock-enabled=false
ubuntu-lock-on-suspend=false

[apps/light-locker]
lock-after-screensaver=uint32 0
lock-on-suspend=false
lock-on-lid=false
EOF
        dconf_write "$DCONF_LOCK_LOCKS" <<'EOF'
/org/gnome/desktop/screensaver/lock-enabled
/org/gnome/desktop/screensaver/ubuntu-lock-on-suspend
/apps/light-locker/lock-after-screensaver
/apps/light-locker/lock-on-suspend
/apps/light-locker/lock-on-lid
EOF
    else
        dconf_remove "$DCONF_LOCK" "$DCONF_LOCK_LOCKS"
    fi
}

blank_keyfile(){
    cat <<'EOF'
[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/desktop/screensaver]
idle-activation-enabled=false

[org/gnome/settings-daemon/plugins/power]
idle-dim=false
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
sleep-inactive-ac-timeout=0
sleep-inactive-battery-timeout=0
EOF
}

apply_screen_blank(){
    local conf section
    if [[ "$DESKTOP_DISABLE_SCREEN_BLANK" == 1 ]]; then
        dconf_profile
        dconf_write "$DCONF_BLANK" < <(blank_keyfile)
        dconf_write "$DCONF_BLANK_LOCKS" <<'EOF'
/org/gnome/desktop/session/idle-delay
/org/gnome/desktop/screensaver/idle-activation-enabled
/org/gnome/settings-daemon/plugins/power/idle-dim
/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-type
/org/gnome/settings-daemon/plugins/power/sleep-inactive-battery-type
EOF
        # The gdm login screen reads ITS OWN profile (profile/gdm ->
        # system-db:gdm); the user keys do not reach it.
        if [[ -f "$DCONF_PROFILE/gdm" ]]; then
            dconf_write "$DCONF_GDM_BLANK" < <(blank_keyfile)
        fi
        # The X level — for any Xorg session, xfce and lxde included.
        write_if_changed "$XSESSION_BLANK" <<'EOF' || true
# Written by the cream extension desktop (DESKTOP_DISABLE_SCREEN_BLANK=1).
if command -v xset >/dev/null 2>&1; then
    xset s off; xset s noblank; xset -dpms
fi
EOF
        if [[ -d "$XFCONF_DIR" || -x "$R/usr/bin/xfce4-power-manager" ]]; then
            write_if_changed "$XFCE_POWER" <<'EOF' || true
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="blank-on-ac" type="int" value="0"/>
    <property name="blank-on-battery" type="int" value="0"/>
    <property name="dpms-enabled" type="bool" value="false"/>
    <property name="inactivity-on-ac" type="uint" value="0"/>
    <property name="inactivity-on-battery" type="uint" value="0"/>
  </property>
</channel>
EOF
        fi
        # The lightdm login screen blanks by itself: X without -s 0 -dpms.
        while read -r conf; do
            [[ -n "$conf" ]] || continue
            section="$(lightdm_seat_section "$conf")"
            set_ini_key "$conf" "$section" xserver-command "$LIGHTDM_BLANK_CMD" \
                || log "lightdm: не записался xserver-command в ${conf#"$R"}"
        done < <(lightdm_confs)
    else
        dconf_remove "$DCONF_BLANK" "$DCONF_BLANK_LOCKS" "$DCONF_GDM_BLANK"
        remove_files "$XSESSION_BLANK" "$XFCE_POWER" || true
        unset_lightdm_blank
    fi
}

# Only our own xserver-command: an administrator's one stays.
unset_lightdm_blank(){
    local conf
    while read -r conf; do
        [[ -n "$conf" ]] || continue
        if grep -qxF "xserver-command=$LIGHTDM_BLANK_CMD" "$conf"; then
            del_ini_key "$conf" xserver-command
        fi
    done < <(lightdm_confs)
}

# xfce4-screensaver keeps both keys in one channel — so separately, after both:
# blanking (saver) and locking (lock).
apply_xfce_screensaver(){
    if [[ "$DESKTOP_DISABLE_SCREEN_LOCK" != 1 && "$DESKTOP_DISABLE_SCREEN_BLANK" != 1 ]]; then
        remove_files "$XFCE_SAVER" || true
        return 0
    fi
    [[ -d "$XFCONF_DIR" || -x "$R/usr/bin/xfce4-screensaver" ]] || return 0
    local saver=true lock=true
    [[ "$DESKTOP_DISABLE_SCREEN_BLANK" == 1 ]] && saver=false
    [[ "$DESKTOP_DISABLE_SCREEN_LOCK" == 1 ]] && lock=false
    write_if_changed "$XFCE_SAVER" <<EOF || true
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-screensaver" version="1.0">
  <property name="saver" type="empty">
    <property name="enabled" type="bool" value="${saver}"/>
  </property>
  <property name="lock" type="empty">
    <property name="enabled" type="bool" value="${lock}"/>
  </property>
</channel>
EOF
}

# lxsession starts the screensaver by the key screensaver of [Startup] in
# desktop.conf: the system default /etc/xdg/lxsession/LXDE/desktop.conf, or the
# user's ~/.config/lxsession/LXDE/desktop.conf once the user has one (lxsession
# writes it on the first change in the session settings, then reads only it).
#
# The system default is ours to write (root-owned /etc). The user's file is
# NEVER written by root: the home directory is the user's, and any component of
# the path may be a symlink the user planted (to /etc/shadow and the like). It
# is edited only when it already exists, by this script run AS THE USER
# (runuser), after a refusal on a symlink in any component and on a real path
# outside the home directory — so the worst a planted link reaches is what the
# user could write anyway. Turning the key off rolls back the system default
# only; the user's own file is the user's to switch back.
LXSESSION_SYS="$R/etc/xdg/lxsession/LXDE/desktop.conf"
LXSESSION_KEY=screensaver
LXSESSION_OFF=disabled

apply_lxsession(){
    local user="$1"
    command -v lxsession >/dev/null 2>&1 || return 0
    if [[ "$DESKTOP_DISABLE_SCREEN_BLANK" != 1 ]]; then
        unset_lxsession_system
        return 0
    fi
    install -d -m 0755 "${LXSESSION_SYS%/*}"
    [[ -f "$LXSESSION_SYS" ]] || printf '[Session]\nwindow_manager=openbox-lxde\n' > "$LXSESSION_SYS"
    set_ini_key "$LXSESSION_SYS" Startup "$LXSESSION_KEY" "$LXSESSION_OFF" \
        || log "lxsession: не записался $LXSESSION_KEY=$LXSESSION_OFF в ${LXSESSION_SYS#"$R"}"
    [[ -n "$user" ]] && lxsession_user "$user"
    return 0
}

unset_lxsession_system(){
    [[ -f "$LXSESSION_SYS" ]] || return 0
    if grep -qxF "$LXSESSION_KEY=$LXSESSION_OFF" "$LXSESSION_SYS"; then
        del_ini_key "$LXSESSION_SYS" "$LXSESSION_KEY"
    fi
}

# safe_user_path <home> <file>: 0 — no component from <home> down to <file> is a
# symlink and the real path stays inside the real <home>.
safe_user_path(){
    local home="$1" file="$2" rel part cur
    [[ -d "$home" && ! -L "$home" ]] || return 1
    rel="${file#"$home"/}"
    [[ "$rel" != "$file" ]] || return 1
    cur="$home"
    while IFS= read -r -d / part || [[ -n "$part" ]]; do
        [[ -n "$part" && "$part" != . && "$part" != .. ]] || return 1
        cur="$cur/$part"
        [[ -L "$cur" ]] && return 1
    done < <(printf '%s' "$rel")
    case "$(realpath -m -- "$file")/" in
        "$(realpath -m -- "$home")"/*) return 0 ;;
    esac
    return 1
}

lxsession_user(){
    local user="$1" home conf
    home="$R$(home_of "$user")"
    conf="$home/.config/lxsession/LXDE/desktop.conf"
    [[ -e "$conf" || -L "$conf" ]] || return 0
    if ! safe_user_path "$home" "$conf"; then
        log "lxsession: ${conf#"$R"} — символическая ссылка в пути или вне домашнего каталога, не правлю"
        return 0
    fi
    # As the user, never as root: runuser drops to the user's uid, gid and groups.
    runuser -u "$user" -- "${BASH_SOURCE[0]}" lxsession-user "$conf" \
        || log "lxsession: ${conf#"$R"} не исправлен (от имени $user)"
}

# The edit itself, run as the user by lxsession_user: refuses a symlink once
# more (the user may have swapped it in meanwhile — harmless now, but no reason
# to follow it).
cmd_lxsession_user(){
    local conf="$1"
    [[ -f "$conf" && ! -L "$conf" ]] || { log "lxsession: $conf — не обычный файл"; exit 1; }
    set_ini_key "$conf" Startup "$LXSESSION_KEY" "$LXSESSION_OFF"
}

# The link <channel>.xml -> our file only when the channel is absent, so what a
# package or an administrator put there is never overwritten.
link_xfconf(){
    local f base
    for f in "$XFCE_POWER" "$XFCE_SAVER"; do
        base="${f%"$XFCE_SUFFIX"}.xml"
        if [[ -f "$f" ]]; then
            [[ -e "$base" || -L "$base" ]] || ln -s "${f##*/}" "$base"
        elif [[ -L "$base" && "$(readlink "$base")" == "${f##*/}" ]]; then
            rm -f -- "$base"
        fi
    done
}

dconf_update(){
    command -v dconf >/dev/null 2>&1 || return 0
    [[ -d "$DCONF_LOCAL" ]] || return 0
    (( DCONF_CHANGED )) || [[ ! -f "$R/etc/dconf/db/local" ]] || return 0
    dconf update || log "dconf update не прошёл — блокировка и затемнение не применятся"
}

# ---------------------------------------------------------------------------
# The session and the display manager
# ---------------------------------------------------------------------------
graphical_user_session(){
    local sid class type
    for sid in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
        class="$(loginctl show-session "$sid" -p Class --value 2>/dev/null || true)"
        type="$(loginctl show-session "$sid" -p Type --value 2>/dev/null || true)"
        [[ "$class" == user && ( "$type" == x11 || "$type" == wayland ) ]] && return 0
    done
    return 1
}

active_dm(){
    local dm
    for dm in gdm3 gdm lightdm; do
        if systemctl is-active "$dm.service" >/dev/null 2>&1; then echo "$dm"; return 0; fi
    done
    return 1
}

dm_fingerprint(){ { gdm_confs; lightdm_confs; } | xargs -r cat 2>/dev/null | sha256sum | cut -c1-64; }

cmd_apply(){
    local mode="$1" user="" wait_s=0 autologin="$DESKTOP_AUTOLOGIN" before after dm
    if [[ "$autologin" == 1 ]]; then
        # The user is created by cloud-init.service, and configure is ordered
        # after it, so it usually exists already. A short wait is insurance
        # for userdata not read yet; a long one would turn into a black
        # screen, and a login screen is better.
        [[ "$mode" == --boot ]] && wait_s=30
        user="$(resolve_user "$wait_s")" || {
            log "пользователь для автологина не найден — автологин не включаю"
            autologin=0
        }
    else
        user="$(resolve_user 0)" || user=""
    fi
    if [[ -n "$user" ]]; then ensure_groups "$user"; fi

    before="$(dm_fingerprint)"
    apply_autologin "$user" "$autologin"
    apply_screen_lock
    apply_screen_blank
    apply_xfce_screensaver
    apply_lxsession "$user"
    link_xfconf
    dconf_update
    after="$(dm_fingerprint)"
    log "автологин=$autologin${user:+ ($user)} блокировка_выкл=$DESKTOP_DISABLE_SCREEN_LOCK затемнение_выкл=$DESKTOP_DISABLE_SCREEN_BLANK"

    [[ "$mode" == --now ]] || return 0
    [[ "$before" == "$after" ]] && return 0
    dm="$(active_dm)" || return 0
    # Somebody's session is not cut off: the autologin change waits for a reboot.
    if graphical_user_session; then
        log "открыта графическая сессия — $dm не перезапускаю, автологин применится со следующей загрузки"
        return 0
    fi
    log "перезапускаю $dm, чтобы автологин применился сейчас"
    # --no-block: configure is a boot unit ordered before the DM, and
    # `cream set` may run inside guestfs-firstboot — a blocking restart from
    # there is a deadlock of systemd jobs.
    systemctl --no-block restart "$dm.service" || log "$dm не перезапустился"
}

cmd_status(){
    local k
    for k in DESKTOP_AUTOLOGIN DESKTOP_AUTOLOGIN_USER DESKTOP_DISABLE_SCREEN_LOCK DESKTOP_DISABLE_SCREEN_BLANK; do
        printf '%s=%s\n' "$k" "${!k}"
    done
    yn(){ if [[ -f "$1" ]]; then echo да; else echo нет; fi; }
    printf 'dconf блокировка: %s; dconf затемнение: %s; X DPMS: %s\n' \
        "$(yn "$DCONF_LOCK")" "$(yn "$DCONF_BLANK")" "$(yn "$XSESSION_BLANK")"
}

# remove: everything this script owns; the autologin is turned off in the DM
# configs (they belong to the packages). The groups stay: taking video away from
# a session user is worse than an extra membership.
cmd_remove(){
    apply_autologin "" 0
    dconf_remove "$DCONF_LOCK" "$DCONF_LOCK_LOCKS" "$DCONF_BLANK" "$DCONF_BLANK_LOCKS" "$DCONF_GDM_BLANK"
    remove_files "$XSESSION_BLANK" "$XFCE_POWER" "$XFCE_SAVER" || true
    link_xfconf
    unset_lightdm_blank
    unset_lxsession_system
    if (( DCONF_CHANGED )) && command -v dconf >/dev/null 2>&1; then
        dconf update || die "dconf update не прошёл"
    fi
    log "ручки сняты; группы пользователя оставлены"
}

case "${1:-}" in
    apply)
        mode="${2:---now}"
        case "$mode" in
            --now|--boot) cmd_apply "$mode" ;;
            *) log "apply: режим --now или --boot, получили '$mode'"; exit 2 ;;
        esac ;;
    status) cmd_status ;;
    remove) cmd_remove ;;
    lxsession-user) cmd_lxsession_user "${2:?}" ;;
    *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
