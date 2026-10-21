# btop

Ставит `btop` — TUI-монитор ресурсов (CPU, память, диски, сеть, процессы)
обычным пакетом из `universe`, а где пакета нет — статической сборкой релиза.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | amd64, arm64 |
| cream | ≥ 1.0.0 |
| Даёт | `system-monitor` |
| Требует | — |
| Зависит от | [`apt-guard`](../apt-guard/README.md) |
| Конфликтует с | — |
| Хуки | `install`, `remove` |
| Настройка на загрузке | — |
| Живая машина | да |
<!-- /catalog:facts -->

## Что делает

- **`install`** — ставит пакет `btop` из apt. Где пакета нет (focal, Ubuntu
  20.04 — образ Jetson Nano от Q-engineering), ставит статическую сборку musl
  релиза `v1.4.4` с GitHub в `/usr/local/bin/btop`, сверив sha256 (закреплён
  для `aarch64` и `x86_64`; другая архитектура — отказ). Кто поставил btop,
  записывает в `/var/lib/cream/ext/btop/method`; повторный `install`
  (`--reinstall`) запись не меняет.
- **`remove`** — снимает только то, что поставило расширение:

| Запись | Что было | Что делает `remove` |
|---|---|---|
| `apt` | пакет поставлен этим расширением | `apt-get remove btop` |
| `static` | сборка релиза в `/usr/local/bin/btop` | удаляет файл |
| `preexisting` | пакет стоял до cream | ничего |

## Параметры

<!-- catalog:params -->
Параметров нет.
<!-- /catalog:params -->

Настроек нет.

## Установка

На машине с подключённым каталогом ([как подключить](../../../docs/getting-started.md)):

```bash
sudo cream install --with-deps btop
cream show btop
sudo cream remove btop
```

В образе bisquite (VMFILE):

```dockerfile
RUN_COMMAND cream install --with-deps btop
```

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | пакет apt или сборка релиза по sha256, запись `method` |
| загрузка | ничего: хука `configure` нет |
| `cream remove` | снимает пакет или файл по записи `method`; `preexisting` не трогает |

## Известные ограничения

- Сборка релиза закреплена только для `aarch64` и `x86_64`; на другой
  архитектуре без пакета — отказ.

## Подробности

### Проверено на

- Живой Jetson Nano (focal, сборка релиза), 2026-09-15.
- Живая плата, Ubuntu 22.04 (jammy) arm64, 2026-09-12:

```
btop | 1.2.3-2 | http://ports.ubuntu.com/ubuntu-ports jammy/universe arm64 Packages
```

### Отношение к jetson-stats

Не конкурируют и не пересекаются: `btop` — общий монитор ОС (CPU/RAM/диск/
сеть/процессы), [`jetson-stats`](../jetson-stats/README.md) — специфичный для
Tegra (GPU, питание, частоты, `nvpmodel`), читает `tegrastats` и sysfs-узлы,
которых на не-Jetson нет. Ставятся вместе без конфликта — оба легитимно нужны
на одном образе.

## Проверки

- **V** — `make cream-validate`, `tools/check-names.sh`.
- **H** — `tests/test-btop.sh`: apt (свой и чужой пакет), сборка релиза, отказ по
  sha256 и архитектуре, повтор, `remove`.
- **L** — `make test-live EXT=btop` на `debian-12` и `ubuntu-24.04` (`tests/live.env`).
