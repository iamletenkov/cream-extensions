#!/usr/bin/env bash
# Тест каркаса tools/new-extension.sh: скелеты cream/v1 (простой; стадия
# cloud-user с библиотекой cloud-user; graphical с live: confirm; библиотека)
# во временном каталоге сразу проходят линт хуков, гейт имён, shellcheck
# уровня warning и собственный H-тест; `cream validate` по пину принимает их
# (есть docker и cream — CREAM_DEB или кеш/скачивание пина). Отказы: имя,
# зарезервированное имя, стадия, live, библиотека со стадией, повтор.
#
#   tools/test-new-extension.sh        код 0 — все проверки прошли
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
NEW="$HERE/new-extension.sh"

T="$(mktemp -d)"
trap 'rm -r -f -- "$T"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&2; }
eq(){ if [[ "$2" == "$3" ]]; then ok; else bad "$1: ждали [$2], получили [$3]"; fi; }
has(){ if grep -qF -- "$2" <<< "$3"; then ok; else bad "$1: нет [$2] в выводе"; fi; }

# A catalog copy: the tools the scaffold's test and checks need.
mkdir -p "$T/cat/tools" "$T/cat/extensions/debian"
cp "$HERE/hooktest.sh" "$HERE/lint-hooks.sh" "$HERE/check-names.sh" "$T/cat/tools/"
new(){ NEW_EXTENSION_ROOT="$T/cat" "$NEW" "$@"; }
E="$T/cat/extensions/debian"

new plain > "$T/plain.log" 2>&1; eq "plain — код 0" 0 "$?"
new desk --stage cloud-user --cloud-user > /dev/null 2>&1; eq "desk — код 0" 0 "$?"
new view --stage graphical --live confirm --arch amd64 > /dev/null 2>&1; eq "view — код 0" 0 "$?"
new shared-lib --library > /dev/null 2>&1; eq "shared-lib — код 0" 0 "$?"
has "plain — что дальше" "make ci" "$(cat "$T/plain.log")"

# eval: the expressions are this test's own literals, the manifest is the scaffold's output.
mf(){ python3 -I -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$E/$1/extension.yaml" "$2"; }
eq "plain: schema" cream/v1 "$(mf plain 'm["schema"]')"
eq "plain: cream" ">=1.0.0" "$(mf plain 'm["cream"]')"
eq "plain: хуки" "['install', 'remove']" "$(mf plain 'list(m["hooks"])')"
eq "plain: ключ домена" "['PLAIN_EXAMPLE']" "$(mf plain 'list(m["config"]["keys"])')"
eq "desk: cream для cloud-user" ">=1.1.1" "$(mf desk 'm["cream"]')"
eq "desk: стадия" cloud-user "$(mf desk 'm["hooks"]["configure"]["stage"]')"
eq "desk: depends" cloud-user "$(mf desk 'm["depends"][0]["name"]')"
eq "view: cream для graphical" ">=1.1.0" "$(mf view 'm["cream"]')"
eq "view: live" confirm "$(mf view 'm["targets"]["live"]')"
eq "view: live_note" True "$(mf view 'bool(m["targets"]["live_note"])')"
eq "view: arch" "['amd64']" "$(mf view 'm["platform"]["arch"]')"
eq "shared-lib: kind" library "$(mf shared-lib 'm["kind"]')"
eq "shared-lib: без хуков" False "$(mf shared-lib '"hooks" in m')"
if [[ -x "$E/desk/hooks/configure" ]]; then ok; else bad "desk: hooks/configure исполняемый"; fi
if grep -q 'opt/cream/ext/cloud-user/get_cloud_user.sh' "$E/desk/hooks/configure"; then ok; else bad "desk: путь библиотеки"; fi
if grep -rq '__NAME__\|__PREFIX__\|__STAGE__\|__FUNC__' "$E"; then bad "остались подстановки шаблона"; else ok; fi

out="$("$T/cat/tools/lint-hooks.sh" 2>&1)"; rc=$?
eq "lint-hooks по скелетам — код 0" 0 "$rc"
has "lint-hooks — все четыре" "расширений cream/v1: 4" "$out"
out="$("$T/cat/tools/check-names.sh" 2>&1)"; rc=$?
eq "check-names по скелетам — код 0" 0 "$rc"

mapfile -t sh_files < <(find "$E" -type f \( -path '*/hooks/*' -o -path '*/tests/*' -o -name '*.sh' \) | sort)
if command -v shellcheck >/dev/null 2>&1; then
    if out="$(shellcheck -x -S warning "${sh_files[@]}" 2>&1)"; then ok; else bad "shellcheck -S warning скелетов"; echo "$out" >&2; fi
else
    echo "shellcheck скелетов пропущен: нет shellcheck (make lint проверит в контейнере)"
fi

for x in plain desk view shared-lib; do
    out="$("$E/$x/tests/test-$x.sh" 2>&1)"; rc=$?
    eq "$x: свой H-тест — код 0" 0 "$rc"
    [[ $rc -eq 0 ]] || echo "$out" >&2
done

# Refusals.
new 'Bad_Name' > /dev/null 2>&1; eq "имя с заглавными — код 2" 2 "$?"
new lock > /dev/null 2>&1; eq "зарезервированное имя — код 2" 2 "$?"
new x1 --stage boot > /dev/null 2>&1; eq "неизвестная стадия — код 2" 2 "$?"
new x2 --live maybe > /dev/null 2>&1; eq "неизвестный live — код 2" 2 "$?"
new x3 --arch riscv64 > /dev/null 2>&1; eq "чужая архитектура — код 2" 2 "$?"
new x4 --library --stage system > /dev/null 2>&1; eq "библиотека со стадией — код 2" 2 "$?"
new plain > /dev/null 2>&1; eq "повтор — код 1" 1 "$?"
if [[ -e "$E/x1" || -e "$E/x4" ]]; then bad "отказ оставил каталог"; else ok; fi

# cream validate by the pin (with the real cloud-user library for `depends`).
if ! command -v docker >/dev/null 2>&1; then
    echo "cream validate скелетов пропущен: нет docker"
else
    # A skeleton that needs a cream newer than the pin (cloud-user: 1.1.1 on the
    # 1.1.0 pin) would be set aside as not applicable: its copy is validated
    # with the requirement lowered to the pinned cream.
    pinned="$(grep -E '^CREAM_VERSION=' "$HERE/cream-pin.env" | tail -n1 | cut -d= -f2-)"
    vdirs=()
    for x in plain desk view shared-lib; do
        mkdir -p "$T/val"; cp -a "$E/$x" "$T/val/$x"
        need="$(sed -n 's/^cream: ">=\([0-9.]*\)"$/\1/p' "$T/val/$x/extension.yaml")"
        if [[ -n "$pinned" && "$need" != "$pinned" \
              && "$(printf '%s\n%s\n' "$need" "$pinned" | sort -V | tail -n1)" == "$need" ]]; then
            sed -i "s/^cream: \">=$need\"/cream: \">=$pinned\"/" "$T/val/$x/extension.yaml"
        fi
        vdirs+=("$T/val/$x")
    done
    if out="$("$HERE/cream-validate.sh" "${vdirs[@]}" "$REPO/extensions/debian/cloud-user" 2>&1)"; then
        ok
    else
        bad "cream validate скелетов"; echo "$out" >&2
    fi
    if grep -q 'неприменим' <<< "$out"; then bad "cream validate: скелет отложен как неприменимый"; else ok; fi
    grep -E '^cream [0-9]|без ошибок' <<< "$out"
fi

echo "test-new-extension: ок $pass, сбоев $fail"
(( fail == 0 ))
