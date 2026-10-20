#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the l4t-pytorch extension (cream/v1): manifest, pip-owned.py on
# fixture dist-info directories, hook install (branches R36 — apt, cuSPARSELt,
# the torch wheel, torchvision from source; R32 — check and OPENBLAS_CORETYPE)
# and hook remove on a scratch root (CREAM_ROOT) the way cream runs them, with
# the library l4t laid down as cream does and fake apt-get, dpkg-query, curl,
# sha256sum, tar, git, ldconfig and python3 (pip and the import checks are
# fakes; the library and pip-owned.py run on the real python3). root, network
# and a Jetson are not needed.
#
#   extensions/debian/l4t-pytorch/tests/test-l4t-pytorch.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
L4T="$EXT/../l4t"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

R36='# R36 (release), REVISION: 4.3, GCID: 38968081, BOARD: generic, EABI: aarch64, DATE: Wed Jan  8 01:49:37 UTC 2025'
R32='# R32 (release), REVISION: 6.1, GCID: 26953352, BOARD: t210ref, EABI: aarch64, DATE: Tue Mar  2 16:53:42 UTC 2021'
VISION_COMMIT=afc54f754c734d903a06194e416495e20d920ff6

# dist SITE NAME [REQUIRES…]: a fixture dist-info directory.
dist() {
    local site="$1" name="$2" r
    shift 2
    mkdir -p "$site/$name-1.0.dist-info"
    { echo "Metadata-Version: 2.1"; echo "Name: $name"; echo "Version: 1.0"
      for r in "$@"; do echo "Requires-Dist: $r"; done; } > "$site/$name-1.0.dist-info/METADATA"
}

# pt_root [RELEASE-LINE]: fresh root with the l4t library, CUDA and fakes.
# Package database — $FAKE/pkgs; site of pip — $SITE; requirements a fake
# `pip install` gives a distribution — $FAKE/req/<name>.
pt_root() {
    ht_root "$EXT"
    mkdir -p "$FAKE/pkgs" "$FAKE/req" "$ROOT/opt/cream/ext/l4t" "$ROOT/etc" "$ROOT/usr/local/cuda/bin" "$ROOT/var/tmp"
    cp "$L4T/l4t.sh" "$ROOT/opt/cream/ext/l4t/l4t.sh"
    [[ -n "${1:-}" ]] && printf '%s\n' "$1" > "$ROOT/etc/nv_tegra_release"
    printf '#!/bin/sh\n' > "$ROOT/usr/local/cuda/bin/nvcc"; chmod +x "$ROOT/usr/local/cuda/bin/nvcc"
    SITE="$ROOT/usr/local/lib/python3.10/dist-packages"
    mkdir -p "$SITE"
    echo 3.10 > "$FAKE/pyver"
    echo "$VISION_COMMIT" > "$FAKE/vision-commit"
    : > "$FAKE/sim-extra"
    echo 'numpy' > "$FAKE/req/torch"
    echo 'torch' > "$FAKE/req/torchvision"
    ht_fake dpkg-query '
f="" p="${*: -1}"
for a in "$@"; do case "$a" in -f*) f="${a#-f}" ;; esac; done
[[ -e "$FAKE/pkgs/$p" ]] || exit 1
case "$f" in *Status-Status*) printf installed ;; *) printf 1.0 ;; esac'
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
    ht_fake curl '
