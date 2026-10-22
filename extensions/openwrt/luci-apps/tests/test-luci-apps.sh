#!/usr/bin/env bash
# H-тест luci-apps: хуки на подменённом корне (tools/hooktest.sh). apk
# подставной: «установленные» пакеты — $FAKE/apk.have, add/del правят его.
# Настоящий apk и подписанные фиды — L (контейнер OpenWrt, сеть).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../../tools/hooktest.sh
. "$HERE/../../../../tools/hooktest.sh"
ht_init

setup() {
    ht_root "$(dirname "$HERE")"
    printf '%s\n' luci-base luci-app-firewall > "$FAKE/apk.have"
    ht_fake apk '
h="$FAKE/apk.have"
case "$1" in
info) grep -qx "${!#}" "$h" ;;
update) exit 0 ;;
add) [ ! -e "$FAKE/add.fail" ] || exit 1; shift; for p in "$@"; do echo "$p" >> "$h"; done ;;
del) shift; for p in "$@"; do grep -qx "$p" "$h" || { echo "ERROR: No such package: $p" >&2; exit 1; }; done
    for p in "$@"; do grep -vx "$p" "$h" > "$h.n"; mv "$h.n" "$h"; done ;;
esac'
    mkdir -p "$ROOT/etc/apk"
    printf 'cache-max-age 4h\n' > "$ROOT/etc/apk/config"
}
added() { tr '\n' ' ' 2>/dev/null < "$ROOT/var/lib/cream/ext/luci-apps/added"; }
have() { grep -qx "$1" "$FAKE/apk.have"; }

# --- пустой список — ничего
setup
ht_hook install; eq "пустой список — 0" 0 "$?"
check_not "apk add не звали" ht_called '^apk add'
check_not "apk update не звали" ht_called '^apk update'

# --- ставит недостающее, уже стоящее не присваивает
setup
HT_PHASE=build ht_hook install LUCI_APPS_PACKAGES="luci-app-sqm luci-app-firewall"
eq "install — 0" 0 "$?"
check "apk update перед add" ht_called '^apk update$'
check "apk add только недостающего" ht_called '^apk add luci-app-sqm$'
eq "своё — только добавленное" "luci-app-sqm " "$(added)"
check_not "без --allow-untrusted" grep -q 'allow-untrusted' "$FAKE/apk.argv"

# --- повтор — ничего не меняет
: > "$FAKE/calls"
ht_hook install LUCI_APPS_PACKAGES="luci-app-sqm luci-app-firewall"
check_not "повтор — без apk add" ht_called '^apk (add|del|update)'
eq "повтор — то же своё" "luci-app-sqm " "$(added)"

# --- короче список — снимает только своё
: > "$FAKE/calls"
ht_hook install LUCI_APPS_PACKAGES="luci-app-wol"
check "снято своё" ht_called '^apk del luci-app-sqm$'
check "добавлен новый" ht_called '^apk add luci-app-wol$'
eq "своё — новый" "luci-app-wol " "$(added)"
check "пакет образа на месте" have luci-app-firewall

# --- remove — только своё
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check "снят luci-app-wol" ht_called '^apk del luci-app-wol$'
check "luci-app-firewall образа не тронут" have luci-app-firewall
check "состояние убрано" test ! -e "$ROOT/var/lib/cream/ext/luci-apps/added"

# --- allow-untrusted в конфиге apk — отказ до изменений
setup
printf 'allow-untrusted\n' >> "$ROOT/etc/apk/config"
ht_hook install LUCI_APPS_PACKAGES="luci-app-sqm"; rc=$?
check "allow-untrusted — сбой" test "$rc" -ne 0
check "причина названа" grep -q 'allow-untrusted' "$ROOT/out"
check_not "apk add не звали" ht_called '^apk add'

# --- APK_CONFIG сборки тоже проверяется
setup
printf 'preserve-env\nallow-untrusted\n' > "$ROOT/apk-build.conf"
HT_PHASE=build ht_hook install LUCI_APPS_PACKAGES="luci-app-sqm" APK_CONFIG="$ROOT/apk-build.conf"; rc=$?
check "allow-untrusted в APK_CONFIG — сбой" test "$rc" -ne 0

# --- apk add упал — сбой, своё не записано
setup
ht_fake apk 'case "$1" in info) exit 1 ;; update) exit 0 ;; add) exit 3 ;; esac'
ht_hook install LUCI_APPS_PACKAGES="luci-app-nope"; rc=$?
check "пакета нет в фиде — сбой" test "$rc" -ne 0
eq "своё пусто" "" "$(added)"

# --- на живой машине — кеш LuCI и rpcd reload
setup
mkdir -p "$ROOT/tmp/luci-modulecache" "$ROOT/etc/init.d"
: > "$ROOT/tmp/luci-indexcache.abc"
printf '#!/bin/sh\necho "rpcd-init $*" >> "%s/calls"\n' "$FAKE" > "$ROOT/etc/init.d/rpcd"
chmod +x "$ROOT/etc/init.d/rpcd"
ht_hook install LUCI_APPS_PACKAGES="luci-app-sqm"
check "кеш индекса снят" test ! -e "$ROOT/tmp/luci-indexcache.abc"
check "кеш модулей снят" test ! -e "$ROOT/tmp/luci-modulecache"
for _ in 1 2 3 4 5 6 7 8 9 10; do ht_called '^rpcd-init reload' && break; sleep 0.1; done
check "rpcd reload" ht_called '^rpcd-init reload$'

# --- своё, снятое вручную: сокращение списка не валит install
setup
HT_PHASE=build ht_hook install LUCI_APPS_PACKAGES="luci-app-sqm luci-app-ttyd"
grep -vx luci-app-sqm "$FAKE/apk.have" > "$FAKE/h.n"; mv "$FAKE/h.n" "$FAKE/apk.have"
: > "$FAKE/calls"
HT_PHASE=build ht_hook install LUCI_APPS_PACKAGES="luci-app-ttyd"
eq "снятое вручную и убранное из списка — 0" 0 "$?"
check_not "apk del снятого не зовётся" ht_called '^apk del'
eq "своё — ttyd" "luci-app-ttyd " "$(added)"

# --- своё, снятое вручную, но в списке: ставится снова, без дублей
setup
HT_PHASE=build ht_hook install LUCI_APPS_PACKAGES="luci-app-sqm"
grep -vx luci-app-sqm "$FAKE/apk.have" > "$FAKE/h.n"; mv "$FAKE/h.n" "$FAKE/apk.have"
HT_PHASE=build ht_hook install LUCI_APPS_PACKAGES="luci-app-sqm"
eq "снова поставлено — 0" 0 "$?"
eq "без дублей" "luci-app-sqm " "$(added)"

# --- apk del прошёл, apk add упал: added уже без снятого, повтор не валится на del
setup
HT_PHASE=build ht_hook install LUCI_APPS_PACKAGES="luci-app-sqm"
: > "$FAKE/add.fail"
HT_PHASE=build ht_hook install LUCI_APPS_PACKAGES="luci-app-ttyd"; rc=$?
check "add упал — сбой" test "$rc" -ne 0
eq "снятое ушло из своего" "" "$(added)"
rm -f "$FAKE/add.fail"; : > "$FAKE/calls"
HT_PHASE=build ht_hook install LUCI_APPS_PACKAGES="luci-app-ttyd"
eq "повтор после сбоя — 0" 0 "$?"
check_not "повтор: apk del не зовётся" ht_called '^apk del'
eq "своё — ttyd" "luci-app-ttyd " "$(added)"

ht_done
