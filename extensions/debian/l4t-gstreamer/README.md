# l4t-gstreamer

GStreamer для Jetson (L4T 36.4): аппаратные плагины NVIDIA плюс набор
убунтовского GStreamer, нужный роботу, — камеры, RTSP, WebRTC, запись,
Python-конвейеры.

```
EXTENSION l4t-gstreamer                         # образ bisquite (основной путь)
sudo cream install l4t-gstreamer                # живая плата Jetson; l4t — по depends
sudo cream install l4t-gstreamer GSTREAMER_DEV=0
sudo cream remove l4t-gstreamer
```

> **2.0.0 — cream/v1.** `install.sh` стал хуком `hooks/install`, появился хук `remove`;
> `live: yes`. Каталог в госте — `/opt/cream/ext/l4t-gstreamer/`. Общий код L4T —
> библиотека [`l4t`](../l4t/README.md) (`depends: l4t >=1.0.0 <2`) вместо общего
> L4T-файла из `lib/` layout 2. Нет `/etc/nv_tegra_release` (не Jetson) — код **20** до apt (рулинг Р11),
> а не отказ 1. Ключ `GSTREAMER_DEV` прежний, без переименования, теперь это
> `config.keys` (`enum:0,1`, `scope: install`: смена через `cream set` — повтор
> `install`). Версии пакетов из dpkg сверяются с алфавитом версий Debian до того,
> как попасть в аргументы apt.

## Ветка R32 (Jetson Nano, JetPack 4.6) — с 1.2.0

Ветка выбирается по первой строке `/etc/nv_tegra_release` (`# R32 …`),
разбор общий — `l4t_major` библиотеки `l4t` (файл читается как данные).

На R32 **ничего не ставится**: репозитории NVIDIA в образе Q-engineering
отключены при апгрейде на focal, а плагины уже есть. Проверяется:

- пакет `nvidia-l4t-gstreamer` той же ревизии, что `nvidia-l4t-core` —
  по версии **до дефиса**: суффикс у R32 — дата сборки, и у одного стека он
  разный (`32.6.1-20210726122000` против `32.6.1-20210916211029`);
- **файлы** `libgstnvvideo4linux2.so`, `libgstnvvidconv.so`,
  `libgstnvarguscamerasrc.so` — не `gst-inspect-1.0`, довод ниже;
- нет `libgstnice.so` — предупреждение, не отказ: `webrtcbin` без него
  соединения не установит, а ставить на R32 нечем.

`GSTREAMER_DEV` на R32 ничего не меняет.

Проверено на живом Nano (L4T R32.6.1, 2026-09-15) прогоном установки (1.2.0) на работающей системе.

## Манифест

| Поле | Значение |
|---|---|
| `targets` | `build: exec`, `live: yes` |
| `platform.arch` | `arm64` |
| `provides` | `gstreamer`, `hw-video-codec` |
| `depends` | `l4t >=1.0.0 <2` (библиотека) |
| `hooks` | `install` (30 мин), `remove` |
| `config.keys` | `GSTREAMER_DEV` |

## Зачем, если в рабочей станции GStreamer уже был

Убунтовский GStreamer приехал в рабочую станцию (тогда `jetson-orin-workstation`) случайно —
зависимостями GNOME и dev-пакетов. Безголовый робот поверх
тогдашнего `jetson-orin-camera` его не получил бы. И даже в рабочей станции (замер
на плате 2026-09-14) не было двух ключевых вещей:

- **`nvidia-l4t-gstreamer`** — нет `nvv4l2h264enc`/`nvv4l2h265enc`,
  `nvvidconv`, `nvarguscamerasrc`. Аппаратный кодек Orin простаивал,
  видео можно было жать только программным `x264enc`;
- **`gstreamer1.0-nice`** — `webrtcbin` регистрируется и виден
  в `gst-inspect-1.0`, но падает на первом же соединении: ICE ему нечем
  делать.

