# desktop

Ручки рабочего стола, общие для `gnome`, `xfce4`, `lxde` и `cloud-user-desktop`:
автологин (gdm3, lightdm), отказ от автоблокировки и затемнения (dconf, X DPMS,
xfconf, lxsession) и группы пользователя сеанса. Один код на все менеджеры входа,
чтобы расширения рабочего стола не расходились, как расходились их копии
`disable_powersave.sh`. Новое расширение cream/v1 (план 2026-10-19, Task 12):
заменяет общий код layout 2 и его CLI.

## Манифест

| Поле | Значение |
|---|---|
| `version` | `1.0.0`, `cream: ">=1.0.0"` |
| `targets` | `build: exec`, `live: yes` |
| `depends` | `cloud-user >=1.0.0 <2` — имя пользователя cloud-init |
| хуки | `install` (dconf-cli, x11-xserver-utils), `configure`, `remove` |
| `configure` | стадия `system`, `after: [cloud-init.service, guestfs-firstboot.service]`, `before: [display-manager.service, gdm.service, gdm3.service, lightdm.service]` |
| действия | `apply` (`lock: exclusive`), `status` (`lock: none`), `defaults` (`lock: exclusive`, и при сборке) |

## Ручки (`/etc/cream/desktop/config`)

| Ключ | Умолчание | Что делает |
|---|---|---|
| `DESKTOP_AUTOLOGIN` | `0` | `1` — вход без пароля |
| `DESKTOP_AUTOLOGIN_USER` | пусто | пользователь автологина и групп; пусто — пользователь cloud-init |
| `DESKTOP_DISABLE_SCREEN_LOCK` | `0` | `1` — без автоблокировки (вручную заблокировать можно) |
| `DESKTOP_DISABLE_SCREEN_BLANK` | `0` | `1` — без затемнения, гашения, DPMS и сна |

Выключенная ручка — это «нашего файла нет»: действует поведение ОС, а не наше «выключено».

| Где | Как |
|---|---|
| сборка образа | `EXTENSION desktop DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_BLANK=1` (значения ложатся в домен до хука `install`) |
| первая загрузка (guestfs-firstboot) | `cream set desktop DESKTOP_AUTOLOGIN=1` — configure стоит после guestfs-firstboot и применит до менеджера входа |
| работающая машина | `sudo cream set desktop DESKTOP_AUTOLOGIN=1` — cream перезапускает `cream-configure@desktop` |
| просмотр | `cream show desktop`, `cream run desktop status` |

## Кто применяет и когда

**configure — на каждой загрузке, до менеджера входа** (рулинг Р5 плана): стадия `system`
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
- Нет менеджера входа или пользователя — предупреждение и 0 (Р11).

**Группы до сессии.** Пользователь вносится в `video render audio pulse input dialout
plugdev` (те, что есть). Xorg автологина без `video` не открывает GPU («Failed to
initialize the NVIDIA graphics device», AGX Orin 2026-09-14), а `systemd --user`
навсегда запоминает группы на момент старта.

## Что пишет

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

## Действия

| Действие | Что делает |
|---|---|
| `cream run desktop apply [--now\|--boot]` | применить сейчас (`--now`, умолчание) или как на загрузке |
| `cream run desktop status` | ручки и что применено (dconf, X DPMS); только читает |
| `cream run desktop defaults KEY=VALUE…` | записать без применения — `cream set --no-apply desktop …` (сборка, скрипты) |

## Для расширений рабочего стола (Task 13, 14, 16, 18)

- `depends: [{name: desktop, version: ">=1.0.0 <2"}]` вместо вызова общего кода из
  `install.sh`; ставить службу и ссылку на CLI больше не нужно — configure расширения
  `desktop` включает cream.
- Умолчания образа — параметрами `desktop` (`EXTENSION desktop DESKTOP_AUTOLOGIN=1`),
  а не параметрами `gnome`/`xfce4`/`lxde`: ключи `DESKTOP_*` принадлежат домену `desktop`.
- Менеджер входа, поставленный после `desktop` на живой машине, подхватит автологин на
  следующей загрузке (хук `install` рабочего стола всё равно возвращает 10 из-за
  `set-default graphical.target`); сразу — `cream run desktop apply` из хука или руками.
- Файлы `daemon.conf`/`lightdm.conf` рабочих столов ссылаются на ручку
  `DESKTOP_AUTOLOGIN` расширения `desktop`.

## Удаление

`cream remove desktop` снимает файлы dconf, X и xfconf и выключает автологин в
конфигах gdm3/lightdm (сами конфиги — пакетов), снимает `screensaver=disabled` из
системного `desktop.conf` lxsession; группы пользователя и правка его собственного
`desktop.conf` остаются. Пакеты `dconf-cli`, `x11-xserver-utils` не снимаются.

## Проверки

- H: `tests/test-desktop.sh` — gdm3 (Debian `daemon.conf`, Ubuntu `custom.conf`), lightdm
  (`Seat:*`, `SeatDefaults`), xfconf, lxsession, загрузка/живая машина, перезапуск менеджера
  входа, действия, `remove`, повтор без изменений.
- L: `make test-live EXT=desktop` — контейнер без менеджера входа и пользователя: configure 0,
  файлы dconf на месте, повтор и `--reinstall` без изменений, `remove`.
- Порядок загрузки с gdm3 и cloud-init (стадия `system` до менеджера входа, без `ordering
  cycle`) — интеграция cream `test/integration/desktop`. Автологин на настоящем рабочем
  столе — L `xfce4` (Task 13) и сборка через bisquite.
