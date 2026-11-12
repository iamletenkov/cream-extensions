#!/usr/bin/env bash
# Запуск Selkies на X-сессии пользователя (та же, что на мониторе).
#
# МИМО `AppRun`. Штатный вход AppImage делает две вещи, которые роботу вредят:
#   * нет сокета дисплея — поднимает Xvfb 8192×4096 и стримит ПУСТОЙ
#     виртуальный экран. Робот без сессии показал бы чёрный стол вместо
#     ошибки в журнале;
#   * нет PulseAudio пользователя — поднимает свой звуковой сервер в чужой
#     сессии.
# Поэтому переменные из `AppRun` ставятся здесь, а запускается сам бинарь.
#
# ЖДЁМ СЕССИЮ, А НЕ ПАДАЕМ. Сессию открывает менеджер входа, и появляется она
# после graphical.target; при выходе пользователя и повторном входе X
# authority меняется. Юнит перезапускает службу всегда, а обёртка до появления
# сессии ждёт молча (одна строка в журнал), вместо цикла падений каждые 5 с.
# Пропажу сессии во время работы ловит сторож в конце файла.
#
# АУТЕНТИФИКАЦИЯ — FAIL-CLOSED. Без SELKIES_BASIC_AUTH_PASSWORD Selkies не
# запускается вовсе, на любом адресе: петля не защищает от других учёток и
# служб этой же машины, а рабочий стол, буфер обмена и файлы — пользователя.
# Пароль есть — SELKIES_ENABLE_BASIC_AUTH=true ставится здесь, поверх того,
# что пришло из настроек (шаблон SELKIES_* выключить его не может). Без пароля
# снимает отказ только явный SELKIES_ALLOW_NO_AUTH=1 — с предупреждением при
# каждом старте и только на петле (решение владельца 2026-11-12): SELKIES_ADDR
# не петля, SELKIES_PUBLIC включён или SELKIES_COMPUTER_USE_BIND не на петле —
# отказ. Отказ — код 78: юнит (RestartPreventExitStatus=78) не крутит
# перезапуски.
#
# СЕКРЕТЫ. Пароли и токен приходят окружением из /etc/cream/selkies/secrets
# (EnvironmentFile юнита) и уходят только в окружение самого Selkies: у обёртки
# и её помощников (loginctl, xdpyinfo, pactl) их нет, в argv и журнал они не
# попадают.
#
# CREAM_ROOT — корень для тестов на подменённом корне; systemd его не задаёт,
# а ключ CREAM_* в настройки cream не пустит.
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} selkies: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} selkies: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} selkies: $*"; }

R="${CREAM_ROOT:-}"; R="${R%/}"
SECRET_KEYS=(SELKIES_BASIC_AUTH_PASSWORD SELKIES_BASIC_AUTH_VIEWONLY_PASSWORD SELKIES_MASTER_TOKEN)
# The secrets stay shell variables of the wrapper, not its environment.
for k in "${SECRET_KEYS[@]}"; do
    if [[ -n "${!k:-}" ]]; then export -n "${k?}"; else unset "$k"; fi
done

USERNAME="${1:?usage: run-selkies.sh <user>}"
(( EUID != 0 )) || { log_error "не от root: юнит запускает обёртку от имени пользователя (User=%i)"; exit 78; }
UID_OF_USER="$(id -u "$USERNAME")" || { log_error "нет пользователя $USERNAME"; exit 1; }
HOME_OF_USER="$R$(getent passwd "$USERNAME" | cut -d: -f6)"
PREFIX="$R/opt/selkies/current"
DISPLAY_NUM="${SELKIES_DISPLAY:-:0}"

# The monitor is the robot's, not the browser's. The settings come with the
# defaults of the manifest from /var/lib/cream/ext/selkies/env (written by
# configure); should that file be missing, Selkies' own default would be
# «sized by the client» — it resizes the X screen, and on a NVIDIA driver that
# refuses the mode it leaves a logical monitor bigger than the screen, so the
# clicks miss (Orin 2026-11-12). Empty means Selkies' default too.
export SELKIES_ENABLE_RESIZE="${SELKIES_ENABLE_RESIZE:-false}"

