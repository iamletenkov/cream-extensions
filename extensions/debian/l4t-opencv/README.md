# l4t-opencv

OpenCV 4.8.0 для Jetson из репозитория NVIDIA: `cv2` с бэкендом
GStreamer, FFmpeg и V4L2. **Без CUDA.** На L4T R32 (Jetson Nano) ничего не
ставит — проверяет `cv2` образа и закрепляет `OPENBLAS_CORETYPE=ARMV8`.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | arm64 |
| cream | ≥ 1.0.0 |
| Даёт | `opencv` |
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
  общий — `l4t_major` библиотеки [`l4t`](../l4t/README.md) (файл читается как
  данные).
  - **R36** — ставит `libopencv` и `libopencv-python` (оба явно, см. «Что
    ставится»), проверяет `import cv2` и бэкенд GStreamer. Пакеты, которых до
    него не было, записывает в `/var/lib/cream/ext/l4t-opencv/packages`; повтор
    (`--reinstall`) запись не меняет.
  - **R32** — ничего не ставит (см. «Ветка R32»).
- **`configure`** — нет: на загрузке доделывать нечего. Бэкенд GStreamer в
  `cv2` работает на голом libgstreamer; аппаратный путь с камер (`nvvidconv`)
  даёт [`l4t-gstreamer`](../l4t-gstreamer/README.md), но импорту он не нужен.
- **`remove`** — через библиотеку [`apt-guard`](../apt-guard/README.md) сначала
  спрашивает apt в режиме симуляции: если вместе со своими пакетами apt снял бы
  и чужие, хук отказывает и ничего не меняет — снимите руками или
  `cream remove --forget l4t-opencv`. Иначе — `apt-get remove` своих пакетов.
  На R32 (отметка `openblas`) снимается drop-in
  `/etc/systemd/system.conf.d/l4t-opencv.conf`, а строка
  `OPENBLAS_CORETYPE=ARMV8` в `/etc/environment` — только если её больше не
  несёт ни один drop-in (`l4t-pytorch`); символическая ссылка на месте
  `/etc/environment` не трогается.

| Код `install` | Когда |
|---|---|
| 0 | поставлено (R36) или `cv2` образа на месте (R32) |
| 1 | нет библиотеки `l4t`, apt не прошёл, `import cv2` не прошёл, `cv2` без GStreamer; R32 — без CUDA или импорт с окружением из файлов не прошёл |
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
sudo cream install --with-deps l4t-opencv
sudo cream remove l4t-opencv
```

В образе bisquite (VMFILE) — основной путь:

```dockerfile
RUN_COMMAND cream install --with-deps l4t-opencv
```

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | R36 — пакеты NVIDIA и проверка `cv2`; R32 — проверка `cv2` образа и закрепление `OPENBLAS_CORETYPE`; не Jetson — код 20 |
| загрузка | ничего: `configure` нет |
| `cream remove` | свои пакеты, если apt не снимет с ними чужих; на R32 — закрепление `OPENBLAS_CORETYPE`, пока оно не нужно другому расширению |

## Известные ограничения

- **Нет CUDA**: модуля `cv2.cuda` в этой сборке нет (см. «Чего нет: CUDA»).
- **Для C++ заголовки — убунтовские 4.5.4**, не 4.8.0 (см. «Два OpenCV в образе»).
- Падает ли импорт на R32 без `OPENBLAS_CORETYPE`, на сборке не проверить:
  appliance видит CPU машины сборки.
- Установка на живой плате и сборка образа проверяются вручную: платы Jetson в
  CI нет.

## Подробности

### Ветка R32 (Jetson Nano, JetPack 4.6)

В образе Q-engineering OpenCV 4.8.0 уже собран — **с CUDA 10.2** и GStreamer
1.16.3. Ничего не ставится; проверяется `import cv2` и строки
`NVIDIA CUDA: YES` и `GStreamer: YES` в `cv2.getBuildInformation()`.

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

### Что ставится

`libopencv` и `libopencv-python` — оба явно. `libopencv-python` от NVIDIA
не объявляет зависимость от собственных библиотек: apt ставит один `cv2`,
и импорт падает с `libopencv_ml.so.408: cannot open shared object file`
(замер на плате 2026-09-14).

### Кадры с камеры в cv2 через аппаратный nvvidconv

Проверено на плате: 30 кадров 1920×1080 с камеры Sensing.

```python
import cv2

pipeline = (
    "v4l2src device=/dev/video6 ! video/x-raw,format=UYVY,width=1920,height=1080 "
    "! nvvidconv ! video/x-raw,format=BGRx ! videoconvert ! video/x-raw,format=BGR ! appsink"
)
cap = cv2.VideoCapture(pipeline, cv2.CAP_GSTREAMER)
ok, frame = cap.read()  # frame.shape == (1080, 1920, 3)
```

### Чего нет: CUDA

Модуля `cv2.cuda` в этой сборке нет. CUDA-сборка OpenCV под JetPack 6
готовой есть только в индексе jetson-ai-lab, а из сети сборки он файлы
не отдаёт: замер 2026-09-14 — каждая загрузка обрывается на 15 865 байтах
при 25 Б/с, при том что страница индекса отвечает. Своя сборка из
исходников — час-два компиляции на каждую пересборку образа.

На Jetson это обычно не мешает: преобразование кадра (масштаб, цвет) делает
`nvvidconv` на аппаратном блоке ещё до `cv2`, а сеть считают TensorRT или
PyTorch. Если нужны именно GPU-операции над изображениями — у NVIDIA для
этого VPI (`nvidia-vpi`, `python3.10-vpi3` в том же репозитории), в это
расширение он не входит.

### Два OpenCV в образе — и ловушка для C++

В образе остаётся убунтовский OpenCV 4.5.4 (`libopencv-*4.5d` и
`libopencv-dev`): его тянет `libgstreamer-plugins-bad1.0-dev`. Для Python
это не важно — `import cv2` отдаёт 4.8.0 от NVIDIA. Для C++ важно:
**`pkg-config opencv4` и `/usr/include/opencv4` — это 4.5.4.**

`libopencv-dev` от NVIDIA поставить нельзя: он объявлен `Conflicts`
с убунтовским, и apt снёс бы вместе с ним `libgstreamer-plugins-bad1.0-dev`
(симуляция удаляла 19 пакетов `-dev`).

## Проверки

- **V** — `make cream-validate`, `tools/check-names.sh`.
- **H** — `tests/test-l4t-opencv.sh`: код 20 без L4T, отказ без библиотеки, R36
  (пакеты, повтор, отказы импорта и GStreamer), R32 (закрепление и проверка с
  окружением из файлов — заглушка `cv2` через `PYTHONPATH` из файлов корня; без CUDA;
  без `cv2`), `remove` (чужой пакет, повтор, отказ при чужих зависимых, снятие
  OPENBLAS при `l4t-pytorch` и при ссылке).
- **P — ожидает.** Платы Jetson в CI нет: установка на живой плате (R36 — AGX Orin, R32 — Nano) через
  `cream install` или сборка образа через bisquite проверяются вручную.
- **L** — не нужен: в контейнере нет `/etc/nv_tegra_release`, ответ — код 20, его
  проверяет H.
