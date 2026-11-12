# Plan: удалённый стол на готовом столе и DM не из cream

> **Для агентов-исполнителей:** выполнять по задаче за раз через
> superpowers:subagent-driven-development (или executing-plans).
> Закрыл задачу — отметь `- [x]` в Progress Tracker в том же коммите.

**Цель:** `selkies`, `x11vnc`, `vino-vnc`, `wallpaper` (и `kiosk` на Debian) ставятся на машину с готовым
столом и DM без перестановки стола; `desktop` и `gnome` больше не ломают чужую настройку входа.
**Спека:** [docs/specs/2026-11-12-existing-desktop.md](../specs/2026-11-12-existing-desktop.md) (рулинги skeptic — §10).
**Ветка:** `feature/existing-desktop` (интеграционная); у каждой задачи — своя ветка `feature/existing-desktop-tN`
в своём worktree от головы интеграционной.
Классификация — **архитектурная** (новое расширение, две общие библиотеки, четыре мажора).

## Progress Tracker
- [x] Task 1: `lib/x-session.sh` — поиск X-сеанса пользователя на seat0 (H)
- [x] Task 2: `lib/gdm-wayland.sh` — чтение, запись и точный возврат `WaylandEnable` (H)
- [x] Task 3: диапазон `desktop <3` у `gnome`, `xfce4`, `lxde`, `cloud-user-desktop`; ночной ubuntu-24.04 у `xfce4`, `lxde`, `wallpaper`
- [x] Task 4: L-раннер — `LIVE_PREINSTALL`, `LIVE_PRESEED`, `LIVE_EXPECT_RESTORED`, принудительное снятие, варианты `live.<v>.env`
- [x] Task 5: L-матрица — варианты и `LIVE_NIGHTLY_DISTROS`
- [ ] Task 6: `existing-desktop` 1.0.0
- [ ] Task 7: `desktop` 2.0.0 — автологин только по ключу, снимок и возврат, хук `upgrade`, отказ на SDDM
- [x] Task 8: `gdm-xorg` 1.0.0
- [ ] Task 9: `gnome` 5.1.0 — `WaylandEnable` через `lib/gdm-wayland.sh`, код 10, возврат при снятии
- [ ] Task 10: `selkies` 7.0.0 — `SELKIES_USER`, `SELKIES_DISPLAY=auto`, проверка машины, uid-правило
- [ ] Task 11: `x11vnc` 6.0.0 — `X11VNC_USER`, `X11VNC_DISPLAY=auto`, проверка машины, uid-правило
- [ ] Task 12: `cloud-user-desktop` 6.0.0 — `live: confirm`, снятие автологина удалённой учётки
- [x] Task 13: `code-server` 5.3.0 — снятие пакета только своего, через apt-guard
- [x] Task 14: `docker` 4.2.0 — снятие только своего источника apt
- [ ] Task 15: `firefox` 2.1.0 — снятие только своего источника apt
- [x] Task 16: issue в cream: неудачная запись даёт способности (§9)
- [ ] Task 17: сверка потребителей — VMFILE и скрипты обновления bisquite, stvor-agent
- [ ] Task 18: документация каталога — способности, раскладка, известные ограничения
- [ ] Task 19: ночная build-сборка графического стека (ждёт ответа владельца, §11 спеки)
- [ ] Task 20: ручная приёмка P1–P7 на ВМ, runbook 05
- [ ] Task 21: Финальная интеграция + `make ci`

## Acceptance criteria
- На Ubuntu 24.04 с готовым gdm3, lightdm или sddm `cream install existing-desktop` → 0, и после него
  `cream install selkies|x11vnc|wallpaper` разрешается без `gnome`/`xfce4`/`lxde`; ни один шаг не меняет файлы DM.
- `desktop` 2.0.0 с пустым `DESKTOP_AUTOLOGIN` не пишет ключи автологина; снимок — только при `CREAM_REASON=install`;
  после обновления с 1.x (маркер `legacy`) `remove` и пустой ключ выключают автологин (H-тест Р1).
- `selkies`/`x11vnc` с `*_USER` = `gdm`, root, uid < 1000 или ≥ 65534 — 78 в обёртке, экземпляр не запускается (Р3).
- `selkies`/`x11vnc` `install` в live без Xorg или без включённого DM — 20 (cream 68); `configure` — 1 (Р2).
- `cream remove gdm-xorg` возвращает `custom.conf`/`daemon.conf` побайтно (H и L `LIVE_EXPECT_RESTORED`).
- `make ci` зелёный; L изменённых расширений зелёный на debian-12 и ubuntu-24.04; ночной L графического стека на
  ubuntu-24.04 зелёный два прогона подряд; P1–P5 и P7 записаны в runbook 05, P6 — замер или «не замерено».
- Issue в cream по §9 заведено, ссылка — в §9 спеки.

## Скоуп
- В скоупе: §4 спеки целиком (4.1–4.8), миграция §5, тесты и приёмка §6, issue §9.
- Вне скоупа: не-цели §2 (виртуальный стол, захват Wayland, автологин SDDM, обои Plasma, `kiosk` на Ubuntu, правка
  кода cream, арм-приёмка на железе); изменение `l4t-vendor-desktop`.

## Архитектурное соответствие
- Общие библиотеки — механизм `lib/<lib>.sh` + `lib/<lib>.consumers` ([раскладка](../reference/layout.md),
  `tools/check-shared-libs.sh`), правило `source`: потребитель подключает `${CREAM_EXT_DIR}/files/<lib>.sh` хуком,
  копия в `extensions/` запрещена. Образец — `lib/fetch.sh` и его потребители.
- Новое расширение — по [runbook 02](../runbooks/02_new-extension.md) (`tools/new-extension.sh`, H-тест первым);
  образец проверки «без установки» — `l4t-vendor-desktop`.
- Коды хуков: 10 — перезагрузка, 20 — только `install`, `configure` без DM — предупреждение и 0 (рулинг Р11 плана
  2026-10-19); исключение по спеке — Р2 (`configure` у `selkies`/`x11vnc` без Xorg/DM → 1).