# bool_on <value>: 0 — on, the way Selkies reads a bool (settings.parse_bool:
# the part before "|", trimmed, lowercase, is true or 1); yes/on are off for it.
bool_on(){
    local v="${1%%|*}"
    v="${v//[[:space:]]/}"
    [[ "${v,,}" == true || "$v" == 1 ]]
}
bool_off(){ ! bool_on "$1"; }

# What is checked below is what Selkies gets: the address (absent or empty —
# the manifest's 127.0.0.1), the mode (the manifest's websockets), WebRTC
# through the UI only when asked for (the manifest's false; Selkies' own default
# is true), SELKIES_PUBLIC as Selkies reads it — true or false.
export SELKIES_ADDR="${SELKIES_ADDR:-127.0.0.1}"
export SELKIES_MODE="${SELKIES_MODE:-websockets}"
export SELKIES_ENABLE_DUAL_MODE="${SELKIES_ENABLE_DUAL_MODE:-false}"
if [[ -n "${SELKIES_PUBLIC+x}" ]]; then
    if bool_on "$SELKIES_PUBLIC"; then export SELKIES_PUBLIC=true; else export SELKIES_PUBLIC=false; fi
fi
addr="$SELKIES_ADDR"

# pixelflux starts its Computer-Use server from PIXELFLUX_CU at import, bypassing
# the check of SELKIES_COMPUTER_USE_BIND below: never passed on.
if [[ -n "${PIXELFLUX_CU+x}" ]]; then
    log_warn "PIXELFLUX_CU в окружении юнита не передаю: сервер Computer-Use — только через SELKIES_COMPUTER_USE_BIND"
    unset PIXELFLUX_CU
fi

RE_LOOPBACK='^(127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|::1|\[::1\]|localhost)$'
loopback_host(){ [[ "$1" =~ $RE_LOOPBACK ]]; }

# The listeners of Selkies 2.0.0 and pixelflux 2.1.0 — see beyond_loopback in
# selkies.sh (configure), the same rule; read from their sources 2026-11-12.

# cu_enabled: 0 — SELKIES_COMPUTER_USE_BIND names something (Selkies starts the
# Computer-Use server for any non-empty value; off by default).
cu_enabled(){ local v="${SELKIES_COMPUTER_USE_BIND:-}"; [[ -n "${v//[[:space:],]/}" ]]; }

# cu_beyond_loopback: prints SELKIES_COMPUTER_USE_BIND, 0 — an entry is beyond
# the loopback (a bare port is the loopback, host:port — the host).
cu_beyond_loopback(){
    local e entries=()
    IFS=, read -ra entries <<< "${SELKIES_COMPUTER_USE_BIND:-}"
    for e in "${entries[@]}"; do
        e="${e//[[:space:]]/}"
        [[ -z "$e" || "$e" =~ ^[0-9]+$ ]] && continue
        loopback_host "${e%:*}" || { echo "SELKIES_COMPUTER_USE_BIND=$SELKIES_COMPUTER_USE_BIND"; return 0; }
    done
    return 1
}

# beyond_loopback: prints what listens beyond the loopback, 0 — something does.
beyond_loopback(){
    loopback_host "$addr" || { echo "SELKIES_ADDR=$addr"; return 0; }
    bool_off "${SELKIES_PUBLIC:-}" || { echo "SELKIES_PUBLIC=$SELKIES_PUBLIC"; return 0; }
    [[ "$SELKIES_MODE" == websockets ]] \
        || { echo "SELKIES_MODE=$SELKIES_MODE (сокеты ICE WebRTC на всех адресах)"; return 0; }
    bool_off "$SELKIES_ENABLE_DUAL_MODE" \
        || { echo "SELKIES_ENABLE_DUAL_MODE=$SELKIES_ENABLE_DUAL_MODE (переход на WebRTC, сокеты ICE на всех адресах)"; return 0; }
    return 1
}

loopback=0
loopback_host "$addr" && loopback=1

