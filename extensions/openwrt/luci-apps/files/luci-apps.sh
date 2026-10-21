#!/bin/sh
# luci-apps: the code of the hooks (POSIX sh, busybox ash on OpenWrt). Called
# as `luci-apps.sh install|remove`.
#
# $CREAM_STATE_DIR/added — the packages this extension added (one per line):
# remove and a shorter list take away only them, never a package of the image
# or of a neighbour. The names come from LUCI_APPS_PACKAGES, whose type admits
# only luci-(app|theme|proto|i18n|mod)-<name>.
set -eu

R="${CREAM_ROOT:-}"
R="${R%/}"
STATE="${CREAM_STATE_DIR:?run by cream}"
ADDED="$STATE/added"

warn() { echo "luci-apps: $*" >&2; }
die() {
	echo "luci-apps: $*" >&2
	exit 1
}

has() { apk info -e "$1" >/dev/null 2>&1; }
in_list() {
	for x in $2; do [ "$x" = "$1" ] && return 0; done
	return 1
}

# save PKG…: the packages of this extension, one per line, atomically.
save() {
	: >"$ADDED.new"
	for p in "$@"; do printf '%s\n' "$p" >>"$ADDED.new"; done
	mv -f "$ADDED.new" "$ADDED"
}

# refresh: drop the LuCI caches and reload rpcd — live machine only.
refresh() {
	[ "${CREAM_PHASE:-}" = live ] || return 0
	rm -rf "$R/tmp/luci-indexcache" "$R/tmp/luci-modulecache" 2>/dev/null || true
	rm -f "$R"/tmp/luci-indexcache.* 2>/dev/null || true
	if [ -x "$R/etc/init.d/rpcd" ]; then
		("$R/etc/init.d/rpcd" reload >/dev/null 2>&1 &)
	fi
}

cmd_install() {
	for f in "$R/etc/apk/config" ${APK_CONFIG:+"$APK_CONFIG"}; do
		if [ -f "$f" ] && grep -q '^[[:space:]]*allow-untrusted' "$f"; then
			die "$f разрешает неподписанные пакеты (allow-untrusted) — отказ: ставим только из подписанных фидов"
		fi
	done
	mkdir -p "$STATE"
	want="${LUCI_APPS_PACKAGES:-}"
	prev="$(cat "$ADDED" 2>/dev/null || true)"
	# keep — ours and still wanted; drop — ours, no longer wanted and still
	# installed (one taken away by hand is just forgotten: apk del of an absent
	# package fails).
	drop=""
	keep=""
	for p in $prev; do
		if in_list "$p" "$want"; then
			in_list "$p" "$keep" || keep="$keep $p"
		elif has "$p"; then
			drop="$drop $p"
		fi
	done
	missing=""
	for p in $want; do
		has "$p" || in_list "$p" "$missing" || missing="$missing $p"
	done
	if [ -n "$drop" ]; then
		echo "luci-apps: снимаю:$drop"
		# shellcheck disable=SC2086 # names checked by the key type
		apk del $drop
	fi
	# Ours from now on: kept ones that are still installed (a failed apk add
	# below must not leave the dropped ones in the list).
	save $keep
	if [ -n "$missing" ]; then
		echo "luci-apps: ставлю:$missing"
		apk update
		# shellcheck disable=SC2086 # names checked by the key type
		apk add $missing
		# A package of the list that was ours and taken away by hand is in keep
		# and in missing: in_list keeps it once.
		mine="$keep"
		for p in $missing; do in_list "$p" "$mine" || mine="$mine $p"; done
		# shellcheck disable=SC2086 # names checked by the key type
		save $mine
	fi
	if [ -n "$drop$missing" ]; then refresh; fi
}

cmd_remove() {
	prev="$(cat "$ADDED" 2>/dev/null || true)"
	now=""
	for p in $prev; do
		has "$p" && now="$now $p"
	done
	if [ -n "$now" ]; then
		echo "luci-apps: снимаю:$now"
		# shellcheck disable=SC2086 # names from the state, checked at install
		apk del $now
		refresh
	fi
	rm -f "$ADDED"
}

case "${1:-}" in
install) cmd_install ;;
remove) cmd_remove ;;
*) die "использование: luci-apps.sh install|remove" ;;
esac
