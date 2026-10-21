# docker

Docker CE из официального apt-репозитория Docker (`download.docker.com`).

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | amd64, arm64 |
| cream | ≥ 1.2.0 |
| Даёт | `container-runtime` |
| Требует | — |
| Зависит от | [`cloud-user`](../cloud-user/README.md), [`apt-guard`](../apt-guard/README.md) |
| Конфликтует с | — |
| Хуки | `install`, `configure`, `remove` |
| Настройка на загрузке | стадия `system`, на каждой загрузке (`every_boot`) |
| Живая машина | с `--accept-risk` |

> **Живая машина — с `--accept-risk`.** Снимает конкурирующие пакеты, если стоят: docker.io, docker-cli, docker-compose, docker-compose-v2, docker-doc, docker-buildx, podman-docker, containerd, runc — их контейнеры останавливаются, обратно remove их не ставит; пользователь cloud-init получает группу docker (равносильно root); на Raspberry Pi правит cmdline.txt (нужна перезагрузка); на Jetson перезапускает dockerd под среду выполнения NVIDIA
<!-- /catalog:facts -->

## Что делает

**Установка** (`hooks/install`, при сборке и на живой машине)

- опознаёт систему по `/etc/os-release` и **отказывается** работать, если
  `ID` не `debian` и не `ubuntu`;
- снимает конфликтующие пакеты, если они стоят: `docker.io`, `docker-cli`,
  `docker-compose`, `docker-compose-v2`, `docker-doc`, `docker-buildx`,
  `podman-docker`, `containerd`, `runc`;
- прописывает ключ (`/etc/apt/keyrings/docker.asc`) и репозиторий в формате
  deb822 (`/etc/apt/sources.list.d/docker.sources`);
- проверяет, есть ли вообще пакет для этой цели, и предупреждает о
  замороженных сюитах;
- ставит ровно пять пакетов: `docker-ce`, `docker-ce-cli`, `containerd.io`,
  `docker-buildx-plugin`, `docker-compose-plugin`;
- на Jetson подключает репозиторий NVIDIA, ставит `nvidia-container-toolkit`
  и зовёт `nvidia-ctk runtime configure --runtime=docker`;
- записывает, какие пакеты поставил сам (не стоявшие до него), в
  `/var/lib/cream/ext/docker/packages` — это всё, что снимет `remove`;
- на живой машине перед установкой пакетов делает `systemctl daemon-reload`:
  postinst сразу стартует `docker.service`, и drop-in проверки iptables raw,
  который cream разложил до хука, должен быть уже виден.

cream раскладывает файлы расширения (`files`): проверку
`/usr/local/libexec/docker-iptables-raw-check` (0755) и drop-in
`/etc/systemd/system/docker.service.d/10-docker-iptables-raw.conf` — см. «Ядро без
таблицы iptables raw».

**Каждая загрузка и сразу после установки** (`hooks/configure` в
`cream-configure@docker`, стадия `system`, `after: [docker.service]` — группа уже
заведена postinst, а перезапуск под NVIDIA видит демон)

- добавляет пользователя cloud-init в группу `docker` — при сборке имя
  пользователя ещё неизвестно;
- на Raspberry Pi добавляет `cgroup_enable=memory` в
  `/boot/firmware/cmdline.txt` (копия `.before-docker` снимается один раз и
  не перезаписывается) и выходит с кодом 10 — нужна перезагрузка; на сборке
  этот файл недостижим, см. «Почему правка cmdline.txt — в configure»;
- на Jetson перезапускает демон (`systemctl --no-block try-restart`), чтобы
  подхватилась среда выполнения NVIDIA (`nvidia-ctk` правил `daemon.json`
  в chroot, где демона не было). Перезапуск — только когда `daemon.json`
  отличается от того, под который демон уже перезапускали (sha256 в
  `/var/lib/cream/ext/docker/daemon-json.sha256`), а не на каждой загрузке.

Все три шага идемпотентны и проверяют факт перед правкой. Нет пользователя,
группы `docker` или устройства — предупреждение и код 0.

**Снятие** (`hooks/remove`, `cream remove docker`)

