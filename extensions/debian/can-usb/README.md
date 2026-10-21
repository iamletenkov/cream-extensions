# can-usb

Модули ядра USB- и serial-адаптеров CAN — `gs_usb` (candleLight, CANable,
прошивка gs_usb), `peak_usb` (PEAK PCAN-USB, -Pro, -FD) и `slcan` (адаптеры
с протоколом LAWICEL поверх последовательного порта) — для **ядра Sensing**
на **Jetson AGX Orin Developer Kit** с **L4T 36.4.3** (JetPack 6.2).

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | arm64 |
| cream | ≥ 1.0.0 |
| Даёт | `can-usb-adapters` |
| Требует | `gmsl2-camera` |
| Зависит от | [`apt-guard`](../apt-guard/README.md) |
| Конфликтует с | — |
| Хуки | `install`, `remove` |
| Настройка на загрузке | — |
| Живая машина | с `--accept-risk` |

> **Живая машина — с `--accept-risk`.** Скачивает исходники ядра Jetson Linux 36.4.3 (около 220 МБ во временный файл, сверка sha256 до распаковки), ставит заголовки ядра (nvidia-l4t-kernel-headers, закрепляет apt-mark hold) и компилятор и собирает три модуля под ядро Sensing в /lib/modules/5.15.148-tegra/updates/can-usb; модули грузит udev при подключении адаптера, после перезагрузки
<!-- /catalog:facts -->

Требование — раздел «CAN» описания базового образа Jetson: в списке модулей
`slcan`, `gs_usb`, `peak_usb`, а в проверке образа —
`modinfo -n mttcan vcan gs_usb peak_usb slcan`. Ядро Sensing
(`5.15.148-tegra`, его кладёт на `/boot/Image` расширение
[`sensing-gmsl2-camera`](../sensing-gmsl2-camera/README.md)) собрано без них:
`CONFIG_CAN_GS_USB`, `CONFIG_CAN_PEAK_USB` и `CONFIG_CAN_SLCAN` не заданы, и ни
один пакет их не приносит. Это расширение собирает три модуля при сборке образа.

## Что делает

**`install`** (`canusb.sh`, `Kbuild` — в дереве расширения,
`/opt/cream/ext/can-usb/`):

1. **Барьеры до сети.** `/etc/nv_tegra_release` — ровно 36.4.3 (нет файла — код
   **20**); есть `/boot/dtb/kernel_tegra234-p3737-0000+p3701-0000-nv.dtb` (AGX Orin
   Devkit); в `/lib/modules` образа ровно одно ядро L4T, и это
   `5.15.148-tegra` (ядро берётся по `/lib/modules`, не `uname -r`:
   внутри `virt-customize` это ядро appliance; ядро generic рядом
   называется и не используется); `/boot/Image` — версии
   `5.15.148-tegra` с закреплённой sha256 ядра Sensing. Штатное ядро
   (`/boot/Image` = `/boot/Image.backup` или бэкапа нет) — отказ с текстом
   про порядок слоёв; ядро Sensing другой сборки — отказ «неизвестной
   сборки».
2. **Заголовки ядра образа** — `/lib/modules/5.15.148-tegra/build` →
   `/usr/src/linux-headers-5.15.148-tegra-ubuntu22.04_aarch64` (пакет
   `nvidia-l4t-kernel-headers`). В базовом образе он есть; если нет —
   ставится версией установленного `nvidia-l4t-kernel` и закрепляется
   `apt-mark hold`. Версия `nvidia-l4t-kernel` из dpkg сверяется с алфавитом
   версий Debian, прежде чем попасть в аргументы apt. `.config` и
   `Module.symvers` сверяются с закреплёнными суммами.
3. **Инструменты** — `gcc make libc6-dev binutils curl bzip2 kmod`, только
   если чего-то нет.
4. **Исходники** — `public_sources.tbz2` R36.4.3 (226 МБ) скачивается во
   временный файл рабочего каталога (`/var/tmp/can-usb.*`, нужно около 230 МБ
   свободного места), sha256 сверяется **до распаковки**: недоверенный архив
   tar и bzip2 от root не трогают. Сошлась — извлекаются только восемь файлов
   драйверов, архив удаляется; не сошлась — архив удаляется, сборка отказывает.
5. **Сборка** — внешними модулями против дерева образа:
   `make -C /lib/modules/5.15.148-tegra/build M=<каталог> modules` со своим
   `Kbuild` (те же объекты, что в Makefile ядра 5.15, без условий
   `CONFIG_`). vermagic каждого модуля сверяется со штатным `can-dev.ko`.
