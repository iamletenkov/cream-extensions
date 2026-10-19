#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the l4t-gstreamer extension (cream/v1): manifest, hook install
# (branches R36 — apt pinned to the L4T stack version, R32 — check only) and
# hook remove on a scratch root (CREAM_ROOT) the way cream runs them, with the
# library l4t laid down as cream does and fake apt-get, apt-cache and
# dpkg-query. root, network and a Jetson are not needed.
#
#   extensions/debian/l4t-gstreamer/tests/test-l4t-gstreamer.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
L4T="$EXT/../l4t"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

R36='# R36 (release), REVISION: 4.3, GCID: 38968081, BOARD: generic, EABI: aarch64, DATE: Wed Jan  8 01:49:37 UTC 2025'
R32='# R32 (release), REVISION: 6.1, GCID: 26953352, BOARD: t210ref, EABI: aarch64, DATE: Tue Mar  2 16:53:42 UTC 2021'
V=36.4.3-20250107174145
NV_PLUGINS=(libgstnvvideo4linux2 libgstnvvidconv libgstnvarguscamerasrc libgstnvv4l2camerasrc
    libgstnvcompositor libgstnvjpeg)
ALL_PLUGINS=("${NV_PLUGINS[@]}" libgstnice libgstwebrtc libgstx264 libgstximagesrc libgstrtsp)

# gs_root [RELEASE-LINE]: fresh root with the l4t library and fakes. Package
# database — $FAKE/pkgs/<pkg> (content — version); versions of
# nvidia-l4t-gstreamer in the repository — $FAKE/madison; nvidia-l4t-core
# after an install — $FAKE/core-after; packages a simulated remove would add —
# $FAKE/sim-extra.
gs_root() {
    ht_root "$EXT"
    mkdir -p "$FAKE/pkgs" "$ROOT/opt/cream/ext/l4t"
    cp "$L4T/l4t.sh" "$ROOT/opt/cream/ext/l4t/l4t.sh"
    if [[ -n "${1:-}" ]]; then
        mkdir -p "$ROOT/etc"
        printf '%s\n' "$1" > "$ROOT/etc/nv_tegra_release"
    fi
    GST="$ROOT/usr/lib/aarch64-linux-gnu/gstreamer-1.0"
    mkdir -p "$GST"
    printf '%s\n' 36.4.0-20240912212859 "$V" 36.4.7-20250918154033 > "$FAKE/madison"
    : > "$FAKE/sim-extra"
    ht_fake dpkg-query '
f="" p="${*: -1}"
for a in "$@"; do case "$a" in -f*) f="${a#-f}" ;; esac; done
[[ -e "$FAKE/pkgs/$p" ]] || exit 1
case "$f" in *Status-Status*) printf installed ;; *) cat "$FAKE/pkgs/$p" ;; esac'
    ht_fake apt-cache '
[[ "$1" == madison ]] || exit 0
while read -r v; do printf " %s | %s | https://repo.download.nvidia.com/jetson/common r36.4/main arm64 Packages\n" "$2" "$v"; done < "$FAKE/madison"'
    ht_fake apt-get '
sub="" sim=""
for a in "$@"; do
    case "$a" in -s) sim=1 ;; -*|Dpkg::*) ;; *) [[ -z "$sub" ]] && { sub="$a"; continue; }
        if [[ -n "$sim" ]]; then echo "Remv ${a%%=*} [1]"; continue; fi
        case "$a" in *=*) ver="${a#*=}" ;; *) ver=1.0 ;; esac
        case "$sub" in install) echo "$ver" > "$FAKE/pkgs/${a%%=*}" ;; remove|purge) rm -f "$FAKE/pkgs/$a" ;; esac ;;
    esac
