#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in bash -c and the names under test are the test data
# Tests of the shared library lib/x-session.sh (spec 2026-11-12-existing-desktop
# §4.2) on a substituted root with fake loginctl, pgrep, xdpyinfo and getent:
# the seat0 session of a user (Seat=seat0, Class=user, Remote=no; active before
# online; the columns of list-sessions never read), the active session of seat0,
# the display (logind Display → the user's Xorg: :N in argv, its lock file or socket → :0 with a
# passing authority; Wayland — no display looked for) and the authority
# candidates. Every call runs in a fresh bash with `set -euo pipefail`, the way
# a consumer's hook sources it: no failure of logind may kill the caller.
#
#   lib/tests/test-x-session.sh     code 0 — every check passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(dirname "$HERE")/x-session.sh"

TMP="$(mktemp -d)"
trap 'rm -r -f -- "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&2; }
eq(){ if [[ "$2" == "$3" ]]; then ok; else bad "$1: ждали [$2], получили [$3]"; fi; }
has(){ if grep -qF -- "$2" <<< "$3"; then ok; else bad "$1: нет [$2] в [$3]"; fi; }
hasnt(){ if grep -qF -- "$2" <<< "$3"; then bad "$1: есть [$2] в [$3]"; else ok; fi; }

# new_root: a root with fake commands; fixtures are files of $ROOT/fake.
#   fake/user.<name>       output of `loginctl show-user` (absent — not logged in)
#   fake/session.<sid>     output of `loginctl show-session`
#   fake/seat.seat0        output of `loginctl show-seat`
#   fake/no-logind         loginctl fails as without a bus
#   fake/pgrep.u<uid>      pids of `pgrep -u <uid> -x Xorg`; fake/pgrep.all — of `pgrep -x Xorg`
#   fake/x.<display>       the authority path xdpyinfo accepts for that display
new_root(){
    ROOT="$(mktemp -d "$TMP/root.XXXXXX")"
    FAKE="$ROOT/fake"
    mkdir -p "$ROOT/bin" "$FAKE" "$ROOT/home/alice" "$ROOT/home/bob" "$ROOT/proc"
    cat > "$ROOT/bin/loginctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/loginctl.log"
[[ -e "$FAKE/no-logind" ]] && { echo "Failed to connect to bus: No such file or directory" >&2; exit 1; }
cmd="$1"; target="${!#}"
case "$cmd" in
    show-user) f="$FAKE/user.$target" ;;
    show-session) f="$FAKE/session.$target" ;;
    show-seat) f="$FAKE/seat.$target" ;;
    *) echo "fake loginctl: $cmd не поддержан" >&2; exit 1 ;;
esac
[[ -f "$f" ]] || { echo "Failed to get: $target" >&2; exit 1; }
cat "$f"
EOF
    cat > "$ROOT/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/pgrep.log"
f="$FAKE/pgrep.all"
[[ "$1" == -u ]] && f="$FAKE/pgrep.u$2"
[[ -s "$f" ]] || exit 1
cat "$f"
EOF
    cat > "$ROOT/bin/xdpyinfo" <<'EOF'
#!/usr/bin/env bash
echo "${XAUTHORITY:-} $*" >> "$FAKE/xdpyinfo.log"
[[ "$1" == -display ]] || exit 1
[[ -f "$FAKE/x.$2" && "$(cat "$FAKE/x.$2")" == "${XAUTHORITY:-}" ]]
EOF
    cat > "$ROOT/bin/getent" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == passwd ]] || exit 2
case "$2" in
    alice) echo "alice:x:1000:1000:Alice:/home/alice:/bin/bash" ;;
    bob) echo "bob:x:1001:1001:Bob:/home/bob:/bin/bash" ;;
    *) exit 2 ;;
esac
EOF
    chmod +x "$ROOT/bin/"*
}

