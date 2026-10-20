# nvidia-jetpack

Превращает обычную amd64-машину с Ubuntu 22.04 в **станцию прошивки NVIDIA
Jetson**: ставит инструментарий L4T, включает NFS-сервер, регистрирует binfmt
для aarch64, гасит USB-autosuspend для устройств NVIDIA; скрипты прошивки лежат
в дереве расширения — `/opt/cream/ext/nvidia-jetpack/scripts/`.

```bash
EXTENSION nvidia-jetpack                          # VMFILE bisquite: при сборке образа
sudo cream install --accept-risk nvidia-jetpack   # живая машина (live: confirm)
sudo cream remove nvidia-jetpack                  # снимает binfmt-файл и свои пакеты
```

> **С 3.0.0 — формат cream/v1.** `install.sh` стал хуком `hooks/install`, появился
> `hooks/remove`; udev-правило раскладывает cream (`files`); скрипты больше не
> копируются в `/opt/nvidia-jetpack/` — они в `/opt/cream/ext/nvidia-jetpack/scripts/`.

Расширение ставится на **ПК**, а не на плату. Соседнее `jetson-stats` — про
обратное, оно объявляет `arm64` и живёт на самой Jetson.

## Зачем это нужно

Прошивка AGX Orin Developer Kit под JetPack 6.2 (L4T 36.4.3) с загрузкой
с NVMe провалилась 2026-09-09: хост — Debian 13 (Proxmox 9), BSP рассчитан
на Ubuntu 22.04, окружение строилось руками через `chroot` в `ubuntu-base`.
Разрыв между хостом и BSP стоил восьми отдельных отказов, и каждый следующий
открывался только после починки предыдущего:

- `chroot: failed to run command 'dpkg': Exec format error` — конфликт
  `binfmt-support` с `systemd-binfmt`;
- `Error: xmlstarlet is not installed` — пакета нет в базовой установке;
- пустое `command is failed` — `ota_make_recovery_img_dtb.sh` зовёт
  `ssh-keygen -t dsa`, а OpenSSH выбросил DSA в 9.8 (Debian 13 несёт 10.0p2);
- пять отказов подряд вокруг NFS (`modprobe nfsd`, `rpcbind`, обёртка
  `service`, `nfsdcld`, `rpc_pipefs`) — просто потому, что в chroot нет
  init-системы.

Физическая машина с Ubuntu 22.04 закрывает обе группы разом: версии утилит
приходят из jammy, а init-система настоящая, и NFS поднимается штатным
`systemctl enable nfs-server`.

Каталог `.scratchpad/jetson-orin/`, где всё это жило, целиком в `.gitignore` —
воспроизвести станцию было неоткуда. Теперь она собирается из VMFILE.

## Манифест

| Поле | Значение |
|---|---|
| `schema` | `cream/v1`, `cream: ">=1.0.0"` |
| `platform` | `deb`, `arch: [amd64]`, `os`: `ubuntu`, `debian` |
| `targets` | `build: exec`; `live: confirm` — `live_note` перечисляет, что меняется на машине |
| `provides` | `jetson-flash-station` |
| `depends` | `apt-guard >=1.0.0 <2` — `remove` снимает только свои пакеты |
| `hooks` | `install` (30 мин), `remove` (15 мин); `configure` нет |
| `files` | `files/99-jetson-usb.rules` → `/etc/udev/rules.d/99-jetson-usb.rules` |

Способность названа по роли машины целиком («этот образ умеет прошивать
Jetson»), а не по отдельной утилите: ссылаться на расширение будут именно
так.

`requires` пуст: скрипты станции тянут BSP сами и работают с
системными пакетами, которые ставит этот же хук `install`. `depends` — только
библиотека `apt-guard`: `remove` сначала спрашивает apt симуляцией и
отказывает, если тот снял бы что-то кроме своих пакетов. Ни рабочего стола, ни
контейнеров, ни VNC им не нужно — образ станции включает их по другим
причинам.

`conflicts` пуст осознанно. С `nvidia` (проприетарный GPU-драйвер десктопа)
пересечения нет: там речь про видеокарту хоста, здесь — про USB-заливку
платы, общих файлов нет. С `l4t-kernel-kvm` и `l4t-board-fdt` — тоже: те
про Nano и tegra210.

`live: confirm`, а не `yes`: на живой машине расширение ставит около двадцати
пакетов (в том числе NFS-сервер, который поднимется на загрузке) и
перезапускает `systemd-binfmt` — это снимает и заново ставит **все**
обработчики binfmt машины, не только aarch64.

