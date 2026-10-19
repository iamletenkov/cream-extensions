#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the nvidia extension (cream/v1): manifest and hook install on a
# scratch root (CREAM_ROOT) the way cream runs it, with fake apt-get, apt-cache,
# dpkg, dpkg-query, curl, gpg, dkms, modinfo, depmod, update-initramfs and
# uname. root, network, a kernel and a GPU are not needed.
#
#   extensions/debian/nvidia/tests/test-nvidia.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

K=6.8.0-45-generic
DEB_K=6.1.0-26-amd64
CUDA12_FPR=EB693B3035CD5710E231E123A4B469963BF863CC

# nv_root ID VERSION [KERNEL…]: fresh root with /etc/os-release, kernels
# (/lib/modules/<k> + /boot/vmlinuz-<k>) and fakes. Package database —
# $FAKE/pkgs, candidates — $FAKE/cand/<pkg>, packages the archive has —
# $FAKE/avail/<pkg>, simulated install output — $FAKE/sim.
nv_root() {
    local id="$1" ver="$2" k
    shift 2
    ht_root "$EXT"
    mkdir -p "$ROOT/etc/modprobe.d" "$ROOT/etc/apt/sources.list.d" "$ROOT/boot" "$ROOT/lib/modules" "$FAKE/pkgs" "$FAKE/cand" "$FAKE/avail" \
        "$ROOT/usr/lib/x86_64-linux-gnu"
    {
        echo "ID=$id"
        echo "VERSION_ID=\"$ver\""
        case "$id" in
            ubuntu) echo "VERSION_CODENAME=noble"; echo "UBUNTU_CODENAME=noble" ;;
            debian) echo "VERSION_CODENAME=bookworm" ;;
        esac
    } > "$ROOT/etc/os-release"
    for k in "$@"; do
        mkdir -p "$ROOT/lib/modules/$k"
        : > "$ROOT/boot/vmlinuz-$k"
    done
    : > "$FAKE/sim"
    echo 580.95.05 > "$FAKE/modver"
    echo 'Dual MIT/GPL' > "$FAKE/license"
    echo 6.1.0-appliance > "$FAKE/uname"
    echo "$CUDA12_FPR" > "$FAKE/fpr"
    ht_fake dpkg '[[ "$1" == --print-architecture ]] && echo amd64'
    ht_fake dpkg-query '
p="${*: -1}"
[[ -e "$FAKE/pkgs/$p" ]] && printf "install ok installed"
exit 0'
    ht_fake apt-get '
sub="" sim=""
for a in "$@"; do
    case "$a" in -s) sim=1 ;; -*|Dpkg::*) ;; *) [[ -z "$sub" ]] && { sub="$a"; continue; }
        [[ -n "$sim" ]] && continue
        case "$sub" in install) : > "$FAKE/pkgs/$a" ;; remove|purge) rm -f "$FAKE/pkgs/$a" ;; esac ;;
    esac
done
[[ -e "$FAKE/apt-fails-$sub" ]] && exit 100
[[ -n "$sim" ]] && cat "$FAKE/sim"
exit 0'
    ht_fake apt-cache '
case "$1" in
    policy) c="(none)"; [[ -f "$FAKE/cand/$2" ]] && c="$(cat "$FAKE/cand/$2")"
            printf "%s:\n  Installed: (none)\n  Candidate: %s\n" "$2" "$c" ;;
    show) [[ -e "$FAKE/avail/$2" ]] ;;
    pkgnames) ls "$FAKE/avail" | grep "^$2" || true ;;
esac'
    ht_fake curl '
out=""; url=""
while (( $# )); do
    case "$1" in -o) out="$2"; shift 2 ;; --retry|--retry-delay) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
echo "KEY $url" > "$out"'
    ht_fake gpg '
case " $* " in
    *" --list-keys "*) echo "pub:-:4096:1:AAAA:0:::-:::scESC::::::23::0:"
                       echo "fpr:::::::::$(cat "$FAKE/fpr"):" ;;
    *" --export "*) echo "ARMORED ${*: -1}" ;;
esac
exit 0'
    ht_fake gpgconf
    ht_fake dkms '
[[ "$1" == status ]] && { cat "$FAKE/dkms-status" 2>/dev/null || true; }
exit 0'
    ht_fake modinfo '
