#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in python snippets is the test data
# Тесты библиотеки l4t (cream/v1, kind: library) на подменённом корне:
# манифест без хуков, l4t_major на фикстурах /etc/nv_tegra_release R32/R36,
# l4t_openblas_pin (запись, повтор без изменений, замена чужого значения,
# файл без перевода строки) и l4t_openblas_check (окружение из файлов входа и
# служб). Пишется только под $ROOT: путь корня — CREAM_ROOT, как у хука
# потребителя. root, systemd и сеть не нужны; нужен python3.
#
#   extensions/debian/l4t/tests/test-l4t.sh        код 0 — все проверки прошли
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../../tools/hooktest.sh
. "$HERE/../../../../tools/hooktest.sh"
EXT="$(dirname "$HERE")"

ht_init

# lib <code>: source the library from the root's copy in a clean shell with
# CREAM_ROOT=$ROOT and run code; output and status are the shell's.
lib() {
    env -i PATH="$HT_PATH_TAIL" LANG=C.UTF-8 CREAM_ROOT="${LIB_ROOT:-$ROOT}" \
        bash -c 'set -euo pipefail; source "$1"; eval "$2"' lib "$HT_EXT/l4t.sh" "$1"
}
sum() { sha256sum "$@" | awk '{print $1}'; }
release() { mkdir -p "$ROOT/etc"; printf '%s\n' "$1" > "$ROOT/etc/nv_tegra_release"; }

echo "== манифест =="
M="$EXT/extension.yaml"
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$M" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "kind: library" library "$(mf 'm["kind"]')"
eq "хуков нет" None "$(mf 'm.get("hooks")')"
check_not "каталога hooks/ нет" test -e "$EXT/hooks"
eq "arm64" "['arm64']" "$(mf 'm["platform"]["arch"]')"
check "l4t.sh в корне расширения" test -f "$EXT/l4t.sh"

echo "== l4t_major =="
ht_root "$EXT"
out="$(lib l4t_major 2>&1)"; rc=$?
eq "нет файла — код 1" 1 "$rc"
eq "нет файла — пустой вывод" "" "$out"
release '# R32 (release), REVISION: 6.1, GCID: 26953352, BOARD: t210ref, EABI: aarch64, DATE: Tue Mar  2 16:53:42 UTC 2021'
eq "R32 (Nano)" 32 "$(lib l4t_major)"
release '# R36 (release), REVISION: 4.3, GCID: 38968081, BOARD: generic, EABI: aarch64, DATE: Wed Jan  8 01:49:37 UTC 2025'
eq "R36 (Orin)" 36 "$(lib l4t_major)"
release 'garbage'
lib l4t_major >/dev/null 2>&1; eq "не разобрать — код 1" 1 "$?"
release '# R36 (release), REVISION: 4.3'
eq "корень со слешем на конце" 36 "$(LIB_ROOT="$ROOT/" lib l4t_major)"
mkdir -p "$ROOT/alt"; printf '# R35 (release), REVISION: 1.0\n' > "$ROOT/alt/rel"
eq "L4T_RELEASE_FILE перекрывает путь" 35 "$(lib "L4T_RELEASE_FILE=$ROOT/alt/rel; l4t_major")"

echo "== l4t_openblas_pin =="
ht_root "$EXT"
lib 'l4t_openblas_pin l4t-demo' 2>/dev/null; eq "pin — код 0" 0 "$?"
ENVF="$ROOT/etc/environment"
DROP="$ROOT/etc/systemd/system.conf.d/l4t-demo.conf"
eq "/etc/environment" "OPENBLAS_CORETYPE=ARMV8" "$(cat "$ENVF")"
check "drop-in служб [Manager]" grep -qx '\[Manager\]' "$DROP"
check "drop-in DefaultEnvironment" grep -qx 'DefaultEnvironment=OPENBLAS_CORETYPE=ARMV8' "$DROP"
check "drop-in называет расширение" grep -q 'l4t-demo extension' "$DROP"
before="$(sum "$ENVF" "$DROP")"
lib 'l4t_openblas_pin l4t-demo' 2>/dev/null
eq "повтор ничего не меняет" "$before" "$(sum "$ENVF" "$DROP")"
lib 'l4t_openblas_pin l4t-other' 2>/dev/null
eq "второй потребитель: строка одна" 1 "$(grep -c OPENBLAS_CORETYPE "$ENVF")"
check "второй потребитель: свой drop-in" test -f "$ROOT/etc/systemd/system.conf.d/l4t-other.conf"

