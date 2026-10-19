#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the firewall extension (cream/v1): the backend choice by the module
# lists of a kernel (backend.sh), the manifest, hooks install, configure and
# remove and actions status, reload, check on a scratch root (CREAM_ROOT) the
# way cream runs them — with fake nft, iptables-legacy*, apt-get, systemctl and
# uname. No root, no kernel, no network. Real rules in a real kernel — the live
# run (tests/live.env, make test-live EXT=firewall).
#
#   extensions/debian/firewall/tests/test-firewall.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init
T="$HT_TMP/k"

# kernel DIR MODULE...: a module tree whose modules.dep lists MODULE…;
# a module written as +name goes to modules.builtin instead.
kernel() {
    local d="$1" m
    shift
    mkdir -p "$d"
    : > "$d/modules.dep"; : > "$d/modules.builtin"; : > "$d/modules.order"
    for m in "$@"; do
        if [[ "$m" == +* ]]; then
            echo "kernel/net/netfilter/${m#+}.ko" >> "$d/modules.builtin"
        else
            echo "kernel/net/netfilter/$m.ko.zst: kernel/net/netfilter/x_tables.ko.zst" >> "$d/modules.dep"
        fi
    done
}
LEGACY=(ip_tables iptable_filter ip6_tables ip6table_filter nf_conntrack xt_conntrack xt_tcpudp)
# The stock L4T r36.4.3 kernel as measured: nf_tables and all legacy modules,
# no nft_ct, nft_compat, nft_counter.
kernel "$T/l4t" nf_tables "${LEGACY[@]}"
kernel "$T/full" nf_tables nft_ct nft_compat "${LEGACY[@]}"
kernel "$T/builtin" +nf_tables +nft_ct
kernel "$T/none" nf_tables nf_conntrack
kernel "$T/nov6" nf_tables ip_tables iptable_filter nf_conntrack xt_conntrack xt_tcpudp

pick() { bash -c '. "$0/backend.sh"; fw_pick "$1" "$2"' "$EXT" "$@" 2>/dev/null; }
why()  { bash -c '. "$0/backend.sh"; fw_pick "$1" "$2" >/dev/null; echo "$FW_PICK_WHY"' "$EXT" "$@"; }
has() { [[ "$2" == *"$1"* ]]; }

# == backend.sh: the choice by the module lists ==============================
eq "L4T: auto → iptables" iptables "$(pick auto "$T/l4t")"
check_not "L4T: nft — отказ" pick nft "$T/l4t"
check "…и причина называет nft_ct" has nft_ct "$(why nft "$T/l4t")"
eq "L4T: iptables → iptables" iptables "$(pick iptables "$T/l4t")"
eq "полное ядро: auto → nft" nft "$(pick auto "$T/full")"
eq "полное ядро: iptables → iptables" iptables "$(pick iptables "$T/full")"
eq "встроенные nf_tables, nft_ct → nft" nft "$(pick auto "$T/builtin")"
check_not "встроенные nft, без legacy: iptables — отказ" pick iptables "$T/builtin"
check_not "ни nft_ct, ни legacy — отказ" pick auto "$T/none"
check "…причина называет оба набора" has ip_tables "$(why auto "$T/none")"
check_not "без ip6_tables — iptables отказ" pick auto "$T/nov6"
check_not "неизвестное значение — отказ" pick pf "$T/full"
check_not "нет каталога ядра — отказ" pick auto "$T/missing"

# == manifest =================================================================
# man EXPR: a Python expression over the manifest m. EXPR is always a literal
# of this test, never outside input — hence eval.
man() {
    python3 - "$EXT/extension.yaml" "$1" <<'PY'
import sys, yaml
m = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
v = eval(sys.argv[2], {}, {"m": m})
print(v if not isinstance(v, (list, dict)) else yaml.safe_dump(v, default_flow_style=True).strip())
PY
}
eq "schema" cream/v1 "$(man 'm["schema"]')"
eq "мажор версии — 2" 2 "$(man 'm["version"].split(".")[0]')"
eq "cream >= 1.1.0 (стадия early)" ">=1.1.0" "$(man 'm["cream"]')"
eq "configure: стадия early" early "$(man 'm["hooks"]["configure"]["stage"]')"
eq "configure: после nftables.service" "[nftables.service]" "$(man 'm["hooks"]["configure"].get("after")')"
eq "живая установка — confirm" confirm "$(man 'm["targets"]["live"]')"
check "live_note называет SSH" has SSH "$(man 'm["targets"].get("live_note", "")')"
eq "хуки: install, configure, remove (apply — перезапуск configure)" "[configure, install, remove]" \
    "$(man 'sorted(m["hooks"])')"
