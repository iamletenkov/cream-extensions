#!/usr/bin/env bash
# L-раннер: живая установка расширения cream/v1 настоящим cream в контейнере с
# systemd как PID 1 (план 2026-10-19, Task 3).
#
#   tools/live-test.sh [флаги] <расширение>
#
#   --distro D        debian-12 (умолчание; или DISTRO=…) | debian-13 | ubuntu-20.04 | ubuntu-22.04 | ubuntu-24.04
#   --deps "a b"      расширения, которые ставятся раньше, по порядку (с --accept-risk
#                     и --allow-skip: код 20 зависимости — запись skipped, не сбой)
#   --accept-risk     расширение с targets.live: confirm
#   --expect-skip     хук install обязан вернуть 20 (нет устройства/ядра/GPU, рулинг Р11):
#                     установка с --allow-skip, в реестре status: skipped
#   --param K=V       параметр установки (повторяемый)
#   --secret K        секретный ключ: случайное значение через --params-file; его не
#                     должно быть в ps, журнале, реестре и config
#   --memory M        предел памяти контейнера (умолчание 1g; gnome — 2g)
#   --cap CAP         --cap-add контейнеру (повторяемый; firewall — NET_ADMIN)
#   --catalog DIR     где искать расширения: DIR/extensions/<семейство>/<имя> (умолчание — репозиторий)
#   --failed-ignore E юниты, которым разрешено быть в systemctl --failed: ERE с якорями
#                     ^…$, сравнивается с именем юнита целиком; каждый такой юнит
#                     печатается строкой «разрешено упасть: <юнит>»
#   --keep-image      не удалять образ (самопроверка гоняет несколько прогонов подряд)
#   --preinstall "p…" пакеты apt, которые ставятся до cream (стол, поставленный не через cream)
#   --preseed DIR     дерево tests/DIR расширения — в корень контейнера до cream (root:root)
#   --variant V       поверх tests/live.env читается tests/live.V.env (его ключи перекрывают)
#
# Умолчания флагов расширения — в его tests/live.env (строки KEY=value, читаются
# как данные, не исполняются): LIVE_DEPS, LIVE_ACCEPT_RISK=1, LIVE_EXPECT_SKIP=1,
# LIVE_PARAMS="K=V …", LIVE_SECRETS="K …", LIVE_MEMORY, LIVE_CAPS="CAP …",
# LIVE_SNAPSHOT_IGNORE (ERE путей, которым разрешено меняться при --reinstall),
# LIVE_BOOT_CONFIGURE=optional (configure на загрузке может не запускаться),
# LIVE_FAILED_IGNORE (как --failed-ignore: стенд, а не расширение, роняет юнит),
# LIVE_PREINSTALL="p …" и LIVE_PRESEED=DIR (как --preinstall, --preseed; путь — только
# внутри tests/, без ..), LIVE_EXPECT_RESTORED="/путь …" (sha256, режим, владелец и
# ссылки путей после preinstall/preseed совпадают с ними же после remove; нет пути до —
# нет и после), LIVE_DEPS_FORCE_REMOVE="имя …" (после LIVE_DEPS и до расширения —
# cream remove --force этих зависимостей; после install оставшиеся зависимости
# installed, cream check с ними поверх установленного — без ошибок графа),
# LIVE_REMOVE_FORCE=1 (итоговый remove с --force: от расширения зависят оставшиеся),
# LIVE_DISTROS="debian-12 ubuntu-24.04" (матрица CI; LIVE_NIGHTLY_DISTROS,
# LIVE_NIGHTLY_ONLY — её же, tools/live-matrix.sh). Флаги перекрывают файл.
# Наличие tests/live.env — признак L-расширения для CI (ночной прогон, PR).
#
# Сценарий: cream по пину (tools/cream-deb.sh) → preinstall, preseed → dpkg -i, system init, источник path
# с временным каталогом (расширение и deps без tests/) → deps → install → повтор
# install (changed: false) → снимок sha256/режимов /etc, /opt/cream, /usr/local,
# /var/lib/cream/ext → install --reinstall → снимок совпал (идемпотентность §6.3) →
# аудит секретов → дважды docker restart (configure на загрузке) → systemctl --failed пуст,
# cream-configure@<ext> успешен, отметка configure соблюдена (every_boot — хук шёл на
# каждой загрузке, без него — пропуск по отметке), нет «ordering cycle» (журнал,
# systemd-analyze verify) → аудит секретов →
# remove (если есть хук) → расширения нет в cream list, --failed пуст.
# С --expect-skip после install (skipped) — только перезапуск и проверки загрузки.
#
# Контейнер — как cream/test/integration/host.sh: без --privileged, --cgroupns=host,
# cgroup v2 на запись, --tmpfs /run, /run/lock, /tmp, явный --memory, сеть есть
# (apt, загрузки по пину). Весь прогон — под замком flock ($LIVE_LOCK, общий для
# всех worktree хоста): живые прогоны идут по одному. Контейнер (и образ, без
# --keep-image) удаляется в trap. Журналы — .scratchpad/live/<ext>-<distro>/, с
# --variant — .scratchpad/live/<ext>.<вариант>-<distro>/.
#
# Код: 0 — все проверки прошли; 1 — проверка не прошла; 2 — ошибка вызова или окружения.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"

