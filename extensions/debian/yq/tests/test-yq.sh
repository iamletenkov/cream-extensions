#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the yq extension (cream/v1): manifest and catalog pin, hooks install
# and remove on a scratch root (CREAM_ROOT) the way cream runs them, with fake
# dpkg and curl. The "binary" is a fake script: what is checked is where it
# comes from, that it is verified by sha256 before use, where it lands and that
# remove takes only what install put. root and network are not needed.
#
#   extensions/debian/yq/tests/test-yq.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

GH=https://github.com/mikefarah/yq/releases/download
PIN_V="$(sed -n 's/^YQ_PIN_VERSION=//p' "$EXT/files/pin.env" 2>/dev/null)"

# payload <file> <version> <flavour>: a fake yq binary answering --version.
payload() {
    local who=mikefarah
    [[ "$3" == kislyuk ]] && who=kislyuk
    printf '#!/usr/bin/env bash\necho "yq (https://github.com/%s/yq/) version %s"\n' "$who" "$2" > "$1"
    chmod 0755 "$1"
}
sha() { sha256sum "$1" | cut -d' ' -f1; }

# yq_root [arch]: fresh root; dpkg prints the arch; curl serves $FAKE/dl-<arch>
# (fails when $FAKE/curl-fails exists); the pin of the copy is rewritten to the
# sha256 of the fake payloads.
yq_root() {
    local arch="${1:-amd64}"
    ht_root "$EXT"
    echo "$arch" > "$FAKE/arch"
    ht_fake dpkg '[[ "$1" == --print-architecture ]] && cat "$FAKE/arch"'
    ht_fake curl '
out=""; url=""
while (( $# )); do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --retry|--retry-delay|--connect-timeout|--proto|--max-redirs) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
[[ -f "$FAKE/curl-fails" ]] && exit 22
cp "$FAKE/dl-${url##*_}" "$out"'
    payload "$FAKE/dl-amd64" "$PIN_V" mikefarah
    payload "$FAKE/dl-arm64" "$PIN_V" mikefarah
    printf '\n# arm64\n' >> "$FAKE/dl-arm64"
    {
        echo "YQ_PIN_VERSION=$PIN_V"
        echo "YQ_PIN_SHA256_AMD64=$(sha "$FAKE/dl-amd64")"
        echo "YQ_PIN_SHA256_ARM64=$(sha "$FAKE/dl-arm64")"
    } > "$HT_EXT/files/pin.env"
    DST="$ROOT/usr/local/bin/yq"
    REC="$ROOT/var/lib/cream/ext/yq/installed"
}
curls() { grep -c '^curl ' "$FAKE/calls"; }

echo "== манифест и пин =="
M="$EXT/extension.yaml"
mf() { python3 -c 'import sys,yaml; m=yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$M" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 2" 2 "$(mf 'm["version"].split(".")[0]')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "хуки install и remove" "install remove" "$(mf '" ".join(sorted(m["hooks"]))')"
eq "default YQ_VERSION = пин каталога" "$PIN_V" "$(mf 'm["config"]["keys"]["YQ_VERSION"]["default"]')"
check "пин: sha256 amd64" grep -Eq '^YQ_PIN_SHA256_AMD64=[0-9a-f]{64}$' "$EXT/files/pin.env"
check "пин: sha256 arm64" grep -Eq '^YQ_PIN_SHA256_ARM64=[0-9a-f]{64}$' "$EXT/files/pin.env"
check "hooks/install исполняемый" test -x "$EXT/hooks/install"
check "hooks/remove исполняемый" test -x "$EXT/hooks/remove"
check_not "install.sh layout 2 не остался" test -e "$EXT/install.sh"

echo "== install: пин каталога, amd64 =="
yq_root amd64
ht_hook install; eq "install — 0" 0 "$?"
check "скачан пин amd64" ht_called "^curl .*$GH/$PIN_V/yq_linux_amd64"
check "бинарь в /usr/local/bin" test -x "$DST"
eq "бинарь — скачанный" "$(sha "$FAKE/dl-amd64")" "$(sha "$DST")"
eq "режим 0755" 755 "$(stat -c %a "$DST")"
eq "запись владения: версия и sha256" "$PIN_V $(sha "$DST")" "$(cat "$REC" 2>/dev/null)"
before="$(stat -c %Y.%i "$DST")"
ht_hook install; eq "повтор install — 0" 0 "$?"
eq "повтор не качает" 1 "$(curls)"
eq "повтор не трогает бинарь" "$before" "$(stat -c %Y.%i "$DST")"

echo "== install: arm64 и чужая архитектура =="
yq_root arm64
ht_hook install; eq "arm64 — 0" 0 "$?"
check "скачан пин arm64" ht_called "^curl .*$GH/$PIN_V/yq_linux_arm64"
eq "бинарь arm64" "$(sha "$FAKE/dl-arm64")" "$(sha "$DST")"
yq_root i386
ht_hook install; eq "i386 — 1" 1 "$?"
eq "i386 — не качает" 0 "$(curls)"

echo "== install: sha256 не совпал, сбой сети =="
yq_root
echo tampered >> "$FAKE/dl-amd64"
ht_hook install; eq "подмена — 1" 1 "$?"
check_not "подмена — бинаря нет" test -e "$DST"
check_not "подмена — записи нет" test -e "$REC"
check "подмена — сказано про sha256" grep -q sha256 <<< "$(ht_out)"
check_not "подмена — временных файлов нет" compgen -G "$ROOT/usr/local/bin/.yq*"
yq_root
: > "$FAKE/curl-fails"
ht_hook install; eq "сбой сети — 1" 1 "$?"
check_not "сбой сети — бинаря нет" test -e "$DST"

echo "== install: своя версия =="
yq_root
ht_hook install YQ_VERSION=v4.44.3; eq "версия без YQ_SHA256 — 1" 1 "$?"
eq "версия без YQ_SHA256 — не качает" 0 "$(curls)"
payload "$FAKE/dl-amd64" v4.44.3 mikefarah
ht_hook install YQ_VERSION=v4.44.3 "YQ_SHA256=$(sha "$FAKE/dl-amd64")"; eq "версия с YQ_SHA256 — 0" 0 "$?"
check "скачана своя версия" ht_called "^curl .*$GH/v4.44.3/yq_linux_amd64"
eq "запись — своя версия" "v4.44.3 $(sha "$DST")" "$(cat "$REC")"
payload "$FAKE/dl-amd64" "$PIN_V" mikefarah
ht_hook install; eq "своя → пин: заменяет свой бинарь" 0 "$?"
eq "запись — пин" "$PIN_V $(sha "$FAKE/dl-amd64")" "$(cat "$REC")"

echo "== install: чужой yq =="
yq_root
mkdir -p "$ROOT/usr/local/bin"
payload "$DST" v4.30.0 mikefarah
foreign="$(sha "$DST")"
ht_hook install; eq "чужой mikefarah в /usr/local/bin — 0" 0 "$?"
eq "чужой не перезаписан" "$foreign" "$(sha "$DST")"
eq "чужой — не качает" 0 "$(curls)"
check_not "чужой — записи владения нет" test -e "$REC"
yq_root
mkdir -p "$ROOT/usr/bin"
payload "$ROOT/usr/bin/yq" v4.40.5 mikefarah
ht_hook install; eq "чужой mikefarah в /usr/bin — 0" 0 "$?"
check_not "чужой в /usr/bin — свой не ставится" test -e "$DST"
yq_root
mkdir -p "$ROOT/usr/bin"
payload "$ROOT/usr/bin/yq" 3.4.3 kislyuk
ht_hook install; eq "kislyuk в /usr/bin — 0" 0 "$?"
check "kislyuk — свой ставится в /usr/local/bin" test -x "$DST"
check "kislyuk — предупреждение" grep -q kislyuk <<< "$(ht_out)"
check "kislyuk — пакет не тронут" test -x "$ROOT/usr/bin/yq"

echo "== remove =="
yq_root
ht_hook install; eq "install перед remove — 0" 0 "$?"
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "remove — свой бинарь снят" test -e "$DST"
check_not "remove — запись снята" test -e "$REC"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
yq_root
ht_hook install
echo '# local edit' >> "$DST"
ht_hook remove; eq "remove изменённого — 0" 0 "$?"
check "изменённый бинарь оставлен" test -e "$DST"
check "изменённый — предупреждение" grep -qi 'изменён' <<< "$(ht_out)"
check_not "изменённый — запись снята" test -e "$REC"
yq_root
mkdir -p "$ROOT/usr/local/bin"
payload "$DST" v4.30.0 mikefarah
ht_hook remove; eq "remove без записи — 0" 0 "$?"
check "чужой бинарь не снят" test -e "$DST"

ht_done
