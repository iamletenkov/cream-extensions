# teleport

Узел Teleport на машине: SSH-нода и веб-приложения без входящих портов — агент
сам держит обратный туннель к прокси на 443. Расширение формата `cream/v1`
(исполнитель — [cream](https://github.com/iamletenkov/cream)), перенос логики
`bisquite-teleport-agent` 3.x (спека stvor-agent §10). Заменило обёртку
`teleport-agent` (layout 2, удалена из каталога); способность — `teleport-node`.

Метки узла задают три стороны: оператор (`TELEPORT_ENV`, `TELEPORT_LABELS`),
внешний управляющий — служба `stvor-agent` (управляемые метки
`TELEPORT_MANAGED_LABELS`, действия `set-managed` и `managed-status`) и другие
расширения (командные метки `command-labels.d`).

## Что изменилось против 3.x

| Было | Стало |
|---|---|
| `bisquite-teleport <команда>` | `cream run teleport <действие>`; хуки `install`, `upgrade`, `remove`, `apply` |
| `/etc/bisquite/teleport/config` (0600), `bisquite-conf` | домен cream `/etc/cream/teleport/config` (0644, секретов в нём нет); схема — `config.keys` манифеста; пишет `cream set` |
| `/etc/bisquite/teleport/apps.d/` | `/etc/cream/teleport/apps.d/` |
| `/var/lib/bisquite/teleport/` | `/var/lib/cream/ext/teleport/` |
| свой `flock` (`.join.lock`) | блокировка cream `lock/teleport` (`lock: exclusive` у `join`, `join-retry`, `leave`, `scrub-token`, хука `apply`) |
| `bisquite-teleport-{apps,token,join}.*` | `teleport-{apps,token,join}.*` |
| метки `managed_by`, `bisquite_agent_version` | не ставятся: признак агента портала — динамическая метка `stvor_agent` расширения `stvor-agent` |
| списки ручек через запятую | **через пробел** (тип `list:` cream); в значениях меток пробела нет |
| `TELEPORT_TOKEN=-` / `TELEPORT_TOKEN=<токен>` | секрет первого входа — только `TELEPORT_REGISTRATION_SECRET=-` (см. ниже) |
| `labels-enable`, `pull`, `TELEPORT_LABELS_URL`, таймер меток | удалено — это служба `stvor-agent` |

## Установка — бинарь Teleport

```
cream install teleport                                   # 18.10.0 с cdn.teleport.dev
cream install teleport TELEPORT_VERSION=18.10.0 TELEPORT_MIRROR=https://binaries.example.org \
    TELEPORT_SHA256=<sha256 тарбола архитектуры машины>
cream install teleport TELEPORT_TARBALL=/media/teleport-v18.10.0-linux-arm64-bin.tar.gz \
    TELEPORT_SHA256=<sha256>                                 # офлайн
```

| Ключ (`scope: install`) | Умолчание | Что делает |
|---|---|---|
| `TELEPORT_VERSION` | `18.10.0` | версия; **не новее кластера**, не старше на мажор; для `bound_keypair` — не ниже 18.8.0 |
| `TELEPORT_SHA256` | пусто | сумма тарбола архитектуры машины; пусто — `.sha256` с `cdn.teleport.dev` (второй канал, если тарбол с зеркала) |
| `TELEPORT_MIRROR` | пусто | база зеркала: `<база>/binaries/teleport/<версия>/teleport-v<версия>-linux-<arch>-bin.tar.gz`; пусто — `cdn.teleport.dev` |
| `TELEPORT_TARBALL` | пусто | локальный тарбол; нужен `TELEPORT_SHA256`; взаимоисключим с `TELEPORT_MIRROR` |

Хук `install` ставит только `teleport` (без `tsh`, `tctl`, `tbot`), включает
`teleport-apps.path` и `teleport-token.path` и **не регистрирует** узел и не
запускает агента. Та же версия уже стоит — пропуск без скачивания. Смена
ключа — повтор `cream install teleport KEY=…`: новый бинарь, и работавший агент
перезапускается (`try-restart`). В сборке образа (`CREAM_PHASE=build`) хук
отказывает, если в `/var/lib/teleport` уже есть регистрация: иначе все копии
образа были бы одной нодой. Своя сборка Teleport на зеркале (форк той же
версии) — не тот тарбол, что описывает `.sha256` CDN: её сумму задают явно.

## Регистрация — `join`

```
printf '%s' '<секрет регистрации>' | cream run teleport join TELEPORT_PROXY=teleport.example.org \
    TELEPORT_JOIN_METHOD=bound_keypair TELEPORT_TOKEN=robot-lab-1 TELEPORT_REGISTRATION_SECRET=- \
    TELEPORT_ENV=dev TELEPORT_NODENAME=lab-1 "TELEPORT_LABELS=space=sp-0123abcd site=lab"
printf '%s' '<join-токен>' | cream run teleport join TELEPORT_PROXY=teleport.example.org \
    TELEPORT_REGISTRATION_SECRET=- TELEPORT_ENV=dev
```

**Секрет первого входа** (рулинг РТ1) — единственный секретный параметр `join`,
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

Поведение перенесено из 3.x без изменений: повтор на зарегистрированной машине
с тем же прокси — ничего не трогает; без сети или прокси (первая загрузка) —
параметры и секрет на диске, `teleport-join.{service,timer}` повторяют при
каждой загрузке и раз в минуту; отказ кластера (секрет неверен или истёк,
токена нет, ключ связан с другой машиной) не повторяется — причина в
`join-refused` и в `status`; не подтвердилось за 120 с — агент продолжает
сам, повторы включены; неудачный переезд зарегистрированной машины
возвращает прежнюю регистрацию.

## Ручки — `cream set teleport KEY=…`

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
| `TELEPORT_MANAGED_LABELS` | `readonly`: пишет только `set-managed` (и `leave`) — см. ниже |

Хук `apply` (после `cream set`): render и `systemctl --no-block
reload-or-restart teleport.service` — HUP, открытые сессии живут.

## Приложения других расширений — `apps.d`

`/etc/cream/teleport/apps.d/<имя>.conf`, root:root, не шире 0644, не
символическая ссылка. Каталог `apps.d` и каждый каталог над ним до `/` —
root, без записи группе и прочим, не символические ссылки; иначе не читается
ни одно объявление (строка журнала), приложения оператора публикуются:

```
NAME=code-server
URI=https://127.0.0.1:9002      только петля
ICON=mcpVscode                  иконка в веб-морде прокси (необязательно)
```

**Право доступа задаёт только оператор:** приложение получает метки ноды плюс
`app=<имя>`; объявление само задаёт только `teleport.icon`. Изменение каталога
видит `teleport-apps.path` и делает `reload` (render + HUP). Имя иконки — ключ
вшитого в прокси набора; неизвестное имя прокси не считает ошибкой.

## Управляемые метки — `set-managed`, `managed-status`

`TELEPORT_MANAGED_LABELS` — метки внешнего управляющего (`stvor-agent`: `env`,
`space`), не больше 16, ключ `^[a-z][a-z0-9_]{0,62}$`, значение
`^[a-z0-9][a-z0-9._-]{0,62}$`; `app`, `os_logins` зарезервированы. Правило
render: метки ноды = `TELEPORT_LABELS` → поверх них управляемые (побеждают по
ключу) → `env` = управляемый `env`, если задан, иначе `TELEPORT_ENV`. Те же
метки получает каждое приложение. `status` показывает перекрытые ключи
оператора.

```
cream run --lock-timeout 20s teleport set-managed env=prod space=sp-1
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

## Командные метки — `command-labels.d`

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
`ProtectHome`/`PrivateTmp`) или путь с `//`; команда — не исполняемый файл;
больше 8 аргументов или аргумент не из `[A-Za-z0-9._=-]`; больше 8 файлов.
Каталог — 0755 root, и вся цепочка над ним до `/` — тоже (иначе пропускается
каталог целиком). Shell не участвует.
Изменение каталога видит `teleport-apps.path` — reload (HUP, плавный).

## Действия и файлы

| Действие | `lock` | Что делает |
|---|---|---|
| `join KEY=…` | exclusive | регистрация, JSON в stdout |
| `join-retry` | exclusive | тик `teleport-join.timer`; ручная регистрация после `TELEPORT_DEFER=1` |
| `leave` | exclusive | агент выключен, `/var/lib/teleport`, `teleport.yaml`, секрет, ожидание, управляемые метки и `managed-pending` стёрты; JSON `{"result":"left"}` |
| `set-managed k=v…` | exclusive | полный набор управляемых меток; JSON схемы 1 |
| `managed-status` | none | управляемые метки, маркер, регистрация, агент; JSON схемы 1 |
| `status` | none | регистрация, служба, ручки, приложения, управляемые и командные метки — текстом |
| `render` | none | `/etc/teleport.yaml` (0600); `ExecStartPre`/`ExecReload` `teleport.service` |
| `reload-apps` | none | `ExecStart` `teleport-apps.service` |
| `scrub-token` | exclusive | `teleport-token.service`: стирает секрет первого входа |

`render`, `reload-apps`, `status`, `managed-status` — `lock: none`: их зовут
юниты, которые перезапускаются, пока блокировку держит другой процесс
(`set-managed` держит её, перезапуская `teleport.service`; спека cream §7.3).

`cream validate` предупреждает (`validate.unit_lock`) о `teleport-join.service`
(`join-retry`) и `teleport-token.service` (`scrub-token`): их `ExecStart` зовёт
действие с `lock: exclusive`. Это допустимо: правило ловит юнит, который
перезапускает держатель блокировки и сам ждёт её, — а эти два никто под
блокировкой не стартует и не ждёт (`join` включает таймер `--no-block`, а
`teleport-token.path` срабатывает сам). Им блокировка нужна: тик и стирание
секрета не должны пересечься с идущим `join`. Пока его держит `join` (до 5 мин),
они ждут: `--lock-timeout 6m`, `TimeoutStartSec` юнита — с запасом на ожидание
и само действие. `teleport.service`: `TimeoutStopSec=30s` — restart внутри
`set-managed` укладывается в 90 с адаптера stvor-agent.

| Путь | Что |
|---|---|
| `/opt/cream/ext/teleport/` | дерево расширения: `hooks/`, `actions/` (тонкие входы), `files/teleport.sh` (общая библиотека), `files/os-logins` (метка `os_logins`, её зовёт Teleport) |
| `/etc/systemd/system/teleport{,-apps,-token,-join}.*` | юниты (раскладывает cream) |
| `/etc/cream/teleport/{config,apps.d,command-labels.d}` | домен ручек и объявления |
| `/var/lib/cream/ext/teleport/{registration-secret,join-pending,join-refused,managed-pending,rollback}` | состояние (каталог 0700, файлы 0600) |
| `/etc/teleport.yaml`, `/var/lib/teleport/`, `/usr/local/bin/teleport` | Teleport, как прежде |

Хук `remove`: `leave`, path-юниты выключены, бинарь и состояние стёрты; юниты
и (с `--purge`) домен удаляет cream.

## Тесты

`bash extensions/debian/teleport/tests/test-join.sh` и `test-managed.sh` —
подменённый корень (`CREAM_ROOT`; «systemd запущен» — каталог-маркер
`$CREAM_ROOT/run/systemd/system`), поддельные `systemctl`, `journalctl`, `curl`,
`teleport`, `dpkg`, `cream`, `stat`, `sleep` через `PATH`; без root, systemd и
сети. Тестовых переключателей в окружении у боевого скрипта нет. Запускаются
из `tools/check.sh` вместе с `tools/check-contract-fixtures.sh`.

Версия кластера из `/webapi/find` — внешний ввод: до любой арифметики она
проверяется как `X.Y.Z[-pre][+build]` (компоненты до 9 цифр) и обрезается до
`X.Y.Z`; иное — «прокси назвал версию не по форме», join ждёт.
