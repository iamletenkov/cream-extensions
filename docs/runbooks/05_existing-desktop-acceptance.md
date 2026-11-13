# 05. Ручная приёмка `existing-desktop` (P1–P7)

Ручная приёмка готового стола машины: план
[2026-11-12-existing-desktop](../plans/2026-11-12-existing-desktop.md), Task 20. В runbook
записано то, что намерено на машине, а не то, что ожидалось. Повторять нужно после правки
`lib/x-session.sh`, обёрток `selkies`/`x11vnc`, `existing-desktop` и `gdm-xorg`, но только
затронутые пункты.

## Стенд

- ВМ amd64 на тестовой PVE-ноде: q35, VGA `std`, 3–4 ГБ, cloud-init. Перед каждым P
  снимается снимок ВМ, после приёмки ВМ удаляются.
- **Отклонение от плана:** вместо ISO использованы облачные образы с метапакетом стола.
  Ubuntu 24.04: `noble-server-cloudimg-amd64`, serial `20261017`, к нему
  `ubuntu-desktop-minimal`, `xubuntu-desktop-minimal` или `kubuntu-desktop`. Debian 12:
  `debian-12-genericcloud-amd64`, к нему `xfce4 lightdm xserver-xorg`. Стол от метапакета
  тот же, что ставит установщик. Отличается ядро: у облачного нет DRM-драйверов, поэтому
  ставилось обычное ядро (Ubuntu — HWE `7.0.0-43-generic`, Debian — `6.1.0-54-amd64`).
  Без KMS GDM запускает Xorg от root, а не от пользователя; это отдельный замер P1(а).
  Автологин GDM настраивался так же, как это делает установщик Ubuntu:
  `AutomaticLoginEnable=true`, `AutomaticLogin=<user>` в `/etc/gdm3/custom.conf`.
- cream `1.4.0` (пин `tools/cream-pin.env`). Каталог — снимок `5.24.0` из головы ветки
  волны 5, коммит `f6d2bff`, sha256 `45a3a3b5…ee6a6`. Подключён по
  [runbook 01](01_release-catalog.md). Повторная приёмка P1, P2, P4 после П27б — снимок из
  коммита `8af8a6e`, sha256 `ef8be882…4b653`.
- Версии расширений: `existing-desktop` 1.0.0, `selkies` 7.0.0, `x11vnc` 6.0.0,
  `gdm-xorg` 1.0.0, `desktop` 2.0.0, `wallpaper` 3.0.3, `vino-vnc` 5.1.1, `kiosk` 4.1.1,
  `cloud-user` 1.0.2, `apt-guard` 1.0.1.
- Стол: Ubuntu 24.04.5 — gdm3 `46.2-1ubuntu1~24.04.9`, gnome-shell
  `46.0-0ubuntu6~24.04.17`, lightdm `1.30.0-0ubuntu14`, xfce4-session `4.18.3-1build2`,
  xserver-xorg-core `2:21.1.12-1ubuntu1.9`. Debian 12 — lightdm `1.26.0-8`,
  xfce4-session `4.18.1-1`, xserver-xorg-core `2:21.1.7-3+deb12u13`.
- Пароли `selkies`/`x11vnc` генерировались на машине в файлы root 0600 и передавались
  через `--params-file`. Ни в журнал, ни сюда они не попали. Снимки экрана — через
  `vncdotool` на `127.0.0.1:5900` и монитор QEMU (`screendump`).

## Итоги

| # | Машина | Итог |
|---|---|---|
| P1 | Ubuntu 24.04, GDM, автологин | по плану после П27б: дисплей Xorg GDM находится по его сокетам (повторная приёмка ниже). Xorg от root без KMS — известное ограничение |
| P2 | то же, без автологина | по плану после П27б: сеанс на `:1` находится сам. Ожидание и диагнозы по плану |
| P3 | Xubuntu 24.04, LightDM, ± автологин | по плану |
| P4 | Kubuntu 24.04, SDDM | по плану после П27б: authority `/tmp/xauth_*` находится, журнал ожидания — раз в 5 минут |
| P5 | Ubuntu 24.04 Server без DM | по плану, с замечанием о порядке снятия |
| P6 | железо с DM без монитора | **не замерено**: железа нет |
| P7 | Debian 12, Xfce + LightDM | `kiosk` и `wallpaper` работают по отдельности. Вместе на Xfce не сочетаются (см. ниже) |

