# kiosk

Chromium в режиме киоска поверх работающего графического сеанса: браузер
занимает весь экран от имени пользователя сеанса, которого менеджер входа
пустил автологином (`desktop`, `DESKTOP_AUTOLOGIN=1`).

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian |
| Архитектура | amd64, arm64 |
| cream | ≥ 1.2.0 |
| Даёт | `kiosk-browser` |
| Требует | `x11-server`, `display-manager` |
| Зависит от | [`cloud-user`](../cloud-user/README.md), [`apt-guard`](../apt-guard/README.md) |
| Конфликтует с | [`chromium-kiosk`](../chromium-kiosk/README.md) |
| Хуки | `install`, `configure`, `remove` |
| Настройка на загрузке | стадия `graphical`, на каждой загрузке (`every_boot`) |
| Живая машина | с `--accept-risk` |

> **Живая машина — с `--accept-risk`.** Захватывает экран: браузер Chromium на весь экран поверх сеанса пользователя (KIOSK_USER или пользователь cloud-init), без панели и рабочего стола Xfce4 — системные умолчания xfconf для всех пользователей машины; перезапускается сам при закрытии; ставит chromium; снимается cream remove kiosk
<!-- /catalog:facts -->

## Что делает

- **`install`** — `chromium`, `x11-utils` (`xdpyinfo`), `x11-xserver-utils`,
  `xauth`, `dbus-x11`; только недостающие, поставленные записываются для
  `remove`. X-сервер и менеджер входа **не** ставит: их дают `gnome`, `xfce4`,
  `lxde` (`requires`). cream раскладывает файлы расширения: юнит
  `/etc/systemd/system/kiosk-chromium@.service`, обёртку
  `/usr/local/lib/kiosk/run-kiosk.sh`, системные умолчания xfconf
  `xfce4-panel.xml` и `xfce4-desktop.xml` в `/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/`.
- **`configure`** (стадия `graphical`, на каждой загрузке после менеджера входа,
  после установки и после `cream set`):
  1. нет менеджера входа (`display-manager.service`) — предупреждение и 0,
     экземпляры браузера выключаются;
  2. пользователь — `KIOSK_USER`, иначе cloud-init (библиотека
     [`cloud-user`](../cloud-user/README.md); на загрузке ждёт до 60 с);
     нет, неизвестен или root — предупреждение и 0;
  3. экранная клавиатура под GNOME — системный ключ dconf (профиль `user` с
     `system-db:local`, то же правило, что у `desktop` и `locale`);
  4. `kiosk-chromium@<пользователь>` — ссылка в `graphical.target.wants`,
     экземпляры других пользователей выключаются (смена `KIOSK_USER` не
     оставляет двух браузеров на одном дисплее); на работающей машине —
     `systemctl --no-block restart`.
- **`remove`** — все экземпляры выключены, ключ клавиатуры снят (если наш),
  свои пакеты удалены; юнит, обёртку и умолчания xfconf снимает cream.

Настройки — домен cream `/etc/cream/kiosk/config`; юнит читает его как
`EnvironmentFile`. В домашний каталог пользователя расширение не пишет: панель
и рабочий стол Xfce4 — системные умолчания xfconf в `/etc/xdg`, экранная
клавиатура GNOME — системный ключ dconf.

## Параметры

<!-- catalog:params -->
| Ключ | Тип | Умолчание | Что задаёт |
|---|---|---|---|
| `KIOSK_USER` | строка `^[a-z_][a-z0-9_-]{0,31}$` | пусто | пользователь киоска; пусто — пользователь cloud-init (библиотека cloud-user) |
| `KIOSK_URL` | строка `^(https?\|file)://[A-Za-z0-9._~:/?#@!&()*+,;=%-]+$` | `https://github.com/iamletenkov/bisquite` | страница киоска: http(s):// или file://, без пробелов, кавычек и $ |
| `KIOSK_DISPLAY` | строка `^:[0-9]{1,3}(\.[0-9]{1,2})?$` | `:0` | X-дисплей браузера |
| `KIOSK_KEYBOARD_ENABLED` | `true` \| `false` | `true` | экранная клавиатура — только под GNOME (системный dconf) |
| `KIOSK_CHROMIUM_FLAGS` | список через пробел, элемент `^--[a-z0-9][a-z0-9-]*(=[A-Za-z0-9._,:/=+-]*)?$` | `--disable-pinch --overscroll-history-navigation=0` | флаги Chromium через пробел, к базовому набору; заменяют умолчание |
<!-- /catalog:params -->

