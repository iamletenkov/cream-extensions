#!/usr/bin/env bash
# Tests of tools/convert-v1.py on tools/testdata/convert-v1/src/<ext> — copies
# of real layout 2 extensions (docker, code-server, firewall, kiosk,
# nvidia-jetpack, can, x11vnc; tests/ left out, nvidia-jetpack trimmed to the
# files with bisquite names) and the synthetic `edge` (every knobs form).
#
# Each fixture: --out gives exactly the golden manifest, report and tree with
# modes (testdata/convert-v1/expected/<ext>/{extension.yaml,report.txt,tree.txt}); the
# source is not touched; --in-place on a copy gives the same tree; a second run
# over the result changes nothing. Then every draft goes through
# `cream validate` (tools/cream-validate.sh, cream by the pin): drafts that
# need cream >=1.1.0 (stages early/cloud-user/graphical) say so in the report
# and are validated with the stage set to `system` — cream 1.0 checks the rest.
# No docker — that half is skipped with a line.
#
#   tools/test-convert-v1.sh                  code 0 — all checks passed
#   UPDATE_GOLDEN=1 tools/test-convert-v1.sh  rewrite the golden files
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONV="$HERE/convert-v1.py"
FX="$HERE/testdata/convert-v1"

T="$(mktemp -d)"
trap 'rm -r -f -- "$T"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&2; }
eq(){ if [[ "$2" == "$3" ]]; then ok; else bad "$1: ждали [$2], получили [$3]"; fi; }
has(){ if grep -qF -- "$2" <<< "$3"; then ok; else bad "$1: нет [$2] в выводе"; fi; }

# tree DIR: "<mode> <path>" of every file, sorted — exec bits are part of the contract.
tree(){ (cd "$1" && find . -type f -printf '%m %P\n' | LC_ALL=C sort); }
# sums DIR: content and mode of every file.
sums(){ (cd "$1" && find . -type f -printf '%m %P ' -exec sh -c 'sha256sum < "$1"' sh {} \; | LC_ALL=C sort); }

golden(){  # golden NAME FILE ACTUAL
    local exp="$FX/expected/$1/$2"
    if [[ -n "${UPDATE_GOLDEN:-}" ]]; then
        cp -- "$3" "$exp"; ok; return
    fi
    if diff -u -- "$exp" "$3" > "$T/diff" 2>&1; then
        ok
    else
        bad "$1: $2 разошёлся с эталоном"; sed -n '1,40p' "$T/diff" >&2
    fi
}

