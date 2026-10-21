#!/usr/bin/env bash
# Тест линта хуков (tools/lint-hooks.sh): чистая фикстура
# tools/testdata/lint-hooks/ok проходит; каждая копия, в которой нарушено одно
# правило, красная с именем правила и file:line; без аргументов линт находит
# все расширения каталога сам.
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
has "чистая — строка ок" "lint-hooks: ок, расширений: 1" "$out"

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

# every-boot (spec 2026-10-21 §10.7): a configure hook with a text sign of
# A1-A4 needs hooks.configure.every_boot: true or the exception comment
# `# cream-lint: every-boot-not-needed <причина>`. LINT_EVERY_BOOT=warn (the
# default until the catalog moves to cream 1.2.0) prints the finding and keeps
# code 0; LINT_EVERY_BOOT=error fails the run.
EB="$HERE/testdata/lint-hooks"
out="$(LINT_EVERY_BOOT=error "$LINT" "$FX" 2>&1)"; rc=$?
eq "every-boot: без признаков, error — код 0" 0 "$rc"
out="$("$LINT" "$EB/every-boot-missing" 2>&1)"; rc=$?
eq "every-boot: без every_boot, warn по умолчанию — код 0" 0 "$rc"
has "every-boot: warn — находка видна" "[every-boot]" "$out"
has "every-boot: warn — место и признак" "hooks/configure:6" "$out"
has "every-boot: warn — помечено" "предупреждение" "$out"
out="$(LINT_EVERY_BOOT=warn "$LINT" "$EB/every-boot-missing" 2>&1)"; rc=$?
eq "every-boot: warn явно — код 0" 0 "$rc"
out="$(LINT_EVERY_BOOT=error "$LINT" "$EB/every-boot-missing" 2>&1)"; rc=$?
eq "every-boot: error — код 1" 1 "$rc"
has "every-boot: error — правило" "[every-boot]" "$out"
has "every-boot: error — признак А2" "А2" "$out"
out="$(LINT_EVERY_BOOT=error "$LINT" "$EB/every-boot-excepted" 2>&1)"; rc=$?
eq "every-boot: исключение — код 0" 0 "$rc"
if grep -qF "[every-boot]" <<< "$out"; then bad "every-boot: исключение — находки быть не должно"; else ok; fi
out="$(LINT_EVERY_BOOT=bogus "$LINT" "$FX" 2>&1)"; rc=$?
eq "every-boot: неизвестный режим — код 2" 2 "$rc"

# ebvariant NAME: a fresh copy of every-boot-missing (path on stdout).
ebvariant(){ rm -r -f -- "${TMP:?}/$1"; cp -a "$EB/every-boot-missing" "$TMP/$1"; printf '%s\n' "$TMP/$1"; }
# ebline NAME LINE: every-boot-missing with the hook body replaced by LINE (line 3).
ebline(){
    local v; v="$(ebvariant "$1")"
    printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$2" > "$v/hooks/configure"
}
# eb_red NAME SIGN WHERE: error mode — code 1, names the sign and the place.
eb_red(){
    local out rc
    out="$(LINT_EVERY_BOOT=error "$LINT" "$TMP/$1" 2>&1)"; rc=$?
    eq "$1 — код 1" 1 "$rc"
    has "$1 — правило" "[every-boot]" "$out"
    has "$1 — признак" "$2" "$out"
    has "$1 — место" "$3" "$out"
}
eb_clean(){
    local out rc
    out="$(LINT_EVERY_BOOT=error "$LINT" "$TMP/$1" 2>&1)"; rc=$?
    eq "$1 — код 0" 0 "$rc"
}

