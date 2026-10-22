#!/usr/bin/env bash
# One copy of every shared library in git (spec cream 2026-10-20-openwrt §4.2,
# ruling Р11): lib/<lib>.sh with its consumers lib/<lib>.consumers — the
# Teleport core (teleport-core.sh) and the downloader fetch_verified (fetch.sh).
#
#   tools/check-shared-libs.sh [catalog-repo]    default — this repository
#
# 1. No <lib>.sh copy under extensions/ (tracked or lying in the tree — the
#    staged tree and the snapshot lay it).
# 2. Every consumer uses files/<lib>.sh, and an extension that uses it is a
#    consumer (otherwise nothing lays it there). "Uses" depends on the rule of
#    the list — a line `# rule: files` in lib/<lib>.consumers: the manifest
#    declares `files/<lib>.sh` in `files` (cream validate of a tree without the
#    library fails instead of an extension that cannot source it; the Teleport
#    core is installed by the consumer); without the line: the extension tree
#    (outside tests/ and *.md) names files/<lib>.sh — it is sourced by a hook
#    from the extension directory (fetch).
# 3. The staged tree (tools/stage-catalog.sh) carries the bytes of lib/ in every
#    consumer. That the snapshot does too — tools/test-snapshot.sh; that a
#    change of a library raises every consumer — tools/check-version-bump.sh.
#
# Exit: 0 — fine; 1 — a rule broken (each is named); 2 — setup failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${1:-$(dirname "$HERE")}" && pwd)"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

die(){ echo "check-shared-libs: $*" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || die "нужен python3 с PyYAML"

libs=()
for list in "$REPO"/lib/*.consumers; do
    [[ -f "$list" ]] || continue
    lib="$(basename "$list" .consumers)"
    [[ "$lib" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "$list: имя библиотеки «$lib» — не [a-z0-9-]"
    [[ -f "$REPO/lib/$lib.sh" ]] || die "нет $REPO/lib/$lib.sh (есть $list)"
    libs+=("$lib")
done
(( ${#libs[@]} )) || die "$REPO/lib: нет ни одного *.consumers"

tmp="$(mktemp -d)"
trap 'rm -r -f -- "$tmp"' EXIT
if ! "$REPO/tools/stage-catalog.sh" "$tmp/cat" >"$tmp/log" 2>&1; then
    cat "$tmp/log" >&2
    die "staged-дерево не собрано"
fi

rc=0; summary=()
for lib in "${libs[@]}"; do
    list="$REPO/lib/$lib.consumers"
    rule=source
    grep -qE '^#[[:space:]]*rule:[[:space:]]*files[[:space:]]*$' "$list" && rule=files
    consumers=()
    while IFS= read -r c || [[ -n "$c" ]]; do
        c="${c%%#*}"; c="${c//[[:space:]]/}"
        [[ -n "$c" ]] || continue
        [[ "$c" =~ ^[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9._-]*$ ]] || die "$list: «$c» — не <семейство>/<имя>"
        [[ -f "$REPO/extensions/$c/extension.yaml" ]] || die "$list: потребитель $c — нет extensions/$c/extension.yaml"
        consumers+=("$c")
    done < "$list"
    (( ${#consumers[@]} )) || die "$list: потребителей нет"

    # 1. No copy under extensions/: in git or in the tree.
    copies="$( { git -C "$REPO" ls-files -- "extensions/*/$lib.sh" 2>/dev/null
                 (cd "$REPO" && find extensions -path '*/files/*' -name "$lib.sh" 2>/dev/null); } \
               | grep -E "/files/$lib\.sh$" | LC_ALL=C sort -u)"
    if [[ -n "$copies" ]]; then
        while IFS= read -r f; do
            echo "$f: копия lib/$lib.sh под extensions/ — единственная копия в lib/, в расширение её кладут снимок и tools/stage-catalog.sh" >&2
        done <<< "$copies"
        rc=1
    fi

    # 2. Who uses files/<lib>.sh.
    users="$(python3 -I - "$REPO" "$lib" "$rule" <<'PY'
import glob, os, sys, yaml
repo, lib, rule = sys.argv[1:4]
want = f"files/{lib}.sh"
for m in sorted(glob.glob(os.path.join(repo, "extensions", "*", "*", "extension.yaml"))):
    d = os.path.dirname(m)
    rel = os.path.relpath(d, os.path.join(repo, "extensions"))
    if rule == "files":
        man = yaml.safe_load(open(m, encoding="utf-8")) or {}
        if any(isinstance(f, dict) and f.get("src") == want for f in man.get("files") or []):
            print(rel)
        continue
    hit = False
    for root, dirs, files in os.walk(d):
        dirs[:] = [x for x in dirs if not (root == d and x == "tests")]
        for f in files:
            if f.endswith(".md"):
                continue
            try:
                if want in open(os.path.join(root, f), encoding="utf-8", errors="replace").read():
                    hit = True
                    break
            except OSError:
                pass
        if hit:
            break
    if hit:
        print(rel)
PY
)" || die "манифесты не прочитаны"
    for c in "${consumers[@]}"; do
        if ! grep -qxF "$c" <<< "$users"; then
            if [[ "$rule" == files ]]; then
                echo "$c: потребитель lib/$lib.sh не объявляет files/$lib.sh в files extension.yaml" >&2
            else
                echo "$c: потребитель lib/$lib.sh не берёт files/$lib.sh (подключать из каталога расширения: \${CREAM_EXT_DIR}/files/$lib.sh)" >&2
            fi
            rc=1
        fi
    done
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        if ! printf '%s\n' "${consumers[@]}" | grep -qxF "$d"; then
            echo "$d: берёт files/$lib.sh, но его нет в lib/$lib.consumers — библиотеку ему не положат" >&2
            rc=1
        fi
    done <<< "$users"

    # 3. The staged copies are the bytes of lib/.
    for c in "${consumers[@]}"; do
        cmp -s "$REPO/lib/$lib.sh" "$tmp/cat/extensions/$c/files/$lib.sh" \
            || { echo "$c: в staged-дереве files/$lib.sh не равен lib/$lib.sh" >&2; rc=1; }
    done
    summary+=("$lib → ${consumers[*]}")
done

if (( rc )); then
    echo "check-shared-libs: нарушено" >&2
else
    echo "check-shared-libs: ок, библиотек ${#libs[@]}:"
    printf '  %s\n' "${summary[@]}"
fi
exit "$rc"