ht_root "$EXT"
mkdir -p "$ROOT/etc"
printf 'PATH="/usr/bin:/bin"\nexport OPENBLAS_CORETYPE=HASWELL\nLANG=C' > "$ROOT/etc/environment"
lib 'l4t_openblas_pin l4t-demo' 2>/dev/null
eq "чужое значение заменено, прочее и порядок сохранены" \
    "$(printf 'PATH="/usr/bin:/bin"\nOPENBLAS_CORETYPE=ARMV8\nLANG=C')" "$(cat "$ROOT/etc/environment")"

ht_root "$EXT"
mkdir -p "$ROOT/etc"
printf 'LANG=C' > "$ROOT/etc/environment"
lib 'l4t_openblas_pin l4t-demo' 2>/dev/null
eq "файл без перевода строки: строка не склеена" \
    "$(printf 'LANG=C\nOPENBLAS_CORETYPE=ARMV8')" "$(cat "$ROOT/etc/environment")"

echo "== l4t_openblas_check =="
CODE='import os; print(os.environ["OPENBLAS_CORETYPE"])'
ht_root "$EXT"
lib "l4t_openblas_check '$CODE'" >/dev/null 2>&1; eq "без pin — отказ" 1 "$?"
lib 'l4t_openblas_pin l4t-demo' 2>/dev/null
out="$(lib "l4t_openblas_check '$CODE'" 2>&1)"; rc=$?
eq "после pin — код 0" 0 "$rc"
eq "проверены оба источника" 2 "$(grep -c 'ARMV8' <<<"$out")"
check "источник login" grep -q '(login)' <<<"$out"
check "источник systemd" grep -q '(systemd)' <<<"$out"
lib "l4t_openblas_check 'import sys; sys.exit(3)'" >/dev/null 2>&1; eq "код python не прошёл — отказ" 1 "$?"
# An empty DefaultEnvironment= in a later drop-in resets the list for services.
printf '[Manager]\nDefaultEnvironment=\n' > "$ROOT/etc/systemd/system.conf.d/zz-reset.conf"
out="$(lib "l4t_openblas_check '$CODE'" 2>&1)"; rc=$?
eq "сброс в позднем drop-in — отказ" 1 "$rc"
check "отказ называет источник systemd" grep -q 'systemd' <<<"$out"
rm -f "$ROOT/etc/systemd/system.conf.d/zz-reset.conf"
# Another section's DefaultEnvironment does not count.
rm -f "$ROOT/etc/systemd/system.conf.d/l4t-demo.conf"
printf '[Other]\nDefaultEnvironment=OPENBLAS_CORETYPE=ARMV8\n' > "$ROOT/etc/systemd/system.conf.d/l4t-demo.conf"
lib "l4t_openblas_check '$CODE'" >/dev/null 2>&1; eq "не та секция — отказ" 1 "$?"

echo "== журнал вызывающего =="
ht_root "$EXT"
out="$(lib 'log_info(){ echo "CALLER: $*" >&2; }; l4t_openblas_pin l4t-demo' 2>&1)"
check "log_info вызывающего" grep -q '^CALLER: OPENBLAS_CORETYPE=ARMV8' <<<"$out"
out="$(lib 'l4t_openblas_pin l4t-demo' 2>&1)"
check "без log_info — [INFO] в stderr" grep -q '^\[INFO\] ' <<<"$out"

ht_done
