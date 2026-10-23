# cream extension stvor-agent-openwrt: sysupgrade with kept settings keeps the
# agent of the machine whole (spec 2026-10-20-openwrt §4.3, §4.7, ruling Р4 as
# revised by the owner 2026-10-23): its machine-id (the identity for the clone
# detector of the portal), state.json, the trace of the telemetry token
# (telemetry-token.src), both tokens, the domain of the extension and the marker
# that this extension made the user stvor-telemetry (/etc/passwd is kept by
# OpenWrt itself). After the new firmware the extension is installed again; the
# portal issues nothing new. The archive keeps files only: install and configure
# (every boot) give the directories and files back their owners and modes. The
# telemetry buffer, the binary, the init scripts and the registry of cream are
# not kept. The archive holds the tokens: a secret of root level.
/opt/stvor-agent/machine-id
/opt/stvor-agent/state.json
/opt/stvor-agent/telemetry-token.src
/etc/stvor-agent/token
/etc/stvor-agent-telemetry/token
/etc/cream/stvor-agent-openwrt/
/opt/cream/var/ext/stvor-agent-openwrt/user-created
