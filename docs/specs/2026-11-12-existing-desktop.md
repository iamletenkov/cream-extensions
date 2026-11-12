# Спека: удалённый стол на машине с готовым рабочим столом и менеджером входа

Дата: 2026-11-12. Статус: черновик, ждёт skeptic. Классификация: **архитектурная** — новое
расширение и новая общая библиотека, смена умолчаний и мажорные версии `desktop`, `selkies`,
`x11vnc`, `cloud-user-desktop`.

Вход: аудит расширений от 2026-11-12, ведётся вне репозитория, в рабочих материалах Stvor. Его
выводы ниже сверены с кодом `origin/main` (`d027662`, каталог 5.23.0) и cream `3c46ca6`. Ссылки
вида `файл:строка` — на эти ревизии. Код cream — в соседнем репозитории, поэтому ссылки на него
записаны текстом.

## 1. Цель и почему

Машина уже с рабочим столом: Ubuntu 24.04 Desktop с GDM, Xubuntu с LightDM, Kubuntu с SDDM.
Стол поставил установщик ОС, а не cream. Оператору нужен удалённый доступ к экрану этой машины
(`selkies`, `x11vnc`, `vino-vnc`) и, на Debian, киоск (`kiosk`) или обои (`wallpaper`). Сейчас
это не работает.

1. **Установка отказывает с кодом 67 `deps.requires`.** `selkies`, `x11vnc`, `vino-vnc`,
   `kiosk` требуют `x11-server` и `display-manager`, а `wallpaper` требует `desktop-session`
   ([selkies/extension.yaml:51](../../extensions/debian/selkies/extension.yaml),
   [wallpaper/extension.yaml:39](../../extensions/debian/wallpaper/extension.yaml)). Эти
   способности дают только `gnome`, `xfce4`, `lxde` и `l4t-vendor-desktop`. Последний на любой
   системе, кроме L4T R32, выходит с кодом 20
   ([l4t-vendor-desktop/hooks/install:22-32](../../extensions/debian/l4t-vendor-desktop/hooks/install)).
   Резолвер cream требует поставщика среди установленного (cream
   `internal/resolve/graph.go:205-216`, `checkRequires`). `cream assume` зарезервирован и
   отвечает 64 (cream `internal/cli/man.go:369`, `reservedCommands`).
2. **Обход через `gnome`, `xfce4` или `lxde` ломает чужую настройку.** Каждый из них тянет
   `desktop` 1.x. У `desktop` умолчание `DESKTOP_AUTOLOGIN=0`
   ([desktop/extension.yaml:52-55](../../extensions/debian/desktop/extension.yaml)), и оно
   **активно** пишет `AutomaticLoginEnable=false` в gdm3 и удаляет `autologin-user` у LightDM
   ([desktop/files/desktop.sh:190-215](../../extensions/debian/desktop/files/desktop.sh)). Делает
   это на каждой загрузке (`every_boot`). Если графического сеанса нет, оно перезапускает DM
   (`:545-586`). SDDM оно не знает: `active_dm` перебирает только gdm3, gdm и lightdm
   (`:535-541`). `remove` не возвращает прежний автологин, а выключает его (`:601-602`).
   `gnome` пишет `WaylandEnable=false` ([gnome/hooks/install:115-132](../../extensions/debian/gnome/hooks/install)).
   Если цель уже `graphical` и DM не менялся, код 10 не возвращается (`:145-155`), а `remove`
   оставляет этот ключ ([gnome/hooks/remove:2-5](../../extensions/debian/gnome/hooks/remove)).
   Вдобавок обход ставит сотни мегабайт пакетов поверх готового стола.
3. **Сеанс ищется не там.** `selkies` по умолчанию смотрит на `:0`
   ([run-selkies.sh:53](../../extensions/debian/selkies/files/run-selkies.sh)). Пользователь —
   только из библиотеки `cloud-user` ([selkies.sh:156-176](../../extensions/debian/selkies/files/selkies.sh)),
   своего ключа нет. `x11vnc` берёт `X11VNC_DISPLAY=:0`. На GDM без автологина сеанс после
   ручного входа может оказаться не на `:0`. В репозитории это **не замерено** (§6, P2).
4. **На Wayland обёртки зацикливаются.** `exit 1` при `Restart=always` (selkies,
   `run-selkies.sh:114`, `selkies@.service:20-23`) и при `Restart=on-failure` (x11vnc,
   `run-x11vnc.sh:131`). Это чинит **отдельный PR «Wayland → 78»** в `selkies` и `x11vnc`, и он
   предпосылка этой спеки. Здесь он не описывается, на код 78 спека только опирается.

Цель — принять готовый стол как есть. Ничего в нём не менять без явного согласия, найти
настоящий сеанс и честно сказать, когда работать нельзя (Wayland, нет входа, нет DM).

## 2. Цели, не-цели, анти-цели

