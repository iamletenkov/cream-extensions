#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the selkies extension (cream/v1): manifest, unit, hooks install,
# configure, apply and remove, and the wrapper run-selkies.sh on a scratch root
# (CREAM_ROOT) the way cream and systemd run them. getent, id, systemctl,
# loginctl, xdpyinfo, pgrep, pactl, sleep, dpkg, curl and apt-get are fakes; the
# cloud-user library is a stub, the AppImage is a fake extracted tree. root,
# systemd, a display manager and the network are not needed.
#
# Security is the point: no start without authentication unless
# SELKIES_ALLOW_NO_AUTH=1 (fail-closed), secrets never in argv, the output or
# the environment of helper processes, the Teleport declaration written without
# following symlinks.
#
#   extensions/debian/selkies/tests/test-selkies.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

PW='Pw-Basic-7f3a9c1e'
VO='Pw-View-2b8d4e6f'
TOKEN='Tok-Master-9e1c5a7b'
VER=2.0.0

# sk_root: fresh root; user alice (uid 1000, home /home/alice) from the
# cloud-user library stub ($FAKE/user); the display manager is active.
sk_root() {
    ht_root "$EXT"
    mkdir -p "$ROOT/home/alice" "$ROOT/home/root"
    printf '%s\n' 'root:x:0:0::/root:/bin/bash' 'alice:x:1000:1000::/home/alice:/bin/bash' \
        'bob:x:1001:1001::/home/bob:/bin/bash' > "$FAKE/passwd"
    echo alice > "$FAKE/user"
    : > "$FAKE/active-display-manager"
    : > "$FAKE/units"
    ht_fake getent '
f="$FAKE/$1"; [[ -f "$f" ]] || exit 2
[[ -z "${2-}" ]] && { cat "$f"; exit 0; }
grep -E "^${2}:" "$f" || exit 2'
    ht_fake id '
[[ "$1" == -u ]] || exit 2
line="$(grep -E "^$2:" "$FAKE/passwd")" || exit 1
echo "$line" | cut -d: -f3'
    ht_fake systemctl '
case "$1" in
    is-active)
        for a in "$@"; do [[ -e "$FAKE/active-${a%.service}" ]] && exit 0; done
        exit 3 ;;
    list-units) cat "$FAKE/units" ;;
