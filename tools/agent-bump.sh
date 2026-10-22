#!/usr/bin/env bash
# Raise the catalog pin of the stvor-agent wrapper to a release of
# iamletenkov/stvor-agent, in the working tree only.
#
# Usage: tools/agent-bump.sh <tag> <SHA256SUMS>
#
#   <tag>         agent release tag, vX.Y.Z
#   <SHA256SUMS>  that release's SHA256SUMS file, e.g. fetched with
#                 gh release download <tag> -R iamletenkov/stvor-agent \
#                     -p SHA256SUMS -D <dir>
#
# Edits extensions/debian/stvor-agent: files/pin.env (version and the sums of
# stvor-agent_<v>_amd64.deb and stvor-agent_<v>_arm64.deb) and extension.yaml
# (patch bump of the extension version with a history line under it); and the
# same way extensions/openwrt/stvor-agent-openwrt from the sums of
# stvor-agent_<v>_linux_{amd64,arm64}.tar.gz of the same SHA256SUMS — when the
# release has no tar.gz at all, that pin stays (a note on stderr); one
# architecture only is an error. Does not commit, does not run the checks — the
# caller does (tools/check.sh). Every check of both pins comes before any write.
#
# Prints `version=`; for a changed .deb pin `sha256_amd64=`, `sha256_arm64=`,
# `ext_version=`; for a changed tar.gz pin `openwrt_sha256_amd64=`,
# `openwrt_sha256_arm64=`, `openwrt_ext_version=`; then `changed=true|false`
# (GITHUB_OUTPUT format) on stdout. A release older than a pin or already
# pinned leaves that pin, not an error: a rebuild of an old release dispatches
# here too. The same version with another sum is an error — the pinned file
# changed under its version, a human has to look. The one exception is the
# fictitious test pin of the .deb (all-zero sums, put before the first
# release): the same version replaces it, and its note goes away. The tar.gz
# pin is empty before the first release with tar.gz: any version fills it.
set -euo pipefail

TAG="${1:-}"
SUMS="${2:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT="$ROOT/extensions/debian/stvor-agent"
PIN="$EXT/files/pin.env"
MANIFEST="$EXT/extension.yaml"
OEXT="$ROOT/extensions/openwrt/stvor-agent-openwrt"
OPIN="$OEXT/files/pin.env"
OMANIFEST="$OEXT/extension.yaml"
SEMVER='[0-9]+\.[0-9]+\.[0-9]+'
ZERO="$(printf '0%.0s' {1..64})"
ARCHES=(amd64 arm64)

die(){ echo "error: $*" >&2; exit 1; }

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: tag must match vX.Y.Z, got '$TAG'" >&2; exit 2; }
[[ -f "$SUMS" ]] || { echo "error: SHA256SUMS file required, got '$SUMS'" >&2; exit 2; }

new="${TAG#v}"
# sum_of <file name>: the one sha256 of the file in SHA256SUMS; empty — none.
# sha256sum writes "<sum>  <file>" (text) or "<sum> *<file>" (binary).
sum_of(){ awk -v f="$1" '$2 == f || $2 == "*" f {print $1}' "$SUMS"; }
declare -A sha old_sha osha old_osha
for arch in "${ARCHES[@]}"; do
    deb="stvor-agent_${new}_${arch}.deb"
    found="$(sum_of "$deb")"
    [[ "$found" =~ ^[0-9a-f]{64}$ ]] || die "no single sha256 for $deb in $SUMS"
    sha[$arch]="$found"
done
# tar.gz of OpenWrt: all architectures or none.
otgz=0
for arch in "${ARCHES[@]}"; do
    [[ -n "$(sum_of "stvor-agent_${new}_linux_${arch}.tar.gz")" ]] && otgz=$((otgz + 1))
done
if (( otgz )); then
    for arch in "${ARCHES[@]}"; do
        tgz="stvor-agent_${new}_linux_${arch}.tar.gz"
        found="$(sum_of "$tgz")"
        [[ "$found" =~ ^[0-9a-f]{64}$ ]] || die "no single sha256 for $tgz in $SUMS"
        osha[$arch]="$found"
    done
