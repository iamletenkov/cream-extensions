#!/bin/sh
# Scenario of tools/test-openwrt.sh for stvor-agent-openwrt inside the container
# with the root FS of openwrt-builder v0.3.1 (busybox, rc.common, the real
# /lib/functions.sh). /t (read-only) — the cream binary and, when given, the
# delivery of the agent /t/agent.tar.gz (OPENWRT_AGENT_TARBALL of
# tools/test-openwrt.sh: stvor-agent_<v>_linux_amd64.tar.gz of the agent's
# repository — the real binary and its procd init scripts); without it the
# delivery is a fake of the same layout. /catalog (read-only) — the staged tree.
# procd is not PID 1: services are enabled (rc.d) but not started; the boot and
# the labels from the portal are checked on a VM (README of the extension).
set -eu

step() { echo "== $*"; }
fail() {
	echo "FAIL: $*" >&2
	exit 1
}
has() { [ -e "$1" ] || fail "нет $1"; }
hasnt() { [ ! -e "$1" ] && [ ! -L "$1" ] || fail "лишнее $1"; }
eq() { [ "$2" = "$3" ] || fail "$1: ждали «$2», получили «$3»"; }
mode() { ls -ld "$1" | cut -c1-10; }
owner() { ls -ld "$1" | awk '{print $3 ":" $4}'; }

. /etc/os-release
step "окружение: $PRETTY_NAME, pid1=$(cat /proc/1/comm)"
# What /etc/init.d/boot makes on a machine: /var/run, /var/lock, /run -> /var/run.
mkdir -p /var/run /var/lock
[ -e /run ] || ln -s /var/run /run

step "cream, источник core, teleport-openwrt из набора-подделки"
cp /t/cream /usr/bin/cream
chmod 0755 /usr/bin/cream
cream system init
mkdir -p /opt/catalog
cp -r /catalog/cream-catalog.yaml /catalog/extensions /opt/catalog/
cream source add core --path /opt/catalog --sync
mkdir -p /opt/set/teleport/lib
printf '#!/bin/sh\necho "Teleport v18.10.0 git:fake go1.25"\n' >/opt/set/teleport/teleport
printf '#!/bin/sh\necho fdpass\n' >/opt/set/teleport/fdpass-teleport
echo glibc >/opt/set/teleport/lib/libc.so.6
chmod 0755 /opt/set/teleport/teleport /opt/set/teleport/fdpass-teleport
tar -czf /opt/set.tar.gz -C /opt/set teleport
cream install teleport-openwrt TELEPORT_SHA256="$(sha256sum /opt/set.tar.gz | cut -d' ' -f1)" TELEPORT_TARBALL=/opt/set.tar.gz

if [ -f /t/agent.tar.gz ]; then
	step "поставка агента: /t/agent.tar.gz (настоящий выпуск)"
	cp /t/agent.tar.gz /opt/agent.tar.gz
	REAL=1
else
	step "поставка агента: подделка с раскладкой выпуска"
	mkdir -p /opt/agent/init.d
	cat >/opt/agent/stvor-agent <<'EOF'
