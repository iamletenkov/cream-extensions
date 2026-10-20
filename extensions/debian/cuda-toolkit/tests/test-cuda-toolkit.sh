#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the cuda-toolkit extension (cream/v1): manifest, hook install and
# hook remove on a scratch root (CREAM_ROOT) the way cream runs them, with fake
# apt-get and dpkg-query. root, network and a Jetson are not needed.
#
#   extensions/debian/cuda-toolkit/tests/test-cuda-toolkit.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

R36='# R36 (release), REVISION: 4.3, GCID: 38968081, BOARD: generic, EABI: aarch64, DATE: Wed Jan  8 01:49:37 UTC 2025'

# cu_root [jetson]: fresh root with fakes; "jetson" adds /etc/nv_tegra_release
# and the jetson/common source list. Package database — $FAKE/pkgs; packages a
# simulated remove would take on top of the asked ones — $FAKE/sim-extra.
cu_root() {
    ht_root "$EXT"
    mkdir -p "$FAKE/pkgs" "$ROOT/etc/profile.d"
    if [[ "${1:-}" == jetson ]]; then
        mkdir -p "$ROOT/etc/apt/sources.list.d"
        printf '%s\n' "$R36" > "$ROOT/etc/nv_tegra_release"
        echo 'deb https://repo.download.nvidia.com/jetson/common r36.4 main' \
            > "$ROOT/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"
    fi
    : > "$FAKE/sim-extra"
    ht_fake dpkg-query '
f="" p="${*: -1}"
for a in "$@"; do case "$a" in -f*) f="${a#-f}" ;; esac; done
[[ -e "$FAKE/pkgs/$p" ]] || exit 1
case "$f" in *Status-Status*) printf installed ;; *) printf 12.6.11-1 ;; esac'
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
[[ "$sub" == install && ! -e "$FAKE/no-layout" ]] && {
    if [[ "${*: -1}" == cuda-toolkit-10-2 ]]; then
        mkdir -p "$(dirname "$FAKE")/usr/local/cuda-10.2/bin"
        printf "#!/bin/sh\n" > "$(dirname "$FAKE")/usr/local/cuda-10.2/bin/nvcc"
        chmod 0755 "$(dirname "$FAKE")/usr/local/cuda-10.2/bin/nvcc"
        [[ -e "$FAKE/no-link" ]] || ln -sfn cuda-10.2 "$(dirname "$FAKE")/usr/local/cuda"
    else
        mkdir -p "$(dirname "$FAKE")/usr/local/cuda-12.6/bin"
        ln -sfn cuda-12.6 "$(dirname "$FAKE")/usr/local/cuda"
    fi
}
exit 0'
    PROFILE="$ROOT/etc/profile.d/cuda-toolkit.sh"
    STATE="$ROOT/var/lib/cream/ext/cuda-toolkit"
}
mf() { python3 -c 'import sys,yaml; m=yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }

echo "== манифест и раскладка =="
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 2" 2 "$(mf 'm["version"].split(".")[0]')"
eq "cream 1.0" ">=1.0.0" "$(mf 'm["cream"]')"
eq "только arm64" arm64 "$(mf '" ".join(m["platform"]["arch"])')"
eq "build: exec" exec "$(mf 'm["targets"]["build"]')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "provides" cuda "$(mf '" ".join(m["provides"])')"
eq "хуки" "install remove" "$(mf '" ".join(sorted(m["hooks"]))')"
check "install: явный timeout" test -n "$(mf 'm["hooks"]["install"]["timeout"]')"
eq "только библиотека apt-guard" "apt-guard >=1.0.0 <2" "$(mf '" ".join(d["name"] + " " + d["version"] for d in m["depends"])')"
check "hooks/install исполняемый" test -x "$EXT/hooks/install"
check "hooks/remove исполняемый" test -x "$EXT/hooks/remove"
check_not "layout 2: install.sh не остался" test -e "$EXT/install.sh"

echo "== не Jetson — 20 до apt =="
cu_root
ht_hook install; eq "нет nv_tegra_release — 20" 20 "$?"
check_not "не Jetson — apt не зовётся" ht_called '^apt-get'
check_not "не Jetson — профиль не пишется" test -e "$PROFILE"
cu_root jetson
rm -f "$ROOT/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"
ht_hook install; eq "Jetson без jetson/common — 1" 1 "$?"
check_not "без источника — apt не зовётся" ht_called '^apt-get'

echo "== установка =="
cu_root jetson
ht_hook install; eq "установка — 0" 0 "$?"
check "apt-get update" ht_called '^apt-get update'
check "ставится cuda-toolkit, не cuda" ht_called '^apt-get .*install .*cuda-toolkit$'
check "профиль PATH" grep -qF 'export PATH="/usr/local/cuda/bin${PATH:+:${PATH}}"' "$PROFILE"
check "профиль LD_LIBRARY_PATH" grep -qF '/usr/local/cuda/lib64' "$PROFILE"
eq "профиль — 0644" 644 "$(stat -c %a "$PROFILE")"
eq "свои пакеты записаны" cuda-toolkit "$(cat "$STATE/packages")"
snap="$(sha256sum < "$PROFILE")"
ht_hook install; eq "повтор — 0" 0 "$?"
eq "повтор: профиль тот же" "$snap" "$(sha256sum < "$PROFILE")"
eq "повтор: запись прежняя" cuda-toolkit "$(cat "$STATE/packages")"

echo "== профиль: ссылка заменяется, а не проходится =="
cu_root jetson
echo secret > "$ROOT/target"
ln -s ../../target "$PROFILE"
ht_hook install; eq "ссылка на месте профиля — 0" 0 "$?"
eq "цель ссылки не тронута" secret "$(cat "$ROOT/target")"
check_not "профиль — уже не ссылка" test -L "$PROFILE"

echo "== отказы =="
cu_root jetson
: > "$FAKE/apt-fails-install"
ht_hook install; eq "apt install не прошёл — 1" 1 "$?"
check_not "отказ — профиль не пишется" test -e "$PROFILE"
cu_root jetson
: > "$FAKE/no-layout"
ht_hook install; eq "нет /usr/local/cuda — 1" 1 "$?"
check_not "нет раскладки — профиль не пишется" test -e "$PROFILE"

echo "== журнал: строка релиза — данные =="
cu_root jetson
printf '# R36 $(touch %s/pwned) \033[31mred\n' "$ROOT" > "$ROOT/etc/nv_tegra_release"
ht_hook install; eq "странная строка релиза — 0" 0 "$?"
check_not "строка релиза не исполнена" test -e "$ROOT/pwned"
check_not "в журнале нет управляющих символов" grep -q $'\033\[31' "$ROOT/out"

echo "== пакет стоял до cream =="
cu_root jetson
: > "$FAKE/pkgs/cuda-toolkit"
ht_hook install; eq "чужой пакет — 0" 0 "$?"
check_not "чужой пакет не записан" test -s "$STATE/packages"
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "чужой пакет не удаляется" ht_called '^apt-get .*(remove|purge)'
check_not "профиль снят" test -e "$PROFILE"

echo "== remove =="
cu_root jetson
ht_hook install >/dev/null
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check "свой пакет удалён" ht_called '^apt-get .* remove cuda-toolkit$'
check_not "профиль снят" test -e "$PROFILE"
check_not "запись снята" test -e "$STATE/packages"
: > "$FAKE/calls"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
check_not "повтор: apt не зовётся" ht_called '^apt-get .*remove'

echo "== remove не уносит чужое =="
cu_root jetson
ht_hook install >/dev/null
echo 'Remv my-app [1.0]' > "$FAKE/sim-extra"
ht_hook remove; eq "apt снял бы чужой пакет — 1" 1 "$?"
check "чужой пакет назван" grep -q my-app "$ROOT/out"
check_not "remove не выполнен" ht_called '^apt-get -q -y remove'
eq "запись осталась" cuda-toolkit "$(cat "$STATE/packages")"

# --- R32 (Jetson Nano, JetPack 4.6): CUDA 10.2 ------------------------------
R32='# R32 (release), REVISION: 6.1, GCID: 27863751, BOARD: t210ref, EABI: aarch64, DATE: Mon Jul 26 19:20:30 UTC 2021'
OTA_PIN=576f852981855e5c6cfb9b625ffb51b984ca451f1181b2e70435b005034fad55
# r32_root: a Nano without CUDA and without an active jetson/common source (the
# vendor image comments NVIDIA's lines out).
r32_root() {
    cu_root
    mkdir -p "$ROOT/etc/apt/sources.list.d"
    printf '%s\n' "$R32" > "$ROOT/etc/nv_tegra_release"
    echo '# deb https://repo.download.nvidia.com/jetson/common r32.6 main' \
        > "$ROOT/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"
    OWN_LIST="$ROOT/etc/apt/sources.list.d/cream-cuda-toolkit.list"
    OWN_KEY="$ROOT/usr/share/keyrings/cream-cuda-toolkit-jetson.asc"
}

echo "== R32: ключ NVIDIA в расширении по sha256 =="
eq "ключ jetson-ota-public — пин sha256" "$OTA_PIN" \
    "$(sha256sum < "$EXT/files/jetson-ota-public.asc" | cut -d' ' -f1)"
check "пин ключа в хуке" grep -q "$OTA_PIN" "$EXT/hooks/install"

echo "== R32: CUDA 10.2 уже в образе — без apt =="
r32_root
mkdir -p "$ROOT/usr/local/cuda-10.2/bin"
printf '#!/bin/sh\n' > "$ROOT/usr/local/cuda-10.2/bin/nvcc"; chmod 0755 "$ROOT/usr/local/cuda-10.2/bin/nvcc"
ln -s cuda-10.2 "$ROOT/usr/local/cuda"
ht_hook install; eq "CUDA в образе — 0" 0 "$?"
check_not "apt не зовётся" ht_called '^apt-get'
check_not "источник не заводится" test -e "$OWN_LIST"
check "профиль PATH" grep -qF '/usr/local/cuda/bin' "$PROFILE"
check_not "своих пакетов нет" test -s "$STATE/packages"
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "remove: apt не зовётся" ht_called '^apt-get'
check "remove: CUDA образа на месте" test -x "$ROOT/usr/local/cuda-10.2/bin/nvcc"
check "remove: ссылка образа на месте" test -L "$ROOT/usr/local/cuda"

echo "== R32: CUDA 10.2 в образе без ссылки /usr/local/cuda =="
r32_root
mkdir -p "$ROOT/usr/local/cuda-10.2/bin"
printf '#!/bin/sh\n' > "$ROOT/usr/local/cuda-10.2/bin/nvcc"; chmod 0755 "$ROOT/usr/local/cuda-10.2/bin/nvcc"
ht_hook install; eq "без ссылки — 0" 0 "$?"
eq "ссылка /usr/local/cuda -> cuda-10.2" cuda-10.2 "$(readlink "$ROOT/usr/local/cuda")"
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "remove: своя ссылка снята" test -L "$ROOT/usr/local/cuda"
check "remove: CUDA образа на месте" test -x "$ROOT/usr/local/cuda-10.2/bin/nvcc"

echo "== R32: установка из jetson/common r32.<ревизия> =="
r32_root
ht_hook install; eq "R32 установка — 0" 0 "$?"
eq "свой источник: r32.6, signed-by" \
    "deb [signed-by=/usr/share/keyrings/cream-cuda-toolkit-jetson.asc] https://repo.download.nvidia.com/jetson/common r32.6 main" \
    "$(cat "$OWN_LIST" 2>/dev/null)"
eq "ключ — из расширения" "$OTA_PIN" "$(sha256sum < "$OWN_KEY" 2>/dev/null | cut -d' ' -f1)"
eq "ключ — 0644" 644 "$(stat -c %a "$OWN_KEY" 2>/dev/null)"
check "ставится cuda-toolkit-10-2" ht_called '^apt-get .*install .*cuda-toolkit-10-2$'
check_not "cuda-toolkit (R36) не ставится" ht_called '^apt-get .*install .* cuda-toolkit$'
eq "свои пакеты записаны" cuda-toolkit-10-2 "$(cat "$STATE/packages")"
check "профиль PATH" grep -qF '/usr/local/cuda/bin' "$PROFILE"
: > "$FAKE/calls"
ht_hook remove; eq "R32 remove — 0" 0 "$?"
check "свой пакет удалён" ht_called '^apt-get .* remove cuda-toolkit-10-2$'
check_not "свой источник снят" test -e "$OWN_LIST"
check_not "свой ключ снят" test -e "$OWN_KEY"
check "чужой список NVIDIA не тронут" test -e "$ROOT/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"

echo "== R32: активный jetson/common вендора — второго источника нет =="
r32_root
echo 'deb https://repo.download.nvidia.com/jetson/common r32.6 main' \
    > "$ROOT/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"
ht_hook install; eq "с источником вендора — 0" 0 "$?"
check_not "свой источник не заводится" test -e "$OWN_LIST"
check "ставится cuda-toolkit-10-2" ht_called '^apt-get .*install .*cuda-toolkit-10-2$'

echo "== R32: отказы =="
r32_root
printf '# R32 (release), REVISION: 9.9, GCID: 1\n' > "$ROOT/etc/nv_tegra_release"
ht_hook install; eq "неизвестная ревизия R32 — 1" 1 "$?"
check_not "неизвестная ревизия — apt не зовётся" ht_called '^apt-get'
check_not "неизвестная ревизия — источник не заводится" test -e "$OWN_LIST"
r32_root
printf 'tampered\n' >> "$HT_EXT/files/jetson-ota-public.asc"
ht_hook install; eq "ключ не сошёлся по sha256 — 1" 1 "$?"
check_not "подменённый ключ — apt не зовётся" ht_called '^apt-get'
check_not "подменённый ключ не положен" test -e "$OWN_KEY"
r32_root
: > "$FAKE/apt-fails-install"
ht_hook install; eq "R32 apt install не прошёл — 1" 1 "$?"
check_not "отказ — профиль не пишется" test -e "$PROFILE"

ht_done
