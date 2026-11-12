#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in bash -c is the test data
# Tests of the shared library lib/gdm-wayland.sh (spec 2026-11-12-existing-desktop
# §4.5, §4.6; plan Task 2, ruling П12) on a substituted root: the four states of
# the WaylandEnable line of [daemon] (absent, commented, true, false) in both
# files gdm3 reads (Debian — daemon.conf, Ubuntu — custom.conf); a file without
# [daemon]; a link instead of the file (never written); a repeat (the record is
# not overwritten); the exact return (cmp) and lines others wrote meanwhile kept;
# a record whose file is gone. Every call runs in a fresh `bash -euo pipefail`,
# the way a consumer's hook sources it; systemctl is a fake that must stay
# unused.
#
#   lib/tests/test-gdm-wayland.sh     code 0 — every check passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(dirname "$HERE")/gdm-wayland.sh"

TMP="$(mktemp -d)"
trap 'rm -r -f -- "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&2; }
check(){ local what="$1"; shift; if "$@"; then ok; else bad "$what"; fi; }
check_not(){ local what="$1"; shift; if "$@"; then bad "$what"; else ok; fi; }
eq(){ if [[ "$2" == "$3" ]]; then ok; else bad "$1: ждали [$2], получили [$3]"; fi; }
has(){ if grep -qF -- "$2" <<< "$3"; then ok; else bad "$1: нет [$2] в [$3]"; fi; }

# The conffile as the packages ship it, byte for byte: /etc/gdm3/custom.conf of
# gdm3 46.2-1ubuntu1~24.04.9 (Ubuntu 24.04) and /etc/gdm3/daemon.conf of gdm3
# 43.0-3 (Debian 12) are the same 554 bytes (extracted 2026-11-12).
package_conf(){
    cat > "$1" <<'EOF'
# GDM configuration storage
#
# See /usr/share/gdm/gdm.schemas for a list of available options.

[daemon]
# Uncomment the line below to force the login screen to use Xorg
#WaylandEnable=false

# Enabling automatic login
#  AutomaticLoginEnable = true
#  AutomaticLogin = user1

# Enabling timed login
#  TimedLoginEnable = true
#  TimedLogin = user1
#  TimedLoginDelay = 10

[security]

[xdmcp]

[chooser]

[debug]
# Uncomment the line below to turn on debugging
# More verbose logs
# Additionally lets the X server dump core if it crashes
#Enable=true

EOF
}
# conf_in <state> <file>: the package file brought to a state of the line.
conf_in(){
    package_conf "$2"
    case "$1" in
        absent) sed -i '/^#WaylandEnable=false$/d' "$2" ;;
        commented) ;;
        true) sed -i 's/^#WaylandEnable=false$/WaylandEnable=true/' "$2" ;;
        false) sed -i 's/^#WaylandEnable=false$/WaylandEnable=false/' "$2" ;;
    esac
}
# daemon_lines <file>: the WaylandEnable lines of [daemon].
daemon_lines(){ awk '/^[[:space:]]*\[/{s=$0} s=="[daemon]" && /WaylandEnable/' "$1"; }

new_root(){
    ROOT="$(mktemp -d "$TMP/root.XXXXXX")"
    GDM="$ROOT/etc/gdm3"
    STATE="$ROOT/var/lib/cream/ext/gdm-x/wayland.before"
    mkdir -p "$ROOT/bin" "$GDM"
    printf '#!/bin/sh\necho "$*" >> "%s/systemctl.log"\n' "$ROOT" > "$ROOT/bin/systemctl"
    chmod +x "$ROOT/bin/systemctl"
}

# gw <function> <args>…: the function in a fresh `bash -euo pipefail` that sourced
# the library; stdout to $OUT, stderr to $ERR, code to $RC.
gw(){
    local errf="$TMP/err"
    OUT="$(env -i PATH="$ROOT/bin:/usr/bin:/bin" \
        bash -euo pipefail -c '. "$1"; shift; "$@"' gw "$LIB" "$@" 2>"$errf")"
    RC=$?
    ERR="$(cat "$errf")"
}

echo "== библиотека: подключается без опций shell и без вывода =="
new_root
out="$(env -i PATH="/usr/bin:/bin" bash -c 'before="$-$(set -o | tr -d "[:space:]")"; . "$1"; after="$-$(set -o | tr -d "[:space:]")"; [[ "$before" == "$after" ]] && echo same' gw "$LIB" 2>&1)"
eq "source не меняет опции shell и молчит" "same" "$out"

