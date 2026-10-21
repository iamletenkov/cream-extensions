#!/usr/bin/env bash
# Tests of the l4t-board-fdt hooks (cream/v1): manifest and `install` on a
# scratch root (CREAM_ROOT) the way cream runs it. Fixtures are extlinux.conf
# layouts and empty *-kvm.dtb files; no board, no root, no network.
#
# The backup rule (spec cream §6.3, plan 2026-10-19 Task 24): extlinux.conf is
# saved once as extlinux.conf.cream-orig and never overwritten — a second run,
# even with another board, keeps the copy from the first.
#
#   extensions/debian/l4t-board-fdt/tests/test-hooks.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

A02=tegra210-p3448-0000-p3449-0000-a02
B00=tegra210-p3448-0000-p3449-0000-b00

# fresh [layout]: a root with /boot/extlinux/extlinux.conf (vendor primary entry
# plus the kvm entry of l4t-kernel-kvm) and two -kvm trees.
fresh() {
    ht_root "$EXT"
    CONF="$ROOT/boot/extlinux/extlinux.conf"
    ORIG="$CONF.cream-orig"
    mkdir -p "$ROOT/boot/extlinux"
    : > "$ROOT/boot/$A02-kvm.dtb"
    : > "$ROOT/boot/$B00-kvm.dtb"
    printf '%s\n' \
        'TIMEOUT 30' \
        'DEFAULT kvm' \
        '' \
        'MENU TITLE L4T boot options' \
        '' \
        'LABEL primary' \
        '      MENU LABEL primary kernel' \
        '      LINUX /boot/Image' \
        '      INITRD /boot/initrd' \
        '      APPEND ${cbootargs} root=PARTUUID=817d4355-fa85-4e38-903f-ea68b2e685ff rw' \
        '' \
        'LABEL kvm' \
        '      MENU LABEL kvm kernel (tegra-kvm)' \
        '      LINUX /boot/Image.kvm' \
        '      INITRD /boot/initrd' \
        '      APPEND ${cbootargs} root=PARTUUID=817d4355-fa85-4e38-903f-ea68b2e685ff rw' > "$CONF"
    chmod 0644 "$CONF"
}
# kvm_fdt: the FDT lines of the kvm entry.
kvm_fdt() { awk '$1=="LABEL"{k=($2=="kvm")} k && $1=="FDT"{print $2}' "$CONF"; }
primary_fdt() { awk '$1=="LABEL"{k=($2=="primary")} k && $1=="FDT"{print $2}' "$CONF"; }

echo "== манифест =="
# eval: test-only literal expressions over our own manifest, as in nvidia-jetpack.
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 2" 2.0.1 "$(mf 'm["version"]')"
eq "cream >=1.0.0" ">=1.0.0" "$(mf 'm["cream"]')"
eq "только arm64" "['arm64']" "$(mf 'm["platform"]["arch"]')"
eq "build: exec" exec "$(mf 'm["targets"]["build"]')"
eq "live: confirm" confirm "$(mf 'm["targets"]["live"]')"
check "live_note про перезагрузку" grep -q 'перезагруз' <<< "$(mf 'm["targets"]["live_note"]')"
eq "provides" "['l4t-board-selected']" "$(mf 'm["provides"]')"
eq "requires" "['l4t-custom-kernel']" "$(mf 'm["requires"]')"
eq "хук только install" "['install']" "$(mf 'sorted(m["hooks"])')"
check "install с явным timeout" test -n "$(mf 'm["hooks"]["install"].get("timeout", "")')"
eq "L4T_BOARD — параметр установки" install "$(mf 'm["config"]["keys"]["L4T_BOARD"]["scope"]')"
check_not "install.sh layout 2 убран" test -e "$EXT/install.sh"

echo "== без платы и не L4T =="
fresh
ht_hook install; eq "L4T_BOARD пуст — 1" 1 "$?"
check "подсказка про compatible" grep -q '/proc/device-tree/compatible' <(ht_out)
cp "$CONF" "$ROOT/before"
ht_hook install L4T_BOARD=../../etc/passwd; eq "L4T_BOARD с путём — 1" 1 "$?"
ht_hook install "L4T_BOARD=a b"; eq "L4T_BOARD с пробелом — 1" 1 "$?"
check "файл не тронут" cmp -s "$ROOT/before" "$CONF"
check_not "бэкапа нет" test -e "$ORIG"
fresh
rm -f -- "$CONF"
ht_hook install L4T_BOARD=$A02; eq "нет extlinux.conf — 20 (не L4T)" 20 "$?"

echo "== отказы до записи =="
fresh
sed -i '/LABEL kvm/,$d' "$CONF"
cp "$CONF" "$ROOT/before"
ht_hook install L4T_BOARD=$A02; eq "нет LABEL kvm — 1" 1 "$?"
check "говорит про l4t-kernel-kvm" grep -q 'l4t-kernel-kvm' <(ht_out)
check "файл не тронут" cmp -s "$ROOT/before" "$CONF"
check_not "бэкапа нет" test -e "$ORIG"
fresh
ht_hook install L4T_BOARD=tegra210-nope; eq "дерева нет — 1" 1 "$?"
check "печатает, что есть" grep -q "$B00" <(ht_out)
check_not "бэкапа нет" test -e "$ORIG"

