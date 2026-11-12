# Спека: удалённый стол на машине с готовым рабочим столом и менеджером входа

Дата: 2026-11-12. Статус: принята (skeptic 2026-11-12, рулинги §10). Классификация: **архитектурная** — новое
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
| `existing-desktop` | нет | 1. «нет менеджера входа: ни `display-manager.service`, ни `/etc/X11/default-display-manager`». Подсказка: **сначала `cream remove existing-desktop`**, затем `gnome`/`xfce4`/`lxde --accept-risk` или виртуальный стол (отдельная спека). Без снятия неудачная запись держит конфликт `desktop-session` (§9) |
| `selkies`, `x11vnc` (после неудачного `existing-desktop`, не снятого) | 67 | Граф **проходит**: запись `failed` в графе даёт способности (§9). Отказывает сам `install` на живой машине: «нет включённого менеджера входа / нет Xorg», код 20 → cream 68 `target.*` (Р2) |
| `selkies`, `x11vnc` (запись снята) | 67 | 67 `deps.requires` |
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
  ничего не дало бы. Пропущенная запись тоже остаётся в графе (§9). Поэтому потребители не
  полагаются на граф и проверяют машину сами (§4.4, Р2).
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
- `xs_seat0_active` выводит пользователя, тип и класс (`user`/`greeter`) активного сеанса seat0 —
  для диагноза «на экране bob» или «на экране вход» (П13).
- `xs_find_display <user>`. Есть сеанс `x11` с непустым `Display` — берётся `Display`. Пусто —
  запасной путь 1: процесс `Xorg` с владельцем `<user>`; его дисплей — `:N` в argv, иначе его
  слушающий сокет `/tmp/.X11-unix/X<N>` (`/proc/<pid>/fd` против `/proc/net/unix`), иначе
  `/tmp/.X<N>-lock` с pid этого Xorg, владелец — root или `<user>`, запись группе и остальным
  закрыта (П13: GDM запускает `Xorg vtN -displayfd 3` без `:N`). Ничего — запасной путь 2,
  нынешнее поведение: `:0`. Дисплей любого запасного пути берётся, только если его открывает
  authority самого пользователя (его `XAUTHORITY`, `~/.Xauthority`, файлы его runtime-dir,
  `/run/lightdm/<user>/xauthority`; файл его uid без записи для других) и у дисплея включён контроль
  доступа (`xhost`; нет `xhost` — не берётся). Какой путь сработал,
  пишется в журнал. Приёмка фиксирует путь для каждого DM.
- `xs_find_authority <user> <display>` — нынешние кандидаты из `run-selkies.sh:86-105`, но
  одной копией на двоих.

### 4.3 `desktop` 2.0.0 (мажор: смена умолчания и смысла снятия)

| Ключ | Было | Стало |
|---|---|---|
| `DESKTOP_AUTOLOGIN` | `bool`, умолчание `"0"` | `bool`, `empty: true`, умолчание `""`. Пусто — «автологином не управляю»; `0` — выключить; `1` — включить. `bool` с `empty: true` cream принимает (cream `internal/keytype/spec.go:43-53`) |

- **Запись прежнего.** Снимок делается **только при `CREAM_REASON=install`** (Р1): перед первой
  записью ключей автологина `configure` сохраняет прежние значения в
  `$CREAM_STATE_DIR/autologin.before` — по файлу и ключу значение или «не было». Ключи:
  `AutomaticLoginEnable` и `AutomaticLogin` в `[daemon]` gdm3; `autologin-user` и
  `autologin-user-timeout` в секции LightDM. Повторный запуск запись не перезаписывает (правило
  cream §6.3 о резервных копиях). На загрузке (`boot`), при `apply` и `upgrade` снимок не
  делается: к этому моменту в файлах может стоять то, что записала сама 1.x.