- `apt-get remove` (не `purge`) пакетов из `/var/lib/cream/ext/docker/packages`:
  образы, тома (`/var/lib/docker`) и `/etc/docker/daemon.json` остаются;
  Docker, стоявший до cream, не трогается. Сначала apt спрашивается
  симуляцией (библиотека `apt-guard`): снял бы что-то кроме своих пакетов —
  отказ (код 1), ничего не меняется; сбой `apt-get remove` — код 1, запись
  остаётся для повтора;
- снимает источник и ключ Docker, свой источник и ключ NVIDIA, обновляет
  списки apt; проверку iptables raw, drop-in и `cream-configure@docker`
  снимает сам cream;
- не возвращает снятые при установке конкурирующие пакеты, не выводит
  пользователя из группы `docker` и не откатывает `cgroup_enable=memory`
  в `cmdline.txt` (без Docker безвредно; бэкап `.before-docker` на месте).

Снятие конфликтующих пакетов — не вкусовщина: `docker.io` конфликтует
с `docker-ce` напрямую, `docker-cli` — с `docker-ce-cli`, а
`docker-compose-v2` добавлен в список по документации самого Docker для
Ubuntu. Неудачное удаление остаётся предупреждением — пакет мог быть
и не установлен по-настоящему.

Все вызовы apt идут через обёртку с повторами (до пяти попыток, задержка
растёт) и с `DEBIAN_FRONTEND=noninteractive` плюс
`-o Dpkg::Options::=--force-confnew`: сборка не может ответить на
интерактивный вопрос про конфиг.

## Параметры

<!-- catalog:params -->
Параметров нет.
<!-- /catalog:params -->

### Параметров нет

Расширение не читает ни одного ключа: всё, на что оно
ветвится, оно спрашивает у самой машины — `/etc/os-release` для сюиты
репозитория, `apt-cache policy docker-ce` для наличия пакета,
`/etc/rpi-issue`, `/boot/firmware/cmdline.txt` и `/etc/nv_tegra_release`
для железа. Ручка здесь означала бы второй источник правды рядом с ответом,
который и так точен.

## Установка

На машине с подключённым каталогом ([как подключить](../../../docs/getting-started.md));
`live: confirm` — нужен `--accept-risk` (см. «Почему `live: confirm`»), библиотеки
`cloud-user` и `apt-guard` cream поставит сам, по `depends`:

```bash
sudo cream install --with-deps --accept-risk docker
sudo cream remove docker
```

В образе bisquite (VMFILE):

```dockerfile
RUN_COMMAND cream install --with-deps docker
```

`hooks/install` при сборке запускается внутри `virt-customize`, то есть под
барьером архитектуры: arm64-образ собирается только на arm64-хосте.

**Предупреждения этого расширения по умолчанию не видны.** `virt-customize`
не печатает вывод гостевых команд вовсе, а расширение говорит вслух и про
заморозку сюиты, и про то, что членство в группе `docker` равносильно root.
Читать их — `bs image build -v`. На живой машине они идут в stderr `cream`
и в журнал `cream-configure@docker`.

`yq` (`RUN_COMMAND cream install --with-deps yq` в VMFILE, `cream install yq` на
машине) раньше этого расширения не обязателен, но **желателен** — см. «Как
определяется пользователь для группы `docker`».

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | конкуренты сняты, репозиторий и пять пакетов, NVIDIA на Jetson, запись своих пакетов |
| загрузка (`cream-configure@docker`, каждая) | группа `docker`, `cmdline.txt` на Pi (код 10), перезапуск под NVIDIA при смене `daemon.json` |
| старт `docker.service` | `ExecStartPre` проверки iptables raw |
| `cream remove` | свои пакеты, источники и ключи сняты; данные Docker остаются |

Что править на живой машине и чем перезапускать:

| Надо | Править | Применять |
|---|---|---|
| настройки демона (среды выполнения, логи, зеркала) | `/etc/docker/daemon.json` | `sudo systemctl restart docker` |
| ограничения памяти на Pi | `/boot/firmware/cmdline.txt` | перезагрузка |
| ещё одного пользователя в группу | `sudo usermod -aG docker <имя>` | новый сеанс пользователя (`usermod` не меняет уже открытый) |

