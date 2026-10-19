#!/usr/bin/env bash
# Тест H-раннера tools/hooktest.sh на фикстуре tools/testdata/hooktest/demo:
# окружение как у cream (очищено, CREAM_*, ключи с default, секрет — только
# в файле), cwd — копия расширения без tests/, umask 022, KEY=VALUE
# перекрывает, код хука доходит до теста (сбой, 20), сторож опасных команд,
# журнал подставных, действие с аргументами.
#
#   tools/test-hooktest.sh        код 0 — все проверки прошли
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hooktest.sh
. "$HERE/hooktest.sh"
DEMO="$HERE/testdata/hooktest/demo"

ht_init
export HT_LEAK=host-only

echo "== окружение и cwd =="
ht_root "$DEMO"
ht_fake apt-get
ht_secret DEMO_PASS s3cr3t-demo
ht_hook install; eq "install — код 0" 0 "$?"
S="$ROOT/var/lib/cream/ext/demo"
eq "default ключа в окружении" blue "$(cat "$ROOT/etc/demo/color")"
check "пустой ключ передан пустым" grep -qx 'DEMO_EMPTY=' "$S/env"
check_not "секретный ключ не в окружении" grep -q '^DEMO_PASS=' "$S/env"
check_not "значение секрета не в окружении" grep -q 's3cr3t-demo' "$S/env"
check "секрет — в CREAM_SECRETS_FILE" grep -qx 'DEMO_PASS=s3cr3t-demo' "$ROOT/etc/cream/demo/secrets"
eq "секреты 0600" 600 "$(stat -c %a "$ROOT/etc/cream/demo/secrets")"
check_not "окружение очищено (переменная хоста не видна)" grep -q '^HT_LEAK=' "$S/env"
check "CREAM_PHASE=live" grep -qx 'CREAM_PHASE=live' "$S/env"
check "CREAM_EXT_VERSION из манифеста" grep -qx 'CREAM_EXT_VERSION=2.1.0' "$S/env"
check "CREAM_ROOT — подменённый корень" grep -qx "CREAM_ROOT=$ROOT" "$S/env"
check "CREAM_ETC_DIR" grep -qx "CREAM_ETC_DIR=$ROOT/etc/cream/demo" "$S/env"
check "LANG=C.UTF-8" grep -qx 'LANG=C.UTF-8' "$S/env"
check "PATH — подставные первыми" grep -qx "PATH=$ROOT/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" "$S/env"
eq "cwd — копия расширения" "$ROOT/opt/cream/ext/demo" "$(cat "$S/cwd")"
eq "umask 022" 0022 "$(cat "$S/umask")"
check_not "tests/ в копию не попали" test -e "$ROOT/opt/cream/ext/demo/tests"
check "вызов apt-get в журнале" ht_called '^apt-get install -y demo-pkg$'

echo "== перекрытие и коды =="
ht_hook install DEMO_COLOR=red; eq "install DEMO_COLOR=red — 0" 0 "$?"
eq "KEY=VALUE перекрывает default" red "$(cat "$ROOT/etc/demo/color")"
ht_hook install DEMO_EXIT=7; eq "код хука доходит до теста" 7 "$?"
ht_hook configure; eq "configure без устройства — 20" 20 "$?"
mkdir -p "$ROOT/dev"; : > "$ROOT/dev/demo0"
ht_hook configure CREAM_REASON=boot; eq "configure с устройством — 0" 0 "$?"
eq "CREAM_REASON передан" reason=boot "$(cat "$S/configure")"
ht_hook nope; eq "нет хука — 126" 126 "$?"

echo "== сторож опасных команд =="
ht_root "$DEMO"
ht_hook install; rc=$?
eq "apt-get без подстановки — хук упал с 127" 127 "$rc"
check "сторож пишет вызов в журнал" ht_called '^apt-get install -y demo-pkg$'
check "сторож объясняет" grep -q 'apt-get не подставлен' <<< "$(ht_out)"
ht_fake apt-get 'echo "apt $*" > "$FAKE/apt.seen"'
ht_hook install; eq "своя подстановка — 0" 0 "$?"
eq "тело подставной видит аргументы" "apt install -y demo-pkg" "$(cat "$FAKE/apt.seen")"
eq "argv подставной" "install -y demo-pkg" "$(tail -n1 "$FAKE/apt-get.argv")"

echo "== действие =="
ht_action hello DEMO_COLOR=red -- a b; eq "действие — 0" 0 "$?"
eq "аргументы и ключи действия" "hello a b color=red" "$(ht_out)"

ht_done
