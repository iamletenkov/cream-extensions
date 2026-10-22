#!/usr/bin/env bash
# Tests of tools/stage-catalog.sh on a fixture repository: the staged tree is
# the catalog of the working tree (cream-catalog.yaml, LICENSE, NOTICE, the
# roots, without tests/), and every consumer of lib/teleport-core.sh
# (lib/teleport-core.consumers) gets files/teleport-core.sh — byte-equal to
# lib/, mode 0644 — and only consumers do. --ext stages one extension and
# prints its path. Broken setups (a consumer without a directory, no core, a
# busy OUT) are refused with code 2. The real repository stages too.
#
#   tools/test-stage-catalog.sh        code 0 — every check passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"

TMP="$(mktemp -d)"
trap 'rm -r -f -- "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&2; }
check(){ local what="$1"; shift; if "$@"; then ok; else bad "$what"; fi; }
check_not(){ local what="$1"; shift; if "$@"; then bad "$what"; else ok; fi; }
eq(){ if [[ "$2" == "$3" ]]; then ok; else bad "$1: ждали [$2], получили [$3]"; fi; }

# fixture <dir>: a catalog with two roots, two consumers and a bystander.
fixture(){
    local r="$1" e
    mkdir -p "$r/tools" "$r/lib" "$r/docs"
    cp "$HERE/stage-catalog.sh" "$r/tools/"
    printf 'schema: cream/v1\nname: cream-extensions\nversion: 1.2.3\nroots: [extensions/debian, extensions/openwrt]\n' \
        > "$r/cream-catalog.yaml"
    echo license > "$r/LICENSE"; echo notice > "$r/NOTICE"; echo doc > "$r/docs/x.md"
    printf '# core\necho core\n' > "$r/lib/teleport-core.sh"
    printf '# consumers\ndebian/tp\n\nopenwrt/tp-owrt\n' > "$r/lib/teleport-core.consumers"
    for e in debian/tp openwrt/tp-owrt debian/other; do
        mkdir -p "$r/extensions/$e/files" "$r/extensions/$e/tests" "$r/extensions/$e/hooks"
        printf 'schema: cream/v1\nname: %s\n' "${e#*/}" > "$r/extensions/$e/extension.yaml"
        printf '#!/bin/sh\n' > "$r/extensions/$e/hooks/install"; chmod 0755 "$r/extensions/$e/hooks/install"
        echo t > "$r/extensions/$e/tests/test-x.sh"
        echo layer > "$r/extensions/$e/files/teleport.sh"
    done
}

echo "== весь каталог =="
R="$TMP/repo"; fixture "$R"
out="$("$R/tools/stage-catalog.sh" "$TMP/out" 2>&1)"; rc=$?
eq "каталог — код 0" 0 "$rc"
for f in cream-catalog.yaml LICENSE NOTICE extensions/debian/tp/extension.yaml \
         extensions/openwrt/tp-owrt/hooks/install extensions/debian/other/files/teleport.sh; do
    check "в дереве $f" test -f "$TMP/out/$f"
done
check "бит исполнения хука сохранён" test -x "$TMP/out/extensions/openwrt/tp-owrt/hooks/install"
check_not "tests/ в дерево не попадают" test -e "$TMP/out/extensions/debian/tp/tests"
check_not "docs/ в дерево не попадает" test -e "$TMP/out/docs"
check_not "tools/ в дерево не попадает" test -e "$TMP/out/tools"
check_not "lib/ в дерево не попадает" test -e "$TMP/out/lib"
for e in debian/tp openwrt/tp-owrt; do
    check "ядро у потребителя $e — байт в байт" cmp -s "$R/lib/teleport-core.sh" "$TMP/out/extensions/$e/files/teleport-core.sh"
    eq "ядро у $e — 0644" 644 "$(stat -c %a "$TMP/out/extensions/$e/files/teleport-core.sh")"