Своего файла настроек расширение не держит: повторный прогон
`sudo cream configure docker` только перепроверит группу,
`cmdline.txt` и необходимость перезапуска демона. `daemon.json` он не
перезаписывает — его правил `nvidia-ctk` один раз, на сборке.

## Известные ограничения

- Только amd64 и arm64: `binary-armhf` в репозитории есть, но проект его не собирает.
- **Членство в группе `docker` равносильно root на этой машине** — через сокет
  поднимается привилегированный контейнер. Расширение говорит это вслух, чтобы
  это было решением, а не случайностью.
- Нет кандидата `docker-ce` — громкий отказ, без отката на `docker.io` (см.
  «Гейт вместо таблицы»). Замороженные сюиты дают старый Docker.
- На Raspberry Pi лимиты памяти заработают только после перезагрузки; для сборки
  raspios с Docker нужен `RESIZE` минимум до 16 ГБ.
- На ядре без таблицы iptables raw защита прямого доступа к контейнерам снята
  (см. «Ядро без таблицы iptables raw»).
- В гонке «cloud-init есть, userdata ещё нет» группа на первой загрузке не
  назначается; назначится на следующей.
- OpenWrt этим расширением не поддерживается; образы OpenWrt собирает bisquite отдельно.

## Подробности

### Почему `live: confirm`

На живой машине `install` снимает конкурирующие пакеты (`docker.io`,
`docker-cli`, `docker-compose`, `docker-compose-v2`, `docker-doc`,
`docker-buildx`, `podman-docker`, `containerd`, `runc`), и их контейнеры
останавливаются; `remove` их обратно не ставит. Пользователь cloud-init получает
группу `docker`, а она равносильна root. На Raspberry Pi правится `cmdline.txt`
(нужна перезагрузка), на Jetson перезапускается `dockerd`. Поэтому без
`--accept-risk` cream не ставит; текст риска — `targets.live_note`.

### Почему один путь, а не два

Отдельного пути через `get.docker.com` нет. Довод «на старых системах
нужен `get.docker.com`, на новых репозиторий» оказался неверен дважды:

- **скрипт ставит из того же репозитория**, только пишет однострочный `.list`
  вместо deb822 (`getdocker.sh:596,606`). Второго источника пакетов никогда
  не было;
- **на bionic скрипт ломает сборку**: `version_gte()` при пустом `VERSION`
  возвращает истину всегда (`getdocker.sh:230-234`), поэтому в список
  безусловно попадает `docker-model-plugin`, которого в репозитории bionic нет
  ни для amd64, ни для arm64. При `set -e` это фатально.

### Почему нет ветвления по дистрибутиву

Замеры 2026-09-03:

- deb822 с `Signed-By: <путь>` работает начиная с apt 1.6.17 (bionic).
  Встроенный ключ требует apt ≥ 2.4 и нигде не нужен;
- 64-битная Raspberry Pi OS объявляет `ID=debian` — её обслуживает
  `linux/debian`. Репозиторий `linux/raspbian` только armhf и без trixie;
- `${UBUNTU_CODENAME:-$VERSION_CODENAME}` покрывает оба семейства одним
  выражением — так написано в инструкциях самого Docker;
- пять имён пакетов одинаковы на всех целях, включая bionic.

Ветвления есть, но они **по признакам железа** и ортогональны системе:
`/etc/rpi-issue` и `/boot/firmware/cmdline.txt` для Pi, `/etc/nv_tegra_release`
для Jetson. Pi 4 с Ubuntu и Jetson с JetPack 6 оба дают `ID=ubuntu`, так что
ветка по `ID` промахнулась бы по обоим.

Строка `Architectures: <arch>` в `docker.sources` обязательна: Raspberry Pi OS
собирается с добавленной второй архитектурой (`dpkg --add-architecture`
в pi-gen), и без неё apt пойдёт ещё и за индексом, которого в репозитории
может не быть.

### Гейт вместо таблицы

