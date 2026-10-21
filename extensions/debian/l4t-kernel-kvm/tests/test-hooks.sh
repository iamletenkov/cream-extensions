#!/usr/bin/env bash
# Tests of the l4t-kernel-kvm hook (cream/v1): manifest, the refusals of
# hooks/install that come before any download (on a scratch root, the way cream
# runs it), and the extlinux.conf helpers of extlinux-root.sh that step 7 uses —
# the backup taken once, the kvm entry, writes through rename.
#
# NOT checked here: the kernel build itself (hours, a board or the appliance)
# and kvm_root_partition (needs a real block device under /) — P, a build
# through bisquite. Rewriting root= — tests/test-l4t-kernel-kvm.sh.
#
#   extensions/debian/l4t-kernel-kvm/tests/test-hooks.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

R32='# R32 (release), REVISION: 6.1, GCID: 27863751, BOARD: t210ref, EABI: aarch64, DATE: Mon Jul 26 19:20:30 UTC 2021'
R36='# R36 (release), REVISION: 4.3, GCID: 38968081, BOARD: generic, EABI: aarch64, DATE: Wed Jan  8 01:49:37 UTC 2025'

fresh() {
    ht_root "$EXT"
    CONF="$ROOT/boot/extlinux/extlinux.conf"
    mkdir -p "$ROOT/etc" "$ROOT/boot/extlinux"
    echo "$R32" > "$ROOT/etc/nv_tegra_release"
    : > "$ROOT/boot/tegra210-p3448-0000-p3449-0000-b00.dtb"
    vendor_conf "$CONF"
}
vendor_conf() {
    printf '%s\n' \
        'TIMEOUT 30' \
        'DEFAULT primary' \
        '' \
        'MENU TITLE L4T boot options' \
        '' \
        'LABEL primary' \
        '      MENU LABEL primary kernel' \
        '      LINUX /boot/Image' \
        '      INITRD /boot/initrd' \
        '      APPEND ${cbootargs} quiet root=PARTUUID=817d4355-fa85-4e38-903f-ea68b2e685ff rw rootwait' > "$1"
    chmod 0644 "$1"
}

echo "== манифест =="
# eval: test-only literal expressions over our own manifest, as in nvidia-jetpack.
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "версия 2.1.1" 2.1.1 "$(mf 'm["version"]')"
eq "cream >=1.0.0" ">=1.0.0" "$(mf 'm["cream"]')"
eq "только arm64" "['arm64']" "$(mf 'm["platform"]["arch"]')"
eq "build: exec" exec "$(mf 'm["targets"]["build"]')"
eq "live: no" no "$(mf 'm["targets"]["live"]')"
check "live_note есть" test -n "$(mf 'm["targets"].get("live_note", "")')"
eq "provides" "['kvm-host', 'l4t-custom-kernel']" "$(mf 'm["provides"]')"
eq "хук только install" "['install']" "$(mf 'sorted(m["hooks"])')"
# The build takes about three hours on a Nano; the timeout is explicit and >= 4 h.
check "timeout install явный, не меньше 4 ч" python3 - "$EXT/extension.yaml" <<'PY'
import re, sys, yaml
t = yaml.safe_load(open(sys.argv[1]))["hooks"]["install"]["timeout"]
s = 0
for n, u in re.findall(r"(\d+)([hms])", t):
    s += int(n) * {"h": 3600, "m": 60, "s": 1}[u]
sys.exit(0 if s >= 4 * 3600 else 1)
PY
eq "ключи — параметры установки" \
    "L4T_KERNEL_CC=install L4T_KERNEL_FDT=install L4T_KERNEL_JOBS=install L4T_KERNEL_KEEP_SOURCES=install L4T_KERNEL_LOCALVERSION=install" \
    "$(mf '" ".join(k + "=" + str(v.get("scope")) for k, v in sorted(m["config"]["keys"].items()))')"
check "extlinux-root.sh в дереве расширения" test -f "$EXT/extlinux-root.sh"
check_not "install.sh layout 2 убран" test -e "$EXT/install.sh"

