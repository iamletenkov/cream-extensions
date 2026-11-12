#!/usr/bin/env bash
# Тест сборки графического стека в образе (tools/build-graphical.sh) без сети,
# docker и libguestfs: список сценариев, сценарий гостя (--guest-script),
# сухой прогон (--dry-run) и разбор итогов из гостя (--verify) на подставных
# журналах.
#
#   tools/test-build-graphical.sh        код 0 — все проверки прошли
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B="$HERE/build-graphical.sh"
TMP="$(mktemp -d)"
trap 'rm -r -f -- "$TMP"' EXIT

pass=0; fail=0
eq(){ if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: ждали [$2], получили [$3]" >&2; fi; }
has(){ if grep -Fq -- "$2" <<< "$3"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: нет [$2]" >&2; fi; }
hasnt(){ if grep -Fq -- "$2" <<< "$3"; then fail=$((fail + 1)); echo "FAIL: $1: есть [$2]" >&2; else pass=$((pass + 1)); fi; }
# before <name> <a> <b> <text>: the first line with a comes before the first with b.
before(){
    local la lb
    la="$(grep -nF -- "$2" <<< "$4" | head -n1 | cut -d: -f1)"
    lb="$(grep -nF -- "$3" <<< "$4" | head -n1 | cut -d: -f1)"
    if [[ -n "$la" && -n "$lb" ]] && (( la < lb )); then pass=$((pass + 1)); else
        fail=$((fail + 1)); echo "FAIL: $1: [$2] (стр. ${la:-нет}) не раньше [$3] (стр. ${lb:-нет})" >&2; fi
}

# --- сценарии ---------------------------------------------------------------
eq "--list" $'cream-gnome\nexisting-gdm3' "$("$B" --list)"

rc=0; out="$("$B" --guest-script nope snap.tar.gz "$(printf 'a%.0s' {1..64})" 2>&1)" || rc=$?
eq "неизвестный сценарий — 2" 2 "$rc"
has "неизвестный сценарий — назван" "nope" "$out"
rc=0; "$B" --guest-script cream-gnome snap.tar.gz not-a-sum > /dev/null 2>&1 || rc=$?
eq "sha256 не 64 hex — 2" 2 "$rc"
rc=0; "$B" > /dev/null 2>&1 || rc=$?
eq "без аргументов — 2" 2 "$rc"

SHA="$(printf 'b%.0s' {1..64})"

# --- сценарий гостя: стол через cream ---------------------------------------
g="$("$B" --guest-script cream-gnome cream-extensions-9.9.9.tar.gz "$SHA")"
bash -n <<< "$g" 2>/dev/null; eq "cream-gnome: сценарий — bash" 0 $?
has "cream-gnome: cream из .deb" "dpkg -i /var/tmp/build-graphical/cream.deb" "$g"
has "cream-gnome: снимок источником core с проверкой суммы" \
    "cream --json source add core --archive file:///var/tmp/build-graphical/cream-extensions-9.9.9.tar.gz --sha256 $SHA --sync" "$g"
has "cream-gnome: desktop с автологином" "cream --json install --with-deps desktop DESKTOP_AUTOLOGIN=1" "$g"
has "cream-gnome: gnome" "cream --json install --with-deps gnome" "$g"
has "cream-gnome: selkies" "cream --json install --with-deps selkies" "$g"
has "cream-gnome: x11vnc" "cream --json install --with-deps x11vnc" "$g"
before "cream-gnome: cream до источника" "dpkg -i" "source add core" "$g"
before "cream-gnome: источник до установок" "source add core" "install --with-deps desktop" "$g"
before "cream-gnome: desktop до gnome" "install --with-deps desktop" "install --with-deps gnome" "$g"
before "cream-gnome: gnome (x11-server) до selkies" "install --with-deps gnome" "install --with-deps selkies" "$g"
before "cream-gnome: selkies до x11vnc" "install --with-deps selkies" "install --with-deps x11vnc" "$g"
hasnt "cream-gnome: стол не ставится apt" "apt-get install" "$g"
hasnt "cream-gnome: нет existing-desktop" "existing-desktop" "$g"
hasnt "cream-gnome: пароли не в образе" "PASSWORD" "$g"
has "cream-gnome: метки образа — в журналы" "/etc/image-labels.d/cream.json" "$g"
# DNS из appliance на hosted-раннере отвечает через раз: apt повторяет скачивание,
# а настройка повторов живёт только на время сборки и в образ не попадает.
has "cream-gnome: apt повторяет скачивание" 'Acquire::Retries "10";' "$g"
before "cream-gnome: повторы apt до первого шага" "Acquire::Retries" "step 01-cream" "$g"
has "cream-gnome: настройка повторов снимается на выходе" "rm -f /etc/apt/apt.conf.d/99build-graphical-retries" "$g"

# --- сценарий гостя: готовый gdm3 -------------------------------------------
g="$("$B" --guest-script existing-gdm3 cream-extensions-9.9.9.tar.gz "$SHA")"
bash -n <<< "$g" 2>/dev/null; eq "existing-gdm3: сценарий — bash" 0 $?
has "existing-gdm3: gdm3 — apt" "apt-get install" "$g"
has "existing-gdm3: gdm3 в списке" "gdm3" "$g"
has "existing-gdm3: existing-desktop" "cream --json install --with-deps existing-desktop" "$g"
has "existing-gdm3: desktop с автологином" "cream --json install --with-deps desktop DESKTOP_AUTOLOGIN=1" "$g"
before "existing-gdm3: gdm3 до cream" "apt-get install" "dpkg -i" "$g"
before "existing-gdm3: existing-desktop до desktop" "install --with-deps existing-desktop" "install --with-deps desktop" "$g"
before "existing-gdm3: existing-desktop до selkies" "install --with-deps existing-desktop" "install --with-deps selkies" "$g"
before "existing-gdm3: selkies до x11vnc" "install --with-deps selkies" "install --with-deps x11vnc" "$g"
hasnt "existing-gdm3: без gnome" "install --with-deps gnome" "$g"
hasnt "existing-gdm3: пароли не в образе" "PASSWORD" "$g"

# --- сухой прогон: команды хоста, ничего не запускается ---------------------
mkdir -p "$TMP/bin"
rc=0; d="$(PATH="$TMP/bin:/usr/bin:/bin" WORK="$TMP/w" "$B" --dry-run cream-gnome 2>&1)" || rc=$?
eq "--dry-run — 0" 0 "$rc"
has "--dry-run: снимок каталога" "catalog-snapshot.sh" "$d"
has "--dry-run: cream по пину" "cream-deb.sh" "$d"
has "--dry-run: образ ubuntu-24.04 amd64" "ubuntu-24.04-server-cloudimg-amd64.img" "$d"
has "--dry-run: сумма образа" "SHA256SUMS" "$d"
has "--dry-run: корень расширен" "virt-resize --expand /dev/sda1" "$d"
has "--dry-run: virt-customize" "virt-customize" "$d"
has "--dry-run: сценарий гостя" "--run" "$d"
has "--dry-run: журналы — наружу" "virt-copy-out" "$d"
has "--dry-run: разбор" "--verify cream-gnome" "$d"
if [[ -e "$TMP/w" ]]; then wc=1; else wc=0; fi
eq "--dry-run: рабочий каталог не создан" 0 "$wc"

# --- разбор итогов ----------------------------------------------------------
# mklogs <dir> <scenario>: logs of a successful run — every step rc 0, cream
# steps with an envelope of phase build and status installed, labels with all.
mklogs(){
    local dir="$1" sc="$2" n kind
    mkdir -p "$dir"
    while IFS='|' read -r n kind _; do
        echo 0 > "$dir/$n.rc"
        if [[ "$kind" == cream ]]; then
            printf '{"phase":"build","ok":true,"result":{"extensions":[{"name":"cloud-user","status":"installed"},{"name":"x","status":"installed"}]},"error":null}\n' > "$dir/$n.out"
        else
            echo ok > "$dir/$n.out"
        fi
    done < <("$B" --steps "$sc")
    # shellcheck disable=SC2016  # JSON with string-encoded lists, as cream writes it
    printf '{"cream.version":"1.4.0","cream.extensions":"[%s]","cream.sources":"[]"}\n' \
        "$(for x in apt-guard cloud-user desktop existing-desktop gnome selkies x11vnc; do printf '{\\"name\\":\\"%s\\"},' "$x"; done | sed 's/,$//')" \
        > "$dir/cream.json"
}
v(){ "$B" --verify "$@" 2>&1; }

steps="$("$B" --steps cream-gnome)"
has "--steps: шаг cream помечен" "|cream|" "$steps"
has "--steps: dpkg — шаг sh" "|sh|" "$steps"
# source add answers without "phase" (found on the first real build).
has "--steps: source add — только код" "02-source|sh|" "$steps"

mklogs "$TMP/ok" cream-gnome
rc=0; out="$(v cream-gnome "$TMP/ok")" || rc=$?
eq "все шаги прошли — 0" 0 "$rc"
has "итог называет сценарий" "cream-gnome" "$out"

cp -r "$TMP/ok" "$TMP/rc1"
last="$("$B" --steps cream-gnome | tail -n1 | cut -d'|' -f1)"
echo 79 > "$TMP/rc1/$last.rc"
rc=0; out="$(v cream-gnome "$TMP/rc1")" || rc=$?
eq "шаг с кодом 79 — 1" 1 "$rc"
has "шаг с кодом назван" "$last" "$out"
has "код назван" "79" "$out"

cp -r "$TMP/ok" "$TMP/norc"
rm -f -- "$TMP/norc/$last.rc"
rc=0; out="$(v cream-gnome "$TMP/norc")" || rc=$?
eq "шаг не дошёл — 1" 1 "$rc"
has "недошедший шаг назван" "$last" "$out"

cp -r "$TMP/ok" "$TMP/skip"
printf '{"phase":"build","ok":true,"result":{"name":"x11vnc","status":"skipped"},"error":null}\n' > "$TMP/skip/$last.out"
rc=0; out="$(v cream-gnome "$TMP/skip")" || rc=$?
eq "skipped — 1" 1 "$rc"
has "skipped назван" "skipped" "$out"

cp -r "$TMP/ok" "$TMP/live"
printf '{"phase":"live","ok":true,"result":{"name":"x11vnc","status":"installed"},"error":null}\n' > "$TMP/live/$last.out"
rc=0; out="$(v cream-gnome "$TMP/live")" || rc=$?
eq "фаза live в образе — 1" 1 "$rc"
has "фаза названа" "live" "$out"

cp -r "$TMP/ok" "$TMP/badjson"
echo 'not json' > "$TMP/badjson/$last.out"
rc=0; v cream-gnome "$TMP/badjson" > /dev/null || rc=$?
eq "конверт не JSON — 1" 1 "$rc"

cp -r "$TMP/ok" "$TMP/nolabel"
# shellcheck disable=SC2016
printf '{"cream.version":"1.4.0","cream.extensions":"[{\\"name\\":\\"desktop\\"},{\\"name\\":\\"gnome\\"},{\\"name\\":\\"x11vnc\\"}]","cream.sources":"[]"}\n' \
    > "$TMP/nolabel/cream.json"
rc=0; out="$(v cream-gnome "$TMP/nolabel")" || rc=$?
eq "в метках нет selkies — 1" 1 "$rc"
has "недостающая метка названа" "selkies" "$out"

cp -r "$TMP/ok" "$TMP/nolabels"
rm -f -- "$TMP/nolabels/cream.json"
rc=0; v cream-gnome "$TMP/nolabels" > /dev/null || rc=$?
eq "нет меток образа — 1" 1 "$rc"

mklogs "$TMP/okg" existing-gdm3
rc=0; v existing-gdm3 "$TMP/okg" > /dev/null || rc=$?
eq "existing-gdm3: все шаги прошли — 0" 0 "$rc"

rc=0; v cream-gnome "$TMP/nonexistent" > /dev/null || rc=$?
eq "нет каталога журналов — 2" 2 "$rc"

echo "проверок: $((pass + fail)), не прошло: $fail"
(( fail == 0 ))
