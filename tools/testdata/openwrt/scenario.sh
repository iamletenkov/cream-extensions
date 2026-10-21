#!/bin/sh
# Scenario of tools/test-openwrt.sh inside the container with the root FS of
# openwrt-builder v0.3.0 (busybox sh). /t (read-only) — the cream binary;
# /catalog (read-only) — this repository.
set -eu

step() { echo "== $*"; }
fail() {
	echo "FAIL: $*" >&2
	exit 1
}
has() { [ -e "$1" ] || fail "нет $1"; }
hasnt() { [ ! -e "$1" ] || fail "лишнее $1"; }
eq() { [ "$2" = "$3" ] || fail "$1: ждали «$2», получили «$3»"; }
mode() { ls -l "$1" | cut -c1-10; }
uget() { uci -q get "$1" 2>/dev/null || true; }

PEER="$(printf "%042d" 0 | tr 0 s)A="
LINK='vless://0b7e6c2a-1111-4222-8333-944445555666@proxy.example.org:443?security=reality&sni=example.org#x'

. /etc/os-release
step "окружение: $PRETTY_NAME, pid1=$(cat /proc/1/comm)"
[ "$ID" = openwrt ] || fail "не OpenWrt: $ID"
for p in kmod-amneziawg amneziawg-tools podkop sing-box; do
	apk info -e "$p" >/dev/null || fail "в образе нет пакета $p"
done

step "cream: бинарь, system init, источник core"
cp /t/cream /usr/bin/cream
chmod 0755 /usr/bin/cream
cream version
cream system init
mkdir -p /opt/catalog
cp -r /catalog/cream-catalog.yaml /catalog/extensions /opt/catalog/
cream source add core --path /opt/catalog --sync

step "фаза build: amneziawg, podkop, luci-apps ставятся; configure только включён"
cream install amneziawg AMNEZIAWG_ADDRESSES=10.8.0.2/32 AMNEZIAWG_PEER_PUBLIC_KEY=$PEER \
	AMNEZIAWG_PEER_ENDPOINT=vpn.example.org:51820 AMNEZIAWG_JC=4 AMNEZIAWG_H1=100-200
cream install podkop PODKOP_CONNECTION_TYPE=vpn PODKOP_INTERFACE=awg0
cream install luci-apps
has /opt/cream/var/stages/early/amneziawg
has /opt/cream/var/stages/system/podkop
has /lib/upgrade/keep.d/amneziawg
hasnt /opt/cream/var/ext/amneziawg/private.key
eq "в сборке uci не тронут" "" "$(uget network.awg0.proto)"
cream remove luci-apps

step "расширение семейства deb на OpenWrt — отказ"
if cream install yq 2>/tmp/deb.err; then fail "расширение deb поставилось на OpenWrt"; fi
grep -q 'platform' /tmp/deb.err || fail "отказ deb без причины: $(cat /tmp/deb.err)"

step "загрузка: S10boot сделал бы /etc/config/network и /var/lock — заготовка"
mkdir -p /var/lock /var/run
cat >/etc/config/network <<'EOF'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	option ipaddr '192.168.1.1'
	option netmask '255.255.255.0'
EOF
/etc/rc.d/S19cream-configure-early boot
eq "proto" amneziawg "$(uget network.awg0.proto)"
eq "адрес" 10.8.0.2/32 "$(uget network.awg0.addresses)"
eq "Jc" 4 "$(uget network.awg0.awg_jc)"
eq "H1" 100-200 "$(uget network.awg0.awg_h1)"
eq "пир" "$PEER" "$(uget network.awg0_peer.public_key)"
eq "endpoint" vpn.example.org "$(uget network.awg0_peer.endpoint_host)"
eq "маршруты не наши" 0 "$(uget network.awg0_peer.route_allowed_ips)"
key=$(cat /opt/cream/var/ext/amneziawg/private.key)
eq "ключ машины в uci" "$key" "$(uget network.awg0.private_key)"
eq "ключ 0600" -rw------- "$(mode /opt/cream/var/ext/amneziawg/private.key)"
eq "lan не тронут" 192.168.1.1 "$(uget network.lan.ipaddr)"
pub=$(CREAM_PHASE=live cream run amneziawg pubkey)
[ "$pub" = "$(echo "$key" | awg pubkey)" ] || fail "pubkey: $pub"

/etc/rc.d/S95cream-configure boot
eq "podkop vpn" vpn "$(uget podkop.main.connection_type)"
eq "podkop interface" awg0 "$(uget podkop.main.interface)"
eq "podkop сообщества" russia_inside "$(uget podkop.main.community_lists)"
eq "podkop источник" br-lan "$(uget podkop.settings.source_network_interfaces)"
eq "podkop настройки образа на месте" 77.88.8.8 "$(uget podkop.settings.dns_server)"
has /etc/rc.d/S99podkop
eq "/etc/config/podkop 0600" -rw------- "$(mode /etc/config/podkop)"

step "вторая загрузка: configure пропущены по отметке"
uci set network.awg0.mtu=1280
uci commit network
/etc/rc.d/S19cream-configure-early boot
eq "configure не повторялся" 1280 "$(uget network.awg0.mtu)"

step "cream set: proxy без ссылки — podkop выключен; со ссылкой — включён"
CREAM_PHASE=live cream set podkop PODKOP_CONNECTION_TYPE=proxy
hasnt /etc/rc.d/S99podkop
eq "proxy" proxy "$(uget podkop.main.connection_type)"
eq "interface снят" "" "$(uget podkop.main.interface)"
printf "%s\n" "$LINK" | CREAM_PHASE=live cream set podkop PODKOP_PROXY_STRING=-
eq "ссылка" "$LINK" "$(uget podkop.main.proxy_string)"
has /etc/rc.d/S99podkop

step "luci-apps: allow-untrusted в /etc/apk/config — отказ"
echo allow-untrusted >>/etc/apk/config
if cream install luci-apps LUCI_APPS_PACKAGES=luci-app-ttyd 2>/tmp/la.err; then fail "luci-apps с allow-untrusted"; fi
grep -q allow-untrusted /tmp/la.err || fail "отказ без причины: $(cat /tmp/la.err)"
sed -i '/^allow-untrusted$/d' /etc/apk/config
cream remove --forget luci-apps 2>/dev/null || true

step "remove: интерфейс и ссылка убраны, пакеты образа на месте"
CREAM_PHASE=live cream remove podkop
eq "ссылка снята" "" "$(uget podkop.main.proxy_string)"
hasnt /etc/rc.d/S99podkop
CREAM_PHASE=live cream remove amneziawg
eq "интерфейса нет" "" "$(uget network.awg0)"
eq "пира нет" "" "$(uget network.awg0_peer)"
hasnt /lib/upgrade/keep.d/amneziawg
apk info -e kmod-amneziawg >/dev/null || fail "пакет образа снят"
echo "OK"
