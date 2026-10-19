#!/usr/bin/env bash
# Прогон shellcheck по всем shell-скриптам репозитория (по расширению или shebang).
# Планка — SEVERITY (умолчание error): существующие скрипты не хуже, чем были;
# новые пишутся чистыми на уровне warning (.claude/rules/shell.md). Скрипты
# расширений (хуки, действия, files/, tests/) проходят вторым прогоном на уровне
# CREAM_SEVERITY (умолчание warning). Остальные правила хуков — tools/lint-hooks.sh.
# Нет shellcheck на хосте — тот же инструмент в контейнере.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SEVERITY="${SEVERITY:-error}"
CREAM_SEVERITY="${CREAM_SEVERITY:-warning}"

shellcheck_run() {
    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck -x "$@"
    else
        docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x "$@"
    fi
}

# Directories of the extensions, with a trailing slash.
cream_dirs=()
while IFS= read -r m; do
    cream_dirs+=("$(dirname "$m")/")
done < <(git ls-files 'extensions/*/*/extension.yaml')

files=()
cream_files=()
while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "$f" in
        *.sh | *.bash | *.bats) ;;
        *.*) continue ;;
        *) head -n1 "$f" | grep -Eq '^#!.*(bash|/sh|dash)' || continue ;;
    esac
    files+=("$f")
    for d in "${cream_dirs[@]}"; do
        if [[ "$f" == "$d"* ]]; then cream_files+=("$f"); break; fi
    done
done < <(git ls-files)

echo "shellcheck -S $SEVERITY: ${#files[@]} файлов"
shellcheck_run -S "$SEVERITY" "${files[@]}"
if (( ${#cream_files[@]} )); then
    echo "shellcheck -S $CREAM_SEVERITY (расширения, ${#cream_dirs[@]}): ${#cream_files[@]} файлов"
    shellcheck_run -S "$CREAM_SEVERITY" "${cream_files[@]}"
fi