echo "== первая запись: FDT, бэкап, код 10 =="
fresh
cp "$CONF" "$ROOT/first"
ht_hook install L4T_BOARD=$A02; eq "первая запись — 10 (перезагрузка)" 10 "$?"
eq "FDT записи kvm" "/boot/$A02-kvm.dtb" "$(kvm_fdt)"
eq "в primary FDT не попал" "" "$(primary_fdt)"
check "бэкап — исходный файл" cmp -s "$ROOT/first" "$ORIG"
eq "режим сохранён" 644 "$(stat -c %a "$CONF")"
fresh
ht_hook install "L4T_BOARD=$A02.dtb"; eq "L4T_BOARD с .dtb — 10" 10 "$?"
eq "…тот же путь" "/boot/$A02-kvm.dtb" "$(kvm_fdt)"

echo "== двойной прогон: бэкап — от первого =="
fresh
cp "$CONF" "$ROOT/first"
ht_hook install L4T_BOARD=$A02; eq "первый — 10" 10 "$?"
cp "$CONF" "$ROOT/after1"
ht_hook install L4T_BOARD=$A02; eq "повтор той же платой — 0" 0 "$?"
check "повтор: файл байт в байт тот же" cmp -s "$ROOT/after1" "$CONF"
check "повтор: бэкап — исходный" cmp -s "$ROOT/first" "$ORIG"
ht_hook install L4T_BOARD=$B00; eq "другая плата — 10" 10 "$?"
eq "FDT сменился" "/boot/$B00-kvm.dtb" "$(kvm_fdt)"
eq "FDT одна" 1 "$(kvm_fdt | wc -l)"
check "бэкап всё ещё от первого прогона" cmp -s "$ROOT/first" "$ORIG"
eq "временных файлов не осталось" "extlinux.conf extlinux.conf.cream-orig" \
    "$(find "$ROOT/boot/extlinux" -mindepth 1 -printf '%f\n' | sort | tr '\n' ' ' | sed 's/ $//')"

echo "== чужой бэкап не перезаписывается =="
fresh
echo 'made by l4t-kernel-kvm' > "$ORIG"
ht_hook install L4T_BOARD=$A02; eq "бэкап уже есть — 10" 10 "$?"
eq "бэкап не тронут" 'made by l4t-kernel-kvm' "$(cat "$ORIG")"

echo "== разбор записи kvm =="
fresh
printf '%s\n' '      FDT /boot/old-1.dtb' '      FDT /boot/old-2.dtb' >> "$CONF"
ht_hook install L4T_BOARD=$A02; eq "две прежние FDT — 10" 10 "$?"
eq "осталась одна, своя" "/boot/$A02-kvm.dtb" "$(kvm_fdt)"
fresh
# kvm not last: the line goes into the kvm entry, not into the next one.
printf '%s\n' '' 'LABEL rescue' '      LINUX /boot/Image' >> "$CONF"
ht_hook install L4T_BOARD=$A02; eq "kvm не последняя — 10" 10 "$?"
eq "FDT в записи kvm" "/boot/$A02-kvm.dtb" "$(kvm_fdt)"
eq "в rescue не попал" "" "$(awk '$1=="LABEL"{k=($2=="rescue")} k && $1=="FDT"' "$CONF")"
check "MENU LABEL kvm kernel не принят за запись" grep -qx '      MENU LABEL kvm kernel (tegra-kvm)' "$CONF"

echo "== ссылки не разыменовываются =="
fresh
mkdir -p "$ROOT/victim"
cp "$CONF" "$ROOT/victim/extlinux.conf"
cp "$CONF" "$ROOT/victim.orig"
rm -f -- "$CONF"
ln -s "$ROOT/victim/extlinux.conf" "$CONF"
ht_hook install L4T_BOARD=$A02; eq "extlinux.conf — ссылка: отказ 1" 1 "$?"
check "цель ссылки не тронута" cmp -s "$ROOT/victim.orig" "$ROOT/victim/extlinux.conf"
check "ссылка осталась ссылкой" test -L "$CONF"
check "сообщение про ссылку" grep -q 'ссылка' <(ht_out)
fresh
echo keep > "$ROOT/victim-file"
ln -s "$ROOT/victim-file" "$ORIG"
ht_hook install L4T_BOARD=$A02; eq "бэкап — висящая ссылка: 10" 10 "$?"
eq "через ссылку бэкапа не пишут" keep "$(cat "$ROOT/victim-file")"

echo "== содержимое — данные =="
fresh
printf '%s\n' '      APPEND $(touch '"$ROOT"'/pwned) `touch '"$ROOT"'/pwned2`' >> "$CONF"
ht_hook install L4T_BOARD=$A02; eq "строки с \$( ) — 10" 10 "$?"
check_not "ничего не исполнено" test -e "$ROOT/pwned" -o -e "$ROOT/pwned2"

ht_done
