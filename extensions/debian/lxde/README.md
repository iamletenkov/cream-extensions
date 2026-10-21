# lxde

LXDE с менеджером входа lightdm. Даёт X-сервер и сессию расширениям, которым они
нужны, — `x11vnc`, `kiosk`, `selkies`. Автологин, автоблокировка и затемнение —
настройки расширения [`desktop`](../desktop/README.md) (`depends`).

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | amd64, arm64 |
| cream | ≥ 1.0.0 |
| Даёт | `x11-server`, `display-manager`, `desktop-session` |
| Требует | — |
| Зависит от | [`desktop`](../desktop/README.md) |
| Конфликтует с | способность `desktop-session` |
| Хуки | `install`, `remove` |
| Настройка на загрузке | — |
| Живая машина | с `--accept-risk` |

> **Живая машина — с `--accept-risk`.** Ставит рабочий стол LXDE (сотни мегабайт пакетов) и включает менеджер входа lightdm и graphical.target: после перезагрузки экран машины занимает экран входа; другой уже включённый менеджер входа не перехватывается (предупреждение); remove возвращает цель загрузки и менеджер входа, пакеты остаются
<!-- /catalog:facts -->

## Что делает

- **`install`** — ставит `lxde`, `lightdm`, `lightdm-gtk-greeter`, `xorg`,
  `xinput`, `x11-xserver-utils`, `dconf-cli`, `usbutils`, `dbus-x11`; пробует
  браузер `firefox-esr` (необязательно); включает `lightdm.service` и
  `graphical.target`. На живой машине, если менеджер входа или цель загрузки
  поменялись, — код 10: экран входа появится после перезагрузки. На сборке — 0.
  Другой уже включённый менеджер входа не перехватывается (предупреждение).
- **`files`** — сессию и приветствие (`user-session=LXDE`,
  `greeter-session=lightdm-gtk-greeter`) cream раскладывает drop-in'ом
  `files/60-lxde.conf` → `/etc/xdg/lightdm/lightdm.conf.d/60-lxde.conf` (см.
  «Почему drop-in»).
- **`configure`** — нет: настройки применяет `cream-configure@desktop` до
  менеджера входа.
- **`remove`** — возвращает цель загрузки (что было до `install`; неизвестно —
  `multi-user.target`) и выключает lightdm, если до `install` менеджером входа был
  не он; снимает `/etc/lightdm/lightdm.conf`, если его создал `install`. Drop-in
  снимает cream. **Пакеты остаются** (`apt-get remove` — вручную): на них могут
  опираться другие программы. На живой машине при смене цели — код 10.

С `gnome`/`xfce4` и любым другим рабочим столом взаимоисключается по
способности `desktop-session`, а не перечнем имён.

## Параметры

<!-- catalog:params -->
Параметров нет.
<!-- /catalog:params -->

Своих ключей нет. Автологин, блокировка и затемнение — домен `desktop`
(`/etc/cream/desktop/config`): `cream set desktop DESKTOP_AUTOLOGIN=1 …`.

## Установка

На машине с подключённым каталогом ([как подключить](../../../docs/getting-started.md))
— только с `--accept-risk`: ставит сотни мегабайт пакетов и занимает экран
машины экраном входа.

```bash
sudo cream install --with-deps --accept-risk lxde    # desktop и cloud-user — по depends
sudo cream set desktop DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_LOCK=1 DESKTOP_DISABLE_SCREEN_BLANK=1
sudo reboot                                          # код 10 install: экран входа — после перезагрузки
```

В образе bisquite (VMFILE):

```dockerfile
RUN_COMMAND cream install --with-deps desktop DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_LOCK=1 DESKTOP_DISABLE_SCREEN_BLANK=1
RUN_COMMAND cream install --with-deps lxde
```

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | пакеты, drop-in lightdm, `lightdm.service` и `graphical.target`; на живой машине при смене — код 10 |
| загрузка | `cream-configure@desktop` применяет настройки `desktop` до менеджера входа |
| `cream set desktop …` | применяет `desktop` |
| `cream remove` | цель загрузки и менеджер входа — как были; пакеты остаются |

## Известные ограничения

- На железе lxde после перехода на cream/v1 не собирался: ключи lightdm и
  xfconf `desktop` подтверждены разбором и H, экран входа — нет.
- Браузер — только нативный `firefox-esr` (Debian). В Ubuntu `firefox` —
  переходник на snap: он тянет `snapd`, а сам браузер в госте сборки не
  ставится (тот же замер, что у `chromium-browser` в
  [`gnome`](../gnome/README.md)), поэтому его не пробуем.
- `remove` пакеты не снимает.

## Подробности

### Почему drop-in

Drop-in в `/etc/xdg/lightdm/lightdm.conf.d/` lightdm читает после
`/usr/share/lightdm/lightdm.conf.d/` и до `/etc/lightdm/lightdm.conf` (проверено
`lightdm --show-config`, Debian 12 и Ubuntu 24.04). Не `/etc/lightdm/lightdm.conf`:
на Debian это conffile пакета (dpkg спросил бы, чей файл оставить), а cream
отказал бы с 67 `conflict.file_unowned` на машине, где lightdm уже стоит.
Автологин и `xserver-command` пишет `desktop` в `/etc/lightdm/lightdm.conf`;
Ubuntu такого файла не ставит — `install` создаёт пустой `[Seat:*]`, если файла
нет (по ссылке не пишет).

### Диагностика

```bash
cream show desktop; cream run desktop status
lightdm --show-config
systemctl get-default; readlink /etc/systemd/system/display-manager.service
journalctl -b -u lightdm -u cream-configure@desktop
```

## Проверки

- **V** — `make cream-validate`, `tools/lint-hooks.sh`, `make check-names`.
- **H** — `tests/test-lxde.sh`: манифест, `install` (пакеты, drop-in, `lightdm.conf` для
  Ubuntu, ссылка не разыменовывается, чужой менеджер входа не перехватывается, код 10
  только на живой машине, повтор ничего не меняет), `remove` (возврат цели и менеджера
  входа, испорченное состояние не исполняется).
- **L** — в ночном прогоне (`tests/live.env`: deps `cloud-user desktop`, debian-12), в PR —
  только `xfce4`: тот же код, другой набор пакетов. lightdm в контейнере
  не стартует (нет VT и X) — его упавший юнит раннер пока не умеет пропускать.
