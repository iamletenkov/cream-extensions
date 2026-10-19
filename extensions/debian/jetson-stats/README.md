# jetson-stats

Ставит `jtop` — монитор NVIDIA Jetson: загрузка CPU и GPU, память, частоты,
питание, температуры, вентилятор, режим `nvpmodel`.

> **3.0.0 — cream/v1.** Хуки `install`, `configure` (стадия `cloud-user` — после
> `cloud-final`; нужен cream ≥ 1.1.1, рулинг Р14 плана) и `remove`; своего
> `configure-jetson-stats.service` нет. pip — с `constraints.txt` (закреплённые
> версии), без `--user`, с `HOME` во временном каталоге и без конфигурации pip:
> в доме root ничего не остаётся. Не Jetson — код 20 («неприменимо»).

## Зачем

На Jetson нет ни `nvidia-smi`, ни `nvtop`, которые работали бы: и то и другое
опирается на NVML, а NVML на Tegra до JetPack 7 не существует (разбор ниже).
Единственный монитор, читающий Tegra её собственными средствами —
`tegrastats` и sysfs, — это `jtop` из пакета `jetson-stats`.

Замер на живой плате, 2026-09-03:

```
Ubuntu 20.04.6 LTS aarch64, ядро 4.9.253-tegra
L4T R32.6.1 (JetPack 4.6.1), плата t210ref, tegra210
jtop:       /usr/local/bin/jtop   (ставится pip-пакетом jetson-stats)
tegrastats: /usr/bin/tegrastats   (из L4T)
nvtop:      нет, и в apt-репозиториях этой машины его нет вовсе
```

## Манифест

| Поле | Значение |
|---|---|
| `platform.arch` | `arm64` |
| `targets` | `build: exec`, `live: yes` |
| `provides` | `jetson-monitor` |
| `depends` | `cloud-user` (библиотека: пользователь cloud-init) |
| хуки | `install`, `configure` (`cloud-user`), `remove` |

Только arm64: Jetson — это aarch64-модуль на Tegra, а с PyPI приезжает колесо
`py3-none-any`, которое на amd64 встало бы мёртвым грузом. Случай «arm64, но
не Jetson» ловит `install` по `/etc/nv_tegra_release` (код 20).

## Подключение

```vmfile
EXTENSION jetson-stats
```

На живой плате — `cream install jetson-stats`.

## Параметры

| Ключ | Умолчание | Что делает |
|---|---|---|
| `JETSON_STATS_VERSION` (`scope: install`) | пусто — версия из `constraints.txt` (7.2.1; на Python 3.6, L4T R32 — 4.3.2) | своя версия `X.Y[.Z]`; закреплённая строка `jetson-stats` из `constraints.txt` при этом не действует, зависимости — по-прежнему по нему |

```vmfile
EXTENSION jetson-stats JETSON_STATS_VERSION=7.2.1
```

## Что делает

- **`install`** — нет `/etc/nv_tegra_release` — код 20; ставит
  `python3-pip`, `python3-setuptools` (только недостающие), затем
  `python3 -m pip install --constraint constraints.txt jetson-stats` от root в
  системный префикс: `HOME` — временный каталог, `PIP_CONFIG_FILE=/dev/null`,
  `PIP_USER=0`, `PYTHONNOUSERSITE=1`, кеша нет; на PEP 668 — `--break-system-packages`.
  Что поставил pip, записывается в `/var/lib/cream/ext/jetson-stats/pip`. Затем
  `jtop.service` (см. «Откуда берётся») и группа `jtop`; служба включена.
- **`configure`** (стадия `cloud-user`, на каждой загрузке) — вносит пользователя
  cloud-init в группу `jtop` (на загрузке ждёт его до 30 с) и, если демон не
  работает, запускает его (`--no-block`). Нет пользователя или не Jetson —
  предупреждение и 0.
- **`remove`** — служба выключена, наш юнит снят, поставленное pip и apt снято
  (pip — в том же окружении, что при установке); группа `jtop` остаётся.

### Почему pip, а не apt

Пакета `jetson-stats` в репозиториях Ubuntu нет: проект живёт на PyPI, и
его README документирует ровно один способ — `sudo pip3 install -U
jetson-stats`, а перед ним `apt install python3-pip python3-setuptools`.
Расширение повторяет обе строки.

На Ubuntu 24.04 и новее pip отказывается ставить в системный интерпретатор
без `--break-system-packages` (PEP 668); upstream документирует это
отдельным пунктом. Расширение смотрит на сам маркер
(`/usr/lib/python3*/EXTERNALLY-MANAGED`), а не на версию дистрибутива —
маркер и есть то, на что смотрит pip.

### Почему службу приходится ставить руками

`jtop` — клиент; данные ему отдаёт демон через сокет `/run/jtop.sock`.
Без `jtop.service` команда отвечает «The jtop.service is not active»
(`jtop/jtop.py:1116`).

