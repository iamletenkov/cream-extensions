#!/usr/bin/env bash
# Одна точка входа для проверок репозитория расширений.
#
# Проверки: `cream validate --catalog .` по корню каталога (cream-validate.sh:
# cream по пину tools/cream-pin.env, пустой пин — пропуск со строкой; локально —
# CREAM_DEB=<.deb>) и его тест; гейт имён bisquite по всему репозиторию
# (check-names.sh, кроме истории — CHANGELOG.md, docs/research/, docs/plans/) и
# его тест; линт хуков и действий (lint-hooks.sh: шапки, systemctl --no-block,
# cream set при lock: none, source lib/, секрет в argv, CREAM_*, стадия
# cloud-user) и его тест; тест каркаса new-extension.sh (скелеты проходят линт,
# гейт имён, свой H-тест и cream validate); тест H-раннера (tools/hooktest.sh —
# хуки на подменённом корне, как их зовёт cream), тест матрицы живых прогонов CI
# (live-matrix.sh). Сверка файлов-образцов контракта stvor-agent
# (check-contract-fixtures.sh: пин набора — всегда, без сети; соседняя копия
# stvor-agent — если есть, в CI её даёт checkout по ref). Тест
# tools/agent-bump.sh (пин обёртки stvor-agent по SHA256SUMS релиза). Тест
# снимка каталога (test-snapshot.sh: две сборки tools/catalog-snapshot.sh дают
# одни байты, cream принимает снимок через source add --archive и resolve).
#
# Тесты расширений находятся сами: каждый исполняемый
# extensions/<семейство>/<имя>/tests/test-*.sh (рулинг Р13 плана
# 2026-10-19: исполнители расширений этот файл не трогают; прочие файлы tests/ —
# помощники и данные, live.env — умолчания живого прогона tools/live-test.sh).
# Живые прогоны (контейнер с systemd, сеть) сюда не входят: make test-live,
# make test-live-self, workflow live.yml. Все проверки доводятся до конца, даже
# если первая упала.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"

rc=0
echo "== cream-validate =="
"$HERE/cream-validate.sh" || rc=1

echo
echo "== test-cream-validate =="
"$HERE/test-cream-validate.sh" || rc=1

echo "== check-names =="
"$HERE/check-names.sh" || rc=1

echo "== test-check-names =="
"$HERE/test-check-names.sh" || rc=1

echo "== lint-hooks =="
"$HERE/lint-hooks.sh" || rc=1

echo "== test-lint-hooks =="
"$HERE/test-lint-hooks.sh" || rc=1

echo "== test-new-extension =="
"$HERE/test-new-extension.sh" || rc=1

echo "== test-hooktest =="
"$HERE/test-hooktest.sh" || rc=1

echo "== test-live-matrix =="
"$HERE/test-live-matrix.sh" || rc=1

echo "== test-agent-bump =="
"$HERE/test-agent-bump.sh" || rc=1

echo "== test-snapshot =="
"$HERE/test-snapshot.sh" || rc=1

echo "== check-contract-fixtures =="
"$HERE/check-contract-fixtures.sh" || rc=1

# Tests of the extensions: found, not listed.
n=0
for t in "$REPO"/extensions/*/*/tests/test-*.sh; do
    [[ -e "$t" ]] || continue
    n=$((n + 1))
    rel="${t#"$REPO"/extensions/}"
    echo "== ${rel} =="
    if [[ ! -x "$t" ]]; then
        echo "$rel: не исполняемый (chmod +x)" >&2
        rc=1
        continue
    fi
    "$t" || rc=1
done
if (( n == 0 )); then
    echo "== тестов расширений (extensions/*/*/tests/test-*.sh) нет =="
fi

echo
if (( rc )); then
    echo "проверки не прошли" >&2
else
    echo "проверки прошли"
fi
exit "$rc"
