# shellcheck shell=bash
# Library `fetch` (cream/v1, kind: library): a large download by a pinned
# sha256 that survives a dropped connection. Sourced, never executed; the
# consumer declares `depends: [{name: fetch, version: ">=1.0.0 <2"}]` and its
# hook does
#
#   source "${CREAM_ROOT:-}/opt/cream/ext/fetch/fetch.sh"
#   fetch_verified "$WORK/asset" "$SHA256" "$URL" ["$MIRROR_URL" …]
#
# WHY. curl 7.68 (Ubuntu 20.04 focal — the L4T rootfs of Jetson Nano) does not
# retry "Connection reset by peer" (curl 56) even with --retry 5, and
# --retry-all-errors appeared only in 7.71. A large AppImage over the board's
# network failed the whole install on the first reset (acceptance on Jetson
# Nano, 2026-10-22). So the attempts are a loop of our own around curl, for any
# curl error, and curl's own --retry is not used: it would multiply the waits.
#
#   fetch_verified DEST SHA256 URL…
#       Each URL in turn, FETCH_ATTEMPTS attempts (default 5) with
#       FETCH_DELAY seconds between them (default 10). The file is written to
#       DEST.part and renamed to DEST only when its sha256 is SHA256.
#       0 — DEST is the pinned file; 1 — no URL gave the file;
#       2 — a file came but its sha256 is not SHA256 (no more attempts: the
#           content, not the network, is wrong); 3 — a wrong call (SHA256 not
#           64 hex digits, no URL, FETCH_ATTEMPTS not a positive number).
#       Nothing is left at DEST.part on any outcome.
#
# A stalled transfer (below 10 KB/s for 60 s — the download froze at 76 of
# 535 MB on AGX Orin Wi-Fi, 2026-09-15) is a failed attempt, not an endless
# wait. Only https and http are followed. The caller's log_warn/log_error are
# used when defined; plain stderr otherwise. Library code sets no shell
# options.

_fetch_warn(){
    if declare -F log_warn >/dev/null; then log_warn "$@"; else >&2 echo "[WARN] ${CREAM_EXT:-fetch}: $*"; fi
}

_fetch_error(){
    if declare -F log_error >/dev/null; then log_error "$@"; else >&2 echo "[ERROR] ${CREAM_EXT:-fetch}: $*"; fi
}

fetch_verified(){
    local dest="${1:-}" sha="${2:-}" attempts="${FETCH_ATTEMPTS:-5}" delay="${FETCH_DELAY:-10}"
    local url i rc
    if [[ -z "$dest" || ! "$sha" =~ ^[0-9a-f]{64}$ || $# -lt 3 ]]; then
        _fetch_error "fetch_verified DEST SHA256 URL…: нужны путь, sha256 (64 hex) и хотя бы один адрес"
        return 3
    fi
    if [[ ! "$attempts" =~ ^[1-9][0-9]*$ || ! "$delay" =~ ^[0-9]+$ ]]; then
        _fetch_error "FETCH_ATTEMPTS=$attempts, FETCH_DELAY=$delay: нужны целые, попыток ≥ 1"
        return 3
    fi
    shift 2
    for url in "$@"; do
        for (( i = 1; i <= attempts; i++ )); do
            rc=0
            curl -fsSL --proto '=https,http' --connect-timeout 30 \
                --speed-limit 10240 --speed-time 60 -o "$dest.part" "$url" || rc=$?
            if (( rc == 0 )); then
                if echo "$sha  $dest.part" | sha256sum -c --quiet - >/dev/null 2>&1; then
                    mv -f -- "$dest.part" "$dest"
                    return 0
                fi
                rm -f -- "$dest.part"
                _fetch_error "sha256 скачанного с $url не совпал с закреплённым $sha — не беру"
                return 2
            fi
            rm -f -- "$dest.part"
            if (( i < attempts )); then
                _fetch_warn "попытка $i/$attempts: $url — curl $rc, повтор через $delay с"
                sleep "$delay"
            else
                _fetch_warn "попытка $i/$attempts: $url — curl $rc, попытки по этому адресу кончились"
            fi
        done
    done
    _fetch_error "файл не скачался ни по одному адресу: $*"
    return 1
}
