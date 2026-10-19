# gnome

GNOME на Xorg (Wayland выключен), менеджер входа gdm3. Даёт X-сервер и сессию
расширениям, которым они нужны, — `x11vnc`, `kiosk`, `selkies`. Автологин,
автоблокировка и затемнение — ручки расширения [`desktop`](../desktop/README.md) (`depends`).

> **С 5.0.0 — формат cream/v1** (план 2026-10-19, Task 13). Каталог в госте —
> `/opt/cream/ext/gnome/`; ручки — домен `desktop` (`/etc/cream/desktop/config`),
> применяет их `cream-configure@desktop` до gdm. Взаимоисключение с `xfce4`/`lxde` —
> по способности `desktop-session`, а не перечнем имён.

## Манифест

| Поле | Значение |
|---|---|
| `version` | `5.0.0`, `cream: ">=1.0.0"` |
| `platform` | `deb`, `amd64`/`arm64`, Debian и Ubuntu |
| `targets` | `build: exec`, `live: confirm` (на живой машине — `--accept-risk`) |
| `provides` | `x11-server`, `display-manager`, `desktop-session` |
| `depends` | `desktop >=1.0.0 <2` |
| `conflicts` | `capabilities: [desktop-session]` — любой другой рабочий стол |
| хуки | `install`, `remove` (без `configure`: ручки применяет `desktop`) |
| `files` | нет — см. «Какой файл читает gdm3» |

## Что делает

**`install`**: ставит `task-gnome-desktop`, `gdm3`, `gnome-shell`, `gnome-session`,
`xorg`, `xinput`, `x11-xserver-utils`, `dconf-cli`, `usbutils`, `dbus-x11`; пробует
нативный `chromium` (только его, см. ниже); выключает Wayland в конфиге gdm3; включает
gdm и `graphical.target`. На живой машине, если менеджер входа или цель загрузки
поменялись, — код 10: экран входа появится после перезагрузки. На сборке — 0.
Другой уже включённый менеджер входа (`display-manager.service` → не gdm) не
перехватывается — предупреждение.

**`remove`**: возвращает цель загрузки (что было до `install`; неизвестно —
`multi-user.target`) и выключает gdm, если до `install` менеджером входа был не он.
**Пакеты остаются** (`apt-get remove` — вручную), `WaylandEnable=false` в конфиге gdm3
тоже. На живой машине при смене цели — код 10.

## Какой файл читает gdm3

Решено при сборке **пакета**, дистрибутивы расходятся (замер 2026-09-03 распаковкой,
повторён 2026-10-19): Debian — `/etc/gdm3/daemon.conf`, Ubuntu 22.04/24.04 —
`/etc/gdm3/custom.conf`. Запись в другой файл не ошибка и предупреждения не даёт — gdm
его просто не читает. `install` ставит `WaylandEnable=false` сразу после заголовка
`[daemon]` в каждом из двух, какой есть, и больше ничего в них не меняет (повтор файл не
переписывает, по ссылке не пишет). Нет ни одного обычным файлом — отказ.

Не `files` cream, как у `xfce4`/`lxde`: оба файла — conffile пакета `gdm3`, и
раскладка поверх них дала бы 67 `conflict.file_unowned` на любой машине, где gdm3 уже
стоит, а drop-in каталога у gdm нет. Автологин в те же файлы пишет `desktop`.

## Wayland выключен, и это несущая связь

`x11vnc`, `xset` и захват экрана (`ximagesrc`) работают только в X11.

## Браузер — только нативный

В Debian `chromium` — обычный deb. В Ubuntu пакета нет, а `chromium-browser` —
переходник на snap: он тянет `snapd`, а сам браузер в госте сборки не ставится (замер
2026-09-12 на AGX Orin). Поэтому на Ubuntu браузера нет; нужен — `epiphany-browser`
или `falkon` отдельным расширением.

## Подключение

```vmfile
EXTENSION desktop DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_LOCK=1 DESKTOP_DISABLE_SCREEN_BLANK=1
EXTENSION gnome
```

На работающей машине:

```bash
sudo cream install --accept-risk gnome          # desktop и cloud-user — по depends
sudo cream set desktop DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_LOCK=1 DESKTOP_DISABLE_SCREEN_BLANK=1
sudo reboot                                     # код 10 install: экран входа — после перезагрузки
```

Поверх `x11vnc` или `kiosk` без `DESKTOP_AUTOLOGIN=1` им не к чему подключаться:
сессии пользователя нет.

## Проверки

- **H** — `tests/test-gnome.sh`: манифест, `install` (пакеты, `WaylandEnable` в
  `daemon.conf`/`custom.conf`/обоих, секции нет, ключа нет, ключ чужой секции, ссылка не
  разыменовывается, нет конфига — отказ, повтор не переписывает файл, код 10 только на
  живой машине), `remove` (возврат цели и менеджера входа, испорченное состояние не
  исполняется).
- **L** — в ночном прогоне (`tests/live.env`: deps `cloud-user desktop`, debian-12,
  2 ГБ), в PR — только `xfce4` (план, Task 13). gdm в контейнере не стартует (нет VT и
  X) — его упавший юнит раннер пока не умеет пропускать.

## Проверено (layout 2)

AGX Orin, Ubuntu 22.04 / L4T 36.4.3, 2026-09-14: ручки `0` — экран входа, служба ручек
стартует перед gdm3, циклов упорядочения нет; автологин на лету — сессия, ключи dconf
заблокированы, `xset q` — `DPMS is Disabled`, x11vnc поднимается. В формате cream/v1
на железе ещё не собирался.

## Диагностика

```bash
cream show desktop; cream run desktop status
grep -E 'AutomaticLogin|WaylandEnable' /etc/gdm3/custom.conf /etc/gdm3/daemon.conf 2>/dev/null
systemctl get-default; readlink /etc/systemd/system/display-manager.service
journalctl -b -u gdm -u cream-configure@desktop
journalctl -b | grep -E 'Failed to initialize the NVIDIA|Session never registered'
```
