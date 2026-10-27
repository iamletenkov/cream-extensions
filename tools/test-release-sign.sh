#!/usr/bin/env bash
# Тесты tools/release-sign.sh: BUILDINFO.json и SHA256SUMS выпуска, отказ
# подписи без секретов. Если есть cosign (COSIGN=<путь> или cosign в PATH) —
# ещё полный круг на одноразовом ключе: подпись, проверка без сети (cosign и
# openssl), отказ на подменённом SHA256SUMS и на чужом ключе. Без cosign эта
# часть пропускается строкой: её гоняет job «Snapshot (dry run)» на PR.
# Рабочее дерево не трогается, root не нужен.
#
#   tools/test-release-sign.sh        код 0 — все проверки прошли

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
S="$HERE/release-sign.sh"

TMP="$(mktemp -d)"
trap 'rm -r -f -- "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&2; }
check(){ local what="$1"; shift; if "$@"; then ok; else bad "$what"; fi; }
eq(){ local what="$1" want="$2" got="$3"; if [[ "$want" == "$got" ]]; then ok; else bad "$what: ждали [$want], получили [$got]"; fi; }
run(){ OUT="$("$@" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"; }

# Подменённый снимок версии $1 в новом каталоге; путь — в D.
new_dist(){
    D="$(mktemp -d "$TMP/dist.XXXXXX")"
    printf 'snapshot %s\n' "$1" > "$D/cream-extensions-$1.tar.gz"
    (cd "$D" && sha256sum "cream-extensions-$1.tar.gz" > SHA256SUMS)
}
bi(){ jq -r "$1" "$D/BUILDINFO.json"; }

echo "== buildinfo: BUILDINFO.json и SHA256SUMS из двух строк =="
new_dist 1.2.3
run env -u GITHUB_RUN_ID "$S" buildinfo "$D" v1.2.3
eq "код" 0 "$RC"
eq "tag" v1.2.3 "$(bi .tag)"
eq "version" 1.2.3 "$(bi .version)"
eq "commit" "$(git -C "$REPO" rev-parse HEAD)" "$(bi .commit)"
eq "source_date_epoch" "$(git -C "$REPO" log -1 --format=%ct HEAD)" "$(bi .source_date_epoch)"
check "time — ISO UTC" grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' <<<"$(bi .time)"
eq "сумма снимка" "$(sha256sum "$D/cream-extensions-1.2.3.tar.gz" | cut -d' ' -f1)" "$(bi '.files["cream-extensions-1.2.3.tar.gz"]')"
eq "пин cream" "$(sed -n 's/^CREAM_VERSION=//p' "$REPO/tools/cream-pin.env")" "$(bi .snapshot.cream.version)"
eq "run без GITHUB_RUN_ID пуст" "" "$(bi .run)"
eq "строк в SHA256SUMS" 2 "$(wc -l < "$D/SHA256SUMS")"
eq "файлы SHA256SUMS" "cream-extensions-1.2.3.tar.gz BUILDINFO.json" "$(awk '{print $2}' "$D/SHA256SUMS" | tr '\n' ' ' | sed 's/ $//')"
check "sha256sum -c" bash -c "cd '$D' && sha256sum -c --quiet SHA256SUMS"

echo "== buildinfo: повтор на том же коммите — те же байты =="
cp "$D/SHA256SUMS" "$TMP/sums.1"
(cd "$D" && sha256sum cream-extensions-1.2.3.tar.gz > SHA256SUMS && rm BUILDINFO.json)
run env -u GITHUB_RUN_ID "$S" buildinfo "$D" v1.2.3
eq "код" 0 "$RC"
check "SHA256SUMS тот же" cmp -s "$TMP/sums.1" "$D/SHA256SUMS"

echo "== buildinfo: run из окружения Actions =="
new_dist 1.2.3
run env GITHUB_RUN_ID=42 GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/r "$S" buildinfo "$D" v1.2.3
eq "код" 0 "$RC"
eq "run" https://github.com/o/r/actions/runs/42 "$(bi .run)"

