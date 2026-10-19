# Статус cream-extensions

**Фаза:** перевод каталога на cream/v1 по плану
[2026-10-19-cream-v1-migration](plans/2026-10-19-cream-v1-migration.md) — задачи 1–28 закрыты,
впереди Task 29 (финальная интеграция, выпуск 5.0.0). Набор расширений в `main` — 4.0.0.

## Сделано
- Все 44 расширения — cream/v1 (`/opt/cream/ext`, `/etc/cream`, `/var/lib/cream/ext`);
  общий код — библиотеки `cloud-user` и `l4t` (`kind: library`).
- Переходное убрано (Task 28): `lib/`, валидатор прежнего формата, `convert-v1.py`, тест библиотеки
  настроек, `extensions/openwrt/` (файлы OpenWrt bisquite берёт по тегу `v3.3.0`, рулинг Р3).
- `cream validate --catalog .` — по корню как он есть; снимок — `roots` из `cream-catalog.yaml`;
  гейт имён `tools/check-names.sh` — по всему репозиторию, кроме истории (CHANGELOG, docs/research,
  docs/plans), двоичные файлы пропускает.

## Дальше
1. Task 29: сквозной `make ci` после слияний, `make snapshot-check`, ночной live по всем
   L-расширениям, сводка P-проверок (ждут плат и bisquite), Release PR 5.0.0.
2. Бэклог после 5.0.0 — в плане (раздел «Бэклог после 5.0.0»).
3. Разгрести предупреждения shellcheck вне расширений (планка `make lint` — error).

## Сломано
- `cream validate` предупреждает `validate.unit_lock` у `teleport` (2 юнита на пине cream 1.1.1) —
  ожидаемо, правит параллельная задача по `teleport`.
