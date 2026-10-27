#!/usr/bin/env bash
# Signed release set of the catalog: BUILDINFO.json, SHA256SUMS and its cosign
# signature — the same scheme as the release of the Teleport fork (key
# stvor-platform, ECDSA P-256, no Rekor, verified without network).
#
#   tools/release-sign.sh install DIR         cosign by the pin tools/cosign-pin.env → DIR/cosign
#   tools/release-sign.sh buildinfo DIST TAG  DIST/BUILDINFO.json; SHA256SUMS over the snapshot and BUILDINFO.json
#   tools/release-sign.sh sign DIST           DIST/SHA256SUMS.sig, DIST/SHA256SUMS.bundle.json
#   tools/release-sign.sh verify DIST PUB     both signatures, no network; .sig also by openssl
#   tools/release-sign.sh reconcile DIST PREV PUB OUT
#                                             rebuilt DIST against the published release PREV
#
# DIST is the output of tools/catalog-snapshot.sh: cream-extensions-<v>.tar.gz
# and SHA256SUMS. buildinfo checks that <v> is the version of TAG (vX.Y.Z) and
# takes the commit and its time from REF (default HEAD — the checked out tag);
# the time is the commit time, not "now", so a rerun on the same tag gives the
# same BUILDINFO.json and the same SHA256SUMS.
#
# reconcile: a signed release is immutable. PREV holds the published files of
# the release downloaded by name (those of DIST and SHA256SUMS.sig /
# .bundle.json, whichever exist):
#   - any published file (SHA256SUMS included) differs from DIST byte for
#     byte — refusal: no new signature, no --clobber;
#   - .sig and .bundle.json both published — they must verify with PUB
#     (otherwise refusal); the signature is copied into DIST, action "reuse";
#   - no signature or an incomplete one — action "sign".
# Writes OUT/action (reuse|sign), OUT/upload (missing files: upload without
# --clobber), OUT/clobber (the incomplete signature replaced by the new one).
#
# SHA256SUMS.sig — base64 of the ASN.1 ECDSA signature over sha256 of
# SHA256SUMS: Go stdlib (crypto/ecdsa.VerifyASN1) and
# `openssl dgst -sha256 -verify <pub> -signature <der>` check it.
# SHA256SUMS.bundle.json — the same for `cosign verify-blob --bundle`.
#
# sign takes the key from the environment: COSIGN_PRIVATE_KEY (the encrypted
# PEM of `cosign generate-key-pair`) and COSIGN_PASSWORD. Either missing is a
# failure, never an unsigned release. COSIGN — the cosign binary (default
# `cosign` from PATH).
#
# Exit: 0 — done; 1 — check failed (no secret, bad signature, wrong set);
# 2 — usage or setup failure.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
COSIGN="${COSIGN:-cosign}"

