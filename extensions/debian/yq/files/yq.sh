# shellcheck shell=bash
# yq: the logic of the hooks install and remove, sourced by hooks/<name>.
#
# One tool, always the same one: mikefarah/yq as a static binary by the
# catalog pin (files/pin.env) and its sha256, into /usr/local/bin/yq. What
# install put there is recorded in $CREAM_STATE_DIR/installed ("<version>
# <sha256>"): remove takes the binary away only while it is still that one.
#
# Paths go under CREAM_ROOT (empty on a machine): the tests run the hooks on a
# scratch root.

yq_log() { printf '%s yq: %s\n' "$1" "$2" >&2; }
yq_info() { yq_log '[INFO]' "$*"; }
yq_warn() { yq_log '[WARN]' "$*"; }
yq_error() { yq_log '[ERROR]' "$*"; }

YQ_ROOT="${CREAM_ROOT%/}"
YQ_DST="$YQ_ROOT/usr/local/bin/yq"
YQ_RECORD="${CREAM_STATE_DIR:?run by cream}/installed"
YQ_GH=https://github.com/mikefarah/yq/releases/download

# yq_pin KEY: value of KEY= from the catalog pin (data, not sourced).
yq_pin() {
    sed -n "s/^$1=//p" "${CREAM_EXT_DIR:?run by cream}/files/pin.env" | tail -n1
}

yq_sha() { sha256sum "$1" | cut -d' ' -f1; }

# yq_is_mikefarah FILE: FILE runs and says it is mikefarah/yq.
yq_is_mikefarah() {
    [[ -x "$1" ]] && "$1" --version 2>&1 | head -n1 | grep -q mikefarah
}

# yq_ours: the binary in place is the one install recorded; sets
# YQ_OURS_VERSION and YQ_OURS_SHA.
yq_ours() {
    YQ_OURS_VERSION="" YQ_OURS_SHA=""
    [[ -f "$YQ_RECORD" && -f "$YQ_DST" ]] || return 1
    read -r YQ_OURS_VERSION YQ_OURS_SHA < "$YQ_RECORD" || return 1
    [[ "$(yq_sha "$YQ_DST")" == "$YQ_OURS_SHA" ]]
}

yq_hook_install() {
    local arch pin_v want_v want_sha url tmp c have
    arch="$(dpkg --print-architecture)"
    case "$arch" in
        amd64|arm64) ;;
        *) yq_error "неподдерживаемая архитектура: $arch"; return 1 ;;
    esac

    # Version and sha256: the catalog pin unless YQ_VERSION names another
    # release; then YQ_SHA256 is mandatory — nothing unchecked goes on.
    pin_v="$(yq_pin YQ_PIN_VERSION)"
    want_v="${YQ_VERSION:-$pin_v}"
    want_sha="${YQ_SHA256:-}"
    if [[ -z "$want_sha" ]]; then
        if [[ "$want_v" != "$pin_v" ]]; then
            yq_error "YQ_VERSION=$want_v не пин каталога ($pin_v): нужен YQ_SHA256 бинаря yq_linux_$arch"
            return 1
        fi
        want_sha="$(yq_pin "YQ_PIN_SHA256_${arch^^}")"
    fi
    [[ "$want_sha" =~ ^[0-9a-f]{64}$ ]] || { yq_error "нет sha256 для $want_v/$arch"; return 1; }

    if yq_ours; then
        if [[ "$YQ_OURS_VERSION" == "$want_v" && "$YQ_OURS_SHA" == "$want_sha" ]]; then
            yq_info "уже установлен: $want_v"
            return 0
        fi
        yq_info "заменяю свой $YQ_OURS_VERSION на $want_v"
    else
        # Someone else's mikefarah/yq is left alone: replacing it for a version
        # number would touch what this extension did not install. The other
        # yq (kislyuk, a jq wrapper from the distribution package) is shadowed
        # by ours in /usr/local/bin, which comes first in PATH; the package
        # itself is not removed — its dependencies are not ours.
        for c in "$YQ_DST" "$YQ_ROOT/usr/bin/yq"; do
            [[ -e "$c" ]] || continue
            have="$("$c" --version 2>&1 | head -n1 || true)"
            if yq_is_mikefarah "$c"; then
                yq_info "уже установлен не этим расширением (${c#"$YQ_ROOT"}): $have — не трогаю"
                return 0
            fi
            yq_warn "найден другой yq (${c#"$YQ_ROOT"}: $have) — ставлю свой в /usr/local/bin"
        done
    fi

    url="$YQ_GH/$want_v/yq_linux_$arch"
    mkdir -p "$(dirname "$YQ_DST")" "$(dirname "$YQ_RECORD")"
    tmp="$(mktemp "$(dirname "$YQ_DST")/.yq.XXXXXX")"
    # shellcheck disable=SC2064  # expand now: the path is fixed
    trap "rm -f -- '$tmp'" EXIT
    yq_info "качаю $want_v для $arch"
    if ! curl -fsSL --retry 3 --proto '=https' -o "$tmp" "$url"; then
        yq_error "не скачался: $url"
        return 1
    fi
    if [[ "$(yq_sha "$tmp")" != "$want_sha" ]]; then
        yq_error "sha256 не совпал: $url (ждали $want_sha)"
        return 1
    fi
    chmod 0755 "$tmp"
    # A full path: the guest shell of virt-customize has no /usr/local/bin in PATH.
    if ! yq_is_mikefarah "$tmp"; then
        yq_error "скачанный бинарь не запускается или не mikefarah/yq"
        return 1
    fi
    mv -f -- "$tmp" "$YQ_DST"
    trap - EXIT
    printf '%s %s\n' "$want_v" "$want_sha" > "$YQ_RECORD"
    yq_info "установлен: $("$YQ_DST" --version 2>&1 | head -n1)"
}

yq_hook_remove() {
    if [[ ! -f "$YQ_RECORD" ]]; then
        yq_info "бинарь ставило не это расширение — снимать нечего"
        return 0
    fi
    if yq_ours; then
        rm -f -- "$YQ_DST"
        yq_info "снят /usr/local/bin/yq"
    elif [[ -e "$YQ_DST" ]]; then
        yq_warn "/usr/local/bin/yq изменён после установки — оставлен"
    fi
    rm -f -- "$YQ_RECORD"
}
