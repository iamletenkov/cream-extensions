#!/usr/bin/env bash
# Тест гейта имён bisquite (tools/check-names.sh) на фикстурах
# tools/testdata/check-names: чистое расширение проходит, грязное — красное
# с file:line каждого имени, исключения (строка `check-names: allow`, блок
# `check-names: off…on`) не считаются; без аргументов гейт находит
# расширения cream/v1 каталога сам (на копии с подложенным грязным).
#
#   tools/test-check-names.sh        код 0 — все проверки прошли
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FX="$HERE/testdata/check-names"
GATE="$HERE/check-names.sh"

TMP="$(mktemp -d)"
trap 'rm -r -f -- "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&2; }
eq(){ if [[ "$2" == "$3" ]]; then ok; else bad "$1: ждали [$2], получили [$3]"; fi; }
has(){ if grep -qF -- "$2" <<< "$3"; then ok; else bad "$1: нет [$2] в выводе"; fi; }
hasnt(){ if grep -qF -- "$2" <<< "$3"; then bad "$1: лишнее [$2] в выводе"; else ok; fi; }

out="$("$GATE" "$FX/clean" 2>&1)"; rc=$?
eq "чистое — код 0" 0 "$rc"
has "чистое — строка ок" "check-names: ок, расширений cream/v1: 1" "$out"

out="$("$GATE" "$FX/dirty" 2>&1)"; rc=$?
eq "грязное — код 1" 1 "$rc"
has "грязное — /opt/bisquite с номером строки" "dirty/hooks/install:2: " "$out"
has "грязное — inet bisquite" "dirty/hooks/install:3: nft add table inet bisquite" "$out"
has "грязное — ключ BISQUITE_ в README" "dirty/README.md:3: " "$out"

out="$("$GATE" "$FX/excepted" 2>&1)"; rc=$?
eq "исключения — код 0" 0 "$rc"
hasnt "блок off…on не виден" "/etc/bisquite/excepted" "$out"

out="$("$GATE" "$FX/clean" "$FX/dirty" 2>&1)"; rc=$?
eq "чистое + грязное — код 1" 1 "$rc"

out="$("$GATE" "$TMP/nope" 2>&1)"; rc=$?
eq "каталог без extension.yaml — код 2" 2 "$rc"

# Discovery: a copy of the gate in a fake repo — cream/v1 dirty is found,
# layout 2 dirty (no `schema: cream/v1`) is not checked.
mkdir -p "$TMP/repo/tools" "$TMP/repo/extensions/debian"
cp "$GATE" "$TMP/repo/tools/"
cp -a "$FX/clean" "$TMP/repo/extensions/debian/clean"
mkdir -p "$TMP/repo/extensions/debian/old"
printf 'layout: 2\nname: old\n' > "$TMP/repo/extensions/debian/old/extension.yaml"
printf '. /opt/bisquite/old/lib/bisquite-conf\n' > "$TMP/repo/extensions/debian/old/install.sh"
out="$("$TMP/repo/tools/check-names.sh" 2>&1)"; rc=$?
eq "поиск: layout 2 не проверяется — код 0" 0 "$rc"
cp -a "$FX/dirty" "$TMP/repo/extensions/debian/dirty"
out="$("$TMP/repo/tools/check-names.sh" 2>&1)"; rc=$?
eq "поиск: cream/v1 грязное найдено — код 1" 1 "$rc"
has "поиск: путь от корня репозитория" "extensions/debian/dirty/hooks/install:2: " "$out"

echo "проверок: $((pass + fail)), не прошло: $fail"
(( fail == 0 ))