6. **Установка** — `/lib/modules/5.15.148-tegra/updates/can-usb/`
   (`gs_usb.ko`, `peak_usb.ko`, `slcan.ko`, без отладочной информации; через
   временный файл и переименование), `depmod 5.15.148-tegra`, затем
   `modprobe -S 5.15.148-tegra --show-depends` каждого — модуль должен
   разрешаться в наш файл.

Модули поставлены или изменились — код **10** (перезагрузка), повтор без
изменений — 0.

**`remove`** — см. «Как снять».

Автозагрузку расширение не трогает, и в `CAN_MODULES_LOAD` расширения
[`can`](../can/README.md) модули добавлять не нужно: модуль адаптера грузит udev при
подключении по USB-идентификатору (modalias), `slcan` — `slcand`/`ldattach`
при привязке порта.

## Параметры

<!-- catalog:params -->
Параметров нет.
<!-- /catalog:params -->

## Установка

На живой плате (`live: confirm`; код 10 — перезагрузка):

```bash
sudo cream install --with-deps --accept-risk can-usb
sudo cream remove can-usb
```

В образе bisquite (VMFILE):

```dockerfile
RUN_COMMAND cream install --with-deps sensing-gmsl2-camera
RUN_COMMAND cream install --with-deps can
RUN_COMMAND cream install --with-deps can-usb
```

**Порядок обязателен: `can-usb` — после `sensing-gmsl2-camera`.** Модули
собираются под ядро, которое лежит в образе, а ядро Sensing появляется там
только после того слоя. Поставить раньше — громкий отказ («штатное ядро
NVIDIA, а не ядро Sensing»), а не модули под чужое ядро. Порядок с `can`
не важен: `can` модули только проверяет, а на ядре `*-tegra` их отсутствие
для него — предупреждение.

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | барьеры, заголовки и инструменты, скачивание исходников со сверкой, сборка и установка трёх модулей; код 10 при изменении |
| загрузка | модули грузит udev при подключении адаптера |
| `cream remove` | модули, своё закрепление и свои пакеты сняты (см. «Как снять») |

## Известные ограничения

- **Только AGX Orin Devkit, L4T 36.4.3, ядро Sensing этой сборки.** Любое
  другое — отказ при сборке образа.
- **Обновление ядра запрещено hold'ом.** `sensing-gmsl2-camera` закрепляет
  пакеты ядра L4T (`apt-mark hold`), `apt upgrade` их не тронет. Смена ядра
  (новая сборка Sensing, другой L4T) — **пересборка образа** с новыми
  суммами в `hooks/install` и новой сверкой конфигов на плате; модули под старое
  ядро в новое не загрузятся.
- **Модули не подписаны.** Ядро собрано с `CONFIG_MODULE_SIG=y` без
  `CONFIG_MODULE_SIG_FORCE`: неподписанный модуль грузится, ядро помечается
  taint «E» (`module verification failed`). Ключа подписи Sensing/NVIDIA
  у нас нет. На плате taint «E» стоит и без них — от внеядерных модулей
  образа (замер 2026-10-15: `/proc/sys/kernel/tainted` = 12800 до загрузки).
- **Kbuild может предупредить «the compiler differs»**: заголовки собраны
  `gcc 11.4.0-1ubuntu1~22.04`, а на плате 2026-10-15 стоял
  `11.4.0-1ubuntu1~22.04.3` — та же версия 11.4.0. На результат не влияет:
  vermagic компилятора не содержит, суммы символов от него не зависят.
- **Сборке нужна сеть** до `developer.nvidia.com` (исходники) и, если
  инструментов нет, до зеркала Ubuntu.

## Подробности

### Почему из исходников NVIDIA, а не Sensing

Описание образа просит собирать из исходников ядра Sensing той же версии.
Sensing публикует ядро только бинарём (`boot/Image` в пакете драйверов камер),
исходников нет. Решение владельца — исходники ядра **того же релиза L4T
36.4.3 от NVIDIA**: публичные исходники Jetson Linux R36.4.3
(`public_sources.tbz2` → `kernel_src.tbz2`, `kernel/kernel-jammy-src`,
5.15.148). Почему это то же самое для этих трёх драйверов:

- **Конфиги совпадают.** Замер на живой плате 2026-10-15: `/proc/config.gz`
  ядра Sensing и `.config` заголовков `nvidia-l4t-kernel-headers`
  36.4.3 различаются только строками компилятора — Buildroot gcc 11.3 против
  Ubuntu gcc 11.4 и `CONFIG_GCC_PLUGINS=y` при выключенных всех плагинах
  (`RANDSTRUCT`, `STRUCTLEAK`, `STACKLEAK`, `LATENT_ENTROPY` — нет). Раскладка
  структур и контрольные суммы символов (`CONFIG_MODVERSIONS=y`) от
  компилятора не зависят.
- **Камерные патчи Sensing драйверов CAN не касаются.** Они — про
  дешериализатор, сенсоры и VI/CSI (модули `max96712`, `sgx-yuv-gmsl2`,
  `tegra-camera`, `nvhost-nvcsi-t194`); `drivers/net/can`, USB core и
  подсистема tty в них не участвуют.
- **Проверено загрузкой.** Модули, собранные так на плате с ядром Sensing,
  загружаются `insmod` в работающее ядро без «disagrees about version of
  symbol» и регистрируются (`usbcore: registered new interface driver
  gs_usb`, `… peak_usb`, `slcan: serial line CAN interface driver`).
  Штатный `can-dev.ko` из `nvidia-l4t-kernel`, от которого зависят `gs_usb`
  и `peak_usb`, с ядром Sensing и так работает (на нём живёт `mttcan`).

Чтобы этот вывод не устарел молча, сборка привязана к сверенной паре
закреплёнными суммами в `hooks/install`: sha256 `/boot/Image` Sensing, sha256
`.config` и `Module.symvers` заголовков и sha256 `public_sources.tbz2`.

### Проверка на устройстве

```bash
modinfo -n gs_usb peak_usb slcan
# /lib/modules/5.15.148-tegra/updates/can-usb/gs_usb.ko
# /lib/modules/5.15.148-tegra/updates/can-usb/peak_usb.ko
# /lib/modules/5.15.148-tegra/updates/can-usb/slcan.ko

# после подключения адаптера gs_usb / PCAN-USB:
lsmod | grep -E 'gs_usb|peak_usb'
ip link                                   # появился can<N>
sudo ip link set can2 up type can bitrate 500000
candump can2

# slcan: адаптер на /dev/ttyACM0
sudo slcand -o -c -s6 /dev/ttyACM0 slcan0 && sudo ip link set slcan0 up
```

Номер `can<N>` зависит от порядка: `can0`/`can1` занимает встроенный
`mttcan` на AGX Orin.

### Как снять

`install` записывает в `/var/lib/cream/ext/can-usb/` только своё: `packages` — пакеты,
которых не было (заголовки, инструменты сборки), `held` — закрепление
`nvidia-l4t-kernel-headers`, если поставил его сам. `sudo cream remove can-usb`
сначала спрашивает apt в режиме симуляции (снял бы чужие пакеты — отказ до любых
изменений; тогда руками и `sudo cream remove --forget can-usb`), затем убирает
`gs_usb.ko`, `peak_usb.ko`, `slcan.ko` из `updates/can-usb` (`depmod`; загруженный
модуль живёт до отключения адаптера или перезагрузки), снимает **своё** закрепление —
кроме стоявшего до cream или записанного другим расширением
(`/var/lib/cream/ext/*/held`, например `sensing-gmsl2-camera`) — и удаляет свои пакеты.
`sensing-gmsl2-camera` не снимается, пока модули `can-usb` лежат под ядром Sensing.

## Проверки

- **V** — `make cream-validate`, `tools/check-names.sh`.
- **H** — `tests/test-can-usb.sh`: функции `canusb.sh` (барьеры,
  потоковое скачивание со сверкой, раскладка, vermagic, установка с depmod,
  закрепления и порядок шагов `hooks/install`), манифест, `install` на подменённом
  корне (20, штатное ядро до сети, сборка — 10, повтор — 0, заголовки и инструменты из
  apt с записью, версия с чужими символами, сбой скачивания), `remove` (модули,
  закрепление, пакеты, чужое закрепление остаётся, отказ при чужих зависимых).
- **P — ожидает.** Плата AGX Orin с ядром Sensing: сборка образа через bisquite и
  `modinfo -n gs_usb peak_usb slcan` на устройстве.
- **L** — не нужен: в контейнере нет `/etc/nv_tegra_release`, ответ — код 20, его
  проверяет H.