## P1. Ubuntu 24.04, GDM, автологин

**а) Без KMS** (облачное ядро `6.8.0-149`, нет `/dev/dri`). Сеанс `Type=x11`, `Display=`
пустой. Xorg от **root**: `Xorg vt2 -displayfd 3 -auth /run/user/1000/gdm/Xauthority …`.
`/tmp/.X0-lock` нет, сокет `X0` принадлежит root.
- `existing-desktop` → 0. В диагнозе: X-сессии `ubuntu-xorg.desktop ubuntu.desktop`, gdm3
  active, «WaylandEnable не задан — сеансы GNOME на Wayland», подсказка про `gdm-xorg`,
  автологин `ubuntu`, `seat0: ubuntu, x11, -, active`.
- `selkies`, `x11vnc` (`--with-deps`) → 0. Обёртки ждут: «на seat0 сеанс ubuntu (x11) —
  его дисплей пока не открывается». Цикла нет, `NRestarts=0`.
- С явным `SELKIES_DISPLAY=:0` и `X11VNC_DISPLAY=:0` всё работает. x11vnc запущен как
  `-display unix:0 -auth /run/user/1000/gdm/Xauthority` и отдаёт снимок стола. Selkies
  пишет «X11 (unix:0) capture», HTTP без пароля 401, с паролем 200.

**б) С KMS** (HWE `7.0.0-43`, bochs). По умолчанию сеанс `Type=wayland`.
- `existing-desktop` → 0, «сеанс seat0 на Wayland — selkies и x11vnc его не захватят».
- `selkies@ubuntu` и `x11vnc@ubuntu` завершаются с кодом 78 и подсказкой (`gdm-xorg`,
  войти заново, `systemctl restart`). `NRestarts=0`, цикла нет.
- `cream install --accept-risk gdm-xorg` → cream 0, `reboot_required: true`. Хук
  вернул 10. В `custom.conf` добавилась только строка `WaylandEnable=false`, строки
  автологина не тронуты.
- После перезагрузки: `Type=x11`, `Display=` пустой. Xorg **от пользователя**
  `ubuntu`: `Xorg vt2 -displayfd 3 …`. Сокет `X0` принадлежит `ubuntu`, **`/tmp/.X0-lock`
  нет**. Обёртки ждали «его дисплей пока не открывается»: это было **расхождение 1**,
  закрыто П27б (см. «Повторная приёмка»).
- С явным `:0` x11vnc и Selkies показывают стол, снимок снят.
- В `selkies --help` (1001 строка) `SELKIES_USER` не упоминается ни разу.
- vino: в noble есть `vino 3.22.0-6ubuntu5`. `vino-vnc` с `VINO_PORT=5901` → 0. После
  перезагрузки `vino-server` слушает порт и снимок через него снимается. Решение П10:
  vino-vnc 5.1.2 ночью гоняется и на ubuntu-24.04.
- `wallpaper` → 0. `gsettings picture-uri` сразу показывает `dst_1080.jpg`, но на
  экране обои меняются только после перезагрузки или повторного входа.
- `cream remove gdm-xorg` → 0. `custom.conf` побайтно совпадает с копией до `gdm-xorg`
  и с исходной, автологин на месте. После перезагрузки сеанс снова Wayland, юниты
  завершаются с 78, `NRestarts=0`.

## P2. Без автологина

- Перед замером ВМ откатывалась к снимку `p1-base`, ставился `AutomaticLoginEnable=false`
  и заводился второй пользователь `bob`. Дальше `existing-desktop`, `selkies`, `x11vnc` (все
  0) и `gdm-xorg`, затем перезагрузка.
- До входа: greeter Xorg от `gdm` на `:0`, сеанс `c1` `Class=greeter`. Обёртки пишут
  «на seat0 экран входа (greeter) — жду вход 'ubuntu'» каждые 5 минут (132 с, 434 с,
  738 с). `NRestarts=0`.
