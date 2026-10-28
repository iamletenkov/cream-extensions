#!/bin/sh
# Scenario of tools/test-openwrt.sh, part 2 of 2: a fresh container of the image
# is the new firmware. The archive of part 1 (/out/backup.tgz) is unpacked as
# preinit does (tar -C / -xzf), then the extensions are installed again the way
# the restore service of Stvor does it — no join, no secret. Expected: the same
# host_uuid and data, teleport called for `version` only, the idempotent rerun of
# the portal command (no secret, no FORCE) answers «уже зарегистрирован», and the
# modes the agent and the node require are back.
set -eu

step() { echo "== $*"; }
fail() {
	echo "FAIL: $*" >&2
	exit 1
}
eq() { [ "$2" = "$3" ] || fail "$1: ждали «$2», получили «$3»"; }
mode() { ls -ld "$1" | cut -c1-10; }
owner() { ls -ld "$1" | awk '{print $3 ":" $4}'; }
tree_sum() { find "$1" -type f | sort | xargs sha256sum | sha256sum | cut -c1-64; }

. /out/expect
mkdir -p /var/run /var/lock
[ -e /run ] || ln -s /var/run /run
[ ! -e /usr/bin/cream ] || fail "в свежем образе уже есть cream"

step "первая загрузка новой прошивки: архив настроек распакован"
# Files docker bind-mounts into the container cannot be replaced; not ours anyway.
printf 'etc/hosts\netc/hostname\netc/resolv.conf\n' >/tmp/docker-mounts
tar -C / -X /tmp/docker-mounts -xzf /out/backup.tgz
eq "tar: каталог токена меток" drwxr-xr-x "$(mode /etc/stvor-agent)"
eq "tar: каталог состояния teleport-openwrt" drwxr-xr-x "$(mode /opt/cream/var/ext/teleport-openwrt)"

step "повторная установка расширений (как служба восстановления Stvor)"
# The restore service runs on a live machine (procd is PID 1 there, not here):
# the phase is given, so the guard of the build phase against a baked identity
# does not apply.
cp /t/cream /usr/bin/cream
chmod 0755 /usr/bin/cream
cream system init
mkdir -p /opt/catalog
cp -r /catalog/cream-catalog.yaml /catalog/extensions /opt/catalog/
cream source add core --path /opt/catalog --sync
CREAM_PHASE=live cream install teleport-openwrt TELEPORT_SHA256="$(sha256sum /out/set.tar.gz | cut -d' ' -f1)" TELEPORT_TARBALL=/out/set.tar.gz
CREAM_PHASE=live cream install stvor-agent-openwrt STVOR_AGENT_VERSION=4.1.0 STVOR_AGENT_SHA256="$(sha256sum /out/agent.tar.gz | cut -d' ' -f1)" \
	STVOR_AGENT_TARBALL=/out/agent.tar.gz

step "узел: тот же host_uuid, data не тронута, join не вызывался"
eq "host_uuid" "$UUID" "$(cat /opt/teleport/data/host_uuid)"
eq "data" "$DATA" "$(tree_sum /opt/teleport/data)"
eq "teleport вызывался только для version" version "$(sort -u /opt/teleport-calls)"
eq "каталог состояния" "drwx------ root:root" "$(mode /opt/cream/var/ext/teleport-openwrt) $(owner /opt/cream/var/ext/teleport-openwrt)"
eq "флаг agent-enabled" "-rw------- root:root" \
	"$(mode /opt/cream/var/ext/teleport-openwrt/agent-enabled) $(owner /opt/cream/var/ext/teleport-openwrt/agent-enabled)"
eq "pin набора" "-rw------- root:root" \
	"$(mode /opt/cream/var/ext/teleport-openwrt/installed-pin) $(owner /opt/cream/var/ext/teleport-openwrt/installed-pin)"
grep -qx "TELEPORT_SHA256=$(sha256sum /out/set.tar.gz | cut -d' ' -f1)" /opt/cream/var/ext/teleport-openwrt/installed-pin ||
	fail "pin набора без суммы набора"