**Цели**
- Ц1. `cream install selkies|x11vnc|vino-vnc|wallpaper` на машине с готовым столом и DM
  разрешается без перестановки стола: новое расширение `existing-desktop` даёт способности
  после проверки (решение A аудита).
- Ц2. `selkies` и `x11vnc` находят X-сеанс нужного пользователя на `seat0` через logind
  (`SELKIES_USER`/`X11VNC_USER` и `*_DISPLAY=auto`; решение C).
- Ц3. `desktop` 2.0.0 не трогает автологин, пока его не попросили. То, что оно заменило,
  запоминается и возвращается при снятии. На SDDM — явный отказ.
- Ц4. Переключение GDM на Xorg — только отдельным расширением с `live: confirm` и с точным
  откатом. `gnome` тоже откатывает `WaylandEnable`.
- Ц5. Хвосты снятия: `cloud-user-desktop` → `confirm`. `code-server` снимает пакет через
  apt-guard и только свой. `docker` и `firefox` снимают только те источники apt, которые
  завели сами.
- Ц6. Приёмка: пять сценариев на ВМ с Ubuntu 24.04 и ночной CI графического стека на
  ubuntu-24.04.

**Не-цели** (не делаем здесь; где сказано — делаем в другом месте)
- Виртуальный стол со своим Xvfb или Xdummy и сеансом на `:N` без DM и монитора — отдельной
  спекой.
- Захват Wayland-сеанса (портал, PipeWire, gnome-remote-desktop).
- Поддержка автологина SDDM (в 2.0.0 только отказ, §4.3).
- `kiosk` на Ubuntu: `platform.os` — только Debian
  ([kiosk/extension.yaml:36](../../extensions/debian/kiosk/extension.yaml)); не меняется.
- Обои Plasma (`wallpaper` знает GNOME, Xfce, LXDE).
- Сеансы `startx` без DM, multi-seat, переключение Selkies на того, кто сейчас вошёл.
- Правка cream: `cream assume` и учёт неудачных записей в графе (§9).
- Арм-приёмка на железе: arm64 закрывают H-тесты, Jetson R32 — `l4t-vendor-desktop` как есть.

**Анти-цели** (не делаем никогда в этой линии)
- Не менять конфигурацию DM, автологин и Wayland без явного ключа или `--accept-risk`.
- `existing-desktop` не ставит пакетов, не включает юнитов и не перезапускает DM.
- Не захватывать экран входа: authority гритера принадлежит `gdm`/root, Selkies от них не
  запускается.
- Не запускать Selkies или x11vnc от root и не выбирать пользователя «кто первый вошёл».

## 3. Поведение по сценариям: до и после

Машина в примерах — Ubuntu 24.04 amd64, пользователь установщика `alice` (uid 1000),
cloud-init без userdata или без него вовсе. Команды — `sudo cream install …`; пароли
`selkies`/`x11vnc` заданы. «До» — по коду `origin/main`, «после» — по этой спеке.
Предположения, которые не замерены, помечены **(не замерено)** и стоят в приёмке (§6).

### S1. GDM с автологином (Ubuntu 24.04 Desktop, Wayland по умолчанию)

| | До | После |
|---|---|---|
| `existing-desktop` | нет такого | 0. Вывод: «DM gdm3; WaylandEnable не задан — сеансы GNOME на Wayland; автологин alice; seat0: alice, wayland». Ничего не меняет |
| `selkies` | 67 `deps.requires`. Через обход `gnome`: автологин alice выключен, gdm перезапущен к экрану входа (если сеанса нет), `WaylandEnable=false` записан без кода 10 | Разрешается. `configure` пишет диагноз и запускает `selkies@alice`. Обёртка видит Wayland и выходит с 78 (PR «Wayland → 78»). Цикла нет, в журнале — подсказка про `gdm-xorg` |
| `gdm-xorg --accept-risk` | нет такого | `WaylandEnable=false`, прежнее значение записано в состояние, код 10. После перезагрузки автологин открывает X11-сеанс alice (ожидаемо `:0` — **не замерено**, P1). Selkies находит его сам (`auto`). Автологин не тронут |
| `x11vnc` | 67 | Как `selkies`: на Wayland — 78, после `gdm-xorg` работает |
| `vino-vnc` | 67 | Разрешается. Работает только в X11-сеансе. Есть ли пакет `vino` в noble и работает ли он с GNOME 46 на Xorg — **не замерено** (P1); не обещаем, пока не замерено |
| `wallpaper` | 67 | Разрешается. Системное умолчание dconf. Подхватит ли его GNOME на Ubuntu без своего профиля dconf — **не замерено** (P1) |
| `remove gdm-xorg` | — | Прежнее значение `WaylandEnable` (нет ключа, закомментирован, `true`) возвращается побайтно, код 10 |

### S2. GDM без автологина

