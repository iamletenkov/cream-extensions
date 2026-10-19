#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the pixelflux-v4l2m2m extension (cream/v1): manifest, hooks install,
# configure and remove on a scratch root (CREAM_ROOT) the way cream runs them.
# The Selkies AppImage is a fake tree whose python answers the probes from
# $FAKE; dpkg and systemctl are fakes. root, systemd and a board with a V4L2
# M2M encoder are not needed.
#
#   extensions/debian/pixelflux-v4l2m2m/tests/test-pixelflux-v4l2m2m.sh   code 0 — all passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

VER=2.0.0

# pf_root: selkies installed; the module carries the v4l2m2m backend and the
# probe answers "v4l2m2m".
pf_root() {
    ht_root "$EXT"
    mkdir -p "$ROOT/opt/selkies/$VER/usr/conda/bin" "$ROOT/opt/selkies/$VER/lib" "$ROOT/dev"
    ln -s "$ROOT/opt/selkies/$VER" "$ROOT/opt/selkies/current"
    MOD="$ROOT/opt/selkies/$VER/lib/pixelflux.so"
    printf 'blob\0V4L2 M2M encoder on %%s\0blob' > "$MOD"
    echo v4l2m2m > "$FAKE/backend"
    printf '#!/usr/bin/env bash\nFAKE=%q\nMOD=%q\n' "$FAKE" "$MOD" > "$ROOT/opt/selkies/$VER/usr/conda/bin/python"
    cat >> "$ROOT/opt/selkies/$VER/usr/conda/bin/python" <<'PY'
echo "$2" >> "$FAKE/python.calls"
case "$2" in
    *__file__*) echo "$MOD" ;;
    *hardware_encoders*) echo "probe noise"; echo "BACKEND=$(cat "$FAKE/backend")" ;;
    *) exit 3 ;;
