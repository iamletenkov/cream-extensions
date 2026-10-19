# cream-extensions

Каталог расширений провизии формата cream/v1 (бывший bisquite-extensions): их
ставит [cream](https://github.com/iamletenkov/cream) на живую машину
(`cream install`) и в образ, собираемый
[bisquite](https://github.com/iamletenkov/bisquite) (инструкция `EXTENSION` в VMFILE).


## Структура

```
extensions/
└── debian/                  # для Debian/Ubuntu, все — cream/v1
    ├── docker/
    ├── teleport/            # узел Teleport (join, render, apps.d, метки)
    ├── stvor-agent/         # обёртка пакета stvor-agent (пин по архитектурам)
    ├── cloud-user/  l4t/    # библиотеки (kind: library) — общий код других расширений
    ├── code-server/
    ├── chromium-kiosk/  kiosk/
    ├── desktop/  gnome/  xfce4/  lxde/
    ├── x11vnc/  vino-vnc/  selkies/
    ├── network-manager/  nocloud-cidata/  cloud-growroot/
    ├── nvidia/  nvidia-container-toolkit/  jetson-stats/
    └── can/  firewall/  locale/  rustdesk/   # рабочая машина робота
cream-catalog.yaml           # корень каталога cream: roots, version (ведёт release-please)
tools/                       # check.sh, cream-validate.sh, lint-hooks.sh, check-names.sh, live-test.sh,
                             #   hooktest.sh, new-extension.sh, catalog-snapshot.sh, cream-pin.env (пин cream)
.github/workflows/ci-release.yml  # CI: tools/check.sh на PR и push в main, выпуск — release-please
.github/workflows/live.yml        # живые прогоны L-расширений: изменённые на PR, все — ночью
docs/extensions.md           # конвенция целиком: формат cream/v1, линт хуков, пин cream, проверки
```

Ubuntu-образы используют расширения из `debian/` (Ubuntu — Debian-совместима).

**Teleport — под cream.** Обёртка `teleport-agent` (пакет
`bisquite-teleport-agent` 3.x) удалена: узел Teleport ведёт расширение
`teleport` формата `cream/v1` (join, render `teleport.yaml`, приложения,
управляемые и командные метки), агент портала ставит обёртка `stvor-agent`
по пину версии и sha256 на архитектуру (`files/pin.env`). Объявления
приложений других расширений (`code-server`, `selkies`) лежат в
`/etc/cream/teleport/apps.d/<имя>.conf`, формат прежний (`NAME`, `URI`,
`ICON`).

**Каталог группировки — удобство автора, а не контракт резолвера.** Расширение
ищется по полю `name` манифеста, а не по имени каталога: bisquite обходит кеш
источника целиком (`rglob extension.yaml`) и берёт тот манифест, чьё `name`
совпало со ссылкой. Другой источник вправе разложить дерево иначе.

Каталог называется `debian/`, а семейство внутри манифеста — `deb`; это разные
вещи, и совмещать их не надо. Контракт — имя каталога расширения равно `name`
(cream/v1 этого требует) и `cream-catalog.yaml` в корне (`roots: [extensions/debian]`).

## Конвенция

Формат — **cream/v1**: расширение ставит и настраивает cream (исполнитель
расширений), сборщик bisquite зовёт тот же cream в госте. Конвенция целиком —
[docs/extensions.md](docs/extensions.md#формат-creamv1), спека — в репозитории cream
(`docs/specs/2026-10-18-cream-core.md`).

```
extensions/debian/<name>/
├── extension.yaml      # schema: cream/v1, name, version, summary, cream, platform, targets,
│                       # provides/requires/depends/conflicts, hooks, config.keys, actions, files
├── hooks/              # install, upgrade, configure, apply, secret, remove, check — объявленные
├── actions/<действие>  # cream run <name> <действие>
├── files/…             # юниты, udev, шаблоны — раскладывает cream (поле files)
├── tests/              # H-тесты (tests/test-*.sh) и live.env; в снимок не попадают
└── README.md
```

```
cream install <name>                 # живая машина (EXTENSION <name> — образ bisquite)
cream show <name>                    # настройки домена
sudo cream set <name> KEY=VALUE      # проверка по схеме, атомарная запись, хук apply
cream run <name> <действие> [аргументы]
cream remove <name>
```

- **Настройки** — `config.keys` манифеста; в хук приходят переменными окружения
  (по имени расширения, без префикса `CREAM_` — это окружение cream), секреты — только
  в `$CREAM_SECRETS_FILE`, дальше через stdin (`KEY=-`), не через argv.
- **Донастройка на машине** — хук `configure` на стадии `system`, `early`,
  `cloud-user` или `graphical` (юнит `cream-configure@<name>` ставит cream).
  Стадии `early`/`graphical` требуют `cream: ">=1.1.0"`, `cloud-user` —
  **`">=1.1.1"`** (в 1.1.0 стадия не стартует при выключенном cloud-init).
- **Общий код** — библиотеки `kind: library` (`cloud-user` — пользователь
  cloud-init, `l4t`): потребитель объявляет `depends` и зовёт
  `"${CREAM_ROOT:-}/opt/cream/ext/<lib>/…"`. Копий общего кода в расширении нет.
- **Коды хука:** 10 — нужна перезагрузка, 20 — неприменимо здесь (только `install`);
  `configure` без устройства — предупреждение и 0. `remove` обязателен при
  `targets.live: yes`.
- **Новое расширение** — только `tools/new-extension.sh <name>` (каркас cream/v1).

### Раскладка в госте

| Что | Где |
|---|---|
| код и данные расширения | `/opt/cream/ext/<name>/` |
| настройки домена (`config`, `secrets`, `apps.d`) | `/etc/cream/<name>/` |
| состояние | `/var/lib/cream/ext/<name>/` |
| донастройка на загрузке | `cream-configure@<name>.service` |

## Проверки

```bash
make ci                       # shellcheck + tools/check.sh — то же, что CI
tools/check.sh                # cream validate, гейт имён, линт хуков, тесты инструментов и расширений (make test)
tools/cream-validate.sh       # cream validate --catalog . по корню (make cream-validate)
tools/lint-hooks.sh           # линт хуков и действий: шапки, --no-block, lock: none, секреты, CREAM_*
tools/check-names.sh          # прежние имена bisquite по всему репозиторию, кроме истории (make check-names)
tools/live-test.sh <имя>      # живой прогон настоящим cream в контейнере с systemd (make test-live EXT=<имя>)
tools/new-extension.sh <имя>  # каркас нового расширения cream/v1
tools/agent-bump.sh <тег> <SHA256SUMS>  # пин stvor-agent в обёртке stvor-agent (его зовёт agent-bump.yml)
tools/catalog-snapshot.sh [OUT] # снимок каталога cream (make snapshot)
tools/test-snapshot.sh          # воспроизводимость и приёмка снимка cream (make snapshot-check)
```

`cream validate --catalog .` проверяет каждый манифест, повторяющиеся имена,
граф (`depends` на отсутствующее расширение или цикл — ошибка, `requires` без
поставщика — предупреждение) и сверку юнитов с действиями; cream — по пину
`tools/cream-pin.env` в контейнере `debian:12`.

**Проверки автоматические.** `tools/check.sh` гоняет GitHub Actions на каждый
pull request и push в `main` — `.github/workflows/ci-release.yml`. Локально перед
пушем — `make ci` (его же зовёт pre-push lefthook). Нужны bash, git, Python 3 с
PyYAML (`apt install python3-yaml`) и docker.

Тесты расширения лежат в его `tests/` и находятся сами: `tools/check.sh` гоняет
каждый исполняемый `extensions/*/*/tests/test-*.sh` (в снимок каталога `tests/` не
попадает). Живой прогон — отдельно (контейнер с systemd, сеть, по одному под
замком): `make test-live EXT=<имя> [DISTRO=ubuntu-24.04]`, умолчания — в
`tests/live.env` расширения. Подробно — [docs/extensions.md](docs/extensions.md#проверки).

## Подключение в образ и на машину

На живой машине — `cream install <name> [KEY=VALUE…]` из источника, в который
подключён снимок каталога (см. «Снимок каталога cream»). В образе — инструкция
bisquite в VMFILE:

```vmfile
EXTENSION docker
EXTENSION x11vnc X11VNC_PORT=5901 X11VNC_LISTEN=all
```

Форма: `EXTENSION [источник/]имя [КЛЮЧ=ЗНАЧЕНИЕ ...]`; применимость слоя считает
`cream resolve --phase build`, ставит расширение cream в госте. Параметры — ключи
`config.keys` манифеста под теми же именами, без таблицы соответствия: README
каждого расширения называет их именами манифеста. Ручной доставки каталога в
гостя (`COPY_IN` + запуск скрипта) нет.

## Версионирование

Версия набора расширений — git-тег этого репозитория и `version` в
`cream-catalog.yaml`; потребители пинят снимок релиза по sha256. Теги — semver,
их ставит release-please, руками не тегают.

### Как выпустить версию

Workflow `CI and Release`, конфиг — `.github/release_please/`:

1. Сливаешь в `main` коммиты по [Conventional Commits](https://www.conventionalcommits.org/ru/):
   `fix:` поднимает patch, `feat:` — minor, `!` или `BREAKING CHANGE:` — major;
   `docs:`, `ci:`, `chore:` версию не трогают.
   Тип и область — латиницей, текст заголовка и тела — на русском
   (`feat(rustdesk): пакет для arm64`); подробнее — [CLAUDE.md](CLAUDE.md).
2. После проверок на `main` release-please открывает (и дальше обновляет)
   PR «chore(main): release X.Y.Z» с секцией `CHANGELOG.md`.
3. Владелец сливает этот PR — release-please создаёт тег `vX.Y.Z` и
   опубликованный релиз с заметками; job `release-assets` собирает на теге
   снимок каталога и прикладывает к релизу `cream-extensions-X.Y.Z.tar.gz`
   и `SHA256SUMS` (см. «Снимок каталога cream» ниже).
4. Тот же прогон запускает в `iamletenkov/bisquite` workflow `extensions-bump.yml`
   (job `dispatch-bisquite`): там открывается PR, поднимающий подмодуль и
   `EXT_VERSION`/`ref` в примерах до нового тега. Токен — секрет
   `BISQUITE_DISPATCH_TOKEN` этого репозитория: fine-grained PAT только на <!-- check-names: allow: имя секрета GitHub -->
   bisquite с правом Actions: Read and write, действует до 16.10.2027 —
   до этой даты перевыпустить, иначе job релиза покраснеет.
   Пока bisquite не ставит расширения через cream, job выключен: его включает
   переменная репозитория `BISQUITE_BUMP_ENABLED=true`. <!-- check-names: allow: имя переменной GitHub -->

Пин агента в обёртке `stvor-agent` руками не поднимают: релиз
`iamletenkov/stvor-agent` запускает здесь `agent-bump.yml` (правки —
`tools/agent-bump.sh`), и тот открывает PR `feat(stvor-agent): пин агента X.Y.Z`
с суммами обоих `.deb` из `SHA256SUMS` релиза. База PR — вход `base`, иначе
переменная `AGENT_BUMP_BASE` (пока обёртка только в пилотной ветке —
`feature/cream-v1-pilot`), иначе `main`.

### Снимок каталога cream

Потребители cream (портал Stvor, bisquite) берут каталог не git-чекаутом,
а снимком — `tar.gz`, собранным `cream catalog pack` (спека cream §9):

```bash
make snapshot        # dist/cream-extensions-<v>.tar.gz + dist/SHA256SUMS из HEAD
make snapshot-check  # две сборки дают одни байты; cream принимает снимок
```

Снимок собирается из коммита (`REF`, по умолчанию `HEAD`), а не из рабочего
дерева; `SOURCE_DATE_EPOCH` — время коммита, cream — по пину
`tools/cream-pin.env` в контейнере `debian:12`, поэтому сборка одного коммита
воспроизводима побайтно. В снимок попадают `cream-catalog.yaml`, `LICENSE`,
`NOTICE` и `roots` каталога (все расширения, без `tests/`); `tools/`, `docs/` и
прочее — нет. Версия каталога —
`version` в `cream-catalog.yaml`, её поднимает release-please вместе с тегом.

Готовый снимок лежит в релизе `vX.Y.Z`; подключение:

```bash
cream source add cream-extensions \
  --archive https://github.com/iamletenkov/cream-extensions/releases/download/vX.Y.Z/cream-extensions-X.Y.Z.tar.gz \
  --sha256 <сумма из SHA256SUMS релиза> --sync
```

Stvor раздаёт тот же файл со своего зеркала (`--archive file://…`) по пину
sha256. Подробнее — [docs/extensions.md](docs/extensions.md#снимок-каталога-для-cream).

## Зависимости и применимость

Объявлены в `extension.yaml` (спека cream §4): `platform` (`family: deb`, `arch`),
`targets` (`build`, `live`), `depends` (расширения, которые ставятся раньше,
с диапазоном версий), `provides`/`requires` (способности), `conflicts` (по имени
или по способности). Применимость слоя и порядок по `depends` считает
`cream resolve`; граф целиком проверяет `cream validate --catalog .` при каждом
`make ci`. Коротко, что объявлено:

- `gnome`, `xfce4`, `lxde` дают `x11-server` + `display-manager` + `desktop-session`
  и взаимоисключающи (конфликт по способности `desktop-session`); ручки
  рабочего стола — домен расширения `desktop`, от которого они зависят;
- `x11vnc`, `vino-vnc` и `kiosk` требуют `x11-server` и `display-manager` —
  то самое отношение, которое держится только порядком слоёв в VMFILE.
  `x11vnc` и `vino-vnc` дают одну способность `remote-desktop`, но конфликта
  не объявляют: мешают друг другу их умолчания (порт 5900), а это лечится
  параметром — разбор в `extensions/debian/vino-vnc/README.md`;
- `jetson-stats` даёт `jetson-monitor` и объявляет только `arm64`: Jetson
  бывает только aarch64, и вдобавок расширение отказывает на образе без
  `/etc/nv_tegra_release`;
- `nvidia` 2.0.0 даёт `gpu-driver-nvidia`: драйвер строго под ядро образа,
  настройки `NVIDIA_DRIVER_VERSION` (580), `NVIDIA_KERNEL_MODULES`
  (`open`|`proprietary`), `NVIDIA_SOURCE` (`archive`|`ppa`);
  `nvidia-container-toolkit` 1.0.0 (`NVIDIA_CTK_VERSION`) требует
  `gpu-driver-nvidia` и `container-runtime`, регистрирует среду `nvidia`
  в Docker без смены `default-runtime`;
- рабочая машина робота: `can` (модули CAN под ядро образа, `can-bus`),
  `firewall` (своя таблица nftables `inet cream` или цепочка iptables-legacy
  `CREAM-INPUT` на ядрах без `nft_ct`, Docker не задевает,
  `host-firewall`), `locale` (локаль и раскладки, `system-locale`), `rustdesk`
  (`.deb` по sha256, адреса своего сервера — на устройстве, `remote-support`);
  ничего не требуют и ни с чем не конфликтуют;
- `docker` даёт `container-runtime` и ни с чем не конфликтует: расширения
  слиты 2026-09-03, когда замер показал, что `get.docker.com` ставит из того
  же `download.docker.com` и вдобавок ломает сборку на bionic. Разбор —
  в `extensions/debian/docker/README.md`.

Полная таблица «кто что даёт и из какого кода это выведено» —
в `docs/extensions.md`.

## Лицензия

[PolyForm Noncommercial 1.0.0](LICENSE), см. [NOTICE](NOTICE). Коммерческое
использование — по отдельной лицензии правообладателя.