| | До | После |
|---|---|---|
| `existing-desktop` | нет | 0. Диагноз: «автологина нет; на seat0 — экран входа» |
| `selkies` до входа | 67 (с обходом — бесконечное ожидание `:0`) | Обёртка ждёт сеанс alice на seat0 и раз в 5 минут пишет «ждём входа alice на seat0; экран входа не захватывается» |
| после входа alice в «Ubuntu on Xorg» или после `gdm-xorg` | с обходом — ожидание `:0`, хотя сеанс может быть на `:1` (**не замерено**) | `auto` берёт дисплей сеанса из logind (`Display`) или запасным путём (§4.4). На каком дисплее сеанс (`:0` или `:1`) и заполнен ли у GDM `Display` — **не замерено**, P2 |
| вошёл `bob`, не alice | бесконечное ожидание, без объяснения | Ожидание и диагноз «на seat0 сеанс bob; Selkies настроен на alice: `cream set selkies SELKIES_USER=bob`» |
| выход из сеанса | сторож ловит пропажу X, перезапуск, ожидание `:0` | То же. После перезапуска обёртка снова ищет сеанс по logind |
| `desktop DESKTOP_AUTOLOGIN=1 DESKTOP_AUTOLOGIN_USER=alice` | включает, при снятии выключает | Включает и записывает прежние значения. При снятии или `DESKTOP_AUTOLOGIN=` возвращает их |

### S3. LightDM (Xubuntu 24.04)

| | До | После |
|---|---|---|
| `existing-desktop` | нет | 0. Диагноз: «DM lightdm; автологин: `autologin-user` или нет» |
| `selkies`, `x11vnc` | 67. С обходом `xfce4`: пакеты доставлены, `desktop` по умолчанию снимает `autologin-user` | Разрешаются. Сеанс Xfce — X11, authority в `~/.Xauthority` или `/run/lightdm/<user>/xauthority` (кандидаты уже в обёртке). Ожидаемо работает и с автологином, и после ручного входа. Дисплей и заполненность `Display` — P3 |
| `wallpaper` | 67 | Системный канал xfconf. Собственный канал пользователя перекрывает его — так было и раньше (README `wallpaper`) |
| `desktop` (не ставится по умолчанию) | — | Пустой `DESKTOP_AUTOLOGIN` не трогает `autologin-user` |

### S4. SDDM (Kubuntu 24.04)

| | До | После |
|---|---|---|
| `existing-desktop` | нет | 0. Диагноз: «DM sddm; автологин `[Autologin] User=` из `/etc/sddm.conf` и `/etc/sddm.conf.d/`» (только чтение) |
| `selkies`, `x11vnc` | 67. С обходом — второй DM и гигабайты пакетов | Разрешаются. Тип сеанса по умолчанию — **не замерено**: по сведениям, в Kubuntu 24.04 (Plasma 5.27) это X11, в Plasma 6 — Wayland. На Wayland — 78. Где SDDM кладёт authority сеанса пользователя (`~/.Xauthority`?) — **не замерено**, P4 |
| `desktop DESKTOP_AUTOLOGIN=1` | молча не действует | Явный отказ: прочие ручки применены, `configure` выходит с 1, в журнале — «автологин SDDM не поддержан: `/etc/sddm.conf.d/`, вручную». При пустом ключе — 0 |
| `wallpaper` | 67 | Разрешается, на Plasma не действует. Написано в README, не чиним (не-цель) |

### S5. Без DM (Ubuntu 24.04 Server; Xorg может стоять пакетом)

| | До | После |
|---|---|---|
| `existing-desktop` | нет | 1. «нет менеджера входа: ни `display-manager.service`, ни `/etc/X11/default-display-manager`»; подсказка: `gnome`/`xfce4`/`lxde --accept-risk` или виртуальный стол (отдельная спека) |
| `selkies` | 67 | 67, пока нет поставщика. Оговорка cream в §9: запись `existing-desktop` со статусом `failed` по коду всё ещё даёт способности. В README — «после отказа: `cream remove existing-desktop`» |
| `gnome --accept-risk` (по-прежнему возможно) | ставит стол, `desktop` пишет `AutomaticLoginEnable=false` | Ставит стол. `desktop` 2.0.0 автологин не трогает. Чтобы был сеанс без человека: `DESKTOP_AUTOLOGIN=1`, как и раньше |

**Xorg без монитора.** На физической машине без монитора, но с DM поднимется ли Xorg и с каким
разрешением — **не замерено** (P6). ВМ это не покрывает: у неё всегда есть виртуальный
дисплей. Настраивать dummy-плату или `AllowEmptyInitialConfiguration` эта спека не будет.

## 4. Контракты

### 4.1 Новое расширение `existing-desktop` 1.0.0

```yaml
schema: cream/v1
name: existing-desktop
version: 1.0.0
summary: Готовый рабочий стол машины (не через cream) как x11-server, display-manager, desktop-session
cream: ">=1.2.0"
platform: {family: deb, arch: [amd64, arm64], os: [{id: debian}, {id: ubuntu}]}
targets: {build: exec, live: "yes"}
provides: [x11-server, display-manager, desktop-session]
conflicts: {capabilities: [desktop-session]}
hooks: {install: {timeout: 2m}, remove: {}, check: {}}
actions:
  status: {summary: "DM, Wayland, автологин, сеанс seat0", lock: none, phases: [live]}
```