## Только `amd64` — у РАСШИРЕНИЯ, но не у сценариев

Инструментарий L4T (`flash.sh`, `tools/kernel_flash/*.sh`, `tegraflash.py`)
исполняется на x86_64-хосте и сам ходит в arm64-rootfs через
`qemu-user-static`. Станция — это ПК с USB-портом; arm64 в манифесте означал бы
«прошивать Jetson с другой Jetson», чего этот набор скриптов не делает.

**Но `arch: [amd64]` — про станцию прошивки, а не про сами сценарии.**
Изготовление базового образа (шаги `01`-`04` и `08`, плата не нужна) идёт
и на aarch64: x86-бинари NVIDIA выполняются под эмуляцией, если на хосте
зарегистрирован binfmt. Проверено на AGX Orin 2026-09-18 — шаг `08` прошёл
целиком на самой плате и выдал `jetson-orin-bsp.qcow2` 7.01 ГБ.

Нужны ДВА пакета, и второй легко забыть:

```bash
sudo apt-get install -y qemu-user-static binfmt-support
```

`qemu-user-static` сам регистраций не создаёт — их заводит `binfmt-support`
(`update-binfmts --display | grep -A1 qemu-x86_64` должен показать `enabled`).
Без него `flash.sh` встаёт на `./tegrarcm_v2: cannot execute binary file:
Exec format error`, и выглядит это как «на ARM нельзя», хотя дело в регистрации.

Прошивка кабелем (`05`-`07`) остаётся делом станции: ей нужен USB и плата
в recovery.

## Без `configure`

Хука `configure` нет. Всё, что делает расширение, от конкретной машины не
зависит: пакеты, симлинк сервиса, udev-правило, binfmt-файл и скрипты.
Донастраивать на загрузке нечего, а пустой `configure` был бы обещанием,
которого никто не держит.

## Что делает

### 1. Пакеты

Список выведен **эмпирически**, а не угадан: это все аргументы `command -v`
из `tools/kernel_flash/*.sh`, `tools/*.sh` и `flash.sh`, плюс то, что зовёт
`tegraflash.py` через `run_cpp_tool()`.

`zstd`, `cpp`, `device-tree-compiler`, `xmlstarlet`, `libxml2-utils`,
`sshpass`, `openssh-client`, `abootimg`, `uuid-runtime`, `lz4`, `cpio`,
`gdisk`, `parted`, `binutils`, `qemu-user-static`, `nfs-kernel-server`,
`python3-yaml`, `bzip2`, `wget`, `curl`, `v4l-utils`.

Ставятся только недостающие; уже стоящие apt не трогает. Поставленное этим
хуком записывается в `/var/lib/cream/ext/nvidia-jetpack/packages` — `remove`
снимает только их. У apt-команд стоит retry: пять попыток с задержкой 2, 4, 6,
8 секунд.

### 2. NFS-сервер

`systemctl enable nfs-server` — **enable, а не start**. Образ собирается
в libguestfs-приложении, где systemd не работает вовсе, и `start` отказал бы
всегда. Enable — offline расстановка симлинков; на живой станции сервис
поднимется сам и приведёт за собой `nfsdcld` и `rpc_pipefs`.

Не вышло — предупреждение, не отказ: доделывается одной командой
`systemctl enable --now nfs-server`, и ронять из-за симлинка сборку
на четыре гигабайта незачем.

### 3. binfmt для aarch64

`qemu-user-static` кладёт `/usr/bin/qemu-aarch64-static`, но сам обработчик ядру
не объявляет: на Ubuntu это делает postinst, и только при `binfmt-support`, а
внутри virt-customize нет работающего systemd. Замер 2026-09-11 на собранной
станции: эмулятор есть, в `/proc/sys/fs/binfmt_misc/` обработчика нет — и шаг
`04` отказал бы. Поэтому хук кладёт `/etc/binfmt.d/qemu-aarch64.conf` (шаблон —
`files/qemu-aarch64.conf`, флаг `F`), а регистрацию применяет `systemd-binfmt`.

- При сборке (`CREAM_PHASE=build`) и без работающего systemd — только файл,
  регистрация на первой загрузке.
- На живой машине с systemd — `systemctl --no-block restart systemd-binfmt`, и
  только когда файл изменился: перезапуск снимает и заново ставит все обработчики.