die() { echo "live-test: $*" >&2; exit 2; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# ---------------------------------------------------------------------------
# Arguments
distro="${DISTRO:-}" deps="" accept_risk="" expect_skip="" memory="" catalog="$REPO"
keep_image="${LIVE_KEEP_IMAGE:-}" ext=""
caps=() params=() secrets=()
set_deps="" set_risk="" set_skip="" set_mem="" set_caps="" set_params="" set_secrets=""
failed_ignore="" set_failed_ignore=""
preinstall="" set_preinstall="" preseed="" set_preseed="" variant=""
while (( $# )); do
    case "$1" in
        --distro) distro="${2:?}"; shift 2 ;;
        --preinstall) preinstall="${2-}"; set_preinstall=1; shift 2 ;;
        --preseed) preseed="${2-}"; set_preseed=1; shift 2 ;;
        --variant) variant="${2:?}"; shift 2 ;;
        --deps) deps="${2-}"; set_deps=1; shift 2 ;;
        --accept-risk) accept_risk=1; set_risk=1; shift ;;
        --expect-skip) expect_skip=1; set_skip=1; shift ;;
        --param) params+=("${2:?}"); set_params=1; shift 2 ;;
        --secret) secrets+=("${2:?}"); set_secrets=1; shift 2 ;;
        --memory) memory="${2:?}"; set_mem=1; shift 2 ;;
        --cap) caps+=("${2:?}"); set_caps=1; shift 2 ;;
        --catalog) catalog="$(cd "${2:?}" && pwd)" || die "--catalog $2: нет каталога"; shift 2 ;;
        --failed-ignore) failed_ignore="${2:?}"; set_failed_ignore=1; shift 2 ;;
        --keep-image) keep_image=1; shift ;;
        -h | --help) usage ;;
        -*) die "неизвестный флаг $1 (--help)" ;;
        *) [[ -z "$ext" ]] || die "одно расширение за прогон, лишнее: $1"; ext="$1"; shift ;;
    esac
done
[[ -n "$ext" ]] || usage
[[ "$ext" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "имя расширения «$ext» — не имя"
distro="${distro:-debian-12}"
case "$distro" in
    debian-12 | debian-13 | ubuntu-20.04 | ubuntu-22.04 | ubuntu-24.04) ;;
    *) die "неизвестный дистрибутив «$distro»" ;;
esac

