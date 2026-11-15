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
#   desktop.sh remove         takes away the files; the autologin goes back to
#                             what the record of install holds (or off)
#   desktop.sh mark-legacy V  hooks/upgrade from version V: below 2.0.0 the
#                             record becomes the marker legacy (if none is there)
#
# Keys:
#   DESKTOP_AUTOLOGIN=              empty — the autologin is not ours to manage;
#                                   0 — off; 1 — login without a password
#   DESKTOP_AUTOLOGIN_USER=         empty — the cloud-init user
#   DESKTOP_DISABLE_SCREEN_LOCK=0   1 — no auto-lock (manual lock stays)
#   DESKTOP_DISABLE_SCREEN_BLANK=0  1 — no dimming, blanking, DPMS and sleep
#
# A key turned off means "our file is absent": the behaviour of the OS applies,
# not our "off". One code for gdm3 and lightdm, so gnome, xfce4, lxde and
# cloud-user-desktop cannot diverge the way their copies of
# disable_powersave.sh once did.
#
# The autologin lives in the configs of the display manager, which belong to the
# packages and the owner (spec 2026-11-12-existing-desktop §4.3, rulings Р1,
# П6, П12, П17). At CREAM_REASON=install, before any write, the lines of the
# autologin keys are recorded in $CREAM_STATE_DIR/autologin.before (never
# overwritten); an empty key or remove after a write of ours puts those lines
# back byte for byte. The marker legacy (an upgrade from 1.x, what was there is
# unknown) or no record — the autologin is turned off, as 1.x did. SDDM: key 0
# or 1 is refused (exit 1 after the other knobs), its autologin is manual.
set -euo pipefail

