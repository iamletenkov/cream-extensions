# stvor-agent-openwrt

[stvor-agent](https://github.com/iamletenkov/stvor-agent) — агент портала Stvor — на
OpenWrt 25.12+. Агент забирает с портала метки `env` и `space` узла Teleport и отдаёт их
расширению [`teleport-openwrt`](../teleport-openwrt/README.md) (`cream run
teleport-openwrt set-managed`), служба телеметрии шлёт на портал состояние машины.
Двойник [stvor-agent](../../debian/stvor-agent/README.md) для OpenWrt: те же ключи, вместо
`.deb` — поставка `stvor-agent_<версия>_linux_<arch>.tar.gz`, вместо systemd — procd
([спека](https://github.com/iamletenkov/cream/blob/main/docs/specs/2026-10-20-openwrt.md) §4.2, §4.3).

<!-- catalog:facts -->
| | |
|---|---|
| ОС | OpenWrt ≥ 25.12 |
| Архитектура | amd64, arm64 |
| cream | ≥ 1.3.0 |
| Даёт | `stvor-agent` |
| Требует | — |
| Зависит от | [`teleport-openwrt`](../teleport-openwrt/README.md) |
| Конфликтует с | — |
| Хуки | `install`, `upgrade`, `configure`, `remove`, `apply` |
| Настройка на загрузке | стадия `system`, на каждой загрузке (`every_boot`) |
| Действия | `cream run stvor-agent-openwrt status` |
| Живая машина | да |
<!-- /catalog:facts -->

## Что делает

- **`install`** (и **`upgrade`** — тот же код) — выбирает версию и сумму (явная пара
  или пин каталога), берёт tar.gz из источника, сверяет sha256 до распаковки и ставит
  из него `/usr/bin/stvor-agent` и init-скрипты procd `/etc/init.d/stvor-agent` и
  `/etc/init.d/stvor-agent-telemetry` (оба включаются в `rc.d`; каждый стартует, только
  когда есть его токен), а если выпуск его несёт (агент ≥ 4.4.0) — и
  `/etc/init.d/stvor-agent-apply`, применитель назначенных порталом версий: он не
  включается и не перезапускается ни здесь, ни при обновлении — включает его служба
  агента на время попытки, выключает сам применитель на финале. Архитектура — `uname -m` (`x86_64` → amd64, `aarch64` → arm64).
  Создаёт системного пользователя и группу `stvor-telemetry` помощниками
  `group_add_next`/`user_add` из `/lib/functions.sh` (shadow-utils на OpenWrt нет) и
  каталоги `/opt/stvor-agent` и `/etc/stvor-agent-telemetry` (0750
  `root:stvor-telemetry`) и каждый раз выставляет владельца и права состояния (как
  `configure`). Та же версия и сумма уже стоят — пропуск без сети. После замены пишет
  пин поставленного tar.gz `installed-pin` (см. «[`sysupgrade`](#sysupgrade)»); перед
  скачиванием пин и запись установленного снимаются, так что прерванная замена не выглядит
  завершённой: повтор прежней пары ставит её заново. Новая
  версия на живой машине — работающие службы перезапускаются фоном. На живой машине
  зовёт `cream run teleport-openwrt reload-apps`, чтобы узел подхватил метку `stvor_agent`.
- **`configure`** (на каждой загрузке, стадия `system` — до того, как procd поднимет
  службы) — владелец и права состояния: `/opt/stvor-agent` 0750 `root:stvor-telemetry`,
  `machine-id` 0640 `root:stvor-telemetry`, `/opt/stvor-agent/telemetry` и его `buffer` —
  0700 `stvor-telemetry`; токены и файлы root — как их пишет агент: `/etc/stvor-agent`
  0700 и `token` 0600 `root`, `/etc/stvor-agent-telemetry` 0750 и `token` 0640
  `root:stvor-telemetry`, `state.json`, `telemetry-token.src` и `last-good.json` 0600 `root` (ссылки не
  разыменовываются). Восстановленное из копии (или `keep.d` версии 1.1.0) приходило
  `0:0 0755`, и служба телеметрии падала с `permission denied`; теперь это чинят и
  загрузка, и повтор `cream install`: буфер не того владельца пересоздаётся пустым. Без
  сети; пользователя `stvor-telemetry` ещё нет — ничего.
- **`apply`** (`cream set stvor-agent-openwrt …`) — работающие службы перезапускаются
  фоном и перечитывают `/etc/cream/stvor-agent-openwrt/config`; без procd — ничего.
- **`remove`** — пока идёт попытка применителя (`/opt/stvor-agent/apply/plan.json`) —
  отказ, ничего не снято. Иначе `stvor-agent disable` (служба, токен, `state.json`), службы
  остановлены и выключены (и применитель); бинарь, init-скрипты, токены (`/etc/stvor-agent`,
  `/etc/stvor-agent-telemetry`), состояние `/opt/stvor-agent` стёрты; пользователь и
  группа `stvor-telemetry` снимаются, только если их создало это расширение. Каталоги,
  куда пишет `stvor-telemetry` (`/opt/stvor-agent`, `/var/run/stvor-agent-telemetry`),
  удаляются только после выхода всех его процессов и через каталог, доступный лишь root;
  процессы не завершились за 40 с — отказ, ничего не снято (повторите `cream remove`). Drop-in
  метки `stvor_agent` уходит до `reload-apps` — узел сразу перестаёт показывать метку.
- **действие `status`** (`cream run stvor-agent-openwrt status`) — здоровье агента и
  телеметрии, как у [`debian/stvor-agent`](../../debian/stvor-agent/README.md):
  `stvor-agent status --json` с вердиктом `{"schema":1,"healthy":…,"problems":[…],"agent":…}`;
  код 0 — агент включён, служба меток и служба телеметрии `active`, токен телеметрии `ok`;
  иначе 1.
- **`files`** — drop-in командной метки
  `/etc/cream/teleport-openwrt/command-labels.d/stvor_agent` и
  `/lib/upgrade/keep.d/stvor-agent`.

## Параметры

<!-- catalog:params -->
| Ключ | Тип | Умолчание | Что задаёт |
|---|---|---|---|
| `STVOR_AGENT_VERSION` | строка `^[0-9]+\.[0-9]+\.[0-9]+$` | пусто | версия агента; задаётся вместе с STVOR_AGENT_SHA256, пусто — пин каталога (files/pin.env) *(только при установке)* |
| `STVOR_AGENT_SHA256` | строка `^[0-9a-f]{64}$` | пусто | sha256 tar.gz архитектуры машины; задаётся вместе с STVOR_AGENT_VERSION *(только при установке)* |
| `STVOR_AGENT_MIRROR` | `str` | пусто | база зеркала, файл плоско <база>/stvor-agent_<версия>_linux_<arch>.tar.gz; пусто — релиз GitHub *(только при установке)* |
| `STVOR_AGENT_TARBALL` | `path` | пусто | локальный tar.gz (офлайн, абсолютный путь); взаимоисключим с STVOR_AGENT_MIRROR *(только при установке)* |
| `STVOR_AGENT_INTERVAL` | строка `^([6-9][0-9]\|[1-5][0-9]{2}\|600)$` | `60` | период опроса портала, секунды, 60–600 |
| `STVOR_AGENT_LOG_LEVEL` | `info` \| `debug` | `info` | уровень журнала службы |
<!-- /catalog:params -->

Ключи — те же, что у [stvor-agent](../../debian/stvor-agent/README.md#параметры)
(контракт со скриптом установки Stvor), `STVOR_AGENT_TARBALL` вместо `STVOR_AGENT_DEB`.
Параметры установки — только через `cream install`, `cream set` им отказывает. Повтор
`cream install stvor-agent-openwrt` с новой версией и суммой — обновление агента.

- `STVOR_AGENT_MIRROR` — так раздаёт `/dist/teleport/` портала (файл плоско
  `<база>/stvor-agent_<версия>_linux_<arch>.tar.gz`); с `STVOR_AGENT_TARBALL` — отказ.
- Версия и сумма обе пусты — пин каталога `files/pin.env` (`STVOR_AGENT_PIN_VERSION`,
  `STVOR_AGENT_PIN_SHA256_AMD64`, `STVOR_AGENT_PIN_SHA256_ARM64` — суммы tar.gz). Задана
  одна из двух — отказ. Пин без версии или без суммы своей архитектуры — отказ до
  сети: до первого выпуска агента с tar.gz пин пуст, и нужна явная пара (скрипт
  установки Stvor передаёт её всегда). Источник по умолчанию — релиз GitHub
  `…/releases/download/v<версия>/stvor-agent_<версия>_linux_<arch>.tar.gz`.
- Пин поднимает `tools/agent-bump.sh` из того же `SHA256SUMS` выпуска, что и `.deb`-пин
  `debian/stvor-agent`; выпуск без tar.gz пин OpenWrt не трогает.

Настройки службы (`STVOR_AGENT_INTERVAL`, `STVOR_AGENT_LOG_LEVEL`) лежат в
`/etc/cream/stvor-agent-openwrt/config`; init-скрипты агента передают их службам:

```sh
cream set stvor-agent-openwrt STVOR_AGENT_INTERVAL=120   # хук apply перезапускает службы
```

## Установка

Обычно — одной командой портала Stvor (строка OpenWrt на «Добавить робота»): она ставит
cream, `teleport-openwrt`, регистрирует узел, ставит это расширение и включает агента.
Руками, на машине с подключённым каталогом ([как подключить](../../../docs/getting-started.md))
и узлом `teleport-openwrt`:

```sh
cream install --with-deps stvor-agent-openwrt STVOR_AGENT_VERSION=<v> STVOR_AGENT_SHA256=<сумма tar.gz arch> STVOR_AGENT_MIRROR=https://<домен>/dist/teleport
printf '%s' "$LABEL_TOKEN" | stvor-agent enable 'URL=https://<домен>/robot-api/v1/labels'
# офлайн: STVOR_AGENT_TARBALL=/путь/stvor-agent_<v>_linux_<arch>.tar.gz вместо зеркала
```

В образе (VMFILE bisquite) агент ставится на сборке: службы включены, но без токена не
стартуют; токен — на первой загрузке тем же `stvor-agent enable`, в образ не кладётся.

```dockerfile
RUN_COMMAND cream install --with-deps stvor-agent-openwrt STVOR_AGENT_VERSION=<v> STVOR_AGENT_SHA256=<сумма> STVOR_AGENT_MIRROR=https://<домен>/dist/teleport
```

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | drop-in метки и `keep.d` (cream, до хука), tar.gz по пину или явной паре, sha256, бинарь и init-скрипты, пользователь `stvor-telemetry`, службы включены; на живой машине — `reload-apps` узла |
| `stvor-agent enable` | токен меток, `/etc/init.d/stvor-agent enable` и `restart`; служба (root) берёт токен телеметрии и стартует `stvor-agent-telemetry` |
| загрузка | `configure` (S95) выставляет владельца и права состояния; procd стартует службы из `rc.d`, каждую — только при её токене; `/var/run/stvor-agent-telemetry` init-скрипт создаёт сам |
| `cream set` (хук `apply`) | перезапуск работающих служб фоном |
| `cream upgrade` | новый tar.gz; работающие службы перезапускаются |
| `sysupgrade` с сохранением настроек | `keep.d` хранит `machine-id`, `state.json`, `telemetry-token.src`, оба токена, домен, маркер пользователя и пин tar.gz `installed-pin`; повтор `cream install` возвращает того же агента без новых токенов, `install` и `configure` чинят права ([ниже](#sysupgrade)) |
| `cream remove` | `stvor-agent disable`, службы выключены, всё поставленное стёрто, `reload-apps` узла |

## Известные ограничения

- Песочницы systemd на OpenWrt нет: агент работает от root без ограничений, телеметрия —
  от `stvor-telemetry` с `no_new_privs` (`SECURITY.md` агента).
- Токен меток cream не хранит и хуки его не принимают: включить агента — только
  `stvor-agent enable` на машине.
- Пока стоит расширение, `cream remove teleport-openwrt` отказывает (67).
- `remove` не останавливается, если `stvor-agent disable` не прошёл (в отличие от
  `debian/stvor-agent`): службы, токены и состояние снимаются хуком, но управляемые
  метки `env`/`space` узла остаются в `teleport-openwrt` до `cream run
  teleport-openwrt set-managed` или `leave`.
- Пользователь `stvor-telemetry` снимается, только если хук создал его вместе с группой
  (маркер в состоянии cream сохраняется при `sysupgrade`).
- tar.gz без `stvor-agent`, `init.d/stvor-agent` или `init.d/stvor-agent-telemetry` —
  отказ до изменений: нужен выпуск агента с поставкой для OpenWrt. `init.d/stvor-agent-apply`
  необязателен (выпуски до 4.4.0), но если есть — только обычным файлом.

## Подробности

### Настройка на загрузке

Службы на загрузке поднимает procd (`rc.d`), не cream; каталог
`/var/run/stvor-agent-telemetry` (tmpfs) init-скрипт создаёт при каждом старте. `configure`
с `every_boot` ([настройка на загрузке](../../../docs/guides/configure-lifecycle.md)) только
выставляет владельца и права `/opt/stvor-agent`: init-скрипт агента чинит лишь верхний
каталог телеметрии, а буфер после восстановления остаётся чужим.

Дерево телеметрии принадлежит непривилегированному пользователю, поэтому root его не
обходит и ничего внутри не перевладевает: жёсткая ссылка или симлинк в буфере на файл root
отдали бы этот файл пользователю. Буфер — временные данные: если он сам или что-то в нём не
пользователя `stvor-telemetry` (проверка только чтением, `find` по ссылкам не идёт), служба
телеметрии останавливается (на живой машине) и дожидается выхода процессов пользователя,
каталог телеметрии закрывается (`0:0 0700`), буфер уходит в каталог, доступный только root,
и удаляется непрочитанным, на его месте создаётся пустой. `chown`/`chmod` — только на
каталоги, которые root только что закрыл или создал; каталог телеметрии отдаётся
пользователю последним, служба запускается вновь. Процессы пользователя не завершились за
40 с — отказ, ничего не тронуто.

### `sysupgrade`

`sysupgrade` с сохранением настроек переносит агента целиком (Р4 с поправкой владельца
2026-10-23). `/lib/upgrade/keep.d/stvor-agent` перечисляет:

- `/opt/stvor-agent/machine-id` — опознание машины детектором клонов портала;
- `/opt/stvor-agent/state.json` и `telemetry-token.src` — состояние агента и отпечаток
  токена меток, под который выдан токен телеметрии;
- `/etc/stvor-agent/token` и `/etc/stvor-agent-telemetry/token` — токены меток и
  телеметрии;
- `/etc/cream/stvor-agent-openwrt/` — домен (настройки службы);
- `/opt/cream/var/ext/stvor-agent-openwrt/user-created` — маркер, что пользователя
  `stvor-telemetry` создало расширение (сам пользователь — в `/etc/passwd`, его хранит
  OpenWrt);
- `/opt/cream/var/ext/stvor-agent-openwrt/installed-pin` — пин поставленного tar.gz, две
  строки `STVOR_AGENT_VERSION=` и `STVOR_AGENT_SHA256=` (0600, запись атомарная). Пишет
  `install`/`upgrade` после замены бинаря и init-скриптов (и при пропуске той же пары, если
  пина ещё нет), `remove` снимает. `/etc/stvor/restore.sh` Stvor ставит агента по нему, а
  без файла — по пинам рецепта: обновление агента через cream рецепт не переписывает;
- `/opt/stvor-agent/last-good.json` — последний рабочий набор версий применителя (спека
  агента «назначения» §8.4, ADR-0001 агента). Файлы отката `rollback/`, скачанное
  `updates/` и попытка `apply/` не сохраняются: после `sysupgrade` следующая попытка
  берёт файлы отката по `baseline`, попытка посреди `sysupgrade` теряется.

Буфер телеметрии, бинарь, init-скрипты и реестр cream не сохраняются. Архив хранит только
файлы: `tar` создаёт их каталоги заново `0755 root`, а агент не принимает токен меток в
каталоге шире 0700. Права возвращают повтор `cream install stvor-agent-openwrt` (на роботе
Stvor — служба восстановления) и `configure` на каждой загрузке — тем же безопасным путём,
что и буфер телеметрии ([выше](#настройка-на-загрузке)). Портал новых токенов не выдаёт.

> **Архив `sysupgrade` — секрет уровня root.** В нём токены агента (и ключ узла
> `teleport-openwrt`, и `/etc/shadow`); выгрузка `sysupgrade -b` или резервная копия LuCI —
> тоже. Восстанавливайте его только на ту же машину: на другой портал увидит клон по
> `machine-id`. При удалении робота на портале токены отзываются.

### Метка `stvor_agent`

Файл `files/stvor_agent.command-label` cream кладёт в
`/etc/cream/teleport-openwrt/command-labels.d/stvor_agent` до хука `install`: одна строка
`command=/usr/bin/stvor-agent version --label`. Teleport раз в 5 минут исполняет её и
публикует версию включённого агента (иначе пустую строку). Path-юнитов на OpenWrt нет,
поэтому изменение `command-labels.d` применяет тот, кто его положил: хуки зовут
`cream run teleport-openwrt reload-apps` (до `join` он ничего не делает, перезапускает
узел только при изменившемся `teleport.yaml`).

## Проверки

- **V** — `make cream-validate` и `make cream-check` по staged-дереву, `tools/lint-hooks.sh`.
- **H** — `tests/test-stvor-agent-openwrt.sh`: ключи сверены с `debian/stvor-agent`,
  выбор версии (явная пара, пин, половина пары), источник (зеркало, GitHub, файл), сверка
  sha256 и состав tar.gz до изменений, раскладка и права, пользователь
  `stvor-telemetry` (создан — снимается, чужой — остаётся), `reload-apps` только на живой
  машине с procd, перезапуск работающих служб при обновлении и в `apply`, применитель
  (ставится, не включается и не перезапускается; выпуск без него; ссылка — отказ), `remove`
  (и отказ во время попытки),
  окружение `curl` без токена и `CREAM_*`, действие `status` (блок `telemetry`), права токенов
  и состояния после `sysupgrade` (каталоги 0755 от `tar`, ссылки не разыменовываются),
  `keep.d` не пересекается с `files` расширений OpenWrt и хранит `last-good.json`, но не
  `rollback/`, `updates/`, `apply/`, `installed-pin` (0600; снят до
  скачивания — при чужой сумме или обрыве сети не новый, пишется и без сети, если его не было). Пин в
  git — полный или пустой целиком.
- **L** — `make test-openwrt`: корневая ФС openwrt-builder v0.3.1 в контейнере, настоящие
  cream, busybox, rc.common и `/lib/functions.sh`: `install` поверх `teleport-openwrt` в
  фазе build, `rc.d`, пользователь и права, метка `stvor_agent` в `teleport.yaml`,
  `stvor-agent status`, `cream set`, `remove`; `sysupgrade` двумя контейнерами — настоящий
  `sysupgrade -b` робота с узлом и агентом, распаковка архива в свежем образе, повторная
  установка: тот же `host_uuid`, `join` не вызывался, повтор команды портала — «уже
  зарегистрирован», права токенов и состояния восстановлены. Поставка — подделка с раскладкой выпуска
  или настоящий tar.gz агента (`OPENWRT_AGENT_TARBALL=<файл>`). procd в контейнере нет —
  загрузка, `stvor-agent enable` и метки с портала проверяются на ВМ.