# find_ext <name>: the extension directory in the catalog.
find_ext() {
    local hits=()
    mapfile -t hits < <(find "$catalog/extensions" -mindepth 2 -maxdepth 2 -type d -name "$1" | sort)
    (( ${#hits[@]} == 1 )) || return 1
    [[ -f "${hits[0]}/extension.yaml" ]] || return 1
    printf '%s\n' "${hits[0]}"
}
ext_dir="$(find_ext "$ext")" || die "$ext: нет (или не одно) extensions/*/$ext/extension.yaml в $catalog"

# --variant: tests/live.<variant>.env over tests/live.env.
if [[ -n "$variant" ]]; then
    [[ "$variant" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "--variant $variant: не имя варианта ([a-z0-9-])"
    [[ -f "$ext_dir/tests/live.$variant.env" ]] || die "$ext: нет tests/live.$variant.env (--variant $variant)"
fi
env_files=("$ext_dir/tests/live.env")
[[ -n "$variant" ]] && env_files+=("$ext_dir/tests/live.$variant.env")

# live.env (and the variant's file): data, KEY=value per line; the variant wins
# over live.env, flags win over both.
envval() {
    local f line="" l
    for f in "${env_files[@]}"; do
        [[ -f "$f" ]] || continue
        l="$(grep -E "^$1=" "$f" | tail -n1)" || true
        [[ -n "$l" ]] && line="$l"
    done
    line="${line#*=}"
    line="${line%\"}"; line="${line#\"}"
    printf '%s' "$line"
}
[[ -n "$set_deps" ]] || deps="$(envval LIVE_DEPS)"
[[ -n "$set_risk" ]] || { [[ "$(envval LIVE_ACCEPT_RISK)" == 1 ]] && accept_risk=1; }
[[ -n "$set_skip" ]] || { [[ "$(envval LIVE_EXPECT_SKIP)" == 1 ]] && expect_skip=1; }
[[ -n "$set_mem" ]] || memory="$(envval LIVE_MEMORY)"
memory="${memory:-1g}"
[[ "$memory" =~ ^[0-9]+[kmg]$ ]] || die "--memory $memory: ждали число с k|m|g"
[[ -n "$set_caps" ]] || read -r -a caps <<< "$(envval LIVE_CAPS)"
[[ -n "$set_params" ]] || read -r -a params <<< "$(envval LIVE_PARAMS)"
[[ -n "$set_secrets" ]] || read -r -a secrets <<< "$(envval LIVE_SECRETS)"
snapshot_ignore="$(envval LIVE_SNAPSHOT_IGNORE)"
boot_configure="$(envval LIVE_BOOT_CONFIGURE)"
[[ -n "$set_failed_ignore" ]] || failed_ignore="$(envval LIVE_FAILED_IGNORE)"
# Anchors are mandatory: an unanchored expression would quietly allow every unit
# whose name merely contains it. The expression is only ever used in [[ =~ ]].
if [[ -n "$failed_ignore" ]]; then
    [[ "$failed_ignore" == ^*\$ ]] \
        || die "LIVE_FAILED_IGNORE «$failed_ignore»: нужны якоря ^…\$ (имя юнита целиком)"
    re_rc=0
    # shellcheck disable=SC2319  # status 2 of [[ =~ ]] is a malformed expression
    [[ "x" =~ $failed_ignore ]] || re_rc=$?
    (( re_rc != 2 )) || die "LIVE_FAILED_IGNORE «$failed_ignore»: не регулярное выражение"
fi
read -r -a dep_list <<< "$deps"
for d in "${dep_list[@]}"; do [[ "$d" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "зависимость «$d» — не имя"; done
# A desktop put there before cream (plan 2026-11-12-existing-desktop, Task 4).
[[ -n "$set_preinstall" ]] || preinstall="$(envval LIVE_PREINSTALL)"
[[ -n "$set_preseed" ]] || preseed="$(envval LIVE_PRESEED)"
read -r -a pre_pkgs <<< "$preinstall"
# Package names only (Debian policy, an optional :arch): never an option of apt.
for p in "${pre_pkgs[@]}"; do
    [[ "$p" =~ ^[a-z0-9][a-z0-9+.-]+(:[a-z0-9]+)?$ ]] || die "--preinstall $p: не имя пакета"
done
preseed_dir=""
if [[ -n "$preseed" ]]; then
    if [[ "$preseed" == /* || "$preseed" =~ (^|/)\.\.(/|$) ]]; then
        die "--preseed $preseed: каталог внутри tests/ расширения — без / в начале и без .."
    fi
    tests_real="$(cd "$ext_dir/tests" 2>/dev/null && pwd -P)" || die "--preseed $preseed: у $ext нет tests/"
    preseed_dir="$(cd "$ext_dir/tests/$preseed" 2>/dev/null && pwd -P)" \
        || die "--preseed $preseed: нет каталога tests/$preseed у $ext"
    # A link inside tests/ must not lead out of it.
    [[ "$preseed_dir" == "$tests_real"/* ]] || die "--preseed $preseed: ведёт вне tests/ расширения"
fi
read -r -a restored <<< "$(envval LIVE_EXPECT_RESTORED)"
for p in "${restored[@]}"; do
    if [[ "$p" != /* || "$p" =~ (^|/)\.\.(/|$) || ! "$p" =~ ^[A-Za-z0-9_./+@:-]+$ ]]; then
        die "LIVE_EXPECT_RESTORED $p: нужен абсолютный путь без .. и пробелов"
    fi
done
read -r -a force_remove <<< "$(envval LIVE_DEPS_FORCE_REMOVE)"
for d in "${force_remove[@]}"; do
    [[ " ${dep_list[*]} " == *" $d "* ]] || die "LIVE_DEPS_FORCE_REMOVE: $d не из LIVE_DEPS (${dep_list[*]})"
done
remove_force=""
[[ "$(envval LIVE_REMOVE_FORCE)" == 1 ]] && remove_force=1
for c in "${caps[@]}"; do [[ "$c" =~ ^[A-Z_]+$ ]] || die "--cap $c: не имя capability"; done
for p in "${params[@]}"; do [[ "$p" =~ ^[A-Z][A-Z0-9_]*=.*$ ]] || die "--param $p: ждали KEY=VALUE"; done
for s in "${secrets[@]}"; do [[ "$s" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "--secret $s: не имя ключа"; done

# Manifest facts (python3 + PyYAML, as tools/check.sh).
manifest() {
    python3 - "$1/extension.yaml" "$2" <<'PY'
import sys, yaml
m = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
what = sys.argv[2]
hooks = m.get("hooks") or {}
if what == "schema":
    print(m.get("schema", ""))
elif what in ("remove", "configure"):
    print("1" if what in hooks else "")
elif what == "every_boot":
    conf = hooks.get("configure")
    print("1" if isinstance(conf, dict) and conf.get("every_boot") is True else "")
PY
}
[[ "$(manifest "$ext_dir" schema)" == cream/v1 ]] || die "$ext: не cream/v1 (layout 2 живьём не проверяется)"
has_remove="$(manifest "$ext_dir" remove)"
has_configure="$(manifest "$ext_dir" configure)"
every_boot="$(manifest "$ext_dir" every_boot)"
if (( ${#restored[@]} )) && [[ -z "$has_remove" || -n "$expect_skip" ]]; then
    die "LIVE_EXPECT_RESTORED: сверяется после remove, а у $ext нет хука remove (или прогон с --expect-skip)"
fi
dep_dirs=()
for d in "${dep_list[@]}"; do
    dd="$(find_ext "$d")" || die "зависимость $d: нет в каталоге"
    [[ "$(manifest "$dd" schema)" == cream/v1 ]] || die "зависимость $d: не cream/v1"
    dep_dirs+=("$dd")
done

command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || die "нужен docker"
deb="$("$HERE/cream-deb.sh")" || die "нет cream по пину (tools/cream-deb.sh; локально — CREAM_DEB=<.deb>)"

# ---------------------------------------------------------------------------
# Lock, scratch, cleanup
LOCK="${LIVE_LOCK:-${XDG_RUNTIME_DIR:-/tmp}/cream-extensions-live.lock}"
exec 9>"$LOCK" || die "замок $LOCK не открылся"
if ! flock -n 9; then
    log "жду замок $LOCK (идёт другой живой прогон)"
    flock 9 || die "замок $LOCK"
fi

label="$ext${variant:+.$variant}"
LOGDIR="${LIVE_LOGDIR:-$REPO/.scratchpad/live/$label-$distro}"
rm -r -f -- "$LOGDIR"
mkdir -p "$LOGDIR"
TMP="$(mktemp -d)"
IMAGE="cream-live:$distro"
NAME="cream-live-$label-$distro-$$"
cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    [[ -n "$keep_image" ]] || docker image rm "$IMAGE" >/dev/null 2>&1 || true
    rm -r -f -- "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }
# finish: state of the machine for the post-mortem, the summary, exit.
finish() {
    {
        cx systemctl --failed --no-legend --plain || true
        cx journalctl -b --no-pager -o short-monotonic || true
    } > "$LOGDIR/journal.log" 2>&1
    echo "live-test $label ($distro): проверок $((pass + fail)), не прошло $fail; журналы — $LOGDIR"
    (( fail == 0 )) && exit 0
    exit 1
}
# abort <what>: a failure after which the scenario makes no sense.
abort() { bad "$*"; finish; }

cx() { docker exec -i "$NAME" "$@"; }

# failed_units: lines of `systemctl --failed` minus the units LIVE_FAILED_IGNORE
# allows (whole name, anchored ERE). Runs in $(…), so each allowed unit is
# reported on stderr — the ignore stays visible in the runner's output.
failed_units() {
    local line unit
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        unit="${line%% *}"
        if [[ -n "$failed_ignore" && "$unit" =~ $failed_ignore ]]; then
            echo "     разрешено упасть: $unit" >&2
            continue
        fi
        printf '%s\n' "$line"
    done < <(cx systemctl --failed --no-legend --plain 2>/dev/null)
}

# creamj <log name> <args…>: cream --json in the container; envelope to
# $LOGDIR/<name>.json, stderr to <name>.err; status is cream's code.
creamj() {
    local n="$1"; shift
    cx cream --json "$@" > "$LOGDIR/$n.json" 2> "$LOGDIR/$n.err"
}
# jf <log name> <python expression over j>: a field of a saved envelope.
jf() {
    python3 - "$LOGDIR/$1.json" "$2" <<'PY' 2>/dev/null
import json, sys
try:
    j = json.load(open(sys.argv[1], encoding="utf-8"))
    # eval is the point of the helper: the expressions are this script's own
    # literals, never outside input (the envelope is data, it is only indexed).
    v = eval(sys.argv[2], {"j": j})
except Exception:
    v = ""
print("" if v is None else (str(v).lower() if isinstance(v, bool) else v))
PY
}
tailerr() { tail -n 15 "$LOGDIR/$1.err" | sed 's/^/    /'; }

wait_boot() {
    local s="" _
    for _ in $(seq 1 90); do
        s="$(cx systemctl is-system-running 2>/dev/null)" || true
        case "$s" in running | degraded) return 0 ;; esac
        sleep 1
    done
    log "systemd в $NAME не загрузился: «$s»"
    docker logs "$NAME" 2>&1 | tail -n 20 >&2
    return 1
}

# ---------------------------------------------------------------------------
# Image and container
log "$label ($distro): образ $IMAGE"
base="${distro/-/:}"
docker build -q -t "$IMAGE" --build-arg "BASE=$base" - > "$LOGDIR/image.log" 2>&1 <<'EOF' || die "образ $IMAGE не собрался ($LOGDIR/image.log)"
ARG BASE=debian:12
FROM ${BASE}
ENV DEBIAN_FRONTEND=noninteractive container=docker
RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd systemd-sysv ca-certificates procps dbus curl \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && systemctl mask getty.target console-getty.service systemd-logind.service systemd-firstboot.service
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
EOF

cap_args=()
for c in "${caps[@]}"; do cap_args+=(--cap-add "$c"); done
log "$label ($distro): контейнер $NAME (память $memory${caps[*]:+, cap ${caps[*]}})"
docker run -d --name "$NAME" \
    --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
    --memory "$memory" --pids-limit 4096 "${cap_args[@]}" \
    "$IMAGE" > /dev/null || die "контейнер не запустился"
wait_boot || die "systemd в контейнере не загрузился"

# Catalog: the extension and its deps, without tests/, staged (the shared core
# laid into its consumers, tools/stage-catalog.sh --ext).
mkdir -p "$TMP/cat/extensions"
printf 'schema: cream/v1\nname: live-test\nversion: 0.0.0\nroots: [extensions]\n' > "$TMP/cat/cream-catalog.yaml"
for d in "${dep_dirs[@]}" "$ext_dir"; do
    "$HERE/stage-catalog.sh" --ext "$d" "$TMP/cat/extensions" > /dev/null || die "$d: не собрано"
done
# Params file: plain params and generated secrets (0600 root inside).
declare -A secret_val=()
: > "$TMP/params"
for p in "${params[@]}"; do printf '%s\n' "$p" >> "$TMP/params"; done
for s in "${secrets[@]}"; do
    secret_val[$s]="live-$s-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
    printf '%s=%s\n' "$s" "${secret_val[$s]}" >> "$TMP/params"
done
cx mkdir -p /live || die "docker exec"
docker cp "$TMP/cat" "$NAME:/live/cat" > /dev/null || die "docker cp каталога"
docker cp "$deb" "$NAME:/live/cream.deb" > /dev/null || die "docker cp cream"
docker cp "$TMP/params" "$NAME:/live/params" > /dev/null || die "docker cp параметров"
cx sh -c 'chown -R root:root /live && chmod 0600 /live/params' || die "chown /live"

# restored_snap <name>: type, mode, owner, link target and sha256 of every file
# under the LIVE_EXPECT_RESTORED paths; a missing path is a line of its own.
restored_snap() {
    # shellcheck disable=SC2016  # expanded inside the container
    cx sh -c 'for p do
            if [ -e "$p" ] || [ -L "$p" ]; then
                find "$p" -xdev \( -type f -o -type l -o -type d \) -printf "%y %m %u:%g %p %l\n"
            else
                echo "нет $p"
            fi
        done | LC_ALL=C sort
        for p do [ -e "$p" ] && find "$p" -xdev -type f -print0; done | LC_ALL=C sort -z | xargs -0 -r sha256sum' \
        sh "${restored[@]}" > "$LOGDIR/$1.snap" 2>/dev/null
}

# A desktop put there before cream: packages, then the tree (it may replace a
# file of a package), then what remove has to give back.
if (( ${#pre_pkgs[@]} )) || [[ -n "$preseed_dir" ]] || (( ${#restored[@]} )); then
    echo "== до cream =="
fi
if (( ${#pre_pkgs[@]} )); then
    # shellcheck disable=SC2016  # expanded inside the container
    if cx sh -c 'apt-get update -q && apt-get install -y -q --no-install-recommends "$@"' sh "${pre_pkgs[@]}" \
        > "$LOGDIR/preinstall.log" 2>&1; then
        ok "preinstall: ${pre_pkgs[*]}"
    else
        tail -n 15 "$LOGDIR/preinstall.log" | sed 's/^/    /'
        abort "preinstall: apt-get install ${pre_pkgs[*]} не прошёл ($LOGDIR/preinstall.log)"
    fi
fi
if [[ -n "$preseed_dir" ]]; then
    # Files of root, not of the host user; directories already in the container
    # (/, /etc, …) keep their mode and owner.
    if tar -C "$preseed_dir" --owner=0 --group=0 --numeric-owner -cf - . \
        | cx tar -C / --no-overwrite-dir -xf - > "$LOGDIR/preseed.log" 2>&1; then
        ok "preseed: tests/$preseed → /"
    else
        tail -n 15 "$LOGDIR/preseed.log" | sed 's/^/    /'
        abort "preseed: tests/$preseed не лёг в корень ($LOGDIR/preseed.log)"
    fi
fi
if (( ${#restored[@]} )); then
    restored_snap restored-before
    ok "до cream записаны ${restored[*]} (сверка после remove)"
fi

echo "== cream =="
cx dpkg -i /live/cream.deb > "$LOGDIR/dpkg.log" 2>&1 || abort "dpkg -i cream ($LOGDIR/dpkg.log)"
creamj init system init || { tailerr init; abort "cream system init"; }
creamj source source add live --path /live/cat --sync || { tailerr source; abort "cream source add"; }
ok "cream $(jf init 'j["cream"]'), источник с $(( ${#dep_dirs[@]} + 1 )) расширениями"

# Deps go on with --allow-skip: a dep whose install exits 20 (no kernel/GPU in
# the container) stays in the registry as skipped, and that record is still a
# provider of its capabilities (nvidia -> gpu-driver-nvidia). Told apart by the
# status in cream's envelope, not by arithmetic.
for d in "${dep_list[@]}"; do
    rc=0
    creamj "dep-$d" install --accept-risk --allow-skip "$d" || rc=$?
    if [[ "$rc" != 0 ]]; then
        tailerr "dep-$d"
        abort "зависимость $d: cream install — код $rc"
    fi
    if [[ "$(jf "dep-$d" 'j["result"]["status"]')" == skipped ]]; then
        ok "зависимость $d пропущена (skipped)"
    else
        ok "зависимость $d установлена"
    fi
done
# The provider the machine had before goes, its dependents stay (the move from
# gnome to existing-desktop, spec 2026-11-12-existing-desktop §5).
for d in "${force_remove[@]}"; do
    rc=0
    creamj "force-$d" remove --force "$d" || rc=$?
    if [[ "$rc" != 0 ]]; then
        tailerr "force-$d"
        abort "зависимость $d: cream remove --force — код $rc"
    fi
    ok "зависимость $d снята (remove --force)"
done

install_args=(install)
[[ -n "$accept_risk" ]] && install_args+=(--accept-risk)
[[ -n "$expect_skip" ]] && install_args+=(--allow-skip)
[[ -s "$TMP/params" ]] && install_args+=(--params-file /live/params)
install_args+=("$ext")

# secrets_audit <when>: no secret value in ps, journal, registry, history, config.
secrets_audit() {
    local s v where
    for s in "${secrets[@]}"; do
        v="${secret_val[$s]}"
        where=""
        cx ps -eo args 2>/dev/null | grep -qF -- "$v" && where+=" ps"
        cx journalctl -b --no-pager 2>/dev/null | grep -qF -- "$v" && where+=" журнал"
        cx grep -rqF --exclude-dir=ext -- "$v" /var/lib/cream 2>/dev/null && where+=" /var/lib/cream"
        cx grep -qF -- "$v" "/etc/cream/$ext/config" 2>/dev/null && where+=" config"
        if [[ -z "$where" ]]; then
            ok "$1: секрета $s нет в ps, журнале, реестре, config"
        else
            bad "$1: секрет $s виден:$where"
        fi
    done
}

# snapshot <name>: type, mode, owner, link target and sha256 of every file.
snapshot() {
    # shellcheck disable=SC2016  # expanded inside the container
    cx sh -c 'for d in /etc /opt/cream /usr/local /var/lib/cream/ext; do
            [ -d "$d" ] && find "$d" -xdev \( -type f -o -type l -o -type d \) -printf "%y %m %u:%g %p %l\n"
        done | LC_ALL=C sort
        for d in /etc /opt/cream /usr/local /var/lib/cream/ext; do
            [ -d "$d" ] && find "$d" -xdev -type f -print0
        done | LC_ALL=C sort -z | xargs -0 -r sha256sum' > "$LOGDIR/$1.raw" 2>/dev/null
    if [[ -n "$snapshot_ignore" ]]; then
        grep -vE -- "$snapshot_ignore" "$LOGDIR/$1.raw" > "$LOGDIR/$1.snap" || true
    else
        cp "$LOGDIR/$1.raw" "$LOGDIR/$1.snap"
    fi
}

echo "== install =="
creamj install "${install_args[@]}"; rc=$?
cx rm -f /live/params
status="$(jf install 'j["result"]["status"]')"
code="$(jf install 'j["error"]["code"]')"
if [[ -n "$expect_skip" ]]; then
    if (( rc == 0 )) && [[ "$status" == skipped ]]; then
        ok "install: хук вернул 20, status: skipped (--expect-skip)"
    else
        tailerr install
        abort "install: ждали код 20 хука install (status: skipped), получили код $rc, status «$status»${code:+, $code}"
    fi
else
    if (( rc == 0 )) && [[ "$status" == installed ]]; then
        ok "install: код 0, status: installed"
    elif [[ "$code" == hook.not_applicable ]]; then
        tailerr install
        abort "install: хук вернул 20 (неприменимо) — для такого расширения нужен --expect-skip (LIVE_EXPECT_SKIP=1)"
    else
        tailerr install
        abort "install: код $rc, status «$status»${code:+, $code}"
    fi
fi

# deps_graph_check: after LIVE_DEPS_FORCE_REMOVE — every dependency left is
# installed, and cream check finds the graph whole: the installed minus those
# dependencies as the base (provides from the staged manifests), each of them a
# step `install <dep>` in the order of LIVE_DEPS.
deps_graph_check() {
    local left=() d steps=() bad_deps
    for d in "${dep_list[@]}"; do
        [[ " ${force_remove[*]} " == *" $d "* ]] || left+=("$d")
    done
    (( ${#left[@]} )) || return 0
    creamj list-deps list || { tailerr list-deps; bad "cream list после install"; return 0; }
    bad_deps="$(python3 - "$LOGDIR/list-deps.json" "$TMP/cat/extensions" "$TMP/installed.json" "${left[@]}" <<'PY'
import json, os, sys, yaml
lst, cat, out, *left = sys.argv[1:]
exts = json.load(open(lst, encoding="utf-8"))["result"]["extensions"]
status = {e["name"]: e["status"] for e in exts}
for n in left:
    if status.get(n) != "installed":
        print(f"{n}: {status.get(n, 'нет в cream list')}")
base = []
for e in exts:
    if e["name"] in left:
        continue
    m = os.path.join(cat, e["name"], "extension.yaml")
    prov = []
    if os.path.isfile(m):
        prov = (yaml.safe_load(open(m, encoding="utf-8")) or {}).get("provides") or []
    base.append({"name": e["name"], "version": e["version"], "provides": prov})
json.dump(base, open(out, "w", encoding="utf-8"))
PY
)" || { bad "разбор cream list после install"; return 0; }
    if [[ -z "$bad_deps" ]]; then
        ok "после install зависимости installed: ${left[*]}"
    else
        bad "после install не installed:"
        printf '%s\n' "$bad_deps" | sed 's/^/    /'
    fi
    docker cp "$TMP/installed.json" "$NAME:/live/installed.json" > /dev/null || { bad "docker cp installed.json"; return 0; }
    for d in "${left[@]}"; do steps+=(--step "install $d"); done
    if creamj graph check --catalog live=/live/cat --installed /live/installed.json "${steps[@]}"; then
        ok "cream check: граф цел (поверх установленного — install ${left[*]})"
    else
        tailerr graph
        bad "cream check: $(jf graph 'j["error"]["code"]') — $(jf graph 'j["error"]["message"]')"
    fi
}

if [[ -z "$expect_skip" ]]; then
    (( ${#force_remove[@]} )) && deps_graph_check
    # Repeat without the params file (deleted after install): the keys are in
    # the domain already, nothing is to change.
    repeat=(install)
    [[ -n "$accept_risk" ]] && repeat+=(--accept-risk)
    creamj install2 "${repeat[@]}" "$ext"; rc=$?
    if (( rc == 0 )) && [[ "$(jf install2 'j["result"]["changed"]')" == false ]]; then
        ok "повтор install: changed: false"
    else
        tailerr install2
        bad "повтор install: код $rc, changed «$(jf install2 'j["result"]["changed"]')» (ждали false)"
    fi

    snapshot before
    if creamj reinstall "${repeat[@]}" --reinstall "$ext"; then
        ok "install --reinstall: код 0"
    else
        tailerr reinstall
        bad "install --reinstall: код $?"
    fi
    snapshot after
    if diff -u "$LOGDIR/before.snap" "$LOGDIR/after.snap" > "$LOGDIR/idempotence.diff"; then
        ok "--reinstall не изменил /etc, /opt/cream, /usr/local, /var/lib/cream/ext"
    else
        bad "--reinstall изменил файлы (идемпотентность §6.3), $LOGDIR/idempotence.diff:"
        grep -E '^[-+][^-+]' "$LOGDIR/idempotence.diff" | head -n 20 | sed 's/^/    /'
    fi
    secrets_audit "после install"
fi

boot_cursor=""
# mark_check ROUND UNIT: cream 1.2.0 runs configure at boot only past a stale
# configure mark (cream spec 2026-10-21 §10.7). every_boot: true — the hook ran
# on this boot (no «пропуск, отметка совпала» in the unit journal of this boot);
# without it — the mark written by install/the previous boot matched, unless
# the hook said 20 (the mark is taken away, the next boot runs it again).
mark_check() {
    local round="$1" u="$2" j
    # Not -b: a container shares the boot id of the host kernel, so «this boot»
    # also holds the runs of install and of the previous restart; the journal
    # cursor taken before the restart cuts them off.
    local from=()
    [[ -n "$boot_cursor" ]] && from=(--after-cursor "$boot_cursor")
    j="$(cx journalctl -u "$u" "${from[@]}" --no-pager -o cat 2>/dev/null)"
    if grep -qF "configure $ext: пропуск, отметка совпала" <<< "$j"; then
        if [[ -n "$every_boot" ]]; then
            bad "$round: configure пропущен по отметке, а у $ext every_boot: true"
        else
            ok "$round: configure пропущен по отметке"
        fi
    elif grep -qF "configure $ext: пропущено (код 20)" <<< "$j"; then
        ok "$round: configure вернул 20 — отметка снята, повтор на следующей загрузке"
    elif [[ -n "$every_boot" ]]; then
        ok "$round: configure отработал (every_boot)"
    else
        bad "$round: configure шёл на загрузке без every_boot — отметка не совпала (хук меняет свой вход?)"
        tail -n 5 <<< "$j" | sed 's/^/    /'
    fi
}

# boot_round ROUND: docker restart, then what a boot must give — no failed
# units, no ordering cycle, configure of the extension succeeded, the
# configure mark honoured, secrets not leaked.
boot_round() {
    local round="$1" failed unit _ u state result
    echo "== $round =="
    boot_cursor="$(cx journalctl -n 1 --show-cursor --no-pager -q 2>/dev/null | sed -n 's/^-- cursor: //p')"
    docker restart "$NAME" > /dev/null || abort "docker restart"
    wait_boot || abort "systemd не загрузился после перезапуска"
    failed="$(failed_units)"
    if [[ -z "$failed" ]]; then
        ok "$round: systemctl --failed пуст"
    else
        bad "$round: после перезапуска есть упавшие юниты:"
        printf '%s\n' "$failed" | sed 's/^/    /'
        while read -r unit _; do
            [[ -n "$unit" ]] && cx journalctl -b -u "$unit" --no-pager -n 10 2>/dev/null | sed 's/^/    /'
        done <<< "$failed"
    fi
    # Ordering cycles: the journal of this boot, and systemd-analyze verify of the
    # default target — in a container the cycles broken at boot are logged before
    # journald and can be lost, the verify transaction finds them again.
    {
        cx journalctl -b --no-pager 2>/dev/null
        cx systemd-analyze verify default.target 2>&1
    } | grep -i 'ordering cycle' > "$LOGDIR/cycles.log"
    if [[ ! -s "$LOGDIR/cycles.log" ]]; then
        ok "$round: нет «ordering cycle» (журнал загрузки, systemd-analyze verify default.target)"
    else
        bad "$round: «ordering cycle» в журнале или systemd-analyze verify default.target:"
        head -n 5 "$LOGDIR/cycles.log" | sed 's/^/    /'
    fi
    if [[ -n "$has_configure" && -z "$expect_skip" ]]; then
        u="cream-configure@$ext.service"
        state="$(cx systemctl show -p ActiveState --value "$u" 2>/dev/null)"
        result="$(cx systemctl show -p Result --value "$u" 2>/dev/null)"
        if [[ "$result" == success && "$state" == active ]]; then
            ok "$round: configure $u active, success"; mark_check "$round" "$u"
        elif [[ "$state" == inactive && "$result" == success && "$boot_configure" == optional ]]; then
            ok "$round: configure не запускался (LIVE_BOOT_CONFIGURE=optional)"
        else
            bad "$round: configure $u — $state/$result (configure выходит 0 и без устройства, рулинг Р11)"
        fi
    fi
    [[ -n "$expect_skip" ]] || secrets_audit "$round"
}

boot_round "загрузка"
# The second boot: an every_boot hook runs again, a hook without it is skipped
# by the mark of the first boot (plan 2026-10-21, Task 19).
boot_round "вторая загрузка"

if [[ -n "$has_remove" && -z "$expect_skip" ]]; then
    echo "== remove =="
    remove_args=(remove)
    [[ -n "$remove_force" ]] && remove_args+=(--force)
    rc=0
    creamj remove "${remove_args[@]}" "$ext" || rc=$?
    if (( rc == 0 )); then
        ok "cream ${remove_args[*]}: код 0"
    else
        tailerr remove
        bad "cream ${remove_args[*]}: код $rc"
    fi
    creamj list list
    if [[ "$(jf list '",".join(e["name"] for e in j["result"]["extensions"])')" =~ (^|,)$ext(,|$) ]]; then
        bad "после remove $ext остался в cream list"
    else
        ok "после remove $ext нет в cream list"
    fi
    failed="$(failed_units)"
    if [[ -z "$failed" ]]; then ok "после remove systemctl --failed пуст"; else bad "после remove упавшие юниты: $failed"; fi
    if (( ${#restored[@]} )); then
        restored_snap restored-after
        if diff -u "$LOGDIR/restored-before.snap" "$LOGDIR/restored-after.snap" > "$LOGDIR/restored.diff"; then
            ok "remove вернул как было до cream: ${restored[*]}"
        else
            bad "remove не вернул как было до cream (LIVE_EXPECT_RESTORED), $LOGDIR/restored.diff:"
            grep -E '^[-+][^-+]' "$LOGDIR/restored.diff" | head -n 20 | sed 's/^/    /'
        fi
    fi
fi

finish
