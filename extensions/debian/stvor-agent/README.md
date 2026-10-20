# stvor-agent

Обёртка пакета [stvor-agent](https://github.com/iamletenkov/stvor-agent) —
агента портала Stvor на машине. Агент забирает с портала метки `env` и `space`
узла Teleport и отдаёт их расширению `teleport` (`cream run teleport
set-managed`). Само расширение — тонкое: ставит `.deb` по версии и sha256 и
включает динамическую метку `stvor_agent`. Формат — `cream/v1`, спека —
stvor-agent §11.

Пин пакета — `files/pin.env` (stvor-agent 4.0.0, суммы по архитектурам из `SHA256SUMS` релиза);
его поднимает `tools/agent-bump.sh` по релизу stvor-agent.

## Что делает

**Платформа:** Debian ≥ 12, Ubuntu ≥ 20.04 (с 4.1.0 — ради Jetson Nano на L4T
R32). Агент — статический Go-бинарь, пакет зависит только от `cream`; юнит пакета
(`Type=exec`, `ProtectClock`, `ProtectKernelLogs`) требует systemd ≥ 245 — у focal 245.


| Хук | Что |
|---|---|
| `install` | выбирает версию и сумму (явные ключи или пин), берёт `.deb` из источника, сверяет sha256, `dpkg -i`. Та же версия уже стоит — пропуск |
| `upgrade` | то же; `postinst` пакета перезапускает службу, если агент включён |
| `remove` | `stvor-agent disable` (служба, токен и `state.json`), затем `dpkg -r stvor-agent` |
| `apply` | `systemctl --no-block try-restart stvor-agent.service` — служба перечитывает `/etc/cream/stvor-agent/config` |

Зависит от `teleport >=4.0.2 <5`: мажор `teleport` — версия интерфейса
управляемых меток и контракта `command-labels.d`. Пока стоит обёртка,
`cream remove teleport` отказывает (67).

**Метка `stvor_agent`.** Файл `files/stvor_agent.command-label` cream кладёт
в `/etc/cream/teleport/command-labels.d/stvor_agent` (поле `files`
манифеста): владелец — эта обёртка, `cream remove stvor-agent` его убирает.
Внутри одна строка `command=/usr/bin/stvor-agent version --label`. Teleport
раз в 5 минут исполняет команду и публикует вывод — версию агента, если он
включён, иначе пустую строку. cream кладёт файл до хука `install` (спека cream
§6.5), то есть раньше бинаря. С `teleport` 4.0.2 это не важно: render оставляет в
конфиге команду, которой ещё нет, если она непосредственно в `/usr/bin`, `/usr/sbin`
или `/usr/local/bin` (контракт drop-in, README `teleport`; `/usr/bin/stvor-agent` —
туда), а проверяет её сам Teleport при запуске. `teleport-apps.path` → `reload-apps` —
одна сериализованная точка применения: HUP новейшему процессу Teleport с
подтверждением, restart только без живого процесса. Хуки обёртки
`teleport-apps.service` больше не запускают. До `join` юнит ничего не делает
(`ConditionPathExists=/etc/teleport.yaml`).

**Токен меток — не ручка cream.** Хуки токен не принимают и службу сами не
включают. Юнит `stvor-agent.service` включает **пакет** при установке
(`postinst`), но старт ждёт токена: в юните `ConditionPathExists=/etc/stvor-agent/token`,
и до токена служба при загрузке тихо пропускается (`inactive`, не `failed`).
Токен пишет `stvor-agent enable` (токен на stdin) — он же запускает службу; `stvor-agent
disable` (и хук `remove`) убирает токен и `state.json`. Дочерние
процессы хуков (`curl`, `dpkg`, `stvor-agent`) получают своё минимальное
окружение (`PATH`, `LANG`, `DEBIAN_FRONTEND`).

## Ключи

Параметры установки (`scope: install`) — только через `cream install`,
`cream set` им отказывает. Повтор `cream install stvor-agent` с новой версией
и суммой перезапускает хук `install` — так портал обновляет агента.

| Ключ | Умолчание | Что |
|---|---|---|
| `STVOR_AGENT_VERSION` | пусто | версия пакета; только вместе с `STVOR_AGENT_SHA256` |
| `STVOR_AGENT_SHA256` | пусто | sha256 `.deb` архитектуры машины; только вместе с `STVOR_AGENT_VERSION` |
| `STVOR_AGENT_MIRROR` | пусто | база зеркала, файл плоско: `<база>/stvor-agent_<версия>_<arch>.deb` (так раздаёт `/dist/teleport/` портала) |
| `STVOR_AGENT_DEB` | пусто | локальный `.deb`, абсолютный путь (офлайн); с `STVOR_AGENT_MIRROR` — отказ |

Обе пусты — версия и сумма берутся из пина каталога `files/pin.env`
(`STVOR_AGENT_PIN_VERSION`, `STVOR_AGENT_PIN_SHA256_AMD64`,
`STVOR_AGENT_PIN_SHA256_ARM64`). Задана одна из двух — отказ: явная пара
побеждает пин целиком и не добирается из него. Пин без версии или без суммы
своей архитектуры — отказ до сети. Источник по умолчанию — релиз GitHub
`…/releases/download/v<версия>/stvor-agent_<версия>_<arch>.deb`. Архитектура —
`dpkg --print-architecture`: `amd64` или `arm64`.

Настройки службы (`scope: config`, файл `/etc/cream/stvor-agent/config`,
служба читает его как `EnvironmentFile`):

| Ключ | Умолчание | Что |
|---|---|---|
| `STVOR_AGENT_INTERVAL` | `60` | период опроса портала, секунды, 60–600 |
| `STVOR_AGENT_LOG_LEVEL` | `info` | `info` или `debug` |

```sh
sudo cream set stvor-agent STVOR_AGENT_INTERVAL=120   # хук apply перезапускает службу
```

## На машине

```sh
cream install teleport TELEPORT_VERSION=18.10.0 TELEPORT_SHA256=<пин arch> TELEPORT_MIRROR=https://<домен>/dist/teleport
cream install stvor-agent STVOR_AGENT_VERSION=<v> STVOR_AGENT_SHA256=<пин arch> STVOR_AGENT_MIRROR=https://<домен>/dist/teleport
printf '%s' "$LABEL_TOKEN" | stvor-agent enable 'URL=https://<домен>/robot-api/v1/labels'
# офлайн: STVOR_AGENT_DEB=/путь/stvor-agent_<v>_<arch>.deb вместо зеркала
```

В образе bisquite (`targets.build: exec`) пакет ставится на сборке: юнит
включён, но без токена служба не стартует; метка `stvor_agent` попадает в первый
render `teleport`. Токен — на первой загрузке тем же `stvor-agent enable`.

## Проверки

`tests/test-stvor-agent.sh` (его зовёт `tools/check.sh`): манифест, пин,
выбор источника, сверка суммы, отказ при неполном пине, явные версия и сумма
побеждают пин, reload меток после `dpkg -i` (не в фазе build), токен не попадает в argv и окружение `curl`/`dpkg`/
`stvor-agent`, хуки `remove` и `apply`. При `CREAM_DEB=<.deb>` (или кеше пина
`tools/cream-pin.env`) и docker — ещё прогон настоящим cream в `debian:12`:
drop-in на месте после `install`, убран `remove`.
