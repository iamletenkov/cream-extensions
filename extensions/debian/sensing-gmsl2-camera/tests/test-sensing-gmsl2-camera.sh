#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the sensing-gmsl2-camera extension (cream/v1), what can be checked
# without a board:
#   - nvisppg.sh: L4T release, overlay download with sha256, the libnvisppg.so
#     swap through dpkg-divert on a scratch root, and its undo;
#   - kernel-hold.sh: apt-mark hold of the L4T kernel packages on fakes;
#   - the manifest, files/ (units, udev rule) and actions;
#   - hooks install / apply / remove on a scratch root (CREAM_ROOT) the way
#     cream runs them: fake git, curl, apt-get, apt-mark, dpkg-query, depmod,
#     systemctl, v4l2-ctl; sha256sum is the real one with the fixture sums
#     mapped onto the pinned ones ($FAKE/shamap), dpkg-divert is the real one
#     with --root. root, network and a board are not needed.
#
#   extensions/debian/sensing-gmsl2-camera/tests/test-sensing-gmsl2-camera.sh   code 0 — all passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
X="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$X/../../../tools/hooktest.sh"
ht_init
T="$HT_TMP"
q() { "$@" >/dev/null 2>&1; }

KV=5.15.148-tegra
DTB=tegra234-p3737-0000+p3701-0000-nv.dtb
R3643='# R36 (release), REVISION: 4.3, GCID: 38968081, BOARD: generic, EABI: aarch64, DATE: Wed Jan  8 01:49:37 UTC 2025'
L=usr/lib/aarch64-linux-gnu/nvidia/libnvisppg.so
pin() { grep -oE "^$1=[0-9a-f]{64}$" "$X/hooks/install" | cut -d= -f2; }

# Run a function of nvisppg.sh in a clean shell against root $1.
nv() { local root="$1"; shift; NVISPPG_ROOT="$root" bash -c 'set -uo pipefail; . "$0/nvisppg.sh"; "$@"' "$X" "$@"; }
release_file() { mkdir -p "$1/etc"; printf '%s\n' "$2" > "$1/etc/nv_tegra_release"; }

echo "== nvisppg.sh: релиз L4T =="
release_file "$T/r3643" "$R3643"
release_file "$T/r3644" '# R36 (release), REVISION: 4.4, GCID: 41062509, BOARD: generic, EABI: aarch64'
release_file "$T/r3261" '# R32 (release), REVISION: 6.1, GCID: 27863751, BOARD: t210ref, EABI: aarch64'
release_file "$T/rbad"  'not a release line'
eq "36.4.3 из nv_tegra_release" 36.4.3 "$(nv "$T/r3643" nvisppg_l4t_release)"
eq "32.6.1 из nv_tegra_release" 32.6.1 "$(nv "$T/r3261" nvisppg_l4t_release)"
check_not "неразборчивая строка — отказ" q nv "$T/rbad" nvisppg_l4t_release
check     "барьер: 36.4.3 проходит"      q nv "$T/r3643" nvisppg_gate 36.4.3
check_not "барьер: 36.4.4 — отказ"       q nv "$T/r3644" nvisppg_gate 36.4.3
check_not "барьер: 32.6.1 — отказ"       q nv "$T/r3261" nvisppg_gate 36.4.3
check_not "барьер: файла нет — отказ"    q nv "$T/none" nvisppg_gate 36.4.3

echo "== nvisppg.sh: оверлей камер, скачивание и сверка =="
mkdir -p "$T/src/Linux_for_Tegra"
echo overlay-lib > "$T/src/Linux_for_Tegra/libnvisppg.so"
echo eula > "$T/src/Linux_for_Tegra/EULA-public.txt"
tar -cjf "$T/overlay.tbz2" -C "$T/src" Linux_for_Tegra
TBZ="$(sha256sum "$T/overlay.tbz2" | cut -d' ' -f1)"
LIBSUM="$(sha256sum "$T/src/Linux_for_Tegra/libnvisppg.so" | cut -d' ' -f1)"
ZERO=0000000000000000000000000000000000000000000000000000000000000000
mkdir -p "$T/f1" "$T/f2" "$T/f3" "$T/f4"
check     "сумма сошлась — библиотека извлечена" q nv / nvisppg_fetch "file://$T/overlay.tbz2" "$TBZ" "$LIBSUM" "$T/f1"
check     "…и это она"                           cmp -s "$T/f1/libnvisppg.so" "$T/src/Linux_for_Tegra/libnvisppg.so"
check_not "sha256 архива не та — отказ"          q nv / nvisppg_fetch "file://$T/overlay.tbz2" "$ZERO" "$LIBSUM" "$T/f2"
check_not "…и библиотеки нет"                    test -e "$T/f2/libnvisppg.so"
check_not "sha256 библиотеки не та — отказ"      q nv / nvisppg_fetch "file://$T/overlay.tbz2" "$TBZ" "$ZERO" "$T/f3"
check_not "не скачалось — отказ"                 q nv / nvisppg_fetch "file://$T/missing.tbz2" "$TBZ" "$LIBSUM" "$T/f4"

