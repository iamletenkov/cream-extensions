#!/usr/bin/env bash
# Extensions of the root extensions/openwrt on a real OpenWrt 25.12 (musl,
# busybox ash, apk, uci, the packages of openwrt-builder v0.3.1): the root FS
# of the openwrt-builder release is imported into a docker image, cream comes
# from the pin tools/cream-pin.env (the binary of the verified .deb — the same
# static build as the release tar.gz), the catalog is this repository
# (read-only). Inside the container — tools/testdata/openwrt/scenario.sh under
# busybox sh: system init, the image build phase (PID 1 is not procd), the
# "boot" by the rc.d scripts with the argument boot, cream set and remove — with
# the real uci, awg and the init scripts of podkop. procd and netifd are not
# running: the boot of a machine is checked on a VM (README of the extensions).
#
#   tools/test-openwrt.sh          (make test-openwrt)
#
# The root FS is downloaded once into .cache/openwrt (or taken from
# OPENWRT_ROOTFS=<file>) and checked against OPENWRT_ROOTFS_SHA256.
# Exit: 0 — the scenario passed; 1 — it failed (the log names the step);
# 2 — setup failure (pin, download, docker).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
URL="${OPENWRT_ROOTFS_URL:-https://github.com/iamletenkov/openwrt-builder/releases/download/v0.3.1/openwrt-25.12.6-custom-x86-64-generic-rootfs.tar.gz}"
SHA="${OPENWRT_ROOTFS_SHA256:-ece09113fd478d37bdb99b74452026eb942007b796dbedcf9e45b87a2e9ac4a9}"

die() { echo "test-openwrt: $*" >&2; exit 2; }
command -v docker >/dev/null 2>&1 || die "нужен docker"
command -v dpkg-deb >/dev/null 2>&1 || die "нужен dpkg-deb (бинарь cream берётся из .deb пина)"

rc=0; deb="$("$HERE/cream-deb.sh")" || rc=$?
if (( rc == 3 )); then
    echo "test-openwrt пропущен: пин cream не задан (tools/cream-pin.env)"
    exit 0
fi
(( rc == 0 )) || exit 2

rootfs="${OPENWRT_ROOTFS:-$REPO/.cache/openwrt/rootfs-${SHA:0:16}.tar.gz}"
if [[ ! -f "$rootfs" ]]; then
    mkdir -p "$(dirname "$rootfs")"
    curl -fsSL --retry 3 -o "$rootfs.part" "$URL" || die "не скачался $URL"
    mv -f "$rootfs.part" "$rootfs"
fi
echo "$SHA  $rootfs" | sha256sum -c --status - || die "sha256 корневой ФС $rootfs не совпала с OPENWRT_ROOTFS_SHA256"
image="cream-extensions-test-openwrt:${SHA:0:16}"
docker image inspect "$image" >/dev/null 2>&1 || docker import "$rootfs" "$image" >/dev/null || die "docker import"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
dpkg-deb -x "$deb" "$work/deb"
install -m 0755 "$work/deb/usr/bin/cream" "$work/cream"
cp "$HERE/testdata/openwrt/scenario.sh" "$work/scenario.sh"

echo "== test-openwrt: $image, cream $(basename "$deb")"
crc=0
docker run --rm --platform linux/amd64 --network none --tmpfs /tmp:rw,nosuid,nodev,mode=1777 \
    -v "$work:/t:ro" -v "$REPO:/catalog:ro" "$image" /bin/sh /t/scenario.sh || crc=$?
if (( crc != 0 )); then
    echo "test-openwrt: сценарий упал (код $crc)" >&2
    exit 1
fi
echo "test-openwrt: ок"
