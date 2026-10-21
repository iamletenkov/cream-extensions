# l4t-pytorch

PyTorch и torchvision с CUDA для Jetson (JetPack 6, L4T 36.4, Orin). На Jetson
Nano (L4T R32) проверяет PyTorch, уже собранный в образе.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | arm64 |
| cream | ≥ 1.0.0 |
| Даёт | `pytorch` |
| Требует | `cuda` |
| Зависит от | [`l4t`](../l4t/README.md), [`apt-guard`](../apt-guard/README.md) |
| Конфликтует с | — |
| Хуки | `install`, `remove` |
| Настройка на загрузке | — |
| Живая машина | да |
<!-- /catalog:facts -->

## Что делает

- **`install`** — нет `/etc/nv_tegra_release` (не Jetson) — код **20** до apt.
  Ветка выбирается по первой строке `/etc/nv_tegra_release`, разбор общий —
  `l4t_major` библиотеки [`l4t`](../l4t/README.md) (файл читается как данные).
  - **R36** — ставит (см. «Что ставится и откуда») колесо torch NVIDIA, cuDNN и
    cuSPARSELt, собирает torchvision из исходников с CUDA (`nvcc` даёт поставщик
    `cuda`, обычно `cuda-toolkit`; он же даёт библиотеки тулкита для torch), ставит
    pip-зависимости только по хешам `requirements.txt` из дерева расширения (см.
    «Хеши PyPI») под root в `/usr/local`, с `HOME` во временном каталоге и без
    конфигурации pip (`PIP_CONFIG_FILE=/dev/null`): в домашний каталог root ничего
    не пишется. Загрузки NVIDIA сверяются по sha256. Временный каталог сборки —
    `/var/tmp`, cuSPARSELt распаковывается рядом и подменяется переименованием.
    После установки — проверка импорта и сторож системного Python
    (`check-system-python.py`).
  - **R32** — ничего не ставит, проверяет torch образа и пишет
    `OPENBLAS_CORETYPE=ARMV8` (см. «Ветка R32»).

  Записывает в `/var/lib/cream/ext/l4t-pytorch/` только своё: `packages` —
  apt-пакеты, которых не было; `pip` — дистрибутивы, появившиеся в `/usr/local` за
  установку (и при отказе на полпути; учёт — `pip-owned.py`); `cusparselt`;
  `openblas` (R32). Повтор (`--reinstall`) записи не меняет.
- **`remove`**:
  1. спрашивает apt в режиме симуляции — если вместе со своими пакетами он снял бы
     чужие, отказ до любых изменений (`cream remove --forget l4t-pytorch` или руками);
  2. `pip uninstall` своих дистрибутивов, кроме тех, что ещё нужны другим в
     `/usr/local` (`numpy`, `scipy` при `l4t-tensorflow`) — `pip-owned.py removable`;
  3. `apt-get remove` своих пакетов; `libcudnn9-cuda-12` и `python3-pip` остаются,
     пока в `/usr/local` стоит `tensorflow`;
  4. `/usr/local/cusparselt` и `/etc/ld.so.conf.d/cusparselt.conf`, `ldconfig`;
  5. R32 — drop-in `l4t-pytorch.conf`, строка `/etc/environment` — если её больше не
     несёт ни один drop-in (`l4t-opencv`).

Коды выхода `install`:

| Код | Когда |
|---|---|
| 0 | поставлено (R36) или torch образа на месте (R32) |
| 1 | неверный `TORCH_CUDA_ARCH_LIST`, нет библиотеки `l4t`, нет `nvcc`, Python не 3.10, sha256 не совпал, тег torchvision передвинут, сборка или pip не прошли, проверка импорта или системного Python не прошла; R32 — torch без CUDA |
| 20 | нет `/etc/nv_tegra_release` — не Jetson, ставить неоткуда (до apt) |

## Параметры

<!-- catalog:params -->
| Ключ | Тип | Умолчание | Что задаёт |
|---|---|---|---|
| `TORCH_CUDA_ARCH_LIST` | строка `^[0-9]+\.[0-9]+(\+PTX)?(;[0-9]+\.[0-9]+(\+PTX)?)*$` | `8.7` | вычислительные архитектуры сборки torchvision; 8.7 — Ampere в Orin (единственная в JetPack 6) *(только при установке)* |
<!-- /catalog:params -->

`TORCH_CUDA_ARCH_LIST` (`scope: install`) — `8.7` или `7.2;8.7`, допускается `+PTX`;
8.7 — Ampere во всех Orin, другой JetPack 6 не поддерживает. На R32 не используется.

## Установка

На плате Jetson с подключённым каталогом ([как подключить](../../../docs/getting-started.md));
`l4t` — по `depends`, `cuda` — поставщик `requires`:

```bash
sudo cream install --with-deps l4t-pytorch
sudo cream remove l4t-pytorch
```