Перед установкой скрипт спрашивает `apt-cache policy docker-ce`. Нет
кандидата — **громкий отказ**, без отката на дистрибутивный `docker.io`.
Заодно это ловит опечатку в кодовом имени и молча не отработавший
`apt-get update`; сверяться с таблицей поддерживаемых сюит нельзя —
таблица устарела бы молча. Поэтому `platform.os` — любая версия Debian и Ubuntu.

Откат был бы тихим: VMFILE один, а на флот уехали бы образы с разными
движками (`download.docker.com` даёт 29.7.2, `docker.io` — 26.1.5 на
Debian 13 и 20.10.12 на Ubuntu 22.04). Это та же подмена гарантии надеждой,
из-за которой установку не переносят на первую загрузку. Нужен
`docker.io` — заводите отдельное расширение под своим именем.

### Замороженные сюиты

Наличие пакета и его свежесть — разные вопросы. Репозиторий для bionic
существует и работает, но заморожен:

```
dists/bionic/Release   Date: 13 Jun 2023   docker-ce 24.0.2
dists/noble/Release    Date: 02 Sep 2026   docker-ce 29.7.2
```

Скрипт предупреждает вслух для `trusty`, `xenial`, `bionic`, `focal`,
`stretch`, `buster`. Это потолок цели, а не выбор способа.

### Почему правка cmdline.txt — в configure

Ядро Pi умеет memcg (`CONFIG_MEMCG=y` во всех ветках), но DTB его гасит:
`bcm2711-rpi-ds.dtsi` и `bcm2712-rpi.dtsi` несут `cgroup_disable=memory`
в `bootargs`. Без правки `docker run --memory` **молча** игнорируется:

```
WARNING: Your kernel does not support memory limit capabilities
         or the cgroup is not mounted. Limitation discarded.
```

Замер на arm64 (2026-09-03): внутри `virt-customize` каталог
`/boot/firmware` **пуст** — libguestfs не монтирует FAT-раздел, хотя в fstab
гостя он объявлен. В корне лежит только заглушка `/boot/cmdline.txt`
с текстом «DO NOT EDIT THIS FILE».

Значит проверка `[[ -f /boot/firmware/cmdline.txt ]]` на сборке не находила
файл никогда и молча уходила в ветку «не Raspberry Pi». Образ собирался
зелёным, а `docker run --memory` на устройстве продолжал игнорироваться.

На загрузке раздел смонтирован по fstab — там правка и делается (`configure`),
одной строкой (загрузчик требует, чтобы всё осталось на одной строке),
и **вступает в силу только после перезагрузки**: хук выходит с кодом 10, cream
пишет `reboot_required` в реестр и создаёт `/run/reboot-required`.
`cgroup_enable=` — патч Raspberry Pi, не upstream, поэтому на чужом ядре
аргумент просто проигнорируется, а проверка наличия файла такой случай и так
отсекает.

**Первый прогон на arm64 упал не из-за расширения**, а из-за размера: корень
raspios 8 ГБ, Docker с зависимостями туда не влез
(`cannot copy extracted data for './usr/bin/git' … No space left on device`).
Для сборки с Docker нужен `RESIZE` минимум до 16 ГБ.

### Jetson: среда выполнения NVIDIA

Берётся из джетсоновского репозитория (`repo.download.nvidia.com/jetson/common`,
сюита `r<release>.<major revision>` из `/etc/nv_tegra_release`), а не из общего
`nvidia.github.io`: пакеты `nvidia-container-csv-*` публикуются только там,
а без них контейнер не увидит CUDA/cuDNN/TensorRT хоста. `nvidia-docker2`
объявляет `Depends: docker-ce | docker-ee | docker.io`, так что установленный
выше Docker CE её удовлетворяет.

**Свой источник добавляется только если его ещё нет**, и это починка
ломающего дефекта, а не аккуратность. Вендорские образы L4T несут репозиторий
сами — `nvidia-l4t-apt-source.list` с тем же URI, но **без** `Signed-By`,
ключ у них в общем `trusted.gpg.d`. Наш файл с `Signed-By` давал:

```
E: Conflicting values set for option Signed-By regarding source
   https://repo.download.nvidia.com/jetson/common
E: The list of sources could not be read.
```

