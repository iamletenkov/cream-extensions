#!/bin/sh
# podkop: the code of the hooks (POSIX sh, busybox ash on OpenWrt). Called as
# `podkop.sh install|configure|remove`.
#
# The keys come from cream: the non-secret ones in the environment, the link
# PODKOP_PROXY_STRING from CREAM_SECRETS_FILE. Every value goes to `uci batch`
# on stdin inside single quotes — the types admit no quote, backslash, space
# or newline, so the link is never in argv and never breaks the batch.
# /etc/config/podkop is 0600: the link carries the credentials of the proxy.
set -eu

R="${CREAM_ROOT:-}"
R="${R%/}"
CONF="$R/etc/config"
SECRETS="${CREAM_SECRETS_FILE:-}"
INIT="$R/etc/init.d/podkop"

warn() { echo "podkop: $*" >&2; }

# secret KEY: the value of a secret key (KEY=value or KEY="value" lines).
secret() {
	[ -n "$SECRETS" ] && [ -f "$SECRETS" ] || return 0
	sed -n "s/^$1=//p" "$SECRETS" | tail -n 1 | sed 's/^"\(.*\)"$/\1/'
}

live() { [ "${CREAM_PHASE:-}" = live ] && [ "${CREAM_REASON:-}" != boot ]; }

# service enable|disable: the rc.d link; on the live machine also start/stop
# in the background (podkop downloads its lists — never wait for it).
service() {
	[ -x "$INIT" ] || return 0
	"$INIT" "$1" || true
	if live || { [ "${CREAM_PHASE:-}" = live ] && [ "$1" = disable ]; }; then
		case "$1" in
		enable) ("$INIT" restart >/dev/null 2>&1 &) ;;
		disable) ("$INIT" stop >/dev/null 2>&1 &) ;;
		esac
	fi
}

cmd_install() {
	missing=""
	for p in podkop sing-box; do
		apk info -e "$p" >/dev/null 2>&1 || missing="$missing $p"
	done
	if [ -n "$missing" ]; then
		warn "в образе нет пакетов:$missing — нужен образ openwrt-builder v0.3.0+"
		exit 20
	fi
}

cmd_configure() {
	type="${PODKOP_CONNECTION_TYPE:-proxy}"
	link="$(secret PODKOP_PROXY_STRING)"
	iface="${PODKOP_INTERFACE:-}"
	ready=1
	case "$type" in
	proxy) [ -n "$link" ] || {
		warn "режим proxy без PODKOP_PROXY_STRING — podkop выключен"
		ready=0
	} ;;
	vpn) [ -n "$iface" ] || {
		warn "режим vpn без PODKOP_INTERFACE — podkop выключен"
		ready=0
	} ;;
	*)
		warn "PODKOP_CONNECTION_TYPE=$type — ждали proxy или vpn"
		exit 1
		;;
	esac
	[ -e "$CONF/podkop" ] || : >"$CONF/podkop"
	chmod 0600 "$CONF/podkop"
	{
		echo "set podkop.main=section"
		echo "set podkop.settings=settings"
		echo "set podkop.main.connection_type='$type'"
		for o in proxy_string interface community_lists user_domains user_subnets \
			user_domain_list_type user_subnet_list_type; do
			echo "delete podkop.main.$o"
		done
		echo "delete podkop.settings.source_network_interfaces"
		if [ "$type" = proxy ]; then
			echo "set podkop.main.proxy_config_type='url'"
			[ -z "$link" ] || echo "set podkop.main.proxy_string='$link'"
		else
			[ -z "$iface" ] || echo "set podkop.main.interface='$iface'"
		fi
		for l in ${PODKOP_COMMUNITY_LISTS:-}; do echo "add_list podkop.main.community_lists='$l'"; done
		if [ -n "${PODKOP_USER_DOMAINS:-}" ]; then
			echo "set podkop.main.user_domain_list_type='dynamic'"
			for d in $PODKOP_USER_DOMAINS; do echo "add_list podkop.main.user_domains='$d'"; done
		fi
		if [ -n "${PODKOP_USER_SUBNETS:-}" ]; then
			echo "set podkop.main.user_subnet_list_type='dynamic'"
			for s in $PODKOP_USER_SUBNETS; do echo "add_list podkop.main.user_subnets='$s'"; done
		fi
		for i in ${PODKOP_SOURCE_INTERFACES:-}; do echo "add_list podkop.settings.source_network_interfaces='$i'"; done
		echo "commit podkop"
	} | uci -q -c "$CONF" batch >/dev/null 2>&1 || true
	# `delete` of an absent option fails inside the batch but the rest is
	# applied; the commit is checked here, not by the status of the batch.
	got="$(uci -q -c "$CONF" get podkop.main.connection_type || true)"
	[ "$got" = "$type" ] || {
		warn "uci не записал /etc/config/podkop"
		exit 1
	}
	if [ "$ready" = 1 ]; then
		service enable
		echo "podkop: режим $type записан в /etc/config/podkop"
	else
		service disable
	fi
}

cmd_remove() {
	{
		echo "delete podkop.main.proxy_string"
		echo "delete podkop.main.interface"
		echo "commit podkop"
	} | uci -q -c "$CONF" batch >/dev/null 2>&1 || true
	service disable
}

case "${1:-}" in
install) cmd_install ;;
configure) cmd_configure ;;
remove) cmd_remove ;;
*)
	warn "использование: podkop.sh install|configure|remove"
	exit 1
	;;
esac
