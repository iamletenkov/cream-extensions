#!/usr/bin/env bash
# Tests of tools/check-shared-libs.sh on fixture git repositories: one copy of
# every shared library in git (a copy under extensions/ — tracked or lying in the
# tree — is refused); for the core (`# rule: files`) every consumer declares
# files/teleport-core.sh in `files` and an extension that declares it is a
# consumer; for a sourced library (fetch) every consumer names files/fetch.sh in
# its tree and an extension naming it is a consumer; the staged copies are the
# bytes of lib/. The real repository passes.
#
#   tools/test-check-shared-libs.sh        code 0 — every check passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMP="$(mktemp -d)"
trap 'rm -r -f -- "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&2; }
eq(){ if [[ "$2" == "$3" ]]; then ok; else bad "$1: ждали [$2], получили [$3]"; fi; }
has(){ if grep -qF -- "$2" <<< "$3"; then ok; else bad "$1: нет [$2] в выводе: $3"; fi; }

g(){ git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@" >/dev/null 2>&1; }
LINE='  - {src: files/teleport-core.sh, dst: /usr/lib/%s/teleport-core.sh, mode: "0644"}'
# ext <family/name> <declares core: 0|1>
ext(){
    local d="$R/extensions/$1"
    mkdir -p "$d/files"
    {
        printf 'schema: cream/v1\nname: %s\nversion: 1.0.0\nfiles:\n' "${1#*/}"
        printf '  - {src: files/x.conf, dst: /etc/%s.conf, mode: "0644"}\n' "${1#*/}"
        # shellcheck disable=SC2059  # LINE is the format
        (( $2 )) && printf "$LINE\n" "${1#*/}"
    } > "$d/extension.yaml"
    echo x > "$d/files/x.conf"
}
# hook <family/name> <sources fetch: 0|1>
hook(){
    mkdir -p "$R/extensions/$1/hooks"
    { echo '#!/bin/sh'; (( $2 )) && echo '. "$CREAM_EXT_DIR/files/fetch.sh"'; echo 'exit 0'; } > "$R/extensions/$1/hooks/install"
}
fresh(){
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    R="$TMP/$1"; mkdir -p "$R/tools" "$R/lib"
    cp "$HERE/check-shared-libs.sh" "$HERE/stage-catalog.sh" "$R/tools/"
    printf 'schema: cream/v1\nname: cream-extensions\nversion: 1.0.0\nroots: [extensions/debian, extensions/openwrt]\n' > "$R/cream-catalog.yaml"
    printf '# core\n' > "$R/lib/teleport-core.sh"
    printf '# rule: files\ndebian/tp\nopenwrt/tp-owrt\n' > "$R/lib/teleport-core.consumers"
    ext debian/tp 1; ext openwrt/tp-owrt 1; ext debian/other 0
    # A sourced library: debian/dl sources files/fetch.sh from a hook.
    printf '# fetch\n' > "$R/lib/fetch.sh"
    printf 'debian/dl\n' > "$R/lib/fetch.consumers"
    ext debian/dl 0; hook debian/dl 1
    g init -q -b main; g add -A; g commit -q -m init
}
run(){ out="$("$R/tools/check-shared-libs.sh" 2>&1)"; rc=$?; }

fresh good; run
eq "чистый репозиторий — код 0" 0 "$rc"
has "чистый — итог" "check-shared-libs: ок, библиотек 2" "$out"

fresh tracked
cp "$R/lib/teleport-core.sh" "$R/extensions/debian/tp/files/teleport-core.sh"; g add -A; g commit -q -m copy
run
eq "копия в git — код 1" 1 "$rc"
has "копия в git — путь назван" "extensions/debian/tp/files/teleport-core.sh" "$out"

fresh loose
cp "$R/lib/teleport-core.sh" "$R/extensions/openwrt/tp-owrt/files/teleport-core.sh"
run
eq "копия в дереве (не в git) — код 1" 1 "$rc"
has "копия в дереве — путь назван" "extensions/openwrt/tp-owrt/files/teleport-core.sh" "$out"

fresh noline
ext openwrt/tp-owrt 0; g add -A; g commit -q -m noline
run
eq "потребитель без строки files — код 1" 1 "$rc"
has "потребитель без строки files — назван" "openwrt/tp-owrt" "$out"
has "потребитель без строки files — что нужно" "files/teleport-core.sh" "$out"

fresh stranger
ext debian/other 1; g add -A; g commit -q -m stranger
run
eq "непотребитель объявил ядро — код 1" 1 "$rc"
has "непотребитель назван" "debian/other" "$out"
has "непотребитель — подсказка" "teleport-core.consumers" "$out"

fresh nocore
rm "$R/lib/teleport-core.sh"
run
eq "нет ядра — код 2" 2 "$rc"

fresh missing
printf 'debian/tp\ndebian/gone\n' > "$R/lib/teleport-core.consumers"
run
eq "потребитель без каталога — код 2" 2 "$rc"
has "потребитель без каталога — назван" "debian/gone" "$out"

fresh fetchcopy
cp "$R/lib/fetch.sh" "$R/extensions/debian/dl/files/fetch.sh"; g add -A; g commit -q -m copy
run
eq "копия fetch.sh в files/ — код 1" 1 "$rc"
has "копия fetch.sh — путь назван" "extensions/debian/dl/files/fetch.sh" "$out"

fresh shim
printf '. "$(dirname "$0")/files/fetch.sh"\n' > "$R/extensions/debian/dl/fetch.sh"; g add -A; g commit -q -m shim
run
eq "прослойка fetch.sh в корне расширения (не files/) — код 0" 0 "$rc"

fresh nosource
hook debian/dl 0; g add -A; g commit -q -m nosource
run
eq "потребитель fetch не берёт files/fetch.sh — код 1" 1 "$rc"
has "потребитель fetch назван" "debian/dl" "$out"

fresh fetchstranger
hook debian/other 1; g add -A; g commit -q -m stranger
run
eq "непотребитель берёт files/fetch.sh — код 1" 1 "$rc"
has "непотребитель fetch назван" "debian/other" "$out"
has "непотребитель fetch — подсказка" "fetch.consumers" "$out"

fresh testsonly
mkdir -p "$R/extensions/debian/other/tests"; echo 'files/fetch.sh' > "$R/extensions/debian/other/tests/test-x.sh"
echo 'files/fetch.sh' > "$R/extensions/debian/other/README.md"; g add -A; g commit -q -m tests
run
eq "упоминание в tests/ и README — не потребление, код 0" 0 "$rc"

fresh nofetch
rm "$R/lib/fetch.sh"
run
eq "нет lib/fetch.sh при fetch.consumers — код 2" 2 "$rc"

out="$("$HERE/check-shared-libs.sh" 2>&1)"; rc=$?
eq "этот репозиторий — код 0" 0 "$rc"
[[ "$rc" == 0 ]] || echo "$out" >&2

echo "test-check-shared-libs: $pass/$((pass + fail))"
(( fail == 0 ))
