#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes and python is the test data
# Тесты обёртки stvor-agent (cream/v1): манифест, пин каталога, хуки
# install/upgrade/remove/apply — на подменённом корне, с поддельными curl,
# dpkg, dpkg-query, systemctl и stvor-agent в PATH. Хук запускается так, как
# его зовёт cream (спека cream §6.3): окружение очищено, ключи домена —
# переменными, CREAM_EXT_DIR — копия расширения с тестовым пином. Пакет —
# подставной файл: проверяется, откуда он берётся, что сверяется по sha256 и
# уходит в dpkg -i, а не сам пакет (его тесты — в репозитории stvor-agent).
# root, systemd и сеть не нужны.
#
# Drop-in командной метки раскладывает cream (`files` манифеста), поэтому он
# проверяется по манифесту всегда, а живьём — настоящим cream в контейнере
# debian:12 (install кладёт файл, remove убирает), если есть cream:
# CREAM_DEB=<.deb> или кеш пина tools/cream-pin.env, и docker. Нет — строка
# «пропущено», не молчание.
#
#   tools/test-stvor-agent.sh        код 0 — все проверки прошли

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
EXT="$REPO/extensions/debian/stvor-agent"

TMP="$(mktemp -d)"
trap 'rm -r -f -- "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
exec 3>&2
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&3; }
check(){ local what="$1"; shift; if "$@"; then ok; else bad "$what"; fi; }
check_not(){ local what="$1"; shift; if "$@"; then bad "$what"; else ok; fi; }
eq(){ local what="$1" want="$2" got="$3"; if [[ "$want" == "$got" ]]; then ok; else bad "$what: ждали [$want], получили [$got]"; fi; }

GH=https://github.com/iamletenkov/stvor-agent/releases/download
MIRROR=https://portal.example.org/dist/teleport
BASE_PATH="$PATH"
TOKEN="tok-$RANDOM$RANDOM-label-secret"

# ---------------------------------------------------------------------------
# A scratch root per scenario.
#   $ROOT/ext           copy of the extension (CREAM_EXT_DIR), test pin inside
#   $ROOT/bin           fakes, first in PATH
#   $FAKE/arch          dpkg --print-architecture (amd64 by default)
#   $FAKE/installed     version dpkg-query reports as installed (absent — none)
#   $FAKE/curl-fails    exists — every download fails
#   $FAKE/disable-fails exists — `stvor-agent disable` exits 1
#   $FAKE/deb-<arch>    what a download of stvor-agent_*_<arch>.deb returns
#   $FAKE/calls         one line per call of a fake, in order
#   $FAKE/<fake>.argv, $FAKE/<fake>.env   argv and environment of every call
new_root(){
    ROOT="$(mktemp -d "$TMP/root.XXXXXX")"
    FAKE="$ROOT/fake"
    mkdir -p "$ROOT/bin" "$FAKE" "$ROOT/tmp" "$ROOT/etc/stvor-agent"
    cp -a "$EXT" "$ROOT/ext"
    # The labels token of an enabled agent: no hook may touch it.
    printf 'url=https://portal.example.org/robot-api/v1/labels\ntoken=%s\n' "$TOKEN" > "$ROOT/etc/stvor-agent/token"
    local f
    for f in curl dpkg dpkg-query systemctl stvor-agent; do
        {
            echo '#!/usr/bin/env bash'
            printf 'FAKE=%q\n' "$FAKE"
            printf 'me=%q\n' "$f"
            echo 'printf "%s\n" "$*" >> "$FAKE/$me.argv"; env >> "$FAKE/$me.env"'
        } > "$ROOT/bin/$f"
    done
    cat >> "$ROOT/bin/curl" <<'EOF'
out=""; url=""
while (( $# )); do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --retry|--retry-delay|--connect-timeout|--speed-limit|--speed-time|--proto|--max-redirs) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
echo "curl $url" >> "$FAKE/calls"
[[ -f "$FAKE/curl-fails" ]] && exit 22
case "$url" in
    *_amd64.deb) src="$FAKE/deb-amd64" ;;
    *_arm64.deb) src="$FAKE/deb-arm64" ;;
    *) exit 22 ;;
esac
[[ -n "$out" ]] || exit 2
cat "$src" > "$out"
EOF
    cat >> "$ROOT/bin/dpkg" <<'EOF'
case "$1" in
    --print-architecture) cat "$FAKE/arch" 2>/dev/null || echo amd64 ;;
    -i) echo "dpkg -i $(basename "$2") $(sha256sum < "$2" | cut -d' ' -f1)" >> "$FAKE/calls" ;;
    -r) echo "dpkg -r $2" >> "$FAKE/calls" ;;
    *) exit 2 ;;