done
[[ -n "$sim" ]] && cat "$FAKE/sim-extra"
[[ -e "$FAKE/apt-fails-$sub" ]] && exit 100
[[ "$sub" == install && -e "$FAKE/core-after" ]] && cp "$FAKE/core-after" "$FAKE/pkgs/nvidia-l4t-core"
exit 0'
    STATE="$ROOT/var/lib/cream/ext/l4t-gstreamer"
}
# plugins NAME…: plugin files in the GStreamer directory of the root.
plugins() { local s; for s in "$@"; do : > "$GST/$s.so"; done; }
# r36_image: the L4T 36.4.3 stack and every plugin the check looks for.
r36_image() { echo "$V" > "$FAKE/pkgs/nvidia-l4t-core"; plugins "${ALL_PLUGINS[@]}"; }
# r32_image: what the Q-engineering image of Jetson Nano carries.
r32_image() {
    echo 32.6.1-20210726122000 > "$FAKE/pkgs/nvidia-l4t-core"
    echo 32.6.1-20210916211029 > "$FAKE/pkgs/nvidia-l4t-gstreamer"
    plugins libgstnvvideo4linux2 libgstnvvidconv libgstnvarguscamerasrc
}
argv() { cat "$FAKE/apt-get.argv" 2>/dev/null; }
mf() { python3 -c 'import sys,yaml; m=yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }

echo "== манифест и раскладка =="
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 2" 2 "$(mf 'm["version"].split(".")[0]')"
eq "cream 1.0" ">=1.0.0" "$(mf 'm["cream"]')"
eq "только arm64" arm64 "$(mf '" ".join(m["platform"]["arch"])')"
eq "build: exec" exec "$(mf 'm["targets"]["build"]')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "provides" "gstreamer hw-video-codec" "$(mf '" ".join(m["provides"])')"
eq "depends l4t, apt-guard" "l4t >=1.0.0 <2 apt-guard >=1.0.0 <2" "$(mf '" ".join(d["name"] + " " + d["version"] for d in m["depends"])')"
eq "хуки" "install remove" "$(mf '" ".join(sorted(m["hooks"]))')"
check "install: явный timeout" test -n "$(mf 'm["hooks"]["install"]["timeout"]')"
eq "ключ GSTREAMER_DEV" "enum:0,1 1 install" \
    "$(mf '" ".join(str(m["config"]["keys"]["GSTREAMER_DEV"][k]) for k in ("type","default","scope"))')"
check "hooks/install исполняемый" test -x "$EXT/hooks/install"
check "hooks/remove исполняемый" test -x "$EXT/hooks/remove"
check_not "layout 2: install.sh не остался" test -e "$EXT/install.sh"
check_not "layout 2: библиотека не рядом со скриптом" grep -q 'SCRIPT_DIR' "$EXT/hooks/install"

echo "== не Jetson — 20 до apt; отказы до apt =="
gs_root
ht_hook install; eq "нет nv_tegra_release — 20" 20 "$?"
check_not "не Jetson — apt не зовётся" ht_called '^apt-get'
gs_root "$R36"
r36_image
ht_hook install GSTREAMER_DEV=2; eq "GSTREAMER_DEV=2 — 1" 1 "$?"
check_not "неверный ключ — apt не зовётся" ht_called '^apt-get'
gs_root "$R36"
r36_image
rm -f "$ROOT/opt/cream/ext/l4t/l4t.sh"
ht_hook install; eq "нет библиотеки l4t — 1" 1 "$?"
check_not "нет библиотеки — apt не зовётся" ht_called '^apt-get'
gs_root "$R36"
plugins "${ALL_PLUGINS[@]}"
ht_hook install; eq "нет nvidia-l4t-core — 1" 1 "$?"
check_not "нет стека — apt не зовётся" ht_called '^apt-get'
gs_root "$R36"
r36_image
echo '36.4.3;$(touch x)' > "$FAKE/pkgs/nvidia-l4t-core"
ht_hook install; eq "версия стека с чужими символами — 1" 1 "$?"
check_not "странная версия — apt не зовётся" ht_called '^apt-get'

echo "== R36: установка с dev =="
gs_root "$R36"
r36_image
ht_hook install; eq "R36 — 0" 0 "$?"
check "apt-get update" ht_called '^apt-get update'
check "плагины NVIDIA по версии стека" grep -q " nvidia-l4t-gstreamer=$V " <<< " $(argv) "
check "RTSP-сервер" grep -q ' libgstrtspserver-1.0-0 ' <<< " $(argv) "
check "libnice для WebRTC" grep -q ' gstreamer1.0-nice ' <<< " $(argv) "
check "dev: заголовки" grep -q ' libgstreamer1.0-dev ' <<< " $(argv) "
check "dev: Multimedia API по версии стека" grep -q " nvidia-l4t-jetson-multimedia-api=$V " <<< " $(argv) "
check "записаны имена без версии" grep -qx nvidia-l4t-gstreamer "$STATE/packages"
check "записан Multimedia API" grep -qx nvidia-l4t-jetson-multimedia-api "$STATE/packages"
check_not "в записи нет =версии" grep -q = "$STATE/packages"
check_not "в записи нет стека" grep -qx nvidia-l4t-core "$STATE/packages"
n="$(wc -l < "$STATE/packages")"
ht_hook install; eq "повтор — 0" 0 "$?"
eq "повтор: запись прежняя" "$n" "$(wc -l < "$STATE/packages")"

echo "== R36: без dev =="
gs_root "$R36"
r36_image
ht_hook install GSTREAMER_DEV=0; eq "GSTREAMER_DEV=0 — 0" 0 "$?"
check_not "без dev — нет заголовков" grep -q -- '-dev ' <<< " $(argv) "
check_not "без dev — нет Multimedia API" grep -q multimedia-api <<< "$(argv)"

echo "== R36: отказы после apt-get update =="
gs_root "$R36"
r36_image
printf '%s\n' 36.4.0-20240912212859 36.4.7-20250918154033 > "$FAKE/madison"
ht_hook install; eq "версии стека нет в репозитории — 1" 1 "$?"
check_not "нет версии — install не зовётся" ht_called '^apt-get install'
check "есть версии — сказано" grep -q '36.4.7' "$ROOT/out"
gs_root "$R36"
r36_image
rm -f "$GST/libgstnvjpeg.so"
ht_hook install; eq "нет плагина — 1" 1 "$?"
check "плагин назван" grep -q libgstnvjpeg "$ROOT/out"
gs_root "$R36"
r36_image
echo 36.4.7-20250918154033 > "$FAKE/core-after"
ht_hook install; eq "стек сдвинулся — 1" 1 "$?"

echo "== R32: проверка без установки =="
gs_root "$R32"
r32_image
ht_hook install; eq "R32 — 0" 0 "$?"
check_not "R32: apt не зовётся" ht_called '^apt-get'
check "R32: без libnice — предупреждение" grep -q 'libgstnice' "$ROOT/out"
check_not "R32: ничего не записано" test -e "$STATE/packages"
gs_root "$R32"
r32_image
echo 32.7.4-20230608212426 > "$FAKE/pkgs/nvidia-l4t-gstreamer"
ht_hook install; eq "R32: ревизии разошлись — 1" 1 "$?"
gs_root "$R32"
r32_image
rm -f "$GST/libgstnvvidconv.so"
ht_hook install; eq "R32: нет плагина — 1" 1 "$?"
gs_root "$R32"
r32_image
rm -f "$FAKE/pkgs/nvidia-l4t-gstreamer"
ht_hook install; eq "R32: нет nvidia-l4t-gstreamer — 1" 1 "$?"

echo "== remove =="
gs_root "$R36"
r36_image
echo 1.24.2-1 > "$FAKE/pkgs/gstreamer1.0-tools"
ht_hook install >/dev/null
check_not "чужой пакет не записан" grep -qx gstreamer1.0-tools "$STATE/packages"
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check "свои пакеты удалены" ht_called '^apt-get -q -y remove .*nvidia-l4t-gstreamer'
check_not "чужой пакет не удаляется" ht_called '^apt-get -q -y remove .*gstreamer1.0-tools'
check_not "стек не удаляется" ht_called '^apt-get -q -y remove .*nvidia-l4t-core'
check_not "запись снята" test -e "$STATE/packages"
: > "$FAKE/calls"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
check_not "повтор: apt не зовётся" ht_called '^apt-get .*remove'
gs_root "$R36"
r36_image
ht_hook install >/dev/null
echo 'Remv ubuntu-desktop [1.539]' > "$FAKE/sim-extra"
ht_hook remove; eq "apt снял бы чужой пакет — 1" 1 "$?"
check "чужой пакет назван" grep -q ubuntu-desktop "$ROOT/out"
check_not "remove не выполнен" ht_called '^apt-get -q -y remove'
check "запись осталась" test -s "$STATE/packages"

ht_done
