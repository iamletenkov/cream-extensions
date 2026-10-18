#!/usr/bin/env bash
# Прогон shellcheck по всем shell-скриптам репозитория (по расширению или shebang).
# Планка — SEVERITY (умолчание error): существующие скрипты не хуже, чем были;
# новые пишутся чистыми на уровне warning (.claude/rules/shell.md).
# Нет shellcheck на хосте — тот же инструмент в контейнере.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SEVERITY="${SEVERITY:-error}"

files=()
while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "$f" in
        *.sh | *.bash | *.bats) files+=("$f") ;;
        *.*) ;;
        *) if head -n1 "$f" | grep -Eq '^#!.*(bash|/sh|dash)'; then files+=("$f"); fi ;;
    esac
done < <(git ls-files)

echo "shellcheck -S $SEVERITY: ${#files[@]} файлов"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x -S "$SEVERITY" "${files[@]}"
else
    docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x -S "$SEVERITY" "${files[@]}"
fi