- **`install`** проверяет **файлы**, одинаково в build и live, по образцу `l4t-vendor-desktop`,
  но без условия R32:
  - Xorg: `/usr/lib/xorg/Xorg` или `/usr/bin/Xorg`;
  - DM: `display-manager.service` — ссылка внутри корня — или `/etc/X11/default-display-manager`
    с существующим бинарём;
  - X-сессия: хотя бы один `*.desktop` в `/usr/share/xsessions`.

  Есть только Wayland-сессии (`/usr/share/wayland-sessions`) — это отказ с отдельным текстом.
  На живой машине в конце печатается диагноз, тот же, что у `status`.
- **Коды `install`:** 0 — все три части на месте; 1 — части нет, она названа в журнале (cream
  отдаёт 79 `hook.failed`). Кодов 10 и 20 нет: расширение ничего не меняет, а «неприменимо»
  ничего не дало бы. Пропущенная запись тоже остаётся в графе (§9).
- **`check`:** 0 — Xorg на месте и DM включён; 1 — нет. Для `cream check` и `cream status`.
- **`status`:** только чтение. Выводит:
  - DM: имя юнита и `is-active`;
  - GDM: `WaylandEnable` — `false`, `true`, нет ключа или закомментирован;
  - автологин: gdm3 (`AutomaticLoginEnable`/`AutomaticLogin`), LightDM (`autologin-user`),
    SDDM (`[Autologin] User`);
  - сеанс seat0: пользователь, `Type`, `Display`, `State`.

  Код 0; если logind недоступен — строка «нет logind».
- **`remove`:** пустой, код 0.
- Конфликт по `desktop-session` с `gnome`, `xfce4`, `lxde`, `l4t-vendor-desktop` честен:
  у машины один стол.
- `l4t-vendor-desktop` не меняется. Объединять ли его с `existing-desktop` — вопрос следующего
  выпуска, этой спеки он не блокирует.

### 4.2 Общая библиотека `lib/x-session.sh` (одна копия в git)

Раскладывается в `files/` потребителей по `lib/x-session.consumers`: `selkies`, `x11vnc`,
`existing-desktop`. Механизм тот же, что у `lib/fetch.sh`
([docs/reference/layout.md](../reference/layout.md)). Функции:

- `xs_seat0_session <user>` выводит `sid type display state` сеанса пользователя на seat0. Берёт
  `loginctl show-user <user> -p Sessions`, затем для каждого `show-session -p Seat -p Class -p Type
  -p Display -p State -p Remote`. Нужны `Seat=seat0`, `Class=user`, `Remote=no`; `active`
  предпочтительнее `online`. Колонки `list-sessions` не разбираются: их состав зависит от
  версии systemd.
- `xs_seat0_active` выводит пользователя и тип активного сеанса seat0 — для диагноза
  «на экране bob».
- `xs_find_display <user>`. Есть сеанс `x11` с непустым `Display` — берётся `Display`. Пусто —
  запасной путь 1: процесс `Xorg` с владельцем `<user>`, первый аргумент `:N`. Ничего — запасной
  путь 2, нынешнее поведение: `:0`, если на нём проходит проверка authority. Какой путь сработал,
  пишется в журнал. Приёмка фиксирует путь для каждого DM.
- `xs_find_authority <user> <display>` — нынешние кандидаты из `run-selkies.sh:86-105`, но
  одной копией на двоих.

### 4.3 `desktop` 2.0.0 (мажор: смена умолчания и смысла снятия)

| Ключ | Было | Стало |
|---|---|---|
| `DESKTOP_AUTOLOGIN` | `bool`, умолчание `"0"` | `bool`, `empty: true`, умолчание `""`. Пусто — «автологином не управляю»; `0` — выключить; `1` — включить. `bool` с `empty: true` cream принимает (cream `internal/keytype/spec.go:43-53`) |

- **Запись прежнего.** Перед первой записью ключей автологина `configure` сохраняет прежние
  значения в `$CREAM_STATE_DIR/autologin.before`: по файлу и ключу — значение или «не было».
  Ключи: `AutomaticLoginEnable` и `AutomaticLogin` в `[daemon]` gdm3; `autologin-user` и
  `autologin-user-timeout` в секции LightDM. Повторный запуск запись не перезаписывает (правило
  cream §6.3 о резервных копиях).
- **Возврат.** `DESKTOP_AUTOLOGIN` стал пустым или вызван `remove` — значения из записи
  возвращаются, запись удаляется. Записи нет (установка 1.x) — `remove` ведёт себя как 1.x и
  выключает автологин. Это осторожное умолчание: машина без пароля не остаётся.
