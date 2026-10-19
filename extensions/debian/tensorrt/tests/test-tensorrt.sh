#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the tensorrt extension (cream/v1): manifest, hook install (branches
# R36 — apt, R32 — check only) and hook remove on a scratch root (CREAM_ROOT)
# the way cream runs them, with the library l4t laid down as cream does and
# fake apt-get, dpkg-query, ldconfig and python3. root, network and a Jetson
# are not needed.
#
#   extensions/debian/tensorrt/tests/test-tensorrt.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
L4T="$EXT/../l4t"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

R36='# R36 (release), REVISION: 4.3, GCID: 38968081, BOARD: generic, EABI: aarch64, DATE: Wed Jan  8 01:49:37 UTC 2025'
R32='# R32 (release), REVISION: 6.1, GCID: 26953352, BOARD: t210ref, EABI: aarch64, DATE: Tue Mar  2 16:53:42 UTC 2021'

# trt_root [RELEASE-LINE]: fresh root with the l4t library and fakes; a release
# line writes /etc/nv_tegra_release and the jetson/common source list. Package
# database — $FAKE/pkgs/<pkg> (content — version); ldconfig -p prints
# $FAKE/ldcache; packages a simulated remove would add — $FAKE/sim-extra.
trt_root() {
    ht_root "$EXT"
    mkdir -p "$FAKE/pkgs" "$ROOT/opt/cream/ext/l4t"
    cp "$L4T/l4t.sh" "$ROOT/opt/cream/ext/l4t/l4t.sh"
    if [[ -n "${1:-}" ]]; then
        mkdir -p "$ROOT/etc/apt/sources.list.d"
        printf '%s\n' "$1" > "$ROOT/etc/nv_tegra_release"
        echo 'deb https://repo.download.nvidia.com/jetson/common r36.4 main' \
            > "$ROOT/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"
    fi
    : > "$FAKE/sim-extra"
    : > "$FAKE/ldcache"
    ht_fake dpkg-query '
f="" p="${*: -1}"
for a in "$@"; do case "$a" in -f*) f="${a#-f}" ;; esac; done
[[ -e "$FAKE/pkgs/$p" ]] || exit 1
case "$f" in *Status-Status*) printf installed ;; *) cat "$FAKE/pkgs/$p" ;; esac'
    ht_fake apt-get '
sub="" sim=""
for a in "$@"; do
    case "$a" in -s) sim=1 ;; -*|Dpkg::*) ;; *) [[ -z "$sub" ]] && { sub="$a"; continue; }
        if [[ -n "$sim" ]]; then echo "Remv ${a%%=*} [1]"; continue; fi
        case "$sub" in install) echo 10.3.0.30-1+cuda12.5 > "$FAKE/pkgs/${a%%=*}" ;; remove|purge) rm -f "$FAKE/pkgs/$a" ;; esac ;;
    esac
done
[[ -n "$sim" ]] && cat "$FAKE/sim-extra"
[[ -e "$FAKE/apt-fails-$sub" ]] && exit 100
[[ "$sub" == install && ! -e "$FAKE/no-dla" ]] &&
    echo "	libnvdla_compiler.so (libc6,AArch64) => /usr/lib/aarch64-linux-gnu/nvidia/libnvdla_compiler.so" >> "$FAKE/ldcache"
