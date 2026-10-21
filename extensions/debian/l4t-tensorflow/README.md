# l4t-tensorflow

TensorFlow 2.16.1 с CUDA для Jetson (JetPack 6, L4T 36.4): колесо NVIDIA,
cuDNN 9 и keras 3.3.3.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | arm64 |
| cream | ≥ 1.0.0 |
| Даёт | `tensorflow` |
| Требует | `cuda` |
| Зависит от | [`apt-guard`](../apt-guard/README.md) |
| Конфликтует с | — |
| Хуки | `install`, `remove` |
| Настройка на загрузке | — |
| Живая машина | да |
<!-- /catalog:facts -->

## Что делает

- **`install`** — ставит пакеты из таблицы ниже. Нет `/etc/nv_tegra_release`
  (не Jetson) — код **20** до apt, а не отказ 1. Временный каталог — `/var/tmp`.
  `pip` — только по хешам `requirements.txt` из дерева расширения (как и почему —
  «Хеши PyPI» в [README l4t-pytorch](../l4t-pytorch/README.md)), под root в
  `/usr/local`, с `HOME` во временном каталоге и без конфигурации pip
  (`PIP_CONFIG_FILE=/dev/null`): в домашний каталог root ничего не пишется.
  Загрузки NVIDIA сверяются по sha256. В дереве (`/opt/cream/ext/l4t-tensorflow/`)
  лежат `requirements.txt`, `check-system-python.py`, `pip-owned.py`.
- **`remove`** — снимает своё (см. «Что снимает `remove`»).

| Что | Версия | Откуда |
|---|---|---|
| tensorflow | 2.16.1 nv24.08 | CDN NVIDIA, sha256 закреплён (и для pip — файлом с хешем) |
| keras | 3.3.3 | PyPI — та, с которой вышел TF 2.16; pip сам взял бы 3.12 |
| cuDNN | 9.3 | apt |
| numpy / scipy | 1.26.4 / 1.13.1 | PyPI, те же, что у `l4t-pytorch` |
| остальное | `requirements.txt` | PyPI, по хешам (`--require-hashes`) |

`requires: cuda` — TF грузит библиотеки тулкита (поставщик —
[`cuda-toolkit`](../cuda-toolkit/README.md)). Конфликта с `l4t-pytorch` нет: оба
делят numpy 1.26.4 и scipy 1.13.1.

| Код `install` | Когда |
|---|---|
| 0 | поставлено |
| 1 | нет `/usr/local/cuda/lib64`, Python не 3.10, apt или pip не прошли, sha256 не совпал, проверка импорта или системного Python не прошла |
| 20 | нет `/etc/nv_tegra_release` — не Jetson, ставить неоткуда (до apt) |

## Параметры

<!-- catalog:params -->
Параметров нет.
<!-- /catalog:params -->

## Установка

На живой плате Jetson (`cuda` — поставщик `requires`, ставится раньше):

```bash
sudo cream install --with-deps l4t-tensorflow
sudo cream remove l4t-tensorflow
```

В образе bisquite (VMFILE), после `cuda-toolkit`:

```dockerfile
RUN_COMMAND cream install --with-deps cuda-toolkit
RUN_COMMAND cream install --with-deps l4t-tensorflow
```

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | apt (cuDNN), колесо NVIDIA и `requirements.txt` через pip, проверка импорта и системного Python |
| `cream remove` | свои pip-дистрибутивы и apt-пакеты, кроме нужных другим |

## Известные ограничения

- **Это последняя версия.** NVIDIA публикует TF для Jetson на
  `developer.download.nvidia.com/compute/redist/jp/`, и последний каталог с ним —
  `v61` (август 2024); `v62` нет. Индекс jetson-ai-lab под именем `tensorflow`
  отдаёт обычные колёса PyPI (cp313, без CUDA для Jetson). Новых сборок TF под
  Jetson не выходит.
- Ветки R32 нет: колеса под Python 3.8 и CUDA 10.2 не существует, на Nano `install`
  откажет проверкой Python (или CUDA).
- Весит 1.9 ГБ в образе — поэтому в `jetson-orin-base.vmfile` не включено по
  умолчанию.

## Подробности

### Зачем

Сегодня на Jetson модели обычно обучают в PyTorch, а на устройстве
запускают через ONNX → TensorRT. TF остаётся для уже написанного кода
и моделей на TF/Keras — этот случай расширение и закрывает.

Проверено на плате 2026-09-14: обучение модели Keras на GPU, и вместе
в одном процессе с torch, torchvision, `cv2` и TensorRT.

### Сторож системного Python

Тот же, что у `l4t-pytorch`, и по той же причине — см. его
[README](../l4t-pytorch/README.md). Поверх apt TF законно перекрывает семь пакетов:
`gast`, `markupsafe`, `mpmath`, `numpy`, `protobuf`, `scipy`, `sympy`. `markupsafe` —
зависимость `jinja2` у cloud-init; с 3.0.3 cloud-init шаблоны рендерит (проверено).
`requests`, `urllib3`, `idna`, `certifi` в `requirements.txt` не закреплены
намеренно: apt-овые версии TF устраивают, и перекрывать их незачем.

### Что снимает `remove`

`install` записывает в `/var/lib/cream/ext/l4t-tensorflow/` только своё:
`packages` — apt-пакеты, которых не было; `pip` — дистрибутивы, появившиеся в
`/usr/local` за установку (и при отказе на полпути). `remove` сначала спрашивает apt
в режиме симуляции (чужие зависимые — отказ до изменений, `cream remove --forget
l4t-tensorflow`), затем `pip uninstall` своих, кроме нужных другим (`numpy`,
`scipy` при `l4t-pytorch`, `pip-owned.py` — тот же файл, что у `l4t-pytorch`), и
`apt-get remove` своих; `libcudnn9-cuda-12` и `python3-pip` остаются, пока в
`/usr/local` стоит `torch`.

## Проверки

- **V** — `make cream-validate`, `tools/check-names.sh`.
- **H** — `tests/test-l4t-tensorflow.sh`: код 20, отказы до apt (CUDA, Python),
  установка (каждый `pip install` — `--require-hashes -r requirements.txt`, колесо TF
  файлом с sha256, у каждой строки `requirements.txt` есть `==` и sha256, `HOME` не root, записи),
  отказы (sha256, импорт, системный Python; запись pip и при отказе), `remove`
  (своё, чужое, при `l4t-pytorch`, отказ при чужих зависимых).
- **P — ожидает.** Платы Jetson в CI нет: установка на живой плате (AGX Orin, R36) через
  `cream install` или сборка образа через bisquite проверяются вручную.
- **L** — не нужен: в контейнере нет `/etc/nv_tegra_release`, ответ — код 20, его
  проверяет H.
