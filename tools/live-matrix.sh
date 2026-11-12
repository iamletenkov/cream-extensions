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
# смене пина. LIVE_NIGHTLY_DISTROS — дистрибутивы, добавляемые к LIVE_DISTROS
# только в --all. Изменение самого раннера проверяет самопроверка
# (tools/test-live-test.sh), не матрица.
#
# Вариант — tests/live.<v>.env рядом с live.env (<v> — [a-z0-9][a-z0-9-]*,
# иначе предупреждение в stderr и не строка): своя строка матрицы с "variant",
# ключи — из файла варианта, нет там — из live.env (так же читает
# tools/live-test.sh --variant). Варианты изменённого расширения попадают в
# --changed вместе с ним, по тем же правилам LIVE_DEPS и LIVE_NIGHTLY_ONLY.
#
# stdout — одна строка JSON: {"include":[{"ext":"…","distro":"…"},…]}, у строки
# варианта ещё "variant":"<v>"; пустая матрица — {"include":[]}. Без вариантов и
# LIVE_NIGHTLY_DISTROS вывод тот же, что до них. Код 2 — ошибка вызова.
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

# keyval KEY FILE…: the value from the last FILE that sets KEY (a variant over
# live.env); no FILE sets it — empty.
keyval() {
    local key="$1" f v=""
    shift
    for f in "$@"; do
        grep -Eq "^$key=" "$f" && v="$(envval "$f" "$key")"
    done
    printf '%s' "$v"
}

# rows NAME VARIANT FILE…: the matrix rows of one live.env (VARIANT empty) or
# one variant (FILE… — live.env, then the variant file).
rows() {
    local name="$1" variant="$2" pick d distros distro extra seen=" "
    shift 2
    if [[ "$mode" == --changed && "$(keyval LIVE_NIGHTLY_ONLY "$@")" == 1 ]]; then
        return 0
    fi
    pick="$all"
    if [[ -z "$pick" ]]; then
        is_changed "$name" && pick=1
        for d in $(keyval LIVE_DEPS "$@"); do
            is_changed "$d" && pick=1
        done
    fi
    [[ -n "$pick" ]] || return 0
    distros="$(keyval LIVE_DISTROS "$@")"
    distros="${distros:-debian-12 ubuntu-24.04}"
    [[ "$mode" == --all ]] && distros="$distros $(keyval LIVE_NIGHTLY_DISTROS "$@")"
    extra=""
    [[ -n "$variant" ]] && extra=",\"variant\":\"$variant\""
    for distro in $distros; do
        [[ "$seen" == *" $distro "* ]] && continue
        seen+="$distro "
        items+=("{\"ext\":\"$name\",\"distro\":\"$distro\"$extra}")
    done
}

items=()
while IFS= read -r envf; do
    tests="$(dirname "$envf")"
    name="$(basename "$(dirname "$tests")")"
    rows "$name" "" "$envf"
    while IFS= read -r vf; do
        v="${vf##*/live.}"; v="${v%.env}"
        if [[ ! "$v" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
            echo "live-matrix: $name: ${vf##*/} — имя варианта не [a-z0-9][a-z0-9-]*, пропущен" >&2
            continue
        fi
        rows "$name" "$v" "$envf" "$vf"
    done < <(find "$tests" -mindepth 1 -maxdepth 1 -type f -name 'live.?*.env' | LC_ALL=C sort)
done < <(find "$REPO/extensions" -mindepth 4 -maxdepth 4 -path '*/tests/live.env' | sort)

printf '{"include":['
(( ${#items[@]} )) && (IFS=,; printf '%s' "${items[*]}")
printf ']}\n'
