#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the chromium-kiosk extension (cream/v1): manifest, the pinned
# repository files, hooks install, configure and remove on a scratch root
# (CREAM_ROOT) the way cream runs them. apt-get and dpkg-query are fakes; the
# generated /etc/chromium-kiosk/config.yml is parsed back with PyYAML.
#
#   extensions/debian/chromium-kiosk/tests/test-chromium-kiosk.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

fresh() {
    ht_root "$EXT"
    CFG="$ROOT/etc/chromium-kiosk/config.yml"
    STATE="$ROOT/var/lib/cream/ext/chromium-kiosk"
    ht_fake dpkg-query 'p="${*: -1}"; [[ -f "$FAKE/pkg-$p" ]] && printf installed; exit 0'
    ht_fake apt-get 'if [[ "$1" == -s ]]; then v=Remv; [[ "$2" == purge ]] && v=Purg
    for a in "${@:3}"; do echo "$v $a [1.0]"; done; cat "$FAKE/sim-extra" 2>/dev/null; exit 0; fi
if [[ " $* " == *" install "* ]]; then
  for a in "$@"; do case "$a" in -*|install|Dpkg::*) ;; *) : > "$FAKE/pkg-$a" ;; esac; done
fi; exit 0'
    ht_fake sleep
}
# y EXPR: a Python expression over the parsed config.yml (c).
y() { python3 -c 'import sys, yaml; c = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$CFG" "$1"; }

echo "== манифест =="
# eval: test-only literal expressions over our own files, as in nvidia-jetpack.
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 4" 4.0.2 "$(mf 'm["version"]')"
eq "cream >=1.0.0 (стадия system)" ">=1.0.0" "$(mf 'm["cream"]')"
eq "live: confirm" confirm "$(mf 'm["targets"]["live"]')"
check "live_note про сторонний репозиторий" grep -q 'salamek' <<< "$(mf 'm["targets"]["live_note"]')"
eq "стадия system" system "$(mf 'm["hooks"]["configure"]["stage"]')"
eq "до config watcher пакета" "['chromium-kiosk_configwatcher.service']" "$(mf 'm["hooks"]["configure"]["before"]')"
eq "хуки" "['configure', 'install', 'remove']" "$(mf 'sorted(m["hooks"])')"
eq "конфликт с kiosk" "['kiosk']" "$(mf 'm["conflicts"]["extensions"]')"
eq "репозиторий и ключ — files" \
    "/etc/apt/keyrings/chromium-kiosk-salamek.asc /etc/apt/sources.list.d/chromium-kiosk-salamek.sources" \
    "$(mf '" ".join(sorted(f["dst"] for f in m["files"]))')"
# The key is pinned by its fingerprint: the tree carries it, nothing is fetched.
check "ключ Salamek по отпечатку" bash -c 'gpg --show-keys --with-colons "$1" 2>/dev/null | grep -q "^fpr:::::::::8177FADDC92D9497E8DA12377FEA00A604652192:$"' _ "$EXT/files/salamek.asc"
check "источник подписан этим ключом" grep -qx 'Signed-By: /etc/apt/keyrings/chromium-kiosk-salamek.asc' "$EXT/files/salamek.sources"
check "источник по https" grep -qx 'URIs: https://repository.salamek.cz/deb/pub' "$EXT/files/salamek.sources"
for f in install.sh configure.sh knobs knobs.apply configure-chromium-kiosk.service; do
    check_not "layout 2: нет $f" test -e "$EXT/$f"
done

echo "== install =="
fresh
ht_hook install; eq "install — 0" 0 "$?"
check "apt-get update" ht_called '^apt-get .*update$'
check "ставит chromium-kiosk" ht_called '^apt-get .*install .*chromium-kiosk'
check_not "ключ не качается (wget/curl)" ht_called '^(wget|curl) '
check_not "локаль системы не трогается" ht_called 'locale'
eq "состояние" "ca-certificates chromium-kiosk" "$(tr '\n' ' ' < "$STATE/packages" | sed 's/ $//')"
: > "$FAKE/calls"
ht_hook install; eq "повтор — 0" 0 "$?"
check_not "повтор: apt не звали" ht_called '^apt-get '

echo "== configure: config.yml из ключей =="
fresh
ht_hook configure CREAM_REASON=boot; eq "умолчания — 0" 0 "$?"
eq "HOME_PAGE" "https://github.com/iamletenkov/bisquite" "$(y 'c["HOME_PAGE"]')"
eq "WINDOW_MODE" fullscreen "$(y 'c["WINDOW_MODE"]')"
eq "TOUCHSCREEN — bool" True "$(y 'c["TOUCHSCREEN"]')"
eq "IDLE_TIME — int" 0 "$(y 'c["IDLE_TIME"]')"
eq "кнопки — список" "['home', 'reload', 'back', 'forward']" "$(y 'c["NAV_BAR"]["ENABLED_BUTTONS"]')"
eq "белый список пуст — список" "[]" "$(y 'c["WHITE_LIST"]["URLS"]')"
eq "ALLOWED_FEATURES — пустой список, не null" "[]" "$(y 'c["ALLOWED_FEATURES"]')"
eq "поворот по умолчанию" normal "$(y 'c["DISPLAY_ROTATION"]')"
eq "режим 0644" 644 "$(stat -c %a "$CFG")"
ino1="$(stat -c %i "$CFG")"
ht_hook configure CREAM_REASON=boot; eq "повтор — 0" 0 "$?"
eq "повтор: файл не переписан" "$ino1" "$(stat -c %i "$CFG")"

fresh
ht_hook configure CREAM_REASON=apply \
    "CHROMIUM_KIOSK_WHITE_LIST_URLS=*.example.org google.*/news" \
    "CHROMIUM_KIOSK_ALLOWED_FEATURES=geolocation notifications" \
    "CHROMIUM_KIOSK_NAV_BAR_BUTTONS=home back" \
    "CHROMIUM_KIOSK_HOME_PAGE=https://example.org/a?b=c&d=1#x" \
    CHROMIUM_KIOSK_SCREEN_ROTATION=left
eq "списки через пробел — 0" 0 "$?"
eq "белый список" "['*.example.org', 'google.*/news']" "$(y 'c["WHITE_LIST"]["URLS"]')"
eq "разрешения" "['geolocation', 'notifications']" "$(y 'c["ALLOWED_FEATURES"]')"
eq "кнопки" "['home', 'back']" "$(y 'c["NAV_BAR"]["ENABLED_BUTTONS"]')"
eq "поворот экрана без общего" "left None" "$(y 'c["SCREEN_ROTATION"] + " " + str(c.get("DISPLAY_ROTATION"))')"

echo "== configure: значения — данные, форма проверяется =="
fresh
ht_hook configure CREAM_REASON=apply 'CHROMIUM_KIOSK_HOME_PAGE=https://x.org/$(touch /tmp/pwned)'
eq "\$ в адресе — 1" 1 "$?"
check_not "файл не записан" test -e "$CFG"
ht_hook configure CREAM_REASON=apply $'CHROMIUM_KIOSK_EXTRA_ARGUMENTS=--a\nHOME_PAGE: evil'
eq "перевод строки — 1" 1 "$?"
ht_hook configure CREAM_REASON=apply 'CHROMIUM_KIOSK_IDLE_TIME=1+1'
eq "IDLE_TIME не число — 1" 1 "$?"
ht_hook configure CREAM_REASON=apply 'CHROMIUM_KIOSK_TOUCHSCREEN=yes'
eq "bool не true/false — 1" 1 "$?"
check_not "файл так и не записан" test -e "$CFG"
fresh
mkdir -p "$ROOT/victim"; ln -s "$ROOT/victim" "$ROOT/etc/chromium-kiosk"
ht_hook configure CREAM_REASON=boot; eq "/etc/chromium-kiosk — ссылка: 1" 1 "$?"
check_not "через ссылку не пишем" test -e "$ROOT/victim/config.yml"

echo "== remove =="
fresh
ht_hook install; : > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check "снимает свои пакеты" ht_called '^apt-get .*remove .*chromium-kiosk'
check_not "состояние снято" test -e "$STATE/packages"
check_not "без systemd: наблюдатель не трогают" ht_called '^systemctl '
fresh; mkdir -p "$ROOT/run/systemd/system"; ht_fake systemctl
ht_hook install; : > "$FAKE/calls"
ht_hook remove; eq "remove на живой — 0" 0 "$?"
eq "симуляция, stop наблюдателя до apt, reset-failed после" \
    "apt-get -s|systemctl stop chromium-kiosk_configwatcher.service|apt-get|systemctl reset-failed chromium-kiosk_configwatcher.service" \
    "$(cut -d' ' -f1-3 "$FAKE/calls" | sed -e 's/^apt-get -s .*/apt-get -s/' -e 's/^apt-get -q .*/apt-get/' | paste -sd'|')"
: > "$FAKE/calls"
ht_hook remove; eq "повтор — 0" 0 "$?"
check_not "повтор: apt не звали" ht_called '^apt-get '

echo "== remove: симуляция снимает чужой пакет — отказ =="
fresh; mkdir -p "$ROOT/run/systemd/system"; ht_fake systemctl
ht_hook install
echo 'Remv chromium-kiosk-extras [1.0]' > "$FAKE/sim-extra"
: > "$FAKE/calls"
ht_hook remove; eq "симуляция снимает чужой пакет — 1" 1 "$?"
check "чужой пакет назван" grep -q 'chromium-kiosk-extras' "$ROOT/out"
check_not "ничего не снято" ht_called '^apt-get -q -y remove'
check_not "наблюдатель не остановлен" ht_called '^systemctl stop'
check "запись пакетов осталась" test -s "$STATE/packages"

ht_done
