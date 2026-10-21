#!/usr/bin/env bash
# H-тест amneziawg: хуки на подменённом корне (tools/hooktest.sh). uci, apk, awg,
# ubus подставные: uci пишет пакет команд batch (stdin) в журнал, show отдаёт
# заготовку $FAKE/network.show. Настоящий uci и netifd — L (контейнер OpenWrt).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../../tools/hooktest.sh
. "$HERE/../../../../tools/hooktest.sh"
ht_init

# fake_key C: a base64 WireGuard-shaped key of one repeated letter (low entropy:
# test data, not a key).
fake_key() { printf '%s' "$(printf "%042d" 0 | tr 0 "$1")A="; }
KEY_A="$(fake_key a)"
KEY_B="$(fake_key b)"
KEY_PSK="$(fake_key p)"
GEN="$(fake_key g)"

setup() {
    ht_root "$(dirname "$HERE")"
    : > "$FAKE/network.show"
    ht_fake apk 'case "$*" in "info -e "*) grep -qx "${!#}" "$FAKE/apk.have" 2>/dev/null ;; *) exit 0 ;; esac'
    printf '%s\n' kmod-amneziawg amneziawg-tools > "$FAKE/apk.have"
    # get: the last `set` of the batch, else the line of network.show (uci show format).
    ht_fake uci 'case "$*" in
*" batch") cat >> "$FAKE/uci.batch" ;;
*" show network") cat "$FAKE/network.show" ;;
*" get "*) k="${!#}"
    v="$(sed -n -e "s/^set $k=.\(.*\).\$/\1/p" -e "s/^set $k=\([a-z_]*\)\$/\1/p" "$FAKE/uci.batch" 2>/dev/null | tail -n1)"
    [ -n "$v" ] || v="$(sed -n "s/^$k=//p" "$FAKE/network.show" | tail -n1)"
    [ -n "$v" ] && echo "$v" ;;
esac'
    ht_fake awg "case \"\$1\" in genkey) echo $GEN ;; pubkey) read -r k; echo \"pub-of-\$k\" ;; esac"
    ht_fake ubus 'exit 1'
    ht_fake ifup
    ht_fake ifdown
}
batch() { cat "$FAKE/uci.batch" 2>/dev/null; }
has_line() { batch | grep -qxF -- "$1"; }

# --- install: пакеты образа
setup
ht_hook install; eq "install с пакетами образа — 0" 0 "$?"
check "install не меняет uci" test ! -e "$FAKE/uci.batch"
setup
printf '%s\n' amneziawg-tools > "$FAKE/apk.have"
ht_hook install; eq "install без kmod-amneziawg — 20 (неприменимо)" 20 "$?"
check "причина — образ openwrt-builder" grep -q 'openwrt-builder' "$ROOT/out"

# --- install в сборке: заданный закрытый ключ уедет во все машины образа — предупреждение
setup
ht_secret AMNEZIAWG_PRIVATE_KEY "$KEY_B"
HT_PHASE=build ht_hook install; eq "install в сборке с ключом — 0" 0 "$?"
check "предупреждение про один ключ на все машины" grep -q 'все машины' "$ROOT/out"
check_not "ключ не в выводе" grep -qF "$KEY_B" "$ROOT/out"
setup
ht_secret AMNEZIAWG_PRIVATE_KEY "$KEY_B"
HT_PHASE=live ht_hook install
check_not "на живой машине не предупреждаем" grep -q 'все машины' "$ROOT/out"

# --- configure: ключ генерируется один раз, интерфейс и пир — одним batch
setup
ht_hook configure CREAM_REASON=boot AMNEZIAWG_ADDRESSES="10.8.0.2/32 fd00::2/128" \
    AMNEZIAWG_PEER_PUBLIC_KEY="$KEY_A" AMNEZIAWG_PEER_ENDPOINT="vpn.example.org:51820" \
    AMNEZIAWG_JC=4 AMNEZIAWG_H1=100-200
eq "configure — 0" 0 "$?"
st="$ROOT/var/lib/cream/ext/amneziawg"
eq "ключ машины в состоянии" "$GEN" "$(cat "$st/private.key" 2>/dev/null)"
eq "ключ — 0600" 600 "$(stat -c %a "$st/private.key")"
check "интерфейс" has_line "set network.awg0=interface"
check "proto" has_line "set network.awg0.proto='amneziawg'"
check "закрытый ключ" has_line "set network.awg0.private_key='$GEN'"
check "адреса списком" has_line "add_list network.awg0.addresses='fd00::2/128'"
check "Jc" has_line "set network.awg0.awg_jc='4'"
check "H1 диапазоном" has_line "set network.awg0.awg_h1='100-200'"
check_not "пустые ключи обфускации не пишутся" has_line "set network.awg0.awg_s1=''"
check "пир — секция amneziawg_awg0" has_line "set network.awg0_peer=amneziawg_awg0"
check "endpoint host" has_line "set network.awg0_peer.endpoint_host='vpn.example.org'"
check "endpoint port" has_line "set network.awg0_peer.endpoint_port='51820'"
check "allowed_ips по умолчанию" has_line "add_list network.awg0_peer.allowed_ips='::/0'"
check "маршруты не трогаем по умолчанию" has_line "set network.awg0_peer.route_allowed_ips='0'"
check "keepalive 25" has_line "set network.awg0_peer.persistent_keepalive='25'"
check "commit" has_line "commit network"
check_not "ключ не в argv" grep -rqF "$GEN" "$FAKE/uci.argv"
check_not "на загрузке netifd не трогаем" ht_called '^ubus call'
: > "$FAKE/uci.batch"
ht_hook configure CREAM_REASON=boot
check "повтор — тот же ключ" has_line "set network.awg0.private_key='$GEN'"
eq "awg genkey — один раз" 1 "$(grep -c '^awg genkey' "$FAKE/calls")"

