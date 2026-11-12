# gnome

GNOME на Xorg (Wayland выключен), менеджер входа gdm3. Даёт X-сервер и сессию
расширениям, которым они нужны, — `x11vnc`, `kiosk`, `selkies`. Автологин,
автоблокировка и затемнение — ручки расширения [`desktop`](../desktop/README.md) (`depends`).

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | amd64, arm64 |
| cream | ≥ 1.0.0 |
| Даёт | `x11-server`, `display-manager`, `desktop-session` |
| Требует | — |
| Зависит от | [`desktop`](../desktop/README.md) |
| Конфликтует с | [`gdm-xorg`](../gdm-xorg/README.md), способность `desktop-session` |
| Хуки | `install`, `remove` |
| Настройка на загрузке | — |
| Живая машина | с `--accept-risk` |

> **Живая машина — с `--accept-risk`.** Ставит рабочий стол GNOME (гигабайты пакетов), выключает Wayland в gdm3 и включает менеджер входа gdm и graphical.target: после перезагрузки экран машины занимает экран входа; другой уже включённый менеджер входа не перехватывается (предупреждение); remove возвращает WaylandEnable, цель загрузки и менеджер входа, пакеты остаются
<!-- /catalog:facts -->

## Что делает

- **`install`** — ставит `task-gnome-desktop`, `gdm3`, `gnome-shell`, `gnome-session`,
  `xorg`, `xinput`, `x11-xserver-utils`, `dconf-cli`, `usbutils`, `dbus-x11`; пробует
  нативный `chromium` (только его, см. «Браузер — только нативный»); выключает Wayland
  в конфиге gdm3, прежнюю строку `WaylandEnable` записав в
  `$CREAM_STATE_DIR/wayland.before`; включает gdm и `graphical.target`. На живой машине,
  если поменялись `WaylandEnable`, менеджер входа или цель загрузки, — код 10 (даже
  когда цель уже `graphical`: gdm читает `WaylandEnable` на старте), экран входа на Xorg
  появится после перезагрузки. На сборке — 0. Другой уже включённый менеджер входа
  (`display-manager.service` → не gdm) не перехватывается — предупреждение. Ссылка
  вместо файла gdm3 или каталога `/etc/gdm3`, конфиг — не обычный файл — отказ (код 1)
  до `apt-get` и любой записи: уже стоящий gdm3 проверяется до долгой установки пакетов.
- Хука `configure` нет: ручки (домен `/etc/cream/desktop/config`) применяет
  `cream-configure@desktop` до gdm. Своих `files` у расширения нет — см. «Какой файл
  читает gdm3».
- **`remove`** — сначала возвращает строку `WaylandEnable` побайтно, как её нашёл
  `install` (заменённая — на место, добавленная — убирается; строку, которую после
  установки поменяли руками, не трогает и предупреждает). Затем возвращает цель загрузки
  (что было до `install`; неизвестно — `multi-user.target`) и выключает gdm, если до
  `install` менеджером входа был не он. **Пакеты остаются** (`apt-get remove` — вручную).
  У установок 5.0.x записи `WaylandEnable` нет — `WaylandEnable=false` остаётся, как
  было. Чужая запись или ссылка вместо файла gdm3 — код 1, ничего не меняется. На живой
  машине при смене цели или `WaylandEnable` — код 10.

Взаимоисключение с `xfce4`/`lxde` — по способности `desktop-session`: любой
другой рабочий стол. С [`gdm-xorg`](../gdm-xorg/README.md) — конфликт по имени (объявлен
с обеих сторон): у строки `WaylandEnable` один владелец. Код правки — общая библиотека
[`lib/gdm-wayland.sh`](../../../lib/gdm-wayland.sh), одна копия с `gdm-xorg`.

## Параметры

<!-- catalog:params -->
Параметров нет.
<!-- /catalog:params -->

Своих ключей нет. Автологин, блокировка и затемнение — ключи `DESKTOP_*`
расширения [`desktop`](../desktop/README.md).

## Установка

На машине с подключённым каталогом ([как подключить](../../../docs/getting-started.md));
`live: confirm` — нужен `--accept-risk`:

```bash
sudo cream install --with-deps --accept-risk gnome          # desktop и cloud-user — по depends
sudo cream set desktop DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_LOCK=1 DESKTOP_DISABLE_SCREEN_BLANK=1
sudo reboot                                                 # код 10 install: экран входа — после перезагрузки
```

В образе bisquite (VMFILE):

```dockerfile
RUN_COMMAND cream install --with-deps desktop DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_LOCK=1 DESKTOP_DISABLE_SCREEN_BLANK=1
RUN_COMMAND cream install --with-deps gnome
```

