#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the cloud-user-desktop extension (cream/v1): manifest, hooks install
# and remove on a scratch root (CREAM_ROOT) the way cream runs them. getent, id
# and userdel are fakes over $FAKE/passwd; no root, no real accounts.
#
# Held here: the vendor account is removed only when named, only a regular
# account (uid >= 1000) and only by a name of the right form; an account that
# survives userdel fails the hook (an image must not carry a known password);
# the desktop settings are the desktop extension's (depends), not a copy here.
#
#   extensions/debian/cloud-user-desktop/tests/test-cloud-user-desktop.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

fresh() {
    ht_root "$EXT"
    printf '%s\n' 'root:x:0:0::/root:/bin/bash' 'daemon:x:1:1::/usr/sbin:/usr/sbin/nologin' \
        'jetson:x:1000:1000::/home/jetson:/bin/bash' 'alice:x:1001:1001::/home/alice:/bin/bash' > "$FAKE/passwd"
    ht_fake getent '[[ "$1" == passwd ]] || exit 2; [[ -z "${2-}" ]] && { cat "$FAKE/passwd"; exit 0; }
grep -E "^${2}:" "$FAKE/passwd" || exit 2'
    ht_fake id 'grep -qE "^${*: -1}:" "$FAKE/passwd"'
    # userdel [-r] NAME: $FAKE/userdel-busy — the account is in use (exit 8),
    # $FAKE/userdel-r-fails — only the form with -r fails.
    ht_fake userdel '[[ -f "$FAKE/userdel-busy" ]] && exit 8
[[ "$1" == -r && -f "$FAKE/userdel-r-fails" ]] && exit 12
sed -i "/^${*: -1}:/d" "$FAKE/passwd"'
}
has_user() { grep -qE "^$1:" "$FAKE/passwd"; }

echo "== манифест =="
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 5" 5.0.1 "$(mf 'm["version"]')"
eq "cream >= 1.0.0" '>=1.0.0' "$(mf 'm["cream"]')"
eq "build: exec" exec "$(mf 'm["targets"]["build"]')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "depends desktop и cloud-user" "cloud-user,desktop" "$(mf '",".join(sorted(d["name"] for d in m["depends"]))')"
eq "provides без изменений" "['cloud-user-desktop']" "$(mf 'm["provides"]')"
eq "хуки install и remove, своей службы нет" "['install', 'remove']" "$(mf 'sorted(m["hooks"])')"
eq "ключ учётки — scope install" install "$(mf 'm["config"]["keys"]["CLOUD_USER_DESKTOP_REMOVE"]["scope"]')"
eq "ключ учётки — пустой по умолчанию" "" "$(mf 'm["config"]["keys"]["CLOUD_USER_DESKTOP_REMOVE"]["default"]')"
check "ключ учётки — форма имени" grep -qF '^[a-z_][a-z0-9_-]{0,31}$' <<< "$(mf 'm["config"]["keys"]["CLOUD_USER_DESKTOP_REMOVE"]["type"]')"
check_not "files не нужны" grep -q files <<< "$(mf 'list(m)')"
for old in install.sh lib; do check_not "layout 2: $old убран" test -e "$EXT/$old"; done
check_not "без юнитов в дереве" bash -c 'find "$1" -name "*.service" | grep -q .' _ "$EXT"

echo "== install: учётка не задана — ничего не удаляется =="
fresh
ht_hook install; eq "install — 0" 0 "$?"
check_not "userdel не звали" ht_called '^userdel'
check "jetson на месте" has_user jetson
check "сказано, что не запрошено" grep -q 'не запрошено' <<< "$(ht_out)"

echo "== install: вендорская учётка удаляется вместе с домом =="
fresh
HT_PHASE=build ht_hook install CLOUD_USER_DESKTOP_REMOVE=jetson; eq "install — 0" 0 "$?"
check "userdel -r jetson" ht_called '^userdel -r (-- )?jetson$'
check_not "jetson удалён" has_user jetson
check "alice не тронута" has_user alice

echo "== install: повтор — учётки уже нет, 0 и без userdel =="
: > "$FAKE/calls"
HT_PHASE=build ht_hook install CLOUD_USER_DESKTOP_REMOVE=jetson; eq "повтор — 0" 0 "$?"
check_not "повтор: userdel не звали" ht_called '^userdel'

echo "== install: -r отказал — удаление без дома =="
fresh
: > "$FAKE/userdel-r-fails"
ht_hook install CLOUD_USER_DESKTOP_REMOVE=jetson; eq "install — 0" 0 "$?"
check "второй заход без -r" ht_called '^userdel (-- )?jetson$'
check_not "jetson удалён" has_user jetson

echo "== install: учётка занята и осталась — отказ, а не предупреждение =="
fresh
: > "$FAKE/userdel-busy"
ht_hook install CLOUD_USER_DESKTOP_REMOVE=jetson; rc=$?
check "install — не 0" test "$rc" -ne 0
check "jetson остался" has_user jetson
check "отказ назван" grep -q 'осталась' <<< "$(ht_out)"

echo "== install: системные учётки и root не удаляются =="
for u in root daemon; do
    fresh
    ht_hook install CLOUD_USER_DESKTOP_REMOVE="$u"; rc=$?
    check "$u: install — не 0" test "$rc" -ne 0
    check_not "$u: userdel не звали" ht_called '^userdel'
    check "$u: на месте" has_user "$u"
done

echo "== install: имя чужой формы — отказ до любых команд =="
for bad in '../etc' 'a b' '-r' 'Jetson' '$(id)' 'x;rm'; do
    fresh
    ht_hook install CLOUD_USER_DESKTOP_REMOVE="$bad"; rc=$?
    check "[$bad]: install — не 0" test "$rc" -ne 0
    check_not "[$bad]: userdel не звали" ht_called '^userdel'
    check_not "[$bad]: getent не звали" ht_called '^getent'
done

echo "== remove: ничего не возвращает и не падает =="
fresh
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "remove: userdel не звали" ht_called '^userdel'
ht_hook remove; eq "remove повтор — 0" 0 "$?"

ht_done
