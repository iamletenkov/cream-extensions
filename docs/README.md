# Документация cream-extensions

Где что лежит и когда писать документ — [.claude/rules/docs.md](../.claude/rules/docs.md).
Новый документ без строки в этой таблице не считается готовым.

| Документ | Зачем читать |
|---|---|
| [STATUS.md](STATUS.md) | состояние работ: что сделано, что дальше, что сломано |
| [extensions.md](extensions.md) | конвенция расширений: манифест, фазы, способности, раскладка в госте, проверки |
| [runbooks/01_release-catalog.md](runbooks/01_release-catalog.md) | выпуск каталога: release-please, снимок, приёмка `cream source add` + `cream resolve` |
| [runbooks/02_new-extension.md](runbooks/02_new-extension.md) | новое расширение: `tools/new-extension.sh`, H-тест первым, L-прогон, PR |
| [runbooks/03_cream-pin-bump.md](runbooks/03_cream-pin-bump.md) | подъём пина cream (`tools/cream-pin.env`) и проверки после него |
| [runbooks/04_live-runs.md](runbooks/04_live-runs.md) | живые прогоны `make test-live` и разбор падений: расширение, стенд, окружение |
| [adr/README.md](adr/README.md) | индекс архитектурных решений; шаблон — [adr/0000-template.md](adr/0000-template.md) |
| [specs/](specs/) | спеки (что и почему строим) — пока пусто |
| [plans/2026-10-19-cream-v1-migration.md](plans/2026-10-19-cream-v1-migration.md) | план перевода всего каталога на cream/v1: 29 задач в 10 волнах, выпуск 5.0.0 |
| [research/2026-10-21-configure-audit.md](research/2026-10-21-configure-audit.md) | аудит 14 хуков configure по признакам А1–А6: кому нужен `every_boot` (cream 1.2.0), правило `[every-boot]` в `lint-hooks` |