- **Хук `upgrade` (новый, Р1).** `CREAM_PREV_VERSION` < 2.0.0 — пишет в `autologin.before`
  маркер `legacy` («прежнее значение неизвестно») без снимка. Без этого хука cream при
  обновлении запускает `install` и `configure` с `CREAM_REASON=upgrade` (cream
  `internal/engine/install.go:498-504`), а `every_boot` — снова на загрузке, и снимок взял бы
  значение, которое записала 1.x: у всех образов bisquite это `DESKTOP_AUTOLOGIN=1`. Если хук
  `upgrade` есть, cream вызывает его вместо `install`, поэтому он делает и работу `install`
  (пакеты `dconf-cli`, `x11-xserver-utils`).
- **Возврат.** `DESKTOP_AUTOLOGIN` стал пустым или вызван `remove`:
  - снимок есть — значения из него возвращаются, запись удаляется;
  - маркер `legacy` или записи нет — автологин выключается, как в 1.x. Это осторожное
    умолчание: машина без пароля не остаётся.
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

- **Откуда берётся `auto` (Р4).** Юниты читают `/etc/cream/<ext>/config` как
  `EnvironmentFile`, а cream кладёт туда только **явно заданные** ключи (cream
  `internal/config/domain.go:323-344`). Поэтому умолчание манифеста до обёртки не доходит. `auto`
  при незаданном ключе даёт запасное значение в обёртке: `${X11VNC_DISPLAY:-auto}` вместо
  нынешнего `${X11VNC_DISPLAY:-:0}` ([run-x11vnc.sh:110](../../extensions/debian/x11vnc/files/run-x11vnc.sh)),
  и так же `${SELKIES_DISPLAY:-auto}` ([run-selkies.sh:53](../../extensions/debian/selkies/files/run-selkies.sh)).
  Параллельный PR `fix/selkies-effective-env` меняет передачу действующих значений в окружение
  юнита. После его слияния умолчание манифеста и запасное значение в обёртке обязаны совпадать.
  H-тест проверяет обе ветки: ключ не задан и ключ задан.
- **Какой пользователь допустим (Р3).** `*_USER` проходит, если он есть в passwd и его uid в
  диапазоне `1000 ≤ uid < 65534` — то же правило, что у
  [cloud-user/get_cloud_user.sh:46](../../extensions/debian/cloud-user/get_cloud_user.sh).
  Иначе — 78. Так отсекаются root, `gdm`, `lightdm`, `sddm` и другие системные учётки:
  для `gdm` второй кандидат authority, `/run/user/<uid>/gdm/Xauthority`, — authority гритера, и
  запуск от неё транслировал бы экран входа (анти-цель §2). Проверка стоит **и в обёртке, и в
  `configure`/`apply`**: `configure` не запускает экземпляр и пишет причину.
- **Проверка машины на живой машине (Р2).** Граф cream может пропустить установку без настоящего
  стола (§9), поэтому `install` у `selkies` и `x11vnc` при `CREAM_PHASE=live` проверяет сам:
  - Xorg: `/usr/lib/xorg/Xorg` или `/usr/bin/Xorg`;
  - включённый DM: ссылка `display-manager.service`.

  Нет одного из двух — код 20 и текст «нет X-сервера / менеджера входа: поставьте стол или
  `existing-desktop`». cream отдаёт 68, а без `--allow-skip` установка не проходит. `configure`
  при тех же условиях выходит с 1 и тем же текстом. Если DM включён, но ещё не активен
  (сразу после `gnome`, до перезагрузки), — по-прежнему предупреждение и 0 (R11). В build
  проверки нет: стол может ставиться той же сборкой.
- Объявленный `SELKIES_USER` должен перекрывать шаблон `SELKIES_*`. Обёртка не передаёт его
  Selkies. Что сам Selkies не читает переменную с таким именем, проверяется по `selkies --help`
  (H и P1), а не предполагается.
- **Коды обёрток:** 78 — Wayland (из PR «Wayland → 78»), а также `*_USER`, которого нет в
  passwd или чей uid вне `1000..65533` (Р3). Ожидание сеанса — не выход: раз в 5 минут строка диагноза — чей сеанс на
  seat0 и какого типа. Пропажа X — выход с 1 и перезапуск юнита. Новый поиск идёт по logind.
