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
# (patch bump of the extension version with a history line under it). Does
# not commit, does not run the checks — the caller does (tools/check.sh).
#
# Prints `version=`, `sha256_amd64=`, `sha256_arm64=`, `ext_version=` and
# `changed=true|false` (GITHUB_OUTPUT format) on stdout. A release older than
# the pin or already pinned is `changed=false`, not an error: a rebuild of an
# old release dispatches here too. The same version with another sum is an
# error — the pinned package changed under its version, a human has to look.
# The one exception is the fictitious test pin (all-zero sums, put before the
# first release): the same version replaces it, and its note goes away.
set -euo pipefail

TAG="${1:-}"
SUMS="${2:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT="$ROOT/extensions/debian/stvor-agent"
PIN="$EXT/files/pin.env"
MANIFEST="$EXT/extension.yaml"
SEMVER='[0-9]+\.[0-9]+\.[0-9]+'
ZERO="$(printf '0%.0s' {1..64})"
ARCHES=(amd64 arm64)

die(){ echo "error: $*" >&2; exit 1; }

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: tag must match vX.Y.Z, got '$TAG'" >&2; exit 2; }
[[ -f "$SUMS" ]] || { echo "error: SHA256SUMS file required, got '$SUMS'" >&2; exit 2; }

new="${TAG#v}"
declare -A sha old_sha
for arch in "${ARCHES[@]}"; do
    deb="stvor-agent_${new}_${arch}.deb"
    # sha256sum writes "<sum>  <file>" (text) or "<sum> *<file>" (binary).
    found="$(awk -v f="$deb" '$2 == f || $2 == "*" f {print $1}' "$SUMS")"
    [[ "$found" =~ ^[0-9a-f]{64}$ ]] || die "no single sha256 for $deb in $SUMS"
    sha[$arch]="$found"
done

# The pin is data (KEY=value), read without sourcing.
pin_get(){ sed -nE "s/^$1=(.*)$/\1/p" "$PIN"; }
old="$(pin_get STVOR_AGENT_PIN_VERSION)"
[[ "$old" =~ ^$SEMVER$ ]] || die "no STVOR_AGENT_PIN_VERSION in $PIN"
fictitious=true
for arch in "${ARCHES[@]}"; do
    old_sha[$arch]="$(pin_get "STVOR_AGENT_PIN_SHA256_${arch^^}")"
    [[ "${old_sha[$arch]}" =~ ^[0-9a-f]{64}$ ]] || die "no STVOR_AGENT_PIN_SHA256_${arch^^} in $PIN"
    [[ "${old_sha[$arch]}" == "$ZERO" ]] || fictitious=false
done

if [[ "$old" == "$new" && "$fictitious" == false ]]; then
    for arch in "${ARCHES[@]}"; do
        [[ "${old_sha[$arch]}" == "${sha[$arch]}" ]] \
            || die "stvor-agent $new $arch is pinned with sha256 ${old_sha[$arch]}, the release lists ${sha[$arch]}"
    done
    echo "version=$new"
    echo "changed=false"
    echo "stvor-agent already pins $new" >&2
    exit 0
fi
if [[ "$old" != "$new" && "$(printf '%s\n%s\n' "$old" "$new" | sort -V | tail -n 1)" == "$old" ]]; then
    echo "version=$new"
    echo "changed=false"
    echo "stvor-agent $new is older than the pinned $old — nothing to do" >&2
    exit 0
fi

ext_old="$(sed -nE "s/^version: ($SEMVER)$/\1/p" "$MANIFEST")"
[[ "$ext_old" =~ ^$SEMVER$ ]] || die "no version in $MANIFEST"
IFS=. read -r major minor patch <<< "$ext_old"
ext_new="$major.$minor.$((patch + 1))"

echo "version=$new"
echo "sha256_amd64=${sha[amd64]}"
echo "sha256_arm64=${sha[arm64]}"
echo "ext_version=$ext_new"

tmp="$(mktemp)"
trap 'rm -f -- "$tmp"' EXIT

# pin.env: the note of the fictitious pin (its comment lines and the empty
# "#" line above them) goes, then the three values.
awk '
    /^# FICTITIOUS TEST PIN/ { skip = 1; if (have && held == "#") have = 0; next }
    skip && /^#/ { next }
    { skip = 0; if (have) print held; held = $0; have = 1 }
    END { if (have) print held }
' "$PIN" > "$tmp"
sed -E \
    -e "s/^STVOR_AGENT_PIN_VERSION=.*$/STVOR_AGENT_PIN_VERSION=$new/" \
    -e "s/^STVOR_AGENT_PIN_SHA256_AMD64=.*$/STVOR_AGENT_PIN_SHA256_AMD64=${sha[amd64]}/" \
    -e "s/^STVOR_AGENT_PIN_SHA256_ARM64=.*$/STVOR_AGENT_PIN_SHA256_ARM64=${sha[arm64]}/" \
    "$tmp" > "$PIN"

# extension.yaml: the new version, the history line right under it.
sed -i -E \
    -e "s/^version: ${ext_old//./\\.}$/version: $ext_new/" \
    -e "/^version: ${ext_new//./\\.}$/a # $ext_new: пин пакета stvor-agent $new." \
    "$MANIFEST"

# A silent no-op here would ship a PR that half-moves the pin.
check(){ grep -qE -- "$2" "$1" || die "not updated in ${1#"$ROOT"/}: $2"; }
check "$PIN" "^STVOR_AGENT_PIN_VERSION=${new//./\\.}$"
check "$PIN" "^STVOR_AGENT_PIN_SHA256_AMD64=${sha[amd64]}$"
check "$PIN" "^STVOR_AGENT_PIN_SHA256_ARM64=${sha[arm64]}$"
check "$MANIFEST" "^version: ${ext_new//./\\.}$"
check "$MANIFEST" "^# ${ext_new//./\\.}: пин пакета stvor-agent ${new//./\\.}\.$"
if grep -q FICTITIOUS "$PIN"; then
    die "the fictitious pin note is still in ${PIN#"$ROOT"/}"
fi

echo "changed=true"
