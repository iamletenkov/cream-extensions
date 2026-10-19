# shellcheck shell=bash
# Library `l4t` (cream/v1, kind: library): shared helpers for the L4T
# extensions (l4t-gstreamer, l4t-opencv, tensorrt, l4t-pytorch). Sourced, never
# executed; the consumer declares `depends: [{name: l4t, version: ">=1.0.0 <2"}]`
# and its hook does
#
#   source "${CREAM_ROOT:-}/opt/cream/ext/l4t/l4t.sh"
#
# Every path is taken under CREAM_ROOT ("/" on a machine, a scratch root in
# tests), read at call time: the hook environment of cream sets it.
#
# Three things live here because more than one extension needs exactly the
# same answer:
#
#   l4t_major                 — the L4T major release from /etc/nv_tegra_release
#                               (32 on Jetson Nano, 36 on Orin); the R32 branch
#                               of the stack extensions is chosen by it.
#   l4t_openblas_pin NAME     — OPENBLAS_CORETYPE=ARMV8 for logins
#                               (/etc/environment) and for services
#                               (/etc/systemd/system.conf.d/NAME.conf).
#   l4t_openblas_check CODE   — run python3 CODE with an environment rebuilt
#                               from those files, once per source.
#
# WHY OPENBLAS_CORETYPE. On Jetson Nano (Cortex-A57, L4T R32) the OpenBLAS
# shipped with numpy picks a kernel the CPU does not have, and `import numpy`,
# `cv2` or `torch` dies with `Illegal instruction`. Measured 2026-09-15 on a
# live Nano: rc=132 without the variable, clean import with it. The vendor
# image exported it from the .bashrc of its `jetson` account, which the chain
# removes — so the variable has to be a system setting, not a shell one.
#
# WHY THE CHECK REBUILDS THE ENVIRONMENT FROM FILES. Exporting the variable in
# the check itself would stay green with a typo in a file name or a key. The
# check therefore reads back what was written — the way pam_env and systemd
# will read it — and imports under `env -i` with nothing else.
#
# Whether the import FAILS without the variable is not checked at build time:
# the appliance runs on the build host's CPU (AGX Orin, Cortex-A78AE), where
# OpenBLAS may well pick a working kernel. The final check is on the board.
#
# The caller's log_info/log_error are used when defined; plain stderr otherwise.

L4T_OPENBLAS_CORETYPE=ARMV8

# The root without a trailing slash: "" for "/" or unset.
_l4t_root(){ local r="${CREAM_ROOT:-}"; printf '%s' "${r%/}"; }

_l4t_info(){ if declare -F log_info >/dev/null; then log_info "$@"; else >&2 echo "[INFO] $*"; fi; }
_l4t_error(){ if declare -F log_error >/dev/null; then log_error "$@"; else >&2 echo "[ERROR] $*"; fi; }

# Print the major release: `# R32 (release), REVISION: 6.1, ...` -> 32.
# Empty output and rc=1 when the file is missing or unparsable.
# L4T_RELEASE_FILE overrides the path (default /etc/nv_tegra_release under the root).
l4t_major(){
    local major file="${L4T_RELEASE_FILE:-$(_l4t_root)/etc/nv_tegra_release}"
    [[ -f "$file" ]] || return 1
    major="$(sed -n '1s/^# R\([0-9]\+\) .*/\1/p' "$file")"
    [[ -n "$major" ]] || return 1
    printf '%s\n' "$major"
}