eq "status — lock none" none "$(man 'm["actions"]["status"]["lock"]')"
eq "check — lock none" none "$(man 'm["actions"]["check"]["lock"]')"
eq "reload — lock exclusive" exclusive "$(man 'm["actions"]["reload"]["lock"]')"
eq "SSH открыт по умолчанию: FIREWALL_SSH_PORTS=22" 22 "$(man 'm["config"]["keys"]["FIREWALL_SSH_PORTS"]["default"]')"
eq "provides host-firewall" "[host-firewall]" "$(man 'm["provides"]')"
for f in hooks/install hooks/configure hooks/remove actions/status actions/reload actions/check; do
    check "$f исполняемый" test -x "$EXT/$f"
done
check_not "hooks/apply нет (§8.4: apply — перезапуск configure)" test -e "$EXT/hooks/apply"

# == the scratch root =========================================================
# fw_root [kernel]: fresh root; the running kernel is 6.1.0-test with the module
# lists of $T/<kernel> (none — no lists, as in a container); fakes of nft,
# iptables-legacy*, uname, apt-get, systemctl. Kernel state lives in $FAKE:
#   nft-table      the table inet cream exists;  nft-loaded — last ruleset loaded
#   ipt4/ipt6-*    the legacy restore input loaded, the INPUT jump
fw_root() {
    ht_root "$EXT"
    if [[ -n "${1:-}" ]]; then
        mkdir -p "$ROOT/lib/modules"
        cp -a "$T/$1" "$ROOT/lib/modules/6.1.0-test"
    fi
    mkdir -p "$ROOT/proc/net"
    RD="$ROOT/etc/cream/firewall/rules.d"
    STATE="$ROOT/var/lib/cream/ext/firewall"
    RUN="$ROOT/run/firewall"
    mkdir -p "$RD"
    cp "$EXT"/rules.d/10-defaults.* "$RD/"
    ht_fake uname 'echo 6.1.0-test'
    ht_fake apt-get
    ht_fake systemctl 'exit 1'
    # nft: -f loads (fails when an included file says "nonsense"), -c -f checks.
    ht_fake nft '
incl() { sed -n "s/^include \"\(.*\)\"$/\1/p" "$1" | xargs -r cat; cat "$1"; }
case "$*" in
    "list table inet cream") [[ -e "$FAKE/nft-table" ]] && echo "table inet cream { }" ;;
    "delete table inet cream") [[ -e "$FAKE/nft-table" ]] && rm -f "$FAKE/nft-table" ;;
    "-c -f "*) ! incl "$3" | grep -q nonsense ;;
    "-f "*) incl "$2" | grep -q nonsense && { echo "$2:3: Error: syntax error" >&2; exit 1; }
            cp "$2" "$FAKE/nft-loaded"; : > "$FAKE/nft-table" ;;
    *) echo "nft: unexpected $*" >&2; exit 99 ;;
esac'
    # iptables-legacy*: restore --test fails on "nonsense", a load keeps the input
    # in $FAKE/ipt<fam>-loaded and the filter table "appears" in /proc/net.
    local fam cmd names
    for fam in 4 6; do
        if [[ "$fam" == 4 ]]; then cmd=iptables names=ip_tables_names; else cmd=ip6tables names=ip6_tables_names; fi
        ht_fake "$cmd-legacy-restore" '
in="$(cat)"
[[ " $* " == *" --noflush "* ]] || { echo "без --noflush" >&2; exit 98; }
grep -q nonsense <<<"$in" && { echo "line 5 failed" >&2; exit 1; }
[[ " $* " == *" --test "* ]] && exit 0
printf "%s\n" "$in" > "$FAKE/ipt'"$fam"'-loaded"
echo filter > "'"$ROOT/proc/net/$names"'"'
        ht_fake "$cmd-legacy" '
j="$FAKE/ipt'"$fam"'-jump"
case " $* " in
    *" -C INPUT -j CREAM-INPUT "*) [[ -e "$j" ]] ;;
    *" -I INPUT 1 -j CREAM-INPUT "*) : > "$j" ;;
    *" -D INPUT -j CREAM-INPUT "*) [[ -e "$j" ]] && rm -f "$j" ;;
    *" -n -L CREAM-INPUT "*) [[ -e "$FAKE/ipt'"$fam"'-loaded" ]] ;;
    *" -X CREAM-INPUT "*) rm -f "$FAKE/ipt'"$fam"'-loaded" ;;
    *) exit 0 ;;
