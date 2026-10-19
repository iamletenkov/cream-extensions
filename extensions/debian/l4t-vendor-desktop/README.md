# l4t-vendor-desktop

Объявляет рабочий стол, который **уже есть** в образе вендора L4T R32 (Jetson
Nano: Ubuntu 18.04/20.04 с Xorg, gdm3/lightdm и сессией GNOME/Unity/LXDE),
способностями `x11-server`, `display-manager`, `desktop-session` — ничего не
ставит и не меняет, только проверяет, что всё это в образе есть.

```
EXTENSION l4t-vendor-desktop              # образ bisquite (после desktop, до x11vnc/selkies/wallpaper)
sudo cream install l4t-vendor-desktop     # живая плата
sudo cream remove l4t-vendor-desktop      # снимает только запись cream; рабочий стол остаётся
```

## Зачем

`x11vnc`, `selkies` и `kiosk` требуют `x11-server` и `display-manager`,
`wallpaper` — `desktop-session`, а дают их только `gnome`, `xfce4`, `lxde`,
которые рабочий стол **ставят**. На Nano (образ Q-engineering, Ubuntu 20.04,
JetPack 4.6.1) GNOME с gdm3 уже в образе, а репозитории NVIDIA вендор
отключил; переставлять стол из focal значит заменить то, что вендор настроил.
Без поставщика способностей цепочка `jetson-nano-robot` на каталоге 5.0.0 не
разрешалась вовсе.

**Почему отдельное расширение, а не `provides` в `gnome`.** У `gnome` другая
работа — поставить и настроить GNOME (пакеты, Wayland выключен,
`graphical.target`); режим «только проверить» внутри него — второе расширение
в одном манифесте. Здесь — одна ответственность: подтвердить, что обещанное
способностями в образе действительно есть, иначе отказ на сборке, а не на
первой загрузке платы.

## Что проверяет `install`

| Что | Где | Нет — |
|---|---|---|
| L4T R32 | `/etc/nv_tegra_release`, `# R32 (release)` | **20** (не применимо: на R36 и обычном Debian/Ubuntu стол ставят `gnome`/`xfce4`/`lxde`) |
| X-сервер | `/usr/lib/xorg/Xorg` или `/usr/bin/Xorg` | **1** |
| Менеджер входа | ссылка `display-manager.service` на существующий юнит или `/etc/X11/default-display-manager` на существующий бинарь | **1** |
| X-сессия | хотя бы один `/usr/share/xsessions/*.desktop` | **1** |

Чего не хватает — названо в журнале; имена из образа печатаются только
печатаемыми символами. Настроек нет. `remove` ничего не трогает.

## Манифест

| Поле | Значение |
|---|---|
| `platform` | `arm64`, Ubuntu ≥ 18.04 |
| `targets` | `build: exec`, `live: yes` |
| `provides` | `x11-server`, `display-manager`, `desktop-session` |
| `conflicts.capabilities` | `desktop-session` — вместе с `gnome`/`xfce4`/`lxde` не ставится |

Автологин и блокировка экрана — расширение `desktop` (его тянет
`cloud-user-desktop`), как и у остальных рабочих столов.

## Проверки

`tests/test-l4t-vendor-desktop.sh` (H, подменённый корень): все три части на
месте — 0 без apt/dpkg; каждая из трёх пропала — 1 с причиной; не Jetson и
R36 — 20; битая ссылка юнита; управляющие символы в имени сессии не попадают
в журнал.