- В контейнере `binfmt_misc` общий с хостом — перезапуска нет (файл лежит).
- Нет эмулятора — предупреждение, файл не пишется (`F` без эмулятора уронил бы
  `systemd-binfmt` на загрузке).

Файл пишется через временный и `rename`: ссылка на его месте заменяется, а не
разыменовывается. `remove` снимает файл, только если он совпадает с шаблоном
байт в байт, и тогда же перезапускает `systemd-binfmt` (по тем же условиям).

### 4. udev-правило

`/etc/udev/rules.d/99-jetson-usb.rules` (поле `files`: кладёт cream до хука
`install`, снимает при `remove`) навсегда гасит USB-autosuspend для
устройств NVIDIA вместо ручного прохода по `/sys/bus/usb/*/power/control`
перед каждой заливкой:

```
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0955", TEST=="power/control", ATTR{power/control}="on"
```

Правило по **vendor**, а не по product, намеренно: за один сеанс прошивки
плата трижды меняет PID — `7020` (обычный режим) → `7023` (APX) → `7035`
(initrd), — и вдобавок наблюдалась миграция с Bus 001 на Bus 002. Правило
по product перестало бы действовать ровно в тот момент, когда идёт запись.

### 5. Скрипты станции

Скрипты никуда не копируются: cream раскладывает дерево расширения в
`/opt/cream/ext/nvidia-jetpack/`, и `scripts/*.sh`, `scripts/*.py` лежат там с
битом исполнения, `scripts/README.md` и профили — без него. Друг друга скрипты
находят относительно себя (`BASH_SOURCE`), поэтому путь нигде не прибит.

Нет каталога `scripts/` или нет в нём ни одного `*.sh`/`*.py` — **отказ**
хука `install` до apt. Станция без скриптов прошить ничего не может, и узнать
об этом на живой машине хуже, чем на сборке.

Профили — три оси, а не один каталог: `scripts/boards/`, `scripts/releases/`
и `scripts/pairs/`. Без профилей `load_profile` откажется собрать любую пару,
кроме той, что зашита в скрипты умолчаниями (AGX Orin, 36.4.3).

## Чего расширение НЕ делает

- **Ничего не запускает автоматически.** Ни таймеров, ни юнитов, ни
  firstboot-сервиса. Скрипты просто лежат в `/opt/cream/ext/nvidia-jetpack/scripts/`; прошивку
  начинает оператор, осознанно.
- **Не скачивает BSP.** Это +4 ГБ к образу, а датированные снапшоты NVIDIA
  удаляются с зеркала — ссылки протухают. Тянет BSP `01-fetch-l4t.sh`,
  на станции, когда оператор её запустил.
- **Не ставит SDK Manager по умолчанию** — он отдельным
  `90-install-sdkmanager.sh`, потому что под капотом зовёт тот же
  `l4t_initrd_flash.sh` с тем же NFS и главной проблемы не решает.
- **Не ставит камеры вовсе.** Базовый образ — только «плата × релиз»:
  пакет Sensing, `/opt/sensing` и подмену `libnvisppg.so` несёт слой
  bisquite, расширение `sensing-gmsl2-camera` (решение владельца 2026-09-18).
- **Не трогает ufw, место на диске и режим APX** — это предполётные проверки
  внутри `06-flash.sh`, там, где они что-то значат.

## Скрипты в `/opt/cream/ext/nvidia-jetpack/scripts/`

Нумерация — часть контракта: она и есть документация порядка.

