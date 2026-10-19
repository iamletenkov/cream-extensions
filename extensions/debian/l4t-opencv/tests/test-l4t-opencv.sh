#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the l4t-opencv extension (cream/v1): manifest, hook install
# (branches R36 — apt, R32 — check and OPENBLAS_CORETYPE) and hook remove on a
# scratch root (CREAM_ROOT) the way cream runs them, with the library l4t laid
# down as cream does and fake apt-get, dpkg-query, ldconfig and python3 (the
# library's own python3 calls go to the real one; cv2 of the R32 image is a
# stub module found through PYTHONPATH from the root's files). root, network
# and a Jetson are not needed.
#
#   extensions/debian/l4t-opencv/tests/test-l4t-opencv.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
L4T="$EXT/../l4t"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

R36='# R36 (release), REVISION: 4.3, GCID: 38968081, BOARD: generic, EABI: aarch64, DATE: Wed Jan  8 01:49:37 UTC 2025'
R32='# R32 (release), REVISION: 6.1, GCID: 26953352, BOARD: t210ref, EABI: aarch64, DATE: Tue Mar  2 16:53:42 UTC 2021'
INFO_OK=$'4.8.0\n  Video I/O:\n    GStreamer:                   YES (1.20.3)\n  NVIDIA CUDA:                   NO'

# cv_root [RELEASE-LINE]: fresh root with the l4t library and fakes. Package
# database — $FAKE/pkgs; cv2 build information — $FAKE/cv2-info; packages a
# simulated remove would add — $FAKE/sim-extra.
cv_root() {
    ht_root "$EXT"
    mkdir -p "$FAKE/pkgs" "$ROOT/opt/cream/ext/l4t" "$ROOT/etc"
    cp "$L4T/l4t.sh" "$ROOT/opt/cream/ext/l4t/l4t.sh"
    [[ -n "${1:-}" ]] && printf '%s\n' "$1" > "$ROOT/etc/nv_tegra_release"
    printf '%s\n' "$INFO_OK" > "$FAKE/cv2-info"
    : > "$FAKE/sim-extra"
    ht_fake dpkg-query '
f="" p="${*: -1}"
for a in "$@"; do case "$a" in -f*) f="${a#-f}" ;; esac; done
[[ -e "$FAKE/pkgs/$p" ]] || exit 1
case "$f" in *Status-Status*) printf installed ;; *) printf 4.8.0-1 ;; esac'
    ht_fake apt-get '
sub="" sim=""
for a in "$@"; do
    case "$a" in -s) sim=1 ;; -*|Dpkg::*) ;; *) [[ -z "$sub" ]] && { sub="$a"; continue; }
        if [[ -n "$sim" ]]; then echo "Remv ${a%%=*} [1]"; continue; fi
        case "$sub" in install) : > "$FAKE/pkgs/${a%%=*}" ;; remove|purge) rm -f "$FAKE/pkgs/$a" ;; esac ;;
    esac
done
[[ -n "$sim" ]] && cat "$FAKE/sim-extra"
[[ -e "$FAKE/apt-fails-$sub" ]] && exit 100
exit 0'
    ht_fake ldconfig
    # python3: the library reads files with `python3 - ROOT` — the real one;
    # cv2 of the hook — the stub output.
    ht_fake python3 '
if [[ "${1:-}" == -c && "${2:-}" == *getBuildInformation* ]]; then
    [[ -e "$FAKE/py-fails" ]] && { echo "ImportError: libopencv_ml.so.408" >&2; exit 1; }
    cat "$FAKE/cv2-info"; exit 0
