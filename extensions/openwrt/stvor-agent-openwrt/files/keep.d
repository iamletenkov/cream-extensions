# cream extension stvor-agent-openwrt: sysupgrade with kept settings keeps the
# agent of the machine whole (spec 2026-10-20-openwrt §4.3, §4.7, ruling Р4 as
# revised by the owner 2026-10-23): its machine-id (the identity for the clone
# detector of the portal), state.json, the trace of the telemetry token
# (telemetry-token.src), both tokens, the domain of the extension and the marker
# that this extension made the user stvor-telemetry (/etc/passwd is kept by
# OpenWrt itself) and the pin of the installed tar.gz (installed-pin: the
# version and sha256 /etc/stvor/restore.sh of Stvor installs again), and
# last-good.json of the applier (the last working set of versions; agent spec
# "assignments" §8.4, ADR-0001 — rollback/, updates/ and apply/ are not kept:
# after sysupgrade the next attempt takes the rollback files by baseline). After the
# new firmware the extension is installed again; the portal issues nothing new. The archive keeps files only: install and configure
# (every boot) give the directories and files back their owners and modes. The
# telemetry buffer, the binary, the init scripts and the registry of cream are
# not kept. The key of the robot (agent v2, ADR-0003 of the agent: robot.key and,
# mid-rotation, robot.key.next), the dev CA of the portal (ca.pem) and the pinned
# roots of the Teleport hook (roots.pem) are kept as well: without the key the
# robot is a stranger to the portal after sysupgrade and must be enrolled again.
# The archive holds the tokens and the key: a secret of root level.
/opt/stvor-agent/machine-id
/opt/stvor-agent/state.json
/opt/stvor-agent/telemetry-token.src
/etc/stvor-agent/token
/etc/stvor-agent/robot.key
/etc/stvor-agent/robot.key.next
/etc/stvor-agent/ca.pem
/etc/stvor-agent/roots.pem
/etc/stvor-agent-telemetry/token
/etc/cream/stvor-agent-openwrt/
/opt/cream/var/ext/stvor-agent-openwrt/user-created
/opt/cream/var/ext/stvor-agent-openwrt/installed-pin
/opt/stvor-agent/last-good.json
