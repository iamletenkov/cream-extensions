# btop

Ставит `btop` — TUI-монитор ресурсов (CPU, память, диски, сеть, процессы)
обычным пакетом из `universe`, а где пакета нет — статической сборкой релиза.

```
cream install btop          # живая машина
cream remove btop
EXTENSION btop              # образ bisquite
```

> **С 2.0.0 — cream/v1.** `install.sh` стал хуком `hooks/install`, появился хук
> `remove`; каталог в госте — `/opt/cream/ext/btop/`. Ставит и удаляет cream,
> настроек нет.

## Где пакета нет — сборка релиза (с 1.2.0)

В focal (Ubuntu 20.04 — образ Jetson Nano от Q-engineering) пакета `btop` нет.
Тогда расширение ставит статическую сборку musl релиза `v1.4.4` с GitHub
в `/usr/local/bin/btop`, сверив sha256 (закреплён для `aarch64` и `x86_64`;
другая архитектура — отказ). Проверено на живом Nano 2026-09-15.

## Что снимает `remove`

`install` записывает, кто поставил btop, в `/var/lib/cream/ext/btop/method`:

| Запись | Что было | Что делает `remove` |
|---|---|---|
| `apt` | пакет поставлен этим расширением | `apt-get remove btop` |
| `static` | сборка релиза в `/usr/local/bin/btop` | удаляет файл |
| `preexisting` | пакет стоял до cream | ничего |

Повторный `install` (`--reinstall`) запись не меняет.

## Манифест

| Поле | Значение |
|---|---|
| `targets` | `build: exec`, `live: yes` |
| `platform.arch` | `amd64`, `arm64` |
| `provides` | `system-monitor` |
| `hooks` | `install` (15 мин), `remove` |

## Проверки

- **V** — `make cream-validate`, `tools/check-names.sh`.
- **H** — `tests/test-btop.sh`: apt (свой и чужой пакет), сборка релиза, отказ по
  sha256 и архитектуре, повтор, `remove`.
- **L** — `make test-live EXT=btop` на `debian-12` и `ubuntu-24.04` (`tests/live.env`).

Живая плата, Ubuntu 22.04 (jammy) arm64, 2026-09-12:

```
btop | 1.2.3-2 | http://ports.ubuntu.com/ubuntu-ports jammy/universe arm64 Packages
```

## Отношение к jetson-stats

Не конкурируют и не пересекаются: `btop` — общий монитор ОС (CPU/RAM/диск/
сеть/процессы), `jetson-stats` — специфичный для Tegra (GPU, питание,
частоты, `nvpmodel`), читает `tegrastats` и sysfs-узлы, которых на не-Jetson
нет. Ставятся вместе без конфликта — оба легитимно нужны на одном образе.
