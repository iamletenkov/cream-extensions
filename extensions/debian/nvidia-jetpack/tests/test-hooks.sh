#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the nvidia-jetpack hooks (cream/v1): manifest, install and remove on a
# scratch root (CREAM_ROOT) the way cream runs them. apt-get, dpkg-query,
# systemctl and systemd-detect-virt are fakes; root, network and a real binfmt
# are not needed. binfmt is checked here only (plan 2026-10-19, Task 21): the
# live run (L) never touches the host's binfmt_misc.
#
#   extensions/debian/nvidia-jetpack/tests/test-hooks.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

PKGS="zstd cpp device-tree-compiler xmlstarlet libxml2-utils sshpass openssh-client abootimg
uuid-runtime lz4 cpio gdisk parted binutils qemu-user-static nfs-kernel-server python3-yaml bzip2
wget curl v4l-utils"
EMU=/usr/bin/qemu-aarch64-static
BINFMT_LINE=':qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-aarch64-static:F'

# fresh: a root with fakes. $FAKE/pkg-<name> — dpkg-query reports it installed;
# apt-get install marks its arguments installed and puts the emulator in place
# (unless $FAKE/no-emulator); $FAKE/container — systemd-detect-virt says
# "container"; $FAKE/enable-broken — systemctl enable fails.
fresh() {
    ht_root "$EXT"
    CONF="$ROOT/etc/binfmt.d/qemu-aarch64.conf"
    STATE="$ROOT/var/lib/cream/ext/nvidia-jetpack/packages"
    ht_fake dpkg-query 'p="${*: -1}"; [[ -f "$FAKE/pkg-$p" ]] && printf installed; exit 0'
    ht_fake apt-get 'if [[ "$1" == -s ]]; then v=Remv; [[ "$2" == purge ]] && v=Purg
    for a in "${@:3}"; do echo "$v $a [1.0]"; done; cat "$FAKE/sim-extra" 2>/dev/null; exit 0; fi
if [[ " $* " == *" install "* ]]; then
  for a in "$@"; do case "$a" in -*|install|Dpkg::*) ;; *) : > "$FAKE/pkg-$a" ;; esac; done
  if [[ ! -f "$FAKE/no-emulator" && -f "$FAKE/pkg-qemu-user-static" ]]; then
    mkdir -p "'"$ROOT"'/usr/bin"; : > "'"$ROOT$EMU"'"; chmod +x "'"$ROOT$EMU"'"
  fi
fi; exit 0'
    ht_fake systemctl '[[ "$1" == enable && -f "$FAKE/enable-broken" ]] && exit 1; exit 0'
    ht_fake systemd-detect-virt '[[ -f "$FAKE/container" ]] && { echo docker; exit 0; }; echo none; exit 1'
    ht_fake sleep
}
all_installed() {
    local p
    for p in $PKGS; do : > "$FAKE/pkg-$p"; done
    mkdir -p "$ROOT/usr/bin"; : > "$ROOT$EMU"; chmod +x "$ROOT$EMU"
}
live_systemd() { mkdir -p "$ROOT/run/systemd/system"; }

echo "== манифест =="
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 3" 3.0.1 "$(mf 'm["version"]')"
eq "cream >=1.0.0" ">=1.0.0" "$(mf 'm["cream"]')"
eq "только amd64" "['amd64']" "$(mf 'm["platform"]["arch"]')"
eq "build: exec" exec "$(mf 'm["targets"]["build"]')"
eq "live: confirm" confirm "$(mf 'm["targets"]["live"]')"
check "live_note про binfmt" grep -q 'binfmt' <<< "$(mf 'm["targets"]["live_note"]')"
check "live_note про NFS" grep -q 'NFS' <<< "$(mf 'm["targets"]["live_note"]')"
eq "provides" "['jetson-flash-station']" "$(mf 'm["provides"]')"
eq "хуки install и remove" "['install', 'remove']" "$(mf 'sorted(m["hooks"])')"
check "install с явным timeout" test -n "$(mf 'm["hooks"]["install"].get("timeout", "")')"
eq "udev-правило — files" "/etc/udev/rules.d/99-jetson-usb.rules" \
    "$(mf '[f["dst"] for f in m["files"]][0]')"
check "правило по vendor 0955" grep -q 'ATTR{idVendor}=="0955"' "$EXT/files/99-jetson-usb.rules"
check_not "install.sh layout 2 убран" test -e "$EXT/install.sh"
check "скрипты станции исполняемые" test -x "$EXT/scripts/09-build-jetson-base.sh"
check "профили на месте" test -f "$EXT/scripts/boards/agx-orin.env"
check_not "скрипты не зовут прежний путь /opt/nvidia-jetpack" grep -rqF '/opt/nvidia-jetpack/' "$EXT/scripts"
check "скрипты называют путь в дереве расширения" grep -qF '/opt/cream/ext/nvidia-jetpack/scripts/' "$EXT/scripts/README.md"

echo "== build: ставит всё =="
fresh
HT_PHASE=build ht_hook install; eq "install (build) — 0" 0 "$?"
check "apt-get update" ht_called '^apt-get .*update$'
check "ставит инструментарий L4T" ht_called '^apt-get .*install .*qemu-user-static .*nfs-kernel-server'
eq "состояние: все пакеты" "$(echo $PKGS)" "$(tr '\n' ' ' < "$STATE" | sed 's/ $//')"
check "nfs-server включён (enable, не start)" ht_called '^systemctl enable nfs-server'
check_not "nfs-server не запускают" ht_called '^systemctl .*start nfs-server'
check "binfmt-файл записан" test -f "$CONF"
eq "binfmt: правило aarch64" "$BINFMT_LINE" "$(grep -v '^#' "$CONF")"
eq "binfmt: режим 0644" 644 "$(stat -c %a "$CONF")"
check_not "build: systemd-binfmt не перезапускают" ht_called 'systemd-binfmt'
check_not "в /opt/nvidia-jetpack ничего" test -e "$ROOT/opt/nvidia-jetpack"
check "сообщение про путь скриптов" grep -q '/opt/cream/ext/nvidia-jetpack/scripts' <(ht_out)

