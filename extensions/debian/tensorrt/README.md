# tensorrt

Ставит TensorRT (движок инференса + Python-биндинги) на Jetson из
apt-репозитория `jetson/common`, уже подключённого базовым образом L4T.

```
EXTENSION tensorrt          # образ bisquite (основной путь)
sudo cream install tensorrt # живая плата Jetson; библиотеку l4t cream ставит по depends
sudo cream remove tensorrt
```

> **2.0.0 — cream/v1.** `install.sh` стал хуком `hooks/install`, появился хук `remove`;
> `live: yes`. Каталог в госте — `/opt/cream/ext/tensorrt/`. Общий код L4T — библиотека
> [`l4t`](../l4t/README.md) (`depends: l4t >=1.0.0 <2`, файл
> `/opt/cream/ext/l4t/l4t.sh`) вместо общего L4T-файла из `lib/` layout 2. Нет `/etc/nv_tegra_release`
> (не Jetson) — код **20** до apt (рулинг Р11), а не отказ 1. Настроек нет.

## Ветка R32 (Jetson Nano, JetPack 4.6) — с 1.2.0

Ветка выбирается по первой строке `/etc/nv_tegra_release` (`# R32 …`),
разбор общий — `l4t_major` библиотеки `l4t` (файл читается как данные).

TensorRT 8.0.1.6 в образе Q-engineering уже есть. Ничего не ставится;
проверяется пакет `libnvinfer8`, исполняемый `/usr/src/tensorrt/bin/trtexec`
(`libnvinfer-bin`) и `libnvinfer.so.8` в кеше загрузчика.

**Python-модуля нет, и это не отказ**: JetPack 4.6 публикует `tensorrt`
только под Python 3.6, а в образе 3.8. Расширение говорит об этом
предупреждением; TensorRT доступен из C++ и `trtexec`.

Проверено на живом Nano (L4T R32.6.1, 2026-09-15) прогоном установки (1.2.0) на работающей системе.

## Манифест

| Поле | Значение |
|---|---|
| `targets` | `build: exec`, `live: yes` |
| `platform.arch` | `arm64` |
| `provides` | `tensorrt` |
| `depends` | `l4t >=1.0.0 <2` (библиотека); зависимость от CUDA решает apt |
| `hooks` | `install` (30 мин), `remove` |

## Проверено

Живая плата, JetPack 6.2.1, L4T 36.4.3, 2026-09-12:

```
tensorrt   | 10.3.0.30-1+cuda12.5 | https://repo.download.nvidia.com/jetson/common r36.4/main arm64 Packages
```

## Что ставится

- `tensorrt` — мета-пакет: рантайм-библиотеки (`libnvinfer10`,
  `libnvinfer-plugin10`, …) и dev-заголовки одной согласованной версией;
- `python3-libnvinfer` — Python-биндинги отдельно: `tensorrt` их не тянет,
  а инференс на Jetson в большинстве случаев идёт из Python;
- `nvidia-l4t-dla-compiler` — `libnvdla_compiler.so`, без которого падает
  `import tensorrt` (и `jtop`); после установки — явный `ldconfig` и проверка, что
  библиотека видна загрузчику.

## Размер

`libnvinfer-dev` один занимает больше полугигабайта установленного —
вместе с рантаймом и заголовками TensorRT ощутимо утяжеляет образ.
Не кандидат в базовый образ флота, только в прикладной слой.

## Что снимает `remove`

`install` записывает в `/var/lib/cream/ext/tensorrt/packages` только пакеты, которых
до него не было; повторный `install` (`--reinstall`) запись не меняет. `remove`
сначала спрашивает apt в режиме симуляции (`apt-get -s remove`): если вместе со
своими пакетами apt снял бы и чужие (от них зависит поставленное позже), хук
отказывает и ничего не меняет — снимите руками или `cream remove --forget tensorrt`.
Иначе — `apt-get remove` своих пакетов. Пакеты, стоявшие до cream, остаются.
На R32 `install` ничего не ставит, и `remove` ничего не снимает.

## Коды выхода `install`

| Код | Когда |
|---|---|
| 0 | поставлено (R36) или движок образа на месте (R32) |
| 1 | нет библиотеки `l4t`, нет источника `jetson/common`, apt не прошёл, `libnvdla_compiler.so` не виден загрузчику; R32 — нет `libnvinfer8`, `trtexec` или `libnvinfer.so.8` |
| 20 | нет `/etc/nv_tegra_release` — не Jetson, ставить неоткуда (до apt) |

## Проверки

- **V** — `make cream-validate`, `tools/check-names.sh`.
- **H** — `tests/test-tensorrt.sh`: код 20 без L4T, отказ без библиотеки и без источника,
  R36 (пакеты, `ldconfig`, отказ без `libnvdla_compiler.so`, повтор, пакеты до cream),
  R32 (без установки, Python-модуль есть/нет, отказы), `remove` (свой, повтор, отказ при
  чужих зависимых). Библиотека `l4t` в тесте — настоящий `l4t.sh` в подменённом корне.
- **P — ожидает.** Платы Jetson в CI нет: установка на живой плате (R36 — AGX Orin,
  R32 — Nano) через `cream install` или сборка образа через bisquite проверяются
  вручную после плана bisquite (Task 22 плана 2026-10-19 cream-v1-migration).
- **L** — не нужен: в контейнере нет `/etc/nv_tegra_release`, ответ — код 20, его
  проверяет H.
