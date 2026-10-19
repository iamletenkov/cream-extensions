# pixelflux-tegra

Формат cream/v1 (план 2026-10-19, Task 27), версия 3.0.0.

Аппаратное кодирование H.264/H.265 в Selkies на NVIDIA Jetson.

С **Selkies 2.0.0** сам базовый образ несёт `pixelflux 2.1.0` с бэкендом
Tegra — подменять колесо больше не нужно. Но одно расширение всё равно
требуется: **подкладка системной `libxcb`** (и шим `gbm` на focal), без которой
сессия на Jetson падает через секунды после старта захвата, плюс проверка на
живом железе.

Замер на AGX Orin (L4T R36.4.3), 1080p@30, живая сессия с браузером:

| кодер | CPU процесса `selkies` |
|---|---|
| штатный x264 (то, что без вендорских библиотек) | **0.423 ядра** |
| аппаратный Tegra | **0.089 ядра** |

## Манифест

| поле | значение | почему |
|---|---|---|
| `version`, `cream` | `3.0.0`, `">=1.1.0"` | стадия `graphical` |
| `platform.arch` | `[arm64]` | кодер спрятан за вендорской `libnvv4l2.so`, её нет вне L4T |
| `targets` | `build: exec`, `live: yes` | подкладка и шим — хуком `install`; «виден ли кодер» — только на железе |
| `requires` | `[web-remote-desktop]` | рабочий стол даёт `selkies`, это его ускоритель |
| `depends` | `cloud-user >=1.0.0 <2` | пользователь сессии — для доступа к узлу кодера |
| `provides` | пусто | `hw-video-codec` принадлежит `l4t-gstreamer` |
| `conflicts.extensions` | `[pixelflux-v4l2m2m]` | оба настраивают pixelflux одного AppImage |
| хуки | `install`, `configure` (стадия `graphical`), `remove` | |

Ставится после `selkies`: `requires` это требует, а хук `install` отказывает без
`/opt/selkies/current`. Не Jetson (нет `/etc/nv_tegra_release`) или не arm64 —
`install` возвращает **20** (рулинг Р11).

## Зачем это нужно

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

## Доступ к узлу кодера: группа `video` на JetPack 4

На JetPack 5/6 узел кодера — `/dev/v4l2-nvenc`, клон `/dev/null` с правами
`0666`: группа не нужна. На JetPack 4 это `/dev/nvhost-msenc` с `root:video 0660`,
а cloud-init создаёт пользователя только с группой `sudo` — pixelflux молча ушёл бы
на x264. `configure` читает права узла битами (кодер открывается `O_RDWR`, `test -r`
этого не покажет), при нехватке добавляет пользователя сессии в группу узла
(`usermod -aG`, не в `root`) и перезапускает `selkies@<пользователь>` с `--no-block`:
группы читаются при старте процесса.

## Что проверяется и когда

**`install`** — что базовый `pixelflux` несёт бэкенд Tegra (апстрим уронит — установка
встанет), что модуль импортируется с той же подкладкой, что получит сессия, и что
drop-in записан. Живой проверки здесь нет: в appliance сборки нет ни устройств, ни X.

**`configure`** (каждая загрузка, стадия `graphical`; было `verify-pixelflux-tegra.service`)
— отпечаток совпадает с текущим AppImage, есть узел кодера, у пользователя сессии
есть доступ, drop-in на месте, и `pixelflux` сам отвечает
`hardware_encoders()["h264"] == "tegra"`. Нет узла, другой бэкенд, устаревший
отпечаток — **предупреждение в журнале и код 0** (рулинг Р11): упавший юнит
загрузки никому не помогает. Сбой — только если `usermod` отказал. После
`install`/`upgrade` работающие `selkies@` перезапускаются (`--no-block`), чтобы
подкладка дошла до процесса.

**Руками, один раз на плату (P)** — браузером: картинка, ввод, звук, переподключение.

## Что и где пишет

Всё — атомарно (временный файл рядом и `rename`), не по символическим ссылкам;
в дерево `selkies` и в домашние каталоги — ничего.

| Путь | Что |
|---|---|
| `/etc/systemd/system/selkies@.service.d/10-pixelflux-tegra.conf` | `Environment=LD_PRELOAD=…` (+ `daemon-reload` на живой машине) |
| `/var/lib/cream/ext/pixelflux-tegra/gbm_shim.so` | шим gbm, только focal; собирается `gcc -shared -fPIC -O2` из `files/gbm_shim.c` во временном каталоге там же |
| `/var/lib/cream/ext/pixelflux-tegra/stamp` | `prefix=/opt/selkies/<версия>`: подъём AppImage без переустановки расширения `configure` замечает |

`remove` снимает все три. Ручек расширение не добавляет: кодер выбирает лестница
pixelflux, `SELKIES_ENCODER` — в схеме `selkies`.

## Переименования (layout 2 → cream/v1)

<!-- check-names: off -->
| Было (2.x) | Стало (3.0.0) |
|---|---|
| `install.sh`, `configure.sh` | `hooks/install`, `hooks/configure` |
| `verify-pixelflux-tegra.service` | `cream-configure@pixelflux-tegra` (стадия `graphical`) |
| `/opt/bisquite/pixelflux-tegra-runtime/gbm_shim.so` | `/var/lib/cream/ext/pixelflux-tegra/gbm_shim.so` |
| отпечаток `/opt/selkies/<версия>/.bisquite-pixelflux-tegra` | `/var/lib/cream/ext/pixelflux-tegra/stamp` |
| не Jetson — сбой `install.sh` | `install` — код 20 |
| отказ проверки на загрузке — упавший юнит | предупреждение и код 0 |
<!-- check-names: on -->

## Проверки

- **V** — `make cream-validate`.
- **H** — `tests/test-pixelflux-tegra.sh`: манифест; `install` (20 без L4T и не на
  arm64, отказ без selkies, без бэкенда, без libxcb; jammy без шима, focal с шимом
  через временный файл, повтор ничего не меняет, drop-in и шим не по ссылкам);
  `configure` (Р11: нет узла, не тот бэкенд, устаревший отпечаток — 0; мусор из
  модуля и кривой drop-in не попадают в журнал и `LD_PRELOAD`; группа `video` на
  JetPack 4, не `root`; перезапуск сессии только `--no-block`); `remove`.
- **P** — ожидает: AGX Orin с `selkies` (бэкенд tegra, живая сессия в браузере).
