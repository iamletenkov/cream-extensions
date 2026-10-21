#!/usr/bin/env bash
# Scaffold a new cream/v1 extension (docs/extensions.md, "Формат cream/v1").
#
# Without this, a new extension is written by copying a neighbour — together
# with its capabilities in the manifest and its paths in the unit file. Those
# copied values look deliberate and survive review, which is exactly how the
# eight diverging copies of get_cloud_user.sh happened.
#
# The scaffold passes `cream validate`, tools/lint-hooks.sh and its own H test
# (tests/test-<name>.sh) right away; what only the author knows is left as TODO.
# Shared code is never copied in: a library is an extension of its own
# (`kind: library`), declared in `depends` and called by its stable path
# ${CREAM_ROOT:-}/opt/cream/ext/<library>/….
#
# Test override: NEW_EXTENSION_ROOT — the catalog to write into (default: this
# repository).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${NEW_EXTENSION_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
    cat >&2 <<'USAGE'
Заводит скелет нового расширения cream/v1 в extensions/debian/<имя>/.

  tools/new-extension.sh <имя> [ключи]

Ключи:
  --arch <список>          через запятую: amd64,arm64 (умолчание — оба)
  --stage <стадия>         хук configure на загрузке: system | early | cloud-user | graphical
                           (без ключа configure нет; early/graphical требуют cream >=1.1.0,
                           cloud-user — >=1.1.1)
  --live <yes|confirm|no>  targets.live (умолчание yes); confirm и no — с live_note
  --cloud-user             configure узнаёт пользователя cloud-init библиотекой cloud-user
                           (depends; без --stage — стадия system; every_boot: true и
                           cream >=1.2.0 — признак А3 аудита configure)
  --library                kind: library — только файлы, без хуков
  -h, --help               эта справка

Пример:
  tools/new-extension.sh tailscale --stage system
USAGE
}

name=""
arch="amd64,arm64"
stage=""
live="yes"
want_cloud_user=0
library=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --arch) arch="${2:?--arch требует значения}"; shift 2 ;;
        --stage) stage="${2:?--stage требует значения}"; shift 2 ;;
        --live) live="${2:?--live требует значения}"; shift 2 ;;
        --cloud-user) want_cloud_user=1; shift ;;
        --library) library=1; shift ;;
        -*) echo "Неизвестный ключ: $1" >&2; usage; exit 2 ;;
        *)
            [[ -n "$name" ]] && { echo "Имя уже задано: $name" >&2; exit 2; }
            name="$1"; shift ;;
    esac
done

[[ -n "$name" ]] || { echo "Не задано имя расширения." >&2; usage; exit 2; }

# cream: [a-z0-9][a-z0-9._-]{0,63}, reserved words; stricter here — the name
# also becomes a key prefix (FOO_BAR), so no dots or underscores.
[[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || {
    echo "Имя — строчные буквы, цифры и дефисы, до 64 знаков: '$name'" >&2
    exit 2
}
case "$name" in
    cream | lib | ext | installed | lock) echo "Имя «$name» зарезервировано cream" >&2; exit 2 ;;
esac
case "$stage" in
    "" | system | early | cloud-user | graphical) ;;
    *) echo "Неизвестная стадия: '$stage' (system | early | cloud-user | graphical)" >&2; exit 2 ;;
esac
case "$live" in
    yes | confirm | no) ;;
    *) echo "--live: yes | confirm | no, а не '$live'" >&2; exit 2 ;;
esac
arch_list=()
IFS=',' read -r -a arch_in <<< "${arch// /}"
for a in "${arch_in[@]}"; do
    case "$a" in
        amd64 | arm64) arch_list+=("$a") ;;
        *) echo "--arch: amd64 и arm64, а не '$a'" >&2; exit 2 ;;
    esac
done
(( ${#arch_list[@]} )) || { echo "--arch: пустой список" >&2; exit 2; }
if (( library )) && [[ -n "$stage" || "$want_cloud_user" -eq 1 ]]; then
    echo "--library: у библиотеки нет хуков — без --stage и --cloud-user" >&2
    exit 2
fi
if (( want_cloud_user )) && [[ -z "$stage" ]]; then
    stage="system"
fi

ext_dir="$REPO_ROOT/extensions/debian/$name"
[[ -e "$ext_dir" ]] && { echo "Уже существует: extensions/debian/$name" >&2; exit 1; }

# Minimal cream of a stage (cream docs/cli.md; cloud-user: plan ruling R14).
case "$stage" in
    early | graphical) cream_min="1.1.0" ;;
    cloud-user) cream_min="1.1.1" ;;
    *) cream_min="1.0.0" ;;
esac
# configure that waits for the cloud-init user (sign A3 of the configure audit,
# docs/research/2026-10-21-configure-audit.md) runs every boot: every_boot
# needs cream >=1.2.0 (cream spec 2026-10-21 §10.9).
every_boot=""
if [[ -n "$stage" ]] && (( want_cloud_user )); then
    every_boot=", every_boot: true"; cream_min="1.2.0"
