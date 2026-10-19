# cream-extensions

Каталог расширений провизии формата cream/v1 (бывший bisquite-extensions): их
ставит [cream](https://github.com/iamletenkov/cream) на живую машину
(`cream install`) и в образ, собираемый
[bisquite](https://github.com/iamletenkov/bisquite) (инструкция `EXTENSION` в VMFILE).

## Структура

```
extensions/
├── debian/                  # для Debian/Ubuntu: cream/v1 (hooks/) и ещё не переведённые layout 2
│   ├── docker/
│   ├── teleport/            # cream/v1: узел Teleport (join, render, apps.d, метки)
│   ├── stvor-agent/         # cream/v1: обёртка пакета stvor-agent (пин по архитектурам)
│   ├── code-server/
│   ├── chromium-kiosk/  kiosk/
│   ├── gnome/  xfce4/  lxde/
│   ├── x11vnc/  vino-vnc/
│   ├── network-manager/  nocloud-cidata/  cloud-growroot/
│   ├── nvidia/  nvidia-container-toolkit/  jetson-stats/
│   └── can/  firewall/  locale/  rustdesk/   # рабочая машина робота
└── openwrt/                 # для OpenWrt (конфиги, UPLOAD) — не расширения, см. docs/
    ├── uci-defaults/
    └── wrt_cloudinit/
lib/                         # переходно: общий код layout 2 (bisquite-conf, knobs/); в cream/v1 — библиотеки kind: library
tools/                       # check.sh, lint-hooks.sh, check-names.sh, live-test.sh, hooktest.sh, new-extension.sh,
                             #   cream-pin.env (пин cream проверок), validate-extensions.py (layout 2)
.github/workflows/ci-release.yml  # CI: tools/check.sh на push и PR, выпуск — release-please
.github/workflows/live.yml        # живые прогоны L-расширений: изменённые на PR, все — ночью
docs/extensions.md           # конвенция целиком: формат cream/v1, линт хуков, пин cream; layout 2 — переходно
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
  (без префикса `CREAM_` — это окружение cream, и без `BISQUITE_`), секреты — только
  в `$CREAM_SECRETS_FILE`, дальше через stdin (`KEY=-`), не через argv.
- **Донастройка на машине** — хук `configure` на стадии `system`, `early`,
  `cloud-user` или `graphical` (юнит `cream-configure@<name>` ставит cream).
  Стадии `early`/`graphical` требуют `cream: ">=1.1.0"`, `cloud-user` —
  **`">=1.1.1"`** (в 1.1.0 стадия не стартует при выключенном cloud-init).
- **Общий код** — библиотеки `kind: library` (`cloud-user` — пользователь
  cloud-init, `l4t`): потребитель объявляет `depends` и зовёт
  `"${CREAM_ROOT:-}/opt/cream/ext/<lib>/…"`. Копий и `lib/` в расширении нет.
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

### Переходное: layout 2

Ещё не переведённые расширения (без `schema: cream/v1` в манифесте) живут по
layout 2: `install.sh` + `configure.sh` + `configure-<name>.service`, схема
`knobs` и `lib/bisquite-conf`, общий код — `lib/` корня, доставляемый сборкой в
`/opt/bisquite/<name>/lib`, настройки — `/etc/bisquite/<домен>/config`,
манифест из девяти полей с `layout: 2`. Его описание — разделы «layout 2» в
[docs/extensions.md](docs/extensions.md); проверяет его
`tools/validate-extensions.py`. Каталог переводится по плану
[2026-10-19-cream-v1-migration](docs/plans/2026-10-19-cream-v1-migration.md),
расширение целиком и с мажором версии; layout 2, `lib/` и валидатор уходят
в последней задаче плана.

**OpenWrt** (`extensions/openwrt/`) — конфиги для `UPLOAD`, не расширения; на
cream/v1 не переводятся и уходят из каталога (bisquite берёт их по тегу `v3.3.0`).

## Проверки

```bash
tools/check.sh                # все проверки: манифесты, cream validate, линт хуков, гейт имён, тесты (make test)
tools/lint-hooks.sh           # линт хуков и действий cream/v1: шапки, --no-block, lock: none, секреты, CREAM_*
tools/validate-extensions.py  # только манифесты (нужен python3 + PyYAML)
tools/check-names.sh          # гейт имён bisquite в расширениях cream/v1 (make check-names)
tools/live-test.sh <имя>      # живой прогон настоящим cream в контейнере с systemd (make test-live EXT=<имя>)
tools/new-extension.sh <имя>  # каркас нового расширения cream/v1
tools/agent-bump.sh <тег> <SHA256SUMS>  # пин stvor-agent в обёртке stvor-agent (его зовёт agent-bump.yml)
tools/catalog-snapshot.sh [OUT] # снимок каталога cream (make snapshot)
tools/test-snapshot.sh          # воспроизводимость и приёмка снимка cream (make snapshot-check)
```

Валидатор проверяет, что у каждого каталога с `install.sh` есть манифест, что
поля заполнены и осмысленны (`layout` — ровно `2`), что каждая способность из `requires` кем-то
предоставляется, что в графе нет циклов и что `conflicts` симметричны.

**Проверки автоматические.** `tools/check.sh` гоняет GitHub Actions на каждый
push и pull request — `.github/workflows/ci-release.yml`. Локально перед пушем это
та же одна команда, и запускать её руками полезно ровно затем, чтобы не узнать
об ошибке из красного CI:

```bash
tools/check.sh
```

Из зависимостей нужен bash и Python 3 с PyYAML (`pip install pyyaml` или
`apt install python3-yaml`).

Тесты расширения лежат в его `tests/` и находятся сами: `tools/check.sh` гоняет
каждый исполняемый `extensions/*/*/tests/test-*.sh` (в снимок каталога `tests/` не
попадает). Живой прогон — отдельно (контейнер с systemd, сеть, по одному под
замком): `make test-live EXT=<имя> [DISTRO=ubuntu-24.04]`, умолчания — в
`tests/live.env` расширения. Подробно — [docs/extensions.md](docs/extensions.md#проверки).

## Подключение в VMFILE

Для расширений `debian/` способ один — `EXTENSION`.

```vmfile
EXTENSION docker
EXTENSION core/x11vnc X11VNC_PORT=5901 X11VNC_LISTEN=all
```

Форма: `EXTENSION [источник/]имя [КЛЮЧ=ЗНАЧЕНИЕ ...]`. Bisquite разворачивает
её в одном вызове `virt-customize`: кладёт `lib/` источника в
`/opt/bisquite/lib/<sha256>/`, копирует каталог расширения в
`/opt/bisquite/<имя>`, ставит `0755` каждому `*.sh` верхнего уровня, ссылку
`/opt/bisquite/<имя>/lib` и запускает `install.sh`, положив `КЛЮЧ=ЗНАЧЕНИЕ`
в его окружение.

**Параметры уезжают в скрипт переменными окружения как есть, без таблицы
соответствия.** Единственный источник правды о том, какие переменные читает
расширение, — его собственный `install.sh`; таблица «параметр VMFILE →
переменная скрипта» устарела бы молча. Поэтому в README каждого расширения
параметры названы теми же именами, что в коде.

Два свойства, и оба несущие:

- права ставятся опцией `--chmod` инструментами appliance, а не
  `RUN_COMMAND chmod`: вторая форма поднимает гостя и на чужой архитектуре
  отказывает;
- применимость **вычисляется** из пары «архитектура хоста ↔ архитектура
  образа», а не предполагается. `phase: build` при несовпадении — отказ до
  сборки, а не тихая подмена на `firstboot`.

Прежняя ручная форма — `COPY_IN <расширение>:/opt/vmsetup/` плюс
`RUN_COMMAND …/install.sh` — с раскладкой 2 не работает: общий `lib` рядом
с расширением она не ставит, а юниты смотрят в `/opt/bisquite`.

OpenWrt подключается другой формой — `UPLOAD` конкретных файлов
по конкретным путям:

```vmfile
UPLOAD <чекаут>/extensions/openwrt/uci-defaults/80-rootfs-resize:/etc/uci-defaults/80-rootfs-resize
```

## Доставка в сборку: источники расширений

Сборка в сеть за расширением **не ходит**. `EXTENSION` берёт его из локального
кеша `<DATA_DIR>/extensions/<источник>/`, а кеш наполняет отдельный явный шаг —
`bs extension sync` — по объявлению в `<DATA_DIR>/data/extensions.yaml`:

```yaml
sources:
  - name: core
    type: git
    url: https://github.com/iamletenkov/bisquite-extensions.git
    ref: v2.0.0                  # ветка, тег или коммит
  - name: lab
    type: path
    path: /srv/lab-extensions    # только абсолютный путь
```

Источник `core` — этот репозиторий — поставляется с пакетом уже объявленным,
поэтому первый шаг оператора обычно не «напиши файл», а `bs extension sync`.
Свой `extensions.yaml` в каталоге данных **замещает** поставляемый целиком,
а не дополняет его: объявил один свой источник — `core` пропал, допиши его
руками, если он нужен.

```bash
bs extension sources     # что объявлено и в каком состоянии кеш
bs extension sync        # привести кеш в соответствие с объявлением
bs extension ls          # что в кеше лежит — расширения, а не источники
bs extension check core/docker   # применимо ли здесь; при отказе код возврата 1
bs extension new my-ext  # каркас нового расширения (вне кеша — внутри откажет)
```

Типов источников три: `git` и `path` работают, `oci` отказывает явно —
не решён вопрос, каким `mediaType` расширения лежат в реестре, а заглушка,
рапортующая успехом, отложила бы новость до момента, когда `EXTENSION`
не найдётся в середине сборки.

Имя источника необязательно в ссылке: `EXTENSION docker` ищет по всем
источникам в порядке объявления и берёт первый, как `PATH`. Затенение
поставляемого `core` своим источником — рабочий приём, и о нём пишется
строка в журнал (`extensions.shadowed`), потому что «взяли не то, что
думали» иначе видно только по содержимому образа.

Прежний способ доставки — `git clone` этого репозитория в контекст сборки —
остаётся нужен только для файлов OpenWrt, которые `UPLOAD` берёт из чекаута
рядом с VMFILE:

```yaml
variables:
  EXT_REPO: https://github.com/iamletenkov/bisquite-extensions.git
  EXT_VERSION: v2.0.0
before_script:
  - rm -rf bisquite-extensions
  - git clone --depth 1 --branch "$EXT_VERSION" "$EXT_REPO"
```

## Версионирование

Версия набора расширений — git-тег этого репозитория. Через `EXTENSION` его
пинит поле `ref` источника в `extensions.yaml`, файлы OpenWrt через `UPLOAD` —
тег чекаута (`EXT_VERSION`). Теги — semver, их ставит release-please, руками
не тегают.

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
   `BISQUITE_DISPATCH_TOKEN` этого репозитория: fine-grained PAT только на
   bisquite с правом Actions: Read and write, действует до 16.10.2027 —
   до этой даты перевыпустить, иначе job релиза покраснеет.

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
воспроизводима побайтно. Пока каталог переходный, в снимок попадают только
расширения `cream/v1` (без `tests/`), `cream-catalog.yaml`, `LICENSE` и
`NOTICE`: манифесты layout 2 cream отвергает. Версия каталога —
`version` в `cream-catalog.yaml`, её поднимает release-please вместе с тегом.

Готовый снимок лежит в релизе `vX.Y.Z`; подключение:

```bash
cream source add cream-extensions \
  --archive https://github.com/iamletenkov/cream-extensions/releases/download/vX.Y.Z/cream-extensions-X.Y.Z.tar.gz \
  --sha256 <сумма из SHA256SUMS релиза> --sync
```

Stvor раздаёт тот же файл со своего зеркала (`--archive file://…`) по пину
sha256. Подробнее — [docs/extensions.md](docs/extensions.md#снимок-каталога-для-cream).

`ref: main` неподвижной точкой не является: ветка мутабельна, а git-тег
переставляется `git tag -f`. Что фактически легло в кеш, записывает
`<DATA_DIR>/data/sources.lock`.

## Зависимости и применимость

Объявлены в `extension.yaml`. Читают их **двое, и по-разному**:

- **bisquite** при разборе `EXTENSION` берёт `name`, `layout`, `family`,
  `arch` и `phase`; `layout` не `2` — отказ до сборки. `family` сверяется с тем, что отвечает `virt-inspector` о самом
  образе (`<package_format>`), `arch` и `phase` — с парой архитектур;
- **`tools/validate-extensions.py`** проверяет `provides`, `requires`
  и `conflicts` — граф способностей, циклы и симметрию конфликтов.

Топологической сортировки и отказа по конфликту в bisquite **нет**: он эти три
поля только печатает (`bs extension ls`, `bs extension check`). Порядок слоёв
по-прежнему держится вниманием автора VMFILE. Коротко, что объявлено:

- `gnome`, `xfce4`, `lxde` дают `x11-server` + `display-manager` + `desktop-session`
  и взаимоисключающи;
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
  `firewall` (своя таблица nftables `inet bisquite` или цепочка iptables-legacy
  `BISQUITE-INPUT` на ядрах без `nft_ct`, Docker не задевает,
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
