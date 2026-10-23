# cream extension stvor-agent-openwrt: sysupgrade keeps only the agent's own
# machine-id — the identity of the machine for the clone detector of the portal
# (spec 2026-10-20-openwrt §4.3, §4.7, ruling Р4). Everything else goes: the
# tokens and their trace (/etc/stvor-agent, /etc/stvor-agent-telemetry,
# telemetry-token.src), state.json, the telemetry buffer, the binary, the init
# scripts, the registry of cream — the command of the portal installs them again
# and issues new tokens. The owner of the restored file is set by install.
/opt/stvor-agent/machine-id