fi
arch_yaml="[$(printf '%s, ' "${arch_list[@]}" | sed 's/, $//')]"
# Key prefix: the name in capitals, dashes to underscores (code-server ->
# CODE_SERVER). CREAM_* is the hook environment and is never a key.
prefix="$(echo "$name" | tr 'a-z-' 'A-Z_')"
[[ "$prefix" == CREAM* ]] && prefix="EXT_$prefix"
if [[ "$live" == yes ]]; then
    targets="{build: exec, live: \"yes\"}"
else
    targets="{build: exec, live: \"$live\", live_note: \"TODO: чем опасна установка на живую машину\"}"
fi

mkdir -p "$ext_dir/tests"

# --- extension.yaml ----------------------------------------------------------
{
    cat <<EOF
# $name — TODO: one line on what it gives the machine.
schema: cream/v1
name: $name
EOF
    if (( library )); then echo "kind: library"; fi
    cat <<EOF
version: 0.1.0
summary: TODO одна фраза — что даёт расширение
cream: ">=$cream_min"
platform:
  family: deb
  arch: $arch_yaml
targets: $targets
EOF
    if (( ! library )); then
        cat <<'EOF'
# Capabilities, not names: derive them FROM THE CODE — what the hooks really
# install and what the units really need (docs/extensions.md, «Словарь способностей»).
provides: []
requires: []
EOF
        if (( want_cloud_user )); then printf 'depends: [{name: cloud-user, version: ">=1.0.0"}]\n'; fi
        echo "hooks:"
        echo "  install: {timeout: 10m}"
        if [[ -n "$stage" ]]; then echo "  configure: {stage: $stage$every_boot}"; fi
        echo "  remove: {}"
        cat <<EOF
config:
  keys:
    ${prefix}_EXAMPLE:
      type: str
      default: ""
      empty: true
      description: "TODO: что задаёт; ключ без префикса CREAM_ (окружение хука)"
EOF
    fi
} > "$ext_dir/extension.yaml"

# --- hooks -------------------------------------------------------------------
if (( library )); then
    cat > "$ext_dir/$name.sh" <<'EOF'
# shellcheck shell=bash
# Library __NAME__: sourced or run by other extensions by the stable path
# "${CREAM_ROOT:-}/opt/cream/ext/__NAME__/__NAME__.sh"; consumers declare
# `depends: [{name: __NAME__}]`. Library code sets no shell options of its own.
__FUNC___hello() { echo "__NAME__"; }
EOF
else
    mkdir -p "$ext_dir/hooks"
    cat > "$ext_dir/hooks/install" <<'EOF'
#!/usr/bin/env bash
# cream hook `install` of __NAME__: TODO what it installs.
#
# Runs as root at image build (CREAM_PHASE=build: a chroot, no systemd) and on
# a live machine (CREAM_PHASE=live). Idempotent: a repeated install (and
# `cream install --reinstall`) gives the same files. Settings come as the
# environment (config.keys of extension.yaml), secrets only from
# $CREAM_SECRETS_FILE — never through argv. Exit 10 asks for a reboot, 20 means
# "not applicable here" (no device, kernel, GPU) — install only (ruling R11).
set -euo pipefail

log_info(){ >&2 echo "[INFO] __NAME__: $*"; }

# TODO: the packages. Branch on /etc/os-release here rather than in the
# manifest — the guest knows itself. Something downloaded goes by a pinned
# version and its sha256 (files/pin.env), checked before use.
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends __NAME__

log_info "installed (example key: ${__PREFIX___EXAMPLE:-unset})"
EOF
    cat > "$ext_dir/hooks/remove" <<'EOF'
