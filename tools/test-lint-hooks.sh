#!/usr/bin/env bash
# Тест линта хуков (tools/lint-hooks.sh): чистая фикстура
# tools/testdata/lint-hooks/ok проходит; каждая копия, в которой нарушено одно
# правило, красная с именем правила и file:line; без аргументов линт находит
# расширения cream/v1 каталога сам и не трогает layout 2.
#
#   tools/test-lint-hooks.sh        код 0 — все проверки прошли
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FX="$HERE/testdata/lint-hooks/ok"
LINT="$HERE/lint-hooks.sh"

TMP="$(mktemp -d)"
trap 'rm -r -f -- "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&2; }
eq(){ if [[ "$2" == "$3" ]]; then ok; else bad "$1: ждали [$2], получили [$3]"; fi; }
has(){ if grep -qF -- "$2" <<< "$3"; then ok; else bad "$1: нет [$2] в выводе"; fi; }

# variant NAME: a fresh copy of the clean fixture at $TMP/NAME (path on stdout).
variant(){ rm -r -f -- "${TMP:?}/$1"; cp -a "$FX" "$TMP/$1"; printf '%s\n' "$TMP/$1"; }

# expect NAME RULE WHERE: the variant fails with code 1, names RULE and WHERE.
expect(){
    local out rc
    out="$("$LINT" "$TMP/$1" 2>&1)"; rc=$?
    eq "$1 — код 1" 1 "$rc"
    has "$1 — правило" "[$2]" "$out"
    has "$1 — место" "$3" "$out"
}

out="$("$LINT" "$FX" 2>&1)"; rc=$?
eq "чистая фикстура — код 0" 0 "$rc"
has "чистая — строка ок" "lint-hooks: ок, расширений cream/v1: 1" "$out"

# Header: shebang and `set -euo pipefail` (`set -eu` in sh) before any command.
v="$(variant no-set)"; sed -i '/^set -euo pipefail$/d' "$v/hooks/install"
expect no-set header "hooks/install:"
v="$(variant late-set)"; sed -i 's/^set -euo pipefail$/echo early\nset -euo pipefail/' "$v/actions/show"
expect late-set header "actions/show:3"
v="$(variant no-pipefail)"; sed -i 's/^set -euo pipefail$/set -eu/' "$v/hooks/remove"
expect no-pipefail header "hooks/remove:"
v="$(variant no-shebang)"; sed -i '1d' "$v/hooks/install"
expect no-shebang header "hooks/install:1"

# Executable bit and hook names.
v="$(variant not-exec)"; chmod -x "$v/hooks/remove"
expect not-exec exec "hooks/remove"
v="$(variant odd-hook)"; cp -a "$v/hooks/remove" "$v/hooks/postinst"
expect odd-hook hook-name "hooks/postinst"

# Blocking systemctl in apply/configure/secret.
v="$(variant blocking)"; sed -i 's/systemctl --no-block restart/systemctl restart/' "$v/hooks/configure"
expect blocking systemctl-block "hooks/configure:5"
v="$(variant blocking-sh)"; sed -i 's/systemctl --no-block try-restart/systemctl try-restart/' "$v/hooks/apply"
expect blocking-sh systemctl-block "hooks/apply:5"
# install may wait for its units: not a violation there.
v="$(variant install-start)"; printf 'systemctl restart ok.service\n' >> "$v/hooks/install"
out="$("$LINT" "$v" 2>&1)"; rc=$?
eq "systemctl restart в install — код 0" 0 "$rc"

# `cream set` from an action with lock: none.
v="$(variant lock-none-set)"; printf 'cream set ok OK_PORT=9090\n' >> "$v/actions/show"
expect lock-none-set lock-none-set "actions/show:5"
v="$(variant lock-none-config-set)"; printf 'cream --json config set ok OK_PORT=1\n' >> "$v/actions/show"
expect lock-none-config-set lock-none-set "actions/show:5"

# Sourcing layout 2 lib/.
v="$(variant source-lib)"; sed -i 's|files/helper.sh"|lib/helper.sh"|' "$v/hooks/install"
expect source-lib source-lib "hooks/install:5"
v="$(variant source-lib-word)"; printf 'source "$CREAM_EXT_DIR/lib/x"\n' >> "$v/hooks/remove"
expect source-lib-word source-lib "hooks/remove:5"

