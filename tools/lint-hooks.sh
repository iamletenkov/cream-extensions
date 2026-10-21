#!/usr/bin/env bash
# Lint of the hooks and actions of the extensions (plan 2026-10-19, Task 7):
# the script rules of the former layout 2 validator, carried over to cream/v1,
# plus the convention of the catalog (docs/reference/lint-rules.md).
#
#   tools/lint-hooks.sh            every extensions/<family>/<name>/ with an
#                                  extension.yaml
#   tools/lint-hooks.sh DIR...     the given extension directories
#
# Rules (the name in brackets is printed with every finding):
#   [header]          hooks/* and actions/*: a shebang (bash or sh), then
#                     `set -euo pipefail` (`set -eu` in sh) before any command;
#   [exec]            hooks/* and actions/* carry the executable bit;
#   [hook-name]       hooks/<name> is one of the hooks of cream (spec §4.1);
#   [systemctl-block] hooks apply, configure, secret do not call a blocking
#                     `systemctl start|restart|…`: `--no-block` is required
#                     (`cream set` may run inside a boot unit — a deadlock);
#   [lock-none-set]   an action with `lock: none` does not call `cream set`
#                     (spec §6.3: such an action only reads the domain);
#   [source-lib]      no `source`/`.` of a `lib/` path: the layout 2 shared code
#                     is gone, libraries are extensions (`kind: library`);
#   [secret-argv]     a secret key (config `secret:`, action param
#                     `secret: true`) is not given to cream as `KEY=value` in
#                     argv — `KEY=-` and stdin (visible in `ps` otherwise);
#   [cream-env]       `CREAM_*` is the environment cream gives the hook: never
#                     assigned, and only the names cream defines;
#   [stage-cream]     `hooks.configure.stage: cloud-user` needs
#                     `cream: ">=1.1.1"` (cream 1.1.0 does not start that stage
#                     with cloud-init disabled; plan ruling R14);
#   [every-boot]      a configure hook with a text sign of A1-A4 (spec
#                     2026-10-21 §10.7: A1 `ip link`, `iptables`, `nft`,
#                     `modprobe`, a write to /run/; A2 `getent passwd`,
#                     `/home/`, UID 1000; A3 `get_cloud_user`; A4
#                     `cream-configure@`) declares `hooks.configure.every_boot:
#                     true` or carries `# cream-lint: every-boot-not-needed
#                     <причина>`. The hook and the files of the extension it
#                     hands over to (`"${CREAM_EXT_DIR…}/<path>"`) are read; the
#                     exception is a line of the hook. Not followed: a
#                     hand-over through another variable or `$CREAM_EXT_DIR/`
#                     without braces; not seen: a /run/ write by cp/ln/mv,
#                     a quoted "nft". A5 and A6 are not
#                     visible in the text — the audit
#                     (docs/research/2026-10-21-configure-audit.md).
#                     LINT_EVERY_BOOT=error (default since the catalog pins
#                     cream 1.2.0) counts the finding; LINT_EVERY_BOOT=warn
#                     prints it and keeps the code.
# Comment lines and tests/ are not linted. shellcheck of the same files at the
# `warning` level is tools/lint.sh (make lint).
#
# Exit: 0 — clean; 1 — findings (file:line: [rule] text); 2 — usage.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"

EVERY_BOOT_MODE="${LINT_EVERY_BOOT:-error}"
case "$EVERY_BOOT_MODE" in
    warn | error) ;;
    *) echo "lint-hooks: LINT_EVERY_BOOT=$EVERY_BOOT_MODE — ожидается warn или error" >&2; exit 2 ;;
esac

HOOKS=(install upgrade configure apply secret remove check)
# Hook and action environment of cream (spec §6.3, §7) and of its CLI (§12).
CREAM_ENV=(
    CREAM_PHASE CREAM_EXT CREAM_EXT_VERSION CREAM_PREV_VERSION CREAM_EXT_DIR
    CREAM_ETC_DIR CREAM_STATE_DIR CREAM_ROOT CREAM_CONFIG_FILE CREAM_SECRETS_FILE
    CREAM_REASON CREAM_CHANGED_KEYS CREAM_LOCK_FD CREAM_LOCK_MODE CREAM_ACTION
    CREAM_OUTPUT CREAM_SOURCES CREAM_CACHE
)
CLOUD_USER_CREAM="1.1.1"