#!/usr/bin/env bash
# cream hook `remove` of __NAME__: takes away only what install put on. Files
# of the manifest's `files:` cream removes itself.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
# TODO: a package that stood before cream is not ours — record the method in
# $CREAM_STATE_DIR at install and leave a preexisting one alone (see btop).
apt-get remove -y __NAME__
EOF
    if [[ -n "$stage" ]]; then
        {
            cat <<'EOF'
#!/usr/bin/env bash
# cream hook `configure` of __NAME__ (stage __STAGE__): what depends on this
# very machine, on every boot (CREAM_REASON=boot) and after install, upgrade,
# apply. No device, display manager or user — a warning on stderr and exit 0:
# a failed boot unit helps nobody (ruling R11). systemctl only with --no-block.
set -euo pipefail

log_warn(){ >&2 echo "[WARN] __NAME__: $*"; }
EOF
            if (( want_cloud_user )); then
                cat <<'EOF'

# The cloud-init user: library cloud-user (depends), never a copy.
CLOUD_USER="$("${CREAM_ROOT:-}/opt/cream/ext/cloud-user/get_cloud_user.sh")" || {
    log_warn "пользователь cloud-init не найден — настройка пропущена"
    exit 0
}
log_warn "TODO: configure for $CLOUD_USER (reason ${CREAM_REASON:-boot})"
EOF
            else
                cat <<'EOF'

log_warn "TODO: configure this machine (reason ${CREAM_REASON:-boot})"
EOF
            fi
        } > "$ext_dir/hooks/configure"
    fi
    chmod +x "$ext_dir"/hooks/*
fi

# --- tests -------------------------------------------------------------------
{
    cat <<'EOF'
#!/usr/bin/env bash
# H-тесты __NAME__ (cream/v1): хуки на подменённом корне, как их зовёт cream
# (tools/hooktest.sh). apt-get подставной; root и сеть не нужны.
# TODO: проверки поведения — пишутся до кода хука.
#
#   extensions/debian/__NAME__/tests/test-__NAME__.sh        код 0 — все проверки прошли
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../../tools/hooktest.sh
. "$HERE/../../../../tools/hooktest.sh"
EXT="$(dirname "$HERE")"

ht_init

echo "== манифест =="
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "name" __NAME__ "$(mf 'm["name"]')"
EOF
    if (( library )); then
        cat <<'EOF'

echo "== библиотека =="
ht_root "$EXT"
# shellcheck source=../__NAME__.sh
. "$ROOT/opt/cream/ext/__NAME__/__NAME__.sh"
eq "функция библиотеки" __NAME__ "$(__FUNC___hello)"
EOF
    else
        cat <<'EOF'

echo "== install и remove =="
ht_root "$EXT"
ht_fake apt-get
ht_hook install; eq "install — код 0" 0 "$?"
check "apt-get install" ht_called '^apt-get install -y --no-install-recommends __NAME__$'
ht_hook install; eq "повтор install — код 0" 0 "$?"
ht_hook remove; eq "remove — код 0" 0 "$?"
check "apt-get remove" ht_called '^apt-get remove -y __NAME__$'
EOF
        if [[ -n "$stage" ]]; then
            cat <<'EOF'

echo "== configure =="
ht_hook configure CREAM_REASON=boot; eq "configure без устройства — код 0" 0 "$?"
EOF
        fi
    fi
    printf '\nht_done\n'
} > "$ext_dir/tests/test-$name.sh"
chmod +x "$ext_dir/tests/test-$name.sh"

# --- README ------------------------------------------------------------------
{
    cat <<EOF
# $name

TODO: одна фраза — что это расширение даёт машине.

\`\`\`
cream install $name          # живая машина
cream remove $name
EXTENSION $name              # образ bisquite
\`\`\`

## Зачем

TODO: чего не хватает без него и чем это заканчивается на машине. Ссылайся на
замер, а не на общее соображение: «замерено на <образе>, <дата>».

## Настройки

Ключи домена \`$name\` (\`config.keys\` манифеста): \`cream show $name\`,
\`sudo cream set $name KEY=VALUE\`; в образе — \`EXTENSION $name KEY=VALUE\`.

| Ключ | Что задаёт | Умолчание |
|---|---|---|
| \`${prefix}_EXAMPLE\` | TODO | пусто |

## Манифест

| Поле | Значение |
|---|---|
| \`targets\` | \`build: exec\`, \`live: $live\` |
| \`platform.arch\` | ${arch_list[*]} |
EOF
    if (( library )); then
        echo "| \`kind\` | \`library\` — путь \`\${CREAM_ROOT:-}/opt/cream/ext/$name/$name.sh\` |"
    else
        echo "| \`hooks\` | \`install\`${stage:+, \`configure\` (стадия \`$stage\`)}, \`remove\` |"
    fi
    if (( want_cloud_user )); then echo "| \`depends\` | \`cloud-user\` |"; fi
    cat <<EOF

## Проверки

- **V** — \`make cream-validate\`, \`make check-names\`, \`tools/lint-hooks.sh\`.
- **H** — \`tests/test-$name.sh\`.
- **L** — \`make test-live EXT=$name\` (умолчания прогона — \`tests/live.env\`; с ним
  расширение попадает в живые прогоны CI).

## Проверено на

| Система | Архитектура | Дата |
|---|---|---|
| TODO после первого живого прогона | | |
EOF
} > "$ext_dir/README.md"

# Substitute into the quoted templates (quoted so that $… stays literal).
func="${name//-/_}"
while IFS= read -r -d '' f; do
    sed -i -e "s/__NAME__/$name/g" -e "s/__PREFIX__/$prefix/g" \
        -e "s/__STAGE__/$stage/g" -e "s/__FUNC__/$func/g" "$f"
done < <(find "$ext_dir" -type f -print0)

echo "Создано: extensions/debian/$name (cream/v1, cream \">=$cream_min\")"
echo
echo "  extension.yaml          summary, provides/requires ПО КОДУ, config.keys"
if (( library )); then
    echo "  $name.sh                код библиотеки"
else
    echo "  hooks/install, remove   идемпотентно; секреты — из \$CREAM_SECRETS_FILE"
    if [[ -n "$stage" ]]; then echo "  hooks/configure         стадия $stage"; fi
fi
echo "  tests/test-$name.sh     H-тест — поведение пишется до кода"
echo "  README.md               что даёт, ключи, проверки"
echo
echo "Дальше: заполнить TODO, потом  make ci  и  make cream-validate"
