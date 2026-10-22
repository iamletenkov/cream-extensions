#!/usr/bin/env bash
# `cream check` over the catalog: every extension as a line of a future image.
#
# For each extension under the roots of cream-catalog.yaml and each OS of the
# matrix of its platform.family that its platform.os admits (deb: debian:12,
# debian:13, ubuntu:22.04, ubuntu:24.04; openwrt: openwrt:25.12; no platform.os
# — all of the family), on amd64 when the extension
# has it (otherwise its first architecture), over an empty base
# (--installed []), the steps are what an image recipe would write:
#   install --with-deps <provider>   for every capability in requires of the
#                                    extension, its depends and the providers
#                                    (transitively), the first provider by name
#                                    that fits the OS and the architecture
#   install --with-deps <extension>
# cream check (cream spec 2026-10-21 §10.3) answers offline, as the guest
# would: depends, requires, conflicts, platform, `cream:` ranges, mandatory
# `scope: build` keys. A capability nobody in the catalog provides for that
# OS/architecture is a finding of this script (code 1), not of cream.
#
#   tools/cream-check.sh [catalog-repo]   default — this repository
#
# cream comes from the pin tools/cream-pin.env through tools/cream-deb.sh
# (CREAM_DEB=<.deb> locally); it runs inside debian:12 with no network. An
# empty pin — the check is skipped with a line and exit 0. The matrix is
# computed on the host (python3 + PyYAML, as tools/lint-hooks.sh).
#
# Exit: 0 — every case ok; 1 — a case failed (its cream answer is printed);
# 2 — setup failure (pin, download, docker, catalog).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAT="$(cd "${1:-$(dirname "$HERE")}" && pwd)"
IMAGE="debian:12"

die() { echo "cream-check: $*" >&2; exit 2; }

[[ -f "$CAT/cream-catalog.yaml" ]] || die "$CAT: нет cream-catalog.yaml в корне"

rc=0; deb="$("$HERE/cream-deb.sh")" || rc=$?
if (( rc == 3 )); then
    echo "cream check пропущен: пин cream не задан (tools/cream-pin.env; локально — CREAM_DEB=<.deb>)"
    exit 0
fi
(( rc == 0 )) || exit 2

# One case per line: <name>\t<os>\t<arch>\t<step>\t<step>… ; a line starting
# with "!" is a finding of the matrix itself.
# shellcheck disable=SC2016  # Python source
MATRIX_PY='
import pathlib, re, sys, yaml
repo = pathlib.Path(sys.argv[1])
cat = yaml.safe_load(open(repo / "cream-catalog.yaml", encoding="utf-8")) or {}
OSES = [("debian", "12"), ("debian", "13"), ("ubuntu", "22.04"), ("ubuntu", "24.04"), ("openwrt", "25.12")]
# cream check takes the family of the image from the OS: openwrt (ADR 0005 of cream) or deb.
def family_of(os_id):
    return "openwrt" if os_id == "openwrt" else "deb"

def vt(v):
    return tuple(int(x) for x in v.split("."))

def admits(rng, v):
    for part in str(rng or "").split():
        m = re.fullmatch(r"(>=|<=|>|<|=)?(\d+(?:\.\d+)*)", part)
        if not m:
            sys.exit(f"неразборчивая версия ОС: {rng!r}")
        x, y = vt(m[2]), vt(v)
        n = max(len(x), len(y)); x += (0,) * (n - len(x)); y += (0,) * (n - len(y))
        op = m[1] or "="
        if not {">=": y >= x, "<=": y <= x, ">": y > x, "<": y < x, "=": y == x}[op]:
            return False
    return True

exts = {}
for root in cat.get("roots") or []:
    for mf in sorted((repo / root).rglob("extension.yaml")):
        if "tests" in mf.relative_to(repo / root).parts:
            continue
        m = yaml.safe_load(open(mf, encoding="utf-8")) or {}
        exts[m["name"]] = m

