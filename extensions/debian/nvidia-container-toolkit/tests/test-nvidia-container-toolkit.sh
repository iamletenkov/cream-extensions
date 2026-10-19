#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the nvidia-container-toolkit extension (cream/v1): manifest, hooks
# install and remove on a scratch root (CREAM_ROOT) the way cream runs them,
# with fake apt-get, apt-cache, dpkg, dpkg-query, curl, gpg, systemctl and
# nvidia-ctk (the fake merges runtimes.nvidia into the JSON the way the real one
# does). root, network, Docker and a GPU are not needed.
#
#   extensions/debian/nvidia-container-toolkit/tests/test-nvidia-container-toolkit.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

CTK_FPR=C95B321B61E88C1809C4F759DDCAE044F796ECB0
FOUR="nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container-tools libnvidia-container1"

# ctk_root: fresh Debian root with Docker (dockerd) and the driver library,
# /etc/os-release, fakes. Package database — $FAKE/pkgs.
ctk_root() {
    local id=debian
    ht_root "$EXT"
    mkdir -p "$ROOT/etc/apt/sources.list.d" "$ROOT/usr/bin" "$ROOT/usr/lib/x86_64-linux-gnu" "$FAKE/pkgs"
    printf 'ID=%s\nVERSION_CODENAME=bookworm\n' "$id" > "$ROOT/etc/os-release"
    : > "$ROOT/usr/bin/dockerd"; chmod +x "$ROOT/usr/bin/dockerd"
    : > "$ROOT/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1"
    printf '1.17.8-1\n1.17.7-1\n' > "$FAKE/madison"
    echo "$CTK_FPR" > "$FAKE/fpr"
    ht_fake dpkg '[[ "$1" == --print-architecture ]] && echo amd64'
    ht_fake dpkg-query '
p="${*: -1}"
case "$p" in nvidia-container-toolkit) [[ "$*" == *Version* ]] && { echo 1.17.8-1; exit 0; } ;; esac
[[ -e "$FAKE/pkgs/$p" ]] && printf "install ok installed"
exit 0'
    ht_fake apt-get '
sub=""
for a in "$@"; do
    case "$a" in -*|Dpkg::*) ;; *) [[ -z "$sub" ]] && { sub="$a"; continue; }
        case "$sub" in install) : > "$FAKE/pkgs/${a%%=*}" ;; remove|purge) rm -f "$FAKE/pkgs/$a" ;; esac ;;
    esac
done
[[ -e "$FAKE/apt-fails-$sub" ]] && exit 100
exit 0'
    ht_fake apt-cache '
[[ "$1" == madison ]] && while read -r v; do echo " $2 | $v | https://nvidia.github.io stable Packages"; done < "$FAKE/madison"
exit 0'
    ht_fake curl '
out=""; url=""
while (( $# )); do
    case "$1" in -o) out="$2"; shift 2 ;; --retry|--retry-delay) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
echo "KEY $url" > "$out"'
    ht_fake gpg '
case " $* " in
    *" --list-keys "*) echo "pub:-:4096:1:AAAA:0:::-:::scESC::::::23::0:"
                       echo "fpr:::::::::$(cat "$FAKE/fpr"):" ;;
    *" --export "*) echo "ARMORED ${*: -1}" ;;
esac
exit 0'
    ht_fake gpgconf
    ht_fake systemctl
    # nvidia-ctk runtime configure --runtime=docker --config=F: adds
    # runtimes.nvidia to F, keeping every other key (as the real one does);
    # $FAKE/ctk-sets-default — misbehaves and sets default-runtime.
    ht_fake nvidia-ctk '
cfg=""
for a in "$@"; do case "$a" in --config=*) cfg="${a#--config=}" ;; esac; done
[[ -n "$cfg" ]] || exit 3
python3 - "$cfg" "$FAKE" <<'"'"'PY'"'"'
import json, os, sys
cfg, fake = sys.argv[1], sys.argv[2]
d = json.load(open(cfg)) if os.path.exists(cfg) else {}
d.setdefault("runtimes", {})["nvidia"] = {"path": "nvidia-container-runtime", "args": []}
if os.path.exists(os.path.join(fake, "ctk-sets-default")):
    d["default-runtime"] = "nvidia"
os.makedirs(os.path.dirname(cfg), exist_ok=True)
with open(cfg, "w") as f:
    json.dump(d, f, indent=4)