- **После ручного входа `ubuntu` сеанс на `:1`, а не на `:0`.** Xorg от `ubuntu`:
  `Xorg vt2 -displayfd 3 -auth /run/user/1000/gdm/Xauthority`, сокет `X1`. greeter-Xorg
  `:0` завершился. `Display=` пустой, lock-файла нет. Обёртки ждали «его дисплей пока не
  открывается»: то же **расхождение 1**, закрыто П27б. Обход явным `:0` здесь не помог бы,
  нужен был `:1`.
- Вход `bob` после выхода `ubuntu`: x11vnc пишет «на seat0 сеанс bob (x11), x11vnc ждёт
  ubuntu: sudo cream set x11vnc X11VNC_USER=bob».
- `cream set selkies SELKIES_USER=gdm`: хук `apply` → 78, cream → 79 `hook.failed`.
  Текст: «uid 124 вне 1000..65533 — системная учётка … Selkies остановлен». После
  возврата `SELKIES_USER=ubuntu` → 0, служба active.
- Выход и вход (повторная приёмка после П27б): `loginctl terminate-session` — порт 8080
  закрылся через 17 с, обе службы перезапустились один раз (`NRestarts=1`) и ждут вход.
  Новый вход — Enter в 17:38:40, Selkies и x11vnc слушают в 17:38:49, через **9 с**,
  снова на `:1` по сокетам Xorg. Снимок через x11vnc снят, Selkies 401/200.

## P3. Xubuntu 24.04, LightDM

- greeter: Xorg от root `Xorg -core :0 -seat seat0 -auth /var/run/lightdm/root/:0 …`,
  `/tmp/.X0-lock` есть, `Display=:0`.
- `existing-desktop` → 0 (lightdm active, X-сессии `xfce.desktop xubuntu.desktop`,
  «автологина нет», «seat0: экран входа (lightdm)»). `selkies` и `x11vnc` → 0. Обёртки
  ждут вход и пишут про greeter.
- **Без автологина:** через 1 с после ввода пароля появился сеанс `c2` `Display=:0`,
  через 11 с оба сервера слушают. Путь в журнале: «дисплей :0: сеанс c2 пользователя
  ubuntu на seat0 (logind Display)». authority — `/home/ubuntu/.Xauthority` (первый
  кандидат). x11vnc `-display unix:0`, снимок стола снят. Selkies: 401 без пароля, 200 с
  паролем.
- Автологин задан руками (`[Seat:*] autologin-user=ubuntu`). Затем
  `install --with-deps desktop` с пустым `DESKTOP_AUTOLOGIN` → 0. sha256 всех файлов
  `/etc/lightdm` до и после совпадают: `autologin-user` не тронут.
  `cream run existing-desktop status`: «автологин: ubuntu», «seat0: ubuntu, x11, :0, active».
- **С автологином** после перезагрузки на 18-й секунде загрузки сеанс `c1` `Display=:0`,
  путь logind Display, authority `~/.Xauthority`. Снимок стола Xubuntu снят, Selkies
  401/200.

## P4. Kubuntu 24.04, SDDM

`kubuntu-desktop` (Plasma `5.27.12-0ubuntu0.1`, sddm `0.20.0-2ubuntu4.2`), ядро HWE
`7.0.0-43`.
- **Тип сеанса по умолчанию — X11.** `kubuntu-desktop` в noble ставит только
  `/usr/share/xsessions/plasma.desktop`. Каталога `/usr/share/wayland-sessions` нет,
  `plasma-workspace-wayland` не установлен.
- greeter: Xorg от root `Xorg -nolisten tcp -background none -seat seat0 vt2 -auth
  /run/sddm/xauth_… -noreset -displayfd 16`. `/tmp/.X0-lock` нет, но SDDM заполняет
  `Display=:0` у сеанса.
- `existing-desktop` → 0 (sddm active, X-сессия `plasma.desktop`, «автологина нет»).
  `selkies` и `x11vnc` → 0.
- `install --with-deps desktop DESKTOP_AUTOLOGIN=1`: configure → 1, cream → 79
  `hook.failed`. Текст: «автологин SDDM не поддержан: /etc/sddm.conf.d/, вручную
  (DESKTOP_AUTOLOGIN= — не управлять)». `/etc/sddm.conf.d` не тронут (sha256 до и после).
  `cream run existing-desktop status`: «автологина нет», «seat0: экран входа (sddm)».
