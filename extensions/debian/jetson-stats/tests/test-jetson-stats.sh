#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the jetson-stats extension (cream/v1): manifest, hooks install,
# configure and remove on a scratch root (CREAM_ROOT) the way cream runs them.
# apt-get, dpkg-query, python3 (only `-m pip`), jtop, systemctl, groupadd,
# usermod, getent, id and sleep are fakes; the cloud-user library is a stub.
# No board, root, network or systemd — the live check is P (AGX Orin).
#
# Held here: pip runs with constraints, HOME in a temporary directory, no pip
# configuration and no --user — nothing lands in root's home; what pip put on
# is recorded and taken away by remove; configure is stage cloud-user and
# never orders itself against jtop.service (that made a cycle on the board).
#
#   extensions/debian/jetson-stats/tests/test-jetson-stats.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

jroot() {
    ht_root "$EXT"
    STATE="$ROOT/var/lib/cream/ext/jetson-stats"
    UNIT="$ROOT/etc/systemd/system/jtop.service"
    mkdir -p "$ROOT/etc/systemd/system" "$ROOT/root"
    echo '# R36 (release), REVISION: 4.3, BOARD: generic' > "$ROOT/etc/nv_tegra_release"
    printf '%s\n' 'alice:x:1000:1000::/home/alice:/bin/bash' > "$FAKE/passwd"
    printf '%s\n' 'alice:x:1000:' > "$FAKE/group"
    echo alice > "$FAKE/user"
    printf '%s\n' pip setuptools > "$FAKE/pip-installed"
    ht_fake getent 'f="$FAKE/$1"; [[ -f "$f" ]] || exit 2; [[ -z "${2-}" ]] && { cat "$f"; exit 0; }; grep -E "^${2}:" "$f" || exit 2'
    ht_fake id '
if [[ "$1" == -nG ]]; then u="$2"; out="$u"
  while IFS=: read -r g _ _ m; do [[ ",$m," == *",$u,"* ]] && out="$out $g"; done < "$FAKE/group"
  echo "$out"; exit 0; fi
grep -qE "^${*: -1}:" "$FAKE/passwd"'
    ht_fake groupadd 'echo "$1:x:999:" >> "$FAKE/group"'
    ht_fake usermod '[[ "$1" == -aG ]] || exit 2
awk -F: -v OFS=: -v g="$2" -v u="$3" "\$1 == g { \$4 = (\$4 == \"\" ? u : \$4 \",\" u) } { print }" "$FAKE/group" > "$FAKE/g.new"; mv "$FAKE/g.new" "$FAKE/group"'
    ht_fake systemctl '[[ "$1" == is-active ]] && { [[ -f "$FAKE/active" ]]; exit; }; exit 0'
    ht_fake dpkg-query 'p="${*: -1}"; [[ -f "$FAKE/pkg-$p" ]] && printf installed; exit 0'
    ht_fake apt-get 'if [[ "$1" == -s ]]; then v=Remv; [[ "$2" == purge ]] && v=Purg
    for a in "${@:3}"; do echo "$v $a [1.0]"; done; cat "$FAKE/sim-extra" 2>/dev/null; exit 0; fi
if [[ " $* " == *" install "* ]]; then
  for a in "$@"; do case "$a" in -*|install|Dpkg::*) ;; *) : > "$FAKE/pkg-$a" ;; esac; done
fi; exit 0'
    # python3 -m pip: list/install/uninstall over $FAKE/pip-installed; the
    # environment and argv of every call are recorded.
    ht_fake python3 '
[[ "$1 $2" == "-m pip" ]] || exec /usr/bin/python3 "$@"
shift 2
env > "$FAKE/pip.env.$1"
if [[ "$1" == install ]]; then
  while (( $# )); do [[ "$1" == -r ]] && cp "$2" "$FAKE/pip.reqs"; shift; done; set -- install
fi
case "$1" in
  list) cat "$FAKE/pip-installed" | sed "s/$/==1.0/" ;;
  install) [[ -f "$FAKE/pip-fails" ]] && exit 1
    printf "%s\n" jetson-stats smbus2 distro nvidia-ml-py >> "$FAKE/pip-installed"
    mkdir -p "'"$ROOT"'/usr/local/share/jetson_stats" ;;
  uninstall) shift; for p in "$@"; do [[ "$p" == -y ]] && continue; sed -i "/^$p\$/d" "$FAKE/pip-installed"; done ;;
esac'
    ht_fake jtop '[[ "$1" == --install-service && -f "$FAKE/jtop-installs-unit" ]] && printf "[Service]\nExecStart=jtop\n" > "'"$UNIT"'"; exit 0'
    ht_fake sleep
    LIB="$ROOT/opt/cream/ext/cloud-user/get_cloud_user.sh"
    mkdir -p "$(dirname "$LIB")"
    printf '#!/usr/bin/env bash\ncat %q 2>/dev/null || exit 1\n' "$FAKE/user" > "$LIB"
    chmod +x "$LIB"
}
live_systemd() { mkdir -p "$ROOT/run/systemd/system"; }