fi

# The pin is data (KEY=value), read without sourcing.
pin_get(){ sed -nE "s/^$2=(.*)$/\1/p" "$1"; }
# newer <a> <b>: a is newer than b (versions compare as versions).
newer(){ [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]; }

# The .deb pin: change, or nothing to do.
deb_change=false
old="$(pin_get "$PIN" STVOR_AGENT_PIN_VERSION)"
[[ "$old" =~ ^$SEMVER$ ]] || die "no STVOR_AGENT_PIN_VERSION in $PIN"
fictitious=true
for arch in "${ARCHES[@]}"; do
    old_sha[$arch]="$(pin_get "$PIN" "STVOR_AGENT_PIN_SHA256_${arch^^}")"
    [[ "${old_sha[$arch]}" =~ ^[0-9a-f]{64}$ ]] || die "no STVOR_AGENT_PIN_SHA256_${arch^^} in $PIN"
    [[ "${old_sha[$arch]}" == "$ZERO" ]] || fictitious=false
done
if [[ "$old" == "$new" && "$fictitious" == false ]]; then
    for arch in "${ARCHES[@]}"; do
        [[ "${old_sha[$arch]}" == "${sha[$arch]}" ]] \
            || die "stvor-agent $new $arch is pinned with sha256 ${old_sha[$arch]}, the release lists ${sha[$arch]}"
    done
    echo "stvor-agent already pins $new" >&2
elif newer "$old" "$new"; then
    echo "stvor-agent $new is older than the pinned $old — nothing to do" >&2
else
    deb_change=true
fi

# The tar.gz pin of stvor-agent-openwrt: change, or nothing to do.
ow_change=false
if [[ ! -f "$OPIN" ]]; then
    :
elif (( ! otgz )); then
    echo "stvor-agent $new has no tar.gz in SHA256SUMS — the pin of stvor-agent-openwrt stays" >&2
else
    oold="$(pin_get "$OPIN" STVOR_AGENT_PIN_VERSION)"
    [[ -z "$oold" || "$oold" =~ ^$SEMVER$ ]] || die "STVOR_AGENT_PIN_VERSION in $OPIN is not X.Y.Z"
    for arch in "${ARCHES[@]}"; do
        old_osha[$arch]="$(pin_get "$OPIN" "STVOR_AGENT_PIN_SHA256_${arch^^}")"
    done
    if [[ "$oold" == "$new" ]]; then
        for arch in "${ARCHES[@]}"; do
            [[ "${old_osha[$arch]}" == "${osha[$arch]}" ]] \
                || die "stvor-agent-openwrt pins $new $arch with sha256 ${old_osha[$arch]}, the release lists ${osha[$arch]}"
        done
        echo "stvor-agent-openwrt already pins $new" >&2
    elif [[ -n "$oold" ]] && newer "$oold" "$new"; then
        echo "stvor-agent $new is older than the pinned $oold of stvor-agent-openwrt — nothing to do" >&2
    else
        ow_change=true
    fi
fi

# Both manifests are read before anything is written.
for m in "$MANIFEST" ${OPIN:+"$OMANIFEST"}; do
    [[ "$m" == "$OMANIFEST" && "$ow_change" == false ]] && continue
    [[ "$(sed -nE "s/^version: ($SEMVER)$/\1/p" "$m")" =~ ^$SEMVER$ ]] || die "no version in $m"
done

echo "version=$new"
if [[ "$deb_change" == false && "$ow_change" == false ]]; then
    echo "changed=false"
    exit 0
fi

tmp="$(mktemp)"
trap 'rm -f -- "$tmp"' EXIT