- **`configure`/`apply`:** пользователь — `*_USER` или cloud-user. Дальше — однострочный диагноз
  по `xs_seat0_active`: «на seat0 сеанс bob (x11), Selkies ждёт alice». «DM включён, но не
  активен — 0 с предупреждением» (R11) не меняется. Нет DM или Xorg — 1 (Р2).
- README `selkies`: `pixelflux-tegra`, `vino-vnc` и `wallpaper` берут пользователя из
  `cloud-user`, а не из `SELKIES_USER`. Если `SELKIES_USER` отличается, на Jetson Nano в группу
  `video` попадёт не тот пользователь, и кодирование молча уйдёт в x264. Назвать это в README.
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
  - Хук `upgrade` пишет маркер `legacy` (Р1), поэтому `remove` и пустой ключ после
    обновления выключают автологин, как 1.x. Записанное самой 1.x «прежним» не считается.
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
- **Машины, где обход уже сделан через `gnome`.** Переход на `existing-desktop` — по желанию,
  одной строкой (Р2):

  ```bash
  sudo cream remove --force gnome && sudo cream install existing-desktop
  ```

  `--force` нужен, потому что `gnome` — единственный поставщик способностей для уже
  стоящих `selkies`/`x11vnc`/`wallpaper`, и без него `remove` отказывает с 67
  `deps.dependents` (cream `internal/engine/remove.go:89-98`). Обратный порядок упирается в
  конфликт `desktop-session`. Между двумя командами потребители остаются без поставщика, но их
  службы не трогаются. `remove gnome` возвращает цель загрузки и DM, пакеты остаются. Этот
  переход покрыт L-тестом (§6).

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
- `desktop`: матрица `""`/`0`/`1` × gdm3/LightDM/SDDM; снимок только при `CREAM_REASON=install`
  и точный возврат; `remove` без записи = 1.x; обновление с 1.x при пустом ключе не меняет
  отпечаток и не перезапускает DM; SDDM + `1` → 1 после прочих ручек. **Р1:** «1.x с
  `DESKTOP_AUTOLOGIN=1` → upgrade (маркер `legacy`) → configure на загрузке → remove:
  автологин выключен»; то же с `DESKTOP_AUTOLOGIN=` вместо `remove`.
- `lib/gdm-wayland.sh`, `gdm-xorg`, `gnome`: четыре исходных состояния строки, ссылка вместо
  файла (не пишем); возврат побайтно; 10 только в live и только при изменении.
- `selkies`, `x11vnc`: `*_USER` нет в passwd → 78; **`*_USER=gdm`** (и root, uid < 1000,
  uid ≥ 65534) → 78 в обёртке, а `configure` экземпляр не запускает (Р3); `auto` → дисплей из
  библиотеки, и при незаданном ключе — запасное значение обёртки (Р4); сохранённое `:0` не
  меняется; `install` в live без Xorg или без включённого DM → 20, `configure` → 1 (Р2).
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
- Переход с обхода (Р2): `gnome` + `selkies` → `cream remove --force gnome && cream install
  existing-desktop` → граф цел, `selkies` установлен, `cream check` без ошибок графа.
- Ночью (`LIVE_NIGHTLY_ONLY`) графический стек — `gnome`, `xfce4`, `lxde`, `selkies`, `x11vnc`,
  `vino-vnc`, `wallpaper`, `existing-desktop`, `gdm-xorg` — получает `ubuntu-24.04` в
  `LIVE_DISTROS` (сейчас только debian-12).

**Ночная сборка (build-фаза).** `cream install` графического стека amd64 (`gnome`, `desktop`,
`selkies`, `x11vnc`, `existing-desktop` на образе с готовым gdm3) под `virt-customize` на
облачном образе ubuntu-24.04 из снимка **настоящего** каталога. Где запускать — открытый
вопрос 1 (§11).