# The Computer-Use server is without a password whatever Selkies' is.
if what="$(cu_beyond_loopback)"; then
    log_error "сервер Computer-Use pixelflux (ввод без аутентификации) допустим только на петле, а $what слушает сеть — не запускаюсь"
    exit 78
fi

if [[ -n "${SELKIES_BASIC_AUTH_PASSWORD:-}" ]]; then
    export SELKIES_ENABLE_BASIC_AUTH=true
    # SELKIES_PUBLIC with a password: Selkies refuses --public together with
    # --addr, and the env file always carries SELKIES_ADDR — not passed on.
    if ! bool_off "${SELKIES_PUBLIC:-}"; then
        unset SELKIES_ADDR
        addr="0.0.0.0,::"; loopback=0
        log_warn "SELKIES_PUBLIC=$SELKIES_PUBLIC: слушаю все интерфейсы (0.0.0.0, ::), SELKIES_ADDR не передаю"
    fi
    if (( ! loopback )) && [[ "${SELKIES_ENABLE_HTTPS:-false}" != true ]]; then
        log_warn "SELKIES_ADDR=$addr без SELKIES_ENABLE_HTTPS=true — пароль basic auth идёт по сети открытым текстом"
    fi
elif [[ "${SELKIES_ALLOW_NO_AUTH:-0}" == 1 ]]; then
    # Owner's ruling 2026-11-12: Computer-Use only with a password, on any
    # address; without a password only on the loopback.
    if cu_enabled; then
        log_error "SELKIES_COMPUTER_USE_BIND=$SELKIES_COMPUTER_USE_BIND: сервер Computer-Use pixelflux (ввод без аутентификации) включается только с паролем Selkies — не запускаюсь"
        log_error "задайте пароль: echo <пароль> | sudo cream set selkies SELKIES_BASIC_AUTH_PASSWORD=- или уберите ключ из /etc/cream/selkies/config"
        exit 78
    fi
    if what="$(beyond_loopback)"; then
        log_error "SELKIES_ALLOW_NO_AUTH=1 допустим только на петле (127.0.0.1, ::1, localhost), а $what слушает сеть — не запускаюсь"
        log_error "задайте пароль: echo <пароль> | sudo cream set selkies SELKIES_BASIC_AUTH_PASSWORD=-"
        log_error "или верните петлю: sudo cream set selkies SELKIES_ADDR=127.0.0.1"
        exit 78
    fi
    export SELKIES_ENABLE_BASIC_AUTH=false
    log_warn "БЕЗ АУТЕНТИФИКАЦИИ (SELKIES_ALLOW_NO_AUTH=1): рабочий стол, буфер обмена и файлы '$USERNAME' — любому, кто достаёт до ${addr}:${SELKIES_PORT:-8080}"
else
    log_error "нет SELKIES_BASIC_AUTH_PASSWORD — без аутентификации не запускаюсь"
    log_error "задайте пароль: echo <пароль> | sudo cream set selkies SELKIES_BASIC_AUTH_PASSWORD=-"
    log_error "или откройте без пароля осознанно: sudo cream set selkies SELKIES_ALLOW_NO_AUTH=1"
    exit 78
fi

[[ -x "$PREFIX/usr/conda/bin/selkies" ]] || { log_error "нет $PREFIX/usr/conda/bin/selkies — расширение не установлено"; exit 1; }

session_type(){
    local sid
    sid="$(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$USERNAME" '$3 == u && $4 == "seat0" {print $1; exit}')"
    [[ -n "$sid" ]] || return 1
    loginctl show-session "$sid" -p Type --value 2>/dev/null
}

# Кандидаты в X authority — те же и в том же порядке, что у x11vnc
# (разбор с замерами — x11vnc/run-x11vnc.sh).
find_authority(){
    local c xorg_pid xorg_auth
    local -a candidates=(
        "$HOME_OF_USER/.Xauthority"
        "/run/user/${UID_OF_USER}/gdm/Xauthority"
        "/run/lightdm/${USERNAME}/xauthority"
    )
    xorg_pid="$(pgrep -x Xorg | head -1 || true)"
    if [[ -n "$xorg_pid" && -r "/proc/$xorg_pid/cmdline" ]]; then
        xorg_auth="$(tr '\0' '\n' < "/proc/$xorg_pid/cmdline" | awk '/^-auth$/{getline; print; exit}')"
        [[ -n "$xorg_auth" ]] && candidates+=("$xorg_auth")
    fi
    for c in "${candidates[@]}"; do
        [[ -r "$c" ]] || continue
        if env XAUTHORITY="$c" xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1; then
            echo "$c"; return 0
        fi
    done
    return 1
}