esac
PY
    chmod +x "$ROOT/opt/selkies/$VER/usr/conda/bin/python"
    ht_fake dpkg 'echo arm64'
    ht_fake systemctl
    STAMP="$ROOT/var/lib/cream/ext/pixelflux-v4l2m2m/stamp"
}
mf() { python3 -c 'import sys,yaml; m=yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXT/extension.yaml" "$1"; }
probed() { grep -q hardware_encoders "$FAKE/python.calls" 2>/dev/null; }

echo "== манифест и раскладка =="
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "name" pixelflux-v4l2m2m "$(mf 'm["name"]')"
eq "мажор +1 (Р1)" 2.0.0 "$(mf 'm["version"]')"
eq "cream 1.1 (graphical)" ">=1.1.0" "$(mf 'm["cream"]')"
eq "arm64" "arm64" "$(mf '" ".join(m["platform"]["arch"])')"
eq "live: yes" yes "$(mf 'm["targets"]["live"]')"
eq "стадия graphical" graphical "$(mf 'm["hooks"]["configure"]["stage"]')"
eq "хуки" "configure install remove" "$(mf '" ".join(sorted(m["hooks"]))')"
eq "requires" "web-remote-desktop" "$(mf '" ".join(m["requires"])')"
eq "provides" "hardware-video-encoding" "$(mf '" ".join(m["provides"])')"
eq "conflicts.extensions" "pixelflux-tegra" "$(mf '" ".join(m["conflicts"]["extensions"])')"
for f in hooks/install hooks/configure hooks/remove; do check "$f исполняемый" test -x "$EXT/$f"; done
for f in install.sh configure.sh verify-pixelflux-v4l2m2m.service; do
    check_not "layout 2: $f не остался в корне" test -e "$EXT/$f"
done

echo "== install на живой машине: кодер есть =="
pf_root
ht_hook install; eq "install — 0" 0 "$?"
check "живая проба бэкенда" probed
eq "отпечаток в состоянии" "prefix=/opt/selkies/$VER" "$(cat "$STAMP")"
check_not "в дерево selkies не пишет" bash -c "find '$ROOT/opt/selkies' -newer '$MOD' -type f | grep -q ."
check_not "службы не трогает" ht_called '^systemctl'
s1="$(stat -c '%i %Y' "$STAMP")"
ht_hook install; eq "повтор — 0" 0 "$?"
eq "повтор: отпечаток не переписан" "$s1" "$(stat -c '%i %Y' "$STAMP")"

echo "== install: нет M2M-кодера на живой машине — 20 =="
pf_root; echo none > "$FAKE/backend"
ht_hook install; eq "live, бэкенд не v4l2m2m — 20" 20 "$?"
check_not "отпечатка нет" test -e "$STAMP"
pf_root; ht_fake dpkg 'echo amd64'
ht_hook install; eq "не arm64 — 20" 20 "$?"

echo "== install на сборке: устройств нет, пробы нет =="
pf_root; echo none > "$FAKE/backend"
HT_PHASE=build ht_hook install; eq "build — 0" 0 "$?"
check_not "на сборке живой пробы нет" probed
check "отпечаток есть" test -f "$STAMP"

echo "== install: без selkies или без бэкенда — отказ =="
pf_root; rm -f "$ROOT/opt/selkies/current"
ht_hook install; check_not "нет selkies — не 0" test "$?" -eq 0
pf_root; printf 'blob' > "$MOD"
ht_hook install; check_not "нет бэкенда v4l2m2m — не 0" test "$?" -eq 0
check_not "отпечатка нет" test -e "$STAMP"

echo "== install: отпечаток не по ссылке =="
pf_root; mkdir -p "$(dirname "$STAMP")" "$ROOT/victim"; echo keep > "$ROOT/victim/f"; ln -s "$ROOT/victim/f" "$STAMP"
ht_hook install; eq "install — 0" 0 "$?"
eq "цель ссылки не тронута" keep "$(cat "$ROOT/victim/f")"
check "отпечаток — обычный файл" test -f "$STAMP" -a ! -L "$STAMP"

echo "== configure =="
pf_root; ht_hook install
ht_hook configure CREAM_REASON=boot; eq "v4l2m2m — 0" 0 "$?"
check "бэкенд объявлен" grep -q 'v4l2m2m' "$ROOT/out"
echo none > "$FAKE/backend"
ht_hook configure CREAM_REASON=boot; eq "кодера нет — предупреждение и 0 (Р11)" 0 "$?"
check "предупреждение про узлы" grep -q '/dev/video' "$ROOT/out"
printf 'x\033[2Jy' > "$FAKE/backend"
ht_hook configure CREAM_REASON=boot; eq "мусор от модуля — 0" 0 "$?"
check_not "управляющие знаки модуля не в журнале" grep -q $'\033' "$ROOT/out"
pf_root
ht_hook configure CREAM_REASON=boot; eq "нет отпечатка — 0" 0 "$?"
check "подсказка переустановки" grep -q 'cream install' "$ROOT/out"
check_not "без отпечатка пробы нет" probed
pf_root; ht_hook install; rm -f "$ROOT/opt/selkies/current"
ht_hook configure CREAM_REASON=boot; eq "нет selkies — 0" 0 "$?"
pf_root; ht_hook install
mkdir -p "$ROOT/opt/selkies/2.1.0"; cp -a "$ROOT/opt/selkies/$VER/." "$ROOT/opt/selkies/2.1.0/"
ln -sfn "$ROOT/opt/selkies/2.1.0" "$ROOT/opt/selkies/current"
ht_hook configure CREAM_REASON=boot; eq "AppImage подняли — 0" 0 "$?"
check "подсказка --reinstall" grep -q 'cream install --reinstall pixelflux-v4l2m2m' "$ROOT/out"

echo "== remove =="
pf_root; ht_hook install
ht_hook remove; eq "remove — 0" 0 "$?"
check_not "отпечаток снят" test -e "$STAMP"
ht_hook remove; eq "повтор — 0" 0 "$?"

echo "== имена layout 2 =="
# check-names: off
check_not "нет /opt/bisquite, .bisquite-, BISQUITE_" \
    grep -rqE '/opt/bisquite|\.bisquite-|BISQUITE_' "$EXT/hooks" "$EXT/extension.yaml"
# check-names: on

ht_done
