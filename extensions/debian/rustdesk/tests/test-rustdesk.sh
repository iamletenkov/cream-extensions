#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the rustdesk extension (cream/v1): manifest, hooks install,
# configure and remove, and files/render-toml.sh, on a scratch root
# (CREAM_ROOT) the way cream runs them. dpkg, dpkg-query, apt-get, curl,
# systemctl, systemd-run, runuser, timeout, getent and sleep are fakes; the
# cloud-user library is a stub. No root, network or systemd.
#
# Held here: the .deb is checked by sha256 BEFORE apt sees it; the image keeps
# no device identity (build only — a live install never wipes an ID); a user's
# RustDesk2.toml is written by a process running as that user (runuser, empty
# environment, closed descriptors, bounded in time), never by root; values
# reach TOML only after a form check; nothing here ever sets a password or an
# access mode — the access stays as RustDesk ships it (one-time password shown
# on the screen), so no silent access without authentication.
#
#   extensions/debian/rustdesk/tests/test-rustdesk.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

DEB_CONTENT="fake rustdesk deb"
DEB_SHA="$(printf '%s' "$DEB_CONTENT" | sha256sum | cut -d' ' -f1)"
SRV="rustdesk.example.com"
KEY="AAAAAAAA+/AAAAAAAA=="

rroot() {
    ht_root "$EXT"
    STATE="$ROOT/var/lib/cream/ext/rustdesk"
    RT="$ROOT/root/.config/rustdesk/RustDesk2.toml"
    AT="$ROOT/home/alice/.config/rustdesk/RustDesk2.toml"
    mkdir -p "$ROOT/root" "$ROOT/etc/skel" "$ROOT/home/alice" "$ROOT/var/tmp"
    printf '%s\n' 'root:x:0:0::/root:/bin/bash' 'alice:x:1000:1000::/home/alice:/bin/bash' \
        'nobody:x:65534:65534::/nonexistent:/usr/sbin/nologin' > "$FAKE/passwd"
    echo alice > "$FAKE/user"
    ht_fake getent 'f="$FAKE/$1"; [[ -f "$f" ]] || exit 2; [[ -z "${2-}" ]] && { cat "$f"; exit 0; }; grep -E "^${2}:" "$f" || exit 2'
    ht_fake dpkg '[[ "$1" == --print-architecture ]] && { cat "$FAKE/arch" 2>/dev/null || echo amd64; exit 0; }; exit 0'
    ht_fake dpkg-query '[[ -f "$FAKE/installed" ]] && printf "install ok installed %s\n" "$(cat "$FAKE/installed")"; exit 0'
    ht_fake apt-get 'if [[ "$1" == -s ]]; then v=Remv; [[ "$2" == purge ]] && v=Purg
    for a in "${@:3}"; do echo "$v $a [1.0]"; done; cat "$FAKE/sim-extra" 2>/dev/null; exit 0; fi
for a in "$@"; do
  if [[ "$a" == *.deb ]]; then
    cp "$a" "$FAKE/got.deb"
    v="${a##*/rustdesk-}"; echo "${v%%-*}" > "$FAKE/installed"
    mkdir -p "'"$ROOT"'/usr/share/rustdesk/files/systemd" "'"$ROOT"'/usr/bin"
    printf "[Service]\nExecStart=/usr/bin/rustdesk --service\nExecStop=pkill -f \"rustdesk --\"\n" > "'"$ROOT"'/usr/share/rustdesk/files/systemd/rustdesk.service"
    : > "'"$ROOT"'/usr/share/rustdesk/rustdesk"
  fi
done; exit 0'
    ht_fake curl 'out=""; while (( $# )); do [[ "$1" == -o ]] && { out="$2"; shift; }; shift; done
printf "%s" "'"$DEB_CONTENT"'" > "$out"'
    ht_fake systemctl '[[ "$1" == is-active ]] && { [[ -f "$FAKE/active" ]]; exit; }; exit 0'
    ht_fake systemd-run
    ht_fake sleep
    ht_fake runuser '
if [[ -e /proc/$$/fd/9 ]]; then echo open; else echo closed; fi > "$FAKE/runuser-lockfd"
[[ "$1" == -u && "$3" == -- ]] || exit 2
shift 3; exec "$@"'
    ht_fake timeout '[[ "$1" == -k ]] && shift 2; shift; exec "$@"'
    LIB="$ROOT/opt/cream/ext/cloud-user/get_cloud_user.sh"
    mkdir -p "$(dirname "$LIB")"
    printf '#!/usr/bin/env bash\ncat %q 2>/dev/null || exit 1\n' "$FAKE/user" > "$LIB"
    chmod +x "$LIB"
}
live_systemd() { mkdir -p "$ROOT/run/systemd/system"; }
opt() { sed -n "s/^$2 = '\\(.*\\)'\$/\\1/p" "$1"; }