**P — ручная приёмка на ВМ** (amd64). Результаты — новый runbook
`docs/runbooks/05_existing-desktop-acceptance.md` с датой, ISO и версиями. Каждый пункт
фиксирует **замер**, а не ожидание.

| # | Машина | Что замерить и проверить |
|---|---|---|
| P1 | Ubuntu 24.04 Desktop, GDM, автологин | Тип сеанса до и после `gdm-xorg`; дисплей сеанса после перезагрузки; заполнен ли `Display` в logind; путь `xs_find_display`; Selkies и x11vnc показывают стол; 78 без цикла на Wayland; `remove gdm-xorg` возвращает `custom.conf` побайтно; автологин не тронут ни одним шагом; пакет и работа `vino`; подхват обоев dconf; `selkies --help` не знает `SELKIES_USER` |
| P2 | то же без автологина | **На каком дисплее сеанс после ручного входа в GDM (`:0` или `:1`)** и с каким `Display`; ожидание до входа с диагнозом; вход другого пользователя — диагноз; выход и вход — Selkies возвращается |
| P3 | Xubuntu 24.04, LightDM, ± автологин | Дисплей, authority, `Display`; Selkies и x11vnc; `desktop` с пустым ключом не трогает `autologin-user` |
| P4 | Kubuntu 24.04, SDDM | **Тип сеанса по умолчанию**; authority сеанса; Selkies на X11-сеансе Plasma; `desktop DESKTOP_AUTOLOGIN=1` → явный отказ |
| P5 | Ubuntu 24.04 Server без DM | `existing-desktop` → 1 с понятным текстом. Сразу после этого `selkies`: граф **проходит** из-за записи `failed` (§9), а `install` отказывает сам — 20 → cream 68 с текстом «нет менеджера входа» (Р2). После `cream remove existing-desktop` — `selkies` → 67 `deps.requires`. Записать фактические коды |
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
| Ждать исправления cream (§9) до выпуска | Блокирует выпуск каталога релизом cream. Проверка в `install`/`configure` потребителей дешевле и полезна и после исправления (Р2) |
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

Выпуск исправления cream **не ждёт** (Р2): потребители проверяют машину сами (§4.4).

