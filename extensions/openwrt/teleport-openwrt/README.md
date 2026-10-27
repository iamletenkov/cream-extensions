# teleport-openwrt

Узел Teleport на OpenWrt 25.12+: SSH-нода и веб-приложения без входящих портов — агент
сам держит обратный туннель к прокси на 443. Двойник [teleport](../../debian/teleport/README.md)
для OpenWrt: те же ключи и действия, то же общее ядро; отличается слой — procd вместо
systemd и набор Teleport с glibc рядом (вариант A
[спеки](https://github.com/iamletenkov/cream/blob/main/docs/specs/2026-10-20-openwrt.md)).
Исполнитель — [cream](https://github.com/iamletenkov/cream) ≥ 1.3.0; способность — `teleport-node`.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | OpenWrt ≥ 25.12 |
| Архитектура | amd64, arm64 |
| cream | ≥ 1.3.0 |
| Даёт | `teleport-node` |
| Требует | — |
| Зависит от | — |
| Конфликтует с | способность `teleport-node` |
| Хуки | `install`, `upgrade`, `remove`, `apply` |
| Настройка на загрузке | — |
| Действия | `cream run teleport-openwrt join`, `cream run teleport-openwrt join-retry`, `cream run teleport-openwrt leave`, `cream run teleport-openwrt set-managed`, `cream run teleport-openwrt managed-status`, `cream run teleport-openwrt status`, `cream run teleport-openwrt render`, `cream run teleport-openwrt reload-apps`, `cream run teleport-openwrt hup`, `cream run teleport-openwrt scrub-token` |
| Живая машина | да |
<!-- /catalog:facts -->

Teleport собран под glibc, а в OpenWrt — musl. Поэтому ставится **набор `openwrt-<arch>`**:
`teleport` и `fdpass-teleport`, перепривязанные `patchelf` к своему загрузчику, и
glibc-рантайм Debian 12 (7 библиотек, ~3 МБ) в `/opt/teleport/lib`. Набор собирает стенд
Stvor из того же тарбола `linux-<arch>` (рулинг Р7); на `cdn.teleport.dev` его нет.

## Что делает

- **`install`** (и **`upgrade`** — тот же код) — набор по `TELEPORT_MIRROR` или
  `TELEPORT_TARBALL`, **всегда** по `TELEPORT_SHA256` (сверка до распаковки);
  архитектура — `uname -m` (`x86_64` → amd64, `aarch64` → arm64). Раскладка:
  `/opt/teleport/bin/{teleport,fdpass-teleport}`, `/opt/teleport/lib/` (рантайм),
  `/opt/teleport/data` (0750, `data_dir`), `/opt/teleport/tmp` (0700, `TMPDIR` узла —
  `/tmp` и `/var` на OpenWrt в ОЗУ), ссылка `/usr/bin/teleport`, маркер владения
  `/opt/teleport/.cream-owned`. Teleport в `/opt/teleport` **без маркера** — отказ
  «Teleport не от cream» (чужой узел не присваивается). Служба `/etc/init.d/teleport`
  включается (`rc.d`); агент не стартует, регистрации нет. Новый набор на работающем
  узле — перезапуск агента.
- **`join`** — регистрация, как у [teleport](../../debian/teleport/README.md#регистрация--join):
  секрет первого входа — `TELEPORT_REGISTRATION_SECRET=-` (stdin), методы `token` и
  `bound_keypair`, отложенная (`TELEPORT_DEFER=1`), ожидание сети с повтором, отказ
  кластера без повторов, откат прежней регистрации. Агент стартует экземпляром procd,
  отказ кластера читается **только из журнала узла** `/opt/teleport/log/teleport.log`
  (каталог 0700, файл 0600 — пишет лишь root) с отсечкой по времени попытки, и
  засчитывается, только пока в `data_dir` нет identity. syslog не читается: любой
  локальный процесс пишет туда любой тег с любым pid (`logger -t 'teleport[1234]'`), а
  отказ стирает секрет и снимает повторы.
- **`apply`** (`cream set teleport-openwrt …`) — render и **перезапуск** работающего
  агента фоном (HUP на OpenWrt не шлётся, см. «Подробности»).
- **`remove`** — `leave`, служба остановлена и выключена, `/opt/teleport`, ссылка и
  состояние стёрты. Чужой `/opt/teleport` (без маркера) не трогается.
- **`files`** — общее ядро `files/teleport-core.sh` (его кладёт снимок, в git — одна
  копия `lib/teleport-core.sh`), `/etc/init.d/teleport` (procd), `/lib/upgrade/keep.d/teleport`.

`teleport.yaml` отличается от Debian: `data_dir: /opt/teleport/data`,
`log.output: /opt/teleport/log/teleport.log` (журнал узла — файл, не syslog; больше 1 МиБ —
копия в `teleport.log.1` и усечение на месте, см. «Служба procd»), `ssh_service.pam.enabled: false`
и `ssh_service.enhanced_recording.enabled: false` (PAM и BPF на OpenWrt нет).
Динамическая метка `os_logins` читает `/etc/passwd` (NSS и `getent` нет): на стоковой
системе это `root`.

## Параметры

<!-- catalog:params -->
| Ключ | Тип | Умолчание | Что задаёт |
|---|---|---|---|
| `TELEPORT_VERSION` | строка `^[0-9]+\.[0-9]+\.[0-9]+$` | `18.10.0` | версия Teleport; не новее кластера, для bound_keypair — не ниже 18.8.0 *(только при установке)* |
| `TELEPORT_SHA256` | строка `^[0-9a-f]{64}$` | пусто | sha256 набора openwrt-<arch> архитектуры машины; обязателен (на cdn.teleport.dev набора нет) *(только при установке)* |
| `TELEPORT_MIRROR` | строка `^https?://[A-Za-z0-9.:/-]+$` | пусто | база зеркала <base>/binaries/teleport/<ver>/teleport-v<ver>-openwrt-<arch>-bin.tar.gz (стенд Stvor) *(только при установке)* |
| `TELEPORT_TARBALL` | `path` | пусто | локальный набор openwrt-<arch> (офлайн, нужен TELEPORT_SHA256); взаимоисключим с TELEPORT_MIRROR *(только при установке)* |
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

**Ключи установки** (`scope: install`, смена — повтор `cream install teleport-openwrt KEY=…`):

- `TELEPORT_VERSION` — версия набора; **не новее кластера**, не старше на мажор.
- `TELEPORT_SHA256` — sha256 набора архитектуры машины; **обязателен**. `install`/`upgrade`
  сверяют и версию, и сумму поставленного набора (`installed-pin`, см. «`sysupgrade`»):
  пересборка форка той же версии с новой суммой (`v18.10.0-stvor.3` → `stvor.4`)
  ставится заново и перезапускает узел, без `--reinstall`.
- `TELEPORT_MIRROR` — база зеркала стенда Stvor:
  `<база>/binaries/teleport/<версия>/teleport-v<версия>-openwrt-<arch>-bin.tar.gz`.
- `TELEPORT_TARBALL` — локальный набор (офлайн); взаимоисключим с `TELEPORT_MIRROR`.
  Один из двух обязателен.

Набор — `tar.gz` с каталогом `teleport/`: `teleport/teleport`, `teleport/fdpass-teleport`
(после `patchelf --set-interpreter /opt/teleport/lib/ld-linux-<arch>.so.* --set-rpath
/opt/teleport/lib`) и `teleport/lib/` (рантайм). `tsh` в нём нет.

Ручки (`cream set teleport-openwrt KEY=…`), управляемые метки (`set-managed`,
`managed-status` — контракт stvor-agent, схема 1), `apps.d` и `command-labels.d` —
те же, что у [teleport](../../debian/teleport/README.md#параметры); каталоги —
`/etc/cream/teleport-openwrt/{apps.d,command-labels.d}`.

## Установка

Обычно — одной командой портала Stvor (строка OpenWrt: ставит `bash`, `curl`, cream,
подключает снимок каталога, `cream install teleport-openwrt` с зеркала стенда и `join`).
Вручную, на машине с OpenWrt и подключённым каталогом
([cream на OpenWrt](https://github.com/iamletenkov/cream/blob/main/docs/guides/openwrt.md)):

```sh
cream install teleport-openwrt TELEPORT_VERSION=18.10.0 \
  TELEPORT_MIRROR=https://stvor.example.org/dist/teleport TELEPORT_SHA256=<sha256 набора>
printf '%s' '<секрет>' | cream run teleport-openwrt join TELEPORT_PROXY=teleport.example.org \
  TELEPORT_JOIN_METHOD=bound_keypair TELEPORT_TOKEN=<имя токена> TELEPORT_REGISTRATION_SECRET=- TELEPORT_ENV=dev
```

В образе bisquite (VMFILE) — только набор; регистрация — на машине:

```dockerfile
RUN_COMMAND cream install teleport-openwrt TELEPORT_MIRROR=https://stvor.example.org/dist/teleport TELEPORT_SHA256=<sha256>
```

Машина: amd64 или arm64, **≥ 1 ГБ ОЗУ** (узел — ~185 МБ RSS) и **≥ 1 ГБ свободно** на
корне (набор ~100 МБ, бинари ~370 МБ; при обновлении — ещё столько же на время замены).

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | набор, раскладка, маркер, ссылка, `rc.d`; регистрации нет (в сборке — отказ, если она есть) |
| `cream upgrade` | тот же код, что `install`; агент перезапускается |
| `cream run teleport-openwrt join …` | регистрация узла |
| загрузка (`S95teleport`) | procd: render и агент (`respawn`), если узел включён; экземпляр `join` — пока ждёт регистрация |
| `cream set` (хук `apply`) | render и перезапуск агента фоном |
| изменение `apps.d` или `command-labels.d` | `cream run teleport-openwrt reload-apps` — зовёт тот, кто их положил |
| `sysupgrade` с сохранением настроек | `keep.d` хранит `/opt/teleport/data`, маркер, флаг `agent-enabled`, пин набора `installed-pin`, `config` и `apps.d` домена; повтор `cream install` возвращает тот же узел (`host_uuid`) без `join` и без секрета |
| `cream remove` | `leave`, служба выключена, набор и состояние стёрты |

Действия — те же, что у [teleport](../../debian/teleport/README.md#этапы), с отличиями:
`render` зовёт `start_service` службы; `reload-apps` — render и перезапуск с
подтверждением новым pid, если `teleport.yaml` изменился; `join-retry` — тик экземпляра
`join`; `scrub-token` — ручной (join и тик стирают секрет сами); `hup` — только для
`ExecReload` systemd, здесь отказ с кодом 2.

## Известные ограничения

- Только OpenWrt ≥ 25.12 (`apk`), amd64 и arm64 с ≥ 1 ГБ ОЗУ; роутеры, MIPS и 32-битный
  ARM не поддерживаются (спека, «Не-цели»).
- Набор `openwrt-<arch>` есть только на зеркале стенда Stvor (или файлом); с
  `cdn.teleport.dev` не ставится.
- Нет PAM, BPF-записи сессий и `create_host_user`; учёт входов (`utmp`) пуст, `wtmp` — в
  ОЗУ: предупреждения в журнале при SSH-сессиях ожидаемы.
- Изменение ручек, меток или приложений перезапускает агента — открытые SSH-сессии
  обрываются (на Debian — HUP без обрыва).
- Процессы `teleport` работают под root без песочницы systemd.
- Регистрация в кластере, `tsh ssh`, перезагрузка и `sysupgrade` проверяются на ВМ (план
  OpenWrt, приёмка), не в автоматических тестах.

## Подробности

### Ядро и слой

`files/teleport.sh` — слой procd, `files/teleport-core.sh` — общее с `teleport` ядро
(рендер, join, метки, `apps.d`, управляемые метки, `status`). Ядро зовёт бинарь только как
`env -u LD_PRELOAD …`, а слой задаёт пути, службу, журнал и подсказки с именем
`teleport-openwrt`. В busybox OpenWrt нет `stat`, `install`, `hostname` и `paste`: слой
подставляет функции ровно для тех форм, что зовёт ядро, и только если команды нет.

### Служба procd

`/etc/init.d/teleport` (`USE_PROCD=1`, `START=95`):

- экземпляр **`teleport`** — если узел включён (`/opt/cream/var/ext/teleport-openwrt/agent-enabled`,
  пишет подтверждённый `join`) или запущен на эту загрузку (`/var/run/teleport.start`):
  сначала `cream run teleport-openwrt render`, затем
  `/opt/teleport/bin/teleport start --config /etc/teleport.yaml`, `respawn`,
  `TMPDIR=/opt/teleport/tmp`. **Без `procd_set_param stdout/stderr`**: иначе procd
  выставляет `LD_PRELOAD=/lib/libsetlbf.so` (musl), и в glibc-процесс грузятся обе libc
  (PoC); журнал — `log.output` в файл `/opt/teleport/log/teleport.log` (0700/0600);
- экземпляр **`logcap`** — рядом с агентом: раз в 10 мин (и перед каждым стартом)
  `/etc/init.d/teleport log_cap` копирует журнал больше 1 МиБ в `teleport.log.1` и усекает
  его на месте (copy-truncate): на диске ≤ 2 МиБ плюс записанное за 10 мин; строки,
  записанные между копированием и усечением, теряются (окно — доли секунды). Под
  работающим агентом это безопасно — Teleport открывает журнал с `O_APPEND`
  (`lib/utils/log`), после усечения пишет с нового конца, без разреженной дыры. Журнал —
  на `/opt`, не в tmpfs (это ОЗУ);
- экземпляр **`join`** — пока есть `join-pending`: `cream run --lock-timeout 6m
  teleport-openwrt join-retry` при загрузке и раз в минуту. Заканчивается сам, когда
  маркер снят, — тик, который завершает регистрацию, не убивает свою же службу.

Агента одного останавливает `ubus call service delete` его экземпляра (отказ кластера
может прийти из тика). HUP на OpenWrt не шлётся: Teleport на HUP порождает потомка, а
родитель, отдренировав сессии, выходит — procd перезапустил бы его рядом с потомком.
Поэтому изменения применяются перезапуском с подтверждением новым pid экземпляра.

### `sysupgrade`

`sysupgrade` с сохранением настроек (по умолчанию, без `-n`) переносит узел тем же
(Р4 с поправкой владельца 2026-10-23). `/lib/upgrade/keep.d/teleport` перечисляет:

- `/opt/teleport/data/` — идентичность узла (`host_uuid`, ключи в `proc/sqlite.db`);
- `/opt/teleport/.cream-owned` — маркер владения cream;
- `/opt/cream/var/ext/teleport-openwrt/agent-enabled` — узел стартует на загрузке;
- `/opt/cream/var/ext/teleport-openwrt/installed-pin` — пин поставленного набора, две
  строки `TELEPORT_VERSION=<X.Y.Z>` и `TELEPORT_SHA256=<64 hex>`; пишет `install`/`upgrade`
  после каждой замены набора. Стабильный интерфейс: `/etc/stvor/restore.sh` Stvor берёт
  версию и сумму набора отсюда, а не из своей копии (иначе после обновления через cream
  его пин устаревает);
- `/etc/cream/teleport-openwrt/config` и `apps.d/` — ручки домена (прокси, имя токена,
  `env`, метки, приложения); секрета первого входа там нет.

Набор, `/etc/init.d/teleport`, реестр cream и `command-labels.d` не сохраняются:
`command-labels.d` кладут другие расширения через `files`, а cream отказывает в файле,
который уже лежит на диске до установки (`conflict.file_unowned`). Расширение, которое
кладёт файл через `files` в сохраняемый путь, ломает восстановление — H-тест это
проверяет.

После новой прошивки расширение ставится заново (`cream install teleport-openwrt` с теми же
`TELEPORT_*` набора; на роботе Stvor это делает его служба восстановления): `install` видит
маркер и data, скачивает набор, возвращает каталогу состояния права 0700, флагу — 0600
(архив хранит только файлы, `tar` создаёт каталоги заново 0755) и ничего не регистрирует;
служба `teleport` поднимает узел по флагу с тем же `host_uuid`. Повтор команды портала без
секрета и без `TELEPORT_FORCE` проходит веткой «уже зарегистрирован». «Новый секрет» нужен
только при потерянной идентичности (`sysupgrade -n`, новый диск) — тогда Teleport выдаёт
новый `host_uuid`.

> **Архив `sysupgrade` — секрет уровня root.** В нём ключ узла (`/opt/teleport/data`), как
> и `/etc/shadow`; выгрузка `sysupgrade -b` или резервная копия LuCI с ним — тоже.
> Восстанавливайте его только на ту же машину: на другой получится клон узла.

### Настройка на загрузке

Хука `configure` нет: на загрузке узел поднимает procd (`S95teleport`), не cream; признаки
А1–А6 ([настройка на загрузке](../../../docs/guides/configure-lifecycle.md)) к расширению не
относятся, `every_boot` не нужен.

## Проверки

- **V** — `make cream-validate` и `make cream-check` (openwrt:25.12) по staged-дереву
  (`tools/stage-catalog.sh` кладёт ядро), `tools/lint-hooks.sh`.
- **H** — `tests/test-teleport-openwrt.sh`: ключи и действия сверены с `debian/teleport`,
  типы — с ядром; init-скрипт (`start_service` с заглушками procd: экземпляры, `respawn`,
  `TMPDIR`, нет `stdout/stderr`), `keep.d`; `install` (зеркало и файл, sha256, `uname -m`,
  маркер владения, сборка, после `sysupgrade`; имитация `sysupgrade` по `keep.d` — тот же
  `host_uuid`, data не тронута, права 0700/0600, повтор `join` без секрета — ветка «уже
  зарегистрирован»; `keep.d` не пересекается с `files` расширений OpenWrt), render (журнал-файл, `pam`,
  `enhanced_recording`, `data_dir`), `join` с подставными procd/ubus
  (регистрация, ожидание сети и тик, отказ по журналу узла с отсечкой; строки `logger`
  с тегом `teleport[<pid экземпляра>]` и журнал с записью для всех — не отказ;
  предел журнала под работающим писателем с `O_APPEND`), `set-managed`
  (перезапуск с подтверждением и без), `reload-apps`, `apply`, `hup`, `remove`; действия
  с набором команд busybox (без `stat`, `install`, `hostname`, `paste`).
- **L** — `make test-openwrt`: корневая ФС openwrt-builder v0.3.1 в контейнере, настоящие
  cream и busybox: `install` из локального набора-подделки в фазе build, отложенный `join`
  (`bound_keypair` и `token`), `log_cap` через rc.common, render, управляемые метки, `remove`; `sysupgrade` с
  `stvor-agent-openwrt` (настоящий `sysupgrade -b`, распаковка в свежем образе, повторная
  установка: тот же `host_uuid`, `join` не вызывался). procd в контейнере нет —
  загрузка, регистрация и `tsh ssh` проверяются на ВМ.
