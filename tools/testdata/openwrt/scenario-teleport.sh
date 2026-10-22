#!/bin/sh
# Scenario of tools/test-openwrt.sh for teleport-openwrt inside the container with
# the root FS of openwrt-builder v0.3.1 (busybox: no stat, install, hostname,
# paste — the stand-ins of the layer work here for real). /t (read-only) — the
# cream binary; /catalog (read-only) — the staged tree of the repository (the
# shared core laid into the extension). The set openwrt-<arch> is a local fake:
# its teleport is a script that prints the version (the real set — glibc and
# patchelf — is checked on a VM, README of the extension). procd is not PID 1:
# join is deferred, the node is not started.
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
yaml_has() { grep -qx -- "$1" /etc/teleport.yaml || fail "в teleport.yaml нет строки «$1»"; }

. /etc/os-release
step "окружение: $PRETTY_NAME, pid1=$(cat /proc/1/comm)"
for c in stat install hostname paste; do
	if command -v "$c" >/dev/null 2>&1; then fail "в образе есть $c — заглушки слоя не проверяются"; fi
done

step "cream: бинарь, system init, источник core"
cp /t/cream /usr/bin/cream
chmod 0755 /usr/bin/cream
cream system init
mkdir -p /opt/catalog
cp -r /catalog/cream-catalog.yaml /catalog/extensions /opt/catalog/
cream source add core --path /opt/catalog --sync

step "набор openwrt-amd64: подделка с теми же путями"
mkdir -p /opt/set/teleport/lib
printf '#!/bin/sh\necho "Teleport v18.10.0 git:fake go1.25"\n' >/opt/set/teleport/teleport
printf '#!/bin/sh\necho fdpass\n' >/opt/set/teleport/fdpass-teleport
echo glibc >/opt/set/teleport/lib/libc.so.6
chmod 0755 /opt/set/teleport/teleport /opt/set/teleport/fdpass-teleport
tar -czf /opt/set.tar.gz -C /opt/set teleport
sha=$(sha256sum /opt/set.tar.gz | cut -d' ' -f1)

step "фаза build: install из локального набора"
cream install teleport-openwrt TELEPORT_SHA256="$sha" TELEPORT_TARBALL=/opt/set.tar.gz
has /opt/teleport/bin/teleport
has /opt/teleport/bin/fdpass-teleport
has /opt/teleport/lib/libc.so.6
has /opt/teleport/.cream-owned
eq "ссылка /usr/bin/teleport" /opt/teleport/bin/teleport "$(readlink /usr/bin/teleport)"
eq "data_dir" drwxr-x--- "$(mode /opt/teleport/data)"
eq "TMPDIR узла" drwx------ "$(mode /opt/teleport/tmp)"
eq "каталог журнала узла" drwx------ "$(mode /opt/teleport/log)"
has /etc/init.d/teleport
has /etc/rc.d/S95teleport
has /lib/upgrade/keep.d/teleport
has /usr/lib/teleport-openwrt/teleport-core.sh
has /opt/cream/ext/teleport-openwrt/files/teleport-core.sh
if grep -v '^[[:space:]]*#' /etc/init.d/teleport | grep -qE 'procd_set_param[[:space:]]+(stdout|stderr)'; then
	fail "init-скрипт ставит stdout/stderr"
fi
eq "keep.d" "/opt/teleport/data/ /opt/teleport/.cream-owned" "$(grep -v '^#' /lib/upgrade/keep.d/teleport | tr '\n' ' ' | sed 's/ $//')"
hasnt /etc/teleport.yaml

step "журнал узла: log_cap через rc.common под писателем с O_APPEND"
mkdir -p /var/lock
exec 5>>/opt/teleport/log/teleport.log
head -c 1048577 /dev/zero | tr '\0' x >&5
/etc/init.d/teleport log_cap
eq "копия в .1" 1048577 "$(wc -c </opt/teleport/log/teleport.log.1)"
echo "after cap" >&5
eq "писатель с нового конца" 10 "$(wc -c </opt/teleport/log/teleport.log)"
exec 5>&-
eq "журнал 0600" -rw------- "$(mode /opt/teleport/log/teleport.log)"