echo "== live: перезапуск systemd-binfmt =="
fresh
live_systemd
ht_hook install; eq "install (live) — 0" 0 "$?"
check "restart --no-block" ht_called '^systemctl --no-block restart systemd-binfmt\.service$'
eq "перезапуск один" 1 "$(grep -c 'systemd-binfmt' "$FAKE/calls")"
: > "$FAKE/calls"
ht_hook install; eq "повтор install — 0" 0 "$?"
check_not "повтор: apt-get не звали" ht_called '^apt-get '
check_not "повтор: binfmt не менялся — не перезапускают" ht_called 'systemd-binfmt'
eq "повтор не теряет «поставлено нами»" "$(echo $PKGS)" "$(tr '\n' ' ' < "$STATE" | sed 's/ $//')"

fresh
live_systemd
: > "$FAKE/container"
ht_hook install; eq "live в контейнере — 0" 0 "$?"
check "binfmt-файл записан и в контейнере" test -f "$CONF"
check_not "в контейнере binfmt хоста не трогают" ht_called 'restart systemd-binfmt'
check "сообщение про контейнер" grep -q 'контейнер' <(ht_out)

fresh
ht_hook install; eq "live без systemd (нет /run/systemd/system) — 0" 0 "$?"
check_not "без systemd не перезапускают" ht_called 'systemd-binfmt'

echo "== уже стоит =="
fresh
all_installed
mkdir -p "$ROOT/etc/binfmt.d"
{ echo '# NVIDIA Jetson'; echo "$BINFMT_LINE"; } > "$CONF"
live_systemd
HT_PHASE=build ht_hook install; eq "всё стоит — 0" 0 "$?"
check_not "apt-get не звали" ht_called '^apt-get '
check_not "состояния нет: ничего не ставили" test -s "$STATE"

echo "== binfmt не следует по ссылке =="
fresh
mkdir -p "$ROOT/etc/binfmt.d" "$ROOT/victim"
echo keep > "$ROOT/victim/file"
ln -s "$ROOT/victim/file" "$CONF"
HT_PHASE=build ht_hook install; eq "ссылка на месте binfmt — 0" 0 "$?"
check "binfmt — обычный файл" test -f "$CONF" -a ! -L "$CONF"
eq "цель ссылки не тронута" keep "$(cat "$ROOT/victim/file")"

echo "== нет эмулятора и сбой enable =="
fresh
: > "$FAKE/no-emulator"; : > "$FAKE/enable-broken"
live_systemd
ht_hook install; eq "нет эмулятора, enable сломан — 0" 0 "$?"
check_not "binfmt без эмулятора не пишут" test -e "$CONF"
check "предупреждение про эмулятор" grep -q 'qemu-aarch64-static' <(ht_out)
check "предупреждение про nfs-server" grep -q 'nfs-server' <(ht_out)
check_not "без файла не перезапускают" ht_called 'systemd-binfmt'

echo "== скриптов нет — отказ =="
fresh
rm -r -f -- "$HT_EXT/scripts"
HT_PHASE=build ht_hook install; eq "нет scripts/ — 1" 1 "$?"
check "сообщение про scripts" grep -q 'scripts' <(ht_out)
fresh
find "$HT_EXT/scripts" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \) -delete
HT_PHASE=build ht_hook install; eq "пустой scripts/ — 1" 1 "$?"

echo "== remove =="
fresh
live_systemd
ht_hook install; eq "install — 0" 0 "$?"
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check "remove снимает свои пакеты" ht_called '^apt-get .*remove .*qemu-user-static'
check_not "binfmt-файл снят" test -e "$CONF"
check "remove: restart --no-block" ht_called '^systemctl --no-block restart systemd-binfmt\.service$'
check_not "состояние снято" test -e "$STATE"
: > "$FAKE/calls"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
check_not "повтор remove ничего не удаляет" ht_called '^apt-get '
check_not "повтор remove не перезапускает" ht_called 'systemd-binfmt'

fresh
all_installed
mkdir -p "$ROOT/etc/binfmt.d"
echo ':qemu-aarch64:M::operator' > "$CONF"
live_systemd
ht_hook remove; eq "remove чужого binfmt — 0" 0 "$?"
check "чужой binfmt-файл оставлен" test -f "$CONF"
check_not "чужие пакеты не трогают" ht_called '^apt-get '

fresh
live_systemd
: > "$FAKE/container"
ht_hook install; eq "install в контейнере — 0" 0 "$?"
: > "$FAKE/calls"
ht_hook remove; eq "remove в контейнере — 0" 0 "$?"
check_not "remove в контейнере binfmt хоста не трогает" ht_called 'systemd-binfmt'

echo "== remove: симуляция снимает чужой пакет — отказ =="
fresh
live_systemd
ht_hook install >/dev/null
echo 'Remv binfmt-support [2.2.2-2]' > "$FAKE/sim-extra"
: > "$FAKE/calls"
ht_hook remove; eq "симуляция снимает чужой пакет — 1" 1 "$?"
check "чужой пакет назван" grep -q 'binfmt-support' "$ROOT/out"
check_not "ничего не снято" ht_called '^apt-get -q -y remove'
check "binfmt-файл на месте" test -e "$CONF"
check "запись пакетов осталась" test -s "$STATE"

ht_done