# session <sid> <seat> <class> <type> <display> <state> <remote> [name]
session(){
    {
        echo "Id=$1"
        echo "Name=${8:-alice}"
        echo "Seat=$2"
        echo "VTNr=2"
        echo "Class=$3"
        echo "Type=$4"
        echo "Display=$5"
        echo "State=$6"
        echo "Remote=$7"
        echo "Service=gdm-password"
    } > "$FAKE/session.$1"
}
user_sessions(){ local u="$1"; shift; printf 'UID=1000\nName=%s\nSessions=%s\nState=active\n' "$u" "$*" > "$FAKE/user.$u"; }
# xorg <pid> <arg>…: /proc/<pid>/cmdline of an Xorg.
xorg(){ local pid="$1"; shift; mkdir -p "$ROOT/proc/$pid"; printf '%s\0' /usr/lib/xorg/Xorg "$@" > "$ROOT/proc/$pid/cmdline"; }

# xs <function> <args>…: the function in a fresh `bash -euo pipefail` that sourced
# the library; stdout to $OUT, stderr to $ERR, code to $RC.
xs(){
    local errf="$TMP/err"
    OUT="$(env -i PATH="$ROOT/bin:/usr/bin:/bin" FAKE="$FAKE" CREAM_ROOT="$ROOT" \
        bash -euo pipefail -c '. "$1"; shift; "$@"' xs "$LIB" "$@" 2>"$errf")"
    RC=$?
    ERR="$(cat "$errf")"
}

echo "== библиотека: подключается без опций shell и без вывода =="
new_root
out="$(env -i PATH="$ROOT/bin:/usr/bin:/bin" bash -c 'before="$-$(set -o | tr -d "[:space:]")"; . "$1"; after="$-$(set -o | tr -d "[:space:]")"; [[ "$before" == "$after" ]] && echo same' xs "$LIB" 2>&1)"
eq "source не меняет опции shell и молчит" "same" "$out"

echo "== x11 на :0 — Display из logind =="
new_root
user_sessions alice c2
session c2 seat0 user x11 :0 active no
xs xs_seat0_session alice
eq "seat0-сеанс — код 0" 0 "$RC"
eq "seat0-сеанс — sid type display state" "c2 x11 :0 active" "$OUT"
xs xs_find_display alice
eq "дисплей :0 — код 0" 0 "$RC"
eq "дисплей :0" ":0" "$OUT"
has "путь назван в stderr — logind" "logind" "$ERR"
hasnt "list-sessions не разбирается" "list-sessions" "$(cat "$FAKE/loginctl.log")"
has "show-user по имени отдельным аргументом" "show-user -p Sessions -- alice" "$(cat "$FAKE/loginctl.log")"

echo "== x11 на :1 =="
new_root
user_sessions alice 3
session 3 seat0 user x11 :1 active no
xs xs_find_display alice
eq "дисплей :1" ":1" "$OUT"
eq "дисплей :1 — код 0" 0 "$RC"

# gdm_auth <display>: alice's GDM authority, and it opens <display>.
gdm_auth(){ mkdir -p "$ROOT/run/user/1000/gdm"; : > "$ROOT/run/user/1000/gdm/Xauthority"; echo "$ROOT/run/user/1000/gdm/Xauthority" > "$FAKE/x.$1"; }
# xlock <N> <content>: /tmp/.X<N>-lock as Xorg writes it (printf "%10d\n").
xlock(){ mkdir -p "$ROOT/tmp"; printf '%s' "$2" > "$ROOT/tmp/.X$1-lock"; }
# xsock <pid> <inode> <path>: a listening unix socket of <pid> at <path>.
xsock(){
    mkdir -p "$ROOT/proc/$1/fd" "$ROOT/proc/net"
    ln -s "socket:[$2]" "$ROOT/proc/$1/fd/$(( $(find "$ROOT/proc/$1/fd" -mindepth 1 | wc -l) + 3 ))"
    [[ -s "$ROOT/proc/net/unix" ]] || echo "Num       RefCount Protocol Flags    Type St Inode Path" > "$ROOT/proc/net/unix"
    printf '0000000000000000: 00000002 00000000 00010000 0001 01 %s %s\n' "$2" "$3" >> "$ROOT/proc/net/unix"
}

