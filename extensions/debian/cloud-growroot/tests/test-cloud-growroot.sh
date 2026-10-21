#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in python snippets is the test data
# Тесты cloud-growroot (cream/v1): хуки install и remove на подменённом корне
# с фикстурой /etc/cloud/cloud.cfg (список cloud_init_modules Raspberry Pi OS:
# без growpart и resizefs). Вставка после write_files с отступом якоря
# (один и два пробела, написание write-files), валидный YAML, бэкап только при
# правке, повтор без изменений, только недостающий модуль, отказы (нет cloud.cfg,
# нет утилит, нет якоря — /etc/cloud не тронут), remove снимает вставленное.
# growpart и resize2fs — подставные; root и сеть не нужны.
#
#   extensions/debian/cloud-growroot/tests/test-cloud-growroot.sh   код 0 — все проверки прошли
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../../tools/hooktest.sh
. "$HERE/../../../../tools/hooktest.sh"
EXT="$(dirname "$HERE")"

ht_init

# fixture <indent> [anchor]: cloud.cfg of Raspberry Pi OS, list items indented
# by <indent> spaces; anchor — the write_files spelling ("none" — no anchor).
fixture() {
    local i anchor="${2:-write_files}"
    i="$(printf '%*s' "$1" '')"
    {
        printf 'users:\n%s- default\n' "$i"
        printf 'cloud_init_modules:\n'
        printf '%s- %s\n' "$i" migrator "$i" seed_random "$i" bootcmd
        [[ "$anchor" == none ]] || printf '%s- %s\n' "$i" "$anchor"
        printf '%s- %s\n' "$i" set_hostname "$i" update_hostname "$i" users_groups "$i" ssh "$i" set_passwords
        printf 'cloud_config_modules:\n'
        printf '%s- %s\n' "$i" write_files_deferred "$i" locale "$i" runcmd
    } > "$CFG"
}

fresh() {
    ht_root "$EXT"
    CFG="$ROOT/etc/cloud/cloud.cfg"
    BAK="$CFG.before-growroot"
    STATE="$ROOT/var/lib/cream/ext/cloud-growroot/inserted"
    mkdir -p "$ROOT/etc/cloud"
    ht_fake growpart
    ht_fake resize2fs
    fixture "${1:-1}" "${2:-write_files}"
    cp "$CFG" "$ROOT/orig.cfg"
}

# modules: cloud_init_modules of $CFG parsed as YAML, space separated.
modules() { python3 -c 'import sys, yaml; print(" ".join(yaml.safe_load(open(sys.argv[1]))["cloud_init_modules"]))' "$CFG"; }
sum() { sha256sum "$1" | cut -d' ' -f1; }

echo "== манифест =="
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 2" 2.0.1 "$(mf 'm["version"]')"
eq "build: exec" exec "$(mf 'm["targets"]["build"]')"
eq "live: no" no "$(mf 'm["targets"]["live"]')"
check "live_note есть" test -n "$(mf 'm["targets"].get("live_note", "")')"
eq "хуки install и remove" "['install', 'remove']" "$(mf 'sorted(m["hooks"])')"
check_not "install.sh layout 2 убран" test -e "$EXT/install.sh"

echo "== вставка после write_files =="
fresh 1
ht_hook install; eq "install — 0" 0 "$?"
eq "модули по порядку" "migrator seed_random bootcmd write_files growpart resizefs set_hostname update_hostname users_groups ssh set_passwords" "$(modules)"
check "отступ якоря (один пробел)" grep -qx ' - growpart' "$CFG"
check "cloud_config_modules не тронут" grep -qx ' - write_files_deferred' "$CFG"
eq "бэкап = прежний файл" "$(sum "$ROOT/orig.cfg")" "$(sum "$BAK")"
check_not "cloud.cfg.new не остался" test -e "$CFG.new"
check "состояние: вставлены" test -s "$STATE"
before="$(sum "$CFG")"
ht_hook install; eq "повтор install — 0" 0 "$?"
eq "повтор: cloud.cfg не изменился" "$before" "$(sum "$CFG")"
eq "повтор: бэкап не перезаписан" "$(sum "$ROOT/orig.cfg")" "$(sum "$BAK")"
check "сообщение «уже включены»" grep -q 'уже включены' <(ht_out)
ht_hook remove; eq "remove — 0" 0 "$?"
eq "remove вернул прежний cloud.cfg" "$(sum "$ROOT/orig.cfg")" "$(sum "$CFG")"
check_not "remove: бэкап снят" test -e "$BAK"
check_not "remove: состояние снято" test -e "$STATE"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
eq "повтор remove: cloud.cfg тот же" "$(sum "$ROOT/orig.cfg")" "$(sum "$CFG")"

fresh 2 write-files
ht_hook install; eq "два пробела, write-files — 0" 0 "$?"
check "отступ якоря (два пробела)" grep -qx '  - growpart' "$CFG"
eq "модули по порядку" "migrator seed_random bootcmd write-files growpart resizefs set_hostname update_hostname users_groups ssh set_passwords" "$(modules)"

echo "== только недостающий =="
fresh 1
sed -i 's/^ - write_files$/ - write_files\n - growpart/' "$CFG"
ht_hook install; eq "growpart уже есть — 0" 0 "$?"
eq "growpart не задвоен" 1 "$(grep -cx ' - growpart' "$CFG")"
eq "resizefs вписан после growpart" "migrator seed_random bootcmd write_files growpart resizefs set_hostname update_hostname users_groups ssh set_passwords" "$(modules)"

echo "== модули уже включены (Ubuntu) =="
fresh 1
sed -i 's/^ - write_files$/ - write_files\n - growpart\n - resizefs/' "$CFG"
cp "$CFG" "$ROOT/orig.cfg"
ht_hook install; eq "install — 0" 0 "$?"
eq "cloud.cfg не изменился" "$(sum "$ROOT/orig.cfg")" "$(sum "$CFG")"
check_not "бэкапа нет" test -e "$BAK"
check_not "состояния нет" test -e "$STATE"
ht_hook remove; eq "remove — 0" 0 "$?"
eq "remove не трогает чужие модули" "$(sum "$ROOT/orig.cfg")" "$(sum "$CFG")"

echo "== отказы =="
fresh 1 none
ht_hook install; eq "нет якоря — 1" 1 "$?"
eq "cloud.cfg не тронут" "$(sum "$ROOT/orig.cfg")" "$(sum "$CFG")"
eq "в /etc/cloud ничего лишнего" cloud.cfg "$(ls "$ROOT/etc/cloud")"
check_not "состояния нет" test -e "$STATE"
check "сообщение про якорь" grep -q 'якорь write_files' <(ht_out)

fresh 1
rm -f "$CFG"
ht_hook install; eq "нет cloud.cfg — 1" 1 "$?"
check "сообщение про cloud-init" grep -q 'cloud-init не установлен' <(ht_out)

# PATH without growpart: only the tools the hook needs, linked from the host.
fresh 1
mkdir -p "$ROOT/minbin"
for c in bash env awk grep cp mv rm install mkdir dirname cat sed; do
    ln -s "$(command -v "$c")" "$ROOT/minbin/$c"
done
ln -s "$ROOT/bin/resize2fs" "$ROOT/minbin/resize2fs"
ht_hook install PATH="$ROOT/minbin"; eq "нет growpart — 1" 1 "$?"
check "сообщение про cloud-guest-utils" grep -q 'cloud-guest-utils' <(ht_out)
eq "cloud.cfg не тронут" "$(sum "$ROOT/orig.cfg")" "$(sum "$CFG")"

ht_done
