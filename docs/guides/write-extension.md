# Написать расширение

Как добавить расширение в этот каталог. Формат `cream/v1` — манифест, хуки,
действия, окружение хука — описан в документации cream:
[написать расширение](https://github.com/iamletenkov/cream/blob/main/docs/guides/write-extension.md),
[стадии configure](https://github.com/iamletenkov/cream/blob/main/docs/guides/configure-stages.md),
[манифест](https://github.com/iamletenkov/cream/blob/main/docs/reference/manifest.md).
Здесь — что каталог добавляет к формату и как это проверяется.

## 1. Каркас

Новое расширение — только каркасом, не копией соседа: с соседом копируются чужие
способности и пути.

```bash
git switch -c feature/<имя> origin/main
tools/new-extension.sh <имя> [--stage system|early|cloud-user|graphical]
                             [--live yes|confirm|no] [--cloud-user] [--library]
                             [--arch amd64,arm64]
```

Каркас кладёт в `extensions/debian/<имя>/` манифест (`schema: cream/v1`, `cream:`
по стадии), хуки `install` и `remove`, при `--stage` — `configure` нужной стадии,
пример ключа `<ИМЯ>_EXAMPLE`, H-тест `tests/test-<имя>.sh` и README по
[шаблону](../reference/extension-readme.md). `--cloud-user` объявляет `depends` на
библиотеку `cloud-user`, зовёт её из `configure` и ставит `every_boot: true` с
`cream: ">=1.2.0"` (признак А3); `--library` даёт `kind: library` без хуков.
`tests/live.env` каркас не кладёт: с ним расширение попадает в живые прогоны CI,
и заводит его автор, когда `install` делает настоящую работу.

Скелет сразу проходит линт хуков, гейт имён, shellcheck, свой H-тест и
`cream validate` — это держит `tools/test-new-extension.sh`.

## 2. Тест первым

`tests/test-<имя>.sh` — поведение хуков на подменённом корне (обвязка
`tools/hooktest.sh`), красный до правки хука. Как писать — [тестирование](testing.md).

## 3. Хуки

cream зовёт хук с очищенным окружением: `PATH`, `LANG=C.UTF-8`, переменные
`CREAM_*` ([список](../reference/environment.md#окружение-хука)) и все
несекретные ключи домена под их именами. Правила каталога:

- **`set -euo pipefail`** первой командой (`set -eu` в sh), бит исполнения.
- **Ключи — по имени расширения**, без префикса `CREAM_` (`SELKIES_ALLOW_NO_AUTH`).
  `CREAM_*` хук только читает.
- **Секрет** читается из `$CREAM_SECRETS_FILE` (или `cream get --secret`) и дальше
  передаётся через stdin (`cream set <имя> KEY=-`), никогда через argv.
- **Коды:** 0 — успех, 10 — нужна перезагрузка, 20 — «здесь неприменимо» (нет
  устройства, ядра, GPU, L4T) — только из `install`. `configure` без устройства
  пишет предупреждение и выходит 0 ([почему](configure-lifecycle.md#коды-configure)).
- **`systemctl` в `apply`, `configure`, `secret` — только `--no-block`.**
- **Действие с `lock: none`** только читает домен — `cream set` из него запрещён;
  действие, которое зовут из `Exec*` юнита, объявляется `lock: none`.
- **`remove` обязателен при `targets.live: yes`.** `upgrade` не пишем: без него
  cream зовёт идемпотентный `install` с `CREAM_PREV_VERSION`.
- **`remove` снимает пакеты apt только через библиотеку `apt-guard`**
  (`apt_guard_remove`, `depends` на `apt-guard`): apt сначала спрашивается
  симуляцией, и чужой пакет в ответе — отказ до любых изменений. H-тест проверяет
  этот отказ; в `tests/live.env` — `apt-guard` первым в `LIVE_DEPS`.
- **Идемпотентность:** повторный `install` и `install --reinstall` не меняют ни
  одного файла (проверяет L).
- **Скачанное — по пину версии и sha256**, иначе отказ. Большой файл (AppImage,
  `.deb` релиза) — через `fetch_verified` из общей `lib/fetch.sh`: curl 7.68 (Ubuntu
  focal, L4T Jetson Nano) не повторяет обрыв соединения даже с `--retry`. Строка
  `<семейство>/<имя>` в `lib/fetch.consumers`, хук подключает
  `"${CREAM_EXT_DIR}/files/fetch.sh"` — копию кладёт снимок, `depends` не нужен.
- **Юниты, правила udev, шаблоны** — через поле `files` манифеста, их раскладывает
  cream. Префикс `cream-` в именах юнитов и путях зарезервирован за cream: юниты
  расширения называются по расширению (`teleport-join.timer`).
- **CLI для человека** — действия (`actions/<действие>`, `cream run <имя> …`), а не
  свои скрипты в `PATH`.
- **Общий код — библиотека** `kind: library` (`cloud-user`, `l4t`, `apt-guard`) в
  `depends`, вызов по пути `"${CREAM_ROOT:-}/opt/cream/ext/<библиотека>/…"`. Копий
  чужого кода в расширении нет.

Хук `configure`: стадия, `every_boot` и признаки А1–А6, повтор через
`cream configure --again` — [настройка на загрузке](configure-lifecycle.md).

## 4. Манифест

Поля задаёт cream ([манифест](https://github.com/iamletenkov/cream/blob/main/docs/reference/manifest.md)).
Каталог добавляет правила:

- **`name`** равно имени каталога; расширение лежит под одним из `roots`
  `cream-catalog.yaml` (сейчас `extensions/debian`), иначе его не увидят ни
  `cream validate`, ни снимок.
- **`version`** — semver самого расширения (файлов и ключей), не софта, который
  оно ставит. Несовместимая правка ключей, путей, юнитов — мажор; **любое
  изменение дерева, даже README, — подъём версии** ([почему](release.md#версия-расширения)).
- **`summary`** — одна фраза «что делает»: она попадает в таблицу README каталога.
- **`platform.family: deb`**; дистрибутив — не ось применимости: «на каком
  дистрибутиве мы оказались» — ветвление в хуке, ограничения версий — `platform.os`.
- **`platform.arch`** — по факту, из кода: только apt-пакеты → обе архитектуры;
  бинарь по ссылке, зависящей от архитектуры → те, для которых опубликован релиз;
  источник только для одной архитектуры → она (так у `nvidia`: подписанные
  модули Canonical и PPA `graphics-drivers` проверены только на `amd64`, а на
  Debian `install` берёт репозиторий CUDA из каталога `x86_64`). Объявить
  архитектуру — пообещать, что она работает (`armhf` нет ни у кого: не
  проверялось). Написание — OCI, канонизируется при разборе: `aarch64` и `arm64` —
  одно и то же; канонических значений два, `amd64` и `arm64`, прочие bisquite
  отвергает, называя список.
- **`provides`/`requires`** — по коду, а не по интуиции: способность — то, на что
  может сослаться сосед, а не имя пакета. Словарь — [способности](../reference/capabilities.md).
- **`conflicts`** по имени объявляют обе стороны; по способности — новый десктоп
  получает конфликт, не правя соседей.
- **`config.keys`** без префикса `CREAM_`, с `description` — это описание
  попадает в таблицу «Параметры» README.
- **`targets.live`**: `confirm` или `no` — с `live_note`: что расширение меняет на
  работающей машине. Текст попадает в README.
- **`cream:`** — не ниже, чем требует стадия и `every_boot` (правила `stage-cream`
  и `every-boot`).

## 5. README

По [шаблону](../reference/extension-readme.md): что делает, параметры, установка,
этапы, известные ограничения, проверки. Блоки `catalog:facts` и `catalog:params`
заполняет `tools/catalog-docs.sh` из манифеста — запусти его после правки
манифеста; таблица README каталога обновится тем же запуском.

## 6. Проверки и PR

```bash
tools/catalog-docs.sh                  # сгенерированные блоки документации
make ci                                # shellcheck + tools/check.sh — то же, что CI
make test-live EXT=<имя>               # L-расширение: живой прогон
git add extensions/debian/<имя> README.md docs/reference/catalog.md
git commit -m 'feat(<имя>): …'
gh pr create --title 'feat(<имя>): …'
```

Что входит в `make ci` и как читать находки — [правила проверок](../reference/lint-rules.md).
Пошагово для ревью — [runbook 02](../runbooks/02_new-extension.md).
