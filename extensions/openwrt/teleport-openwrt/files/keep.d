# cream extension teleport-openwrt: sysupgrade with kept settings keeps the node
# itself (spec 2026-10-20-openwrt §4.7, ruling Р4 as revised by the owner
# 2026-10-23): its identity (data_dir), the marker of cream's ownership, the flag
# agent-enabled (the node starts at boot), the installed pin (version and sum of
# the set: /etc/stvor/restore.sh of Stvor reads it) and the knobs of the domain — config
# (proxy, token name, env, labels; no secret) and apps.d. After the new firmware
# the extension is installed again: the marker and data are there, so install
# takes them as its own, nothing joins, and the node returns with the same
# host_uuid. The archive keeps files only: install narrows the state directory
# (0700) and the flag (0600) back. command-labels.d is not kept: other extensions
# lay it by `files`, and cream refuses a file that is on disk before them. The
# binaries, /etc/init.d/teleport and the registry of cream are not kept.
# The archive holds the key of the node: a secret of root level.
/opt/teleport/data/
/opt/teleport/.cream-owned
/opt/cream/var/ext/teleport-openwrt/agent-enabled
/opt/cream/var/ext/teleport-openwrt/installed-pin
/etc/cream/teleport-openwrt/config
/etc/cream/teleport-openwrt/apps.d/
