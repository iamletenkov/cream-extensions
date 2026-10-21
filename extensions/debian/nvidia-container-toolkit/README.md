# nvidia-container-toolkit

NVIDIA Container Toolkit для Docker: репозиторий NVIDIA с ключом, пакеты
тулкита и регистрация среды выполнения `nvidia` в `/etc/docker/daemon.json`
**без смены `default-runtime`** — контейнеры по умолчанию остаются на `runc`,
GPU получают только те, кого об этом попросили (`--gpus`, `--runtime=nvidia`).

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | amd64 |
| cream | ≥ 1.0.0 |
| Даёт | `nvidia-container-runtime` |
| Требует | `container-runtime`, `gpu-driver-nvidia` |
| Зависит от | [`apt-guard`](../apt-guard/README.md) |
| Конфликтует с | — |
| Хуки | `install`, `remove` |
| Настройка на загрузке | — |
| Живая машина | с `--accept-risk` |

> **Живая машина — с `--accept-risk`.** Подключает репозиторий NVIDIA, ставит тулкит и дописывает в /etc/docker/daemon.json среду выполнения nvidia (остальные ключи и default-runtime не трогаются); при изменении файла работающий docker перезапускается — его контейнеры останавливаются (без live-restore) и поднимаются по своей restart-политике; remove возвращает daemon.json, если его не правили после установки, и перезапускает docker снова
<!-- /catalog:facts -->

## Что делает

**`install`:**

- нет `curl`, `gpg`, `gpg-agent` или `ca-certificates` — ставятся (`gpg` без
  `gpg-agent` импортирует ключ, но выходит с кодом 2 — замер 2026-10-19 в `debian:12`,
  найдено живым прогоном);
- ключ `https://nvidia.github.io/libnvidia-container/gpgkey` в
  `/etc/apt/keyrings/nvidia-container-toolkit.asc` — принимается, только если
  в файле ровно один основной ключ с отпечатком
  `C95B321B61E88C1809C4F759DDCAE044F796ECB0`; в keyring кладётся экспорт
  этого ключа, а не скачанный файл (лишний ключ в нём доверия apt не получит);
- источник `/etc/apt/sources.list.d/nvidia-container-toolkit.sources`
  (deb822, `stable/deb/amd64`); если образ уже несёт запись на этот
  репозиторий, своя не добавляется — две записи с разным `Signed-By` apt
  не читает вовсе;
- пакеты `nvidia-container-toolkit`, `nvidia-container-toolkit-base`,
  `libnvidia-container-tools`, `libnvidia-container1` — новейшие или все
  четыре строго версии `NVIDIA_CTK_VERSION` (они выпускаются вместе, и пин
  одного верхнего дал бы apt собрать его с более новым `-base`);
- `nvidia-ctk runtime configure --runtime=docker --config=/etc/docker/daemon.json` —
  **сливает**: дописывает в `daemon.json` блок `runtimes.nvidia`, остальные ключи файла
  сохраняются. `--set-as-default` не передаётся, и хук это проверяет: если
  `default-runtime` до и после вызова различается — код 1. Если runtime `nvidia`
  в файле уже есть, `nvidia-ctk` не зовётся вовсе — повтор ничего не меняет и docker
  не трогает. Ссылка вместо `/etc/docker` или `daemon.json` — отказ.
- перед первой правкой файл копируется в
  `/var/lib/cream/ext/nvidia-container-toolkit/daemon-json.before` (или отмечается,
  что его не было, — `daemon-json.absent`), а sha256 результата — в `daemon-json.sha256`;
  поставленные пакеты — в `packages`.

При сборке демон не работает: правка ложится в файл, и `dockerd` прочтёт её
при первом старте на машине. На живой машине после правки —
`systemctl try-restart docker.service`: работающий docker перезапускается
(контейнеры без `live-restore` останавливаются и поднимаются по своей
restart-политике), остановленный остаётся остановленным.

**`remove`** возвращает `daemon.json` к состоянию до установки — копию или
отсутствие файла, — но только если файл с тех пор не правили (sha256 совпадает);
иначе оставляет его и говорит, что runtime `nvidia` убирать руками. Затем снимает
пакеты из записи (стоявшие до cream остаются), источник и ключ, обновляет списки apt;
при изменении `daemon.json` перезапускает работающий docker.

Своего `configure` нет. Обе способности (`container-runtime`, `gpu-driver-nvidia`)
требует манифест, cream проверяет поставщиков. Сам хук:

- отказывает без Docker (`/usr/bin/dockerd`; способность `container-runtime`,
  расширение [`docker`](../docker/README.md));
- без драйвера (`libnvidia-ml.so.1`; способность `gpu-driver-nvidia`, расширение
  [`nvidia`](../nvidia/README.md)) — **предупреждает и продолжает**: запись `nvidia`
  со `status: skipped` (нет ядра или GPU: контейнер, ВМ без проброса GPU) — тоже
  поставщик `gpu-driver-nvidia`, а тулкиту и записи в `daemon.json` GPU не нужен.
  GPU в контейнерах появится, когда драйвер встанет.

## Параметры