- `KIOSK_USER` — пусто означает пользователя cloud-init; root — отказ.
- `KIOSK_URL` — `http(s)://` или `file://`, без пробелов, кавычек и `$`.
- `KIOSK_KEYBOARD_ENABLED` — экранная клавиатура только под GNOME.
- `KIOSK_CHROMIUM_FLAGS` — флаги `--имя[=значение]` через пробел к базовому
  набору; заданное значение **заменяет** умолчание.

Смена любого ключа через `cream set kiosk KEY=…` перезапускает configure, тот —
браузер.

## Установка

На машине с подключённым каталогом ([как подключить](../../../docs/getting-started.md));
`live: confirm` (захват экрана) — нужен `--accept-risk`:

```bash
sudo cream install --with-deps --accept-risk kiosk KIOSK_URL=https://dashboard.example.org
sudo cream set kiosk KIOSK_URL=https://other.example.org
cream show kiosk
```

В образе bisquite (VMFILE):

```dockerfile
RUN_COMMAND cream install --with-deps xfce4
RUN_COMMAND cream install --with-deps desktop DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_LOCK=1 DESKTOP_DISABLE_SCREEN_BLANK=1
RUN_COMMAND cream install --with-deps kiosk KIOSK_URL=https://dashboard.example.org
```

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | недостающие пакеты, файлы юнита, обёртки и умолчаний xfconf |
| загрузка (`cream-configure@kiosk`, стадия `graphical`) | пользователь, клавиатура, включение `kiosk-chromium@<пользователь>` |
| `cream set` | тот же `configure`; на работающей машине браузер перезапускается |
| `cream remove` | экземпляры выключены, ключ клавиатуры и свои пакеты сняты, файлы снимает cream |

## Известные ограничения

- Только Debian: на Ubuntu `chromium` — snap (`chromium-browser` — переходной
  пакет), и киоск там не работал.
- Конфликтует с `chromium-kiosk`: оба забирают экран; установка поверх — отказ
  cream 67.
- Умолчания xfconf прячут панель и иконки для **всех** пользователей машины без
  своего канала xfconf (см. «Рабочий стол»).
- Экрана в L-контейнере нет, браузер там не запускается.

## Подробности

### Безопасность

- Браузер — **от пользователя сеанса** (`User=%i`); обёртка от root отказывает.
- Значения настроек доходят до браузера как переменные окружения юнита
  (`EnvironmentFile`), без оболочки: в `ExecStart` нет `bash -c` и подстановок.
  Обёртка ещё раз проверяет форму каждого значения (файл домена можно поправить
  руками) и отказывает громко; адрес — отдельный последний аргумент `chromium`.
- В `$HOME` пользователя root не пишет ничего.

### X authority ищется в рантайме

`run-kiosk.sh` перебирает кандидатов (`$XAUTHORITY`, `~/.Xauthority`,
`/run/user/<uid>/gdm/Xauthority`, `/run/lightdm/<user>/xauthority`, `-auth`
работающего `Xorg`, старая раскладка GDM), проверяя каждого `xdpyinfo`, ждёт
дисплей до 60 с и при неудаче печатает весь список: путь под LightDM и GDM ≥ 42
разный, и прибитый в юните `~/.Xauthority` прежде давал немой цикл рестарта.

### Рабочий стол

Окно киоска полноэкранное поверх всего. Под Xfce4 системные умолчания прячут
панель и иконки и делают фон чёрным — для **всех** пользователей машины, у
которых нет своего канала xfconf (свой `~/.config/xfce4/xfconf/…` их
перекрывает). Под GNOME и LXDE эти файлы никто не читает.

### Диагностика

```bash
systemctl status 'cream-configure@kiosk' 'kiosk-chromium@*'
journalctl -u cream-configure@kiosk -u 'kiosk-chromium@*' -b
cream show kiosk
```

- **Браузер не стартует** — в журнале `kiosk-chromium@<user>` список
  проверенных путей X authority; чаще всего в образе нет рабочего стола или
  автологина.
- **«не по форме»** — значение ключа поправлено в файле руками; исправить
  `cream set kiosk KEY=…`.
- **«менеджер входа не включён»** — нет `gnome`/`xfce4`/`lxde`.

## Проверки

- **H** — `tests/test-kiosk.sh`.
- **L** — `make test-live EXT=kiosk` (поверх `xfce4`, `tests/live.env`); экрана в
  контейнере нет, браузер там не запускается.
