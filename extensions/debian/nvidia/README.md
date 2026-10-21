# nvidia

Драйвер NVIDIA **заданной ветки** (по умолчанию 580, открытые модули ядра):
пакеты драйвера, модуль ядра строго под ядра **машины** (`/lib/modules`, а не
`uname -r`), блокировка `nouveau`, initramfs и проверка результата в конце установки.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | amd64 |
| cream | ≥ 1.0.0 |
| Даёт | `gpu-driver-nvidia` |
| Требует | — |
| Зависит от | — |
| Конфликтует с | — |
| Хуки | `install` |
| Настройка на загрузке | — |
| Живая машина | с `--accept-risk` |

> **Живая машина — с `--accept-risk`.** Ставит драйвер NVIDIA и собирает модуль ядра (DKMS — компилятор и заголовки ядра) под каждое ядро в /lib/modules, блокирует nouveau и пересобирает initramfs всех ядер; до перезагрузки работает прежний драйвер (nouveau), после — NVIDIA: графический сеанс и консоль переключаются; Secure Boot должен быть выключен (README); снимать драйвер — руками (README, «Как снять»)
<!-- /catalog:facts -->

## Что делает

**`install`** ставит драйвер, собирает модуль под каждое ядро, пишет
`/etc/modprobe.d/blacklist-nouveau.conf` (комментарий — «cream nvidia»),
пересобирает initramfs и проверяет результат. Коды: **20** — ядер в `/lib/modules`
нет (контейнер; до apt), **10** — драйвер поставлен или изменился blacklist
`nouveau` (нужна перезагрузка), 0 — ничего не поменялось, 1 — сбой или проверка не
прошла. Файлы пишутся через временный файл и переименование — символическая ссылка
на месте файла заменяется, а не проходится. Нужной ветки нет — сборка падает с
объяснением, а не ставит «что нашлось».

| Система | Источник | Пакеты | Модуль ядра |
|---|---|---|---|
| Ubuntu 22.04, 24.04 | архив Ubuntu (`restricted`) — `NVIDIA_SOURCE=archive` | `nvidia-driver-<ветка>[-open]` | предсобранный подписанный Canonical `linux-modules-nvidia-<ветка>[-open]-<ядро>` + метапакет флейвора, если они есть под ядро образа и сходятся с драйвером по версии; иначе DKMS: `nvidia-dkms-<ветка>[-open]` + `linux-headers-<ядро>` |
| Ubuntu 22.04, 24.04 | PPA `graphics-drivers` — `NVIDIA_SOURCE=ppa` | то же | всегда DKMS |
| Debian 12, 13 | репозиторий CUDA NVIDIA (`developer.download.nvidia.com/compute/cuda/repos/debian12` / `debian13`) | `nvidia-driver-pinning-<ветка>`, затем `nvidia-open` (open) или `cuda-drivers` (proprietary) | DKMS: `nvidia-kernel-open-dkms` / `nvidia-kernel-dkms` + `linux-headers-<ядро>` |

Ключи репозиториев скачиваются и принимаются, **только если в файле ровно
один основной ключ с отпечатком**, прибитым в `hooks/install`; в keyring
кладётся экспорт этого ключа, а не скачанный файл; источники пишутся в формате deb822
с `Signed-By`. Нет `curl`, `gpg`, `gpg-agent` или `ca-certificates` — ставятся
(`gpg` без `gpg-agent` импортирует ключ, но выходит с кодом 2 — замер 2026-10-19
в `debian:12`). Если машина уже несёт запись на тот же репозиторий, своя не
добавляется (иначе apt отказывает на всём списке источников — урок
расширения `docker`).

Своего `configure` нет — на загрузке донастраивать нечего. Хука `remove` нет — см.
«Как снять».

## Параметры

