#!/usr/bin/env bash
# Tests of the l4t-boot-verify hooks (cream/v1): manifest, install and remove
# on a scratch root (CREAM_ROOT) the way cream runs them. The vendor unit
# nv-l4t-bootloader-config.service is a fixture file; no board, no systemd.
#
# What is held: install masks the vendor unit (symlink to /dev/null) and
# enables ours by a link in multi-user.target.wants; what was at the vendor's
# place before is recorded once in $CREAM_STATE_DIR and not overwritten by a
# second install; remove puts it back byte for byte. Our unit file itself is a
# `files` entry — cream lays it out before install and takes it away after
# remove, so the hooks never write it.
#
#   extensions/debian/l4t-boot-verify/tests/test-hooks.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

VENDOR=nv-l4t-bootloader-config.service
OURS=l4t-boot-verify.service

# fresh: an L4T root with nvbootctrl, the vendor unit as a file in
# /etc/systemd/system (as on AGX Orin images) enabled in multi-user.target,
# and our unit laid out by cream (`files`).
fresh() {
    ht_root "$EXT"
    SD="$ROOT/etc/systemd/system"
    WANTS="$SD/multi-user.target.wants"
    STATE="$ROOT/var/lib/cream/ext/l4t-boot-verify"
    mkdir -p "$ROOT/etc" "$ROOT/usr/sbin" "$WANTS"
    echo '# R36 (release), REVISION: 4.3' > "$ROOT/etc/nv_tegra_release"
    printf '#!/bin/sh\nexit 0\n' > "$ROOT/usr/sbin/nvbootctrl"; chmod +x "$ROOT/usr/sbin/nvbootctrl"
    printf '%s\n' '[Unit]' 'Description=vendor' '[Service]' 'ExecStart=/opt/nvidia/l4t-bootloader-config/nv-l4t-bootloader-config.sh -v' \
        '[Install]' 'WantedBy=multi-user.target' > "$SD/$VENDOR"
    cp "$SD/$VENDOR" "$ROOT/vendor.orig"
    ln -s /etc/systemd/system/$VENDOR "$WANTS/$VENDOR"
    install -m 0644 "$EXT/files/$OURS" "$SD/$OURS"
}
masked() { [[ -L "$SD/$VENDOR" && "$(readlink "$SD/$VENDOR")" == /dev/null ]]; }
ours_enabled() { [[ -L "$WANTS/$OURS" && "$(readlink "$WANTS/$OURS")" == "/etc/systemd/system/$OURS" ]]; }

echo "== манифест =="
# eval: test-only literal expressions over our own manifest, as in nvidia-jetpack.
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 2" 2.0.0 "$(mf 'm["version"]')"
eq "cream >=1.0.0" ">=1.0.0" "$(mf 'm["cream"]')"
eq "только arm64" "['arm64']" "$(mf 'm["platform"]["arch"]')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "provides" "['l4t-boot-verify']" "$(mf 'm["provides"]')"
eq "хуки install и remove" "['install', 'remove']" "$(mf 'sorted(m["hooks"])')"
eq "юнит — files" "files/$OURS -> /etc/systemd/system/$OURS" \
    "$(mf '" ".join(f["src"] + " -> " + f["dst"] for f in m["files"])')"
check "юнит зовёт nvbootctrl verify" grep -qx 'ExecStart=/usr/sbin/nvbootctrl verify' "$EXT/files/$OURS"
check "юнит в multi-user.target" grep -qx 'WantedBy=multi-user.target' "$EXT/files/$OURS"
check_not "install.sh layout 2 убран" test -e "$EXT/install.sh"
check_not "юнита с прежним именем нет" test -e "$EXT/bisquite-l4t-boot-verify.service" # check-names: allow