# Pin OPENBLAS_CORETYPE for logins and services. Idempotent: a second call,
# from the same or another extension, changes nothing; a different value of
# the key in /etc/environment is replaced, not duplicated.
l4t_openblas_pin(){
    local name="$1" root
    root="$(_l4t_root)"
    local line="OPENBLAS_CORETYPE=$L4T_OPENBLAS_CORETYPE"
    local envf="$root/etc/environment"
    local dropin="$root/etc/systemd/system.conf.d/$name.conf"

    install -d -m 0755 "$root/etc" || return 1
    touch "$envf" || return 1
    # A file without a trailing newline would glue an appended line to the last one.
    if [[ -s "$envf" && -n "$(tail -c 1 "$envf")" ]]; then
        echo >> "$envf" || return 1
    fi
    if grep -qxF "$line" "$envf"; then
        :
    elif grep -qE '^[[:space:]]*(export[[:space:]]+)?OPENBLAS_CORETYPE=' "$envf"; then
        sed -i -E "s|^[[:space:]]*(export[[:space:]]+)?OPENBLAS_CORETYPE=.*|$line|" "$envf" || return 1
    else
        printf '%s\n' "$line" >> "$envf" || return 1
    fi

    install -d -m 0755 "$root/etc/systemd/system.conf.d" || return 1
    printf '%s\n' \
        "# OPENBLAS_CORETYPE for services: without it numpy, cv2 and torch die with" \
        "# 'Illegal instruction' on Jetson Nano. Written by the $name extension." \
        "[Manager]" \
        "DefaultEnvironment=$line" > "$dropin" || return 1
    _l4t_info "$line: /etc/environment (входы) и $dropin (службы)"
}

# NUL-separated KEY=VALUE pairs as pam_env reads /etc/environment.
_l4t_env_login(){
    python3 - "$(_l4t_root)" <<'PYEOF'
import re, sys
out = []
try:
    lines = open(sys.argv[1] + "/etc/environment", encoding="utf-8").read().splitlines()
except FileNotFoundError:
    lines = []
for raw in lines:
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    line = re.sub(r"^export\s+", "", line)
    key, sep, value = line.partition("=")
    if not sep or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
        continue
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    out.append(f"{key}={value}")
sys.stdout.write("".join(v + "\0" for v in out))
PYEOF
}

# NUL-separated KEY=VALUE pairs as systemd builds DefaultEnvironment from
# system.conf and its drop-ins: [Manager] section only, files in lexical
# order, assignments accumulate, an empty assignment resets the list.
_l4t_env_systemd(){
    python3 - "$(_l4t_root)" <<'PYEOF'
import glob, shlex, sys
root = sys.argv[1]
files = [root + "/etc/systemd/system.conf"] + sorted(glob.glob(root + "/etc/systemd/system.conf.d/*.conf"))
env = {}
for path in files:
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except FileNotFoundError:
        continue
    section = None
    for raw in lines:
        line = raw.strip()
        if not line or line[0] in "#;":
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        key, sep, value = line.partition("=")
        if section != "Manager" or key.strip() != "DefaultEnvironment":
            continue
        if not value.strip():
            env.clear()
            continue
        for word in shlex.split(value):
            k, s, v = word.partition("=")
            if s:
                env[k] = v
sys.stdout.write("".join(f"{k}={v}\0" for k, v in env.items()))
PYEOF
}

# Run `python3 -c CODE` under `env -i` twice: with the login environment and
# with the service environment, both rebuilt from the files. Fails when either
# source lacks OPENBLAS_CORETYPE=ARMV8 or the code fails under it.
l4t_openblas_check(){
    local code="$1"
    local source listing out
    local pairs=()
    for source in login systemd; do
        pairs=()
        mapfile -d '' -t pairs < <("_l4t_env_$source")
        # Herestring, not a pipe: `… | grep -q` under pipefail fails on SIGPIPE.
        listing="$(printf '%s\n' "${pairs[@]}")"
        if ! grep -qxF "OPENBLAS_CORETYPE=$L4T_OPENBLAS_CORETYPE" <<<"$listing"; then
            _l4t_error "OPENBLAS_CORETYPE=$L4T_OPENBLAS_CORETYPE не выводится из файлов ($source):"
            _l4t_error "  ${pairs[*]:-пусто}"
            return 1
        fi
        # PATH only when the source does not set one: systemd's default is not
        # in system.conf, and python3 is called by absolute path anyway.
        grep -q '^PATH=' <<<"$listing" || pairs+=("PATH=/usr/sbin:/usr/bin:/sbin:/bin")
        if ! out="$(env -i "${pairs[@]}" /usr/bin/python3 -c "$code" 2>&1)"; then
            _l4t_error "импорт с окружением из файлов ($source) не прошёл:"
            >&2 echo "$out"
            return 1
        fi
        _l4t_info "окружение из файлов ($source): $out"
    done
}
