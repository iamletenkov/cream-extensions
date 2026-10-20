#!/usr/bin/env bash
# Правило версий расширений: если дерево расширения extensions/<семейство>/<имя>/
# изменилось относительно последнего выпущенного тега каталога, его version в
# extension.yaml обязана быть больше, чем в этом теге.
#
# Почему: cream хранит у робота номер версии и отпечаток дерева; обновление с тем
# же номером и другим отпечатком он отвергает (`version.same_digest`). В 5.1.1
# правка README у teleport и stvor-agent без подъёма версий сломала обновление
# роботам с 5.1.0. Любая правка дерева — даже README — меняет отпечаток.
#
# База — старший тег v*, достижимый из HEAD (или --base <ref>). Сравнивается
# рабочее дерево (локальный make ci ловит и незакоммиченное; в CI это HEAD).
# Расширение, которого в базе нет (появилось после тега), и удалённое — без
# сравнения. Без тегов — отказ: в CI нужен checkout с fetch-depth: 0.
#
#   tools/check-version-bump.sh [--base <ref>] [каталог-репозитория]
#   код 0 — правило соблюдено, 1 — нарушено, 2 — нет базы / ошибка вызова
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

base=""
if [[ "${1:-}" == "--base" ]]; then
    base="${2:?--base требует ref}"; shift 2
fi
REPO="${1:-$(dirname "$HERE")}"
# Внутри git-хука GIT_DIR указывает на репозиторий хука, а не на REPO.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
gitr(){ git -C "$REPO" "$@"; }

if [[ -z "$base" ]]; then
    base="$(gitr tag --merged HEAD -l 'v*' --sort=-v:refname 2>/dev/null | head -n 1)"
    if [[ -z "$base" ]]; then
        echo "check-version-bump: нет тега v*, достижимого из HEAD — не с чем сравнить." >&2
        echo "  В CI нужен actions/checkout с fetch-depth: 0 (теги и история); локально — git fetch --tags." >&2
        exit 2
    fi
fi
if ! gitr rev-parse -q --verify "$base^{commit}" >/dev/null; then
    echo "check-version-bump: база '$base' не найдена" >&2
    exit 2
fi

# version из YAML на stdin; пусто — нет поля.
yaml_version(){
    python3 -c 'import sys, yaml
d = yaml.safe_load(sys.stdin) or {}
v = d.get("version") if isinstance(d, dict) else None
print("" if v is None else v)'
}
# vgt A B — код 0, если A > B (semver: X.Y.Z числами, выпуск выше предвыпуска).
vgt(){
    python3 - "$1" "$2" <<'EOF'
import re, sys
def key(v):
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+.*)?", v)
    if not m:
        sys.exit(f"check-version-bump: версия не по форме X.Y.Z: {v!r}")
    pre = m.group(4)
    prek = (1,) if pre is None else (0,) + tuple(
        (0, int(p), "") if p.isdigit() else (1, 0, p) for p in pre.split("."))
    return tuple(int(x) for x in m.groups()[:3]), prek
sys.exit(0 if key(sys.argv[1]) > key(sys.argv[2]) else 1)
EOF
}

rc=0; checked=0; changed=0
for manifest in "$REPO"/extensions/*/*/extension.yaml; do
    [[ -e "$manifest" ]] || continue
    dir="${manifest%/extension.yaml}"
    rel="${dir#"$REPO"/}"
    old_yaml="$(gitr show "$base:$rel/extension.yaml" 2>/dev/null)" || continue  # новое после тега
    checked=$((checked + 1))
    gitr diff --quiet "$base" -- "$rel/" && continue
    changed=$((changed + 1))
    new_v="$(yaml_version < "$manifest")"
    old_v="$(yaml_version <<< "$old_yaml")"
    if ! out="$(vgt "$new_v" "$old_v" 2>&1)"; then
        [[ -n "$out" ]] && echo "$out" >&2
        echo "$rel: дерево изменилось с $base, а version $new_v не выше $old_v." >&2
        echo "  Подними version в $rel/extension.yaml (patch — правка без смены поведения, в т. ч. README)" >&2
        echo "  и запиши причину в историю версий манифеста: иначе cream на роботе с $base" >&2
        echo "  отвергнет обновление (version.same_digest — тот же номер, другой отпечаток дерева)." >&2
        rc=1
    fi
done

if (( rc )); then
    echo "check-version-bump: нарушено (база $base)" >&2
else
    echo "check-version-bump: ок, база $base, расширений с базой: $checked, изменённых: $changed"
fi
exit "$rc"
