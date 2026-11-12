# Расширения в образе bisquite

bisquite 3 собирает образ ВМ по VMFILE и ставит расширения тем же cream, что и на
живой машине, — внутри гостя (`virt-customize`). Отдельной директивы для
расширений нет: это обычные строки `RUN_COMMAND cream …`.

## Что bisquite делает сам

- Везёт cream и снимок этого каталога в своём пакете: сеть при сборке для
  каталога не нужна.
- Сразу после `FROM` ставит в гость cream пиновой версии и подключает снимок
  каталога источником `core`. Отключается `bs image build --no-cream` или директивой
  `CREAM off`.
- До сборки проверяет строки cream командой `cream check` — как hadolint для
  Dockerfile: имя и версия расширения, платформа, `depends`/`requires`/`conflicts`
  против базы и предыдущих строк, параметры по типам.

Подробно — [cream в образах bisquite](https://github.com/iamletenkov/cream/blob/main/docs/guides/bisquite-images.md)
и [фаза build](https://github.com/iamletenkov/cream/blob/main/docs/guides/build-phase.md)
в документации cream.

## Строки VMFILE

```dockerfile
FROM ubuntu2404:dst-base
RUN_COMMAND cream install --with-deps desktop DESKTOP_AUTOLOGIN=1
RUN_COMMAND cream install --with-deps gnome x11vnc X11VNC_PORT=5901
RUN_COMMAND cream install --with-deps --accept-risk firewall FIREWALL_SSH_PORTS=22
```

- **Одна строка — один шаг.** `--phase` не пишется: в госте cream сам узнаёт фазу
  `build`.
- **`--with-deps`** добирает `depends` расширения из того же источника (библиотеки
  `apt-guard`, `cloud-user`, `l4t`, домен `desktop`). Без него недостающая
  зависимость — отказ.
- **`имя@версия`** (`desktop@1.1.1`) — утверждение: в снимке другая версия — отказ. Версии
  расширений — в их `extension.yaml` и в
  [справочнике каталога](../reference/catalog.md) выпуска.
- **Параметры** — те же `KEY=VALUE`, что у `cream install` на машине; имена — из
  раздела «Параметры» README расширения. В образе они становятся настройками домена
  расширения (`/etc/cream/<имя>/config`), их можно поменять потом `cream set`.
- **Секреты** — только `--mount=type=secret` и `--params-file /run/secrets/<id>`,
  никогда литералом: VMFILE едет в образ. Секрет, переданный так, всё равно
  ложится в домен расширения в образе и достаётся всему тиражу; пароли доступа
  (`x11vnc`, `vino-vnc`, `code-server`, `selkies`) задают на машине.
- **Порядок строк** задаёт автор. Расширения, которые требуют способность
  (`x11vnc` требует `x11-server` и `display-manager`), ставятся после её
  поставщика (`gnome`, `xfce4`, `lxde`); `cream check` это проверяет.
- `--accept-risk` в образе не нужен: он про живую машину. Расширения «только
  образ» (`cloud-growroot`, `nocloud-cidata`, `l4t-kernel-kvm`) ставятся только так.

Директивы `EXTENSION` (bisquite 2.x) больше нет:
`EXTENSION src/name@v K=V` → `RUN_COMMAND cream install --source src name@v K=V`.

## Что происходит при сборке и на первой загрузке

| Когда | Что делает cream |
|---|---|
| сборка, строка `RUN_COMMAND cream install` | хук `install`: пакеты, файлы, `systemctl enable`; юнит `cream-configure@<имя>` только включается |
| конец сборки | `/etc/image-labels.d/cream.json` — состав образа (имя, версия, источник, способности), bisquite превращает его в метки OCI |
| первая загрузка машины | хук `configure` каждого расширения на его стадии (`early`, `system`, `cloud-user`, `graphical`) — то, что зависит от конкретной машины: пользователь cloud-init, ключи, железо |
| следующие загрузки | `configure` — только при изменениях (отметка выполнения), у `every_boot: true` — каждый раз |

Граница проведена по природе задачи: при сборке — всё, что одинаково на всём
тираже; на загрузке — только то, что делается на устройстве. `configure` в сеть не
ходит — [почему](configure-lifecycle.md#сборка-и-загрузка).

## Миграция на desktop 2.0.0 и cloud-user-desktop 6.0.0

**`desktop` 2.0.0: пустой `DESKTOP_AUTOLOGIN` — автологином не управляю.** В 1.x
умолчание было `0`, и `configure` на каждой загрузке писал `AutomaticLoginEnable=false`
(LightDM — снимал `autologin-user`), гася и автологин, который настроил вендор или
владелец. Теперь:

- строка с явным `DESKTOP_AUTOLOGIN=1` или `=0` значит то же, что раньше;
- строка без ключа (или `--with-deps` от `gnome`/`xfce4`/`lxde`) оставляет автологин
  таким, каким его оставил пакет или вендор. Нужен вход без пароля — `=1`, нужен
  экран входа — `=0`, явно;
- машина, обновлённая с 1.x, видимо не меняется: в файле остаётся последнее
  записанное значение, а маркер `legacy` хука `upgrade` заставляет пустой ключ и
  `cream remove desktop` выключить автологин, как в 1.x
  ([README `desktop`](../../extensions/debian/desktop/README.md)).

**`cloud-user-desktop` 6.0.0: автологин удалённой учётки снимает он сам.** Раньше
вендорский автологин на удалённую учётку (`jetson` у Q-engineering) гасило умолчание
`desktop` 1.x. Теперь `install` после удаления учётки снимает в gdm3 и LightDM
только записи, которые называют её; автологин другой учётки не трогает. Запись
`autologin.before` расширения `desktop`, сделанная до `cloud-user-desktop`, может
по-прежнему называть вендорскую учётку: пустой `DESKTOP_AUTOLOGIN` или
`cream remove desktop` вернут эту строку. Входа она не открывает — учётки нет, —
но чистый экран входа даёт явный `DESKTOP_AUTOLOGIN=0`.

**`cloud-user-desktop` 6.0.0 — `live: confirm`** (`userdel -r` необратим). В VMFILE
ничего не меняется: в образе фаза `build`, флаг не нужен. На живой машине:

```bash
sudo cream install --with-deps --accept-risk cloud-user-desktop CLOUD_USER_DESKTOP_REMOVE=jetson
sudo cream upgrade --all --accept-risk cloud-user-desktop   # иначе blocked:risk, код 68
sudo cream hold cloud-user-desktop                          # или закрепить: --all пропускает, код 0
```

Скрипт, который зовёт `cream upgrade --all` без вопроса (cron, агент), выбирает одно из
двух заранее; иначе код 68 будет у каждого запуска на машине с этим расширением.

**Сверка потребителей** (2026-11-12, bisquite и stvor-agent по `main`):

| Где | Что нашли | Нужно ли менять |
|---|---|---|
| bisquite, `examples/build/**/*.vmfile` с `desktop`: `amd64/debian12/{gnome,xfce4,lxde}`, `amd64/debian13/gnome`, `amd64/ubuntu2204/gnome`, `amd64/ubuntu2404/gnome`, `jetson/nano/jetson-nano-robot`, `jetson/orin/jetson-orin-robot`, `raspberry-pi/raspios/pi-workstation`, `raspberry-pi/ubuntu2404/pi-workstation-gnome`, `examples/dst/amd64/build/dst-desktop` | везде `cream install desktop DESKTOP_AUTOLOGIN=1` явно | нет |
| bisquite, `examples/build/jetson/nano/jetson-nano-robot.vmfile` | единственный `cloud-user-desktop CLOUD_USER_DESKTOP_REMOVE=jetson`; `desktop` с `DESKTOP_AUTOLOGIN=1` стоит раньше | нет: автологин уходит пользователю cloud-init, как раньше; вендорский `jetson` 6.0.0 снимает уже при сборке |
| bisquite, `examples/build/amd64/debian12/{chromium-kiosk,nuc-kiosk}.vmfile` | `chromium-kiosk` не зависит от `desktop` | нет |
| bisquite, `docs/guides/{extensions,vmfile}.md`, `examples/deploy/{deploy,nvidia_gnome}.yml` | `DESKTOP_AUTOLOGIN=1` явно (`cream install` и `cream set`) | нет |
| bisquite, код и скрипты | `cream upgrade --all` не зовёт; `RUN_COMMAND cream upgrade …` — строка автора VMFILE, фаза `build` | нет |
| stvor-agent, шаг применения назначения | `cream install --source stvor --allow-downgrade` только `teleport`/`stvor-agent` по имени; `cream upgrade --all` вне его рамок (спека assignment-apply) | нет |
| stvor-agent, `docs/guides/install-on-robot.md` | `cream upgrade stvor-agent` — одно имя | нет |

## Архитектура образа

libguestfs выполняет код гостя только при совпадении архитектур хоста и образа
(и `x86_64 → i386`); остальное — отказ, а не деградация. `RUN_COMMAND`
выполняет код внутри гостя, поэтому расширение для arm64-образа ставится на
arm64-хосте. Расширение, чей `platform.arch` не включает архитектуру образа,
`cream check` отвергает до сборки, называя причину.

## Проверить строки до сборки

```bash
bs image validate -f VMFILE     # cream check по бандлу bisquite
```

Каталог целиком тем же способом проверяет CI этого репозитория —
`tools/cream-check.sh` (`make cream-check`): каждое расширение строкой образа на
`debian:12`, `debian:13`, `ubuntu:22.04`, `ubuntu:24.04`.