names=()
for d in "$FX"/src/*; do
    name="$(basename "$d")"
    names+=("$name")
    before="$(sums "$d")"

    out="$T/out/$name"
    "$CONV" "$d" --out "$out" --report "$T/$name.report" 2> "$T/$name.err"; rc=$?
    eq "$name: --out код" 0 "$rc"
    golden "$name" extension.yaml "$out/extension.yaml"
    golden "$name" report.txt "$T/$name.report"
    tree "$out" > "$T/$name.tree"
    golden "$name" tree.txt "$T/$name.tree"
    eq "$name: источник не тронут" "$before" "$(sums "$d")"

    # stdout mode: the same manifest.
    "$CONV" "$d" > "$T/$name.stdout" 2>/dev/null
    eq "$name: манифест в stdout" "$(cat "$out/extension.yaml")" "$(cat "$T/$name.stdout")"

    # --in-place on a copy: the same tree as --out.
    ip="$T/ip/$name"
    mkdir -p "$ip"; cp -a "$d/." "$ip/"
    "$CONV" "$ip" --in-place --report "$T/$name.ip-report" 2>/dev/null; rc=$?
    eq "$name: --in-place код" 0 "$rc"
    eq "$name: --in-place = --out" "$(sums "$out")" "$(sums "$ip")"
    eq "$name: отчёт --in-place = --out" "$(cat "$T/$name.report")" "$(cat "$T/$name.ip-report")"

    # A second run: already cream/v1, nothing changes.
    snap="$(sums "$ip")"
    msg="$("$CONV" "$ip" --in-place 2>&1)"; rc=$?
    eq "$name: повтор код" 0 "$rc"
    has "$name: повтор — уже cream/v1" "уже cream/v1, ничего не меняю" "$msg"
    eq "$name: повтор без изменений" "$snap" "$(sums "$ip")"
done
eq "фикстур" 8 "${#names[@]}"

# Refusals.
mkdir -p "$T/empty"
"$CONV" "$T/empty" 2>/dev/null; eq "нет extension.yaml — код 1" 1 "$?"
mkdir -p "$T/l1"; printf 'name: l1\nversion: 1.0.0\nfamily: deb\n' > "$T/l1/extension.yaml"
msg="$("$CONV" "$T/l1" 2>&1)"; rc=$?
eq "не layout 2 — код 1" 1 "$rc"; has "не layout 2 — причина" "не layout 2" "$msg"
mkdir -p "$T/busy"; : > "$T/busy/x"
"$CONV" "$FX/src/can" --out "$T/busy" 2>/dev/null; eq "--out в непустой каталог — код 1" 1 "$?"
mkdir -p "$T/badknobs"; cp -a "$FX/src/can/." "$T/badknobs/"
mv "$T/badknobs" "$T/can"; printf 'BROKEN "re:^x\n' >> "$T/can/knobs"
msg="$("$CONV" "$T/can" 2>&1)"; rc=$?
eq "битая строка knobs — код 1" 1 "$rc"; has "битая строка knobs — где" "knobs:" "$msg"

# 1.1 stages are marked in the report; cloud-user needs 1.1.1 (ruling R14).
for name in firewall kiosk x11vnc; do
    has "$name: пометка 1.1" "нужен cream >=1.1.0" "$(cat "$T/$name.report")"
done
has "code-server: пометка 1.1.1" "нужен cream >=1.1.1" "$(cat "$T/code-server.report")"
has "code-server: cream >=1.1.1" 'cream: ">=1.1.1"' "$(cat "$T/out/code-server/extension.yaml")"

# cream validate over the drafts.
if [[ -n "${UPDATE_GOLDEN:-}" ]]; then
    echo "эталоны переписаны — cream validate пропущен"
elif ! command -v docker >/dev/null 2>&1; then
    echo "cream validate пропущен: нет docker"
else
    pinned="$(grep -E '^CREAM_VERSION=' "$HERE/cream-pin.env" | tail -n1 | cut -d= -f2-)"
    vdirs=()
    for name in "${names[@]}"; do
        v="$T/val/$name"
        mkdir -p "$v"; cp -a "$T/out/$name/." "$v/"
        # A draft that needs a cream newer than the pin would be set aside as
        # not applicable: its requirement is lowered to the pinned cream.
        need="$(sed -n 's/^cream: ">=\([0-9.]*\)"$/\1/p' "$v/extension.yaml")"
        if [[ -n "$need" && -n "$pinned" && "$need" != "$pinned" \
              && "$(printf '%s\n%s\n' "$need" "$pinned" | sort -V | tail -n1)" == "$need" ]]; then
            sed -i "s/^cream: \">=$need\"/cream: \">=$pinned\"/" "$v/extension.yaml"
        fi
        vdirs+=("$v")
    done
    # cream >= 1.1.0 checks the graph: the libraries the drafts depend on come
    # from the catalog itself.
    libs=("$HERE/../extensions/debian/cloud-user" "$HERE/../extensions/debian/l4t")
    if "$HERE/cream-validate.sh" "${vdirs[@]}" "${libs[@]}" > "$T/validate.log" 2>&1; then
        ok
    else
        bad "cream validate черновиков"; sed -n '1,40p' "$T/validate.log" >&2
    fi
    # Every draft is really checked: none is set aside as "needs a newer cream".
    has "cream validate: проверены все" "расширений $(( ${#names[@]} + ${#libs[@]} )): " "$(cat "$T/validate.log")"
    if grep -q 'неприменим' "$T/validate.log"; then bad "cream validate: черновик отложен как неприменимый"; else ok; fi
    grep -E '^cream [0-9]|без ошибок' "$T/validate.log"
fi

echo "test-convert-v1: ок $pass, сбоев $fail"
(( fail == 0 ))
