# teleport

Узел Teleport на машине: SSH-нода и веб-приложения без входящих портов — агент
сам держит обратный туннель к прокси на 443. Исполнитель —
[cream](https://github.com/iamletenkov/cream); способность — `teleport-node`.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian ≥ 12, Ubuntu ≥ 20.04 |
| Архитектура | amd64, arm64 |
| cream | ≥ 1.0.0 |
| Даёт | `teleport-node` |
| Требует | — |
| Зависит от | — |
| Конфликтует с | способность `teleport-node` |
| Хуки | `install`, `upgrade`, `remove`, `apply` |
| Настройка на загрузке | — |
| Действия | `cream run teleport join`, `cream run teleport join-retry`, `cream run teleport leave`, `cream run teleport set-managed`, `cream run teleport managed-status`, `cream run teleport apps-status`, `cream run teleport status`, `cream run teleport render`, `cream run teleport reload-apps`, `cream run teleport hup`, `cream run teleport scrub-token` |
| Живая машина | да |
<!-- /catalog:facts -->

Метки узла задают три стороны: оператор (`TELEPORT_ENV`, `TELEPORT_LABELS`),
внешний управляющий — служба `stvor-agent` (управляемые метки
`TELEPORT_MANAGED_LABELS`, действия `set-managed` и `managed-status`) и другие
расширения (командные метки `command-labels.d`).

## Что делает

- **`install`** (и **`upgrade`** — тот же код) — ставит только бинарь `teleport`
  в `/usr/local/bin` (без `tsh`, `tctl`, `tbot`) из тарбола Teleport 18.10 (см.
  «Установка — бинарь Teleport»), включает `teleport-apps.path` и
  `teleport-token.path` и **не регистрирует** узел и не запускает агента. Та же
  версия уже стоит — пропуск без скачивания. Смена ключа — повтор
  `cream install teleport KEY=…`: новый бинарь, и работавший агент перезапускается
  (`try-restart`). В сборке образа (`CREAM_PHASE=build`) хук отказывает, если в
  `/var/lib/teleport` уже есть регистрация: иначе все копии образа были бы одной
  нодой. cream раскладывает юниты `teleport.service`, `teleport-apps.{path,service}`,
  `teleport-token.{path,service}`, `teleport-join.{service,timer}` в
  `/etc/systemd/system/`.
- **`apply`** (после `cream set`) — render и `systemctl --no-block
  reload-or-restart teleport.service` — HUP, открытые сессии живут.
- **`remove`** — `leave`, path-юниты выключены, бинарь и состояние стёрты; юниты
  и (с `--purge`) домен удаляет cream.

Хука `configure` нет: регистрация — действие `join` (см. «Регистрация — `join`»),
конфиг собирает действие `render` в `ExecStartPre`/`ExecReload` `teleport.service`.

| Путь | Что |
|---|---|
| `/opt/cream/ext/teleport/` | дерево расширения: `hooks/`, `actions/` (тонкие входы), `files/teleport.sh` (слой systemd), `files/teleport-core.sh` (общее ядро, см. «Ядро и слой»), `files/os-logins` (метка `os_logins`, её зовёт Teleport) |
| `/etc/systemd/system/teleport{,-apps,-token,-join}.*` | юниты (раскладывает cream) |
| `/etc/cream/teleport/{config,apps.d,command-labels.d}` | домен ручек и объявления |
| `/var/lib/cream/ext/teleport/{installed-pin,registration-secret,join-pending,join-refused,managed-pending,reload-pending,rollback}` | состояние (каталог 0700, файлы 0600); `installed-pin` — строки `TELEPORT_VERSION=` и `TELEPORT_SHA256=` поставленного тарбола, при `TELEPORT_TAG` (с `TELEPORT_DIST` или `TELEPORT_TARBALL`) — и `TELEPORT_TAG=` сборки форка |
| `/etc/teleport.yaml`, `/var/lib/teleport/`, `/usr/local/bin/teleport` | Teleport |

## Параметры

<!-- catalog:params -->
| Ключ | Тип | Умолчание | Что задаёт |
|---|---|---|---|
| `TELEPORT_VERSION` | строка `^[0-9]+\.[0-9]+\.[0-9]+$` | `18.10.0` | версия Teleport; не новее кластера, для bound_keypair — не ниже 18.8.0 *(только при установке)* |
| `TELEPORT_SHA256` | строка `^[0-9a-f]{64}$` | пусто | sha256 тарбола архитектуры машины; пусто — .sha256 с cdn.teleport.dev *(только при установке)* |
| `TELEPORT_MIRROR` | строка `^https?://[A-Za-z0-9.:/-]+$` | пусто | база зеркала <base>/binaries/teleport/<ver>/<тарбол>; пусто — cdn.teleport.dev *(только при установке)* |
| `TELEPORT_TARBALL` | `path` | пусто | локальный тарбол (офлайн, нужен TELEPORT_SHA256); взаимоисключим с TELEPORT_MIRROR и TELEPORT_DIST *(только при установке)* |
| `TELEPORT_DIST` | строка `^https://[A-Za-z0-9.:/-]+$` | пусто | раздача портала Stvor <база>/teleport/<тег>/<тарбол>; только с TELEPORT_TAG и TELEPORT_SHA256 *(только при установке)* |
| `TELEPORT_TAG` | строка `^v[0-9]+\.[0-9]+\.[0-9]+-stvor\.[0-9]+$` | пусто | тег сборки форка vX.Y.Z-stvor.N (X.Y.Z = TELEPORT_VERSION); с TELEPORT_DIST или TELEPORT_TARBALL *(только при установке)* |
| `TELEPORT_PROXY` | строка `^[a-z0-9][a-z0-9.-]{0,252}(:[0-9]{1,5})?$` | пусто | прокси кластера host[:port]; пишет только join *(только чтение)* |
| `TELEPORT_JOIN_METHOD` | `token` \| `bound_keypair` | `token` | метод регистрации; пишет только join *(только чтение)* |
| `TELEPORT_TOKEN` | строка `^[A-Za-z0-9._-]{8,256}$` | пусто | имя токена bound_keypair (не секрет); у метода token пусто; пишет только join *(только чтение)* |
| `TELEPORT_CA_PIN` | строка `^sha256:[0-9a-f]{64}$` | пусто | необязательная сверка CA кластера: sha256:<64 hex> |
| `TELEPORT_ENV` | строка `^[a-zA-Z0-9][a-zA-Z0-9_./ -]{0,127}$` | пусто | метка env — по ней роли кластера дают доступ |
| `TELEPORT_NODENAME` | строка `^[a-z0-9][a-z0-9-]{1,62}$` | пусто | имя ноды, метка DNS; пусто — короткое имя хоста |
| `TELEPORT_LABELS` | список через пробел, элемент `^[a-zA-Z0-9][a-zA-Z0-9_./-]{0,63}=[a-zA-Z0-9][a-zA-Z0-9_./-]{0,127}$` | пусто | прочие метки ноды ключ=значение через пробел (env, app, os_logins, teleport.icon нельзя) |
| `TELEPORT_APPS` | список через пробел, элемент `^[a-z0-9][a-z0-9-]{0,62}=([0-9]{1,5}\|https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?)$` | пусто | приложения оператора имя=порт или имя=http(s)://хост[:порт][/путь] через пробел |
| `TELEPORT_APPS_DISABLE` | список через пробел, элемент `^[a-z0-9][a-z0-9-]{0,62}$` | пусто | не публиковать объявленные приложения: имена через пробел |
| `TELEPORT_APPS_ICONS` | список через пробел, элемент `^[a-z0-9][a-z0-9-]{0,62}=[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` | пусто | иконка приложения в веб-морде прокси: имя=иконка через пробел |
| `TELEPORT_APPS_DISCOVERY` | `bool` | `1` | 0 — не читать объявления /etc/cream/teleport/apps.d |
| `TELEPORT_OS_LOGINS` | `bool` | `1` | динамическая метка ноды os_logins (root и uid >= 1000 с shell); 0 — нет |
| `TELEPORT_MANAGED_LABELS` | список через пробел, элемент `^[a-z][a-z0-9_]{0,62}=[a-z0-9][a-z0-9._-]{0,62}$` | пусто | управляемые метки ключ=значение через пробел; пишет только set-managed *(только чтение)* |
<!-- /catalog:params -->

**Ключи установки** (`scope: install`, смена — повтор `cream install teleport KEY=…`):

- `TELEPORT_VERSION` — **не новее кластера**, не старше на мажор; для
  `bound_keypair` — не ниже 18.8.0.
- `TELEPORT_SHA256` — пусто: `.sha256` с `cdn.teleport.dev` (второй канал, если
  тарбол с зеркала). Своя сборка Teleport на зеркале (форк той же версии) — не тот
  тарбол, что описывает `.sha256` CDN: её сумму задают явно. С заданной суммой
  `install`/`upgrade` сверяют и версию, и сумму поставленного тарбола (файл
  `installed-pin` состояния): пересборка форка той же версии с новой суммой
  (`v18.10.0-stvor.3` → `stvor.4`) ставится заново и перезапускает агента, без
  `--reinstall`. Без суммы — сверка только по версии. Перед скачиванием нового тарбола
  `installed-pin` снимается: прерванная установка (чужая сумма, обрыв) не выглядит завершённой.
- `TELEPORT_MIRROR` — база зеркала:
  `<база>/binaries/teleport/<версия>/teleport-v<версия>-linux-<arch>-bin.tar.gz`;
  пусто — `cdn.teleport.dev`.
- `TELEPORT_DIST` + `TELEPORT_TAG` — раздача портала Stvor: тарбол по
  `<база>/teleport/<тег>/teleport-v<версия>-linux-<arch>-bin.tar.gz`, тег — сборка форка
  `vX.Y.Z-stvor.N` той же X.Y.Z, что `TELEPORT_VERSION`. Портал отвечает 302 на подписанную
  ссылку S3 (тот же или другой хост): curl идёт по редиректу только по https
  (`--proto =https --proto-redir =https`). Задаются вместе и только с `TELEPORT_SHA256`
  (сумма форка на `cdn.teleport.dev` не лежит).
  Доверие — только закреплённым корням агента stvor-agent v2: `--cacert
  /etc/stvor-agent/roots.pem` (и `--capath` на каталог с их копией, чтобы системные корни
  сборки curl не добавились); нет `roots.pem` — отказ до скачивания, без отката на системные
  корни. Хост подписанной ссылки обязан сходиться к тем же корням. Прокси — только `proxy=`
  из `/etc/stvor-agent/token` (`--proxy`), без него — `--noproxy '*'`; `HTTPS_PROXY` и
  прочие `*_proxy` окружения у curl сняты.
- `TELEPORT_TARBALL` — локальный тарбол; нужен `TELEPORT_SHA256`. С `TELEPORT_TAG` (тег той же
  X.Y.Z, что `TELEPORT_VERSION`) — офлайн-сборка форка: тег ничего не качает, только пишется
  в `installed-pin`; тот же тарбол с новым тегом переписывает пин без переустановки бинаря.

Источник тарбола — один из трёх: `TELEPORT_MIRROR`, `TELEPORT_DIST` + `TELEPORT_TAG` или
`TELEPORT_TARBALL` (с ним — по желанию `TELEPORT_TAG`); два сразу — отказ до скачивания.
Ни одного — `cdn.teleport.dev`. `TELEPORT_TAG` без `TELEPORT_DIST` и `TELEPORT_TARBALL`
(в том числе с `TELEPORT_MIRROR`) — отказ.

Обрыв на LTE: тарбол качается до 5 попыток, каждая докачивает частичный файл (`-C -`),
паузы между ними 5, 10, 20, 40 с; внутри попытки curl повторяет любую ошибку
(`--retry 5 --retry-all-errors`: обрыв потока HTTP/2, 429 с `Retry-After`; на curl < 7.71 —
только `--retry 5`). Сумма сверяется после докачки как обычно. Цена: неверный `TELEPORT_TAG`
(тег по форме, но такого на портале нет — 404) даёт отказ лишь примерно через 3 минуты.

**Ручки** — `cream set teleport KEY=…` (хук `apply`):

| Ключ | Что делает |
|---|---|
| `TELEPORT_PROXY`, `TELEPORT_JOIN_METHOD`, `TELEPORT_TOKEN` | `readonly`: пишет только `join` (и `leave`) |
| `TELEPORT_CA_PIN` | сверка CA кластера `sha256:<64 hex>` |
| `TELEPORT_ENV` | метка `env` — по ней роли кластера дают доступ |
| `TELEPORT_NODENAME` | имя ноды; пусто — короткое имя хоста |
| `TELEPORT_LABELS` | метки ноды `ключ=значение` **через пробел**; `env`, `app`, `os_logins`, `teleport.icon` нельзя |
| `TELEPORT_APPS` | приложения оператора `имя=порт` или `имя=http(s)://хост[:порт][/путь]` через пробел |
| `TELEPORT_APPS_DISABLE` | не публиковать объявленное: имена через пробел |
| `TELEPORT_APPS_ICONS` | `имя=иконка` через пробел; сильнее `ICON=` объявления |
| `TELEPORT_APPS_DISCOVERY` | `0` — не читать `apps.d` |
| `TELEPORT_OS_LOGINS` | `0` — без динамической метки `os_logins` |
| `TELEPORT_MANAGED_LABELS` | `readonly`: пишет только `set-managed` (и `leave`) — см. «Управляемые метки» |

Значения ложатся в YAML в двойных кавычках: кавычек и `$` в них нет (те же
регулярные выражения — в ядре `files/teleport-core.sh`, `KEY_TYPE`).

## Установка

На машине с подключённым каталогом ([как подключить](../../../docs/getting-started.md)):

```bash
sudo cream install --with-deps teleport                                   # 18.10.0 с cdn.teleport.dev
sudo cream install --with-deps teleport TELEPORT_VERSION=18.10.0 TELEPORT_MIRROR=https://binaries.example.org \
    TELEPORT_SHA256=<sha256 тарбола архитектуры машины>
sudo cream install --with-deps teleport TELEPORT_TARBALL=/media/teleport-v18.10.0-linux-arm64-bin.tar.gz \
    TELEPORT_SHA256=<sha256>                                             # офлайн
```

В образе bisquite (VMFILE) — только бинарь; регистрация — на машине (`join`
работает только на живой машине):

```dockerfile
RUN_COMMAND cream install --with-deps teleport
```

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | бинарь, path-юниты включены; регистрации нет (в сборке — отказ, если она есть) |
| `cream upgrade` | тот же код, что `install`; агент перезапускается |
| `cream run teleport join …` | регистрация узла (см. ниже) |
| загрузка | `teleport-join.timer` повторяет ждущую регистрацию; `teleport.service` собирает конфиг (`render`) |
| `cream set` (хук `apply`) | render и HUP агенту |
| изменение `apps.d` или `command-labels.d` | `teleport-apps.path` → `reload-apps` |
| `cream remove` | `leave`, бинарь и состояние стёрты |

Действия:

| Действие | `lock` | Что делает |
|---|---|---|
| `join KEY=…` | exclusive | регистрация, JSON в stdout |
| `join-retry` | exclusive | тик `teleport-join.timer`; ручная регистрация после `TELEPORT_DEFER=1` |
| `leave` | exclusive | агент выключен, `/var/lib/teleport`, `teleport.yaml`, секрет, ожидание, управляемые метки и `managed-pending` стёрты; JSON `{"result":"left"}` |
| `set-managed k=v…` | exclusive | полный набор управляемых меток; JSON схемы 1 |
| `managed-status` | none | управляемые метки, маркер, регистрация, агент; JSON схемы 1 |
| `apps-status` | none | итог публикации приложений: опубликованные, отброшенные объявления с причиной; JSON схемы 1 |
| `status` | none | регистрация, служба, ручки, приложения, управляемые и командные метки — текстом |
| `render` | none | `/etc/teleport.yaml` (0600); `ExecStartPre`/`ExecReload` `teleport.service` |
| `reload-apps` | exclusive | `teleport-apps.service`: render, HUP с подтверждением новым процессом или restart |
| `hup` | none | `ExecReload` `teleport.service`: адресный HUP с подтверждением, иначе `reload-pending` |
| `scrub-token` | exclusive | `teleport-token.service`: стирает секрет первого входа |

## Известные ограничения

- Только Debian ≥ 12 и Ubuntu ≥ 20.04; Ubuntu 18.04 (systemd 237) не
  поддерживается (см. «Установка — бинарь Teleport»).
- `TELEPORT_VERSION` не новее кластера и не старше на мажор.
- Регистрации в кластере в живом L-прогоне нет.
- `cream validate` предупреждает (`validate.unit_lock`) о трёх юнитах — это
  допустимо (см. «Действия и файлы»).

## Подробности

### Ядро и слой

С 4.2.0 init-независимая часть — ручки, `render`, `join` с повтором и отказом, метки,
`apps.d`, `command-labels.d`, управляемые метки, `status` — общее ядро
`files/teleport-core.sh`, одно с [teleport-openwrt](../../openwrt/teleport-openwrt/README.md).
В git у ядра одна копия — `lib/teleport-core.sh` каталога; в расширение его кладёт снимок
(`tools/catalog-snapshot.sh`), для проверок — `tools/stage-catalog.sh`. `files/teleport.sh`
— слой systemd: пути, юниты, `journalctl`, тарбол `linux-<arch>`, HUP. Поведение не
изменилось, кроме одного усиления: строка отказа в журнале засчитывается, только пока у
узла нет identity в `data_dir`. Бинарь Teleport ядро зовёт как `env -u LD_PRELOAD …`. Строка `files` с ядром
(`/usr/lib/teleport/teleport-core.sh`) нужна, чтобы `cream validate` отверг дерево без него.

### Установка — бинарь Teleport

**Платформа:** Debian ≥ 12, Ubuntu ≥ 20.04 (ради Jetson Nano на L4T R32). Тарбол
Teleport 18.10 arm64 требует glibc ≥ 2.17 (`objdump -T`, 2026-10-20), у focal
2.31; path-юниты, `PIDFile`, `ConditionPathExists` и `systemctl show --value` есть
в systemd 245. Ubuntu 18.04 (systemd 237) не поддерживается.

### Регистрация — `join`

```bash
printf '%s' '<секрет регистрации>' | sudo cream run teleport join TELEPORT_PROXY=teleport.example.org \
    TELEPORT_JOIN_METHOD=bound_keypair TELEPORT_TOKEN=robot-lab-1 TELEPORT_REGISTRATION_SECRET=- \
    TELEPORT_ENV=dev TELEPORT_NODENAME=lab-1 "TELEPORT_LABELS=space=sp-0123abcd site=lab"
printf '%s' '<join-токен>' | sudo cream run teleport join TELEPORT_PROXY=teleport.example.org \
    TELEPORT_REGISTRATION_SECRET=- TELEPORT_ENV=dev
```

**Секрет первого входа** — единственный секретный параметр `join`,
только `TELEPORT_REGISTRATION_SECRET=-` со stdin: у метода `token` это сам
join-токен, у `bound_keypair` — секрет регистрации, а `TELEPORT_TOKEN` — имя
токена (не секрет, несекретная пара; у `token` пусто). Секрет лежит в
`/var/lib/cream/ext/teleport/registration-secret` (0600) до подтверждения
регистрации: render берёт его оттуда, `scrub-token` (юнит `teleport-token`) и
успешный `join` стирают. В домен, argv и журнал он не попадает.

Прочие параметры: `TELEPORT_CA_PIN`, `TELEPORT_ENV`, `TELEPORT_NODENAME`,
`TELEPORT_LABELS`, `TELEPORT_OS_LOGINS`, `TELEPORT_FORCE=1` (переподключить
зарегистрированную машину), `TELEPORT_DEFER=1` (записать конфиг и секрет,
поставить ожидание и **ничего не включать**; зарегистрировать позже —
`cream run teleport join-retry`).

stdout `join` — один JSON-объект:
`{"result":"registered|pending|deferred|written|refused|failed","joined":…,"pending":…,"refused":…,"reason":"…"}`.
Коды: 0 — зарегистрирован, ждёт сети или отложен; 1 — отказ кластера или
неверный ввод (причина — в stderr и `reason`); 2 — узел зарегистрирован, но у
токена не было роли App (приложения не опубликованы).

Поведение: повтор на зарегистрированной машине
с тем же прокси — ничего не трогает; без сети или прокси (первая загрузка) —
параметры и секрет на диске, `teleport-join.{service,timer}` повторяют при
каждой загрузке и раз в минуту; отказ кластера (секрет неверен или истёк,
токена нет, ключ связан с другой машиной) не повторяется — причина в
`join-refused` и в `status`; не подтвердилось за 120 с — агент продолжает
сам, повторы включены; неудачный переезд зарегистрированной машины
возвращает прежнюю регистрацию.

Версия кластера из `/webapi/find` — внешний ввод: до любой арифметики она
проверяется как `X.Y.Z[-pre][+build]` (компоненты до 9 цифр) и обрезается до
`X.Y.Z`; иное — «прокси назвал версию не по форме», join ждёт.

### Приложения других расширений — `apps.d`

`/etc/cream/teleport/apps.d/<имя>.conf`, root:root, не шире 0644, не
символическая ссылка. Каталог `apps.d` и каждый каталог над ним до `/` —
root, без записи группе и прочим, не символические ссылки; иначе не читается
ни одно объявление (строка журнала), приложения оператора публикуются:

```
NAME=code-server
URI=https://127.0.0.1:9002      только петля
ICON=mcpVscode                  иконка в веб-морде прокси (необязательно)
```

**Адрес приложения** — одна метка DNS под прокси: `<имя>-<нода>.<прокси>`
(`code-server-lab-1.teleport.example.org`), так все приложения кластера закрывает один
wildcard-сертификат `*.<прокси>`. Тот же адрес — `public_addr` и заголовок `Host` для
приложений на петле. До teleport 4.5.0 адрес был двухуровневым `<имя>.<нода>.<прокси>` —
такие ссылки больше не работают. Метка DNS — не длиннее 63 знаков: имя + `-` + нода ≤ 63;
приложение (оператора или из `apps.d`) с более длинной не публикуется — строка журнала
«пропускаю приложение '<имя>': адрес <имя>-<нода> — метка DNS длиннее 63», в
`apps-status` — `invalid` с `"detail":"name_too_long"`.

**Право доступа задаёт только оператор:** приложение получает метки ноды плюс
`app=<имя>`; объявление само задаёт только `teleport.icon`. Изменение каталога
видит `teleport-apps.path` и делает `reload` (render + HUP). Имя иконки — ключ
вшитого в прокси набора; неизвестное имя прокси не считает ошибкой.

Что опубликовано и почему — `cream run teleport apps-status` (`lock: none`, только
читает: файлов не пишет, юнитов не трогает). Это то же решение, по которому `render`
собирает `app_service` (функция `apps_resolve` ядра; `status` и `join` берут список
оттуда же), одним JSON-объектом схемы 1:

```json
{"schema":1,"ext":"teleport","apps_dir":"/etc/cream/teleport/apps.d",
 "discovery":true,"registered":true,"app_role_missing":false,"app_role_known":true,
 "apps":[{"name":"code-server","uri":"https://127.0.0.1:9002","source":"extension",
          "file":"/etc/cream/teleport/apps.d/code-server.conf","icon":"mcpVscode"},
         {"name":"web","uri":"http://127.0.0.1:8080","source":"operator"}],
 "dropped":[{"file":"/etc/cream/teleport/apps.d/b.conf","name":"code-server","reason":"name_shadowed"}]}
```

- `apps` — опубликованное, в порядке `teleport.yaml`: `source` — `operator`
  (`TELEPORT_APPS`) или `extension` (тогда `file`); `icon` — если задана.
- `dropped` — что не опубликовано; `name` — если файл прочитан. `reason`:
  `discovery_off` (`TELEPORT_APPS_DISCOVERY=0`), `untrusted_path` (файл или каталог до
  `/` — не root, запись группе/прочим, ссылка), `invalid` (не `KEY=VALUE`, чужой ключ,
  `NAME` не метка DNS, `URI` не петля, `ICON` не имя иконки; у оператора и объявления —
  `detail: "name_too_long"`, если `<имя>-<нода>` длиннее 63 знаков), `name_shadowed` (имя уже
  объявлено файлом раньше по glob — тот и опубликован), `overridden_by_operator` (то же
  имя в `TELEPORT_APPS`), `disabled` (`TELEPORT_APPS_DISABLE`; для приложения оператора
  `file` — `"TELEPORT_APPS"`). Файлы не `*.conf` не рассматриваются.
  Имя файла объявления — `[A-Za-z0-9._-]+.conf`; иное (пробел, управляющие знаки)
  не читается — `invalid`, в журнале имя экранировано. В `file` байты вне
  `[A-Za-z0-9._/~+-]` даны как `\u00XX`: JSON валиден при любом имени.
- `registered` — у узла есть identity (как `joined` в `managed-status`);
  `app_role_missing` — агент текущего запуска пишет в журнал отказ роли App (как
  `status`); `app_role_known` — слой умеет это определить (оба слоя — да).

Код 0 и объект — всегда, в том числе без `apps.d`, без регистрации и без агента; ручка
домена не по типу (её отверг бы и `render`) — `{"schema":1,"error":"…"}` и код 3.

### Управляемые метки — `set-managed`, `managed-status`

`TELEPORT_MANAGED_LABELS` — метки внешнего управляющего (`stvor-agent`: `env`,
`space`), не больше 16, ключ `^[a-z][a-z0-9_]{0,62}$`, значение
`^[a-z0-9][a-z0-9._-]{0,62}$`; `app`, `os_logins` зарезервированы. Правило
render: метки ноды = `TELEPORT_LABELS` → поверх них управляемые (побеждают по
ключу) → `env` = управляемый `env`, если задан, иначе `TELEPORT_ENV`. Те же
метки получает каждое приложение. `status` показывает перекрытые ключи
оператора. Интерфейс управляемых меток — мажор расширения: его несовместимое
изменение поднимает мажорную версию.

```bash
sudo cream run --lock-timeout 20s teleport set-managed env=prod space=sp-1
cream run teleport managed-status
```

`set-managed` задаёт **полный** набор (замена; без аргументов — снять все).
Маркер `/var/lib/cream/ext/teleport/managed-pending` пишется **до** записи
ручки (`cream set --no-apply --allow-readonly` под блокировкой действия), затем
render в кандидат. Restart (не HUP: метки — решение о доступе, старые сессии
не должны пережить переезд) с подтверждением нового запуска юнита по
`InvocationID`, `MainPID` или `ActiveEnterTimestampMonotonic` за 30 с — только
если узел зарегистрирован **и** кандидат отличается от `/etc/teleport.yaml`,
или остался маркер прошлого неподтверждённого вызова, или агент не активен.
Итоговый конфиг тот же — без restart (первый вызов после `join`: те же `env`
и `space` уже стоят ручками оператора).

stdout — один JSON-объект схемы 1 (эталон — `tests/fixtures/*.json`, копия
`stvor-agent/internal/teleport/testdata`, сверка — `tools/check-contract-fixtures.sh`):

```
{"schema":1,"managed":{"env":"prod","space":"sp-1"},"pending":false,"joined":true,"active":true,"result":"applied"}
```

| Код | `result` | Когда |
|---|---|---|
| 0 | `applied` | записано и действует (restart подтверждён или не нужен) |
| 0 | `unchanged` | набор тот же, конфиг тот же — ничего не тронуто |
| 0 | `deferred` | узел не зарегистрирован или systemd не запущен — только запись |
| 1 | `unconfirmed` | restart не подтверждён — маркер остаётся, следующий вызов перезапустит |
| 2 | — | неверный ввод, `{"schema":1,"error":"…"}`; ничего не тронуто |
| 3 | — | прочая ошибка (домен не по типу, cream set), `{"schema":1,"error":"…"}` |

`managed-status` (`lock: none`) — тот же объект без `result`, только читает;
домен не по типу — код 3. `leave` стирает управляемые метки и маркер.

### Командные метки — `command-labels.d`

Другое расширение кладёт `/etc/cream/teleport/command-labels.d/<ключ>` (через
`files` своего манифеста) с одной строкой `command=<абсолютный путь> [аргумент…]`.
render добавляет `ssh_service.commands`: `{name: <ключ>, command: [путь,
аргументы…], period: 5m0s}` — как у `os_logins`; только узлу. Файл пропускается
строкой журнала (остальной конфиг цел), если: ключ не `^[a-z][a-z0-9_]{0,62}$`,
это `env`, `space`, `app`, `os_logins` или ключ `TELEPORT_LABELS` /
`TELEPORT_MANAGED_LABELS`; файл или команда — символическая ссылка, не root
или с записью группе и прочим; любой каталог над командой до `/` такой же
(не root, запись группе или всем, символическая ссылка — значит, `/bin/…` на
merged-usr не годится, нужен `/usr/bin/…`); команда под `/home`, `/tmp`,
`/var/tmp`, `/run/user` (там пишет пользователь, а у `stvor-agent.service`
`ProtectHome`/`PrivateTmp`) или путь с `//`; команда есть, но не исполняемый файл;
больше 8 аргументов или аргумент не из `[A-Za-z0-9._=-]`; больше 8 файлов.
Каталог — 0755 root, и вся цепочка над ним до `/` — тоже (иначе пропускается
каталог целиком). Shell не участвует.

**Команды может ещё не быть** — но только непосредственно в
`/usr/bin`, `/usr/sbin` или `/usr/local/bin`: cream раскладывает `files`
расширения до его хука `install` (спека cream §6.5), и drop-in `stvor_agent`
появляется раньше `/usr/bin/stvor-agent`. Такая метка попадает в конфиг, команду
при запуске проверяет сам Teleport (раз в 5 мин). Каталог и вся цепочка над ним
до `/` включительно — root, без записи группе и всем, без ссылок: файл туда
позже положит только root. Отсутствующая команда в любом другом месте (`/opt/…`,
подкаталог `/usr/bin/…/x`) — пропуск строкой журнала. Это часть
контракта drop-in: расширение, чья команда появляется после раскладки `files`,
ставит её в один из этих трёх каталогов.

Изменение каталога видит `teleport-apps.path` → `teleport-apps.service` →
`reload-apps` — **одна сериализованная точка** (`lock: exclusive`):
1. ждёт, пока `teleport.service` выйдет из перехода (до 30 с);
2. собирает конфиг; остановленный агент получает только файл; если
   `teleport.yaml` не изменился — HUP не нужен (кроме случая, когда прошлое
   применение не завершилось: пометка `reload-pending` в состоянии);
3. HUP встроенным `kill` bash процессу из pid-файла — самому новому Teleport.
   После HUP старый родитель, пока открыты SSH-сессии, остаётся главным
   процессом юнита; сигнал ему потерялся бы, а сессии рвать незачем. Нет
   pid-файла — главному процессу. Сигнал получает только процесс Teleport
   системного юнита: его cgroup совпадает с `ControlGroup` юнита целиком (v2 —
   строка `0::…`, v1 — строка `name=systemd:…`; пользовательский юнит
   `user@…/app.slice/teleport.service` — не он), исполняемый файл —
   `/usr/local/bin/teleport` (в том числе `(deleted)` после обновления), и это
   главный процесс или его потомок (не дальше 8 поколений по `PPid`): оболочки
   SSH-сессий живут в том же cgroup. Процесс из pid-файла принимается и сиротой
   (`PPid` 1 — промежуточный потомок отдренировал раньше старого родителя), раз
   cgroup и бинарь совпали. Проверка повторяется прямо перед `kill`.
   Успех — новый pid-файл другого процесса Teleport юнита: потомок прочитал
   новый конфиг и стартовал (до 60 с);
4. restart (открытые сессии рвутся) — только если живого процесса Teleport в
   cgroup нет вовсе (ждёт до 30 с) или HUP не подтвердился.

### Действия и файлы

`render`, `hup`, `status`, `managed-status` — `lock: none`: их зовут
юниты, которые перезапускаются, пока блокировку держит другой процесс
(`set-managed` держит её, перезапуская `teleport.service`; спека cream §7.3).

Перезагрузка `teleport.service` (`ExecReload`) — render и действие `hup`:
адресный HUP встроенным `kill` bash новейшему процессу Teleport юнита с
подтверждением новым pid-файлом — тот же код, что у `reload-apps`. Главному
процессу (`systemctl kill --kill-who=main`) сигнал не годится: после HUP
старый родитель дренирует сессии и остаётся главным, и следующий HUP терялся бы
(`cream set teleport …` молча не применялся). `/bin/kill` (procps) в минимальных
образах нет. `hup` перезапусков не делает (он внутри reload-задания юнита):
неподтверждённый HUP оставляет пометку `reload-pending`, и ближайший `reload-apps`
досылает его, даже если `teleport.yaml` не изменился.

`cream validate` предупреждает (`validate.unit_lock`) о `teleport-join.service`
(`join-retry`), `teleport-token.service` (`scrub-token`) и `teleport-apps.service`
(`reload-apps`): их `ExecStart` зовёт
действие с `lock: exclusive`. Это допустимо: правило ловит юнит, который
перезапускает держатель блокировки и сам ждёт её, — а эти три никто под
блокировкой не стартует и не ждёт (`join` включает таймер `--no-block`, а
`teleport-token.path` и `teleport-apps.path` срабатывают сами). Им блокировка нужна: тик и стирание
секрета не должны пересечься с идущим `join`, а `lock: none` запрещает им писать
(тик пишет ожидание и регистрацию, стирание — удаляет секрет, который `join --force`
мог только что записать заново). Что ни один держатель блокировки не ждёт job этих
юнитов, держит тест (`tests/test-join.sh`, «юниты»). Пока блокировку держит `join` (до 5 мин),
они ждут: `--lock-timeout 6m`, `TimeoutStartSec` юнита — с запасом на ожидание
и само действие. `teleport.service`: `TimeoutStopSec=30s` — restart внутри
`set-managed` укладывается в 90 с адаптера stvor-agent.

## Проверки

- **H** — `bash extensions/debian/teleport/tests/test-join.sh` и `test-managed.sh` —
  по staged-копии расширения (ядро положено `tools/stage-catalog.sh --ext`), подменённый корень (`CREAM_ROOT`; «systemd запущен» — каталог-маркер
  `$CREAM_ROOT/run/systemd/system`), поддельные `systemctl`, `journalctl`, `curl`,
  `teleport`, `dpkg`, `cream`, `stat`, `sleep` через `PATH`; без root, systemd и
  сети. Тестовых переключателей в окружении у боевого скрипта нет. Запускаются
  из `tools/check.sh` вместе с `tools/check-contract-fixtures.sh`.
- **L** — `make test-live EXT=teleport` (`tests/live.env`: без зависимостей,
  debian-12, ubuntu-20.04, ubuntu-24.04; тарбол с `cdn.teleport.dev`): установка, повтор,
  `--reinstall` без изменений, загрузка, `remove`; регистрации в кластере в нём нет.