R="${CREAM_ROOT:-}"; R="${R%/}"
DESKTOP_AUTOLOGIN="${DESKTOP_AUTOLOGIN-}"
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
# autologin_file <conf> <user> <on>: the autologin of one config of gdm3 or
# lightdm (by its path) on or off.
autologin_file(){
    local conf="$1" user="$2" on="$3" section
    case "${conf#"$R"}" in
        /etc/gdm3/*)
            if [[ "$on" == 1 ]]; then
                { set_ini_key "$conf" daemon AutomaticLoginEnable true \
                    && set_ini_key "$conf" daemon AutomaticLogin "$user"; } \
                    || die "gdm: не записался автологин в ${conf#"$R"}"
            else
                set_ini_key "$conf" daemon AutomaticLoginEnable false \
                    || die "gdm: не записался отказ от автологина в ${conf#"$R"}"
            fi ;;
        *)
            section="$(lightdm_seat_section "$conf")"
            if [[ "$on" == 1 ]]; then
                { set_ini_key "$conf" "$section" autologin-user "$user" \
                    && set_ini_key "$conf" "$section" autologin-user-timeout 0; } \
                    || die "lightdm: не записался автологин в ${conf#"$R"}"
            else
                if [[ "$conf" == "$LIGHTDM_AUTO" ]] && grep -qxF "$LIGHTDM_AUTO_MARK" "$conf"; then
                    set_ini_key "$conf" "$section" autologin-user "" \
                        || die "lightdm: не записался отказ от автологина"
                else
                    del_ini_key "$conf" autologin-user
                fi
                del_ini_key "$conf" autologin-user-timeout
            fi ;;
    esac
}

# Xubuntu can ship only /usr/share/lightdm/lightdm.conf.d, with no local
# config at all. Create our own layer only in that case; never edit /usr/share.
LIGHTDM_AUTO="$R/etc/lightdm/lightdm.conf.d/90-cream-desktop-autologin.conf"
LIGHTDM_AUTO_MARK='# cream desktop: generated autologin layer'
apply_autologin(){
    local user="$1" on="$2" conf
    if [[ -z "$(lightdm_confs)" ]] && {
        [[ -d "$R/usr/share/lightdm/lightdm.conf.d" || -x "$R/usr/sbin/lightdm" ]]
    }; then
        printf '%s\n[Seat:*]\n' "$LIGHTDM_AUTO_MARK" | write_if_changed "$LIGHTDM_AUTO" || true
    fi
    while read -r conf; do
        [[ -n "$conf" ]] || continue
        autologin_file "$conf" "$user" "$on"
    done < <(gdm_confs; lightdm_confs)
}

# ---------------------------------------------------------------------------
# The record of the autologin as it was (spec §4.3, rulings Р1, П12, П17)
#
#   desktop-autologin 1                       head
#   file /etc/gdm3/custom.conf                a config there was at install
#   eol 1                                     1 — it ended with a newline
#   absent daemon                             the section of the keys was not
#                                             there (set_ini_key appends it)
#   line<TAB>occ<TAB>idx<TAB>section<TAB>raw  every line of a tracked key, the
#                                             commented ones included, in any
#                                             section: the occ-th [section],
#                                             after idx other lines of it
#
# or the single line "legacy" (hooks/upgrade from 1.x: what was there is
# unknown). The marker autologin.written says "a key 0/1 of ours was written
# since the record or the last return" — an empty key and remove put the lines
# back only then, so what the owner changed meanwhile under an empty key stays.
# ---------------------------------------------------------------------------
STATE_DIR="${CREAM_STATE_DIR:-$R/var/lib/cream/ext/desktop}"
AUTOLOGIN_REC="$STATE_DIR/autologin.before"
AUTOLOGIN_WRITTEN="$STATE_DIR/autologin.written"
REC_HEAD="desktop-autologin 1"
REC_LEGACY=legacy
GDM_KEYS="AutomaticLoginEnable|AutomaticLogin"
LIGHTDM_KEYS="autologin-user|autologin-user-timeout"
# The section name of a header line, as both the record and the return read it.
AWK_SECNAME='function secname(l) { sub(/^[[:space:]]*\[/, "", l); sub(/\].*$/, "", l); gsub(/\t/, " ", l); return l }'

# The regexp of set_ini_key: a key line, commented or not.
key_re(){ printf '^[[:space:]]*#*[[:space:]]*(%s)[[:space:]]*=' "$1"; }

conf_keys(){ case "$1" in /etc/gdm3/*) echo "$GDM_KEYS" ;; *) echo "$LIGHTDM_KEYS" ;; esac; }

# known_conf <rel>: a path the record may name — a config of gdm3 or lightdm.
known_conf(){
    [[ "$1" =~ ^/etc/gdm3/(daemon|custom)\.conf$ || "$1" == /etc/lightdm/lightdm.conf \
        || "$1" =~ ^/etc/lightdm/lightdm\.conf\.d/[^/]+\.conf$ ]]
}

has_section(){
    W="$2" awk "$AWK_SECNAME"' /^[[:space:]]*\[/ && secname($0) == ENVIRON["W"] { f = 1 } END { exit !f }' "$1"
}

record_file(){
    local conf="$1" rel="${1#"$R"}" sec eol=1
    case "$rel" in
        /etc/gdm3/*) sec=daemon ;;
        *) sec="$(lightdm_seat_section "$conf")" ;;
    esac
    if [[ -s "$conf" && -n "$(tail -c 1 -- "$conf")" ]]; then eol=0; fi
    printf 'file %s\neol %s\n' "$rel" "$eol"
    has_section "$conf" "$sec" || printf 'absent %s\n' "$sec"
    awk -v re="$(key_re "$(conf_keys "$rel")")" "$AWK_SECNAME"'
        BEGIN { cur = ""; occ[""] = 1; o = 1; idx = 0 }
        /^[[:space:]]*\[/ { s = secname($0); occ[s]++; cur = s; o = occ[s]; idx = 0; next }
        $0 ~ re { printf "line\t%d\t%d\t%s\t%s\n", o, idx, cur, $0; next }
        { idx++ }
    ' "$conf"
}

# take_record: at CREAM_REASON=install, before any write; a record that is there
# (of an earlier install, legacy, or not ours) is never overwritten.
take_record(){
    local conf tmp
    [[ -e "$AUTOLOGIN_REC" || -L "$AUTOLOGIN_REC" ]] && return 0
    install -d -m 0755 "$STATE_DIR"
    tmp="$(mktemp "$STATE_DIR/.autologin.XXXXXX")" || die "запись автологина не создана"
    if ! {
        echo "$REC_HEAD"
        while read -r conf; do
            [[ -n "$conf" ]] || continue
            known_conf "${conf#"$R"}" || continue
            record_file "$conf"
        done < <(gdm_confs; lightdm_confs)
    } > "$tmp" || ! mv -f -T -- "$tmp" "$AUTOLOGIN_REC"; then
        rm -f -- "$tmp"
        die "запись прежнего автологина не сохранена — автологин не трогаю"
    fi
    log "прежний автологин записан (${AUTOLOGIN_REC#"$R"})"
}

# rec_kind: none | legacy | record | junk (a file that is not a record of ours).
rec_kind(){
    local head line cur=0 re_line=$'^line\t[0-9]+\t[0-9]+\t[^\t]*\t'
    if [[ ! -e "$AUTOLOGIN_REC" && ! -L "$AUTOLOGIN_REC" ]]; then echo none; return 0; fi
    if [[ -L "$AUTOLOGIN_REC" || ! -f "$AUTOLOGIN_REC" ]]; then echo junk; return 0; fi
    {
        IFS= read -r head || head=""
        if [[ "$head" == "$REC_LEGACY" ]]; then
            if IFS= read -r line || [[ -n "${line:-}" ]]; then echo junk; else echo legacy; fi
            return 0
        fi
        [[ "$head" == "$REC_HEAD" ]] || { echo junk; return 0; }
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                "file "*) known_conf "${line#file }" || { echo junk; return 0; }; cur=1 ;;
                "eol 0" | "eol 1" | "absent "*) (( cur )) || { echo junk; return 0; } ;;
                *) { [[ "$line" =~ $re_line ]] && (( cur )); } || { echo junk; return 0; } ;;
            esac
        done
    } < "$AUTOLOGIN_REC"
    echo record
}

# return_file <rel>: the tracked lines of one config as the record holds them —
# every tracked line now there goes, the recorded ones come back at their place
# (the section, its occurrence, the other lines before them), a section that
# set_ini_key appended goes, the final newline is as it was. Other lines stay;
# an unchanged file is not rewritten (in place: mode and owner stay).
return_file(){
    local rel="$1" conf="$R$1" block tmp eol
    if [[ ! -f "$conf" ]]; then
        log "$rel нет — автологин возвращать некуда"
        return 0
    fi
    block="$(mktemp)"
    W="file $rel" awk '$0 == ENVIRON["W"] { on = 1; next } /^file / { on = 0 } on' "$AUTOLOGIN_REC" > "$block"
    eol="$(awk '/^eol / { print $2; exit }' "$block")"
    tmp="$(mktemp "${conf%/*}/.desktop.XXXXXX")" || { rm -f -- "$block"; die "$rel: автологин не вернулся"; }
    if ! awk -v re="$(key_re "$(conf_keys "$rel")")" -v rel="$rel" "$AWK_SECNAME"'
        function put(c, oc, at,   j) {
            for (j = 1; j <= m; j++)
                if (!used[j] && rs[j] == c && ro[j] == oc && (at < 0 || ri[j] == at)) { print rr[j]; used[j] = 1 }
        }
        FNR == NR {
            if ($0 ~ /^absent /) { absent = substr($0, 8); has_absent = 1 }
            else if ($0 ~ /^line\t/) {
                r = substr($0, 6)
                p = index(r, "\t"); ro[++m] = substr(r, 1, p - 1) + 0; r = substr(r, p + 1)
                p = index(r, "\t"); ri[m] = substr(r, 1, p - 1) + 0; r = substr(r, p + 1)
                p = index(r, "\t"); rs[m] = substr(r, 1, p - 1); rr[m] = substr(r, p + 1)
            }
            next
        }
        $0 ~ re { next }
        { sk[++n] = $0 }
        END {
            if (has_absent && n && sk[n] ~ /^[[:space:]]*\[/ && secname(sk[n]) == absent) {
                n--
                if (n && sk[n] == "") n--
            }
            cur = ""; occ[""] = 1; o = 1; idx = 0
            for (i = 1; i <= n; i++) {
                if (sk[i] ~ /^[[:space:]]*\[/) {
                    put(cur, o, -1)
                    s = secname(sk[i]); occ[s]++; cur = s; o = occ[s]; idx = 0
                    print sk[i]; continue
                }
                put(cur, o, idx)
                print sk[i]; idx++
            }
            put(cur, o, -1)
            for (j = 1; j <= m; j++) if (!used[j]) lost++
            if (lost) printf "desktop: %s: %d строк автологина некуда вернуть — их секции больше нет\n", rel, lost > "/dev/stderr"
        }
    ' "$block" "$conf" > "$tmp"; then
        rm -f -- "$block" "$tmp"
        die "$rel: автологин не вернулся"
    fi
    rm -f -- "$block"
    if [[ "$eol" == 0 && -s "$tmp" ]]; then truncate -s -1 -- "$tmp"; fi
    cmp -s -- "$tmp" "$conf" || cat -- "$tmp" > "$conf"
    rm -f -- "$tmp"
}

# return_record: every config of the record back; a config that appeared after
# install — off, as 1.x.
return_record(){
    local line conf
    local -A seen=()
    while IFS= read -r line; do
        [[ "$line" == "file "* ]] || continue
        seen["${line#file }"]=1
        return_file "${line#file }"
    done < "$AUTOLOGIN_REC"
    while read -r conf; do
        [[ -n "$conf" && -z "${seen[${conf#"$R"}]:-}" ]] || continue
        autologin_file "$conf" "" 0
    done < <(gdm_confs; lightdm_confs)
    log "автологин возвращён, как был при установке"
}

# return_autologin <kind>: the autologin is no longer ours — back as recorded, or
# off (legacy, no record). The record of install stays until remove (П17).
return_autologin(){
    case "$1" in
        record) return_record ;;
        *)
            apply_autologin "" 0
            log "прежний автологин неизвестен (${1/none/записи нет}) — выключен, как в 1.x" ;;
    esac
    if [[ -f "$LIGHTDM_AUTO" ]] && grep -qxF "$LIGHTDM_AUTO_MARK" "$LIGHTDM_AUTO"; then
        # Preserve any unrelated administrator additions, if there are any.
        local extra
        extra="$(grep -vE '^(# cream desktop: generated autologin layer|\[Seat:\*\]|autologin-user(-timeout)?=.*|[[:space:]]*)$' "$LIGHTDM_AUTO" || true)"
        if [[ -z "$extra" ]]; then
            rm -f -- "$LIGHTDM_AUTO"
        else
            del_ini_key "$LIGHTDM_AUTO" autologin-user
            del_ini_key "$LIGHTDM_AUTO" autologin-user-timeout
        fi
    fi
}

# sddm_dm: the display manager is SDDM — by the files, like existing-desktop:
# the link display-manager.service, else /etc/X11/default-display-manager.
sddm_dm(){
    local unit="$R/etc/systemd/system/display-manager.service" t
    if [[ -L "$unit" ]]; then
        t="$(readlink -- "$unit")"
        [[ "${t##*/}" == sddm.service ]]
        return
    fi
    [[ -f "$R/etc/X11/default-display-manager" ]] || return 1
    t="$(head -n 1 -- "$R/etc/X11/default-display-manager")"
    [[ "${t##*/}" == sddm ]]
}

