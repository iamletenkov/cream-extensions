#!/usr/bin/env bash
# Матрица живых прогонов для CI (.github/workflows/live.yml): какие расширения и
# на каких дистрибутивах гонять tools/live-test.sh.
#
#   tools/live-matrix.sh --all              все L-расширения
#   tools/live-matrix.sh --changed FILE     по списку изменённых путей (строка на путь)
#
# L-расширение — каталог extensions/<семейство>/<имя>/ с tests/live.env.
# Дистрибутивы — LIVE_DISTROS из его live.env (умолчание «debian-12 ubuntu-24.04»).
# По изменённым путям: расширение попадает в матрицу, если изменилось оно само
# или одно из его LIVE_DEPS; изменение пина cream (tools/cream-pin.env) —
# все L-расширения. LIVE_NIGHTLY_ONLY=1 в live.env (тяжёлые: gnome, lxde) —
# только в --all (ночь, ручной запуск), в --changed (PR) — никогда, даже при
# смене пина. Изменение самого раннера проверяет самопроверка
# (tools/test-live-test.sh), не матрица.
#
# stdout — одна строка JSON: {"include":[{"ext":"…","distro":"…"},…]}; пустая
# матрица — {"include":[]}. Код 2 — ошибка вызова.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${LIVE_MATRIX_REPO:-$(dirname "$HERE")}"

mode="${1:-}"
case "$mode" in
    --all) ;;
    --changed) [[ -f "${2:-}" ]] || { echo "live-matrix: --changed FILE: нет файла" >&2; exit 2; } ;;
    *) echo "live-matrix: --all | --changed FILE" >&2; exit 2 ;;
esac

envval() {
    local line
    line="$(grep -E "^$2=" "$1" | tail -n1)" || true
    line="${line#*=}"
    line="${line%\"}"; line="${line#\"}"
    printf '%s' "$line"
}

changed=()
all=""
if [[ "$mode" == --changed ]]; then
    while IFS= read -r p; do
        case "$p" in
            tools/cream-pin.env) all=1 ;;
            extensions/*/*/*) n="${p#extensions/*/}"; changed+=("${n%%/*}") ;;
        esac
    done < "$2"
else
    all=1
fi

is_changed() {
    local c
    for c in "${changed[@]}"; do [[ "$c" == "$1" ]] && return 0; done
    return 1
}

items=()
while IFS= read -r envf; do
    dir="$(dirname "$(dirname "$envf")")"
    name="$(basename "$dir")"
    if [[ "$mode" == --changed && "$(envval "$envf" LIVE_NIGHTLY_ONLY)" == 1 ]]; then
        continue
    fi
    pick="$all"
    if [[ -z "$pick" ]]; then
        is_changed "$name" && pick=1
        for d in $(envval "$envf" LIVE_DEPS); do
            is_changed "$d" && pick=1
        done
    fi
    [[ -n "$pick" ]] || continue
    distros="$(envval "$envf" LIVE_DISTROS)"
    for distro in ${distros:-debian-12 ubuntu-24.04}; do
        items+=("{\"ext\":\"$name\",\"distro\":\"$distro\"}")
    done
done < <(find "$REPO/extensions" -mindepth 4 -maxdepth 4 -path '*/tests/live.env' | sort)

printf '{"include":['
(( ${#items[@]} )) && (IFS=,; printf '%s' "${items[*]}")
printf ']}\n'
