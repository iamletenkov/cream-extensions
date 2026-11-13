#!/usr/bin/env bash
# Тест правила «дерево расширения изменилось — версия выросла»
# (tools/check-version-bump.sh) на временных git-репозиториях: правка без
# подъёма — красное с подсказкой; подъём — зелёное; расширение, появившееся
# после тега, и удалённое — без сравнения; база — старший выпущенный тег v*,
# достижимый из HEAD; без тегов — отказ с подсказкой про fetch-depth.
#
#   tools/test-check-version-bump.sh        код 0 — все проверки прошли
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/check-version-bump.sh"

TMP="$(mktemp -d)"
trap 'rm -r -f -- "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&2; }
eq(){ if [[ "$2" == "$3" ]]; then ok; else bad "$1: ждали [$2], получили [$3]"; fi; }
has(){ if grep -qF -- "$2" <<< "$3"; then ok; else bad "$1: нет [$2] в выводе"; fi; }
hasnt(){ if grep -qF -- "$2" <<< "$3"; then bad "$1: лишнее [$2] в выводе"; else ok; fi; }

g(){ git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c tag.gpgsign=false "$@" >/dev/null 2>&1; }
ext(){ # ext <имя> <версия> [текст README]
    mkdir -p "$R/extensions/debian/$1"
    printf 'schema: cream/v1\nname: %s\nversion: %s\n' "$1" "$2" > "$R/extensions/debian/$1/extension.yaml"
    printf '%s\n' "${3:-readme}" > "$R/extensions/debian/$1/README.md"
}
commit(){ g add -A && g commit -q -m "$1"; }
fresh(){
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    R="$TMP/$1"; mkdir -p "$R"; g init -q -b main
    ext alpha 1.0.0; ext beta 2.0.0; ext gone 1.0.0
    commit init; g tag v1.0.0
}

# Без изменений после тега — зелёное.
fresh same
out="$("$GATE" "$R" 2>&1)"; rc=$?
eq "без изменений — код 0" 0 "$rc"
has "без изменений — база названа" "v1.0.0" "$out"

# README изменён, версия та же — красное, имя, обе версии и подсказка.
fresh readme
ext alpha 1.0.0 "другой текст"; commit readme
out="$("$GATE" "$R" 2>&1)"; rc=$?
eq "правка без подъёма — код 1" 1 "$rc"
has "правка без подъёма — расширение названо" "extensions/debian/alpha" "$out"
has "правка без подъёма — версия" "1.0.0" "$out"
has "правка без подъёма — подсказка" "Подними version" "$out"
hasnt "нетронутое не названо" "extensions/debian/beta" "$out"

# Та же правка с подъёмом patch — зелёное.
ext alpha 1.0.1 "другой текст"; commit bump
out="$("$GATE" "$R" 2>&1)"; rc=$?
eq "с подъёмом — код 0" 0 "$rc"

# Версия понижена — красное.
fresh lower
ext beta 1.9.9 "x"; commit lower
out="$("$GATE" "$R" 2>&1)"; rc=$?
eq "понижение — код 1" 1 "$rc"
has "понижение — названо" "extensions/debian/beta" "$out"

# Сравнение версий — числовое, а не строковое: 1.0.10 > 1.0.9.
fresh numeric
ext alpha 1.0.9 "a"; commit a; g tag v1.1.0
ext alpha 1.0.10 "b"; commit b
out="$("$GATE" "$R" 2>&1)"; rc=$?
eq "1.0.10 > 1.0.9 — код 0" 0 "$rc"
has "база — старший тег" "v1.1.0" "$out"

# Расширение, появившееся после тега, и удалённое — без сравнения.
fresh newext
ext gamma 0.1.0; g rm -r -q extensions/debian/gone; commit newext
out="$("$GATE" "$R" 2>&1)"; rc=$?
eq "новое и удалённое — код 0" 0 "$rc"

# Незакоммиченная правка тоже ловится (локальный make ci до коммита).
fresh dirty
printf 'x\n' >> "$R/extensions/debian/beta/README.md"
out="$("$GATE" "$R" 2>&1)"; rc=$?
eq "незакоммиченная правка — код 1" 1 "$rc"

# База — тег, достижимый из HEAD: тег на чужой ветке не в счёт.
fresh branch
g checkout -q -b other; ext alpha 9.0.0 "o"; commit other; g tag v9.0.0
g checkout -q main
out="$("$GATE" "$R" 2>&1)"; rc=$?
eq "чужой тег не база — код 0" 0 "$rc"
has "чужой тег не база — база v1.0.0" "v1.0.0" "$out"

# Явная база --base.
fresh explicit
ext alpha 1.0.0 "z"; commit z; g tag v1.0.1
out="$("$GATE" --base v1.0.0 "$R" 2>&1)"; rc=$?
eq "--base v1.0.0 — код 1" 1 "$rc"

# Без тегов (неглубокий checkout CI) — отказ с подсказкой.
fresh notag
g tag -d v1.0.0
out="$("$GATE" "$R" 2>&1)"; rc=$?
eq "без тегов — код 2" 2 "$rc"
has "без тегов — подсказка" "fetch-depth" "$out"