echo "== отказы до сборки (без apt и сети) =="
fresh
ht_fake nproc 'echo 4'
ht_hook install L4T_KERNEL_JOBS=0; eq "L4T_KERNEL_JOBS=0 — 1" 1 "$?"
ht_hook install 'L4T_KERNEL_JOBS=$(touch /tmp/x)'; eq "L4T_KERNEL_JOBS не число — 1" 1 "$?"
ht_hook install 'L4T_KERNEL_CC=gcc;id'; eq "L4T_KERNEL_CC не имя команды — 1" 1 "$?"
ht_hook install 'L4T_KERNEL_LOCALVERSION=-a b'; eq "L4T_KERNEL_LOCALVERSION с пробелом — 1" 1 "$?"
ht_hook install L4T_KERNEL_FDT=../../etc/passwd; eq "L4T_KERNEL_FDT с путём — 1" 1 "$?"
ht_hook install L4T_KERNEL_KEEP_SOURCES=maybe; eq "L4T_KERNEL_KEEP_SOURCES не yes/no — 1" 1 "$?"
check_not "до сборки apt-get не звали" ht_called '^apt-get '

fresh
rm -f -- "$ROOT/etc/nv_tegra_release"
ht_hook install; eq "нет /etc/nv_tegra_release — 20 (не L4T)" 20 "$?"
fresh
echo 'garbage $(touch '"$ROOT"'/pwned)' > "$ROOT/etc/nv_tegra_release"
ht_hook install; eq "версия L4T не разбирается — 1" 1 "$?"
check_not "строка релиза не исполнена" test -e "$ROOT/pwned"
fresh
echo "$R36" > "$ROOT/etc/nv_tegra_release"
rm -f -- "$ROOT/boot/"*.dtb
: > "$ROOT/boot/kernel_tegra234-p3701-0000-p3737-0000.dtb"
ht_hook install; eq "t234 — 1 (только t210)" 1 "$?"
check "называет SoC" grep -q 't234' <(ht_out)
fresh
echo "$R36" > "$ROOT/etc/nv_tegra_release"
rm -f -- "$ROOT/boot/"*.dtb
ht_hook install; eq "SoC не определить — 1" 1 "$?"
fresh
# 32.7.3: NVIDIA publishes no t210 sources — no line in the table.
echo '# R32 (release), REVISION: 7.3, GCID: 31982016, BOARD: t210ref, EABI: aarch64, DATE: Tue Nov 22 17:30:08 UTC 2022' \
    > "$ROOT/etc/nv_tegra_release"
ht_hook install; eq "версии нет в таблице сумм — 1" 1 "$?"
check "называет версию" grep -q 'L4T 32.7.3' <(ht_out)
check "перечисляет известные версии" grep -q '32.7.4' <(ht_out)
fresh
rm -f -- "$HT_EXT/public-sources.sha256"
ht_hook install; eq "нет таблицы сумм — 1" 1 "$?"
check_not "отказы по суммам не дошли до apt-get" ht_called '^apt-get '
fresh
cp "$CONF" "$ROOT/victim"; rm -f -- "$CONF"; ln -s "$ROOT/victim" "$CONF"
ht_hook install; eq "extlinux.conf — ссылка: отказ 1" 1 "$?"
check "сообщение про ссылку" grep -q 'ссылка' <(ht_out)
fresh
rm -f -- "$CONF"
ht_hook install; eq "нет extlinux.conf — 1" 1 "$?"
check_not "отказы не дошли до apt-get" ht_called '^apt-get '

echo "== таблица сумм исходников =="
SUMS="$EXT/public-sources.sha256"
check "строки: версия, sha256, размер" python3 - "$SUMS" <<'PY2'
import re, sys
seen = set()
for line in open(sys.argv[1]):
    if line.startswith("#") or not line.strip():
        continue
    v, h, n = line.split()
    assert re.fullmatch(r"\d+\.\d+\.\d+", v) and v not in seen, v
    assert re.fullmatch(r"[0-9a-f]{64}", h) and int(n) > 100_000_000, v
    seen.add(v)