echo "== nvisppg.sh: подмена libnvisppg.so и её снятие =="
STOCK="$(printf 'stock-lib\n' | sha256sum | cut -d' ' -f1)"
mkroot() {
    local r="$1"
    mkdir -p "$r/usr/lib/aarch64-linux-gnu/nvidia" "$r/var/lib/dpkg"
    ln -s nvidia "$r/usr/lib/aarch64-linux-gnu/tegra"
    printf '%s\n' "${2:-stock-lib}" > "$r/$L"
    chmod 0644 "$r/$L"
}
mkroot "$T/i1"
check     "штатная → оверлей"                q nv "$T/i1" nvisppg_install "$T/f1/libnvisppg.so" "$STOCK" "$LIBSUM"
check     "…на месте оверлей"                cmp -s "$T/i1/$L" "$T/f1/libnvisppg.so"
check     "…штатная сохранена в .distrib"    grep -qx stock-lib "$T/i1/$L.distrib"
eq        "…права 0644" 644 "$(stat -c %a "$T/i1/$L")"
check     "…отведение записано в dpkg"       grep -qx "/$L.distrib" "$T/i1/var/lib/dpkg/diversions"
check     "повторный прогон — без изменений" q nv "$T/i1" nvisppg_install "$T/f1/libnvisppg.so" "$STOCK" "$LIBSUM"
check     "…оверлей и .distrib те же"        bash -c "cmp -s '$T/i1/$L' '$T/f1/libnvisppg.so' && grep -qx stock-lib '$T/i1/$L.distrib'"
check     "снятие: штатная вернулась"        q nv "$T/i1" nvisppg_remove "$STOCK" "$LIBSUM"
check     "…это штатная"                     grep -qx stock-lib "$T/i1/$L"
check_not "….distrib не осталось"            test -e "$T/i1/$L.distrib"
check_not "…отведения в dpkg нет"            grep -q libnvisppg "$T/i1/var/lib/dpkg/diversions"
check     "повторное снятие — 0"             q nv "$T/i1" nvisppg_remove "$STOCK" "$LIBSUM"
mkroot "$T/i2" overlay-lib
check     "база до 2026-09-19 (уже оверлей)" q nv "$T/i2" nvisppg_install "$T/f1/libnvisppg.so" "$STOCK" "$LIBSUM"
check     "…отведение без переименования"    bash -c "grep -qx '/$L.distrib' '$T/i2/var/lib/dpkg/diversions' && [ ! -e '$T/i2/$L.distrib' ]"
mkroot "$T/i3" other-lib
check_not "неизвестная ревизия — отказ"      q nv "$T/i3" nvisppg_install "$T/f1/libnvisppg.so" "$STOCK" "$LIBSUM"
check     "…файл не тронут"                  grep -qx other-lib "$T/i3/$L"
mkdir -p "$T/i4/usr/lib/aarch64-linux-gnu/nvidia"
check_not "библиотеки нет — отказ"           q nv "$T/i4" nvisppg_install "$T/f1/libnvisppg.so" "$STOCK" "$LIBSUM"
mkroot "$T/i5"; rm "$T/i5/usr/lib/aarch64-linux-gnu/tegra"; mkdir -p "$T/i5/usr/lib/aarch64-linux-gnu/tegra"
printf 'stock-lib\n' > "$T/i5/usr/lib/aarch64-linux-gnu/tegra/libnvisppg.so"
check_not "tegra/ — не ссылка на nvidia/ — отказ" q nv "$T/i5" nvisppg_install "$T/f1/libnvisppg.so" "$STOCK" "$LIBSUM"
mkroot "$T/i6"
q nv "$T/i6" nvisppg_install "$T/f1/libnvisppg.so" "$STOCK" "$LIBSUM"
echo changed > "$T/i6/$L"
check_not "снятие: библиотеку меняли — отказ" q nv "$T/i6" nvisppg_remove "$STOCK" "$LIBSUM"
check     "…файл не тронут"                   grep -qx changed "$T/i6/$L"