esac
EOF
    cat >> "$ROOT/bin/dpkg-query" <<'EOF'
[[ -f "$FAKE/installed" ]] || { echo "dpkg-query: no packages found matching stvor-agent" >&2; exit 1; }
printf 'install ok installed %s' "$(cat "$FAKE/installed")"
EOF
    cat >> "$ROOT/bin/systemctl" <<'EOF'
echo "systemctl $*" >> "$FAKE/calls"
EOF
    cat >> "$ROOT/bin/stvor-agent" <<'EOF'
echo "stvor-agent $*" >> "$FAKE/calls"
[[ -f "$FAKE/disable-fails" && "$1" == disable ]] && exit 1
exit 0
EOF
    chmod +x "$ROOT/bin/"*
    echo "fake stvor-agent amd64 $RANDOM" > "$FAKE/deb-amd64"
    echo "fake stvor-agent arm64 $RANDOM" > "$FAKE/deb-arm64"
    SUM_AMD64="$(sha256sum < "$FAKE/deb-amd64" | cut -d' ' -f1)"
    SUM_ARM64="$(sha256sum < "$FAKE/deb-arm64" | cut -d' ' -f1)"
    pin 4.0.0 "$SUM_AMD64" "$SUM_ARM64"
}
# pin <version> <sum amd64> <sum arm64>: the catalog pin of the copy.
pin(){
    printf '# test pin\nSTVOR_AGENT_PIN_VERSION=%s\nSTVOR_AGENT_PIN_SHA256_AMD64=%s\nSTVOR_AGENT_PIN_SHA256_ARM64=%s\n' \
        "$1" "$2" "$3" > "$ROOT/ext/files/pin.env"
}
# hook <name> [KEY=VALUE…]: run a hook the way cream does — clean
# environment, every key of the domain present (empty by default).
hook(){
    local name="$1"; shift
    env -i PATH="$ROOT/bin:$BASE_PATH" LANG=C.UTF-8 TMPDIR="$ROOT/tmp" \
        CREAM_PHASE="${PHASE:-live}" CREAM_EXT=stvor-agent CREAM_EXT_VERSION=4.0.0 \
        CREAM_EXT_DIR="$ROOT/ext" CREAM_ETC_DIR="$ROOT/etc/cream/stvor-agent" \
        CREAM_STATE_DIR="$ROOT/var/lib/cream/ext/stvor-agent" CREAM_ROOT="$ROOT" \
        CREAM_CONFIG_FILE="$ROOT/etc/cream/stvor-agent/config" CREAM_SECRETS_FILE="$ROOT/etc/cream/stvor-agent/secrets" \
        STVOR_AGENT_VERSION= STVOR_AGENT_SHA256= STVOR_AGENT_MIRROR= STVOR_AGENT_DEB= \
        STVOR_AGENT_INTERVAL=60 STVOR_AGENT_LOG_LEVEL=info \
        "$@" "$ROOT/ext/hooks/$name"
}
calls(){ cat "$FAKE/calls" 2>/dev/null; }
net(){ grep '^curl ' "$FAKE/calls" 2>/dev/null; }
installed(){ grep '^dpkg -[ir] ' "$FAKE/calls" 2>/dev/null; }
pure(){ bash -c 'source "$1"; shift; "$@"' _ "$EXT/files/agent.sh" "$@"; }
# token_leaked: the labels token in argv or environment of any fake.
token_leaked(){ grep -rqF -- "$TOKEN" "$FAKE"/*.argv "$FAKE"/*.env 2>/dev/null; }
workdir_left(){ [[ -n "$(ls -A "$ROOT/tmp")" ]]; }

# ===========================================================================
echo "== манифест =="
# manifest <python expression over m>: the expressions are this file's own
# literals, never outside input — eval is the point of the helper.
manifest(){
    python3 - "$EXT/extension.yaml" "$1" <<'PY'
import sys, yaml
m = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
v = eval(sys.argv[2], {"m": m})
print(v if isinstance(v, str) else repr(v))
PY
}
eq "schema" cream/v1 "$(manifest 'm["schema"]')"
eq "name" stvor-agent "$(manifest 'm["name"]')"
check "version — 4.x (patch поднимает agent-bump)" grep -qE '^4\.[0-9]+\.[0-9]+$' <<< "$(manifest 'm["version"]')"
eq "cream" '>=1.0.0' "$(manifest 'm["cream"]')"
eq "arch" "['amd64', 'arm64']" "$(manifest 'm["platform"]["arch"]')"
eq "targets" "{'build': 'exec', 'live': 'yes'}" "$(manifest 'm["targets"]')"
eq "provides" "['stvor-agent']" "$(manifest 'm["provides"]')"
eq "depends: teleport >=4.0.0 <5" "[{'name': 'teleport', 'version': '>=4.0.0 <5'}]" "$(manifest 'm["depends"]')"
eq "хуки" "['apply', 'install', 'remove', 'upgrade']" "$(manifest 'sorted(m["hooks"])')"
for h in install upgrade remove apply; do
    check "hooks/$h исполняемый" test -x "$EXT/hooks/$h"
done
eq "ключи scope: install" "['STVOR_AGENT_DEB', 'STVOR_AGENT_MIRROR', 'STVOR_AGENT_SHA256', 'STVOR_AGENT_VERSION']" \
    "$(manifest 'sorted(k for k, d in m["config"]["keys"].items() if d.get("scope") == "install")')"
eq "ключи scope: config" "['STVOR_AGENT_INTERVAL', 'STVOR_AGENT_LOG_LEVEL']" \
    "$(manifest 'sorted(k for k, d in m["config"]["keys"].items() if d.get("scope", "config") == "config")')"
eq "секретных ключей нет (токен — не ручка cream)" "[]" \
    "$(manifest '[k for k, d in m["config"]["keys"].items() if d.get("secret")]')"
eq "STVOR_AGENT_INTERVAL по умолчанию" 60 "$(manifest 'm["config"]["keys"]["STVOR_AGENT_INTERVAL"]["default"]')"
eq "STVOR_AGENT_LOG_LEVEL" "enum:info,debug info" \
    "$(manifest 'm["config"]["keys"]["STVOR_AGENT_LOG_LEVEL"]["type"] + " " + m["config"]["keys"]["STVOR_AGENT_LOG_LEVEL"]["default"]')"
# Range 60–600 of the interval, by the type's own regular expression.
interval_ok(){
    python3 - "$EXT/extension.yaml" "$1" <<'PY'
import re, sys, yaml
t = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["config"]["keys"]["STVOR_AGENT_INTERVAL"]["type"]
assert t.startswith("re:"), t
sys.exit(0 if re.search(t[3:], sys.argv[2]) else 1)
PY
}
for v in 60 61 99 100 300 599 600; do check "интервал $v допустим" interval_ok "$v"; done
for v in 0 59 601 1000 6000 060 '' 6a; do check_not "интервал '$v' — отказ" interval_ok "$v"; done
eq "files — только drop-in командной метки" \
    "[{'src': 'files/stvor_agent.command-label', 'dst': '/etc/cream/teleport/command-labels.d/stvor_agent', 'mode': '0644'}]" \
    "$(manifest 'm["files"]')"
eq "drop-in: команда метки" "command=/usr/bin/stvor-agent version --label" "$(cat "$EXT/files/stvor_agent.command-label")"
check_not "хуки сами не трогают command-labels.d (файлом владеет cream)" grep -rq 'command-labels' "$EXT/hooks" "$EXT/files/agent.sh"
check_not "systemctl в хуках — только --no-block" grep -rqE 'systemctl (try-restart|restart|reload)' "$EXT/hooks" "$EXT/files/agent.sh"

echo "== пин каталога =="
pinval(){ grep -E "^$1=" "$EXT/files/pin.env" | tail -n1 | cut -d= -f2-; }
check "PIN_VERSION — X.Y.Z" grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' <<< "$(pinval STVOR_AGENT_PIN_VERSION)"
check "PIN_SHA256_AMD64 — 64 hex" grep -qE '^[0-9a-f]{64}$' <<< "$(pinval STVOR_AGENT_PIN_SHA256_AMD64)"
check "PIN_SHA256_ARM64 — 64 hex" grep -qE '^[0-9a-f]{64}$' <<< "$(pinval STVOR_AGENT_PIN_SHA256_ARM64)"
if grep -q 'FICTITIOUS' "$EXT/files/pin.env"; then
    check "фиктивный пин помечен и в README" grep -q 'фиктивный' "$EXT/README.md"
fi

echo "== источник: чистые функции =="
eq "имя пакета" stvor-agent_4.0.0_arm64.deb "$(pure sa_deb_name 4.0.0 arm64)"
eq "по умолчанию — релиз GitHub" "$GH/v4.0.0/stvor-agent_4.0.0_amd64.deb" "$(pure sa_url 4.0.0 amd64 '')"
eq "зеркало — плоско" "$MIRROR/stvor-agent_4.0.0_amd64.deb" "$(pure sa_url 4.0.0 amd64 "$MIRROR")"
eq "зеркало со слешем" "$MIRROR/stvor-agent_4.0.1_arm64.deb" "$(pure sa_url 4.0.1 arm64 "$MIRROR/")"

# ===========================================================================
echo "== install: выбор источника и сверка суммы =="
new_root
out="$(hook install 2>&1)"; rc=$?
eq "пин каталога — код 0" 0 "$rc"
eq "пин каталога — релиз GitHub" "curl $GH/v4.0.0/stvor-agent_4.0.0_amd64.deb" "$(net)"
eq "пин каталога — dpkg -i того самого файла" "dpkg -i stvor-agent_4.0.0_amd64.deb $SUM_AMD64" "$(installed)"
check_not "рабочий каталог убран" workdir_left
check "подсказка про enable" grep -q 'stvor-agent enable' <<< "$out"
check_not "службу хук не трогает" grep -q '^systemctl\|^stvor-agent' <<< "$(calls)"

new_root; echo arm64 > "$FAKE/arch"
hook install >/dev/null 2>&1; rc=$?
eq "arm64 — код 0" 0 "$rc"
eq "arm64 — свой файл и своя сумма" "curl $GH/v4.0.0/stvor-agent_4.0.0_arm64.deb
dpkg -i stvor-agent_4.0.0_arm64.deb $SUM_ARM64" "$(calls)"

new_root
hook install STVOR_AGENT_MIRROR="$MIRROR/" >/dev/null 2>&1; rc=$?
eq "зеркало — код 0" 0 "$rc"
eq "зеркало — файл плоско в базе" "curl $MIRROR/stvor-agent_4.0.0_amd64.deb" "$(net)"

new_root
cp "$FAKE/deb-amd64" "$TMP/local.deb"
hook install STVOR_AGENT_DEB="$TMP/local.deb" >/dev/null 2>&1; rc=$?
eq "STVOR_AGENT_DEB — код 0" 0 "$rc"
eq "STVOR_AGENT_DEB — сеть не трогалась" "" "$(net)"
eq "STVOR_AGENT_DEB — dpkg -i под именем пакета" "dpkg -i stvor-agent_4.0.0_amd64.deb $SUM_AMD64" "$(installed)"

new_root
echo other > "$TMP/other.deb"
out="$(hook install STVOR_AGENT_DEB="$TMP/other.deb" 2>&1)"; rc=$?
check "STVOR_AGENT_DEB чужой — отказ" test "$rc" -ne 0
check "STVOR_AGENT_DEB чужой — текст про sha256" grep -q 'sha256' <<< "$out"
eq "STVOR_AGENT_DEB чужой — dpkg не звался" "" "$(installed)"

new_root
out="$(hook install STVOR_AGENT_DEB=relative.deb 2>&1)"; rc=$?
check "STVOR_AGENT_DEB не абсолютный — отказ" test "$rc" -ne 0
new_root
out="$(hook install STVOR_AGENT_DEB="$TMP/nope.deb" 2>&1)"; rc=$?
check "STVOR_AGENT_DEB нет файла — отказ" test "$rc" -ne 0
eq "STVOR_AGENT_DEB нет файла — сеть не трогалась" "" "$(net)"

new_root
out="$(hook install STVOR_AGENT_DEB="$TMP/local.deb" STVOR_AGENT_MIRROR="$MIRROR" 2>&1)"; rc=$?
check "STVOR_AGENT_DEB вместе с зеркалом — отказ" test "$rc" -ne 0
check "STVOR_AGENT_DEB вместе с зеркалом — текст" grep -q 'взаимоисключ' <<< "$out"
eq "STVOR_AGENT_DEB вместе с зеркалом — ничего не сделано" "" "$(calls)"

new_root
check_not "зеркало с кавычкой — отказ" hook install STVOR_AGENT_MIRROR='https://x"y/dist' 2>/dev/null
eq "зеркало с кавычкой — ничего не сделано" "" "$(calls)"
new_root
check_not "зеркало не http(s) — отказ" hook install STVOR_AGENT_MIRROR='ftp://x.example.org/dist' 2>/dev/null

new_root
printf 'not the package\n' > "$FAKE/deb-amd64"
out="$(hook install 2>&1)"; rc=$?
check "сумма не та — отказ" test "$rc" -ne 0
check "сумма не та — текст" grep -q 'sha256 пакета не совпал' <<< "$out"
eq "сумма не та — dpkg не звался" "" "$(installed)"
check_not "сумма не та — рабочий каталог убран" workdir_left

new_root; touch "$FAKE/curl-fails"
out="$(hook install 2>&1)"; rc=$?
check "не скачался — отказ" test "$rc" -ne 0
check "не скачался — текст" grep -q 'не скачался' <<< "$out"
eq "не скачался — dpkg не звался" "" "$(installed)"

new_root; echo armhf > "$FAKE/arch"
check_not "armhf — отказ" hook install 2>/dev/null
eq "armhf — сеть не трогалась" "" "$(net)"

echo "== install: пин и явные версия с суммой =="
new_root
X="$(printf 'a%.0s' {1..64})"
out="$(hook install STVOR_AGENT_VERSION=4.0.1 2>&1)"; rc=$?
check "версия без суммы — отказ" test "$rc" -ne 0
check "версия без суммы — текст" grep -q 'STVOR_AGENT_SHA256' <<< "$out"
eq "версия без суммы — ничего не сделано" "" "$(calls)"
new_root
out="$(hook install STVOR_AGENT_SHA256="$X" 2>&1)"; rc=$?
check "сумма без версии — отказ" test "$rc" -ne 0
check "сумма без версии — текст" grep -q 'STVOR_AGENT_VERSION' <<< "$out"
eq "сумма без версии — ничего не сделано" "" "$(calls)"

new_root
printf 'fake stvor-agent 4.1.0\n' > "$FAKE/deb-amd64"
S410="$(sha256sum < "$FAKE/deb-amd64" | cut -d' ' -f1)"
hook install STVOR_AGENT_VERSION=4.1.0 STVOR_AGENT_SHA256="$S410" >/dev/null 2>&1; rc=$?
eq "явные версия и сумма — код 0" 0 "$rc"
eq "явные версия и сумма побеждают пин" "curl $GH/v4.1.0/stvor-agent_4.1.0_amd64.deb
dpkg -i stvor-agent_4.1.0_amd64.deb $S410" "$(calls)"

new_root
pin 4.0.0 "$X" "$SUM_ARM64"
out="$(hook install STVOR_AGENT_VERSION=4.0.0 STVOR_AGENT_SHA256="$SUM_AMD64" 2>&1)"; rc=$?
eq "явная сумма побеждает пин той же версии" "dpkg -i stvor-agent_4.0.0_amd64.deb $SUM_AMD64" "$(installed)"

new_root
pin 4.0.0 "$X" "$SUM_ARM64"
out="$(hook install STVOR_AGENT_SHA256="$SUM_AMD64" STVOR_AGENT_VERSION= 2>&1)"; rc=$?
check "неполная пара не добирается из пина — отказ" test "$rc" -ne 0

new_root; pin "" "$SUM_AMD64" "$SUM_ARM64"
out="$(hook install 2>&1)"; rc=$?
check "пин без версии — отказ" test "$rc" -ne 0
check "пин без версии — текст про пин" grep -q 'пин' <<< "$out"
eq "пин без версии — сеть не трогалась" "" "$(net)"
new_root; pin 4.0.0 "$SUM_AMD64" ""; echo arm64 > "$FAKE/arch"
out="$(hook install 2>&1)"; rc=$?
check "пин без суммы своей архитектуры — отказ" test "$rc" -ne 0
eq "пин без суммы своей архитектуры — сеть не трогалась" "" "$(net)"
new_root; pin 4.0.0 "$SUM_AMD64" ""
hook install >/dev/null 2>&1; rc=$?
eq "пин без суммы чужой архитектуры — amd64 ставится" 0 "$rc"
new_root; pin 4.0 "$SUM_AMD64" "$SUM_ARM64"
check_not "пин: версия не X.Y.Z — отказ" hook install 2>/dev/null
new_root; pin 4.0.0 "${SUM_AMD64:0:63}" "$SUM_ARM64"
check_not "пин: сумма не 64 hex — отказ" hook install 2>/dev/null
eq "пин: сумма не 64 hex — сеть не трогалась" "" "$(net)"
new_root; rm "$ROOT/ext/files/pin.env"
check_not "нет files/pin.env — отказ" hook install 2>/dev/null
new_root; rm "$ROOT/ext/files/pin.env"
hook install STVOR_AGENT_VERSION=4.0.0 STVOR_AGENT_SHA256="$SUM_AMD64" >/dev/null 2>&1; rc=$?
eq "нет files/pin.env, явные версия и сумма — код 0" 0 "$rc"
new_root
check_not "STVOR_AGENT_VERSION не X.Y.Z — отказ" hook install STVOR_AGENT_VERSION='4.0.0;x' STVOR_AGENT_SHA256="$SUM_AMD64" 2>/dev/null
check_not "STVOR_AGENT_SHA256 не hex — отказ" hook install STVOR_AGENT_VERSION=4.0.0 STVOR_AGENT_SHA256=XYZ 2>/dev/null
eq "неверные ключи — ничего не сделано" "" "$(calls)"

echo "== install: повтор и обновление =="
new_root; echo 4.0.0 > "$FAKE/installed"
out="$(hook install 2>&1)"; rc=$?
eq "та же версия уже стоит — код 0" 0 "$rc"
eq "та же версия уже стоит — ни сети, ни dpkg" "" "$(calls)"
check "та же версия уже стоит — строка" grep -q 'уже установлен' <<< "$out"
new_root; echo 3.1.0 > "$FAKE/installed"
hook install >/dev/null 2>&1; rc=$?
eq "старая версия — ставится пин" "dpkg -i stvor-agent_4.0.0_amd64.deb $SUM_AMD64" "$(installed)"
new_root
PHASE=build hook install >/dev/null 2>&1; rc=$?
eq "фаза build — пакет ставится" "0 dpkg -i stvor-agent_4.0.0_amd64.deb $SUM_AMD64" "$rc $(installed)"

echo "== install: метка stvor_agent подхватывается сразу =="
# cream lays the drop-in before the install hook (spec cream §6.5): the render
# of teleport-apps.path then skips the command — no binary yet. After dpkg -i
# the hook asks teleport-apps.service for a render + reload (no restart).
new_root; mkdir -p "$ROOT/run/systemd/system"
hook install >/dev/null 2>&1; rc=$?
eq "live, systemd — код 0" 0 "$rc"
eq "live, systemd — после dpkg -i неблокирующий start teleport-apps.service" \
    "curl $GH/v4.0.0/stvor-agent_4.0.0_amd64.deb
dpkg -i stvor-agent_4.0.0_amd64.deb $SUM_AMD64
systemctl --no-block start teleport-apps.service" "$(calls)"
new_root; mkdir -p "$ROOT/run/systemd/system"
PHASE=build hook install >/dev/null 2>&1; rc=$?
eq "фаза build — teleport-apps.service не трогается" "0 " "$rc $(grep '^systemctl' "$FAKE/calls")"
new_root
hook install >/dev/null 2>&1; rc=$?
eq "без systemd — teleport-apps.service не трогается" "0 " "$rc $(grep '^systemctl' "$FAKE/calls")"
new_root; mkdir -p "$ROOT/run/systemd/system"; echo 4.0.0 > "$FAKE/installed"
hook install >/dev/null 2>&1; rc=$?
eq "та же версия уже стоит — teleport-apps.service не трогается" "0 " "$rc $(calls)"
new_root; mkdir -p "$ROOT/run/systemd/system"; echo 3.1.0 > "$FAKE/installed"
hook upgrade CREAM_PREV_VERSION=3.1.0 >/dev/null 2>&1; rc=$?
eq "upgrade, systemd — тоже reload меток" "0 systemctl --no-block start teleport-apps.service" \
    "$rc $(grep '^systemctl' "$FAKE/calls")"
new_root; mkdir -p "$ROOT/run/systemd/system"
printf 'not the package\n' > "$FAKE/deb-amd64"
hook install >/dev/null 2>&1
eq "сумма не та — teleport-apps.service не трогается" "" "$(grep '^systemctl' "$FAKE/calls")"

echo "== upgrade =="
new_root; echo 3.1.0 > "$FAKE/installed"
hook upgrade CREAM_PREV_VERSION=3.1.0 >/dev/null 2>&1; rc=$?
eq "upgrade — код 0" 0 "$rc"
eq "upgrade — новый пакет тем же путём" "curl $GH/v4.0.0/stvor-agent_4.0.0_amd64.deb
dpkg -i stvor-agent_4.0.0_amd64.deb $SUM_AMD64" "$(calls)"
new_root; echo 4.0.0 > "$FAKE/installed"
hook upgrade CREAM_PREV_VERSION=4.0.0 >/dev/null 2>&1; rc=$?
eq "upgrade без новой версии агента — ничего" "0 " "$rc $(calls)"
new_root
check_not "upgrade с неполной парой — отказ" hook upgrade STVOR_AGENT_VERSION=4.0.1 2>/dev/null

echo "== remove =="
new_root; echo 4.0.0 > "$FAKE/installed"
hook remove >/dev/null 2>&1; rc=$?
eq "remove — код 0" 0 "$rc"
eq "remove — disable, затем dpkg -r" "stvor-agent disable
dpkg -r stvor-agent" "$(calls)"
new_root
hook remove >/dev/null 2>&1; rc=$?
eq "remove без пакета — код 0, ничего" "0 " "$rc $(calls)"
new_root; echo 4.0.0 > "$FAKE/installed"; touch "$FAKE/disable-fails"
out="$(hook remove 2>&1)"; rc=$?
check "disable не прошёл — отказ" test "$rc" -ne 0
eq "disable не прошёл — пакет не снят" "" "$(installed)"

echo "== apply =="
new_root; mkdir -p "$ROOT/run/systemd/system"
hook apply CREAM_CHANGED_KEYS=STVOR_AGENT_INTERVAL >/dev/null 2>&1; rc=$?
eq "apply — код 0" 0 "$rc"
eq "apply — неблокирующий try-restart" "systemctl --no-block try-restart stvor-agent.service" "$(calls)"
new_root
hook apply >/dev/null 2>&1; rc=$?
eq "apply без systemd — код 0, ничего" "0 " "$rc $(calls)"
new_root; mkdir -p "$ROOT/run/systemd/system"
PHASE=build hook apply >/dev/null 2>&1; rc=$?
eq "apply в фазе build — ничего" "0 " "$rc $(calls)"

echo "== токен меток не уходит в dpkg и stvor-agent =="
# The token is on disk (enabled agent) and, as a canary, in the caller's
# environment: the hooks hand children a minimal environment of their own.
for scenario in install upgrade remove; do
    new_root
    [[ "$scenario" == remove ]] && echo 4.0.0 > "$FAKE/installed"
    hook "$scenario" STVOR_AGENT_TOKEN="$TOKEN" LABEL_TOKEN="$TOKEN" >/dev/null 2>&1
    check "$scenario: фейки вызывались" test -s "$FAKE/calls"
    check_not "$scenario: токена нет в argv/окружении curl, dpkg, stvor-agent" token_leaked
done
new_root
hook install STVOR_AGENT_TOKEN="$TOKEN" >/dev/null 2>&1
check_not "dpkg получает чистое окружение (без ключей домена)" grep -q '^STVOR_AGENT_' "$FAKE/dpkg.env"
check "файл токена хук не трогал" grep -qF "token=$TOKEN" "$ROOT/etc/stvor-agent/token"

# ===========================================================================
echo "== drop-in командной метки настоящим cream =="
cream_deb=""
if [[ -n "${CREAM_DEB:-}" ]]; then
    cream_deb="$CREAM_DEB"
else
    pv="$(grep -E '^CREAM_VERSION=' "$HERE/cream-pin.env" | tail -n1 | cut -d= -f2-)"
    ps="$(grep -E '^CREAM_SHA256=' "$HERE/cream-pin.env" | tail -n1 | cut -d= -f2-)"
    cached="$REPO/.cache/cream/cream_${pv}_amd64.deb"
    if [[ -n "$pv" && -f "$cached" ]] && echo "$ps  $cached" | sha256sum -c --status - 2>/dev/null; then
        cream_deb="$cached"
    fi
fi
if [[ -z "$cream_deb" || ! -f "$cream_deb" ]] || ! command -v docker >/dev/null 2>&1 \
   || ! docker info >/dev/null 2>&1; then
    echo "ПРОПУЩЕНО: drop-in живьём — нет cream (CREAM_DEB или кеш пина) или docker; проверен манифест" >&3
else
    # A catalog: a stub `teleport` 4.0.0 (the dependency) and this extension.
    CAT="$TMP/cat"
    mkdir -p "$CAT/extensions/teleport/hooks"
    printf 'schema: cream/v1\nname: cat\nversion: 0.0.0\nroots: [extensions]\n' > "$CAT/cream-catalog.yaml"
    cat > "$CAT/extensions/teleport/extension.yaml" <<'EOF'
schema: cream/v1
name: teleport
version: 4.0.0
summary: заглушка teleport для теста обёртки stvor-agent
cream: ">=1.0.0"
platform: {family: deb, arch: [amd64, arm64]}
hooks:
  install: {}
  remove: {}
EOF
    printf '#!/bin/sh\nexit 0\n' > "$CAT/extensions/teleport/hooks/install"
    cp "$CAT/extensions/teleport/hooks/install" "$CAT/extensions/teleport/hooks/remove"
    chmod +x "$CAT/extensions/teleport/hooks/"*
    cp -a "$EXT" "$CAT/extensions/stvor-agent"
    # The container: a real .deb stvor-agent 4.0.0 whose binary logs its
    # calls; cream installs teleport, then stvor-agent from that .deb with
    # explicit version and sum; then removes stvor-agent.
    inner='set -u
dpkg-deb -x /cream.deb /tmp/creamx && install -m 0755 /tmp/creamx/usr/bin/cream /usr/bin/cream
cp -a /src /tmp/cat
d=/tmp/pkg; mkdir -p $d/DEBIAN $d/usr/bin
printf "Package: stvor-agent\nVersion: 4.0.0\nArchitecture: amd64\nMaintainer: test <t@example.org>\nDescription: fake\n" > $d/DEBIAN/control
printf "#!/bin/sh\necho \"\$*\" >> /tmp/stvor-agent.calls\n" > $d/usr/bin/stvor-agent; chmod 0755 $d/usr/bin/stvor-agent
dpkg-deb --root-owner-group -b $d /tmp/stvor-agent_4.0.0_amd64.deb >/dev/null
sum=$(sha256sum /tmp/stvor-agent_4.0.0_amd64.deb | cut -d" " -f1)
r(){ "$@" >/tmp/out 2>&1; c=$?; [ $c -eq 0 ] || { echo "--- $* -> $c"; cat /tmp/out; }; return $c; }
res(){ if [ "$1" = 0 ]; then echo "CHECK ok $2"; else echo "CHECK fail $2"; fi; }
r cream system init; res $? "cream system init"
r cream source add dev --path /tmp/cat --sync; res $? "cream source add --sync"
r cream install teleport; res $? "cream install teleport"
r cream install stvor-agent STVOR_AGENT_DEB=/tmp/stvor-agent_4.0.0_amd64.deb STVOR_AGENT_VERSION=4.0.0 STVOR_AGENT_SHA256=$sum
res $? "cream install stvor-agent"
f=/etc/cream/teleport/command-labels.d/stvor_agent
[ "$(cat $f 2>/dev/null)" = "command=/usr/bin/stvor-agent version --label" ]; res $? "drop-in на месте после install"
[ "$(stat -c %a $f 2>/dev/null)" = 644 ]; res $? "drop-in 0644"
[ "$(dpkg-query -W -f="\${Status}" stvor-agent 2>/dev/null)" = "install ok installed" ]; res $? "пакет установлен"
r cream install stvor-agent STVOR_AGENT_DEB=/tmp/stvor-agent_4.0.0_amd64.deb STVOR_AGENT_VERSION=4.0.0 STVOR_AGENT_SHA256=$sum
res $? "повтор install — код 0"
r cream set stvor-agent STVOR_AGENT_INTERVAL=120; res $? "cream set интервала"
grep -qx STVOR_AGENT_INTERVAL=120 /etc/cream/stvor-agent/config; res $? "интервал в /etc/cream/stvor-agent/config"
r cream set stvor-agent STVOR_AGENT_INTERVAL=30; [ $? -ne 0 ]; res $? "интервал 30 — отказ cream"
r cream set stvor-agent STVOR_AGENT_VERSION=4.0.1; [ $? -ne 0 ]; res $? "ключ scope: install через set — отказ cream"
r cream remove teleport; [ $? -ne 0 ]; res $? "remove teleport при установленной обёртке — отказ"
r cream remove stvor-agent; res $? "cream remove stvor-agent"
[ ! -e $f ]; res $? "drop-in убран remove"
grep -qx disable /tmp/stvor-agent.calls; res $? "remove звал stvor-agent disable"
! dpkg-query -W -f="\${Status}" stvor-agent 2>/dev/null | grep -q "^install ok installed"; res $? "пакет снят"
true'
    out="$(docker run --rm --network none -v "$cream_deb:/cream.deb:ro" -v "$CAT:/src:ro" \
        debian:12 sh -c "$inner" 2>&1)"
    n=0
    while IFS= read -r line; do
        case "$line" in
            "CHECK ok "*) ok; n=$((n + 1)) ;;
            "CHECK fail "*) bad "cream: ${line#CHECK fail }"; n=$((n + 1)) ;;
        esac
    done <<< "$out"
    eq "cream: все проверки контейнера отработали" 17 "$n"
    if (( fail )); then
        printf '%s\n' "$out" | grep -v '^CHECK ok ' >&3
    fi
fi

echo
echo "проверок: $((pass + fail)), не прошло: $fail"
(( fail == 0 ))