cmd_mark_legacy(){
    local prev="$1" major tmp
    major="${prev%%.*}"
    if [[ "$major" =~ ^[0-9]+$ ]] && (( 10#$major >= 2 )); then return 0; fi
    if [[ -e "$AUTOLOGIN_REC" || -L "$AUTOLOGIN_REC" ]]; then
        log "запись прежнего автологина уже есть — не трогаю"
        return 0
    fi
    install -d -m 0755 "$STATE_DIR"
    tmp="$(mktemp "$STATE_DIR/.autologin.XXXXXX")" || die "маркер legacy не записан"
    if ! printf '%s\n' "$REC_LEGACY" > "$tmp" || ! mv -f -T -- "$tmp" "$AUTOLOGIN_REC"; then
        rm -f -- "$tmp"
        die "маркер legacy не записан"
    fi
    log "обновление с $(printf '%s' "$prev" | tr -cd '[:alnum:].~+-'): прежний автологин неизвестен (маркер legacy) — пустой DESKTOP_AUTOLOGIN и remove выключат его, как 1.x"
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
# Marker: the system desktop.conf did not exist and was created by us — then
# turning the key off removes the whole file, not just the key.
LXSESSION_OURS="${CREAM_STATE_DIR:-$R/var/lib/cream/ext/desktop}/lxsession-desktop-conf.created"
# The edit as the user is bounded: a user could stop the process (SIGSTOP).
LXSESSION_USER_TIMEOUT=30

apply_lxsession(){
    local user="$1"
    command -v lxsession >/dev/null 2>&1 || return 0
    if [[ "$DESKTOP_DISABLE_SCREEN_BLANK" != 1 ]]; then
        unset_lxsession_system
        return 0
    fi
    install -d -m 0755 "${LXSESSION_SYS%/*}"
    if [[ ! -f "$LXSESSION_SYS" ]]; then
        printf '[Session]\nwindow_manager=openbox-lxde\n' > "$LXSESSION_SYS"
        install -d -m 0755 "${LXSESSION_OURS%/*}"
        : > "$LXSESSION_OURS"
    fi
    set_ini_key "$LXSESSION_SYS" Startup "$LXSESSION_KEY" "$LXSESSION_OFF" \
        || log "lxsession: не записался $LXSESSION_KEY=$LXSESSION_OFF в ${LXSESSION_SYS#"$R"}"
    [[ -n "$user" ]] && lxsession_user "$user"
    return 0
}

unset_lxsession_system(){
    if [[ -e "$LXSESSION_OURS" ]]; then
        rm -f -- "$LXSESSION_SYS" "$LXSESSION_OURS"
        rmdir "${LXSESSION_SYS%/*}" "${LXSESSION_SYS%/*/*}" 2>/dev/null || true
        return 0
    fi
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
    # The user owns that process, so it gets nothing of ours: every descriptor
    # above stderr is closed (CREAM_LOCK_FD — the flock of the domain, which a
    # stopped or ptraced process would hold), stdin is /dev/null, its output goes
    # to a file of ours (not the pipe of cream), the environment is empty but
    # PATH and LANG, and it is killed after LXSESSION_USER_TIMEOUT seconds.
    local out rc=0
    out="$(mktemp)"
    (
        close_fds
        exec timeout -k 5 "$LXSESSION_USER_TIMEOUT" runuser -u "$user" -- \
            env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LANG=C.UTF-8 \
            "${BASH_SOURCE[0]}" lxsession-user "$conf" < /dev/null > "$out" 2>&1
    ) || rc=$?
    # The output is the user's: no control characters into the journal and no
    # line passing for ours. iconv -c keeps valid UTF-8 only (a stray 0x80–0x9f
    # byte goes), so C0 and DEL are ASCII bytes and C1 is exactly \xc2[\x80-\x9f]:
    # deleting whole characters of valid UTF-8 cannot build a new one. Every
    # line is marked as the user's.
    head -c 4096 "$out" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null \
        | LC_ALL=C tr -d '\000-\011\013-\037\177' \
        | LC_ALL=C sed -e 's/\xc2[\x80-\x9f]//g' -e 's/^/lxsession-user: /' >&2 || true
    rm -f -- "$out"
    if (( rc != 0 )); then
        log "lxsession: ${conf#"$R"} не исправлен от имени $user (код $rc)"
    fi
    return 0
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

# The edit itself, run as the user by lxsession_user: refuses a symlink once
# more (the user may have swapped it in meanwhile — harmless now, but no reason
# to follow it).
cmd_lxsession_user(){
    local conf="$1"
    (( EUID != 0 )) || { log "lxsession-user: не от root — только от имени пользователя"; exit 1; }
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
    for dm in gdm3 gdm lightdm sddm; do
        if systemctl is-active "$dm.service" >/dev/null 2>&1; then echo "$dm"; return 0; fi
    done
    return 1
}

dm_fingerprint(){ { gdm_confs; lightdm_confs; } | xargs -r cat 2>/dev/null | sha256sum | cut -c1-64; }

cmd_apply(){
    local mode="$1" user="" wait_s=0 autologin="$DESKTOP_AUTOLOGIN" before after dm sddm=0 kind
    # 1 — on; empty — not ours to manage; anything else — off.
    if [[ -n "$autologin" && "$autologin" != 1 ]]; then autologin=0; fi
    # The record — before anything is written (Р1: only at install; at boot,
    # apply and upgrade the files may hold what 1.x wrote).
    if [[ "${CREAM_REASON:-}" == install ]]; then take_record; fi
    if [[ -n "$autologin" ]] && sddm_dm; then sddm=1; fi
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
    if (( sddm )); then
        :
    elif [[ -n "$autologin" ]]; then
        # The mark first: a write that stops half-way is still returned.
        install -d -m 0755 "$STATE_DIR"
        : > "$AUTOLOGIN_WRITTEN"
        apply_autologin "$user" "$autologin"
    else
        kind="$(rec_kind)"
        if [[ "$kind" == legacy ]] || [[ -e "$AUTOLOGIN_WRITTEN" ]]; then
            [[ "$kind" != junk ]] || die "${AUTOLOGIN_REC#"$R"} — не запись desktop; автологин не возвращаю"
            return_autologin "$kind"
            rm -f -- "$AUTOLOGIN_WRITTEN"
            if [[ "$kind" == legacy ]]; then rm -f -- "$AUTOLOGIN_REC"; fi
        fi
    fi
    apply_screen_lock
    apply_screen_blank
    apply_xfce_screensaver
    apply_lxsession "$user"
    link_xfconf
    dconf_update
    after="$(dm_fingerprint)"
    log "автологин=${autologin:-не управляю}${user:+ ($user)} блокировка_выкл=$DESKTOP_DISABLE_SCREEN_LOCK затемнение_выкл=$DESKTOP_DISABLE_SCREEN_BLANK"
    # The other knobs are applied; the autologin of SDDM is refused (§4.3: it
    # needs Session=, and the X11 session of Plasma is named differently in 5.27
    # and 6 — not measured yet).
    (( sddm == 0 )) || die "автологин SDDM не поддержан: /etc/sddm.conf.d/, вручную (DESKTOP_AUTOLOGIN= — не управлять)"

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
    local dm
    if dm="$(active_dm)"; then
        if [[ "$dm" == sddm ]]; then
            echo "менеджер входа: sddm — автологин SDDM не поддержан: /etc/sddm.conf.d/, вручную"
        else
            echo "менеджер входа: $dm"
        fi
    else
        echo "менеджер входа: не запущен"
    fi
    case "$(rec_kind)" in
        record) echo "прежний автологин: записан при установке — вернётся при пустом ключе и remove" ;;
        legacy) echo "прежний автологин: неизвестен (обновление с 1.x) — пустой ключ и remove выключат его" ;;
        none) echo "прежний автологин: записи нет — remove выключит его, как 1.x" ;;
        junk) echo "прежний автологин: ${AUTOLOGIN_REC#"$R"} — не запись desktop" ;;
    esac
}

