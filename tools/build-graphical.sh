#!/usr/bin/env bash
# Build test of the graphical stack in an image: the real cream (pin
# tools/cream-pin.env) installs the extensions inside an ubuntu-24.04 amd64
# cloud image under virt-customize, from a snapshot of this catalog — the
# build phase as bisquite runs it (docs/guides/use-in-bisquite.md). Spec
# 2026-11-12-existing-desktop §8 «Ночная сборка», plan Task 19, ruling П29.
#
#   tools/build-graphical.sh <scenario>             build and verify
#   tools/build-graphical.sh --dry-run <scenario>   print the host commands, run nothing
#   tools/build-graphical.sh --list                 scenarios, one per line
#   tools/build-graphical.sh --steps <scenario>     guest steps: name|kind|command
#   tools/build-graphical.sh --guest-script <scenario> <snapshot.tar.gz> <sha256>
#                                                   the script run in the guest
#   tools/build-graphical.sh --verify <scenario> <logdir>
#                                                   judge the logs taken out of the guest
#
# Scenarios:
#   cream-gnome    the desktop through cream: desktop (autologin), gnome, selkies, x11vnc
#   existing-gdm3  a desktop not through cream: gdm3 by apt before cream, then
#                  existing-desktop, desktop (autologin), selkies, x11vnc
# No passwords go into the image: selkies and x11vnc get them on the machine.
#
# The guest script runs the steps in order and stops at the first failure;
# every step leaves <name>.rc, <name>.out, <name>.err in /var/tmp/build-graphical/logs,
# and /etc/image-labels.d/cream.json is copied next to them. --verify passes
# when every step has rc 0, every cream envelope says phase build and no
# record is anything but installed, and the image labels list every
# extension of the scenario.
#
# Needs on the host: virt-customize, virt-resize, virt-copy-out, qemu-img
# (libguestfs-tools, KVM for speed), docker (the snapshot), curl, python3.
# Environment:
#   WORK          working directory (default .scratchpad/build-graphical/<scenario>)
#   SNAPSHOT      a ready snapshot .tar.gz (default: tools/catalog-snapshot.sh from HEAD)
#   CLOUD_IMAGE   a local cloud image (default: download, checked by SHA256SUMS)
#   CLOUD_IMAGE_BASE  where to download it from
#   DISK_SIZE (20G), GUEST_MEM (MiB, 4096), GUEST_SMP (2)
#   CREAM_DEB     a local cream .deb instead of the pin (tools/cream-deb.sh)
#   LIBGUESTFS_CACHEDIR (.cache/libguestfs); TMPDIR — .cache/tmp when /var/tmp is not writable
#
# Exit: 0 — built and verified; 1 — a step failed or the result is wrong;
# 2 — usage or setup failure.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
GUEST_DIR=/var/tmp/build-graphical
IMAGE_NAME=ubuntu-24.04-server-cloudimg-amd64.img
CLOUD_IMAGE_BASE="${CLOUD_IMAGE_BASE:-https://cloud-images.ubuntu.com/releases/noble/release}"

