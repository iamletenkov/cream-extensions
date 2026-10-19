#!/usr/bin/env bash
# Тест гейта имён bisquite (tools/check-names.sh) на фикстурах
# tools/testdata/check-names: чистое расширение проходит, грязное — красное
# с file:line каждого имени, исключения (строка `check-names: allow`, блок
# `check-names: off…on`) не считаются; двоичные файлы пропускаются молча; без
# аргументов гейт проверяет весь репозиторий (на копии с подложенным грязным),
# кроме истории — CHANGELOG.md, docs/research/, docs/plans/ — и самого себя.
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

# A line that only names the markers (documentation of the gate) opens no block.
mkdir -p "$TMP/doc"
cp -a "$FX/clean" "$TMP/doc/ext"
printf 'Блок: `check-names: off` … `check-names: on`.\nключ BISQUITE_X\n' > "$TMP/doc/ext/README.md"
out="$("$GATE" "$TMP/doc/ext" 2>&1)"; rc=$?
eq "строка с off и on — блок не открывает" 1 "$rc"
has "строка с off и on — следующая строка проверена" "ext/README.md:2: " "$out"

# A binary file (NUL bytes, invalid UTF-8) is skipped: no hit, no awk noise.
mkdir -p "$TMP/bin"
cp -a "$FX/clean" "$TMP/bin/ext"
mkdir -p "$TMP/bin/ext/images"
printf '\xff\xd8\xff\xe0\x00\x10JFIF\x00/opt/bisquite\xc3\x28\n' > "$TMP/bin/ext/images/w.jpg"
out="$(LC_ALL=C.UTF-8 "$GATE" "$TMP/bin/ext" 2>&1)"; rc=$?
eq "двоичный файл — код 0" 0 "$rc"
hasnt "двоичный файл — не в выводе" "w.jpg" "$out"
hasnt "двоичный файл — без шума awk" "multibyte" "$out"

# Discovery: a copy of the gate in a fake git repository — every file of the
# repository is checked (an extension without `schema: cream/v1`, the root
# README, a workflow), the history (CHANGELOG.md, docs/research/, docs/plans/)
# and the gate itself are not.
R="$TMP/repo"
mkdir -p "$R/tools" "$R/extensions/debian" "$R/docs/research" "$R/docs/plans"
git -C "$R" init -q
cp "$GATE" "$HERE/test-check-names.sh" "$R/tools/"
cp -a "$FX/clean" "$R/extensions/debian/clean"
cp -a "$TMP/bin/ext/images" "$R/extensions/debian/clean/images"
printf 'see /opt/bisquite/old\n' > "$R/CHANGELOG.md"
printf 'was /etc/bisquite/x\n' > "$R/docs/research/2026-01-01-old.md"
printf 'was bisquite-conf\n' > "$R/docs/plans/2026-01-01-old.md"
printf 'ignored /opt/bisquite\n' > "$R/build.log"
printf '*.log\n' > "$R/.gitignore"
out="$("$R/tools/check-names.sh" 2>&1)"; rc=$?
eq "поиск: чистый репозиторий с историей — код 0" 0 "$rc"
has "поиск: строка ок" "check-names: ок, файлов:" "$out"
mkdir -p "$R/extensions/debian/old"
printf 'name: old\n' > "$R/extensions/debian/old/extension.yaml"
printf '. /opt/bisquite/old/lib/bisquite-conf\n' > "$R/extensions/debian/old/install.sh"
printf '# x\nSee `BISQUITE_KEY`.\n' > "$R/README.md"
out="$("$R/tools/check-names.sh" 2>&1)"; rc=$?
eq "поиск: грязное — код 1" 1 "$rc"
has "поиск: расширение без schema проверяется" "extensions/debian/old/install.sh:1: " "$out"
has "поиск: README корня проверяется" "README.md:2: " "$out"
hasnt "поиск: CHANGELOG — история" "CHANGELOG.md" "$out"
hasnt "поиск: docs/research — история" "docs/research" "$out"
hasnt "поиск: docs/plans — история" "docs/plans" "$out"
hasnt "поиск: .gitignore соблюдается" "build.log" "$out"
hasnt "поиск: гейт и его тест не проверяются" "tools/" "$out"

echo "проверок: $((pass + fail)), не прошло: $fail"
(( fail == 0 ))