def fits(m, os_id, os_ver, arch):
    p = m.get("platform") or {}
    if (p.get("family") or "deb") != family_of(os_id):
        return False
    if arch not in (p.get("arch") or [arch]):
        return False
    oses = p.get("os")
    return oses is None or any(o.get("id") == os_id and admits(o.get("version"), os_ver) for o in oses)

for name in sorted(exts):
    m = exts[name]
    arches = (m.get("platform") or {}).get("arch") or ["amd64"]
    arch = "amd64" if "amd64" in arches else arches[0]
    if not any(fits(m, os_id, os_ver, arch) for os_id, os_ver in OSES):
        print(f"!{name}\t-\t{arch}\tни одной ОС матрицы {OSES} для её platform")
        continue
    for os_id, os_ver in OSES:
        if not fits(m, os_id, os_ver, arch):
            continue
        steps, seen, missing = [], set(), []
        def need(ext, done=None):
            done = set() if done is None else done
            if ext in done or ext not in exts:
                return
            done.add(ext)
            # depends are installed by --with-deps; their requires need providers too.
            for dep in exts[ext].get("depends") or []:
                need(dep.get("name") if isinstance(dep, dict) else dep, done)
            for cap in exts[ext].get("requires") or []:
                if cap in seen:
                    continue
                seen.add(cap)
                prov = [n for n in sorted(exts) if cap in (exts[n].get("provides") or [])
                        and fits(exts[n], os_id, os_ver, arch)]
                if not prov:
                    missing.append(cap)
                    continue
                need(prov[0], done)
                if prov[0] not in steps:
                    steps.append(prov[0])
        need(name)
        case = f"{name}\t{os_id}:{os_ver}\t{arch}"
        if missing:
            caps = ", ".join(missing)
            print(f"!{case}\tспособность {caps}: в каталоге её никто не даёт для этой ОС и архитектуры")
            continue
        print(case + "".join(f"\tinstall --with-deps {s}" for s in steps + [name]))
'
command -v python3 >/dev/null 2>&1 || die "нужен python3 с PyYAML"
matrix="$(python3 -I -c "$MATRIX_PY" "$CAT")" || die "матрица не построена"
[[ -n "$matrix" ]] || die "в каталоге нет расширений"

fail=0
while IFS= read -r line; do
    [[ "$line" == '!'* ]] || continue
    fail=$((fail + 1))
    echo "FAIL ${line#!}" | tr '\t' ' '
done <<< "$matrix"
cases="$(grep -v '^!' <<< "$matrix" || true)"

command -v docker >/dev/null 2>&1 || die "нужен docker"
echo "cream check: случаев $(grep -c . <<< "$cases"), каталог $CAT"
# shellcheck disable=SC2016  # expanded inside the container
inner='set -u
dpkg-deb -x /cream.deb /tmp/cream
cream=/tmp/cream/usr/bin/cream
"$cream" --version
echo "[]" > /tmp/empty.json
n=0; bad=0
while IFS="	" read -r name os arch rest; do
    [ -n "$name" ] || continue
    n=$((n + 1))
    set -- --catalog core=/cat --os "$os" --arch "$arch" --installed /tmp/empty.json
    while [ -n "$rest" ]; do
        step="${rest%%	*}"
        set -- "$@" --step "$step"
        case "$rest" in *"	"*) rest="${rest#*	}" ;; *) rest="" ;; esac
    done
    if ! out="$("$cream" check "$@" 2>&1)"; then
        bad=$((bad + 1))
        echo "FAIL $name $os $arch:"
        printf "%s\n" "$out" | sed "s/^/    /"
    fi
done
echo "cream check: случаев $n, не прошло $bad"
[ "$bad" -eq 0 ]'
crc=0
docker run --rm --network none -i -v "$deb:/cream.deb:ro" -v "$CAT:/cat:ro" "$IMAGE" \
    sh -c "$inner" <<< "$cases" || crc=$?
(( crc == 0 && fail == 0 )) && { echo "cream check: ок"; exit 0; }
echo "cream check: не прошло (см. выше)" >&2
exit 1