Ломался при этом не docker — он к тому моменту уже стоял, — а **весь** список
источников, то есть каждый следующий слой сборки. Замер 2026-09-04 на Jetson
Nano: сборка дошла до расширения `vino-vnc` и упала там на
`apt-get install vino`, хотя виновата была эта строка тремя слоями раньше.
Если наш файл остался от прежней сборки, он удаляется — иначе конфликт
переживёт починку.

Неустановившийся `nvidia-container-toolkit` — предупреждение, а не отказ:
Docker работает, GPU в контейнерах не будет.

### Ядро без таблицы iptables raw

Docker 28+ ставит в `raw/PREROUTING` правило DROP на пакеты, адресованные
прямо IP контейнера мимо `docker0`. Если в ядре нет таблицы raw, он не
снимает защиту сам, а **отказывает в запуске любого контейнера в bridge-сети**:

```
failed to set up container networking: … Unable to enable DIRECT ACCESS
FILTERING - DROP rule: … can't initialize iptables table `raw'
```

Замер 2026-09-14, Jetson AGX Orin, ядро Sensing поверх L4T 36.4.3:
`# CONFIG_IP_NF_RAW is not set`, модуля `iptable_raw` нет. Работало только
`--network host`.

Расширение кладёт (`files`) `ExecStartPre` для `docker.service`
(`/usr/local/libexec/docker-iptables-raw-check`, drop-in
`docker.service.d/10-docker-iptables-raw.conf`): перед каждым
стартом dockerd он пробует `modprobe iptable_raw` и `iptables -t raw -L`,
и **только если таблицы нет** выставляет `DOCKER_INSECURE_NO_IPTABLES_RAW=1`
через `/run/docker-iptables-raw/env`. На обычном ядре защита
остаётся. Проверка — на старте, а не на сборке: внутри `virt-customize`
ядро не загружено, а ядро образа может смениться после.

Чем платите на таком ядре: соседи по сети, которые пропишут маршрут
к `172.17.0.0/16` через эту машину, достанут до портов контейнеров
напрямую, в том числе неопубликованных. Решение в журнале видно:

```bash
journalctl -u docker -b | grep "iptables raw"
```

Проверено на плате: без правки `docker run` падал, с ней контейнер
стартует в bridge-сети, работают DNS, `apt-get update` внутри и проброс
порта — и с платы, и по сети.

### Как определяется пользователь для группы `docker`

`hooks/configure` зовёт библиотеку [`cloud-user`](../cloud-user/README.md) по её
постоянному пути `${CREAM_ROOT:-}/opt/cream/ext/cloud-user/get_cloud_user.sh`
(cream ставит её раньше по `depends`): имя берётся из userdata cloud-init, а при
отсутствии `cloud-init` или `yq` — первая по порядку `/etc/passwd` учётка с uid
1000..65533 и домашним каталогом. Не определился никто — предупреждение, группа не
назначена; отказа нет, потому что Docker от этого работать не перестаёт.

**Своего запасного пути у расширения нет** — только библиотека. Довод — замер
2026-09-04 на живом Jetson, вендорский образ без cloud-init: `vino-vnc` и
`jetson-stats` не настроились, а `docker` настроился, потому что запасной путь
(тот же перебор «uid ≥ 1000 и домашний каталог») был только у него. Довод записан
в самой библиотеке: её и централизовали, чтобы не держать девять расходящихся копий.

Локальная копия **расходилась** по поведению, и расхождение было в худшую сторону.
Общий скрипт различает два случая: «`cloud-init` нет» — запасной путь, и
«`cloud-init` есть, userdata пока нет» — отказ, потому что вендорская учётка
сейчас не та, которую cloud-init создаст через секунду. Копия различия не
делала и в этой гонке выдавала группу `docker` вендорской учётке, то есть
**давала ей права, равносильные root**.