done
check_not "у непотребителя ядра нет" test -e "$TMP/out/extensions/debian/other/files/teleport-core.sh"
check_not "исходное дерево не тронуто" test -e "$R/extensions/debian/tp/files/teleport-core.sh"

echo "== незакоммиченная правка видна (рабочее дерево, не коммит) =="
echo "echo edited" >> "$R/lib/teleport-core.sh"
"$R/tools/stage-catalog.sh" "$TMP/out2" >/dev/null 2>&1
check "правка ядра в дереве" grep -q 'echo edited' "$TMP/out2/extensions/debian/tp/files/teleport-core.sh"

echo "== --ext: одно расширение =="
got="$("$R/tools/stage-catalog.sh" --ext "$R/extensions/openwrt/tp-owrt" "$TMP/one" 2>/dev/null)"; rc=$?
eq "--ext — код 0" 0 "$rc"
eq "--ext печатает путь" "$TMP/one/tp-owrt" "$got"
check "--ext: ядро на месте" cmp -s "$R/lib/teleport-core.sh" "$TMP/one/tp-owrt/files/teleport-core.sh"
check_not "--ext: без tests/" test -e "$TMP/one/tp-owrt/tests"
got="$("$R/tools/stage-catalog.sh" --ext "$R/extensions/debian/other" "$TMP/one" 2>/dev/null)"; rc=$?
eq "--ext непотребителя — код 0" 0 "$rc"
check_not "--ext непотребителя: ядра нет" test -e "$TMP/one/other/files/teleport-core.sh"
# A relative path and a trailing slash name the same extension.
got="$(cd "$R" && tools/stage-catalog.sh --ext extensions/debian/tp/ "$TMP/rel" 2>/dev/null)"; rc=$?
eq "--ext относительный путь — код 0" 0 "$rc"
check "--ext относительный путь: ядро" test -f "$TMP/rel/tp/files/teleport-core.sh"

echo "== отказы =="
out="$("$R/tools/stage-catalog.sh" "$TMP/out" 2>&1)"; rc=$?
eq "OUT не пуст — код 2" 2 "$rc"
R2="$TMP/repo2"; fixture "$R2"
echo "debian/missing" >> "$R2/lib/teleport-core.consumers"
out="$("$R2/tools/stage-catalog.sh" "$TMP/o3" 2>&1)"; rc=$?
eq "потребитель без каталога — код 2" 2 "$rc"
check "потребитель без каталога назван" grep -q 'debian/missing' <<< "$out"
R3="$TMP/repo3"; fixture "$R3"
rm "$R3/lib/teleport-core.sh"
out="$("$R3/tools/stage-catalog.sh" "$TMP/o4" 2>&1)"; rc=$?
eq "нет ядра — код 2" 2 "$rc"
R4="$TMP/repo4"; fixture "$R4"
printf 'debian/tp\n../../etc\n' > "$R4/lib/teleport-core.consumers"
out="$("$R4/tools/stage-catalog.sh" "$TMP/o5" 2>&1)"; rc=$?
eq "потребитель не <семейство>/<имя> — код 2" 2 "$rc"

echo "== этот репозиторий =="
out="$("$HERE/stage-catalog.sh" "$TMP/real" 2>&1)"; rc=$?
eq "репозиторий — код 0" 0 "$rc"
n=0
while IFS= read -r c; do
    [[ -z "$c" || "$c" == \#* ]] && continue
    n=$((n + 1))
    check "репозиторий: ядро у $c" cmp -s "$REPO/lib/teleport-core.sh" "$TMP/real/extensions/$c/files/teleport-core.sh"
done < "$REPO/lib/teleport-core.consumers"
check "репозиторий: потребители есть" test "$n" -gt 0
check_not "репозиторий: tests/ нет" bash -c 'compgen -G "$1/extensions/*/*/tests" >/dev/null' _ "$TMP/real"

echo "test-stage-catalog: $pass/$((pass + fail))"
(( fail == 0 ))
