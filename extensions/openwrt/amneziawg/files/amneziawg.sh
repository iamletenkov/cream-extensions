#!/bin/sh
# amneziawg: the code of the hooks and the action (POSIX sh, busybox ash on
# OpenWrt). Called as `amneziawg.sh install|configure|remove|pubkey`.
#
# The keys come from cream: the non-secret ones in the environment, the secret
# ones (AMNEZIAWG_PRIVATE_KEY, AMNEZIAWG_PEER_PRESHARED_KEY) from
# CREAM_SECRETS_FILE. Every value goes to `uci batch` on stdin inside single
# quotes — the types of the keys admit no quote, backslash, space or newline,
# so a secret is never in argv and a value never breaks the batch.
#
# The private key: the secret if given, otherwise one generated on the machine
# (awg genkey) at the first configure and kept in $CREAM_STATE_DIR/private.key
# (0600) — one key per machine, never one key for the whole image run. The
# state is kept over sysupgrade by /lib/upgrade/keep.d/amneziawg.
set -eu

R="${CREAM_ROOT:-}"
R="${R%/}"
CONF="$R/etc/config"
STATE="${CREAM_STATE_DIR:?run by cream}"
SECRETS="${CREAM_SECRETS_FILE:-}"
IFACE="${AMNEZIAWG_IFACE:-awg0}"
KEY_RE='^[A-Za-z0-9+/]\{42\}[AEIMQUYcgkosw480]=$'

warn() { echo "amneziawg: $*" >&2; }
die() {
	echo "amneziawg: $*" >&2
	exit 1
}

# secret KEY: the value of a secret key (KEY=value or KEY="value" lines).
secret() {
	[ -n "$SECRETS" ] && [ -f "$SECRETS" ] || return 0
	sed -n "s/^$1=//p" "$SECRETS" | tail -n 1 | sed 's/^"\(.*\)"$/\1/'
}

# is_key VALUE: a WireGuard key in base64.
is_key() { printf '%s\n' "$1" | grep -q "$KEY_RE"; }

# ubus_up: netifd answers (not in a container, not in the image).
ubus_up() { command -v ubus >/dev/null 2>&1 && ubus -t 2 list network >/dev/null 2>&1; }

# peer_sections IFACE: the names of the peer sections of the interface; -X
# names the anonymous ones (LuCI, manual edits) cfgXXXXXX, which delete accepts.
peer_sections() {
	uci -q -X -c "$CONF" show network 2>/dev/null |
		sed -n "s/^network\.\([A-Za-z0-9_]*\)=amneziawg_$1\$/\1/p"
}

# foreign IFACE: the section network.IFACE exists and is not ours (lan, wan…):
# the extension never deletes or rewrites it.
foreign() {
	uci -q -c "$CONF" get "network.$1" >/dev/null 2>&1 || return 1
	[ "$(uci -q -c "$CONF" get "network.$1.proto" 2>/dev/null || true)" != amneziawg ]
}

# drop_iface IFACE: delete commands for the interface and its peers; a foreign
# section of that name is left alone with a warning.
drop_iface() {
	if foreign "$1"; then
		warn "network.$1 — не интерфейс amneziawg, не трогаю"
		return 0
	fi
	if uci -q -c "$CONF" get "network.$1" >/dev/null 2>&1; then
		echo "delete network.$1"
	fi
	for s in $(peer_sections "$1"); do
		echo "delete network.$s"
	done
}

private_key() {
	key="$(secret AMNEZIAWG_PRIVATE_KEY)"
	if [ -n "$key" ]; then
		is_key "$key" || die "AMNEZIAWG_PRIVATE_KEY — не ключ base64"
		printf '%s\n' "$key"
		return 0
	fi
	if [ ! -s "$STATE/private.key" ]; then
		mkdir -p "$STATE"
		chmod 0700 "$STATE"
		(
			umask 077
			awg genkey >"$STATE/private.key.new"
		)
		mv -f "$STATE/private.key.new" "$STATE/private.key"
		warn "сгенерирован закрытый ключ машины ($STATE/private.key); открытый — cream run amneziawg pubkey"
	fi
	key="$(cat "$STATE/private.key")"
	is_key "$key" || die "$STATE/private.key — не ключ base64"
	printf '%s\n' "$key"
}

