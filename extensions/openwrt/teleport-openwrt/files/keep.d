# cream extension teleport-openwrt: sysupgrade keeps only the state of the node —
# its identity (data_dir) and the marker of cream's ownership (spec 2026-10-20-openwrt
# §4.7, ruling Р4). The binaries, /etc/init.d/teleport, the registry of cream and the
# tokens of stvor-agent are not kept: the command of the portal installs them again.
/opt/teleport/data/
/opt/teleport/.cream-owned
