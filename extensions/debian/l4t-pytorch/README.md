# l4t-pytorch

PyTorch и torchvision с CUDA для Jetson (JetPack 6, L4T 36.4, Orin).

```
EXTENSION l4t-pytorch          # образ bisquite (основной путь), после cuda-toolkit
sudo cream install l4t-pytorch # живая плата Jetson; l4t — по depends, cuda — поставщик requires
sudo cream remove l4t-pytorch
```

> **2.0.0 — cream/v1.** `install.sh` стал хуком `hooks/install`, появился хук `remove`;
> `live: yes`. Каталог в госте — `/opt/cream/ext/l4t-pytorch/` (`constraints.txt`,
> `check-system-python.py`, `pip-owned.py` — в дереве расширения). Общий код L4T — библиотека [`l4t`](../l4t/README.md) (`depends: l4t >=1.0.0 <2`) вместо общего L4T-файла из `lib/` layout 2.
> Нет `/etc/nv_tegra_release` (не Jetson) — код **20** до apt (рулинг Р11), а не
> отказ 1. `TORCH_CUDA_ARCH_LIST` — прежнее имя, теперь ключ `config.keys`
> (`scope: install`). Временный каталог сборки — `/var/tmp`, cuSPARSELt распаковывается
> рядом и подменяется переименованием. `pip` — только с `constraints.txt` из дерева расширения, под root в `/usr/local`,
> с `HOME` во временном каталоге и без конфигурации pip (`PIP_CONFIG_FILE=/dev/null`):
> в домашний каталог root ничего не пишется. Загрузки NVIDIA сверяются по sha256.

## Ветка R32 (Jetson Nano, JetPack 4.6) — с 1.2.0

Ветка выбирается по первой строке `/etc/nv_tegra_release` (`# R32 …`),
разбор общий — `l4t_major` библиотеки `l4t` (файл читается как данные).

В образе Q-engineering PyTorch 1.13 и torchvision 0.14 уже собраны с CUDA
10.2 под Python 3.8. Ничего не ставится (всё про колесо 2.5.0, cuSPARSELt
и сборку torchvision ниже — только r36); `requires: [cuda]` на R32 не
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

Проверено на живом Nano (L4T R32.6.1, 2026-09-15) прогоном установки (1.2.0) на работающей системе.

## Манифест

| Поле | Значение |
|---|---|
| `targets` | `build: exec`, `live: yes` |
| `platform.arch` | `arm64` |
| `provides` | `pytorch` |
| `requires` | `cuda` — `nvcc` для сборки torchvision и библиотеки тулкита для torch |
| `depends` | `l4t >=1.0.0 <2` (библиотека) |
| `hooks` | `install` (4 ч — сборка torchvision в малом appliance), `remove` |
| `config.keys` | `TORCH_CUDA_ARCH_LIST` |

## Что ставится и откуда

| Что | Версия | Откуда |
|---|---|---|
| torch | 2.5.0 nv24.08 | CDN NVIDIA, колесо под JetPack 6.1 (CUDA 12.6), sha256 закреплён |
| torchvision | 0.20.0 | **исходники** с GitHub (тег сверяется с коммитом), сборка с CUDA 8.7 |
| cuDNN | 9.3 | apt, `libcudnn9-cuda-12` |
| cuSPARSELt | 0.6.2.3 | архив NVIDIA redist `linux-aarch64`, sha256 закреплён, в `/usr/local/cusparselt` |
| numpy / scipy | 1.26.4 / 1.13.1 | PyPI |
| sympy, networkx, filelock, fsspec, mpmath, typing_extensions | `constraints.txt` | PyPI |

Проверено на плате 2026-09-14: `torch.cuda.is_available()`, свёртка на GPU,
`torchvision.ops.nms` на `cuda:0`, `resnet18` на GPU, мост numpy↔CUDA,
и вместе в одном процессе с `cv2` 4.8.0, TensorRT 10.3 и TensorFlow 2.16.

## Почему не новее

torch 2.8–2.10 с готовым torchvision под Jetson есть только в индексе
jetson-ai-lab, а из сети сборки он файлы не отдаёт (замер 2026-09-14:
каждая загрузка обрывается на 15 865 байтах). 2.5.0 nv24.08 — последнее,
что NVIDIA публикует на своём CDN: каталог `jp/v61/pytorch/` есть,
`jp/v62/` — нет.

## Почему torchvision из исходников

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

## numpy 1.26.4 перекрывает системный — и почему это правильно

