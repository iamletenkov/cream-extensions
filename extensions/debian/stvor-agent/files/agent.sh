# shellcheck shell=bash
# The stvor-agent package: which one, where from, how it goes on and off.
# Sourced by the hooks (hooks/install, upgrade, remove, apply); the pure
# functions are called by tools/test-stvor-agent.sh. The agent lives in its own
# repository and ships as stvor-agent_<version>_<arch>.deb:
# https://github.com/iamletenkov/stvor-agent
#
# Keys of the domain (cream passes them as environment, spec cream §6.3):
#   STVOR_AGENT_VERSION + STVOR_AGENT_SHA256  explicit version and sha256 of
#       the .deb of this machine's architecture; both or neither — neither
#       means the catalog pin files/pin.env
#   STVOR_AGENT_MIRROR  base URL, the file lies flat: <base>/<deb name>
#   STVOR_AGENT_DEB     absolute path of a local .deb (offline)
#   default source — the GitHub release of the version
# The labels token is never an input here: `stvor-agent enable` takes it on
# stdin. Children (curl, dpkg, stvor-agent) get a minimal environment of their
# own, so nothing the caller had in its environment reaches them.

SA_RELEASES=https://github.com/iamletenkov/stvor-agent/releases/download
RE_SA_VERSION='^[0-9]+\.[0-9]+\.[0-9]+$'
RE_SA_SHA256='^[0-9a-f]{64}$'
RE_SA_URL='^https?://[A-Za-z0-9._~:/%+-]+$'

sa_log(){ >&2 echo "stvor-agent: $*"; }
sa_die(){ >&2 echo "stvor-agent: ОШИБКА: $*"; exit 1; }

sa_deb_name(){ echo "stvor-agent_$1_$2.deb"; }
# sa_url <version> <arch> <mirror>
sa_url(){
    if [[ -n "$3" ]]; then
        echo "${3%/}/$(sa_deb_name "$1" "$2")"
    else
        echo "$SA_RELEASES/v$1/$(sa_deb_name "$1" "$2")"
    fi
}
# sa_pin_get <file> <KEY>: the value of KEY= (data, not sourced).
sa_pin_get(){
    local line
    line="$(grep -E "^$2=" "$1" | tail -n1)" || true
    printf '%s' "${line#*=}"
}
# sa_run <command…>: a child with a minimal environment of its own.
sa_run(){ env -i "PATH=$PATH" LANG=C.UTF-8 DEBIAN_FRONTEND=noninteractive "$@"; }
sa_arch(){
    local a
    a="$(sa_run dpkg --print-architecture)" || return 1
    case "$a" in
        amd64|arm64) echo "$a" ;;
        *) sa_log "ОШИБКА: архитектура $a не поддерживается (amd64, arm64)"; return 1 ;;
    esac
}
# sa_installed_version: the installed version of the package, empty — none.
sa_installed_version(){
    local s
    s="$(sa_run dpkg-query -W -f='${Status} ${Version}' stvor-agent 2>/dev/null)" || return 0
    [[ "$s" == "install ok installed "* ]] && echo "${s#install ok installed }"
    return 0
}

# sa_select <arch>: sets SA_VERSION and SA_SHA256 — the explicit pair or the
# catalog pin. Exits on a half pair or an incomplete pin, before any network.
sa_select(){
    local arch="$1" v="${STVOR_AGENT_VERSION:-}" s="${STVOR_AGENT_SHA256:-}" pin key
    if [[ -n "$v" && -z "$s" ]]; then
        sa_die "STVOR_AGENT_VERSION=$v задан без STVOR_AGENT_SHA256 — задайте обе или ни одной (тогда пин каталога)"
    elif [[ -z "$v" && -n "$s" ]]; then
        sa_die "STVOR_AGENT_SHA256 задан без STVOR_AGENT_VERSION — задайте обе или ни одной (тогда пин каталога)"
    elif [[ -z "$v" ]]; then
        pin="$CREAM_EXT_DIR/files/pin.env"
        [[ -f "$pin" ]] || sa_die "нет пина каталога $pin — задайте STVOR_AGENT_VERSION и STVOR_AGENT_SHA256"
        key="STVOR_AGENT_PIN_SHA256_${arch^^}"
        v="$(sa_pin_get "$pin" STVOR_AGENT_PIN_VERSION)"
        s="$(sa_pin_get "$pin" "$key")"
        [[ -n "$v" && -n "$s" ]] \
            || sa_die "пин каталога неполон (STVOR_AGENT_PIN_VERSION, $key) — задайте STVOR_AGENT_VERSION и STVOR_AGENT_SHA256"
        sa_log "пин каталога: $v"
    fi
    [[ "$v" =~ $RE_SA_VERSION ]] || sa_die "версия агента '$v': ожидали X.Y.Z"
    [[ "$s" =~ $RE_SA_SHA256 ]] || sa_die "sha256 пакета агента: ожидали 64 hex"
    SA_VERSION="$v"
    SA_SHA256="$s"
}

