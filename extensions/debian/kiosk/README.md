# kiosk

Chromium в режиме киоска поверх работающего графического сеанса: браузер
занимает весь экран от имени пользователя сеанса, которого менеджер входа
пустил автологином (`desktop`, `DESKTOP_AUTOLOGIN=1`).

> **4.0.0 — cream/v1.** Хуки `install`, `configure` (стадия `graphical`, нужен
> cream ≥ 1.1.0) и `remove`; настройки — домен cream `/etc/cream/kiosk/config`,
> юнит читает его как `EnvironmentFile`; своего `configure-kiosk.service` нет.
> В домашний каталог пользователя расширение больше **не пишет**: панель и
> рабочий стол Xfce4 — системные умолчания xfconf в `/etc/xdg`, экранная
> клавиатура GNOME — системный ключ dconf. Только Debian (на Ubuntu `chromium` —
> snap, и киоск там не работал).

<!-- check-names: off -->
| Было (layout 2) | Стало |
|---|---|
| `/etc/bisquite/kiosk/config`, `bisquite-conf set kiosk …` | `/etc/cream/kiosk/config`, `cream set kiosk …` |
| `configure-kiosk.service` | стадия `graphical` cream (`cream-configure@kiosk`) |
| `/opt/bisquite/kiosk/run-kiosk.sh` | `/usr/local/lib/kiosk/run-kiosk.sh` (`files`) |
| `~/.config/xfce4/xfconf/…/xfce4-{panel,desktop}.xml` от root | `/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/` (`files`) |
| `~/.config/autostart/enable-keyboard.desktop` от root | `/etc/dconf/db/local.d/50-kiosk-keyboard` |
<!-- check-names: on -->

## Манифест

| Поле | Значение |
|---|---|
| `platform` | `deb`, `amd64`/`arm64`, Debian |
| `targets` | `build: exec`, `live: confirm` (`--accept-risk`: захват экрана) |
| `provides` | `kiosk-browser` |
| `requires` | `x11-server`, `display-manager` — их дают `gnome`, `xfce4`, `lxde` |
| `depends` | `cloud-user` (библиотека: пользователь cloud-init) |
| `conflicts.extensions` | `chromium-kiosk` (оба забирают экран; установка поверх — отказ cream 67) |
| хуки | `install`, `configure` (`graphical`), `remove` |
| `files` | `kiosk-chromium@.service`, `run-kiosk.sh`, `xfce4-panel.xml`, `xfce4-desktop.xml` |

## Подключение

```vmfile
EXTENSION xfce4
EXTENSION desktop DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_LOCK=1 DESKTOP_DISABLE_SCREEN_BLANK=1
EXTENSION kiosk KIOSK_URL=https://dashboard.example.org
```

На живой машине — `cream install --accept-risk kiosk KIOSK_URL=…`; сменить
страницу — `cream set kiosk KIOSK_URL=…` (cream перезапускает configure, тот —
браузер).

| Ключ | Умолчание | Что делает |
|---|---|---|
| `KIOSK_USER` | пусто — пользователь cloud-init | пользователь киоска (`[a-z_][a-z0-9_-]*`); root — отказ |
| `KIOSK_URL` | `https://github.com/iamletenkov/bisquite` | страница: `http(s)://` или `file://`, без пробелов, кавычек и `$` |
| `KIOSK_DISPLAY` | `:0` | X-дисплей |
| `KIOSK_KEYBOARD_ENABLED` | `true` | экранная клавиатура — только под GNOME |
| `KIOSK_CHROMIUM_FLAGS` | `--disable-pinch --overscroll-history-navigation=0` | флаги `--имя[=значение]` через пробел к базовому набору; заданное значение **заменяет** умолчание |

## Что делают хуки

- **`install`** — `chromium`, `x11-utils` (`xdpyinfo`), `x11-xserver-utils`,
  `xauth`, `dbus-x11`; только недостающие, поставленные записываются для
  `remove`. X-сервер и менеджер входа **не** ставит.
- **`configure`** (на каждой загрузке после менеджера входа, после установки
  и после `cream set`):
  1. нет менеджера входа (`display-manager.service`) — предупреждение и 0,
     экземпляры браузера выключаются;
  2. пользователь — `KIOSK_USER`, иначе cloud-init (на загрузке ждёт до 60 с);
     нет, неизвестен или root — предупреждение и 0;
  3. экранная клавиатура под GNOME — системный ключ dconf (профиль `user` с
     `system-db:local`, то же правило, что у `desktop` и `locale`);
  4. `kiosk-chromium@<пользователь>` — ссылка в `graphical.target.wants`,
     экземпляры других пользователей выключаются (смена `KIOSK_USER` не
     оставляет двух браузеров на одном дисплее); на работающей машине —
     `systemctl --no-block restart`.
- **`remove`** — все экземпляры выключены, ключ клавиатуры снят (если наш),
  свои пакеты удалены; юнит, обёртку и умолчания xfconf снимает cream.

## Безопасность

- Браузер — **от пользователя сеанса** (`User=%i`); обёртка от root отказывает.
- Значения настроек доходят до браузера как переменные окружения юнита
  (`EnvironmentFile`), без оболочки: в `ExecStart` нет `bash -c` и подстановок.
  Обёртка ещё раз проверяет форму каждого значения (файл домена можно поправить
  руками) и отказывает громко; адрес — отдельный последний аргумент `chromium`.
- В `$HOME` пользователя root не пишет ничего.

## X authority ищется в рантайме

`run-kiosk.sh` перебирает кандидатов (`$XAUTHORITY`, `~/.Xauthority`,
`/run/user/<uid>/gdm/Xauthority`, `/run/lightdm/<user>/xauthority`, `-auth`
работающего `Xorg`, старая раскладка GDM), проверяя каждого `xdpyinfo`, ждёт
дисплей до 60 с и при неудаче печатает весь список: путь под LightDM и GDM ≥ 42
разный, и прибитый в юните `~/.Xauthority` прежде давал немой цикл рестарта.

## Рабочий стол

Окно киоска полноэкранное поверх всего. Под Xfce4 системные умолчания прячут
панель и иконки и делают фон чёрным — для **всех** пользователей машины, у
которых нет своего канала xfconf (свой `~/.config/xfce4/xfconf/…` их
перекрывает). Под GNOME и LXDE эти файлы никто не читает.

## Диагностика

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

H — `tests/test-kiosk.sh`; L — `make test-live EXT=kiosk` (поверх `xfce4`,
`tests/live.env`); экрана в контейнере нет, браузер там не запускается.
