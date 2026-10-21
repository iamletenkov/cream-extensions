# desktop

Ручки рабочего стола, общие для `gnome`, `xfce4`, `lxde` и `cloud-user-desktop`:
автологин (gdm3, lightdm), отказ от автоблокировки и затемнения (dconf, X DPMS,
xfconf, lxsession) и группы пользователя сеанса. Один код на все менеджеры входа,
чтобы расширения рабочего стола не расходились, как расходились их копии
`disable_powersave.sh`.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | amd64, arm64 |
| cream | ≥ 1.2.0 |
| Даёт | — |
| Требует | — |
| Зависит от | [`cloud-user`](../cloud-user/README.md) |
| Конфликтует с | — |
| Хуки | `install`, `configure`, `remove` |
| Настройка на загрузке | стадия `system`, на каждой загрузке (`every_boot`) |
| Действия | `cream run desktop apply`, `cream run desktop status`, `cream run desktop defaults` |
| Живая машина | да |
<!-- /catalog:facts -->

## Что делает

- **`install`** — ставит `dconf-cli`, `x11-xserver-utils` и применяет ручки (как
  `apply`, без ожидания пользователя).
- **`configure`** — на каждой загрузке, стадия `system`: после
  `cloud-init.service` и `guestfs-firstboot.service`, до `display-manager.service`,
  `gdm.service`, `gdm3.service`, `lightdm.service`; пишет файлы ручек и вносит
  пользователя в группы (см. «Кто применяет и когда»).
- **`remove`** — снимает файлы dconf, X и xfconf и выключает автологин в
  конфигах gdm3/lightdm (сами конфиги — пакетов), снимает `screensaver=disabled` из
  системного `desktop.conf` lxsession; группы пользователя и правка его собственного
  `desktop.conf` остаются. Пакеты `dconf-cli`, `x11-xserver-utils` не снимаются.

Что пишет каждая ручка:

| Ручка | Файлы |
|---|---|
| автологин | `/etc/gdm3/daemon.conf` и `custom.conf` (`[daemon]`), `/etc/lightdm/lightdm.conf` и `lightdm.conf.d/*.conf` (`[Seat:*]` или прежняя `[SeatDefaults]`) |
| блокировка | `/etc/dconf/db/local.d/50-desktop-screen-lock` + `locks/`, профиль `/etc/dconf/profile/user` (`system-db:local`, то же правило, что у `locale`); xfce4-screensaver |
| затемнение | `/etc/dconf/db/local.d/50-desktop-screen-blank` + `locks/`, `gdm.d/` при профиле gdm, `/etc/X11/Xsession.d/90-desktop-disable-dpms`, xfce4-power-manager, `xserver-command=X -s 0 -dpms` у lightdm, `screensaver=disabled` у lxsession (`/etc/xdg/lxsession/LXDE/desktop.conf`) |

Каналы xfconf — `<канал>.desktop-ext.xml` в `/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/`
и ссылка `<канал>.xml` на него, только если канала там ещё нет. `dconf update` — только
при изменении: повторный configure систему не меняет.

**В домашний каталог root не пишет.** Всё — системные умолчания в `/etc`. Единственное
исключение — уже существующий `~/.config/lxsession/LXDE/desktop.conf` (lxsession заводит его
при первой правке настроек и дальше читает только его): ключ `screensaver` в нём правится
**от имени пользователя** (`runuser -u`), и только если ни один компонент пути не ссылка
и настоящий путь не выходит из домашнего каталога; иначе — предупреждение, файл не трогается.
Процесс пользователя не получает ничего от cream: дескрипторы выше stderr (в том числе
блокировка домена `CREAM_LOCK_FD`) закрыты, stdin — `/dev/null`, окружение — только `PATH`
и `LANG`, вывод — во временный файл, предел — 30 с (`timeout`). От root подкоманда отказывает.
Системный `desktop.conf`, созданный расширением (маркер в `/var/lib/cream/ext/desktop`),
при выключении ручки и в `remove` удаляется целиком; у файла пакета снимается только ключ.

## Параметры

<!-- catalog:params -->
| Ключ | Тип | Умолчание | Что задаёт |
|---|---|---|---|
| `DESKTOP_AUTOLOGIN` | `bool` | `0` | 1 — вход без пароля (gdm3, lightdm) |
| `DESKTOP_AUTOLOGIN_USER` | строка `^[a-z_][a-z0-9_-]{0,31}$` | пусто | пользователь автологина и групп сеанса; пусто — пользователь cloud-init (библиотека cloud-user) |
| `DESKTOP_DISABLE_SCREEN_LOCK` | `bool` | `0` | 1 — без автоблокировки экрана (заблокировать вручную можно) |
| `DESKTOP_DISABLE_SCREEN_BLANK` | `bool` | `0` | 1 — без затемнения, гашения, DPMS и сна |
<!-- /catalog:params -->

Домен — `/etc/cream/desktop/config`.

| Ключ | Что делает |
|---|---|
| `DESKTOP_AUTOLOGIN` | `1` — вход без пароля |
| `DESKTOP_AUTOLOGIN_USER` | пользователь автологина и групп; пусто — пользователь cloud-init (библиотека [`cloud-user`](../cloud-user/README.md)) |
| `DESKTOP_DISABLE_SCREEN_LOCK` | `1` — без автоблокировки (вручную заблокировать можно) |
| `DESKTOP_DISABLE_SCREEN_BLANK` | `1` — без затемнения, гашения, DPMS и сна |

