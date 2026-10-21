#!/usr/bin/env bash
# Тест проверки ссылок (tools/check-links.sh) на временном git-репозитории:
# целые ссылки и якоря (кириллица, обратные кавычки, повторы -1) — код 0;
# нет файла, нет заголовка, выход за репозиторий — код 1 с файлом и строкой;
# ссылки в коде и внешние адреса без --external не проверяются; .gitignore
# соблюдается.
#
#   tools/test-check-links.sh        код 0 — все проверки прошли
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/check-links.sh"
# Inside a git hook GIT_DIR points to the hook's repository, not to the test one.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

TMP="$(mktemp -d)"
trap 'rm -r -f -- "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&2; }
eq(){ if [[ "$2" == "$3" ]]; then ok; else bad "$1: ждали [$2], получили [$3]"; fi; }
has(){ if grep -qF -- "$2" <<< "$3"; then ok; else bad "$1: нет [$2] в выводе"; fi; }
hasnt(){ if grep -qF -- "$2" <<< "$3"; then bad "$1: лишнее [$2] в выводе"; else ok; fi; }

R="$TMP/repo"
mkdir -p "$R/docs/guides"
git -C "$R" init -q
cat > "$R/docs/guides/a.md" <<'EOF'
# Руководство

## Отметка выполнения и `every_boot`

## Шаги

## Шаги

Текст.
EOF
cat > "$R/README.md" <<'EOF'
# Корень

[гайд](docs/guides/a.md) · [якорь](docs/guides/a.md#отметка-выполнения-и-every_boot)
[повтор](docs/guides/a.md#шаги-1) · [свой](#корень) · [внешний](https://example.invalid/x)
`[в коде](нет.md)`

```
[в блоке](тоже-нет.md)
```
EOF
out="$("$GATE" --repo "$R" 2>&1)"; rc=$?
eq "целые ссылки — код 0" 0 "$rc"
has "целые ссылки — строка ок" "check-links: ок, файлов: 2" "$out"

printf '[нет](docs/nope.md)\n[якорь](docs/guides/a.md#нет-такого)\n[вне](../outside.md)\n' >> "$R/README.md"
printf '[игнор](nope.md)\n' > "$R/ignored.md"
printf 'ignored.md\n' > "$R/.gitignore"
out="$("$GATE" --repo "$R" 2>&1)"; rc=$?
eq "битые ссылки — код 1" 1 "$rc"
has "нет файла" "README.md:10: docs/nope.md — нет файла" "$out"
has "нет заголовка" "README.md:11: docs/guides/a.md#нет-такого — нет заголовка" "$out"
has "за пределы репозитория" "README.md:12: ../outside.md — ведёт за пределы репозитория" "$out"
hasnt "ссылка в коде не проверяется" "нет.md" "$out"
hasnt "ссылка в блоке кода не проверяется" "тоже-нет.md" "$out"
hasnt "внешний адрес без --external не проверяется" "example.invalid" "$out"
hasnt ".gitignore соблюдается" "ignored.md" "$out"

out="$("$GATE" --bogus 2>&1)"; rc=$?
eq "неизвестный аргумент — код 2" 2 "$rc"

echo "проверок: $((pass + fail)), не прошло: $fail"
(( fail == 0 ))
