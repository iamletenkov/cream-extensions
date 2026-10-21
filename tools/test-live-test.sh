#!/usr/bin/env bash
# Самопроверка L-раннера tools/live-test.sh на фикстурах
# tools/testdata/live/extensions/debian: верное расширение — зелёное, каждое
# нарушение — красное своей проверкой (сбой install, код 20 без --expect-skip,
# --expect-skip у применимого, упавший юнит после загрузки,
# неидемпотентный --reinstall, секрет в журнале, цикл порядка), код 20 install
# с --expect-skip — зелёный (skipped); зависимость с кодом 20 — «пропущена (skipped)»,
# упавшая зависимость — красная с кодом cream; configure с every_boot и кодом 20 на
# загрузке — зелёный (cream ≥ 1.2.0: «пропущено», юнит успешен, спека cream §10.8). LIVE_FAILED_IGNORE: разрешённый юнит —
# зелёный с пометкой «разрешено упасть», юнит не из списка — красный, выражение без
# якорей ^…$ — отказ (код 2). Две загрузки (cream 1.2.0, отметка configure):
# хук без every_boot пропущен по отметке на обеих, с every_boot — отработал на обеих;
# хук без every_boot, прошедший на загрузке мимо отметки, — красный. Плюс приёмка плана: настоящее расширение
# stvor-agent (с teleport) — LIVE_REAL=1 (сеть: тарбол Teleport, .deb агента).
#
# Тяжёлая (контейнеры с systemd): не входит в make ci; цель make test-live-self.
# Нужны docker и cream по пину (tools/cream-deb.sh; локально — CREAM_DEB=<.deb>).
#
#   tools/test-live-test.sh [debian-12|ubuntu-24.04|…]   код 0 — все проверки прошли
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
CAT="$HERE/testdata/live"
DISTRO="${1:-${DISTRO:-debian-12}}"
LOGS="$REPO/.scratchpad/live/selftest-$DISTRO"

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&2; }
cleanup(){ docker image rm "cream-live:$DISTRO" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# run <case> <want code> <want lines> <live-test args…>: one run of the runner,
# its code and lines of its report (fixed strings, separated by «|»).
run(){
    local name="$1" want="$2" line="$3"; shift 3
    local out rc want_lines
    out="$(LIVE_LOGDIR="$LOGS/$name" "$HERE/live-test.sh" --distro "$DISTRO" --keep-image \
        --catalog "$CAT" "$@" 2>&1)"; rc=$?
    printf '%s\n' "$out" > "$LOGS/$name.out"
    local got=1 l
    IFS='|' read -r -a want_lines <<< "$line"
    for l in "${want_lines[@]}"; do grep -qF -- "$l" <<< "$out" || got=0; done
    if [[ "$rc" == "$want" ]] && (( got )); then
        ok; echo "ok   $name: код $rc, «$line»"
    else
        bad "$name: ждали код $want и «$line», получили код $rc ($LOGS/$name.out):"
        tail -n 15 <<< "$out" | sed 's/^/    /' >&2
    fi
}

mkdir -p "$LOGS"
run ok 0 "проверок 19, не прошло 0|ok   загрузка: configure пропущен по отметке|ok   вторая загрузка: configure пропущен по отметке" \
    --secret LIVE_OK_TOKEN live-ok
run every-boot 0 "ok   загрузка: configure отработал (every_boot)|ok   вторая загрузка: configure отработал (every_boot)" \
    live-every-boot
run mark-stale 1 "FAIL загрузка: configure шёл на загрузке без every_boot" live-mark-stale
run install-fails 1 "FAIL install: код" live-fail
run skip-expected 0 "ok   install: хук вернул 20, status: skipped (--expect-skip)" --expect-skip live-skip
run skip-unexpected 1 "нужен --expect-skip" live-skip
run skip-but-installed 1 "ждали код 20 хука install" --expect-skip live-ok
run dep-skipped 0 "ok   зависимость live-skip пропущена (skipped)" --secret LIVE_OK_TOKEN --deps live-skip live-ok
run dep-fails 1 "FAIL зависимость live-fail: cream install — код 79" --deps live-fail live-ok
run unit-failed 1 "FAIL загрузка: после перезапуска есть упавшие юниты" live-unit-failed
run unit-allowed 0 "разрешено упасть: live-unit-allowed.service" live-unit-allowed
run unit-not-listed 1 "FAIL загрузка: после перезапуска есть упавшие юниты" \
    --failed-ignore '^other\.service$' live-unit-failed
run ignore-unanchored 2 "LIVE_FAILED_IGNORE" --failed-ignore 'live-unit-failed\.service' live-unit-failed
run configure-20 0 "ok   загрузка: configure вернул 20|ok   вторая загрузка: configure вернул 20" \
    live-configure-20
run not-idempotent 1 "FAIL --reinstall изменил файлы" live-nonidem
run secret-leak 1 "FAIL после install: секрет LIVE_LEAK_TOKEN виден: журнал" --secret LIVE_LEAK_TOKEN live-leak
run ordering-cycle 1 "FAIL загрузка: «ordering cycle» в журнале или systemd-analyze" live-cycle
run unknown 2 "нет (или не одно)" live-nope
run bad-distro 2 "неизвестный дистрибутив" --distro debian-11 live-ok

if [[ "${LIVE_REAL:-}" == 1 ]]; then
    out="$(LIVE_LOGDIR="$LOGS/stvor-agent" "$HERE/live-test.sh" --distro "$DISTRO" --keep-image \
        stvor-agent 2>&1)"; rc=$?
    printf '%s\n' "$out" > "$LOGS/stvor-agent.out"
    if (( rc == 0 )); then ok; echo "ok   stvor-agent (настоящее расширение): зелёное"
    else bad "stvor-agent: код $rc ($LOGS/stvor-agent.out)"; tail -n 20 <<< "$out" >&2; fi
fi

echo "проверок: $((pass + fail)), не прошло: $fail"
(( fail == 0 ))
