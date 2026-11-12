# existing-desktop

Объявляет готовый рабочий стол машины — поставленный установщиком ОС, а не cream
(Ubuntu Desktop с gdm3, Xubuntu с LightDM, Kubuntu с SDDM) — способностями
`x11-server`, `display-manager` и `desktop-session`. После него
[`selkies`](../selkies/README.md), [`x11vnc`](../x11vnc/README.md),
[`wallpaper`](../wallpaper/README.md) и остальные ставятся без
[`gnome`](../gnome/README.md)/[`xfce4`](../xfce4/README.md)/[`lxde`](../lxde/README.md),
которые пересобрали бы стол. Стол расширение только проверяет и в нём ничего не меняет.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | amd64, arm64 |
| cream | ≥ 1.2.0 |
| Даёт | `x11-server`, `display-manager`, `desktop-session` |
| Требует | — |
| Зависит от | — |
| Конфликтует с | способность `desktop-session` |
| Хуки | `install`, `remove` |
| Настройка на загрузке | — |
| Действия | `cream run existing-desktop check`, `cream run existing-desktop status` |
| Живая машина | да |
<!-- /catalog:facts -->

## Что делает

- **`install`** — проверяет **файлы**, одинаково при сборке образа и на живой машине:
  - Xorg: `/usr/lib/xorg/Xorg` или `/usr/bin/Xorg`;
  - менеджер входа: ссылка `display-manager.service`, которая разрешается внутри
    корня, или `/etc/X11/default-display-manager` с существующим бинарём;
  - X-сессия: хотя бы один `*.desktop` в `/usr/share/xsessions`; есть только
    Wayland-сессии (`/usr/share/wayland-sessions`) — отказ с отдельным текстом.

  Части нет — код **1**, она названа в журнале (cream отвечает 79 `hook.failed`), с
  подсказкой «сначала `cream remove existing-desktop`». Все три на месте — код 0. Кодов
  10 и 20 нет: ничего не меняется, а пропуск спрятал бы, чего не хватает.
  Единственное, что ставится, — пакет `x11-xserver-utils` (`xhost`), если его нет:
  без него [`lib/x-session.sh`](../../../lib/x-session.sh) не подтверждает дисплей,
  найденный без logind. apt ждёт блокировку dpkg до 2 минут на попытку (`DPkg::Lock::Timeout=120`, все повторы укладываются в таймаут 10m:
  на готовом Ubuntu Desktop её часто держат unattended-upgrades или packagekit) и
  повторяется трижды; таймаут хука — 10m, а не 2m спеки (рулинг П19 плана). На живой
  машине в конце журнала — диагноз, как у `status`.
- **действие `check`** — 0: Xorg и менеджер входа на месте; 1 — нет. Только файлы, ничего не
  вызывается; при сборке и на живой машине. Действие, а не хук: `hooks.check` cream 1.4.0
  отвергает как зарезервированный (рулинг П18 плана).
- **`remove`** — ничего: стол принадлежит машине. `x11-xserver-utils` остаётся.
- **действие `status`** — только чтение, код 0:
  - менеджер входа и `systemctl is-active display-manager.service`;
  - gdm3: `WaylandEnable` в `/etc/gdm3/daemon.conf` и `/etc/gdm3/custom.conf` — не
    задан, закомментирован, `true` или `false` — и подсказка про
    [`gdm-xorg`](../gdm-xorg/README.md), если сеансы GNOME идут на Wayland;
  - автологин: gdm3 (`AutomaticLoginEnable` и `AutomaticLogin` в `[daemon]`), LightDM
    (`autologin-user` в `[Seat:*]` из `lightdm.conf.d` и `lightdm.conf`), SDDM
    (`[Autologin] User` из `sddm.conf.d` и `/etc/sddm.conf`);
  - сеанс seat0 через logind: пользователь, тип, дисплей, состояние; экран входа;
    «активного сеанса нет»; без logind — «нет logind».

Всё прочитанное с машины (имена юнитов, сессий, пользователей) попадает в журнал
только печатными символами.

## Параметры

<!-- catalog:params -->
Параметров нет.
<!-- /catalog:params -->

Ключей нет.

## Установка

На машине с подключённым каталогом ([как подключить](../../../docs/getting-started.md)):

```bash
sudo cream install --with-deps existing-desktop
sudo cream run existing-desktop status
sudo cream install --with-deps selkies        # или x11vnc, wallpaper
```

Сеансы GNOME на Wayland (Ubuntu 24.04 по умолчанию) `selkies` и `x11vnc` не
захватывают; переключить gdm3 на Xorg с согласия владельца —
[`gdm-xorg`](../gdm-xorg/README.md).

Машина, где стол уже поставлен через обход `gnome`, переходит так (спека
[2026-11-12-existing-desktop](../../../docs/specs/2026-11-12-existing-desktop.md), §5):

```bash
sudo cream remove --force gnome && sudo cream install existing-desktop
```

В образе bisquite (VMFILE) — когда стол уже в базовом образе:

```dockerfile
RUN_COMMAND cream install --with-deps existing-desktop
```

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | проверка файлов; `x11-xserver-utils`, если нет `xhost`; на живой машине — диагноз |
| загрузка | ничего: хука `configure` нет |
| `cream run existing-desktop check` | Xorg и менеджер входа на месте — 0 |
| `cream remove` | ничего |
| `cream run existing-desktop status` | диагноз: менеджер входа, Wayland, автологин, сеанс seat0 |

## Известные ограничения

- Не выключает Wayland и не трогает автологин — это [`gdm-xorg`](../gdm-xorg/README.md)
  и [`desktop`](../desktop/README.md), по согласию.
- Не ставится вместе с `gnome`, `xfce4`, `lxde`, `l4t-vendor-desktop`: у машины один
  стол (конфликт по `desktop-session`).
- Неудачная установка оставляет запись в графе cream, и она держит конфликт
  `desktop-session` и даёт способности потребителям (issue в cream, §9 спеки):
  сначала `cream remove existing-desktop`. Поэтому `selkies` и `x11vnc` проверяют
  машину сами.
- Что менеджер входа реально поднимет X без монитора, по файлам не проверить: на
  физической машине без монитора — не замерено.

## Проверки

- **V** — `make cream-validate`, `tools/lint-hooks.sh`, `make check-names`.
- **H** — `tests/test-existing-desktop.sh`: фикстуры gdm3 Ubuntu (`custom.conf`: нет
  ключа, закомментирован, `false`, `true`), gdm3 Debian (`daemon.conf`), LightDM, SDDM,
  нет DM, только Wayland-сессии, L4T R32; при сборке — ни одного вызова `loginctl` и
  `systemctl`; `status` на подставном `loginctl`; дерево корня до и после — то же.
- **L** — `make test-live EXT=existing-desktop` (`tests/live.env`: Xorg и LightDM до
  cream, X-сессия preseed'ом, `/etc/lightdm` и `/etc/X11` после `remove` — те же;
  debian-12 и ubuntu-24.04). Варианты (ночь, ubuntu-24.04):
  `ARGS='--variant gdm3'`, `--variant sddm`, `--variant from-gnome` (переход с обхода
  `gnome`).
