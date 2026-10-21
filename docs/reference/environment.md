# Переменные

## Окружение хука

cream зовёт хук и действие с очищенным окружением: `PATH`, `LANG=C.UTF-8`,
переменные ниже и все **несекретные** ключи домена расширения под их именами
(`X11VNC_PORT=5900`). Секреты в окружение не попадают — только в файл
`$CREAM_SECRETS_FILE`. Значения и правила — [файлы и переменные окружения](https://github.com/iamletenkov/cream/blob/main/docs/reference/files-and-environment.md)
в документации cream.

| Переменная | Что это |
|---|---|
| `CREAM_PHASE` | `build` (сборка образа) или `live` |
| `CREAM_EXT`, `CREAM_EXT_VERSION` | имя и версия расширения |
| `CREAM_PREV_VERSION` | прежняя версия при обновлении (`install` вместо `upgrade`) |
| `CREAM_EXT_DIR` | каталог расширения: `/opt/cream/ext/<имя>` |
| `CREAM_ETC_DIR`, `CREAM_STATE_DIR` | `/etc/cream/<имя>`, `/var/lib/cream/ext/<имя>` |
| `CREAM_ROOT` | корень машины (пусто на машине; в H-тестах — подменённый корень) |
| `CREAM_CONFIG_FILE`, `CREAM_SECRETS_FILE` | файл настроек и файл секретов домена |
| `CREAM_REASON` | почему запущен `configure`: загрузка, `apply`, повтор |
| `CREAM_CHANGED_KEYS` | ключи, изменённые `cream set` (хук `apply`) |
| `CREAM_LOCK_FD`, `CREAM_LOCK_MODE` | блокировка, под которой идёт хук |
| `CREAM_ACTION`, `CREAM_OUTPUT` | только у действий: имя действия, файл вывода JSON |

Правило `cream-env` в `tools/lint-hooks.sh` не даёт хуку присвоить `CREAM_*` или
сослаться на имя, которого cream не задаёт ([правила](lint-rules.md)).

## Пин cream: `tools/cream-pin.env`

Единственное место версии cream для проверок каталога: `cream validate`,
`cream check`, снимок, живые прогоны.

| Переменная | Что это |
|---|---|
| `CREAM_VERSION` | версия cream |
| `CREAM_SHA256` | sha256 `cream_<v>_amd64.deb` — его гоняют инструменты |
| `CREAM_SHA256_ARM64` | sha256 `cream_<v>_arm64.deb` (для учёта) |
| `CREAM_URL` | откуда брать `.deb`; пусто — ассет выпуска на GitHub |

Пустой пин — проверки cream пропускаются со строкой. Поднимают пин —
[runbook 03](../runbooks/03_cream-pin-bump.md).

## Инструменты

| Переменная | Где | Что задаёт |
|---|---|---|
| `CREAM_DEB` | `cream-validate.sh`, `cream-check.sh`, `catalog-snapshot.sh` | локальный `.deb` cream вместо пина (пин не проверяется — предупреждение) |
| `CREAM_PIN_FILE`, `CREAM_CACHE_DIR` | `cream-deb.sh`, `cream-validate.sh` | другой файл пина и кеш `.deb` (умолчание `.cache/cream/`); для тестов |
| `LINT_EVERY_BOOT` | `lint-hooks.sh` | `error` (умолчание, так гоняет `check.sh`) — находка; `warn` — предупреждение с кодом 0 |
| `CREAM_SEVERITY` | `lint.sh` | уровень shellcheck для скриптов расширений (умолчание `warning`) |
| `REF` | `catalog-snapshot.sh` | коммит, из которого собирается снимок (умолчание `HEAD`) |
| `NEW_EXTENSION_ROOT` | `new-extension.sh` | куда класть каркас (тесты) |
| `HT_PHASE` | `hooktest.sh` | `CREAM_PHASE` хука в H-тесте (умолчание `live`) |
| `LIVE_LOCK`, `LIVE_LOGDIR`, `LIVE_KEEP_IMAGE` | `live-test.sh` | файл замка, каталог журналов (умолчание `.scratchpad/live/<имя>-<дистрибутив>`), не удалять образ |
| `STVOR_AGENT_DIR` | `check-contract-fixtures.sh` | соседняя копия stvor-agent для сверки образцов контракта |

Ключи `tests/live.env` (`LIVE_DISTROS`, `LIVE_DEPS`, …) — [тестирование](../guides/testing.md#l--живой-прогон).

## make

| Переменная | Цель | Что задаёт |
|---|---|---|
| `EXT` | `make test-live` | имя расширения (обязательно) |
| `DISTRO` | `make test-live`, `make test-live-self` | `debian-12` (умолчание), `debian-13`, `ubuntu-20.04`, `ubuntu-22.04`, `ubuntu-24.04` |
| `ARGS` | `make test-live` | прочие флаги `tools/live-test.sh` (`--accept-risk`, `--deps '…'`, `--param K=V`, `--cap NET_ADMIN`) |
| `CREAM_DEB` | `make cream-validate`, `make cream-check`, `make snapshot` | локальный `.deb` cream |