echo "== kernel-hold.sh: apt-mark hold на подставных командах =="
mkdir -p "$T/kbin"
cat > "$T/kbin/dpkg-query" <<'FAKE'
#!/usr/bin/env bash
p="${!#}"
if grep -qxF "$p" <<<"${FAKE_INSTALLED// /$'\n'}"; then printf installed; else exit 1; fi
FAKE
cat > "$T/kbin/apt-mark" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
    hold)
        [ "${FAKE_HOLD_FAIL:-0}" = 1 ] && exit 100
        shift; printf '%s\n' "$*" >> "$FAKE_HOLD.calls"
        for p in "$@"; do [ "$p" = "${FAKE_HOLD_DROP:-}" ] || echo "$p" >> "$FAKE_HOLD"; done ;;
    showhold) [ -f "$FAKE_HOLD" ] && sort -u "$FAKE_HOLD"; exit 0 ;;
    *) exit 2 ;;
esac
FAKE
chmod +x "$T/kbin/dpkg-query" "$T/kbin/apt-mark"
ALL="nvidia-l4t-kernel nvidia-l4t-kernel-dtbs nvidia-l4t-kernel-oot-modules nvidia-l4t-initrd nvidia-l4t-kernel-headers nvidia-l4t-kernel-oot-headers nvidia-l4t-display-kernel"
kh() { PATH="$T/kbin:$PATH" bash -c 'set -uo pipefail; . "$0/kernel-hold.sh"; sensing_kernel_hold' "$X"; }
held() { sort -u "$1" | tr '\n' ' ' | sed 's/ $//'; }
sorted() { tr ' ' '\n' <<<"$1" | sort -u | tr '\n' ' ' | sed 's/ $//'; }
export FAKE_HOLD="$T/h1" FAKE_INSTALLED="$ALL"
check     "все семь установлены — закреплены все" q kh
eq        "…apt-mark hold получил ровно семь" "$(sorted "$ALL")" "$(held "$T/h1")"
eq        "…одним вызовом" 1 "$(wc -l < "$T/h1.calls")"
check     "повторный прогон — снова успех"        q kh
export FAKE_HOLD="$T/h2" FAKE_INSTALLED="nvidia-l4t-kernel nvidia-l4t-kernel-dtbs nvidia-l4t-kernel-oot-modules nvidia-l4t-initrd"
check     "без заголовков и display-kernel — успех" q kh
eq        "…закреплены только установленные" "$(sorted "$FAKE_INSTALLED")" "$(held "$T/h2")"
check     "…о пропущенных — предупреждение" grep -q 'не установлены, закреплять нечего: nvidia-l4t-kernel-headers' <<<"$(kh 2>&1)"
export FAKE_HOLD="$T/h3" FAKE_INSTALLED=""
check     "ядра L4T в dpkg нет — не отказ"        q kh
check_not "…и apt-mark hold не звался"            test -e "$T/h3.calls"
export FAKE_HOLD="$T/h4" FAKE_INSTALLED="$ALL" FAKE_HOLD_FAIL=1
check_not "apt-mark hold упал — отказ"            q kh
unset FAKE_HOLD_FAIL
export FAKE_HOLD="$T/h5" FAKE_HOLD_DROP=nvidia-l4t-kernel-oot-modules
check_not "hold не закрепил oot-modules — отказ"  q kh
unset FAKE_HOLD_DROP FAKE_HOLD FAKE_INSTALLED
for p in $ALL; do
    check "README называет $p" grep -qF "\`$p\`" "$X/README.md"
done
check "README: как снять руками (apt-mark unhold)" grep -qF 'sudo apt-mark unhold nvidia-l4t-kernel ' "$X/README.md"