- После ручного входа: сеанс `Display=:0`, `Type=x11`, путь logind Display. **Authority
  не находится**: SDDM 0.20 кладёт её пользователю в `/tmp/xauth_XXXXXX` (0600, владелец
  пользователь, `XAUTHORITY` сеанса). В `/run/user/<uid>/xauth_*` и `~/.Xauthority` её
  нет. Обёртки ждут и **каждые 5 секунд** пишут строку «дисплей :0: сеанс 12 … (logind
  Display)», 38 строк за 3 минуты. Это были расхождения 2 и 3, закрыты П27б.
- Когда пользователь сам копирует `/tmp/xauth_*` в `~/.Xauthority`, оба сервера
  поднимаются через 5 с: authority `~/.Xauthority`, Selkies «X11 (unix:0) capture», снимок
  стола Plasma через x11vnc снят, Selkies 401/200. Значит, на X11-сеансе Plasma Selkies
  работает, дело только в поиске authority.

## P5. Ubuntu 24.04 Server без DM

Облачный образ без стола (serial `20261017`, ядро `6.8.0-147`).

| Шаг | Код | Что сказано |
|---|---|---|
| `install existing-desktop` | 79 (хук 1) | нет Xorg, нет менеджера входа, нет X-сессии; «неудачная запись держит конфликт desktop-session: сначала `cream remove existing-desktop`». Запись `failed` |
| `install --with-deps selkies` | 68 (хук 20) | «нет X-сервера / менеджера входа: поставьте стол или `existing-desktop`». Записи: `cloud-user` installed, `selkies` **skipped** |
| `remove existing-desktop` | 67 `deps.dependents` | «existing-desktop нужно установленным расширениям: selkies» — пропущенная запись `selkies` держит неудачную `existing-desktop` |
| `remove selkies`, затем `remove existing-desktop` | 0, 0 | «стол принадлежит машине — снимать нечего» |
| `install --with-deps selkies` | 67 `deps.requires` | «selkies требует способность x11-server, а её никто не даёт». Так же у `x11vnc` |

Порядок снятия на машине без стола такой: сначала пропущенные потребители (`selkies`,
`x11vnc`), потом `existing-desktop`. Подсказка «сначала `cream remove existing-desktop`»
упирается в `deps.dependents`, если `selkies` уже пытались поставить. Это строка для
`docs/known-issues.md`, а не дефект кода: отказ cream верен.

## P6. Железо с DM без монитора

Не замерено: подходящего железа нет. То же записано в README `existing-desktop`.

## P7. Debian 12, Xfce + LightDM

- greeter: Xorg от root `:0`, lock есть, `Display=:0`.
- `existing-desktop` → 0 (X-сессии `lightdm-xsession.desktop xfce.desktop`, «автологина
  нет»). `install --with-deps desktop DESKTOP_AUTOLOGIN=1` → 0. Из `/etc/lightdm`
  изменился только `lightdm.conf` (`autologin-user=debian`, `autologin-user-timeout=0`).
- `wallpaper` → 0. После перезагрузки автологин `debian`, `Display=:0`, на экране обои
  `dst_1080.jpg` (снимок монитора QEMU).
- **`kiosk` после `wallpaper` → 67 `conflict.file_unowned`**: файл
  `/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml` уже есть и не
  принадлежит ни одному расширению. Его записал хук `wallpaper`, а `kiosk` раскладывает
  такой же файл через `files:`. При этом зависимость `apt-guard` успела встать.
- После `remove wallpaper` (0, файл снят): `install --accept-risk --with-deps kiosk` →
  0, `kiosk-chromium@debian` active, `NRestarts=0`. Chromium на весь экран. Страница по
  умолчанию `KIOSK_URL` отдаёт GitHub 404: репозиторий закрытый.
- `wallpaper` после `kiosk` → 0 с предупреждением «xfce4-desktop.xml уже есть и не наш —
  обои Xfce не задаю».