echo "== не L4T =="
fresh
rm -f -- "$ROOT/etc/nv_tegra_release"
ht_hook install; eq "нет /etc/nv_tegra_release — 20" 20 "$?"
check "вендорская не тронута" cmp -s "$ROOT/vendor.orig" "$SD/$VENDOR"
fresh
rm -f -- "$ROOT/usr/sbin/nvbootctrl"
ht_hook install; eq "нет nvbootctrl — 1" 1 "$?"
check "вендорская не тронута" cmp -s "$ROOT/vendor.orig" "$SD/$VENDOR"
check_not "своя не включена" test -e "$WANTS/$OURS"

echo "== install: маска вендорской, своя включена =="
fresh
ht_hook install; eq "install — 0" 0 "$?"
check "вендорская замаскирована (/dev/null)" masked
check_not "вендорская снята из multi-user.target.wants" test -e "$WANTS/$VENDOR" -o -L "$WANTS/$VENDOR"
check "своя включена" ours_enabled
check "копия вендорской в состоянии" cmp -s "$ROOT/vendor.orig" "$STATE/$VENDOR.orig"
check_not "systemctl не звали (build и live одинаково)" ht_called '^systemctl '
cp -a "$STATE" "$ROOT/state1"
ht_hook install; eq "повтор install — 0" 0 "$?"
check "повтор: копия вендорской — от первого" cmp -s "$ROOT/vendor.orig" "$STATE/$VENDOR.orig"
check "повтор: состояние байт в байт" diff -r "$ROOT/state1" "$STATE"
check "повтор: маска на месте" masked
check "повтор: своя включена" ours_enabled

echo "== remove: всё как было =="
ht_hook remove; eq "remove — 0" 0 "$?"
check "вендорская — снова файл" test -f "$SD/$VENDOR" -a ! -L "$SD/$VENDOR"
check "вендорская байт в байт" cmp -s "$ROOT/vendor.orig" "$SD/$VENDOR"
eq "вендорская снова включена" "/etc/systemd/system/$VENDOR" "$(readlink "$WANTS/$VENDOR")"
check_not "своя выключена" test -e "$WANTS/$OURS" -o -L "$WANTS/$OURS"
check_not "состояние снято" test -e "$STATE/$VENDOR.orig"
check "свой юнит не трогает (его снимает cream)" test -f "$SD/$OURS"
cp -a "$SD" "$ROOT/sd-after"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
check "повтор remove ничего не меняет" diff -r --no-dereference "$ROOT/sd-after" "$SD"

echo "== вендорская в /lib, не в /etc =="
fresh
rm -f -- "$SD/$VENDOR" "$WANTS/$VENDOR"
ht_hook install; eq "install — 0" 0 "$?"
check "маска в /etc" masked
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "маска снята, в /etc пусто" test -e "$SD/$VENDOR" -o -L "$SD/$VENDOR"
check_not "чужого wants не появилось" test -e "$WANTS/$VENDOR" -o -L "$WANTS/$VENDOR"

echo "== оператор замаскировал до нас =="
fresh
rm -f -- "$SD/$VENDOR" "$WANTS/$VENDOR"
ln -s /dev/null "$SD/$VENDOR"
ht_hook install; eq "install — 0" 0 "$?"
ht_hook remove; eq "remove — 0" 0 "$?"
check "маска оператора осталась" masked

echo "== ссылки состояния не разыменовываются =="
fresh
echo keep > "$ROOT/victim"
mkdir -p "$STATE"
ln -s "$ROOT/victim" "$STATE/$VENDOR.orig"
ht_hook install; eq "ссылка на месте копии — отказ 1" 1 "$?"
eq "цель ссылки не тронута" keep "$(cat "$ROOT/victim")"
check "вендорская не тронута" cmp -s "$ROOT/vendor.orig" "$SD/$VENDOR"

echo "== состояние — данные =="
fresh
mkdir -p "$STATE"
printf '%s\n' 'link $(touch '"$ROOT"'/pwned)' > "$STATE/vendor-unit"
ht_hook remove; eq "remove с чужим содержимым состояния — 0" 0 "$?"
check_not "ничего не исполнено" test -e "$ROOT/pwned"
printf '%s\n' 'bogus' > "$STATE/vendor-unit"
ht_hook remove; eq "неизвестная запись состояния — 1" 1 "$?"

ht_done