Раньше службу ставил сам pip: `setup.py` объявляет команду `build_py`,
которая копирует `services/jtop.service` в `/etc/systemd/system`, зовёт
`systemctl enable` и заводит группу `jtop`.

**Замер по артефактам PyPI (2026-09-03):**

| Версия | Что опубликовано | Ставит ли pip службу |
|---|---|---|
| … 4.3.2 (19.03.2025) | только sdist | да — pip собирает колесо сам, `build_py` выполняется |
| 7.2.0 (14.07.2026) | sdist **и** `py3-none-any.whl` | **нет** — pip берёт готовое колесо |
| 7.2.1 (09.08.2026) | sdist **и** `py3-none-any.whl` | **нет** |

Из готового колеса `build_py` не выполняется никогда. Поэтому
`pip3 install -U jetson-stats` сегодня оставляет систему с установленным
клиентом и без демона.

Расширение проверяет **факт** (есть ли файл юнита), а не версию, и добивается
его четырьмя заходами подряд:

1. после `pip install` — вдруг уже есть (ветка sdist);
2. `jtop --install-service` — штатная команда проекта
   (`jtop/__main__.py:174`): ставит `/etc/profile.d/jtop_env.sh`, заводит
   группу `jtop` и копирует юнит, находя шаблон в data-файлах колеса
   (`/usr/local/share/jetson_stats/jtop.service`);
3. копирование того же шаблона руками —
   `/usr/local/share/jetson_stats/jtop.service` или
   `/usr/share/jetson_stats/jtop.service`;
4. юнит пишется самим расширением по эталону с живой платы — разбор
   в разделе «Откуда берётся `jtop.service`».

Не помог ни один — **отказ сборки**. «Поставилось, но не работает»
обнаружилось бы на плате, после записи карты.

## Почему НЕ nvtop

Коротко: `nvtop` не умеет Tegra ни в одной версии, а не «умеет начиная
с 3.x». Проверено по исходникам и по архиву Ubuntu 2026-09-03.

**1. Бэкенда Tegra в nvtop нет вовсе.** В дереве тега 3.3.2 (последний релиз,
опубликован 08.02.2026) слов `tegra`, `jetson` и `nvgpu` нет ни одного —
ни в коде, ни в README, ни в CMake. Бэкенды перечислены каталогом `src/`:
amdgpu, radeon, intel (i915 и xe), msm, panfrost, panthor, v3d, apple,
ascend, ixml, metax, enflame, tenstorrent, tpu, rockchip. Tegra среди них
нет.

**2. NVIDIA у nvtop — это NVML и только он.** Бэкенд грузит библиотеку
драйвера: `dlopen("libnvidia-ml.so")`, при неудаче `"libnvidia-ml.so.1"`
(`src/extract_gpuinfo_nvidia.c:275,277`). README проекта в разделе
зависимостей говорит то же: «For NVIDIA: the *NVIDIA Management Library*
(*NVML*) which comes with the GPU driver», а в разделе про неполадки —
что без этой библиотеки будет `NO GPU to monitor`.

**3. NVML на Tegra до JetPack 7 нет.** Это видно из кода самого
jetson-stats: к NVML он тянется **только** на JetPack 7 / L4T R38 и новее
(`jtop/core/gpu.py`, ветка `is_jetpack7()`; порог объявлен в
`jtop/core/hw_detect.py`: `JETPACK7_L4T_MAJOR = 38`). На всём, что старше —
а Nano это R32, JetPack 4.6.1, и новее для него не выйдет, — данные берутся
из `tegrastats` и sysfs. То есть upstream-монитор Jetson сам считает NVML
доступным только с JetPack 7.

Проверяется на плате одной командой:

```console
$ ldconfig -p | grep libnvidia-ml   # на Nano пусто
```

**4. В focal лежит nvtop 1.0.0, и он в multiverse.** Замер по Launchpad
(`getPublishedSources`, 2026-09-03):

| Выпуск Ubuntu | Версия nvtop | Компонент |
|---|---|---|
| focal (20.04) | 1.0.0-1ubuntu2 | multiverse |
| jammy (22.04) | 1.2.2-1 | multiverse |
| noble (24.04) | 3.0.2-1 | multiverse |

То есть даже с включённым `multiverse` на 20.04 приезжает сборка 2020 года —
и она тоже NVML-only. На замеренной плате `multiverse` не включён, поэтому
`apt` не находит `nvtop` вовсе.

**Что из исходного утверждения не подтвердилось:** «поддержка Tegra
появилась только в nvtop 3.x». Её нет и в 3.3.2. Остальное подтвердилось:
1.x в focal — да (с уточнением про multiverse), опора на NVML — да,
3.3.2 — последний релиз — да.

## Откуда берётся `jtop.service`

Пакет его **не поставляет**. С 7.2.0 на PyPI лежит готовое колесо
`py3-none-any`, а хук `build_py`, который раньше ставил юнит, из колеса
не выполняется; data-файлов `services/` и `share/jetson_stats/` в колесе
тоже нет.