torch nv24.08 собран под C-API numpy 0x10 (ветка 1.23+), а в jammy numpy
1.21.5. С системным numpy torch импортируется и считает на GPU, но любой
мост torch↔numpy падает: `RuntimeError: Numpy is not available`. 1.26.4 —
последняя 1.x; модули apt, собранные под 1.21 (Gst, jtop, TensorRT, cv2),
с ней работают — проверено. Вместе с numpy поднимается scipy: apt-овый
1.8.0 (его тянут matplotlib и pandas) с numpy 1.26 предупреждает на каждом
импорте.

## Сторож системного Python

pip под root ставит в `/usr/local`, и оттуда пакеты перекрывают apt-овые
для всех, кто зовёт `/usr/bin/python3`, — в том числе для cloud-init. Он
на первой загрузке создаёт пользователя и сеть, и сломанный cloud-init
на сборке не виден: образ собирается, плата приезжает без пользователя.

Поэтому:

- в `constraints.txt` закреплено **только то, что pip ставит в любом
  случае**. `jinja2` там нет: apt-овый 3.0.3 удовлетворяет torch, а
  закреплённая версия встала бы поверх — и cloud-init импортировал бы её;
- `check-system-python.py` после установки проверяет, что прямые
  зависимости cloud-init импортируются из apt, и что cloud-init рендерит
  jinja-шаблон. Нарушение — отказ сборки.

## Настройки

| Ключ | Умолчание | Что делает |
|---|---|---|
| `TORCH_CUDA_ARCH_LIST` | `8.7` | архитектура CUDA для torchvision (`8.7` или `7.2;8.7`, допускается `+PTX`); 8.7 — Ampere во всех Orin, другой JetPack 6 не поддерживает |

## Что снимает `remove`

`install` записывает в `/var/lib/cream/ext/l4t-pytorch/` только своё: `packages` —
apt-пакеты, которых не было; `pip` — дистрибутивы, появившиеся в `/usr/local` за
установку (и при отказе на полпути); `cusparselt`; `openblas` (R32). Повтор
(`--reinstall`) записи не меняет. `remove`:

1. спрашивает apt в режиме симуляции — если вместе со своими пакетами он снял бы
   чужие, отказ до любых изменений (`cream remove --forget l4t-pytorch` или руками);
2. `pip uninstall` своих дистрибутивов, кроме тех, что ещё нужны другим в
   `/usr/local` (`numpy`, `scipy` при `l4t-tensorflow`) — `pip-owned.py removable`;
3. `apt-get remove` своих пакетов; `libcudnn9-cuda-12` и `python3-pip` остаются,
   пока в `/usr/local` стоит `tensorflow`;
4. `/usr/local/cusparselt` и `/etc/ld.so.conf.d/cusparselt.conf`, `ldconfig`;
5. R32 — drop-in `l4t-pytorch.conf`, строка `/etc/environment` — если её больше не
   несёт ни один drop-in (`l4t-opencv`).

## Коды выхода `install`

| Код | Когда |
|---|---|
| 0 | поставлено (R36) или torch образа на месте (R32) |
| 1 | неверный `TORCH_CUDA_ARCH_LIST`, нет библиотеки `l4t`, нет `nvcc`, Python не 3.10, sha256 не совпал, тег torchvision передвинут, сборка или pip не прошли, проверка импорта или системного Python не прошла; R32 — torch без CUDA |
| 20 | нет `/etc/nv_tegra_release` — не Jetson, ставить неоткуда (до apt) |

## Проверки

- **V** — `make cream-validate`, `tools/check-names.sh`.
- **H** — `tests/test-l4t-pytorch.sh`: `pip-owned.py` на фикстурах dist-info; код 20,
  отказы до apt (ключ, библиотека, `nvcc`, Python); R36 — apt, cuSPARSELt, каждый
  `pip install` с `constraints.txt`, `HOME` не root, сборка torchvision с CUDA,
  `MAX_JOBS` по памяти и при мусоре в meminfo, отказы (sha256, коммит, сборка, импорт,
  системный Python), запись pip и при отказе; R32; `remove` (своё, чужое, при
  `l4t-tensorflow`, отказ при чужих зависимых).
- **P — ожидает.** Платы Jetson в CI нет: установка на живой плате (R36 — AGX Orin, R32 — Nano) через
  `cream install` или сборка образа через bisquite проверяются вручную после плана
  bisquite (Task 23 плана 2026-10-19 cream-v1-migration).
- **L** — не нужен: в контейнере нет `/etc/nv_tegra_release`, ответ — код 20, его
  проверяет H.