cmd_install() {
	missing=""
	for p in kmod-amneziawg amneziawg-tools; do
		apk info -e "$p" >/dev/null 2>&1 || missing="$missing $p"
	done
	if [ -n "$missing" ]; then
		warn "в образе нет пакетов:$missing — нужен образ openwrt-builder v0.3.0+ (модуль собран под ядро выпуска, в фидах OpenWrt его нет)"
		exit 20
	fi
	mkdir -p "$STATE"
	chmod 0700 "$STATE"
	# A key given at the image build stays in the image (secrets of the domain,
	# then uci): every machine of the image gets the same one.
	if [ "${CREAM_PHASE:-}" = build ] && [ -n "$(secret AMNEZIAWG_PRIVATE_KEY)" ]; then
		warn "AMNEZIAWG_PRIVATE_KEY задан при сборке образа — один ключ на все машины образа; оставьте его пустым (ключ сгенерируется на первой загрузке) или задайте на машине: cream set amneziawg AMNEZIAWG_PRIVATE_KEY=-"
	fi
}

# desired: the uci commands of the interface and its peer from the keys
# (globals of cmd_configure: key, psk, host, port).
desired() {
	echo "set network.$IFACE=interface"
	echo "set network.$IFACE.proto='amneziawg'"
	echo "set network.$IFACE.private_key='$key'"
	for a in ${AMNEZIAWG_ADDRESSES:-}; do echo "add_list network.$IFACE.addresses='$a'"; done
	for o in LISTEN_PORT:listen_port MTU:mtu JC:awg_jc JMIN:awg_jmin JMAX:awg_jmax S1:awg_s1 S2:awg_s2 \
		S3:awg_s3 S4:awg_s4 H1:awg_h1 H2:awg_h2 H3:awg_h3 H4:awg_h4; do
		eval "v=\${AMNEZIAWG_${o%%:*}:-}"
		[ -z "$v" ] || echo "set network.$IFACE.${o#*:}='$v'"
	done
	if [ -n "${AMNEZIAWG_PEER_PUBLIC_KEY:-}" ]; then
		p="${IFACE}_peer"
		echo "set network.$p=amneziawg_$IFACE"
		echo "set network.$p.description='cream amneziawg'"
		echo "set network.$p.public_key='$AMNEZIAWG_PEER_PUBLIC_KEY'"
		[ -z "$psk" ] || echo "set network.$p.preshared_key='$psk'"
		for a in ${AMNEZIAWG_PEER_ALLOWED_IPS:-}; do echo "add_list network.$p.allowed_ips='$a'"; done
		echo "set network.$p.route_allowed_ips='${AMNEZIAWG_ROUTE_ALLOWED_IPS:-0}'"
		[ -z "$host" ] || echo "set network.$p.endpoint_host='$host'"
		[ -z "$port" ] || echo "set network.$p.endpoint_port='$port'"
		[ -z "${AMNEZIAWG_PEER_KEEPALIVE:-}" ] || echo "set network.$p.persistent_keepalive='$AMNEZIAWG_PEER_KEEPALIVE'"
	fi
}

# in_place: the interface (and its peer, if one is set) is in the network config.
in_place() {
	[ "$(uci -q -c "$CONF" get "network.$IFACE.proto" 2>/dev/null || true)" = amneziawg ] || return 1
	[ -z "${AMNEZIAWG_PEER_PUBLIC_KEY:-}" ] || uci -q -c "$CONF" get "network.${IFACE}_peer" >/dev/null 2>&1
}