echo "== манифест =="
# eval: test-only literal expressions over our own manifest, as in nvidia-jetpack.
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 2" 2.0.1 "$(mf 'm["version"]')"
eq "cream >=1.0.0" ">=1.0.0" "$(mf 'm["cream"]')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "стадия system" system "$(mf 'm["hooks"]["configure"]["stage"]')"
eq "до rustdesk.service" "['rustdesk.service']" "$(mf 'm["hooks"]["configure"]["before"]')"
eq "хуки" "['configure', 'install', 'remove']" "$(mf 'sorted(m["hooks"])')"
eq "depends cloud-user, apt-guard" "cloud-user >=1.0.0 <2 apt-guard >=1.0.0 <2" "$(mf '" ".join(d["name"]+" "+d["version"] for d in m["depends"])')"
eq "параметры установки" "RUSTDESK_SHA256 RUSTDESK_SHA256_AMD64 RUSTDESK_SHA256_ARM64 RUSTDESK_URL RUSTDESK_VERSION" \
    "$(mf '" ".join(sorted(k for k, v in m["config"]["keys"].items() if v.get("scope") == "install"))')"
check_not "ни одного ключа пароля или режима доступа" grep -qiE 'PASSWORD|VERIFICATION|APPROVE' <<< "$(mf '" ".join(m["config"]["keys"])')"
for f in install.sh configure.sh render-toml.sh knobs knobs.apply configure-rustdesk.service; do
    check_not "layout 2: нет $f" test -e "$EXT/$f"
done

echo "== install: sha256 до apt =="
rroot
ht_hook install RUSTDESK_SHA256=0000000000000000000000000000000000000000000000000000000000000000
eq "чужая сумма — 1" 1 "$?"
check_not "пакет apt не видел" ht_called '^apt-get .*\.deb'
check "сообщение про sha256" grep -q 'sha256' <(ht_out)
ht_hook install; eq "закреплённая сумма 1.5.0 не совпала с подделкой — 1" 1 "$?"
ht_hook install RUSTDESK_VERSION=1.6.0; eq "версия без суммы — 1" 1 "$?"
check "подсказка про RUSTDESK_SHA256_AMD64" grep -q 'RUSTDESK_SHA256_AMD64' <(ht_out)
ht_hook install 'RUSTDESK_VERSION=1.5;id'; eq "версия не X.Y.Z — 1" 1 "$?"
ht_hook install "RUSTDESK_SHA256=$DEB_SHA" 'RUSTDESK_URL=https://x.org/a b'; eq "URL не по форме — 1" 1 "$?"
echo armhf > "$FAKE/arch"
ht_hook install "RUSTDESK_SHA256=$DEB_SHA"; eq "armhf — 1" 1 "$?"
check_not "до сих пор apt-get install не звали" ht_called '^apt-get .*install'

echo "== install (build): пакет, юнит, без идентичности в образе =="
rroot
mkdir -p "$ROOT/root/.config/rustdesk" "$ROOT/etc/skel/.config/rustdesk" "$ROOT/home/alice/.config/rustdesk"
for h in root etc/skel home/alice; do echo "id = '1'" > "$ROOT/$h/.config/rustdesk/RustDesk.toml"; done
HT_PHASE=build ht_hook install "RUSTDESK_SHA256_AMD64=$DEB_SHA"; eq "build — 0" 0 "$?"
check "скачан ассет x86_64" ht_called '^curl .*/1\.5\.0/rustdesk-1\.5\.0-x86_64\.deb$'
eq "apt получил проверенный файл" "$DEB_CONTENT" "$(cat "$FAKE/got.deb")"
check "юнит положен" grep -qx 'ExecStop=/usr/bin/pkill -f "rustdesk --"' "$ROOT/usr/lib/systemd/system/rustdesk.service"
check "rustdesk.service включён" ht_called '^systemctl enable rustdesk\.service$'
check_not "ID root удалён" test -e "$ROOT/root/.config/rustdesk/RustDesk.toml"
check_not "ID skel удалён" test -e "$ROOT/etc/skel/.config/rustdesk/RustDesk.toml"
check_not "ID alice удалён" test -e "$ROOT/home/alice/.config/rustdesk/RustDesk.toml"
check "в доме alice — от её имени" ht_called '^runuser -u alice -- env -i PATH=[^ ]+ LANG=C\.UTF-8 rm -f -- '
eq "fd блокировки cream процессу пользователя не достаётся" closed "$(cat "$FAKE/runuser-lockfd" 2>/dev/null)"
eq "состояние: пакет наш" rustdesk "$(cat "$STATE/packages")"
check_not "временный каталог убран" test -n "$(ls -A "$ROOT/tmp")"
: > "$FAKE/calls"
HT_PHASE=build ht_hook install "RUSTDESK_SHA256_AMD64=$DEB_SHA"; eq "повтор — 0" 0 "$?"
check_not "повтор: не качает" ht_called '^curl '

