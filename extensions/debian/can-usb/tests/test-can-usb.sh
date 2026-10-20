#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the can-usb extension (cream/v1), what can be checked without a
# board: the gates of canusb.sh (release, board, module tree, Sensing kernel,
# headers), the download of the sources checked by sha256 before unpacking, the build layout,
# the vermagic check and the install with depmod on fake make/modinfo/strip/
# depmod/modprobe, the pins and the order of steps in hooks/install; then the
# manifest and hooks install / remove on a scratch root (CREAM_ROOT) the way
# cream runs them (sha256sum — the real one with fixture sums mapped onto the
# pinned ones). The real build — on the board (README, «Проверка»).
#
#   extensions/debian/can-usb/tests/test-can-usb.sh   code 0 — all passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
X="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$X/../../../tools/hooktest.sh"
ht_init
T="$HT_TMP"
q() { "$@" >/dev/null 2>&1; }
says() { local n="$1" pat="$2" out; shift 2; out="$("$@" 2>&1)"; if grep -qF -- "$pat" <<<"$out"; then ok; else bad "$n (нет «$pat»)"; fi; }

KV=5.15.148-tegra
DTB=tegra234-p3737-0000+p3701-0000-nv.dtb
# Run a function from canusb.sh in a clean shell against root $1, fakes first in PATH.
cu() { local root="$1"; shift; PATH="$T/bin:$PATH" CANUSB_ROOT="$root" bash -c 'set -uo pipefail; . "$0/canusb.sh"; "$@"' "$X" "$@"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
release_file() { mkdir -p "$1/etc"; printf '%s\n' "$2" > "$1/etc/nv_tegra_release"; }
board() { release_file "$1" "$2"; mkdir -p "$1/boot/dtb"; : > "$1/boot/dtb/kernel_$DTB"; }

echo "== релиз и плата =="
R3643='# R36 (release), REVISION: 4.3, GCID: 38968081, BOARD: generic, EABI: aarch64, DATE: Wed Jan  8 01:49:37 UTC 2025'
board "$T/b1" "$R3643"
board "$T/b2" '# R36 (release), REVISION: 4.4, GCID: 41062509, BOARD: generic, EABI: aarch64'
release_file "$T/b3" "$R3643"
check   "AGX Orin, 36.4.3 — проходит"          q cu "$T/b1" canusb_gate_board 36.4.3 "$DTB"
check_not "36.4.4 — отказ"                       q cu "$T/b2" canusb_gate_board 36.4.3 "$DTB"
check_not "нет DTB AGX Orin — отказ"             q cu "$T/b3" canusb_gate_board 36.4.3 "$DTB"
check_not "нет nv_tegra_release — отказ"         q cu "$T/none" canusb_gate_board 36.4.3 "$DTB"

echo "== ядро по /lib/modules образа =="
mkdir -p "$T/k1/lib/modules/$KV" "$T/k1/lib/modules/5.15.0-191-generic"
mkdir -p "$T/k2/lib/modules/$KV" "$T/k2/lib/modules/5.10.216-tegra"
mkdir -p "$T/k3/lib/modules/5.10.216-tegra" "$T/k4/lib/modules"
check   "одно ядро L4T $KV (+generic) — проходит"  q cu "$T/k1" canusb_gate_kernel_tree "$KV"
says    "…generic назван и не используется"      "не используются: 5.15.0-191-generic" cu "$T/k1" canusb_gate_kernel_tree "$KV"
check_not "два ядра L4T — отказ"                   q cu "$T/k2" canusb_gate_kernel_tree "$KV"
check_not "другое ядро L4T — отказ"                q cu "$T/k3" canusb_gate_kernel_tree "$KV"
check_not "ядер нет — отказ"                       q cu "$T/k4" canusb_gate_kernel_tree "$KV"

echo "== ядро Sensing на /boot/Image =="
image() { mkdir -p "$1/boot"; printf 'ARM64\0Linux version %s (%s) #1 SMP PREEMPT\0' "$2" "$3" > "$1/boot/Image"; }
image "$T/s1" "$KV" sensing; printf 'stock' > "$T/s1/boot/Image.backup"
SENS="$(sha "$T/s1/boot/Image")"
image "$T/s2" "$KV" stock; cp "$T/s2/boot/Image" "$T/s2/boot/Image.backup"
image "$T/s3" "$KV" stock
image "$T/s4" "$KV" sensing-rebuild; printf 'stock' > "$T/s4/boot/Image.backup"
image "$T/s5" 5.10.216-tegra sensing
check   "ядро Sensing с закреплённой суммой — проходит"  q cu "$T/s1" canusb_gate_sensing_kernel "$KV" "$SENS"
check_not "штатное ядро (= Image.backup) — отказ"          q cu "$T/s2" canusb_gate_sensing_kernel "$KV" "$SENS"
says    "…и названо, что sensing-gmsl2-camera раньше"    "sensing-gmsl2-camera должен стоять в VMFILE РАНЬШЕ" cu "$T/s2" canusb_gate_sensing_kernel "$KV" "$SENS"
says    "нет Image.backup — тоже порядок слоёв"          "РАНЬШЕ can-usb" cu "$T/s3" canusb_gate_sensing_kernel "$KV" "$SENS"
says    "другая сборка Sensing — отказ с причиной"       "неизвестной сборки" cu "$T/s4" canusb_gate_sensing_kernel "$KV" "$SENS"
check_not "другая версия ядра — отказ"                     q cu "$T/s5" canusb_gate_sensing_kernel "$KV" "$SENS"
check_not "нет /boot/Image — отказ"                        q cu "$T/none" canusb_gate_sensing_kernel "$KV" "$SENS"

echo "== заголовки ядра =="
headers() {
    local b="$1/lib/modules/$KV/build"
    mkdir -p "$b/include/config"
    echo 'all:' > "$b/Makefile"; echo 'CONFIG_MODVERSIONS=y' > "$b/.config"
    printf '0x1bd17b3e\tcan_change_mtu\tdrivers/net/can/dev/can-dev\tEXPORT_SYMBOL_GPL\t\n' > "$b/Module.symvers"
    echo "${2:-$KV}" > "$b/include/config/kernel.release"
}
headers "$T/h1"; HC="$(sha "$T/h1/lib/modules/$KV/build/.config")"; HS="$(sha "$T/h1/lib/modules/$KV/build/Module.symvers")"
headers "$T/h2"; rm "$T/h2/lib/modules/$KV/build/Module.symvers"
headers "$T/h3" 5.15.148-tegra-other
headers "$T/h4"; echo 'CONFIG_GCC_PLUGIN_RANDSTRUCT=y' >> "$T/h4/lib/modules/$KV/build/.config"
check   "сверенные .config и Module.symvers — проходит"  q cu "$T/h1" canusb_gate_headers "$KV" "$HC" "$HS"
check_not "нет Module.symvers — отказ"                     q cu "$T/h2" canusb_gate_headers "$KV" "$HC" "$HS"
check_not "kernel.release не тот — отказ"                  q cu "$T/h3" canusb_gate_headers "$KV" "$HC" "$HS"
check_not ".config другой — отказ"                         q cu "$T/h4" canusb_gate_headers "$KV" "$HC" "$HS"

echo "== исходники: скачивание во временный файл, сверка, потом распаковка =="
P=kernel/kernel-jammy-src/drivers/net/can
mkdir -p "$T/ks/$P/usb/peak_usb" "$T/ps/Linux_for_Tegra/source"
for f in usb/gs_usb.c usb/peak_usb/pcan_usb_core.c usb/peak_usb/pcan_usb_core.h usb/peak_usb/pcan_usb.c \
         usb/peak_usb/pcan_usb_pro.c usb/peak_usb/pcan_usb_pro.h usb/peak_usb/pcan_usb_fd.c slcan.c; do
    echo "/* $f */" > "$T/ks/$P/$f"
done
echo other > "$T/ks/$P/usb/Makefile"
tar -cjf "$T/ps/Linux_for_Tegra/source/kernel_src.tbz2" -C "$T/ks" kernel
tar -cjf "$T/public_sources.tbz2" -C "$T/ps" Linux_for_Tegra
PSUM="$(sha "$T/public_sources.tbz2")"
rm "$T/ks/$P/slcan.c"
tar -cjf "$T/ps/Linux_for_Tegra/source/kernel_src.tbz2" -C "$T/ks" kernel
tar -cjf "$T/short.tbz2" -C "$T/ps" Linux_for_Tegra
ZERO=0000000000000000000000000000000000000000000000000000000000000000
check   "сумма сошлась — исходники извлечены"     q cu / canusb_fetch "file://$T/public_sources.tbz2" "$PSUM" "$T/f1"
check   "…ровно восемь файлов драйверов"          q test "$(find "$T/f1/kernel" -type f | wc -l)" -eq 8
check   "…и это они"                              q grep -qF 'usb/peak_usb/pcan_usb_fd.c' "$T/f1/$P/usb/peak_usb/pcan_usb_fd.c"
check   "…архив после распаковки удалён"          q test "$(find "$T/f1" -maxdepth 1 -name '.public_sources*' | wc -l)" -eq 0
# tar that logs each call: an archive whose sum does not match is never unpacked.
mkdir -p "$T/tarbin"
printf '#!/usr/bin/env bash\necho "tar $*" >> "%s/tar.calls"\nexec /usr/bin/env -S PATH=/usr/bin:/bin tar "$@"\n' "$T" > "$T/tarbin/tar"
chmod +x "$T/tarbin/tar"
: > "$T/tar.calls"
check   "сумма сошлась — tar зовётся"             q env PATH="$T/tarbin:$PATH" bash -c "$(declare -f cu); T='$T' X='$X'; cu / canusb_fetch 'file://$T/public_sources.tbz2' '$PSUM' '$T/f1t'"
check   "…и распаковывает из файла, не из потока" q grep -q '^tar -xjOf .*/\.public_sources\.' "$T/tar.calls"
: > "$T/tar.calls"
check_not "sha256 не та — отказ"                    q env PATH="$T/tarbin:$PATH" bash -c "$(declare -f cu); T='$T' X='$X'; cu / canusb_fetch 'file://$T/public_sources.tbz2' '$ZERO' '$T/f2'"
check_not "…и исходников нет"                       q test -e "$T/f2/kernel"
eq      "…tar не запускался ни разу"              0 "$(wc -l < "$T/tar.calls")"
check   "…архив не остался"                       q test "$(find "$T/f2" -maxdepth 1 -name '.public_sources*' | wc -l)" -eq 0
says    "…причина названа"                        "закреплена $ZERO" cu / canusb_fetch "file://$T/public_sources.tbz2" "$ZERO" "$T/f2b"
check_not "в архиве нет slcan.c — отказ"            q cu / canusb_fetch "file://$T/short.tbz2" "$PSUM" "$T/f3"
check_not "не скачалось — отказ"                    q cu / canusb_fetch "file://$T/missing.tbz2" "$PSUM" "$T/f4"

echo "== раскладка сборки =="
check   "исходники и Kbuild разложены"            q cu / canusb_prepare "$T/f1" "$X/Kbuild" "$T/bd"
check   "…peak_usb/ — подкаталогом"               q test -f "$T/bd/peak_usb/pcan_usb_core.h" -a -f "$T/bd/gs_usb.c" -a -f "$T/bd/slcan.c"
check   "Kbuild собирает три модуля"              q grep -qx 'obj-m := gs_usb.o peak_usb.o slcan.o' "$X/Kbuild"
check   "…peak_usb из четырёх объектов ядра 5.15" q bash -c "tr -d '\\\\\n' < '$X/Kbuild' | grep -q 'peak_usb-y := peak_usb/pcan_usb_core.o peak_usb/pcan_usb.o *peak_usb/pcan_usb_pro.o peak_usb/pcan_usb_fd.o'"

echo "== сборка и сверка vermagic на подставных командах =="
# make writes FAKE_MAGIC into the three .ko (FAKE_MAKE_FAIL=1 fails, FAKE_SKIP
# names a module it does not build); modinfo -F vermagic prints a file's first
# line; strip is a no-op; depmod logs its args; modprobe --show-depends prints
# the path depmod "found" unless FAKE_MODPROBE_FAIL=1.
mkdir -p "$T/bin"
cat > "$T/bin/make" <<'FAKE'
#!/usr/bin/env bash
[ "${FAKE_MAKE_FAIL:-0}" = 1 ] && { echo "gs_usb.c:1: error: boom"; exit 2; }
for a; do case "$a" in M=*) m="${a#M=}";; esac; done
for k in gs_usb peak_usb slcan; do [ "$k" = "${FAKE_SKIP:-}" ] || echo "$FAKE_MAGIC" > "$m/$k.ko"; done
FAKE
cat > "$T/bin/modinfo" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = -F ] && [ "$2" = vermagic ] && head -n1 "$3"
FAKE
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/strip"
cat > "$T/bin/depmod" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
FAKE
cat > "$T/bin/modprobe" <<'FAKE'
#!/usr/bin/env bash
[ "${FAKE_MODPROBE_FAIL:-0}" = 1 ] && { echo "modprobe: FATAL: Module ${!#} not found"; exit 1; }
echo "insmod /lib/modules/$KV/updates/can-usb/${!#}.ko"
FAKE
chmod +x "$T/bin/"*
MAGIC="$KV SMP preempt mod_unload modversions aarch64"
mkdir -p "$T/r1/lib/modules/$KV/kernel/drivers/net/can/dev"
echo "$MAGIC" > "$T/r1/lib/modules/$KV/kernel/drivers/net/can/dev/can-dev.ko"
mkdir -p "$T/r2/lib/modules/$KV/kernel"
export KV FAKE_MAGIC="$MAGIC" FAKE_LOG="$T/depmod.log"
cu "$T/r1" canusb_prepare "$T/f1" "$X/Kbuild" "$T/bd1" >/dev/null 2>&1
check   "собрано, vermagic как у can-dev.ko"      q cu "$T/r1" canusb_build "$KV" "$T/bd1" 2
for v in "FAKE_MAKE_FAIL=1" "FAKE_SKIP=slcan" "FAKE_MAGIC=5.15.148-tegra SMP preempt mod_unload aarch64"; do
    rm -f "$T/bd1"/*.ko
    check_not "отказ при ${v%%=*}=${v#*=}"         q env "$v" bash -c "$(declare -f cu); T='$T' X='$X' cu '$T/r1' canusb_build '$KV' '$T/bd1' 2"
done
rm -f "$T/bd1"/*.ko
check_not "нет can-dev.ko для сверки — отказ"       q cu "$T/r2" canusb_build "$KV" "$T/bd1" 2
cu "$T/r1" canusb_build "$KV" "$T/bd1" 2 >/dev/null 2>&1

echo "== установка и depmod =="
MD="/lib/modules/$KV/updates/can-usb"
check   "установлено, depmod прошёл"              q cu "$T/r1" canusb_install "$KV" "$T/bd1" "$MD"
check   "…три модуля, права 0644"                 q bash -c "for m in gs_usb peak_usb slcan; do [ \"\$(stat -c %a '$T/r1$MD/'\$m.ko)\" = 644 ] || exit 1; done"
check   "…depmod для ядра образа, не uname -r"    q grep -qx -- "-b $T/r1 $KV" "$FAKE_LOG"
check   "повторная установка — снова успех"       q cu "$T/r1" canusb_install "$KV" "$T/bd1" "$MD"
check_not "modprobe не разрешает модуль — отказ"    q env FAKE_MODPROBE_FAIL=1 bash -c "$(declare -f cu); T='$T' X='$X' cu '$T/r1' canusb_install '$KV' '$T/bd1' '$MD'"
check_not "modprobe берёт чужой файл — отказ"       q cu "$T/r1" canusb_install "$KV" "$T/bd1" /lib/modules/$KV/updates/other

echo "== install.sh: закрепления и порядок =="
I="$X/hooks/install"
check   "закреплён релиз L4T 36.4.3"               q grep -qx 'CANUSB_L4T=36.4.3' "$I"
check   "закреплено ядро 5.15.148-tegra"           q grep -qx 'CANUSB_KERNEL=5.15.148-tegra' "$I"
check   "закреплён адрес исходников R36.4.3"       q grep -qx 'CANUSB_SRC_URL=https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.3/sources/public_sources.tbz2' "$I"
check   "закреплена sha256 исходников"             q grep -qx 'CANUSB_SRC_SHA256=2c177804679e3ed650dabec6fa958388579896f170570c6171a1b6c386669216' "$I"
check   "закреплена sha256 ядра Sensing"           q grep -qx 'CANUSB_SENSING_IMAGE_SHA256=fb75806692bd7216916da985ed828f841cbf38b3e7207f124921b41fd84b8771' "$I"
check   "закреплены .config и Module.symvers"      q bash -c "grep -qx 'CANUSB_HEADERS_CONFIG_SHA256=9f3129b2dd65e88c043fa09a7f0a3abd30c88891e029f3f1b6d976bed09459f2' '$I' && grep -qx 'CANUSB_HEADERS_SYMVERS_SHA256=bdbf119f6a3844aa7810fb22ed4c604f5608e9302033a81d27fa558314ce7f96' '$I'"
check   "модули — в updates/can-usb ядра образа"   q grep -qx 'CANUSB_MODDIR="/lib/modules/$CANUSB_KERNEL/updates/can-usb"' "$I"
line() { grep -nE "$1" "$I" | head -1 | cut -d: -f1; }
check   "барьеры — до apt и сети"                  q test "$(line '^canusb_gate_sensing_kernel ')" -lt "$(line 'apt_update_once \|\| exit')"
check   "…и до скачивания"                         q test "$(line '^canusb_gate_sensing_kernel ')" -lt "$(line '^canusb_fetch ')"
check   "заголовки сверяются до сборки"            q test "$(line '^canusb_gate_headers ')" -lt "$(line '^canusb_build ')"
check   "установка — после сборки"                 q test "$(line '^canusb_build ')" -lt "$(line '^canusb_install ')"
check_not "uname -r в коде не используется"          q bash -c "grep -hv '^[[:space:]]*#' '$I' '$X/canusb.sh' | grep -qF '\$(uname'"
check_not "автозагрузку не трогает"                  q grep -qE 'modules-load\.d|CAN_MODULES_LOAD=' "$I" "$X/canusb.sh"

echo "== манифест =="
mf() { python3 -c 'import sys,yaml; m=yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$X/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 2" 2 "$(mf 'm["version"].split(".")[0]')"
eq "cream 1.0" ">=1.0.0" "$(mf 'm["cream"]')"
eq "только arm64" arm64 "$(mf '" ".join(m["platform"]["arch"])')"
eq "build: exec" exec "$(mf 'm["targets"]["build"]')"
eq "live: confirm" confirm "$(mf 'm["targets"]["live"]')"
check "live_note называет сборку и сеть" bash -c 'grep -q "собира" <<<"$1" && grep -q "МБ" <<<"$1"' _ "$(mf 'm["targets"]["live_note"]')"
eq "provides" can-usb-adapters "$(mf '" ".join(m["provides"])')"
eq "requires" gmsl2-camera "$(mf '" ".join(m["requires"])')"
eq "хуки" "install remove" "$(mf '" ".join(sorted(m["hooks"]))')"
check "install: явный timeout" test -n "$(mf 'm["hooks"]["install"]["timeout"]')"
check "canusb.sh и Kbuild в дереве" test -f "$X/canusb.sh" -a -f "$X/Kbuild"
check_not "layout 2: install.sh не остался" test -e "$X/install.sh"

echo "== hooks: подменённый корень =="
HV=5.15.148-tegra-36.4.3-20250107174145
pin() { grep -oE "^$1=[0-9a-f]{64}$" "$X/hooks/install" | cut -d= -f2; }
# The headers tree as the package would put it, kept aside for the fake apt-get.
headers "$T/hdr"
cu_root() {
    ht_root "$X"
    local r="$ROOT" c
    board "$r" "$R3643"
    image "$r" "$KV" sensing; printf 'stock' > "$r/boot/Image.backup"
    mkdir -p "$r/lib/modules/$KV/kernel/drivers/net/can/dev" "$r/usr/bin" "$r/var/tmp" "$FAKE/pkgs"
    echo "$MAGIC" > "$r/lib/modules/$KV/kernel/drivers/net/can/dev/can-dev.ko"
    cp -a "$T/hdr/lib" "$r/"
    for c in gcc make curl bzip2 strip modinfo depmod modprobe; do printf '#!/bin/sh\n' > "$r/usr/bin/$c"; chmod +x "$r/usr/bin/$c"; done
    : > "$FAKE/pkgs/nvidia-l4t-kernel"
    echo "$HV" > "$FAKE/kver"
    : > "$FAKE/holds"; : > "$FAKE/sim-extra"
    cp "$T/public_sources.tbz2" "$FAKE/src.tbz2"
    {   echo "$(sha "$r/boot/Image") $(pin CANUSB_SENSING_IMAGE_SHA256)"
        echo "$HC $(pin CANUSB_HEADERS_CONFIG_SHA256)"
        echo "$HS $(pin CANUSB_HEADERS_SYMVERS_SHA256)"
        echo "$PSUM $(pin CANUSB_SRC_SHA256)"; } > "$FAKE/shamap"
    printf -v hq '%q' "$T/hdr"
    ht_fake sha256sum '
out="$(/usr/bin/sha256sum "$@")" || exit
while read -r from to; do out="${out//$from/$to}"; done < "$FAKE/shamap"
printf "%s\n" "$out"'
    ht_fake curl '[[ -e "$FAKE/curl-fails" ]] && exit 22
o=""; while (( $# )); do [[ "$1" == -o ]] && { o="$2"; shift; }; shift; done
if [[ -n "$o" ]]; then cat "$FAKE/src.tbz2" > "$o"; else cat "$FAKE/src.tbz2"; fi'
    ht_fake make "MAGIC='$MAGIC'"'
for a; do case "$a" in M=*) m="${a#M=}";; esac; done
for k in gs_usb peak_usb slcan; do echo "$MAGIC" > "$m/$k.ko"; done'
    ht_fake modinfo '[ "$1" = -F ] && [ "$2" = vermagic ] && head -n1 "$3"'
    ht_fake strip
    ht_fake depmod
    ht_fake modprobe "echo \"insmod /lib/modules/$KV/updates/can-usb/\${!#}.ko\""
    ht_fake dpkg-query '
f="" p="${*: -1}"
for a in "$@"; do case "$a" in -f*) f="${a#-f}" ;; esac; done
[[ -e "$FAKE/pkgs/$p" ]] || exit 1
case "$f" in *Status-Status*) printf installed ;; *) cat "$FAKE/kver" ;; esac'
    ht_fake apt-mark '
case "$1" in
    hold) shift; for p in "$@"; do echo "$p" >> "$FAKE/holds"; done ;;
    unhold) shift; for p in "$@"; do grep -vxF "$p" "$FAKE/holds" > "$FAKE/holds.n" || true; mv "$FAKE/holds.n" "$FAKE/holds"; done ;;
    showhold) sort -u "$FAKE/holds" ;;
esac'
    ht_fake apt-get "HDR=$hq"'
sub="" sim=""
for a in "$@"; do
    case "$a" in -s) sim=1 ;; -*) ;; *) [[ -z "$sub" ]] && { sub="$a"; continue; }
        if [[ -n "$sim" ]]; then echo "Remv $a [1]"; continue; fi
        case "$sub" in
            install) : > "$FAKE/pkgs/${a%%=*}"
                     [[ "$a" == nvidia-l4t-kernel-headers=* ]] && cp -a "$HDR/lib" "$(dirname "$FAKE")/" ;;
            remove) rm -f "$FAKE/pkgs/$a" ;;
        esac ;;
    esac
done
[[ -n "$sim" ]] && cat "$FAKE/sim-extra"
exit 0'
    STATE="$ROOT/var/lib/cream/ext/can-usb"
    MODS="$ROOT/lib/modules/$KV/updates/can-usb"
}

echo "== install: отказы до сети =="
cu_root; rm "$ROOT/etc/nv_tegra_release"
ht_hook install; eq "нет nv_tegra_release — 20" 20 "$?"
check_not "не Jetson — сети нет" ht_called '^curl'
cu_root; image "$ROOT" "$KV" stock; cp "$ROOT/boot/Image" "$ROOT/boot/Image.backup"
ht_hook install; eq "штатное ядро — 1" 1 "$?"
check "порядок слоёв назван" grep -q 'sensing-gmsl2-camera' "$ROOT/out"
check_not "штатное ядро — сети нет" ht_called '^(curl|apt-get)'

echo "== install: сборка и установка =="
cu_root
ht_hook install; eq "первая установка — 10" 10 "$?"
for m in gs_usb peak_usb slcan; do check "$m.ko в updates/can-usb" test -f "$MODS/$m.ko"; done
check "depmod под ядро образа" ht_called "^depmod (-b [^ ]+ )?$KV\$"
check_not "заголовки были — apt не зовётся" ht_called '^apt-get'
check_not "временный каталог убран" compgen -G "$ROOT/var/tmp/can-usb.*"
check_not "временных .ko не осталось" compgen -G "$MODS/.*"
ht_hook install; eq "повтор — 0" 0 "$?"

echo "== install: заголовки и инструменты из apt =="
cu_root; rm -r "$ROOT/lib/modules/$KV/build"; rm "$ROOT/usr/bin/gcc"
ht_hook install; eq "без заголовков и gcc — 10" 10 "$?"
check "заголовки по версии ядра" ht_called "^apt-get .*install .*nvidia-l4t-kernel-headers=$HV\$"
check "заголовки закреплены" grep -qx nvidia-l4t-kernel-headers "$FAKE/holds"
check "hold записан" grep -qx nvidia-l4t-kernel-headers "$STATE/held"
check "инструменты сборки" ht_called '^apt-get .*install .*gcc make'
check "пакеты записаны" grep -qx nvidia-l4t-kernel-headers "$STATE/packages"
cu_root; rm -r "$ROOT/lib/modules/$KV/build"
echo '5.15.148-tegra-36.4.3;$(id)' > "$FAKE/kver"
ht_hook install; eq "версия ядра с чужими символами — 1" 1 "$?"
check_not "странная версия — apt не зовётся" ht_called '^apt-get'
cu_root; : > "$FAKE/curl-fails"
ht_hook install; eq "исходники не скачались — 1" 1 "$?"
check_not "модулей нет" test -e "$MODS/gs_usb.ko"

echo "== remove =="
cu_root; rm -r "$ROOT/lib/modules/$KV/build"
ht_hook install >/dev/null
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "модули сняты" test -e "$MODS"
check "depmod после снятия" ht_called "^depmod (-b [^ ]+ )?$KV\$"
check_not "свой hold снят" grep -qx nvidia-l4t-kernel-headers "$FAKE/holds"
check "свои пакеты удалены" ht_called '^apt-get -q -y remove .*nvidia-l4t-kernel-headers'
check_not "записи сняты" test -e "$STATE/held"
: > "$FAKE/calls"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
check_not "повтор: apt не зовётся" ht_called '^apt-get'
cu_root; rm -r "$ROOT/lib/modules/$KV/build"
ht_hook install >/dev/null
mkdir -p "$ROOT/var/lib/cream/ext/sensing-gmsl2-camera"
echo nvidia-l4t-kernel-headers > "$ROOT/var/lib/cream/ext/sensing-gmsl2-camera/held"
ht_hook remove >/dev/null
check "hold, записанный sensing-gmsl2-camera, остался" grep -qx nvidia-l4t-kernel-headers "$FAKE/holds"
cu_root; rm "$ROOT/usr/bin/gcc"
ht_hook install >/dev/null
echo 'Remv my-build-app [1]' > "$FAKE/sim-extra"
ht_hook remove; eq "apt снял бы чужой пакет — 1" 1 "$?"
check "модули не тронуты при отказе" test -f "$MODS/gs_usb.ko"

ht_done