echo "== Display пуст — Xorg пользователя с :N первым аргументом (startx) =="
new_root
user_sessions alice c2
session c2 seat0 user x11 "" active no
echo 4242 > "$FAKE/pgrep.u1000"
xorg 4242 :1 vt2 -keeptty -auth /tmp/serverauth.x
gdm_auth :1
xs xs_seat0_session alice
eq "пустой Display — прочерк" "c2 x11 - active" "$OUT"
xs xs_find_display alice
eq "дисплей из Xorg пользователя" ":1" "$OUT"
has "путь назван — Xorg" "Xorg" "$ERR"
has "путь назван — argv" "argv" "$ERR"
has "Xorg ищется по uid пользователя" "-u 1000 -x Xorg" "$(cat "$FAKE/pgrep.log")"
has "найденный дисплей подтверждён authority" "-display :1" "$(cat "$FAKE/xdpyinfo.log")"

echo "== :N не первым аргументом =="
new_root
echo 4242 > "$FAKE/pgrep.u1000"
xorg 4242 -nolisten tcp :2 vt7
gdm_auth :2
xs xs_find_display alice
eq ":N где угодно в argv" ":2" "$OUT"

echo "== :N в argv, но authority его не открывает — не берётся =="
new_root
echo 4242 > "$FAKE/pgrep.u1000"
xorg 4242 :1 vt2
xs xs_find_display alice
eq "без authority — код 1" 1 "$RC"
eq "без authority — пусто" "" "$OUT"

echo "== rootless GDM: экран входа на :0, alice на :1, logind Display пуст — lock-файл =="
new_root
user_sessions alice c2
session c2 seat0 user x11 "" active no
printf '1111\n4242\n' > "$FAKE/pgrep.all"
echo 4242 > "$FAKE/pgrep.u1000"
xorg 1111 vt1 -displayfd 3 -auth /run/user/120/gdm/Xauthority -nolisten tcp
xorg 4242 vt2 -displayfd 3 -auth /run/user/1000/gdm/Xauthority -nolisten tcp -background none -noreset -keeptty -novtswitch -verbose 3
xlock 0 "      1111"$'\n'
xlock 1 "      4242"$'\n'
gdm_auth :1
# alice's authority would open :0 too (the fallback 2 must not be reached).
echo "$ROOT/run/user/1000/gdm/Xauthority" > "$FAKE/x.:0"
xs xs_find_display alice
eq "rootless GDM — код 0" 0 "$RC"
eq "rootless GDM — :1 по lock-файлу" ":1" "$OUT"
has "путь назван — lock" "/tmp/.X1-lock" "$ERR"
has "путь назван — pid" "4242" "$ERR"

echo "== lock-файл с чужим pid или мусором — не берётся =="
new_root
echo 4242 > "$FAKE/pgrep.u1000"
xorg 4242 vt2 -displayfd 3 -auth /run/user/1000/gdm/Xauthority
xlock 0 "      1111"$'\n'
xlock 5 "4242abc"$'\n'
xlock 6 "  -4242"$'\n'
xlock x "4242"$'\n'
mkdir -p "$ROOT/tmp/.X7-lock"
gdm_auth :0; gdm_auth :5; gdm_auth :6
rm -f "$FAKE/x.:0"
xs xs_find_display alice
eq "чужой pid и мусор — код 1" 1 "$RC"
eq "чужой pid и мусор — пусто" "" "$OUT"

echo "== lock-файла нет — слушающий сокет /tmp/.X11-unix/X<N> этого pid =="
new_root
echo 4242 > "$FAKE/pgrep.u1000"
xorg 4242 vt2 -displayfd 3 -auth /run/user/1000/gdm/Xauthority
xsock 1111 50001 /tmp/.X11-unix/X0
xsock 4242 50003 @/tmp/.X11-unix/X1
xsock 4242 50002 /tmp/.X11-unix/X1
gdm_auth :1
xs xs_find_display alice
eq "сокет — код 0" 0 "$RC"
eq "сокет — :1" ":1" "$OUT"
has "путь назван — сокет" "/tmp/.X11-unix/X1" "$ERR"
# The socket of another pid (the login screen) is not this Xorg's display.
new_root
echo 4242 > "$FAKE/pgrep.u1000"
xorg 4242 vt2 -displayfd 3
xsock 1111 50001 /tmp/.X11-unix/X0
mkdir -p "$ROOT/proc/4242/fd"; ln -s "socket:[777]" "$ROOT/proc/4242/fd/9"
printf '0000000000000000: 00000003 00000000 00000000 0001 03 777 /tmp/.X11-unix/X3\n' >> "$ROOT/proc/net/unix"
gdm_auth :3
xs xs_find_display alice
eq "сокет чужого pid или не слушающий — код 1" 1 "$RC"

