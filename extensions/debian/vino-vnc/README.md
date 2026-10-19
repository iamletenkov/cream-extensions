# vino-vnc

VNC через `vino` — штатный VNC-сервер GNOME, живёт внутри сессии пользователя
cloud-init. По умолчанию слушает только петлю (доступ — SSH-туннелем).

> **С 5.0.0 — формат cream/v1** (план 2026-10-19, Task 18). Каталог в госте —
> `/opt/cream/ext/vino-vnc/`; настройки — домен `vino-vnc` (`/etc/cream/vino-vnc/config`,
> пароль — в `/etc/cream/vino-vnc/secrets`); донастройка — `cream-configure@vino-vnc`
> (стадия `system` до менеджера входа). **В домашний каталог больше ничего не пишется**:
> настройки — системные базы dconf с блокировками, автозапуск — `/etc/xdg/autostart`.
> Таблица переименований — ниже.

## Зачем отдельное расширение, а не режим `x11vnc`

Общего кода почти нет, и это видно по устройству обоих:

| | `x11vnc` | `vino-vnc` |
|---|---|---|
| Кто запускает | системный юнит `x11vnc@<user>.service` | автозапуск XDG внутри сессии |
| Как находит дисплей | обёртка ищет X authority в рантайме | никак: он уже внутри сессии |
| Как настраивается | аргументы командной строки в обёртке | системные базы dconf с блокировками |
| Что ломается | путь к authority | отсутствие сессии |

Ни обёртки, ни authority, ни системного юнита у vino не бывает: он часть
GNOME и живёт внутри пользовательской сессии. Свести их в одно расширение
значило бы написать два непересекающихся скрипта под одним именем.

Зачем тогда второй сервер вообще: `vino` — то, что на GNOME-плате уже есть
в репозитории и что настраивает штатная панель «Общий доступ к рабочему
столу». Замер на Jetson Nano (2026-09-03) показал рабочую конфигурацию
именно через него.

## Манифест

| Поле | Значение |
|---|---|
| `version` | `5.0.0`, `cream: ">=1.0.0"` |
| `targets` | `build: exec`, `live: yes` |
| `provides` / `requires` | `remote-desktop` / `x11-server`, `display-manager` |
| `depends` | `cloud-user >=1.0.0 <2` — группа пользователя сессии для базы пароля |
| хуки | `install`, `configure` (стадия `system`, `after: [cloud-init.service]`, `before: [display-manager.service, gdm.service, gdm3.service, lightdm.service]` — рулинг Р5), `remove`; своего `apply` нет — `cream set` перезапускает configure |

## Параметры (`cream set vino-vnc …`)

| Ключ | Умолчание | Что делает |
|---|---|---|
| `VINO_PORT` | `5900` | порт 5000–50000 (диапазон `alternative-port` схемы `org.gnome.Vino`) |
| `VINO_LISTEN` | `localhost` | `localhost` — только петля, `all` — все интерфейсы |
| `VINO_ENCRYPTION` | `false` | `require-encryption` |
| `VINO_PASSWORD` | пусто | секрет (`secret: file`); пусто — без аутентификации |

```bash
echo 'пароль' | sudo cream set vino-vnc VINO_PASSWORD=-   # только stdin
sudo cream set vino-vnc VINO_LISTEN=all
```

Значимы первые 8 символов пароля. На работающей машине изменение доходит до vino
со следующего входа в сессию (или перезагрузки): базы dconf читаются при открытии сессии.

## Что делает

- **`install`**: `vino`, `dconf-cli`, `libglib2.0-bin`, `dbus`; автозапуск
  `/etc/xdg/autostart/vino-server.desktop` — копия `.desktop` пакета с
  `X-GNOME-Autostart-enabled=true` (у пользовательского юнита vino нет `[Install]`, а путь
  к бинарю зависит от выпуска — поэтому копия, а не свой файл).
- **`configure`** — на каждой загрузке до менеджера входа и после `cream set`:
  - `/etc/dconf/db/vino-vnc` (0644): `prompt-enabled=false` (подтверждать некому),
    `require-encryption`, `authentication-methods` (`['vnc']` с паролем, `['none']` без),
    `network-interface` (`'lo'` или все), порт; все ключи **заблокированы** — база
    пользователя их не перекрывает;
  - `/etc/dconf/db/vino-vnc-secret` (0640 `root:<основная группа пользователя сессии>`):
    `vnc-password` в base64 (так хочет ключ — то есть сам пароль), заблокирован. Читает её
    только пользователь сессии, другим dconf отказывает. Пароля нет — базы нет;
  - `/etc/dconf/profile/user`: строки `system-db:vino-vnc-secret` и `system-db:vino-vnc`
    (профиль `desktop` с `system-db:local` сохраняется).
- **`remove`**: базы, строки профиля и автозапуск сняты; пакет `vino` — только если его
  поставил этот `install`.

## Пароль (рулинг Р4 плана)

