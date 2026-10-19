---
name: new-extension
description: Завести новое расширение формата cream/v1 (extension.yaml, hooks/, tests/) через tools/new-extension.sh — не копированием соседа.
argument-hint: <имя> [--stage system|early|cloud-user|graphical] [--live yes|confirm|no] [--cloud-user] [--library] [--arch amd64,arm64]
---
# /new-extension $ARGUMENTS

Формат — cream/v1: [docs/extensions.md](../../../docs/extensions.md) («Формат cream/v1»), спека — `cream:docs/specs/2026-10-18-cream-core.md` §4–§8. Пути — `/opt/cream/ext/<имя>`, `/etc/cream/<имя>`, `/var/lib/cream/ext/<имя>`; имён `bisquite-*` и `lib/` в новом расширении нет (гейт `tools/check-names.sh`).

1. Классифицируй: новое расширение — минимум bounded; новая библиотека (`kind: library`) или способность — архитектурная (спека).
2. Каркас: `tools/new-extension.sh <имя> [ключи]` (`--help` — справка). Копировать соседний каталог нельзя: вместе с ним копируются чужие способности и пути. Стадия `cloud-user` даёт `cream: ">=1.1.1"`, `early`/`graphical` — `">=1.1.0"`.
3. Тест первым: `tests/test-<имя>.sh` каркаса (обвязка `tools/hooktest.sh`) дополняется проверками поведения до правки хука; `tools/check.sh` находит его сам.
4. Хуки: `install` идемпотентный, ключи — из окружения (`config.keys`), секреты — из `$CREAM_SECRETS_FILE`, не через argv; `remove` обязателен при `live: yes` (Р9); `configure` без устройства — предупреждение и код 0 (Р11); `systemctl` в `apply`/`configure` — только `--no-block`. Скачанное — по пину версии и sha256.
5. `extension.yaml`: `provides`/`requires` выводятся из кода; общий код — библиотека в `depends`, путь `${CREAM_ROOT:-}/opt/cream/ext/<lib>/…`.
6. `README.md` расширения: что делает, `cream install/set/run`, **таблица ключей** домена.
7. `make ci` (в нём `tools/lint-hooks.sh`) и `make cream-validate` зелёные → reviewer → PR `feat(<имя>): …` (по-русски). Релиз и тег — release-please, не руками.