echo "== манифест, files, действия =="
mf() { python3 -c 'import sys,yaml; m=yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$X/extension.yaml" "$1"; }
eq "schema" cream/v1 "$(mf 'm["schema"]')"
eq "мажор 5" 5 "$(mf 'm["version"].split(".")[0]')"
eq "cream 1.0" ">=1.0.0" "$(mf 'm["cream"]')"
eq "только arm64" arm64 "$(mf '" ".join(m["platform"]["arch"])')"
eq "build: exec" exec "$(mf 'm["targets"]["build"]')"
eq "live: confirm" confirm "$(mf 'm["targets"]["live"]')"
check "live_note называет ядро и перезагрузку" bash -c 'grep -q "ядр" <<<"$1" && grep -q "перезагруз" <<<"$1"' _ "$(mf 'm["targets"]["live_note"]')"
eq "provides" gmsl2-camera "$(mf '" ".join(m["provides"])')"
eq "хуки" "apply install remove" "$(mf '" ".join(sorted(m["hooks"]))')"
eq "ключи" "SENSING_BOOST_CLOCK SENSING_CAMERA_CONTROLS SENSING_GMSLMODE" "$(mf '" ".join(sorted(m["config"]["keys"]))')"
eq "GMSLMODE — scope install" install "$(mf 'm["config"]["keys"]["SENSING_GMSLMODE"]["scope"]')"
eq "действия" "boost-clock camera-profile" "$(mf '" ".join(sorted(m["actions"]))')"
eq "действия из юнитов — lock: none" "none none" "$(mf '" ".join(a["lock"] for a in m["actions"].values())')"
eq "files → цели" \
    "/etc/systemd/system/sensing-gmsl2-camera@.service /etc/systemd/system/sensing-gmsl2-clock.service /etc/udev/rules.d/99-sensing-gmsl2-camera.rules" \
    "$(mf '" ".join(sorted(f["dst"] for f in m["files"]))')"
for f in $(mf '" ".join(f["src"] for f in m["files"])'); do check "files: $f есть" test -f "$X/$f"; done
check "юнит камеры зовёт действие по абсолютному пути" \
    grep -qx 'ExecStart=/opt/cream/ext/sensing-gmsl2-camera/actions/camera-profile %i' "$X/files/sensing-gmsl2-camera@.service"
check "юнит частот зовёт действие по абсолютному пути" \
    grep -qx 'ExecStart=/opt/cream/ext/sensing-gmsl2-camera/actions/boost-clock' "$X/files/sensing-gmsl2-clock.service"
check "юниты читают настройки cream" bash -c "grep -qx 'EnvironmentFile=/etc/cream/sensing-gmsl2-camera/config' '$X/files/sensing-gmsl2-camera@.service' && grep -qx 'EnvironmentFile=/etc/cream/sensing-gmsl2-camera/config' '$X/files/sensing-gmsl2-clock.service'"
check "udev хочет юнит камеры" grep -qF 'ENV{SYSTEMD_WANTS}+="sensing-gmsl2-camera@%k.service"' "$X/files/99-sensing-gmsl2-camera.rules"
check "udev: только узлы videoN" grep -qF 'KERNEL=="video[0-9]*"' "$X/files/99-sensing-gmsl2-camera.rules"
for f in install.sh knobs knobs.apply bisquite-sensing-camera-ctl; do check_not "layout 2: $f не остался" test -e "$X/$f"; done  # check-names: allow — the old CLI name
check "kernel-hold.sh и nvisppg.sh в дереве" test -f "$X/kernel-hold.sh" -a -f "$X/nvisppg.sh"

echo "== действия =="
act_root() {
    ht_root "$X"
    ht_fake v4l2-ctl '
case "$*" in
    *--info*) cat "$FAKE/v4l2-info" 2>/dev/null ;;
    *" -c "*) [[ -e "$FAKE/v4l2-fails" ]] && exit 1; exit 0 ;;
