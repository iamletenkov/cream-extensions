#!/usr/bin/env bash
# Одна точка входа для проверок репозитория расширений.
#
# Проверки: валидация манифестов layout 2 (validate-extensions.py, и схем
# настроек, и того, как скрипты обращаются с файлами настроек); `cream validate`
# по расширениям cream/v1 (cream-validate.sh: cream по пину tools/cream-pin.env,
# пустой пин — пропуск со строкой; локально — CREAM_DEB=<.deb>); тесты
# библиотеки настроек lib/bisquite-conf и расширений на подменённом корне.
# Сверка файлов-образцов контракта stvor-agent (check-contract-fixtures.sh:
# пин набора — всегда, без сети; соседняя копия stvor-agent — если есть,
# в CI её даёт checkout по ref). Тест tools/agent-bump.sh (пин обёртки
# stvor-agent по SHA256SUMS релиза). Тест снимка каталога
# (test-snapshot.sh: две сборки tools/catalog-snapshot.sh дают одни байты,
# cream принимает снимок через source add --archive и resolve). Тесты, которых ещё нет
# (extensions/debian/teleport/tests/*.sh, tools/test-stvor-agent.sh),
# пропускаются со строкой, а не молча. Сверки копий
# lib/ нет: копий нет, общий код доставляет в гостя сама сборка
# (`/opt/bisquite/<имя>/lib`, см. docs/extensions.md). Все проверки доводятся
# до конца, даже если первая упала.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rc=0
echo "== validate-extensions =="
"$HERE/validate-extensions.py" || rc=1

echo
echo "== test-validate-extensions =="
"$HERE/test-validate-extensions.sh" || rc=1

echo
echo "== cream-validate =="
"$HERE/cream-validate.sh" || rc=1

echo
echo "== test-cream-validate =="
"$HERE/test-cream-validate.sh" || rc=1

echo
echo "== test-conf =="
"$HERE/test-conf.sh" || rc=1

echo "== test-agent-bump =="
"$HERE/test-agent-bump.sh" || rc=1

echo "== test-nvidia-jetpack =="
"$HERE/test-nvidia-jetpack.sh" || rc=1

echo "== test-sensing-gmsl2-camera =="
"$HERE/test-sensing-gmsl2-camera.sh" || rc=1

echo "== test-l4t-kernel-kvm =="
"$HERE/test-l4t-kernel-kvm.sh" || rc=1

echo "== test-firewall =="
"$HERE/test-firewall.sh" || rc=1

echo "== test-can-usb =="
"$HERE/test-can-usb.sh" || rc=1

echo "== test-snapshot =="
"$HERE/test-snapshot.sh" || rc=1

echo "== check-contract-fixtures =="
"$HERE/check-contract-fixtures.sh" || rc=1

teleport_tests=()
for t in "$HERE"/../extensions/debian/teleport/tests/*.sh; do
    [[ -f "$t" ]] && teleport_tests+=("$t")
done
if (( ${#teleport_tests[@]} == 0 )); then
    echo "== teleport/tests: пропуск, тестов ещё нет =="
fi
for t in "${teleport_tests[@]}"; do
    echo "== teleport/tests/$(basename "$t") =="
    "$t" || rc=1
done

if [[ -f "$HERE/test-stvor-agent.sh" ]]; then
    echo "== test-stvor-agent =="
    "$HERE/test-stvor-agent.sh" || rc=1
else
    echo "== test-stvor-agent: пропуск, tools/test-stvor-agent.sh ещё нет =="
fi

echo
if (( rc )); then
    echo "проверки не прошли" >&2
else
    echo "проверки прошли"
fi
exit "$rc"
