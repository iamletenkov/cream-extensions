#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the can extension (cream/v1): manifest, hooks install, apply and
# remove on a scratch root (CREAM_ROOT) the way cream runs them, with fake
# apt-get, dpkg-query, modinfo, uname and systemctl. Kernels of the "image" are
# directories $ROOT/lib/modules/<k>/ with modules.order; a module is present
# for a kernel when $FAKE/mod/<k>/<module> exists (or it is in modules.builtin).
# root, network and real kernel modules are not needed.
#
#   extensions/debian/can/tests/test-can.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

ALL="can can_raw can_dev vcan slcan gs_usb peak_usb"

# can_root [ID]: fresh root, /etc/os-release, fakes; no kernels yet.
can_root() {
    local id="${1:-debian}"
    ht_root "$EXT"
    mkdir -p "$ROOT/etc" "$FAKE/pkgs" "$FAKE/mod"
    echo "ID=$id" > "$ROOT/etc/os-release"
    ht_fake dpkg-query '
p="${*: -1}"
[[ -e "$FAKE/pkgs/$p" ]] && { printf "install ok installed\n"; exit 0; }
exit 1'
    # linux-modules-extra-<k> brings every module for <k>.
    ht_fake apt-get '
if [[ "$1" == -s ]]; then v=Remv; [[ "$2" == purge ]] && v=Purg
    for a in "${@:3}"; do echo "$v $a [1.0]"; done; cat "$FAKE/sim-extra" 2>/dev/null; exit 0; fi
sub=""
for a in "$@"; do
    case "$a" in -*) ;; *) [[ -z "$sub" ]] && { sub="$a"; continue; }
        case "$sub" in
            install) : > "$FAKE/pkgs/$a"
                if [[ "$a" == linux-modules-extra-* ]]; then
                    k="${a#linux-modules-extra-}"; mkdir -p "$FAKE/mod/$k"
                    for m in '"$ALL"'; do : > "$FAKE/mod/$k/$m"; done
                fi ;;
            remove|purge) rm -f "$FAKE/pkgs/$a" ;;
        esac ;;
    esac
done
[[ -e "$FAKE/apt-fails-$sub" ]] && exit 100
exit 0'
    ht_fake modinfo '
k="$(cat "$FAKE/uname")"
while (( $# )); do
    case "$1" in -k) k="$2"; shift 2 ;; -n) shift ;; *) m="$1"; shift ;; esac