echo "== манифест =="
# eval: test-only literal expressions over our own manifest, as in nvidia-jetpack.
mf() { python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "версия 3.2.0 (every_boot)" 3.2.0 "$(mf 'm["version"]')"
eq "cream >=1.2.0 (every_boot, спека cream §10.9)" ">=1.2.0" "$(mf 'm["cream"]')"
eq "configure на каждой загрузке (аудит 2026-10-21)" True "$(mf 'm["hooks"]["configure"].get("every_boot")')"
eq "только arm64" "['arm64']" "$(mf 'm["platform"]["arch"]')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "стадия cloud-user" cloud-user "$(mf 'm["hooks"]["configure"]["stage"]')"
check_not "без порядка относительно jtop.service" grep -q 'jtop' <<< "$(mf 'm["hooks"]["configure"].get("after", []) + m["hooks"]["configure"].get("before", []) + m["hooks"]["configure"].get("wants", [])')"
eq "хуки" "['configure', 'install', 'remove']" "$(mf 'sorted(m["hooks"])')"
eq "depends cloud-user, apt-guard" "cloud-user >=1.0.0 <2 apt-guard >=1.0.0 <2" "$(mf '" ".join(d["name"]+" "+d["version"] for d in m["depends"])')"
check "requirements.txt закрепляет jetson-stats" grep -qE '^jetson-stats==[0-9.]+' "$EXT/requirements.txt"
check_not "constraints.txt убран" test -e "$EXT/constraints.txt"
# pip 9.0.1 of Ubuntu 18.04 (L4T R32) reads the file as ASCII under LANG=C.
check "requirements.txt — только ASCII (pip 9 на R32)" python3 -c 'open(__import__("sys").argv[1], encoding="ascii").read()' "$EXT/requirements.txt"
check "requirements.txt: каждый пакет — == и хотя бы один sha256" python3 - "$EXT/requirements.txt" <<'PY2'
import re, sys
text = re.sub(r"\\\n", " ", open(sys.argv[1]).read())
reqs = [" ".join(l.split("#")[0].split()) for l in text.splitlines()]
reqs = [r for r in reqs if r]
assert reqs
for r in reqs:
    assert re.fullmatch(r'[A-Za-z0-9_.-]+==[A-Za-z0-9_.+!-]+( ; python_version [<>=]+ "[0-9.]+")?( --hash=sha256:[0-9a-f]{64})+', r), r
PY2
for f in install.sh configure.sh configure-jetson-stats.service; do
    check_not "layout 2: нет $f" test -e "$EXT/$f"
done

echo "== install: не Jetson — 20 =="
jroot
rm -f -- "$ROOT/etc/nv_tegra_release"
ht_hook install; eq "нет /etc/nv_tegra_release — 20" 20 "$?"
check_not "apt не звали" ht_called '^apt-get '

echo "== install: pip без следов в доме root =="
jroot
: > "$FAKE/jtop-installs-unit"
ht_hook install; eq "install — 0" 0 "$?"
check "apt: python3-pip" ht_called '^apt-get .*install .*python3-pip'
check "pip по хешам requirements.txt" ht_called '^python3 -m pip install .*--require-hashes -r .*/requirements\.txt'
check_not "pip без --constraint" ht_called '^python3 -m pip .*--constraint'
check_not "pip без --user" ht_called '^python3 -m pip .*--user'
envf="$FAKE/pip.env.install"
check "HOME pip — временный каталог" grep -qE "^HOME=$ROOT/tmp/" "$envf"
check "PIP_CONFIG_FILE=/dev/null" grep -qx 'PIP_CONFIG_FILE=/dev/null' "$envf"
check "PIP_USER=0" grep -qx 'PIP_USER=0' "$envf"
check "PYTHONNOUSERSITE=1" grep -qx 'PYTHONNOUSERSITE=1' "$envf"
check_not "в /root ничего" test -n "$(ls -A "$ROOT/root")"
check_not "временный каталог убран" test -n "$(ls -A "$ROOT/tmp")"
eq "pip: записано поставленное" "distro jetson-stats nvidia-ml-py smbus2" "$(sort "$STATE/pip" | tr '\n' ' ' | sed 's/ $//')"
check "юнит от jtop --install-service" test -f "$UNIT"
check "группа jtop" grep -q '^jtop:' "$FAKE/group"
check "jtop.service включён" ht_called '^systemctl enable jtop\.service$'
check_not "юнит не наш — remove его не тронет" test -e "$STATE/unit-ours"

echo "== install: колесо без юнита — юнит пишет расширение =="
jroot
ht_hook install; eq "install — 0" 0 "$?"
check "юнит написан" grep -qx 'Environment="JTOP_SERVICE=True"' "$UNIT"
check "ExecStart — путь jtop" grep -qE "^ExecStart=/[^ ]+/jtop --force$" "$UNIT"
eq "юнит 0644" 644 "$(stat -c %a "$UNIT")"
check "помечен как наш" test -e "$STATE/unit-ours"
: > "$FAKE/calls"
ht_hook install; eq "повтор — 0" 0 "$?"
eq "повтор: pip-запись та же" "distro jetson-stats nvidia-ml-py smbus2" "$(sort "$STATE/pip" | tr '\n' ' ' | sed 's/ $//')"

echo "== install: своя версия и сбой pip =="
jroot
ht_hook install JETSON_STATS_VERSION=4.3.2; eq "версия 4.3.2 — 0" 0 "$?"
check "ставит заданную версию — по её хешу, без маркера Python" \
    grep -qE '^jetson-stats==4\.3\.2 +--hash=sha256:2b033cb02b9d' "$FAKE/pip.reqs"
check_not "…другой версии jetson-stats в файле нет" grep -q '^jetson-stats==7' "$FAKE/pip.reqs"
check "…зависимости — по хешам" grep -q '^smbus2==0.6.1' "$FAKE/pip.reqs"
jroot
ht_hook install JETSON_STATS_VERSION=7.3.0; eq "версия без хешей — 1" 1 "$?"
check "…называет версии с хешами" grep -q '7.2.1 4.3.2' <(ht_out)
check_not "…pip не звали" ht_called '^python3 -m pip install'
ht_hook install 'JETSON_STATS_VERSION=1;id'; eq "версия не по форме — 1" 1 "$?"
jroot; : > "$FAKE/pip-fails"
ht_hook install; eq "pip упал — 1" 1 "$?"

echo "== configure: пользователь cloud-init в группе jtop =="
jroot
ht_hook install >/dev/null
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
check "alice в jtop" grep -qE '^jtop:.*alice' "$FAKE/group"
check_not "без systemd: не запускает" ht_called '^systemctl --no-block start'
jroot; live_systemd
ht_hook configure CREAM_REASON=install; eq "live — 0" 0 "$?"
check "jtop.service запускается --no-block" ht_called '^systemctl --no-block start jtop\.service$'
check_not "блокирующего systemctl нет" ht_called '^systemctl (start|restart|stop) '
: > "$FAKE/calls"; : > "$FAKE/active"
ht_hook configure CREAM_REASON=apply; eq "повтор — 0" 0 "$?"
check_not "повтор: usermod не нужен" ht_called '^usermod '
check_not "уже работает — не запускает" ht_called 'start jtop'
jroot; rm -f -- "$FAKE/user"
ht_hook configure CREAM_REASON=boot; eq "нет пользователя — 0" 0 "$?"
check "предупреждение" grep -q 'пользовател' <(ht_out)
jroot; rm -f -- "$ROOT/etc/nv_tegra_release"
ht_hook configure CREAM_REASON=boot; eq "не Jetson — 0" 0 "$?"

echo "== remove =="
jroot; live_systemd
ht_hook install >/dev/null
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check "pip снимает своё" ht_called '^python3 -m pip uninstall -y .*jetson-stats'
check "HOME pip при снятии — временный" grep -qE "^HOME=$ROOT/tmp/" "$FAKE/pip.env.uninstall"
check "службу выключили" ht_called '^systemctl disable jtop\.service'
check_not "наш юнит снят" test -e "$UNIT"
check "apt снимает своё" ht_called '^apt-get .*remove .*python3-pip'
check_not "состояние снято" test -e "$STATE/pip" -o -e "$STATE/packages" -o -e "$STATE/unit-ours"
: > "$FAKE/calls"
ht_hook remove; eq "повтор — 0" 0 "$?"
check_not "повтор: pip и apt не звали" ht_called '^(apt-get|python3) '

echo "== remove: симуляция снимает чужой пакет — отказ =="
jroot; live_systemd
ht_hook install >/dev/null
echo 'Remv python3-jtop-plugins [1.0]' > "$FAKE/sim-extra"
: > "$FAKE/calls"
ht_hook remove; eq "симуляция снимает чужой пакет — 1" 1 "$?"
check "чужой пакет назван" grep -q 'python3-jtop-plugins' "$ROOT/out"
check_not "ничего не снято" ht_called '^apt-get -q -y remove'
check_not "pip не тронут" ht_called 'pip uninstall'
check_not "служба не выключена" ht_called '^systemctl disable'
check "юнит на месте" test -e "$UNIT"
check "запись пакетов осталась" test -s "$STATE/packages"

ht_done
