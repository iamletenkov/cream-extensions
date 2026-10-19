# nvidia-container-toolkit

NVIDIA Container Toolkit для Docker: репозиторий NVIDIA с ключом, пакеты
тулкита и регистрация среды выполнения `nvidia` в `/etc/docker/daemon.json`
**без смены `default-runtime`** — контейнеры по умолчанию остаются на `runc`,
GPU получают только те, кого об этом попросили (`--gpus`, `--runtime=nvidia`).

```
EXTENSION nvidia-container-toolkit                                 # образ bisquite
sudo cream install --accept-risk nvidia-container-toolkit          # живая машина (live: confirm)
sudo cream remove nvidia-container-toolkit
```

> **2.0.0 — cream/v1.** `install.sh` стал хуком `hooks/install`, появился хук `remove`;
> расширение ставится и при сборке, и на живую машину (`live: confirm`: на ней при
> изменении `daemon.json` работающий docker перезапускается). `daemon.json` по-прежнему
> **сливается** (`nvidia-ctk` дописывает `runtimes.nvidia`, остальные ключи остаются), а
> файл, где runtime уже есть, не переписывается вовсе — повтор ничего не меняет и docker
> не трогает. **Нет драйвера — больше не отказ:** запись `nvidia` со `status: skipped`
> (нет ядра или GPU) — тоже поставщик `gpu-driver-nvidia`, и без `libnvidia-ml.so.1`
> тулкит ставится с предупреждением. Ссылка вместо `/etc/docker` или `daemon.json` —
> отказ. Ключ `NVIDIA_CTK_VERSION` прежний (`config.keys`, `scope: install`).

## Что ставится

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
  дописывает в `daemon.json` блок `runtimes.nvidia`; остальные ключи файла
  сохраняются. `--set-as-default` не передаётся, и хук это проверяет: если
  `default-runtime` до и после вызова различается — код 1. Если runtime `nvidia`
  в файле уже есть, `nvidia-ctk` не зовётся вовсе.
- перед первой правкой файл копируется в
  `/var/lib/cream/ext/nvidia-container-toolkit/daemon-json.before` (или отмечается,
  что его не было, — `daemon-json.absent`), а sha256 результата — в `daemon-json.sha256`;
  поставленные пакеты — в `packages`.

При сборке демон не работает: правка ложится в файл, и `dockerd` прочтёт её
при первом старте на машине. На живой машине после правки —
`systemctl try-restart docker.service`: работающий docker перезапускается
(контейнеры без `live-restore` останавливаются и поднимаются по своей
restart-политике), остановленный остаётся остановленным.

**`hooks/remove`** возвращает `daemon.json` к состоянию до установки — копию или
отсутствие файла, — но только если файл с тех пор не правили (sha256 совпадает);
иначе оставляет его и говорит, что runtime `nvidia` убирать руками. Затем снимает
пакеты из записи (стоявшие до cream остаются), источник и ключ, обновляет списки apt;
при изменении `daemon.json` перезапускает работающий docker.

## Порядок слоёв — проверяется

Обе способности требует манифест (`requires`), cream проверяет поставщиков. Сам хук:

- отказывает без Docker (`/usr/bin/dockerd`; способность `container-runtime`,
  расширение `docker`);
- без драйвера (`libnvidia-ml.so.1`; способность `gpu-driver-nvidia`, расширение
  `nvidia`) — **предупреждает и продолжает**: запись `nvidia` бывает `skipped`
  (контейнер, ВМ без проброса GPU), а тулкиту и записи в `daemon.json` GPU не нужен.
  GPU в контейнерах появится, когда драйвер встанет.

## Настройки

| Переменная | Умолчание | Что |
|---|---|---|
| `NVIDIA_CTK_VERSION` | — (новейшая) | точная версия тулкита: `1.17.8` или `1.17.8-1`; нет такой в репозитории — ошибка со списком последних доступных |

`scope: install`: смена — повтор `cream install nvidia-container-toolkit
NVIDIA_CTK_VERSION=…`. Другой конфигурации у расширения нет — среда выполнения
описана в `/etc/docker/daemon.json`.

## Подключение

На живой машине (драйвер `nvidia` ставится раньше; без GPU — с `--allow-skip`):

```bash
sudo cream install --accept-risk docker
sudo cream install --accept-risk --allow-skip nvidia
sudo cream install --accept-risk nvidia-container-toolkit
```

В VMFILE:

```vmfile
EXTENSION docker
EXTENSION nvidia
EXTENSION nvidia-container-toolkit
EXTENSION nvidia-container-toolkit NVIDIA_CTK_VERSION=1.17.8
```

### Как сменить версию драйвера

Драйвер ставит расширение `nvidia`, и меняется он пересборкой образа
с другой `NVIDIA_DRIVER_VERSION` в его строке. Тулкит от ветки драйвера не
зависит: он берёт библиотеки того драйвера, что стоит на машине.

## Манифест

| Поле | Значение |
|---|---|
| `version` | `2.0.0`, `cream: ">=1.0.0"` |
| `targets` | `build: exec`, `live: confirm` (`live_note` — `daemon.json` и перезапуск docker) |
| `platform` | `deb`, `arch: [amd64]` — репозиторий публикует и arm64, но драйвер (`nvidia`) только amd64, а на Jetson тулкит ставит расширение `docker` из репозитория L4T; `os`: debian, ubuntu |
| `hooks` | `install` (20 мин), `remove` (10 мин); `configure` нет |
| `provides` | `nvidia-container-runtime` |
| `requires` | `container-runtime`, `gpu-driver-nvidia` |
| `config.keys` | `NVIDIA_CTK_VERSION` (`scope: install`, может быть пустым) |
| `depends`, `conflicts` | — |

## Проверка на машине

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

## Ограничения

- Secure Boot выключен — требование расширения `nvidia` (DKMS-модуль
  драйвера без регистрации MOK не загрузится), к тулкиту отдельных
  требований нет.
- Тулкит 1.18+ ставит `nvidia-cdi-refresh` — спецификация CDI
  (`/var/run/cdi/nvidia.yaml`) генерируется на машине, при сборке GPU нет.
  Для `docker run --gpus` она не нужна.
- Только Docker: containerd/CRI-O/podman расширение не настраивает.
