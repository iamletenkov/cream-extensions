# lxde

LXDE с менеджером входа lightdm. Даёт X-сервер и сессию расширениям, которым они
нужны, — `x11vnc`, `kiosk`, `selkies`. Автологин, автоблокировка и затемнение — ручки
расширения [`desktop`](../desktop/README.md) (`depends`).

> **С 5.0.0 — формат cream/v1** (план 2026-10-19, Task 13). Каталог в госте —
> `/opt/cream/ext/lxde/`; ручки — домен `desktop` (`/etc/cream/desktop/config`),
> применяет их `cream-configure@desktop` до менеджера входа. Взаимоисключение с
> `gnome`/`xfce4` — по способности `desktop-session`, а не перечнем имён. Таблица
> переименований — ниже.

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
| `files` | `files/60-lxde.conf` → `/etc/xdg/lightdm/lightdm.conf.d/60-lxde.conf` |

## Что делает

**`install`**: ставит `lxde`, `lightdm`, `lightdm-gtk-greeter`, `xorg`,
`xinput`, `x11-xserver-utils`, `dconf-cli`, `usbutils`, `dbus-x11`; пробует браузер
`firefox-esr` (необязательно); включает `lightdm.service` и `graphical.target`. На живой
машине, если менеджер входа или цель загрузки поменялись, — код 10: экран входа
появится после перезагрузки. На сборке — 0.

**Сессия и приветствие** (`user-session=LXDE`, `greeter-session=lightdm-gtk-greeter`)
раскладывает cream полем `files` — drop-in'ом в `/etc/xdg/lightdm/lightdm.conf.d/`,
который lightdm читает после `/usr/share/lightdm/lightdm.conf.d/` и до
`/etc/lightdm/lightdm.conf` (проверено `lightdm --show-config`, Debian 12 и Ubuntu 24.04).
Не `/etc/lightdm/lightdm.conf`: на Debian это conffile пакета (dpkg спросил бы, чей
файл оставить), а cream отказал бы с 67 `conflict.file_unowned` на машине, где lightdm
уже стоит. Автологин и `xserver-command` пишет `desktop` в `/etc/lightdm/lightdm.conf`;
Ubuntu такого файла не ставит — `install` создаёт пустой `[Seat:*]`, если файла нет
(по ссылке не пишет).

**`remove`**: возвращает цель загрузки (что было до `install`; неизвестно —
`multi-user.target`) и выключает lightdm, если до `install` менеджером входа был не он;
снимает `/etc/lightdm/lightdm.conf`, если его создал `install`. Drop-in снимает cream.
**Пакеты остаются** (`apt-get remove` — вручную): на них могут опираться другие
программы. На живой машине при смене цели — код 10.

Браузер — только нативный `firefox-esr` (Debian). В Ubuntu `firefox` — переходник на
snap: он тянет `snapd`, а сам браузер в госте сборки не ставится (тот же замер, что у
`chromium-browser` в [`gnome`](../gnome/README.md)), поэтому в 5.0.0 его больше не пробуем.

## Подключение

```vmfile
EXTENSION desktop DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_LOCK=1 DESKTOP_DISABLE_SCREEN_BLANK=1
EXTENSION lxde
```

На работающей машине:

```bash
sudo cream install --accept-risk lxde           # desktop и cloud-user — по depends
sudo cream set desktop DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_LOCK=1 DESKTOP_DISABLE_SCREEN_BLANK=1
sudo reboot                                     # код 10 install: экран входа — после перезагрузки
```

## Переименования (layout 2 → cream/v1)

<!-- check-names: off -->
| Было (4.x) | Стало (5.0.0) |
|---|---|
| `/opt/bisquite/lxde/install.sh` | `/opt/cream/ext/lxde/hooks/install` |
| `bisquite-desktop set KEY=…` | `cream set desktop KEY=…` |
| `bisquite-desktop status` | `cream run desktop status` |
| `bisquite-desktop.service` | `cream-configure@desktop.service` |
| `/etc/bisquite/desktop/config` | `/etc/cream/desktop/config` |
| `/etc/lightdm/lightdm.conf` из шаблона расширения | drop-in `/etc/xdg/lightdm/lightdm.conf.d/60-lxde.conf` (`files`) |
| `conflicts: [gnome, xfce4]` | `conflicts.capabilities: [desktop-session]` |
| браузер `firefox-esr`, иначе `firefox` | только `firefox-esr` |
<!-- check-names: on -->

## Проверки

- **H** — `tests/test-lxde.sh`: манифест, `install` (пакеты, drop-in, `lightdm.conf` для
  Ubuntu, ссылка не разыменовывается, чужой менеджер входа не перехватывается, код 10
  только на живой машине, повтор ничего не меняет), `remove` (возврат цели и менеджера
  входа, испорченное состояние не исполняется).
- **L** — в ночном прогоне (`tests/live.env`: deps `cloud-user desktop`, debian-12), в PR —
  только `xfce4` (план, Task 13): тот же код, другой набор пакетов. lightdm в контейнере
  не стартует (нет VT и X) — его упавший юнит раннер пока не умеет пропускать.

## Не проверено

На железе lxde в формате cream/v1 не собирался: ключи lightdm и xfconf `desktop`
подтверждены разбором и H, экран входа — нет.

## Диагностика

```bash
cream show desktop; cream run desktop status
lightdm --show-config
systemctl get-default; readlink /etc/systemd/system/display-manager.service
journalctl -b -u lightdm -u cream-configure@desktop
```