| Скрипт | Что делает |
|---|---|
| `01-fetch-l4t.sh` | Качает BSP, sample rootfs (кроме пар с `ROOTFS_SOURCE=vendor-image`) и оверлей QSPI профиля; сверяет SHA1 с эталонами |
| `03-prepare-bsp.sh` | Распаковка, оверлей QSPI, `apply_binaries.sh`; при `vendor-image` — только дерево BSP, без `apply_binaries` |
| `04-customize-rootfs.sh` | Пользователь (пароль — `-P` файл 0600 или stdin, не argv) без `oem-config`, узел `/dev/null` и `<SOC>` в источнике apt NVIDIA внутри rootfs |
| `05-generate-images.sh` | `l4t_initrd_flash.sh --no-flash`; плата должна быть в recovery |
| `06-flash.sh` | `--flash-only`; предполётно проверяет ufw, место и режим APX |
| `07-flash-rootfs-ssh.sh` | Обход: rootfs в APP SSH-потоком, минуя NFS |
| `08-build-base-image.sh` | Образ диска (`.img` + `.qcow2`) для тиражирования на флот; плата не нужна |
| `09-build-jetson-base.sh` | Оркестратор `01`→`03`→`04 -U`→`11`→манифест→`08`→манифест; у `vendor-image` — `01`→`03`→`11`→образ вендора→qcow2→манифесты; собирает в `$WORK/.out-stage`, в `$OUT_DIR` результаты переносит оператор (`publish-out.sh`); в bisquite ничего не регистрирует |
| `10-flash-internal.sh` | Выборочно: только QSPI либо QSPI + внутренняя eMMC |
| `11-package-bootloader.sh` | Пакет прошивки загрузчика, плата не нужна: `l4t_initrd_flash.sh --massflash` у AGX, `nvmassflashgen.sh` у Nano |
| `14-flash-bootloader.sh` | Прошивка загрузчика готовым пакетом; плата в recovery; **необратимо**; у Nano — `nvmflash.sh` из самого пакета |
| `15-verify-pair.sh` | Доказывает по самому BSP, что пара плата×релиз вообще собирается; у Nano — ещё sha256 образа вендора |
| `16-matrix.sh` | Таблица «плата × релиз × статус» из профилей и записей |
| `90-install-sdkmanager.sh` | SDK Manager по редирект-ссылке NVIDIA |
| `manifest.py` | Пишет внутренний (в rootfs) и внешний (рядом с артефактами) манифесты пары |
| `vendor-image.sh` | Подключается шагом `09`: образ вендора в кеш со сверкой sha256, разреженный raw, qcow2, внутренний манифест |
| `publish-out.sh` | Подключается шагом `09`: каталог сборки только для root и перенос результатов в `$OUT_DIR` от имени оператора (`OUT_OWNER` или `SUDO_UID`) |

Порядок запуска и что делать при обрыве — в `/opt/cream/ext/nvidia-jetpack/scripts/README.md`.

### Плата и релиз задаются профилем, а не правкой

Скрипты платонезависимы: версия L4T со ссылками и суммами, XML разметки,
конфиг QSPI, цель `flash.sh` и SKU модуля читаются из окружения.
Согласованный набор на пару собирает `load_profile` из трёх осей:

| Каталог | Что несёт |
|---|---|
| `boards/<плата>.env` | железо: SoC, `BOARDID`/`FAB`/`BOARD_SKU`/`BOARDREV`, `ROOTFS_DEV`, `BOOTLOADER_PACKAGE`, `BOOTLOADER_TOOL` (`initrd-flash` у AGX, `nvmassflashgen` у Nano) |
| `releases/<релиз>.env` | версия L4T со ссылками и суммами, совместимые SoC (`SOCS`), официальные хосты прошивки |
| `pairs/<плата>@<релиз>.env` | точечное исключение на конкретную пару: свой оверлей QSPI, у смешанной пары — источник системы (`ROOTFS_SOURCE`, `ROOTFS_L4T`, `VENDOR_IMG_*`) |

```bash
. /opt/cream/ext/nvidia-jetpack/scripts/profile.sh && load_profile agx-xavier 35.6.5
sudo -E /opt/cream/ext/nvidia-jetpack/scripts/09-build-jetson-base.sh
```

`sudo -E` обязателен — иначе sudo вычистит окружение и соберётся Orin.
`WORK` вычисляется из пары (`/srv/l4t/<плата>@<релиз>`), если не задан явно —
два релиза одной платы в общем каталоге затёрли бы друг друга, шаг `03`
необратим. AGX Xavier на JetPack 5.1.7 (L4T 35.6.5) объявлен, но **не
прогнан на железе**.

## Подключение

```vmfile
EXTENSION nvidia-jetpack
```

При сборке образа хук `install` выполняет cream в госте (`targets.build: exec`).
На живой машине — `sudo cream install --accept-risk nvidia-jetpack`: без
`--accept-risk` cream не ставит, текст риска — `targets.live_note`.

Целевой образ — Ubuntu 22.04 (jammy) с рабочим столом; L4T 36.4.3 официально
требует 20.04/22.04, про 24.04 есть прямые сообщения о несовместимости
инструментария.

## Параметров нет

Ключей настройки (`config.keys`) у расширения нет: `EXTENSION nvidia-jetpack`
и `cream install nvidia-jetpack` параметров не принимают.

