#!/usr/bin/env bash
# Raise the cream pin of this catalog (tools/cream-pin.env) to a release of
# iamletenkov/cream, in the working tree only.
#
# Usage: tools/cream-bump.sh <tag> <SHA256SUMS>
#
#   <tag>         cream release tag, vX.Y.Z
#   <SHA256SUMS>  that release's SHA256SUMS file, e.g. fetched with
#                 gh release download <tag> -R iamletenkov/cream -p SHA256SUMS -D <dir>
#
# Edits CREAM_VERSION, CREAM_SHA256 (cream_<v>_amd64.deb) and
# CREAM_SHA256_ARM64 (cream_<v>_arm64.deb); CREAM_URL and the comments stay.
# Does not commit, does not run the checks — the caller does (tools/check.sh;
# the workflow is cream-bump.yml).
#
# Prints `version=`, `sha256_amd64=`, `sha256_arm64=` and `changed=true|false`
# (GITHUB_OUTPUT format) on stdout. A release older than the pin or already
# pinned is `changed=false`, not an error. The same version with another sum
# is an error — the package changed under its version, a human has to look.
#
# Exit: 0 — done / nothing to do; 1 — release or pin problem; 2 — usage.
set -euo pipefail

TAG="${1:-}"
SUMS="${2:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="$ROOT/tools/cream-pin.env"
SEMVER='[0-9]+\.[0-9]+\.[0-9]+'

die(){ echo "error: $*" >&2; exit 1; }

[[ "$TAG" =~ ^v$SEMVER$ ]] || { echo "error: tag must match vX.Y.Z, got '$TAG'" >&2; exit 2; }
[[ -f "$SUMS" ]] || { echo "error: SHA256SUMS file required, got '$SUMS'" >&2; exit 2; }

new="${TAG#v}"
# sha256sum writes "<sum>  <file>" (text) or "<sum> *<file>" (binary).
sum_of(){
    local f="$1" found
    found="$(awk -v f="$f" '$2 == f || $2 == "*" f {print $1}' "$SUMS")"
    [[ "$found" =~ ^[0-9a-f]{64}$ ]] || die "no single sha256 for $f in $SUMS"
    echo "$found"
}
amd64="$(sum_of "cream_${new}_amd64.deb")"
arm64="$(sum_of "cream_${new}_arm64.deb")"

# The pin is data (KEY=value), read without sourcing.
pin_get(){ sed -nE "s/^$1=(.*)$/\1/p" "$PIN"; }
old="$(pin_get CREAM_VERSION)"
old_amd64="$(pin_get CREAM_SHA256)"
old_arm64="$(pin_get CREAM_SHA256_ARM64)"
[[ "$old" =~ ^$SEMVER$ ]] || die "no CREAM_VERSION in $PIN"

echo "version=$new"
if [[ "$old" == "$new" ]]; then
    [[ "$old_amd64" == "$amd64" ]] || die "cream $new amd64 is pinned with sha256 $old_amd64, the release lists $amd64"
    [[ "$old_arm64" == "$arm64" ]] || die "cream $new arm64 is pinned with sha256 $old_arm64, the release lists $arm64"
    echo "changed=false"
    echo "cream $new is already pinned" >&2
    exit 0
fi
if [[ "$(printf '%s\n%s\n' "$old" "$new" | sort -V | tail -n 1)" == "$old" ]]; then
    echo "changed=false"
    echo "cream $new is older than the pinned $old — nothing to do" >&2
    exit 0
fi

sed -i -E \
    -e "s/^CREAM_VERSION=.*$/CREAM_VERSION=$new/" \
    -e "s/^CREAM_SHA256=.*$/CREAM_SHA256=$amd64/" \
    -e "s/^CREAM_SHA256_ARM64=.*$/CREAM_SHA256_ARM64=$arm64/" \
    "$PIN"

# A silent no-op here would ship a PR that half-moves the pin.
for line in "CREAM_VERSION=$new" "CREAM_SHA256=$amd64" "CREAM_SHA256_ARM64=$arm64"; do
    grep -qxF -- "$line" "$PIN" || die "not updated in tools/cream-pin.env: $line"
done

echo "sha256_amd64=$amd64"
echo "sha256_arm64=$arm64"
echo "changed=true"