die(){ echo "build-graphical: $*" >&2; exit 2; }
usage(){ sed -n '9,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

SCENARIOS=(cream-gnome existing-gdm3)

# steps <scenario>: name|kind|command, in order. kind cream — the output is
# the JSON envelope of a cream install (phase, statuses); sh — only the code. @SNAP@ and @SHA@ are filled by
# guest_script. Commands are shell text of this script, never outside input.
steps(){
    local pre=""
    case "$1" in
        cream-gnome) ;;
        existing-gdm3)
            # A ready Ubuntu desktop before cream: GDM, Xorg and the Ubuntu X session.
            pre="sh -c 'apt-get update -q && apt-get install -y -q --no-install-recommends gdm3 xserver-xorg-core ubuntu-session'" ;;
        *) die "сценарий '$1' неизвестен (есть: ${SCENARIOS[*]})" ;;
    esac
    [[ -z "$pre" ]] || echo "00-preinstall|sh|$pre"
    echo "01-cream|sh|dpkg -i $GUEST_DIR/cream.deb"
    # source add answers without a phase: only its code is judged.
    echo "02-source|sh|cream --json source add core --archive file://$GUEST_DIR/@SNAP@ --sha256 @SHA@ --sync"
    case "$1" in
        cream-gnome)
            echo "03-desktop|cream|cream --json install --with-deps desktop DESKTOP_AUTOLOGIN=1"
            echo "04-gnome|cream|cream --json install --with-deps gnome" ;;
        existing-gdm3)
            echo "03-existing-desktop|cream|cream --json install --with-deps existing-desktop"
            echo "04-desktop|cream|cream --json install --with-deps desktop DESKTOP_AUTOLOGIN=1" ;;
    esac
    echo "05-selkies|cream|cream --json install --with-deps selkies"
    echo "06-x11vnc|cream|cream --json install --with-deps x11vnc"
}

# expected <scenario>: extensions the image labels must list.
expected(){
    case "$1" in
        cream-gnome) echo "cloud-user desktop gnome selkies x11vnc" ;;
        existing-gdm3) echo "cloud-user existing-desktop desktop selkies x11vnc" ;;
        *) die "сценарий '$1' неизвестен (есть: ${SCENARIOS[*]})" ;;
    esac
}

guest_script(){
    local sc="$1" snap="$2" sha="$3" lines n cmd
    [[ "$snap" =~ ^[A-Za-z0-9._-]+\.tar\.gz$ ]] || die "снимок '$snap': нужно имя файла .tar.gz"
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "sha256 снимка: нужно 64 hex-знака"
    lines="$(steps "$sc")"
    cat <<EOF
#!/bin/bash
# Generated by tools/build-graphical.sh, scenario $sc. Runs in the guest under
# virt-customize; stops at the first failed step, always exits 0 — the host
# judges the logs (tools/build-graphical.sh --verify).
set -u
L=$GUEST_DIR/logs
mkdir -p "\$L"
export DEBIAN_FRONTEND=noninteractive
trap 'cp /etc/image-labels.d/cream.json "\$L/cream.json" 2>/dev/null || true' EXIT
step(){ local n="\$1" rc=0; shift; "\$@" > "\$L/\$n.out" 2> "\$L/\$n.err" || rc=\$?; echo "\$rc" > "\$L/\$n.rc"; return "\$rc"; }
EOF
    while IFS='|' read -r n _ cmd; do
        cmd="${cmd//@SNAP@/$snap}"; cmd="${cmd//@SHA@/$sha}"
        echo "step $n $cmd || exit 0"
    done <<< "$lines"
    echo "exit 0"
}

# shellcheck disable=SC2016  # Python source
VERIFY_PY='
import json, pathlib, sys
d = pathlib.Path(sys.argv[1]); sc = sys.argv[2]
steps = [l.split("|", 2) for l in sys.argv[3].splitlines() if l]
want = sys.argv[4].split()
bad = []
for name, kind, _ in steps:
    rcf = d / f"{name}.rc"
    if not rcf.exists():
        bad.append(f"{name}: шаг не выполнялся (раньше остановился сценарий)"); continue
    rc = rcf.read_text().strip()
    if rc != "0":
        bad.append(f"{name}: код {rc}"); continue
    if kind != "cream":
        continue
    try:
        env = json.loads((d / f"{name}.out").read_text())
    except (OSError, ValueError) as e:
        bad.append(f"{name}: ответ cream не JSON ({e.__class__.__name__})"); continue
    phase, ok = env.get("phase"), env.get("ok")
    if phase != "build":
        bad.append(f"{name}: фаза {phase!r}, а не build"); continue
    if ok is not True:
        bad.append(f"{name}: ok={ok!r}"); continue
    res = env.get("result") or {}
    recs = res.get("extensions", [res]) if isinstance(res, dict) else []
    for r in recs:
        if isinstance(r, dict) and "status" in r and r["status"] != "installed":
            rn, rs = r.get("name"), r["status"]
            bad.append(f"{name}: {rn} — {rs}")
