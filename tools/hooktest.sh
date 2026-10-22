# shellcheck shell=bash
# H-раннер: хуки и действия расширения cream/v1 на подменённом корне — так, как
# их зовёт cream (спека cream §6.3), без root, systemd и сети. Подключается из
# тестов расширения:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/../../../../tools/hooktest.sh"
#   ht_init
#   ht_root "$(dirname "$HERE")"          # свежий корень + копия расширения
#   ht_fake apt-get 'exit 0'              # подставная команда (журнал вызовов)
#   ht_hook install DEMO_COLOR=red; eq "install — 0" 0 "$?"
#   check "apt-get позван" ht_called '^apt-get install '
#   ht_done                               # итог; код 0 — все проверки прошли
#
# Корень ($ROOT):
#   $ROOT/opt/cream/ext/<ext>  копия расширения — CREAM_EXT_DIR и cwd хука
#   $ROOT/opt/cream/ext/<lib>  библиотеки (kind: library) из depends — соседи по каталогу
#   $ROOT/etc/cream/<ext>      CREAM_ETC_DIR (config, secrets)
#   $ROOT/var/lib/cream/ext/<ext>  CREAM_STATE_DIR
#   $ROOT/bin                  подставные команды, первыми в PATH
#   $ROOT/tmp                  TMPDIR хука
#   $FAKE ($ROOT/fake)         журнал: calls — «команда аргументы» по строке на вызов,
#                              <команда>.argv; ht_out — вывод последнего хука
#
# Окружение хука очищено (env -i): PATH cream с $ROOT/bin впереди, LANG=C.UTF-8,
# CREAM_* как у cream (CREAM_PHASE — $HT_PHASE, по умолчанию live), все
# несекретные ключи config.keys манифеста с их default; аргументы KEY=VALUE
# перекрывают. Секретные ключи в окружение не попадают — ht_secret кладёт их в
# CREAM_SECRETS_FILE. stdin — /dev/null, umask 022.
#
# Команды, опасные на хосте (apt-get, dpkg, systemctl, curl, …), в $ROOT/bin
# заранее закрыты сторожем: вызов пишется в журнал и падает с кодом 127, пока
# тест не подставит свою (ht_fake). Так хук не дойдёт до настоящего apt-get или сети.
#
# Нужны bash, python3 с PyYAML (разбор манифеста).

HT_GUARDED=(apt apt-get apt-key add-apt-repository dpkg curl wget systemctl journalctl
    modprobe depmod update-initramfs update-grub reboot shutdown nft iptables ip6tables
    useradd usermod groupadd docker snap pip pip3 cream)
HT_PATH_TAIL=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ht_init: scratch directory removed on exit, counters, fd 3 = real stderr.
ht_init() {
    HT_TMP="$(mktemp -d)"
    # shellcheck disable=SC2064  # expand now: the path is fixed
    trap "rm -r -f -- '$HT_TMP'" EXIT
    HT_PASS=0
    HT_FAIL=0
    exec 3>&2
}

ok() { HT_PASS=$((HT_PASS + 1)); }
bad() { HT_FAIL=$((HT_FAIL + 1)); echo "FAIL: $*" >&3; }
check() { local what="$1"; shift; if "$@"; then ok; else bad "$what"; fi; }
check_not() { local what="$1"; shift; if "$@"; then bad "$what"; else ok; fi; }
eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1: ждали [$2], получили [$3]"; fi; }

# ht_done: the summary line; status 0 when nothing failed.
ht_done() {
    echo "проверок: $((HT_PASS + HT_FAIL)), не прошло: $HT_FAIL"
    (( HT_FAIL == 0 ))
}