esac'
    echo 'Card type : vi-output, sgx-yuv-gmsl2 30-0062' > "$FAKE/v4l2-info"
}
act_root
ht_action camera-profile -- video3; eq "профиль на узел Sensing — 0" 0 "$?"
check "v4l2-ctl -c с умолчанием" ht_called '^v4l2-ctl -d /dev/video3 -c sensor_mode=1,trig_mode=0,trig_pin=0x00020007$'
act_root
echo 'Card type : UVC Camera' > "$FAKE/v4l2-info"
ht_action camera-profile -- video0; eq "не Sensing — 0, мимо" 0 "$?"
check_not "не Sensing — -c не зовётся" ht_called '^v4l2-ctl .* -c '
act_root
ht_action camera-profile -- 'video0;id'; eq "чужое имя узла — 2" 2 "$?"
check_not "чужое имя — v4l2-ctl не зовётся" ht_called '^v4l2-ctl'
act_root
ht_action camera-profile 'SENSING_CAMERA_CONTROLS=sensor_mode=1;reboot' -- video1; eq "контролы с чужими символами — 1" 1 "$?"
check_not "чужие контролы — -c не зовётся" ht_called '^v4l2-ctl .* -c '
act_root
: > "$FAKE/v4l2-fails"
ht_action camera-profile -- video1; eq "v4l2-ctl не принял — 1" 1 "$?"
act_root
CLK="$ROOT/sys/kernel/debug/bpmp/debug/clk"
for c in vi isp nvcsi emc; do mkdir -p "$CLK/$c"; echo 0 > "$CLK/$c/mrq_rate_locked"; echo 800000000 > "$CLK/$c/max_rate"; echo 1 > "$CLK/$c/rate"; done
ht_action boost-clock; eq "частоты — 0" 0 "$?"
eq "vi: rate = max_rate" 800000000 "$(cat "$CLK/vi/rate")"
eq "emc: заблокирована" 1 "$(cat "$CLK/emc/mrq_rate_locked")"
for c in vi isp nvcsi emc; do echo 1 > "$CLK/$c/rate"; done
ht_action boost-clock SENSING_BOOST_CLOCK=0; eq "SENSING_BOOST_CLOCK=0 — 0" 0 "$?"
eq "частоты не тронуты" 1 "$(cat "$CLK/vi/rate")"
rm -r "$CLK/emc"
ht_action boost-clock; eq "нет emc в debugfs — 1" 1 "$?"

echo "== apply =="
ht_root "$X"
ht_fake systemctl
ht_hook apply; eq "apply в сборке — 0" 0 "$?"
check_not "в сборке systemctl не зовётся" ht_called '^systemctl'
mkdir -p "$ROOT/run/systemd/system"
ht_hook apply; eq "apply на живой — 0" 0 "$?"
check "перезапуск юнитов без блокировки" \
    ht_called '^systemctl --no-block restart sensing-gmsl2-camera@\*\.service sensing-gmsl2-clock\.service$'

# --- hook install / remove on a scratch root ------------------------------------
# Driver package of Sensing as git would check it out, and the stock image.
P="$T/pkg"
mkdir -p "$P/boot" "$P/ko" "$P/dtb/SGX_YUV_GMSL2"
echo sensing-image > "$P/boot/Image"
for k in tegra-camera nvhost-nvcsi-t194 max96712 sgx-yuv-gmsl2 sgcam-gmsl2 pwm-gpio; do echo "sensing $k" > "$P/ko/$k.ko"; done
echo dtbo > "$P/dtb/SGX_YUV_GMSL2/tegra234-camera-sgx-yuv-gmsl2.dtbo"
printf '#!/bin/sh\n' > "$P/install.sh"
MOD="lib/modules/$KV/updates/drivers"

