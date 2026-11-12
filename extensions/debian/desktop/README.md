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
| Хуки | `install`, `configure`, `upgrade`, `remove` |
| Настройка на загрузке | стадия `system`, на каждой загрузке (`every_boot`) |
| Действия | `cream run desktop apply`, `cream run desktop status`, `cream run desktop defaults` |
| Живая машина | да |
<!-- /catalog:facts -->

## Что делает

- **`install`** — ставит `dconf-cli`, `x11-xserver-utils`; ручки применяет следующий
  за ним `configure` (`CREAM_REASON=install`), он же до первой записи снимает
  прежний автологин (см. «Автологин: запись и возврат»).
- **`upgrade`** — вызывается cream вместо `install` при `cream upgrade`: та же работа
  `install`; с 1.x (`CREAM_PREV_VERSION` < 2.0.0) сначала пишет маркер `legacy` —
  «прежний автологин неизвестен».
- **`configure`** — на каждой загрузке, стадия `system`: после
  `cloud-init.service` и `guestfs-firstboot.service`, до `display-manager.service`,
  `gdm.service`, `gdm3.service`, `lightdm.service`; пишет файлы ручек и вносит
  пользователя в группы (см. «Кто применяет и когда»).
- **`remove`** — снимает файлы dconf, X и xfconf; автологин в конфигах gdm3/lightdm
  возвращает, как был при установке (маркер `legacy` или записи нет — выключает, как
  1.x; сами конфиги — пакетов и владельца), снимает `screensaver=disabled` из
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
| `DESKTOP_AUTOLOGIN` | `bool` | пусто | пусто — автологином не управляю; 0 — выключить; 1 — вход без пароля (gdm3, lightdm; SDDM — отказ) |
| `DESKTOP_AUTOLOGIN_USER` | строка `^[a-z_][a-z0-9_-]{0,31}$` | пусто | пользователь автологина и групп сеанса; пусто — пользователь cloud-init (библиотека cloud-user) |
| `DESKTOP_DISABLE_SCREEN_LOCK` | `bool` | `0` | 1 — без автоблокировки экрана (заблокировать вручную можно) |
| `DESKTOP_DISABLE_SCREEN_BLANK` | `bool` | `0` | 1 — без затемнения, гашения, DPMS и сна |
<!-- /catalog:params -->

Домен — `/etc/cream/desktop/config`.

| Ключ | Что делает |
|---|---|
| `DESKTOP_AUTOLOGIN` | пусто (умолчание с 2.0.0) — автологином не управляю; `0` — выключить; `1` — вход без пароля. Смысл значений — таблица ниже |
| `DESKTOP_AUTOLOGIN_USER` | пользователь автологина и групп; пусто — пользователь cloud-init (библиотека [`cloud-user`](../cloud-user/README.md)) |
| `DESKTOP_DISABLE_SCREEN_LOCK` | `1` — без автоблокировки (вручную заблокировать можно) |
| `DESKTOP_DISABLE_SCREEN_BLANK` | `1` — без затемнения, гашения, DPMS и сна |

Выключенная ручка — это «нашего файла нет»: действует поведение ОС, а не наше «выключено».

### Автологин: запись и возврат

Конфиги менеджера входа принадлежат пакетам и владельцу машины, поэтому с 2.0.0
автологин меняется только по явному ключу (спека
[2026-11-12-existing-desktop](../../../docs/specs/2026-11-12-existing-desktop.md), §4.3):

| `DESKTOP_AUTOLOGIN` | gdm3, LightDM | SDDM |
|---|---|---|
| пусто | не трогает; если раньше писали `0`/`1` — возвращает строки из записи (нет записи или `legacy` — выключает, как 1.x) | 0 |
| `0` | `AutomaticLoginEnable=false` в `[daemon]`; у LightDM `autologin-user*` сняты | прочие ручки применены, затем 1: «автологин SDDM не поддержан: `/etc/sddm.conf.d/`, вручную» |
| `1` | `AutomaticLoginEnable=true`, `AutomaticLogin=<пользователь>`; `autologin-user=<пользователь>`, `autologin-user-timeout=0` | как `0` |

- **Запись прежнего** — только при `CREAM_REASON=install`, до первой записи, в
  `/var/lib/cream/ext/desktop/autologin.before`: по каждому конфигу gdm3 и LightDM — сырые
  строки ключей `AutomaticLoginEnable`, `AutomaticLogin` (gdm3), `autologin-user`,
  `autologin-user-timeout` (LightDM), закомментированные тоже, и их место в секции; дописанная
  секция и перевод строки в конце. Повтор запись не перезаписывает. На загрузке, при
  `apply` и `upgrade` записи нет: в файлах может стоять то, что записала 1.x.
- **Возврат** — пустой ключ или `remove` после записи `0`/`1`: строки встают на свои места,
  файл пакета — побайтно. Ключ пуст с установки (или с прошлого возврата) — `remove` конфиги
  не трогает: что владелец поменял сам, остаётся. Запись живёт до `remove` (рулинг П17).
