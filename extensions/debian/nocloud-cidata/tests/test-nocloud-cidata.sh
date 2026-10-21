#!/usr/bin/env bash
# Тесты nocloud-cidata (cream/v1): хуки install и remove на подменённом корне.
# Файл zz-cream-nocloud.cfg ложится в /etc/cloud/cloud.cfg.d (0644, байт в байт
# из расширения, валидный YAML, имя старше штатных), повтор без изменений,
# предупреждение о перекрытом штатном источнике seed, отказ без cloud-init,
# remove снимает только свой файл. Root и сеть не нужны.
#
#   extensions/debian/nocloud-cidata/tests/test-nocloud-cidata.sh   код 0 — все проверки прошли
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../../tools/hooktest.sh
. "$HERE/../../../../tools/hooktest.sh"
EXT="$(dirname "$HERE")"

ht_init

fresh() {
    ht_root "$EXT"
    D="$ROOT/etc/cloud/cloud.cfg.d"
    F="$D/zz-cream-nocloud.cfg"
    mkdir -p "$D"
}
sum() { sha256sum "$1" | cut -d' ' -f1; }

echo "== манифест =="
# shellcheck disable=SC2016  # the python expression is the test data
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 2" 2.0.1 "$(mf 'm["version"]')"
eq "build: exec" exec "$(mf 'm["targets"]["build"]')"
eq "live: no" no "$(mf 'm["targets"]["live"]')"
check "live_note есть" test -n "$(mf 'm["targets"].get("live_note", "")')"
eq "хуки install и remove" "['install', 'remove']" "$(mf 'sorted(m["hooks"])')"
check_not "install.sh layout 2 убран" test -e "$EXT/install.sh"
check_not "zz-bisquite-nocloud.cfg убран" test -e "$EXT/zz-bisquite-nocloud.cfg" # check-names: allow

echo "== кладёт конфиг =="
fresh
printf 'datasource:\n  NoCloud:\n    fs_label: system-boot\n' > "$D/99-fake-ubuntu.cfg"
printf 'apt:\n  preserve_sources_list: true\n' > "$D/99_raspberry-pi.cfg"
ht_hook install; eq "install — 0" 0 "$?"
check "файл на месте" test -f "$F"
eq "режим 0644" 644 "$(stat -c %a "$F")"
eq "содержимое из расширения" "$(sum "$EXT/files/zz-cream-nocloud.cfg")" "$(sum "$F")"
eq "datasource_list" "['NoCloud', 'None']" \
    "$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["datasource_list"])' "$F")"
eq "fs_label: cidata, seedfrom пуст" "cidata|" \
    "$(python3 -c 'import sys, yaml; n = yaml.safe_load(open(sys.argv[1]))["datasource"]["NoCloud"]; print(n["fs_label"] + "|" + n["seedfrom"])' "$F")"
eq "имя старше штатных (cloud-init берёт обратный порядок)" zz-cream-nocloud.cfg "$(ls "$D" | sort -r | head -n 1)"
check "предупреждение про перекрытый ubuntu" grep -q 'перекрыт штатный 99-fake-ubuntu.cfg' <(ht_out)
check_not "raspberry без seedfrom — без предупреждения" grep -q '99_raspberry-pi.cfg' <(ht_out)
before="$(sum "$F")"
ht_hook install; eq "повтор install — 0" 0 "$?"
eq "повтор: файл тот же" "$before" "$(sum "$F")"
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "remove: файл снят" test -e "$F"
check "remove: штатные не тронуты" test -f "$D/99-fake-ubuntu.cfg"
ht_hook remove; eq "повтор remove — 0" 0 "$?"

echo "== отказ без cloud-init =="
fresh
rmdir "$D"
ht_hook install; eq "нет cloud.cfg.d — 1" 1 "$?"
check_not "каталог не создан" test -e "$D"
check "сообщение про cloud-init" grep -q 'cloud-init не установлен' <(ht_out)
ht_hook remove; eq "remove без cloud.cfg.d — 0" 0 "$?"

ht_done