echo "== нет файлов gdm3 =="
new_root
gw gw_read "$ROOT"
eq "gw_read без gdm3 — код 1" 1 "$RC"
eq "gw_read без gdm3 — пусто" "" "$OUT"
gw gw_set_false "$ROOT" "$STATE"
eq "gw_set_false без gdm3 — код 1" 1 "$RC"
check_not "gw_set_false без gdm3 — записи нет" test -e "$STATE"
check_not "gw_set_false без gdm3 — файл не создан" test -e "$GDM/custom.conf"

echo "== четыре состояния строки × оба файла: запись, повтор, побайтный возврат =="
for name in custom.conf daemon.conf; do
    for st in absent commented true false; do
        new_root
        conf_in "$st" "$GDM/$name"
        chmod 0640 "$GDM/$name"
        cp -p "$GDM/$name" "$TMP/orig"
        gw gw_read "$ROOT"
        eq "$name/$st: gw_read" "$st /etc/gdm3/$name" "$OUT"
        eq "$name/$st: gw_read — код 0" 0 "$RC"

        gw gw_set_false "$ROOT" "$STATE"
        eq "$name/$st: gw_set_false — код 0" 0 "$RC"
        if [[ "$st" == false ]]; then
            eq "$name/$st: уже false — не изменил" unchanged "$OUT"
            check "$name/$st: файл не тронут" cmp -s "$TMP/orig" "$GDM/$name"
        else
            eq "$name/$st: изменил" changed "$OUT"
        fi
        check "$name/$st: запись сделана" test -s "$STATE"
        gw gw_read "$ROOT"
        eq "$name/$st: после записи — false" "false /etc/gdm3/$name" "$OUT"
        eq "$name/$st: режим сохранён" 640 "$(stat -c %a "$GDM/$name")"
        case "$st" in
            absent) eq "$name/$st: одна строка false" "WaylandEnable=false" "$(daemon_lines "$GDM/$name")" ;;
            commented) eq "$name/$st: комментарий на месте, строка false добавлена" \
                "$(printf 'WaylandEnable=false\n#WaylandEnable=false')" "$(daemon_lines "$GDM/$name")" ;;
            true) eq "$name/$st: true заменена на false" "WaylandEnable=false" "$(daemon_lines "$GDM/$name")" ;;
        esac
        # Only the line changed: the rest of the package file stays.
        eq "$name/$st: прочие строки пакета на месте" \
            "$(grep -v WaylandEnable "$TMP/orig")" "$(grep -v WaylandEnable "$GDM/$name")"

        sum="$(sha256sum < "$STATE")"
        gw gw_set_false "$ROOT" "$STATE"
        eq "$name/$st: повтор — код 0" 0 "$RC"
        eq "$name/$st: повтор — не изменил" unchanged "$OUT"
        eq "$name/$st: повтор — запись не перезаписана" "$sum" "$(sha256sum < "$STATE")"

        gw gw_restore "$ROOT" "$STATE"
        eq "$name/$st: gw_restore — код 0" 0 "$RC"
        if [[ "$st" == false ]]; then
            eq "$name/$st: возврат — не изменил" unchanged "$OUT"
        else
            eq "$name/$st: возврат — изменил" changed "$OUT"
        fi
        check "$name/$st: возврат побайтно" cmp "$TMP/orig" "$GDM/$name"
        eq "$name/$st: возврат — режим" 640 "$(stat -c %a "$GDM/$name")"
        check_not "$name/$st: запись удалена" test -e "$STATE"
        gw gw_read "$ROOT"
        eq "$name/$st: после возврата — прежнее состояние" "$st /etc/gdm3/$name" "$OUT"

        gw gw_restore "$ROOT" "$STATE"
        eq "$name/$st: возврат без записи — код 0" 0 "$RC"
        eq "$name/$st: возврат без записи — не изменил" unchanged "$OUT"
        check "$name/$st: возврат без записи — файл тот же" cmp -s "$TMP/orig" "$GDM/$name"
    done
done