<!-- catalog:params -->
| Ключ | Тип | Умолчание | Что задаёт |
|---|---|---|---|
| `NVIDIA_DRIVER_VERSION` | строка `^[0-9]{3,4}$` | `580` | ветка драйвера (580, 590, …), не полная версия; внутри ветки — новейшая из источника *(только при установке)* |
| `NVIDIA_KERNEL_MODULES` | `open` \| `proprietary` | `open` | open — открытые модули (Blackwell, RTX 50xx — только они); proprietary — для карт до Turing *(только при установке)* |
| `NVIDIA_SOURCE` | `archive` \| `ppa` | `archive` | Ubuntu: архив Ubuntu или PPA graphics-drivers (всегда DKMS); Debian: только archive — репозиторий CUDA NVIDIA *(только при установке)* |
<!-- /catalog:params -->

Все ключи — `scope: install`: параметры строки установки (`cream install nvidia
KEY=…`); смена ключа — повтор `install` (на живой машине — новая ветка поверх старой,
лучше пересборка образа).

- `NVIDIA_DRIVER_VERSION` — номер ветки (`580`, `590`, …); полная версия
  (`580.95.05`) не принимается — внутри ветки ставится новейшая из источника.
- `NVIDIA_KERNEL_MODULES` — **Blackwell (RTX 50xx, в т.ч. RTX 5060) и новее —
  только `open`**; `proprietary` нужен лишь для карт до Turing (Maxwell, Pascal,
  Volta), и с ним скрипт предупреждает.
- `NVIDIA_SOURCE` — Ubuntu: архив Ubuntu или PPA `graphics-drivers` (там ветки
  появляются раньше; модуль — всегда DKMS). Debian: только `archive` (= репозиторий
  CUDA NVIDIA), `ppa` — ошибка.

Нет ветки в источнике — ошибка с подсказкой: на Ubuntu с `archive` —
«`NVIDIA_SOURCE=ppa`», на Debian — список веток, которые есть.

## Установка

На живой машине (`live: confirm`; код 10 — перезагрузитесь):

```bash
sudo cream install --with-deps --accept-risk nvidia
sudo cream install --with-deps --accept-risk nvidia NVIDIA_DRIVER_VERSION=590
sudo reboot
```

Установка собирает модуль (на Debian и с PPA — DKMS: компилятор, заголовки,
десятки минут), блокирует `nouveau` и пересобирает initramfs всех ядер. До
перезагрузки работает прежний драйвер, после — NVIDIA. В контейнере или на машине
без ядер в `/lib/modules` хук возвращает 20 — с `--allow-skip` это запись
`skipped`, и она служит поставщиком `gpu-driver-nvidia` для
[`nvidia-container-toolkit`](../nvidia-container-toolkit/README.md).

В образе bisquite (VMFILE; основной путь) — одна из строк:

```dockerfile
RUN_COMMAND cream install --with-deps nvidia
RUN_COMMAND cream install --with-deps nvidia NVIDIA_DRIVER_VERSION=580 NVIDIA_KERNEL_MODULES=open NVIDIA_SOURCE=archive
RUN_COMMAND cream install --with-deps nvidia NVIDIA_DRIVER_VERSION=590          # Debian 13
```

Ставьте **после** слоёв, меняющих ядро (`UPDATE`, установка другого
`linux-image-*`): модуль собирается под ядро, которое лежит в образе
в момент запуска расширения. Обновление ядра после него оставит новое ядро
без модуля (на Ubuntu с предсобранными модулями метапакет флейвора потянет
их сам, с DKMS — соберёт DKMS-хук ядра, но проверки этого расширения
уже не будет).

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | источник и ключ, пакеты, модуль под каждое ядро, blacklist `nouveau`, initramfs, проверка; initrd ядра appliance удаляется — только при сборке |
| загрузка | своего configure нет |
| `cream remove` | хука нет — снимать руками (см. «Как снять») |

## Известные ограничения

- **Secure Boot должен быть выключен.** Предсобранные модули Canonical
  подписаны и загрузятся и с SB, но DKMS-модуль (Debian всегда, Ubuntu с
  `ppa` или с ядром, под которое предсобранного нет) подписан в лучшем случае
  ключом MOK, созданным при сборке образа; чтобы ядро ему поверило, ключ надо
  зарегистрировать (`mokutil --import`) на **каждой** машине с подтверждением
  в консоли при загрузке. Для тиража это не годится — решение владельца:
  SB выключен.