cmd_configure() {
	if foreign "$IFACE"; then
		die "network.$IFACE уже есть и это не amneziawg (proto $(uci -q -c "$CONF" get "network.$IFACE.proto" 2>/dev/null || echo '?')) — выберите другое AMNEZIAWG_IFACE"
	fi
	key="$(private_key)"
	psk="$(secret AMNEZIAWG_PEER_PRESHARED_KEY)"
	[ -z "$psk" ] || is_key "$psk" || die "AMNEZIAWG_PEER_PRESHARED_KEY — не ключ base64"
	prev="$(cat "$STATE/iface" 2>/dev/null || true)"
	[ -n "${AMNEZIAWG_ADDRESSES:-}" ] || warn "AMNEZIAWG_ADDRESSES пуст — у интерфейса $IFACE нет адреса"
	[ -n "${AMNEZIAWG_PEER_PUBLIC_KEY:-}" ] || warn "AMNEZIAWG_PEER_PUBLIC_KEY пуст — интерфейс $IFACE без пира"
	host=""
	port=""
	if [ -n "${AMNEZIAWG_PEER_ENDPOINT:-}" ]; then
		host="${AMNEZIAWG_PEER_ENDPOINT%:*}"
		port="${AMNEZIAWG_PEER_ENDPOINT##*:}"
		host="${host#[}"
		host="${host%]}"
	fi
	body="$(desired)"
	sum="$(printf '%s\n' "$body" | sha256sum | cut -d' ' -f1)"
	[ -n "$sum" ] || die "sha256sum не дал отпечаток"
	# Every boot (stage system, S95 — after S47 wrt.cloudinit, which purges
	# /etc/config/network when it provisions a seed): the interface in place and
	# the same keys — nothing to write, manual edits stay; gone — written again.
	if [ "${CREAM_REASON:-}" = boot ] && [ "$(cat "$STATE/applied" 2>/dev/null || true)" = "$sum" ] && in_place; then
		echo "amneziawg: интерфейс $IFACE на месте, настройки те же — не переписываю"
		return 0
	fi
	if [ -e "$CONF/network" ]; then
		chmod 0600 "$CONF/network"
	fi
	{
		if [ -n "$prev" ] && [ "$prev" != "$IFACE" ]; then drop_iface "$prev"; fi
		drop_iface "$IFACE"
		printf '%s\n' "$body"
		echo "commit network"
	} | uci -c "$CONF" batch >/dev/null
	# uci batch answers 0 even when a command inside failed: check the result.
	[ "$(uci -q -c "$CONF" get "network.$IFACE.proto" 2>/dev/null || true)" = amneziawg ] ||
		die "uci не записал network.$IFACE в /etc/config/network"
	printf '%s\n' "$IFACE" >"$STATE/iface"
	printf '%s\n' "$sum" >"$STATE/applied"
	echo "amneziawg: интерфейс $IFACE записан в /etc/config/network"
	# On the live machine netifd runs at S95 too (since S20network): reload.
	if [ "${CREAM_PHASE:-}" = live ] && ubus_up; then
		ubus call network reload || warn "ubus call network reload не прошёл — $IFACE поднимется после перезагрузки"
		(ifup "$IFACE" >/dev/null 2>&1 &)
	elif [ "${CREAM_PHASE:-}" = live ]; then
		warn "netifd не отвечает — $IFACE поднимется после ubus call network reload или перезагрузки"
	fi
}

cmd_remove() {
	prev="$(cat "$STATE/iface" 2>/dev/null || true)"
	for i in $prev $IFACE; do
		foreign "$i" && continue
		if [ "${CREAM_PHASE:-}" = live ] && ubus_up; then
			ifdown "$i" >/dev/null 2>&1 || true
		fi
	done
	{
		[ -z "$prev" ] || [ "$prev" = "$IFACE" ] || drop_iface "$prev"
		drop_iface "$IFACE"
		echo "commit network"
	} | uci -c "$CONF" batch >/dev/null
	if [ "${CREAM_PHASE:-}" = live ] && ubus_up; then
		ubus call network reload
	fi
	rm -f "$STATE/iface" "$STATE/applied"
}

cmd_pubkey() {
	key="$(secret AMNEZIAWG_PRIVATE_KEY)"
	if [ -z "$key" ]; then
		[ -s "$STATE/private.key" ] || die "ключа ещё нет: configure не запускался (cream configure amneziawg)"
		key="$(cat "$STATE/private.key")"
	fi
	printf '%s\n' "$key" | awg pubkey
}

case "${1:-}" in
install) cmd_install ;;
configure) cmd_configure ;;
remove) cmd_remove ;;
pubkey) cmd_pubkey ;;
*) die "использование: amneziawg.sh install|configure|remove|pubkey" ;;
esac