esac'
    done
}
# Kernel state checks
loaded() { grep -qxF -- "$1" "$FAKE/nft-loaded"; }
v4() { grep -qxF -- "$1" "$FAKE/ipt4-loaded"; }
v6() { grep -qxF -- "$1" "$FAKE/ipt6-loaded"; }
count() { grep -cE -- "$1" "$FAKE/calls"; }

# == configure, nftables ======================================================
fw_root full
ht_hook configure; eq "configure (nft) — 0" 0 "$?"
check "таблица inet cream загружена" test -e "$FAKE/nft-table"
check "…пересоздаётся одной транзакцией" loaded "delete table inet cream"
check "…input: policy drop" grep -q 'type filter hook input priority filter; policy drop;' "$FAKE/nft-loaded"
check "…умолчания включены файлом" loaded "include \"$RD/10-defaults.nft\""
check "SSH открыт по умолчанию (nft)" loaded "add rule inet cream input tcp dport { 22 } accept"
check "…и после файлов правил" test "$(grep -n 'dport { 22 }' "$FAKE/nft-loaded" | cut -d: -f1)" -gt \
    "$(grep -n '^include' "$FAKE/nft-loaded" | tail -1 | cut -d: -f1)"
eq "бэкенд записан" nft "$(cat "$RUN/backend")"
check_not "flush ruleset — никогда" ht_called 'flush'
check "умолчания nft — таблица inet cream" grep -q '^add rule inet cream input iif lo accept$' "$EXT/rules.d/10-defaults.nft"

: > "$FAKE/calls"
ht_hook configure; eq "повторный configure — 0" 0 "$?"
eq "…одна загрузка nft" 1 "$(count '^nft -f ')"

ht_hook configure FIREWALL_SSH_PORTS="22 2222"
check "FIREWALL_SSH_PORTS=\"22 2222\"" loaded "add rule inet cream input tcp dport { 22, 2222 } accept"
ht_hook configure FIREWALL_SSH_PORTS=
check_not "FIREWALL_SSH_PORTS пуст — SSH закрыт" grep -q 'dport {' "$FAKE/nft-loaded"
cp "$FAKE/nft-loaded" "$HT_TMP/prev"
: > "$FAKE/calls"
ht_hook configure 'FIREWALL_SSH_PORTS=22;flush ruleset'
check_not "битый FIREWALL_SSH_PORTS — configure не 0" test "$?" -eq 0
eq "…и ничего не загружено" 0 "$(count '^nft -f ')"
check "…таблица прежняя" cmp "$HT_TMP/prev" "$FAKE/nft-loaded"
ht_hook configure FIREWALL_SSH_PORTS=70000
check_not "порт 70000 — отказ" test "$?" -eq 0

# Broken file: the fallback (loopback, replies, SSH) instead of the rules.
echo 'add rule inet cream input tcp dport nonsense accept' > "$RD/70-broken.nft"
ht_hook configure; eq "битый файл — configure 1 (failed-юнит)" 1 "$?"
check "…запасной набор: петля" loaded "add rule inet cream input iif lo accept"
check "…ответы" loaded "add rule inet cream input ct state established,related accept"
check "…и SSH (машину не отрезать)" loaded "add rule inet cream input tcp dport { 22 } accept"
check_not "…без файлов каталога" grep -q '^include' "$FAKE/nft-loaded"
check "…причина в выводе" grep -q 'не загрузились' "$ROOT/out"
rm -f "$RD/70-broken.nft"

: > "$FAKE/calls"
ht_hook configure FIREWALL_ENABLE=0; eq "FIREWALL_ENABLE=0 — 0" 0 "$?"
check_not "…таблица снята" test -e "$FAKE/nft-table"
eq "…снятие — одна команда delete своей таблицы" 1 "$(count '^nft delete table inet cream$')"

# No module lists (a container): the backend picked by the build, else nft.
fw_root
ht_hook configure; eq "без списков модулей — nft" nft "$(cat "$RUN/backend")"
echo iptables > "$STATE/backend"
ht_hook configure; eq "без списков модулей — бэкенд сборки" iptables "$(cat "$RUN/backend")"

