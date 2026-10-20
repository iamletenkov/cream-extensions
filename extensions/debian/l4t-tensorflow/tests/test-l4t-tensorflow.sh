#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the l4t-tensorflow extension (cream/v1): manifest, hook install
# (cuDNN from apt, the NVIDIA TensorFlow wheel, pip only by hashes of requirements.txt) and
# hook remove on a scratch root (CREAM_ROOT) the way cream runs them, with fake
# apt-get, dpkg-query, curl, sha256sum and python3 (pip and the import checks
# are fakes; pip-owned.py runs on the real python3). root, network and a
# Jetson are not needed.
#
#   extensions/debian/l4t-tensorflow/tests/test-l4t-tensorflow.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

R36='# R36 (release), REVISION: 4.3, GCID: 38968081, BOARD: generic, EABI: aarch64, DATE: Wed Jan  8 01:49:37 UTC 2025'

# dist SITE NAME [REQUIRES…]: a fixture dist-info directory.
dist() {
    local site="$1" name="$2" r
    shift 2
    mkdir -p "$site/$name-1.0.dist-info"
    { echo "Metadata-Version: 2.1"; echo "Name: $name"; echo "Version: 1.0"
      for r in "$@"; do echo "Requires-Dist: $r"; done; } > "$site/$name-1.0.dist-info/METADATA"
}

# tf_root [jetson]: fresh root with CUDA libraries and fakes. Package
# database — $FAKE/pkgs; site of pip — $SITE; requirements a fake
# `pip install` gives a distribution — $FAKE/req/<name>.
tf_root() {
    ht_root "$EXT"
    mkdir -p "$FAKE/pkgs" "$FAKE/req" "$ROOT/etc" "$ROOT/usr/local/cuda/lib64" "$ROOT/var/tmp"
    [[ "${1:-}" == jetson ]] && printf '%s\n' "$R36" > "$ROOT/etc/nv_tegra_release"
    SITE="$ROOT/usr/local/lib/python3.10/dist-packages"
    mkdir -p "$SITE"
    echo 3.10 > "$FAKE/pyver"
    : > "$FAKE/sim-extra"
    echo 'numpy' > "$FAKE/req/tensorflow"
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
    printf -v site_q '%q' "$SITE"
    ht_fake python3 "SITE=$site_q"'
case "${1:-}" in
    */pip-owned.py) exec /usr/bin/python3 "$@" ;;
    */check-system-python.py) [[ ! -e "$FAKE/syspy-fails" ]]; exit ;;
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
    uninstall)
        for a in "$@"; do [[ "$a" == -* ]] || rm -rf "$SITE/$a-1.0.dist-info"; done ;;
esac
exit 0'
    STATE="$ROOT/var/lib/cream/ext/l4t-tensorflow"
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
eq "provides" tensorflow "$(mf '" ".join(m["provides"])')"
eq "requires cuda" cuda "$(mf '" ".join(m["requires"])')"
eq "только библиотека apt-guard" "apt-guard >=1.0.0 <2" "$(mf '" ".join(d["name"] + " " + d["version"] for d in m["depends"])')"
eq "хуки" "install remove" "$(mf '" ".join(sorted(m["hooks"]))')"
check "install: явный timeout" test -n "$(mf 'm["hooks"]["install"]["timeout"]')"
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
check "pip-owned.py как у l4t-pytorch" cmp -s "$EXT/pip-owned.py" "$EXT/../l4t-pytorch/pip-owned.py"
check "hooks/install исполняемый" test -x "$EXT/hooks/install"
check "hooks/remove исполняемый" test -x "$EXT/hooks/remove"
check_not "layout 2: install.sh не остался" test -e "$EXT/install.sh"

echo "== не Jetson — 20; отказы до apt =="
tf_root
ht_hook install; eq "нет nv_tegra_release — 20" 20 "$?"
check_not "не Jetson — apt не зовётся" ht_called '^apt-get'
tf_root jetson
rm -r "$ROOT/usr/local/cuda/lib64"
ht_hook install; eq "нет библиотек CUDA (cuda-toolkit) — 1" 1 "$?"
check "подсказка cuda-toolkit" grep -q cuda-toolkit "$ROOT/out"
check_not "нет CUDA — apt не зовётся" ht_called '^apt-get'
tf_root jetson
echo 3.8 > "$FAKE/pyver"
ht_hook install; eq "Python 3.8 — 1" 1 "$?"