- `platform.arch` — только amd64: модули Canonical, PPA и каталог `x86_64`
  репозитория CUDA; arm64-серверы не проверялись, Jetson обслуживает
  [`nvidia-jetpack`](../nvidia-jetpack/README.md). Ubuntu 20.04 не поддерживается.
- Внутри ветки ставится новейшая версия источника на момент сборки — две
  сборки в разные дни могут дать разные 580.x.
- Нужен GPU на машине (или passthrough в ВМ); в ВМ без GPU модуль есть, но
  `nvidia-smi` ответит «No devices were found».
- Драйвер с зависимостями (а с DKMS — ещё компилятор и заголовки) заметно
  увеличивают образ: закладывайте место под сборку с запасом.
- **При сборке DKMS идёт в appliance libguestfs, а ему bisquite по умолчанию даёт
  2 ГБ** (`virt-customize --memsize 2048`). Ветке 590 под ядро Debian 13
  (6.12) этого мало — компилятор убивает OOM (замер 2026-10-14), хук
  тогда так и пишет. Собирайте с запасом: `bs image build --memsize 6144
  --smp 4 …` (`--smp` заодно ускоряет компиляцию). Debian 12 с 580 и Ubuntu
  с готовыми модулями Canonical укладываются в умолчание.
- На машине с GPU (P) не проверялось.

## Подробности

### Почему на Debian — репозиторий CUDA, а не non-free

Замер 2026-10-14:

| | non-free Debian | репозиторий CUDA NVIDIA |
|---|---|---|
| Debian 12 | 535 (`bookworm`), 535 (`bookworm-backports`) | 580 (open и proprietary), а также 570–615 |
| Debian 13 | 550 (`trixie`, `trixie-backports`) | **590 и новее** (590, 595, 610, 615); 580 нет |

Ветки 580 в non-free нет ни у одного выпуска, а репозиторий NVIDIA даёт её
для Debian 12 и закрепляет пакетом `nvidia-driver-pinning-580` — это способ
самой NVIDIA держать все пакеты драйвера на одной ветке, в том числе при
последующих `apt upgrade` на машине. **На Debian 13 ветки 580 нет**:
умолчание даёт громкую ошибку со списком доступных веток —
`NVIDIA_DRIVER_VERSION=590` (или новее) это решает. RTX 5060 (Blackwell)
поддерживается начиная с 570, так что 590 open для неё годится.

### Ядро машины, а не `uname -r`

Сборка идёт внутри appliance libguestfs: `uname -r` там — ядро appliance,
которого в образе нет. Поэтому:

- ядра образа берутся из `/lib/modules/<версия>` при наличии
  `/boot/vmlinuz-<версия>` (каталог без образа ядра — остаток удалённого
  ядра — пропускается); ядер может быть несколько, всё делается под каждое;
- заголовки — `linux-headers-<ядро образа>`, DKMS собирает явно
  `dkms autoinstall -k <ядро образа>`;
- initramfs — `update-initramfs -u -k <ядро образа>`; initrd, который
  триггер пакетов создал под ядро appliance (замер: 23 МБ в
  `/boot/initrd.img-<ядро appliance>`), удаляется, если такого ядра в образе
  нет, — **только при сборке** (`CREAM_PHASE=build`): на живой машине
  `uname -r` — работающее ядро, и его initrd не наш.

На живой машине правило то же: модуль собирается под **каждое** ядро из
`/lib/modules`, в том числе под то, в которое машина загрузится следующим.
Ядер нет вовсе (контейнер) — хук выходит с кодом 20 до любого apt.

### Проверка в конце установки

`hooks/install` завершается кодом 1, если для **какого-либо** ядра образа:

- `modinfo -k <ядро> nvidia` не находит модуль;
- версия модуля не равна версии пользовательской части
  (`libnvidia-ml.so.<версия>` — с ней сверяется `nvidia-smi`; расхождение на
  машине дало бы «Driver/library version mismatch»);
- версия не из запрошенной ветки;
- лицензия модуля не та: `Dual MIT/GPL` у open, `NVIDIA` у proprietary.

### Как сменить версию драйвера