echo "== buildinfo: отказы =="
new_dist 1.2.3
run "$S" buildinfo "$D" v1.2.4
eq "версия не та: код" 1 "$RC"
check "версия не та: причина" grep -q "не совпала с тегом" <<<"$ERR"
check "версия не та: BUILDINFO нет" test ! -e "$D/BUILDINFO.json"
run "$S" buildinfo "$D" 1.2.3
eq "тег без v: код" 1 "$RC"
new_dist 1.2.3
printf 'x' >> "$D/cream-extensions-1.2.3.tar.gz"
run "$S" buildinfo "$D" v1.2.3
eq "снимок не совпал с суммой: код" 1 "$RC"
new_dist 1.2.3
printf 'x' > "$D/cream-extensions-9.9.9.tar.gz"
run "$S" buildinfo "$D" v1.2.3
eq "два снимка: код" 1 "$RC"

echo "== sign без секретов — отказ, подписи нет =="
new_dist 1.2.3
run env -u COSIGN_PRIVATE_KEY -u COSIGN_PASSWORD "$S" sign "$D"
eq "нет ключа: код" 1 "$RC"
check "нет ключа: причина" grep -q "нет секрета COSIGN_PRIVATE_KEY" <<<"$ERR"
check "нет ключа: .sig нет" test ! -e "$D/SHA256SUMS.sig"
run env -u COSIGN_PASSWORD COSIGN_PRIVATE_KEY=x "$S" sign "$D"
eq "нет пароля: код" 1 "$RC"
check "нет пароля: причина" grep -q "нет секрета COSIGN_PASSWORD" <<<"$ERR"

echo "== подпись и проверка без сети на одноразовом ключе =="
COSIGN_BIN="$(command -v "${COSIGN:-cosign}" 2>/dev/null || true)"
if [[ -z "$COSIGN_BIN" ]]; then
    echo "пропуск: нет cosign (COSIGN=<путь>) — полный круг гоняет job Snapshot (dry run)"
else
    K="$TMP/key"; mkdir -p "$K"
    (cd "$K" && COSIGN_PASSWORD=test-only "$COSIGN_BIN" generate-key-pair >/dev/null 2>&1)
    check "ключ создан" test -s "$K/cosign.key"
    new_dist 1.2.3
    "$S" buildinfo "$D" v1.2.3 >/dev/null
    run env COSIGN="$COSIGN_BIN" COSIGN_PRIVATE_KEY="$(cat "$K/cosign.key")" COSIGN_PASSWORD=test-only "$S" sign "$D"
    eq "sign: код" 0 "$RC"
    [[ "$RC" == 0 ]] || echo "$ERR" >&2
    check ".sig — base64 DER" bash -c "base64 -d '$D/SHA256SUMS.sig' | openssl asn1parse -inform DER >/dev/null"
    check "bundle — JSON" jq -e '.mediaType | startswith("application/vnd.dev.sigstore.bundle")' "$D/SHA256SUMS.bundle.json" >/dev/null
    run env COSIGN="$COSIGN_BIN" "$S" verify "$D" "$K/cosign.pub"
    eq "verify: код" 0 "$RC"
    [[ "$RC" == 0 ]] || echo "$ERR" >&2
    run env COSIGN="$COSIGN_BIN" "$S" verify "$D" "$REPO/release/keys/stvor-platform.pub"
    eq "чужой ключ: код" 1 "$RC"
    cp "$D/SHA256SUMS" "$TMP/sums.ok"
    echo "0000000000000000000000000000000000000000000000000000000000000000  extra" >> "$D/SHA256SUMS"
    run env COSIGN="$COSIGN_BIN" "$S" verify "$D" "$K/cosign.pub"
    eq "подменённый SHA256SUMS: код" 1 "$RC"
fi

echo "== ключи в release/keys — PEM P-256 =="
for k in stvor-platform stvor-platform-next; do
    check "$k.pub" bash -c "openssl pkey -pubin -in '$REPO/release/keys/$k.pub' -noout -text | grep -q 'P-256\|prime256v1'"
done

echo "test-release-sign: пройдено $pass, упало $fail"
(( fail == 0 ))