# --- configure: секретный ключ и PSK из CREAM_SECRETS_FILE, не из окружения
setup
ht_secret AMNEZIAWG_PRIVATE_KEY "$KEY_B"
ht_secret AMNEZIAWG_PEER_PRESHARED_KEY "\"$KEY_PSK\""
ht_hook configure CREAM_REASON=install AMNEZIAWG_PEER_PUBLIC_KEY="$KEY_A" \
    AMNEZIAWG_PEER_ENDPOINT="[2001:db8::1]:443"
eq "configure с секретами — 0" 0 "$?"
check "закрытый ключ из секрета" has_line "set network.awg0.private_key='$KEY_B'"
check "PSK из секрета (в кавычках файла)" has_line "set network.awg0_peer.preshared_key='$KEY_PSK'"
check "IPv6 endpoint без скобок" has_line "set network.awg0_peer.endpoint_host='2001:db8::1'"
check_not "ключ не генерировался" ht_called '^awg genkey'
check_not "секрет не в выводе" grep -qF "$KEY_B" "$ROOT/out"

# --- configure: без пира — интерфейс без пира и предупреждение
setup
ht_hook configure CREAM_REASON=boot
eq "без пира — 0" 0 "$?"
check "предупреждение про пира" grep -q 'без пира' "$ROOT/out"
check_not "секции пира нет" has_line "set network.awg0_peer=amneziawg_awg0"

# --- configure: смена имени интерфейса убирает прежний и его пиров
setup
printf 'awg0\n' > "$ROOT/var/lib/cream/ext/amneziawg/iface"
printf '%s\n' "network.awg0=interface" "network.awg0.proto=amneziawg" "network.awg0_peer=amneziawg_awg0" "network.extra=amneziawg_awg0" \
    > "$FAKE/network.show"
ht_hook configure CREAM_REASON=apply AMNEZIAWG_IFACE=vpn1
check "прежний интерфейс удалён" has_line "delete network.awg0"
check "пиры прежнего удалены" has_line "delete network.extra"
check "новый интерфейс" has_line "set network.vpn1=interface"
eq "имя запомнено" vpn1 "$(cat "$ROOT/var/lib/cream/ext/amneziawg/iface")"

# --- configure: на живой машине (не загрузка) — reload netifd и ifup
setup
ht_fake ubus 'exit 0'
ht_hook configure CREAM_REASON=apply
check "ubus call network reload" ht_called '^ubus call network reload'
setup
ht_fake ubus 'exit 0'
HT_PHASE=build ht_hook configure CREAM_REASON=install
check_not "в сборке netifd не трогаем" ht_called '^ubus call'

# --- configure: битый секрет — отказ
setup
ht_secret AMNEZIAWG_PRIVATE_KEY "not-a-key"
ht_hook configure CREAM_REASON=boot; rc=$?
check "битый ключ — сбой" test "$rc" -ne 0

# --- чужая секция с тем же именем (lan, wan) не трогается
setup
printf '%s\n' "network.lan=interface" "network.lan.proto=static" > "$FAKE/network.show"
ht_hook configure CREAM_REASON=apply AMNEZIAWG_IFACE=lan; rc=$?
check "AMNEZIAWG_IFACE=lan (proto static) — сбой" test "$rc" -ne 0
check "причина названа" grep -q 'network.lan' "$ROOT/out"
check_not "lan не удалён" has_line "delete network.lan"
setup
printf 'lan\n' > "$ROOT/var/lib/cream/ext/amneziawg/iface"
printf '%s\n' "network.lan=interface" "network.lan.proto=static" > "$FAKE/network.show"
ht_hook remove; eq "remove с чужим прежним именем — 0" 0 "$?"
check_not "remove: lan не удалён" has_line "delete network.lan"
setup
printf 'lan\n' > "$ROOT/var/lib/cream/ext/amneziawg/iface"
printf '%s\n' "network.lan=interface" "network.lan.proto=static" > "$FAKE/network.show"
ht_hook configure CREAM_REASON=apply; eq "configure: чужое прежнее имя пропущено — 0" 0 "$?"
check_not "configure: lan не удалён" has_line "delete network.lan"
check "свой интерфейс записан" has_line "set network.awg0=interface"

# --- configure: uci не записал интерфейс — сбой, а не «записан»
setup
ht_fake uci 'case "$*" in *" batch") cat > /dev/null ;; esac; exit 0'
ht_hook configure CREAM_REASON=boot; rc=$?
check "batch без записи — сбой" test "$rc" -ne 0

# --- remove
setup
printf 'awg0\n' > "$ROOT/var/lib/cream/ext/amneziawg/iface"
printf '%s\n' "network.awg0=interface" "network.awg0.proto=amneziawg" "network.awg0_peer=amneziawg_awg0" > "$FAKE/network.show"
ht_hook remove; eq "remove — 0" 0 "$?"
check "интерфейс удалён" has_line "delete network.awg0"
check "пир удалён" has_line "delete network.awg0_peer"
check "commit" has_line "commit network"

# --- pubkey
setup
ht_action pubkey; rc=$?
check "pubkey без ключа — сбой" test "$rc" -ne 0
printf '%s\n' "$GEN" > "$ROOT/var/lib/cream/ext/amneziawg/private.key"
ht_action pubkey; eq "pubkey — 0" 0 "$?"
eq "pubkey через awg pubkey (stdin)" "pub-of-$GEN" "$(cat "$ROOT/out")"
check_not "ключ не в argv awg" grep -qF "$GEN" "$FAKE/awg.argv"

ht_done
