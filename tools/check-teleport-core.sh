#!/usr/bin/env bash
# One copy of the Teleport core in git (spec cream 2026-10-20-openwrt §4.2, ruling Р11).
#
#   tools/check-teleport-core.sh [catalog-repo]    default — this repository
#
# lib/teleport-core.sh is the only copy: no teleport-core.sh under extensions/
# (tracked or lying in the tree — the staged tree and the snapshot lay it). Every
# consumer of lib/teleport-core.consumers declares `files/teleport-core.sh` in
# `files` of its extension.yaml, so cream validate of a tree without the core
# fails instead of an extension that cannot source it; an extension that declares
# it is a consumer. The staged tree (tools/stage-catalog.sh) carries the bytes of
# lib/ in every consumer. That the snapshot does too — tools/test-snapshot.sh;
# that a change of the core raises every consumer — tools/check-version-bump.sh.
#
# Exit: 0 — fine; 1 — a rule broken (each is named); 2 — setup failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${1:-$(dirname "$HERE")}" && pwd)"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
CORE="$REPO/lib/teleport-core.sh"
CONSUMERS="$REPO/lib/teleport-core.consumers"

die(){ echo "check-teleport-core: $*" >&2; exit 2; }
[[ -f "$CORE" ]] || die "нет $CORE"
[[ -f "$CONSUMERS" ]] || die "нет $CONSUMERS"
command -v python3 >/dev/null 2>&1 || die "нужен python3 с PyYAML"

consumers=()
while IFS= read -r c || [[ -n "$c" ]]; do
    c="${c%%#*}"; c="${c//[[:space:]]/}"
    [[ -n "$c" ]] || continue
    [[ "$c" =~ ^[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9._-]*$ ]] || die "$CONSUMERS: «$c» — не <семейство>/<имя>"
    [[ -f "$REPO/extensions/$c/extension.yaml" ]] || die "$CONSUMERS: потребитель $c — нет extensions/$c/extension.yaml"
    consumers+=("$c")
done < "$CONSUMERS"
(( ${#consumers[@]} )) || die "$CONSUMERS: потребителей нет"

rc=0
# 1. No copy under extensions/: in git or in the tree.
copies="$( { git -C "$REPO" ls-files -- 'extensions/*teleport-core.sh' 2>/dev/null
             (cd "$REPO" && find extensions -name teleport-core.sh 2>/dev/null); } | LC_ALL=C sort -u)"
if [[ -n "$copies" ]]; then
    while IFS= read -r f; do
        echo "$f: копия ядра под extensions/ — единственная копия lib/teleport-core.sh, в расширение её кладут снимок и tools/stage-catalog.sh" >&2
    done <<< "$copies"
    rc=1
fi

# 2. Who declares files/teleport-core.sh in `files`.
declared="$(python3 -I - "$REPO" <<'PY'
import glob, os, sys, yaml
repo = sys.argv[1]
for m in sorted(glob.glob(os.path.join(repo, "extensions", "*", "*", "extension.yaml"))):
    d = yaml.safe_load(open(m, encoding="utf-8")) or {}
    for f in d.get("files") or []:
        if isinstance(f, dict) and f.get("src") == "files/teleport-core.sh":
            print(os.path.relpath(os.path.dirname(m), os.path.join(repo, "extensions")))
            break
PY
)" || die "манифесты не прочитаны"
for c in "${consumers[@]}"; do
    if ! grep -qxF "$c" <<< "$declared"; then
        echo "$c: потребитель ядра не объявляет files/teleport-core.sh в files extension.yaml" >&2
        rc=1
    fi
done
while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    if ! printf '%s\n' "${consumers[@]}" | grep -qxF "$d"; then
        echo "$d: объявляет files/teleport-core.sh, но его нет в lib/teleport-core.consumers — ядро ему не положат" >&2
        rc=1
    fi
done <<< "$declared"

# 3. The staged copies are the bytes of lib/.
tmp="$(mktemp -d)"
trap 'rm -r -f -- "$tmp"' EXIT
if "$REPO/tools/stage-catalog.sh" "$tmp/cat" >"$tmp/log" 2>&1; then
    for c in "${consumers[@]}"; do
        cmp -s "$CORE" "$tmp/cat/extensions/$c/files/teleport-core.sh" \
            || { echo "$c: в staged-дереве ядро не равно lib/teleport-core.sh" >&2; rc=1; }
    done
else
    cat "$tmp/log" >&2
    echo "check-teleport-core: staged-дерево не собрано" >&2
    rc=1
fi

if (( rc )); then
    echo "check-teleport-core: нарушено" >&2
else
    echo "check-teleport-core: ок, потребителей ${#consumers[@]}: ${consumers[*]}"
fi
exit "$rc"