Выключенная ручка — это «нашего файла нет»: действует поведение ОС, а не наше «выключено».

## Установка

На машине с подключённым каталогом ([как подключить](../../../docs/getting-started.md)):

```bash
sudo cream install --with-deps desktop
sudo cream set desktop DESKTOP_AUTOLOGIN=1    # cream перезапускает cream-configure@desktop
cream show desktop
cream run desktop status
```

В образе bisquite (VMFILE) — значения ложатся в домен до хука `install`:

```dockerfile
RUN_COMMAND cream install --with-deps desktop DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_BLANK=1
```

На первой загрузке (guestfs-firstboot) — `cream set desktop DESKTOP_AUTOLOGIN=1`:
configure стоит после guestfs-firstboot и применит до менеджера входа.

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | пакеты `dconf-cli`, `x11-xserver-utils`; ручки применяются без ожидания |
| загрузка (`cream-configure@desktop`) | `CREAM_REASON=boot`: ждёт пользователя до 30 с, пишет файлы, группы, ничего не перезапускает |
| `cream set` (перезапуск `cream-configure@desktop`) | то же без ожидания; при смене автологина — перезапуск менеджера входа, если нет графической сессии |
| `cream remove` | файлы ручек сняты, автологин выключен; группы и пакеты остаются |

Действия:

| Действие | Что делает |
|---|---|
| `cream run desktop apply [--now\|--boot]` | применить сейчас (`--now`, умолчание) или как на загрузке |
| `cream run desktop status` | ручки и что применено (dconf, X DPMS); только читает |
| `cream run desktop defaults KEY=VALUE…` | записать без применения — `cream set --no-apply desktop …` (сборка, скрипты) |

## Известные ограничения

- Открытую графическую сессию `apply` не обрывает: изменение автологина
  применится со следующей загрузки.
- Нет менеджера входа или пользователя — предупреждение и 0; автологин не
  включается (экран входа лучше чёрного экрана).
- Автологин на настоящем рабочем столе проверяется только через L `xfce4` и
  сборку через bisquite.

## Подробности

### Кто применяет и когда

**configure — на каждой загрузке, до менеджера входа**: стадия `system`
с `before` менеджеров входа, а не `graphical` — та стоит `After=display-manager`, и gdm
успел бы стартовать со старым автологином. После `cloud-init.service` (там создаётся
пользователь), **не** после `cloud-final`: тот упорядочен после `multi-user.target`, и
связка с ним дважды давала молчаливый цикл, из-за которого systemd выбрасывал gdm.

- `CREAM_REASON=boot` — ждёт пользователя до 30 с (userdata ещё не дочитана), пишет
  файлы, ничего не перезапускает. Не нашёлся — автологин не включается (экран входа
  лучше чёрного экрана), код 0.
- `install`, `apply` (после `cream set`) — то же без ожидания; если автологин в конфиге
  менеджера изменился, менеджер работает и графической сессии нет — перезапуск
  `systemctl --no-block restart <dm>`. Открытую сессию не обрывает: применится со следующей загрузки.
- Нет менеджера входа или пользователя — предупреждение и 0.

**Группы до сессии.** Пользователь вносится в `video render audio pulse input dialout
plugdev` (те, что есть). Xorg автологина без `video` не открывает GPU («Failed to
initialize the NVIDIA graphics device», AGX Orin 2026-09-14), а `systemd --user`
навсегда запоминает группы на момент старта.

### Для расширений рабочего стола

- `depends: [{name: desktop, version: ">=1.0.0 <2"}]`; ставить свою службу и ссылку
  на CLI не нужно — configure расширения `desktop` включает cream.
- Умолчания образа — параметрами `desktop` (`RUN_COMMAND cream install --with-deps
  desktop DESKTOP_AUTOLOGIN=1`), а не параметрами `gnome`/`xfce4`/`lxde`: ключи
  `DESKTOP_*` принадлежат домену `desktop`.
- Менеджер входа, поставленный после `desktop` на живой машине, подхватит автологин на
  следующей загрузке (хук `install` рабочего стола всё равно возвращает 10 из-за
  `set-default graphical.target`); сразу — `cream run desktop apply` из хука или руками.
- Файлы `daemon.conf`/`lightdm.conf` рабочих столов ссылаются на ручку
  `DESKTOP_AUTOLOGIN` расширения `desktop`.

## Проверки

- **H** — `tests/test-desktop.sh`: gdm3 (Debian `daemon.conf`, Ubuntu `custom.conf`), lightdm
  (`Seat:*`, `SeatDefaults`), xfconf, lxsession, загрузка/живая машина, перезапуск менеджера
  входа, действия, `remove`, повтор без изменений.
- **L** — `make test-live EXT=desktop` — контейнер без менеджера входа и пользователя: configure 0,
  файлы dconf на месте, повтор и `--reinstall` без изменений, `remove`.
- Порядок загрузки с gdm3 и cloud-init (стадия `system` до менеджера входа, без `ordering
  cycle`) — интеграция cream `test/integration/desktop`. Автологин на настоящем рабочем
  столе — L `xfce4` и сборка через bisquite.