- **`legacy` или записи нет** — пустой ключ и `remove` выключают автологин, как 1.x: машина
  без пароля не остаётся. После выключения по пустому ключу маркер снимается, и дальше пусто
  значит «не управляю».
- Чужой файл на месте записи — `remove` отказывает (1) и ничего не снимает; пустой ключ
  после записи `0`/`1` — тоже 1.

## Установка

На машине с подключённым каталогом ([как подключить](../../../docs/getting-started.md)):

```bash
sudo cream install --with-deps desktop
sudo cream set desktop DESKTOP_AUTOLOGIN=1    # cream перезапускает cream-configure@desktop
sudo cream set desktop DESKTOP_AUTOLOGIN=     # вернуть автологин, как был при установке
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
| сборка образа / `cream install` | пакеты `dconf-cli`, `x11-xserver-utils`; запись прежнего автологина и ручки — первым `configure` (`install` на живой машине, `boot` после сборки) |
| `cream upgrade` | хук `upgrade`: пакеты; с 1.x — маркер `legacy`; затем `configure` (`CREAM_REASON=upgrade`) |
| загрузка (`cream-configure@desktop`) | `CREAM_REASON=boot`: ждёт пользователя до 30 с, пишет файлы, группы, ничего не перезапускает |
| `cream set` (перезапуск `cream-configure@desktop`) | то же без ожидания; при смене автологина — перезапуск менеджера входа, если нет графической сессии |
| `cream remove` | файлы ручек сняты, автологин возвращён по записи (`legacy` или нет записи — выключен); группы и пакеты остаются |

Действия:

| Действие | Что делает |
|---|---|
| `cream run desktop apply [--now\|--boot]` | применить сейчас (`--now`, умолчание) или как на загрузке |
| `cream run desktop status` | ручки и что применено (dconf, X DPMS), работающий менеджер входа (`sddm` — с пометкой «вручную»), запись прежнего автологина; только читает |
| `cream run desktop defaults KEY=VALUE…` | записать без применения — `cream set --no-apply desktop …` (сборка, скрипты) |

## Известные ограничения

- Открытую графическую сессию `apply` не обрывает: изменение автологина
  применится со следующей загрузки.
- Нет менеджера входа или пользователя — предупреждение и 0; автологин не
  включается (экран входа лучше чёрного экрана).
- Автологин на настоящем рабочем столе проверяется только через L `xfce4` и
  сборку через bisquite.
- Автологин SDDM не поддержан (нужен `Session=`, имя X11-сессии Plasma 5.27 и 6 разное, не
  замерено): ключ `0`/`1` — код 1 после прочих ручек, пусто — 0.
- В образе, собранном без живой машины, первый `configure` идёт с `CREAM_REASON=boot` —
  записи нет, и `remove` выключает автологин, как 1.x.

## Миграция с 1.x

Спека, §5:

- Явно заданный `DESKTOP_AUTOLOGIN` сохраняет смысл: cream хранит в домене только явные
  значения.
- Где ключ не задавался, умолчание становится пустым: `desktop` перестаёт писать
  `AutomaticLoginEnable=false` на загрузке, но в файле остаётся последнее записанное значение —
  видимого изменения нет, менеджер входа не перезапускается.
- Хук `upgrade` пишет маркер `legacy`: записанное самой 1.x «прежним» не считается, `remove` и
  пустой ключ выключают автологин, как 1.x.
- Где вендорский автологин гасило умолчание `0` (`cloud-user-desktop`), теперь его гасит
  `cloud-user-desktop` 6.0.0 — только запись, указывающую на удалённую учётку.

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

- `depends: [{name: desktop, version: ">=1.0.0 <3"}]`; ставить свою службу и ссылку
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
  входа, действия, `remove`, повтор без изменений. С 2.0.0: матрица пусто/`0`/`1` × gdm3/LightDM/SDDM;
  запись только при `install`; возврат побайтно конфигов пакетов gdm3 Ubuntu 24.04 и Debian 12
  (П6), вендорского автологина, дописанной секции, файла без перевода строки в конце; Р1 —
  1.x → `upgrade` (`legacy`) → загрузка → `remove` или пустой ключ: автологин выключен; с 1.x
  при пустом ключе менеджер входа не перезапускается; чужая запись — `remove` 1.
- **L** — `make test-live EXT=desktop` — контейнер без менеджера входа и пользователя: configure 0,
  файлы dconf на месте, повтор и `--reinstall` без изменений, `remove`. Вариант
  `ARGS='--variant gdm3'` (ubuntu-24.04): `custom.conf` пакета с включённым автологином
  (preseed), install с `DESKTOP_AUTOLOGIN=0`, после `remove` файл тот же побайтно.
- Порядок загрузки с gdm3 и cloud-init (стадия `system` до менеджера входа, без `ordering
  cycle`) — интеграция cream `test/integration/desktop`. Автологин на настоящем рабочем
  столе — L `xfce4` и сборка через bisquite.