fi
exec /usr/bin/python3 "$@"'
    STATE="$ROOT/var/lib/cream/ext/l4t-opencv"
    DROP="$ROOT/etc/systemd/system.conf.d/l4t-opencv.conf"
    ENVF="$ROOT/etc/environment"
}
# r32_image: OpenCV 4.8.0 of the Q-engineering image — a stub cv2 the
# library's check finds through PYTHONPATH taken from the root's files.
r32_image() {
    local py="$ROOT/pyfake"
    mkdir -p "$py" "$ROOT/etc/systemd/system.conf.d"
    printf 'import os\nassert os.environ.get("OPENBLAS_CORETYPE") == "ARMV8"\n__version__ = "4.8.0"\n' > "$py/cv2.py"
    echo "PYTHONPATH=$py" > "$ENVF"
    printf '[Manager]\nDefaultEnvironment=PYTHONPATH=%s\n' "$py" > "$ROOT/etc/systemd/system.conf.d/00-test.conf"
    printf '%s\n' "4.8.0" "  GStreamer:  YES (1.16.3)" "  NVIDIA CUDA:  YES (ver 10.2)" > "$FAKE/cv2-info"
}
mf() { python3 -c 'import sys,yaml; m=yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }

echo "== манифест и раскладка =="
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 2" 2 "$(mf 'm["version"].split(".")[0]')"
eq "cream 1.0" ">=1.0.0" "$(mf 'm["cream"]')"
eq "только arm64" arm64 "$(mf '" ".join(m["platform"]["arch"])')"
eq "build: exec" exec "$(mf 'm["targets"]["build"]')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "provides" opencv "$(mf '" ".join(m["provides"])')"
eq "depends l4t" "l4t >=1.0.0 <2" "$(mf '" ".join(d["name"] + " " + d["version"] for d in m["depends"])')"
eq "хуки" "install remove" "$(mf '" ".join(sorted(m["hooks"]))')"
check "install: явный timeout" test -n "$(mf 'm["hooks"]["install"]["timeout"]')"
check "hooks/install исполняемый" test -x "$EXT/hooks/install"
check "hooks/remove исполняемый" test -x "$EXT/hooks/remove"
check_not "layout 2: install.sh не остался" test -e "$EXT/install.sh"
check_not "layout 2: библиотека не рядом со скриптом" grep -q 'SCRIPT_DIR' "$EXT/hooks/install"

echo "== не Jetson — 20 до apt; отказы до apt =="
cv_root
ht_hook install; eq "нет nv_tegra_release — 20" 20 "$?"
check_not "не Jetson — apt не зовётся" ht_called '^apt-get'
cv_root "$R36"
rm -f "$ROOT/opt/cream/ext/l4t/l4t.sh"
ht_hook install; eq "нет библиотеки l4t — 1" 1 "$?"
check_not "нет библиотеки — apt не зовётся" ht_called '^apt-get'

echo "== R36: установка =="
cv_root "$R36"
ht_hook install; eq "R36 — 0" 0 "$?"
check "оба пакета явно" ht_called '^apt-get install .* libopencv libopencv-python$'
check "ldconfig" ht_called '^ldconfig ?$'
eq "свои пакеты записаны" "libopencv libopencv-python" "$(paste -sd' ' "$STATE/packages")"
check_not "R36: OPENBLAS не закрепляется" test -e "$DROP"
ht_hook install; eq "повтор — 0" 0 "$?"
eq "повтор: запись прежняя" "libopencv libopencv-python" "$(paste -sd' ' "$STATE/packages")"
cv_root "$R36"
: > "$FAKE/py-fails"
ht_hook install; eq "import cv2 упал — 1" 1 "$?"
check "причина в журнале" grep -q libopencv_ml "$ROOT/out"
cv_root "$R36"
printf '%s\n' 4.8.0 '  GStreamer:  NO' > "$FAKE/cv2-info"
ht_hook install; eq "cv2 без GStreamer — 1" 1 "$?"
cv_root "$R36"
: > "$FAKE/apt-fails-install"
ht_hook install; eq "apt install не прошёл — 1" 1 "$?"
check_not "отказ — запись не пишется" test -e "$STATE/packages"

echo "== R32: проверка и OPENBLAS_CORETYPE =="
cv_root "$R32"
r32_image
ht_hook install; eq "R32 — 0" 0 "$?"
check_not "R32: apt не зовётся" ht_called '^apt-get'
check "R32: /etc/environment" grep -qx 'OPENBLAS_CORETYPE=ARMV8' "$ENVF"
check "R32: drop-in служб" grep -qx 'DefaultEnvironment=OPENBLAS_CORETYPE=ARMV8' "$DROP"
check "R32: отметка закрепления" test -e "$STATE/openblas"
cv_root "$R32"
r32_image
printf '%s\n' 4.8.0 '  GStreamer:  YES' '  NVIDIA CUDA:  NO' > "$FAKE/cv2-info"
ht_hook install; eq "R32: cv2 без CUDA — 1" 1 "$?"
cv_root "$R32"
r32_image
rm -f "$ROOT/pyfake/cv2.py"
ht_hook install; eq "R32: cv2 не импортируется — 1" 1 "$?"

echo "== remove =="
cv_root "$R36"
: > "$FAKE/pkgs/libopencv"
ht_hook install >/dev/null
eq "чужой libopencv не записан" libopencv-python "$(paste -sd' ' "$STATE/packages")"
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check "свой пакет удалён" ht_called '^apt-get -q -y remove libopencv-python$'
check_not "запись снята" test -e "$STATE/packages"
: > "$FAKE/calls"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
check_not "повтор: apt не зовётся" ht_called '^apt-get .*remove'
cv_root "$R36"
ht_hook install >/dev/null
echo 'Remv my-vision-app [1.0]' > "$FAKE/sim-extra"
ht_hook remove; eq "apt снял бы чужой пакет — 1" 1 "$?"
check "чужой пакет назван" grep -q my-vision-app "$ROOT/out"
check_not "remove не выполнен" ht_called '^apt-get -q -y remove'

echo "== remove: OPENBLAS_CORETYPE снимается, пока он больше никому не нужен =="
cv_root "$R32"
r32_image
ht_hook install >/dev/null
ht_hook remove; eq "R32 remove — 0" 0 "$?"
check_not "drop-in снят" test -e "$DROP"
check_not "строка /etc/environment снята" grep -q OPENBLAS_CORETYPE "$ENVF"
check "чужая строка /etc/environment осталась" grep -q '^PYTHONPATH=' "$ENVF"
check_not "отметка снята" test -e "$STATE/openblas"
cv_root "$R32"
r32_image
ht_hook install >/dev/null
printf '[Manager]\nDefaultEnvironment=OPENBLAS_CORETYPE=ARMV8\n' > "$ROOT/etc/systemd/system.conf.d/l4t-pytorch.conf"
ht_hook remove; eq "R32 remove при l4t-pytorch — 0" 0 "$?"
check_not "свой drop-in снят" test -e "$DROP"
check "строка нужна l4t-pytorch — осталась" grep -qx 'OPENBLAS_CORETYPE=ARMV8' "$ENVF"
cv_root "$R32"
r32_image
ht_hook install >/dev/null
echo secret > "$ROOT/target"
rm -f "$ENVF"; ln -s ../target "$ENVF"
ht_hook remove; eq "R32 remove, /etc/environment — ссылка — 0" 0 "$?"
eq "цель ссылки не тронута" secret "$(cat "$ROOT/target")"

ht_done