AUTH=""; waited=0
until AUTH="$(find_authority)"; do
    if (( waited == 0 )); then
        log_info "жду X-сессию '$USERNAME' на $DISPLAY_NUM (без DESKTOP_AUTOLOGIN=1 она появится после входа человека)"
    fi
    # 78 (EX_CONFIG): the session type is a setting of the display manager, a
    # restart every 5 s would not change it (RestartPreventExitStatus=78).
    if [[ "$(session_type)" == wayland ]]; then
        log_error "сессия '$USERNAME' на Wayland — Selkies подключается только к X.Org, служба остановлена"
        log_error "включите Xorg у менеджера входа (расширение gnome пишет WaylandEnable=false), войдите заново"
        log_error "и запустите: sudo systemctl restart selkies@$USERNAME"
        exit 78
    fi
    sleep 5; waited=$((waited + 5))
done
log_info "дисплей $DISPLAY_NUM, authority $AUTH"

export DISPLAY="$DISPLAY_NUM" XAUTHORITY="$AUTH"
export HOME="$HOME_OF_USER" USER="$USERNAME"
export XDG_RUNTIME_DIR="/run/user/${UID_OF_USER}"
export PULSE_RUNTIME_PATH="$XDG_RUNTIME_DIR/pulse"
export PULSE_SERVER="unix:$PULSE_RUNTIME_PATH/native"
export PATH="$PREFIX/usr/conda/bin:$PATH"
export SELKIES_INTERPOSER="$PREFIX/usr/lib/selkies_joystick_interposer.so"
export SELKIES_WEBCAM_INTERPOSER="$PREFIX/usr/lib/selkies_v4l2_interposer.so"

# Звук — только PulseAudio пользователя; свой не поднимаем. Сокет появляется
# вместе с user@<uid>.service, а X-сессия автологина бывает готова раньше —
# ждём до 30 с, а не выключаем звук на первой проверке. Захват — monitor
# источника по умолчанию: имя Selkies «output.monitor» есть только в его
# AppRun, и pcmflux откатывается на monitor sink'а по умолчанию
# (замер на AGX Orin: alsa_output.platform-sound.analog-stereo.monitor).
if [[ "${SELKIES_AUDIO_ENABLED:-true}" == true ]]; then
    for _ in $(seq 1 30); do
        [[ -S "$PULSE_RUNTIME_PATH/native" ]] && break
        sleep 1
    done
    if [[ ! -S "$PULSE_RUNTIME_PATH/native" ]]; then
        log_warn "нет $PULSE_RUNTIME_PATH/native за 30 с — звук выключен"
        export SELKIES_AUDIO_ENABLED=false
    fi
fi

# HTTPS: браузер даёт буфер обмена, микрофон, камеру и геймпады только
# защищённому контексту, а http://<адрес робота> им не является. Selkies умеет
# выпустить самоподписанную пару сам, но сначала берёт путь по умолчанию —
# /etc/ssl/certs/ssl-cert-snakeoil.pem. На Ubuntu сертификат там есть, а ключ
# пользователю не читается, и Selkies падает с «PEM lib» вместо генерации
# (замер на AGX Orin 2026-09-14). Поэтому путь по умолчанию переносится
# в состояние пользователя: файла там нет — Selkies создаёт пару на
# устройстве и переиспользует её между перезапусками. Ключ в образ не попадает.
if [[ "${SELKIES_ENABLE_HTTPS:-false}" == true && -z "${SELKIES_HTTPS_CERT:-}" ]]; then
    tls_dir="${XDG_STATE_HOME:-$HOME_OF_USER/.local/state}/selkies"
    # The key is created right away private: umask 077 before mkdir, not chmod after.
    ( umask 077 && mkdir -p "$tls_dir" ) && chmod 0700 "$tls_dir"
    export SELKIES_HTTPS_CERT="$tls_dir/selkies.pem" SELKIES_HTTPS_KEY="$tls_dir/selkies.key"