Поверх `x11vnc` или `kiosk` без `DESKTOP_AUTOLOGIN=1` им не к чему подключаться:
сессии пользователя нет.

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа | пакеты, `WaylandEnable=false` (с записью прежней строки), gdm и `graphical.target` включены; код 0 |
| `cream install` на живой машине | то же; при смене `WaylandEnable`, менеджера входа или цели — код 10, нужна перезагрузка |
| `cream upgrade` с 5.0.x | `install` находит `WaylandEnable=false` от 5.0.x и записывает «было false»; `remove` его оставит |
| загрузка | своего хука нет; `cream-configure@desktop` применяет ручки до gdm |
| `cream remove` | `WaylandEnable`, цель загрузки и менеджер входа возвращены; пакеты остаются |

## Известные ограничения

- На Ubuntu браузера нет (см. «Браузер — только нативный»).
- `remove` пакеты не снимает.
- После обновления с 5.0.x `remove` не возвращает `WaylandEnable`: 5.0.x не записывала
  прежнюю строку, и `false` остаётся (вернуть — вручную в `custom.conf`/`daemon.conf`).
- В формате cream/v1 на железе ещё не собирался.
- В L-прогоне gdm в контейнере не стартует (нет VT и X) — его упавший юнит раннер
  пропускает (`LIVE_FAILED_IGNORE`), экран входа L не проверяет.

## Подробности

### Какой файл читает gdm3

Решено при сборке **пакета**, дистрибутивы расходятся (замер 2026-09-03 распаковкой,
повторён 2026-10-19): Debian — `/etc/gdm3/daemon.conf`, Ubuntu 22.04/24.04 —
`/etc/gdm3/custom.conf`. Запись в другой файл не ошибка и предупреждения не даёт — gdm
его просто не читает. `install` ставит `WaylandEnable=false` в `[daemon]` каждого из двух,
какой есть (`true` — заменяется на месте, нет ключа или закомментирован — новая строка
сразу после заголовка), и больше ничего в них не меняет: повтор файл не переписывает,
режим и владелец сохраняются. Ссылка вместо файла или нет ни одного файла — отказ.

Запись `$CREAM_STATE_DIR/wayland.before` (формат — [`lib/gdm-wayland.sh`](../../../lib/gdm-wayland.sh))
делается до правки, повтор `install` её не перезаписывает. Она хранит по каждому файлу
состояние строки (`absent`, `commented`, `true`, `false`) и что сделано (`none`,
`replaced` с прежней строкой побайтно, `inserted`, `appended`); `remove` по ней возвращает
файл побайтно и снимает запись.

Не `files` cream, как у `xfce4`/`lxde`: оба файла — conffile пакета `gdm3`, и
раскладка поверх них дала бы 67 `conflict.file_unowned` на любой машине, где gdm3 уже
стоит, а drop-in каталога у gdm нет. Автологин в те же файлы пишет `desktop`.

### Wayland выключен, и это несущая связь

`x11vnc`, `xset` и захват экрана (`ximagesrc`) работают только в X11.

### Браузер — только нативный

В Debian `chromium` — обычный deb. В Ubuntu пакета нет, а `chromium-browser` —
переходник на snap: он тянет `snapd`, а сам браузер в госте сборки не ставится (замер
2026-09-12 на AGX Orin). Поэтому на Ubuntu браузера нет; нужен — `epiphany-browser`
или `falkon` отдельным расширением.

### Проверено на (до перехода на cream/v1)

AGX Orin, Ubuntu 22.04 / L4T 36.4.3, 2026-09-14: ручки `0` — экран входа, служба ручек
стартует перед gdm3, циклов упорядочения нет; автологин на лету — сессия, ключи dconf
заблокированы, `xset q` — `DPMS is Disabled`, x11vnc поднимается. В формате cream/v1
на железе ещё не собирался.

### Диагностика

```bash
cream show desktop; cream run desktop status
grep -E 'AutomaticLogin|WaylandEnable' /etc/gdm3/custom.conf /etc/gdm3/daemon.conf 2>/dev/null
systemctl get-default; readlink /etc/systemd/system/display-manager.service
journalctl -b -u gdm -u cream-configure@desktop
journalctl -b | grep -E 'Failed to initialize the NVIDIA|Session never registered'
```

## Проверки

- **H** — `tests/test-gnome.sh`: манифест (конфликт с `gdm-xorg`), библиотека
  `files/gdm-wayland.sh` разложена, `install` (пакеты, четыре исходных состояния строки
  в `daemon.conf` и `custom.conf` пакета gdm3, оба файла, секции нет, ключ чужой секции,
  ссылка или не файл — отказ до apt и записи, нет конфига — отказ, повтор не переписывает ни файл, ни
  запись, код 10 при `graphical` и изменённой строке, 0 при уже `false`), `remove`
  (побайтный возврат с режимом, без записи 5.0.x — строка остаётся, чужая запись — 1 и
  ничего не тронуто, возврат цели и менеджера входа, испорченное состояние не
  исполняется).
- **L** — в ночном прогоне (`tests/live.env`: deps `cloud-user desktop`, debian-12 и
  ночью ubuntu-24.04, 2 ГБ), в PR — только `xfce4`. Упавший в контейнере gdm (нет VT и
  X) раннер пропускает (`LIVE_FAILED_IGNORE`).
