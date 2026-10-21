# tensorrt

Ставит TensorRT (движок инференса + Python-биндинги) на Jetson из
apt-репозитория `jetson/common`, уже подключённого базовым образом L4T. На L4T
R32 (Jetson Nano) ничего не ставит — проверяет движок образа.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | arm64 |
| cream | ≥ 1.0.0 |
| Даёт | `tensorrt` |
| Требует | — |
| Зависит от | [`l4t`](../l4t/README.md), [`apt-guard`](../apt-guard/README.md) |
| Конфликтует с | — |
| Хуки | `install`, `remove` |
| Настройка на загрузке | — |
| Живая машина | да |
<!-- /catalog:facts -->

## Что делает

- **`install`** — нет `/etc/nv_tegra_release` (не Jetson) — код **20** до apt.
  Ветка выбирается по первой строке `/etc/nv_tegra_release` (`# R32 …`); разбор
  общий — `l4t_major` библиотеки [`l4t`](../l4t/README.md)
  (`/opt/cream/ext/l4t/l4t.sh`, файл читается как данные).
  - **R36** — ставит пакеты из «Что ставится»; после установки — явный
    `ldconfig` и проверка, что `libnvdla_compiler.so` видна загрузчику. Пакеты,
    которых до него не было, записывает в `/var/lib/cream/ext/tensorrt/packages`;
    повторный `install` (`--reinstall`) запись не меняет.
  - **R32** — ничего не ставит (см. «Ветка R32»).
- **`configure`** — нет: на загрузке доделывать нечего.
- **`remove`** — через библиотеку [`apt-guard`](../apt-guard/README.md) сначала
  спрашивает apt в режиме симуляции (`apt-get -s remove`): если вместе со своими
  пакетами apt снял бы и чужие (от них зависит поставленное позже), хук
  отказывает и ничего не меняет — снимите руками или
  `cream remove --forget tensorrt`. Иначе — `apt-get remove` своих пакетов.
  Пакеты, стоявшие до cream, остаются. На R32 `install` ничего не ставит, и
  `remove` ничего не снимает.

Зависимость от CUDA решает apt: TensorRT нужен рантайм CUDA
(`nvidia-l4t-cuda`, всегда в базовом образе), а не `cuda-toolkit`.

### Что ставится (R36)

- `tensorrt` — мета-пакет: рантайм-библиотеки (`libnvinfer10`,
  `libnvinfer-plugin10`, …) и dev-заголовки одной согласованной версией;
- `python3-libnvinfer` — Python-биндинги отдельно: `tensorrt` их не тянет,
  а инференс на Jetson в большинстве случаев идёт из Python;
- `nvidia-l4t-dla-compiler` — `libnvdla_compiler.so`, без которого падает
  `import tensorrt` (и `jtop`).

| Код `install` | Когда |
|---|---|
| 0 | поставлено (R36) или движок образа на месте (R32) |
| 1 | нет библиотеки `l4t`, нет источника `jetson/common`, apt не прошёл, `libnvdla_compiler.so` не виден загрузчику; R32 — нет `libnvinfer8`, `trtexec` или `libnvinfer.so.8` |
| 20 | нет `/etc/nv_tegra_release` — не Jetson, ставить неоткуда (до apt) |

## Параметры

<!-- catalog:params -->
Параметров нет.
<!-- /catalog:params -->

Настроек нет.

## Установка

На плате Jetson с подключённым каталогом ([как подключить](../../../docs/getting-started.md));
библиотеки `l4t` и `apt-guard` cream ставит по `depends`:

```bash
sudo cream install --with-deps tensorrt
sudo cream remove tensorrt
```

В образе bisquite (VMFILE) — основной путь:

```dockerfile
RUN_COMMAND cream install --with-deps tensorrt
```

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | R36 — пакеты, `ldconfig`, проверка DLA-компилятора; R32 — проверка движка образа; не Jetson — код 20 |
| загрузка | ничего: `configure` нет |
| `cream remove` | свои пакеты, если apt не снимет с ними чужих |

## Известные ограничения

- **Размер.** `libnvinfer-dev` один занимает больше полугигабайта установленного —
  вместе с рантаймом и заголовками TensorRT ощутимо утяжеляет образ.
  Не кандидат в базовый образ флота, только в прикладной слой.
- На R32 Python-модуля `tensorrt` нет (см. «Ветка R32»).
- Установка на живой плате и сборка образа проверяются вручную: платы Jetson в
  CI нет.

## Подробности

### Ветка R32 (Jetson Nano, JetPack 4.6)

TensorRT 8.0.1.6 в образе Q-engineering уже есть. Ничего не ставится;
проверяется пакет `libnvinfer8`, исполняемый `/usr/src/tensorrt/bin/trtexec`
(`libnvinfer-bin`) и `libnvinfer.so.8` в кеше загрузчика.

**Python-модуля нет, и это не отказ**: JetPack 4.6 публикует `tensorrt`
только под Python 3.6, а в образе 3.8. Расширение говорит об этом
предупреждением; TensorRT доступен из C++ и `trtexec`.

Проверено на живом Nano (L4T R32.6.1, 2026-09-15) прогоном установки на
работающей системе (до перехода на cream/v1).

### Проверено на R36

Живая плата, JetPack 6.2.1, L4T 36.4.3, 2026-09-12:

```
tensorrt   | 10.3.0.30-1+cuda12.5 | https://repo.download.nvidia.com/jetson/common r36.4/main arm64 Packages
```

## Проверки

- **V** — `make cream-validate`, `tools/check-names.sh`.
- **H** — `tests/test-tensorrt.sh`: код 20 без L4T, отказ без библиотеки и без источника,
  R36 (пакеты, `ldconfig`, отказ без `libnvdla_compiler.so`, повтор, пакеты до cream),
  R32 (без установки, Python-модуль есть/нет, отказы), `remove` (свой, повтор, отказ при
  чужих зависимых). Библиотека `l4t` в тесте — настоящий `l4t.sh` в подменённом корне.
- **P — ожидает.** Платы Jetson в CI нет: установка на живой плате (R36 — AGX Orin,
  R32 — Nano) через `cream install` или сборка образа через bisquite проверяются
  вручную.
- **L** — не нужен: в контейнере нет `/etc/nv_tegra_release`, ответ — код 20, его
  проверяет H.