fi
scheme=http
[[ "${SELKIES_ENABLE_HTTPS:-false}" == true ]] && scheme=https

# Что захватывать. Умолчание Selkies — «output.monitor»: для контейнера без
# звуковой карты он сам заводит пустой sink «output». На роботе приложения
# играют в настоящий sink по умолчанию, и Selkies слушал бы тишину (замер на
# AGX Orin 2026-09-14: pcmflux на output.monitor, звук в analog-stereo).
# Поэтому по умолчанию — monitor sink'а по умолчанию: слышно и в динамиках, и
# в браузере. Микрофон клиента делает sink по умолчанию из этого же имени —
# он существует, так что звук робота никуда не уводится.
if [[ "${SELKIES_AUDIO_ENABLED:-true}" == true && -z "${SELKIES_AUDIO_DEVICE_NAME:-}" ]]; then
    default_sink="$(pactl get-default-sink 2>/dev/null || pactl info 2>/dev/null | sed -n 's/^Default Sink: //p')"
    if [[ -n "$default_sink" && "$default_sink" != output ]]; then
        export SELKIES_AUDIO_DEVICE_NAME="${default_sink}.monitor"
        log_info "звук: захват ${SELKIES_AUDIO_DEVICE_NAME}"
    else
        log_warn "sink по умолчанию не определён — Selkies захватит свой output.monitor"
    fi
fi

# Каталог передачи файлов — в домашнем каталоге того, кто на экране.
if [[ -z "${SELKIES_FILE_MANAGER_PATH:-}" ]]; then
    export SELKIES_FILE_MANAGER_PATH="$HOME_OF_USER/Downloads"
fi
mkdir -p "$SELKIES_FILE_MANAGER_PATH" 2>/dev/null || true

log_info "${scheme}://${addr}:${SELKIES_PORT:-8080}/ файлы=${SELKIES_FILE_TRANSFERS:-} в $SELKIES_FILE_MANAGER_PATH, буфер=${SELKIES_ENABLE_CLIPBOARD:-}"

# СТОРОЖ СЕССИИ. Selkies не умирает вместе с X: замер на AGX Orin 2026-09-14 —
# после `loginctl terminate-session` процесс остался жив (тот же pid), в журнале
# только «X11 clipboard monitor thread exited; respawning», а при новом входе
# к новому X он не подключился бы. Поэтому Selkies — дочерний процесс, а
# обёртка раз в 10 с проверяет дисплей и при двух неудачах подряд гасит его
# и выходит с ошибкой: юнит перезапустит, обёртка дождётся новой сессии.
# The secrets are exported in the subshell that becomes Selkies, and only there.
(
    for k in "${SECRET_KEYS[@]}"; do
        if [[ -n "${!k:-}" ]]; then export "${k?}"; fi
    done
    exec "$PREFIX/usr/conda/bin/selkies"
) &
child=$!
trap 'kill -TERM "$child" 2>/dev/null; wait "$child"; exit 0' TERM INT
misses=0
while kill -0 "$child" 2>/dev/null; do
    sleep 10 & wait $!
    if [[ -r "$AUTH" ]] && xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1; then
        misses=0
    else
        misses=$((misses + 1))
        if (( misses >= 2 )); then
            log_warn "X-сессия '$USERNAME' на $DISPLAY_NUM пропала — останавливаю Selkies, дождусь новой"
            kill -TERM "$child" 2>/dev/null
            for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$child" 2>/dev/null || break; sleep 1; done
            kill -KILL "$child" 2>/dev/null
            exit 1
        fi
    fi
done
wait "$child"
rc=$?
log_warn "Selkies завершился с кодом $rc"
exit $(( rc == 0 ? 1 : rc ))