# every_boot: true in the manifest — clean.
v="$(ebvariant eb-declared)"; sed -i 's/configure: {stage: system}/configure: {stage: system, every_boot: true}/' "$v/extension.yaml"
eb_clean eb-declared
# every_boot: false is the default, not a declaration.
v="$(ebvariant eb-false)"; sed -i 's/configure: {stage: system}/configure: {stage: system, every_boot: false}/' "$v/extension.yaml"
eb_red eb-false А2 "hooks/configure:6"
# The exception without a reason is no exception.
v="$(ebvariant eb-noreason)"
sed -i '2a # cream-lint: every-boot-not-needed' "$v/hooks/configure"
eb_red eb-noreason А2 "hooks/configure:"
# The text signs, one per variant.
ebline eb-home 'ls /home/ >/dev/null';                                   eb_red eb-home А2 "hooks/configure:3"
ebline eb-uid '(( uid >= 1000 )) && echo x';                             eb_red eb-uid А2 "hooks/configure:3"
ebline eb-cloud 'u="$(/opt/cream/ext/cloud-user/get_cloud_user.sh)"';    eb_red eb-cloud А3 "hooks/configure:3"
ebline eb-again 'systemctl --no-block restart cream-configure@x.service'; eb_red eb-again А4 "hooks/configure:3"
ebline eb-iplink 'ip link set can0 up';                                  eb_red eb-iplink А1 "hooks/configure:3"
ebline eb-ipt 'iptables-legacy -w -A INPUT -j ACCEPT';                   eb_red eb-ipt А1 "hooks/configure:3"
ebline eb-nft 'nft -f /etc/x.nft';                                       eb_red eb-nft А1 "hooks/configure:3"
ebline eb-modprobe 'modprobe can';                                       eb_red eb-modprobe А1 "hooks/configure:3"
ebline eb-run-redir 'echo 1 > "$R/run/x/state"';                         eb_red eb-run-redir А1 "hooks/configure:3"
ebline eb-run-var 'RUN_DIR="$R/run/firewall"';                           eb_red eb-run-var А1 "hooks/configure:3"
ebline eb-run-mkdir 'install -d -m 0700 /run/x';                         eb_red eb-run-mkdir А1 "hooks/configure:3"
# Reading /run (is systemd up?) is not a sign; neither are comments, nor the
# same text in another hook.
ebline eb-run-read '[[ -d "$R/run/systemd/system" ]] && echo up';        eb_clean eb-run-read
ebline eb-comment '# getent passwd, ip link, /home/';                    eb_clean eb-comment
v="$(ebvariant eb-other-hook)"
mv "$v/hooks/configure" "$v/hooks/install"
sed -i 's/configure: {stage: system}/install: {}/' "$v/extension.yaml"
eb_clean eb-other-hook
# The hook hands over to a file of the extension (exec "$CREAM_EXT_DIR/…"):
# that file is read too, and the finding names it.
v="$(ebvariant eb-delegated)"; mkdir -p "$v/files"
printf '#!/usr/bin/env bash\nset -euo pipefail\nexec "${CREAM_EXT_DIR:?run by cream}/files/x.sh" configure\n' > "$v/hooks/configure"
printf '#!/usr/bin/env bash\n# x.sh of the fixture\nset -euo pipefail\ngetent passwd >&2\n' > "$v/files/x.sh"
chmod +x "$v/files/x.sh"
eb_red eb-delegated А2 "files/x.sh:4"
v="$(ebvariant eb-delegated-fallback)"
printf '#!/usr/bin/env bash\nset -euo pipefail\nexec "${CREAM_EXT_DIR:-$(dirname "$0")/..}/x.sh" apply\n' > "$v/hooks/configure"
printf '#!/usr/bin/env bash\nset -euo pipefail\nnft -f /x\n' > "$v/x.sh"
chmod +x "$v/x.sh"
eb_red eb-delegated-fallback А1 "x.sh:3"
# The exception lives in the hook even when the sign is in the delegated file.
sed -i '2a # cream-lint: every-boot-not-needed правила сохраняет nftables.service' "$v/hooks/configure"
eb_clean eb-delegated-fallback

# Several directories: one bad makes the run red, every problem is listed.
out="$("$LINT" "$FX" "$TMP/no-set" "$TMP/blocking" 2>&1)"; rc=$?
eq "чистое + два плохих — код 1" 1 "$rc"
has "оба нарушения видны" "[systemctl-block]" "$out"

out="$("$LINT" "$TMP/nope" 2>&1)"; rc=$?
eq "каталог без extension.yaml — код 2" 2 "$rc"

# Discovery: a copy of the linter in a fake repo — every extension under
# extensions/ is linted, a manifest without `schema: cream/v1` included (the
# catalog has one format; cream validate rejects such a manifest anyway).
mkdir -p "$TMP/repo/tools" "$TMP/repo/extensions/debian/old/hooks"
cp "$LINT" "$TMP/repo/tools/"
cp -a "$FX" "$TMP/repo/extensions/debian/ok"
out="$("$TMP/repo/tools/lint-hooks.sh" 2>&1)"; rc=$?
eq "поиск: чистое — код 0" 0 "$rc"
has "поиск: одно расширение" "расширений: 1" "$out"
printf 'name: old\n' > "$TMP/repo/extensions/debian/old/extension.yaml"
printf '#!/bin/sh\nsystemctl restart x\n' > "$TMP/repo/extensions/debian/old/hooks/install"
chmod +x "$TMP/repo/extensions/debian/old/hooks/install"
out="$("$TMP/repo/tools/lint-hooks.sh" 2>&1)"; rc=$?
eq "поиск: без schema тоже проверяется — код 1" 1 "$rc"
has "поиск: без schema — находка" "extensions/debian/old/hooks/install" "$out"
rm -r -f -- "$TMP/repo/extensions/debian/old"
cp -a "$TMP/blocking" "$TMP/repo/extensions/debian/blocking"
out="$("$TMP/repo/tools/lint-hooks.sh" 2>&1)"; rc=$?
eq "поиск: плохое найдено — код 1" 1 "$rc"
has "поиск: путь от корня репозитория" "extensions/debian/blocking/hooks/configure:5" "$out"

echo "проверок: $((pass + fail)), не прошло: $fail"
(( fail == 0 ))