echo "== install (live): идентичность не трогается =="
rroot; live_systemd
mkdir -p "$ROOT/home/alice/.config/rustdesk"; echo "id = '7'" > "$ROOT/home/alice/.config/rustdesk/RustDesk.toml"
ht_hook install "RUSTDESK_SHA256=$DEB_SHA"; eq "live — 0" 0 "$?"
check "ID устройства на живой машине цел" test -e "$ROOT/home/alice/.config/rustdesk/RustDesk.toml"
check_not "rustdesk.service не останавливали" ht_called '^systemctl stop'

echo "== configure: адреса сервера =="
rroot
ht_hook configure CREAM_REASON=boot; eq "пусто — 0" 0 "$?"
check_not "пусто: файлов нет" test -e "$RT" -o -e "$AT"
ht_hook configure CREAM_REASON=boot "RUSTDESK_ID_SERVER=$SRV" "RUSTDESK_KEY=$KEY"; eq "сервер и ключ — 0" 0 "$?"
eq "root: custom-rendezvous-server" "$SRV" "$(opt "$RT" custom-rendezvous-server)"
eq "alice: key" "$KEY" "$(opt "$AT" key)"
eq "файл alice 0600" 600 "$(stat -c %a "$AT")"
check "alice — от её имени, в пределе времени" ht_called '^timeout -k 5 30 runuser -u alice -- env -i PATH=[^ ]+ LANG=C\.UTF-8 .*/files/render-toml\.sh .*/home/alice/\.config/rustdesk/RustDesk2\.toml'
check_not "nobody не трогается" ht_called 'runuser -u nobody'
eq "managed" "custom-rendezvous-server key" "$(tr '\n' ' ' < "$STATE/managed" | sed 's/ $//')"
check_not "ни пароля, ни режима доступа" grep -qiE 'password|verification|approve' "$RT" "$AT"
cp "$AT" "$ROOT/at1"
ht_hook configure CREAM_REASON=boot "RUSTDESK_ID_SERVER=$SRV" "RUSTDESK_KEY=$KEY"; eq "повтор — 0" 0 "$?"
check "повтор: файл тот же" cmp -s "$ROOT/at1" "$AT"
ht_hook configure CREAM_REASON=apply "RUSTDESK_ID_SERVER=$SRV"; eq "ключ снят — 0" 0 "$?"
eq "свой key убран" "" "$(opt "$AT" key)"
eq "сервер остался" "$SRV" "$(opt "$AT" custom-rendezvous-server)"

echo "== configure: форма значений =="
rroot
ht_hook configure CREAM_REASON=apply "RUSTDESK_ID_SERVER=x.org' = 1"; eq "кавычка — 1" 1 "$?"
ht_hook configure CREAM_REASON=apply $'RUSTDESK_KEY=abc\npassword = x'; eq "перевод строки — 1" 1 "$?"
ht_hook configure CREAM_REASON=apply 'RUSTDESK_API_SERVER=javascript:x'; eq "API не URL — 1" 1 "$?"
check_not "ничего не записано" test -e "$RT" -o -e "$AT"

echo "== configure: ссылка в доме пользователя =="
rroot
mkdir -p "$ROOT/home/alice/.config" "$ROOT/victim"
ln -s "$ROOT/victim" "$ROOT/home/alice/.config/rustdesk"
ht_hook configure CREAM_REASON=boot "RUSTDESK_ID_SERVER=$SRV"; rc=$?
check_not "root не пишет через ссылку пользователя (рендер идёт от пользователя)" \
    ht_called '^bash .*/home/alice'