- **Перезапуск DM** — как сейчас: только `--now`, только при сменённом отпечатке конфигов и без
  графического сеанса. При обновлении с 1.x и пустом ключе отпечаток не меняется, перезапуска
  нет (H-тест).
- **SDDM.** Нашёлся `sddm` (ссылка `display-manager.service` или
  `/etc/X11/default-display-manager`), а ключ `0` или `1` — прочие ручки применяются, затем
  `configure` выходит с 1 и называет причину. Пусто — 0. `active_dm` узнаёт `sddm`, чтобы
  `status` показывал правду. Поддержку отложили: автологин SDDM требует `Session=`, имя
  X11-сессии Plasma различается между 5.27 и 6, и сначала это надо замерить.
- `gnome`, `xfce4`, `lxde`, `cloud-user-desktop` расширяют `depends` на `desktop` до
  `">=1.0.0 <3"`, иначе `cream upgrade` заблокирует `desktop` по `deps.version`.

### 4.4 `selkies` 7.0.0 и `x11vnc` 6.0.0 (мажор: смена умолчания дисплея)

Обе версии отсчитываются от выпуска PR «Wayland → 78».

| Ключ | Тип, умолчание | Смысл |
|---|---|---|
| `SELKIES_USER` | `re:^[a-z_][a-z0-9_-]{0,31}$`, `empty: true`, `""` | пусто — как сейчас (библиотека `cloud-user`); имя — этот пользователь, без cloud-user |
| `SELKIES_DISPLAY` | `re:^(auto\|:[0-9]+(\.[0-9]+)?)$`, `empty: true`, `"auto"` | `auto` (и пусто) — `xs_find_display`; `:N` — жёстко, как сейчас |
| `X11VNC_USER` | как `SELKIES_USER` | то же |
| `X11VNC_DISPLAY` | `re:^(auto\|:[0-9]+(\.[0-9]+)?)$`, `"auto"` | то же; сохранённое `:0` остаётся валидным |

- Объявленный `SELKIES_USER` должен перекрывать шаблон `SELKIES_*`. Обёртка не передаёт его
  Selkies. Что сам Selkies не читает переменную с таким именем, проверяется по `selkies --help`
  (H и P1), а не предполагается.
- **Коды обёрток:** 78 — Wayland (из PR «Wayland → 78»), а также `*_USER`, которого нет в
  passwd, или root. Ожидание сеанса — не выход: раз в 5 минут строка диагноза — чей сеанс на
  seat0 и какого типа. Пропажа X — выход с 1 и перезапуск юнита. Новый поиск идёт по logind.
- **`configure`/`apply`:** пользователь — `*_USER` или cloud-user. Дальше — однострочный диагноз
  по `xs_seat0_active`: «на seat0 сеанс bob (x11), Selkies ждёт alice». Поведение «нет DM — 0 с
  предупреждением» (R11) не меняется.
- Попутно: `selkies/hooks/install:109-111` ставит `x11-utils` и `xauth` без `apt-get update`,
  если curl уже был. На готовой Ubuntu со старыми списками это отказ. Добавить `update` один раз.

### 4.5 `gdm-xorg` 1.0.0 (новое; переключение GDM на Xorg по согласию)

```yaml
targets:
  build: exec
  live: confirm
  live_note: >-
    выключает Wayland у GDM (WaylandEnable=false в /etc/gdm3/custom.conf или daemon.conf): после
    перезагрузки все сеансы GNOME и экран входа — Xorg; прежнее значение возвращает cream remove
conflicts: {extensions: [gnome]}
```

- `install`: файлов gdm3 нет — 20 («не GDM»). Значение уже `false` — 0, ничего не пишется, в
  состоянии помечено «было false». Иначе прежнее состояние строки — нет ключа, закомментирован
  или `true` — записывается в `$CREAM_STATE_DIR/wayland.before`, пишется `false`. На живой
  машине — код 10, gdm не перезапускается. В build — 0.
- `remove`: строка возвращается побайтно как была. Изменение на живой машине — код 10.
- Код правки — `lib/gdm-wayland.sh` (`gw_read`, `gw_set_false`, `gw_restore`), потребители —
  `gdm-xorg` и `gnome`: одна копия, без расхождения.
- Конфликт с `gnome` объявляют **обе** стороны ([правило](../reference/capabilities.md)): у
  строки один владелец.

### 4.6 `gnome` 5.1.0

`install` переходит на `lib/gdm-wayland.sh` и записывает прежнее значение. Если `WaylandEnable`
изменился на живой машине — код 10, даже когда цель уже `graphical`. `remove` возвращает
записанное значение; у установок 5.0.x записи нет — строка остаётся, как и сейчас. Добавляются
`conflicts.extensions: [gdm-xorg]` и `desktop` до `<3`. `xfce4`, `lxde` 5.0.2 — только
диапазон `desktop`.

### 4.7 Хвосты снятия

