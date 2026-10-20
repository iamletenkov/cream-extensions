# Конвенция расширений

Документ описывает, как устроено расширение каталога формата **cream/v1**: что
каталог добавляет к спеке cream, где расширение лежит в госте, как его
подключают, где живут настройки на работающей машине, какие способности
объявлены и какие проверки это держат. История прежнего формата — в
`CHANGELOG.md` и в git.

## Содержание

- [Формат cream/v1](#формат-creamv1) — раскладка, хуки, стадии, пин cream, линт хуков
- [Каталог и имена](#каталог-и-имена)
- [Как расширение подключается](#как-расширение-подключается)
- [Сборка и загрузка](#сборка-и-загрузка)
- [Настройки на работающей машине](#настройки-на-работающей-машине)
- [Манифест: правила каталога](#манифест-правила-каталога)
- [Словарь способностей](#словарь-способностей)
- [Новое расширение: каркас](#новое-расширение-каркас)
- [Проверки](#проверки)
- [Как добавить расширение](#как-добавить-расширение)
- [Что осталось незакрытым](#что-осталось-незакрытым)

## Формат cream/v1

Формат задаёт cream — спека
`cream:docs/specs/2026-10-18-cream-core.md` (§4 манифест, §5 раскладка, §6 хуки,
§7 действия, §8 настройки) и справочник `cream:docs/cli.md`; здесь — то, что
каталог добавляет к ней сам, и проверки, которые это держат.

### Раскладка расширения

```
<имя>/
├── extension.yaml      # schema: cream/v1; name = имя каталога
├── hooks/              # install (обязателен, кроме kind: library), upgrade, configure,
│                       # apply, secret, remove, check — только объявленные в манифесте
├── actions/<действие>  # cream run <имя> <действие> — вместо самописных CLI (Р7)
├── files/…             # юниты, правила udev, шаблоны; раскладывает cream (поле files)
├── tests/              # H-тесты и live.env — в снимок каталога не попадают
└── README.md
```

Файлы `hooks/*` и `actions/*` исполняемые. Каталог не несёт копий чужого кода и
не ссылается на `lib/` корня: общий код — **библиотека**, отдельное расширение
`kind: library` (`cloud-user`, `l4t`, `apt-guard`), которое потребитель объявляет в `depends`
и зовёт по стабильному пути `"${CREAM_ROOT:-}/opt/cream/ext/<библиотека>/…"`.

### Раскладка в госте

| Что | Где |
|---|---|
| код и данные расширения (копия каталога без `tests/`) | `/opt/cream/ext/<имя>/` |
| настройки домена (`config`, `secrets` 0600, `apps.d` у `teleport`) | `/etc/cream/<имя>/` |
| состояние расширения | `/var/lib/cream/ext/<имя>/` |
| юнит донастройки | `cream-configure@<имя>.service` (ставит cream; своих `configure-<имя>.service` нет) |

Префикс `cream-` в именах юнитов и путях `files` зарезервирован за cream: юниты
расширения называются по расширению (`teleport-join.timer`).

### Хуки: окружение и коды

cream зовёт хук с очищенным окружением: `PATH`, `LANG=C.UTF-8`, `CREAM_*`
(`CREAM_PHASE`, `CREAM_EXT`, `CREAM_EXT_DIR`, `CREAM_ETC_DIR`, `CREAM_STATE_DIR`,
`CREAM_ROOT`, `CREAM_CONFIG_FILE`, `CREAM_SECRETS_FILE`, `CREAM_REASON`,
`CREAM_CHANGED_KEYS`, `CREAM_LOCK_FD`, `CREAM_LOCK_MODE`; у действий ещё
`CREAM_ACTION`, `CREAM_OUTPUT`) и все **несекретные** ключи домена под их
именами. Отсюда правила каталога:

- **Ключи — по имени расширения, без префикса `CREAM_` и без прежнего префикса
  сборщика** (Р8): `SELKIES_ALLOW_NO_AUTH`. `CREAM_*` хук только читает: не присваивает
  и не выдумывает новых имён.
- **Секрет** читается из `$CREAM_SECRETS_FILE` (или `cream config get --secret`) и
  передаётся дальше через stdin (`cream set <имя> KEY=-`), никогда через argv.
- **Коды:** 0 — успех, 10 — нужна перезагрузка, 20 — «здесь неприменимо» (нет
  устройства, ядра, GPU, L4T) — **только из `install`** (Р11). `configure` без
  устройства или менеджера входа пишет предупреждение в stderr и выходит 0.
- **`systemctl` в `apply`, `configure`, `secret` — только с `--no-block`**: `cream set`
  бывает внутри загрузочного юнита, и блокирующий restart ждал бы сам себя.
- **Действие с `lock: none`** только читает домен — `cream set` из него запрещён;
  действие, которое зовут из `Exec*` юнита, объявляется `lock: none` (§7.3).
- **`remove`** обязателен при `targets.live: yes` (Р9); `upgrade` не пишем (Р10).
- **`remove` снимает пакеты apt только через библиотеку `apt-guard`**
  (`apt_guard_remove`/`apt_guard_check`, `depends` на `apt-guard`): apt сначала
  спрашивается симуляцией, и пакет в ответе, кроме своих, — отказ до любых изменений
  (иначе `remove X` снимает и всё, что от X зависит). H-тест потребителя проверяет
  отказ «симуляция снимает чужой пакет → ничего не снято»; в `tests/live.env` —
  `apt-guard` первым в `LIVE_DEPS`.
- Идемпотентность: повторный `install` и `install --reinstall` не меняют ни одного
  файла (проверяет L).

### Стадии configure и версия cream

| Стадия | Когда | `cream:` манифеста |
|---|---|---|
| `system` | `multi-user.target` (+ свои `after`/`before`) | `">=1.0.0"` |
| `early` | `sysinit.target`, до сети | `">=1.1.0"` |
| `graphical` | после `multi-user.target` и `display-manager.service` | `">=1.1.0"` |
| `cloud-user` | после `cloud-final.service`, без cloud-init — `multi-user.target` | **`">=1.1.1"`** |

`cloud-user` требует 1.1.1, а не 1.1.0: в cream 1.1.0 эта стадия не запускается,
когда cloud-init на машине выключен; исправление — cream 1.1.1. Расширение со
стадией `cloud-user` выходит в каталоге только с `cream: ">=1.1.1"` (рулинг Р14
плана); `tools/lint-hooks.sh` отказывает манифесту, где это не так, а
`tools/new-extension.sh` ставит нужную версию сам. Пин проверок
(`tools/cream-pin.env`) — 1.1.1.

### Пин cream

`tools/cream-pin.env` — единственное место версии cream для проверок каталога:
`cream validate` (`tools/cream-validate.sh`), снимок (`tools/cream-deb.sh`), живые
прогоны (`tools/live-test.sh`). В нём `CREAM_VERSION`, `CREAM_SHA256`
(`cream_<v>_amd64.deb` — его гоняют инструменты) и `CREAM_SHA256_ARM64` (для
учёта); суммы — из `SHA256SUMS` релиза
(`gh release download v<v> -R iamletenkov/cream -p SHA256SUMS`). Поднять cream —
поправить три строки и прогнать `make ci`, `make cream-validate`; изменение пина
CI считает изменением всех L-расширений (`tools/live-matrix.sh`).

### Линт хуков: `tools/lint-hooks.sh`

Входит в `make test` (`tools/check.sh`) и проверяет все расширения каталога;
правила для скриптов перенесены из прежнего валидатора и дополнены конвенцией. Каждая находка печатается как
`файл:строка: [правило] текст`.

| Правило | Что проверяет |
|---|---|
| `header` | `hooks/*`, `actions/*`: shebang bash или sh, первая команда — `set -euo pipefail` (`set -eu` в sh) |
| `exec` | бит исполнения у `hooks/*` и `actions/*` |
| `hook-name` | имя хука из набора cream: `install upgrade configure apply secret remove check` |
| `systemctl-block` | блокирующий `systemctl start/restart/…` без `--no-block` в `apply`, `configure`, `secret` |
| `lock-none-set` | `cream set` / `cream config set` в действии с `lock: none` |
| `source-lib` | `source`/`.` пути `lib/` — общий код только библиотеками `kind: library` |
| `secret-argv` | секретный ключ (`config.keys.*.secret`, `params.*.secret: true`) в argv cream не как `KEY=-` |
| `cream-env` | присваивание `CREAM_*` или имя `CREAM_*`, которого cream не задаёт (опечатка) |
| `stage-cream` | `hooks.configure.stage: cloud-user` при `cream:` ниже `">=1.1.1"` |

Комментарии и `tests/` не проверяются. Рядом — `make lint`: скрипты расширений
(хуки, действия, `files/`, `tests/`) проходят shellcheck на уровне `warning`,
остальной репозиторий — на уровне `error` (`tools/lint.sh`). Прежние имена
путей, ключей, юнитов и таблиц nft ловит гейт `tools/check-names.sh` по всему
репозиторию (см. «Проверки»); слово `bisquite` как имя сборщика (`EXTENSION` в
README) разрешено.

## Каталог и имена

Расширение — каталог `extensions/<семейство>/<имя>/` с `extension.yaml`
(`schema: cream/v1`); имя каталога равно `name` манифеста (cream этого
требует). `cream-catalog.yaml` в корне перечисляет `roots` (`[extensions/debian]`),
и каждое расширение обязано лежать под одним из них — иначе его не увидят ни
`cream validate --catalog .`, ни снимок.

Каталог называется `debian/`, а семейство в манифесте — `platform.family: deb`;
это разные вещи. Ubuntu берёт расширения из того же `debian/`. Группировка по
семейству — удобство автора: потребитель ищет расширение по `name` в кеше
источника, а не по пути, и другой источник вправе разложить дерево иначе.

## Как расширение подключается

На живой машине — cream:

```bash
cream install <имя> [KEY=VALUE…]     # ключи — config.keys манифеста; секрет — KEY=- со stdin
cream show <имя>                     # настройки домена
sudo cream set <имя> KEY=VALUE       # проверка по схеме, атомарная запись, хук apply
cream run <имя> <действие> [аргументы]
cream remove <имя>
```

В образе — сборщик bisquite, инструкция `EXTENSION [источник/]имя
[КЛЮЧ=ЗНАЧЕНИЕ ...]` в VMFILE: применимость слоя считает `cream resolve` (фаза
`build`, архитектуры хоста и образа), а ставит расширение тот же cream в госте.
Ключи — те же `config.keys`, что у `cream install`, поэтому README каждого
расширения называет их именами манифеста; другой таблицы соответствия нет.
Ручной доставки каталога в гостя (`COPY_IN` + запуск скрипта) нет: раскладку
`/opt/cream/ext`, юниты `cream-configure@` и реестр ведёт только cream.

### Снимок каталога для cream

Для cream (спека cream §9) каталог — это источник типа `archive`: снимок
`cream-extensions-<v>.tar.gz` с `cream-catalog.yaml` в корне, который cream
скачивает, сверяет по sha256 **до** распаковки и проверяет целиком. Снимок
приложен к каждому релизу `vX.Y.Z` вместе с `SHA256SUMS` (job
`release-assets` в `.github/workflows/ci-release.yml`); на PR тот же шаг
идёт сухим прогоном без загрузки.

```bash
make snapshot        # tools/catalog-snapshot.sh: снимок HEAD в dist/
make snapshot-check  # tools/test-snapshot.sh: воспроизводимость + приёмка cream
cream source add cream-extensions --archive file:///…/cream-extensions-<v>.tar.gz \
    --sha256 <сумма из SHA256SUMS> --sync
```

Снимок — каталог коммита как он есть: `tools/catalog-snapshot.sh` выгружает
из коммита (`git archive`, не рабочее дерево) `cream-catalog.yaml`, `LICENSE`,
`NOTICE` и `roots` из `cream-catalog.yaml` без `tests/` расширений — по тем же
путям, что в репозитории; `tools/`, `docs/` и прочее в снимок не попадают.
Затем `cream catalog pack` по пину `tools/cream-pin.env` в `debian:12` без сети.
`SOURCE_DATE_EPOCH` — время коммита: две сборки одного коммита дают одни
байты, это проверяет `tools/test-snapshot.sh` (часть `tools/check.sh`), он же
подключает снимок тем же cream и разрешает `teleport` и `stvor-agent`.
Расширение под `extensions/`, не покрытое `roots`, — отказ скрипта: оно не
должно пропасть из снимка молча.

## Сборка и загрузка

| | сборка (`targets.build`) | загрузка (хук `configure`) |
|---|---|---|
| Кто запускает | cream в госте при сборке образа | `cream-configure@<имя>.service` на машине |
| Когда | при сборке образа | на каждой загрузке, на своей стадии |
| Что можно | ставить пакеты, править файлы, `systemctl enable` | всё, что зависит от конкретной машины |
| Сеть | сеть машины сборки | сеть устройства в поле |

**Границу между сборкой и загрузкой проводит не удобство, а природа задачи.** При сборке
уезжает всё, что должно быть одинаковым на всём тираже: `INSTALL` запекает
пакет в образ, и все устройства получают идентичное содержимое. На загрузку
остаётся только то, что **по природе** делается на устройстве: привязка к
пользователю, которого создаёт cloud-init (при сборке его имени нет),
генерация ключей и сертификатов, донастройка под конкретное железо.

**`configure` не должен ходить в сеть.** Строка
«сеть устройства в поле» в таблице выше описывает, что там *доступно*, а не
что там *позволено*: устройство может уехать туда, где сети нет вовсе, и
скачивание на первой загрузке молча не доедет — образ загрузится, а куска
в нём не окажется. Проверять это на стенде бесполезно, потому что на стенде
сеть есть.

Замер 2026-09-12 по всему дереву: 26 расширений, из них 12 с донастройкой
на загрузке, и сетевой вызов был ровно один — `snap install chromium`
в расширении `chromium`. Обойти его внутри расширения нечем: нативного
Chromium для arm64 нет ни в Ubuntu ports, ни в репозиториях NVIDIA —
`chromium-browser` там транзитный пакет к снапу, `firefox` на jammy устроен
так же, — то есть зависимость была не в реализации, а в самом пакете.
Расширение удалено. Браузер без снапа даёт расширение `firefox`: Mozilla
собирает amd64 и arm64 сама и публикует `.deb` в `packages.mozilla.org`,
установка идёт при сборке (проверено на AGX Orin 2026-09-14). Из репозиториев
дистрибутива остаются `epiphany-browser` (WebKitGTK) и `falkon` (QtWebEngine).

Практическое следствие для нового расширения: если работа требует
скачивания, ей место в `install`, а `configure` пусть доводит уже лежащее
в образе. Если скачивание в `configure` неизбежно — это признак, что
пакет выбран неверно.

**Сам cloud-init в сеть на первой загрузке тоже не идёт.** Бисквит пишет
в `user-data` `package_update: false` и `package_upgrade: false`
(`infrastructure/device/cloud_init.py`), а расширение `nocloud-cidata`
прибивает `datasource_list` к `[NoCloud, None]`, то есть перебора сетевых
датасорсов не будет. Сид читается с раздела `cidata` на самом носителе.

Перенести установку пакета из `install` в `configure`, чтобы обойти
несовпадение архитектур, — не оптимизация, а подмена гарантии надеждой:
каждое устройство пойдёт в репозиторий в свой момент времени и может
получить другую версию.

Ограничение libguestfs, из которого растёт вся возня с архитектурой:
совместимыми считаются только `x == y` и `x86_64 → i386`, остальное — **отказ,
а не деградация**. Граница проходит по слою: `FROM`, `COPY_IN`, `UPLOAD` и
завершающий `virt-sysprep` на amd64-хосте с arm64-образом работают, а
`UPDATE`/`INSTALL`/`RUN_COMMAND` — нет. `EXTENSION` выполняет код внутри
гостя, поэтому попадает под тот же барьер: расширение, чей `platform.arch` не
включает архитектуру образа или чей `targets.build` не годится для пары
архитектур, `cream resolve --phase build` отвергает до сборки, называя причину.

## Настройки на работающей машине

Раздел отвечает на вопрос оператора: **устройство уже работает, как
поменять настройку и чем её применить.** Ответ один на все расширения —
`cream show` / `cream set` по домену расширения:

```bash
cream show x11vnc                                    # ключи, значения, умолчания
sudo cream set x11vnc X11VNC_LISTEN=all              # проверка по схеме, запись, хук apply
echo 'пароль' | sudo cream set x11vnc X11VNC_PASSWORD=-   # секрет со stdin, не в argv
```

Схема — `config.keys` манифеста; файл — `/etc/cream/<имя>/config`
(`KEY=VALUE`, грамматика systemd `EnvironmentFile`), секреты — отдельно в
`/etc/cream/<имя>/secrets` (0600). Ручки рабочего стола (автологин,
блокировка, затемнение) — домен расширения `desktop`, общий для `gnome`,
`xfce4`, `lxde` и `cloud-user-desktop`; подробно — README `desktop`.

| Домен | Ключей | Когда правка действует |
|---|---|---|
| `can` | 1 | хук `apply` сразу после `cream set` |
| `chromium-kiosk` | 16 | на следующем `configure` (загрузка, стадия `system`) |
| `cloud-user-desktop` | 1 | при установке (`cream install --reinstall`) |
| `code-server` | 5, из них секретов 1 | хук `apply` сразу после `cream set` |
| `desktop` | 4 | на следующем `configure` (загрузка, стадия `system`) |
| `firefox` | 1 | при установке (`cream install --reinstall`) |
| `firewall` | 3 | на следующем `configure` (загрузка, стадия `early`) |
| `jetson-stats` | 1 | на следующем `configure` (загрузка, стадия `cloud-user`) |
| `kiosk` | 5 | на следующем `configure` (загрузка, стадия `graphical`) |
| `l4t-board-fdt` | 1 | при установке (`cream install --reinstall`) |
| `l4t-gstreamer` | 1 | при установке (`cream install --reinstall`) |
| `l4t-kernel-kvm` | 5 | при установке (`cream install --reinstall`) |
| `l4t-pytorch` | 1 | при установке (`cream install --reinstall`) |
| `locale` | 3 | хук `apply` сразу после `cream set` |
| `nvidia-container-toolkit` | 1 | при установке (`cream install --reinstall`) |
| `nvidia` | 3 | при установке (`cream install --reinstall`) |
| `rustdesk` | 9 | на следующем `configure` (загрузка, стадия `system`) |
| `selkies` | 29, из них секретов 3 | хук `apply` сразу после `cream set` |
| `sensing-gmsl2-camera` | 3 | хук `apply` сразу после `cream set` |
| `stvor-agent` | 6 | хук `apply` сразу после `cream set` |
| `teleport` | 17 | хук `apply` сразу после `cream set` |
| `vino-vnc` | 5, из них секретов 1 | на следующем `configure` (загрузка, стадия `system`) |
| `wallpaper` | 2 | на следующем `configure` (загрузка, стадия `cloud-user`) |
| `x11vnc` | 5, из них секретов 1 | хук `apply` сразу после `cream set` |
| `yq` | 2 | при установке (`cream install --reinstall`) |

Точнее — README расширения (таблица ключей и что делает `apply`). Остальные
расширения настроек не имеют. `/etc/cream/teleport/apps.d/` — не настройки
домена, а объявления других расширений для Teleport.

### Открытие службы в сеть — отдельное решение, а не смена адреса

Умолчания прослушивания осознанно локальные (`localhost` у `x11vnc` и
`vino`, `127.0.0.1` у `selkies`). Меняя их, проверьте, чем закрыт доступ: у
`code-server` связка `CODE_SERVER_BIND=0.0.0.0` с пустым паролем отдаёт в сеть
шелл под пользователем, который обычно состоит в группе `sudo`, — то есть
машину целиком.

Вторая альтернатива — веб-приложение Teleport (расширение `teleport`): служба
остаётся на петле, а расширение кладёт объявление в
`/etc/cream/teleport/apps.d/<имя>.conf` — `NAME` и `URI` на петле (и при нужде
`ICON`). Кому приложение видно, решает метка `env` оператора, а не объявление;
формат и проверки — README `teleport`.

Альтернатива без открытия порта и без кластера — туннель, он не требует правки
конфигурации вовсе:

```bash
ssh -L 9001:127.0.0.1:9001 <пользователь>@<машина>
```

## Манифест: правила каталога

Поля манифеста задаёт спека cream (§4). Каталог добавляет к ней несколько
правил, которые держат ревью и проверки.

- **`version`** — semver версии самого расширения (его файлов и ключей), не
  софта, который оно ставит; несовместимая правка ключей, путей или юнитов —
  мажор. Версия всего каталога — `version` в `cream-catalog.yaml` и git-тег.
- **`platform.family`** — `deb`: это не «дистрибутив» под другим именем.
  Дистрибутив осью не является **нарочно**: гость знает о себе точнее любой
  объявленной таблицы (`/etc/os-release` не устаревает молча), поэтому «на каком
  дистрибутиве мы оказались» — ветвление внутри хука, а не поле манифеста.

### `platform.arch`

Архитектура — единственная объявляемая ось применимости, потому что она
**ограничение пары хост↔гость на этапе сборки**: внутри гостя её не спросишь,
гостя ещё нет.

Написание — OCI, и оно канонизируется при разборе: `aarch64` в файле и `arm64`
в `LABEL arch` — одно и то же. Различать их было бы ложным расхождением на
каждом arm64-расширении, потому что словари ядра и OCI не совпадают. Сегодня
канонических значений два — `amd64` и `arm64`; всё остальное bisquite
отвергает, называя список.

Заполняется по факту, из кода:

- расширение ставит только apt-пакеты → обе архитектуры;
- расширение качает бинарь по ссылке, зависящей от архитектуры → те
  архитектуры, для которых релиз опубликован (так у `code-server`: ссылка
  на mkcert собирается из `dpkg --print-architecture`, и это сняло прежнее
  ограничение `amd64`);
- расширение опирается на источники, опубликованные только для одной
  архитектуры → только она. Так у `nvidia`: готовые подписанные модули
  Canonical (`linux-modules-nvidia-*`) и PPA `graphics-drivers` проверены
  только на `amd64`, а на Debian `install` берёт репозиторий CUDA из каталога
  `x86_64` → `amd64`.

Объявить архитектуру — значит пообещать, что она работает. Поэтому `armhf`
нет ни у одного расширения, хотя релизы под него существуют: 32-битные цели
проектом не собираются и не проверялись.

### `provides`

Способности, которые расширение даёт. Способность — не имя пакета, а то, на
что может сослаться сосед. Три десктопа ставят `xorg xinput` и потому дают
**одну и ту же** способность `x11-server`; если назвать её у каждого
по-своему, `x11vnc` не сможет сослаться ни на одну.

Имя расширения тоже считается способностью.

### `requires`

Способности, без которых расширение не работает. **Каждая обязана кем-то
предоставляться** — иначе `cream validate --catalog .` предупреждает.

Заполняется по коду, а не по интуиции. Пример: `x11vnc` требует `x11-server`
и `display-manager`, потому что `x11vnc@.service` прицепляется к `DISPLAY=:0`
и несёт `Requires=display-manager.service`, а обёртка `run-x11vnc.sh` ищет
X authority в каталогах, которые заводит дисплей-менеджер. Требование
**родовое**, и это верно: конкретный путь в юните не зашит — под GDM и
LightDM он разный, а под самим LightDM зависит от его конфига, — поэтому
различать в манифесте «какой именно менеджер» значило бы зафиксировать ось,
которая ответа не определяет.

Ровно это отношение сегодня держится только порядком слоёв в четырёх VMFILE:
поменяй местами `gnome` и `x11vnc` — сборка пройдёт, а VNC окажется не к чему
прицепить.

### `conflicts`

Несовместимость объявляется по имени расширения (`conflicts.extensions`) или по
способности (`conflicts.capabilities`): три десктопа конфликтуют по
`desktop-session`, и новый десктоп получает конфликт, не правя соседей.
Конфликт по имени объявляют обе стороны (`kiosk` ↔ `chromium-kiosk`): односторонний
конфликт — это конфликт, о котором узнает только один из двух авторов.

`cream validate --catalog .` проверяет граф: `depends` на отсутствующее
расширение или цикл — ошибка, `requires` без поставщика и `conflicts` на имя
не из каталога — предупреждение (способность может дать другой источник).

## Словарь способностей

Полный список того, что объявлено сегодня, и на чём это основано.

| Способность | Кто даёт | Откуда выведено |
|---|---|---|
| `x11-server` | `gnome`, `xfce4`, `lxde` | `apt-get install ... xorg xinput` (`hooks/install` у всех трёх) |
| `display-manager` | `gnome`, `xfce4`, `lxde` | `systemctl enable gdm3`/`lightdm` + `set-default graphical.target` (`hooks/install`) |
| `desktop-session` | `gnome`, `xfce4`, `lxde` | `task-gnome-desktop` / `xfce4 xfce4-goodies` / `lxde` |
| `container-runtime` | `docker` | Docker CE из apt-репозитория Docker |
| `kiosk-browser` | `kiosk`, `chromium-kiosk` | обе реализации автостартом забирают экран |
| `remote-desktop` | `x11vnc`, `vino-vnc` | `x11vnc@.service` на `rfbport` из `X11VNC_PORT`; у `vino-vnc` — `gsettings` `org.gnome.Vino` и автозапуск XDG (умолчание у обоих 5900) |
| `web-ide` | `code-server` | code-server на порту `CODE_SERVER_PORT` домена `code-server` (умолчание 9001) |
| `gpu-driver-nvidia` | `nvidia` | драйвер NVIDIA под ядро образа (2.0.0: `NVIDIA_DRIVER_VERSION`, `NVIDIA_KERNEL_MODULES=open\|proprietary`, `NVIDIA_SOURCE=archive\|ppa`) + blacklist nouveau |
| `nvidia-container-runtime` | `nvidia-container-toolkit` | `nvidia-container-toolkit` из `nvidia.github.io/libnvidia-container`, `nvidia-ctk runtime configure --runtime=docker` без смены `default-runtime` |
| `can-bus` | `can` | `can-utils`, `iproute2`; модули `can can_raw can_dev vcan slcan gs_usb peak_usb` проверены `modinfo -k <ядро образа>` (ядро L4T `*-tegra`: без `slcan gs_usb peak_usb` — предупреждение); `/etc/modules-load.d/can.conf` |
| `can-usb-adapters` | `can-usb` | `gs_usb`, `peak_usb`, `slcan` для ядра Sensing 5.15.148-tegra (AGX Orin, L4T 36.4.3): собраны при сборке образа из исходников Jetson Linux R36.4.3 против `nvidia-l4t-kernel-headers`, `/lib/modules/<ядро>/updates/can-usb`, `depmod` |
| `host-firewall` | `firewall` | таблица nftables `inet cream` (input — `policy drop`) или цепочка iptables-legacy `CREAM-INPUT` — бэкенд по модулям ядра при сборке и на каждой загрузке (`FIREWALL_BACKEND`); штатное L4T r36 без `nft_ct` — iptables; ядро без обоих — отказ; цепочки Docker не трогает |
| `system-locale` | `locale` | `locale-gen`, `/etc/default/locale`, `/etc/default/keyboard`, `xorg.conf.d/00-keyboard.conf`, умолчания GNOME input-sources (dconf) |
| `remote-support` | `rustdesk` | `.deb` RustDesk (x86_64 / aarch64) по версии и sha256 своей архитектуры, включённый `rustdesk.service`; адреса сервера — `RustDesk2.toml` из домена `rustdesk` |
| `nocloud-cidata-seed` | `nocloud-cidata` | `/etc/cloud/cloud.cfg.d/zz-cream-nocloud.cfg` с `fs_label: cidata` |
| `network-manager` | `network-manager` | пакеты `network-manager` и `wpasupplicant`, включённый `NetworkManager.service` |
| `jetson-monitor` | `jetson-stats` | `jtop` из PyPI плюс `jtop.service`; данные идут из `tegrastats` и sysfs Tegra, а не из NVML |
| `cuda` | `cuda-toolkit` | `cuda-toolkit-12-6` из `jetson/common`, `nvcc` в `/usr/local/cuda/bin` |
| `tensorrt` | `tensorrt` | мета-пакет `tensorrt` плюс `python3-libnvinfer` и `nvidia-l4t-dla-compiler` |
| `web-remote-desktop` | `selkies` | Selkies 2.0 (AppImage) на существующем X-дисплее, WebSocket на `127.0.0.1:8080`; `selkies@.service` от пользователя сессии |
| `web-browser` | `firefox` | `firefox` из `packages.mozilla.org` с пином 1000 поверх транзитного пакета снапа |
| `teleport-node` | `teleport` | `/usr/local/bin/teleport`, `teleport.service` из `cream run teleport join`; приложения — из `/etc/cream/teleport/apps.d` |
| `l4t-boot-verify` | `l4t-boot-verify` | `l4t-boot-verify.service` — `nvbootctrl verify` на каждой загрузке; вендорская `nv-l4t-bootloader-config` заглушена |
| `gmsl2-camera` | `sensing-gmsl2-camera` | ядро и модули Sensing (пакеты ядра L4T — `apt-mark hold`), DTB-оверлей, запуск камер на каждой загрузке (`modprobe.d`, правило udev, `sensing-gmsl2-clock.service`) |
| `gstreamer` | `l4t-gstreamer` | `gstreamer1.0-tools` и плагины base/good/bad/ugly/libav, RTSP-сервер, `gstreamer1.0-nice`, `python3-gst-1.0` |
| `hw-video-codec` | `l4t-gstreamer` | `nvidia-l4t-gstreamer` версии `nvidia-l4t-core`: `nvv4l2h264enc`/`h265enc`/`decoder`, `nvvidconv` |
| `opencv` | `l4t-opencv` | `libopencv` и `libopencv-python` 4.8.0 от NVIDIA, с GStreamer, без CUDA; на R32 ничего не ставит — сверяет cv2 образа (с CUDA) и пишет `OPENBLAS_CORETYPE` |
| `pytorch` | `l4t-pytorch` | колесо torch nv24.08 с CDN NVIDIA, torchvision из исходников с CUDA; на R32 ничего не ставит — сверяет torch образа и пишет `OPENBLAS_CORETYPE` |
| `tensorflow` | `l4t-tensorflow` | колесо tensorflow nv24.08 с CDN NVIDIA |

Кто чего требует:

| Расширение | `requires` | Откуда выведено |
|---|---|---|
| `x11vnc` | `x11-server`, `display-manager` | `x11vnc@.service` — `Requires=display-manager.service` и `DISPLAY=:0`. Путь к X authority в юните НЕ зашит: он разный под LightDM и GDM, и обёртка ищет его в рантайме |
| `kiosk` | `x11-server`, `display-manager` | `install` ставит клиентские утилиты X, но **не** `xorg`; `kiosk-chromium@.service` — `DISPLAY=:0`; донастройка — стадия `graphical` (после `display-manager.service`). Путь к X authority в юните, как и у `x11vnc`, НЕ зашит — его ищет обёртка `run-kiosk.sh` |
| `vino-vnc` | `x11-server`, `display-manager` | vino живёт ВНУТРИ пользовательской сессии: `configure` пишет `gsettings` в dconf пользователя и кладёт автозапуск в его `~/.config/autostart`, а сессию открывает дисплей-менеджер. Системного юнита и поиска X authority здесь нет вовсе — этим он и отличается от `x11vnc` |
| `selkies` | `x11-server`, `display-manager` | `run-selkies.sh` снимает экран существующего X-дисплея и ждёт сессию пользователя; без автологина показывать нечего |
| `l4t-pytorch` | `cuda` | `install` отказывает без `/usr/local/cuda/bin/nvcc`: им собирается torchvision с `FORCE_CUDA=1`; сам torch грузит `libcublas`, `libcufft` и прочие библиотеки тулкита. На R32 (Nano) не проверяется: torch и CUDA 10.2 уже в образе |
| `l4t-tensorflow` | `cuda` | `install` отказывает без `/usr/local/cuda/lib64`: TF грузит библиотеки тулкита |
| `can-usb` | `gmsl2-camera` | `install` отказывает, если `/boot/Image` — не ядро Sensing закреплённой сборки: модули собираются под него, а кладёт его `sensing-gmsl2-camera` — ставится раньше `can-usb` |
| `nvidia-container-toolkit` | `gpu-driver-nvidia`, `container-runtime` | `nvidia-ctk runtime configure --runtime=docker` правит `/etc/docker/daemon.json`; без драйвера среда `nvidia` бесполезна |
| остальные | — | ничего не требуют по коду |

Конфликты:

| Пара | Причина |
|---|---|
| `gnome` ↔ `xfce4` ↔ `lxde` (по способности `desktop-session`) | каждый ставит свой дисплей-менеджер и делает его системным `display-manager.service` |
| `kiosk` ↔ `chromium-kiosk` | оба автостартом на `graphical.target` разворачивают полноэкранный браузер на одном месте |

Оговорка про честность вывода: десктопы измерены по коду, киоски —
рассуждение, а не замер. Ни один VMFILE не ставит `kiosk` и `chromium-kiosk`
вместе, так что проверить конфликт на практике не на чем.

### Docker: одно расширение, и почему их было два

Расширений было два — `docker` через `get.docker.com` и `docker-ce` через
apt-репозиторий, — на том основании, что старым системам нужен скрипт, а
новым репозиторий. Замер 2026-09-03 опроверг это дважды, и они слиты.

**Скрипт ставит из того же репозитория.** `get.docker.com` пишет однострочный
`.list` на `download.docker.com` вместо deb822 (`getdocker.sh:596,606`).
Второго источника пакетов никогда не существовало, значит и противопоставления
не было.

**На bionic скрипт ломает сборку.** `version_gte()` при пустом `VERSION`
возвращает истину всегда (`getdocker.sh:230-234`), поэтому гейт
`version_gte "28.2"` пропускает `docker-model-plugin` в список безусловно —
а в репозитории bionic его нет ни для amd64, ни для arm64. При `set -e` это
фатально.

**Довод про apt тоже неверен.** deb822 с `Signed-By: <путь>` работает начиная
с apt 1.6.17 (замерено в `ubuntu:18.04`); apt ≥ 2.4 нужен только встроенному
ключу, которым никто не пользуется.

Что осталось верным: репозиторий для bionic **заморожен** — Release от
13.06.2023, `docker-ce 24.0.2` против 29.7.2 у noble. Но это потолок цели,
а не выбор способа установки, и расширение говорит об этом вслух.

Разбор целиком — в `extensions/debian/docker/README.md`.

## Новое расширение: каркас

```bash
tools/new-extension.sh <имя> [--stage system|early|cloud-user|graphical]
                             [--live yes|confirm|no] [--cloud-user] [--library]
                             [--arch amd64,arm64]
```

Кладёт скелет **cream/v1** в `extensions/debian/<имя>/`: манифест
(`schema: cream/v1`, `cream:` по стадии — `cloud-user` получает `">=1.1.1"`,
`early`/`graphical` — `">=1.1.0"`), хуки `install` и `remove` (Р9), при `--stage` —
`configure` нужной стадии, пример ключа домена `<ИМЯ>_EXAMPLE`, H-тест
`tests/test-<имя>.sh` на `tools/hooktest.sh` и README с таблицей ключей.
`--cloud-user` объявляет `depends` на библиотеку `cloud-user` и зовёт
`"${CREAM_ROOT:-}/opt/cream/ext/cloud-user/get_cloud_user.sh"` из `configure`;
`--library` даёт `kind: library` без хуков. `tests/live.env` каркас не кладёт:
с ним расширение попадает в живые прогоны CI, и заводит его автор, когда
`install` делает настоящую работу.

Скелет сразу проходит `tools/lint-hooks.sh`, гейт имён, shellcheck уровня
`warning`, свой H-тест и `cream validate` по пину — это держит
`tools/test-new-extension.sh` (в `make test`). Манифест намеренно пустой там, где
знает только автор: `provides` и `requires` заполняются **по коду** — из того,
что хуки реально ставят и что требуют юниты. Заполненные за автора способности
выглядели бы обдуманными и пережили бы ревью.

`bs extension new` в bisquite кладёт прежнюю раскладку и для этого каталога не
годится: каркас — только `tools/new-extension.sh`.

## Проверки

```bash
tools/check.sh                # всё сразу: cream validate, гейт имён, линт хуков, тесты (make test)
tools/lint.sh                 # shellcheck: скрипты расширений — warning, остальное — error (make lint)
tools/lint-hooks.sh           # линт хуков и действий (см. «Формат cream/v1»)
tools/cream-validate.sh       # cream validate --catalog . по корню (make cream-validate)
tools/check-names.sh          # прежние имена bisquite по всему репозиторию (make check-names)
tools/live-test.sh <имя>      # живой прогон настоящим cream (make test-live EXT=<имя>)
```

### Тесты расширения: V, H, L

Три уровня (план [2026-10-19-cream-v1-migration](plans/2026-10-19-cream-v1-migration.md), колонка «тесты»):

- **V** — `cream validate` (`make cream-validate`), линт хуков `tools/lint-hooks.sh` и гейт имён
  `tools/check-names.sh`: прежних путей, ключей, юнитов и таблиц nft нет (список — в скрипте). Слово
  `bisquite` как имя сборщика можно. Таблиц переименований в README нет — они в описании PR
  (`BREAKING CHANGE`); строку теста, проверяющего отсутствие, помечают `check-names: allow`, блок —
  `check-names: off` … `check-names: on`.
- **H** — хуки на подменённом корне: `extensions/<семейство>/<имя>/tests/test-*.sh`, исполняемый,
  код 0 — прошли. `tools/check.sh` находит такие файлы сам, править его не нужно. Общая обвязка —
  `tools/hooktest.sh` (`. "$HERE/../../../../tools/hooktest.sh"`): `ht_root` кладёт копию расширения в
  `$ROOT/opt/cream/ext/<имя>`, `ht_hook <хук> [KEY=VALUE…]` зовёт хук как cream (очищенное окружение,
  `CREAM_*`, несекретные ключи с default, cwd — каталог расширения), `ht_fake` подставляет команду с
  журналом вызовов; опасные на хосте команды (`apt-get`, `dpkg`, `systemctl`, `curl`, …) закрыты сторожем
  с кодом 127, пока тест их не подставит. Образец — `tools/test-hooktest.sh`.
- **L** — живой прогон `tools/live-test.sh <имя>` (`make test-live EXT=<имя> [DISTRO=…]`): контейнер
  `debian:12`/`debian:13`/`ubuntu:22.04`/`ubuntu:24.04` с systemd как PID 1 (флаги — как у интеграции
  cream: без `--privileged`, `--cgroupns=host`, cgroup на запись, `--tmpfs /run`, явный `--memory`),
  настоящий cream по пину, источник `path`. Сценарий: зависимости → `install` → повтор (`changed: false`)
  → `install --reinstall` не меняет ни одного файла в `/etc`, `/opt/cream`, `/usr/local`,
  `/var/lib/cream/ext` → перезапуск (configure на загрузке успешен, `systemctl --failed` пуст, нет
  `ordering cycle`) → `remove` (если есть хук); значения секретов не видны в `ps`, журнале, реестре.
  Код 20 допустим только от хука `install` и только с `--expect-skip` (рулинг Р11): `configure` без
  устройства пишет предупреждение и выходит 0. Умолчания прогона — `tests/live.env` расширения (данные
  `KEY=value`): `LIVE_DEPS`, `LIVE_ACCEPT_RISK=1`, `LIVE_EXPECT_SKIP=1`, `LIVE_PARAMS`, `LIVE_SECRETS`,
  `LIVE_MEMORY`, `LIVE_CAPS` (`firewall` — `NET_ADMIN`), `LIVE_SNAPSHOT_IGNORE`, `LIVE_BOOT_CONFIGURE=optional`,
  `LIVE_FAILED_IGNORE` (ERE с якорями `^…$` по имени юнита целиком: юниты, которые роняет контейнер, а не
  расширение, — например, `lightdm.service` без VT или монтирования NFS без `CAP_SYS_ADMIN`; каждый такой
  юнит печатается строкой «разрешено упасть»), `LIVE_NIGHTLY_ONLY=1` (тяжёлое расширение — `gnome`, `lxde` —
  не входит в матрицу PR, только в ночной и ручной прогон), `LIVE_DISTROS`. Зависимости ставятся с `--allow-skip`:
  зависимость, ответившая кодом 20 (`nvidia` без ядер), записывается `skipped` и печатается «пропущена». Наличие `tests/live.env` делает расширение L-расширением для CI: `.github/workflows/live.yml`
  гоняет изменённые на PR (и те, чьи `LIVE_DEPS` изменились) и все — ночью, каждое на своём раннере.
  Прогоны на хосте идут по одному (замок `flock`), контейнер и образ удаляются, журналы — в
  `.scratchpad/live/<имя>-<дистрибутив>/`. Самопроверка раннера на фикстурах `tools/testdata/live/` —
  `make test-live-self`.

`tools/cream-validate.sh` без аргументов гоняет `cream validate --catalog .` по
корню репозитория как он есть (смонтирован только на чтение, контейнер
`debian:12` без сети): все расширения под `roots`, граф (`depends` на
отсутствующее — ошибка, `requires` без поставщика — предупреждение),
повторяющиеся имена и сверку юнитов с действиями. С аргументами — только
названные каталоги во временном каталоге (так их проверяют тесты инструментов
на фикстурах `tools/testdata/cream-v1-min/`, `ok` и заведомо невалидный `bad`).
cream берётся по пину `tools/cream-pin.env` (см. «Пин cream»); пустой пин —
пропуск со строкой «cream/v1 пропущен: пин cream не задан». Локально без
релиза — `CREAM_DEB=<путь к .deb> tools/cream-validate.sh [каталог…]` (пин не
проверяется, об этом печатается предупреждение).

`tools/check-names.sh` без аргументов проверяет каждый файл, который git
отслеживает или отследил бы (`.gitignore` соблюдается), кроме истории —
`CHANGELOG.md`, `docs/research/`, `docs/plans/` — и самого гейта с его тестом и
фикстурами; двоичные файлы (картинки, архивы) пропускаются. Исключения в тексте —
`check-names: allow` (строка) и `check-names: off` … `check-names: on` (блок).

### Где это выполняется само

Проверка, которую надо не забыть запустить, — не проверка. `tools/check.sh`
гоняет GitHub Actions: `.github/workflows/ci-release.yml`, на каждый pull
request в `main` и на каждый push в `main`. Один job, одна команда — та же, что
запускают руками, чтобы CI и локальный прогон не разъезжались.

- **`runs-on: ubuntu-latest`, а не `[self-hosted, linux, x64]`,** как в основном
  репозитории: job, приколоченный к раннеру, которого у репозитория может не
  оказаться, не падает, а висит в очереди навсегда, и это хуже красного CI.
- **PyYAML ставится явно**, хотя на образе раннера он есть: манифесты читают
  `tools/lint-hooks.sh`, `tools/hooktest.sh` и тесты, и обновление образа не
  должно выключить их молча.
- **`check.sh` доводит до конца все проверки**, даже если первая упала: ошибки
  всех видны в одном прогоне CI.

Локально перед пушем — `make ci` (линт и `tools/check.sh`). Нужны bash, git,
Python 3 с PyYAML и docker (cream validate и снимок).

## Как добавить расширение

1. `tools/new-extension.sh <имя> [ключи]` — скелет cream/v1 (не копия соседа).
2. Тест первым: в `tests/test-<имя>.sh` — проверки поведения хуков на
   подменённом корне (`tools/hooktest.sh`), красные до правки хука.
3. Хуки — по «Формату cream/v1»: `install` идемпотентный, ключи из окружения,
   секреты из `$CREAM_SECRETS_FILE`, `remove` снимает только своё, `configure` без
   устройства — предупреждение и 0. Юниты и правила — через `files:` манифеста,
   CLI для человека — действия (`cream run <имя> …`). Общий код — библиотека в
   `depends`. Скачанное — по пину версии и sha256.
4. `extension.yaml`: `summary`, `provides`/`requires` **по коду**, `config.keys`
   (без префикса `CREAM_`), `targets.live` (`confirm`/`no` — с `live_note`),
   `cream:` по стадии.
5. `README.md` расширения: что делает, `cream install/set/run`, **таблица ключей**
   домена — у автора VMFILE (`EXTENSION <имя> KEY=VALUE`) другого справочника нет.
6. `make ci` (линт, `tools/lint-hooks.sh`, гейт имён, тесты), `make cream-validate`;
   L-расширение — `tests/live.env` и `make test-live EXT=<имя>`.
7. Выпуск — release-please (тег каталога — `ref` источника), не руками.

## Что осталось незакрытым

Перечислено, чтобы не выглядело сделанным.

- **Дефект «одна способность двумя механизмами» не закрыт.** Docker ставится
  расширением примерно в половине случаев, в остальных — голым `INSTALL`
  в VMFILE. В один граф зависимостей эти два способа не попадают, поэтому
  топологическая сортировка тут не поможет. Закрывается только приведением
  примеров к единообразию, то есть правками в основном репозитории.
- **Требования к базовому образу манифестом выражены не все.** Библиотека
  `cloud-user` узнаёт пользователя cloud-init через `cloud-init` и `yq` (без них —
  запасной путь по первой учётке с uid ≥ 1000), а ставит их базовый образ;
  проверить, что база их даёт, при сборке нечем.
- **`arch` у `chromium-kiosk` объявлен, но не проверен.** Пакет тянется из
  стороннего репозитория `repository.salamek.cz` (suite `all`); что там есть
  под arm64, не замерялось. На сборках bisquite подтверждён только amd64.
- **Пароль x11vnc проходит через argv `x11vnc -storepasswd`** на время
  короткого вызова хука: у `-storepasswd` нет чтения со stdin. Из argv cream
  секрет убран (`KEY=-`).
