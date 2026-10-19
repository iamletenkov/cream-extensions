# l4t-boot-verify

Отмечает каждую загрузку Jetson (L4T) успешной — `nvbootctrl verify`.
**Без этого AGX Orin после трёх загрузок перестаёт грузиться вообще.**

> **2.0.0 — cream/v1.** Служба называется `l4t-boot-verify.service` и
> раскладывается cream (`files`); хук `install` маскирует вендорскую
> `nv-l4t-bootloader-config.service` и включает свою, хук `remove` возвращает
> вендорскую как была. Нет `/etc/nv_tegra_release` — код 20 («неприменимо»).

## Манифест

| Поле | Значение |
|---|---|
| `platform.arch` | `arm64` |
| `targets` | `build: exec`, `live: yes` |
| `provides` | `l4t-boot-verify` |
| хуки | `install`, `remove` |
| `files` | `files/l4t-boot-verify.service` → `/etc/systemd/system/l4t-boot-verify.service` |

## Подключение

```vmfile
EXTENSION l4t-boot-verify
```

На живой плате — `cream install l4t-boot-verify` (ключей нет); отметка начнётся
со следующей загрузки. Снять — `cream remove l4t-boot-verify`.

## Что делают хуки

**`install`:**
1. Записывает **один раз** в `/var/lib/cream/ext/l4t-boot-verify/`, что стояло на месте
   `/etc/systemd/system/nv-l4t-bootloader-config.service` (`vendor-unit`: `none`,
   `file` или `link <цель>`; файл — копией `nv-l4t-bootloader-config.service.orig`)
   и в `multi-user.target.wants` (`vendor-wants`). Повтор запись не трогает: иначе
   вторая установка приняла бы свою же маску за состояние вендора.
2. Маскирует вендорскую службу руками — ссылкой на `/dev/null` (`systemctl mask`
   внутри сборки отказывает на существующем файле в `/etc`) и убирает её из
   `multi-user.target.wants`.
3. Включает свою ссылкой в `multi-user.target.wants` — одинаково в сборке и на живой
   машине (после установки cream сам делает `daemon-reload`).

**`remove`:** выключает свою, а на месте вендорской — только если там всё ещё наша
маска — возвращает то, что записал `install` (файл — байт в байт из копии), и её
ссылку в `multi-user.target.wants`. Сам юнит `l4t-boot-verify.service` снимает cream.
**После `remove` загрузку отмечает только вернувшаяся вендорская служба** — см. ниже,
чем это грозит на AGX Orin.

| Код `install` | Когда |
|---|---|
| 0 | служба включена (повтор — тоже 0, без изменений) |
| 20 | нет `/etc/nv_tegra_release` — не L4T |
| 1 | нет `/usr/sbin/nvbootctrl` (пакет `nvidia-l4t-tools`) или ссылка на месте файла состояния |

## Что происходит без отметки

UEFI Jetson считает попытки загрузки корневой системы. На AGX Orin
(L4T 36.4.3) `RootfsRetryCountMax = 3`. Каждая загрузка, которую никто не
отметил успешной, тратит попытку; после трёх подряд UEFI объявляет систему
негодной:

- логотип NVIDIA, затем чёрный экран, сети нет;
- не грузится и внутренний NVMe — состояние общее для платы;
- лечится **только** прошивкой QSPI со станции
  (`l4t_initrd_flash.sh --showlogs --network usb0 p3737-0000-p3701-0000-qspi internal`):
  она сбрасывает переменные UEFI.

Штатно отметку делает `nv-l4t-bootloader-config.service`: юнит зовёт
`nv-l4t-bootloader-config.sh -v`, а тот в самом конце — `nvbootctrl verify`.

## Почему своя служба, а не вендорская

С 2026-09-13 вендорская служба в `jetson-orin-camera`/`jetson-orin-base`
глушилась — диагноз был «она обновляет QSPI и убивает плату». **Для AGX Orin
он неверен**: `auto_update_qspi` в скрипте срабатывает только на Orin Nano
Devkit SKU 0005 и IGX. Заглушив службу, мы выключили отметку, и 2026-09-14
плата отказала ровно на четвёртой загрузке с SSD.

Отказы 2026-09-13, когда служба ещё работала, правдоподобно объясняются тем,
что при загрузке с USB-диска скрипт падал раньше отметки: до `verify` он
пишет переменные UEFI и монтирует ESP. Это не подтверждено, поэтому
вендорская остаётся заглушенной, а отметка делается отдельно и ничем больше.

## Проверено

AGX Orin после прошивки QSPI, 2026-09-14: пять загрузок с SSD подряд,
служба отработала на каждой, `RootfsStatusSlotA` оставался `00`.

## Диагностика

```bash
systemctl status l4t-boot-verify
sudo nvbootctrl dump-slots-info
for v in RootfsRetryCountMax RootfsStatusSlotA; do
  sudo od -An -tx1 /sys/firmware/efi/efivars/$v-781e084c-a330-417c-b678-38e696380cb9
done
```