В образе bisquite (VMFILE; основной путь) — после `cuda-toolkit`:

```dockerfile
RUN_COMMAND cream install --with-deps l4t-pytorch
```

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` (R36) | apt, cuSPARSELt, колесо torch, сборка torchvision, pip по хешам, проверки |
| сборка образа / `cream install` (R32) | проверка torch образа, `OPENBLAS_CORETYPE=ARMV8` |
| загрузка | ничего: хука `configure` нет |
| `cream remove` | своё снято, чужое и нужное соседям оставлено |

## Известные ограничения

- Только arm64: колесо torch — сборка NVIDIA под JetPack; колесо PyPI для aarch64
  без CUDA.
- Версия torch — 2.5.0 nv24.08 (см. «Почему не новее»).
- `requires: [cuda]` на R32 не выполняется и не нужен — CUDA в образе.
- Сборка torchvision в appliance bisquite с ресурсами по умолчанию долгая (см.
  «Почему torchvision из исходников»).
- Падает ли импорт без `OPENBLAS_CORETYPE` на R32, на сборке не проверить.
- Установка на живой плате R36 через `cream install` и сборка образа через bisquite
  в CI не проверяются: платы Jetson в CI нет.

## Подробности

### Что ставится и откуда

| Что | Версия | Откуда |
|---|---|---|
| torch | 2.5.0 nv24.08 | CDN NVIDIA, колесо под JetPack 6.1 (CUDA 12.6), sha256 закреплён |
| torchvision | 0.20.0 | **исходники** с GitHub (тег сверяется с коммитом), сборка с CUDA 8.7 |
| cuDNN | 9.3 | apt, `libcudnn9-cuda-12` |
| cuSPARSELt | 0.6.2.3 | архив NVIDIA redist `linux-aarch64`, sha256 закреплён, в `/usr/local/cusparselt` |
| numpy / scipy | 1.26.4 / 1.13.1 | PyPI, по хешам |
| sympy, networkx, filelock, fsspec, mpmath, typing_extensions, pillow | `requirements.txt` | PyPI, по хешам |

Проверено на плате 2026-09-14: `torch.cuda.is_available()`, свёртка на GPU,
`torchvision.ops.nms` на `cuda:0`, `resnet18` на GPU, мост numpy↔CUDA,
и вместе в одном процессе с `cv2` 4.8.0, TensorRT 10.3 и TensorFlow 2.16.

### Ветка R32 (Jetson Nano, JetPack 4.6)

В образе Q-engineering PyTorch 1.13 и torchvision 0.14 уже собраны с CUDA
10.2 под Python 3.8. Ничего не ставится (всё про колесо 2.5.0, cuSPARSELt
и сборку torchvision — только r36); `requires: [cuda]` на R32 не
выполняется и не нужен — CUDA в образе. Проверяются импорт `numpy`, `torch`,
`torchvision`, версии и `torch.version.cuda`; `torch.cuda.is_available()` —
нет, GPU в appliance нет.

**`OPENBLAS_CORETYPE=ARMV8`.** На Cortex-A57 OpenBLAS из numpy выбирает ядро,
которого у процессора нет, и `import numpy`/`cv2`/`torch` падают `Illegal
instruction` (замер на Nano: rc=132). Вендорский образ экспортировал
переменную из `.bashrc` учётки `jetson`, которую цепочка удаляет. Ветка R32
пишет её в `/etc/environment` (входы) и
`/etc/systemd/system.conf.d/<имя расширения>.conf` (`DefaultEnvironment=`,
службы) — идемпотентно, `l4t-opencv` и `l4t-pytorch` одним способом.
Проверка **не экспортирует переменную сама**: окружение собирается из
записанных файлов так, как их прочтут pam_env и systemd, и импорт идёт под
`env -i` с ним — опечатка в имени файла или ключа дала бы отказ. Падает ли
импорт без переменной, на сборке не проверить: appliance видит CPU машины
сборки (на AGX — Cortex-A78AE).

Проверено на живом Nano (L4T R32.6.1, 2026-09-15) прогоном установки на
работающей системе (до перехода на cream/v1).

### Почему не новее

torch 2.8–2.10 с готовым torchvision под Jetson есть только в индексе
jetson-ai-lab, а из сети сборки он файлы не отдаёт (замер 2026-09-14:
каждая загрузка обрывается на 15 865 байтах). 2.5.0 nv24.08 — последнее,
что NVIDIA публикует на своём CDN: каталог `jp/v61/pytorch/` есть,
`jp/v62/` — нет.

### Почему torchvision из исходников

NVIDIA его под JetPack 6 не публикует, а колесо с PyPI собрано под
PyPI-torch, и его C++-операции с torch от NVIDIA несовместимы по ABI.
Сборка на самой плате (12 ядер) — 128 с.

**Внутри `bs image build` ресурсы appliance по умолчанию — 1 vCPU и 2 ГБ.**
Сборка пройдёт и так (число потоков компиляции расширение считает по
памяти, по ~1.5 ГБ на поток, чтобы не словить OOM; `/proc/meminfo` сверяется
с числом до арифметики), но долго. С ресурсами —
быстрее:

```bash
bs image build --smp 8 --memsize 16000 -f jetson-orin-base.vmfile ...
```

### numpy 1.26.4 перекрывает системный — и почему это правильно

torch nv24.08 собран под C-API numpy 0x10 (ветка 1.23+), а в jammy numpy
1.21.5. С системным numpy torch импортируется и считает на GPU, но любой
мост torch↔numpy падает: `RuntimeError: Numpy is not available`. 1.26.4 —
последняя 1.x; модули apt, собранные под 1.21 (Gst, jtop, TensorRT, cv2),
с ней работают — проверено. Вместе с numpy поднимается scipy: apt-овый
1.8.0 (его тянут matplotlib и pandas) с numpy 1.26 предупреждает на каждом
импорте.

### Хеши PyPI (`--require-hashes`)

Всё, что `pip` берёт из сети, проверяется по sha256: `requirements.txt` в дереве
расширения — каждый пакет закреплён `==` и несёт хеши всех файлов PyPI, которые
pip CPython 3.10 на linux-aarch64 (glibc 2.35) может выбрать, плюс sdist. Колесо
NVIDIA передаётся файлом с его sha256 (`<имя> @ file://… --hash=sha256:…`), и
`pip install --require-hashes -r requirements.txt -r <файл колеса>` ставит всё
одним вызовом. Зависимость, которой нет в файле и нет в системе, — отказ pip
«нет хеша», а не тихое скачивание свежей версии. Уже стоящим из apt пакетам
(`jinja2`, `requests`, `six`, `setuptools`, `wheel`) хеш не нужен — pip их не качает
(проверено на `pip` 22.0.2 Ubuntu 22.04).