Следствие, которое надо знать: в такой гонке на первой загрузке группа
не назначается вовсе, и в журнале стоят два предупреждения об этом. Цикла
ожидания здесь нет и не нужно — configure прогоняется на каждой
загрузке, а userdata cloud-init остаётся лежать в `/var/lib/cloud/instance`,
поэтому на следующей загрузке имя определяется и группа назначается.
Стадия `system`, а не `cloud-user`, намеренно: `cloud-user` (cream 1.1) дала бы
порядок после `cloud-final`, но привязала бы Docker к новой версии cream ради
удобства, которое и так догоняется на следующей загрузке. `after:
[cloud-final.service]` при стадии `system` нельзя: привязка
`multi-user.target.wants`, а `cloud-final` сам объявлен
`After=multi-user.target` — это кольцо, и оно замерено (2026-09-06, три молча
выброшенных службы).

Вывод библиотеки в stderr **не глушится**: скрипт говорит там, что
пошёл запасным путём и какую учётку выбрал, — ровно то, что надо видеть
в журнале, если группу получил не тот пользователь.

`yq` раньше этого расширения не обязателен, но **желателен**: без `yq` имя
берётся запасным путём, а он угадывает, тогда как userdata знает точно.

### Проверено на

| Система | Архитектура | Что получилось | Дата |
|---|---|---|---|
| Debian 13 trixie | amd64 | `docker-ce 5:29.7.2-1~debian.13~trixie`, `containerd.io 2.3.4`, плагины `buildx` и `compose` на месте | 2026-09-03 |
| Ubuntu 18.04 bionic | amd64 | `docker-ce 5:24.0.2-1~ubuntu.18.04~bionic` — замороженная версия, оба плагина на месте | 2026-09-03 |
| Raspberry Pi OS trixie | arm64 (Jetson) | `docker-ce 5:29.7.2-1~debian.13~trixie`, `Architectures: arm64`, репозиторий `linux/debian` — отображение Pi OS сработало | 2026-09-03 |

Проверялось не по коду возврата, а по содержимому образа: `virt-ls` нашёл
`docker`, `dockerd`, `containerd` в `/usr/bin` и оба плагина в
`/usr/libexec/docker/cli-plugins`, а `virt-cat` подтвердил, что
`/etc/apt/sources.list.d/docker.sources` указывает на
`download.docker.com/linux/debian` — то есть движок пришёл из репозитория
Docker, а не дистрибутивный `docker.io 26.1.5`.

## Проверки

- **V** — `make cream-validate`, `tools/check-names.sh`.
- **H** — `tests/test-docker.sh`: манифест и раскладка; `install` на Debian и
  Ubuntu, amd64 и arm64 (источник deb822, ключ, пять пакетов, запись своих),
  снятие конкурирующих, отказ без кандидата и на чужом `ID`, заморозка сюиты,
  Jetson (свой источник NVIDIA или вендорский, `nvidia-ctk`); `configure` —
  группа через заглушку `cloud-user`, двойной прогон `cmdline.txt` (одна
  правка, код 10, бэкап не перезаписан), перезапуск под NVIDIA один раз;
  `remove` — только своё, повтор без действий, сбой apt — код 1 с сохранённой
  записью, симуляция снимает чужой пакет — отказ без изменений.
- **L** — `make test-live EXT=docker` на `debian-12` и `ubuntu-24.04`
  (`tests/live.env`: `LIVE_DEPS="apt-guard cloud-user"`, `--accept-risk`, `LIVE_CAPS=NET_ADMIN`).
  **Ограничение среды:** контейнер без `--privileged`. `NET_ADMIN` — в
  собственном netns контейнера, как у `firewall`: без него `dockerd` не
  создаёт цепочку `nat DOCKER` и падает в цикле перезапусков. С ним демон
  стартует через drop-in проверки iptables raw (`API listen on /run/docker.sock`
  в журнале прогона). Запуск контейнеров (overlay-снапшоттер, `SYS_ADMIN`)
  L не проверяет — это проверка на ВМ или плате.
- Снятие `docker.io` живьём проверено разово (2026-10-19, `debian-12`): прогон
  `tools/live-test.sh --catalog` с временным расширением, ставившим `docker.io`
  раньше `docker`, — `docker.io`, `containerd` и `runc` сняты, установка и
  `remove` прошли.
