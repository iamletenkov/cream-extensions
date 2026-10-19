# teleport

Узел Teleport на машине: SSH-нода и веб-приложения без входящих портов — агент
сам держит обратный туннель к прокси на 443. Расширение формата `cream/v1`
(исполнитель — [cream](https://github.com/iamletenkov/cream)), перенос логики
`bisquite-teleport-agent` 3.x (спека stvor-agent §10). Заменит `teleport-agent`
(layout 2), который пока живёт рядом; оба дают способность `teleport-node` и
взаимоисключимы.

> Управляемые метки (`TELEPORT_MANAGED_LABELS`, действия `set-managed` и
> `managed-status`) и командные метки `command-labels.d` появятся следующей
> версией этого расширения (задача 12 плана stvor-agent). Каталог
> `command-labels.d` и слежение за ним уже на месте.

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

Хук `apply` (после `cream set`): render и `systemctl --no-block
reload-or-restart teleport.service` — HUP, открытые сессии живут.

## Приложения других расширений — `apps.d`

`/etc/cream/teleport/apps.d/<имя>.conf`, root:root, не шире 0644:

```
NAME=code-server
URI=https://127.0.0.1:9002      только петля
ICON=mcpVscode                  иконка в веб-морде прокси (необязательно)
```

**Право доступа задаёт только оператор:** приложение получает метки ноды плюс
`app=<имя>`; объявление само задаёт только `teleport.icon`. Изменение каталога
видит `teleport-apps.path` и делает `reload` (render + HUP). Имя иконки — ключ
вшитого в прокси набора; неизвестное имя прокси не считает ошибкой.

## Действия и файлы

| Действие | `lock` | Что делает |
|---|---|---|
| `join KEY=…` | exclusive | регистрация, JSON в stdout |
| `join-retry` | exclusive | тик `teleport-join.timer`; ручная регистрация после `TELEPORT_DEFER=1` |
| `leave` | exclusive | агент выключен, `/var/lib/teleport`, `teleport.yaml`, секрет, ожидание стёрты; JSON `{"result":"left"}` |
| `status` | none | регистрация, служба, ручки, приложения — текстом |
| `render` | none | `/etc/teleport.yaml` (0600); `ExecStartPre`/`ExecReload` `teleport.service` |
| `reload-apps` | none | `ExecStart` `teleport-apps.service` |
| `scrub-token` | exclusive | `teleport-token.service`: стирает секрет первого входа |

`render`, `reload-apps`, `status` — `lock: none`: их зовут юниты, которые
перезапускаются, пока блокировку держит другой процесс (спека cream §7.3).

| Путь | Что |
|---|---|
| `/opt/cream/ext/teleport/` | дерево расширения: `hooks/`, `actions/` (тонкие входы), `files/teleport.sh` (общая библиотека), `files/os-logins` (метка `os_logins`, её зовёт Teleport) |
| `/etc/systemd/system/teleport{,-apps,-token,-join}.*` | юниты (раскладывает cream) |
| `/etc/cream/teleport/{config,apps.d,command-labels.d}` | домен ручек и объявления |
| `/var/lib/cream/ext/teleport/{registration-secret,join-pending,join-refused,rollback}` | состояние (каталог 0700, файлы 0600) |
| `/etc/teleport.yaml`, `/var/lib/teleport/`, `/usr/local/bin/teleport` | Teleport, как прежде |

Хук `remove`: `leave`, path-юниты выключены, бинарь и состояние стёрты; юниты
и (с `--purge`) домен удаляет cream.

## Тесты

`bash extensions/debian/teleport/tests/test-join.sh` — подменённый корень
(`CREAM_ROOT`), поддельные `systemctl`, `journalctl`, `curl`, `teleport`, `dpkg`,
`cream`; без root, systemd и сети. Запускается из `tools/check.sh`.
