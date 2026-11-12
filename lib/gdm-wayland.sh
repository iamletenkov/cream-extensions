# shellcheck shell=bash
# gdm-wayland.sh — WaylandEnable of gdm3: read it, set it to false with a record
# of what was there, put back exactly that. Sourced, never executed.
#
# ONE COPY IN GIT: lib/gdm-wayland.sh (spec 2026-11-12-existing-desktop §4.5,
# §4.6). The snapshot and tools/stage-catalog.sh lay it into
# files/gdm-wayland.sh of every consumer of lib/gdm-wayland.consumers (gdm-xorg,
# gnome); a hook does
#
#   source "${CREAM_EXT_DIR:?run by cream}/files/gdm-wayland.sh"
#   res="$(gw_set_false "$R" "$CREAM_STATE_DIR/wayland.before")" || exit 1
#
# WHERE. Which file gdm reads is decided when the PACKAGE is built (measured
# 2026-09-03): Debian — /etc/gdm3/daemon.conf, Ubuntu — /etc/gdm3/custom.conf;
# a key in the other file is silently ignored. Both are dpkg conffiles. Every
# one of the two that exists is read and edited, daemon.conf first — the order
# of gnome/hooks/install. Only the [daemon] group counts (GKeyFile: the last
# uncommented line wins; false and 0 are false, anything else is true).
#
#   gw_read ROOT
#       One line "<state> <path>" per existing file, state is absent (no line in
#       [daemon]), commented (only "#WaylandEnable=…"), true, false, or link (a
#       symlink — not read, never written). 0 — a file is there; 1 — no gdm3
#       config.
#   gw_set_false ROOT STATE-FILE
#       Records first, writes after: the record of every file (its state and
#       the exact line it replaces, or that the line is new) goes to STATE-FILE;
#       a repeat never overwrites what is there, it only appends (atomically,
#       before the edit) a file the record lacks — custom.conf that appeared
#       after the first run; a STATE-FILE that is not a record — refused. Then
#       WaylandEnable=false: a true line is replaced in place (the last, the one
#       that counts), absent or commented — a new line right after [daemon], no
#       [daemon] — the group is appended. Prints "changed" or "unchanged".
#       0 — done; 1 — refused, nothing written (no gdm3 config, a link, a file
#       that is not a regular one) or a write failed.
#   gw_restore ROOT STATE-FILE
#       Puts back what STATE-FILE recorded: the replaced line byte for byte at
#       its place, the added line (and the appended group) removed; lines others
#       wrote meanwhile stay. A line we wrote and someone changed since is left
#       as it is, with a warning; a file already back (a repeat after a return
#       that stopped half-way) is skipped silently. A recorded file that is gone
#       is not created. A replaced entry without its raw WaylandEnable line —
#       refused before any write.
#       STATE-FILE is removed. Prints "changed" or "unchanged". 0 — done (no
#       STATE-FILE — nothing to do); 1 — refused, STATE-FILE kept (a link, a path
#       that is not a gdm3 config, an unknown record) or a write failed.
#
# The rest of each file stays byte for byte, the final newline (or its absence)
# included; mode and owner are kept, an unchanged file is not rewritten.
# Nothing here calls systemctl or restarts gdm: that is the consumer's (code 10).
# The caller's log_warn/log_error are used when defined; plain stderr otherwise.
# Library code sets no shell options and prints nothing but its result to stdout.

_GW_RECORD_HEAD="gdm-wayland 1"
_GW_LINE="WaylandEnable=false"

_gw_warn(){
    if declare -F log_warn >/dev/null; then log_warn "$@"; else >&2 echo "[WARN] ${CREAM_EXT:-gdm-wayland}: $*"; fi
}

_gw_error(){
    if declare -F log_error >/dev/null; then log_error "$@"; else >&2 echo "[ERROR] ${CREAM_EXT:-gdm-wayland}: $*"; fi
}

_gw_names(){ printf '%s\n' /etc/gdm3/daemon.conf /etc/gdm3/custom.conf; }

_gw_known(){ [[ "$1" == /etc/gdm3/daemon.conf || "$1" == /etc/gdm3/custom.conf ]]; }

# _gw_safe ROOT REL: 0 — REL can be written: neither /etc/gdm3 nor the file is a
# link, and the file, when there, is a regular one.
_gw_safe(){
    local root="$1" rel="$2"
    if [[ -L "$root/etc/gdm3" ]]; then
        _gw_error "/etc/gdm3 — ссылка; по ней не пишу"
        return 1
    fi
    if [[ -L "$root$rel" ]]; then
        _gw_error "$rel — ссылка; по ней не пишу"
        return 1
    fi
    if [[ -e "$root$rel" && ! -f "$root$rel" ]]; then
        _gw_error "$rel — не обычный файл; не пишу"
        return 1
    fi
}