Пароль читается `cream config get --secret` в переменную оболочки и уходит только
через канал (`printf`, `base64`) в ключевой файл во временном каталоге 0700 (`umask 077`);
`dconf compile` собирает базу там же, группа и права ставятся до переименования на
место — окна с широкими правами нет, в `ps`, журнал и окружение дочерних процессов
пароль не попадает. Каталога `*.d` нет, поэтому `dconf update` других расширений эти
базы не пересобирает (он записал бы 0644). Ссылка на месте базы или профиля — сбой
`configure`. Повтор с теми же значениями ничего не переписывает.

Нет пользователя cloud-init (контейнер) — предупреждение и 0 (Р11): база пароля
остаётся только для root, vino пароля не видит и отказывает всем.

## Wayland

**vino обслуживает X11 и на Wayland-сессии бесполезен.** Связь с соседним
расширением здесь несущая и в манифестах не выражается: Xorg включает
десктопное расширение — `gnome` ставит `WaylandEnable=false` в тот файл GDM,
который этот дистрибутив действительно читает (`daemon.conf` у Debian,
`custom.conf` у Ubuntu). Поставите vino поверх сессии на Wayland — сервер
запустится и не покажет ничего.

Проверить на плате:

```console
$ loginctl show-session "$(loginctl list-sessions --no-legend | awk 'NR==1{print $1}')" -p Type
Type=x11
```

## Соседство с x11vnc

Конфликт не объявлен: мешают друг другу не расширения, а их умолчания (оба берут порт
5900). Разводится параметром — `VINO_PORT=5901` или `X11VNC_PORT=5901`.

## Ограничения

Расширение **не** поднимает менеджер входа, не настраивает автологин и не выключает
Wayland — это работа рабочего стола (`gnome`) и `desktop`. vino живёт внутри сессии,
поэтому без `cream set desktop DESKTOP_AUTOLOGIN=1` до входа человека VNC не поднимется.
Порт в межсетевом экране не открывает.

## Переименования (layout 2 → cream/v1)

<!-- check-names: off -->
| Было (4.x) | Стало (5.0.0) |
|---|---|
| домен `vino`, `/etc/bisquite/vino/config` | домен `vino-vnc`, `/etc/cream/vino-vnc/config` (+ `secrets`) |
| `bisquite-conf set vino …` | `cream set vino-vnc …` |
| `VINO_PASSWORD` — `secret:hook`, `VINO_PASSWORD_FILE` — `ro:path`, `/etc/vino/vnc-password.b64` | `VINO_PASSWORD` — `secret: file`; производное — база `/etc/dconf/db/vino-vnc-secret` |
| `configure-vino-vnc.service` (после `cloud-final`) | `cream-configure@vino-vnc.service` (после `cloud-init.service`, до менеджера входа) |
| `gsettings` от имени пользователя в `~/.config/dconf/user` | системные базы dconf с блокировками |
| `~/.config/autostart/vino-server.desktop` | `/etc/xdg/autostart/vino-server.desktop` |
<!-- check-names: on -->

## Проверки

- **H** — `tests/test-vino-vnc.sh`: манифест; автозапуск в `/etc/xdg`; нет пароля — нет
  секретной базы, `['none']`; есть — база 0640 с группой пользователя, пароля нет в
  общей базе, argv, окружении и журнале; повтор не переписывает; ссылка на месте базы
  или профиля — сбой; профиль `desktop` сохраняется; отказ `dconf compile` — сбой;
  `remove`; в домашний каталог не пишется ничего.
- **L** — `make test-live EXT=vino-vnc` (`tests/live.env`: deps `cloud-user desktop xfce4`,
  секрет `VINO_PASSWORD`, debian-12). Вручную 2026-10-19 на debian:12 с настоящим
  `dconf`: значения и блокировки читаются пользователем сессии, другой пользователь
  базу пароля не открывает.

## Диагностика

```bash
cream show vino-vnc; systemctl status cream-configure@vino-vnc
ls -l /etc/dconf/db/vino-vnc*; cat /etc/dconf/profile/user
dconf read /org/gnome/desktop/remote-access/authentication-methods   # от имени пользователя
dconf list-locks /org/gnome/desktop/remote-access/
```

## Проверено на

| Что | Как | Дата |
|---|---|---|
| ключи и умолчания `org.gnome.Vino` | схема из пакетов focal и noble — совпадают побайтово по ключам | 2026-09-03 |
| отсутствие `[Install]` в юните, `Exec=` в `.desktop`, отсутствие `/etc/xdg/autostart` | распакованные пакеты 3.22.0-5ubuntu2.2 (focal) и 3.22.0-6ubuntu5 (noble) | 2026-09-03 |
| доступность `vino` по выпускам Ubuntu | Launchpad `getPublishedSources` | 2026-09-03 |
| рабочая конфигурация на Jetson Nano | Ubuntu 20.04, GNOME/GDM3, `0.0.0.0:5900` | 2026-09-03 |
| сборка образа с этим расширением | — | **не проверялось** |

Схема и пакеты замерены 2026-09-03 (layout 2); формат cream/v1 на железе ещё не проверялся.
