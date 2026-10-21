# Документация cream-extensions

Начните с [первых шагов](getting-started.md). Формат расширения и команды cream —
в [документации cream](https://github.com/iamletenkov/cream/blob/main/docs/README.md);
здесь — то, что относится к этому каталогу. Новый документ добавляется строкой в
этот индекс ([где что лежит](../.claude/rules/docs.md)).

## Начало

- [Первые шаги](getting-started.md) — подключить каталог, поставить, настроить и
  снять расширение на живой машине.

## Руководства

| Задача | Документ |
|---|---|
| ставить расширения в образ строками `RUN_COMMAND cream install` VMFILE bisquite | [guides/use-in-bisquite.md](guides/use-in-bisquite.md) |
| поменять настройку расширения на работающей машине; открыть службу в сеть | [guides/settings.md](guides/settings.md) |
| написать расширение: каркас, хуки, манифест, README, PR | [guides/write-extension.md](guides/write-extension.md) |
| хук `configure`: стадии, отметка выполнения, `every_boot` и признаки А1–А6, `--again` | [guides/configure-lifecycle.md](guides/configure-lifecycle.md) |
| проверить расширение: V, H-тест на подменённом корне, живой прогон, CI | [guides/testing.md](guides/testing.md) |
| выпустить каталог: версии, release-please, снимок, цепочка подъёмов | [guides/release.md](guides/release.md) |

## Справочник

| Что | Документ |
|---|---|
| все расширения: связи, способности, стадии (генерируется из манифестов) | [reference/catalog.md](reference/catalog.md) |
| способности: правила `provides`/`requires`/`conflicts` и откуда каждая выведена | [reference/capabilities.md](reference/capabilities.md) |
| структура репозитория, расширения, раскладка на машине, снимок | [reference/layout.md](reference/layout.md) |
| правила проверок: линт хуков, гейт имён, правило версий, таблицы, ссылки | [reference/lint-rules.md](reference/lint-rules.md) |
| переменные: окружение хука, пин cream, инструменты, `make` | [reference/environment.md](reference/environment.md) |
| шаблон README расширения | [reference/extension-readme.md](reference/extension-readme.md) |
| известные ограничения каталога целиком | [known-issues.md](known-issues.md) |

## Процедуры (runbooks)

| Документ | Зачем читать |
|---|---|
| [runbooks/01_release-catalog.md](runbooks/01_release-catalog.md) | выпуск каталога: release-please, снимок, приёмка `cream source add` + `cream check` |
| [runbooks/02_new-extension.md](runbooks/02_new-extension.md) | новое расширение: `tools/new-extension.sh`, H-тест первым, L-прогон, PR |
| [runbooks/03_cream-pin-bump.md](runbooks/03_cream-pin-bump.md) | подъём пина cream (`tools/cream-pin.env`) и проверки после него |
| [runbooks/04_live-runs.md](runbooks/04_live-runs.md) | живые прогоны `make test-live` и разбор падений: расширение, стенд, окружение |

## Решения, история, рабочие материалы

| Документ | Что это |
|---|---|
| [STATUS.md](STATUS.md) | состояние работ: что сделано, что дальше, что сломано |
| [adr/README.md](adr/README.md) | индекс архитектурных решений; шаблон — [adr/0000-template.md](adr/0000-template.md) |
| [history/README.md](history/README.md) | история каталога: переход с формата bisquite на `cream/v1` |
| [specs/](specs/) | спеки (что и почему строим) — пока пусто |
| [plans/2026-10-19-cream-v1-migration.md](plans/2026-10-19-cream-v1-migration.md) | план перевода каталога на cream/v1: 29 задач в 10 волнах, выпуск 5.0.0 (закрыт) |
| [research/2026-10-21-configure-audit.md](research/2026-10-21-configure-audit.md) | аудит 14 хуков configure по признакам А1–А6: кому нужен `every_boot` |
| [../CHANGELOG.md](../CHANGELOG.md) | изменения по версиям (ведёт release-please) |