f="" k=""
while (( $# )); do case "$1" in -F) f="$2"; shift 2 ;; -k) k="$2"; shift 2 ;; -n) f=path; shift ;; *) shift ;; esac; done
[[ -e "$FAKE/no-module" ]] && exit 1
case "$f" in version) cat "$FAKE/modver" ;; license) cat "$FAKE/license" ;; path) echo "/lib/modules/$k/updates/nvidia.ko" ;; esac'
    ht_fake depmod
    ht_fake update-initramfs
    ht_fake dmesg
    ht_fake uname 'cat "$FAKE/uname"'
    BL="$ROOT/etc/modprobe.d/blacklist-nouveau.conf"
}
# ubuntu_driver: the archive of Ubuntu 24.04 with 580-open and the user-space library.
ubuntu_driver() {
    echo 580.95.05-0ubuntu1 > "$FAKE/cand/nvidia-driver-580-open"
    : > "$ROOT/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.580.95.05"
}
# debian_driver: the CUDA repository for Debian 12 with branch 580.
debian_driver() {
    : > "$FAKE/avail/nvidia-driver-pinning-580"
    : > "$FAKE/avail/nvidia-driver-pinning-590"
    echo 580.95.05-1 > "$FAKE/cand/nvidia-open"
    echo 580.95.05-1 > "$FAKE/cand/cuda-drivers"
    echo 6.1.112-1 > "$FAKE/cand/linux-headers-$DEB_K"
    : > "$ROOT/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.580.95.05"
}
mf() { python3 -c 'import sys,yaml; m=yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }

echo "== манифест и раскладка =="
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 3" 3 "$(mf 'm["version"].split(".")[0]')"
eq "cream 1.0" ">=1.0.0" "$(mf 'm["cream"]')"
eq "только amd64" amd64 "$(mf '" ".join(m["platform"]["arch"])')"
eq "os: debian, ubuntu" "debian ubuntu" "$(mf '" ".join(sorted(o["id"] for o in m["platform"]["os"]))')"
eq "build: exec" exec "$(mf 'm["targets"]["build"]')"
eq "live: confirm" confirm "$(mf 'm["targets"]["live"]')"
check "live_note называет nouveau" grep -q nouveau <<< "$(mf 'm["targets"]["live_note"]')"
check "live_note называет перезагрузку" grep -q 'перезагруз' <<< "$(mf 'm["targets"]["live_note"]')"
eq "provides" gpu-driver-nvidia "$(mf '" ".join(m["provides"])')"
eq "хуки" install "$(mf '" ".join(sorted(m["hooks"]))')"
check "install: явный timeout" test -n "$(mf 'm["hooks"]["install"]["timeout"]')"
eq "ключи" "NVIDIA_DRIVER_VERSION NVIDIA_KERNEL_MODULES NVIDIA_SOURCE" "$(mf '" ".join(sorted(m["config"]["keys"]))')"
eq "умолчания" "580 open archive" \
    "$(mf '" ".join(str(m["config"]["keys"][k]["default"]) for k in ("NVIDIA_DRIVER_VERSION","NVIDIA_KERNEL_MODULES","NVIDIA_SOURCE"))')"
eq "все ключи — scope install" "install install install" \
    "$(mf '" ".join(v["scope"] for v in m["config"]["keys"].values())')"
check "hooks/install исполняемый" test -x "$EXT/hooks/install"
check_not "layout 2: install.sh не остался" test -e "$EXT/install.sh"

echo "== нет ядер — 20 до apt =="
nv_root ubuntu 24.04
ht_hook install; eq "нет ядер — 20" 20 "$?"
check_not "нет ядер — apt не зовётся" ht_called '^apt-get'
check_not "нет ядер — blacklist не пишется" test -e "$BL"
nv_root ubuntu 24.04
mkdir -p "$ROOT/lib/modules/$K"
ht_hook install; eq "каталог ядра без vmlinuz — 20" 20 "$?"
nv_root ubuntu 24.04 "$K"
ht_hook install NVIDIA_DRIVER_VERSION=580.95.05; eq "полная версия вместо ветки — 1" 1 "$?"
check_not "неверная ветка — apt не зовётся" ht_called '^apt-get'
nv_root ubuntu 24.04 "$K"
ht_hook install 'NVIDIA_KERNEL_MODULES=open;x'; eq "чужой тип модулей — 1" 1 "$?"
nv_root ubuntu 24.04 'bad$(id)k'
ht_hook install; eq "ядро со странным именем — 1" 1 "$?"
check_not "странное ядро — apt не зовётся" ht_called '^apt-get'

echo "== Ubuntu 24.04: предсобранные модули Canonical =="
nv_root ubuntu 24.04 "$K"
ubuntu_driver
: > "$FAKE/avail/linux-modules-nvidia-580-open-$K"
ht_hook install; eq "первая установка — 10 (перезагрузка)" 10 "$?"
check "предсобранные модули и драйвер одним install" \
    ht_called "^apt-get .*install linux-modules-nvidia-580-open-$K linux-modules-nvidia-580-open-generic nvidia-driver-580-open\$"
check_not "DKMS не нужен" ht_called 'nvidia-dkms'
check "blacklist nouveau" grep -qx 'blacklist nouveau' "$BL"
check "nouveau modeset=0" grep -qx 'options nouveau modeset=0' "$BL"
check_not "в blacklist нет имени bisquite" grep -q bisquite "$BL"
eq "blacklist — 0644" 644 "$(stat -c %a "$BL")"
check "initramfs создан под ядро образа" ht_called "^update-initramfs -c -k $K\$"
check_not "initramfs не под uname" ht_called 'update-initramfs .*appliance'
check "depmod под ядро образа" ht_called "^depmod -a $K\$"
check "проверка modinfo под ядро образа" ht_called "^modinfo -k $K -F version nvidia\$"
snap="$(sha256sum < "$BL")"
: > "$ROOT/boot/initrd.img-$K"
: > "$FAKE/calls"
ht_hook install; eq "повтор — 0 (ничего не поменялось)" 0 "$?"
eq "повтор: blacklist тот же" "$snap" "$(sha256sum < "$BL")"
check "повтор: initrd есть — update-initramfs -u" ht_called "^update-initramfs -u -k $K\$"

echo "== Ubuntu: DKMS, когда предсобранного нет =="
nv_root ubuntu 24.04 "$K"
ubuntu_driver
echo 6.8.0-45.45 > "$FAKE/cand/linux-headers-$K"
echo "nvidia/580.95.05, $K, x86_64: installed" > "$FAKE/dkms-status"
ht_hook install; eq "DKMS — 10" 10 "$?"
check "заголовки ядра образа" ht_called "^apt-get .*install linux-headers-$K\$"
check "nvidia-dkms-580-open и драйвер" ht_called '^apt-get .*install nvidia-dkms-580-open nvidia-driver-580-open$'
check "dkms autoinstall под ядро образа" ht_called "^dkms autoinstall -k $K\$"
nv_root ubuntu 24.04 "$K"
ubuntu_driver
ht_hook install; eq "нет заголовков — 1" 1 "$?"
check "нет заголовков — сказано" grep -q "linux-headers-$K" <<< "$(ht_out)"

echo "== Ubuntu: отказы и PPA =="
nv_root ubuntu 24.04 "$K"
ht_hook install; eq "нет драйвера в архиве — 1" 1 "$?"
check "подсказка NVIDIA_SOURCE=ppa" grep -q 'NVIDIA_SOURCE=ppa' <<< "$(ht_out)"
check_not "отказ — blacklist не пишется" test -e "$BL"
nv_root ubuntu 20.04 "$K"
ht_hook install; eq "Ubuntu 20.04 — 1" 1 "$?"
nv_root ubuntu 24.04 "$K"
ubuntu_driver
echo 6.8.0-45.45 > "$FAKE/cand/linux-headers-$K"
echo 2388FF3BE10A76F638F80723FCAE110B1118213C > "$FAKE/fpr"
ht_hook install NVIDIA_SOURCE=ppa; eq "PPA — 10" 10 "$?"
PPA="$ROOT/etc/apt/sources.list.d/graphics-drivers-ppa.sources"
check "источник PPA deb822" grep -qx 'URIs: https://ppa.launchpadcontent.net/graphics-drivers/ppa/ubuntu' "$PPA"
check "источник PPA: сюита noble" grep -qx 'Suites: noble' "$PPA"
check "ключ PPA — экспорт, не скачанный файл" grep -q '^ARMORED' "$ROOT/etc/apt/keyrings/graphics-drivers-ppa.asc"
nv_root ubuntu 24.04 "$K"
ubuntu_driver
echo DEADBEEF > "$FAKE/fpr"
ht_hook install NVIDIA_SOURCE=ppa; eq "чужой отпечаток ключа PPA — 1" 1 "$?"
check_not "чужой ключ не лёг в keyring" test -e "$ROOT/etc/apt/keyrings/graphics-drivers-ppa.asc"

echo "== Debian 12: репозиторий CUDA =="
nv_root debian 12 "$DEB_K"
debian_driver
echo "nvidia/580.95.05, $DEB_K, x86_64: installed" > "$FAKE/dkms-status"
ht_hook install; eq "Debian 12 — 10" 10 "$?"
CUDA="$ROOT/etc/apt/sources.list.d/nvidia-cuda.sources"
check "источник CUDA debian12" grep -qx 'URIs: https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/' "$CUDA"
check "ключ CUDA — экспорт прибитого" grep -qx "ARMORED $CUDA12_FPR" "$ROOT/etc/apt/keyrings/nvidia-cuda.asc"
check "пакет закрепления ветки" ht_called '^apt-get .*install nvidia-driver-pinning-580$'
check "nvidia-open (open)" ht_called '^apt-get .*install nvidia-open$'
check "dkms autoinstall" ht_called "^dkms autoinstall -k $DEB_K\$"
nv_root debian 12 "$DEB_K"
debian_driver
echo 'deb [signed-by=/x] https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/ /' \
    > "$ROOT/etc/apt/sources.list.d/cuda-vendor.list"
ht_hook install; eq "свой источник CUDA уже есть — 10" 10 "$?"
check_not "второй источник не добавлен" test -e "$ROOT/etc/apt/sources.list.d/nvidia-cuda.sources"
nv_root debian 13 "$DEB_K"
debian_driver
rm -f "$FAKE/avail/nvidia-driver-pinning-580"
echo 'deb https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/ /' \
    > "$ROOT/etc/apt/sources.list.d/cuda-vendor.list"
ht_hook install; eq "Debian 13 без ветки 580 — 1" 1 "$?"
check "список веток в ошибке" grep -q '590' <<< "$(ht_out)"
nv_root debian 12 "$DEB_K"
debian_driver
ht_hook install NVIDIA_SOURCE=ppa; eq "Debian и ppa — 1" 1 "$?"

echo "== проверка результата =="
nv_root debian 12 "$DEB_K"
debian_driver
ht_hook install NVIDIA_KERNEL_MODULES=proprietary; eq "proprietary, а модуль Dual MIT/GPL — 1" 1 "$?"
check "proprietary: cuda-drivers" ht_called '^apt-get .*install cuda-drivers$'
nv_root debian 12 "$DEB_K"
debian_driver
echo 580.82.07 > "$FAKE/modver"
ht_hook install; eq "модуль и библиотека разных версий — 1" 1 "$?"
nv_root debian 12 "$DEB_K"
debian_driver
: > "$FAKE/no-module"
ht_hook install; eq "модуля под ядро нет — 1" 1 "$?"
nv_root debian 12 "$DEB_K"
debian_driver
rm -f "$ROOT/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.580.95.05"
ht_hook install; eq "нет libnvidia-ml — 1" 1 "$?"

echo "== ветка appliance: только build =="
nv_root ubuntu 24.04 "$K"
ubuntu_driver
: > "$FAKE/avail/linux-modules-nvidia-580-open-$K"
: > "$ROOT/boot/initrd.img-6.1.0-appliance"
HT_PHASE=build ht_hook install; eq "build — 10" 10 "$?"
check_not "build: initrd ядра appliance удалён" test -e "$ROOT/boot/initrd.img-6.1.0-appliance"
nv_root ubuntu 24.04 "$K"
ubuntu_driver
: > "$FAKE/avail/linux-modules-nvidia-580-open-$K"
: > "$ROOT/boot/initrd.img-6.1.0-appliance"
ht_hook install; eq "live — 10" 10 "$?"
check "live: чужой initrd не трогается" test -e "$ROOT/boot/initrd.img-6.1.0-appliance"
nv_root ubuntu 24.04 "$K"
ubuntu_driver
: > "$FAKE/avail/linux-modules-nvidia-580-open-$K"
echo "$K" > "$FAKE/uname"
: > "$ROOT/boot/initrd.img-$K"
HT_PHASE=build ht_hook install; eq "build, uname = ядро образа — 10" 10 "$?"
check "initrd ядра образа не удалён" test -e "$ROOT/boot/initrd.img-$K"

echo "== запись не идёт по ссылке =="
nv_root ubuntu 24.04 "$K"
ubuntu_driver
: > "$FAKE/avail/linux-modules-nvidia-580-open-$K"
echo victim > "$ROOT/victim"
ln -s "$ROOT/victim" "$BL"
ht_hook install; eq "blacklist был ссылкой — 10" 10 "$?"
eq "цель ссылки не тронута" victim "$(cat "$ROOT/victim")"
check_not "blacklist теперь не ссылка" test -L "$BL"
check "blacklist записан" grep -qx 'blacklist nouveau' "$BL"

ht_done