echo "== оба файла: правятся и возвращаются оба =="
new_root
conf_in true "$GDM/daemon.conf"; conf_in absent "$GDM/custom.conf"
cp "$GDM/daemon.conf" "$TMP/d"; cp "$GDM/custom.conf" "$TMP/c"
gw gw_read "$ROOT"
eq "оба: gw_read — строка на файл, daemon.conf первым" \
    "$(printf 'true /etc/gdm3/daemon.conf\nabsent /etc/gdm3/custom.conf')" "$OUT"
gw gw_set_false "$ROOT" "$STATE"
eq "оба: изменил" changed "$OUT"
gw gw_read "$ROOT"
eq "оба: false в обоих" "$(printf 'false /etc/gdm3/daemon.conf\nfalse /etc/gdm3/custom.conf')" "$OUT"
gw gw_restore "$ROOT" "$STATE"
check "оба: daemon.conf побайтно" cmp "$TMP/d" "$GDM/daemon.conf"
check "оба: custom.conf побайтно" cmp "$TMP/c" "$GDM/custom.conf"

echo "== нет секции [daemon]; пустой файл; без перевода строки в конце =="
for kind in nosection empty noeol; do
    new_root
    case "$kind" in
        nosection) printf '# local\n[security]\nDisallowTCP=true\n' > "$GDM/custom.conf" ;;
        empty) : > "$GDM/custom.conf" ;;
        noeol) printf '[security]\nDisallowTCP=true' > "$GDM/custom.conf" ;;
    esac
    cp "$GDM/custom.conf" "$TMP/orig"
    gw gw_read "$ROOT"
    eq "$kind: absent" "absent /etc/gdm3/custom.conf" "$OUT"
    gw gw_set_false "$ROOT" "$STATE"
    eq "$kind: изменил" changed "$OUT"
    gw gw_read "$ROOT"
    eq "$kind: false" "false /etc/gdm3/custom.conf" "$OUT"
    check "$kind: секция [daemon] дописана" grep -qx '\[daemon\]' "$GDM/custom.conf"
    gw gw_restore "$ROOT" "$STATE"
    eq "$kind: возврат — код 0" 0 "$RC"
    check "$kind: возврат побайтно" cmp "$TMP/orig" "$GDM/custom.conf"
done

echo "== ключ вне [daemon] и значение 0 =="
new_root
printf '[daemon]\nAutomaticLoginEnable=true\n[security]\nWaylandEnable=false\n' > "$GDM/custom.conf"
gw gw_read "$ROOT"
eq "WaylandEnable вне [daemon] не считается" "absent /etc/gdm3/custom.conf" "$OUT"
printf '[daemon]\n  WaylandEnable = 0  \n' > "$GDM/custom.conf"
gw gw_read "$ROOT"
eq "WaylandEnable = 0 — false" "false /etc/gdm3/custom.conf" "$OUT"

echo "== две строки true: правится последняя (действующая), возврат побайтно =="
new_root
printf '[daemon]\nWaylandEnable=true\nAutomaticLoginEnable=false\n\tWaylandEnable = true \n[debug]\n' > "$GDM/custom.conf"
cp "$GDM/custom.conf" "$TMP/orig"
gw gw_set_false "$ROOT" "$STATE"
eq "две строки — изменил" changed "$OUT"
eq "две строки — первая цела, последняя false" "$(printf 'WaylandEnable=true\nWaylandEnable=false')" "$(daemon_lines "$GDM/custom.conf")"
gw gw_read "$ROOT"
eq "две строки — действует false" "false /etc/gdm3/custom.conf" "$OUT"
gw gw_restore "$ROOT" "$STATE"
check "две строки — возврат побайтно (табуляция и пробелы)" cmp "$TMP/orig" "$GDM/custom.conf"

echo "== чужие строки между записью и возвратом остаются =="
new_root
conf_in commented "$GDM/custom.conf"
gw gw_set_false "$ROOT" "$STATE"
# What desktop does to the same file meanwhile: a key right after [daemon].
sed -i 's/^\[daemon\]$/[daemon]\nAutomaticLoginEnable=true/' "$GDM/custom.conf"
conf_in commented "$TMP/want"
sed -i 's/^\[daemon\]$/[daemon]\nAutomaticLoginEnable=true/' "$TMP/want"
gw gw_restore "$ROOT" "$STATE"
eq "чужие строки — код 0" 0 "$RC"
check "чужая строка осталась, WaylandEnable вернулся" cmp "$TMP/want" "$GDM/custom.conf"