# remove: everything this script owns; the autologin goes back to what the
# record of install holds when a key of ours was written since (else it stays
# as it is), off with the marker legacy or no record — the DM configs belong to
# the packages and the owner. A record that is not ours — refused before any
# write. The groups stay: taking video away from a session user is worse than
# an extra membership.
cmd_remove(){
    local kind
    kind="$(rec_kind)"
    [[ "$kind" != junk ]] || die "${AUTOLOGIN_REC#"$R"} — не запись desktop; ничего не снимаю (проверьте и удалите её вручную)"
    dconf_remove "$DCONF_LOCK" "$DCONF_LOCK_LOCKS" "$DCONF_BLANK" "$DCONF_BLANK_LOCKS" "$DCONF_GDM_BLANK"
    remove_files "$XSESSION_BLANK" "$XFCE_POWER" "$XFCE_SAVER" || true
    link_xfconf
    unset_lightdm_blank
    unset_lxsession_system
    # After unset_lightdm_blank: the lines of lightdm are returned to the file
    # without our xserver-command.
    if [[ "$kind" != record || -e "$AUTOLOGIN_WRITTEN" ]]; then
        return_autologin "$kind"
    fi
    rm -f -- "$AUTOLOGIN_REC" "$AUTOLOGIN_WRITTEN"
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
    mark-legacy) cmd_mark_legacy "${2-}" ;;
    *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