#!/bin/sh
case "$1" in
version) [ "${2:-}" = --label ] && exit 0; echo "stvor-agent 4.1.0 (fake)" ;;
status) echo "версия:               4.1.0" ;;
disable) rm -f /etc/stvor-agent/token ;;
esac
exit 0
EOF
	for s in stvor-agent stvor-agent-telemetry; do
		printf '#!/bin/sh /etc/rc.common\nUSE_PROCD=1\nSTART=99\nSTOP=01\nstart_service() {\n\t[ -f /etc/%s/token ] || return 0\n\tprocd_open_instance\n\tprocd_set_param command /usr/bin/stvor-agent run\n\tprocd_close_instance\n}\n' \
			"$s" >"/opt/agent/init.d/$s"
	done
	chmod 0755 /opt/agent/stvor-agent /opt/agent/init.d/*
	echo license >/opt/agent/LICENSE
	tar -czf /opt/agent.tar.gz -C /opt/agent stvor-agent init.d LICENSE
	REAL=0
fi
sha=$(sha256sum /opt/agent.tar.gz | cut -d' ' -f1)

step "фаза build: install из файла"
cream install stvor-agent-openwrt STVOR_AGENT_VERSION=4.1.0 STVOR_AGENT_SHA256="$sha" STVOR_AGENT_TARBALL=/opt/agent.tar.gz
has /usr/bin/stvor-agent
eq "бинарь 0755" -rwxr-xr-x "$(mode /usr/bin/stvor-agent)"
for s in stvor-agent stvor-agent-telemetry; do
	eq "/etc/init.d/$s 0755" -rwxr-xr-x "$(mode "/etc/init.d/$s")"
	set -- /etc/rc.d/S[0-9]*"$s"
	[ -e "$1" ] || fail "$s не включён (rc.d)"
done
grep -q '^stvor-telemetry:x:[0-9]*:[0-9]*:Stvor agent telemetry:/var/run/stvor-agent-telemetry:/bin/false$' /etc/passwd ||
	fail "пользователь stvor-telemetry: $(grep stvor /etc/passwd || true)"
grep -q '^stvor-telemetry:x:[0-9]*:$' /etc/group || fail "группа stvor-telemetry"
grep -q '^stvor-telemetry:' /etc/shadow || fail "shadow stvor-telemetry"
eq "/opt/stvor-agent" "drwxr-x--- root:stvor-telemetry" "$(mode /opt/stvor-agent) $(owner /opt/stvor-agent)"
eq "/etc/stvor-agent-telemetry" "drwxr-x--- root:stvor-telemetry" \
	"$(mode /etc/stvor-agent-telemetry) $(owner /etc/stvor-agent-telemetry)"
eq "keep.d" "/opt/stvor-agent/machine-id" "$(grep -v '^#' /lib/upgrade/keep.d/stvor-agent)"
has /etc/cream/teleport-openwrt/command-labels.d/stvor_agent
out=$(cream install stvor-agent-openwrt STVOR_AGENT_VERSION=4.1.0 STVOR_AGENT_SHA256="$sha" STVOR_AGENT_TARBALL=/opt/agent.tar.gz 2>&1) ||
	fail "повтор install: $out"
eq "один пользователь" 1 "$(grep -c '^stvor-telemetry:' /etc/passwd)"

# A restore (keep.d of 1.1.0, a backup) brings the state back as 0:0 0755.
SHADOW_OWNER=$(owner /etc/shadow)
spoil() {
	mkdir -p /opt/stvor-agent/telemetry/buffer/q
	chown -R 0:0 /opt/stvor-agent/telemetry
	chmod 0755 /opt/stvor-agent/telemetry /opt/stvor-agent/telemetry/buffer /opt/stvor-agent/telemetry/buffer/q
	echo seg >/opt/stvor-agent/telemetry/buffer/q/0001
	echo 0123 >/opt/stvor-agent/machine-id
	chown 0:0 /opt/stvor-agent/machine-id
	chmod 0600 /opt/stvor-agent/machine-id
	ln -sfn /etc/shadow /opt/stvor-agent/telemetry/buffer/shadow
	ln -f /etc/shadow /opt/stvor-agent/telemetry/buffer/shadow-hard
	echo marker >/opt/stvor-agent/telemetry/token-rejected
}
fixed() {
	for d in /opt/stvor-agent/telemetry /opt/stvor-agent/telemetry/buffer; do
		eq "$1: $d" "drwx------ stvor-telemetry:stvor-telemetry" "$(mode "$d") $(owner "$d")"
	done
	eq "$1: буфер пересоздан пустым" "" "$(ls -A /opt/stvor-agent/telemetry/buffer)"
	has /opt/stvor-agent/telemetry/token-rejected
	eq "$1: корзины нет" "" "$(find /opt/stvor-agent -maxdepth 1 -name '.trash.*')"
	eq "$1: /etc/shadow — одна ссылка" 1 "$(ls -ld /etc/shadow | awk '{print $2}')"
	eq "$1: machine-id" "-rw-r----- root:stvor-telemetry" "$(mode /opt/stvor-agent/machine-id) $(owner /opt/stvor-agent/machine-id)"
	eq "$1: ссылка не разыменована" "$SHADOW_OWNER" "$(owner /etc/shadow)"
}
step "права состояния: повтор install и configure на загрузке чинят восстановленное"
spoil
# After sysupgrade the registry is empty and the hook runs; here --reinstall does that.
out=$(cream install --reinstall stvor-agent-openwrt STVOR_AGENT_VERSION=4.1.0 STVOR_AGENT_SHA256="$sha" STVOR_AGENT_TARBALL=/opt/agent.tar.gz 2>&1) ||
	fail "install поверх восстановленного: $out"
fixed install
spoil
/etc/rc.d/S95cream-configure boot
fixed configure
rm -r -f -- /opt/stvor-agent/telemetry /opt/stvor-agent/machine-id

step "метка stvor_agent в teleport.yaml (render после отложенного join)"
out=$(printf '%s' 'abcdefgh1-join-token' | CREAM_PHASE=live cream run teleport-openwrt join \
	TELEPORT_PROXY=teleport.example.org TELEPORT_REGISTRATION_SECRET=- TELEPORT_DEFER=1 TELEPORT_NODENAME=owrt-1)
echo "$out" | grep -q '"result":"deferred"' || fail "join: $out"
grep -q 'name: "stvor_agent"' /etc/teleport.yaml || fail "в teleport.yaml нет командной метки stvor_agent"
grep -q 'command: \["/usr/bin/stvor-agent", "version", "--label"\]' /etc/teleport.yaml ||
	fail "команда метки stvor_agent: $(grep -A3 stvor_agent /etc/teleport.yaml)"

step "stvor-agent status и version"
st=$(stvor-agent status 2>&1) || true
echo "$st" | grep -q '^версия: *4\.1\.0' || fail "stvor-agent status: $st"
if [ "$REAL" = 1 ]; then
	echo "$st" | grep -q '^включён: *нет' || fail "агент включён без токена: $st"
	stvor-agent version | grep -q '^stvor-agent 4\.1\.0' || fail "version: $(stvor-agent version)"
fi
eq "метка без токена пуста" "" "$(stvor-agent version --label)"

step "cream set: настройки службы в config расширения"
CREAM_PHASE=live cream set stvor-agent-openwrt STVOR_AGENT_INTERVAL=120 STVOR_AGENT_LOG_LEVEL=debug
grep -qx 'STVOR_AGENT_INTERVAL=120' /etc/cream/stvor-agent-openwrt/config ||
	fail "config: $(cat /etc/cream/stvor-agent-openwrt/config)"

step "remove: службы, бинарь, токены, состояние, пользователь, метка"
mkdir -p /etc/stvor-agent /opt/stvor-agent/telemetry
echo 'url=https://stvor.example.org/robot-api/v1/labels' >/etc/stvor-agent/token
echo 0123 >/opt/stvor-agent/machine-id
ln -sfn /etc /opt/stvor-agent/telemetry/etc
CREAM_PHASE=live cream remove stvor-agent-openwrt
has /etc/os-release
eq "корзин нет" "" "$(find /opt /var/run -maxdepth 1 -name '.stvor-agent-trash.*')"
for p in /usr/bin/stvor-agent /etc/init.d/stvor-agent /etc/init.d/stvor-agent-telemetry /etc/stvor-agent \
	/etc/stvor-agent-telemetry /opt/stvor-agent /lib/upgrade/keep.d/stvor-agent \
	/etc/cream/teleport-openwrt/command-labels.d/stvor_agent; do
	hasnt "$p"
done
for f in /etc/rc.d/*stvor-agent*; do
	[ ! -e "$f" ] || fail "rc.d: $f"
done
if grep -q '^stvor-telemetry:' /etc/passwd /etc/group /etc/shadow; then fail "пользователь stvor-telemetry не снят"; fi
grep -q '^root:' /etc/passwd || fail "root пропал из /etc/passwd"
CREAM_PHASE=live cream run teleport-openwrt render
if grep -q stvor_agent /etc/teleport.yaml; then fail "метка stvor_agent осталась в teleport.yaml"; fi
cream list | grep -q teleport-openwrt || fail "teleport-openwrt пропал"
echo "OK"
