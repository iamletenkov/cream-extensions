# can

Шина CAN на машине: утилиты `can-utils` (`candump`, `cansend`, …), `iproute2`
(`ip link set can0 type can bitrate …`), модули ядра CAN **для ядер машины** и
их автозагрузка через `/etc/modules-load.d/can.conf`.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | amd64, arm64 |
| cream | ≥ 1.0.0 |
| Даёт | `can-bus` |
| Требует | — |
| Зависит от | [`apt-guard`](../apt-guard/README.md) |
| Конфликтует с | — |
| Хуки | `install`, `apply`, `remove` |
| Настройка на загрузке | — |
| Живая машина | да |
<!-- /catalog:facts -->

## Что делает

- **`install`** — ставит пакеты и проверяет модули для каждого ядра машины (таблица
  ниже), затем зовёт `apply`. Ядро не меняется: на Ubuntu добавляется только
  `linux-modules-extra` **уже установленного** ядра, смены и удаления ядра нет.
  Без ядер в `/lib/modules` (контейнер) — код 20 («неприменимо») до любого apt.
- **`apply`** (собственный, спека cream §8.4; его же зовёт `install`) — переписывает
  `/etc/modules-load.d/can.conf` из `CAN_MODULES_LOAD` и, если файл изменился, ставит
  в очередь `systemctl --no-block restart systemd-modules-load`. Своего `configure`
  на загрузке нет: модули грузит `systemd-modules-load`.
- **`remove`** — снимает `/etc/modules-load.d/can.conf` и `can-utils`, если его
  поставил `install` (запись в `/var/lib/cream/ext/can/packages`). **Не**
  снимаются: `iproute2`, `kmod`, `linux-modules-extra-*` и всё, что относится к
  ядрам; загруженные модули — до перезагрузки.

| Что | Откуда |
|---|---|
| `can-utils`, `iproute2`, `kmod` | apt дистрибутива |
| модули `can`, `can_raw`, `can_dev`, `vcan`, `slcan`, `gs_usb`, `peak_usb` | Ubuntu — `linux-modules-extra-<ядро>`, если их нет; Debian — уже в `linux-image-*`; L4T — `nvidia-l4t-kernel`, без `slcan`/`gs_usb`/`peak_usb` (см. «Jetson / L4T») |
| `/etc/modules-load.d/can.conf` | из настройки `CAN_MODULES_LOAD` (по умолчанию `can`, `can_raw`, `vcan`) |

**Ядра — из `/lib/modules`, а не `uname -r`.** Внутри appliance `virt-customize`
`uname -r` — ядро самого appliance, а на работающей машине следующая загрузка
может взять более новое ядро. `hooks/install` перебирает ядра в
`/lib/modules/*/` (с `modules.order`) и для каждого проверяет
`modinfo -k <ядро> <модуль>`; на Ubuntu недостающее ставит пакетом
`linux-modules-extra-<ядро>`. Модуля нет и после этого (облачное ядро Debian,
`linux-kvm` Ubuntu) — **отказ** со списком модулей, а не немой образ без CAN.

USB/serial-адаптеры на ядре Sensing для AGX Orin — отдельное расширение
[`can-usb`](../can-usb/README.md) (сборка модулей под ядро), а не это.

## Параметры

<!-- catalog:params -->
| Ключ | Тип | Умолчание | Что задаёт |
|---|---|---|---|
| `CAN_MODULES_LOAD` | строка `^[a-z0-9_-]+( [a-z0-9_-]+)*$` | `can can_raw vcan` | модули для автозагрузки через пробел; каждый проверяется для ядер машины; пусто — /etc/modules-load.d/can.conf удаляется |
<!-- /catalog:params -->

Домен `can`, файл `/etc/cream/can/config`. При `install` каждый модуль
`CAN_MODULES_LOAD` проверяется для всех ядер машины. При `cream set` хук `apply`
грузит новые модули сразу; модуль, которого нет для текущего ядра, —
предупреждение. Убранные из списка остаются загруженными до перезагрузки
или `sudo modprobe -r <модуль>`. Новый список при `cream set` не сверяется со
всеми ядрами (это делает только `install`); проверить заново —
`sudo cream install --reinstall can`.

## Установка

На живой машине:

```bash
sudo cream install --with-deps can
sudo cream install --with-deps can CAN_MODULES_LOAD="can can_raw vcan mttcan"
cream show can
sudo cream set can CAN_MODULES_LOAD="can can_raw vcan gs_usb"
sudo cream remove can
```

В образе bisquite (VMFILE):

```dockerfile
RUN_COMMAND cream install --with-deps can
RUN_COMMAND cream install --with-deps can CAN_MODULES_LOAD="can can_raw vcan gs_usb"
```

Манифест записи / развёртывания: обычно ничего не нужно — модули и автозагрузка
уже в образе. Свой список — строкой первой загрузки (`firstboot-commands`
манифеста записи, `firstboot_commands` манифеста развёртывания ВМ):

```yaml
firstboot-commands:
  - 'cream set can CAN_MODULES_LOAD="can can_raw vcan peak_usb"'
```

Хук `apply` не ждёт systemd (`systemctl --no-block`), поэтому `cream set`
безопасен и на первой загрузке.

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | пакеты, проверка модулей для всех ядер, `can.conf` (через `apply`) |
| загрузка | модули грузит `systemd-modules-load` по `can.conf` |
| `cream set` (хук `apply`) | `can.conf` переписан, `systemd-modules-load` перезапущен без ожидания |
| `cream remove` | `can.conf` и свой `can-utils` сняты |