esac
exit 0'
    ht_fake sleep
    LIB="$ROOT/opt/cream/ext/cloud-user/get_cloud_user.sh"
    mkdir -p "$(dirname "$LIB")"
    printf '#!/usr/bin/env bash\ncat %q 2>/dev/null || { echo "Error: no user" >&2; exit 1; }\n' "$FAKE/user" > "$LIB"
    chmod +x "$LIB"
    APPS="$ROOT/etc/cream/teleport/apps.d"
    DECL="$APPS/selkies.conf"
}
# fake_appimage: an extracted AppImage already in /opt/selkies/<ver>; its
# selkies binary dumps its environment and argv into $FAKE.
fake_appimage() {
    local bin="$ROOT/opt/selkies/$VER/usr/conda/bin/selkies"
    mkdir -p "$(dirname "$bin")"
    printf '#!/usr/bin/env bash\n[[ "${1-}" == --help ]] && exit 0\nenv > %q\nprintf "%%s\\n" "$*" > %q\nexit 0\n' \
        "$FAKE/selkies.env" "$FAKE/selkies.args" > "$bin"
    chmod +x "$bin"
}
mf() { python3 -c 'import sys,yaml; m=yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
started() { ht_called "^systemctl (start|restart) --no-block selkies@$1\\.service"; }
leaked() { grep -rqF -e "$PW" -e "$VO" -e "$TOKEN" "$@" 2>/dev/null; }
blocking_systemctl() { grep -E '^systemctl (start|restart|stop|reload|enable --now|disable --now)' "$FAKE/calls" | grep -qv -- '--no-block'; }

echo "== манифест и раскладка =="
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "name" selkies "$(mf 'm["name"]')"
eq "версия 6.2.0 (загрузка библиотекой fetch)" 6.2.0 "$(mf 'm["version"]')"
eq "cream >=1.2.0 (every_boot, спека cream §10.9)" ">=1.2.0" "$(mf 'm["cream"]')"
eq "configure на каждой загрузке (аудит 2026-10-21)" True "$(mf 'm["hooks"]["configure"].get("every_boot")')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "стадия graphical" graphical "$(mf 'm["hooks"]["configure"]["stage"]')"
eq "хуки" "apply configure install remove" "$(mf '" ".join(sorted(m["hooks"]))')"
eq "depends cloud-user и fetch" "cloud-user >=1.0.0 <2 fetch >=1.0.0 <2" "$(mf '" ".join(d["name"]+" "+d["version"] for d in m["depends"])')"
eq "provides" "web-remote-desktop" "$(mf '" ".join(m["provides"])')"
eq "requires" "display-manager x11-server" "$(mf '" ".join(sorted(m["requires"]))')"
eq "секреты — secret: file" "SELKIES_BASIC_AUTH_PASSWORD SELKIES_BASIC_AUTH_VIEWONLY_PASSWORD SELKIES_MASTER_TOKEN" \
    "$(mf '" ".join(sorted(k for k, v in m["config"]["keys"].items() if v.get("secret") == "file"))')"
eq "Р8: SELKIES_ALLOW_NO_AUTH — bool, 0" "bool 0" \
    "$(mf 'm["config"]["keys"]["SELKIES_ALLOW_NO_AUTH"]["type"] + " " + m["config"]["keys"]["SELKIES_ALLOW_NO_AUTH"]["default"]')"
eq "шаблон SELKIES_*" True "$(mf 'm["config"]["keys"]["SELKIES_*"]["pattern"]')"
eq "SELKIES_ENABLE_BASIC_AUTH — не ручка: ставит обёртка по паролю" False \
    "$(mf '"SELKIES_ENABLE_BASIC_AUTH" in m["config"]["keys"]')"
eq "files: юнит" "files/selkies@.service /etc/systemd/system/selkies@.service 0644" \
    "$(mf '" ".join(f["src"]+" "+f["dst"]+" "+f["mode"] for f in m["files"])')"
# Every value reaches an EnvironmentFile and a Teleport declaration: the types
# admit no newline, quote, $, backquote, backslash or space (re checked with
# Python; the classes used are the common subset of RE2 and re).
bad_types="$(python3 - "$EXT/extension.yaml" <<'PY'
import re, sys, yaml
m = yaml.safe_load(open(sys.argv[1]))
bad = []
for k, s in m["config"]["keys"].items():
    t = s["type"]
    if t in ("bool", "port") or t.startswith("enum:"):
        continue
    if not t.startswith("re:"):
        bad.append(f"{k}:{t}")
        continue
    rx = re.compile("^(?:" + t[3:] + ")$")
    for v in ("a\nb", 'a"b', "a'b", "a$b", "a`b", "a\\b", "a b"):
        if rx.match(v):
            bad.append(f"{k}:{v!r}")
print(" ".join(bad))
PY
)"
eq "типы ключей: без \\n, кавычек, \$, \`, \\, пробела" "" "$bad_types"
eq "фиктивный пароль (буквы, цифры, дефис) подходит под тип" True \
    "$(mf 'bool(__import__("re").fullmatch(m["config"]["keys"]["SELKIES_BASIC_AUTH_PASSWORD"]["type"][3:], "fake-pass-0123456789abcdef"))')"
for f in hooks/install hooks/configure hooks/apply hooks/remove files/selkies.sh files/run-selkies.sh; do
    check "$f исполняемый" test -x "$EXT/$f"
done
for f in install.sh configure.sh configure-selkies.service knobs knobs.apply teleport-app.sh run-selkies.sh selkies@.service lib; do
    check_not "layout 2: $f не остался в корне" test -e "$EXT/$f"
done
UNIT="$EXT/files/selkies@.service"
check "юнит: EnvironmentFile config" grep -qx 'EnvironmentFile=/etc/cream/selkies/config' "$UNIT"
check "юнит: EnvironmentFile -secrets" grep -qx 'EnvironmentFile=-/etc/cream/selkies/secrets' "$UNIT"
check "юнит: от имени пользователя" grep -qx 'User=%i' "$UNIT"
check "юнит: обёртка из дерева расширения" grep -qx 'ExecStart=/bin/bash /opt/cream/ext/selkies/files/run-selkies.sh %i' "$UNIT"
check "юнит: отказ по аутентификации не перезапускается" grep -qx 'RestartPreventExitStatus=78' "$UNIT"
check_not "юнит: не включается сам (стартует configure)" grep -q '^WantedBy=' "$UNIT"

