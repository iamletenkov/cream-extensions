# cream extension stvor-agent-openwrt: sysupgrade keeps only the state of the
# agent — state.json, its own machine-id (the identity of the machine in the
# telemetry) and the telemetry buffer (spec 2026-10-20-openwrt §4.7, ruling Р4).
# The binary, /etc/init.d/stvor-agent*, the registry of cream and the tokens
# (/etc/stvor-agent, /etc/stvor-agent-telemetry) are not kept: the command of the
# portal installs them again and issues new tokens.
/opt/stvor-agent/