- Правило версий — [выпуск](../guides/release.md#версия-расширения), `tools/check-version-bump.sh`.
- Тесты — V/H/L/P по [руководству](../guides/testing.md); H — `tools/hooktest.sh`.
- Параллельный PR `fix/selkies-effective-env` (selkies 6.2.2: действующие значения в
  `/var/lib/cream/ext/selkies/env`, 78 на Wayland, без пароля — только петля; x11vnc 5.1.2: 78 на Wayland) — база
  Task 10, 11. Мажоры `selkies` 7.0.0 и `x11vnc` 6.0.0 отсчитываются от него.

## Рулинги плана (контроллер, в рамках спеки)
| № | Решение | Почему |
|---|---|---|
| П1 | Предусловие старта: PR `fix/selkies-effective-env` слит в `main`; `feature/existing-desktop` — от `main` с влитой `docs/existing-desktop-spec` | Task 10, 11 строятся поверх 6.2.2 / 5.1.2 |
| П2 | В ветке у расширения одна версия выше последнего тега. Задача, которая находит версию уже поднятой в ветке (Task 3 → 9, 12), поднимает её до номера из спеки и **сливает** комментарий под `version:` в один; промежуточный номер в выпуск не попадает | `check-version-bump` сравнивает только с тегом; лишние строки истории не нужны |
| П3 | Сгенерированные блоки `README.md` (корень) и `docs/reference/catalog.md` владельца не имеют: каждая задача, меняющая манифест, гоняет `make docs` в своём worktree; конфликт слияния в них — повторный `make docs`, не ручная правка. Блоки README расширения — у задачи расширения | `tools/catalog-docs.sh --check` в `make test`; иначе задачи не могли бы быть параллельными |
| П4 | `lib/<lib>.consumers` создаёт первый потребитель (Task 6 — `x-session`, Task 8 — `gdm-wayland`) и дописывает каждый следующий (Task 10 → 11; Task 9). Task 1, 2 кладут библиотеку **без** `.consumers` | `check-shared-libs` отказывает, если потребитель из списка ещё не берёт `files/<lib>.sh` |
| П5 | Коммиты задач — `feat(<ext>): …` / `test(tools): …` **без** `!` и `BREAKING CHANGE:`; мажоры несут версии расширений. Итоговый PR в `main` — squash с заголовком `feat(existing-desktop): …`, в теле нет `BREAKING CHANGE:` | спека §4.8: каталог — минор |
| П6 | `desktop` 2.0.0 снимает `autologin.before` при `CREAM_REASON=install` **всегда**, даже при пустом ключе: позже `cream set DESKTOP_AUTOLOGIN=1` (reason `apply`) снимка не делает, а возвращать надо состояние до cream | иначе S2 «включает → при снятии возвращает» не работает для включения через `set` |
| П7 | Хук `desktop/hooks/upgrade` делает работу `install` при **любом** обновлении (cream зовёт его вместо `install`), а маркер `legacy` пишет только при `CREAM_PREV_VERSION` < 2.0.0 и отсутствии записи | хук остаётся и для 2.x → 2.y |
| П8 | Обёртка `selkies` снимает `SELKIES_USER` из окружения (`unset`) до `exec` Selkies: 6.2.2 кладёт все действующие ключи в `EnvironmentFile`, и шаблон `SELKIES_*` иначе отдал бы его Selkies. H проверяет окружение подставного `selkies` | спека §4.4 «обёртка не передаёт его Selkies» |
| П9 | Варианты L — файлы `tests/live.<вариант>.env` поверх `tests/live.env`; три DM у `existing-desktop`, gdm3 у `desktop`, переход с `gnome` — вариантами, а не отдельными скриптами | один L-раннер, данные вместо кода |
| П10 | `vino-vnc` в ночной ubuntu-24.04 — только после замера P1 (пакет `vino` в noble). Решение и правка `tests/live.env` (5.1.2) — в Task 20 | без замера ночь краснела бы от отсутствующего пакета |
| П11 | Ночные варианты `sddm` и `from-gnome` обязаны быть зелёными (Task 6 и Task 21); `from-gnome` ставит `gdm3` до `gnome` (`LIVE_PREINSTALL`), иначе `gnome` запоминает пустой `dm=` и проверяется не миграция §5 | skeptic по плану: «разобраны» в Task 6 против «два зелёных ночных подряд» в Task 21 |
| П12 | Снимок `desktop` 2.0.0 — сырые строки и позиция (с закомментированными), а не «значение или не было»; фикстуры из настоящих пакетов gdm3 | `set_ini_key` удаляет закомментированные варианты — без сырых строк П6 «побайтно» невыполним |
| П13 | `xs_find_display`, запасной путь 1: дисплей Xorg пользователя — `:N` в argv, иначе его слушающий сокет `/tmp/.X11-unix/X<N>` (`/proc/<pid>/fd` против `/proc/net/unix`), иначе `/tmp/.X<N>-lock` с его pid (владелец root или uid Xorg, без записи для группы и остальных, не ссылка); найденный дисплей (и `:0`) подтверждает только authority самого пользователя при включённом контроле доступа (`xhost`), спека §10; `ss -xlp` не используется. `xs_seat0_active` печатает `user type class`. В Task 20 (P1/P2) записать сработавший подпуть и заполнен ли `Display` | ревью волны 1: rootless GDM запускает `Xorg vtN -displayfd 3` без `:N`, а в S2 вход идёт на `:1` |
| П14 | L `desktop` проверяет побайтный возврат после `remove` (`LIVE_EXPECT_RESTORED`); путь «`set 0` → `remove`» — в H | раннер не умеет `cream set` между шагами; заводить его ради одного теста — лишняя абстракция |
| П15 | `x11-xserver-utils` (`xhost`) — зависимость каждого потребителя `lib/x-session.sh`: `existing-desktop` (Task 6), `selkies` (Task 10), `x11vnc` (Task 11). Пакет ставит `hooks/install` рядом с `x11-utils`/`xauth` (у `existing-desktop` — единственный пакет, который он ставит); README называет его, H проверяет вызов apt, L — `command -v xhost` после install | без `xhost` `_xs_confirm` не проверяет контроль доступа и не принимает дисплей запасных путей (П13): без пакета безопасного запасного пути нет; пакет маленький и есть в Debian и Ubuntu |
| П16 | Рулинг исполнителя волны 2: L `gdm-xorg` гоняет debian-12 и ubuntu-24.04 **в PR** (`LIVE_DISTROS`), `LIVE_NIGHTLY_DISTROS` не заводится; gdm3 не ставится — файлы пакета (554 байта) ложатся `LIVE_PRESEED=live-root`: `custom.conf` закомментирован, `daemon.conf` с `true`. Код 10 раннер принимает без отметок (cream — rc 0, «нужна перезагрузка»). Ссылка вместо файла gdm3 — `install` 1 (отказ), не 20 | пакетов нет — прогон короткий, ночная добавка ничего не даёт; 20 скрыл бы от владельца, что gdm3 есть, а файл — чужая ссылка |

## Версии
| Расширение | Было (после П1) | Станет | Мажор? | Задача |
|---|---|---|---|---|
| `existing-desktop` | — | 1.0.0 | новое | 6 |
| `gdm-xorg` | — | 1.0.0 | новое | 8 |
| `desktop` | 1.1.1 | 2.0.0 | да | 7 |
| `selkies` | 6.2.2 | 7.0.0 | да | 10 |
| `x11vnc` | 5.1.2 | 6.0.0 | да | 11 |
| `cloud-user-desktop` | 5.0.1 | 6.0.0 (в Task 3 — 5.0.2, П2) | да | 3 → 12 |
| `gnome` | 5.0.1 | 5.1.0 (в Task 3 — 5.0.2, П2) | нет | 3 → 9 |
| `xfce4`, `lxde` | 5.0.1 | 5.0.2 | нет | 3 |
| `wallpaper` | 3.0.2 | 3.0.3 (только `tests/live.env`) | нет | 3 |
| `code-server` | 5.2.3 | 5.3.0 | нет | 13 |
| `docker` | 4.1.1 | 4.2.0 | нет | 14 |
| `firefox` | 2.0.3 | 2.1.0 | нет | 15 |
| `vino-vnc` | 5.1.1 | 5.1.1 или 5.1.2 (П10) | нет | 20 |
| `kiosk`, `l4t-vendor-desktop` | без изменений | — | — | — |

Каталог — минор (`feat:`), П5.

## Файлы (создать / изменить)
| Действие | Путь | Назначение | Задача |
|---|---|---|---|
| создать | `lib/x-session.sh`, `lib/tests/test-x-session.sh` | поиск сеанса seat0, дисплея, authority | 1 |
| создать | `lib/gdm-wayland.sh`, `lib/tests/test-gdm-wayland.sh` | `gw_read`, `gw_set_false`, `gw_restore` | 2 |
| изменить | `extensions/debian/{gnome,xfce4,lxde,cloud-user-desktop}/extension.yaml`, `{xfce4,lxde,wallpaper}/tests/live.env`, `wallpaper/extension.yaml` | диапазон `desktop`, ночной ubuntu-24.04 | 3 |
| изменить | `tools/live-test.sh`, `tools/testdata/live/…`, `docs/guides/testing.md`, `docs/runbooks/04_live-runs.md` | новые ключи раннера, варианты | 4 |
| изменить | `tools/live-matrix.sh`, `tools/test-live-matrix.sh`, `.github/workflows/live.yml` | варианты и ночные дистрибутивы в матрице | 5 |
| создать | `extensions/debian/existing-desktop/**`, `lib/x-session.consumers` | новое расширение | 6 |
| изменить | `extensions/debian/desktop/**` (+ `hooks/upgrade`) | 2.0.0 | 7 |
| создать | `extensions/debian/gdm-xorg/**`, `lib/gdm-wayland.consumers` | новое расширение | 8 |
| изменить | `extensions/debian/gnome/**`, `lib/gdm-wayland.consumers` | 5.1.0 | 9 |
| изменить | `extensions/debian/selkies/**`, `lib/x-session.consumers` | 7.0.0 | 10 |
| изменить | `extensions/debian/x11vnc/**`, `lib/x-session.consumers` | 6.0.0 | 11 |
| изменить | `extensions/debian/cloud-user-desktop/**` | 6.0.0 | 12 |
| изменить | `extensions/debian/code-server/**` | 5.3.0 | 13 |
| изменить | `extensions/debian/docker/**` | 4.2.0 | 14 |
| изменить | `extensions/debian/firefox/**` | 2.1.0 | 15 |
| изменить | `docs/specs/2026-11-12-existing-desktop.md` (статус, ссылка на issue в §9) | | 16 |
| изменить | `docs/guides/use-in-bisquite.md` | миграция VMFILE и `--accept-risk cloud-user-desktop` | 17 |
| изменить | `docs/reference/capabilities.md`, `docs/reference/layout.md`, `docs/known-issues.md` | | 18 |
| создать | `.github/workflows/<по ответу владельца>`, `tools/<скрипт сборки>` | ночная build-сборка | 19 |
| создать | `docs/runbooks/05_existing-desktop-acceptance.md`; строка в `docs/README.md` | P1–P7 | 20 |
| изменить | `docs/STATUS.md`; генерируемые блоки (П3) | | 21 |

**Владение.** Исполнитель трогает только файлы своей задачи из таблицы плюс генерируемые блоки (П3). Чужой файл
нужен — остановиться и доложить контроллеру. `git add <пути>`, `git commit -m "…" -- <пути>`, без `-A`.

## Волны (до 5 исполнителей; тяжёлое — `make ci`, `make test-live` — по одному на хосте)
| Волна | Задачи | Условие старта |
|---|---|---|
| 0 | — | П1 |
| 1 | 1, 2, 3, 4, 5; 16 (контроллер, без worktree) | волна 0 |
| 2 | 6, 7, 8, 13, 14 | 6 ← 1, 4, 5; 7 ← 3, 4; 8 ← 2, 4 |
| 3 | 9, 10, 12, 15, 17 | 9 ← 2, 3, 8; 10 ← 1, 4, 6; 12 ← 3; 17 ← 7 (читать можно раньше) |
| 4 | 11, 18 | 11 ← 10; 18 ← 6, 8, 9, 10 (дописывает x11vnc после 11) |
| 5 | 20 → 21 | 20 ← 6–15, 18; 21 ← всё, кроме 19 |
| вне волн | 19 | ответ владельца на §11; 21 его не ждёт |

H-тесты задач 6–15 можно писать до слияния зависимостей; L и `make ci` — после rebase на голову интеграционной ветки.

## Задачи (по волнам)

### Task 1: `lib/x-session.sh`
- **Модель:** Opus (выбор пользователя и сеанса для захвата экрана, разбор вывода `loginctl`).
- **Зависит от:** —. **Версия:** нет (библиотека без потребителей, П4).
- **Что:** функции §4.2 спеки: `xs_seat0_session <user>` (через `loginctl show-user -p Sessions` и
  `show-session -p Seat -p Class -p Type -p Display -p State -p Remote`; только `Seat=seat0`, `Class=user`,
  `Remote=no`; `active` раньше `online`; колонки `list-sessions` не разбирать), `xs_seat0_active`,
  `xs_find_display <user>` (`Display` → Xorg пользователя по `pgrep`/`ps` с первым аргументом `:N` → `:0` при
  проходящей проверке authority; путь пишется в stderr), `xs_find_authority <user> <display>` — кандидаты из
  `run-selkies.sh` (одна копия на двоих). Имя пользователя в библиотеку приходит уже проверенным, но в командах —
  только как отдельный аргумент, без `eval` и подстановки в строку для shell.
- **Файлы:** `lib/x-session.sh`, `lib/tests/test-x-session.sh`.
- **Тесты (H, до кода):** на моках `loginctl`/`pgrep`/`xdpyinfo`: x11 `:0`; x11 `:1`; `Display` пуст → Xorg
  пользователя; оба пусты → `:0` с authority; Wayland (тип отдаётся, дисплей не ищется); на seat0 другой
  пользователь; `Remote=yes` не берётся; `online` против `active`; logind недоступен → пустой ответ без падения.
  Проверка: `make test` (H), `make lint`.
- **Готово когда:** `make test` и `make lint` зелёные; `lib/tests/test-x-session.sh` найден `tools/check.sh`.

### Task 2: `lib/gdm-wayland.sh`
- **Модель:** Opus (правка конфигурации DM, точный возврат).
- **Зависит от:** —. **Версия:** нет (П4).
- **Что:** `gw_read <root>` → `absent|commented|true|false` и файл (`/etc/gdm3/custom.conf` Ubuntu,
  `/etc/gdm3/daemon.conf` Debian, порядок поиска — по коду `gnome/hooks/install`); `gw_set_false <root> <state-file>`
  — записывает прежнюю строку побайтно (вместе с её позицией в секции `[daemon]`) в файл состояния, пишет
  `WaylandEnable=false`, код «изменил/не изменил»; `gw_restore <root> <state-file>` — возвращает строку побайтно,
  удаляет запись. Ссылка вместо файла — не пишем, отказ. Повторный `gw_set_false` не перезаписывает запись.
- **Файлы:** `lib/gdm-wayland.sh`, `lib/tests/test-gdm-wayland.sh`.
- **Тесты (H):** четыре исходных состояния строки × оба файла; нет секции `[daemon]`; ссылка; повтор; возврат
  побайтно (`cmp`); запись есть, файла нет. `make test`, `make lint`.
- **Готово когда:** тесты зелёные; функции не зовут `systemctl` и не печатают в stdout ничего, кроме результата.

### Task 3: диапазон `desktop <3` и ночной ubuntu-24.04
- **Модель:** Sonnet (механика: строки манифестов и `live.env`).
- **Зависит от:** —.
- **Что:** `depends: desktop ">=1.0.0 <3"` у `gnome`, `xfce4`, `lxde`, `cloud-user-desktop`; версии `xfce4`, `lxde`,
  `gnome`, `cloud-user-desktop` → 5.0.2 с комментарием «диапазон desktop <3 (desktop 2.0.0)». `LIVE_NIGHTLY_DISTROS="ubuntu-24.04"`
  в `tests/live.env` у `xfce4`, `lxde`, `wallpaper`; `wallpaper` → 3.0.3 («только тест: ночной ubuntu-24.04»).
  `make docs`.
- **Файлы:** `extensions/debian/{gnome,xfce4,lxde,cloud-user-desktop,wallpaper}/extension.yaml`,
  `extensions/debian/{xfce4,lxde,wallpaper}/tests/live.env`; генерируемые блоки (П3).
- **Тесты:** V — `make cream-validate`, `make test` (`check-version-bump`, `catalog-docs --check`).
- **Готово когда:** `make ci` зелёный; `desktop` 2.x проходит диапазон у всех четырёх.

### Task 4: L-раннер — новые ключи и варианты
- **Модель:** Opus.
- **Зависит от:** —. **Версия:** нет.
- **Что (`tools/live-test.sh`):**
  - `LIVE_PREINSTALL="пакеты"` / `--preinstall` — `apt-get install -y --no-install-recommends` в контейнере
    **до** установки cream (стол, поставленный не через cream);
  - `LIVE_PRESEED=<каталог под tests/>` / `--preseed` — дерево копируется в корень контейнера до cream (данные,
    не скрипт; путь только внутри `tests/` расширения, `..` — отказ);
  - `LIVE_EXPECT_RESTORED="пути"` — sha256 и режимы путей фиксируются после preinstall/preseed и сверяются после
    `remove` (нет пути до — нет и после);
  - `LIVE_DEPS_FORCE_REMOVE="имена"` — после `LIVE_DEPS` и до установки расширения `cream remove --force <имя>`;
    после установки каждая оставшаяся зависимость в `cream list --json` — `installed`, `cream check` (форма —
    по `--help` пина) без ошибок графа;
  - `LIVE_REMOVE_FORCE=1` — итоговый `remove` с `--force` (у расширения остаются зависимые);
  - `--variant <v>` — поверх `tests/live.env` читается `tests/live.<v>.env` (ключи варианта перекрывают), журналы —
    `.scratchpad/live/<ext>.<v>-<distro>/`.
- **Файлы:** `tools/live-test.sh`, `tools/testdata/live/<фикстуры новых ключей>`, `docs/guides/testing.md` (таблица
  ключей, включая `LIVE_NIGHTLY_DISTROS` и варианты из Task 5), `docs/runbooks/04_live-runs.md` (разбор падений
  preinstall/restored).
- **Тесты:** фикстуры в `tools/testdata/live/` на каждый ключ; `make test-live-self DISTRO=ubuntu-24.04` (тяжёлая,
  по одному); `make lint`, `make test`.
- **Готово когда:** самопроверка зелёная; без новых ключей прогон расширения не изменился (сверка журнала
  `make test-live EXT=btop`).

### Task 5: L-матрица — варианты и ночные дистрибутивы
- **Модель:** Opus.
- **Зависит от:** —; контракт с Task 4 — строка матрицы `ext`, `distro`, `variant` (пусто — `live.env`).
- **Что:** `tools/live-matrix.sh` перечисляет `tests/live.env` и `tests/live.*.env`; `LIVE_NIGHTLY_DISTROS`
  добавляется к `LIVE_DISTROS` только в `--all`; вариант наследует `LIVE_NIGHTLY_ONLY` своего файла, иначе — базового;
  `--changed` берёт варианты изменённого расширения. `.github/workflows/live.yml` передаёт `--variant`.
- **Файлы:** `tools/live-matrix.sh`, `tools/test-live-matrix.sh`, `.github/workflows/live.yml`.
- **Тесты:** `tools/test-live-matrix.sh` — вариант в `--all` и `--changed`; ночные дистрибутивы только в `--all`;
  ночной вариант не попадает в PR. `make test`, `make lint`.
- **Готово когда:** `make ci` зелёный; вывод матрицы без вариантов совпадает с прежним побайтно.

### Task 6: `existing-desktop` 1.0.0
- **Модель:** Opus (разбор конфигов DM и logind — внешний ввод; анти-цель «ничего не менять»).
- **Зависит от:** 1, 4, 5. **Версия:** 1.0.0 (новое).
- **Что:** манифест §4.1 спеки; `install` — проверка файлов (Xorg, DM по ссылке `display-manager.service` внутри
  корня или `/etc/X11/default-display-manager` с существующим бинарём, `*.desktop` в `/usr/share/xsessions`; только
  Wayland-сессии — отдельный текст), коды 0/1, в live — диагноз как у `status`; `check` 0/1; действие `status`
  (только чтение: DM и `is-active`, `WaylandEnable`, автологин gdm3/LightDM/SDDM, сеанс seat0 через
  `xs_seat0_active`; без logind — строка «нет logind»); `install` ставит `x11-xserver-utils` (П15); `remove` пустой. Подсказка в тексте отказа — «сначала
  `cream remove existing-desktop`» (S5). `lib/x-session.consumers` с `debian/existing-desktop`.
  Создавать через `tools/new-extension.sh`.
- **Файлы:** `extensions/debian/existing-desktop/{extension.yaml,hooks/install,hooks/check,hooks/remove,actions/status,README.md}`,
  `tests/test-existing-desktop.sh`, `tests/live.env` (debian-12 и ubuntu-24.04, `LIVE_PREINSTALL="xserver-xorg-core lightdm"`,
  `LIVE_PRESEED` с `usr/share/xsessions/*.desktop`, `LIVE_EXPECT_RESTORED="/etc/lightdm /etc/X11"`),
  `tests/live.gdm3.env`, `tests/live.sddm.env` (ubuntu-24.04, `LIVE_NIGHTLY_ONLY=1`),
  `tests/live.from-gnome.env` (ubuntu-24.04, ночь: `LIVE_PREINSTALL="gdm3 xserver-xorg-core"` (готовый стол до `gnome`, П11), `LIVE_DEPS="cloud-user desktop gnome selkies"`,
  `LIVE_DEPS_FORCE_REMOVE=gnome`, `LIVE_REMOVE_FORCE=1`, `LIVE_ACCEPT_RISK=1`), `tests/live-root/…`;
  `lib/x-session.consumers`.
- **Тесты:** H (до кода) — фикстуры gdm3 Ubuntu (`custom.conf`: нет ключа, закомментирован, `false`), gdm3 Debian
  (`daemon.conf`), LightDM, SDDM, нет DM, только Wayland-сессии, L4T R32; `HT_PHASE=build` — ни одного вызова
  `loginctl`/`systemctl is-active`; `status` на моках `loginctl`; снимок дерева корня до и после — без изменений.
  L — `make test-live EXT=existing-desktop` на debian-12 и ubuntu-24.04; варианты `gdm3`, `sddm`, `from-gnome` —
  `make test-live EXT=existing-desktop DISTRO=ubuntu-24.04 ARGS='--variant <v>'`.
- **Готово когда:** `make ci` зелёный, L-прогоны (основной ×2, `gdm3`, `sddm`, `from-gnome`) зелёные — ночной набор
  целиком входит в критерий Task 21 (П11).

### Task 7: `desktop` 2.0.0
- **Модель:** Opus (автологин).
- **Зависит от:** 3, 4. **Версия:** 1.1.1 → 2.0.0, мажор.
- **Что:** §4.3 спеки, рулинги Р1, П6, П7: `DESKTOP_AUTOLOGIN` — `bool`, `empty: true`, умолчание `""`; снимок
  `$CREAM_STATE_DIR/autologin.before` (П12: по файлу и ключу — сырые строки секции, совпавшие с регэкспом
  `set_ini_key`, включая закомментированные, и их позиция, как `lib/gdm-wayland.sh` хранит `WaylandEnable`;
  ключи — `AutomaticLoginEnable`, `AutomaticLogin` в `[daemon]` gdm3; `autologin-user`, `autologin-user-timeout`
  LightDM) только при
  `CREAM_REASON=install`, не перезаписывается; новый `hooks/upgrade` (работа `install` + маркер `legacy` при
  `CREAM_PREV_VERSION` < 2.0.0); возврат при пустом ключе и в `remove` (снимок → значения; `legacy` или нет записи →
  выключить, как 1.x); `active_dm` узнаёт `sddm`; SDDM + ключ `0`/`1` → прочие ручки, затем 1 с текстом
  «автологин SDDM не поддержан: `/etc/sddm.conf.d/`, вручную»; перезапуск DM — как сейчас (только при сменённом
  отпечатке и без графического сеанса). README — таблица смысла ключа, миграция §5.
- **Файлы:** `extensions/debian/desktop/{extension.yaml,hooks/install,hooks/upgrade,hooks/configure,hooks/remove,files/desktop.sh,actions/status,actions/apply,README.md}`,
  `tests/test-desktop.sh`, `tests/live.env`, `tests/live.gdm3.env` (ubuntu-24.04: `LIVE_PRESEED` с `custom.conf`, где
  автологин включён; `LIVE_PARAMS="DESKTOP_AUTOLOGIN=0"`; `LIVE_EXPECT_RESTORED=/etc/gdm3/custom.conf`), `tests/live-root-gdm3/…`.
- **Тесты (H, до кода):** матрица `""`/`0`/`1` × gdm3/LightDM/SDDM; снимок только при `CREAM_REASON=install`
  (при `boot`, `apply`, `upgrade` — нет); точный возврат; `remove` без записи = 1.x; **Р1:** «1.x с
  `DESKTOP_AUTOLOGIN=1` → `upgrade` (маркер `legacy`) → `configure` при `boot` → `remove`: автологин выключен» и то
  же с `DESKTOP_AUTOLOGIN=` вместо `remove`; обновление с 1.x при пустом ключе — отпечаток не меняется, DM не
  перезапускается; П6 — install с пустым ключом, затем `apply` с `1`, `remove` → исходный файл побайтно (П12: фикстуры H и варианта
  `gdm3` — настоящие `custom.conf`/`daemon.conf` из пакетов gdm3 Ubuntu 24.04 и Debian 12, с закомментированными
  ключами).
  L — `make test-live EXT=desktop` (debian-12, ubuntu-24.04) и вариант `gdm3`.
- **Готово когда:** `make ci` и L зелёные; `actions/status` показывает `sddm`.

### Task 8: `gdm-xorg` 1.0.0
- **Модель:** Opus (меняет вход владельца по согласию).
- **Зависит от:** 2, 4. **Версия:** 1.0.0 (новое).
- **Что:** §4.5 спеки: `targets: {build: exec, live: confirm}` с `live_note`, `conflicts.extensions: [gnome]`;
  `install` — нет файлов gdm3 → 20; `false` → 0 без записи (в состоянии «было false»); иначе `gw_set_false`, в live
  код 10 без перезапуска gdm, в build 0; `remove` — `gw_restore`, изменение в live → 10. `lib/gdm-wayland.consumers`
  с `debian/gdm-xorg`.
- **Файлы:** `extensions/debian/gdm-xorg/{extension.yaml,hooks/install,hooks/remove,README.md}`,
  `tests/test-gdm-xorg.sh`, `tests/live.env` (ubuntu-24.04 и debian-12, `LIVE_PRESEED` с `custom.conf`/`daemon.conf`,
  `LIVE_ACCEPT_RISK=1`, `LIVE_EXPECT_RESTORED`, `LIVE_NIGHTLY_DISTROS`), `tests/live-root/…`; `lib/gdm-wayland.consumers`.
- **Тесты (H):** четыре исходных состояния; ссылка вместо файла — не пишем; побайтный возврат; 10 только в live и
  только при изменении. L — `make test-live EXT=gdm-xorg DISTRO=ubuntu-24.04` (как раннер обрабатывает код 10 —
  проверить и, если нужно, отметить в `live.env`).
- **Готово когда:** `make ci`, L зелёные; односторонний конфликт допустим до Task 9 (`cream validate` даёт только
  предупреждение).

### Task 9: `gnome` 5.1.0
- **Модель:** Opus (DM, Wayland, возврат при снятии).
- **Зависит от:** 2, 3, 8. **Версия:** 5.0.2 (Task 3) → 5.1.0, минор (П2).
- **Что:** §4.6 спеки: `install` через `gw_set_false` с записью прежнего; изменение `WaylandEnable` в live → 10 даже
  при уже `graphical`; `remove` — `gw_restore`, у установок 5.0.x записи нет — строка остаётся (README);
  `conflicts.extensions: [gdm-xorg]`; `tests/live.env` — `LIVE_NIGHTLY_DISTROS="ubuntu-24.04"`. Дописать
  `debian/gnome` в `lib/gdm-wayland.consumers`.
- **Файлы:** `extensions/debian/gnome/{extension.yaml,hooks/install,hooks/remove,README.md,tests/test-gnome.sh,tests/live.env}`,
  `lib/gdm-wayland.consumers`.
- **Тесты (H):** четыре исходных состояния; 10 при `graphical` и изменённой строке; `remove` с записью — побайтно,
  без записи — строка остаётся. L — ночью (`LIVE_NIGHTLY_ONLY`), вручную один раз `make test-live EXT=gnome`.
- **Готово когда:** `make ci` зелёный, ручной L зелёный, `check-shared-libs` видит двух потребителей.

### Task 10: `selkies` 7.0.0
- **Модель:** Opus (учётка для захвата экрана, внешний ввод `SELKIES_USER`).
- **Зависит от:** 1, 4, 6 (и П1). **Версия:** 6.2.2 → 7.0.0, мажор.
- **Что:** §4.4 спеки, Р2–Р4, П8, П15 (`install` ставит `x11-xserver-utils` вместе с `x11-utils` и `xauth`):
  - ключи `SELKIES_USER` (`re:^[a-z_][a-z0-9_-]{0,31}$`, `empty: true`, `""`) и `SELKIES_DISPLAY`
    (`re:^(auto|:[0-9]+(\.[0-9]+)?)$`, `empty: true`, `"auto"`); умолчание манифеста (оно попадает в действующее
    окружение 6.2.2) и запасное значение обёртки `${SELKIES_DISPLAY:-auto}` совпадают;
  - uid-правило: есть в passwd и `1000 ≤ uid < 65534` — в обёртке (иначе 78) и в `configure`/`apply`
    (экземпляр не запускается, причина в журнале);
  - обёртка: `xs_find_display`/`xs_find_authority`; ожидание сеанса — строка диагноза раз в 5 минут; пропажа X —
    1; `unset SELKIES_USER` до `exec` (П8);
  - `install` в live без Xorg или без ссылки `display-manager.service` → 20 с текстом «нет X-сервера / менеджера
    входа: поставьте стол или `existing-desktop`»; `configure` в тех же условиях → 1; DM включён, но не активен —
    предупреждение и 0 (R11); в build проверки нет;
  - `configure`/`apply` — однострочный диагноз по `xs_seat0_active`;
  - `install`: `apt-get update` один раз перед `x11-utils xauth`, даже если curl уже был;
  - README: `pixelflux-tegra`, `vino-vnc`, `wallpaper` берут пользователя из `cloud-user` (Jetson Nano, группа `video`);
  - `tests/live.env`: `LIVE_DEPS="cloud-user existing-desktop"`, `LIVE_PREINSTALL`/`LIVE_PRESEED` как у Task 6,
    `LIVE_NIGHTLY_DISTROS="ubuntu-24.04"`; дописать `debian/selkies` в `lib/x-session.consumers`.
- **Файлы:** `extensions/debian/selkies/{extension.yaml,hooks/install,hooks/configure,hooks/apply,files/selkies.sh,files/run-selkies.sh,README.md,tests/test-selkies.sh,tests/live.env}`,
  `tests/live-root/…`, `lib/x-session.consumers`.
- **Тесты (H, до кода):** `SELKIES_USER` нет в passwd → 78; `gdm` (uid < 1000), root, uid ≥ 65534 → 78 в обёртке,
  `configure` не запускает экземпляр; `auto` → дисплей из библиотеки; ключ не задан → запасное значение обёртки;
  сохранённое `:0` не меняется; `install` в live без Xorg / без DM → 20, `configure` → 1; в build — 0;
  окружение подставного `selkies` без `SELKIES_USER`; logind не отдаёт сеанс → запасной путь 2 (`:0`).
  L — `make test-live EXT=selkies` (debian-12, ubuntu-24.04).
- **Готово когда:** `make ci`, L зелёные; `check-shared-libs` — `x-session → existing-desktop selkies`.

### Task 11: `x11vnc` 6.0.0
- **Модель:** Opus.
- **Зависит от:** 10 (образец и `lib/x-session.consumers`). **Версия:** 5.1.2 → 6.0.0, мажор.
- **Что:** то же, что Task 10 (включая `x11-xserver-utils` по П15), для `X11VNC_USER`/`X11VNC_DISPLAY` (`"auto"`, сохранённое `:0` валидно):
  запасное значение `${X11VNC_DISPLAY:-auto}` в `run-x11vnc.sh` (cream кладёт в config только явные ключи — Р4);
  uid-правило; проверка машины в `install`/`configure`; `tests/live.env` — как у Task 10; дописать `debian/x11vnc` в
  `lib/x-session.consumers`.
- **Файлы:** `extensions/debian/x11vnc/{extension.yaml,hooks/install,hooks/configure,hooks/apply,files/x11vnc.sh,files/run-x11vnc.sh,README.md,tests/test-x11vnc.sh,tests/live.env}`,
  `tests/live-root/…`, `lib/x-session.consumers`.
- **Тесты:** как у Task 10 (кроме П8); обе ветки Р4 — ключ не задан и задан. L — `make test-live EXT=x11vnc` ×2 дистрибутива.
- **Готово когда:** `make ci`, L зелёные.

### Task 12: `cloud-user-desktop` 6.0.0
- **Модель:** Opus (`userdel -r`, автологин).
- **Зависит от:** 3. **Версия:** 5.0.2 (Task 3) → 6.0.0, мажор (П2).
- **Что:** `targets.live: confirm` с `live_note` про необратимый `userdel -r`; `install` снимает автологин gdm3 и
  LightDM **только** если он указывает на удалённую учётку (раньше это делало умолчание `desktop` 1.x); README —
  `--accept-risk` и `hold` при `cream upgrade --all`.
- **Файлы:** `extensions/debian/cloud-user-desktop/{extension.yaml,hooks/install,README.md,tests/test-cloud-user-desktop.sh}`.
- **Тесты (H):** автологин на удалённую учётку снят; на другую учётку — не тронут; нет конфигов DM — 0.
  L — `make test-live EXT=cloud-user-desktop` (уже `LIVE_ACCEPT_RISK=1`).
- **Готово когда:** `make ci`, L зелёные.

### Task 13: `code-server` 5.3.0
- **Модель:** Opus (удаление).
- **Зависит от:** —. **Версия:** 5.2.3 → 5.3.0, минор.
- **Что:** `install` записывает в состояние, был ли пакет `code-server` до него; `remove` снимает пакет через
  apt-guard и только если его поставил `install` (сейчас — безусловный `apt-get purge`, `files/code-server.sh`);
  записи нет (старая установка) — как сейчас. Нужна ли `depends: apt-guard` — по коду apt-guard (как у `x11vnc`).
- **Файлы:** `extensions/debian/code-server/{extension.yaml,hooks/install,hooks/remove,files/code-server.sh,README.md,tests/test-code-server.sh}`.
- **Тесты (H):** предустановленный пакет переживает `remove`; свой — снимается; старая установка без записи — как 5.2.x.
  L — `make test-live EXT=code-server`.
- **Готово когда:** `make ci`, L зелёные.

### Task 14: `docker` 4.2.0
- **Модель:** Opus (удаление).
- **Зависит от:** —. **Версия:** 4.1.1 → 4.2.0, минор.
- **Что:** `install` записывает, были ли `docker.sources` и ключ до него; `remove` удаляет их только если завёл
  `install`; записи нет — как сейчас.
- **Файлы:** `extensions/debian/docker/{extension.yaml,hooks/install,hooks/remove,README.md,tests/test-docker.sh}`.
- **Тесты (H):** чужой источник и ключ переживают `remove`; свои — сняты; без записи — как 4.1.x.
  L — `make test-live EXT=docker`.
- **Готово когда:** `make ci`, L зелёные.

### Task 15: `firefox` 2.1.0
- **Модель:** Opus (удаление).
- **Зависит от:** —. **Версия:** 2.0.3 → 2.1.0, минор.
- **Что:** то же для `mozilla.list`, `preferences.d/mozilla` и ключа.
- **Файлы:** `extensions/debian/firefox/{extension.yaml,hooks/install,hooks/remove,README.md,tests/test-firefox.sh}`.
- **Тесты:** как у Task 14. L — `make test-live EXT=firefox`.
- **Готово когда:** `make ci`, L зелёные.

### Task 16: issue в cream (§9)
- **Модель:** Sonnet (текст готов ниже; сверка строк).
- **Зависит от:** —. Делает контроллер, кода нет.
- **Что:** сверить ссылки `файл:строка` с текущим `main` cream; завести issue в `iamletenkov/cream` (`gh issue
  create`); ссылку записать в §9 спеки; статус спеки — «принята (skeptic 2026-11-12, рулинги §10)».
- **Файлы:** `docs/specs/2026-11-12-existing-desktop.md`.
- **Готово когда:** issue есть, ссылка в спеке, `make check-links` зелёный.

Текст issue:

```markdown
Заголовок: Запись со статусом failed/skipped участвует в графе как поставщик и сторона конфликта

## Что
Расширение, у которого хук `install` упал (`failed`) или вернул 20 (`skipped`), остаётся в графе
установленного: его `provides` закрывают чужие `requires`, а его `conflicts` мешают ставить соседей.

## Где (main, ревизия <sha>)
- `internal/engine/install.go:468-486` — дерево расширения ставится до хука;
- `internal/engine/install.go:536-546` — при сбое хука запись сохраняется со статусом `failed`;
- `internal/engine/installed.go:16-30` (`Installed()`) — все записи без фильтра статуса;
- `internal/engine/upgrade.go:545-562` (`installNodes`) — узлы графа из всех записей с читаемым деревом;
- `internal/resolve/graph.go:205-216` (`checkRequires`) — поставщик ищется среди них.

## Как воспроизвести
1. Ubuntu 24.04 Server без менеджера входа, каталог cream-extensions ≥ <версия с existing-desktop>.
2. `sudo cream install existing-desktop` → хук отвечает 1 (нет DM), cream — 79 `hook.failed`.
3. `sudo cream install selkies` → граф проходит (способности `x11-server`, `display-manager` дала неудачная
   запись); отказывает уже сам хук `install` selkies (20 → 68).
4. `sudo cream install gnome --accept-risk` → `conflict.capability` с неудачной записью `existing-desktop`
   по `desktop-session`.

## Ожидание
Запись `failed` или `skipped` не считается поставщиком и стороной конфликта. Либо спека cream явно описывает,
почему считается, и что оператор должен сделать (`cream remove` неудачной записи).

## Контекст
Каталог обходит это проверкой машины в хуках потребителей (спека cream-extensions
`docs/specs/2026-11-12-existing-desktop.md`, §4.4, рулинг Р2) и выпуска cream не ждёт. `cream assume` не требуется.
```

### Task 17: сверка потребителей
- **Модель:** Opus (автологин на роботах и образах).
- **Зависит от:** 7, 12 (поведение зафиксировано); читать можно с волны 2. Репозитории bisquite и stvor-agent —
  только чтение.
- **Что:** (1) VMFILE bisquite, где `desktop` идёт без явного `DESKTOP_AUTOLOGIN` или где вендорский автологин гасило
  умолчание 1.x (`cloud-user-desktop`) — список файлов и строк; (2) скрипты обновления bisquite и stvor-agent,
  которые зовут `cream upgrade --all` — нужен ли `--accept-risk cloud-user-desktop` или `hold`; (3) раздел
  «Миграция на desktop 2.0.0 и cloud-user-desktop 6.0.0» в `docs/guides/use-in-bisquite.md`; (4) тексты issue в
  bisquite и stvor-agent — в отчёт контроллеру (заводит контроллер).
- **Файлы:** `docs/guides/use-in-bisquite.md`.
- **Тесты:** `make check-links`, `make test` (документация).
- **Готово когда:** раздел написан, тексты issue переданы, ни одного потребителя без решения.

### Task 18: документация каталога
- **Модель:** Sonnet (механика: строки таблиц по готовым манифестам).
- **Зависит от:** 6, 8, 9, 10, 11.
- **Что:** `capabilities.md` — `existing-desktop` пятым поставщиком `x11-server`, `display-manager`, `desktop-session`
  (проверка без установки), строки `requires` у `x11vnc`/`selkies` без «`DISPLAY=:0`» (`auto`, `xs_find_display`),
  конфликт `gnome` ↔ `gdm-xorg`; `layout.md` — `x-session.sh`, `gdm-wayland.sh` и их потребители; `known-issues.md` —
  Wayland не захватывается (78, `gdm-xorg`), автологин SDDM — отказ, обои Plasma, запись `failed` в графе cream
  (ссылка на issue из Task 16), `gnome` 5.0.x → 5.1.0 не возвращает `WaylandEnable`.
- **Файлы:** `docs/reference/capabilities.md`, `docs/reference/layout.md`, `docs/known-issues.md`.
- **Тесты:** `make test` (`check-links`, таблицы), `make lint`.
- **Готово когда:** `make ci` зелёный.

### Task 19: ночная build-сборка графического стека (ждёт §11)
- **Модель:** Opus.
- **Зависит от:** ответ владельца на вопрос 1 §11 (hosted `ubuntu-latest` с KVM для libguestfs или self-hosted).
  Task 21 её **не ждёт**.
- **Что:** `cream install` `gnome`, `desktop`, `selkies`, `x11vnc` и `existing-desktop` (на образе с готовым gdm3)
  под `virt-customize` на облачном образе ubuntu-24.04 amd64 из снимка каталога (`make snapshot`); ночью и вручную.
- **Файлы:** по ответу владельца — workflow в `.github/workflows/` и скрипт в `tools/` с тестом на сухом прогоне;
  строка в `docs/guides/testing.md` («Где это идёт само»).
- **Готово когда:** два ночных прогона подряд зелёные.

### Task 20: ручная приёмка P1–P7 на ВМ
- **Модель:** Opus (живая машина, автологин, учётки).
- **Зависит от:** 6–15, 18 слиты в интеграционную ветку.
- **Подготовка:** ВМ amd64 (тестовая PVE-нода); снимок каталога из головы ветки — `make snapshot`; cream — по пину
  `tools/cream-pin.env`; подключение снимка и `cream check` — по [runbook 01](../runbooks/01_release-catalog.md).
  На каждую машину — ISO и его дата, версии cream, каталога, расширений, ядра, DM, Xorg; перед каждым P — снимок ВМ.
  Пароли `selkies`/`x11vnc` — секретом (`--params-file`/`cream set` по README), в runbook и журнал не попадают.
- **Замеры (в runbook — фактическое значение, а не ожидание):**

| # | Машина | Что замерить |
|---|---|---|
| P1 | Ubuntu 24.04 Desktop, GDM, автологин | `existing-desktop` → код и диагноз; тип сеанса (`loginctl show-session -p Type -p Display`) до и после `gdm-xorg --accept-risk`; код `gdm-xorg` (10); дисплей сеанса после перезагрузки; заполнен ли `Display`; путь `xs_find_display` (журнал обёртки); Selkies и x11vnc показывают стол (скриншот в `.scratchpad/`); на Wayland — 78 и нет цикла (`systemctl show -p NRestarts`); `remove gdm-xorg` — `cmp` с копией `custom.conf` до; автологин не тронут ни одним шагом (`cmp`); есть ли пакет `vino` в noble и работает ли на Xorg (решение П10); подхват обоев dconf; `selkies --help` не знает `SELKIES_USER` |
| P2 | то же, без автологина | до входа — строка ожидания раз в 5 минут; **на каком дисплее сеанс после ручного входа (`:0` или `:1`)** и `Display`; вход другого пользователя — диагноз; выход и вход — Selkies вернулся (время); `SELKIES_USER=gdm` → 78 |
| P3 | Xubuntu 24.04, LightDM, ± автологин | дисплей, authority (какой кандидат), `Display`; Selkies и x11vnc; `desktop` с пустым ключом не трогает `autologin-user` (`cmp`) |
| P4 | Kubuntu 24.04, SDDM | **тип сеанса по умолчанию**; где authority; Selkies на X11-сеансе Plasma; `desktop DESKTOP_AUTOLOGIN=1` → код 1 и текст; `existing-desktop status` — автологин SDDM |
| P5 | Ubuntu 24.04 Server без DM | `existing-desktop` → код и текст; сразу `selkies` — проходит ли граф (§9) и код `install` (ожидаем 20 → 68); после `cream remove existing-desktop` — `selkies` → 67; записать фактические коды |
| P6 | физическая машина с DM без монитора (если есть) | поднимается ли Xorg и с каким разрешением; что видит Selkies. Нет железа — «не замерено» в runbook и README `existing-desktop` |
| P7 | Debian 12, готовый Xfce + LightDM | `kiosk` и `wallpaper` поверх `existing-desktop`: коды, экран, обои |

- **Файлы:** `docs/runbooks/05_existing-desktop-acceptance.md`, строка в `docs/README.md`; по П10 —
  `extensions/debian/vino-vnc/{tests/live.env,extension.yaml,README.md}` (5.1.2) или строка «на noble не поддержан»
  в README `vino-vnc`. Расхождение замера с поведением кода — отдельная fix-задача тому же исполнителю
  расширения, приёмка P — заново только по затронутым пунктам.
- **Готово когда:** P1–P5, P7 записаны, P6 — замер или «не замерено»; открытых расхождений нет.

### Task 21: Финальная интеграция + `make ci`
- **Модель:** Opus.
- **Зависит от:** 1–18, 20.
- **Что:** rebase `feature/existing-desktop` на `main`; `make docs`; `make ci`; `make cream-check`;
  `make snapshot-check`; L изменённых L-расширений на debian-12 и ubuntu-24.04 по одному; два прогона ночного набора
  `gh workflow run live.yml --ref feature/existing-desktop` (пустой `ext` — все, с ночными дистрибутивами) подряд
  зелёные; `docs/STATUS.md`; PR в `main` — squash, заголовок `feat(existing-desktop): …`, в теле нет
  `BREAKING CHANGE:` (П5); в описании PR — таблица версий, миграция §5 и ссылки на issue (Task 16, 17).
- **Файлы:** `docs/STATUS.md`, генерируемые блоки (П3).
- **Готово когда:** все проверки выше зелёные выводом `make`/`gh run view`, PR открыт; слияние — по правилам
  репозитория.

## Миграции / схема
БД нет. Состояние расширений на машине — файлы в `$CREAM_STATE_DIR`: `desktop/autologin.before` (снимок или маркер
`legacy`), `gdm-xorg/wayland.before`, `gnome/wayland.before`, записи `code-server`/`docker`/`firefox` о том, что
было до `install`. Формат каждого — в README расширения.

## Риски и открытые вопросы
- **§11 спеки (владелец):** где гонять ночную build-сборку — блокирует только Task 19.
- `LIVE_PREINSTALL` на ubuntu-24.04 с `gdm3`/`sddm` тянет сотни мегабайт — варианты `gdm3`/`sddm` только ночью;
  память контейнера — `LIVE_MEMORY=2g`.
- Код 10 `gdm-xorg` в L-раннере: как он трактуется (`reboot required`) — проверить в Task 8 до правки раннера; править
  раннер — только через контроллера (файл Task 4).
- Task 11 ждёт Task 10 из-за общего `lib/x-session.consumers` (П4) — последовательность, а не параллель.
- Если `fix/selkies-effective-env` до слияния поменяет имя или формат действующего окружения, Task 10 сверяет
  умолчание `SELKIES_DISPLAY` с новым механизмом (Р4).
- `cloud-user-desktop` → `confirm` ломает `cream upgrade --all` у потребителей без `--accept-risk` — Task 17 до
  выпуска.
