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