echo "== установка =="
tf_root jetson
ht_hook install; eq "установка — 0" 0 "$?"
check "cuDNN и pip из apt" ht_called '^apt-get install .* libcudnn9-cuda-12 python3-pip$'
check "pip install был" test -n "$(pip_calls)"
check "каждый pip install — по хешам requirements.txt" \
    test "$(pip_calls | wc -l)" = "$(pip_calls | grep -c -- '--require-hashes -r .*/requirements.txt')"
check_not "pip без --constraint" grep -q -- '--constraint' "$FAKE/calls"
check "tensorflow — файлом с sha256 колеса NVIDIA" \
    grep -qE "^tensorflow @ file://$ROOT/var/tmp/l4t-tensorflow\.[^ ]+/tensorflow-2\.16\.1[^ ]*\.whl --hash=sha256:ee3cd33c24f75ec9d429580499ae9c7bfdcb4a833b4e92e8b3b1092659fb287c$" "$FAKE/pip-reqs"
check "keras из requirements.txt" test -d "$SITE/keras-1.0.dist-info"
check_not "pip без --user" grep -q -- '--user' "$FAKE/calls"
check "pip: HOME во временном каталоге" grep -q "HOME=$ROOT/var/tmp/" "$FAKE/pip-env"
check "pip: конфиг pip не читается" grep -q 'PIP_CONFIG_FILE=/dev/null' "$FAKE/pip-env"
check "pip-записи" grep -qx tensorflow "$STATE/pip"
check "apt-записи" grep -qx libcudnn9-cuda-12 "$STATE/packages"
check_not "временный каталог убран" compgen -G "$ROOT/var/tmp/l4t-tensorflow.*"
n="$(wc -l < "$STATE/pip")"
ht_hook install; eq "повтор — 0" 0 "$?"
eq "повтор: pip-запись прежняя" "$n" "$(wc -l < "$STATE/pip")"

echo "== отказы =="
tf_root jetson
: > "$FAKE/sha-bad"
ht_hook install; eq "sha256 не совпал — 1" 1 "$?"
check_not "сумма не та — pip не зовётся" ht_called '^python3 -m pip install'
tf_root jetson
: > "$FAKE/import-fails"
ht_hook install; eq "проверка импорта — 1" 1 "$?"
check "tensorflow записан и при отказе" grep -qx tensorflow "$STATE/pip"
tf_root jetson
: > "$FAKE/syspy-fails"
ht_hook install; eq "системный Python поврежден — 1" 1 "$?"

echo "== remove =="
tf_root jetson
dist "$SITE" scipy
ht_hook install >/dev/null
check_not "чужой scipy не записан" grep -qx scipy "$STATE/pip"
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check "pip uninstall своих" ht_called '^python3 -m pip uninstall -y .*tensorflow'
check_not "чужой scipy не трогается" ht_called '^python3 -m pip uninstall .*scipy'
check "apt remove своих" ht_called '^apt-get -q -y remove libcudnn9-cuda-12 python3-pip$'
check_not "записи сняты" test -e "$STATE/pip"
: > "$FAKE/calls"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
check_not "повтор: ни apt, ни pip" ht_called '(^apt-get .*remove|pip uninstall)'

echo "== remove при l4t-pytorch =="
tf_root jetson
ht_hook install >/dev/null
dist "$SITE" torch numpy
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "numpy нужен torch — остаётся" ht_called '^python3 -m pip uninstall .* numpy( |$)'
check_not "cuDNN и pip нужны torch — остаются" ht_called '^apt-get -q -y remove'
check "tensorflow снят" ht_called '^python3 -m pip uninstall -y .*tensorflow'

echo "== remove не уносит чужое через apt =="
tf_root jetson
ht_hook install >/dev/null
echo 'Remv my-ml-app [1.0]' > "$FAKE/sim-extra"
ht_hook remove; eq "apt снял бы чужой пакет — 1" 1 "$?"
check "чужой пакет назван" grep -q my-ml-app "$ROOT/out"
check_not "pip не тронут" ht_called 'pip uninstall'

ht_done
