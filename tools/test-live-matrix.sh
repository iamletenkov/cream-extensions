#!/usr/bin/env bash
# Тест матрицы живых прогонов (tools/live-matrix.sh) на подставном каталоге:
# --all — все расширения с tests/live.env по их LIVE_DISTROS (умолчание —
# debian-12 и ubuntu-24.04); --changed — изменённое расширение и те, чьи
# LIVE_DEPS изменились; пин cream — все; расширение без live.env — никогда.
#
#   tools/test-live-matrix.sh        код 0 — все проверки прошли
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -r -f -- "$TMP"' EXIT

pass=0; fail=0
eq(){ if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: ждали [$2], получили [$3]" >&2; fi; }

R="$TMP/repo"
mkdir -p "$R/extensions/debian/"{lib-a,app-b,app-c,plain}/tests
printf 'LIVE_DISTROS="debian-12"\n' > "$R/extensions/debian/lib-a/tests/live.env"
printf 'LIVE_DEPS=lib-a\nLIVE_DISTROS="debian-12 ubuntu-22.04"\n' > "$R/extensions/debian/app-b/tests/live.env"
printf '# defaults\n' > "$R/extensions/debian/app-c/tests/live.env"
m(){ LIVE_MATRIX_REPO="$R" "$HERE/live-matrix.sh" "$@"; }
ch(){ printf '%s\n' "$@" > "$TMP/changed"; m --changed "$TMP/changed"; }

eq "--all" '{"include":[{"ext":"app-b","distro":"debian-12"},{"ext":"app-b","distro":"ubuntu-22.04"},{"ext":"app-c","distro":"debian-12"},{"ext":"app-c","distro":"ubuntu-24.04"},{"ext":"lib-a","distro":"debian-12"}]}' "$(m --all)"
eq "изменено app-c" '{"include":[{"ext":"app-c","distro":"debian-12"},{"ext":"app-c","distro":"ubuntu-24.04"}]}' \
    "$(ch extensions/debian/app-c/hooks/install)"
eq "изменена зависимость lib-a" '{"include":[{"ext":"app-b","distro":"debian-12"},{"ext":"app-b","distro":"ubuntu-22.04"},{"ext":"lib-a","distro":"debian-12"}]}' \
    "$(ch extensions/debian/lib-a/files/x.sh)"
eq "без live.env — не в матрице" '{"include":[]}' "$(ch extensions/debian/plain/hooks/install README.md)"
eq "пин cream — все" "$(m --all)" "$(ch tools/cream-pin.env)"
eq "раннер — не матрица" '{"include":[]}' "$(ch tools/live-test.sh)"
m --bogus >/dev/null 2>&1; eq "неверный вызов — 2" 2 "$?"

echo "проверок: $((pass + fail)), не прошло: $fail"
(( fail == 0 ))