echo "== install: AppImage уже распакован =="
sk_root; fake_appimage
ht_fake dpkg 'echo amd64'
ht_fake apt-get
ht_hook install; eq "install — 0" 0 "$?"
eq "current → $VER" "$ROOT/opt/selkies/$VER" "$(readlink "$ROOT/opt/selkies/current")"
check_not "сеть не нужна" ht_called '^curl'
check "x11-utils и xauth" ht_called '^apt-get .*install .*x11-utils xauth'
check_not "install не трогает службы" ht_called '^systemctl'
check_not "install не пишет объявление (это configure)" test -e "$DECL"
link1="$(stat -c '%i %Y' "$ROOT/opt/selkies/current")"
ht_hook install; eq "повтор — 0" 0 "$?"
eq "повтор: ссылка та же" "$link1" "$(stat -c '%i %Y' "$ROOT/opt/selkies/current")"

echo "== install: sha256 не совпал — отказ, ничего не распаковано =="
sk_root
ht_fake dpkg 'echo arm64'
ht_fake apt-get
ht_fake curl 'while (( $# )); do [[ "$1" == -o ]] && { echo bogus > "$2"; }; shift; done; exit 0'
ht_hook install; check_not "install не 0" test "$?" -eq 0
check "скачивался AppImage aarch64" ht_called "^curl .*selkies-$VER-aarch64\\.AppImage"
check_not "ничего не распаковано" test -e "$ROOT/opt/selkies/$VER"
check_not "ссылки current нет" test -L "$ROOT/opt/selkies/current"