dirs=()
if (( $# )); then
    for d in "$@"; do
        [[ -f "$d/extension.yaml" ]] || { echo "lint-hooks: $d: нет extension.yaml" >&2; exit 2; }
        dirs+=("$(cd "$d" && pwd)")
    done
else
    while IFS= read -r m; do
        dirs+=("$(dirname "$m")")
    done < <(find "$REPO/extensions" -mindepth 3 -maxdepth 3 -name extension.yaml | sort)
fi
if (( ${#dirs[@]} == 0 )); then
    echo "lint-hooks: расширений нет, проверять нечего"
    exit 0
fi

# Facts of a manifest, one per line: `hook NAME`, `stage S`, `cream RANGE`,
# `locknone ACTION`, `secret KEY`. PyYAML.
# shellcheck disable=SC2016  # Python source, not shell
FACTS_PY='
import sys, yaml
m = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
hooks = m.get("hooks") or {}
for h in hooks:
    print("hook", h)
conf = hooks.get("configure") or {}
if isinstance(conf, dict) and conf.get("stage"):
    print("stage", conf["stage"])
if isinstance(conf, dict) and conf.get("every_boot") is True:
    print("everyboot", "true")
if m.get("cream") is not None:
    print("cream", m["cream"])
for k, v in ((m.get("config") or {}).get("keys") or {}).items():
    if isinstance(v, dict) and v.get("secret"):
        print("secret", k)
for a, v in (m.get("actions") or {}).items():
    v = v or {}
    if v.get("lock") == "none":
        print("locknone", a)
    for k, p in (v.get("params") or {}).items():
        if isinstance(p, dict) and p.get("secret") is True:
            print("secret", k)
'

found=0
rel_of() { local p="$1"; p="${p#"$REPO"/}"; printf '%s' "$p"; }
report() { printf '%s: [%s] %s\n' "$1" "$2" "$3"; found=1; }

in_list() {
    local x="$1"; shift
    local y
    for y in "$@"; do [[ "$x" == "$y" ]] && return 0; done
    return 1
}

# Minimal version of a range such as ">=1.1.1, <2.0.0" (0.0.0 when there is no >=).
range_min() {
    local v
    v="$(grep -oE '>=[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+' <<< "$1" | head -n1 | tr -d '>= ')" || true
    printf '%s' "${v:-0.0.0}"
}
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

is_shell() {
    case "$1" in
        */hooks/* | */actions/* | *.sh | *.bash) return 0 ;;
    esac
    head -n1 -- "$1" 2>/dev/null | grep -Eq '^#!.*(bash|/sh|dash)'
}

check_header() {
    local f="$1" where="$2" first sh="" n=0 line flags
    if [[ "$(head -c 4 -- "$f")" == $'\x7fELF' ]]; then return 0; fi
    first="$(head -n1 -- "$f")"
    case "$first" in
        '#!/usr/bin/env bash' | '#!/bin/bash' | '#!/usr/bin/bash') sh="bash" ;;
        '#!/bin/sh' | '#!/usr/bin/env sh' | '#!/bin/dash') sh="sh" ;;
        *) report "$where:1" header "нет shebang bash или sh (#!/usr/bin/env bash)"; return 0 ;;
    esac
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        (( n == 1 )) && continue
        [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
        if [[ "$line" =~ ^set[[:space:]]+-([A-Za-z]+) ]]; then
            flags="${BASH_REMATCH[1]}"
            if [[ "$flags" == *e* && "$flags" == *u* ]] \
                && { [[ "$sh" == sh ]] || [[ "$line" == *pipefail* ]]; }; then
                return 0
            fi
        fi
        if [[ "$sh" == sh ]]; then
            report "$where:$n" header "первая команда — не \`set -eu\`"
        else
            report "$where:$n" header "первая команда — не \`set -euo pipefail\`"
        fi
        return 0
    done < "$f"
    report "$where:1" header "нет \`set -euo pipefail\`"
}

BLOCKING='(^|[^[:alnum:]_-])systemctl([[:space:]].*)?[[:space:]](start|restart|try-restart|reload-or-restart|try-reload-or-restart|condrestart|isolate)([[:space:]]|$)'
CREAM_SET='(^|[^[:alnum:]_-])cream([[:space:]]+-[^[:space:]]+)*[[:space:]]+(config[[:space:]]+)?set([[:space:]]|$)'
CREAM_CALL='(^|[^[:alnum:]_-])cream[[:space:]]'
SOURCE_LIB='(^|[[:space:];&|(])(source|\.)[[:space:]]+[^;&|]*(^|[/"'"'"'[:space:]])lib/'
CREAM_ASSIGN='(^|[[:space:];&|(])((export|local|readonly|declare|typeset)([[:space:]]+-[A-Za-z]+)*[[:space:]]+)?CREAM_[A-Z0-9_]+(\+)?='

# Text signs of the configure audit (spec 2026-10-21 §10.7): "label|text|regex".
# A /run/ path counts when it is written: a redirection, a directory or file
# made there, or a path variable set to it; a test such as -d /run/systemd/system
# is a read.
RUN_PATH='"?[^[:space:]"]*/run/'
EVERY_BOOT_SIGNS=(
    "А1|ip link|(^|[^[:alnum:]_-])ip[[:space:]]+(-[^[:space:]]+[[:space:]]+)*link([[:space:]]|$)"
    "А1|iptables|(^|[^[:alnum:]_-])ip6?tables"
    "А1|nft|(^|[^[:alnum:]_.-])nft([[:space:]]|$)"
    "А1|modprobe|(^|[^[:alnum:]_-])(modprobe|insmod)([[:space:]]|$)"
    "А1|запись в /run/|>[[:space:]]*${RUN_PATH}"
    "А1|запись в /run/|(^|[^[:alnum:]_-])(mkdir|install|touch|tee|mktemp)([[:space:]][^;&|]*)?[[:space:]]${RUN_PATH}"
    "А1|путь в /run/|^[[:space:]]*((local|readonly|export|declare)[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=${RUN_PATH}"
    "А2|getent passwd|getent[[:space:]]+passwd"
    "А2|/home/|/home/"
    "А2|UID 1000|[Uu][Ii][Dd][^[:alnum:]]{0,8}1000([^0-9]|$)"
    "А3|get_cloud_user|get_cloud_user"
    "А4|cream-configure@|cream-configure@"
)
EXCEPT_RE='^[[:space:]]*#[[:space:]]*cream-lint:[[:space:]]*every-boot-not-needed[[:space:]]+[^[:space:]]'
EXT_REF_RE='CREAM_EXT_DIR[^}]*\}/[A-Za-z0-9_./-]+'

# check_every_boot DIR: the rule every-boot for one extension.
check_every_boot(){
    local d="$1" hook="$1/hooks/configure" f line n sign label text re where="" found_signs="" ref
    local -a files=("$hook")
    [[ -f "$hook" ]] || return 0
    grep -Eq "$EXCEPT_RE" "$hook" && return 0
    # Files of the extension the hook hands over to, one level deep.
    while IFS= read -r ref; do
        ref="${ref#*\}/}"
        [[ "$ref" == *..* ]] && continue
        [[ -f "$d/$ref" ]] && ! in_list "$d/$ref" "${files[@]}" && files+=("$d/$ref")
    done < <(grep -Ev '^[[:space:]]*#' "$hook" | grep -oE "$EXT_REF_RE" || true)
    for f in "${files[@]}"; do
        n=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            n=$((n + 1))
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            for sign in "${EVERY_BOOT_SIGNS[@]}"; do
                label="${sign%%|*}"; text="${sign#*|}"; re="${text#*|}"; text="${text%%|*}"
                [[ "$line" =~ $re ]] || continue
                [[ -n "$where" ]] || where="$(rel_of "$f"):$n"
                [[ "$found_signs" == *"$label $text "* ]] && continue
                found_signs+="$label $text ($(rel_of "$f"):$n); "
            done
        done < "$f"
    done
    [[ -n "$found_signs" ]] || return 0
    found_signs="${found_signs%; }"
    local msg="признаки $found_signs — нужен hooks.configure.every_boot: true или «# cream-lint: every-boot-not-needed <причина>» в хуке"
    if [[ "$EVERY_BOOT_MODE" == error ]]; then
        report "$where" every-boot "$msg"
    else
        printf '%s: [%s] %s (предупреждение, LINT_EVERY_BOOT=warn)\n' "$where" every-boot "$msg"
        warned=$((warned + 1))
    fi
}
warned=0

for d in "${dirs[@]}"; do
    facts="$(python3 -I -c "$FACTS_PY" "$d/extension.yaml")" \
        || { echo "lint-hooks: $(rel_of "$d")/extension.yaml: не разбирается" >&2; exit 2; }
    stage="$(awk '$1 == "stage" { print $2 }' <<< "$facts")"
    cream_range="$(sed -n 's/^cream //p' <<< "$facts")"
    mapfile -t locknone < <(awk '$1 == "locknone" { print $2 }' <<< "$facts")
    mapfile -t secrets < <(awk '$1 == "secret" { print $2 }' <<< "$facts")
    grep -qx 'everyboot true' <<< "$facts" || check_every_boot "$d"

    if [[ "$stage" == cloud-user ]] \
        && ! version_ge "$(range_min "$cream_range")" "$CLOUD_USER_CREAM"; then
        report "$(rel_of "$d")/extension.yaml" stage-cream \
            "стадия cloud-user требует cream: \">=$CLOUD_USER_CREAM\" (сейчас: ${cream_range:-нет поля cream})"
    fi

    while IFS= read -r -d '' f; do
        rel="$(rel_of "$f")"
        sub="${f#"$d"/}"
        kind=""
        case "$sub" in
            tests/*) continue ;;
            hooks/*) kind=hook ;;
            actions/*) kind=action ;;
        esac
        name="${sub#*/}"
        if [[ -n "$kind" ]]; then
            [[ -x "$f" ]] || report "$rel" exec "нет бита исполнения (chmod +x)"
            if [[ "$kind" == hook ]] && ! in_list "$name" "${HOOKS[@]}"; then
                report "$rel" hook-name "хука «$name» у cream нет (${HOOKS[*]})"
            fi
            check_header "$f" "$rel"
        fi
        is_shell "$f" || continue

        n=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            n=$((n + 1))
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            if [[ "$kind" == hook ]] && in_list "$name" apply configure secret \
                && [[ "$line" =~ $BLOCKING ]] && [[ "$line" != *--no-block* ]]; then
                report "$rel:$n" systemctl-block "блокирующий systemctl в хуке $name — нужен --no-block"
            fi
            if [[ "$kind" == action ]] && (( ${#locknone[@]} )) && in_list "$name" "${locknone[@]}" \
                && [[ "$line" =~ $CREAM_SET ]]; then
                report "$rel:$n" lock-none-set "cream set в действии с lock: none — только чтение домена"
            fi
            if [[ "$line" =~ $SOURCE_LIB ]]; then
                report "$rel:$n" source-lib "source из lib/ — общий код теперь библиотека (kind: library)"
            fi
            if (( ${#secrets[@]} )) && [[ "$line" =~ $CREAM_CALL ]]; then
                for k in "${secrets[@]}"; do
                    # KEY=<anything but a lone "-">
                    re="(^|[^[:alnum:]_])${k}=([^-[:space:]]|-[^[:space:]\"';&|)])"
                    if [[ "$line" =~ $re ]]; then
                        report "$rel:$n" secret-argv "секрет $k в argv cream — $k=- и stdin"
                    fi
                done
            fi
            if [[ "$line" =~ $CREAM_ASSIGN ]]; then
                report "$rel:$n" cream-env "присваивание CREAM_* — это окружение cream, не переменные расширения"
            fi
            while read -r v; do
                [[ -n "$v" ]] || continue
                in_list "$v" "${CREAM_ENV[@]}" \
                    || report "$rel:$n" cream-env "$v — такой переменной cream не задаёт (опечатка?)"
            done < <(grep -oE 'CREAM_[A-Z0-9_]+' <<< "$line" | sort -u)
        done < "$f"
    done < <(find "$d" -type f -not -name README.md -print0 | sort -z)
done

if (( found )); then
    echo "lint-hooks: нарушения в хуках и действиях cream/v1 (см. выше; правила — docs/reference/lint-rules.md)" >&2
    exit 1
fi
if (( warned )); then
    echo "lint-hooks: ок, расширений: ${#dirs[@]}; предупреждений every-boot: $warned (LINT_EVERY_BOOT=warn; по умолчанию — ошибки)"
else
    echo "lint-hooks: ок, расширений: ${#dirs[@]}"
fi