Настраивается всё **на станции**, переменными окружения самих скриптов:
`WORK` (рабочий каталог, умолчание `/srv/jetson` без профиля, иначе
`/srv/l4t/<пара>`), `APP_SIZE`, `MIN_FREE_GIB`, `BOARD_TARGET` и профильные
`BSP_URL`/`FLASH_XML`/`BOARD_SKU`/… Полная
таблица с умолчаниями — в `/opt/cream/ext/nvidia-jetpack/scripts/README.md` (он же
`scripts/README.md` в этом дереве); согласованные наборы на пару плата×релиз —
в `boards/`, `releases/`, `pairs/`, собирает их `load_profile` из `profile.sh`.
Такой порядок выбран потому, что все эти значения зависят от носителя и от
конкретной платы, а не от образа: зашитые в образ, они потребовали бы
пересборки ради `-S`.

## Проверка

После загрузки станции:

```bash
ls -l /opt/cream/ext/nvidia-jetpack/scripts/   # скрипты на месте, 0755
ls /etc/binfmt.d/qemu-aarch64.conf /proc/sys/fs/binfmt_misc/ | grep qemu-aarch64
systemctl is-enabled nfs-server     # enabled
systemctl is-active nfs-server      # active
cat /etc/udev/rules.d/99-jetson-usb.rules
command -v xmlstarlet zstd dtc sshpass abootimg sgdisk qemu-aarch64-static
```

С платой в recovery:

```bash
lsusb | grep -i 0955                            # плата видна
cat /sys/bus/usb/devices/*/power/control        # должно быть on
```

## Известные ограничения

- **Станция не гарантирует успешной заливки.** Обрыв на распаковке
  `system.img` (`nfs: server ... not responding, still trying` → `timed out`
  и уже без восстановления) — **известная проблема самого L4T**, а не
  следствие окружения: пользователи Orin сообщают об успехе после нескольких
  попыток. Расширение убирает устранимое — нестабильное окружение, ufw,
  нехватку места, версии утилит, — но не эту проблему. На неё есть проверенный
  обход: `07-flash-rootfs-ssh.sh` льёт rootfs в APP SSH-потоком, минуя NFS;
  тот же объём (2.2 ГБ → 6.9 ГБ) по тому же кабелю прошёл с первого раза.
- **`mke2fs` отсутствует в initrd платы**, поэтому шаг форматирования
  в SSH-обходе не отрабатывает и распаковка ложится поверх прежнего
  содержимого. Практически безвредно — тот же архив, — но раздел не чист.
- **`-S 40GiB` под вопросом.** Дефолтная конфигурация L4T рассчитана на
  внешний носитель ≥64 ГБ, а NVMe здесь терабайтный. Значение осталось
  с прошлых попыток и требует замера, а не переноса по инерции.
- **VM с проброшенным USB-портом не годится.** Плата меняет PID трижды за
  сеанс и мигрирует между шинами; проброс пришлось бы делать для обеих, и
  обрыв пришёлся бы на начало записи. Станция — физическая машина, и это
  единственный проверенный вариант.

## Проверки

- **V** — `make cream-validate`, `tools/check-names.sh`, `tools/lint-hooks.sh`.
- **H** — `tests/test-hooks.sh`: манифест, установка при сборке и на живой машине,
  повтор без apt и без перезапуска, binfmt (перезапуск `systemd-binfmt` только на
  живой машине с systemd вне контейнера; ссылка на месте файла не разыменовывается;
  без эмулятора файла нет), отказ без `scripts/`, `remove` только своего (симуляция снимает
  чужой пакет — отказ); `tests/test-nvidia-jetpack.sh` — сценарии станции (профили, манифесты,
  шаги, пароль шага `04` только через `-P`, перенос результатов `09` оператором) без BSP и платы.
- **L** — `make test-live EXT=nvidia-jetpack` (`tests/live.env`: `LIVE_DEPS=apt-guard`, `--accept-risk`) на
  `ubuntu-22.04` и `debian-12`: установка, повтор, `--reinstall`, загрузка, `remove`; без
  прошивки платы и без binfmt хоста. NFS-сервер в контейнере без `CAP_SYS_ADMIN` не
  поднимается: `proc-fs-nfsd.mount` и `run-rpc_pipefs.mount` разрешено упасть
  (`LIVE_FAILED_IGNORE`), раннер печатает их отдельной строкой.
- **P** — прошивка платы на физической станции по `scripts/README.md`.

## Лицензия

Расширение распространяется на условиях публичной некоммерческой лицензии
Bisquite (PolyForm Noncommercial 1.0.0, см. `LICENSE`). Для коммерческого
использования требуется отдельная платная лицензия — см. `NOTICE`.