# bump_manifest <manifest> <history text>: patch bump, the history line right
# under `version:`; the new version on stdout.
bump_manifest(){
    local manifest="$1" text="$2" ext_old ext_new major minor patch
    ext_old="$(sed -nE "s/^version: ($SEMVER)$/\1/p" "$manifest")"
    [[ "$ext_old" =~ ^$SEMVER$ ]] || die "no version in $manifest"
    IFS=. read -r major minor patch <<< "$ext_old"
    ext_new="$major.$minor.$((patch + 1))"
    sed -i -E \
        -e "s/^version: ${ext_old//./\\.}$/version: $ext_new/" \
        -e "/^version: ${ext_new//./\\.}$/a # $ext_new: $text" \
        "$manifest"
    echo "$ext_new"
}
# write_pin <pin> <name of the map arch -> sha256>: the three values.
write_pin(){
    local pin="$1"
    local -n sums_ref="$2"
    sed -i -E \
        -e "s/^STVOR_AGENT_PIN_VERSION=.*$/STVOR_AGENT_PIN_VERSION=$new/" \
        -e "s/^STVOR_AGENT_PIN_SHA256_AMD64=.*$/STVOR_AGENT_PIN_SHA256_AMD64=${sums_ref[amd64]}/" \
        -e "s/^STVOR_AGENT_PIN_SHA256_ARM64=.*$/STVOR_AGENT_PIN_SHA256_ARM64=${sums_ref[arm64]}/" \
        "$pin"
}
# A silent no-op here would ship a PR that half-moves the pin.
check(){ grep -qE -- "$2" "$1" || die "not updated in ${1#"$ROOT"/}: $2"; }

if [[ "$deb_change" == true ]]; then
    # pin.env: the note of the fictitious pin (its comment lines and the empty
    # "#" line above them) goes, then the three values.
    awk '
        /^# FICTITIOUS TEST PIN/ { skip = 1; if (have && held == "#") have = 0; next }
        skip && /^#/ { next }
        { skip = 0; if (have) print held; held = $0; have = 1 }
        END { if (have) print held }
    ' "$PIN" > "$tmp"
    cat "$tmp" > "$PIN"
    write_pin "$PIN" sha
    ext_new="$(bump_manifest "$MANIFEST" "пин пакета stvor-agent $new.")"
    check "$PIN" "^STVOR_AGENT_PIN_VERSION=${new//./\\.}$"
    check "$PIN" "^STVOR_AGENT_PIN_SHA256_AMD64=${sha[amd64]}$"
    check "$PIN" "^STVOR_AGENT_PIN_SHA256_ARM64=${sha[arm64]}$"
    check "$MANIFEST" "^version: ${ext_new//./\\.}$"
    check "$MANIFEST" "^# ${ext_new//./\\.}: пин пакета stvor-agent ${new//./\\.}\.$"
    if grep -q FICTITIOUS "$PIN"; then
        die "the fictitious pin note is still in ${PIN#"$ROOT"/}"
    fi
    echo "sha256_amd64=${sha[amd64]}"
    echo "sha256_arm64=${sha[arm64]}"
    echo "ext_version=$ext_new"
fi

if [[ "$ow_change" == true ]]; then
    write_pin "$OPIN" osha
    oext_new="$(bump_manifest "$OMANIFEST" "пин tar.gz stvor-agent $new.")"
    check "$OPIN" "^STVOR_AGENT_PIN_VERSION=${new//./\\.}$"
    check "$OPIN" "^STVOR_AGENT_PIN_SHA256_AMD64=${osha[amd64]}$"
    check "$OPIN" "^STVOR_AGENT_PIN_SHA256_ARM64=${osha[arm64]}$"
    check "$OMANIFEST" "^version: ${oext_new//./\\.}$"
    check "$OMANIFEST" "^# ${oext_new//./\\.}: пин tar.gz stvor-agent ${new//./\\.}\.$"
    echo "openwrt_sha256_amd64=${osha[amd64]}"
    echo "openwrt_sha256_arm64=${osha[arm64]}"
    echo "openwrt_ext_version=$oext_new"
fi

echo "changed=true"