# == configure, iptables-legacy ===============================================
fw_root l4t
ht_hook configure; eq "configure (L4T, iptables) — 0" 0 "$?"
eq "бэкенд iptables" iptables "$(cat "$RUN/backend")"
check "IPv4: своя цепочка объявлена" v4 ':CREAM-INPUT - [0:0]'
check "IPv4: петля" v4 '-A CREAM-INPUT -i lo -j ACCEPT'
check "IPv4: established,related" v4 '-A CREAM-INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT'
check "IPv4: UDP 7400–32000 на 127.0.0.1" v4 '-A CREAM-INPUT -d 127.0.0.1/32 -p udp -m udp --dport 7400:32000 -j ACCEPT'
check "IPv4: SSH открыт по умолчанию" v4 '-A CREAM-INPUT -p tcp -m tcp --dport 22 -j ACCEPT'
check "IPv6: SSH открыт по умолчанию" v6 '-A CREAM-INPUT -p tcp -m tcp --dport 22 -j ACCEPT'
check "IPv6: обнаружение соседей" v6 '-A CREAM-INPUT -p ipv6-icmp -m icmp6 --icmpv6-type neighbour-solicitation -j ACCEPT'
check_not "IPv6 не получает правил IPv4" grep -q 127.0.0.1 "$FAKE/ipt6-loaded"
eq "IPv4: в конце DROP и COMMIT" $'-A CREAM-INPUT -j DROP\nCOMMIT' "$(tail -2 "$FAKE/ipt4-loaded")"
eq "правила — только своей цепочки" 0 \
    "$(grep -vE '^(\*filter|:CREAM-INPUT - \[0:0\]|-A CREAM-INPUT .*|COMMIT|# .*)$' "$FAKE/ipt4-loaded" "$FAKE/ipt6-loaded" | wc -l)"
eq "переход из INPUT вставлен по разу (v4, v6)" 2 "$(count '-legacy -w -I INPUT 1 -j CREAM-INPUT$')"
: > "$FAKE/calls"
ht_hook configure; eq "повторный configure — 0" 0 "$?"
eq "…переход не дублируется" 0 "$(count '-I INPUT')"
check_not "ничего не сбрасывается целиком (-F/-X без своей цепочки, -P)" \
    grep -qE -- ' -(F|X|P)( [^C]|$)' "$FAKE/calls"

# Own file: short and full form, after the defaults, before DROP.
printf '%s\n' '# ping' '-p icmp --icmp-type echo-request -j ACCEPT' \
    '  -A CREAM-INPUT -p tcp --dport 8000 -j ACCEPT  ' > "$RD/50-own.rules"
ht_hook configure; eq "свой файл — 0" 0 "$?"
check "…краткая форма получила префикс" v4 '-A CREAM-INPUT -p icmp --icmp-type echo-request -j ACCEPT'
check "…полная — как есть" v4 '-A CREAM-INPUT -p tcp --dport 8000 -j ACCEPT'
rm -f "$RD/50-own.rules"

# Format errors: action check, rc 3; nothing loaded by check.
for bad_line in '-A INPUT -p tcp --dport 22 -j ACCEPT' '-I CREAM-INPUT 1 -j ACCEPT' '-F' '-P INPUT ACCEPT' \
                '-X DOCKER' '-N FOO' '*filter' 'COMMIT' ':FOO - [0:0]' '-t nat -A PREROUTING -j ACCEPT' \
                '--flush DOCKER-USER' '--append=INPUT -j ACCEPT' 'tcp dport 22 accept'; do
    printf '%s\n' "$bad_line" > "$RD/60-bad.rules"
    ht_action check; eq "check: отказ формата (rc 3): $bad_line" 3 "$?"
done
check "…причина называет файл и строку" grep -q '60-bad.rules:1' "$ROOT/out"
ht_hook configure; eq "файл с -A INPUT — configure 1" 1 "$?"
check "…запасной набор v4 с SSH" v4 '-A CREAM-INPUT -p tcp -m tcp --dport 22 -j ACCEPT'
check_not "…и без правил файлов" v4 '-A INPUT -p tcp --dport 22 -j ACCEPT'
rm -f "$RD/60-bad.rules"
ht_action check; eq "check по умолчаниям — 0" 0 "$?"

# Switching to nft: our table first, then the legacy chains go.
: > "$FAKE/calls"
ht_hook configure FIREWALL_BACKEND=nft; eq "FIREWALL_BACKEND=nft на L4T (явно) — 0" 0 "$?"
check "…таблица nft" test -e "$FAKE/nft-table"
check "…переход v4 снят" ht_called '^iptables-legacy -w -D INPUT -j CREAM-INPUT$'
check "…цепочка v4 снята" ht_called '^iptables-legacy -w -X CREAM-INPUT$'
check "…сначала таблица, потом снятие цепочек" test "$(grep -n '^nft -f' "$FAKE/calls" | cut -d: -f1)" -lt \
    "$(grep -n -- '-D INPUT' "$FAKE/calls" | head -1 | cut -d: -f1)"

