#!/bin/sh
# Scenario of tools/test-openwrt.sh, part 1 of 2: sysupgrade with kept settings
# of a robot (teleport-openwrt + stvor-agent-openwrt, ruling Р4 as revised by the
# owner 2026-10-23). A registered node and an enabled agent are laid out (the
# registration and the tokens are fakes of the same paths and modes), then the
# real `sysupgrade -b` of the image makes the archive of the kept settings into
# /out (writable). Part 2 (scenario-sysupgrade-restore.sh) unpacks it in a fresh
# container of the same image, as preinit does on the first boot of a new firmware.
set -eu

step() { echo "== $*"; }
fail() {
	echo "FAIL: $*" >&2
	exit 1
}
tree_sum() { find "$1" -type f | sort | xargs sha256sum | sha256sum | cut -c1-64; }

. /etc/os-release
step "окружение: $PRETTY_NAME, pid1=$(cat /proc/1/comm)"
mkdir -p /var/run /var/lock
[ -e /run ] || ln -s /var/run /run

step "cream, источник core, наборы-подделки teleport и агента"
cp /t/cream /usr/bin/cream
chmod 0755 /usr/bin/cream
cream system init
mkdir -p /opt/catalog
cp -r /catalog/cream-catalog.yaml /catalog/extensions /opt/catalog/
cream source add core --path /opt/catalog --sync
mkdir -p /opt/set/teleport/lib
# The fake teleport logs every call: after the restore only `version` may be seen.
printf '#!/bin/sh\necho "$*" >>/opt/teleport-calls\necho "Teleport v18.10.0 git:fake go1.25"\n' >/opt/set/teleport/teleport
printf '#!/bin/sh\necho fdpass\n' >/opt/set/teleport/fdpass-teleport
echo glibc >/opt/set/teleport/lib/libc.so.6
chmod 0755 /opt/set/teleport/teleport /opt/set/teleport/fdpass-teleport
tar -czf /out/set.tar.gz -C /opt/set teleport
mkdir -p /opt/agent/init.d
cat >/opt/agent/stvor-agent <<'AGENT'
#!/bin/sh
case "$1" in
version) [ "${2:-}" = --label ] && exit 0; echo "stvor-agent 4.1.0 (fake)" ;;
esac
exit 0
AGENT
for s in stvor-agent stvor-agent-telemetry; do
	printf '#!/bin/sh /etc/rc.common\nUSE_PROCD=1\nSTART=99\nSTOP=01\nstart_service() {\n\t[ -f /etc/%s/token ] || return 0\n\tprocd_open_instance\n\tprocd_set_param command /usr/bin/stvor-agent run\n\tprocd_close_instance\n}\n' \
		"$s" >"/opt/agent/init.d/$s"
done
chmod 0755 /opt/agent/stvor-agent /opt/agent/init.d/*
tar -czf /out/agent.tar.gz -C /opt/agent stvor-agent init.d

step "установка расширений, как команда портала"
cream install teleport-openwrt TELEPORT_SHA256="$(sha256sum /out/set.tar.gz | cut -d' ' -f1)" TELEPORT_TARBALL=/out/set.tar.gz
cream install stvor-agent-openwrt STVOR_AGENT_VERSION=4.1.0 STVOR_AGENT_SHA256="$(sha256sum /out/agent.tar.gz | cut -d' ' -f1)" \
	STVOR_AGENT_TARBALL=/out/agent.tar.gz
out=$(printf '%s' 'abcdefgh1-join-token' | CREAM_PHASE=live cream run teleport-openwrt join \
	TELEPORT_PROXY=teleport.example.org TELEPORT_REGISTRATION_SECRET=- TELEPORT_DEFER=1 TELEPORT_NODENAME=owrt-1 TELEPORT_ENV=dev)
echo "$out" | grep -q '"result":"deferred"' || fail "join: $out"
CREAM_PHASE=live cream set stvor-agent-openwrt STVOR_AGENT_INTERVAL=120

step "регистрация узла и токены агента (подделки тех же путей и прав)"
# What a confirmed join leaves: the identity in data_dir and the flag agent-enabled.
mkdir -p /opt/teleport/data/proc
echo 55555555-6666-7777-8888-999999999999 >/opt/teleport/data/host_uuid
echo identity >/opt/teleport/data/proc/sqlite.db
chmod 0600 /opt/teleport/data/host_uuid /opt/teleport/data/proc/sqlite.db
: >/opt/cream/var/ext/teleport-openwrt/agent-enabled
chmod 0600 /opt/cream/var/ext/teleport-openwrt/agent-enabled
mkdir -m 0700 /etc/stvor-agent
printf 'url=https://stvor.example.org/robot-api/v1/labels\ntoken=labels-secret\n' >/etc/stvor-agent/token
chmod 0600 /etc/stvor-agent/token
printf 'url=https://stvor.example.org/robot-api\ntoken=telemetry-secret\n' >/etc/stvor-agent-telemetry/token
chown root:stvor-telemetry /etc/stvor-agent-telemetry/token
chmod 0640 /etc/stvor-agent-telemetry/token
echo '{"schema":1}' >/opt/stvor-agent/state.json
echo fingerprint >/opt/stvor-agent/telemetry-token.src
echo 0123456789abcdef >/opt/stvor-agent/machine-id
chmod 0600 /opt/stvor-agent/state.json /opt/stvor-agent/telemetry-token.src
chown root:stvor-telemetry /opt/stvor-agent/machine-id
chmod 0640 /opt/stvor-agent/machine-id
{
	echo "UUID=$(cat /opt/teleport/data/host_uuid)"
	echo "DATA=$(tree_sum /opt/teleport/data)"
	echo "TUID=$(awk -F: '$1 == "stvor-telemetry" { print $3 }' /etc/passwd)"
} >/out/expect

step "sysupgrade -b: архив сохраняемых настроек"
sysupgrade -b /out/backup.tgz >/dev/null 2>&1 || fail "sysupgrade -b"
tar -tzf /out/backup.tgz | sed 's|^\./||' >/out/backup.list
for p in opt/teleport/data/host_uuid opt/teleport/data/proc/sqlite.db opt/teleport/.cream-owned \
	opt/cream/var/ext/teleport-openwrt/agent-enabled opt/cream/var/ext/teleport-openwrt/installed-pin \
	etc/cream/teleport-openwrt/config opt/stvor-agent/machine-id opt/stvor-agent/state.json opt/stvor-agent/telemetry-token.src \
	etc/stvor-agent/token etc/stvor-agent-telemetry/token etc/cream/stvor-agent-openwrt/config \
	opt/cream/var/ext/stvor-agent-openwrt/user-created etc/passwd; do
	grep -qx "$p" /out/backup.list || fail "в архиве нет $p"
done
for p in usr/bin/cream etc/init.d/teleport opt/teleport/bin/teleport opt/cream/var/installed \
	opt/cream/var/ext/teleport-openwrt/registration-secret etc/cream/teleport-openwrt/command-labels.d/stvor_agent; do
	if grep -q "^$p" /out/backup.list; then fail "в архиве лишнее $p"; fi
done
chmod 0644 /out/*
echo "OK"