eq "data_dir" drwxr-x--- "$(mode /opt/teleport/data)"
[ -e /etc/rc.d/S95teleport ] || fail "служба teleport не включена"
grep -q '^TELEPORT_PROXY=' /etc/cream/teleport-openwrt/config || fail "домен без прокси"

step "повтор команды портала без секрета и FORCE — ветка «уже зарегистрирован»"
out=$(CREAM_PHASE=live cream run teleport-openwrt join TELEPORT_PROXY=teleport.example.org TELEPORT_ENV=dev </dev/null 2>&1) ||
	fail "повтор join: $out"
echo "$out" | grep -q 'уже зарегистрирован' || fail "повтор join: $out"
echo "$out" | grep -q '"result":"registered"' || fail "повтор join: $out"
[ ! -e /opt/cream/var/ext/teleport-openwrt/registration-secret ] || fail "секрет первого входа появился"
eq "host_uuid после повтора" "$UUID" "$(cat /opt/teleport/data/host_uuid)"
eq "data после повтора" "$DATA" "$(tree_sum /opt/teleport/data)"
eq "teleport после повтора — только version" version "$(sort -u /opt/teleport-calls)"

step "агент: токены, состояние и домен на месте, права как пишет агент"
eq "/etc/stvor-agent" "drwx------ root:root" "$(mode /etc/stvor-agent) $(owner /etc/stvor-agent)"
eq "токен меток" "-rw------- root:root" "$(mode /etc/stvor-agent/token) $(owner /etc/stvor-agent/token)"
grep -qx 'token=labels-secret' /etc/stvor-agent/token || fail "токен меток не тот"
eq "/etc/stvor-agent-telemetry" "drwxr-x--- root:stvor-telemetry" \
	"$(mode /etc/stvor-agent-telemetry) $(owner /etc/stvor-agent-telemetry)"
eq "токен телеметрии" "-rw-r----- root:stvor-telemetry" \
	"$(mode /etc/stvor-agent-telemetry/token) $(owner /etc/stvor-agent-telemetry/token)"
eq "/opt/stvor-agent" "drwxr-x--- root:stvor-telemetry" "$(mode /opt/stvor-agent) $(owner /opt/stvor-agent)"
for f in state.json telemetry-token.src; do
	eq "$f" "-rw------- root:root" "$(mode "/opt/stvor-agent/$f") $(owner "/opt/stvor-agent/$f")"
done
eq "machine-id" "-rw-r----- root:stvor-telemetry" "$(mode /opt/stvor-agent/machine-id) $(owner /opt/stvor-agent/machine-id)"
eq "machine-id тот же" 0123456789abcdef "$(cat /opt/stvor-agent/machine-id)"
eq "uid stvor-telemetry тот же" "$TUID" "$(awk -F: '$1 == "stvor-telemetry" { print $3 }' /etc/passwd)"
eq "один пользователь" 1 "$(grep -c '^stvor-telemetry:' /etc/passwd)"
eq "pin агента" "-rw------- root:root" \
	"$(mode /opt/cream/var/ext/stvor-agent-openwrt/installed-pin) $(owner /opt/cream/var/ext/stvor-agent-openwrt/installed-pin)"
eq "pin агента: версия и сумма tar.gz" \
	"STVOR_AGENT_VERSION=4.1.0 STVOR_AGENT_SHA256=$(sha256sum /out/agent.tar.gz | cut -d' ' -f1)" \
	"$(tr '\n' ' ' </opt/cream/var/ext/stvor-agent-openwrt/installed-pin | sed 's/ $//')"
[ -e /opt/cream/var/ext/stvor-agent-openwrt/user-created ] || fail "маркер пользователя пропал — remove его не снимет"
grep -qx 'STVOR_AGENT_INTERVAL=120' /etc/cream/stvor-agent-openwrt/config || fail "домен агента: $(cat /etc/cream/stvor-agent-openwrt/config)"
[ -e /etc/cream/teleport-openwrt/command-labels.d/stvor_agent ] || fail "метка stvor_agent не разложена"
for s in stvor-agent stvor-agent-telemetry; do
	set -- /etc/rc.d/S[0-9]*"$s"
	[ -e "$1" ] || fail "$s не включён (rc.d)"
done
echo "OK"