echo "== строку после записи поменял человек — не трогаю =="
new_root
conf_in absent "$GDM/custom.conf"
gw gw_set_false "$ROOT" "$STATE"
sed -i 's/^WaylandEnable=false$/WaylandEnable=true/' "$GDM/custom.conf"
cp "$GDM/custom.conf" "$TMP/human"
gw gw_restore "$ROOT" "$STATE"
eq "чужое значение — код 0" 0 "$RC"
eq "чужое значение — не изменил" unchanged "$OUT"
check "чужое значение осталось" cmp -s "$TMP/human" "$GDM/custom.conf"
has "чужое значение — предупреждение" "WaylandEnable" "$ERR"
check_not "чужое значение — запись удалена" test -e "$STATE"

echo "== ссылка вместо файла — не пишем =="
new_root
conf_in true "$ROOT/elsewhere.conf"
cp "$ROOT/elsewhere.conf" "$TMP/orig"
ln -s "$ROOT/elsewhere.conf" "$GDM/custom.conf"
gw gw_read "$ROOT"
eq "ссылка — gw_read" "link /etc/gdm3/custom.conf" "$OUT"
gw gw_set_false "$ROOT" "$STATE"
eq "ссылка — код 1" 1 "$RC"
eq "ссылка — ничего в stdout" "" "$OUT"
has "ссылка — причина названа" "ссылка" "$ERR"
check "ссылка — цель не тронута" cmp -s "$TMP/orig" "$ROOT/elsewhere.conf"
check "ссылка — ссылка осталась" test -L "$GDM/custom.conf"
check_not "ссылка — записи нет" test -e "$STATE"
# A link next to a regular file: nothing is written in either.
new_root
conf_in true "$GDM/daemon.conf"; cp "$GDM/daemon.conf" "$TMP/orig"
conf_in true "$ROOT/elsewhere.conf"
ln -s "$ROOT/elsewhere.conf" "$GDM/custom.conf"
gw gw_set_false "$ROOT" "$STATE"
eq "ссылка рядом с файлом — код 1" 1 "$RC"
check "ссылка рядом с файлом — файл не тронут" cmp -s "$TMP/orig" "$GDM/daemon.conf"
check_not "ссылка рядом с файлом — записи нет" test -e "$STATE"
# The directory itself a link.
new_root
rmdir "$GDM"; mkdir -p "$ROOT/other"; ln -s "$ROOT/other" "$GDM"
conf_in true "$ROOT/other/custom.conf"; cp "$ROOT/other/custom.conf" "$TMP/orig"
gw gw_set_false "$ROOT" "$STATE"
eq "/etc/gdm3 — ссылка — код 1" 1 "$RC"
check "/etc/gdm3 — ссылка — файл не тронут" cmp -s "$TMP/orig" "$ROOT/other/custom.conf"
# A link appearing between the record and the return.
new_root
conf_in absent "$GDM/custom.conf"
gw gw_set_false "$ROOT" "$STATE"
mv "$GDM/custom.conf" "$ROOT/moved.conf"; ln -s "$ROOT/moved.conf" "$GDM/custom.conf"
cp "$ROOT/moved.conf" "$TMP/orig"
gw gw_restore "$ROOT" "$STATE"
eq "возврат в ссылку — код 1" 1 "$RC"
check "возврат в ссылку — цель не тронута" cmp -s "$TMP/orig" "$ROOT/moved.conf"
check "возврат в ссылку — запись осталась" test -s "$STATE"

echo "== запись есть, файла нет =="
new_root
conf_in true "$GDM/custom.conf"
gw gw_set_false "$ROOT" "$STATE"
rm -f "$GDM/custom.conf"
gw gw_restore "$ROOT" "$STATE"
eq "файла нет — код 0" 0 "$RC"
eq "файла нет — не изменил" unchanged "$OUT"
check_not "файла нет — не создан" test -e "$GDM/custom.conf"
check_not "файла нет — запись удалена" test -e "$STATE"

echo "== запись указывает на чужой путь — отказ =="
new_root
conf_in absent "$GDM/custom.conf"
gw gw_set_false "$ROOT" "$STATE"
mkdir -p "$ROOT/etc"; printf 'root:x:0:0::/root:/bin/sh\n' > "$ROOT/etc/passwd"
cp "$ROOT/etc/passwd" "$TMP/passwd"
sed -i 's#^file /etc/gdm3/custom.conf$#file /etc/passwd#' "$STATE"
gw gw_restore "$ROOT" "$STATE"
eq "чужой путь — код 1" 1 "$RC"
check "чужой путь — файл не тронут" cmp -s "$TMP/passwd" "$ROOT/etc/passwd"