# _gw_load FILE: the lines into _gw_l, _gw_eol — 1 when the file ends with a
# newline (or is empty). The caller declares both (dynamic scope).
_gw_load(){
    _gw_l=()
    mapfile -t _gw_l < "$1" || return 1
    _gw_eol=1
    if [[ -s "$1" && -n "$(tail -c 1 -- "$1")" ]]; then _gw_eol=0; fi
}

# _gw_scan: over _gw_l — _gw_act (indexes of the uncommented WaylandEnable lines
# of [daemon]), _gw_com (commented ones), _gw_hdr / _gw_lasthdr (first / last
# [daemon] header, -1 — none).
_gw_scan(){
    local i line sec="" re_group='^[[:space:]]*\[([^]]*)\]'
    local re_on='^[[:space:]]*WaylandEnable[[:space:]]*='
    local re_off='^[[:space:]]*#+[[:space:]]*WaylandEnable[[:space:]]*='
    _gw_act=(); _gw_com=0; _gw_hdr=-1; _gw_lasthdr=-1
    for i in "${!_gw_l[@]}"; do
        line="${_gw_l[i]}"
        if [[ "$line" =~ $re_group ]]; then
            sec="${BASH_REMATCH[1]}"
            if [[ "$sec" == daemon ]]; then
                if (( _gw_hdr < 0 )); then _gw_hdr=$i; fi
                _gw_lasthdr=$i
            fi
            continue
        fi
        [[ "$sec" == daemon ]] || continue
        if [[ "$line" =~ $re_on ]]; then
            _gw_act+=("$i")
        elif [[ "$line" =~ $re_off ]]; then
            _gw_com=$((_gw_com + 1))
        fi
    done
}