<!-- catalog:params -->
| Ключ | Тип | Умолчание | Что задаёт |
|---|---|---|---|
| `NVIDIA_CTK_VERSION` | строка `^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.~+]+)?$` | пусто | точная версия тулкита (1.17.8 или 1.17.8-1); пусто — новейшая в репозитории *(только при установке)* |
<!-- /catalog:params -->

`NVIDIA_CTK_VERSION`: нет такой версии в репозитории — ошибка со списком последних
доступных. `scope: install`: смена — повтор `cream install nvidia-container-toolkit
NVIDIA_CTK_VERSION=…`. Другой конфигурации у расширения нет — среда выполнения
описана в `/etc/docker/daemon.json`.

## Установка

На живой машине (`live: confirm`; драйвер `nvidia` ставится раньше; без GPU — с
`--allow-skip`):

```bash
sudo cream install --with-deps --accept-risk docker
sudo cream install --with-deps --accept-risk --allow-skip nvidia
sudo cream install --with-deps --accept-risk nvidia-container-toolkit
sudo cream remove nvidia-container-toolkit
```

В образе bisquite (VMFILE):

```dockerfile
RUN_COMMAND cream install --with-deps docker
RUN_COMMAND cream install --with-deps nvidia
RUN_COMMAND cream install --with-deps nvidia-container-toolkit
```

С закреплённой версией тулкита — последняя строка в виде:

```dockerfile
RUN_COMMAND cream install --with-deps nvidia-container-toolkit NVIDIA_CTK_VERSION=1.17.8
```

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | репозиторий, ключ, пакеты, `runtimes.nvidia` в `daemon.json`; на живой машине — `try-restart docker` при изменении |
| загрузка | своего configure нет; `dockerd` читает `daemon.json` |
| `cream remove` | `daemon.json` возвращён (если не правлен), пакеты, источник и ключ сняты; `try-restart docker` при изменении |

## Известные ограничения

- `platform.arch` — только amd64: репозиторий публикует и arm64, но драйвер
  (`nvidia`) только amd64, а на Jetson тулкит ставит расширение `docker` из
  репозитория L4T.
- Secure Boot выключен — требование расширения `nvidia` (DKMS-модуль
  драйвера без регистрации MOK не загрузится), к тулкиту отдельных
  требований нет.
- Тулкит 1.18+ ставит `nvidia-cdi-refresh` — спецификация CDI
  (`/var/run/cdi/nvidia.yaml`) генерируется на машине, при сборке GPU нет.
  Для `docker run --gpus` она не нужна.
- Только Docker: containerd/CRI-O/podman расширение не настраивает.
- На машине с GPU (P) не проверялось.

## Подробности

### Как сменить версию драйвера

Драйвер ставит расширение `nvidia`, и меняется он пересборкой образа
с другой `NVIDIA_DRIVER_VERSION` в его строке. Тулкит от ветки драйвера не
зависит: он берёт библиотеки того драйвера, что стоит на машине.

### Проверка на машине

```bash
nvidia-smi                                              # драйвер отвечает
docker info --format '{{.Runtimes}}'                     # среди сред — nvidia
docker info --format '{{.DefaultRuntime}}'               # runc
docker run --rm --runtime=nvidia --gpus all ubuntu:24.04 nvidia-smi
cat /etc/docker/daemon.json
```

## Проверки

- **V** — `make cream-validate`, `tools/check-names.sh`, `tools/lint-hooks.sh`.
- **H** — `tests/test-nvidia-container-toolkit.sh`: манифест; чистая машина (источник,
  ключ — экспорт прибитого, четыре пакета, `--config` корня, без `--set-as-default`,
  перезапуск docker только на живой машине); **слияние** поверх `daemon.json` с
  `log-driver`, `default-runtime: runc` и чужим runtime — все ключи на месте;
  **двойной прогон** — файлы и записи те же, `nvidia-ctk` и перезапуска нет; нет
  драйвера — предупреждение и 0; нет `dockerd`, кривая и отсутствующая версия,
  смена `default-runtime`, чужой отпечаток — 1; точная версия на все четыре пакета;
  ссылка вместо `daemon.json`, `/etc/docker` и записи пакетов — цель не тронута;
  `remove` — файл снят или возвращён, правленный после нас оставлен, сбой apt
  сохраняет запись.
- **L** — `make test-live EXT=nvidia-container-toolkit` на `debian-12` и `ubuntu-24.04`
  (`tests/live.env`: `LIVE_DEPS="cloud-user docker nvidia"`, `--accept-risk`,
  `LIVE_CAPS=NET_ADMIN`): `nvidia` в контейнере возвращает 20 и ставится с
  `--allow-skip` — запись `skipped` служит поставщиком `gpu-driver-nvidia`; тулкит
  установлен, runtime прописан, повтор и `--reinstall` ничего не меняют, `remove`
  снимает всё, `systemctl --failed` пуст.
- **P** — ВМ с GPU: `docker run --rm --gpus all … nvidia-smi` (раздел «Проверка на
  машине»). **Не выполнялась** при переводе на cream/v1 (машины с GPU нет).