out=""
while (( $# )); do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
echo data > "$out"'
    ht_fake sha256sum 'cat > /dev/null; [[ ! -e "$FAKE/sha-bad" ]]'
    ht_fake tar '
d=""
while (( $# )); do case "$1" in -C) d="$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "$d/lib"; : > "$d/lib/libcusparseLt.so.0"'
    ht_fake git '
if [[ "$1" == clone ]]; then mkdir -p "${*: -1}"; exit 0; fi
if [[ "$1" == -C && "$3" == rev-parse ]]; then cat "$FAKE/vision-commit"; exit 0; fi
exit 1'
    ht_fake ldconfig
    printf -v site_q '%q' "$SITE"
    ht_fake python3 "SITE=$site_q"'
case "${1:-}" in
    */pip-owned.py|*/check-system-python.py)
        [[ "$1" == */check-system-python.py ]] && { [[ -e "$FAKE/syspy-fails" ]] && exit 1; exit 0; }
        exec /usr/bin/python3 "$@" ;;
    -c) if [[ "$2" == *version_info* ]]; then cat "$FAKE/pyver"; exit 0; fi
        exec /usr/bin/python3 "$@" ;;
    -) if (( $# > 1 )); then exec /usr/bin/python3 "$@"; fi
       cat > /dev/null; [[ ! -e "$FAKE/import-fails" ]]; exit ;;
    -m) ;;
    *) exec /usr/bin/python3 "$@" ;;
esac
shift 2   # -m pip
echo "HOME=${HOME:-} PIP_CONFIG_FILE=${PIP_CONFIG_FILE:-} PIP_USER=${PIP_USER:-}" >> "$FAKE/pip-env"
sub="$1"; shift
case "$sub" in
    install)
        [[ -e "$FAKE/pip-fails" ]] && exit 1
        while (( $# )); do
            case "$1" in
                --constraint|-c) shift 2; continue ;;
                -r) cat "$2" >> "$FAKE/pip-reqs"
                    for n in $(grep -v -e "^[[:space:]]*#" -e "^[[:space:]]*--" -e "^[[:space:]]*$" "$2" | sed -e "s/[ =@].*//"); do
                        mkdir -p "$SITE/$n-1.0.dist-info"
                        { echo "Name: $n"; echo "Version: 1.0"
                          [[ -f "$FAKE/req/$n" ]] && sed "s/^/Requires-Dist: /" "$FAKE/req/$n"; } > "$SITE/$n-1.0.dist-info/METADATA"
                    done
                    shift 2; continue ;;
                -*) shift; continue ;;
                *.whl) n="$(basename "$1")"; n="${n%%-*}" ;;
                *) n="$1" ;;
            esac
            mkdir -p "$SITE/$n-1.0.dist-info"
            { echo "Name: $n"; echo "Version: 1.0"
              [[ -f "$FAKE/req/$n" ]] && sed "s/^/Requires-Dist: /" "$FAKE/req/$n"; } > "$SITE/$n-1.0.dist-info/METADATA"
            shift
        done ;;
    wheel)
        echo "MAX_JOBS=${MAX_JOBS:-} FORCE_CUDA=${FORCE_CUDA:-} TORCH_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST:-}" > "$FAKE/build-env"
        [[ -e "$FAKE/build-fails" ]] && { echo "nvcc fatal: died"; exit 1; }
        w=""; while (( $# )); do case "$1" in -w) w="$2"; shift 2 ;; *) shift ;; esac; done
        mkdir -p "$w"; : > "$w/torchvision-0.20.0-cp310-cp310-linux_aarch64.whl" ;;
    uninstall)
        for a in "$@"; do [[ "$a" == -* ]] || rm -rf "$SITE/$a-1.0.dist-info"; done ;;
esac
exit 0'
    STATE="$ROOT/var/lib/cream/ext/l4t-pytorch"
}
# r32_image: PyTorch 1.13 of the Q-engineering image — stub modules the
# library's check finds through PYTHONPATH taken from the root's files.
r32_image() {
    local py="$ROOT/pyfake"
    mkdir -p "$py/torch" "$ROOT/etc/systemd/system.conf.d"
    printf '__version__ = "1.23.5"\n' > "$py/numpy.py"
    printf '__version__ = "0.14.1"\n' > "$py/torchvision.py"
    printf 'from . import version\n__version__ = "1.13.0"\n' > "$py/torch/__init__.py"
    printf 'cuda = "%s"\n' "${1-10.2}" > "$py/torch/version.py"
    echo "PYTHONPATH=$py" > "$ROOT/etc/environment"
    printf '[Manager]\nDefaultEnvironment=PYTHONPATH=%s\n' "$py" > "$ROOT/etc/systemd/system.conf.d/00-test.conf"
}
pip_calls() { grep -E '^python3 -m pip install' "$FAKE/calls"; }
mf() { python3 -c 'import sys,yaml; m=yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }

echo "== манифест и раскладка =="
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 2" 2 "$(mf 'm["version"].split(".")[0]')"
eq "cream 1.0" ">=1.0.0" "$(mf 'm["cream"]')"
eq "только arm64" arm64 "$(mf '" ".join(m["platform"]["arch"])')"
eq "build: exec" exec "$(mf 'm["targets"]["build"]')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "provides" pytorch "$(mf '" ".join(m["provides"])')"
eq "requires cuda" cuda "$(mf '" ".join(m["requires"])')"
eq "depends l4t, apt-guard" "l4t >=1.0.0 <2 apt-guard >=1.0.0 <2" "$(mf '" ".join(d["name"] + " " + d["version"] for d in m["depends"])')"
eq "хуки" "install remove" "$(mf '" ".join(sorted(m["hooks"]))')"
check "install: timeout с запасом (≥ 2 ч)" python3 -c '
import re, sys, yaml
t = yaml.safe_load(open(sys.argv[1]))["hooks"]["install"]["timeout"]
n, u = re.fullmatch(r"(\d+)([mh])", t).groups()
sys.exit(0 if int(n) * (60 if u == "h" else 1) >= 120 else 1)' "$EXT/extension.yaml"
eq "ключ TORCH_CUDA_ARCH_LIST" "8.7 install" \
    "$(mf '" ".join(str(m["config"]["keys"]["TORCH_CUDA_ARCH_LIST"][k]) for k in ("default","scope"))')"
check "requirements.txt в дереве" test -f "$EXT/requirements.txt"
check_not "constraints.txt убран" test -e "$EXT/constraints.txt"
check "requirements.txt: каждый пакет — == и хотя бы один sha256" python3 - "$EXT/requirements.txt" <<'PY2'
import re, sys
text = re.sub(r"\\\n", " ", open(sys.argv[1]).read())
reqs = [" ".join(l.split("#")[0].split()) for l in text.splitlines()]
reqs = [r for r in reqs if r]
assert reqs
for r in reqs:
    assert re.fullmatch(r"[A-Za-z0-9_.-]+==[A-Za-z0-9_.+!-]+( --hash=sha256:[0-9a-f]{64})+", r), r
PY2
check "check-system-python.py в дереве" test -f "$EXT/check-system-python.py"
check "pip-owned.py в дереве" test -f "$EXT/pip-owned.py"
check "hooks/install исполняемый" test -x "$EXT/hooks/install"
check "hooks/remove исполняемый" test -x "$EXT/hooks/remove"
check_not "layout 2: install.sh не остался" test -e "$EXT/install.sh"
check_not "layout 2: библиотека не рядом со скриптом" grep -q 'SCRIPT_DIR' "$EXT/hooks/install"

echo "== pip-owned.py =="
ht_root "$EXT"
S="$ROOT/usr/local/lib/python3.10/dist-packages"
dist "$S" torch numpy 'sympy; extra == "opt"'
dist "$S" numpy
dist "$S" sympy
dist "$S" Typing_Extensions
dist "$S" tensorflow 'numpy>=1.23.5'
po() { CREAM_ROOT="$ROOT" python3 "$EXT/pip-owned.py" "$@"; }
eq "list — нормализованные имена" "numpy sympy tensorflow torch typing-extensions" "$(po list | paste -sd' ')"
check "has torch" po has torch
check_not "has scipy" po has scipy
printf '%s\n' torch numpy sympy typing_extensions scipy > "$ROOT/ours"
eq "removable: numpy нужен tensorflow, extra не в счёт, scipy нет" "sympy torch typing-extensions" \
    "$(po removable "$ROOT/ours" 2>/dev/null | paste -sd' ')"
rm -rf "$S/tensorflow-1.0.dist-info"
eq "removable без tensorflow" "numpy sympy torch typing-extensions" "$(po removable "$ROOT/ours" 2>/dev/null | paste -sd' ')"

echo "== не Jetson — 20; отказы до apt =="
pt_root
ht_hook install; eq "нет nv_tegra_release — 20" 20 "$?"
check_not "не Jetson — apt не зовётся" ht_called '^apt-get'
pt_root "$R36"
ht_hook install 'TORCH_CUDA_ARCH_LIST=8.7;$(id)'; eq "чужой TORCH_CUDA_ARCH_LIST — 1" 1 "$?"
check_not "неверный ключ — apt не зовётся" ht_called '^apt-get'
pt_root "$R36"
rm -f "$ROOT/opt/cream/ext/l4t/l4t.sh"
ht_hook install; eq "нет библиотеки l4t — 1" 1 "$?"
pt_root "$R36"
rm -f "$ROOT/usr/local/cuda/bin/nvcc"
ht_hook install; eq "нет nvcc (cuda-toolkit) — 1" 1 "$?"
check "подсказка cuda-toolkit" grep -q cuda-toolkit "$ROOT/out"
check_not "нет nvcc — apt не зовётся" ht_called '^apt-get'
pt_root "$R36"
echo 3.8 > "$FAKE/pyver"
ht_hook install; eq "Python 3.8 — 1" 1 "$?"
pt_root "$R36"
echo 3.100 > "$FAKE/pyver"
ht_hook install; eq "Python 3.100 — не 3.10, 1" 1 "$?"

echo "== R36: установка =="
pt_root "$R36"
mkdir -p "$ROOT/proc"; echo 'MemAvailable:    8388608 kB' > "$ROOT/proc/meminfo"
ht_hook install; eq "R36 — 0" 0 "$?"
check "cuDNN и сборочные пакеты" ht_called '^apt-get install .* libcudnn9-cuda-12 .*ninja-build'
check "cuSPARSELt распакован" test -f "$ROOT/usr/local/cusparselt/lib/libcusparseLt.so.0"
eq "ld.so.conf cuSPARSELt" /usr/local/cusparselt/lib "$(cat "$ROOT/etc/ld.so.conf.d/cusparselt.conf")"
check "pip install из сети — по хешам requirements.txt" \
    test "$(pip_calls | grep -vc -- '--no-index')" = "$(pip_calls | grep -c -- '--require-hashes -r .*/requirements.txt')"
check_not "pip без --constraint" grep -q -- '--constraint' "$FAKE/calls"
check "pip wheel torchvision — без индекса" ht_called '^python3 -m pip wheel .*--no-index'
check "torchvision ставится без индекса и зависимостей" \
    ht_called '^python3 -m pip install .*--no-index --no-deps .*torchvision-0\.20\.0.*\.whl'
check "torch — файлом с sha256 колеса NVIDIA" \
    grep -qE "^torch @ file://$ROOT/var/tmp/l4t-pytorch\.[^ ]+/torch-2\.5\.0a0[^ ]*\.whl --hash=sha256:6f75fd2d2ef840ede1a90dbcf40a5458214bee26cc803fa510cda2e8978d972a$" "$FAKE/pip-reqs"
check "pip install был" test -n "$(pip_calls)"
check_not "pip без --user" grep -q -- '--user' "$FAKE/calls"
check_not "pip: HOME не /root" grep -q 'HOME=/root' "$FAKE/pip-env"
check "pip: HOME во временном каталоге" grep -q "HOME=$ROOT/var/tmp/" "$FAKE/pip-env"
check "pip: конфиг pip не читается" grep -q 'PIP_CONFIG_FILE=/dev/null' "$FAKE/pip-env"
check "torch поставлен" test -d "$SITE/torch-1.0.dist-info"
check "torchvision собран с CUDA 8.7" grep -q 'FORCE_CUDA=1 TORCH_CUDA_ARCH_LIST=8.7' "$FAKE/build-env"
check "MAX_JOBS по памяти (8 ГБ — 5, не больше ядер)" grep -qE "MAX_JOBS=($(( $(nproc) < 5 ? $(nproc) : 5 )))( |$)" "$FAKE/build-env"
check "torchvision поставлен" ht_called '^python3 -m pip install .*torchvision-0\.20\.0.*\.whl'
check "pip-записи: torch, torchvision, numpy" grep -qx torchvision "$STATE/pip"
check "apt-записи" grep -qx libcudnn9-cuda-12 "$STATE/packages"
check "отметка cuSPARSELt" test -e "$STATE/cusparselt"
check_not "временный каталог убран" compgen -G "$ROOT/var/tmp/l4t-pytorch.*"
n="$(wc -l < "$STATE/pip")"
ht_hook install; eq "повтор — 0" 0 "$?"
eq "повтор: pip-запись прежняя" "$n" "$(wc -l < "$STATE/pip")"

echo "== R36: странная память — один поток =="
pt_root "$R36"
mkdir -p "$ROOT/proc"; echo 'MemAvailable: $(touch x) kB' > "$ROOT/proc/meminfo"
ht_hook install; eq "мусор в meminfo — 0" 0 "$?"
check "MAX_JOBS=1" grep -q 'MAX_JOBS=1 ' "$FAKE/build-env"

echo "== R36: отказы =="
pt_root "$R36"
: > "$FAKE/sha-bad"
ht_hook install; eq "sha256 не совпал — 1" 1 "$?"
check_not "сумма не та — pip не зовётся" ht_called '^python3 -m pip install'
pt_root "$R36"
echo 0000000000000000000000000000000000000000 > "$FAKE/vision-commit"
ht_hook install; eq "тег torchvision передвинут — 1" 1 "$?"
check_not "чужой коммит — сборки нет" test -e "$FAKE/build-env"
check "torch записан и при отказе" grep -qx torch "$STATE/pip"
pt_root "$R36"
: > "$FAKE/build-fails"
ht_hook install; eq "сборка torchvision упала — 1" 1 "$?"
check "хвост журнала сборки" grep -q 'nvcc fatal' "$ROOT/out"
pt_root "$R36"
: > "$FAKE/import-fails"
ht_hook install; eq "проверка импорта — 1" 1 "$?"
pt_root "$R36"
: > "$FAKE/syspy-fails"
ht_hook install; eq "системный Python поврежден — 1" 1 "$?"

echo "== R32: проверка и OPENBLAS_CORETYPE =="
pt_root "$R32"
rm -f "$ROOT/usr/local/cuda/bin/nvcc"
r32_image
ht_hook install; eq "R32 — 0 (nvcc не нужен)" 0 "$?"
check_not "R32: apt не зовётся" ht_called '^apt-get'
check_not "R32: pip не зовётся" ht_called '^python3 -m pip'
check "R32: drop-in служб" grep -qx 'DefaultEnvironment=OPENBLAS_CORETYPE=ARMV8' "$ROOT/etc/systemd/system.conf.d/l4t-pytorch.conf"
pt_root "$R32"
r32_image ""
ht_hook install; eq "R32: torch без CUDA — 1" 1 "$?"

echo "== remove =="
pt_root "$R36"
dist "$SITE" pillow
: > "$FAKE/pkgs/git"
ht_hook install >/dev/null
check_not "чужой pillow не записан" grep -qx pillow "$STATE/pip"
check_not "чужой git не записан" grep -qx git "$STATE/packages"
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check "pip uninstall своих" ht_called '^python3 -m pip uninstall -y .*torchvision'
check_not "pip uninstall не трогает чужой pillow" ht_called '^python3 -m pip uninstall .*pillow'
check "apt remove своих" ht_called '^apt-get -q -y remove .*libcudnn9-cuda-12'
check_not "apt не трогает чужой git" ht_called '^apt-get -q -y remove .* git( |$)'
check_not "cuSPARSELt снят" test -e "$ROOT/usr/local/cusparselt"
check_not "ld.so.conf снят" test -e "$ROOT/etc/ld.so.conf.d/cusparselt.conf"
check_not "записи сняты" test -e "$STATE/pip"
: > "$FAKE/calls"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
check_not "повтор: ни apt, ни pip" ht_called '(^apt-get .*remove|pip uninstall)'

echo "== remove при l4t-tensorflow =="
pt_root "$R36"
ht_hook install >/dev/null
dist "$SITE" tensorflow numpy
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "numpy нужен tensorflow — остаётся" ht_called '^python3 -m pip uninstall .* numpy( |$)'
check_not "cuDNN нужен tensorflow — остаётся" ht_called '^apt-get -q -y remove .*libcudnn9-cuda-12'
check_not "python3-pip нужен tensorflow — остаётся" ht_called '^apt-get -q -y remove .*python3-pip'
check "torch снят" ht_called '^python3 -m pip uninstall -y .*torch( |$)'

echo "== remove не уносит чужое через apt =="
pt_root "$R36"
ht_hook install >/dev/null
echo 'Remv my-ml-app [1.0]' > "$FAKE/sim-extra"
ht_hook remove; eq "apt снял бы чужой пакет — 1" 1 "$?"
check "чужой пакет назван" grep -q my-ml-app "$ROOT/out"
check_not "apt remove не выполнен" ht_called '^apt-get -q -y remove'

ht_done