## Что ставится

| Группа | Пакеты | Зачем |
|---|---|---|
| NVIDIA | `nvidia-l4t-gstreamer` (версия = `nvidia-l4t-core`) | `nvv4l2h264enc`/`h265enc`/`decoder`, `nvvidconv`, `nvarguscamerasrc`, `nvv4l2camerasrc`, `nvcompositor`, `nvjpegenc`/`dec`, `nveglglessink` |
| ядро | `gstreamer1.0-tools`, `-plugins-base/good/bad/ugly`, `-libav` | `gst-launch-1.0`, `v4l2src`, `x264enc`, `avdec_*`, `splitmuxsink`, `srtsrc`, `rtmpsink`, `hlssink2` |
| экран | `gstreamer1.0-x`, `-gl` | `ximagesrc` (захват рабочего стола), `glimagesink` |
| звук | `gstreamer1.0-alsa`, `-pulseaudio` | `alsasrc`, `pulsesrc` |
| RTSP | `gstreamer1.0-rtsp`, `libgstrtspserver-1.0-0`, `gir1.2-gst-rtsp-server-1.0` | раздавать камеры по RTSP, в том числе из Python |
| WebRTC | `gstreamer1.0-nice` | ICE для `webrtcbin` |
| Python | `python3-gi`, `python3-gst-1.0`, `gir1.2-gstreamer-1.0`, `gir1.2-gst-plugins-base-1.0`, `gir1.2-gst-plugins-bad-1.0` | `Gst`, `GstWebRTC`, `GstSdp`, `GstRtspServer` |
| отладка | `v4l-utils` | `v4l2-ctl`: форматы и контролы камер |
| dev (`GSTREAMER_DEV=1`) | `libgstreamer1.0-dev`, `libgstreamer-plugins-base/bad1.0-dev`, `libgstrtspserver-1.0-dev`, `nvidia-l4t-jetson-multimedia-api` | свои приложения на C/C++, Jetson Multimedia API |

## Версия плагинов NVIDIA — по стеку, а не по apt

Репозиторий `r36.4` публикует обновления одной веткой: на 2026-09-14
кандидат `nvidia-l4t-gstreamer` — 36.4.7, а стек в образе — 36.4.3.
Зависимости у пакета мягкие (`nvidia-l4t-multimedia (>= 36.3.0)`), поэтому
apt без возражений поставил бы плагин 36.4.7 поверх `libnvbufsurface`
36.4.3. Расширение берёт ровно версию `nvidia-l4t-core`; нет её
в репозитории — отказ на сборке, а не смешанный стек. После установки
версия `nvidia-l4t-core` сверяется ещё раз.

## Проверено на плате (AGX Orin, 2026-09-14)

```bash
# тестовый поток 1080p → аппаратный H.264, 10 с
gst-launch-1.0 -e videotestsrc num-buffers=300 ! video/x-raw,width=1920,height=1080,framerate=30/1 \
  ! nvvidconv ! 'video/x-raw(memory:NVMM),format=NV12' ! nvv4l2h264enc ! h264parse ! mp4mux ! filesink location=t.mp4

# рабочий стол 3840×2160 → аппаратный H.264
DISPLAY=:0 gst-launch-1.0 -e ximagesrc use-damage=0 num-buffers=150 ! video/x-raw,framerate=30/1 \
  ! videoconvert ! nvvidconv ! 'video/x-raw(memory:NVMM),format=NV12' ! nvv4l2h264enc ! h264parse ! mp4mux ! filesink location=desk.mp4

# камера Sensing 1920×1080 → аппаратный H.265
gst-launch-1.0 -e v4l2src device=/dev/video6 num-buffers=150 ! video/x-raw,format=UYVY,width=1920,height=1080,framerate=30/1 \
  ! nvvidconv ! 'video/x-raw(memory:NVMM),format=NV12' ! nvv4l2h265enc ! h265parse ! mp4mux ! filesink location=cam.mp4
```