# Общее ядро lib/teleport-core.sh: его правка требует подъёма всех потребителей,
# непотребитель не затронут; без файла потребителей — как раньше.
fresh core
mkdir -p "$R/lib"; printf '# core\n' > "$R/lib/teleport-core.sh"; printf 'debian/alpha\ndebian/beta\n' > "$R/lib/teleport-core.consumers"
commit core-init; g tag v1.1.0
printf '# core 2\n' > "$R/lib/teleport-core.sh"; commit core-edit
out="$("$GATE" "$R" 2>&1)"; rc=$?
eq "правка ядра без подъёма — код 1" 1 "$rc"
has "правка ядра — потребитель alpha назван" "extensions/debian/alpha" "$out"
has "правка ядра — потребитель beta назван" "extensions/debian/beta" "$out"
has "правка ядра — причина" "ядро lib/teleport-core.sh" "$out"
hasnt "правка ядра — непотребитель не назван" "extensions/debian/gone" "$out"
ext alpha 1.0.1 readme; commit bump-alpha
out="$("$GATE" "$R" 2>&1)"; rc=$?
eq "подъём одного потребителя из двух — код 1" 1 "$rc"
hasnt "поднятый потребитель не назван" "extensions/debian/alpha:" "$out"
ext beta 2.0.1 readme; commit bump-beta
out="$("$GATE" "$R" 2>&1)"; rc=$?
eq "подъём всех потребителей — код 0" 0 "$rc"
# The core unchanged since the tag — consumers need nothing.
fresh core-same
mkdir -p "$R/lib"; printf '# core\n' > "$R/lib/teleport-core.sh"; printf 'debian/alpha\n' > "$R/lib/teleport-core.consumers"
commit core-init; g tag v1.1.0
out="$("$GATE" "$R" 2>&1)"; rc=$?
eq "ядро не менялось — код 0" 0 "$rc"
# A second shared library (lib/fetch.sh): its edit raises its consumers only.
fresh lib-second
mkdir -p "$R/lib"; printf '# core\n' > "$R/lib/teleport-core.sh"; printf 'debian/alpha\n' > "$R/lib/teleport-core.consumers"
printf '# fetch\n' > "$R/lib/fetch.sh"; printf 'debian/beta\n' > "$R/lib/fetch.consumers"
commit libs-init; g tag v1.1.0
printf '# fetch 2\n' > "$R/lib/fetch.sh"; commit fetch-edit
out="$("$GATE" "$R" 2>&1)"; rc=$?
eq "правка второй библиотеки без подъёма — код 1" 1 "$rc"
has "правка fetch — потребитель beta назван" "extensions/debian/beta" "$out"
has "правка fetch — причина" "общая библиотека lib/fetch.sh" "$out"
hasnt "правка fetch — потребитель ядра не назван" "extensions/debian/alpha" "$out"
ext beta 2.0.1 readme; commit bump-beta
out="$("$GATE" "$R" 2>&1)"; rc=$?
eq "подъём потребителя fetch — код 0" 0 "$rc"

# tests/ of an extension does not reach the snapshot (catalog-snapshot.sh), so
# the digest cream compares stays the same: an edit there needs no bump; an
# edit next to it — a file named tests*, a tests/ deeper in files/ — does.
fresh tests-only
mkdir -p "$R/extensions/debian/alpha/tests"; printf 'A=1\n' > "$R/extensions/debian/alpha/tests/live.env"; commit tests-new
out="$("$GATE" "$R" 2>&1)"; rc=$?
eq "новый tests/ без подъёма — код 0" 0 "$rc"
g tag v1.0.1
printf 'A=2\n' > "$R/extensions/debian/alpha/tests/live.env"; commit tests-edit
out="$("$GATE" "$R" 2>&1)"; rc=$?
eq "правка только tests/ — код 0" 0 "$rc"
hasnt "правка только tests/ — расширение не названо" "extensions/debian/alpha" "$out"
fresh tests-near
printf 'x\n' > "$R/extensions/debian/alpha/tests.md"; commit near-file
out="$("$GATE" "$R" 2>&1)"; rc=$?
eq "файл tests.md рядом с tests/ — код 1" 1 "$rc"
fresh tests-deep
mkdir -p "$R/extensions/debian/alpha/files/tests"; printf 'x\n' > "$R/extensions/debian/alpha/files/tests/data"; commit deep
out="$("$GATE" "$R" 2>&1)"; rc=$?
eq "files/tests/ — в снимке, код 1" 1 "$rc"
fresh tests-mixed
mkdir -p "$R/extensions/debian/alpha/tests"; printf 'A=1\n' > "$R/extensions/debian/alpha/tests/live.env"
ext alpha 1.0.0 "другой текст"; commit mixed
out="$("$GATE" "$R" 2>&1)"; rc=$?
eq "tests/ и README вместе — код 1" 1 "$rc"
# One rule for both: the gate excludes exactly what the snapshot excludes.
pat="':(exclude,glob)extensions/*/*/tests/**'"
has "снимок исключает tests/ этим правилом" "$pat" "$(cat "$HERE/catalog-snapshot.sh")"
has "гейт исключает tests/ тем же правилом" "$pat" "$(cat "$GATE")"

echo "test-check-version-bump: ok $pass, fail $fail"
(( fail == 0 ))