sg_root() {
    ht_root "$X"
    local r="$ROOT"
    mkdir -p "$FAKE/pkgs" "$r/boot/dtb" "$r/boot/extlinux" "$r/var/lib/dpkg" "$r/usr/bin" "$r/var/tmp" \
        "$r/$MOD/media/platform/tegra/camera" "$r/$MOD/video/tegra/host/nvcsi" "$r/$MOD/media/i2c" \
        "$r/usr/lib/aarch64-linux-gnu/nvidia" "$r/etc/systemd/system"
    release_file "$r" "$R3643"
    : > "$r/boot/dtb/kernel_$DTB"
    echo stock-image > "$r/boot/Image"
    printf 'TIMEOUT 30\nDEFAULT primary\n\nLABEL primary\n      MENU LABEL primary kernel\n      LINUX /boot/Image\n      INITRD /boot/initrd\n      APPEND ${cbootargs} root=PARTUUID=1234 rw\n' \
        > "$r/boot/extlinux/extlinux.conf"
    echo "stock tegra-camera" > "$r/$MOD/media/platform/tegra/camera/tegra-camera.ko"
    echo "stock nvcsi" > "$r/$MOD/video/tegra/host/nvcsi/nvhost-nvcsi-t194.ko"
    echo "stock max96712" > "$r/$MOD/media/i2c/max96712.ko"
    ln -s nvidia "$r/usr/lib/aarch64-linux-gnu/tegra"
    echo stock-lib > "$r/$L"
    printf '#!/bin/sh\n' > "$r/usr/bin/v4l2-ctl"; chmod +x "$r/usr/bin/v4l2-ctl"
    : > "$FAKE/holds"
    : > "$FAKE/sim-extra"
    for p in $ALL; do : > "$FAKE/pkgs/$p"; done
    cp "$T/overlay.tbz2" "$FAKE/overlay.tbz2"
    {   echo "$TBZ $(pin NVISPPG_TBZ2_SHA256)"
        echo "$LIBSUM $(pin NVISPPG_OVERLAY_SHA256)"
        echo "$STOCK $(pin NVISPPG_STOCK_SHA256)"; } > "$FAKE/shamap"
    printf -v pq '%q' "$P"
    ht_fake sha256sum '
out="$(/usr/bin/sha256sum "$@")" || exit
while read -r from to; do out="${out//$from/$to}"; done < "$FAKE/shamap"
printf "%s\n" "$out"'
    ht_fake curl '
out=""; while (( $# )); do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
[[ -e "$FAKE/curl-fails" ]] && exit 22
cp "$FAKE/overlay.tbz2" "$out"'
    ht_fake git "PKG=$pq"'
case "$1" in
    clone) mkdir -p "${*: -1}" ;;
    -C) case "$3" in checkout) mkdir -p "$2/$(cat "$FAKE/sparse")"; cp -a "$PKG/." "$2/$(cat "$FAKE/sparse")/" ;;
                     sparse-checkout) [[ "$4" == set ]] && printf "%s" "$5" > "$FAKE/sparse" ;; esac ;;
esac
exit 0'
    ht_fake dpkg-query '
f="" p="${*: -1}"
for a in "$@"; do case "$a" in -f*) f="${a#-f}" ;; esac; done
[[ -e "$FAKE/pkgs/$p" ]] || exit 1
case "$f" in *Status-Status*) printf installed ;; *) printf 1.0 ;; esac'
    ht_fake apt-mark '
case "$1" in
    hold) shift; for p in "$@"; do echo "$p" >> "$FAKE/holds"; done ;;
    unhold) shift; for p in "$@"; do grep -vxF "$p" "$FAKE/holds" > "$FAKE/holds.n" || true; mv "$FAKE/holds.n" "$FAKE/holds"; done ;;
    showhold) sort -u "$FAKE/holds" ;;
esac'
    ht_fake apt-get '
sub="" sim=""
for a in "$@"; do
    case "$a" in -s) sim=1 ;; -*) ;; *) [[ -z "$sub" ]] && { sub="$a"; continue; }
        if [[ -n "$sim" ]]; then echo "Remv $a [1]"; continue; fi
        case "$sub" in install) : > "$FAKE/pkgs/$a"; [[ "$a" == v4l-utils ]] && printf "#!/bin/sh\n" > "$(dirname "$FAKE")/usr/bin/v4l2-ctl" ;;
                       remove) rm -f "$FAKE/pkgs/$a" ;; esac ;;
    esac
done
[[ -n "$sim" ]] && cat "$FAKE/sim-extra"
exit 0'
    ht_fake depmod
    ht_fake systemctl
    EXT_L="$ROOT/boot/extlinux/extlinux.conf"
    STATE="$ROOT/var/lib/cream/ext/sensing-gmsl2-camera"
}

echo "== install: отказы до сети =="
sg_root; rm "$ROOT/etc/nv_tegra_release"
ht_hook install; eq "нет nv_tegra_release — 20" 20 "$?"
check_not "не Jetson — сети нет" ht_called '^(curl|git)'
sg_root; rm "$ROOT/boot/dtb/kernel_$DTB"
ht_hook install; eq "не AGX Orin — 1" 1 "$?"
check_not "не та плата — сети нет" ht_called '^(curl|git)'
sg_root; release_file "$ROOT" '# R36 (release), REVISION: 4.4, GCID: 41062509'
ht_hook install; eq "L4T 36.4.4 — 1" 1 "$?"
check_not "не тот релиз — сети нет" ht_called '^(curl|git)'
sg_root
ht_hook install SENSING_GMSLMODE='1,1,1,1,1,1,1,1;x'; eq "чужой SENSING_GMSLMODE — 1" 1 "$?"
check_not "неверный ключ — сети нет" ht_called '^(curl|git)'