try:
    labels = json.loads((d / "cream.json").read_text())
    names = {e["name"] for e in json.loads(labels["cream.extensions"])}
except (OSError, ValueError, KeyError, TypeError) as e:
    bad.append(f"метки образа /etc/image-labels.d/cream.json не прочитаны ({e.__class__.__name__})")
else:
    for w in want:
        if w not in names:
            bad.append(f"метки образа: нет {w}")
for b in bad:
    print(f"FAIL {sc}: {b}")
print(f"{sc}: шагов {len(steps)}, ошибок {len(bad)}")
sys.exit(1 if bad else 0)
'

verify(){
    local sc="$1" dir="$2" lines
    [[ -d "$dir" ]] || die "$dir: нет каталога журналов"
    lines="$(steps "$sc")"
    python3 -I -c "$VERIFY_PY" "$dir" "$sc" "$lines" "$(expected "$sc")"
}

# --- the build ----------------------------------------------------------------
DRY=0
# run <cmd…>: print it; execute unless --dry-run.
run(){ echo "+ $*"; (( DRY )) || "$@"; }

# cloud_image <dir>: path of the verified cloud image (download if needed).
cloud_image(){
    local dir="$1" sums want img
    if [[ -n "${CLOUD_IMAGE:-}" ]]; then
        [[ -f "$CLOUD_IMAGE" ]] || die "CLOUD_IMAGE=$CLOUD_IMAGE: файла нет"
        echo "ВНИМАНИЕ: образ из CLOUD_IMAGE=$CLOUD_IMAGE — сумма не проверяется" >&2
        printf '%s\n' "$CLOUD_IMAGE"; return
    fi
    mkdir -p "$dir"
    sums="$(curl -fsSL --retry 3 "$CLOUD_IMAGE_BASE/SHA256SUMS")" || die "не скачался $CLOUD_IMAGE_BASE/SHA256SUMS"
    want="$(awk -v f="*$IMAGE_NAME" '$2 == f || $2 == substr(f, 2) {print $1}' <<< "$sums")"
    [[ "$want" =~ ^[0-9a-f]{64}$ ]] || die "в SHA256SUMS нет $IMAGE_NAME"
    img="$dir/$IMAGE_NAME"
    if [[ ! -f "$img" ]] || ! echo "$want  $img" | sha256sum -c --status -; then
        curl -fsSL --retry 3 -o "$img.part" "$CLOUD_IMAGE_BASE/$IMAGE_NAME" || die "не скачался $IMAGE_NAME"
        echo "$want  $img.part" | sha256sum -c --status - || die "sha256 $IMAGE_NAME не совпал с SHA256SUMS"
        mv -f -- "$img.part" "$img"
    fi
    printf '%s\n' "$img"
}