assert {"32.6.1", "32.7.4"} <= seen  # the kvm base and the BSP of the build chain
PY2
# Static order (the build itself is P): checksum before unpacking.
check "sha256sum до tar -xjf" python3 - "$EXT/hooks/install" <<'PY2'
import sys
s = open(sys.argv[1]).read()
sys.exit(0 if 0 < s.index('sha256sum "$WORK/public_sources.tbz2"') < s.index("tar -xjf") else 1)
PY2
check "проверка версии до apt-get" python3 - "$EXT/hooks/install" <<'PY2'
import sys
s = open(sys.argv[1]).read()
sys.exit(0 if 0 < s.index("нет суммы public_sources.tbz2") < s.index("apt-get update") else 1)
PY2

# --- extlinux-root.sh: what step 7 does to extlinux.conf ---------------------
# er FUNCTION ARGS…: a function of extlinux-root.sh in a clean shell.
er() { bash -c 'set -uo pipefail; . "$0/extlinux-root.sh"; "$@"' "$EXT" "$@"; }
T="$HT_TMP/el"; mkdir -p "$T"
P=817d4355-fa85-4e38-903f-ea68b2e685ff
kvm_block() { awk '$1=="LABEL"{k=($2=="kvm")} k' "$1"; }

echo "== бэкап один раз =="
vendor_conf "$T/c1"; cp "$T/c1" "$T/c1.first"
er kvm_backup_once "$T/c1" 2>/dev/null; eq "первый бэкап — 0" 0 "$?"
check "бэкап — исходный файл" cmp -s "$T/c1.first" "$T/c1.cream-orig"
echo changed >> "$T/c1"
er kvm_backup_once "$T/c1" 2>/dev/null; eq "второй бэкап — 0" 0 "$?"
check "бэкап не перезаписан" cmp -s "$T/c1.first" "$T/c1.cream-orig"
vendor_conf "$T/c2"; echo keep > "$T/victim2"; ln -s "$T/victim2" "$T/c2.cream-orig"
er kvm_backup_once "$T/c2" 2>/dev/null; eq "на месте бэкапа ссылка — 0, не пишем" 0 "$?"
eq "цель ссылки не тронута" keep "$(cat "$T/victim2")"
vendor_conf "$T/v3"; ln -s "$T/v3" "$T/c3"
er kvm_backup_once "$T/c3" 2>/dev/null; eq "extlinux.conf — ссылка: отказ" 1 "$?"
check_not "бэкапа по ссылке нет" test -e "$T/c3.cream-orig"

echo "== запись kvm =="
vendor_conf "$T/e1"
er kvm_write_entry "$T/e1" -tegra-kvm "" 2>/dev/null; eq "запись без FDT — 0" 0 "$?"
check "DEFAULT kvm" grep -qx 'DEFAULT kvm' "$T/e1"
check_not "DEFAULT primary снят" grep -qx 'DEFAULT primary' "$T/e1"
check "запасная primary на месте" grep -qx 'LABEL primary' "$T/e1"
eq "запись kvm" "LABEL kvm
      MENU LABEL kvm kernel (tegra-kvm, l4t-kernel-kvm)
      LINUX /boot/Image.kvm
      INITRD /boot/initrd
      APPEND \${cbootargs} quiet root=PARTUUID=$P rw rootwait" "$(kvm_block "$T/e1")"
