#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the locale extension (cream/v1): manifest, hooks install, apply and
# remove on a scratch root (CREAM_ROOT) the way cream runs them, with fake
# apt-get, dpkg-query, locale-gen, update-locale, locale, setupcon and dconf.
# root, network and a real locale database are not needed.
#
#   extensions/debian/locale/tests/test-locale.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

PKGS="locales keyboard-configuration console-setup xkb-data"

# locale_root [ID]: fresh root with /etc/os-release, SUPPORTED, xkb symbols and
# fakes; `locale -a` lists what the fake locale-gen compiled ($FAKE/compiled).
locale_root() {
    local id="${1:-debian}"
    ht_root "$EXT"
    mkdir -p "$ROOT/etc" "$ROOT/usr/share/i18n" "$ROOT/usr/share/X11/xkb/symbols"
    echo "ID=$id" > "$ROOT/etc/os-release"
    printf '%s\n' 'en_US.UTF-8 UTF-8' 'ru_RU.UTF-8 UTF-8' 'de_DE.UTF-8 UTF-8' > "$ROOT/usr/share/i18n/SUPPORTED"
    printf '%s\n' '# en_US.UTF-8 UTF-8' '# ru_RU.UTF-8 UTF-8' > "$ROOT/etc/locale.gen"
    : > "$ROOT/usr/share/X11/xkb/symbols/us"
    : > "$ROOT/usr/share/X11/xkb/symbols/ru"
    ht_fake apt-get
    ht_fake dpkg-query 'exit 0'
    # Debian: compiles what is uncommented in /etc/locale.gen; Ubuntu: the argument.
    ht_fake locale-gen '
if (( $# )); then echo "$1" >> "$FAKE/compiled"; exit 0; fi
grep -v "^#" "'"$ROOT"'/etc/locale.gen" | awk "NF {print \$1}" >> "$FAKE/compiled"'
    ht_fake locale '[[ "$1" == -a ]] && { echo C.utf8; sed "s/UTF-8/utf8/" "$FAKE/compiled" 2>/dev/null; }'
    ht_fake update-locale 'printf "%s\n" "${2}" > "'"$ROOT"'/etc/default/locale"'
    ht_fake setupcon
    mkdir -p "$ROOT/etc/default"
    KBD="$ROOT/etc/default/keyboard"
    XORG="$ROOT/etc/X11/xorg.conf.d/00-keyboard.conf"
    LOCALDB="$ROOT/etc/dconf/db/local.d/40-locale"
    GDMDB="$ROOT/etc/dconf/db/gdm.d/40-locale"
}
with_dconf() { ht_fake dconf '[[ "$1" == update ]] && : > "'"$ROOT"'/etc/dconf/db/local"; exit 0'; }
mf() { python3 -c 'import sys,yaml; m=yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
tree_sum() { (cd "$ROOT" && find etc -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum); }

echo "== манифест и раскладка =="
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 2" 2 "$(mf 'm["version"].split(".")[0]')"
eq "cream 1.0" ">=1.0.0" "$(mf 'm["cream"]')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "хуки" "apply install remove" "$(mf '" ".join(sorted(m["hooks"]))')"
eq "provides" system-locale "$(mf '" ".join(m["provides"])')"
eq "без depends (desktop — только то же правило профиля)" "[]" "$(mf 'm.get("depends", [])')"
eq "ключи" "KEYBOARD_LAYOUTS KEYBOARD_TOGGLE LOCALE" "$(mf '" ".join(sorted(m["config"]["keys"]))')"
eq "KEYBOARD_TOGGLE может быть пустым" True "$(mf 'm["config"]["keys"]["KEYBOARD_TOGGLE"]["empty"]')"
for f in hooks/install hooks/apply hooks/remove; do
    check "$f исполняемый" test -x "$EXT/$f"
done
for f in install.sh apply.sh knobs knobs.apply; do
    check_not "layout 2: $f не остался в корне" test -e "$EXT/$f"
done

echo "== install: debian, умолчания =="
locale_root debian
ht_hook install; eq "install — 0" 0 "$?"
check "пакеты одним apt-get install" ht_called "^apt-get .*install .*$PKGS\$"
check "en_US раскомментирована в locale.gen" grep -qx 'en_US.UTF-8 UTF-8' "$ROOT/etc/locale.gen"
check "debian: locale-gen без аргумента" ht_called '^locale-gen $'
check "LANG в /etc/default/locale" grep -qx 'LANG=en_US.UTF-8' "$ROOT/etc/default/locale"
check "XKBLAYOUT us,ru" grep -qx 'XKBLAYOUT="us,ru"' "$KBD"
check "XKBVARIANT пуст" grep -qx 'XKBVARIANT=","' "$KBD"
check "XKBOPTIONS пуст" grep -qx 'XKBOPTIONS=""' "$KBD"
check "XKBMODEL pc105" grep -qx 'XKBMODEL="pc105"' "$KBD"
check "Xorg InputClass с раскладками" grep -q 'Option "XkbLayout" "us,ru"' "$XORG"
check "профиль dconf user над system-db:local" grep -qx 'system-db:local' "$ROOT/etc/dconf/profile/user"
check "умолчания GNOME: источники" grep -qxF "sources=[('xkb', 'us'), ('xkb', 'ru')]" "$LOCALDB"
check "умолчания GNOME: пустой xkb-options с типом" grep -qxF 'xkb-options=@as []' "$LOCALDB"
check_not "без профиля gdm — gdm.d не пишется" test -e "$GDMDB"
check "кэш консоли обновлён" ht_called '^setupcon --save-only'
check_not "systemctl не зовётся" ht_called '^systemctl'
check "файлы ссылаются на cream set, не на старый CLI" grep -q 'cream set locale' "$KBD"
check_not "временных файлов не осталось" bash -c "ls -A '$ROOT/etc/default' | grep -q '^\\.'"

echo "== install: повтор ничего не меняет =="
snap="$(tree_sum)"
: > "$FAKE/calls"
ht_hook install; eq "повтор install — 0" 0 "$?"
eq "повтор: /etc тот же" "$snap" "$(tree_sum)"
check_not "повтор: setupcon не зовётся (кэш консоли не пересобирается)" ht_called '^setupcon'
check_not "повтор: update-locale не зовётся" ht_called '^update-locale'

echo "== install: ubuntu =="
locale_root ubuntu
ht_hook install; eq "ubuntu — 0" 0 "$?"
check "ubuntu: locale-gen с локалью" ht_called '^locale-gen en_US.UTF-8$'

echo "== apply: варианты, опция, GNOME и экран входа =="
locale_root debian
with_dconf
mkdir -p "$ROOT/etc/dconf/profile"
printf 'user-db:user\nsystem-db:gdm\n' > "$ROOT/etc/dconf/profile/gdm"
ht_hook apply LOCALE=ru_RU.UTF-8 'KEYBOARD_LAYOUTS=us,ru(phonetic)' KEYBOARD_TOGGLE=grp:caps_toggle \
    CREAM_CHANGED_KEYS='LOCALE KEYBOARD_LAYOUTS KEYBOARD_TOGGLE'
eq "apply — 0" 0 "$?"
check "ru_RU раскомментирована" grep -qx 'ru_RU.UTF-8 UTF-8' "$ROOT/etc/locale.gen"
check "LANG=ru_RU" grep -qx 'LANG=ru_RU.UTF-8' "$ROOT/etc/default/locale"
check "вариант phonetic" grep -qx 'XKBVARIANT=",phonetic"' "$KBD"
check "опция переключения" grep -qx 'XKBOPTIONS="grp:caps_toggle"' "$KBD"
check "GNOME: ru+phonetic" grep -qF "('xkb', 'ru+phonetic')" "$LOCALDB"
check "GNOME: опция" grep -qxF "xkb-options=['grp:caps_toggle']" "$LOCALDB"
check "экран входа: gdm.d" grep -qF "('xkb', 'ru+phonetic')" "$GDMDB"
check "dconf update позван" ht_called '^dconf update'
check_not "apply не зовёт systemctl" ht_called '^systemctl'
check_not "apply не ставит пакеты" ht_called '^apt-get'
: > "$FAKE/calls"
ht_hook apply LOCALE=ru_RU.UTF-8 'KEYBOARD_LAYOUTS=us,ru(phonetic)' KEYBOARD_TOGGLE=grp:caps_toggle
eq "повтор apply — 0" 0 "$?"
check_not "повтор: dconf update не зовётся" ht_called '^dconf update'

echo "== apply: отказы =="
locale_root debian
ht_hook apply LOCALE=xx_XX.UTF-8; eq "локали нет в SUPPORTED — 1" 1 "$?"
check "отказ назван" grep -q 'SUPPORTED' <<< "$(ht_out)"
check_not "отказ: раскладка не записана" test -e "$KBD"
locale_root debian
ht_hook apply KEYBOARD_LAYOUTS=us,zz; eq "неизвестная раскладка — предупреждение, 0" 0 "$?"
check "неизвестная раскладка названа" grep -q "'zz'" <<< "$(ht_out)"

echo "== remove =="
locale_root debian
with_dconf
ht_hook install; eq "install перед remove — 0" 0 "$?"
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "умолчания GNOME сняты" test -e "$LOCALDB"
check "база dconf пересобрана" ht_called '^dconf update'
check "/etc/default/keyboard оставлен (система без раскладки хуже)" test -f "$KBD"
check "/etc/default/locale оставлен" test -f "$ROOT/etc/default/locale"
check_not "пакеты локали не снимаются" ht_called '^apt-get'
: > "$FAKE/calls"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
check_not "повтор: dconf update не зовётся" ht_called '^dconf'

ht_done