echo "== install: установка =="
sg_root
ht_hook install SENSING_GMSLMODE=1,1,1,1,2,2,0,0; eq "первая установка — 10 (перезагрузка)" 10 "$?"
eq "ядро Sensing на /boot/Image" sensing-image "$(cat "$ROOT/boot/Image")"
eq "штатное — в Image.backup" stock-image "$(cat "$ROOT/boot/Image.backup")"
check "оверлей libnvisppg.so" grep -qx overlay-lib "$ROOT/$L"
check "модули Sensing на месте" grep -qx 'sensing sgx-yuv-gmsl2' "$ROOT/$MOD/media/i2c/sgx-yuv-gmsl2.ko"
check "max96712 — Sensing, не штатный" grep -qx 'sensing max96712' "$ROOT/$MOD/media/i2c/max96712.ko"
check "pwm-gpio" test -f "$ROOT/$MOD/pwm/pwm-gpio.ko"
check "штатные модули сохранены" grep -qx 'stock max96712' "$STATE/orig/$MOD/media/i2c/max96712.ko"
check "depmod под ядро образа" ht_called "^depmod (-b [^ ]+ )?$KV\$"
check "оверлей камер в /boot" test -f "$ROOT/boot/tegra234-camera-sgx-yuv-gmsl2.dtbo"
check "extlinux: DEFAULT JetsonIO" grep -q '^DEFAULT JetsonIO' "$EXT_L"
check "extlinux: запись backup" grep -q '^LABEL backup' "$EXT_L"
check "extlinux: OVERLAYS" grep -qF 'OVERLAYS /boot/tegra234-camera-sgx-yuv-gmsl2.dtbo' "$EXT_L"
eq "extlinux: root= переиспользован в трёх записях" 3 "$(grep -c 'root=PARTUUID=1234' "$EXT_L")"
check "исходный extlinux сохранён" grep -q '^DEFAULT primary' "$STATE/extlinux.conf.orig"
MP="$ROOT/etc/modprobe.d/sensing-gmsl2-camera.conf"
check "режим GMSL по портам" grep -qx 'options sgx_yuv_gmsl2 GMSLMODE_0=1,1,1,1 GMSLMODE_1=2,2,0,0' "$MP"
check "ядро закреплено" grep -qx nvidia-l4t-kernel "$FAKE/holds"
eq "свои hold записаны" "$(sorted "$ALL")" "$(held "$STATE/held")"
check "частоты включены на загрузку" test -L "$ROOT/etc/systemd/system/multi-user.target.wants/sensing-gmsl2-clock.service"
check "пакет драйверов в /opt/sensing" test -f "$ROOT/opt/sensing/install.sh"
check_not "v4l2-ctl был — apt не зовётся" ht_called '^apt-get'
check_not "временный каталог убран" compgen -G "$ROOT/var/tmp/sensing-gmsl2-camera.*"
check_not "имён bisquite в корне нет" bash -c "find '$ROOT/etc' '$ROOT/boot' -name '*bisquite*' | grep -q ."
snap="$(cd "$ROOT" && find boot etc lib usr opt -type f -exec /usr/bin/sha256sum {} + | sort)"
ht_hook install SENSING_GMSLMODE=1,1,1,1,2,2,0,0; eq "повтор — 0 (ничего не поменялось)" 0 "$?"
eq "повтор: файлы те же" "$snap" "$(cd "$ROOT" && find boot etc lib usr opt -type f -exec /usr/bin/sha256sum {} + | sort)"
eq "повтор: штатные копии прежние" "stock max96712" "$(cat "$STATE/orig/$MOD/media/i2c/max96712.ko")"
ht_hook install SENSING_GMSLMODE=1,1,1,1,1,1,1,1; eq "смена режима GMSL — 10" 10 "$?"

echo "== install: v4l-utils и отказы после сети =="
sg_root; rm "$ROOT/usr/bin/v4l2-ctl"
ht_hook install; eq "без v4l2-ctl — 10" 10 "$?"
check "v4l-utils поставлен" ht_called '^apt-get .*install v4l-utils$'
check "v4l-utils записан" grep -qx v4l-utils "$STATE/packages"
sg_root; : > "$FAKE/curl-fails"
ht_hook install; eq "оверлей не скачался — 1" 1 "$?"
eq "ядро не тронуто" stock-image "$(cat "$ROOT/boot/Image")"
sg_root; mv "$P/ko/sgx-yuv-gmsl2.ko" "$T/sgx.ko"
ht_hook install; eq "в пакете нет модуля — 1" 1 "$?"
mv "$T/sgx.ko" "$P/ko/sgx-yuv-gmsl2.ko"

