#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the pixelflux-tegra extension (cream/v1): manifest, hooks install,
# configure and remove on a scratch root (CREAM_ROOT) the way cream runs them.
# The Selkies AppImage is a fake tree whose python answers the probes from
# $FAKE; dpkg, nm, gcc, apt-get, systemctl, id, usermod, stat and the cloud-user
# library are fakes. The encoder node is a symlink to /dev/null (a character
# device the tests can make without root). root, systemd and a Jetson are not needed.
#
#   extensions/debian/pixelflux-tegra/tests/test-pixelflux-tegra.sh   code 0 — all passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

VER=2.0.0
LIBDIR=/usr/lib/aarch64-linux-gnu
DROPIN_REL=/etc/systemd/system/selkies@.service.d/10-pixelflux-tegra.conf
SHIM_REL=/var/lib/cream/ext/pixelflux-tegra/gbm_shim.so

# pf_root: a Jetson root with selkies installed; system libxcb and a libgbm that
# has gbm_bo_create_with_modifiers2 (jammy); the backend answers "tegra".
pf_root() {
    ht_root "$EXT"
    echo '# R36 (release), REVISION: 4.3, GCID: 38968081, BOARD: generic, EABI: aarch64' > "$ROOT/etc/nv_tegra_release"
    mkdir -p "$ROOT$LIBDIR" "$ROOT/opt/selkies/$VER/usr/conda/bin" "$ROOT/opt/selkies/$VER/lib" "$ROOT/run/systemd/system" "$ROOT/dev"
    : > "$ROOT$LIBDIR/libxcb.so.1"; : > "$ROOT$LIBDIR/libgbm.so.1"
    ln -s "$ROOT/opt/selkies/$VER" "$ROOT/opt/selkies/current"
    MOD="$ROOT/opt/selkies/$VER/lib/pixelflux.so"
    printf 'blob\0vendor V4L2 encoder\0blob' > "$MOD"
    echo tegra > "$FAKE/backend"
    echo 'gbm_bo_create gbm_bo_create_with_modifiers2' > "$FAKE/gbm-syms"
    printf '#!/usr/bin/env bash\nFAKE=%q\nMOD=%q\n' "$FAKE" "$MOD" > "$ROOT/opt/selkies/$VER/usr/conda/bin/python"
    cat >> "$ROOT/opt/selkies/$VER/usr/conda/bin/python" <<'PY'
echo "${LD_PRELOAD-}" >> "$FAKE/python.preload"
case "$2" in
    *__file__*) echo "$MOD" ;;
    *CaptureSettings*) [[ -e "$FAKE/import-fails" ]] && exit 1; exit 0 ;;
    *hardware_encoders*) echo "Render node 0 encodes H264 on $(cat "$FAKE/backend")"; echo "BACKEND=$(cat "$FAKE/backend")" ;;
    *) exit 3 ;;
esac
PY
    chmod +x "$ROOT/opt/selkies/$VER/usr/conda/bin/python"
    ht_fake dpkg 'echo arm64'
    ht_fake apt-get
    ht_fake nm 'cat "$FAKE/gbm-syms"'
    ht_fake gcc 'while (( $# )); do [[ "$1" == -o ]] && { printf "ELF-shim" > "$2"; }; shift; done; [[ -e "$FAKE/gcc-fails" ]] && exit 1; exit 0'
    ht_fake systemctl '
case "$1" in
    is-active) for a in "$@"; do [[ -e "$FAKE/active-${a%.service}" ]] && exit 0; done; exit 3 ;;
    list-units) cat "$FAKE/units" 2>/dev/null ;;
esac
exit 0'
    : > "$FAKE/units"
    printf '%s\n' 'alice:x:1000:1000::/home/alice:/bin/bash' > "$FAKE/passwd"
    ht_fake id '
case "$1" in
    -u) grep -E "^$2:" "$FAKE/passwd" | cut -d: -f3 ;;
    -nG) cat "$FAKE/groups-$2" 2>/dev/null || echo "$2" ;;
    *) exit 2 ;;
