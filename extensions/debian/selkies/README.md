# selkies

X-сессия, которая на мониторе, — в браузере, через один WebSocket-порт
([Selkies](https://github.com/selkies-project/selkies) 2.0.0, AppImage). Формат
cream/v1 (план 2026-10-19, Task 17).

**Без пароля не стартует.** Пока не задан `SELKIES_BASIC_AUTH_PASSWORD` или явно
не разрешено `SELKIES_ALLOW_NO_AUTH=1`, служба не запускается ни на каком адресе,
включая петлю: петля не защищает рабочий стол, буфер обмена и файлы пользователя
от других учёток и служб той же машины. По умолчанию слушает `127.0.0.1:8080`;
снаружи — через Teleport или ssh-туннель.

## Манифест

| Поле | Значение |
|---|---|
| `version` | `6.0.0`, `cream: ">=1.1.0"` (стадия `graphical`) |
| `platform.arch` | `amd64`, `arm64` (AppImage — x86_64, aarch64) |
| `targets` | `build: exec`, `live: yes` |
| `provides` / `requires` | `web-remote-desktop` / `x11-server`, `display-manager` |
| `depends` | `cloud-user >=1.0.0 <2` — пользователь сессии |
| хуки | `install`, `configure` (стадия `graphical`), `apply` (свой), `remove` |
| `files` | `selkies@.service` → `/etc/systemd/system/selkies@.service` |

С `x11vnc` работает параллельно (конфликта нет).

## Что делает

- **`install`** — AppImage Selkies по закреплённой версии и sha256 на архитектуру,
  распаковка в `/opt/selkies/2.0.0` (**+1,7 ГБ**, без FUSE), ссылка
  `/opt/selkies/current`; `x11-utils`, `xauth` для обёртки. Службу не запускает,
  настроек не пишет. Повтор при распакованном дереве сеть не трогает.
- **`configure`** — на каждой загрузке (стадия `graphical`, после менеджера входа),
  после `install` на живой машине:
  1. проверка аутентификации (ниже); нет — объявление для Teleport снимается,
     запущенные `selkies@*` гасятся (`--no-block`), предупреждение, код 0;
  2. объявление `/etc/cream/teleport/apps.d/selkies.conf`;
  3. менеджер входа не запущен — предупреждение, код 0 (рулинг Р11);
  4. пользователь cloud-init (библиотека `cloud-user`; на загрузке ждёт до 60 с);
     нет, root или имя не годится для юнита — предупреждение, код 0;
  5. экземпляры других пользователей гасятся, `systemctl start --no-block
     selkies@<пользователь>` (после `install` — `restart`). Экземпляр **не
     включается** (`enable`): его каждый раз запускает configure, проверив пароль.
- **`apply`** — после `cream set selkies …`: то же без ожидания пользователя,
  `restart --no-block` (или останов, если аутентификации больше нет);
  предупреждения видны в терминале `cream set`.
- **`remove`** — останавливает `selkies@*`, снимает объявление, удаляет
  `/opt/selkies` (по ссылке — нет). Юнит удаляет cream (`files`).
- **`files/run-selkies.sh`** — обёртка юнита (от имени пользователя, `User=%i`):
  ещё раз проверяет аутентификацию (отказ — код 78, `RestartPreventExitStatus=78`,
  без цикла перезапусков), ждёт X-сессию, запускает бинарь мимо `AppRun` (иначе
  без дисплея поднялся бы Xvfb с пустым экраном) и сторожит пропажу сессии.

## Аутентификация и секреты

| Пароль | `SELKIES_ALLOW_NO_AUTH` | Что будет |
|---|---|---|
| задан | любое | basic auth включён обёрткой (`SELKIES_ENABLE_BASIC_AUTH=true` поверх настроек) |
| нет | `0` (умолчание) | служба не стартует; предупреждение в каждом configure/apply и в журнале юнита |
| нет | `1` | стартует **без аутентификации**; предупреждение при каждом configure, apply и старте |

- Пароль просмотра (`SELKIES_BASIC_AUTH_VIEWONLY_PASSWORD`) без основного
  аутентификацией не считается.
- Адрес не петли с паролем, но без `SELKIES_ENABLE_HTTPS=true` — предупреждение:
  пароль basic auth идёт по сети открытым текстом.
- Три секрета — `secret: file` в `/etc/cream/selkies/secrets` (0600, root; пишет
  cream). Юнит читает файл `EnvironmentFile=-…` (systemd, от root); обёртка
  убирает секреты из своего окружения и передаёт их только в окружение самого
  Selkies — у `loginctl`, `xdpyinfo`, `pactl` их нет; в argv и журнал они не
  попадают. Хуки секреты не читают: проверяют только, что строка ключа непуста.
- Пароль — 8–128 знаков `A-Za-z0-9` и `!#%&()*+,./:;<=>?@^_{|}~[]-`; токен —
  16–256 знаков `A-Za-z0-9._~+/=-`. Остальные ключи тоже без переводов строк,
  кавычек, `$`, обратной косой и пробелов: значения уходят в `EnvironmentFile` и в
  объявление. Шаблон `SELKIES_*` — для несекретных переменных Selkies; секреты —
  только три ключа выше.
- Пароль задают на машине, а не в VMFILE (строка VMFILE остаётся в образе):

  ```bash
  echo '<пароль>' | sudo cream set selkies SELKIES_BASIC_AUTH_PASSWORD=-
  ```

  Несколько секретов разом — `--params-file` (0600, root).
- Объявление для Teleport пишется атомарно (временный файл в `apps.d`, `rename`):
  ссылка на месте файла заменяется, а не разыменовывается; если ссылка —
  `/etc/cream`, `/etc/cream/teleport` или `apps.d`, объявление не пишется
  (предупреждение). От root в домашний каталог расширение не пишет: `~/Downloads`
  и пару TLS создаёт обёртка от имени пользователя (`UMask=0077`, каталог TLS — 0700
  сразу).
- **Чужие страницы.** WebSocket Selkies принимает только Origin своей страницы и
  клиентов без Origin (`Origin: http://evil.example` → `403`). Локальный
  **процесс** (не браузер) к петле подключится — отсюда обязательный пароль.

## Ручки (`/etc/cream/selkies/config`)

Имена — родные переменные Selkies (`/opt/selkies/current/usr/conda/bin/selkies --help`):
юнит читает файл как `EnvironmentFile`. Объявлены умолчания и то, что стоит
проверять; любая другая `SELKIES_*` — шаблоном (`cream set selkies SELKIES_VIDEO_CRF=25`).

| Ключ | Умолчание | Почему |
|---|---|---|
| `SELKIES_ADDR` | `127.0.0.1` | снаружи — через Teleport или ssh |
| `SELKIES_PORT` | `8080` | |
| `SELKIES_ALLOW_NO_AUTH` | `0` | ручка расширения, не Selkies (Р8) |
| `SELKIES_ENABLE_HTTPS` | `false` | TLS завершает прокси; наружу — `true` |
| `SELKIES_ENABLE_RESIZE` | `false` | **иначе Selkies меняет разрешение монитора** под окно браузера |
| `SELKIES_ENCODER` | `h264enc` | NVENC/VA-API, если есть, иначе x264 |
| `SELKIES_FRAMERATE` | `30,8-60` | старт, мин-макс |
| `SELKIES_AUDIO_ENABLED` | `true` | обёртка ждёт сокет PulseAudio пользователя до 30 с и захватывает monitor sink'а по умолчанию |
| `SELKIES_ENABLE_CLIPBOARD` | `true` | `in`/`out`/`false` — по направлениям |
| `SELKIES_FILE_TRANSFERS` | `upload,download` | в `~/Downloads` пользователя; `none` — выключить |
| `SELKIES_MICROPHONE_ENABLED`, `SELKIES_WEBCAM_ENABLED`, `SELKIES_GAMEPAD_ENABLED` | `false` | машине не нужны |
| `SELKIES_COMMAND_ENABLED`, `SELKIES_ENABLE_SHARING`, `SELKIES_SECOND_SCREEN` | `false` | API команд, ссылки для просмотра, второй монитор |
| `SELKIES_MODE` | `websockets` | WebRTC через веб-приложение Teleport не проходит |
| `SELKIES_DISPLAY` | пусто (`:0`) | ключ обёртки |
| `SELKIES_HTTPS_CERT`, `SELKIES_HTTPS_KEY` | пусто | пара выпускается на машине в `~/.local/state/selkies/` пользователя |

## Подключение

```vmfile
EXTENSION desktop DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_LOCK=1 DESKTOP_DISABLE_SCREEN_BLANK=1
EXTENSION xfce4
EXTENSION selkies SELKIES_PORT=8090 SELKIES_FILE_TRANSFERS=download
```

Пароль — на машине (см. выше). **Без `DESKTOP_AUTOLOGIN=1`** показывать нечего до
входа человека: обёртка ждёт сессию и пишет об этом одну строку в журнал.

На работающей машине:

```bash
sudo cream install selkies
echo '<пароль>' | sudo cream set selkies SELKIES_BASIC_AUTH_PASSWORD=-
sudo cream set selkies SELKIES_ADDR=0.0.0.0 SELKIES_ENABLE_HTTPS=true   # открыть в сеть
```

**HTTPS обязателен для «всех функций»** в сети: буфер обмена, микрофон, камеру и
геймпады браузер даёт только защищённому контексту (`localhost` туннеля — тоже).
Без `SELKIES_HTTPS_CERT` Selkies при первом старте выпускает самоподписанную пару
в состоянии пользователя и переиспользует её (путь по умолчанию самого Selkies,
`ssl-cert-snakeoil`, на Ubuntu даёт `[SSL] PEM lib`).

## Веб-приложение Teleport

`configure` и `apply` кладут `/etc/cream/teleport/apps.d/selkies.conf` в формате
расширения `teleport` (`files/teleport.sh`, `read_decl`):

```
NAME=selkies
URI=http://127.0.0.1:8080      # https — при SELKIES_ENABLE_HTTPS=true; ::1 — [::1]
ICON=desktop
```

Объявление есть, только когда служба может работать (аутентификация есть) и
слушает петлю (`127.0.0.1`, `localhost`, `0.0.0.0`, `::1`); `remove` его снимает.
Кому видно — метка `env` ноды и роли кластера; не публиковать —
`cream set teleport TELEPORT_APPS_DISABLE=selkies`. Если прокси передаёт Selkies
`Host` петли, а браузер — свой Origin, будет `403` и
`Rejected WebSocket upgrade from disallowed Origin` — тогда
`SELKIES_ALLOWED_ORIGINS=https://<публичный адрес>`.

## Проверки

- **V** — `make cream-validate`.
- **H** — `tests/test-selkies.sh`: манифест и типы ключей (без `\n`, кавычек, `$`),
  юнит, `install` (распакованное дерево — без сети, повтор без изменений; чужой
  sha256 — отказ, ничего не распаковано), `configure` (fail-closed без пароля и с
  одним паролем просмотра, `SELKIES_ALLOW_NO_AUTH=1` с предупреждением, адреса не
  петли, проверка значений, объявление не по ссылкам, без менеджера входа и без
  пользователя — 0, root не запускается, чужие экземпляры гасятся, только
  `--no-block`), `apply`, `remove`, обёртка (отказ 78, basic auth принудительно,
  секреты только у Selkies, каталог TLS 0700).
- **L** — `make test-live EXT=selkies` (`tests/live.env`: deps `cloud-user desktop
  xfce4`, пароль — случайный секрет, debian-12): установка AppImage, повтор,
  `--reinstall` без изменений, аудит секретов, загрузка, `remove`. lightdm в
  контейнере падает — configure предупреждает «менеджер входа не запущен» и выходит
  0; сама служба Selkies в L не стартует.

## Проверено ранее (5.x, Jetson AGX Orin, L4T 36.4.3, 2026-09-14)

Скачивание 43 с, распаковка 1,7 ГБ; экран 3840×1080 через ssh-туннель: статичный
стол 30 fps / ~0,05 Мбит/с, движение 1080p 30 fps / ~1 Мбит/с, камера 1080p
41–56 fps / ~1,8 Мбит/с (CPU Selkies 150–225% из 1200%). Через Teleport —
WebSocket `101`, картинка и звук. Выход пользователя: Selkies сам не завершается,
сторож обёртки гасит его, юнит перезапускает, новая сессия подхватывается (~15 с).

## Не проверено

Формат cream/v1 на железе и с настоящим менеджером входа (P): старт службы,
basic auth из `secrets`, объявление в Teleport. amd64 AppImage на Ubuntu 22.04;
клавиатура и буфер обмена отдельно; микрофон и камера клиента.

## Известное

- Шум в журнале на Jetson: `WARNING:NvidiaGPUMonitor:Invalid process ID: [N/A]` раз
  в 2 с (`nvidia-smi` там заглушка) — на работу не влияет.
- Браузер с запретом автовоспроизведения не начнёт поток до клика.
- Обновление Selkies — `SELKIES_VERSION` и sha256 в `hooks/install`.
- Секреты видит процесс Selkies (его окружение читают root и сам пользователь
  сессии) — это и есть потребитель пароля.

## Диагностика

```bash
systemctl status selkies@<пользователь>
journalctl -u cream-configure@selkies -b
journalctl -u selkies@<пользователь> -b | grep -E 'selkies:|running on|Origin|ERROR'
sudo cream show selkies
ss -ltnp | grep 8080
```
