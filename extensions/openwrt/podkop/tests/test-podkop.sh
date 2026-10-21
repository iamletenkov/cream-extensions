#!/usr/bin/env bash
# H-тест podkop: хуки на подменённом корне (tools/hooktest.sh). uci и apk
# подставные: uci пишет пакет batch (stdin) в журнал и отвечает на get
# connection_type последним set из него; init-скрипт podkop — подставной файл.
# Настоящий uci и init-скрипт — L (контейнер OpenWrt).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../../tools/hooktest.sh
. "$HERE/../../../../tools/hooktest.sh"
ht_init

LINK='vless://0b7e6c2a-1111-4222-8333-944445555666@proxy.example.org:443?security=reality&sni=example.org#x'

setup() {
    ht_root "$(dirname "$HERE")"
    ht_fake apk 'case "$*" in "info -e "*) grep -qx "${!#}" "$FAKE/apk.have" 2>/dev/null ;; *) exit 0 ;; esac'
    printf '%s\n' podkop sing-box > "$FAKE/apk.have"
    ht_fake uci 'case "$*" in *" batch") cat >> "$FAKE/uci.batch" ;; *" get podkop.main.connection_type") sed -n "s/^set podkop.main.connection_type=.\(.*\).$/\1/p" "$FAKE/uci.batch" 2>/dev/null | tail -n1 ;; esac'
    mkdir -p "$ROOT/etc/init.d" "$ROOT/etc/config"
    printf '#!/bin/sh\necho "podkop-init $*" >> "%s/calls"\n' "$FAKE" > "$ROOT/etc/init.d/podkop"
    chmod +x "$ROOT/etc/init.d/podkop"
    : > "$ROOT/etc/config/podkop"
}
batch() { cat "$FAKE/uci.batch" 2>/dev/null; }
has_line() { batch | grep -qxF -- "$1"; }
has_re() { batch | grep -q -- "$1"; }
wait_bg() { local i; for i in 1 2 3 4 5 6 7 8 9 10; do ht_called "$1" && return 0; sleep 0.1; done; return 1; }

# --- install
setup
ht_hook install; eq "install с пакетами образа — 0" 0 "$?"
setup
printf 'podkop\n' > "$FAKE/apk.have"
ht_hook install; eq "install без sing-box — 20" 20 "$?"

# --- configure proxy: ссылка из секрета, 0600, podkop включён
setup
ht_secret PODKOP_PROXY_STRING "\"$LINK\""
ht_hook configure CREAM_REASON=boot PODKOP_USER_DOMAINS="example.com test.org" PODKOP_USER_SUBNETS="1.2.3.0/24"
eq "configure proxy — 0" 0 "$?"
check "connection_type proxy" has_line "set podkop.main.connection_type='proxy'"
check "ссылка" has_line "set podkop.main.proxy_string='$LINK'"
check "url" has_line "set podkop.main.proxy_config_type='url'"
check "список сообществ по умолчанию" has_line "add_list podkop.main.community_lists='russia_inside'"
check "домены dynamic" has_line "set podkop.main.user_domain_list_type='dynamic'"
check "домен" has_line "add_list podkop.main.user_domains='test.org'"
check "подсеть" has_line "add_list podkop.main.user_subnets='1.2.3.0/24'"
check "источник br-lan" has_line "add_list podkop.settings.source_network_interfaces='br-lan'"
check "старые списки сняты" has_line "delete podkop.main.community_lists"
check "commit" has_line "commit podkop"
eq "конфиг 0600" 600 "$(stat -c %a "$ROOT/etc/config/podkop")"
check "podkop enable" ht_called '^podkop-init enable$'
check_not "на загрузке не перезапускаем" ht_called '^podkop-init restart'
check_not "ссылка не в argv uci" grep -qF "proxy.example.org" "$FAKE/uci.argv"
check_not "ссылка не в выводе" grep -qF "proxy.example.org" "$ROOT/out"

# --- configure proxy без ссылки — выключен, код 0
setup
ht_hook configure CREAM_REASON=boot
eq "proxy без ссылки — 0" 0 "$?"
check "предупреждение" grep -q 'без PODKOP_PROXY_STRING' "$ROOT/out"
check "podkop disable" ht_called '^podkop-init disable$'
check_not "не включён" ht_called '^podkop-init enable'

# --- configure vpn: интерфейс, без ссылки
setup
ht_hook configure CREAM_REASON=apply PODKOP_CONNECTION_TYPE=vpn PODKOP_INTERFACE=awg0 PODKOP_COMMUNITY_LISTS=""
eq "configure vpn — 0" 0 "$?"
check "vpn" has_line "set podkop.main.connection_type='vpn'"
check "интерфейс" has_line "set podkop.main.interface='awg0'"
check_not "ссылки нет" has_re proxy_string=
check_not "списков нет" has_re "add_list podkop.main.community_lists"
check "на живой машине — restart фоном" wait_bg '^podkop-init restart$'

# --- vpn без интерфейса — выключен
setup
ht_hook configure CREAM_REASON=apply PODKOP_CONNECTION_TYPE=vpn
eq "vpn без интерфейса — 0" 0 "$?"
check "podkop disable" ht_called '^podkop-init disable$'
check "на живой машине — stop фоном" wait_bg '^podkop-init stop$'

# --- в сборке — только enable, без запуска
setup
ht_secret PODKOP_PROXY_STRING "\"$LINK\""
HT_PHASE=build ht_hook configure CREAM_REASON=install
check "enable" ht_called '^podkop-init enable$'
sleep 0.3
check_not "в сборке не запускаем" ht_called '^podkop-init (restart|start)'

# --- uci не записал — сбой
setup
ht_fake uci 'case "$*" in *" batch") cat > /dev/null ;; esac'
ht_hook configure CREAM_REASON=boot; rc=$?
check "без записи uci — сбой" test "$rc" -ne 0

# --- remove
setup
ht_hook remove; eq "remove — 0" 0 "$?"
check "ссылка снята" has_line "delete podkop.main.proxy_string"
check "интерфейс снят" has_line "delete podkop.main.interface"
check "disable" ht_called '^podkop-init disable$'

ht_done