eq "режим сохранён" 644 "$(stat -c %a "$T/e1")"
cp "$T/e1" "$T/e1.first"
er kvm_write_entry "$T/e1" -tegra-kvm "" 2>/dev/null; eq "повтор — 0" 0 "$?"
check "повтор: байт в байт" cmp -s "$T/e1.first" "$T/e1"
er kvm_write_entry "$T/e1" -tegra-kvm /boot/tegra210-p3448-0000-p3449-0000-b00-kvm.dtb 2>/dev/null
eq "с FDT — 0" 0 "$?"
eq "FDT в записи kvm" "      FDT /boot/tegra210-p3448-0000-p3449-0000-b00-kvm.dtb" "$(kvm_block "$T/e1" | grep FDT)"
eq "запись kvm одна" 1 "$(grep -c '^LABEL kvm$' "$T/e1")"
# A foreign entry after ours is kept; ours ends at the next LABEL, not at a blank line.
printf '%s\n' '' 'LABEL rescue' '      LINUX /boot/Image' >> "$T/e1"
er kvm_write_entry "$T/e1" -tegra-kvm "" 2>/dev/null; eq "чужая запись после нашей — 0" 0 "$?"
check "чужая запись цела" grep -qx 'LABEL rescue' "$T/e1"
eq "APPEND берётся из primary, не из kvm" 1 \
    "$(kvm_block "$T/e1" | grep -c 'APPEND ${cbootargs} quiet root=PARTUUID=')"
printf '%s\n' 'TIMEOUT 30' 'LABEL primary' '      LINUX /boot/Image' > "$T/e2"; cp "$T/e2" "$T/e2.orig"
er kvm_write_entry "$T/e2" -tegra-kvm "" 2>/dev/null; eq "нет APPEND — 1" 1 "$?"
check "файл не тронут" cmp -s "$T/e2.orig" "$T/e2"
printf '%s\n' 'TIMEOUT 30' 'LABEL primary' '      APPEND root=/dev/sda1 $(touch '"$T"'/pwned)' > "$T/e3"
er kvm_write_entry "$T/e3" -tegra-kvm "" 2>/dev/null; eq "строки с \$( ) — 0" 0 "$?"
check_not "ничего не исполнено" test -e "$T/pwned"
check "DEFAULT kvm вставлен, когда DEFAULT не было" test "$(head -1 "$T/e3")" = "DEFAULT kvm"
vendor_conf "$T/v4"; cp "$T/v4" "$T/v4.orig"; ln -s "$T/v4" "$T/e4"
er kvm_write_entry "$T/e4" -tegra-kvm "" 2>/dev/null; eq "ссылка: отказ" 1 "$?"
check "цель ссылки не тронута" cmp -s "$T/v4.orig" "$T/v4"
eq "временных файлов не осталось" "" "$(find "$T" -name '.extlinux*' -o -name '.e*.*' | head -1)"

echo "== переписывание root= не следует по ссылке =="
printf '%s\n' 'LABEL primary' '      APPEND root=/dev/mmcblk0p1 rw' > "$T/v5"; cp "$T/v5" "$T/v5.orig"
ln -s "$T/v5" "$T/r5"
er kvm_rewrite_root "$T/r5" "$P" 2>/dev/null; eq "ссылка: отказ" 1 "$?"
check "цель ссылки не тронута" cmp -s "$T/v5.orig" "$T/v5"
printf '%s\n' 'LABEL primary' '      APPEND root=/dev/mmcblk0p1 rw' > "$T/r6"; chmod 0640 "$T/r6"
er kvm_rewrite_root "$T/r6" "$P" 2>/dev/null; eq "переписывание — 0" 0 "$?"
eq "режим сохранён" 640 "$(stat -c %a "$T/r6")"

echo "== двойной прогон шага 7: бэкап — от первого =="
vendor_conf "$T/d"; cp "$T/d" "$T/d.first"
step7() {
    er kvm_backup_once "$T/d" && er kvm_rewrite_root "$T/d" "$P" && er kvm_write_entry "$T/d" -tegra-kvm "$1"
} 2>/dev/null
step7 ""; eq "первый — 0" 0 "$?"
cp "$T/d" "$T/d.after1"
step7 ""; eq "второй — 0" 0 "$?"
check "второй: файл байт в байт" cmp -s "$T/d.after1" "$T/d"
step7 /boot/x-kvm.dtb; eq "третий, с платой — 0" 0 "$?"
check "бэкап — от первого прогона" cmp -s "$T/d.first" "$T/d.cream-orig"

ht_done