# ht_root <extension dir>: a fresh root with a copy of the extension, staged as
# cream gets it (tools/stage-catalog.sh --ext: the shared core laid into a
# consumer, tests/ left out).
ht_root() {
    local src="$1" k
    [[ -f "$src/extension.yaml" ]] || { echo "ht_root: $src: нет extension.yaml" >&2; return 2; }
    ROOT="$(mktemp -d "$HT_TMP/root.XXXXXX")"
    FAKE="$ROOT/fake"
    HT_NAME="$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["name"])' \
        "$src/extension.yaml")" || return 2
    HT_EXT="$ROOT/opt/cream/ext/$HT_NAME"
    mkdir -p "$ROOT/bin" "$ROOT/tmp" "$FAKE" "$(dirname "$HT_EXT")" \
        "$ROOT/etc/cream/$HT_NAME" "$ROOT/var/lib/cream/ext/$HT_NAME"
    "$(dirname "${BASH_SOURCE[0]}")/stage-catalog.sh" --ext "$src" "$(dirname "$HT_EXT")" > /dev/null || return 2
    [[ -d "$HT_EXT" ]] || mv -- "$(dirname "$HT_EXT")/$(basename "$src")" "$HT_EXT"
    # Libraries (kind: library) from `depends`, laid down as cream does: the
    # catalog sibling, without tests/. Other depends are the test's business.
    local lib
    while read -r lib; do
        [[ -n "$lib" ]] || continue
        cp -a "$(dirname "$src")/$lib" "$ROOT/opt/cream/ext/$lib"
        rm -r -f -- "$ROOT/opt/cream/ext/$lib/tests"
    done < <(python3 - "$src" <<'PY'
import os, sys, yaml
src = sys.argv[1]
m = yaml.safe_load(open(os.path.join(src, "extension.yaml"), encoding="utf-8"))
for d in m.get("depends") or []:
    p = os.path.join(os.path.dirname(src), d["name"], "extension.yaml")
    if os.path.isfile(p) and (yaml.safe_load(open(p, encoding="utf-8")) or {}).get("kind") == "library":
        print(d["name"])
PY
    )
    : > "$FAKE/calls"
    for k in "${HT_GUARDED[@]}"; do
        ht_fake "$k" "echo \"hooktest: $k не подставлен (ht_fake $k …)\" >&2; exit 127"
    done
    # Non-secret keys with their defaults, one KEY=VALUE per line.
    mapfile -t HT_DEFAULTS < <(python3 - "$src/extension.yaml" <<'PY'
import sys, yaml
m = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for key, spec in ((m.get("config") or {}).get("keys") or {}).items():
    spec = spec or {}
    if spec.get("secret"):
        continue
    d = spec.get("default", "")
    print(f"{key}={'' if d is None else d}")
PY
    )
}

# ht_fake <command> [body]: a fake in $ROOT/bin that logs "command args" to
# $FAKE/calls and argv to $FAKE/<command>.argv, then runs body (bash; $FAKE and
# "$@" are available). No body — exit 0.
ht_fake() {
    local name="$1" body="${2:-exit 0}"
    {
        echo '#!/usr/bin/env bash'
        printf 'FAKE=%q\n' "$FAKE"
        printf 'printf "%%s\\n" "%s $*" >> "$FAKE/calls"\n' "$name"
        printf 'printf "%%s\\n" "$*" >> "$FAKE/%s.argv"\n' "$name"
        printf '%s\n' "$body"
    } > "$ROOT/bin/$name"
    chmod +x "$ROOT/bin/$name"
}

# ht_secret KEY VALUE: a secret key in CREAM_SECRETS_FILE (0600), not in the environment.
ht_secret() {
    local f="$ROOT/etc/cream/$HT_NAME/secrets"
    printf '%s=%s\n' "$1" "$2" >> "$f"
    chmod 0600 "$f"
}

ht_called() { grep -qE -- "$1" "$FAKE/calls"; }
ht_calls() { cat "$FAKE/calls"; }
ht_out() { cat "$ROOT/out" 2>/dev/null; }

# _ht_env: the environment cream gives a hook or an action (to stdout, NUL-separated).
_ht_env() {
    local n="$HT_NAME" v
    v="$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["version"])' \
        "$HT_EXT/extension.yaml")"
    printf '%s\0' "PATH=$ROOT/bin:$HT_PATH_TAIL" LANG=C.UTF-8 "TMPDIR=$ROOT/tmp" \
        "CREAM_PHASE=${HT_PHASE:-live}" "CREAM_EXT=$n" "CREAM_EXT_VERSION=$v" \
        "CREAM_EXT_DIR=$HT_EXT" "CREAM_ETC_DIR=$ROOT/etc/cream/$n" \
        "CREAM_STATE_DIR=$ROOT/var/lib/cream/ext/$n" "CREAM_ROOT=$ROOT" \
        "CREAM_CONFIG_FILE=$ROOT/etc/cream/$n/config" "CREAM_SECRETS_FILE=$ROOT/etc/cream/$n/secrets" \
        "${HT_DEFAULTS[@]}"
}

# _ht_exec <file> <env pairs…> -- <args…>: run like cream, output to $ROOT/out.
_ht_exec() {
    local file="$1"; shift
    local -a vars=() args=()
    while (( $# )) && [[ "$1" != -- ]]; do vars+=("$1"); shift; done
    [[ "${1:-}" == -- ]] && shift
    args=("$@")
    [[ -x "$file" ]] || { echo "hooktest: $file нет или не исполняемый" > "$ROOT/out"; return 126; }
    local -a envv=()
    mapfile -d '' -t envv < <(_ht_env)
    (
        cd "$HT_EXT" || exit 125
        umask 022
        exec env -i "${envv[@]}" "${vars[@]}" "$file" "${args[@]}" < /dev/null
    ) > "$ROOT/out" 2>&1
}

# ht_hook <hook> [KEY=VALUE…]: run hooks/<hook>; status is the hook's code.
ht_hook() {
    local hook="$1"; shift
    _ht_exec "$HT_EXT/hooks/$hook" "$@" --
}

# ht_action <action> [KEY=VALUE…] [-- args…]: run actions/<action>.
ht_action() {
    local action="$1"; shift
    _ht_exec "$HT_EXT/actions/$action" "$@"
}