| Расширение | Версия | Изменение |
|---|---|---|
| `cloud-user-desktop` | 6.0.0 | `live: confirm` с `live_note` про необратимый `userdel -r` ([hooks/install:51-53](../../extensions/debian/cloud-user-desktop/hooks/install)). `install` сам снимает автологин gdm3 и LightDM, который указывает на удалённую учётку: раньше это делало умолчание `desktop` 1.x. Диапазон `desktop` — `<3` |
| `code-server` | минор | `remove` снимает пакет через apt-guard и только если его поставил `install`. Предустановленный пакет остаётся. Сейчас — `apt-get purge` безусловно ([files/code-server.sh:556](../../extensions/debian/code-server/files/code-server.sh)) |
| `docker` | минор | `install` записывает в состояние, был ли `docker.sources` до него. `remove` удаляет источник и ключ, только если их завёл `install`. Записи нет (старая установка) — как сейчас |
| `firefox` | минор | То же для `mozilla.list`, `preferences.d/mozilla` и ключа |

### 4.8 Способности и сводка версий

Новых имён способностей нет. `existing-desktop` — пятый поставщик `x11-server`,
`display-manager`, `desktop-session`. Строки в [reference/capabilities.md](../reference/capabilities.md)
и пересборка [reference/catalog.md](../reference/catalog.md) входят в задачи.

| Расширение | Версия | Мажор? | Почему |
|---|---|---|---|
| `existing-desktop` | 1.0.0 | новое | |
| `gdm-xorg` | 1.0.0 | новое | |
| `desktop` | 2.0.0 | да | умолчание `DESKTOP_AUTOLOGIN`, смысл `remove` |
| `selkies` | 7.0.0 | да | умолчание `SELKIES_DISPLAY`, новый ключ |
| `x11vnc` | 6.0.0 | да | умолчание `X11VNC_DISPLAY`, новый ключ |
| `cloud-user-desktop` | 6.0.0 | да | `live: yes → confirm` ломает скрипты без `--accept-risk` |
| `gnome` | 5.1.0 | нет | новое поведение `remove`, конфликт |
| `xfce4`, `lxde` | 5.0.2 | нет | диапазон `depends` |
| `code-server`, `docker`, `firefox` | минор | нет | `remove` бережнее |
| `vino-vnc`, `kiosk`, `wallpaper` | без изменений | — | разрешаются через `existing-desktop` |

Каталог — `feat:` (минор): мажоры несут версии расширений, `cream upgrade` строит план по
зависимостям.

## 5. Миграция существующих установок

- **Образы bisquite с `gnome`/`xfce4`/`lxde` + `desktop` 1.x.** `cream upgrade` до 2.0.0:
  - Явно заданный `DESKTOP_AUTOLOGIN` сохраняет смысл: cream хранит в домене только явные
    значения, умолчание берётся из схемы (cream `internal/config/domain.go:323-344`, `Values`).
  - Где ключ не задавался, умолчание становится пустым. `desktop` перестаёт писать
    `AutomaticLoginEnable=false` на загрузке, но в файле остаётся последнее записанное значение,
    поэтому видимого изменения нет. DM при обновлении не перезапускается.
  - `remove` после обновления без записи ведёт себя как 1.x.
- **VMFILE, где вендорский автологин гасило умолчание `desktop`** (`cloud-user-desktop`).
  Теперь его гасит `cloud-user-desktop` 6.0.0 — только запись, указывающую на удалённую учётку.
  Задача bisquite — сверить примеры, где `desktop` идёт без `DESKTOP_AUTOLOGIN`.
- **`cloud-user-desktop` → `confirm`.** `cream upgrade --all` покажет `blocked (risk)`. Нужен
  `--accept-risk cloud-user-desktop` или `hold`. Скрипты обновления потребителей (bisquite,
  stvor-agent) надо сверить до выпуска, это пункт плана.
- **`selkies` 6 → 7, `x11vnc` 5 → 6.**
  - Сохранённые `:0`/`:N` остаются как есть.
  - Где ключ не задавался, работает `auto`. На образах с автологином он находит тот же `:0`.
  - Если logind не отдаёт сеанс seat0, запасной путь 2 — нынешнее поведение. Регрессии нет,
    это H-тест.
- **`gnome` 5.0.x → 5.1.0.** Записи о прежнем `WaylandEnable` нет — `remove` оставляет `false`,
  как сейчас. Это написано в README.
- **Машины, где обход уже сделан через `gnome`.** Переход на `existing-desktop` — по желанию:
  1. `cream remove gnome` — цель и DM возвращаются, пакеты остаются;
  2. `cream install existing-desktop`.

  Автоматики нет: конфликт по `desktop-session` честно не даст держать оба.

## 6. Тесты и приёмка

**H** (`tests/test-*.sh` на подменённом корне, пишутся до кода):
- `existing-desktop`:
  - фикстуры gdm3 Ubuntu (`custom.conf`: Wayland по умолчанию, закомментирован, `false`), gdm3
    Debian (`daemon.conf`), LightDM, SDDM, нет DM, только Wayland-сессии, L4T R32;
  - `HT_PHASE=build` — без вызовов `loginctl`/`systemctl is-active`;
  - `status` на моках `loginctl`;
  - ни одной записи в корень (снимок дерева до и после).