echo "== install: curl 56 дважды (focal, curl 7.68) — третья попытка того же адреса =="
sk_root
ht_fake dpkg 'echo arm64'
ht_fake apt-get
ht_fake curl '
n=$(( $(cat "$FAKE/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/n"
(( n <= 2 )) && { echo "curl: (56) Recv failure: Connection reset by peer" >&2; exit 56; }
while (( $# )); do [[ "$1" == -o ]] && { echo bogus > "$2"; }; shift; done; exit 0'
ht_hook install; check_not "install не 0 (сумма подставного файла не сходится)" test "$?" -eq 0
eq "три вызова curl, все по первому адресу" 3 "$(grep -c "^curl .*/download/$VER/selkies-$VER-aarch64\.AppImage$" "$FAKE/calls")"
check "между попытками пауза" ht_called '^sleep 10$'
check "отказ — по sha256, а не по сети" grep -q 'sha256' "$ROOT/out"
check_not "ничего не распаковано" test -e "$ROOT/opt/selkies/$VER"
check_not "рабочий каталог убран" compgen -G "$ROOT/opt/selkies/.install.*"

echo "== configure: нет пароля и нет SELKIES_ALLOW_NO_AUTH — не стартует =="
sk_root
ht_fake systemctl '
case "$1" in
    is-active) [[ -e "$FAKE/active-display-manager" ]] && exit 0; exit 3 ;;
    list-units) echo "selkies@alice.service loaded active running Selkies" ;;
esac
exit 0'
mkdir -p "$APPS"; echo 'NAME=selkies' > "$DECL"
ht_hook configure CREAM_REASON=boot; eq "configure — 0 (предупреждение, не сбой)" 0 "$?"
check "предупреждение про аутентификацию" grep -q 'SELKIES_ALLOW_NO_AUTH' "$ROOT/out"
check_not "selkies@alice не запускается" started alice
check "запущенный экземпляр гасится (--no-block)" ht_called '^systemctl stop --no-block selkies@alice\.service'
check_not "объявление для Teleport снято" test -e "$DECL"
check_not "блокирующих systemctl нет" blocking_systemctl

echo "== configure: только пароль просмотра — не аутентификация =="
sk_root; ht_secret SELKIES_BASIC_AUTH_VIEWONLY_PASSWORD "$VO"
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
check_not "без основного пароля не стартует" started alice
check_not "пароль не в выводе" leaked "$ROOT/out" "$FAKE"

echo "== configure: пустой пароль — нет пароля =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD '""'
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
check_not "пустой пароль не открывает" started alice

echo "== configure: пароль задан — старт, объявление =="
sk_root
ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"; ht_secret SELKIES_BASIC_AUTH_VIEWONLY_PASSWORD "$VO"
ht_secret SELKIES_MASTER_TOKEN "$TOKEN"
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
check "загрузка: start --no-block selkies@alice" ht_called '^systemctl start --no-block selkies@alice\.service'
check_not "в selkies@ ничего не включается навсегда" ht_called '^systemctl enable'
eq "объявление" "NAME=selkies URI=http://127.0.0.1:8080 ICON=desktop" "$(tr '\n' ' ' < "$DECL" | sed 's/ $//')"
eq "объявление 0644" 644 "$(stat -c %a "$DECL")"
check_not "секреты не в выводе, argv, журнале вызовов" leaked "$ROOT/out" "$FAKE"
check_not "секреты не в объявлении" leaked "$APPS"
check_not "блокирующих systemctl нет" blocking_systemctl
check_not "ожидания нет: пользователь есть" ht_called '^sleep'
check_not "предупреждения про открытый доступ нет" grep -q 'SELKIES_ALLOW_NO_AUTH=1' "$ROOT/out"
decl1="$(stat -c '%i %Y' "$DECL")"
ht_hook configure CREAM_REASON=boot; eq "повтор — 0" 0 "$?"
eq "повтор: объявление не переписано" "$decl1" "$(stat -c '%i %Y' "$DECL")"

echo "== configure: после install — restart; HTTPS и порт в объявлении =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
ht_hook configure CREAM_REASON=install SELKIES_PORT=8443 SELKIES_ENABLE_HTTPS=true; eq "configure — 0" 0 "$?"
check "restart --no-block selkies@alice" ht_called '^systemctl restart --no-block selkies@alice\.service'
check "URI https с портом" grep -qx 'URI=https://127.0.0.1:8443' "$DECL"

echo "== configure: SELKIES_ALLOW_NO_AUTH=1 — старт с предупреждением =="
sk_root
ht_hook configure CREAM_REASON=boot SELKIES_ALLOW_NO_AUTH=1; eq "configure — 0" 0 "$?"
check "стартует" started alice
check "предупреждение при каждом configure" grep -q 'SELKIES_ALLOW_NO_AUTH=1' "$ROOT/out"
ht_hook configure CREAM_REASON=boot SELKIES_ALLOW_NO_AUTH=1 SELKIES_ADDR=0.0.0.0
check "адрес не петли без пароля — громче: открыт сети" grep -q 'сети' "$ROOT/out"

echo "== configure: адрес не петли =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
ht_hook configure CREAM_REASON=boot SELKIES_ADDR=0.0.0.0; eq "0.0.0.0 — 0" 0 "$?"
check "0.0.0.0: объявление на петле" grep -qx 'URI=http://127.0.0.1:8080' "$DECL"
check "пароль по http в сеть — предупреждение" grep -q 'SELKIES_ENABLE_HTTPS' "$ROOT/out"
ht_hook configure CREAM_REASON=boot SELKIES_ADDR=192.0.2.10; eq "192.0.2.10 — 0" 0 "$?"
check_not "адрес без петли — объявления нет" test -e "$DECL"
ht_hook configure CREAM_REASON=boot SELKIES_ADDR=::1; eq "::1 — 0" 0 "$?"
check "::1 — объявление на [::1]" grep -qxF 'URI=http://[::1]:8080' "$DECL"

echo "== configure: значения проверяются до записи =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
ht_hook configure CREAM_REASON=boot 'SELKIES_PORT=8080"x'; check_not "порт с кавычкой — сбой" test "$?" -eq 0
check_not "объявления нет" test -e "$DECL"
check_not "не стартует" started alice
ht_hook configure CREAM_REASON=boot 'SELKIES_ADDR=127.0.0.1$x'; check_not "адрес с \$ — сбой" test "$?" -eq 0
ht_hook configure CREAM_REASON=boot 'SELKIES_ENABLE_HTTPS=yes'; check_not "HTTPS не true/false — сбой" test "$?" -eq 0

echo "== configure: объявление не идёт по ссылкам =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
mkdir -p "$APPS" "$ROOT/victim"; echo keep > "$ROOT/victim/file"
ln -s "$ROOT/victim/file" "$DECL"
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
eq "цель ссылки не тронута" keep "$(cat "$ROOT/victim/file")"
check "объявление — обычный файл" test -f "$DECL" -a ! -L "$DECL"
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
mkdir -p "$ROOT/etc/cream/teleport" "$ROOT/victim"; ln -s "$ROOT/victim" "$APPS"
ht_hook configure CREAM_REASON=boot; eq "apps.d — ссылка: configure 0" 0 "$?"
check_not "в цель ссылки каталога ничего не легло" test -e "$ROOT/victim/selkies.conf"
check "предупреждение про ссылку" grep -q 'ссылк' "$ROOT/out"
check "служба всё равно стартует" started alice
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
mkdir -p "$ROOT/etc/cream" "$ROOT/victim"; ln -s "$ROOT/victim" "$ROOT/etc/cream/teleport"
ht_hook configure CREAM_REASON=boot; eq "teleport — ссылка: configure 0" 0 "$?"
check_not "через ссылку /etc/cream/teleport ничего не создано" test -e "$ROOT/victim/apps.d"

echo "== configure: без менеджера входа — предупреждение и 0 (Р11) =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"; rm -f "$FAKE/active-display-manager"
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
check "предупреждение про менеджер входа" grep -q 'менеджер входа' "$ROOT/out"
check_not "не стартует" started alice
check_not "пользователя не ждёт" ht_called '^sleep'

echo "== configure: без пользователя — предупреждение и 0 =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"; rm -f "$FAKE/user"
ht_hook configure CREAM_REASON=boot; eq "загрузка — 0" 0 "$?"
check "на загрузке ждёт пользователя" ht_called '^sleep'
check "предупреждение про пользователя" grep -q 'пользовател' "$ROOT/out"
check_not "не стартует" ht_called '^systemctl (start|restart) --no-block selkies@'
: > "$FAKE/calls"
ht_hook configure CREAM_REASON=install; eq "install — 0" 0 "$?"
check_not "после install не ждёт" ht_called '^sleep'
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"; echo root > "$FAKE/user"
ht_hook configure CREAM_REASON=boot; eq "root — 0" 0 "$?"
check_not "от root не стартует" started root
echo 'bad;name' > "$FAKE/user"
ht_hook configure CREAM_REASON=boot; eq "кривое имя — 0" 0 "$?"
check_not "кривое имя не идёт в имя юнита" ht_called 'selkies@bad'

echo "== configure: прежний экземпляр другого пользователя гасится =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
printf '%s\n' 'selkies@bob.service loaded active running Selkies' 'selkies@alice.service loaded inactive dead Selkies' > "$FAKE/units"
ht_fake systemctl '
case "$1" in
    is-active) [[ -e "$FAKE/active-display-manager" ]] && exit 0; exit 3 ;;
    list-units) cat "$FAKE/units" ;;
esac
exit 0'
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
check "selkies@bob — stop --no-block" ht_called '^systemctl stop --no-block selkies@bob\.service'
check_not "selkies@alice не гасится" ht_called '^systemctl stop --no-block selkies@alice'
check "selkies@alice стартует" started alice

echo "== apply: перезапуск и объявление; без аутентификации — останов =="
sk_root; ht_secret SELKIES_BASIC_AUTH_PASSWORD "$PW"
ht_hook apply CREAM_CHANGED_KEYS=SELKIES_PORT SELKIES_PORT=9090; eq "apply — 0" 0 "$?"
check "restart --no-block selkies@alice" ht_called '^systemctl restart --no-block selkies@alice\.service'
check "порт доехал до объявления" grep -qx 'URI=http://127.0.0.1:9090' "$DECL"
check_not "apply не ждёт" ht_called '^sleep'
check_not "блокирующих systemctl нет" blocking_systemctl
check_not "секреты не в выводе" leaked "$ROOT/out" "$FAKE"
sk_root
printf '%s\n' 'selkies@alice.service loaded active running Selkies' > "$FAKE/units"
ht_hook apply CREAM_CHANGED_KEYS=SELKIES_BASIC_AUTH_PASSWORD; eq "пароль снят: apply — 0" 0 "$?"
check "экземпляр гасится" ht_called '^systemctl stop --no-block selkies@alice\.service'
check_not "не перезапускается" started alice
check "предупреждение" grep -q 'SELKIES_ALLOW_NO_AUTH' "$ROOT/out"

echo "== remove: службы, объявление, AppImage =="
sk_root; fake_appimage; ln -s "$ROOT/opt/selkies/$VER" "$ROOT/opt/selkies/current"
mkdir -p "$APPS"; echo 'NAME=selkies' > "$DECL"; echo 'NAME=other' > "$APPS/other.conf"
printf '%s\n' 'selkies@alice.service loaded active running Selkies' > "$FAKE/units"
ht_hook remove; eq "remove — 0" 0 "$?"
check "экземпляры остановлены" ht_called '^systemctl stop .*selkies@alice\.service'
check_not "объявление снято" test -e "$DECL"
check "чужое объявление на месте" test -f "$APPS/other.conf"
check_not "AppImage удалён" test -e "$ROOT/opt/selkies/$VER"
check_not "ссылка current удалена" test -L "$ROOT/opt/selkies/current"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
sk_root; mkdir -p "$ROOT/victim/$VER"; echo keep > "$ROOT/victim/$VER/f"
mkdir -p "$ROOT/opt"; ln -s "$ROOT/victim" "$ROOT/opt/selkies"
ht_hook remove; eq "/opt/selkies — ссылка: remove 0" 0 "$?"
check "по ссылке не удаляет" test -f "$ROOT/victim/$VER/f"

echo "== run-selkies.sh: fail-closed и секреты =="
# run_wrapper <env pairs…>: the wrapper as systemd starts it for alice (User=%i):
# config and secrets in the environment, nothing else.
run_wrapper() {
    (
        cd / || exit 125
        exec env -i "PATH=$ROOT/bin:$HT_PATH_TAIL" LANG=C.UTF-8 "CREAM_ROOT=$ROOT" \
            SELKIES_AUDIO_ENABLED=false "$@" /bin/bash "$EXT/files/run-selkies.sh" alice < /dev/null
    ) > "$ROOT/out" 2>&1
}
wr_root() {
    sk_root; fake_appimage; ln -s "$ROOT/opt/selkies/$VER" "$ROOT/opt/selkies/current"
    : > "$ROOT/home/alice/.Xauthority"
    for c in xdpyinfo pactl loginctl pgrep; do
        ht_fake "$c" "env > \"\$FAKE/$c.env\"; [[ $c == pgrep ]] && exit 1; exit 0"
    done
}
wr_root
run_wrapper; eq "без пароля и ключа — 78" 78 "$?"
check_not "selkies не запущен" test -e "$FAKE/selkies.env"
check "сказано, как открыть" grep -q 'SELKIES_ALLOW_NO_AUTH' "$ROOT/out"
wr_root
run_wrapper "SELKIES_BASIC_AUTH_VIEWONLY_PASSWORD=$VO"; eq "только пароль просмотра — 78" 78 "$?"
check_not "selkies не запущен" test -e "$FAKE/selkies.env"
wr_root
run_wrapper SELKIES_ENABLE_BASIC_AUTH=false; eq "SELKIES_ENABLE_BASIC_AUTH=false без пароля — 78" 78 "$?"

wr_root
run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW" "SELKIES_MASTER_TOKEN=$TOKEN" SELKIES_ENABLE_BASIC_AUTH=false
check "selkies запущен" test -e "$FAKE/selkies.env"
check "basic auth включён принудительно" grep -qx 'SELKIES_ENABLE_BASIC_AUTH=true' "$FAKE/selkies.env"
check "пароль дошёл до selkies через окружение" grep -qxF "SELKIES_BASIC_AUTH_PASSWORD=$PW" "$FAKE/selkies.env"
check "токен дошёл до selkies" grep -qxF "SELKIES_MASTER_TOKEN=$TOKEN" "$FAKE/selkies.env"
eq "argv selkies пуст" "" "$(cat "$FAKE/selkies.args")"
check_not "секретов нет у xdpyinfo, pactl, loginctl, pgrep" leaked "$FAKE"/{xdpyinfo,pactl,loginctl,pgrep}.env
check_not "секретов нет в argv вызовов" leaked "$FAKE/calls" "$FAKE"/*.argv
check_not "секретов нет в выводе обёртки" leaked "$ROOT/out"

wr_root
run_wrapper SELKIES_ALLOW_NO_AUTH=1
check "SELKIES_ALLOW_NO_AUTH=1 — запущен" test -e "$FAKE/selkies.env"
check "basic auth выключен явно" grep -qx 'SELKIES_ENABLE_BASIC_AUTH=false' "$FAKE/selkies.env"
check "предупреждение при старте" grep -q 'SELKIES_ALLOW_NO_AUTH=1' "$ROOT/out"

wr_root
run_wrapper "SELKIES_BASIC_AUTH_PASSWORD=$PW" SELKIES_ENABLE_HTTPS=true
d="$ROOT/home/alice/.local/state/selkies"
eq "каталог TLS 0700" 700 "$(stat -c %a "$d")"
check "сертификат — в состоянии пользователя" grep -qxF "SELKIES_HTTPS_CERT=$d/selkies.pem" "$FAKE/selkies.env"

echo "== имена layout 2 =="
# check-names: off
check_not "нет /opt/bisquite, bisquite-conf, BISQUITE_ в коде" \
    grep -rqE '/opt/bisquite|/etc/bisquite|bisquite-conf|BISQUITE_' "$EXT/hooks" "$EXT/files" "$EXT/extension.yaml"
# check-names: on

ht_done
