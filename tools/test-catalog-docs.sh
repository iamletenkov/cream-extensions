#!/usr/bin/env bash
# Тест генератора документации из манифестов (tools/catalog-docs.sh) на
# временном каталоге: запись заполняет блоки README корня, справочника и
# расширений; повтор ничего не меняет; --check зелёный на свежем и красный с
# разницей на устаревшем; нет маркера — код 2; библиотека — в своей таблице;
# секрет, scope: install, live: confirm с live_note, every_boot, ссылки на
# соседей по depends — в тексте.
#
#   tools/test-catalog-docs.sh        код 0 — все проверки прошли
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$HERE/catalog-docs.sh"

TMP="$(mktemp -d)"
trap 'rm -r -f -- "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&2; }
eq(){ if [[ "$2" == "$3" ]]; then ok; else bad "$1: ждали [$2], получили [$3]"; fi; }
has(){ if grep -qF -- "$2" <<< "$3"; then ok; else bad "$1: нет [$2]"; fi; }
hasnt(){ if grep -qF -- "$2" <<< "$3"; then bad "$1: лишнее [$2]"; else ok; fi; }

R="$TMP/cat"
mkdir -p "$R/extensions/debian/lib1" "$R/extensions/debian/app" "$R/docs/reference"
printf 'schema: cream/v1\nname: t\nversion: 1.0.0\nroots: [extensions/debian]\n' > "$R/cream-catalog.yaml"
printf '# t\n\n<!-- catalog:table -->\nстарое\n<!-- /catalog:table -->\n\nхвост\n' > "$R/README.md"
printf '# ref\n<!-- catalog:reference -->\n<!-- /catalog:reference -->\n' > "$R/docs/reference/catalog.md"
readme='# %s\n\nтекст автора\n\n<!-- catalog:facts -->\n<!-- /catalog:facts -->\n\n## Параметры\n\n<!-- catalog:params -->\n<!-- /catalog:params -->\n\nпояснение\n'
# shellcheck disable=SC2059  # the template is ours
printf "$readme" lib1 > "$R/extensions/debian/lib1/README.md"
# shellcheck disable=SC2059
printf "$readme" app > "$R/extensions/debian/app/README.md"
cat > "$R/extensions/debian/lib1/extension.yaml" <<'EOF'
schema: cream/v1
name: lib1
version: 1.0.0
kind: library
summary: Общий код
cream: ">=1.0.0"
platform: {family: deb, arch: [amd64, arm64]}
targets: {build: exec, live: "yes"}
EOF
cat > "$R/extensions/debian/app/extension.yaml" <<'EOF'
schema: cream/v1
name: app
version: 2.0.0
summary: Приложение | с чертой
cream: ">=1.2.0"
platform:
  family: deb
  arch: [arm64]
  os: [{id: debian, version: ">=12"}, {id: ubuntu}]
targets: {build: exec, live: confirm, live_note: "меняет сеть"}
provides: [cap-a]
requires: [cap-b]
depends: [{name: lib1, version: ">=1.0.0 <2"}]
conflicts: {extensions: [other]}
hooks:
  install: {}
  configure: {stage: graphical, every_boot: true}
actions:
  status: {summary: состояние}
config:
  keys:
    APP_PORT: {type: port, default: "8080", description: "порт"}
    APP_PASS: {type: str, default: "", empty: true, secret: file, description: "пароль"}
    APP_VER: {type: "re:^[0-9]+|x$", default: "1", scope: install, description: "версия"}
    APP_MODE: {type: "enum:a,b", default: a, description: "режим"}
EOF

out="$("$GEN" --repo "$R" 2>&1)"; rc=$?
eq "запись — код 0" 0 "$rc"
has "запись — названы файлы" "обновлён README.md" "$out"
top="$(cat "$R/README.md")"
has "таблица: расширение со ссылкой" "[\`app\`](extensions/debian/app/README.md)" "$top"
has "таблица: черта в summary экранирована" 'Приложение \| с чертой' "$top"
has "таблица: ОС с версией" "Debian ≥ 12, Ubuntu" "$top"
has "таблица: первые три ключа и остаток" "\`APP_PORT\`, \`APP_PASS\`, \`APP_VER\` и ещё 1" "$top"
has "таблица: библиотека отдельно" "| [\`lib1\`](extensions/debian/lib1/README.md) | Общий код |" "$top"
hasnt "таблица: старое содержимое заменено" "старое" "$top"
has "таблица: текст вне маркеров цел" "хвост" "$top"
app="$(cat "$R/extensions/debian/app/README.md")"
has "facts: depends — ссылка на соседа" "[\`lib1\`](../lib1/README.md)" "$app"
has "facts: every_boot" "стадия \`graphical\`, на каждой загрузке (\`every_boot\`)" "$app"
has "facts: действие" "\`cream run app status\`" "$app"
has "facts: live_note" "> **Живая машина — с \`--accept-risk\`.** Меняет сеть" "$app"
has "params: секрет" "секрет: \`KEY=-\` со stdin или \`--params-file\`" "$app"
has "params: scope install" "только при установке" "$app"
has "params: черта в регулярном выражении экранирована" '^[0-9]+\|x$' "$app"
has "params: enum" "\`a\` \\| \`b\`" "$app"
has "params: текст автора цел" "пояснение" "$app"
hasnt "версии в блоки не попадают" "2.0.0" "$app$top"
ref="$(cat "$R/docs/reference/catalog.md")"
has "справочник: способность и поставщик" "| \`cap-a\` | [\`app\`](../../extensions/debian/app/README.md) | — |" "$ref"
has "справочник: способность без поставщика" "| \`cap-b\` | — (нет поставщика) |" "$ref"

before="$(cat "$R/README.md" "$R"/extensions/debian/*/README.md "$R/docs/reference/catalog.md" | sha256sum)"
"$GEN" --repo "$R" >/dev/null 2>&1
after="$(cat "$R/README.md" "$R"/extensions/debian/*/README.md "$R/docs/reference/catalog.md" | sha256sum)"
eq "повтор ничего не меняет" "$before" "$after"
out="$("$GEN" --check --repo "$R" 2>&1)"; rc=$?
eq "--check на свежем — код 0" 0 "$rc"

sed -i 's/description: "порт"/description: "порт HTTP"/' "$R/extensions/debian/app/extension.yaml"
out="$("$GEN" --check --repo "$R" 2>&1)"; rc=$?
eq "--check на устаревшем — код 1" 1 "$rc"
has "--check показывает разницу" "+| \`APP_PORT\` | \`port\` | \`8080\` | порт HTTP |" "$out"
has "--check подсказывает команду" "tools/catalog-docs.sh" "$out"

sed -i '/catalog:params -->/d' "$R/extensions/debian/lib1/README.md"
out="$("$GEN" --check --repo "$R" 2>&1)"; rc=$?
eq "нет маркера — код 2" 2 "$rc"
has "нет маркера — файл назван" "extensions/debian/lib1/README.md: нет пары маркеров" "$out"

echo "проверок: $((pass + fail)), не прошло: $fail"
(( fail == 0 ))