- **Issue в cream: неудачная запись даёт способности** — [cream#56](https://github.com/iamletenkov/cream/issues/56) (2026-11-12, ссылки сверены с main e400a4b).
  - Что: запись со статусом `failed` или `skipped` участвует в графе как поставщик и как сторона
    конфликта.
  - Где:
    - `internal/engine/install.go:468-486` — дерево ставится до хука;
    - `internal/engine/install.go:536-546` — при сбое хука запись сохраняется со статусом
      `failed`;
    - `internal/engine/installed.go:16-30` (`Installed()`) — все записи без фильтра статуса;
    - `internal/engine/upgrade.go:545-562` (`installNodes`) — узлы графа из всех записей с
      читаемым деревом;
    - `internal/resolve/graph.go:205-216` (`checkRequires`) — поставщик ищется среди них.
  - Следствие: после отказа `existing-desktop` `cream install selkies` проходит граф, а
    `cream install gnome` упирается в `conflict.capability` с неудачной записью.
  - Ожидание: не считать поставщиком и стороной конфликта запись `failed` или `skipped`
    (или явно описать в спеке cream, почему считать).
- **`cream assume`** остаётся зарезервированным; спека его не требует.

## 10. Рулинги после skeptic (2026-11-12)

Отзыв skeptic — в рабочих материалах Stvor. Рулинги контроллера внесены в §3–§9.

- **Р1 (риск 1: `desktop` записывал своё как «прежнее»).** Новый `desktop/hooks/upgrade`: при
  `CREAM_PREV_VERSION` < 2 пишет маркер `legacy` без снимка. `remove` и пустой ключ при
  `legacy` выключают автологин, как 1.x. Снимок — только при `CREAM_REASON=install`. В H — тест
  «1.x с `DESKTOP_AUTOLOGIN=1` → upgrade → remove: автологин выключен» (§4.3, §5, §6).
- **Р2 (риск 2: граф cream расходится с S5, P5 и миграцией).** Выпуск не ждёт исправления
  cream. `install`/`configure` у `selkies` и `x11vnc` на живой машине сами проверяют Xorg и DM и
  отказывают понятным кодом. S5 и P5 описывают фактическое поведение графа, подсказка S5 —
  «сначала `cream remove existing-desktop`». Миграция — `cream remove --force gnome && cream
  install existing-desktop`, с тестом. Находка про `installNodes`/`Installed()` — отдельный
  пункт «issue в cream» (§9) (§3 S5, §4.4, §5, §6).
- **Р3 (риск 3: системная учётка DM в `*_USER`).** `SELKIES_USER`/`X11VNC_USER` — код 78 для
  uid < 1000 и ≥ 65534 (правило `get_cloud_user.sh:46`). Проверка и в обёртке, и в
  `configure`, H-тест на `gdm` (§4.4, §6).
- **Р4 (x11vnc `auto`).** `auto` при незаданном ключе работает через запасное значение в
  обёртке (`run-x11vnc.sh:110`), а не через умолчание манифеста: cream кладёт в
  `EnvironmentFile` только явные ключи. Параллельный PR `fix/selkies-effective-env` это
  меняет, и спека с ним сходится (§4.4).
- **П13 (ревью волны 1: rootless GDM без `:N` в argv; security-ревью).** Дисплей Xorg пользователя
  ищется по `:N` в argv, иначе по его слушающему сокету `/tmp/.X11-unix/X<N>` (привязан к
  процессу), и только в последнюю очередь по `/tmp/.X<N>-lock` с его pid. Lock берётся, если его
  владелец root или uid этого Xorg, запись группе и остальным закрыта и это не ссылка: `/tmp`
  пишут все, подложенный lock не должен увести на чужой X. Найденный дисплей (и `:0` запасного
  пути 2) подтверждает только authority самого пользователя, файл его uid без записи для других;
  `-auth` чужого Xorg не подтверждение. Дисплей без контроля доступа (`xhost`: «access control
  disabled») подтверждением не считается; без `xhost` дисплей не берётся. `xs_find_authority`
  для уже известного дисплея — прежний список кандидатов. `ss -xlp` не используется.
  `xs_seat0_active` печатает и класс сеанса. Подпуть и заполненность `Display` фиксируются в
  P1/P2 (§4.2).
- **П15 (`xhost` у потребителей).** `x11-xserver-utils` (`xhost`) — зависимость каждого
  потребителя `lib/x-session.sh`: `existing-desktop`, `selkies`, `x11vnc`. Её ставит их `install`
  (у `selkies` и `x11vnc` — рядом с `x11-utils` и `xauth`). Без `xhost` контроль доступа не
  проверить, и дисплей запасных путей не принимается (П13). Для `existing-desktop` это
  единственное, что он ставит: уточнение к §4.1 «расширение ничего не меняет» — Xorg, DM и их
  настройки он по-прежнему не трогает.
- Вопрос о раннере ночной сборки остаётся открытым вопросом к владельцу (§11).

## 11. Открытые вопросы к владельцу

1. **Где гонять ночную build-сборку графического стека** (`virt-customize` на облачном образе
   ubuntu-24.04)? На hosted `ubuntu-latest`, если там есть KVM для libguestfs (не проверено),
   или на self-hosted раннере? Без ответа нельзя написать задачу 7. Остальные задачи от этого
   не зависят.
   **Решение владельца 2026-11-12:** не ночью. Build-сборка идёт в PR, которые меняют затронутые
   расширения или общие `lib/` (фильтр путей в workflow), и вручную; PR выпуска (release-please) и PR
   несвязанных расширений её не запускают. Раннер — self-hosted на .93 (`/dev/kvm` есть).