PY'
    DJ="$ROOT/etc/docker/daemon.json"
    SRC="$ROOT/etc/apt/sources.list.d/nvidia-container-toolkit.sources"
    KEY="$ROOT/etc/apt/keyrings/nvidia-container-toolkit.asc"
    STATE="$ROOT/var/lib/cream/ext/nvidia-container-toolkit"
}
installed() { [[ -e "$FAKE/pkgs/$1" ]]; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$DJ" "$1"; }
mf() { python3 -c 'import sys,yaml; m=yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }

echo "== манифест и раскладка =="
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 2" 2 "$(mf 'm["version"].split(".")[0]')"
eq "cream 1.0" ">=1.0.0" "$(mf 'm["cream"]')"
eq "только amd64" amd64 "$(mf '" ".join(m["platform"]["arch"])')"
eq "live: confirm" confirm "$(mf 'm["targets"]["live"]')"
check "live_note называет daemon.json" grep -q daemon.json <<< "$(mf 'm["targets"]["live_note"]')"
check "live_note называет перезапуск docker" grep -q 'перезапуск' <<< "$(mf 'm["targets"]["live_note"]')"
eq "provides" nvidia-container-runtime "$(mf '" ".join(m["provides"])')"
eq "requires" "container-runtime gpu-driver-nvidia" "$(mf '" ".join(m["requires"])')"
eq "хуки" "install remove" "$(mf '" ".join(sorted(m["hooks"]))')"
eq "ключ версии — scope install, может быть пустым" "install True" \
    "$(mf 'm["config"]["keys"]["NVIDIA_CTK_VERSION"]["scope"]+" "+str(m["config"]["keys"]["NVIDIA_CTK_VERSION"]["empty"])')"
for f in hooks/install hooks/remove; do check "$f исполняемый" test -x "$EXT/$f"; done
check_not "layout 2: install.sh не остался" test -e "$EXT/install.sh"

echo "== install: чистая машина, daemon.json нет =="
ctk_root
ht_hook install; eq "install — 0" 0 "$?"
check "источник deb822" grep -qx 'URIs: https://nvidia.github.io/libnvidia-container/stable/deb/amd64/' "$SRC"
check "источник: Signed-By" grep -qx 'Signed-By: /etc/apt/keyrings/nvidia-container-toolkit.asc' "$SRC"
check "ключ — экспорт прибитого" grep -qx "ARMORED $CTK_FPR" "$KEY"
check "четыре пакета" ht_called "^apt-get .*install $FOUR\$"
check "nvidia-ctk пишет daemon.json корня" ht_called "^nvidia-ctk runtime configure --runtime=docker --config=$DJ\$"
check_not "без --set-as-default" ht_called 'set-as-default'
eq "runtime nvidia прописан" nvidia-container-runtime "$(jget 'd["runtimes"]["nvidia"]["path"]')"
check "live: docker перезапущен, если работал" ht_called '^systemctl try-restart docker.service$'
check "запись: daemon.json не было" test -e "$STATE/daemon-json.absent"
eq "запись своих пакетов" "$(tr ' ' '\n' <<< "$FOUR" | LC_ALL=C sort)" "$(cat "$STATE/packages" 2>/dev/null)"

echo "== install: слияние, а не перезапись; двойной прогон =="
ctk_root
mkdir -p "$ROOT/etc/docker"
printf '{\n  "log-driver": "local",\n  "default-runtime": "runc",\n  "runtimes": {"crun": {"path": "/usr/bin/crun"}}\n}\n' > "$DJ"
orig="$(cat "$DJ")"
ht_hook install; eq "install поверх daemon.json — 0" 0 "$?"
eq "log-driver сохранён" local "$(jget 'd["log-driver"]')"
eq "default-runtime не тронут" runc "$(jget 'd["default-runtime"]')"
eq "чужой runtime сохранён" /usr/bin/crun "$(jget 'd["runtimes"]["crun"]["path"]')"
eq "runtime nvidia добавлен" nvidia-container-runtime "$(jget 'd["runtimes"]["nvidia"]["path"]')"
eq "копия исходного daemon.json" "$orig" "$(cat "$STATE/daemon-json.before" 2>/dev/null)"
snap="$(cat "$DJ" "$SRC" "$KEY" "$STATE/packages" "$STATE/daemon-json.before" | sha256sum)"
: > "$FAKE/calls"
ht_hook install; eq "повтор install — 0" 0 "$?"
eq "повтор: daemon.json, источник, ключ, записи те же" "$snap" \
    "$(cat "$DJ" "$SRC" "$KEY" "$STATE/packages" "$STATE/daemon-json.before" | sha256sum)"
check_not "повтор: nvidia-ctk не зовётся — runtime уже есть" ht_called '^nvidia-ctk'
check_not "повтор: docker не перезапускается" ht_called 'restart'

echo "== install: build-фаза =="
ctk_root
HT_PHASE=build ht_hook install; eq "build — 0" 0 "$?"
check_not "build: systemctl не зовётся" ht_called '^systemctl'

echo "== install: драйвера нет (nvidia пропущен) =="
ctk_root
rm -f "$ROOT/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1"
ht_hook install; eq "нет libnvidia-ml — 0 с предупреждением" 0 "$?"
check "предупреждение о драйвере" grep -q 'libnvidia-ml' <<< "$(ht_out)"
check "тулкит всё равно ставится" ht_called "^apt-get .*install $FOUR\$"
check "runtime всё равно прописан" test -f "$DJ"

echo "== install: отказы =="
ctk_root
rm -f "$ROOT/usr/bin/dockerd"
ht_hook install; eq "нет dockerd — 1" 1 "$?"
check_not "нет dockerd — apt не зовётся" ht_called '^apt-get'
ctk_root
ht_hook install NVIDIA_CTK_VERSION='1.17.8;rm'; eq "кривая версия — 1" 1 "$?"
check_not "кривая версия — apt не зовётся" ht_called '^apt-get'
ctk_root
ht_hook install NVIDIA_CTK_VERSION=1.16.0; eq "нет такой версии — 1" 1 "$?"
check "список доступных в ошибке" grep -q '1.17.8-1' <<< "$(ht_out)"
ctk_root
: > "$FAKE/ctk-sets-default"
ht_hook install; eq "nvidia-ctk сменил default-runtime — 1" 1 "$?"
ctk_root
echo DEADBEEF > "$FAKE/fpr"
ht_hook install; eq "чужой отпечаток ключа — 1" 1 "$?"
check_not "чужой ключ не лёг в keyring" test -e "$KEY"

echo "== install: точная версия =="
ctk_root
ht_hook install NVIDIA_CTK_VERSION=1.17.8; eq "версия 1.17.8 — 0" 0 "$?"
check "все четыре строго 1.17.8-1" ht_called \
    '^apt-get .*install nvidia-container-toolkit=1.17.8-1 nvidia-container-toolkit-base=1.17.8-1 libnvidia-container-tools=1.17.8-1 libnvidia-container1=1.17.8-1$'

echo "== install: источник уже есть =="
ctk_root
echo 'deb [signed-by=/x] https://nvidia.github.io/libnvidia-container/stable/deb/amd64 /' \
    > "$ROOT/etc/apt/sources.list.d/vendor.list"
ht_hook install; eq "чужой источник — 0" 0 "$?"
check_not "второй источник не добавлен" test -e "$SRC"

echo "== запись не идёт по ссылке =="
ctk_root
mkdir -p "$ROOT/etc/docker"
echo '{"x": 1}' > "$ROOT/victim.json"
ln -s "$ROOT/victim.json" "$DJ"
ht_hook install; eq "daemon.json — ссылка — 1" 1 "$?"
eq "цель ссылки не тронута" '{"x": 1}' "$(cat "$ROOT/victim.json")"
check_not "ссылка — nvidia-ctk не зовётся" ht_called '^nvidia-ctk'
ctk_root
mkdir -p "$ROOT/elsewhere"
ln -s "$ROOT/elsewhere" "$ROOT/etc/docker"
ht_hook install; eq "/etc/docker — ссылка — 1" 1 "$?"
check_not "в цель ссылки ничего не легло" test -e "$ROOT/elsewhere/daemon.json"
ctk_root
mkdir -p "$STATE"
echo victim > "$ROOT/victim"
ln -s "$ROOT/victim" "$STATE/packages"
ht_hook install; eq "запись пакетов — ссылка: 0" 0 "$?"
eq "цель ссылки записи не тронута" victim "$(cat "$ROOT/victim")"

echo "== remove: daemon.json не было =="
ctk_root
: > "$FAKE/pkgs/libnvidia-container1"
ht_hook install; eq "install перед remove — 0" 0 "$?"
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "daemon.json снят (его не было до нас)" test -e "$DJ"
check "docker перезапущен" ht_called '^systemctl try-restart docker.service$'
check "свои пакеты сняты" ht_called '^apt-get .*purge libnvidia-container-tools nvidia-container-toolkit nvidia-container-toolkit-base$'
check "стоявший раньше libnvidia-container1 оставлен" installed libnvidia-container1
check_not "источник снят" test -e "$SRC"
check_not "ключ снят" test -e "$KEY"
check "списки apt обновлены" ht_called '^apt-get .*update'
check_not "записи сняты" test -e "$STATE/packages"
check_not "отметка снята" test -e "$STATE/daemon-json.absent"
: > "$FAKE/calls"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
check_not "повтор: apt-get purge не зовётся" ht_called '^apt-get .*purge'

echo "== remove: daemon.json был — восстановлен =="
ctk_root
mkdir -p "$ROOT/etc/docker"
printf '{"log-driver": "local"}\n' > "$DJ"
ht_hook install; eq "install — 0" 0 "$?"
ht_hook remove; eq "remove — 0" 0 "$?"
eq "исходный daemon.json вернулся" '{"log-driver": "local"}' "$(cat "$DJ")"
check_not "копия снята" test -e "$STATE/daemon-json.before"

echo "== remove: daemon.json правили после нас — не трогаем =="
ctk_root
mkdir -p "$ROOT/etc/docker"
printf '{"log-driver": "local"}\n' > "$DJ"
ht_hook install; eq "install — 0" 0 "$?"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["debug"]=True; json.dump(d,open(p,"w"))' "$DJ"
after="$(cat "$DJ")"
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
eq "чужая правка сохранена" "$after" "$(cat "$DJ")"
check "сказано, что runtime убирать руками" grep -q 'руками' <<< "$(ht_out)"
check_not "daemon.json не трогали — перезапуска нет" ht_called 'restart'

echo "== remove: сбой apt =="
ctk_root
ht_hook install; eq "install — 0" 0 "$?"
: > "$FAKE/apt-fails-purge"
ht_hook remove; eq "apt-get purge упал — 1" 1 "$?"
check "сбой — запись пакетов сохранена для повтора" test -s "$STATE/packages"

ht_done
