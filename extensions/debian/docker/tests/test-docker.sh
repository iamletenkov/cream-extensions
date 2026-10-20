#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the docker extension (cream/v1): manifest, hooks install, configure
# and remove on a scratch root (CREAM_ROOT) the way cream runs them, with fake
# apt-get, apt-cache, dpkg, curl, systemctl, usermod, nvidia-ctk and a stub of
# the cloud-user library. root, network and a Docker daemon are not needed.
#
#   extensions/debian/docker/tests/test-docker.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

FIVE="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

# docker_root [ID] [CODENAME]: fresh root; /etc/os-release of ID/CODENAME
# (ubuntu also gets UBUNTU_CODENAME); fake package database in $FAKE/pkgs.
docker_root() {
    local id="${1:-debian}" code="${2-bookworm}"
    ht_root "$EXT"
    mkdir -p "$ROOT/etc" "$FAKE/pkgs"
    {
        echo "ID=$id"
        echo "VERSION_CODENAME=$code"
        [[ "$id" == ubuntu ]] && echo "UBUNTU_CODENAME=$code"
    } > "$ROOT/etc/os-release"
    echo amd64 > "$FAKE/arch"
    echo '5:29.7.2-1~debian.12~bookworm' > "$FAKE/candidate"
    ht_fake dpkg '
case "$1" in
    --print-architecture) cat "$FAKE/arch" ;;
    -l) [[ -e "$FAKE/pkgs/$2" ]] || exit 1; echo "ii  $2  1.0  amd64  fake" ;;
    *) exit 1 ;;
esac'
    ht_fake dpkg-query '
p="${*: -1}"
[[ -e "$FAKE/pkgs/$p" ]] && printf installed
exit 0'
    ht_fake apt-get '
if [[ "$1" == -s ]]; then v=Remv; [[ "$2" == purge ]] && v=Purg
    for a in "${@:3}"; do echo "$v $a [1.0]"; done; cat "$FAKE/sim-extra" 2>/dev/null; exit 0; fi
sub=""
for a in "$@"; do
    case "$a" in -*|Dpkg::*) ;; *) [[ -z "$sub" ]] && { sub="$a"; continue; }
        case "$sub" in
            install) : > "$FAKE/pkgs/$a" ;;
            remove|purge) rm -f "$FAKE/pkgs/$a" ;;
        esac ;;
    esac
done
[[ -e "$FAKE/apt-fails-$sub" ]] && exit 100
exit 0'
    ht_fake apt-cache '[[ "$1" == policy ]] && printf "%s:\n  Installed: (none)\n  Candidate: %s\n" "$2" "$(cat "$FAKE/candidate")"'
    ht_fake curl '