echo "== запись есть, файл появился позже: повтор дописывает его в запись, возврат — обоих =="
new_root
conf_in true "$GDM/daemon.conf"; cp "$GDM/daemon.conf" "$TMP/d"
gw gw_set_false "$ROOT" "$STATE"
conf_in true "$GDM/custom.conf"; cp "$GDM/custom.conf" "$TMP/c"
cp "$STATE" "$TMP/state1"
gw gw_set_false "$ROOT" "$STATE"
eq "появился — код 0" 0 "$RC"
eq "появился — изменил" changed "$OUT"
gw gw_read "$ROOT"
eq "появился — false в обоих" "$(printf 'false /etc/gdm3/daemon.conf\nfalse /etc/gdm3/custom.conf')" "$OUT"
check "появился — прежние строки записи не тронуты" cmp -s "$TMP/state1" <(head -n "$(wc -l < "$TMP/state1")" "$STATE")
has "появился — custom.conf в записи" "file /etc/gdm3/custom.conf" "$(cat "$STATE")"
gw gw_set_false "$ROOT" "$STATE"
eq "появился — третий повтор не меняет" unchanged "$OUT"
eq "появился — запись без дублей" 1 "$(grep -c '^file /etc/gdm3/custom.conf$' "$STATE")"
gw gw_restore "$ROOT" "$STATE"
eq "появился — возврат код 0" 0 "$RC"
check "появился — daemon.conf побайтно" cmp "$TMP/d" "$GDM/daemon.conf"
check "появился — custom.conf побайтно" cmp "$TMP/c" "$GDM/custom.conf"
# A record that is not ours is not appended to and nothing is written.
new_root
conf_in true "$GDM/custom.conf"; cp "$GDM/custom.conf" "$TMP/c"
mkdir -p "${STATE%/*}"; printf 'something else\n' > "$STATE"
gw gw_set_false "$ROOT" "$STATE"
eq "чужая запись — код 1" 1 "$RC"
check "чужая запись — файл не тронут" cmp -s "$TMP/c" "$GDM/custom.conf"
eq "чужая запись — не дописана" "something else" "$(cat "$STATE")"

echo "== порченая запись replaced: без raw или raw не WaylandEnable — отказ до правки =="
for bogus in drop "raw [daemon]"; do
    new_root
    conf_in true "$GDM/custom.conf"
    gw gw_set_false "$ROOT" "$STATE"
    cp "$GDM/custom.conf" "$TMP/now"
    if [[ "$bogus" == drop ]]; then sed -i '/^raw /d' "$STATE"; else sed -i "s/^raw .*/$bogus/" "$STATE"; fi
    gw gw_restore "$ROOT" "$STATE"
    eq "raw «$bogus» — код 1" 1 "$RC"
    check "raw «$bogus» — файл не тронут" cmp -s "$TMP/now" "$GDM/custom.conf"
    check "raw «$bogus» — запись осталась" test -s "$STATE"
done

echo "== повтор возврата после частичного: уже возвращённый файл — без предупреждения =="
new_root
conf_in true "$GDM/daemon.conf"; conf_in true "$GDM/custom.conf"
cp "$GDM/daemon.conf" "$TMP/d"; cp "$GDM/custom.conf" "$TMP/c"
gw gw_set_false "$ROOT" "$STATE"
# daemon.conf came back, custom.conf did not (its mv failed): the record is kept.
cp "$TMP/d" "$GDM/daemon.conf"
gw gw_restore "$ROOT" "$STATE"
eq "частичный — код 0" 0 "$RC"
check "частичный — daemon.conf побайтно" cmp "$TMP/d" "$GDM/daemon.conf"
check "частичный — custom.conf побайтно" cmp "$TMP/c" "$GDM/custom.conf"
eq "частичный — нет предупреждения о чужой правке" "" "$ERR"

echo "== systemctl не зовётся =="
check_not "systemctl не звался ни разу" test -e "$ROOT/systemctl.log"
for r in "$TMP"/root.*; do
    [[ -e "$r/systemctl.log" ]] && bad "systemctl звался: $r"
done

echo
echo "test-gdm-wayland: прошло $pass, упало $fail"
(( fail == 0 ))