Только пересборкой образа: поменяйте `NVIDIA_DRIVER_VERSION` в строке
`cream install` и соберите образ заново. Ставить другую ветку руками на
машине не нужно — тираж должен быть одинаковым, а на Debian ветку держит
`nvidia-driver-pinning-<ветка>`.

### Как снять

Хука `remove` нет (для `live: confirm` это допустимо): снять драйвер с
работающей машины — это пакеты драйвера с зависимостями, DKMS-модуль под каждое ядро,
закрепление ветки (Debian) и initramfs, а машина после этого остаётся на `nouveau` или
без графики. Делается руками и осознанно:

```bash
sudo apt-get purge 'nvidia-*' 'libnvidia-*' 'linux-modules-nvidia-*'   # Ubuntu
sudo apt-get purge 'nvidia-*' 'libnvidia-*' cuda-drivers               # Debian (репозиторий CUDA)
sudo rm -f /etc/modprobe.d/blacklist-nouveau.conf \
    /etc/apt/sources.list.d/nvidia-cuda.sources /etc/apt/keyrings/nvidia-cuda.asc \
    /etc/apt/sources.list.d/graphics-drivers-ppa.sources /etc/apt/keyrings/graphics-drivers-ppa.asc
sudo update-initramfs -u -k all && sudo reboot
sudo cream remove --forget nvidia                                     # снять запись реестра
```

### Проверка на машине

```bash
nvidia-smi                              # драйвер отвечает, видна карта и версия 580.x
cat /proc/driver/nvidia/version         # «Open Kernel Module» у open
modinfo -F license nvidia               # Dual MIT/GPL (open) или NVIDIA
lsmod | grep -E '^nvidia'               # модули загружены
lsmod | grep nouveau                    # должно быть ПУСТО
cat /etc/modprobe.d/blacklist-nouveau.conf
```

### Диагностика

```bash
dpkg -l | grep -E 'nvidia|linux-modules-nvidia'
dkms status                             # если модуль шёл через DKMS
modinfo -k "$(uname -r)" nvidia         # модуль под загруженное ядро
dmesg | grep -iE 'nvidia|nouveau|NVRM'
```

- **`nvidia-smi`: No devices were found / NVRM: GPU … not supported** —
  у карты нет поддержки в выбранном типе модулей: Blackwell с
  `proprietary` не работает, нужен `open`.
- **Driver/library version mismatch** — ядро обновили после сборки, а модуль
  остался от другой версии; пересоберите образ.
- **Модуль не грузится, в `dmesg` про подпись (Lockdown / Key was rejected)** —
  включён Secure Boot, см. «Известные ограничения».

## Проверки

- **V** — `make cream-validate`, `tools/check-names.sh`, `tools/lint-hooks.sh`.
- **H** — `tests/test-nvidia.sh`: манифест; нет ядер (и каталог ядра без `vmlinuz`) —
  20 до apt; неверные ключи и ядро со странным именем — 1 до apt; Ubuntu 24.04 —
  предсобранные модули Canonical, DKMS, нет заголовков, нет драйвера в архиве,
  PPA с прибитым ключом и с чужим отпечатком, Ubuntu 20.04 — отказ; Debian 12 —
  репозиторий CUDA (ключ — экспорт прибитого), чужой источник уже есть, Debian 13
  без ветки 580 — список веток; проверка результата (лицензия, версии модуля и
  библиотеки, нет модуля, нет `libnvidia-ml`); код 10 и повтор с 0; initrd ядра
  appliance удаляется только при сборке; blacklist-ссылка заменяется, цель не тронута.
- **L20** — `make test-live EXT=nvidia` на `debian-12` и `ubuntu-24.04`
  (`tests/live.env`: `--accept-risk`, `--expect-skip`): ядер в контейнере нет,
  хук возвращает 20, запись `skipped`, загрузка чистая.
- **P** — ВМ с GPU (passthrough) или машина с картой: сборка образа через bisquite
  и живая установка, `nvidia-smi` после перезагрузки (раздел «Проверка на машине»).
  **Не выполнялась** при переводе на cream/v1 (машины с GPU нет).