## Известные ограничения

- На Ubuntu без метапакета `linux-image-generic*` (база на
  `linux-image-virtual`) `install` предупреждает: следующее ядро из
  `apt upgrade` придёт без `linux-modules-extra`, и CAN после перезагрузки
  пропадёт. Машины на `linux-generic` (Ubuntu Desktop) это не касается.
- На ядре L4T нет `slcan`, `gs_usb`, `peak_usb` — предупреждение, а не отказ (см.
  «Jetson / L4T»). На самой плате Jetson не запускалось.

## Подробности

### Jetson / L4T

Ядро L4T (`<версия>-tegra`, например `5.15.148-tegra` у r36.4.3 / JetPack 6.2)
ставится пакетами NVIDIA, `linux-modules-extra` для него нет — `hooks/install`
его и не ищет: проверяет модули для ядра образа (`modinfo -k`, встроенные —
ещё и по `modules.builtin`) и не трогает apt ядра.

Фактический состав ядра r36.4.3 (`nvidia-l4t-kernel` и
`nvidia-l4t-kernel-oot-modules` 5.15.148-tegra-36.4.3, конфиг — встроенный
в `Image`):

| Модуль | В ядре L4T r36.4.3 |
|---|---|
| `can`, `can_raw`, `can_dev`, `vcan` | модули (`kernel/net/can/`, `kernel/drivers/net/can/`) |
| `mttcan` — родной контроллер CAN Orin | модуль вне дерева: `updates/drivers/net/can/mttcan/` (`nvidia-l4t-kernel-oot-modules`), зависит от `can_dev` |
| `slcan`, `gs_usb`, `peak_usb` | **нет**: `CONFIG_CAN_SLCAN`, `CONFIG_CAN_GS_USB`, `CONFIG_CAN_PEAK_USB` не заданы, ни встроенными, ни модулями |

Поэтому для ядра `*-tegra`:

- `can`, `can_raw`, `can_dev`, `vcan` и всё из `CAN_MODULES_LOAD` —
  обязательны, как везде: нет — **отказ**;
- `slcan`, `gs_usb`, `peak_usb` — **громкое предупреждение**, а не отказ.
  Ни один пакет их не доставит: нужно ядро, пересобранное с этими опциями.
  Отказ сделал бы расширение непригодным на любом Jetson, хотя основной
  интерфейс платы — `mttcan`, а USB/serial-адаптеры (`gs_usb` —
  candleLight/CANable, `peak_usb` — PCAN-USB, `slcan` — адаптеры с
  последовательным протоколом) — дополнительный. Нужен такой адаптер —
  впишите его модуль в `CAN_MODULES_LOAD`: тогда отсутствие станет отказом,
  а не предупреждением. Пункт `modinfo -n vcan gs_usb peak_usb slcan` из
  чек-листа рабочей машины на штатном ядре L4T не пройдёт.

Для AGX Orin с ядром Sensing на L4T 36.4.3 эти три модуля собирает при
сборке образа расширение [`can-usb`](../can-usb/README.md) — слоем после
`sensing-gmsl2-camera`; с ним пункт чек-листа проходит.

Рекомендованный список автозагрузки для Jetson (не умолчание —
умолчание общее для всех платформ):

```dockerfile
RUN_COMMAND cream install --with-deps can CAN_MODULES_LOAD="can can_raw vcan mttcan"
```

`mttcan` — драйвер контроллеров CAN самого SoC (интерфейсы `can0`, `can1`;
трансивер на шину — внешний).

### Проверка

```bash
which candump cansend                         # обе утилиты
modinfo -n vcan gs_usb peak_usb slcan         # четыре пути к модулям
cat /etc/modules-load.d/can.conf
lsmod | grep vcan                             # после перезагрузки
sudo ip link add dev vcan0 type vcan && sudo ip link set vcan0 up
candump vcan0 &  cansend vcan0 123#DEADBEEF   # кадр виден в candump
```

### Проверено на

До перехода на cream/v1 — в контейнерах `ubuntu:24.04` (ядро
6.8.0-147-generic, модули доставлены `linux-modules-extra`) и `debian:12`
(6.1.0-53-amd64) с ядром, поставленным в контейнер.

arm64 / L4T (до перехода на cream/v1, 2026-10-15) — контейнер `ubuntu:22.04` arm64 (qemu-user)
с раскладкой ядра L4T r36.4.3: `/lib/modules/5.15.148-tegra` из
`nvidia-l4t-kernel` плюс `updates/` из `nvidia-l4t-kernel-oot-modules`
(`modules.dep` пакета уже знает `mttcan`). Умолчание — успех, три
предупреждения (`slcan`, `gs_usb`, `peak_usb`), `linux-modules-extra` не
ставится, `can.conf` = `can can_raw vcan`; `CAN_MODULES_LOAD` с `mttcan` —
успех; с `gs_usb` — отказ; `can_raw`, перенесённый во встроенные
(`modules.builtin`, без файла `.ko`), — найден; удалённый `vcan` — отказ.
На самой плате не запускалось.

## Проверки

- **H** — `tests/test-can.sh` (хуки на подменённом корне: нет ядер — 20,
  Debian, Ubuntu с `linux-modules-extra`, несколько ядер, `modules.builtin`,
  L4T с `mttcan` и без USB-модулей, `apply` с systemd и без, `remove`).
- **L** — `make test-live EXT=can` (`debian-12`, `ubuntu-24.04`): в контейнере ядер
  нет, `install` обязан вернуть 20 (`LIVE_EXPECT_SKIP=1`).