- Вывод: на Xfce `kiosk` и `wallpaper` вместе не сочетаются. Порядок `wallpaper → kiosk`
  кончается отказом, обратный — обоями без эффекта. Под киоском обоев не видно, так что
  вреда нет. Но это вопрос каталога, не `existing-desktop`: с `xfce4` вместо
  `existing-desktop` будет то же самое.

## Расхождения — закрыты рулингом П27б

Три расхождения первого прогона закрыты fix-задачей по `lib/x-session.sh` и обёрткам
(рулинг П27б плана, коммит `8af8a6e`).

1. **GDM + Xorg: дисплей не находился сам** (P1б, P2). Xorg, который GDM запускает с
   `-displayfd 3`, не создаёт `/tmp/.X<N>-lock` ни от root, ни от пользователя, а logind
   не заполняет `Display` у x11-сеанса GDM. Запасной путь 1 по П27 требовал доверенный
   lock с pid Xorg, поэтому не срабатывал никогда: посылка П13 («GDM… `:N` по lock»)
   замером не подтвердилась. Теперь без lock-файла `N` берётся из собственных слушающих
   сокетов Xorg пользователя: ровно один `N`, второй `N` или inode в двух строках
   `/proc/net/unix` — отказ.
2. **SDDM 0.20: authority пользователя в `/tmp/xauth_*`** (P4). Её не перебирали ни
   `xs_find_authority`, ни `_xs_confirm`: там был только `/run/user/<uid>/xauth_*`.
   Теперь `/tmp/xauth_*` — кандидат, если это обычный файл uid сеанса с правами не шире
   `0600`.
3. **Журнал каждые 5 секунд** (P4). Когда дисплей найден, а authority нет,
   `xs_find_display` писал строку на каждом опросе. Теперь обёртки дают библиотеке
   говорить одной попыткой в 5 минут, а неудачу authority библиотека называет.

## Повторная приёмка P1, P2, P4 после П27б

Снимок каталога `5.24.0` из коммита `8af8a6e`, sha256 `ef8be882…4b653`. ВМ откатывались к
снимкам `p1-base` и `p4-base` (стол есть, cream ещё нет). `existing-desktop`, `selkies`,
`x11vnc` → 0 на обеих.

- **P1б** (GDM, автологин, `gdm-xorg` → 0, перезагрузка). Xorg пользователя `ubuntu`
  `Xorg vt2 -displayfd 3 …`, `Display=` пустой, lock-файла нет. Обе обёртки на 132-й
  секунде загрузки: «дисплей :0: Xorg 1330 пользователя ubuntu, сокеты Xorg (lock-файла
  нет)», authority `/run/user/1000/gdm/Xauthority`. Снимок стола через x11vnc снят,
  Selkies: без пароля 401, с паролем 200. `NRestarts=0`.
- **P2** (`AutomaticLoginEnable=false`, перезагрузка). До входа — greeter Xorg от `gdm` на
  `:0`, обёртки пишут «на seat0 экран входа (greeter)» один раз за опрос в 5 минут. После
  ручного входа Xorg `ubuntu` на `:1`, lock-файла нет. Через 2 с обе обёртки нашли
  «дисплей :1: … сокеты Xorg (lock-файла нет)», чужой `:0` greeter-а не тронут. Снимок
  через x11vnc снят, Selkies 401/200.
- **P4** (SDDM, ручной вход). `Display=:0` из logind, authority сеанса
  `/tmp/xauth_fhGeUB` (0600, владелец `ubuntu`). Обе обёртки подняли серверы через 5 с
  после входа с authority `/tmp/xauth_…`. Снимок стола Plasma снят, Selkies 401/200.
  За время до входа строк «logind Display» — по одной на обёртку.
- **P4, подделка прав на живой машине.** `chmod 644 /tmp/xauth_…` и рестарт `selkies@ubuntu`:
  за 65 с — одна строка «ни одна authority пользователя ubuntu его не открывает», одна
  строка ожидания, порт 8080 не открыт. После `chmod 600` Selkies поднялся на следующем
  опросе, путь найденного дисплея записан один раз. `NRestarts=0`.

P1(а) (Xorg от root без KMS) не менялся. Это известное ограничение: fd Xorg от root
обёртке не видны, нужен явный `:N`, см. `docs/known-issues.md`.