echo "== Xorg без :N, lock-файла и сокета — запасной путь :0 =="
new_root
user_sessions alice c2
session c2 seat0 user x11 "" active no
echo 4242 > "$FAKE/pgrep.u1000"
xorg 4242 vt2 -displayfd 3 -auth /run/user/1000/gdm/Xauthority
gdm_auth :0
xs xs_find_display alice
eq "ничего у Xorg — :0 с authority" ":0" "$OUT"

echo "== нет ни сеанса, ни Xorg — :0, если authority проходит =="
new_root
: > "$ROOT/home/alice/.Xauthority"
echo "$ROOT/home/alice/.Xauthority" > "$FAKE/x.:0"
xs xs_find_display alice
eq "запасной путь 2 — код 0" 0 "$RC"
eq "запасной путь 2 — :0" ":0" "$OUT"
has "путь назван — authority" "authority" "$ERR"
rm -f "$FAKE/x.:0"
xs xs_find_display alice
eq "authority не проходит — код 1" 1 "$RC"
eq "authority не проходит — пусто" "" "$OUT"

echo "== Wayland: тип отдаётся, дисплей не ищется =="
new_root
user_sessions alice c2
session c2 seat0 user wayland "" active no
: > "$ROOT/home/alice/.Xauthority"
echo "$ROOT/home/alice/.Xauthority" > "$FAKE/x.:0"
xs xs_seat0_session alice
eq "wayland — тип отдаётся" "c2 wayland - active" "$OUT"
xs xs_find_display alice
eq "wayland — код 2" 2 "$RC"
eq "wayland — дисплея нет" "" "$OUT"
eq "wayland — Xorg не ищется" "" "$(cat "$FAKE/pgrep.log" 2>/dev/null)"
eq "wayland — authority не проверяется" "" "$(cat "$FAKE/xdpyinfo.log" 2>/dev/null)"

echo "== на seat0 другой пользователь =="
new_root
user_sessions bob c5
session c5 seat0 user x11 :0 active no bob
printf 'Id=seat0\nActiveSession=c5\nCanGraphical=yes\n' > "$FAKE/seat.seat0"
xs xs_seat0_session alice
eq "alice не вошла — код 1" 1 "$RC"
eq "alice не вошла — пусто" "" "$OUT"
xs xs_seat0_active
eq "активный seat0 — код 0" 0 "$RC"
eq "активный seat0 — bob x11 user" "bob x11 user" "$OUT"

echo "== экран входа на seat0: greeter не сеанс пользователя =="
new_root
user_sessions gdm c1
session c1 seat0 greeter wayland "" active no gdm
user_sessions alice c1
printf 'Id=seat0\nActiveSession=c1\n' > "$FAKE/seat.seat0"
xs xs_seat0_session alice
eq "greeter не берётся — код 1" 1 "$RC"
xs xs_seat0_active
eq "активный seat0 — экран входа" "gdm wayland greeter" "$OUT"

echo "== Remote=yes (ssh) не берётся =="
new_root
user_sessions alice 7 c2
session 7 "" user tty "" active yes
session c2 seat0 user x11 :0 online no
xs xs_seat0_session alice
eq "ssh пропущен, берётся seat0" "c2 x11 :0 online" "$OUT"
new_root
user_sessions alice 7 8
session 7 "" user tty "" active yes
session 8 seat0 user x11 :0 active yes
xs xs_seat0_session alice
eq "только удалённые — код 1" 1 "$RC"
eq "только удалённые — пусто" "" "$OUT"

echo "== active раньше online, независимо от порядка =="
new_root
user_sessions alice c1 c3
session c1 seat0 user x11 :0 online no
session c3 seat0 user x11 :1 active no
xs xs_seat0_session alice
eq "active выбран" "c3 x11 :1 active" "$OUT"
xs xs_find_display alice
eq "дисплей active-сеанса" ":1" "$OUT"
new_root
user_sessions alice c3 c1
session c3 seat0 user x11 :1 closing no
session c1 seat0 user x11 :0 online no
xs xs_seat0_session alice
eq "closing пропущен, online выбран" "c1 x11 :0 online" "$OUT"