exit 0'
    ht_fake ldconfig '[[ "${1:-}" == -p ]] && cat "$FAKE/ldcache"; exit 0'
    ht_fake python3 '[[ -e "$FAKE/py-ok" ]]'
    STATE="$ROOT/var/lib/cream/ext/tensorrt"
}
# r32_image: what the Q-engineering image of Jetson Nano carries.
r32_image() {
    echo 8.0.1-1+cuda10.2 > "$FAKE/pkgs/libnvinfer8"
    mkdir -p "$ROOT/usr/src/tensorrt/bin"
    printf '#!/bin/sh\n' > "$ROOT/usr/src/tensorrt/bin/trtexec"
    chmod +x "$ROOT/usr/src/tensorrt/bin/trtexec"
    echo "	libnvinfer.so.8 (libc6,AArch64) => /usr/lib/aarch64-linux-gnu/libnvinfer.so.8" > "$FAKE/ldcache"
}
mf() { python3 -c 'import sys,yaml; m=yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }

echo "== манифест и раскладка =="
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 2" 2 "$(mf 'm["version"].split(".")[0]')"
eq "cream 1.0" ">=1.0.0" "$(mf 'm["cream"]')"
eq "только arm64" arm64 "$(mf '" ".join(m["platform"]["arch"])')"
eq "build: exec" exec "$(mf 'm["targets"]["build"]')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "provides" tensorrt "$(mf '" ".join(m["provides"])')"
eq "depends l4t, apt-guard" "l4t >=1.0.0 <2 apt-guard >=1.0.0 <2" "$(mf '" ".join(d["name"] + " " + d["version"] for d in m["depends"])')"
eq "хуки" "install remove" "$(mf '" ".join(sorted(m["hooks"]))')"
check "install: явный timeout" test -n "$(mf 'm["hooks"]["install"]["timeout"]')"
check "hooks/install исполняемый" test -x "$EXT/hooks/install"
check "hooks/remove исполняемый" test -x "$EXT/hooks/remove"
check_not "layout 2: install.sh не остался" test -e "$EXT/install.sh"
check_not "layout 2: библиотека не рядом со скриптом" grep -q 'SCRIPT_DIR' "$EXT/hooks/install"

echo "== не Jetson — 20 до apt =="
trt_root
ht_hook install; eq "нет nv_tegra_release — 20" 20 "$?"
check_not "не Jetson — apt не зовётся" ht_called '^apt-get'
trt_root "$R36"
rm -f "$ROOT/opt/cream/ext/l4t/l4t.sh"
ht_hook install; eq "нет библиотеки l4t — 1" 1 "$?"
check "нет библиотеки — сказано" grep -q 'l4t' "$ROOT/out"
check_not "нет библиотеки — apt не зовётся" ht_called '^apt-get'

echo "== R36: установка =="
trt_root "$R36"
ht_hook install; eq "R36 — 0" 0 "$?"
check "apt-get update" ht_called '^apt-get update'
check "tensorrt, биндинги и компилятор DLA" \
    ht_called '^apt-get install .* tensorrt python3-libnvinfer nvidia-l4t-dla-compiler$'
check "ldconfig явно" ht_called '^ldconfig ?$'
eq "свои пакеты записаны" "nvidia-l4t-dla-compiler python3-libnvinfer tensorrt" \
    "$(paste -sd' ' "$STATE/packages")"
: > "$FAKE/calls"
ht_hook install; eq "повтор — 0" 0 "$?"
eq "повтор: запись прежняя" "nvidia-l4t-dla-compiler python3-libnvinfer tensorrt" \
    "$(paste -sd' ' "$STATE/packages")"

echo "== R36: отказы =="
trt_root "$R36"
rm -f "$ROOT/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"
ht_hook install; eq "без jetson/common — 1" 1 "$?"
check_not "без источника — apt не зовётся" ht_called '^apt-get'
trt_root "$R36"
: > "$FAKE/no-dla"
ht_hook install; eq "libnvdla_compiler.so не виден — 1" 1 "$?"
check "сказано про libnvdla_compiler" grep -q libnvdla_compiler "$ROOT/out"
trt_root "$R36"
: > "$FAKE/apt-fails-install"
ht_hook install; eq "apt install не прошёл — 1" 1 "$?"
check_not "отказ — запись не пишется" test -e "$STATE/packages"

echo "== R36: часть пакетов стояла до cream =="
trt_root "$R36"
echo 10.3.0.30-1+cuda12.5 > "$FAKE/pkgs/tensorrt"
ht_hook install; eq "чужой tensorrt — 0" 0 "$?"
eq "записаны только свои" "nvidia-l4t-dla-compiler python3-libnvinfer" "$(paste -sd' ' "$STATE/packages")"

echo "== R32: проверка без установки =="
trt_root "$R32"
r32_image
ht_hook install; eq "R32 — 0" 0 "$?"
check_not "R32: apt не зовётся" ht_called '^apt-get'
check "R32: про Python-модуль сказано" grep -q 'Python-модуля tensorrt' "$ROOT/out"
check_not "R32: ничего не записано" test -e "$STATE/packages"
trt_root "$R32"
r32_image
: > "$FAKE/py-ok"
ht_hook install; eq "R32 с модулем — 0" 0 "$?"
check "R32: модуль найден" grep -q 'Python-модуль tensorrt есть' "$ROOT/out"
trt_root "$R32"
r32_image
rm -f "$FAKE/pkgs/libnvinfer8"
ht_hook install; eq "R32 без libnvinfer8 — 1" 1 "$?"
trt_root "$R32"
r32_image
rm -f "$ROOT/usr/src/tensorrt/bin/trtexec"
ht_hook install; eq "R32 без trtexec — 1" 1 "$?"
trt_root "$R32"
r32_image
: > "$FAKE/ldcache"
ht_hook install; eq "R32: libnvinfer.so.8 не виден — 1" 1 "$?"

echo "== remove =="
trt_root "$R36"
ht_hook install >/dev/null
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check "свои пакеты удалены" \
    ht_called '^apt-get -q -y remove nvidia-l4t-dla-compiler python3-libnvinfer tensorrt$'
check_not "запись снята" test -e "$STATE/packages"
: > "$FAKE/calls"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
check_not "повтор: apt не зовётся" ht_called '^apt-get .*remove'
trt_root "$R36"
ht_hook install >/dev/null
echo 'Remv deepstream-7.1 [7.1]' > "$FAKE/sim-extra"
ht_hook remove; eq "apt снял бы чужой пакет — 1" 1 "$?"
check "чужой пакет назван" grep -q deepstream "$ROOT/out"
check_not "remove не выполнен" ht_called '^apt-get -q -y remove'
check "запись осталась" test -s "$STATE/packages"

ht_done