Поднять версию или добавить пакет:

```sh
# 1. файл, который выберет плата (arm64, cp310), — из того же индекса PyPI
pip download --no-deps --only-binary=:all: --python-version 3.10 --implementation cp --abi cp310 \
  $(for m in $(seq 35 -1 17); do printf -- '--platform manylinux_2_%s_aarch64 ' "$m"; done) \
  --platform manylinux2014_aarch64 -d /tmp/wh 'numpy==1.26.4'
pip hash /tmp/wh/*            # этот хеш обязан попасть в requirements.txt
# 2. остальные файлы той же версии (другие теги aarch64, sdist) — digests.sha256 из
#    https://pypi.org/pypi/numpy/1.26.4/json
```

Правка файла — новый минор расширения; `tests/test-*.sh` проверяет, что у каждой
строки есть `==` и хотя бы один sha256.

### Сторож системного Python

pip под root ставит в `/usr/local`, и оттуда пакеты перекрывают apt-овые
для всех, кто зовёт `/usr/bin/python3`, — в том числе для cloud-init. Он
на первой загрузке создаёт пользователя и сеть, и сломанный cloud-init
на сборке не виден: образ собирается, плата приезжает без пользователя.

Поэтому:

- в `requirements.txt` закреплено **только то, что pip ставит в любом
  случае**. `jinja2` там нет: apt-овый 3.0.3 удовлетворяет torch, а
  закреплённая версия встала бы поверх — и cloud-init импортировал бы её;
- `check-system-python.py` после установки проверяет, что прямые
  зависимости cloud-init импортируются из apt, и что cloud-init рендерит
  jinja-шаблон. Нарушение — отказ сборки.

## Проверки

- **V** — `make cream-validate`, `tools/check-names.sh`.
- **H** — `tests/test-l4t-pytorch.sh`: `pip-owned.py` на фикстурах dist-info; код 20,
  отказы до apt (ключ, библиотека, `nvcc`, Python); R36 — apt, cuSPARSELt, каждый
  `pip install` из сети — `--require-hashes -r requirements.txt`, колесо torch файлом с
  sha256, torchvision — `--no-index --no-deps`; у каждой строки `requirements.txt` есть
  `==` и sha256; `HOME` не root, сборка torchvision с CUDA,
  `MAX_JOBS` по памяти и при мусоре в meminfo, отказы (sha256, коммит, сборка, импорт,
  системный Python), запись pip и при отказе; R32; `remove` (своё, чужое, при
  `l4t-tensorflow`, отказ при чужих зависимых).
- **P — ожидает.** Платы Jetson в CI нет: установка на живой плате (R36 — AGX Orin, R32 — Nano) через
  `cream install` или сборка образа через bisquite проверяются вручную.
- **L** — не нужен: в контейнере нет `/etc/nv_tegra_release`, ответ — код 20, его
  проверяет H.