Расширение добивается юнита четырьмя заходами подряд, останавливаясь
на первом сработавшем:

| | способ | когда срабатывает |
|---|---|---|
| 1 | хук pip | установка из sdist, до 4.3.2 включительно |
| 2 | `jtop --install-service` | если команда есть и отрабатывает |
| 3 | копия шаблона из data-файлов пакета | если они поставлены |
| 4 | **пишем сами** | нынешние версии — единственный рабочий |

Содержимое четвёртого не выдумано: снято с **живого Jetson Nano**
(2026-09-03), где jtop 7.2.1 работает, а юнит в `/etc/systemd/system`
написан руками — ровно потому, что пакет его не несёт. Путь к `jtop`
резолвится через `command -v`, а не прибивается: `sudo pip3` кладёт его
в `/usr/local/bin`, а pip в venv — в другое место.

## Отказы

**Нет `/etc/nv_tegra_release`** — образ не L4T, код 20 («неприменимо»): `jtop`
там не заработает никогда. Это тот же файл, по которому опознаёт плату сам
jetson-stats (`jtop/core/jetson_variables.py:240`).

**Не удалось поставить пакет с PyPI** — три попытки с нарастающей паузой,
потом отказ. **`JETSON_STATS_VERSION` не по форме** — отказ до сети.

**Не появился `jtop.service`** — четвёртый заход невозможен, если `jtop` не
нашёлся в `PATH` после установки: писать юнит не на что.

`configure` не отказывает: без пользователя или без Tegra — предупреждение и 0
(рулинг Р11); незапустившийся демон виден в `systemctl --failed` как
`jtop.service`.

## Ограничения

**`arch: [arm64]`** — собирать надо на **arm64-хосте**: хук выполняется внутри
гостя, а libguestfs не выполняет код гостя чужой архитектуры. В госте нужна
сеть: пакет качается с PyPI в момент сборки.

**Членство в группе применяется при входе.** Если автологин уже случился,
текущая сессия группу не видит, и `jtop` в ней отвечает отказом доступа —
помогает новый вход или перезагрузка.

## Почему configure не упорядочен относительно jtop.service

`jtop.service` (вендорский юнит) объявлен `After=multi-user.target`, а прежний
`configure-jetson-stats.service` стоял `WantedBy=multi-user.target` с
`After=jtop.service`: кольцо, которое systemd разрывает, **молча** выбрасывая
задачу (замер 2026-09-04, Jetson Nano). Второе кольцо — `After=cloud-final`
при `WantedBy=multi-user.target` (замер 2026-09-06). Стадия `cloud-user` cream
привязывает configure к `cloud-init.target` (или к `multi-user.target` без
cloud-init) с `After=cloud-final.service`, а относительно `jtop.service` не
упорядочивает его вовсе: хуку нужны пакет и группа, а не запущенный демон.

## Что править и чем перезапускать

| Что менять | Где | Чем применить |
|---|---|---|
| версию пакета | `cream install jetson-stats JETSON_STATS_VERSION=X.Y.Z` | хук `install` перезапускается сам |
| донастройка (группа, запуск демона) | — | `systemctl restart cream-configure@jetson-stats` |
| сам демон | `/etc/systemd/system/jtop.service` | `systemctl restart jtop.service` |

## Проверка

На собранном образе:

```console
$ virt-ls -a образ.qcow2 /etc/systemd/system | grep jtop
$ virt-cat -a образ.qcow2 /etc/systemd/system/jtop.service
$ virt-ls -a образ.qcow2 /usr/local/bin | grep jtop
```

На плате после первой загрузки:

```console
$ systemctl is-active jtop.service
$ id -nG | tr ' ' '\n' | grep -x jtop     # пользователь в группе
$ jtop                                     # без sudo
$ jetson_release                           # сводка по плате
```

## Проверено на

| Что | Как | Дата |
|---|---|---|
| артефакты PyPI 4.3.2 / 7.2.0 / 7.2.1 — sdist против колеса | `pypi.org/pypi/jetson-stats/json`, распакованное колесо | 2026-09-03 |
| путь шаблона юнита в колесе (`share/jetson_stats/jtop.service`) | список файлов `jetson_stats-7.2.1-py3-none-any.whl` | 2026-09-03 |
| права сокета и текст отказа клиента | исходники 7.2.1 (`jtop/service.py`, `jtop/jtop.py`) | 2026-09-03 |
| отсутствие Tegra в nvtop | дерево тега 3.3.2 целиком | 2026-09-03 |
| версии nvtop в Ubuntu | Launchpad `getPublishedSources` | 2026-09-03 |
| Jetson Nano, L4T R32.6.1 | сборка образа целиком | **не проверялось** |

Последняя строка честная: хуки прогнаны на подменённом корне
(`tests/test-jetson-stats.sh`: подменённые `pip`, `jtop`, `systemctl`,
`usermod`), но живой платы в проверке не было — P (AGX Orin) ожидает.