die() { echo "release-sign: $*" >&2; exit 2; }
fail() {
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::error::release-sign: $*" >&2; fi
    echo "release-sign: $*" >&2
    exit 1
}
usage() { sed -n '6,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
pin() { sed -n "s/^$1=//p" "$HERE/$2" | head -n 1; }

# The snapshot of DIST: exactly one cream-extensions-<v>.tar.gz.
snapshot_of() {
    local dist="$1" found=()
    shopt -s nullglob
    found=("$dist"/cream-extensions-*.tar.gz)
    shopt -u nullglob
    (( ${#found[@]} == 1 )) || fail "$dist: ждали ровно один cream-extensions-<v>.tar.gz, нашлось ${#found[@]}"
    basename "${found[0]}"
}

# Run "$@" with no network: a separate network namespace (only lo). Without
# unprivileged user namespaces (AppArmor of Ubuntu 24.04) — sudo unshare -n,
# and the command still runs as the calling user.
offline() {
    if unshare -rn true 2>/dev/null; then
        unshare -rn "$@"
    elif sudo -n true 2>/dev/null; then
        sudo -n env HOME="$HOME" unshare -n -- setpriv --reuid="$(id -u)" --regid="$(id -g)" --init-groups -- "$@"
    else
        die "нечем отрезать сеть: нет ни unshare -rn, ни sudo -n"
    fi
}

cmd_install() {
    (( $# == 1 )) || usage
    local dir="$1" ver sum
    ver="$(pin COSIGN_VERSION cosign-pin.env)"
    sum="$(pin COSIGN_SHA256_AMD64 cosign-pin.env)"
    [[ "$ver" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tools/cosign-pin.env: COSIGN_VERSION=\"$ver\""
    [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || die "tools/cosign-pin.env: COSIGN_SHA256_AMD64 — не sha256"
    mkdir -p "$dir"
    curl -fsSL --proto '=https' --retry 3 -o "$dir/cosign" \
        "https://github.com/sigstore/cosign/releases/download/${ver}/cosign-linux-amd64"
    echo "$sum  $dir/cosign" | sha256sum -c - || fail "cosign $ver: сумма не совпала с пином"
    chmod +x "$dir/cosign"
    "$dir/cosign" version 2>/dev/null | grep -m1 -i gitversion || true
}

cmd_buildinfo() {
    (( $# == 2 )) || usage
    local dist="$1" tag="$2" version asset commit epoch time run=""
    [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || fail "тег должен иметь вид vX.Y.Z, получено: '$tag'"
    version="${BASH_REMATCH[1]}"
    asset="$(snapshot_of "$dist")"
    [[ "$asset" == "cream-extensions-$version.tar.gz" ]] || fail "$asset: версия снимка не совпала с тегом $tag"
    (cd "$dist" && sha256sum -c SHA256SUMS >/dev/null) || fail "$dist/SHA256SUMS: снимок не совпал с суммой"
    commit="$(git -C "$REPO" rev-parse --verify "${REF:-HEAD}^{commit}")" || die "нет коммита ${REF:-HEAD}"
    epoch="$(git -C "$REPO" log -1 --format=%ct "$commit")"
    time="$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
        run="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID}"
    fi
    jq -n --arg tag "$tag" --arg commit "$commit" --arg version "$version" \
        --arg time "$time" --argjson epoch "$epoch" \
        --arg cream_version "$(pin CREAM_VERSION cream-pin.env)" \
        --arg cream_sha256 "$(pin CREAM_SHA256 cream-pin.env)" \
        --arg asset "$asset" --arg asset_sha256 "$(sha256sum "$dist/$asset" | cut -d' ' -f1)" \
        --arg run "$run" \
        '{tag:$tag, commit:$commit, version:$version, time:$time, source_date_epoch:$epoch,
          reproducible:true,
          snapshot:{tool:"cream catalog pack", script:"tools/catalog-snapshot.sh",
                    cream:{version:$cream_version, sha256_amd64:$cream_sha256, pins:"tools/cream-pin.env"}},
          files:{($asset):$asset_sha256},
          run:$run}' > "$dist/BUILDINFO.json"
    (cd "$dist" && sha256sum -- "$asset" BUILDINFO.json > SHA256SUMS && sha256sum -c SHA256SUMS >/dev/null)
    [[ "$(wc -l < "$dist/SHA256SUMS")" == 2 ]] || fail "в SHA256SUMS не 2 строки"
    cat "$dist/SHA256SUMS"
}

cmd_sign() {
    (( $# == 1 )) || usage
    local dist="$1" k
    [[ -n "${COSIGN_PRIVATE_KEY:-}" ]] || fail "нет секрета COSIGN_PRIVATE_KEY (environment release) — релиз без подписи не выпускается"
    [[ -n "${COSIGN_PASSWORD:-}" ]] || fail "нет секрета COSIGN_PASSWORD (environment release) — релиз без подписи не выпускается"
    [[ -f "$dist/SHA256SUMS" ]] || fail "нет $dist/SHA256SUMS"
    k="$(mktemp)"
    # shellcheck disable=SC2064  # the path is fixed now
    trap "rm -f -- '$k'" EXIT
    (umask 077; printf '%s\n' "$COSIGN_PRIVATE_KEY" > "$k")
    rm -f -- "$dist/SHA256SUMS.sig" "$dist/SHA256SUMS.bundle.json"
    "$COSIGN" sign-blob --yes --key "$k" \
        --use-signing-config=false --tlog-upload=false --new-bundle-format=false \
        --output-signature "$dist/SHA256SUMS.sig" "$dist/SHA256SUMS"
    "$COSIGN" sign-blob --yes --key "$k" \
        --use-signing-config=false --tlog-upload=false \
        --bundle "$dist/SHA256SUMS.bundle.json" "$dist/SHA256SUMS"
    echo "подписано: $dist/SHA256SUMS.sig, $dist/SHA256SUMS.bundle.json"
}

cmd_verify() {
    (( $# == 2 )) || usage
    local dist="$1" pub="$2" ifs der cosign_bin
    [[ -f "$pub" ]] || die "нет публичного ключа $pub"
    for f in SHA256SUMS SHA256SUMS.sig SHA256SUMS.bundle.json; do
        [[ -s "$dist/$f" ]] || fail "нет $dist/$f"
    done
    cosign_bin="$(command -v "$COSIGN")" || die "нет cosign ($COSIGN)"
    # The namespace really has no network: only lo.
    ifs="$(offline awk -F: 'NR > 2 {gsub(/ /, "", $1); printf "%s ", $1}' /proc/net/dev)"
    [[ "$ifs" == "lo " ]] || die "в пространстве имён без сети есть интерфейсы: $ifs"
    offline "$cosign_bin" verify-blob --key "$pub" --insecure-ignore-tlog=true \
        --signature "$dist/SHA256SUMS.sig" "$dist/SHA256SUMS" || fail "SHA256SUMS.sig не проверяется ключом $pub"
    offline "$cosign_bin" verify-blob --key "$pub" --insecure-ignore-tlog=true \
        --bundle "$dist/SHA256SUMS.bundle.json" "$dist/SHA256SUMS" || fail "SHA256SUMS.bundle.json не проверяется ключом $pub"
    der="$(mktemp)"
    base64 -d "$dist/SHA256SUMS.sig" > "$der" || { rm -f -- "$der"; fail "SHA256SUMS.sig — не base64"; }
    if ! openssl dgst -sha256 -verify "$pub" -signature "$der" "$dist/SHA256SUMS"; then
        rm -f -- "$der"; fail "openssl: SHA256SUMS.sig не проверяется ключом $pub"
    fi
    rm -f -- "$der"
    (cd "$dist" && sha256sum -c SHA256SUMS) || fail "файлы не совпали с SHA256SUMS"
}

cmd_reconcile() {
    (( $# == 4 )) || usage
    local dist="$1" prev="$2" pub="$3" out="$4" f n chk
    [[ -s "$dist/SHA256SUMS" ]] || fail "нет $dist/SHA256SUMS"
    mkdir -p "$out"
    : > "$out/upload"
    : > "$out/clobber"
    shopt -s nullglob
    for f in "$prev"/*; do
        n="$(basename "$f")"
        [[ "$n" == SHA256SUMS.sig || "$n" == SHA256SUMS.bundle.json ]] && continue
        [[ -e "$dist/$n" ]] || fail "в релизе лишний файл $n — не из этой сборки"
        cmp -s "$f" "$dist/$n" ||
            fail "опубликованный $n отличается от пересборки — релиз неизменяем, не переподписывается и не заменяется"
    done
    if [[ -e "$prev/SHA256SUMS.sig" && -e "$prev/SHA256SUMS.bundle.json" ]]; then
        [[ -e "$prev/SHA256SUMS" ]] || fail "подпись опубликована без SHA256SUMS — релиз неизменяем"
        # SHA256SUMS опубликован тот же: подпись проверяется на копии DIST.
        chk="$(mktemp -d)"
        cp -- "$dist"/* "$chk/"
        cp -- "$prev/SHA256SUMS.sig" "$prev/SHA256SUMS.bundle.json" "$chk/"
        if ! (cmd_verify "$chk" "$pub") >/dev/null 2>&1; then
            rm -r -f -- "$chk"
            fail "опубликованная подпись не проверяется ключом $pub — релиз неизменяем, не переподписывается"
        fi
        rm -r -f -- "$chk"
        cp -- "$prev/SHA256SUMS.sig" "$prev/SHA256SUMS.bundle.json" "$dist/"
        echo reuse > "$out/action"
    else
        echo sign > "$out/action"
    fi
    for f in "$dist"/*; do
        n="$(basename "$f")"
        [[ "$n" == SHA256SUMS.sig || "$n" == SHA256SUMS.bundle.json ]] && continue
        [[ -e "$prev/$n" ]] || echo "$n" >> "$out/upload"
    done
    shopt -u nullglob
    if [[ "$(cat "$out/action")" == sign ]]; then
        for n in SHA256SUMS.sig SHA256SUMS.bundle.json; do
            if [[ -e "$prev/$n" ]]; then echo "$n" >> "$out/clobber"; else echo "$n" >> "$out/upload"; fi
        done
    fi
    echo "reconcile: $(cat "$out/action"); загрузить: $(tr '\n' ' ' < "$out/upload"); заменить: $(tr '\n' ' ' < "$out/clobber")"
}

(( $# >= 1 )) || usage
sub="$1"; shift
case "$sub" in
    install) cmd_install "$@" ;;
    buildinfo) cmd_buildinfo "$@" ;;
    sign) cmd_sign "$@" ;;
    verify) cmd_verify "$@" ;;
    reconcile) cmd_reconcile "$@" ;;
    *) usage ;;
esac