- `lib/x-session.sh` на моках `loginctl`/`pgrep`/`xdpyinfo`: x11 `:0`; x11 `:1`; `Display`
  пустой → Xorg пользователя; оба пусто → `:0` с authority; Wayland; на seat0 другой
  пользователь; ssh-сеанс пользователя (`Remote=yes`) не берётся; `online` против `active`.
- `desktop`: матрица `""`/`0`/`1` × gdm3/LightDM/SDDM; запись и точный возврат; `remove` без
  записи = 1.x; обновление с 1.x при пустом ключе не меняет отпечаток и не перезапускает DM;
  SDDM + `1` → 1 после прочих ручек.
- `lib/gdm-wayland.sh`, `gdm-xorg`, `gnome`: четыре исходных состояния строки, ссылка вместо
  файла (не пишем); возврат побайтно; 10 только в live и только при изменении.
- `selkies`, `x11vnc`: `*_USER` нет в passwd → 78; `auto` → дисплей из библиотеки; сохранённое
  `:0` не меняется.
- `cloud-user-desktop`: снимает автологин только удалённой учётки. `code-server`, `docker`,
  `firefox`: предустановленное переживает `remove`.

**L** (`tools/live-test.sh`, контейнер с systemd):
- Новая переменная `tests/live.env` — `LIVE_PREINSTALL="пакеты"`: ставятся apt **до** cream,
  чтобы имитировать стол, поставленный не через cream. Сейчас такой нет (`tools/live-test.sh`).
- `existing-desktop` на ubuntu-24.04 с `LIVE_PREINSTALL` = gdm3, lightdm, sddm: код 0,
  `--reinstall` без изменений, `remove` ничего не меняет.
- `desktop` с предустановленным gdm3 и заранее включённым автологином: после install
  автологин на месте, после `set 0` и `remove` — исходный файл побайтно.
- `selkies` и `x11vnc` с `LIVE_DEPS=existing-desktop` на ubuntu-24.04: граф и установка
  проходят. Служба без экрана не стартует — как сейчас (`LIVE_FAILED_IGNORE`).
- Ночью (`LIVE_NIGHTLY_ONLY`) графический стек — `gnome`, `xfce4`, `lxde`, `selkies`, `x11vnc`,
  `vino-vnc`, `wallpaper`, `existing-desktop`, `gdm-xorg` — получает `ubuntu-24.04` в
  `LIVE_DISTROS` (сейчас только debian-12).

**Ночная сборка (build-фаза).** `cream install` графического стека amd64 (`gnome`, `desktop`,
`selkies`, `x11vnc`, `existing-desktop` на образе с готовым gdm3) под `virt-customize` на
облачном образе ubuntu-24.04 из снимка **настоящего** каталога. Где запускать — открытый
вопрос 1.

**P — ручная приёмка на ВМ** (amd64). Результаты — новый runbook
`docs/runbooks/05_existing-desktop-acceptance.md` с датой, ISO и версиями. Каждый пункт
фиксирует **замер**, а не ожидание.

| # | Машина | Что замерить и проверить |
|---|---|---|
| P1 | Ubuntu 24.04 Desktop, GDM, автологин | Тип сеанса до и после `gdm-xorg`; дисплей сеанса после перезагрузки; заполнен ли `Display` в logind; путь `xs_find_display`; Selkies и x11vnc показывают стол; 78 без цикла на Wayland; `remove gdm-xorg` возвращает `custom.conf` побайтно; автологин не тронут ни одним шагом; пакет и работа `vino`; подхват обоев dconf; `selkies --help` не знает `SELKIES_USER` |
| P2 | то же без автологина | **На каком дисплее сеанс после ручного входа в GDM (`:0` или `:1`)** и с каким `Display`; ожидание до входа с диагнозом; вход другого пользователя — диагноз; выход и вход — Selkies возвращается |
| P3 | Xubuntu 24.04, LightDM, ± автологин | Дисплей, authority, `Display`; Selkies и x11vnc; `desktop` с пустым ключом не трогает `autologin-user` |
| P4 | Kubuntu 24.04, SDDM | **Тип сеанса по умолчанию**; authority сеанса; Selkies на X11-сеансе Plasma; `desktop DESKTOP_AUTOLOGIN=1` → явный отказ |
| P5 | Ubuntu 24.04 Server без DM | `existing-desktop` → 1 с понятным текстом; `selkies` → 67; после `cream remove existing-desktop` граф чист |
| P6 | физическая машина с DM без монитора (если есть железо) | Поднимается ли Xorg и с каким разрешением; что видит Selkies. Нет железа — в README «не замерено», выпуск не блокирует |
| P7 | Debian 12, готовый Xfce + LightDM | `kiosk` и `wallpaper` поверх `existing-desktop` (`kiosk` — только Debian) |