## Про Selkies и удалённый рабочий стол

Selkies (WebRTC-рабочий стол на GStreamer) с этим набором запускается:
`ximagesrc`, `webrtcbin`, `nicesrc`, `x264enc`, `opusenc`, `pulsesrc`
на месте. **Аппаратного кодирования он на Jetson сам не выберет:** его
аппаратные кодеры — `nvh264enc` (NVENC дискретных карт NVIDIA) и VA-API,
а на Jetson кодек — `nvv4l2h264enc`, другой элемент с другими свойствами.
Без правки конвейера Selkies пойдёт программным `x264enc`. Что аппаратный
путь для захвата экрана на Orin работает, показывает второй конвейер
выше — 4K рабочего стола через `nvv4l2h264enc`.

Сам Selkies (Python-пакет и веб-клиент) расширение не ставит.

## Внутри сборки `gst-inspect-1.0` не зовётся

В `virt-customize` гость не загружен: нет `/dev/nvhost-*` и
`/dev/v4l2-nvenc`, и плагины NVIDIA при сканировании реестра отваливаются
по причинам, которых на плате не будет. Проверка идёт по файлам плагинов
в `/usr/lib/aarch64-linux-gnu/gstreamer-1.0/`.

## Настройки

| Ключ | Тип | Умолчание | Что делает |
|---|---|---|---|
| `GSTREAMER_DEV` | `enum:0,1` | `1` | `0` — без заголовков GStreamer и Jetson Multimedia API (роботу в поле не нужны) |

## Что снимает `remove`

`install` записывает в `/var/lib/cream/ext/l4t-gstreamer/packages` только пакеты, которых
до него не было; повторный `install` (`--reinstall`) запись не меняет. `remove`
сначала спрашивает apt в режиме симуляции (`apt-get -s remove`): если вместе со
своими пакетами apt снял бы и чужие (от них зависит поставленное позже), хук
отказывает и ничего не меняет — снимите руками или `cream remove --forget l4t-gstreamer`.
Иначе — `apt-get remove` своих пакетов. Пакеты, стоявшие до cream, остаются.
Стек L4T (`nvidia-l4t-core` и его ветка) не снимается никогда — его ставил
базовый образ. На R32 `install` ничего не ставит, и `remove` ничего не снимает.

## Коды выхода `install`

| Код | Когда |
|---|---|
| 0 | поставлено (R36) или плагины образа на месте (R32) |
| 1 | неверный `GSTREAMER_DEV`, нет библиотеки `l4t`, нет `nvidia-l4t-core`, нужной версии плагинов нет в репозитории, apt не прошёл, не хватает файлов плагинов, стек сдвинулся при установке; R32 — нет пакетов, разошлись ревизии, нет плагинов |
| 20 | нет `/etc/nv_tegra_release` — не Jetson, ставить неоткуда (до apt) |

## Проверки

- **V** — `make cream-validate`, `tools/check-names.sh`.
- **H** — `tests/test-l4t-gstreamer.sh`: код 20 без L4T, отказы до apt (ключ,
  библиотека, стек, версия с чужими символами), R36 с dev и без, версия плагинов по
  стеку, отказы после `apt-get update` (нет версии, нет плагина, стек сдвинулся),
  R32 (без установки, ревизии, плагины, libnice), `remove` (чужой пакет и стек не
  снимаются, повтор, отказ при чужих зависимых).
- **P — ожидает.** Платы Jetson в CI нет: установка на живой плате (R36 — AGX Orin,
  R32 — Nano) через `cream install` или сборка образа через bisquite проверяются
  вручную после плана bisquite (Task 22 плана 2026-10-19 cream-v1-migration).
- **L** — не нужен: в контейнере нет `/etc/nv_tegra_release`, ответ — код 20, его
  проверяет H.
