# chromium-kiosk

Пакет [chromium-kiosk](https://github.com/salamek/chromium-kiosk) из
репозитория Salamek: полноэкранный браузер для стендов и терминалов со своей
графической сессией (xorg, xinit, xfwm4). Расширение подключает репозиторий,
ставит пакет и на каждой загрузке собирает из ключей домена
`/etc/chromium-kiosk/config.yml` — до того, как пакет запустит свой
наблюдатель за этим файлом.

> **4.0.0 — cream/v1.** Хуки `install`, `configure` (стадия `system`, до
> `chromium-kiosk_configwatcher.service`) и `remove`; домен —
> `/etc/cream/chromium-kiosk/config`, `cream set chromium-kiosk …`. Репозиторий и
> ключ — `files` (ключ лежит в дереве, отпечаток
> `8177FADDC92D9497E8DA12377FEA00A604652192`), при установке ничего не
> скачивается мимо apt. **Списки — через пробел** (были через запятую).
> Системную локаль расширение больше не меняет (прежде навязывало
> `ru_RU.UTF-8`) — это работа расширения `locale`.

## Манифест

| Поле | Значение |
|---|---|
| `targets` | `build: exec`, `live: confirm` (сторонний репозиторий, своя графическая сессия) |
| `provides` | `kiosk-browser` |
| `conflicts.extensions` | `kiosk` (установка поверх — отказ cream 67) |
| хуки | `install`, `configure` (`system`), `remove` |

Рабочий стол не нужен: пакет приносит свою сессию.

## Подключение

```vmfile
EXTENSION chromium-kiosk CHROMIUM_KIOSK_HOME_PAGE=https://dashboard.example.org
```

На живой машине — `cream install --accept-risk chromium-kiosk …`; дальше
`cream set chromium-kiosk KEY=…` (cream перезапускает configure, наблюдатель
пакета подхватывает файл).

| Ключ | Умолчание | Ключ пакета |
| --- | --- | --- |
| `CHROMIUM_KIOSK_HOME_PAGE` | `https://github.com/iamletenkov/bisquite` | `HOME_PAGE`: `http(s)://` или `file://`, без пробелов, кавычек и `$` |
| `CHROMIUM_KIOSK_WINDOW_MODE` | `fullscreen` | `WINDOW_MODE`: `hidden`, `automaticvisibility`, `windowed`, `minimized`, `maximized`, `fullscreen` |
| `CHROMIUM_KIOSK_TOUCHSCREEN` | `true` | `TOUCHSCREEN` |
| `CHROMIUM_KIOSK_IDLE_TIME` | `0` | `IDLE_TIME`, секунды; `0` — выключено |
| `CHROMIUM_KIOSK_WHITE_LIST_ENABLED` | `false` | `WHITE_LIST.ENABLED` |
| `CHROMIUM_KIOSK_WHITE_LIST_URLS` | пусто | `WHITE_LIST.URLS`, через пробел, glob |
| `CHROMIUM_KIOSK_WHITE_LIST_IFRAME_ENABLED` | `true` | `WHITE_LIST.IFRAME_ENABLED` |
| `CHROMIUM_KIOSK_NAV_BAR_ENABLED` | `false` | `NAV_BAR.ENABLED` |
| `CHROMIUM_KIOSK_NAV_BAR_BUTTONS` | `home reload back forward` | `NAV_BAR.ENABLED_BUTTONS`, порядок важен |
| `CHROMIUM_KIOSK_VIRTUAL_KEYBOARD_ENABLED` | `true` | `VIRTUAL_KEYBOARD.ENABLED` |
| `CHROMIUM_KIOSK_DISPLAY_ROTATION` | пусто | `DISPLAY_ROTATION`: `normal`, `left`, `right`, `inverted`; пусто — `normal`, если не заданы два ключа ниже |
| `CHROMIUM_KIOSK_SCREEN_ROTATION` | пусто | `SCREEN_ROTATION` — только экран |
| `CHROMIUM_KIOSK_TOUCHSCREEN_ROTATION` | пусто | `TOUCHSCREEN_ROTATION` — только тач |
| `CHROMIUM_KIOSK_EXTRA_ARGUMENTS` | `--disable-pinch --overscroll-history-navigation=0` | `EXTRA_ARGUMENTS`, флаги `--имя[=значение]` |
| `CHROMIUM_KIOSK_ALLOWED_FEATURES` | пусто — ни одного | `ALLOWED_FEATURES`, через пробел |
| `CHROMIUM_KIOSK_CURSOR_ENABLED` | `false` | `CURSOR.ENABLED` |

Прочие ключи пакета постоянны и заданы в `hooks/configure`: панель навигации —
`center`/`bottom`, `WIDTH: 100`, `HEIGHT: 5`, `UNDERLAY: false`.

## Что делают хуки

- **`install`** — `ca-certificates` и `chromium-kiosk` из репозитория Salamek
  (только недостающие, поставленные записываются для `remove`).
- **`configure`** — проверяет форму каждого значения (файл домена можно
  поправить руками; значение не по форме — отказ, файл не пишется), пишет
  строки YAML в одинарных кавычках, списки — явными последовательностями
  (`ALLOWED_FEATURES: []`, а не пустой ключ: тот был бы `null`); файл —
  через временный и `rename`, только при изменении; ссылку на месте
  `/etc/chromium-kiosk` отвергает.
- **`remove`** — свои пакеты; репозиторий и ключ снимает cream.
  `/etc/chromium-kiosk/config.yml` — conffile пакета, apt его оставляет.

## Проверки

H — `tests/test-chromium-kiosk.sh`; L — `make test-live EXT=chromium-kiosk`
(`tests/live.env`: настоящий репозиторий, экрана в контейнере нет).