build(){
    local sc="$1" work snap sha deb img disk rc
    steps "$sc" > /dev/null
    work="${WORK:-$REPO/.scratchpad/build-graphical/$sc}"
    disk="$work/disk.qcow2"
    if (( DRY )); then
        echo "+ $HERE/catalog-snapshot.sh $work/dist   # SNAPSHOT=${SNAPSHOT:-}"
        echo "+ $HERE/cream-deb.sh > $work/cream.deb"
        echo "+ curl $CLOUD_IMAGE_BASE/SHA256SUMS; curl $CLOUD_IMAGE_BASE/$IMAGE_NAME   # CLOUD_IMAGE=${CLOUD_IMAGE:-}"
        snap="cream-extensions-X.Y.Z.tar.gz"; sha="$(printf '0%.0s' {1..64})"; img="<cache>/$IMAGE_NAME"
    else
        for t in virt-customize virt-resize virt-copy-out qemu-img python3 curl; do
            command -v "$t" > /dev/null || die "нужен $t (libguestfs-tools, qemu-utils)"
        done
        export LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND:-direct}"
        # The appliance is cached between runs; supermin builds it in TMPDIR
        # (default /var/tmp, closed to users on some hosts).
        export LIBGUESTFS_CACHEDIR="${LIBGUESTFS_CACHEDIR:-$REPO/.cache/libguestfs}"
        [[ -n "${TMPDIR:-}" || -w /var/tmp ]] || export TMPDIR="$REPO/.cache/tmp"
        mkdir -p "$LIBGUESTFS_CACHEDIR" "${TMPDIR:-/var/tmp}"
        mkdir -p "$work"
        rm -f -- "$disk" "$work/steps.sh"
        rm -r -f -- "$work/logs"
        if [[ -n "${SNAPSHOT:-}" ]]; then
            [[ -f "$SNAPSHOT" ]] || die "SNAPSHOT=$SNAPSHOT: файла нет"
            cp -f -- "$SNAPSHOT" "$work/"
            snap="$(basename "$SNAPSHOT")"
        else
            rm -r -f -- "$work/dist"
            "$HERE/catalog-snapshot.sh" "$work/dist" || die "снимок каталога не собран"
            snap="$(cd "$work/dist" && ls cream-extensions-*.tar.gz)"
            cp -f -- "$work/dist/$snap" "$work/"
        fi
        sha="$(sha256sum "$work/$snap" | cut -d' ' -f1)"
        rc=0; deb="$("$HERE/cream-deb.sh")" || rc=$?
        (( rc != 3 )) || die "пин cream не задан (tools/cream-pin.env; локально — CREAM_DEB=<.deb>)"
        (( rc == 0 )) || exit 2
        cp -f -- "$deb" "$work/cream.deb"
        img="$(cloud_image "$REPO/.cache/cloud-images")"
    fi
    if (( DRY )); then
        echo "+ $0 --guest-script $sc $snap <sha256> > $work/steps.sh"
    else
        guest_script "$sc" "$snap" "$sha" > "$work/steps.sh"
    fi
    run qemu-img create -q -f qcow2 "$disk" "${DISK_SIZE:-20G}"
    # The root is the first partition; the rest of the image stays as it is.
    run virt-resize --expand /dev/sda1 --quiet "$img" "$disk"
    run virt-customize --quiet -a "$disk" --memsize "${GUEST_MEM:-4096}" --smp "${GUEST_SMP:-2}" \
        --mkdir "$GUEST_DIR" \
        --copy-in "$work/cream.deb:$GUEST_DIR" --copy-in "$work/$snap:$GUEST_DIR" \
        --run "$work/steps.sh"
    run virt-copy-out -a "$disk" "$GUEST_DIR/logs" "$work/"
    if (( DRY )); then
        echo "+ $0 --verify $sc $work/logs"
        return 0
    fi
    rc=0; verify "$sc" "$work/logs" || rc=$?
    if (( rc != 0 )); then
        for f in "$work"/logs/*.rc; do
            [[ -e "$f" && "$(cat "$f")" != 0 ]] || continue
            echo "--- ${f##*/}: хвост ${f%.rc}.err и .out" >&2
            tail -n 30 "${f%.rc}.err" "${f%.rc}.out" >&2 || true
        done
    fi
    return "$rc"
}

(( $# )) || usage
case "$1" in
    --list) printf '%s\n' "${SCENARIOS[@]}" ;;
    --steps) (( $# == 2 )) || usage; steps "$2" ;;
    --guest-script) (( $# == 4 )) || usage; guest_script "$2" "$3" "$4" ;;
    --verify) (( $# == 3 )) || usage; verify "$2" "$3" ;;
    --dry-run) (( $# == 2 )) || usage; DRY=1; build "$2" ;;
    -*) usage ;;
    *) (( $# == 1 )) || usage; build "$1" ;;
esac
