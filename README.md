# cream-extensions

[![CI](https://github.com/iamletenkov/cream-extensions/actions/workflows/ci-release.yml/badge.svg)](https://github.com/iamletenkov/cream-extensions/actions/workflows/ci-release.yml)
[![Выпуск](https://img.shields.io/github/v/release/iamletenkov/cream-extensions?label=%D0%B2%D1%8B%D0%BF%D1%83%D1%81%D0%BA)](https://github.com/iamletenkov/cream-extensions/releases/latest)
[![Лицензия](https://img.shields.io/badge/license-PolyForm%20Noncommercial-blue)](LICENSE)

Каталог расширений для [cream](https://github.com/iamletenkov/cream) — исполнителя
расширений для машин на Debian и Ubuntu. Расширение ставит и настраивает одну
вещь: Docker, узел Teleport, рабочий стол и удалённый доступ к нему, драйверы
NVIDIA, стек Jetson (L4T), файрвол, локаль и прочее. Одно и то же расширение
работает на живой машине (`cream install`) и при сборке образа
[bisquite](https://github.com/iamletenkov/bisquite)
(`RUN_COMMAND cream install` в VMFILE).

## Быстрый старт

Нужен cream 1.2.0 или новее ([установка](https://github.com/iamletenkov/cream#установка)).
Подключить каталог — снимок выпуска, проверенный по sha256:

```bash
CV=5.9.3 # x-release-please-version
URL="https://github.com/iamletenkov/cream-extensions/releases/download/v$CV"
curl -fLO "$URL/cream-extensions-$CV.tar.gz"
curl -fLO "$URL/SHA256SUMS"
sha256sum -c --ignore-missing SHA256SUMS           # cream-extensions-<версия>.tar.gz: OK
SUM=$(awk -v f="cream-extensions-$CV.tar.gz" '$2 == f {print $1}' SHA256SUMS)
sudo cream source add core --archive "$URL/cream-extensions-$CV.tar.gz" --sha256 "$SUM" --sync
```

Поставить, настроить, снять:

```bash
sudo cream install --with-deps btop                # --with-deps добирает depends из каталога
sudo cream install --with-deps locale LOCALE=ru_RU.UTF-8
cream show locale                                  # настройки и их значения
sudo cream set locale KEYBOARD_LAYOUTS=us,ru       # проверка по схеме, хук apply
sudo cream install --with-deps --accept-risk docker   # заметно меняет машину — только с флагом
sudo cream remove locale
```

В образе bisquite 3 каталог уже подключён источником `core` — строки VMFILE:

```dockerfile
FROM ubuntu2404:dst-base
RUN_COMMAND cream install --with-deps desktop DESKTOP_AUTOLOGIN=1
RUN_COMMAND cream install --with-deps gnome x11vnc
```

Расширения, у которых в README сказано «Живая машина — с `--accept-risk`»,
заметно меняют работающую машину (сеть, экран входа, ядро); на живой машине они
ставятся только с этим флагом. `--with-deps` добирает `depends`, но не
способности из `requires`: `x11vnc` ставится после рабочего стола (`gnome`,
`xfce4`, `lxde`). Секреты — `KEY=-` со stdin или `--params-file`, не в argv. Подробно — [первые шаги](docs/getting-started.md)
и [расширения в образе bisquite](docs/guides/use-in-bisquite.md).

## Расширения

Параметры, этапы и ограничения — в README каждого расширения. Связи (кто что даёт
и требует) — [справочник каталога](docs/reference/catalog.md). Таблицу строит
`tools/catalog-docs.sh` из манифестов; CI проверяет, что она не устарела.

<!-- catalog:table -->
Расширений — 48, библиотек — 4.

| Расширение | Что делает | ОС | Архитектура | Параметры |
|---|---|---|---|---|
| [`amneziawg`](extensions/openwrt/amneziawg/README.md) | интерфейс AmneziaWG на OpenWrt — ключ на машине, интерфейс и пир через uci, пакеты из образа | OpenWrt ≥ 25.12 | amd64, arm64 | `AMNEZIAWG_IFACE`, `AMNEZIAWG_PRIVATE_KEY`, `AMNEZIAWG_ADDRESSES` и ещё 19 |
| [`btop`](extensions/debian/btop/README.md) | TUI-монитор ресурсов btop — пакет apt или статическая сборка релиза по sha256 | Debian, Ubuntu | amd64, arm64 | — |
| [`can`](extensions/debian/can/README.md) | Шина CAN — can-utils, модули ядра CAN для ядер машины и их автозагрузка | Debian, Ubuntu | amd64, arm64 | `CAN_MODULES_LOAD` |
| [`can-usb`](extensions/debian/can-usb/README.md) | Модули адаптеров CAN gs_usb, peak_usb, slcan под ядро Sensing (Jetson AGX Orin, L4T 36.4.3) | Debian, Ubuntu | arm64 | — |
| [`chromium-kiosk`](extensions/debian/chromium-kiosk/README.md) | Киоск пакета chromium-kiosk (Salamek) — своя графическая сессия, config.yml из ключей домена | Debian, Ubuntu | amd64, arm64 | `CHROMIUM_KIOSK_HOME_PAGE`, `CHROMIUM_KIOSK_WINDOW_MODE`, `CHROMIUM_KIOSK_TOUCHSCREEN` и ещё 13 |
| [`cloud-growroot`](extensions/debian/cloud-growroot/README.md) | Модули cloud-init growpart и resizefs в cloud.cfg — корень растёт до размера носителя | Debian, Ubuntu | amd64, arm64 | — |
| [`cloud-user-desktop`](extensions/debian/cloud-user-desktop/README.md) | Вендорский рабочий стол — удаление вендорской учётки и ручки desktop для пользователя cloud-init | Debian, Ubuntu | amd64, arm64 | `CLOUD_USER_DESKTOP_REMOVE` |
| [`code-server`](extensions/debian/code-server/README.md) | code-server — VS Code в браузере от имени пользователя; без пароля не стартует, наружу — через Teleport | Debian, Ubuntu | amd64, arm64 | `CODE_SERVER_USER`, `CODE_SERVER_PASSWORD`, `CODE_SERVER_PORT` и ещё 2 |
| [`cuda-toolkit`](extensions/debian/cuda-toolkit/README.md) | CUDA Toolkit для NVIDIA Jetson из репозитория jetson/common и системный профиль PATH | Debian, Ubuntu | arm64 | — |
| [`desktop`](extensions/debian/desktop/README.md) | Ручки рабочего стола — автологин gdm3/lightdm, без автоблокировки и затемнения, группы пользователя | Debian, Ubuntu | amd64, arm64 | `DESKTOP_AUTOLOGIN`, `DESKTOP_AUTOLOGIN_USER`, `DESKTOP_DISABLE_SCREEN_LOCK` и ещё 1 |
| [`docker`](extensions/debian/docker/README.md) | Docker CE из официального apt-репозитория Docker (download.docker.com) | Debian, Ubuntu | amd64, arm64 | — |
| [`firefox`](extensions/debian/firefox/README.md) | Firefox из APT-репозитория Mozilla — настоящий .deb, а не снап | Debian, Ubuntu | amd64, arm64 | `FIREFOX_LANGPACK` |
| [`firewall`](extensions/debian/firewall/README.md) | Файрвол машины — своя таблица nftables inet cream или цепочка iptables-legacy CREAM-INPUT | Debian, Ubuntu | amd64, arm64 | `FIREWALL_ENABLE`, `FIREWALL_BACKEND`, `FIREWALL_SSH_PORTS` |
| [`gnome`](extensions/debian/gnome/README.md) | GNOME на Xorg и менеджер входа gdm3 — X-сервер и сессия для x11vnc, kiosk, selkies | Debian, Ubuntu | amd64, arm64 | — |
| [`jetson-stats`](extensions/debian/jetson-stats/README.md) | jtop — монитор NVIDIA Jetson (CPU, GPU, память, питание) и служба jtop.service | Debian, Ubuntu | arm64 | `JETSON_STATS_VERSION` |
| [`kiosk`](extensions/debian/kiosk/README.md) | Chromium в режиме киоска поверх графического сеанса — от пользователя сеанса, на весь экран | Debian | amd64, arm64 | `KIOSK_USER`, `KIOSK_URL`, `KIOSK_DISPLAY` и ещё 2 |
| [`l4t-board-fdt`](extensions/debian/l4t-board-fdt/README.md) | Дерево устройств платы Jetson — строка FDT в записи kvm файла extlinux.conf | Debian, Ubuntu | arm64 | `L4T_BOARD` |
| [`l4t-boot-verify`](extensions/debian/l4t-boot-verify/README.md) | Отметка каждой загрузки Jetson (L4T) успешной — nvbootctrl verify вместо вендорской службы | Debian, Ubuntu | arm64 | — |
| [`l4t-gstreamer`](extensions/debian/l4t-gstreamer/README.md) | GStreamer для NVIDIA Jetson — аппаратные плагины NVIDIA по версии стека L4T, RTSP, WebRTC, Python | Debian, Ubuntu | arm64 | `GSTREAMER_DEV` |
| [`l4t-kernel-kvm`](extensions/debian/l4t-kernel-kvm/README.md) | Ядро L4T с KVM для Jetson Nano/TX1 (t210) — сборка из исходников NVIDIA, загрузка по умолчанию | Debian, Ubuntu | arm64 | `L4T_KERNEL_JOBS`, `L4T_KERNEL_LOCALVERSION`, `L4T_KERNEL_CC` и ещё 2 |
| [`l4t-opencv`](extensions/debian/l4t-opencv/README.md) | OpenCV 4.8.0 для NVIDIA Jetson (cv2 с GStreamer) — пакеты NVIDIA на R36, проверка образа на R32 | Debian, Ubuntu | arm64 | — |
| [`l4t-pytorch`](extensions/debian/l4t-pytorch/README.md) | PyTorch и torchvision с CUDA для NVIDIA Jetson — колесо NVIDIA и сборка torchvision (R36), проверка образа (R32) | Debian, Ubuntu | arm64 | `TORCH_CUDA_ARCH_LIST` |
| [`l4t-tensorflow`](extensions/debian/l4t-tensorflow/README.md) | TensorFlow с CUDA для NVIDIA Jetson — колесо NVIDIA 2.16.1, cuDNN 9 и keras 3.3.3 | Debian, Ubuntu | arm64 | — |
| [`l4t-vendor-desktop`](extensions/debian/l4t-vendor-desktop/README.md) | Рабочий стол образа вендора L4T R32 (Jetson Nano) как x11-server, display-manager, desktop-session | Ubuntu ≥ 18.04 | arm64 | — |
| [`locale`](extensions/debian/locale/README.md) | Системная локаль и раскладки клавиатуры — система, консоль, Xorg/GDM, умолчания GNOME | Debian, Ubuntu | amd64, arm64 | `LOCALE`, `KEYBOARD_LAYOUTS`, `KEYBOARD_TOGGLE` |
| [`luci-apps`](extensions/openwrt/luci-apps/README.md) | приложения LuCI из подписанных фидов OpenWrt (apk) по списку; снимает только то, что поставило само | OpenWrt ≥ 25.12 | amd64, arm64 | `LUCI_APPS_PACKAGES` |
| [`lxde`](extensions/debian/lxde/README.md) | LXDE и менеджер входа lightdm — X-сервер и сессия для x11vnc, kiosk, selkies | Debian, Ubuntu | amd64, arm64 | — |
| [`network-manager`](extensions/debian/network-manager/README.md) | NetworkManager и wpasupplicant в образе — чтобы Wi-Fi из манифеста устройства поднялся | Debian, Ubuntu | amd64, arm64 | — |
| [`nocloud-cidata`](extensions/debian/nocloud-cidata/README.md) | cloud-init читает NoCloud-seed с раздела с меткой cidata | Debian, Ubuntu | amd64, arm64 | — |
| [`nvidia`](extensions/debian/nvidia/README.md) | Драйвер NVIDIA заданной ветки (по умолчанию 580, открытые модули) под ядра машины | Debian, Ubuntu | amd64 | `NVIDIA_DRIVER_VERSION`, `NVIDIA_KERNEL_MODULES`, `NVIDIA_SOURCE` |
| [`nvidia-container-toolkit`](extensions/debian/nvidia-container-toolkit/README.md) | NVIDIA Container Toolkit для Docker — среда выполнения nvidia без смены default-runtime | Debian, Ubuntu | amd64 | `NVIDIA_CTK_VERSION` |
| [`nvidia-jetpack`](extensions/debian/nvidia-jetpack/README.md) | Станция прошивки NVIDIA Jetson на amd64 — инструментарий L4T, NFS, binfmt aarch64, скрипты | Ubuntu, Debian | amd64 | — |
| [`pixelflux-tegra`](extensions/debian/pixelflux-tegra/README.md) | Аппаратное кодирование Selkies на Jetson — подкладка libxcb, шим gbm, проверка бэкенда Tegra | Debian, Ubuntu | arm64 | — |
| [`pixelflux-v4l2m2m`](extensions/debian/pixelflux-v4l2m2m/README.md) | Аппаратное кодирование Selkies через V4L2 M2M (Raspberry Pi) — проверка бэкенда на сборке и загрузке | Debian, Ubuntu | arm64 | — |
| [`podkop`](extensions/openwrt/podkop/README.md) | выборочная маршрутизация podkop на OpenWrt — прокси по ссылке или VPN-интерфейс, списки сообществ, через uci | OpenWrt ≥ 25.12 | amd64, arm64 | `PODKOP_CONNECTION_TYPE`, `PODKOP_PROXY_STRING`, `PODKOP_INTERFACE` и ещё 4 |
| [`rustdesk`](extensions/debian/rustdesk/README.md) | RustDesk — клиент и служба удалённой поддержки, адреса своего сервера из ключей домена | Debian, Ubuntu | amd64, arm64 | `RUSTDESK_VERSION`, `RUSTDESK_SHA256_AMD64`, `RUSTDESK_SHA256_ARM64` и ещё 6 |
| [`selkies`](extensions/debian/selkies/README.md) | Selkies — рабочий стол X-сессии в браузере; без пароля не стартует, наружу — через Teleport | Debian, Ubuntu | amd64, arm64 | `SELKIES_ADDR`, `SELKIES_PORT`, `SELKIES_MODE` и ещё 26 |
| [`sensing-gmsl2-camera`](extensions/debian/sensing-gmsl2-camera/README.md) | Камеры Sensing GMSL2 на Jetson AGX Orin (SG8A-AGON-G2Y-A1, L4T 36.4.3) — ядро, модули, оверлей, запуск на загрузке | Debian, Ubuntu | arm64 | `SENSING_GMSLMODE`, `SENSING_CAMERA_CONTROLS`, `SENSING_BOOST_CLOCK` |
| [`stvor-agent`](extensions/debian/stvor-agent/README.md) | Агент портала Stvor — метки env и space узла Teleport с портала | Debian ≥ 12, Ubuntu ≥ 20.04 | amd64, arm64 | `STVOR_AGENT_VERSION`, `STVOR_AGENT_SHA256`, `STVOR_AGENT_MIRROR` и ещё 3 |
| [`stvor-agent-openwrt`](extensions/openwrt/stvor-agent-openwrt/README.md) | Агент портала Stvor на OpenWrt — метки env и space узла Teleport с портала и телеметрия, procd | OpenWrt ≥ 25.12 | amd64, arm64 | `STVOR_AGENT_VERSION`, `STVOR_AGENT_SHA256`, `STVOR_AGENT_MIRROR` и ещё 3 |
| [`teleport`](extensions/debian/teleport/README.md) | Узел Teleport — бинарь, регистрация (join), рендер teleport.yaml, приложения apps.d | Debian ≥ 12, Ubuntu ≥ 20.04 | amd64, arm64 | `TELEPORT_VERSION`, `TELEPORT_SHA256`, `TELEPORT_MIRROR` и ещё 16 |
| [`teleport-openwrt`](extensions/openwrt/teleport-openwrt/README.md) | Узел Teleport на OpenWrt — набор openwrt-<arch> с glibc рядом, регистрация, рендер teleport.yaml, procd | OpenWrt ≥ 25.12 | amd64, arm64 | `TELEPORT_VERSION`, `TELEPORT_SHA256`, `TELEPORT_MIRROR` и ещё 16 |
| [`tensorrt`](extensions/debian/tensorrt/README.md) | TensorRT для NVIDIA Jetson — движок, биндинги Python и компилятор DLA (R36), проверка движка образа (R32) | Debian, Ubuntu | arm64 | — |
| [`vino-vnc`](extensions/debian/vino-vnc/README.md) | VNC через vino (GNOME) в сессии пользователя cloud-init — настройки системным dconf, по умолчанию только петля | Debian, Ubuntu | amd64, arm64 | `VINO_PORT`, `VINO_LISTEN`, `VINO_ENCRYPTION` и ещё 2 |
| [`wallpaper`](extensions/debian/wallpaper/README.md) | Обои рабочего стола — системное умолчание GNOME (dconf), Xfce (xfconf) и LXDE (pcmanfm) из картинок расширения | Debian, Ubuntu | amd64, arm64 | `WALLPAPER_IMAGE`, `WALLPAPER_MODE` |
| [`x11vnc`](extensions/debian/x11vnc/README.md) | VNC к рабочему столу X11 пользователя cloud-init — x11vnc@<пользователь>, по умолчанию только петля | Debian, Ubuntu | amd64, arm64 | `X11VNC_PORT`, `X11VNC_DISPLAY`, `X11VNC_LISTEN` и ещё 2 |
| [`xfce4`](extensions/debian/xfce4/README.md) | Xfce4 и менеджер входа lightdm — X-сервер и сессия для x11vnc, kiosk, selkies | Debian, Ubuntu | amd64, arm64 | — |
| [`yq`](extensions/debian/yq/README.md) | Статический бинарь mikefarah/yq в /usr/local/bin по пину версии и sha256 | Debian ≥ 12, Ubuntu ≥ 18.04 | amd64, arm64 | `YQ_VERSION`, `YQ_SHA256` |

Библиотеки — общий код, который другие расширения объявляют в `depends`; сами по себе их не ставят:

| Библиотека | Что даёт | ОС | Архитектура |
|---|---|---|---|
| [`apt-guard`](extensions/debian/apt-guard/README.md) | Библиотека — remove снимает только свои пакеты apt, с проверкой симуляцией | Debian, Ubuntu | amd64, arm64 |
| [`cloud-user`](extensions/debian/cloud-user/README.md) | Библиотека — имя пользователя cloud-init для хуков других расширений | Debian, Ubuntu | amd64, arm64 |
| [`fetch`](extensions/debian/fetch/README.md) | Устарела (не нужна с каталога 5.5.0) — совместимость для потребителей 5.4.2, загрузка с повторами на обрыв соединения | Debian, Ubuntu | amd64, arm64 |
| [`l4t`](extensions/debian/l4t/README.md) | Общие функции расширений стека L4T — версия L4T и OPENBLAS_CORETYPE для Jetson | Debian, Ubuntu | arm64 |
<!-- /catalog:table -->

## Документация

- [Первые шаги](docs/getting-started.md) — подключить каталог, поставить и настроить расширение.
- Руководства: [расширения в образе bisquite](docs/guides/use-in-bisquite.md) ·
  [настройки на работающей машине](docs/guides/settings.md) ·
  [написать расширение](docs/guides/write-extension.md) ·
  [настройка на загрузке и `every_boot`](docs/guides/configure-lifecycle.md) ·
  [тестирование](docs/guides/testing.md) · [выпуск](docs/guides/release.md)
- Справочник: [каталог](docs/reference/catalog.md) ·
  [способности](docs/reference/capabilities.md) ·
  [структура репозитория](docs/reference/layout.md) ·
  [правила проверок](docs/reference/lint-rules.md) ·
  [переменные](docs/reference/environment.md) ·
  [шаблон README расширения](docs/reference/extension-readme.md)
- [Все документы](docs/README.md) · [изменения по версиям](CHANGELOG.md) ·
  [история каталога](docs/history/README.md)

Формат расширения, команды и коды cream — в документации cream:
[манифест](https://github.com/iamletenkov/cream/blob/main/docs/reference/manifest.md),
[CLI](https://github.com/iamletenkov/cream/blob/main/docs/reference/cli.md).

## Совместимость

| | |
|---|---|
| cream | ≥ 1.2.0 для каталога целиком; у каждого расширения своё `cream:` в манифесте; проверки идут на пине [`tools/cream-pin.env`](tools/cream-pin.env) |
| bisquite | ≥ 3.0 — везёт cream и снимок каталога сам; строки `RUN_COMMAND cream install` |
| ОС | Debian 12 и 13, Ubuntu 18.04–24.04 — по `platform.os` расширения (таблица выше) |
| Архитектуры | `amd64`, `arm64` — по `platform.arch` расширения |
| Версии | каталог — semver, тег `vX.Y.Z` и снимок в выпуске; у расширения своя версия, она растёт при любом изменении его дерева |

## Участие

Изменения — pull request в `main` по [Conventional Commits](https://www.conventionalcommits.org/ru/)
(тип латиницей, текст по-русски). Перед PR — `make ci`; новое расширение —
только каркасом `tools/new-extension.sh` ([руководство](docs/guides/write-extension.md)).
Регламент для людей и агентов — [AGENTS.md](AGENTS.md).

## Лицензия

[PolyForm Noncommercial 1.0.0](LICENSE), см. [NOTICE](NOTICE). Коммерческое
использование — по отдельной лицензии правообладателя.