check "у alice рендер от её имени" ht_called '^timeout -k 5 30 runuser -u alice'
eq "код" 0 "$rc"

echo "== configure: перезапуск и повторная сверка =="
rroot; live_systemd; : > "$FAKE/active"
ht_hook configure CREAM_REASON=apply "RUSTDESK_ID_SERVER=$SRV"; eq "live — 0" 0 "$?"
check "rustdesk перезапуск --no-block" ht_called '^systemctl --no-block restart rustdesk\.service$'
check_not "блокирующего systemctl нет" ht_called '^systemctl (start|restart|stop) '
check "повторная сверка через минуту — перезапуск configure" \
    ht_called '^systemd-run --quiet --no-block --on-active=60 --unit=rustdesk-followup-1 systemctl --no-block restart cream-configure@rustdesk\.service$'
echo 10 > "$ROOT/run/rustdesk/followup"
: > "$FAKE/calls"
ht_hook configure CREAM_REASON=apply "RUSTDESK_ID_SERVER=other.example.com"; eq "предел сверок — 0" 0 "$?"
check_not "больше 10 сверок за загрузку нет" ht_called '^systemd-run'
check_not "счётчик сверок не в состоянии (повтор install не меняет его)" test -e "$STATE/followup"
rroot
ht_hook configure CREAM_REASON=boot "RUSTDESK_ID_SERVER=$SRV"; eq "без systemd — 0" 0 "$?"
check_not "без systemd: сверки нет" ht_called '^systemd-run'

echo "== remove =="
rroot; live_systemd
HT_PHASE=build ht_hook install "RUSTDESK_SHA256=$DEB_SHA"
ht_hook configure CREAM_REASON=install "RUSTDESK_ID_SERVER=$SRV" "RUSTDESK_KEY=$KEY"
echo "other = 'kept'" >> "$AT"
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
eq "свои опции сняты у alice" "" "$(opt "$AT" custom-rendezvous-server)$(opt "$AT" key)"
check "чужая строка осталась" grep -qx "other = 'kept'" "$AT"
check "пакет снят" ht_called '^apt-get .*remove .*rustdesk'
check_not "положенный нами юнит снят" test -e "$ROOT/usr/lib/systemd/system/rustdesk.service"
check_not "состояние снято" test -e "$STATE/managed" -o -e "$STATE/packages"
: > "$FAKE/calls"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
check_not "повтор: apt не звали" ht_called '^apt-get '

echo "== render-toml.sh =="
R2="$HT_TMP/r"; mkdir -p "$R2"
printf '%s\n' "rendezvous_server = 'x'" '' '[options]' "custom-rendezvous-server = 'old'" "local-ip-addr = '1'" > "$R2/t.toml"
"$EXT/files/render-toml.sh" "$R2/t.toml" custom-rendezvous-server=new >/dev/null; eq "рендер — 0" 0 "$?"
eq "значение заменено" new "$(opt "$R2/t.toml" custom-rendezvous-server)"
eq "чужая опция цела" 1 "$(opt "$R2/t.toml" local-ip-addr)"
"$EXT/files/render-toml.sh" "$R2/t.toml" "key=a'b" >/dev/null 2>&1; eq "кавычка — 2" 2 "$?"
ln -s "$R2/t.toml" "$R2/link.toml"
"$EXT/files/render-toml.sh" "$R2/link.toml" key=abc >/dev/null 2>&1; eq "ссылка — отказ 1" 1 "$?"

echo "== remove: симуляция снимает чужой пакет — отказ =="
rroot; live_systemd
HT_PHASE=build ht_hook install "RUSTDESK_SHA256=$DEB_SHA"
ht_hook configure CREAM_REASON=install "RUSTDESK_ID_SERVER=$SRV" "RUSTDESK_KEY=$KEY"
echo 'Remv rustdesk-plugins [1.0]' > "$FAKE/sim-extra"
: > "$FAKE/calls"
ht_hook remove; eq "симуляция снимает чужой пакет — 1" 1 "$?"
check "чужой пакет назван" grep -q 'rustdesk-plugins' "$ROOT/out"
check_not "ничего не снято" ht_called '^apt-get -q -y remove'
check "свои опции остались" test -n "$(opt "$AT" custom-rendezvous-server)"
check "запись осталась" grep -qx rustdesk "$STATE/packages"

ht_done