# == actions ==================================================================
ht_action status; eq "status — 0" 0 "$?"
check "status: бэкенд" grep -q '# бэкенд: nft' "$ROOT/out"
check "status: таблица" grep -q 'table inet cream' "$ROOT/out"
check "status: что выберет apply" grep -q 'apply выберет: iptables' "$ROOT/out"
: > "$FAKE/calls"
ht_action reload; eq "reload — 0" 0 "$?"
eq "reload применяет (iptables по ядру L4T)" iptables "$(cat "$RUN/backend")"

# == install ==================================================================
fw_root
mkdir -p "$ROOT/lib/modules"
cp -a "$T/l4t" "$ROOT/lib/modules/5.15.148-tegra"
rm -f "$RD"/*
HT_PHASE=build ht_hook install; eq "install (образ с ядром L4T) — 0" 0 "$?"
check "apt-get ставит nftables и iptables" ht_called '^apt-get .*install .*nftables iptables'
eq "выбор сборки — iptables" iptables "$(cat "$STATE/backend")"
for f in 10-defaults.nft 10-defaults.rules 10-defaults.rules6 README; do
    check "умолчания: $f" cmp "$EXT/rules.d/$f" "$RD/$f"
done
check_not "в ядро при сборке ничего не грузится" ht_called '^(nft -f|ip6?tables-legacy-restore -w --noflush$)'
check_not "юниты не ставит и не включает (это cream)" ht_called '^systemctl (enable|daemon-reload)'
check_not "ссылок в /usr/local/sbin нет" test -e "$ROOT/usr/local/sbin"
echo '# edited' >> "$RD/10-defaults.nft"
cp "$RD/10-defaults.nft" "$HT_TMP/edited"
snap() { (cd "$ROOT" && find etc/cream var/lib/cream -type f -print0 | sort -z | xargs -0 sha256sum); }
before="$(snap)"
HT_PHASE=build ht_hook install; eq "повторный install — 0" 0 "$?"
eq "…ни один файл не изменился" "$before" "$(snap)"
check "…правленая копия оставлена" cmp "$HT_TMP/edited" "$RD/10-defaults.nft"
check "…и об этом сказано" grep -q 'отличается' "$ROOT/out"

echo '-A INPUT -j ACCEPT' > "$RD/60-bad.rules"
HT_PHASE=build ht_hook install; eq "install с битым *.rules — 1" 1 "$?"
rm -f "$RD/60-bad.rules"

rm -rf "$ROOT/lib/modules"/*
cp -a "$T/none" "$ROOT/lib/modules/6.1.0-none"
: > "$FAKE/calls"
HT_PHASE=build ht_hook install; eq "ядро без nft_ct и без legacy — отказ" 1 "$?"
check_not "…до apt" ht_called '^apt-get'
rm -rf "$ROOT/lib/modules"
HT_PHASE=build ht_hook install; eq "ядра в образе нет — 0" 0 "$?"
check_not "…выбора сборки нет" test -e "$STATE/backend"

# == remove ===================================================================
fw_root full
ht_hook configure FIREWALL_BACKEND=iptables
: > "$FAKE/nft-table"      # both present: a leftover of an interrupted switch
echo nft > "$STATE/backend"
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "таблица inet cream снята" test -e "$FAKE/nft-table"
check_not "цепочка CREAM-INPUT v4 снята" test -e "$FAKE/ipt4-loaded"
check_not "цепочка CREAM-INPUT v6 снята" test -e "$FAKE/ipt6-loaded"
check_not "переход из INPUT снят" test -e "$FAKE/ipt4-jump"
eq "nft: только своя таблица" "" "$(grep '^nft ' "$FAKE/calls" | grep -vxE 'nft (list|delete) table inet cream')"
eq "iptables: только своя цепочка" "" "$(grep -E '^ip6?tables-legacy ' "$FAKE/calls" \
    | grep -vE -- '-w (-n -L|-D INPUT -j|-F|-X) CREAM-INPUT$')"
check_not "flush ruleset — никогда" ht_called 'flush'
check_not "выбор сборки снят" test -e "$STATE/backend"
check "файлы правил оператора остаются" test -f "$RD/10-defaults.nft"
: > "$FAKE/calls"
ht_hook remove; eq "повторный remove — 0" 0 "$?"
eq "…ничего не снимает" 0 "$(count '(delete|-X|-D INPUT)')"

if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck -S warning" shellcheck -S warning -x "$EXT/backend.sh" "$EXT/firewall.sh" \
        "$EXT"/hooks/* "$EXT"/actions/* "$0"
fi

ht_done