out=""; url=""
while (( $# )); do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --retry|--retry-delay|--max-time|--connect-timeout) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
echo "KEY $url" > "$out"'
    ht_fake systemctl '
[[ "$1" == is-active ]] && { [[ -e "$FAKE/docker-active" ]]; exit; }
exit 0'
    ht_fake usermod
    ht_fake nvidia-ctk
    ht_fake getent '[[ "$1 $2" == "group docker" && -e "$FAKE/group-docker" ]] && echo "docker:x:999:"'
    ht_fake id '[[ "$1" == -nG ]] && { cat "$FAKE/groups-$2" 2>/dev/null || echo "$2"; }'
    : > "$FAKE/group-docker"
    # Stub of the cloud-user library at its stable path: prints $FAKE/user or fails.
    LIB="$ROOT/opt/cream/ext/cloud-user/get_cloud_user.sh"
    mkdir -p "$(dirname "$LIB")"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$CREAM_ROOT" > %q/lib-root\n[[ -f %q/user ]] || { echo "Error: no user" >&2; exit 1; }\ncat %q/user\n' \
        "$FAKE" "$FAKE" "$FAKE" > "$LIB"
    chmod +x "$LIB"
    STATE="$ROOT/var/lib/cream/ext/docker"
    SRC="$ROOT/etc/apt/sources.list.d/docker.sources"
    NVSRC="$ROOT/etc/apt/sources.list.d/nvidia-jetson.sources"
}
installed() { [[ -e "$FAKE/pkgs/$1" ]]; }
mf() { python3 -c 'import sys,yaml; m=yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }

echo "== манифест и раскладка =="
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 4" 4 "$(mf 'm["version"].split(".")[0]')"
eq "cream 1.0 (стадия system)" ">=1.0.0" "$(mf 'm["cream"]')"
eq "live: confirm" confirm "$(mf 'm["targets"]["live"]')"
check "live_note называет docker.io" grep -q docker.io <<< "$(mf 'm["targets"]["live_note"]')"
check "live_note называет podman-docker" grep -q podman-docker <<< "$(mf 'm["targets"]["live_note"]')"
eq "depends cloud-user, apt-guard" "cloud-user >=1.0.0 <2 apt-guard >=1.0.0 <2" "$(mf '" ".join(d["name"]+" "+d["version"] for d in m["depends"])')"
eq "хуки" "configure install remove" "$(mf '" ".join(sorted(m["hooks"]))')"
eq "стадия configure" system "$(mf 'm["hooks"]["configure"]["stage"]')"
eq "configure после docker.service" docker.service "$(mf '" ".join(m["hooks"]["configure"]["after"])')"
eq "provides" container-runtime "$(mf '" ".join(m["provides"])')"
eq "files: drop-in и проверка raw" \
    "/etc/systemd/system/docker.service.d/10-docker-iptables-raw.conf /usr/local/libexec/docker-iptables-raw-check" \
    "$(mf '" ".join(sorted(f["dst"] for f in m["files"]))')"
eq "files: режим проверки raw" 0755 "$(mf '[f["mode"] for f in m["files"] if f["dst"].endswith("-check")][0]')"
for f in hooks/install hooks/configure hooks/remove files/docker-iptables-raw-check; do
    check "$f исполняемый" test -x "$EXT/$f"
done
for f in install.sh configure.sh configure-docker.service 10-bisquite-iptables-raw.conf docker-iptables-raw-check; do  # check-names: allow
    check_not "layout 2: $f не остался в корне" test -e "$EXT/$f"
done
DROPIN="$EXT/files/10-docker-iptables-raw.conf"
check "drop-in зовёт проверку по пути files" grep -qx 'ExecStartPre=/usr/local/libexec/docker-iptables-raw-check' "$DROPIN"
envf="$(sed -n 's/^EnvironmentFile=-//p' "$DROPIN")"
check "файл окружения drop-in — в /run, не bisquite" grep -Eq '^/run/docker-iptables-raw/[a-z.-]+$' <<< "$envf"
check "проверка пишет тот же файл окружения" grep -qF "${envf##*/}" "$EXT/files/docker-iptables-raw-check"
check "проверка пишет тот же каталог" grep -qF "${envf%/*}" "$EXT/files/docker-iptables-raw-check"

echo "== install: debian, amd64 =="
docker_root debian bookworm
ht_hook install; eq "install — 0" 0 "$?"
check "источник deb822: linux/debian" grep -qx 'URIs: https://download.docker.com/linux/debian' "$SRC"
check "источник: сюита bookworm" grep -qx 'Suites: bookworm' "$SRC"
check "источник: Architectures amd64" grep -qx 'Architectures: amd64' "$SRC"
check "источник: Signed-By" grep -qx 'Signed-By: /etc/apt/keyrings/docker.asc' "$SRC"
check "ключ скачан с download.docker.com" grep -q 'linux/debian/gpg' "$ROOT/etc/apt/keyrings/docker.asc"
eq "ключ — 0644" 644 "$(stat -c %a "$ROOT/etc/apt/keyrings/docker.asc" 2>/dev/null)"
check "пять пакетов одним apt-get install" ht_called "^apt-get .*install .*$FIVE\$"
check "юниты docker включены" ht_called '^systemctl enable docker.service containerd.service'
check "live: daemon-reload до установки (drop-in виден postinst)" ht_called '^systemctl daemon-reload'
eq "daemon-reload раньше install пакетов" daemon-reload \
    "$(grep -E '^(systemctl daemon-reload|apt-get .*install .*docker-ce)' "$FAKE/calls" | head -n1 | awk '{print $2}')"
eq "запись своих пакетов" "$(tr ' ' '\n' <<< "$FIVE" | LC_ALL=C sort)" "$(cat "$STATE/packages" 2>/dev/null)"
check_not "юнит configure-docker не ставится" ht_called 'configure-docker'
check_not "drop-in хук не кладёт сам (это files)" test -e "$ROOT/etc/systemd/system/docker.service.d"
check_not "nvidia-ctk не зовётся без L4T" ht_called '^nvidia-ctk'
snap="$(cat "$SRC" "$STATE/packages" "$ROOT/etc/apt/keyrings/docker.asc" | sha256sum)"
ht_hook install; eq "повтор install — 0" 0 "$?"
eq "повтор: источник, ключ и запись те же" "$snap" "$(cat "$SRC" "$STATE/packages" "$ROOT/etc/apt/keyrings/docker.asc" | sha256sum)"

echo "== install: build-фаза =="
docker_root debian trixie
HT_PHASE=build ht_hook install; eq "build — 0" 0 "$?"
check_not "build: daemon-reload не зовётся (systemd нет)" ht_called '^systemctl daemon-reload'

echo "== install: ubuntu, arm64 =="
docker_root ubuntu noble
echo arm64 > "$FAKE/arch"
ht_hook install; eq "ubuntu — 0" 0 "$?"
check "источник: linux/ubuntu" grep -qx 'URIs: https://download.docker.com/linux/ubuntu' "$SRC"
check "источник: UBUNTU_CODENAME" grep -qx 'Suites: noble' "$SRC"
check "источник: Architectures arm64" grep -qx 'Architectures: arm64' "$SRC"

echo "== install: конкурирующие пакеты =="
docker_root
: > "$FAKE/pkgs/docker.io"; : > "$FAKE/pkgs/runc"; : > "$FAKE/pkgs/podman-docker"
ht_hook install; eq "с docker.io — 0" 0 "$?"
check "docker.io снят" ht_called '^apt-get .*remove docker.io$'
check "runc снят" ht_called '^apt-get .*remove runc$'
check "podman-docker снят" ht_called '^apt-get .*remove podman-docker$'
check_not "не стоявший containerd не трогается" ht_called '^apt-get .*remove containerd$'
check "снятие сказано вслух" grep -q 'docker.io' <<< "$(ht_out)"
check_not "снятые не попали в запись своих" grep -qx docker.io "$STATE/packages"
docker_root
: > "$FAKE/pkgs/docker.io"; : > "$FAKE/apt-fails-remove"
ht_hook install; eq "неудачное снятие — предупреждение, не отказ" 0 "$?"

echo "== install: стоявший раньше docker-ce — не наш =="
docker_root
: > "$FAKE/pkgs/docker-ce"; : > "$FAKE/pkgs/containerd.io"
ht_hook install; eq "поверх своего docker-ce — 0" 0 "$?"
check_not "стоявший docker-ce не в записи" grep -qx docker-ce "$STATE/packages"
check "доставленный docker-ce-cli — в записи" grep -qx docker-ce-cli "$STATE/packages"

echo "== install: отказы =="
docker_root
echo '(none)' > "$FAKE/candidate"
ht_hook install; eq "нет кандидата — 1" 1 "$?"
check_not "нет кандидата — пакеты не ставятся" ht_called "^apt-get .*install .*docker-ce"
check "нет кандидата — отката на docker.io нет" grep -q 'docker.io' <<< "$(ht_out)"
docker_root fedora 40
ht_hook install; eq "чужой ID — 1" 1 "$?"
check_not "чужой ID — apt не зовётся" ht_called '^apt-get'
docker_root debian ""
ht_hook install; eq "нет кодового имени — 1" 1 "$?"
docker_root
: > "$FAKE/apt-fails-install"
ht_hook install; eq "apt-get install упал — 1" 1 "$?"
check_not "сбой — записи своих нет" test -s "$STATE/packages"

echo "== install: замороженная сюита =="
docker_root debian buster
ht_hook install; eq "buster — 0" 0 "$?"
check "buster — предупреждение о заморозке" grep -q 'заморожена' <<< "$(ht_out)"

echo "== install: Jetson (L4T) =="
docker_root ubuntu jammy
echo arm64 > "$FAKE/arch"
echo '# R36 (release), REVISION: 4.3, GCID: 38968081, BOARD: generic, EABI: aarch64' > "$ROOT/etc/nv_tegra_release"
ht_hook install; eq "L4T — 0" 0 "$?"
check "свой источник NVIDIA: сюита r36.4" grep -qx 'Suites: r36.4' "$NVSRC"
check "ключ NVIDIA скачан" grep -q 'jetson-ota-public.asc' "$ROOT/etc/apt/keyrings/nvidia-jetson.asc"
check "nvidia-container-toolkit ставится" ht_called '^apt-get .*install nvidia-container-toolkit$'
check "nvidia-ctk runtime configure" ht_called '^nvidia-ctk runtime configure --runtime=docker'
check "toolkit — в записи своих" grep -qx nvidia-container-toolkit "$STATE/packages"
docker_root ubuntu jammy
echo '# R36 (release), REVISION: 4.3' > "$ROOT/etc/nv_tegra_release"
mkdir -p "$(dirname "$NVSRC")"
echo 'deb https://repo.download.nvidia.com/jetson/common r36.4 main' > "$ROOT/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"
echo stale > "$NVSRC"
ht_hook install; eq "L4T с вендорским источником — 0" 0 "$?"
check_not "свой источник не добавлен, старый снят" test -e "$NVSRC"
docker_root ubuntu jammy
echo '# R36 (release), REVISION: 4.3' > "$ROOT/etc/nv_tegra_release"
: > "$FAKE/apt-fails-install"
rm -f "$FAKE/apt-fails-install"
ht_fake nvidia-ctk 'exit 1'
ht_hook install; eq "nvidia-ctk упал — предупреждение, 0" 0 "$?"

echo "== configure: группа docker =="
docker_root
echo alice > "$FAKE/user"
ht_hook configure; eq "configure — 0" 0 "$?"
check "alice добавлена в docker" ht_called '^usermod -aG docker alice$'
check "сказано, что это равносильно root" grep -q 'root' <<< "$(ht_out)"
eq "библиотеке передан CREAM_ROOT" "$ROOT" "$(cat "$FAKE/lib-root" 2>/dev/null)"
docker_root
echo alice > "$FAKE/user"
echo 'alice sudo docker' > "$FAKE/groups-alice"
ht_hook configure; eq "уже в группе — 0" 0 "$?"
check_not "уже в группе — usermod не зовётся" ht_called '^usermod'
docker_root
ht_hook configure; eq "пользователь не определился — 0" 0 "$?"
check_not "пользователь не определился — usermod нет" ht_called '^usermod'
check "пользователь не определился — предупреждение" grep -q 'не назначена' <<< "$(ht_out)"
docker_root
rm -f "$LIB"
echo alice > "$FAKE/user"
ht_hook configure; eq "нет библиотеки cloud-user — 0" 0 "$?"
check_not "нет библиотеки — usermod нет" ht_called '^usermod'
docker_root
echo alice > "$FAKE/user"
rm -f "$FAKE/group-docker"
ht_hook configure; eq "нет группы docker — 0" 0 "$?"
check_not "нет группы — usermod нет" ht_called '^usermod'
for junk in '-oroot' 'Alice' 'a b' 'x$(id)' $'b\e[31mad' '../etc'; do
    docker_root
    printf '%s\n' "$junk" > "$FAKE/user"
    ht_hook configure; eq "имя [$junk] — 0" 0 "$?"
    check_not "имя [$junk] — usermod нет" ht_called '^usermod'
    check "имя [$junk] — предупреждение" grep -q 'не имя пользователя' "$ROOT/out"
    check_not "имя [$junk] — ESC имени не в выводе" grep -q $'\e\\[31m' "$ROOT/out"
done

echo "== configure: Raspberry Pi cmdline.txt =="
docker_root
CMD="$ROOT/boot/firmware/cmdline.txt"
mkdir -p "$(dirname "$CMD")"
printf 'console=serial0,115200 root=PARTUUID=abc-02 rootwait  \n' > "$CMD"
orig="$(cat "$CMD")"
ht_hook configure; eq "правка cmdline.txt — 10 (перезагрузка)" 10 "$?"
eq "одна строка с cgroup_enable=memory" 'console=serial0,115200 root=PARTUUID=abc-02 rootwait cgroup_enable=memory' "$(cat "$CMD")"
eq "строк в cmdline.txt — 1" 1 "$(wc -l < "$CMD")"
eq "бэкап — исходный файл" "$orig" "$(cat "$CMD.before-docker" 2>/dev/null)"
after="$(sha256sum < "$CMD")"
ht_hook configure; eq "повтор configure — 0" 0 "$?"
eq "повтор: cmdline.txt не тронут" "$after" "$(sha256sum < "$CMD")"
eq "повтор: бэкап не перезаписан" "$orig" "$(cat "$CMD.before-docker")"
eq "cgroup_enable=memory один раз" 1 "$(grep -o 'cgroup_enable=memory' "$CMD" | wc -l)"
docker_root
CMD="$ROOT/boot/firmware/cmdline.txt"
mkdir -p "$(dirname "$CMD")"
echo 'root=/dev/mmcblk0p2' > "$CMD"
echo 'earlier backup' > "$CMD.before-docker"
ht_hook configure; eq "бэкап уже есть — 10" 10 "$?"
eq "существующий бэкап не перезаписан" 'earlier backup' "$(cat "$CMD.before-docker")"
docker_root
CMD="$ROOT/boot/firmware/cmdline.txt"
mkdir -p "$(dirname "$CMD")"
echo 'root=/dev/mmcblk0p2 cgroup_enable=memory' > "$CMD"
ht_hook configure; eq "уже есть cgroup_enable=memory — 0" 0 "$?"
check_not "уже есть — бэкапа нет" test -e "$CMD.before-docker"
docker_root
ht_hook configure; eq "не Pi — 0" 0 "$?"
check_not "не Pi — cmdline.txt не создан" test -e "$ROOT/boot/firmware/cmdline.txt"

echo "== configure: Jetson, среда выполнения NVIDIA =="
docker_root ubuntu jammy
echo '# R36 (release), REVISION: 4.3' > "$ROOT/etc/nv_tegra_release"
mkdir -p "$ROOT/etc/docker"
echo '{"runtimes":{"nvidia":{}}}' > "$ROOT/etc/docker/daemon.json"
: > "$FAKE/docker-active"
ht_hook configure; eq "Jetson — 0" 0 "$?"
check "демон перезапускается без ожидания" ht_called '^systemctl --no-block try-restart docker.service$'
: > "$FAKE/calls"
ht_hook configure; eq "Jetson, повтор — 0" 0 "$?"
check_not "повтор: daemon.json тот же — перезапуска нет" ht_called 'restart'
echo '{"runtimes":{"nvidia":{}},"log-driver":"local"}' > "$ROOT/etc/docker/daemon.json"
ht_hook configure; eq "Jetson, daemon.json изменился — 0" 0 "$?"
check "daemon.json изменился — перезапуск" ht_called '^systemctl --no-block try-restart docker.service$'
docker_root ubuntu jammy
echo '# R36 (release), REVISION: 4.3' > "$ROOT/etc/nv_tegra_release"
mkdir -p "$ROOT/etc/docker"
echo '{}' > "$ROOT/etc/docker/daemon.json"
ht_hook configure; eq "Jetson, демон не запущен — 0" 0 "$?"
check_not "демон не запущен — перезапуска нет" ht_called 'restart'
docker_root
mkdir -p "$ROOT/etc/docker"
echo '{}' > "$ROOT/etc/docker/daemon.json"
: > "$FAKE/docker-active"
ht_hook configure; eq "не Jetson — 0" 0 "$?"
check_not "не Jetson — перезапуска нет" ht_called 'restart'
check_not "configure не зовёт блокирующий systemctl start/restart" ht_called '^systemctl (start|restart) '

echo "== remove =="
docker_root ubuntu jammy
echo '# R36 (release), REVISION: 4.3' > "$ROOT/etc/nv_tegra_release"
: > "$FAKE/pkgs/docker-ce"
ht_hook install; eq "install перед remove — 0" 0 "$?"
: > "$FAKE/calls"
ht_hook remove; eq "remove — 0" 0 "$?"
check "свои пакеты сняты (remove, не purge: данные /var/lib/docker остаются)" \
    ht_called '^apt-get .*remove .*docker-ce-cli'
check_not "purge не зовётся" ht_called '^apt-get .*purge'
check "стоявший раньше docker-ce оставлен" installed docker-ce
check_not "доставленный docker-ce-cli снят" installed docker-ce-cli
check_not "toolkit снят" installed nvidia-container-toolkit
check_not "источник Docker снят" test -e "$SRC"
check_not "ключ Docker снят" test -e "$ROOT/etc/apt/keyrings/docker.asc"
check_not "свой источник NVIDIA снят" test -e "$NVSRC"
check_not "ключ NVIDIA снят" test -e "$ROOT/etc/apt/keyrings/nvidia-jetson.asc"
check "списки apt обновлены" ht_called '^apt-get .*update'
check_not "запись своих снята" test -e "$STATE/packages"
: > "$FAKE/calls"
ht_hook remove; eq "повтор remove — 0" 0 "$?"
check_not "повтор: apt-get remove не зовётся" ht_called '^apt-get .*remove'
docker_root
mkdir -p "$STATE"
printf 'docker-ce\n' > "$STATE/packages"
: > "$FAKE/pkgs/docker-ce"
: > "$FAKE/apt-fails-remove"
ht_hook remove; eq "apt-get remove упал — 1" 1 "$?"
check "сбой remove — запись сохранена для повтора" test -s "$STATE/packages"
# apt would take a package installed later on top of ours: refuse, change nothing.
docker_root
mkdir -p "$STATE"
printf 'docker-ce\ncontainerd.io\n' > "$STATE/packages"
: > "$FAKE/pkgs/docker-ce"; : > "$FAKE/pkgs/containerd.io"
echo 'Remv nvidia-container-toolkit [1.17.8-1]' > "$FAKE/sim-extra"
ht_hook remove; eq "симуляция снимает чужой пакет — 1" 1 "$?"
check "симуляция спрошена" ht_called '^apt-get -s remove docker-ce containerd.io$'
check "чужой пакет назван" grep -q 'nvidia-container-toolkit' "$ROOT/out"
check_not "ничего не снято" ht_called '^apt-get -q -y remove'
check "docker-ce на месте" installed docker-ce
check "запись осталась" test -s "$STATE/packages"

ht_done
