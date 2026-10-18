# Статус cream-extensions

**Фаза:** старт обвязки после переименования (2026-10-18); набор расширений — 3.3.0.

## Сделано
- Репозиторий переименован из bisquite-extensions; проверки имени репозитория в CI знают новые имена.
- Обвязка Claude Code: AGENTS.md, CLAUDE.md, `.claude/`, lefthook, Makefile (`make lint/test/check/ci`).

## Дальше
1. Спека cream: формат `extension.yaml` и жизненный цикл переезжают под исполнитель cream;
   план миграции расширений и `lib/bisquite-conf` → `cream set/show`.
2. Ссылки на старые имена репозиториев в README и в `teleport-agent` (URL релизов агента)
   — заменить на stvor-agent/cream-extensions; GitHub пока перенаправляет.
3. Разгрести предупреждения shellcheck (37 на уровне warning, планка `make lint` — error).

## Сломано
- Ничего известного.
