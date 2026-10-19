# shellcheck shell=bash
# Shared functions of the rustdesk hooks (sourced from hooks/*, from the
# extension tree: "$CREAM_EXT_DIR/files/common.sh"). Declares functions only.

log(){ >&2 echo "rustdesk: $*"; }

# User files are touched only by a process running AS THAT USER, bounded in
# time (a user could stop it) and with nothing of ours: every descriptor above
# stderr closed (CREAM_LOCK_FD — the lock of the domain), stdin /dev/null, the
# environment empty but PATH and LANG. The same rule as the extension desktop.
AS_USER_TIMEOUT=30

close_fds(){
    local fd fds=()
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

# as_user USER OUT COMMAND…: run COMMAND as USER; its stdout goes to the file
# OUT, its stderr — cleaned of control characters, marked as the user's — to
# ours. Status is the command's.
as_user(){
    local user="$1" out="$2" err rc=0
    shift 2
    err="$(mktemp)"
    (
        close_fds
        exec timeout -k 5 "$AS_USER_TIMEOUT" runuser -u "$user" -- \
            env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LANG=C.UTF-8 "$@" < /dev/null > "$out" 2> "$err"
    ) || rc=$?
    head -c 4096 "$err" | LC_ALL=C tr -d '\000-\011\013-\037\177' | sed "s/^/rustdesk ($user): /" >&2 || true
    rm -f -- "$err"
    return "$rc"
}

# users: "name home" of every account with UID 1000..65533 and a home
# directory (65534 is nobody).
users(){
    local name uid home
    while IFS=: read -r name _ uid _ _ home _; do
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        (( uid >= 1000 && uid < 65534 )) || continue
        [[ "$name" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || continue
        [[ -n "$home" && "$home" != / && -d "${R:-}$home" ]] || continue
        printf '%s %s\n' "$name" "$home"
    done < <(getent passwd)
}