echo "== remove =="
sg_root
MP="$ROOT/etc/modprobe.d/sensing-gmsl2-camera.conf"
ht_hook install >/dev/null
check "перед remove modprobe.d есть" test -f "$MP"
: > "$FAKE/calls"
ht_hook remove; eq "remove — 10 (перезагрузка)" 10 "$?"
eq "штатное ядро вернулось" stock-image "$(cat "$ROOT/boot/Image")"
check_not "Image.backup снят" test -e "$ROOT/boot/Image.backup"
check "extlinux как до установки" grep -q '^DEFAULT primary' "$EXT_L"
check_not "в extlinux нет JetsonIO" grep -q JetsonIO "$EXT_L"
eq "штатный max96712 вернулся" "stock max96712" "$(cat "$ROOT/$MOD/media/i2c/max96712.ko")"
eq "штатный tegra-camera вернулся" "stock tegra-camera" "$(cat "$ROOT/$MOD/media/platform/tegra/camera/tegra-camera.ko")"
check_not "модули Sensing сняты" test -e "$ROOT/$MOD/media/i2c/sgx-yuv-gmsl2.ko"
check "depmod после снятия" ht_called "^depmod (-b [^ ]+ )?$KV\$"
check_not "оверлей камер снят" test -e "$ROOT/boot/tegra234-camera-sgx-yuv-gmsl2.dtbo"
check_not "modprobe.d снят" test -e "$MP"
check_not "автозапуск частот снят" test -L "$ROOT/etc/systemd/system/multi-user.target.wants/sensing-gmsl2-clock.service"
check_not "/opt/sensing снят" test -e "$ROOT/opt/sensing"
check "штатная libnvisppg.so вернулась" grep -qx stock-lib "$ROOT/$L"
check "ядро снято с hold" test ! -s "$FAKE/holds"
check_not "записи сняты" test -e "$STATE/held"
: > "$FAKE/calls"
ht_hook remove; eq "повтор remove — 0" 0 "$?"

echo "== remove: что держит кто-то ещё =="
sg_root
echo nvidia-l4t-kernel-headers >> "$FAKE/holds"
ht_hook install >/dev/null
check_not "чужой hold не записан своим" grep -qx nvidia-l4t-kernel-headers "$STATE/held"
mkdir -p "$ROOT/var/lib/cream/ext/other"
echo nvidia-l4t-kernel-dtbs > "$ROOT/var/lib/cream/ext/other/held"
ht_hook remove >/dev/null
check "hold, бывший до cream, остался" grep -qx nvidia-l4t-kernel-headers "$FAKE/holds"
check "hold, записанный другим расширением, остался" grep -qx nvidia-l4t-kernel-dtbs "$FAKE/holds"
check_not "свой hold снят" grep -qx nvidia-l4t-kernel "$FAKE/holds"

echo "== remove: отказы до изменений =="
sg_root
ht_hook install >/dev/null
mkdir -p "$ROOT/lib/modules/$KV/updates/can-usb"; : > "$ROOT/lib/modules/$KV/updates/can-usb/gs_usb.ko"
ht_hook remove; eq "модули can-usb под ядро Sensing — 1" 1 "$?"
check "can-usb назван" grep -q 'can-usb' "$ROOT/out"
eq "ядро не тронуто" sensing-image "$(cat "$ROOT/boot/Image")"
sg_root
ht_hook install >/dev/null
echo '# edited' >> "$EXT_L"
ht_hook remove; eq "extlinux правили после установки — 1" 1 "$?"
check "подсказка --forget" grep -q 'cream remove --forget sensing-gmsl2-camera' "$ROOT/out"
eq "ядро не тронуто" sensing-image "$(cat "$ROOT/boot/Image")"
sg_root; rm "$ROOT/usr/bin/v4l2-ctl"
ht_hook install >/dev/null
echo 'Remv my-cam-app [1]' > "$FAKE/sim-extra"
ht_hook remove; eq "apt снял бы чужой пакет — 1" 1 "$?"
eq "ядро не тронуто" sensing-image "$(cat "$ROOT/boot/Image")"

ht_done