# sa_check_source: STVOR_AGENT_MIRROR and STVOR_AGENT_DEB, before any network.
sa_check_source(){
    local mirror="${STVOR_AGENT_MIRROR:-}" deb="${STVOR_AGENT_DEB:-}"
    if [[ -n "$mirror" && -n "$deb" ]]; then
        sa_die "STVOR_AGENT_MIRROR и STVOR_AGENT_DEB взаимоисключающие — задайте один"
    fi
    [[ -z "$mirror" || "$mirror" =~ $RE_SA_URL ]] || sa_die "STVOR_AGENT_MIRROR='$mirror': ожидали http(s) URL"
    if [[ -n "$deb" ]]; then
        [[ "$deb" == /* ]] || sa_die "STVOR_AGENT_DEB=$deb: нужен абсолютный путь"
        [[ -f "$deb" ]] || sa_die "STVOR_AGENT_DEB=$deb: файла нет"
    fi
    return 0
}

# sa_fetch <work dir> <arch>: the checked .deb, its path on stdout.
sa_fetch(){
    local work="$1" arch="$2" file url
    file="$work/$(sa_deb_name "$SA_VERSION" "$arch")"
    if [[ -n "${STVOR_AGENT_DEB:-}" ]]; then
        cp -- "$STVOR_AGENT_DEB" "$file" || return 1
    else
        command -v curl >/dev/null 2>&1 || { sa_log "ОШИБКА: нет curl — поставьте его или задайте STVOR_AGENT_DEB"; return 1; }
        url="$(sa_url "$SA_VERSION" "$arch" "${STVOR_AGENT_MIRROR:-}")"
        sa_log "скачиваю $url"
        # Stalls become retries instead of an endless wait.
        sa_run curl -fL --retry 5 --retry-delay 5 \
            --connect-timeout 30 --speed-limit 10240 --speed-time 60 \
            -o "$file" "$url" || { sa_log "ОШИБКА: пакет агента не скачался"; return 1; }
    fi
    if ! echo "$SA_SHA256  $file" | sha256sum -c --quiet - >/dev/null 2>&1; then
        sa_log "ОШИБКА: sha256 пакета не совпал (ждали $SA_SHA256)"
        return 1
    fi
    echo "$file"
}

# hooks/install, hooks/upgrade: .deb → sha256 → dpkg -i. The package's own
# postinst enables the unit and restarts the service if the agent is enabled;
# in a build (no systemd) it only links the unit.
sa_hook_install(){
    local arch work deb have
    arch="$(sa_arch)" || exit 1
    sa_select "$arch"
    sa_check_source
    have="$(sa_installed_version)"
    if [[ "$have" == "$SA_VERSION" ]]; then
        sa_log "stvor-agent $SA_VERSION уже установлен"
        return 0
    fi
    work="$(mktemp -d "${TMPDIR:-/var/tmp}/stvor-agent.XXXXXX")"
    # shellcheck disable=SC2064  # the path is fixed now, on purpose
    trap "rm -r -f -- '$work'" EXIT
    deb="$(sa_fetch "$work" "$arch")" || exit 1
    sa_run dpkg -i "$deb" || sa_die "dpkg -i $(basename "$deb") не прошёл"
    sa_log "установлен $(basename "$deb")${have:+ (было $have)}"
    sa_reload_labels
    sa_log "включение: printf '%s' '<токен>' | sudo stvor-agent enable 'URL=https://<портал>/robot-api/v1/labels'"
}

# The drop-in of the stvor_agent label is laid by cream before the install
# hook (spec cream §6.5): the render teleport-apps.path ran then skipped the
# command, the binary was not there yet. Now it is: render + reload (HUP, no
# restart) through teleport-apps.service, without waiting (cream convention).
# Its ConditionPathExists=/etc/teleport.yaml makes it a no-op before join.
sa_reload_labels(){
    if [[ "${CREAM_PHASE:-live}" == build || ! -d "${CREAM_ROOT%/}/run/systemd/system" ]]; then
        return 0
    fi
    sa_run systemctl --no-block start teleport-apps.service \
        || sa_log "ВНИМАНИЕ: teleport-apps.service не запущен — метка stvor_agent появится при следующем render teleport"
    return 0
}

# hooks/remove: the agent forgets its token and stops, then the package goes.
sa_hook_remove(){
    local have
    have="$(sa_installed_version)"
    if [[ -z "$have" ]]; then
        sa_log "пакет stvor-agent не установлен — снимать нечего"
        return 0
    fi
    if command -v stvor-agent >/dev/null 2>&1; then
        sa_run stvor-agent disable || sa_die "stvor-agent disable не прошёл — пакет не снят"
    fi
    sa_run dpkg -r stvor-agent || sa_die "dpkg -r stvor-agent не прошёл"
    sa_log "пакет stvor-agent $have снят"
}

# hooks/apply: the service rereads /etc/cream/stvor-agent/config on restart.
# Never waits for systemd jobs (cream convention); no-op without systemd.
sa_hook_apply(){
    if [[ "${CREAM_PHASE:-live}" == build || ! -d "${CREAM_ROOT%/}/run/systemd/system" ]]; then
        sa_log "systemd не запущен — настройки подхватит служба при старте"
        return 0
    fi
    sa_run systemctl --no-block try-restart stvor-agent.service
}
