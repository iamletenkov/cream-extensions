# stvor-agent

Обёртка пакета [stvor-agent](https://github.com/iamletenkov/stvor-agent) —
агента портала Stvor на машине. Агент забирает с портала метки `env` и `space`
узла Teleport и отдаёт их расширению `teleport` (`cream run teleport
set-managed`). Само расширение — тонкое: ставит `.deb` по версии и sha256 и
включает динамическую метку `stvor_agent`. Спека — stvor-agent §11.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian ≥ 12, Ubuntu ≥ 20.04 |
| Архитектура | amd64, arm64 |
| cream | ≥ 1.0.0 |
| Даёт | `stvor-agent` |
| Требует | — |
| Зависит от | [`teleport`](../teleport/README.md) |
| Конфликтует с | — |
| Хуки | `install`, `upgrade`, `remove`, `apply` |
| Настройка на загрузке | — |
| Действия | `cream run stvor-agent status` |
| Живая машина | да |
<!-- /catalog:facts -->

## Что делает

| Хук | Что |
|---|---|
| `install` | выбирает версию и сумму (явные ключи или пин), берёт `.deb` из источника, сверяет sha256, `dpkg -i`. Та же версия уже стоит — пропуск |
| `upgrade` | то же; `postinst` пакета перезапускает службу, если агент включён |
| `remove` | `stvor-agent disable` (обе службы, токены, `state.json`), на живой машине — `systemctl stop` юнитов `stvor-agent` и `stvor-agent-telemetry`, `dpkg -r stvor-agent`, затем стираются `/etc/stvor-agent-telemetry` и `/var/lib/stvor-agent-telemetry` |
| `apply` | `systemctl --no-block try-restart stvor-agent.service` — служба перечитывает `/etc/cream/stvor-agent/config` |

| Действие | Что |
|---|---|
| `status` | здоровье: `stvor-agent status --json` с вердиктом — `{"schema":1,"healthy":…,"problems":[…],"agent":<документ агента>}`; код 0 — здоров, 1 — нет |

**Телеметрия (агент ≥ 4.1.0).** Пакет сам заводит пользователя `stvor-telemetry`
(`sysusers.d`, в `postinst`) и включает `stvor-agent-telemetry.service`; обёртка в
это не вмешивается — не маскирует юнит и пользователей не заводит. Служба стартует
только с токеном телеметрии, который получает служба меток. `cream remove`
останавливает оба юнита и стирает каталоги телеметрии: cream не сообщает хуку о
`--purge`, а после `disable` там только отпечаток и неотправленный буфер снятого
токена — то, что убрал бы `dpkg --purge`.

**Здоровье** (`cream run stvor-agent status`): здоров, если агент включён
(`enabled: true`), служба меток `active`, а при блоке `telemetry` (агент ≥ 4.1.0) —
служба телеметрии `active` и её токен `ok`. Иначе код 1, в `problems` — строки вида
`agent.enabled:false`, `agent.service:inactive`, `telemetry.service:failed`,
`telemetry.token:absent|rejected|no_access|corrupt`, `agent.not_installed`,
`agent.status_failed`. Сразу после `enable` токен телеметрии ещё `absent` —
это не здорово, пока служба меток его не получит.

Пин пакета — `files/pin.env` (версия и суммы по архитектурам из `SHA256SUMS`
релиза); его поднимает `tools/agent-bump.sh` по релизу stvor-agent.

**Платформа:** Debian ≥ 12, Ubuntu ≥ 20.04 (20.04 — ради Jetson Nano на L4T
R32). Агент — статический Go-бинарь, пакет зависит только от `cream`; юнит пакета
(`Type=exec`, `ProtectClock`, `ProtectKernelLogs`) требует systemd ≥ 245 — у focal 245.

Зависит от `teleport >=4.0.2 <5`: мажор `teleport` — версия интерфейса
управляемых меток и контракта `command-labels.d`. Пока стоит обёртка,
`cream remove teleport` отказывает (67).

**Метка `stvor_agent`.** Файл `files/stvor_agent.command-label` cream кладёт
в `/etc/cream/teleport/command-labels.d/stvor_agent` (поле `files`
манифеста): владелец — эта обёртка, `cream remove stvor-agent` его убирает.
Внутри одна строка `command=/usr/bin/stvor-agent version --label`. Teleport
раз в 5 минут исполняет команду и публикует вывод — версию агента, если он
включён, иначе пустую строку. cream кладёт файл до хука `install` (спека cream
§6.5), то есть раньше бинаря. Это не важно: render `teleport` оставляет в
конфиге команду, которой ещё нет, если она непосредственно в `/usr/bin`, `/usr/sbin`
или `/usr/local/bin` (контракт drop-in, [README `teleport`](../teleport/README.md);
`/usr/bin/stvor-agent` — туда), а проверяет её сам Teleport при запуске.
`teleport-apps.path` → `reload-apps` — одна сериализованная точка применения:
HUP новейшему процессу Teleport с подтверждением, restart только без живого
процесса. Хуки обёртки `teleport-apps.service` не запускают. До `join` юнит
ничего не делает (`ConditionPathExists=/etc/teleport.yaml`).

**Токен меток — не настройка cream.** Хуки токен не принимают и службу сами не
включают. Юнит `stvor-agent.service` включает **пакет** при установке
(`postinst`), но старт ждёт токена: в юните `ConditionPathExists=/etc/stvor-agent/token`,
и до токена служба при загрузке тихо пропускается (`inactive`, не `failed`).
Токен пишет `stvor-agent enable` (токен на stdin) — он же запускает службу; `stvor-agent
disable` (и хук `remove`) убирает токен и `state.json`. Дочерние
процессы хуков (`curl`, `dpkg`, `stvor-agent`) получают своё минимальное
окружение (`PATH`, `LANG`, `DEBIAN_FRONTEND`).

## Параметры

<!-- catalog:params -->
| Ключ | Тип | Умолчание | Что задаёт |
|---|---|---|---|
| `STVOR_AGENT_VERSION` | строка `^[0-9]+\.[0-9]+\.[0-9]+$` | пусто | версия пакета агента; задаётся вместе с STVOR_AGENT_SHA256, пусто — пин каталога (files/pin.env) *(только при установке)* |
| `STVOR_AGENT_SHA256` | строка `^[0-9a-f]{64}$` | пусто | sha256 .deb архитектуры машины; задаётся вместе с STVOR_AGENT_VERSION *(только при установке)* |
| `STVOR_AGENT_MIRROR` | `str` | пусто | база зеркала, файл плоско <база>/stvor-agent_<версия>_<arch>.deb; пусто — релиз GitHub *(только при установке)* |
| `STVOR_AGENT_DEB` | `path` | пусто | локальный .deb (офлайн, абсолютный путь); взаимоисключим с STVOR_AGENT_MIRROR *(только при установке)* |
| `STVOR_AGENT_INTERVAL` | строка `^([6-9][0-9]\|[1-5][0-9]{2}\|600)$` | `60` | период опроса портала, секунды, 60–600 |
| `STVOR_AGENT_LOG_LEVEL` | `info` \| `debug` | `info` | уровень журнала службы |
<!-- /catalog:params -->

Параметры установки (`STVOR_AGENT_VERSION`, `_SHA256`, `_MIRROR`, `_DEB`) —
только через `cream install`, `cream set` им отказывает. Повтор
`cream install stvor-agent` с новой версией и суммой перезапускает хук
`install` — так портал обновляет агента.

- `STVOR_AGENT_MIRROR` — так раздаёт `/dist/teleport/` портала;
  `STVOR_AGENT_DEB` с `STVOR_AGENT_MIRROR` — отказ.
- Версия и сумма обе пусты — берутся из пина каталога `files/pin.env`
  (`STVOR_AGENT_PIN_VERSION`, `STVOR_AGENT_PIN_SHA256_AMD64`,
  `STVOR_AGENT_PIN_SHA256_ARM64`). Задана одна из двух — отказ: явная пара
  побеждает пин целиком и не добирается из него. Пин без версии или без суммы
  своей архитектуры — отказ до сети. Источник по умолчанию — релиз GitHub
  `…/releases/download/v<версия>/stvor-agent_<версия>_<arch>.deb`. Архитектура —
  `dpkg --print-architecture`: `amd64` или `arm64`.

Настройки службы (`STVOR_AGENT_INTERVAL`, `STVOR_AGENT_LOG_LEVEL`) лежат в
`/etc/cream/stvor-agent/config`; служба читает его как `EnvironmentFile`:

```sh
sudo cream set stvor-agent STVOR_AGENT_INTERVAL=120   # хук apply перезапускает службу
```

## Установка

На машине с подключённым каталогом ([как подключить](../../../docs/getting-started.md)):

```sh
sudo cream install --with-deps teleport TELEPORT_VERSION=18.10.0 TELEPORT_SHA256=<пин arch> TELEPORT_MIRROR=https://<домен>/dist/teleport
sudo cream install --with-deps stvor-agent STVOR_AGENT_VERSION=<v> STVOR_AGENT_SHA256=<пин arch> STVOR_AGENT_MIRROR=https://<домен>/dist/teleport
printf '%s' "$LABEL_TOKEN" | sudo stvor-agent enable 'URL=https://<домен>/robot-api/v1/labels'
# офлайн: STVOR_AGENT_DEB=/путь/stvor-agent_<v>_<arch>.deb вместо зеркала
```

В образе bisquite (VMFILE) пакет ставится на сборке: юнит включён, но без токена
служба не стартует; метка `stvor_agent` попадает в первый render `teleport`.
Токен — на первой загрузке тем же `stvor-agent enable`, в образ не кладётся.

```dockerfile
RUN_COMMAND cream install --with-deps stvor-agent
```

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | drop-in метки (cream, до хука), `.deb` по пину или явной паре, sha256, `dpkg -i`; на живой машине — reload меток |
| загрузка | служба `stvor-agent` стартует, только если есть токен |
| `cream set` (хук `apply`) | `try-restart` службы без ожидания |
| `cream upgrade` | новый `.deb`; `postinst` перезапускает включённую службу |
| `cream remove` | `stvor-agent disable`, стоп обоих юнитов, `dpkg -r`, каталоги телеметрии стёрты; drop-in метки снимает cream |

## Известные ограничения

- Токен меток cream не хранит и хуки его не принимают: включить агента —
  только `stvor-agent enable` на машине.
- Пока стоит обёртка, `cream remove teleport` отказывает (67).

## Проверки

- **V** — `make cream-validate`, `tools/lint-hooks.sh`, `make check-names`.
- **H** — `tests/test-stvor-agent.sh` (его зовёт `tools/check.sh`): манифест, пин,
  выбор источника, сверка суммы, отказ при неполном пине, явные версия и сумма
  побеждают пин, reload меток после `dpkg -i` (не в фазе build), токен не попадает в argv и окружение `curl`/`dpkg`/
  `stvor-agent`, хуки `remove` (оба юнита, каталоги телеметрии) и `apply`, действие
  `status` (блок `telemetry`, агент до 4.1.0, не включён, нет пакета, не JSON). При `CREAM_DEB=<.deb>` (или кеше пина
  `tools/cream-pin.env`) и docker — ещё прогон настоящим cream в `debian:12`:
  drop-in на месте после `install`, убран `remove`.
- **L** — `make test-live EXT=stvor-agent` (`tests/live.env`: поверх `teleport`;
  `debian-12`, `ubuntu-20.04`, `ubuntu-24.04`).