esac'
    ht_fake usermod '[[ -e "$FAKE/usermod-fails" ]] && exit 1; exit 0'
    echo alice > "$FAKE/user"
    LIB="$ROOT/opt/cream/ext/cloud-user/get_cloud_user.sh"
    mkdir -p "$(dirname "$LIB")"
    printf '#!/usr/bin/env bash\ncat %q 2>/dev/null || { echo "Error: no user" >&2; exit 1; }\n' "$FAKE/user" > "$LIB"
    chmod +x "$LIB"
    DROPIN="$ROOT$DROPIN_REL"
    SHIM="$ROOT$SHIM_REL"
    STAMP="$ROOT/var/lib/cream/ext/pixelflux-tegra/stamp"
}
node_v4l2() { ln -s /dev/null "$ROOT/dev/v4l2-nvenc"; }
mf() { python3 -c 'import sys,yaml; m=yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
tree_sum() { (cd "$ROOT" && find etc var opt -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum; find etc var -type l -printf '%p -> %l\n' | LC_ALL=C sort); }
blocking_systemctl() { grep -E '^systemctl (start|restart|stop|reload) ' "$FAKE/calls" | grep -qv -- '--no-block'; }

echo "== манифест и раскладка =="
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "name" pixelflux-tegra "$(mf 'm["name"]')"
eq "мажор +1 (Р1)" 3.0.0 "$(mf 'm["version"]')"
eq "cream 1.1 (graphical)" ">=1.1.0" "$(mf 'm["cream"]')"
eq "arm64" "arm64" "$(mf '" ".join(m["platform"]["arch"])')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "стадия graphical" graphical "$(mf 'm["hooks"]["configure"]["stage"]')"
eq "хуки" "configure install remove" "$(mf '" ".join(sorted(m["hooks"]))')"
eq "requires" "web-remote-desktop" "$(mf '" ".join(m["requires"])')"
eq "provides пусто" "" "$(mf '" ".join(m.get("provides", []))')"
eq "conflicts.extensions" "pixelflux-v4l2m2m" "$(mf '" ".join(m["conflicts"]["extensions"])')"
eq "depends cloud-user" "cloud-user >=1.0.0 <2" "$(mf '" ".join(d["name"]+" "+d["version"] for d in m["depends"])')"
for f in hooks/install hooks/configure hooks/remove; do check "$f исполняемый" test -x "$EXT/$f"; done
check "files/gbm_shim.c" test -f "$EXT/files/gbm_shim.c"
for f in install.sh configure.sh verify-pixelflux-tegra.service gbm_shim.c lib; do
    check_not "layout 2: $f не остался в корне" test -e "$EXT/$f"
done

echo "== install: не Jetson — 20 =="
pf_root; rm -f "$ROOT/etc/nv_tegra_release"
ht_hook install; eq "нет /etc/nv_tegra_release — 20" 20 "$?"
check_not "ничего не записано" test -e "$DROPIN"
pf_root; ht_fake dpkg 'echo amd64'
ht_hook install; eq "не arm64 — 20" 20 "$?"

echo "== install: без selkies — отказ =="
pf_root; rm -f "$ROOT/opt/selkies/current"
ht_hook install; check_not "нет /opt/selkies/current — не 0" test "$?" -eq 0
check_not "drop-in не записан" test -e "$DROPIN"

echo "== install: jammy — без шима =="
pf_root
ht_hook install; eq "install — 0" 0 "$?"
eq "drop-in: LD_PRELOAD системной libxcb" "Environment=LD_PRELOAD=$LIBDIR/libxcb.so.1" "$(grep '^Environment=' "$DROPIN")"
eq "drop-in 0644" 644 "$(stat -c %a "$DROPIN")"
check_not "gcc не зовётся" ht_called '^gcc'
check_not "шима нет" test -e "$SHIM"
check "проверка импорта с той же подкладкой" grep -qx "$LIBDIR/libxcb.so.1" "$FAKE/python.preload"
check "отпечаток в состоянии расширения" grep -q "prefix=/opt/selkies/$VER" "$STAMP"
check_not "в дерево selkies не пишет" test -e "$ROOT/opt/selkies/$VER/.pixelflux-tegra"
check_not "в чужое дерево — ни одного нового файла" bash -c "find '$ROOT/opt/selkies' -newer '$MOD' -type f | grep -q ."
check "daemon-reload на живой машине" ht_called '^systemctl daemon-reload'
check_not "блокирующих start/restart нет" blocking_systemctl
snap="$(tree_sum)"
ht_hook install; eq "повтор — 0" 0 "$?"
eq "повтор ничего не меняет" "$snap" "$(tree_sum)"

echo "== install: focal — шим собирается в состоянии, через временный файл =="
pf_root; echo 'gbm_bo_create' > "$FAKE/gbm-syms"
ht_hook install; eq "install — 0" 0 "$?"
check "gcc с фиксированными флагами и исходником расширения" \
    ht_called "^gcc -shared -fPIC -O2 -o $ROOT/var/lib/cream/ext/pixelflux-tegra/\\.build\\.[A-Za-z0-9]+/gbm_shim\\.so $ROOT/opt/cream/ext/pixelflux-tegra/files/gbm_shim\\.c\$"
eq "шим на месте, 0644" "ELF-shim 644" "$(cat "$SHIM") $(stat -c %a "$SHIM")"
eq "LD_PRELOAD: шим, затем libxcb" "Environment=LD_PRELOAD=$SHIM_REL:$LIBDIR/libxcb.so.1" "$(grep '^Environment=' "$DROPIN")"
check_not "каталог сборки убран" bash -c "ls -a '$ROOT/var/lib/cream/ext/pixelflux-tegra' | grep -q '^\\.build'"
check_not "в домашние каталоги не пишет" test -e "$ROOT/home"
snap="$(tree_sum)"
ht_hook install; eq "повтор — 0" 0 "$?"
eq "повтор: шим и drop-in те же" "$snap" "$(tree_sum)"
pf_root; echo 'gbm_bo_create' > "$FAKE/gbm-syms"; : > "$FAKE/gcc-fails"
ht_hook install; check_not "шим не собрался — не 0" test "$?" -eq 0
check_not "полусобранный шим не лёг" test -e "$SHIM"
check_not "каталог сборки убран и при сбое" bash -c "ls -a '$ROOT/var/lib/cream/ext/pixelflux-tegra' 2>/dev/null | grep -q '^\\.build'"
pf_root; echo 'gbm_bo_create' > "$FAKE/gbm-syms"
mkdir -p "$(dirname "$SHIM")" "$ROOT/victim"; echo keep > "$ROOT/victim/f"; ln -s "$ROOT/victim/f" "$SHIM"
ht_hook install; eq "шим — ссылка: install 0" 0 "$?"
eq "цель ссылки не тронута" keep "$(cat "$ROOT/victim/f")"
check "шим — обычный файл" test -f "$SHIM" -a ! -L "$SHIM"

echo "== install: модуль без бэкенда или не импортируется — отказ =="
pf_root; printf 'blob' > "$MOD"
ht_hook install; check_not "нет бэкенда Tegra — не 0" test "$?" -eq 0
pf_root; : > "$FAKE/import-fails"
ht_hook install; check_not "pixelflux не импортируется — не 0" test "$?" -eq 0
pf_root; rm -f "$ROOT$LIBDIR/libxcb.so.1"
ht_hook install; check_not "нет системной libxcb — не 0" test "$?" -eq 0

echo "== install: drop-in не по ссылкам =="
pf_root; mkdir -p "$(dirname "$DROPIN")" "$ROOT/victim"; echo keep > "$ROOT/victim/f"; ln -s "$ROOT/victim/f" "$DROPIN"
ht_hook install; eq "drop-in — ссылка: install 0" 0 "$?"
eq "цель ссылки не тронута" keep "$(cat "$ROOT/victim/f")"
check "drop-in — обычный файл" test -f "$DROPIN" -a ! -L "$DROPIN"
pf_root; mkdir -p "$ROOT/etc/systemd/system" "$ROOT/victim"; ln -s "$ROOT/victim" "$(dirname "$DROPIN")"
ht_hook install; check_not "каталог drop-in — ссылка: не 0" test "$?" -eq 0
check_not "в цель ссылки ничего не легло" test -e "$ROOT/victim/10-pixelflux-tegra.conf"

echo "== configure: кодер виден =="
pf_root; ht_hook install; node_v4l2; : > "$FAKE/calls"; : > "$FAKE/python.preload"
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
check "бэкенд tegra" grep -q 'tegra' "$ROOT/out"
check "проба с подкладкой из drop-in" grep -qx "$LIBDIR/libxcb.so.1" "$FAKE/python.preload"
check_not "usermod не нужен (0666)" ht_called '^usermod'
check_not "блокирующих systemctl нет" blocking_systemctl

echo "== configure: нет кодера / не тот бэкенд / нет отпечатка — предупреждение и 0 (Р11) =="
pf_root; ht_hook install; : > "$FAKE/python.preload"
ht_hook configure CREAM_REASON=boot; eq "нет узла — 0" 0 "$?"
check "предупреждение про узел" grep -q 'v4l2-nvenc' "$ROOT/out"
check_not "без узла проба не зовётся" grep -q . "$FAKE/python.preload"
pf_root; ht_hook install; node_v4l2; echo x264 > "$FAKE/backend"
ht_hook configure CREAM_REASON=boot; eq "бэкенд x264 — 0" 0 "$?"
check "предупреждение про процессор" grep -q "x264" "$ROOT/out"
pf_root; ht_hook install; node_v4l2; printf 'evil\033[2Jx;rm' > "$FAKE/backend"
ht_hook configure CREAM_REASON=boot; eq "мусор от модуля — 0" 0 "$?"
check_not "управляющие знаки модуля не в журнале" grep -q $'\033' "$ROOT/out"
pf_root; node_v4l2
ht_hook configure CREAM_REASON=boot; eq "нет отпечатка (не установлено) — 0" 0 "$?"
check "предупреждение про переустановку" grep -q 'cream install' "$ROOT/out"
pf_root; ht_hook install; node_v4l2
mkdir -p "$ROOT/opt/selkies/2.1.0"; cp -a "$ROOT/opt/selkies/$VER/." "$ROOT/opt/selkies/2.1.0/"
ln -sfn "$ROOT/opt/selkies/2.1.0" "$ROOT/opt/selkies/current"
ht_hook configure CREAM_REASON=boot; eq "AppImage подняли — 0" 0 "$?"
check "отпечаток не совпал — предупреждение" grep -q 'cream install --reinstall pixelflux-tegra' "$ROOT/out"
pf_root; ht_hook install; node_v4l2; rm -f "$ROOT/opt/selkies/current"
ht_hook configure CREAM_REASON=boot; eq "selkies нет — 0" 0 "$?"
pf_root; ht_hook install; node_v4l2
printf '[Service]\nEnvironment=LD_PRELOAD=/x;y $(id)\n' > "$DROPIN"
ht_hook configure CREAM_REASON=boot; eq "кривая подкладка в drop-in — 0" 0 "$?"
check_not "кривая подкладка не уходит в LD_PRELOAD" grep -qF '$(id)' "$FAKE/python.preload"

echo "== configure: узел JetPack 4 — группа video =="
pf_root; ht_hook install; node_v4l2; ln -s /dev/null "$ROOT/dev/nvhost-msenc"
ht_fake stat 'case "$*" in *%a*) echo 660 ;; *%G*) echo video ;; *) exit 2 ;; esac'
: > "$FAKE/active-selkies@alice"
ht_hook configure CREAM_REASON=boot; eq "configure — 0" 0 "$?"
check "alice — в группу video" ht_called '^usermod -aG video alice$'
check "сессия перезапускается без ожидания" ht_called '^systemctl restart --no-block selkies@alice\.service'
check_not "блокирующих systemctl нет" blocking_systemctl
pf_root; ht_hook install; node_v4l2; ln -s /dev/null "$ROOT/dev/nvhost-msenc"
ht_fake stat 'case "$*" in *%a*) echo 660 ;; *%G*) echo video ;; *) exit 2 ;; esac'
echo 'alice video' > "$FAKE/groups-alice"
ht_hook configure CREAM_REASON=boot; eq "уже в группе — 0" 0 "$?"
check_not "usermod не зовётся" ht_called '^usermod'
pf_root; ht_hook install; node_v4l2; ln -s /dev/null "$ROOT/dev/nvhost-msenc"
ht_fake stat 'case "$*" in *%a*) echo 600 ;; *%G*) echo root ;; *) exit 2 ;; esac'
ht_hook configure CREAM_REASON=boot; eq "группа root — 0 с предупреждением" 0 "$?"
check_not "в группу root не добавляет" ht_called '^usermod'
pf_root; ht_hook install; node_v4l2; ln -s /dev/null "$ROOT/dev/nvhost-msenc"
ht_fake stat 'case "$*" in *%a*) echo 660 ;; *%G*) echo "vid;eo" ;; *) exit 2 ;; esac'
ht_hook configure CREAM_REASON=boot; eq "кривое имя группы — 0" 0 "$?"
check_not "кривая группа не уходит в usermod" ht_called '^usermod'
pf_root; ht_hook install; node_v4l2; ln -s /dev/null "$ROOT/dev/nvhost-msenc"
ht_fake stat 'case "$*" in *%a*) echo 660 ;; *%G*) echo video ;; *) exit 2 ;; esac'
: > "$FAKE/usermod-fails"
ht_hook configure CREAM_REASON=boot; check_not "usermod отказал — сбой" test "$?" -eq 0
pf_root; ht_hook install; node_v4l2; ln -s /dev/null "$ROOT/dev/nvhost-msenc"
ht_fake stat 'case "$*" in *%a*) echo 660 ;; *%G*) echo video ;; *) exit 2 ;; esac'
rm -f "$FAKE/user"
ht_hook configure CREAM_REASON=boot; eq "нет пользователя — 0" 0 "$?"
check_not "usermod не зовётся" ht_called '^usermod'

echo "== configure после install: работающая сессия получает подкладку =="
pf_root; ht_hook install; node_v4l2
printf '%s\n' 'selkies@alice.service loaded active running Selkies' > "$FAKE/units"
ht_hook configure CREAM_REASON=install; eq "configure — 0" 0 "$?"
check "restart --no-block selkies@alice" ht_called '^systemctl restart --no-block selkies@alice\.service'
: > "$FAKE/calls"
ht_hook configure CREAM_REASON=boot; eq "на загрузке — 0" 0 "$?"
check_not "на загрузке сессию не трогает" ht_called '^systemctl restart'

echo "== remove =="
pf_root; echo 'gbm_bo_create' > "$FAKE/gbm-syms"; ht_hook install
mkdir -p "$(dirname "$DROPIN")"; echo keep > "$(dirname "$DROPIN")/20-other.conf"
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "drop-in снят" test -e "$DROPIN"
check "чужой drop-in на месте" test -f "$(dirname "$DROPIN")/20-other.conf"
check_not "шим снят" test -e "$SHIM"
check_not "отпечаток снят" test -e "$STAMP"
check "daemon-reload" ht_called '^systemctl daemon-reload'
ht_hook remove; eq "повтор remove — 0" 0 "$?"

echo "== имена layout 2 =="
# check-names: off
check_not "нет /opt/bisquite, .bisquite-, lib/get_cloud_user" \
    grep -rqE '/opt/bisquite|\.bisquite-|lib/get_cloud_user|BISQUITE_' "$EXT/hooks" "$EXT/files" "$EXT/extension.yaml"
# check-names: on

ht_done