done
[[ -e "$FAKE/mod/$k/$m" ]] && { echo "/lib/modules/$k/$m.ko"; exit 0; }
echo "modinfo: ERROR: Module $m not found." >&2; exit 1'
    echo 6.1.0-53-amd64 > "$FAKE/uname"
    ht_fake uname 'cat "$FAKE/uname"'
    ht_fake systemctl
    ht_fake candump
    ht_fake cansend
    CONF="$ROOT/etc/modules-load.d/can.conf"
    STATE="$ROOT/var/lib/cream/ext/can"
}
# kernel <k> [modules…]: a kernel of the image with these modules (default — all).
kernel() {
    local k="$1" m; shift
    mkdir -p "$ROOT/lib/modules/$k" "$FAKE/mod/$k"
    : > "$ROOT/lib/modules/$k/modules.order"
    (( $# )) || set -- $ALL
    for m in "$@"; do : > "$FAKE/mod/$k/$m"; done
}
running() { mkdir -p "$ROOT/run/systemd/system"; }
mf() { python3 -c 'import sys,yaml; m=yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
conf_mods() { sed -e '/^#/d' -e '/^$/d' "$CONF" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

echo "== манифест и раскладка =="
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 2" 2 "$(mf 'm["version"].split(".")[0]')"
eq "cream 1.0" ">=1.0.0" "$(mf 'm["cream"]')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "хуки" "apply install remove" "$(mf '" ".join(sorted(m["hooks"]))')"
eq "provides" can-bus "$(mf '" ".join(m["provides"])')"
eq "ключ" CAN_MODULES_LOAD "$(mf '" ".join(m["config"]["keys"])')"
eq "умолчание автозагрузки" "can can_raw vcan" "$(mf 'm["config"]["keys"]["CAN_MODULES_LOAD"]["default"]')"
eq "пустой список допустим" True "$(mf 'm["config"]["keys"]["CAN_MODULES_LOAD"]["empty"]')"
for f in hooks/install hooks/apply hooks/remove; do
    check "$f исполняемый" test -x "$EXT/$f"
done
for f in install.sh render-modules-load.sh knobs knobs.apply; do
    check_not "layout 2: $f не остался в корне" test -e "$EXT/$f"
done

echo "== install: ядер нет — 20 (контейнер) =="
can_root debian
ht_hook install; eq "нет ядер — 20" 20 "$?"
check_not "нет ядер: apt не зовётся" ht_called '^apt-get'
check_not "нет ядер: can.conf не пишется" test -e "$CONF"
check "нет ядер: причина названа" grep -q '/lib/modules' <<< "$(ht_out)"
mkdir -p "$ROOT/lib/modules/5.10.0-old"
ht_hook install; eq "каталог без modules.order (остаток DKMS) — не ядро, 20" 20 "$?"

echo "== install: debian, все модули, сборка =="
can_root debian
kernel 6.1.0-53-amd64
HT_PHASE=build ht_hook install; eq "build — 0" 0 "$?"
check "пакеты одним apt-get install" ht_called '^apt-get .*install .*can-utils iproute2 kmod$'
eq "can.conf — умолчание" "can can_raw vcan" "$(conf_mods)"
check "can.conf ссылается на cream set" grep -q 'cream set can' "$CONF"
eq "запись своих пакетов" can-utils "$(cat "$STATE/packages" 2>/dev/null)"
check_not "build: systemctl не зовётся" ht_called '^systemctl'
check_not "debian: linux-modules-extra не ищется" ht_called 'linux-modules-extra'
snap="$(cat "$CONF" "$STATE/packages" | sha256sum)"
: > "$FAKE/calls"
HT_PHASE=build ht_hook install; eq "повтор install — 0" 0 "$?"
eq "повтор: can.conf и запись те же" "$snap" "$(cat "$CONF" "$STATE/packages" | sha256sum)"

echo "== install: стоявший can-utils не записывается своим =="
can_root debian
kernel 6.1.0-53-amd64
: > "$FAKE/pkgs/can-utils"
ht_hook install; eq "поверх can-utils — 0" 0 "$?"
check_not "чужой can-utils не в записи" grep -qxs can-utils "$STATE/packages"

echo "== install: debian без драйверов — отказ =="
can_root debian
kernel 6.1.0-53-cloud-amd64 can can_raw can_dev vcan
ht_hook install; eq "облачное ядро — 1" 1 "$?"
check "отказ называет модули" grep -q 'gs_usb peak_usb slcan' <<< "$(ht_out)"
check_not "отказ: can.conf не пишется" test -e "$CONF"

echo "== install: ubuntu — linux-modules-extra =="
can_root ubuntu
kernel 6.8.0-47-generic can can_raw can_dev
ht_hook install; eq "ubuntu — 0" 0 "$?"
check "linux-modules-extra ядра образа" ht_called '^apt-get .*install .*linux-modules-extra-6.8.0-47-generic$'
check "без linux-image-generic — предупреждение" grep -q 'linux-image-generic' <<< "$(ht_out)"
check_not "linux-modules-extra не в записи своих (ядро не трогаем при remove)" grep -qs linux-modules "$STATE/packages"
check_not "apt-mark hold не зовётся" ht_called 'apt-mark'

echo "== install: несколько ядер, uname не используется =="
can_root debian
kernel 6.1.0-52-amd64
kernel 6.1.0-53-amd64 can can_raw can_dev vcan slcan gs_usb
echo 5.15.0-appliance > "$FAKE/uname"
ht_hook install; eq "у второго ядра нет peak_usb — 1" 1 "$?"
check "отказ называет ядро" grep -q '6.1.0-53-amd64: модулей peak_usb' <<< "$(ht_out)"

echo "== install: встроенный модуль (modules.builtin) =="
can_root debian
kernel 6.1.0-53-amd64 can can_dev vcan slcan gs_usb peak_usb
echo 'kernel/net/can/can-raw.ko' > "$ROOT/lib/modules/6.1.0-53-amd64/modules.builtin"
ht_hook install; eq "can_raw встроен — 0" 0 "$?"

echo "== install: L4T =="
can_root ubuntu
kernel 5.15.148-tegra can can_raw can_dev vcan mttcan
ht_hook install; eq "L4T без slcan/gs_usb/peak_usb — 0" 0 "$?"
check "L4T: предупреждение про gs_usb" grep -q 'модуля gs_usb нет' <<< "$(ht_out)"
check_not "L4T: linux-modules-extra не ставится" ht_called 'linux-modules-extra'
can_root ubuntu
kernel 5.15.148-tegra can can_raw can_dev vcan mttcan
ht_hook install 'CAN_MODULES_LOAD=can can_raw vcan mttcan'; eq "L4T с mttcan — 0" 0 "$?"
eq "can.conf с mttcan" "can can_raw vcan mttcan" "$(conf_mods)"
can_root ubuntu
kernel 5.15.148-tegra can can_raw can_dev vcan mttcan
ht_hook install 'CAN_MODULES_LOAD=can can_raw vcan gs_usb'; eq "L4T: gs_usb в автозагрузке — 1" 1 "$?"
can_root debian
kernel 6.1.0-53-amd64
ht_hook install 'CAN_MODULES_LOAD=can mttcan'; eq "amd64: mttcan в автозагрузке — 1" 1 "$?"

echo "== install: живая машина грузит модули =="
can_root debian
kernel 6.1.0-53-amd64
running
ht_hook install; eq "live — 0" 0 "$?"
check "systemd-modules-load поставлен в очередь" ht_called '^systemctl --no-block restart systemd-modules-load.service$'

echo "== apply =="
can_root debian
kernel 6.1.0-53-amd64
running
HT_PHASE=build ht_hook install >/dev/null; : > "$FAKE/calls"
ht_hook apply 'CAN_MODULES_LOAD=can can_raw vcan gs_usb' CREAM_CHANGED_KEYS=CAN_MODULES_LOAD
eq "apply — 0" 0 "$?"
eq "can.conf с gs_usb" "can can_raw vcan gs_usb" "$(conf_mods)"
check "apply: модули грузятся без ожидания" ht_called '^systemctl --no-block restart systemd-modules-load.service$'
check_not "apply: блокирующего systemctl нет" grep -qE '^systemctl (restart|start)' "$FAKE/calls"
check_not "apply: apt не зовётся" ht_called '^apt-get'
: > "$FAKE/calls"
ht_hook apply 'CAN_MODULES_LOAD=can can_raw vcan gs_usb'; eq "повтор apply — 0" 0 "$?"
check_not "без изменений — systemctl не зовётся" ht_called '^systemctl'
ht_hook apply 'CAN_MODULES_LOAD=can nosuchmod'; eq "неизвестный модуль — предупреждение, 0" 0 "$?"
check "неизвестный модуль назван" grep -q 'модуля nosuchmod нет' <<< "$(ht_out)"
ht_hook apply CAN_MODULES_LOAD=; eq "пустой список — 0" 0 "$?"
check_not "пустой список — can.conf удалён" test -e "$CONF"
rm -r -f -- "$ROOT/run/systemd"
: > "$FAKE/calls"
ht_hook apply 'CAN_MODULES_LOAD=can'; eq "без systemd — 0" 0 "$?"
check "без systemd — файл записан" test -f "$CONF"
check_not "без systemd — systemctl не зовётся" ht_called '^systemctl'

echo "== remove =="
can_root debian
kernel 6.1.0-53-amd64
HT_PHASE=build ht_hook install >/dev/null
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "can.conf снят" test -e "$CONF"
check "свой can-utils снят" ht_called '^apt-get .*remove can-utils$'
check_not "iproute2 и kmod не снимаются" ht_called '^apt-get .*remove .*(iproute2|kmod)'
check_not "ядро и его модули не трогаются" ht_called 'linux-'
check_not "запись своих снята" test -e "$STATE/packages"
: > "$FAKE/calls"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
check_not "повтор: apt не зовётся" ht_called '^apt-get'
can_root debian
mkdir -p "$STATE"; echo can-utils > "$STATE/packages"; : > "$FAKE/apt-fails-remove"
ht_hook remove; eq "apt-get remove упал — 1" 1 "$?"
check "сбой remove — запись сохранена" test -s "$STATE/packages"

echo "== remove: симуляция снимает чужой пакет — отказ =="
can_root debian
kernel 6.1.0-53-amd64
HT_PHASE=build ht_hook install >/dev/null
echo 'Remv canopen-tools [1.0]' > "$FAKE/sim-extra"
: > "$FAKE/calls"
ht_hook remove; eq "симуляция снимает чужой пакет — 1" 1 "$?"
check "чужой пакет назван" grep -q 'canopen-tools' "$ROOT/out"
check_not "ничего не снято" ht_called '^apt-get -q -y remove'
check "can.conf на месте" test -e "$CONF"
check "запись пакетов осталась" test -s "$STATE/packages"

ht_done