echo "== logind недоступен — пусто, без падения =="
new_root
touch "$FAKE/no-logind"
xs xs_seat0_session alice
eq "нет logind: seat0-сеанс — код 1" 1 "$RC"
eq "нет logind: seat0-сеанс — пусто" "" "$OUT"
xs xs_seat0_active
eq "нет logind: активный — код 1" 1 "$RC"
eq "нет logind: активный — пусто" "" "$OUT"
: > "$ROOT/home/alice/.Xauthority"
echo "$ROOT/home/alice/.Xauthority" > "$FAKE/x.:0"
xs xs_find_display alice
eq "нет logind: запасной путь 2 — :0" ":0" "$OUT"
new_root
rm -f "$ROOT/bin/loginctl"
OUT="$(env -i PATH="$ROOT/bin" FAKE="$FAKE" CREAM_ROOT="$ROOT" /bin/bash -euo pipefail -c '. "$1"; xs_seat0_session alice || echo "rc=$?"' xs "$LIB" 2>/dev/null)"
eq "нет loginctl вовсе — код 1 без падения" "rc=1" "$OUT"

echo "== authority: кандидаты по порядку, -auth из Xorg =="
new_root
mkdir -p "$ROOT/run/user/1000/gdm" "$ROOT/run/lightdm/alice"
: > "$ROOT/home/alice/.Xauthority"
: > "$ROOT/run/user/1000/gdm/Xauthority"
echo "$ROOT/run/user/1000/gdm/Xauthority" > "$FAKE/x.:1"
xs xs_find_authority alice :1
eq "gdm Xauthority — код 0" 0 "$RC"
eq "gdm Xauthority" "$ROOT/run/user/1000/gdm/Xauthority" "$OUT"
has "сначала ~/.Xauthority" "$ROOT/home/alice/.Xauthority -display :1" "$(head -1 "$FAKE/xdpyinfo.log")"
new_root
mkdir -p "$ROOT/run/lightdm/alice"
: > "$ROOT/run/lightdm/alice/xauthority"
echo "$ROOT/run/lightdm/alice/xauthority" > "$FAKE/x.:0"
xs xs_find_authority alice :0
eq "LightDM xauthority" "$ROOT/run/lightdm/alice/xauthority" "$OUT"
new_root
echo 900 > "$FAKE/pgrep.all"
xorg 900 :0 -seat seat0 -auth /var/run/sddm/abc -nolisten tcp
mkdir -p "$ROOT/var/run/sddm"; : > "$ROOT/var/run/sddm/abc"
echo "$ROOT/var/run/sddm/abc" > "$FAKE/x.:0"
xs xs_find_authority alice :0
eq "-auth из командной строки Xorg" "$ROOT/var/run/sddm/abc" "$OUT"
new_root
xs xs_find_authority alice :0
eq "ни один кандидат — код 1" 1 "$RC"
eq "ни один кандидат — пусто" "" "$OUT"
xs xs_find_authority alice '0; touch /tmp/x'
eq "дисплей не :N — код 1" 1 "$RC"
eq "дисплей не :N — xdpyinfo не звался" "" "$(cat "$FAKE/xdpyinfo.log" 2>/dev/null)"

echo "== имя пользователя: не опция, не путь =="
new_root
for u in "" "-p" "--help" "a/../b" "a b" 'a$(id)'; do
    xs xs_seat0_session "$u"
    eq "seat0-сеанс «$u» — код 1" 1 "$RC"
    xs xs_find_display "$u"
    eq "дисплей «$u» — код 1" 1 "$RC"
    xs xs_find_authority "$u" :0
    eq "authority «$u» — код 1" 1 "$RC"
done
eq "плохое имя — loginctl не звался" "" "$(cat "$FAKE/loginctl.log" 2>/dev/null)"
eq "плохое имя — pgrep не звался" "" "$(cat "$FAKE/pgrep.log" 2>/dev/null)"
xs xs_find_display nosuchuser
eq "нет в passwd — код 1" 1 "$RC"

echo
echo "test-x-session: прошло $pass, упало $fail"
(( fail == 0 ))
