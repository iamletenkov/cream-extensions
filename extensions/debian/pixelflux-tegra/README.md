# pixelflux-tegra

Аппаратное кодирование H.264/H.265 в Selkies на NVIDIA Jetson: подкладка
системной `libxcb` (и шим `gbm` на focal), без которой сессия на Jetson падает
через секунды после старта захвата, плюс проверка бэкенда Tegra на живом железе.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | arm64 |
| cream | ≥ 1.2.0 |
| Даёт | — |
| Требует | `web-remote-desktop` |
| Зависит от | [`cloud-user`](../cloud-user/README.md) |
| Конфликтует с | [`pixelflux-v4l2m2m`](../pixelflux-v4l2m2m/README.md) |
| Хуки | `install`, `configure`, `remove` |
| Настройка на загрузке | стадия `graphical`, на каждой загрузке (`every_boot`) |
| Живая машина | да |
<!-- /catalog:facts -->

## Что делает

- **`install`** — проверяет, что базовый `pixelflux` несёт бэкенд Tegra (апстрим
  уронит — установка встанет), что модуль импортируется с той же подкладкой, что
  получит сессия, и пишет drop-in. Живой проверки здесь нет: в appliance сборки нет
  ни устройств, ни X. Отказ без `/opt/selkies/current`. Не Jetson (нет
  `/etc/nv_tegra_release`) или не arm64 — код **20**. После `install`/`upgrade`
  работающие `selkies@` перезапускаются (`--no-block`), чтобы подкладка дошла до
  процесса.
- **`configure`** (каждая загрузка, стадия `graphical`) — отпечаток совпадает с
  текущим AppImage, есть узел кодера, у пользователя сессии есть доступ (см.
  «Доступ к узлу кодера»), drop-in на месте, и `pixelflux` сам отвечает
  `hardware_encoders()["h264"] == "tegra"`. Нет узла, другой бэкенд, устаревший
  отпечаток — **предупреждение в журнале и код 0**: упавший юнит загрузки никому не
  помогает. Сбой — только если `usermod` отказал.
- **`remove`** — снимает все три файла из таблицы ниже.

Всё — атомарно (временный файл рядом и `rename`), не по символическим ссылкам;
в дерево `selkies` и в домашние каталоги — ничего.

| Путь | Что |
|---|---|
| `/etc/systemd/system/selkies@.service.d/10-pixelflux-tegra.conf` | `Environment=LD_PRELOAD=…` (+ `daemon-reload` на живой машине) |
| `/var/lib/cream/ext/pixelflux-tegra/gbm_shim.so` | шим gbm, только focal; собирается `gcc -shared -fPIC -O2` из `files/gbm_shim.c` во временном каталоге там же |
| `/var/lib/cream/ext/pixelflux-tegra/stamp` | `prefix=/opt/selkies/<версия>`: подъём AppImage без переустановки расширения `configure` замечает |

`requires: web-remote-desktop` — рабочий стол даёт [`selkies`](../selkies/README.md),
это его ускоритель. `provides` пусто: `hw-video-codec` принадлежит `l4t-gstreamer`.
С [`pixelflux-v4l2m2m`](../pixelflux-v4l2m2m/README.md) конфликтует: оба настраивают
pixelflux одного AppImage. Пользователь сессии (библиотека
[`cloud-user`](../cloud-user/README.md)) нужен для доступа к узлу кодера.

## Параметры

<!-- catalog:params -->
Параметров нет.
<!-- /catalog:params -->

Ключей расширение не добавляет: кодер выбирает лестница pixelflux,
`SELKIES_ENCODER` — в схеме `selkies`.

## Установка

Ставится после `selkies`: `requires` это требует, а хук `install` отказывает без
`/opt/selkies/current`.

```bash
sudo cream install --with-deps pixelflux-tegra
```

В образе bisquite (VMFILE):

```dockerfile
RUN_COMMAND cream install --with-deps selkies
RUN_COMMAND cream install --with-deps pixelflux-tegra
```

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | проверка бэкенда, drop-in `LD_PRELOAD`, шим gbm на focal, отпечаток; перезапуск работающих `selkies@` |
| загрузка (`cream-configure@pixelflux-tegra`, стадия `graphical`, каждая загрузка) | проверка отпечатка, узла, доступа, бэкенда; группа `video` на JetPack 4 |
| `cream remove` | drop-in, шим и отпечаток сняты |

