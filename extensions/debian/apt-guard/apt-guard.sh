# shellcheck shell=bash
# Library `apt-guard` (cream/v1, kind: library): the `remove` hooks of the
# catalog take away only the apt packages their `install` put on — never
# anything apt would take along with them. Sourced, never executed; the
# consumer declares `depends: [{name: apt-guard, version: ">=1.0.0 <2"}]` and
# its hook does
#
#   source "${CREAM_ROOT:-}/opt/cream/ext/apt-guard/apt-guard.sh"
#
# WHY. `apt-get remove X` also takes every installed package that depends on X:
# network-manager would take network-manager-gnome and with it the desktop
# metapackage, docker — whatever came later on top of containerd.io. The hook
# cannot know what the operator installed after it, so apt is asked first in
# simulation (`apt-get -s`), and anything besides our own packages in the
# answer is a refusal before any change.
#
#   apt_guard_check VERB PKG…   VERB remove|purge. 0 — apt would take only
#                               PKG…; 1 — the simulation failed, a name is not
#                               a package name, or apt would take others (named
#                               on stderr with the way out). Changes nothing.
#   apt_guard_remove VERB PKG…  apt_guard_check, then apt-get -q -y VERB PKG….
#                               1 — refused or apt failed.
#
# No PKG — 0 and apt is not called. Names come from the consumer's own state
# file; one that is not a Debian package name (an option like `-o…`, a path,
# control characters) is refused rather than passed to apt. A name in the
# simulation is compared with and without its `:arch` suffix (apt prints
# `pkg:arm64` for some).
#
# The way out printed with a refusal is APT_GUARD_HINT when the caller sets it,
# else `cream remove --forget <ext>`. The caller's log_error is used when
# defined; plain stderr otherwise. Library code sets no shell options.

_apt_guard_error(){
    if declare -F log_error >/dev/null; then log_error "$@"; else >&2 echo "[ERROR] ${CREAM_EXT:-apt-guard}: $*"; fi
}

# _apt_guard_safe TEXT: TEXT cut to 64 characters, anything but [[:alnum:]+.:_-] as '?'.
_apt_guard_safe(){ printf '%s' "${1:0:64}" | LC_ALL=C tr -c '[:alnum:]+.:_-' '?'; }

apt_guard_check(){
    local verb="${1:-}" sim word pkg p mine
    local -a extra=()
    case "$verb" in
        remove|purge) ;;
        *) _apt_guard_error "apt_guard: неизвестное действие '$(_apt_guard_safe "$verb")' (remove|purge)"; return 1 ;;
    esac
    shift
    (( $# )) || return 0
    for p in "$@"; do
        if [[ ! "$p" =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9]+)?$ ]]; then
            _apt_guard_error "в записи пакетов не имя пакета: '$(_apt_guard_safe "$p")' — apt не зову"
            return 1
        fi
    done
    sim="$(apt-get -s "$verb" "$@")" || { _apt_guard_error "apt-get -s $verb $* не прошёл"; return 1; }
    while read -r word pkg _; do
        [[ "$word" == Remv || "$word" == Purg ]] || continue
        mine=""
        for p in "$@"; do
            [[ "$p" == "$pkg" || "${p%%:*}" == "${pkg%%:*}" ]] && mine=1
        done
        [[ -n "$mine" ]] || extra+=("$pkg")
    done <<< "$sim"
    if (( ${#extra[@]} )); then
        _apt_guard_error "вместе с $* apt снял бы и чужие пакеты: ${extra[*]}"
        _apt_guard_error "${APT_GUARD_HINT:-сними руками или забудь запись: cream remove --forget ${CREAM_EXT:-<расширение>}}"
        return 1
    fi
    return 0
}

apt_guard_remove(){
    local verb="${1:-}"
    apt_guard_check "$@" || return 1
    shift
    (( $# )) || return 0
    apt-get -q -y "$verb" "$@" || { _apt_guard_error "apt-get $verb $* не прошёл"; return 1; }
}
