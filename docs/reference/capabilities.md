# Способности

Способность — то, на что может сослаться соседнее расширение: «X-сервер»,
«менеджер входа», «среда контейнеров». Расширение объявляет в манифесте, какие
способности даёт (`provides`), без каких не работает (`requires`) и с чем
несовместимо (`conflicts`); `cream check` и `cream validate` проверяют граф.
Кто сейчас что даёт и требует (из манифестов) — [справочник каталога](catalog.md#способности-кто-даёт-и-кто-требует);
здесь — правила и **откуда** каждая способность выведена.

## `provides` — что расширение даёт

Способности, которые расширение даёт. Способность — не имя пакета, а то, на
что может сослаться сосед. Три десктопа ставят `xorg xinput` и потому дают
**одну и ту же** способность `x11-server`; если назвать её у каждого
по-своему, `x11vnc` не сможет сослаться ни на одну.

Имя расширения тоже считается способностью.

## `requires` — без чего не работает

Способности, без которых расширение не работает. **Каждая обязана кем-то
предоставляться** — иначе `cream validate --catalog .` предупреждает.

Заполняется по коду, а не по интуиции. Пример: `x11vnc` требует `x11-server`
и `display-manager`, потому что `x11vnc@.service` прицепляется к `DISPLAY=:0`
и несёт `Requires=display-manager.service`, а обёртка `run-x11vnc.sh` ищет
X authority в каталогах, которые заводит дисплей-менеджер. Требование
**родовое**, и это верно: конкретный путь в юните не зашит — под GDM и
LightDM он разный, а под самим LightDM зависит от его конфига, — поэтому
различать в манифесте «какой именно менеджер» значило бы зафиксировать ось,
которая ответа не определяет.

До `requires` это отношение держалось только порядком строк в VMFILE: поменяй
местами `gnome` и `x11vnc` — сборка пройдёт, а VNC окажется не к чему прицепить.
Теперь `cream check` ловит такой порядок до сборки.

## `conflicts` — с чем несовместимо

Несовместимость объявляется по имени расширения (`conflicts.extensions`) или по
способности (`conflicts.capabilities`): десктопы (`gnome`, `xfce4`, `lxde`,
`l4t-vendor-desktop`) конфликтуют по `desktop-session`, и новый десктоп получает
конфликт, не правя соседей.
Конфликт по имени объявляют обе стороны (`kiosk` ↔ `chromium-kiosk`): односторонний
конфликт — это конфликт, о котором узнает только один из двух авторов.

`cream validate --catalog .` проверяет граф: `depends` на отсутствующее
расширение или цикл — ошибка, `requires` без поставщика и `conflicts` на имя
не из каталога — предупреждение (способность может дать другой источник).

## Словарь способностей

Полный список того, что объявлено сегодня, и на чём это основано.

| Способность | Кто даёт | Откуда выведено |
|---|---|---|
| `x11-server` | `gnome`, `xfce4`, `lxde`; `l4t-vendor-desktop` | `apt-get install ... xorg xinput` (`hooks/install` у всех трёх); `l4t-vendor-desktop` — Xorg образа вендора L4T R32, проверка без установки |
| `display-manager` | `gnome`, `xfce4`, `lxde`; `l4t-vendor-desktop` | `systemctl enable gdm3`/`lightdm` + `set-default graphical.target` (`hooks/install`); `l4t-vendor-desktop` — менеджер входа образа вендора (проверка) |
| `desktop-session` | `gnome`, `xfce4`, `lxde`; `l4t-vendor-desktop` | `task-gnome-desktop` / `xfce4 xfce4-goodies` / `lxde`; `l4t-vendor-desktop` — сессия в `/usr/share/xsessions` образа вендора (проверка) |
| `container-runtime` | `docker` | Docker CE из apt-репозитория Docker |
| `kiosk-browser` | `kiosk`, `chromium-kiosk` | обе реализации автостартом забирают экран |
| `remote-desktop` | `x11vnc`, `vino-vnc` | `x11vnc@.service` на `rfbport` из `X11VNC_PORT`; у `vino-vnc` — `gsettings` `org.gnome.Vino` и автозапуск XDG (умолчание у обоих 5900) |
| `web-ide` | `code-server` | code-server на порту `CODE_SERVER_PORT` домена `code-server` (умолчание 9001) |
| `gpu-driver-nvidia` | `nvidia` | драйвер NVIDIA под ядро образа (2.0.0: `NVIDIA_DRIVER_VERSION`, `NVIDIA_KERNEL_MODULES=open\|proprietary`, `NVIDIA_SOURCE=archive\|ppa`) + blacklist nouveau |
| `nvidia-container-runtime` | `nvidia-container-toolkit` | `nvidia-container-toolkit` из `nvidia.github.io/libnvidia-container`, `nvidia-ctk runtime configure --runtime=docker` без смены `default-runtime` |
| `can-bus` | `can` | `can-utils`, `iproute2`; модули `can can_raw can_dev vcan slcan gs_usb peak_usb` проверены `modinfo -k <ядро образа>` (ядро L4T `*-tegra`: без `slcan gs_usb peak_usb` — предупреждение); `/etc/modules-load.d/can.conf` |
| `can-usb-adapters` | `can-usb` | `gs_usb`, `peak_usb`, `slcan` для ядра Sensing 5.15.148-tegra (AGX Orin, L4T 36.4.3): собраны при сборке образа из исходников Jetson Linux R36.4.3 против `nvidia-l4t-kernel-headers`, `/lib/modules/<ядро>/updates/can-usb`, `depmod` |
| `host-firewall` | `firewall` | таблица nftables `inet cream` (input — `policy drop`) или цепочка iptables-legacy `CREAM-INPUT` — бэкенд по модулям ядра при сборке и на каждой загрузке (`FIREWALL_BACKEND`); штатное L4T r36 без `nft_ct` — iptables; ядро без обоих — отказ; цепочки Docker не трогает |
| `system-locale` | `locale` | `locale-gen`, `/etc/default/locale`, `/etc/default/keyboard`, `xorg.conf.d/00-keyboard.conf`, умолчания GNOME input-sources (dconf) |
| `remote-support` | `rustdesk` | `.deb` RustDesk (x86_64 / aarch64) по версии и sha256 своей архитектуры, включённый `rustdesk.service`; адреса сервера — `RustDesk2.toml` из домена `rustdesk` |
| `nocloud-cidata-seed` | `nocloud-cidata` | `/etc/cloud/cloud.cfg.d/zz-cream-nocloud.cfg` с `fs_label: cidata` |
| `network-manager` | `network-manager` | пакеты `network-manager` и `wpasupplicant`, включённый `NetworkManager.service` |
| `jetson-monitor` | `jetson-stats` | `jtop` из PyPI плюс `jtop.service`; данные идут из `tegrastats` и sysfs Tegra, а не из NVML |
| `cuda` | `cuda-toolkit` | `cuda-toolkit-12-6` из `jetson/common` (R36), `cuda-toolkit-10-2` или CUDA 10.2 образа (R32); `nvcc` в `/usr/local/cuda/bin` |
| `tensorrt` | `tensorrt` | мета-пакет `tensorrt` плюс `python3-libnvinfer` и `nvidia-l4t-dla-compiler` |
| `web-remote-desktop` | `selkies` | Selkies 2.0 (AppImage) на существующем X-дисплее, WebSocket на `127.0.0.1:8080`; `selkies@.service` от пользователя сессии |
| `web-browser` | `firefox` | `firefox` из `packages.mozilla.org` с пином 1000 поверх транзитного пакета снапа |
| `teleport-node` | `teleport` | `/usr/local/bin/teleport`, `teleport.service` из `cream run teleport join`; приложения — из `/etc/cream/teleport/apps.d` |
| `l4t-boot-verify` | `l4t-boot-verify` | `l4t-boot-verify.service` — `nvbootctrl verify` на каждой загрузке; вендорская `nv-l4t-bootloader-config` заглушена |
| `gmsl2-camera` | `sensing-gmsl2-camera` | ядро и модули Sensing (пакеты ядра L4T — `apt-mark hold`), DTB-оверлей, запуск камер на каждой загрузке (`modprobe.d`, правило udev, `sensing-gmsl2-clock.service`) |
| `gstreamer` | `l4t-gstreamer` | `gstreamer1.0-tools` и плагины base/good/bad/ugly/libav, RTSP-сервер, `gstreamer1.0-nice`, `python3-gst-1.0` |
| `hw-video-codec` | `l4t-gstreamer` | `nvidia-l4t-gstreamer` версии `nvidia-l4t-core`: `nvv4l2h264enc`/`h265enc`/`decoder`, `nvvidconv` |
| `opencv` | `l4t-opencv` | `libopencv` и `libopencv-python` 4.8.0 от NVIDIA, с GStreamer, без CUDA; на R32 ничего не ставит — сверяет cv2 образа (с CUDA) и пишет `OPENBLAS_CORETYPE` |
| `pytorch` | `l4t-pytorch` | колесо torch nv24.08 с CDN NVIDIA, torchvision из исходников с CUDA (pip с `--require-hashes` по `requirements.txt` расширения); на R32 ничего не ставит — сверяет torch образа и пишет `OPENBLAS_CORETYPE` |
| `tensorflow` | `l4t-tensorflow` | колесо tensorflow nv24.08 с CDN NVIDIA; pip с `--require-hashes` по `requirements.txt` расширения |
| `system-monitor` | `btop` | `btop` из apt или статическая сборка релиза по sha256 |
| `cloud-growroot` | `cloud-growroot` | модули cloud-init `growpart` и `resizefs` в `cloud.cfg` |
| `cloud-user-desktop` | `cloud-user-desktop` | вендорский рабочий стол: удаление вендорской учётки, ручки `desktop` для пользователя cloud-init |
| `wallpaper` | `wallpaper` | системное умолчание обоев GNOME (dconf), Xfce (xfconf), LXDE (pcmanfm) |
| `yq` | `yq` | статический `mikefarah/yq` в `/usr/local/bin` по пину версии и sha256 |
| `stvor-agent` | `stvor-agent` | пакет `stvor-agent` по пину версии и sha256 своей архитектуры (`files/pin.env`) |
| `kvm-host`, `l4t-custom-kernel` | `l4t-kernel-kvm` | ядро L4T с KVM для Jetson Nano/TX1 (t210), собранное из исходников NVIDIA (сверка по `public-sources.sha256` для каждой версии L4T), загрузка по умолчанию |
| `l4t-board-selected` | `l4t-board-fdt` | строка `FDT` платы в записи `kvm` файла `extlinux.conf` |
| `jetson-flash-station` | `nvidia-jetpack` | станция прошивки Jetson на amd64: инструментарий L4T, NFS, binfmt aarch64, скрипты |
| `hardware-video-encoding` | `pixelflux-v4l2m2m` | аппаратное кодирование Selkies через V4L2 M2M (Raspberry Pi); `pixelflux-tegra` своей способности не даёт |

Кто чего требует:

| Расширение | `requires` | Откуда выведено |
|---|---|---|
| `x11vnc` | `x11-server`, `display-manager` | `x11vnc@.service` — `Requires=display-manager.service` и `DISPLAY=:0`. Путь к X authority в юните НЕ зашит: он разный под LightDM и GDM, и обёртка ищет его в рантайме |
| `kiosk` | `x11-server`, `display-manager` | `install` ставит клиентские утилиты X, но **не** `xorg`; `kiosk-chromium@.service` — `DISPLAY=:0`; донастройка — стадия `graphical` (после `display-manager.service`). Путь к X authority в юните, как и у `x11vnc`, НЕ зашит — его ищет обёртка `run-kiosk.sh` |
| `vino-vnc` | `x11-server`, `display-manager` | vino живёт ВНУТРИ пользовательской сессии: `configure` пишет `gsettings` в dconf пользователя и кладёт автозапуск в его `~/.config/autostart`, а сессию открывает дисплей-менеджер. Системного юнита и поиска X authority здесь нет вовсе — этим он и отличается от `x11vnc` |
| `selkies` | `x11-server`, `display-manager` | `run-selkies.sh` снимает экран существующего X-дисплея и ждёт сессию пользователя; без автологина показывать нечего |
| `l4t-pytorch` | `cuda` | `install` отказывает без `/usr/local/cuda/bin/nvcc`: им собирается torchvision с `FORCE_CUDA=1`; сам torch грузит `libcublas`, `libcufft` и прочие библиотеки тулкита. На R32 (Nano) не проверяется: torch и CUDA 10.2 уже в образе |
| `l4t-tensorflow` | `cuda` | `install` отказывает без `/usr/local/cuda/lib64`: TF грузит библиотеки тулкита |
| `can-usb` | `gmsl2-camera` | `install` отказывает, если `/boot/Image` — не ядро Sensing закреплённой сборки: модули собираются под него, а кладёт его `sensing-gmsl2-camera` — ставится раньше `can-usb` |
| `nvidia-container-toolkit` | `gpu-driver-nvidia`, `container-runtime` | `nvidia-ctk runtime configure --runtime=docker` правит `/etc/docker/daemon.json`; без драйвера среда `nvidia` бесполезна |
| `wallpaper` | `desktop-session` | без рабочего стола ключи обоев никто не читает: отказ — при сборке |
| `pixelflux-tegra`, `pixelflux-v4l2m2m` | `web-remote-desktop` | настраивают pixelflux внутри AppImage `selkies` |
| `l4t-board-fdt` | `l4t-custom-kernel` | без деревьев `-kvm` от `l4t-kernel-kvm` выбирать нечего |
| остальные | — | ничего не требуют по коду |

Конфликты:

| Пара | Причина |
|---|---|
| `gnome` ↔ `xfce4` ↔ `lxde` ↔ `l4t-vendor-desktop` (по способности `desktop-session`) | каждый ставит (или берёт из образа вендора) свой дисплей-менеджер и делает его системным `display-manager.service` |
| `kiosk` ↔ `chromium-kiosk` | оба автостартом на `graphical.target` разворачивают полноэкранный браузер на одном месте |
| `pixelflux-tegra` ↔ `pixelflux-v4l2m2m` | оба настраивают pixelflux внутри одного AppImage `selkies` |
| `teleport` (по своей способности `teleport-node`) | второй поставщик узла Teleport из другого источника |

Оговорка про честность вывода: десктопы измерены по коду, киоски —
рассуждение, а не замер. Ни один VMFILE не ставит `kiosk` и `chromium-kiosk`
вместе, так что проверить конфликт на практике не на чем.