## Известные ограничения

- `platform.arch` — только arm64: кодер спрятан за вендорской `libnvv4l2.so`, её
  нет вне L4T. «Виден ли кодер» проверяется только на железе.
- Картинка, ввод, звук, переподключение — проверяются руками браузером, один раз
  на плату.

## Подробности

### Замер

Базовый образ Selkies сам несёт `pixelflux` с бэкендом Tegra — подменять колесо
не нужно. Замер на AGX Orin (L4T R36.4.3), 1080p@30, живая сессия с браузером:

| кодер | CPU процесса `selkies` |
|---|---|
| штатный x264 (то, что без вендорских библиотек) | **0.423 ядра** |
| аппаратный Tegra | **0.089 ядра** |

### Чего не решает базовый образ

Selkies несёт `pixelflux` с бэкендом Tegra и сам выбирает его лестницей по
факту наличия вендорских библиотек. Но две вещи базовый образ не решает.

### Подкладка libxcb нужна всегда

AppImage несёт свою `libxcb` (conda, 1.17), которая затеняет системную, а
X/EGL NVIDIA в L4T собран против системной. Смешение роняет поток захвата:
сессия стартует, сообщает кодер, отдаёт страницу — и через несколько секунд
процесс исчезает с `status=139`, а `Restart=always` превращает это в цикл.
Заведено апстриму: [selkies#396](https://github.com/selkies-project/selkies/issues/396).

Апстрим починил это **в `AppRun`**. Но наша служба `selkies@` запускает бинарь
**мимо `AppRun`**: обёртка `files/run-selkies.sh` расширения `selkies` цепляется к живой X-сессии
пользователя, а не поднимает Xvfb, как это делает `AppRun`. Поэтому подкладку
системной `libxcb` ставим сами — drop-in `selkies@.service.d/10-pixelflux-tegra.conf`
с `LD_PRELOAD`. Правка `files/run-selkies.sh` расширения `selkies` для этого не годится: расширение
`selkies` общее с amd64, и подкладка уехала бы в чужое окружение там, где
Selkies работает без неё.

### Шим gbm — только focal

В Mesa focal (Jetson Nano) нет `gbm_bo_create_with_modifiers2`, и на такой
системе `import pixelflux` может падать. Если в системной `libgbm` символа нет,
хук `install` собирает крошечный шим `gcc` в госте (готовый `.so` пришлось бы
держать в репозитории двоичным файлом) и добавляет его в тот же `LD_PRELOAD`.
На jammy шим не нужен.

### Доступ к узлу кодера: группа `video` на JetPack 4

На JetPack 5/6 узел кодера — `/dev/v4l2-nvenc`, клон `/dev/null` с правами
`0666`: группа не нужна. На JetPack 4 это `/dev/nvhost-msenc` с `root:video 0660`,
а cloud-init создаёт пользователя только с группой `sudo` — pixelflux молча ушёл бы
на x264. `configure` читает права узла битами (кодер открывается `O_RDWR`, `test -r`
этого не покажет), при нехватке добавляет пользователя сессии в группу узла
(`usermod -aG`, только в `video` или `render`; узел с другой группой — `root`,
`sudo`, `disk`, `docker` — даёт предупреждение без `usermod`: доступ к кодеру не
должен становиться root-доступом) и перезапускает `selkies@<пользователь>` с `--no-block`:
группы читаются при старте процесса.

## Проверки

- **V** — `make cream-validate`.
- **H** — `tests/test-pixelflux-tegra.sh`: манифест; `install` (20 без L4T и не на
  arm64, отказ без selkies, без бэкенда, без libxcb; jammy без шима, focal с шимом
  через временный файл, повтор ничего не меняет, drop-in и шим не по ссылкам);
  `configure` (нет узла, не тот бэкенд, устаревший отпечаток — 0; мусор из
  модуля и кривой drop-in не попадают в журнал и `LD_PRELOAD`; группа `video` на
  JetPack 4, не `root`; перезапуск сессии только `--no-block`); `remove`.
- **P** — ожидает: AGX Orin с `selkies` (бэкенд tegra, живая сессия в браузере).