step "join отложенный (procd не PID 1): ручки, секрет, render"
mkdir -p /etc/cream/teleport-openwrt/apps.d
printf 'NAME=luci\nURI=http://127.0.0.1:80\n' >/etc/cream/teleport-openwrt/apps.d/luci.conf
chmod 0644 /etc/cream/teleport-openwrt/apps.d/luci.conf
# bound_keypair first: the bounds {8,256} and {8,1000} of the types are over
# RE_DUP_MAX of musl (re_ok of the core).
out=$(printf '%s' 'Zk3_q9-RobotSecret-0123456789abcdef' | CREAM_PHASE=live cream run teleport-openwrt join \
	TELEPORT_PROXY=teleport.example.org TELEPORT_JOIN_METHOD=bound_keypair TELEPORT_TOKEN=robot-lab-1 \
	TELEPORT_REGISTRATION_SECRET=- TELEPORT_DEFER=1 TELEPORT_NODENAME=owrt-1)
echo "$out" | grep -q '"result":"deferred"' || fail "join bound_keypair: $out"
yaml_has '    method: bound_keypair'
yaml_has '    token_name: "robot-lab-1"'
out=$(printf '%s' 'abcdefgh1-join-token' | CREAM_PHASE=live cream run teleport-openwrt join TELEPORT_PROXY=teleport.example.org \
	TELEPORT_REGISTRATION_SECRET=- TELEPORT_DEFER=1 TELEPORT_ENV=dev TELEPORT_NODENAME=owrt-1 TELEPORT_LABELS="a=1 b=2")
echo "$out" | grep -q '"result":"deferred"' || fail "join: $out"
eq "секрет 0600" -rw------- "$(mode /opt/cream/var/ext/teleport-openwrt/registration-secret)"
eq "состояние 0700" drwx------ "$(mode /opt/cream/var/ext/teleport-openwrt)"
eq "teleport.yaml 0600" -rw------- "$(mode /etc/teleport.yaml)"
yaml_has '  data_dir: /opt/teleport/data'
yaml_has '    output: /opt/teleport/log/teleport.log'
yaml_has '  nodename: "owrt-1"'
yaml_has '    "env": "dev"'
yaml_has '    enabled: false'
grep -A1 -x '  pam:' /etc/teleport.yaml | grep -qx '    enabled: false' || fail "pam не выключен"
grep -A1 -x '  enhanced_recording:' /etc/teleport.yaml | grep -qx '    enabled: false' || fail "enhanced_recording не выключен"
grep -q 'name: "luci-owrt-1"' /etc/teleport.yaml || fail "приложение apps.d не опубликовано (заглушка stat)"
grep -q 'command: \["/opt/cream/ext/teleport-openwrt/files/os-logins"\]' /etc/teleport.yaml || fail "os_logins не из дерева"
eq "os-logins" root "$(/opt/cream/ext/teleport-openwrt/files/os-logins)"

step "действия: render, set-managed, managed-status, status"
CREAM_PHASE=live cream run teleport-openwrt render
out=$(CREAM_PHASE=live cream run teleport-openwrt set-managed space=sp-1 env=prod)
echo "$out" | grep -q '"result":"deferred"' || fail "set-managed: $out"
grep -q '^TELEPORT_MANAGED_LABELS="env=prod space=sp-1"$' /etc/cream/teleport-openwrt/config ||
	fail "управляемые метки не отсортированы: $(grep MANAGED /etc/cream/teleport-openwrt/config)"
out=$(CREAM_PHASE=live cream run teleport-openwrt managed-status)
echo "$out" | grep -q '"managed":{"env":"prod","space":"sp-1"}' || fail "managed-status: $out"
st=$(CREAM_PHASE=live cream run teleport-openwrt status) || fail "status: код $?"
echo "$st" | grep -q 'Регистрация: ждёт сети' || fail "status: $st"
CREAM_PHASE=live cream run teleport-openwrt render
yaml_has '    "space": "sp-1"'
code=0; CREAM_PHASE=live cream run teleport-openwrt hup 2>/dev/null || code=$?
[ "$code" != 0 ] || fail "hup на OpenWrt прошёл"

step "remove: набор, ссылка, служба и состояние сняты"
CREAM_PHASE=live cream remove teleport-openwrt
hasnt /opt/teleport
hasnt /usr/bin/teleport
hasnt /etc/init.d/teleport
hasnt /etc/rc.d/S95teleport
hasnt /lib/upgrade/keep.d/teleport
hasnt /etc/teleport.yaml
hasnt /opt/cream/var/ext/teleport-openwrt/registration-secret
echo "OK"
