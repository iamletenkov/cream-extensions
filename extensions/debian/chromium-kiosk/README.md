# chromium-kiosk

Пакет [chromium-kiosk](https://github.com/salamek/chromium-kiosk) из
репозитория Salamek: полноэкранный браузер для стендов и терминалов со своей
графической сессией (xorg, xinit, xfwm4). Расширение подключает репозиторий,
ставит пакет и на каждой загрузке собирает из ключей домена
`/etc/chromium-kiosk/config.yml` — до того, как пакет запустит свой
наблюдатель за этим файлом.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | amd64, arm64 |
| cream | ≥ 1.0.0 |
| Даёт | `kiosk-browser` |
| Требует | — |
| Зависит от | [`apt-guard`](../apt-guard/README.md) |
| Конфликтует с | [`kiosk`](../kiosk/README.md) |
| Хуки | `install`, `configure`, `remove` |
| Настройка на загрузке | стадия `system`, по отметке выполнения |
| Живая машина | с `--accept-risk` |

> **Живая машина — с `--accept-risk`.** Подключает сторонний репозиторий repository.salamek.cz (ключ в дереве расширения) и ставит пакет chromium-kiosk с собственной графической сессией (xorg, xinit, xfwm4): после перезагрузки экран машины занимает киоск
<!-- /catalog:facts -->

## Что делает

- **`install`** — `ca-certificates` и `chromium-kiosk` из репозитория Salamek
  (только недостающие, поставленные записываются для `remove`).
- **`configure`** (стадия `system`, до `chromium-kiosk_configwatcher.service`;
  на загрузке и после `cream set chromium-kiosk …`, своего `apply` нет) —
  проверяет форму каждого значения (файл домена `/etc/cream/chromium-kiosk/config`
  можно поправить руками; значение не по форме — отказ, файл не пишется), пишет
  строки YAML в одинарных кавычках, списки — явными последовательностями
  (`ALLOWED_FEATURES: []`, а не пустой ключ: тот был бы `null`); файл —
  через временный и `rename`, только при изменении; ссылку на месте
  `/etc/chromium-kiosk` отвергает.
- **`remove`** — свои пакеты; репозиторий и ключ снимает cream.
  `/etc/chromium-kiosk/config.yml` — conffile пакета, apt его оставляет.
- **`files`** — репозиторий (deb822) и ключ лежат в дереве расширения (отпечаток
  `8177FADDC92D9497E8DA12377FEA00A604652192`): при установке ничего не
  скачивается мимо apt.

Рабочий стол не нужен: пакет приносит свою сессию. Системную локаль расширение
не меняет — это работа расширения [`locale`](../locale/README.md).

## Параметры

<!-- catalog:params -->
| Ключ | Тип | Умолчание | Что задаёт |
|---|---|---|---|
| `CHROMIUM_KIOSK_HOME_PAGE` | строка `^(https?\|file)://[A-Za-z0-9._~:/?#@!&()*+,;=%-]+$` | `https://github.com/iamletenkov/bisquite` | стартовая страница: http(s):// или file://, без пробелов, кавычек и $ |
| `CHROMIUM_KIOSK_WINDOW_MODE` | `hidden` \| `automaticvisibility` \| `windowed` \| `minimized` \| `maximized` \| `fullscreen` | `fullscreen` | режим окна |
| `CHROMIUM_KIOSK_TOUCHSCREEN` | `true` \| `false` | `true` | поддержка тач-ввода |
| `CHROMIUM_KIOSK_IDLE_TIME` | строка `^[0-9]{1,6}$` | `0` | секунды простоя до возврата на стартовую страницу; 0 — выключено |
| `CHROMIUM_KIOSK_WHITE_LIST_ENABLED` | `true` \| `false` | `false` | белый список адресов |
| `CHROMIUM_KIOSK_WHITE_LIST_URLS` | список через пробел, элемент `^[A-Za-z0-9._~:/?#@!&()*+,;=%-]+$` | пусто | адреса белого списка через пробел, glob (*.example.org google.*/news) |
| `CHROMIUM_KIOSK_WHITE_LIST_IFRAME_ENABLED` | `true` \| `false` | `true` | разрешить iframe |
| `CHROMIUM_KIOSK_NAV_BAR_ENABLED` | `true` \| `false` | `false` | панель навигации |
| `CHROMIUM_KIOSK_NAV_BAR_BUTTONS` | `list:enum:home,reload,back,forward` | `home reload back forward` | кнопки панели по порядку, через пробел |
| `CHROMIUM_KIOSK_VIRTUAL_KEYBOARD_ENABLED` | `true` \| `false` | `true` | экранная клавиатура |
| `CHROMIUM_KIOSK_DISPLAY_ROTATION` | `normal` \| `left` \| `right` \| `inverted` | пусто | поворот экрана и тача вместе; пусто — normal, если не заданы два ключа ниже |
| `CHROMIUM_KIOSK_SCREEN_ROTATION` | `normal` \| `left` \| `right` \| `inverted` | пусто | поворот только экрана (при пустом DISPLAY_ROTATION) |
| `CHROMIUM_KIOSK_TOUCHSCREEN_ROTATION` | `normal` \| `left` \| `right` \| `inverted` | пусто | поворот только тача (при пустом DISPLAY_ROTATION) |
| `CHROMIUM_KIOSK_EXTRA_ARGUMENTS` | список через пробел, элемент `^--[a-z0-9][a-z0-9-]*(=[A-Za-z0-9._,:/=+-]*)?$` | `--disable-pinch --overscroll-history-navigation=0` | флаги браузера через пробел |
| `CHROMIUM_KIOSK_ALLOWED_FEATURES` | `list:enum:desktop-audio-video-capture,desktop-video-capture,geolocation,invalid-certificate,media-audio-capture,media-audio-video-capture,media-video-capture,mouse-lock,notifications` | пусто | разрешения браузера через пробел; пусто — ни одного |
| `CHROMIUM_KIOSK_CURSOR_ENABLED` | `true` \| `false` | `false` | показывать курсор |
<!-- /catalog:params -->

Ключ домена → ключ `config.yml` пакета: `CHROMIUM_KIOSK_HOME_PAGE` → `HOME_PAGE`,
`…_WINDOW_MODE` → `WINDOW_MODE`, `…_TOUCHSCREEN` → `TOUCHSCREEN`, `…_IDLE_TIME` →
`IDLE_TIME`, `…_WHITE_LIST_ENABLED` / `…_URLS` / `…_IFRAME_ENABLED` →
`WHITE_LIST.ENABLED` / `URLS` / `IFRAME_ENABLED`, `…_NAV_BAR_ENABLED` →
`NAV_BAR.ENABLED`, `…_NAV_BAR_BUTTONS` → `NAV_BAR.ENABLED_BUTTONS` (порядок важен),
`…_VIRTUAL_KEYBOARD_ENABLED` → `VIRTUAL_KEYBOARD.ENABLED`, `…_DISPLAY_ROTATION` /
`…_SCREEN_ROTATION` / `…_TOUCHSCREEN_ROTATION` → `DISPLAY_ROTATION` /
`SCREEN_ROTATION` / `TOUCHSCREEN_ROTATION`, `…_EXTRA_ARGUMENTS` →
`EXTRA_ARGUMENTS` (флаги `--имя[=значение]`), `…_ALLOWED_FEATURES` →
`ALLOWED_FEATURES`, `…_CURSOR_ENABLED` → `CURSOR.ENABLED`.

**Списки — через пробел.** Прочие ключи пакета постоянны и заданы в
`hooks/configure`: панель навигации — `center`/`bottom`, `WIDTH: 100`,
`HEIGHT: 5`, `UNDERLAY: false`.

## Установка

На живой машине (`live: confirm`):

```bash
sudo cream install --with-deps --accept-risk chromium-kiosk CHROMIUM_KIOSK_HOME_PAGE=https://dashboard.example.org
sudo cream set chromium-kiosk CHROMIUM_KIOSK_IDLE_TIME=300
cream show chromium-kiosk
```

`cream set` перезапускает configure, наблюдатель пакета подхватывает файл.

В образе bisquite (VMFILE):

```dockerfile
RUN_COMMAND cream install --with-deps chromium-kiosk CHROMIUM_KIOSK_HOME_PAGE=https://dashboard.example.org
```

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | репозиторий и ключ (`files`), пакеты |
| загрузка (`cream-configure@chromium-kiosk`, стадия `system`) | `config.yml` из ключей домена — до наблюдателя пакета |
| `cream set` | cream перезапускает `configure`, наблюдатель пакета подхватывает файл |
| `cream remove` | свои пакеты; репозиторий и ключ снимает cream; `config.yml` остаётся (conffile) |

## Известные ограничения

- Вместе с [`kiosk`](../kiosk/README.md) не ставится: оба киоска занимают
  экран (`conflicts`, установка поверх — отказ cream 67).
- Пакет в репозитории — `Architecture: all` для amd64 и arm64; сборки bisquite
  подтверждены только на amd64.

## Проверки

H — `tests/test-chromium-kiosk.sh`; L — `make test-live EXT=chromium-kiosk`
(`tests/live.env`: настоящий репозиторий, экрана в контейнере нет).