# _gw_state: absent|commented|true|false of the scanned lines.
_gw_state(){
    local v
    if (( ${#_gw_act[@]} )); then
        v="${_gw_l[${_gw_act[-1]}]#*=}"
        v="${v#"${v%%[![:space:]]*}"}"
        v="${v%"${v##*[![:space:]]}"}"
        if [[ "$v" == false || "$v" == 0 ]]; then echo false; else echo true; fi
    elif (( _gw_com )); then
        echo commented
    else
        echo absent
    fi
}

# _gw_save FILE: _gw_l back into FILE (the final newline as _gw_eol says) with
# its mode and owner; an unchanged file is not rewritten. 0 — written, 1 —
# failed, 2 — nothing to write.
_gw_save(){
    local file="$1" tmp i n="${#_gw_l[@]}"
    tmp="$(mktemp "${file%/*}/.gdm-wayland.XXXXXX")" || return 1
    if ! {
        for (( i = 0; i < n; i++ )); do
            if (( i < n - 1 || _gw_eol )); then printf '%s\n' "${_gw_l[i]}"; else printf '%s' "${_gw_l[i]}"; fi
        done
    } > "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    if cmp -s -- "$tmp" "$file"; then
        rm -f -- "$tmp"
        return 2
    fi
    if chmod --reference="$file" -- "$tmp" && chown --reference="$file" -- "$tmp" \
        && mv -f -T -- "$tmp" "$file"; then
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}

# _gw_del I: drop line I of _gw_l.
_gw_del(){ _gw_l=("${_gw_l[@]:0:$1}" "${_gw_l[@]:$(( $1 + 1 ))}"); }

gw_read(){
    local root="${1%/}" rel n=0
    local -a _gw_l=() _gw_act=()
    local _gw_eol=1 _gw_com=0 _gw_hdr=-1 _gw_lasthdr=-1
    while IFS= read -r rel; do
        if [[ -L "$root/etc/gdm3" || -L "$root$rel" ]]; then
            if [[ -e "$root$rel" || -L "$root$rel" ]]; then
                printf 'link %s\n' "$rel"; n=$((n + 1))
            fi
            continue
        fi
        [[ -f "$root$rel" ]] || continue
        _gw_load "$root$rel" || { _gw_error "$rel не читается"; continue; }
        _gw_scan
        printf '%s %s\n' "$(_gw_state)" "$rel"
        n=$((n + 1))
    done < <(_gw_names)
    (( n > 0 ))
}

gw_set_false(){
    local root="${1%/}" sf="${2:-}" rel st k sep tmp rc line changed=0
    local -a files=() record=() known=() add=()
    local -a _gw_l=() _gw_act=()
    local _gw_eol=1 _gw_com=0 _gw_hdr=-1 _gw_lasthdr=-1
    if [[ -z "$sf" ]]; then
        _gw_error "gw_set_false ROOT STATE-FILE: нужен файл записи"
        return 1
    fi
    while IFS= read -r rel; do
        _gw_safe "$root" "$rel" || return 1
        [[ -f "$root$rel" ]] && files+=("$rel")
    done < <(_gw_names)
    if (( ${#files[@]} == 0 )); then
        _gw_error "нет /etc/gdm3/daemon.conf и /etc/gdm3/custom.conf — gdm3 не стоит"
        return 1
    fi

    # The record first: nothing is written before what it replaces is kept. A
    # repeat keeps the record as it is and only appends the files it lacks (a
    # custom.conf that appeared after the first run) — before they are edited.
    if [[ -s "$sf" ]]; then
        if [[ -L "$sf" || ! -f "$sf" ]] || ! mapfile -t record < "$sf"; then
            _gw_error "запись $sf не читается — файлы gdm3 не трогаю"
            return 1
        fi
        if [[ "${record[0]:-}" != "$_GW_RECORD_HEAD" ]]; then
            _gw_error "$sf — не запись gdm-wayland; файлы gdm3 не трогаю"
            return 1
        fi
        for line in "${record[@]}"; do
            [[ "$line" == "file "* ]] && known+=("${line#file }")
        done
    else
        record=("$_GW_RECORD_HEAD")
    fi
    for rel in "${files[@]}"; do
        [[ " ${known[*]} " == *" $rel "* ]] || add+=("$rel")
    done
    if (( ${#add[@]} )); then
        for rel in "${add[@]}"; do
            _gw_load "$root$rel" || { _gw_error "$rel не читается"; return 1; }
            _gw_scan
            st="$(_gw_state)"
            record+=("file $rel" "state $st")
            case "$st" in
                false) record+=("op none") ;;
                true)
                    record+=("op replaced ${#_gw_act[@]}" "raw ${_gw_l[${_gw_act[-1]}]}")
                    ;;
                *)
                    if (( _gw_hdr >= 0 )); then
                        record+=("op inserted")
                    else
                        sep=0
                        if (( ${#_gw_l[@]} )) && [[ -n "${_gw_l[-1]}" ]]; then sep=1; fi
                        record+=("op appended $sep")
                    fi
                    ;;
            esac
        done
        mkdir -p -- "$(dirname -- "$sf")" || { _gw_error "каталог записи ${sf%/*} не создан"; return 1; }
        tmp="$(mktemp "$sf.XXXXXX")" || { _gw_error "запись $sf не создана"; return 1; }
        if ! printf '%s\n' "${record[@]}" > "$tmp" || ! mv -f -T -- "$tmp" "$sf"; then
            rm -f -- "$tmp"
            _gw_error "запись $sf не сохранена — файлы gdm3 не трогаю"
            return 1
        fi
    fi

    for rel in "${files[@]}"; do
        _gw_load "$root$rel" || { _gw_error "$rel не читается"; return 1; }
        _gw_scan
        case "$(_gw_state)" in
            false) continue ;;
            true) k="${_gw_act[-1]}"; _gw_l[k]="$_GW_LINE" ;;
            *)
                if (( _gw_hdr >= 0 )); then
                    k=$((_gw_hdr + 1))
                    _gw_l=("${_gw_l[@]:0:$k}" "$_GW_LINE" "${_gw_l[@]:$k}")
                else
                    if (( ${#_gw_l[@]} )) && [[ -n "${_gw_l[-1]}" ]]; then _gw_l+=(""); fi
                    _gw_l+=("[daemon]" "$_GW_LINE")
                fi
                ;;
        esac
        rc=0; _gw_save "$root$rel" || rc=$?
        case "$rc" in
            0) changed=1 ;;
            2) ;;
            *) _gw_error "$rel: $_GW_LINE не записался"; return 1 ;;
        esac
    done
    if (( changed )); then echo changed; else echo unchanged; fi
}

gw_restore(){
    local root="${1%/}" sf="${2:-}" line i k n h rc changed=0 cur=-1 done_one
    local -a rfile=() rop=() rarg=() rraw=()
    local -a _gw_l=() _gw_act=()
    local _gw_eol=1 _gw_com=0 _gw_hdr=-1 _gw_lasthdr=-1
    if [[ -z "$sf" ]]; then
        _gw_error "gw_restore ROOT STATE-FILE: нужен файл записи"
        return 1
    fi
    if [[ ! -e "$sf" ]]; then
        echo unchanged
        return 0
    fi

    # Read and check the whole record before any write.
    {
        IFS= read -r line || line=""
        if [[ "$line" != "$_GW_RECORD_HEAD" ]]; then
            _gw_error "$sf — не запись gdm-wayland ($line); не трогаю"
            return 1
        fi
        while IFS= read -r line; do
            case "$line" in
                "file "*) cur=$((cur + 1)); rfile[cur]="${line#file }"; rop[cur]=""; rarg[cur]=""; rraw[cur]="" ;;
                "state "*) ;;
                "op "*)
                    (( cur >= 0 )) || { _gw_error "$sf: op до file"; return 1; }
                    line="${line#op }"; rop[cur]="${line%% *}"
                    [[ "$line" == *" "* ]] && rarg[cur]="${line#* }"
                    ;;
                "raw "*) (( cur >= 0 )) && rraw[cur]="${line#raw }" ;;
                *) _gw_error "$sf: непонятная строка записи; не трогаю"; return 1 ;;
            esac
        done
    } < "$sf"
    for (( i = 0; i <= cur; i++ )); do
        if ! _gw_known "${rfile[i]}"; then
            _gw_error "$sf: ${rfile[i]} — не файл gdm3; не трогаю"
            return 1
        fi
        case "${rop[i]}" in
            none | inserted) ;;
            replaced)
                [[ "${rarg[i]}" =~ ^[1-9][0-9]*$ ]] || { _gw_error "$sf: replaced без номера"; return 1; }
                [[ "${rraw[i]}" =~ ^[[:space:]]*WaylandEnable[[:space:]]*= ]] \
                    || { _gw_error "$sf: replaced без строки raw WaylandEnable=…; не трогаю"; return 1; }
                ;;
            appended) [[ "${rarg[i]}" == 0 || "${rarg[i]}" == 1 ]] || { _gw_error "$sf: appended без признака"; return 1; } ;;
            *) _gw_error "$sf: неизвестная операция «${rop[i]}»"; return 1 ;;
        esac
        _gw_safe "$root" "${rfile[i]}" || return 1
    done

    for (( i = 0; i <= cur; i++ )); do
        [[ "${rop[i]}" != none ]] || continue
        if [[ ! -e "$root${rfile[i]}" ]]; then
            _gw_warn "${rfile[i]} нет — WaylandEnable возвращать некуда"
            continue
        fi
        _gw_load "$root${rfile[i]}" || { _gw_error "${rfile[i]} не читается"; return 1; }
        _gw_scan
        n="${#_gw_l[@]}"
        done_one=0
        case "${rop[i]}" in
            replaced)
                k=$(( rarg[i] - 1 ))
                if (( k < ${#_gw_act[@]} )) && [[ "${_gw_l[${_gw_act[k]}]}" == "$_GW_LINE" ]]; then
                    h="${_gw_act[k]}"
                    _gw_l[h]="${rraw[i]}"
                    done_one=1
                fi
                ;;
            inserted)
                for k in "${_gw_act[@]}"; do
                    if [[ "${_gw_l[k]}" == "$_GW_LINE" ]]; then _gw_del "$k"; done_one=1; break; fi
                done
                ;;
            appended)
                h="$_gw_lasthdr"
                if (( h >= 0 && h + 1 < n )) && [[ "${_gw_l[h + 1]}" == "$_GW_LINE" ]]; then
                    if (( h + 2 == n )); then
                        _gw_del $((h + 1)); _gw_del "$h"
                        if [[ "${rarg[i]}" == 1 ]] && (( h > 0 )) && [[ -z "${_gw_l[h - 1]}" ]]; then _gw_del $((h - 1)); fi
                    else
                        _gw_del $((h + 1))
                    fi
                    done_one=1
                fi
                ;;
        esac
        if (( ! done_one )); then
            # Already back (a repeat after a return that stopped half-way): no
            # warning, nothing to write.
            case "${rop[i]}" in
                replaced)
                    k=$(( rarg[i] - 1 ))
                    if (( k < ${#_gw_act[@]} )) && [[ "${_gw_l[${_gw_act[k]}]}" == "${rraw[i]}" ]]; then continue; fi
                    ;;
                *) (( ${#_gw_act[@]} )) || continue ;;
            esac
            _gw_warn "${rfile[i]}: строки $_GW_LINE, записанной при установке, нет — WaylandEnable поменяли после; оставляю как есть"
            continue
        fi
        rc=0; _gw_save "$root${rfile[i]}" || rc=$?
        case "$rc" in
            0) changed=1 ;;
            2) ;;
            *) _gw_error "${rfile[i]}: прежний WaylandEnable не вернулся"; return 1 ;;
        esac
    done
    rm -f -- "$sf"
    if (( changed )); then echo changed; else echo unchanged; fi
}