Готово, когда H и L зелёные в `make ci`, ночной L на ubuntu-24.04 зелёный два прогона подряд,
P1–P5 и P7 записаны в runbook. По P6 — замер или явное «не замерено».

## 7. Отвергнутые варианты

| Вариант | Почему нет |
|---|---|
| Реализовать `cream assume add CAP` (вариант B аудита) | Это правка cream, а не каталога; «правду» способности никто не проверяет; оператор должен знать имена способностей. `existing-desktop` даёт то же с проверкой и без релиза cream. `assume` не исключается в будущем |
| Снять условие R32 с `l4t-vendor-desktop` | Имя станет неправдой. Код 20 на не-R32 — часть его контракта: VMFILE для R36 на него рассчитывают, и способности появились бы там, где раньше был пропуск |
| Режим «только проверка» внутри `gnome`/`xfce4`/`lxde` | Два расширения в одном манифесте; тот же довод, что в шапке `l4t-vendor-desktop/extension.yaml` |
| Убрать `requires` у `selkies`/`x11vnc` | Пропадает проверка порядка в VMFILE до сборки (`cream check`) — ради неё `requires` и вводили ([capabilities.md](../reference/capabilities.md)) |
| `existing-desktop` сам выключает Wayland | Меняет машину владельца без согласия: анти-цель. Для этого есть `gdm-xorg` с `confirm` |
| Переключатель Xorg ключом в `selkies` (`SELKIES_FORCE_X11=1`) | `live: confirm` — свойство расширения, а не ключа: ключ обошёл бы согласие. Строку правили бы три владельца |
| `gnome` зависит от `gdm-xorg` вместо своей правки | После `cream remove gnome` Wayland остаётся выключенным, пока не снят `gdm-xorg`; общий код и так один (`lib/gdm-wayland.sh`) |
| Пользователь Selkies по умолчанию — «кто сейчас на seat0» | Гонка с автологином на стадии `graphical`; удалённый доступ к столу того, кто случайно вошёл, по чужому паролю. Явный `SELKIES_USER` и диагноз лучше |
| Поддержать автологин SDDM сразу | `Session=` обязателен, имя X11-сессии Plasma 5.27 и 6 различается, ничего не замерено. Явный отказ сейчас, поддержка — после P4 |
| `remove` у `desktop` без записи оставляет автологин | Машина без пароля после снятия расширения. Осторожнее вести себя как 1.x |
| Захват гритера (F) | Selkies от root или `gdm`; анти-цель |
| Виртуальный стол сейчас (E) | Другой продукт: сеанс, звук, Xvfb или Xdummy, свой жизненный цикл. Отдельная спека |
| Отказ `existing-desktop` кодом 20 | Пропущенная запись тоже остаётся в графе (§9), а 20 без `--allow-skip` даёт 68 и прячет «чего нет». Код 1 называет недостающее, как у `l4t-vendor-desktop` |

## 8. Объём работ (ориентир для плана)

1. `lib/x-session.sh` и `lib/gdm-wayland.sh` с тестами `lib/tests`.
2. `existing-desktop` 1.0.0, строки capabilities и catalog.
3. `desktop` 2.0.0; `xfce4`, `lxde` 5.0.2 (диапазон).
4. `gdm-xorg` 1.0.0; `gnome` 5.1.0.
5. `selkies` 7.0.0 и `x11vnc` 6.0.0 — после выпуска PR «Wayland → 78».
6. Хвосты: `cloud-user-desktop` 6.0.0, `code-server`, `docker`, `firefox`.
7. `LIVE_PREINSTALL` в `tools/live-test.sh`, L-матрица ubuntu-24.04, ночная build-сборка.
8. P-приёмка и runbook 05; `known-issues.md`; сверка скриптов обновления потребителей
   (`--accept-risk cloud-user-desktop`).
9. Финальная интеграция и `make ci`.

## 9. Зависимости от cream (не блокируют)

- **Неудачная запись даёт способности.** По коду графа в него идут все установленные записи с
  читаемым деревом, статус не учитывается (cream `internal/engine/upgrade.go:545-562`,
  `installNodes`). Поэтому `existing-desktop` со статусом `failed` или `skipped` по коду всё ещё
  «даёт» `display-manager`. Это прочитано в коде, но не воспроизведено. В плане — H или
  интеграционный тест в cream и issue в cream: не считать поставщиком запись `failed` или
  `skipped`. До исправления спасают README и диагноз `configure` у потребителей (`dm_active`).
- **`cream assume`** остаётся зарезервированным; спека его не требует.

## 10. Открытые вопросы к владельцу

1. **Где гонять ночную build-сборку графического стека** (`virt-customize` на облачном образе
   ubuntu-24.04)? На hosted `ubuntu-latest`, если там есть KVM для libguestfs (не проверено),
   или на self-hosted раннере? Без ответа нельзя написать задачу 7. Остальные задачи от этого
   не зависят.