# A secret key's value in argv of cream.
v="$(variant secret-argv)"; sed -i 's/OK_TOKEN=-$/OK_TOKEN="$(cat)"/' "$v/actions/rotate"
expect secret-argv secret-argv "actions/rotate:4"

# CREAM_* is the hook's environment: not assigned, no unknown names.
v="$(variant cream-assign)"; printf 'export CREAM_ROOT=/tmp/x\n' >> "$v/hooks/remove"
expect cream-assign cream-env "hooks/remove:5"
v="$(variant cream-local)"; printf 'f(){ local CREAM_STATE_DIR=/x; }\n' >> "$v/files/helper.sh"
expect cream-local cream-env "files/helper.sh:4"
v="$(variant cream-typo)"; sed -i 's/CREAM_STATE_DIR}/CREAM_STATEDIR}/' "$v/hooks/install"
expect cream-typo cream-env "hooks/install:7"

# Stage cloud-user needs cream >= 1.1.1 (plan 2026-10-19, ruling R14).
v="$(variant stage-old)"; sed -i 's/^cream: ">=1.1.1"$/cream: ">=1.1.0"/' "$v/extension.yaml"
expect stage-old stage-cream "extension.yaml"
v="$(variant stage-none)"; sed -i '/^cream: /d' "$v/extension.yaml"
expect stage-none stage-cream "extension.yaml"
v="$(variant stage-new)"; sed -i 's/^cream: ">=1.1.1"$/cream: ">=1.2.0, <2.0.0"/' "$v/extension.yaml"
out="$("$LINT" "$v" 2>&1)"; rc=$?
eq "cloud-user при cream >=1.2.0 — код 0" 0 "$rc"
v="$(variant stage-system)"
sed -i -e 's/stage: cloud-user/stage: system/' -e 's/^cream: ">=1.1.1"$/cream: ">=1.0.0"/' "$v/extension.yaml"
out="$("$LINT" "$v" 2>&1)"; rc=$?
eq "system при cream >=1.0.0 — код 0" 0 "$rc"

# Comments and tests/ are not linted.
v="$(variant comments)"
printf '# cream set ok OK_TOKEN=x; systemctl restart a; CREAM_FOO=1\n' >> "$v/actions/show"
mkdir -p "$v/tests"; printf '#!/usr/bin/env bash\nCREAM_ROOT=/tmp/x systemctl restart a\n' > "$v/tests/test-ok.sh"
out="$("$LINT" "$v" 2>&1)"; rc=$?
eq "комментарии и tests/ — код 0" 0 "$rc"

# Several directories: one bad makes the run red, every problem is listed.
out="$("$LINT" "$FX" "$TMP/no-set" "$TMP/blocking" 2>&1)"; rc=$?
eq "чистое + два плохих — код 1" 1 "$rc"
has "оба нарушения видны" "[systemctl-block]" "$out"

out="$("$LINT" "$TMP/nope" 2>&1)"; rc=$?
eq "каталог без extension.yaml — код 2" 2 "$rc"

# Discovery: a copy of the linter in a fake repo — cream/v1 is found, layout 2
# (no `schema: cream/v1`) is not linted.
mkdir -p "$TMP/repo/tools" "$TMP/repo/extensions/debian/old"
cp "$LINT" "$TMP/repo/tools/"
cp -a "$FX" "$TMP/repo/extensions/debian/ok"
printf 'layout: 2\nname: old\n' > "$TMP/repo/extensions/debian/old/extension.yaml"
printf '#!/bin/sh\nsystemctl restart x\n' > "$TMP/repo/extensions/debian/old/knobs.apply"
out="$("$TMP/repo/tools/lint-hooks.sh" 2>&1)"; rc=$?
eq "поиск: layout 2 не проверяется — код 0" 0 "$rc"
has "поиск: одно расширение" "расширений cream/v1: 1" "$out"
cp -a "$TMP/blocking" "$TMP/repo/extensions/debian/blocking"
out="$("$TMP/repo/tools/lint-hooks.sh" 2>&1)"; rc=$?
eq "поиск: плохое найдено — код 1" 1 "$rc"
has "поиск: путь от корня репозитория" "extensions/debian/blocking/hooks/configure:5" "$out"

echo "проверок: $((pass + fail)), не прошло: $fail"
(( fail == 0 ))
