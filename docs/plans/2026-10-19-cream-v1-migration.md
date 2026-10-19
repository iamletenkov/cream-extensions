# План: перевод каталога cream-extensions на cream/v1 (шаг 3 §16 спеки cream)

Дата: 2026-10-19. Ляжет в `cream-extensions` как `docs/plans/2026-10-19-cream-v1-migration.md` (строка в `docs/README.md`).
Классификация — **архитектурная**: меняется формат всех 39 расширений, раскладка в госте, общий код `lib/`, контракт
с bisquite. Спека — `cream:docs/specs/2026-10-18-cream-core.md` (§4–§8, §16 шаг 3, §17); опись —
`cream:docs/research/2026-10-18-bisquite-extension-system-inventory.md` (§6 — таблица расширений, §8 — имена bisquite).

## Progress Tracker
Исполнителю: после выполнения отметь свою задачу `- [x]` в том же коммите.

- [x] Task 1: [cream] стадии configure `early`, `cloud-user`, `graphical` (§6.4), `cream resolve --installed`, правка спеки по `desktop`
- [x] Task 2: конвертер `tools/convert-v1.py` (§4.7) с тестом на фикстурах
- [x] Task 3: обвязка проверок — автообнаружение тестов расширений, живой стенд `tools/live-test.sh`, гейт имён bisquite
- [x] Task 4: [cream] статическая проверка графа в `cream validate --catalog` и выпуск cream 1.1.0
- [x] Task 5: библиотека `cloud-user` (`kind: library`) + `yq`
- [x] Task 6: библиотека `l4t` (`kind: library`) + `btop` + `firefox`
- [x] Task 7: пин cream 1.1.0, линт хуков вместо `validate-extensions.py`, конвенция cream/v1 в документации и `new-extension.sh`
- [x] Task 8: `docker`
- [x] Task 9: `locale` + `can`
- [x] Task 10: `firewall` (стадия `early`, `inet cream`, `CREAM-INPUT`, CLI → действия)
- [x] Task 11: `network-manager` + `cloud-growroot` + `nocloud-cidata`
- [x] Task 12: новое расширение `desktop` (из `lib/bisquite-desktop` и `lib/knobs/desktop`)
- [x] Task 13: `gnome` + `xfce4` + `lxde`
- [ ] Task 14: `cloud-user-desktop` + `wallpaper`
- [ ] Task 15: `code-server`
- [x] Task 16: `kiosk` + `chromium-kiosk`
- [ ] Task 17: `selkies`
- [x] Task 18: `x11vnc` + `vino-vnc`
- [ ] Task 19: `rustdesk` + `jetson-stats`
- [x] Task 20: `nvidia` + `nvidia-container-toolkit`
- [x] Task 21: `nvidia-jetpack`
- [x] Task 22: `cuda-toolkit` + `tensorrt` + `l4t-gstreamer`
- [x] Task 23: `l4t-opencv` + `l4t-pytorch` + `l4t-tensorflow`
- [x] Task 24: `l4t-board-fdt` + `l4t-boot-verify`
- [x] Task 25: `l4t-kernel-kvm`
- [ ] Task 26: `sensing-gmsl2-camera` + `can-usb`
- [ ] Task 27: `pixelflux-tegra` + `pixelflux-v4l2m2m`
- [ ] Task 28: уборка переходного — `lib/`, layout 2 в инструментах, `extensions/openwrt/`, документация
- [ ] Task 29: Финальная интеграция + `make ci`, выпуск каталога 5.0.0

Задачи с пометкой **[cream]** исполняются в репозитории `cream`, остальные — в `cream-extensions`.

## Предусловия (проверить до волны 1)
1. **Пилот в `main`, каталог 4.0.0 выпущен** (смешанный: `teleport`, `stvor-agent` — cream/v1, остальное — layout 2;
   `tools/cream-validate.sh`, `tools/catalog-snapshot.sh`, `cream-catalog.yaml` с `roots: [extensions/debian]`).
   Все ветки задач — от свежего `main`.
2. cream `v1.0.0` выпущен, пин `tools/cream-pin.env` = 1.0.0 (есть).
3. В `cream-extensions` подъём пина в bisquite выключен (`BISQUITE_BUMP_ENABLED` не задан): промежуточные состояния
   `main` до bisquite не доезжают. bisquite сидит на пине каталога 3.3.0 (layout 2).

## Рулинги этого плана (контроллер, в рамках спеки и решений владельца)
| № | Решение | Почему |
|---|---|---|
| Р1 | Переходной совместимости нет: расширение переводится целиком, layout 2 рядом с ним не остаётся; мажор каждого расширения +1, каталог — 5.0.0 | решение владельца (реальных машин нет), спека §4.7 |
| Р2 | nft-таблица `inet bisquite` → `inet cream`, цепочка `BISQUITE-INPUT` → `CREAM-INPUT` сейчас, без миграции правил | решение владельца, спека §19 В5 |
| Р3 | `extensions/openwrt/` не переводится; удаляется в Task 28. bisquite забирает файлы по тегу `v3.3.0` (его текущий пин) — удаление здесь его не блокирует | решение владельца, спека §19 В3 |
| Р4 | `x11vnc`, `vino-vnc`: `secret: hook` (зарезервирован в 1.0) → **`secret: file`**, производный файл (`/etc/x11vnc/passwd`, `vnc-password.b64`) строит `configure` из `CREAM_SECRETS_FILE`. Деградация по безопасности нулевая: rfbauth — DES с известным ключом, b64 — открытый текст, т. е. производные файлы и так равносильны паролю; хранение 0600 root то же. Поэтому `hooks.secret` cream **не нужен** | не ждать минорной версии ради фикции защиты |
| Р5 | `desktop` — стадия **`system`** с `after: [cloud-init.service, guestfs-firstboot.service]` и `before: [display-manager.service, gdm.service, gdm3.service, lightdm.service]`, а не `graphical` | нынешний `bisquite-desktop.service` обязан отработать **до** менеджера входа (автологин); стадия `graphical` спеки — `After=display-manager`, это ломает автологин. Спека §4.5/§6.4 правится в Task 1. Работает на cream 1.0 |
| Р6 | Стадии `early`/`cloud-user`/`graphical` не эмулируются на `system` + `after`/`before`: `cloud-user` даёт цикл с `cloud-final` (урок описи), `graphical` через `multi-user.target.wants` + `After=display-manager` тянет DM раньше `multi-user.target`, `early` невозможен без `DefaultDependencies=no`. Такие расширения ждут cream 1.1.0 (Task 1, 4) | без деградации порядка загрузки |
| Р7 | CLI расширений (`bisquite-firewall`, `bisquite-sensing-camera-ctl`, `bisquite-desktop`) → **действия** (`cream run <ext> …`); юниты и udev зовут файлы по абсолютному пути `/opt/cream/ext/<ext>/…`. Поле `bin` (зарезервировано) не нужно | спека §4.6 |
| Р8 | Ключи настроек без префикса `BISQUITE_` (`CREAM_*` занято окружением хука): `BISQUITE_SELKIES_ALLOW_NO_AUTH` → `SELKIES_ALLOW_NO_AUTH` и т. п.; тестовые переменные `BISQUITE_FIREWALL_*`, `BISQUITE_RUSTDESK_FOLLOWUP` → `<EXT>_TEST_*`/`<EXT>_*`; `BISQUITE_CONF_ROOT` → `CREAM_ROOT`. Таблица переименований копится в README расширения и в описании PR → вход для плана bisquite (примеры VMFILE, `firstboot-commands`) | спека §6.3 (`CREAM_*` зарезервированы) |
| Р9 | Хук `remove` обязателен у расширений с `targets.live: yes`; у `confirm`/`no` — по возможности, иначе README описывает `cream remove --forget` | без хука `remove` отказывает (§6.5); живой `yes` подразумевает обратимость |
| Р10 | `upgrade`-хуков не пишем: без них cream зовёт `install` с `CREAM_PREV_VERSION`, а install идемпотентен | машин с прежней версией нет |
| Р11 | Перезагрузка — код 10. Код 20 («нет устройства/ядра/GPU/L4T», §6.2) возвращает **только хук `install`**; `configure` при отсутствии DM, кодера или устройства пишет предупреждение в stderr и выходит 0 (рулинг контроллера, без изменений в cream) | сбой configure на загрузке — `failed`-юнит без пользы; L ждёт 20 только от install (`--expect-skip`) |
| Р12 | Release PR release-please **не сливается** до Task 29; коммиты расширений — `feat(<ext>)!:` с `BREAKING CHANGE:`; Task 29 добавляет `Release-As: 5.0.0` | один мажор каталога, без промежуточных выпусков смешанного каталога |
| Р14 | Расширение со стадией `cloud-user` выпускается в каталоге **только с `cream: ">=1.1.1"`**; проставляют исполнители волн, использующих `cloud-user` (Task 14 `wallpaper`, 15 `code-server`, 19 `jetson-stats` и любые другие с этой стадией). `tools/lint-hooks.sh` (правило `stage-cream`) отказывает манифесту с меньшей версией; `convert-v1.py` и `new-extension.sh` ставят `>=1.1.1` сами. Пин проверок — 1.1.0 (Task 7), пока 1.1.1 не выпущен: `cream validate` откладывает такие расширения как неприменимые (`catalog.cream_newer`, не ошибка), поэтому их L-прогон и слияние ждут подъёма пина до 1.1.1 — одной правки `tools/cream-pin.env` (версия и две суммы из `SHA256SUMS`) | в cream 1.1.0 стадия `cloud-user` не запускается при выключенном cloud-init (найдено после выпуска 1.1.0); исправление — cream 1.1.1 |
| Р13 | Тесты расширения живут в `extensions/debian/<ext>/tests/*.sh` (снимок их не берёт), `tools/test-<ext>.sh` переезжают туда в Task 3 | у файла один владелец; `tools/check.sh` их находит сам — исполнители волн его не трогают |

## Группы, решения и проверки по расширениям
Колонки: **live** — `targets.live`; **стадия** — `hooks.configure.stage` (— нет configure); **cream** — минимальная версия;
**тесты**: V — `cream validate`; H — хуки на подменённом корне (`CREAM_ROOT`, подставные `apt-get/curl/systemctl…`);
L — живой прогон `tools/live-test.sh` в systemd-контейнере с настоящим cream; L20 — в контейнере ожидается код 20;
P — живая проверка **ожидает** (плата Jetson/ВМ с GPU вручную по README или сборка через bisquite после плана bisquite).

### Группа A — библиотеки (снимают `lib/`)
| Расширение | Задача | live | стадия | cream | depends / прочее | тесты |
|---|---|---|---|---|---|---|
| `cloud-user` (новое, `kind: library`) | 5 | — | — | 1.0 | из `lib/get_cloud_user.sh`; путь `/opt/cream/ext/cloud-user/get_cloud_user.sh`; 10 потребителей | V, H (cloud-init + yq / запасной путь), L (install потребителя тянет) |
| `l4t` (новое, `kind: library`) | 6 | — | — | 1.0 | из `lib/l4t`; потребители `l4t-gstreamer`, `l4t-opencv`, `l4t-pytorch`, `tensorrt` | V, H (`l4t_major`, `l4t_openblas_*` на фикстурах `/etc/nv_tegra_release`) |
| `desktop` (новое, `kind: extension`) | 12 | yes | `system` + before DM (Р5) | 1.0 | depends `cloud-user`; домен `desktop` из `lib/knobs/desktop`; действия `apply`, `status`, `defaults` вместо `bisquite-desktop` | V, H (порт тестов `bisquite-desktop`, если есть; иначе новые на dconf/lightdm/xfconf-фикстурах), L |

### Группа B — базовые
| Расширение | Задача | live | стадия | cream | depends / прочее | тесты |
|---|---|---|---|---|---|---|
| `yq` | 5 | yes | — | 1.0 | статический бинарь по sha256; нужен `cloud-user` | V, H, L |
| `btop` | 6 | yes | — | 1.0 | | V, H, L |
| `firefox` | 6 | yes | — | 1.0 | | V, H, L |
| `locale` | 9 | yes | — | 1.0 | свой `apply` (§8.4) | V, H, L |
| `can` | 9 | yes | — | 1.0 | свой `apply`; ядра из `/lib/modules` | V, H, L (L20 без модулей `can`) |
| `docker` | 8 | confirm | `system`, `after: [docker.service]` | 1.0 | depends `cloud-user`; `live_note`: удаляет `docker.io`/`podman-docker`/`containerd`/`runc`; `10-bisquite-iptables-raw.conf` → `10-docker-iptables-raw.conf`; RPi `cmdline.txt` — код 10 | V, H, L (`--accept-risk`) |
| `firewall` | 10 | confirm | **`early`** | 1.1 | `inet cream`, `CREAM-INPUT` (Р2); `bisquite-firewall.service` → configure; CLI → действия `status`, `reload`; `apply` = перезапуск configure; `/var/lib/cream/ext/firewall/backend`; `live_note`: policy drop может отрезать SSH | V, H (порт `tools/test-firewall.sh`), L (nft в привилегированном контейнере; iptables-legacy — подменённые списки модулей) |
| `network-manager` | 11 | confirm | — | 1.0 | `live_note`: смена сетевого стека | V, H, L |
| `cloud-growroot` | 11 | **no** | — | 1.0 | `build: exec`; на живой машине смысла нет | V, H, P (сборка через bisquite) |
| `nocloud-cidata` | 11 | **no** | — | 1.0 | `zz-bisquite-nocloud.cfg` → `zz-cream-nocloud.cfg`; `build: files` не нужен — `exec` на машине цели (§4.4) | V, H, P |

### Группа C — десктоп, киоск, удалённый доступ
| Расширение | Задача | live | стадия | cream | depends / прочее | тесты |
|---|---|---|---|---|---|---|
| `gnome`, `xfce4`, `lxde` | 13 | confirm | — (стол применяет `desktop`) | 1.0 | depends `desktop`; `conflicts.capabilities: [desktop-session]` вместо перечня имён; `set-default graphical.target` → код 10; `bisquite-desktop install` из install удаляется | V, H, L (только `xfce4` в PR; `gnome`/`lxde` — ночной прогон) |
| `cloud-user-desktop` | 14 | yes | — | 1.0 | depends `desktop`, `cloud-user` | V, H, L |
| `wallpaper` | 14 | yes | **`cloud-user`** (порядок как сейчас, без `before` DM) | 1.1 | depends `cloud-user`; requires `desktop-session` | V, H, L |
| `code-server` | 15 | yes | **`cloud-user`** | 1.1 | depends `cloud-user`; `CODE_SERVER_PASSWORD` — `secret: file`; объявление в `/etc/cream/teleport/apps.d/` (контракт `teleport`), снимается хуком `remove` | V, H, L |
| `kiosk` | 16 | confirm | **`graphical`** | 1.1 | depends `cloud-user`; `conflicts.extensions: [chromium-kiosk]`; `kiosk-chromium@.service` — `files`, `EnvironmentFile=/etc/cream/kiosk/config`; `live_note`: захват экрана | V, H, L (configure без DM — предупреждение, 0) |
| `chromium-kiosk` | 16 | confirm | `system` | 1.0 | `conflicts.extensions: [kiosk]`; сторонний репозиторий по ключу | V, H, L |
| `selkies` | 17 | yes | **`graphical`** | 1.1 | depends `cloud-user`; 3 секрета — `secret: file`; `SELKIES_ALLOW_NO_AUTH` (Р8); `selkies@.service` — `files`; apps.d как у code-server; свой `apply` | V, H, L (с `xfce4` предустановленным; configure без DM — предупреждение, 0) |
| `x11vnc` | 18 | yes | **`graphical`**, `after: [display-manager.service]` | 1.1 | depends `cloud-user`; Р4; свой `apply`; `/etc/default/bisquite-x11vnc` (legacy) удаляется | V, H, L |
| `vino-vnc` | 18 | yes | `system`, `after: [cloud-init.service]`, `before: [display-manager.service, gdm.service, gdm3.service, lightdm.service]` (по образцу Р5) | 1.0 | depends `cloud-user`; Р4 | V, H, L |
| `rustdesk` | 19 | yes | `system` | 1.0 | depends `cloud-user`; `.deb` по sha256; `/var/lib/cream/ext/rustdesk/managed` | V, H, L |

### Группа D — NVIDIA, Jetson, CUDA, L4T (в основном build-only на практике)
| Расширение | Задача | live | стадия | cream | depends / прочее | тесты |
|---|---|---|---|---|---|---|
| `jetson-stats` | 19 | yes | **`cloud-user`** | 1.1 | depends `cloud-user`; без цикла с `jtop.service` (урок в юните) | V, H, P |
| `nvidia` | 20 | confirm | — | 1.0 | amd64; модули под все ядра `/lib/modules`; blacklist nouveau → 10; нет ядер → 20 | V, H, L20, P (ВМ с GPU) |
| `nvidia-container-toolkit` | 20 | confirm | — | 1.0 | requires `container-runtime`, `gpu-driver-nvidia`; правит `daemon.json`, перезапуск docker → `live_note` | V, H, L (поверх `docker`), P |
| `nvidia-jetpack` | 21 | confirm | — | 1.0 | amd64, станция прошивки; `/opt/bisquite` в `scripts/` → `/opt/cream/ext/nvidia-jetpack`; binfmt → `systemctl restart systemd-binfmt` | V, H (порт `tools/test-nvidia-jetpack.sh`), L |
| `cuda-toolkit`, `tensorrt`, `l4t-gstreamer` | 22 | yes | — | 1.0 | arm64; `tensorrt`, `l4t-gstreamer` depends `l4t`; нет `/etc/nv_tegra_release` → 20 | V, H, P |
| `l4t-opencv`, `l4t-pytorch`, `l4t-tensorflow` | 23 | yes | — | 1.0 | depends `l4t` (opencv, pytorch); requires `cuda` | V, H, P |
| `l4t-board-fdt` | 24 | confirm | — | 1.0 | **починить перезапись бэкапа `extlinux.conf`** (§6.3 запрещает); код 10 | V, H (двойной прогон: бэкап не перезаписан), P |
| `l4t-boot-verify` | 24 | yes | — | 1.0 | `bisquite-l4t-boot-verify.service` → `l4t-boot-verify.service` (`files`, enable хуком) | V, H, P |
| `l4t-kernel-kvm` | 25 | **no** | — | 1.0 | ~3 ч сборки ядра, меняет загрузчик — только базовый образ; `timeout` хука явный | V, H (порт `tools/test-l4t-kernel-kvm.sh`), P (bisquite) |
| `sensing-gmsl2-camera` | 26 | confirm | — | 1.0 | юниты `bisquite-sensing-*` → `sensing-gmsl2-camera@`, `sensing-gmsl2-clock`; `99-bisquite-sensing-camera.rules` → `99-sensing-gmsl2-camera.rules`; CLI → действия, udev зовёт `/opt/cream/ext/…`; свой `apply`; код 10 | V, H (порт `tools/test-sensing-gmsl2-camera.sh`), P |
| `can-usb` | 26 | confirm | — | 1.0 | requires `gmsl2-camera`; сборка модулей под ядро Sensing → 10 | V, H (порт `tools/test-can-usb.sh`), P |
| `pixelflux-tegra`, `pixelflux-v4l2m2m` | 27 | yes | **`graphical`** | 1.1 | requires `web-remote-desktop`; `conflicts.extensions` друг на друга; `verify-*.service` → configure; нет кодера — предупреждение, 0; нет Tegra/V4L2 M2M в install → 20 | V, H, P |

Итого 39 переводимых расширений + 3 новых (`cloud-user`, `l4t`, `desktop`). Ждут cream 1.1.0: `firewall` (early);
`code-server`, `wallpaper`, `jetson-stats` (cloud-user); `kiosk`, `selkies`, `x11vnc`, `pixelflux-*`
(graphical) — 9 расширений. Остальные 30 + 3 новых идут на cream 1.0.

## Порядок перевода одного расширения (общий для Task 5–27)
1. **Тест первым.** `extensions/debian/<ext>/tests/test-hooks.sh`: запуск хука как у cream (`env -i`, cwd —
   копия расширения, ключи домена — переменными, `CREAM_ROOT` — подменённый корень, подставные команды в `PATH`).
   Есть `tools/test-<ext>.sh` (перенесён в Task 3) — переписать под cream/v1. Тест красный на layout 2.
2. `tools/convert-v1.py extensions/debian/<ext>` → черновик манифеста и `git mv` хуков; руками — список TODO конвертера:
   `targets.live`/`live_note` (таблица выше), стадия и `after/before`, `depends` на библиотеки, `conflicts`,
   юниты через `files` вместо `install -m`, действия вместо CLI, хук `remove` (Р9), коды 10/20 (Р11).
3. Удалить `configure-<ext>.service` и прочие самописные configure-юниты; `source …/lib/bisquite-conf` и `conf_*` →
   ключи из окружения хука, в юнитах — `EnvironmentFile=/etc/cream/<ext>/config` (+ `-/etc/cream/<ext>/secrets`);
   `lib/get_cloud_user.sh` → `"${CREAM_ROOT:-}/opt/cream/ext/cloud-user/get_cloud_user.sh"`.
4. Мажор версии, `cream: ">=1.0.0"`, `">=1.1.0"` (`early`, `graphical`) или `">=1.1.1"` (`cloud-user`, Р14); README расширения: `cream install/set/run`, пути, переименованные ключи (Р8).
5. Проверки (одна тяжёлая за раз на хосте): `make cream-validate`, `make test`, `make test-live EXT=<ext>` (если L),
   `make lint`. Гейт имён (Task 3) для расширения зелёный.
6. Коммит целыми файлами (`git add <пути>`), `feat(<ext>)!: …` + `BREAKING CHANGE:`; чекбокс задачи — в том же коммите.

**Владение файлами.** Исполнитель Task 5–27 трогает только `extensions/debian/<свои>/` (и создаёт новые каталоги своих
библиотек). `lib/`, `tools/`, `Makefile`, `cream-catalog.yaml`, `README.md`, `docs/`, `.github/` — **не заходить**:
нужна правка — остановиться и доложить контроллеру (её делает задача-владелец общих файлов волны).

## Волны (≤ 3 исполнителя, у каждого свой worktree)
| Волна | Задачи | Владелец общих файлов | Условие старта |
|---|---|---|---|
| 1 | 1 [cream], 2, 3 | Task 3 (`tools/check.sh`, `Makefile`, `.github/workflows/`) | предусловия |
| 2 | 4 [cream], 5, 6 | — (Task 4 в репозитории cream) | 1 → 4; 2, 3 → 5, 6 |
| 3 | 7, 8, 9 | Task 7 (`tools/cream-pin.env`, `tools/lint.sh`, `docs/extensions.md`, `README.md`, `tools/new-extension.sh`) | выпуск cream 1.1.0 (Task 4) → 7; 5 → 8 |
| 4 | 10, 11, 12 | — | 7 → 10 (пин 1.1); 5 → 12 |
| 5 | 13, 14, 15 | — | 12 → 13, 14 (L Task 14 — в волне 6, после слияния 13) |
| 6 | 16, 17, 18 (+ L Task 14) | — | 7; живой прогон 14, 17, 18 — поверх `xfce4` (13) |
| 7 | 19, 20, 21 | — | 8 → 20 (`nvidia-container-toolkit` поверх `docker`) |
| 8 | 22, 23, 24 | — | 6 → 22, 23; 22 → 23 (`cuda`) |
| 9 | 25, 26, 27 | — | 17 → 27 (живой — после selkies) |
| 10 | 28 → 29 | Task 28, затем 29 | все предыдущие |

**Запасной порядок при задержке cream 1.1.0.** Волны 4–9 переставляются так, чтобы сначала шли задачи без 1.1:
11, 12, 13, 19 (`rustdesk`; `jetson-stats` — позже), 20, 21, 22, 23, 24, 25, 26, 16 (`chromium-kiosk`; `kiosk` — позже),
18 (`vino-vnc`; `x11vnc` — позже). Задачи 10, 14 (`wallpaper`), 15, 17, 27 ждут 1.1. В Task 7 тогда остаётся только документация, пин — отдельным коммитом позже.

## Задачи

### Task 1: [cream] стадии configure `early`, `cloud-user`, `graphical` и `cream resolve --installed`
**Файлы (cream):** `internal/manifest/types.go`, `internal/manifest/validate.go`, `internal/systemd/stage.go` (+`_test.go`),
`testdata/catalog/extensions/configure-{early,cloud-user,graphical}/`, `test/integration/scenario/…`, `docs/specs/2026-10-18-cream-core.md`
(§4.5, §6.4, §17), `docs/cli.md`, `CHANGELOG` — через release-please.
**Шаги.**
1. Тесты первыми: table-driven на разбор (`stage: early|cloud-user|graphical` принимаются при `cream: ">=1.1.0"`;
   при `">=1.0.0"` — отказ 65 «нужен cream >= 1.1.0», рулинг §4.2), на `10-stage.conf` каждой стадии по таблице §6.4,
   на выбор цели `cloud-user` (есть `cloud-final.service` → `cloud-init.target.wants`, нет → `multi-user.target.wants`),
   на пересчёт цели при `cream system init`/`upgrade`.
2. Реализация в `stage.go`; снять `stage.unsupported` для трёх стадий.
3. Интеграция: фикстуры по стадии, перезапуск контейнера — порядок проверяется `systemctl show -p After,Before`
   и `systemd-analyze verify`; отдельная фикстура `ubuntu:24.04` с `gdm3` и cloud-init (стадии `cloud-user` и `graphical`
   вместе с DM) — после перезагрузки в журнале нет `ordering cycle` (`journalctl -b | grep -c 'ordering cycle'` = 0).
4. Спека: таблица §4.5 и пример §6.4 — `desktop` в стадии `system` с `before: [display-manager.service…]` (Р5); §17 —
   «стадии вошли в 1.1.0».
5. `cream resolve --installed <файл реестра>` (аддитивно, из плана bisquite): тест первым — golden `--json` резолва слоя,
   когда часть `depends`/`requires` закрыта расширениями базы `FROM` из переданного реестра; без флага вывод прежний.
   Если не помещается в день — отдельная задача cream той же волны (владелец — исполнитель Task 1).
**Приёмка:** `make ci` и `make test-integration DISTRO=all` зелёные (под замком, по одному).

### Task 2: конвертер `tools/convert-v1.py`
**Файлы:** `tools/convert-v1.py`, `tools/test-convert-v1.sh`, `tools/testdata/convert-v1/{src,expected}/` (копии layout 2 docker, code-server, firewall, kiosk, nvidia-jetpack, can, x11vnc и синтетика `edge` + эталоны).
**Шаги.**
1. Тест первым: фикстура `btop` (только `install.sh`) и `x11vnc` (knobs, `secret:hook`, `ro:`, `?`, `knobs.apply`,
   `configure.sh`, `configure-*.service`) → эталонный манифест и раскладка; повторный запуск — без изменений.
2. Механика §4.7: поля (`layout`/`family`/`arch`/`phase` → `schema`/`platform`/`targets`), `conflicts` → `conflicts.extensions`,
   `knobs` → `config.keys` (`ro:` → `readonly`, `secret` → `secret: file`, `secret:hook` → TODO + Р4, `?` → `empty`,
   `PREFIX_*` → `pattern`), `install.sh` → `hooks/install`, `configure.sh` → `hooks/configure`, `knobs.apply` → `hooks/apply`,
   `update.sh` → `hooks/upgrade`, замены путей и имён по таблице описи §8 (Р2, Р8).
3. Вывод — список TODO по расширению (stage, live, юниты, CLI, `remove`, `lib/`), не молчаливое «готово».
**Приёмка:** `tools/test-convert-v1.sh` зелёный; `make lint`. Конвертер удаляется в Task 28.

### Task 3: обвязка проверок (владелец общих файлов волны 1)
**Файлы:** `tools/check.sh`, `tools/live-test.sh` (новый), `tools/check-names.sh` (новый), `Makefile`,
`.github/workflows/live.yml` (новый; PR — изменённые L-расширения, ночью — все), `tools/hooktest.sh` (H-раннер), `tools/live-matrix.sh`, перенос `tools/test-{firewall,can-usb,l4t-kernel-kvm,nvidia-jetpack,sensing-gmsl2-camera}.sh`
→ `extensions/debian/<ext>/tests/` (`git mv`, без изменения логики, правка путей).
**Шаги.**
1. `check.sh` находит `extensions/debian/*/tests/*.sh` сам (как сейчас `teleport/tests`); явные строки перенесённых тестов убрать.
2. `tools/live-test.sh <ext> [--deps "a b"] [--accept-risk] [DISTRO=debian-12|ubuntu-24.04]`: systemd как PID 1
   с флагами как в `cream/test/integration/host.sh` — без `--privileged`: `--cgroupns=host`, cgroup rw, `--tmpfs /run`,
   явный `--memory` (1g; `gnome` — 2g); `firewall` — `--cap-add NET_ADMIN` в собственном netns контейнера; cream по пину `tools/cream-pin.env` (кеш как в `cream-validate.sh`), источник `path`
   с временным каталогом cream/v1-расширений; сценарий: deps → install → повторный install (`changed: false`) →
   `--reinstall` (снимок sha256 файлов `/etc`, `/opt/cream`, `/usr/local`, `/var/lib/cream/ext` до и после совпадает — проверка
   идемпотентности §6.3) → рестарт контейнера (configure на загрузке, `systemctl --failed` пуст) → `remove` (если есть хук) →
   нет секретов в `ps`/журнале/реестре. Код 20 ожидается флагом `--expect-skip` — только от хука `install` (Р11);
   `configure` обязан выйти 0. Замок `flock` на весь прогон —
   параллельные исполнители не грузят хост одновременно; контейнер и образ удаляются в `trap`.
   Тест самого `live-test.sh` — на фикстуре `extensions/debian/stvor-agent` (уже cream/v1).
3. `tools/check-names.sh`: в cream/v1-расширениях запрещены `/opt/bisquite`, `/etc/bisquite`, `/var/lib/bisquite`,
   `bisquite-conf`, `bisquite-desktop`, `bisquite-firewall`, `bisquite-sensing`, `bisquite-l4t`, `BISQUITE_`,
   `inet bisquite`, `BISQUITE-INPUT`, `zz-bisquite`, `10-bisquite`, `99-bisquite`, `lib/get_cloud_user`, `lib/l4t`;
   слово `bisquite` как имя сборщика (`EXTENSION` в README) разрешено. Список растёт сам по мере перевода.
4. `Makefile`: `test-live EXT=…`, `check-names`; `make test` включает `check-names`. Ночной workflow: `live-test.sh`
   по всем L-расширениям на `debian:12` и `ubuntu:24.04` (amd64), сеть разрешена.
**Приёмка:** `make ci` зелёный; `make test-live EXT=stvor-agent` зелёный.

### Task 4: [cream] проверка графа в `cream validate --catalog` и выпуск 1.1.0
**Файлы (cream):** `internal/catalog/validate.go` (+`_test.go`), `testdata/…`, `docs/cli.md`.
**Шаги.** Тест первым: `depends` на отсутствующее имя или с невыполнимым диапазоном — ошибка 65 `catalog.depends`;
`requires` без поставщика в каталоге — **предупреждение** (способность может прийти от `cream assume`/голого `INSTALL`);
`conflicts.extensions` на несуществующее имя — предупреждение; цикл `depends` — ошибка. Затем выпуск 1.1.0
(release-please, `.deb` amd64/arm64, `SHA256SUMS`, `make repro-check`).
**Приёмка:** `make ci`, `make test-integration DISTRO=all`; релиз `v1.1.0` с ассетами. Выпуск — внешнее действие:
если у контроллера нет мандата владельца на выпуск cream, пауза только здесь.

### Task 5: `cloud-user` + `yq`
**Файлы:** `extensions/debian/{cloud-user,yq}/`.
`cloud-user` — `kind: library` без хуков; `get_cloud_user.sh` переносится с заменой путей; H: пользователь из
`/etc/cloud/cloud.cfg(.d)` через yq, запасной путь без cloud-init/yq, uid ≥ 1000. `yq` — по порядку §«Порядок перевода»,
`remove` хук. **Приёмка:** V, H, L (`make test-live EXT=yq`; библиотека проверяется установкой в `--deps`).

### Task 6: `l4t` + `btop` + `firefox`
**Файлы:** `extensions/debian/{l4t,btop,firefox}/`.
`l4t` — `kind: library` из `lib/l4t`; H на фикстурах `/etc/nv_tegra_release` R32/R36 и `l4t_openblas_pin` в подменённом корне.
`btop`, `firefox` — простые, `remove`-хуки. **Приёмка:** V, H; L для `btop`, `firefox`.

### Task 7: пин cream 1.1.0, линт хуков, конвенция (владелец общих файлов волны 3)
**Файлы:** `tools/cream-pin.env`, `tools/lint-hooks.sh` (новый, + `tools/test-lint-hooks.sh`, `tools/testdata/lint-hooks/`),
`tools/lint.sh` (shellcheck cream/v1 на уровне `warning`), `tools/check.sh` (подключение), `docs/extensions.md`,
`README.md` (разделы «Конвенция», «Раскладка» — под cream/v1, переходная пометка про layout 2), `tools/new-extension.sh`
(+ `tools/test-new-extension.sh`, `.claude/skills/new-extension`), `AGENTS.md` (карта: `lib/` уходит),
`tools/convert-v1.py` и `tools/test-convert-v1.sh` (`cloud-user` → `>=1.1.1`, граф 1.1.0: библиотеки в наборе проверки).
**Итог.** Пин — 1.1.0 (суммы сверены с `SHA256SUMS` релиза `v1.1.0`), `CREAM_SHA256_ARM64` — для учёта; рулинг Р14.
Правила `lint-hooks.sh`: `header`, `exec`, `hook-name`, `systemctl-block`, `lock-none-set`, `source-lib`, `secret-argv`,
`cream-env` (присваивание и неизвестные имена `CREAM_*`), `stage-cream`. `validate-extensions.py` остаётся для layout 2
до Task 28.
**Шаги.** Тест первым для `lint-hooks.sh` (фикстуры-нарушители): `systemctl` без `--no-block` в `hooks/apply` и `hooks/configure`;
`cream set` в действиях с `lock: none`; `source` библиотек `lib/`; секрет в argv. Эти правила переносятся из
`validate-extensions.py` до его удаления. `new-extension.sh` генерирует cream/v1-скелет; тест на скелет — `cream validate`.
**Приёмка:** `make ci`; `make cream-validate` на пине 1.1.0.

### Task 8: `docker`
`depends: [{name: cloud-user, version: ">=1.0.0 <2"}]`, configure `system` с `after: [docker.service]`, `live: confirm`
и `live_note`; RPi `cmdline.txt` — код 10, бэкап не перезаписывается; `docker-iptables-raw-check` и drop-in — `files`.
**Приёмка:** V, H (двойной configure — `cmdline.txt` один раз), L `--accept-risk` (поверх образа с `docker.io` — удалён).

### Task 9: `locale` + `can`
Свои `hooks/apply`; `can`: `render-modules-load.sh` читает окружение, а не `bisquite-conf`; в контейнере без модулей — 20.
`locale`: правило dconf-профиля совпадает с `desktop` (комментарий-ссылка на расширение, не на `lib/`).
**Приёмка:** V, H, L.

### Task 10: `firewall`
Стадия `early` (`cream: ">=1.1.0"`); `bisquite-firewall.service` → configure; `backend.sh` и `rules.d/` →
`/etc/cream/firewall/rules.d/`; Р2; CLI → действия `status` (`lock: none`), `reload` (`lock: exclusive`); ключи
`FIREWALL_*` без префикса; `apply` = перезапуск configure (без своего хука, §8.4). H — порт теста firewall (оба бэкенда).
**Приёмка:** V, H, L `--accept-risk` (после рестарта таблица `inet cream` стоит до `network-pre.target`; SSH контейнера
по правилу по умолчанию открыт).

### Task 11: `network-manager` + `cloud-growroot` + `nocloud-cidata`
`network-manager` — `confirm`; два остальных — `live: no` с `live_note`, `build: exec`. **Приёмка:** V, H; L для
`network-manager` (install в контейнере без netplan/ifupdown — 20 по `--expect-skip`, иначе 0); `cloud-growroot`,
`nocloud-cidata` — P (сборка через bisquite).

### Task 12: `desktop` (новое)
**Файлы:** `extensions/debian/desktop/` (из `lib/bisquite-desktop`, `lib/knobs/desktop{,.apply}`; сами файлы `lib/` не трогать —
их удаляет Task 28). Хуки: `install` (зависимости dconf/xfconf), `configure` (Р5), `remove`; действия `apply`
(`lock: exclusive`, `--now`/`--boot`), `status` (`lock: none`), `defaults`; `config.keys` — `DESKTOP_*`; путь
`/etc/default/bisquite-desktop` и ветки layout 1 (`/opt/vmsetup`) удаляются.
**Приёмка:** V, H (gdm/lightdm/xfce/lxde фикстуры), L (без DM: configure — 0, файлы dconf на месте).

### Task 13: `gnome` + `xfce4` + `lxde`
depends `desktop`, `conflicts.capabilities: [desktop-session]`, `provides` без изменений; `daemon.conf`/`lightdm.conf` — `files`;
`set-default graphical.target` → код 10. **Приёмка:** V, H; L для `xfce4` (+ проверка конфликта: install `lxde` поверх — 67);
`gnome`, `lxde` — в ночном прогоне.

### Task 14: `cloud-user-desktop` + `wallpaper`
`cloud-user-desktop` — depends `desktop`, `cloud-user`, без своей службы. `wallpaper` — стадия `cloud-user` (1.1),
картинки в дереве расширения (`/opt/cream/ext/wallpaper/images`). **Приёмка:** V, H, L (поверх `xfce4`).

### Task 15: `code-server`
Стадия `cloud-user`; `CODE_SERVER_PASSWORD` — `secret: file`, хук читает из `CREAM_SECRETS_FILE`; `teleport-app.sh` пишет
`/etc/cream/teleport/apps.d/code-server.conf` в формате, который читает `extensions/debian/teleport` (H сверяет разбором
`teleport/files/teleport.sh`); `remove` снимает объявление и службу. **Приёмка:** V, H, L (пароль не в `ps`/журнале).

### Task 16: `kiosk` + `chromium-kiosk`
`kiosk` — `graphical` (1.1), `kiosk-chromium@.service` и `run-kiosk.sh` на `EnvironmentFile`; `chromium-kiosk` — `system`
(1.0), `conflicts.extensions` взаимно. **Приёмка:** V, H, L (`kiosk`: configure без DM — предупреждение и 0; конфликт — 67).

### Task 17: `selkies`
`graphical`; секреты `SELKIES_BASIC_AUTH_PASSWORD`, `…_VIEWONLY_PASSWORD`, `SELKIES_MASTER_TOKEN` — `secret: file`,
`selkies@.service` с `EnvironmentFile=-/etc/cream/selkies/secrets`; `SELKIES_ALLOW_NO_AUTH` (Р8); свой `apply`; apps.d как в
Task 15; configure без DM — предупреждение и 0 (Р11). **Приёмка:** V, H, L (`--deps "desktop xfce4"`).

### Task 18: `x11vnc` + `vino-vnc`
`x11vnc` — `graphical` (1.1); `vino-vnc` — `system` с `after: [cloud-init.service]`, `before: [display-manager.service,
gdm.service, gdm3.service, lightdm.service]` (по образцу Р5, cream 1.0: dconf пишется до входа, vino в сессии подхватит сам). Р4: `knobs.secret` удаляется, `configure` строит производный файл пароля (0600, владелец — пользователь сессии,
`hand_over_passfile` сохраняется), пустой пароль снимает файл, отказ построить файл — сбой configure (а не `-nopw`);
свой `apply` у x11vnc. **Приёмка:** V, H (нет пароля → нет файла; есть → файл 0600; повтор — без изменений), L.

### Task 19: `rustdesk` + `jetson-stats`
`rustdesk` — `system`, `render-toml.sh` на окружении, `/var/lib/cream/ext/rustdesk/`; `jetson-stats` — `cloud-user` (1.1),
без `jtop.service` в порядке. **Приёмка:** V, H; L для `rustdesk`; `jetson-stats` — P (AGX Orin).

### Task 20: `nvidia` + `nvidia-container-toolkit`
`confirm`, amd64; `nvidia`: нет ядер в `/lib/modules` → 20, blacklist nouveau → 10, ветка appliance сохраняется для build;
`nvidia-container-toolkit`: `daemon.json` — слияние, а не перезапись (двойной прогон). **Приёмка:** V, H; L20 для `nvidia`,
L для `nvidia-container-toolkit` (`--deps "docker nvidia"`, `nvidia` с `--allow-skip` — запись `skipped` в реестре служит поставщиком `gpu-driver-nvidia`; без GPU — `nvidia-ctk` установлен, runtime прописан); P — ВМ с GPU.

### Task 21: `nvidia-jetpack`
`confirm`, amd64; `scripts/` (≈3,6 тыс. строк) — замены путей и имён по гейту, логика не меняется; binfmt —
`systemctl --no-block restart systemd-binfmt` при живом systemd, проверяется **только H** (в L binfmt хоста не трогаем,
рестарт пропускается). **Приёмка:** V, H (порт теста, включая binfmt), L (без прошивки платы и без binfmt).

### Task 22: `cuda-toolkit` + `tensorrt` + `l4t-gstreamer`
depends `l4t` (tensorrt, l4t-gstreamer); нет `/etc/nv_tegra_release` → 20. **Приёмка:** V, H; P.

### Task 23: `l4t-opencv` + `l4t-pytorch` + `l4t-tensorflow`
depends `l4t` (opencv, pytorch), requires `cuda`; `check-system-python.py`, `constraints.txt` — в дереве; явные
`timeout` хуков (сборка torchvision). **Приёмка:** V, H; P.

### Task 24: `l4t-board-fdt` + `l4t-boot-verify`
`l4t-board-fdt`: бэкап `extlinux.conf` создаётся один раз (`.cream-orig`, не перезаписывается), код 10; `l4t-boot-verify`:
юнит `l4t-boot-verify.service` через `files`, маскировка вендорской службы — в `install`, снятие — в `remove`.
**Приёмка:** V, H (двойной прогон: бэкап — от первого); P.

### Task 25: `l4t-kernel-kvm`
`live: no`, `timeout` явный (≥ 4 ч), `extlinux-root.sh` в дереве; H — порт теста. **Приёмка:** V, H; P (сборка через bisquite).

### Task 26: `sensing-gmsl2-camera` + `can-usb`
Переименования юнитов, правила udev и CLI (Р7); `kernel-hold.sh`, `nvisppg.sh`, `Kbuild`, `canusb.sh` — в дереве; свой `apply`
у sensing; `apt-mark hold`/`dpkg-divert` снимаются в `remove`, если это безопасно, иначе `--forget` в README. **Приёмка:** V, H
(порт двух тестов); P.

### Task 27: `pixelflux-tegra` + `pixelflux-v4l2m2m`
`graphical` (1.1); `verify-*.service` → configure (проверка кодера на загрузке; нет кодера — предупреждение и 0, Р11); install без Tegra/M2M → 20; `gbm_shim.c` собирается
в `install`. **Приёмка:** V, H; P (Orin с selkies).

### Task 28: уборка переходного
**Файлы:** удалить `lib/`, `tools/validate-extensions.py`, `tools/test-validate-extensions.sh`, `tools/test-conf.sh`,
`tools/convert-v1.py` (+тест и фикстуры), `extensions/openwrt/` (Р3) и ссылки на него; в `tools/cream-validate.sh`
и `tools/catalog-snapshot.sh` убрать отбор cream/v1 из смешанного каталога — `cream validate --catalog .` по корню;
`check.sh`, `Makefile`, `lefthook.yml`, `.github/workflows/ci-release.yml` — без layout 2; `README.md`, `AGENTS.md`,
`docs/extensions.md`, `CLAUDE.md` — без `lib/`, `/opt/bisquite`, layout 2; `docs/STATUS.md`.
**Шаги.** Сначала тест: `test-snapshot.sh` собирает снимок из всего корня; `check-names.sh` — по всему репозиторию
(исключения — CHANGELOG и история в docs/research).
**Приёмка:** `make ci`; `grep -rn 'layout: 2\|/opt/bisquite\|/etc/bisquite' extensions tools lib` пуст.

**Найдено исполнителями (для Task 28):** `docs/extensions.md:947` — старое имя `bisquite-l4t-boot-verify.service`
(Task 24 переименовал юнит в `l4t-boot-verify.service`).

**Бэклог после 5.0.0 (найдено в волнах, вне плана):**
- `l4t-kernel-kvm`: `public_sources.tbz2` NVIDIA скачивается без sha256 — нужны суммы по версиям L4T.
- `l4t-pytorch`, `l4t-tensorflow`: колёса PyPI — только по `constraints.txt`, без `--require-hashes`.
- `nvidia-jetpack`: шаг 04 принимает пароль в argv (`-p`) — перевести на файл/stdin; шаг 09 — `chown -R` каталога
  результатов на оператора, при повторе root пишет в каталог оператора (повышения нет, но стоит писать от оператора).
- `network-manager`: живой прогон на Ubuntu не идёт в контейнере (polkit/hostnamed без `SYS_ADMIN`) — только debian-12.

### Task 29: Финальная интеграция + `make ci`, выпуск каталога 5.0.0
1. Сквозной `make ci` на `main` после всех слияний («зелено у агента» ≠ «зелено в ветке»).
2. `make snapshot-check`; ночной workflow вручную по всем L-расширениям (`debian:12`, `ubuntu:24.04`).
3. Сводка P-проверок (ждут платы/bisquite) — в `docs/STATUS.md` списком с владельцем.
4. Release PR release-please с `Release-As: 5.0.0`; CHANGELOG — раздел BREAKING: пути `/opt/cream/ext`, `/etc/cream`,
   `/var/lib/cream/ext`; `lib/` и layout 2 удалены из каталога и инструментов; таблица переименованных ключей (Р8) и юнитов;
   nft `inet cream`/`CREAM-INPUT`; `extensions/openwrt/` перенесён в bisquite.
5. Выпуск — внешнее действие (тег, ассет снимка); `BISQUITE_BUMP_ENABLED` не включать до плана bisquite.
**Приёмка:** зелёный CI релиза, ассеты `cream-extensions-5.0.0.tar.gz` и `SHA256SUMS`, `cream source add --archive` +
`cream resolve` по снимку.

## Что требуется от cream (новые минорные версии)
| Версия | Что | Кому нужно | Задача |
|---|---|---|---|
| **1.1.0** | стадии configure `early`, `cloud-user`, `graphical` (§6.4), отказ «нужен cream >= 1.1.0» для них в 1.0-манифесте | `firewall`; `code-server`, `wallpaper`, `jetson-stats`; `kiosk`, `selkies`, `x11vnc`, `pixelflux-*` | 1 |
| **1.1.0** | статическая проверка графа в `cream validate --catalog` (depends — ошибка, requires/conflicts — предупреждение) | замена проверки графа из удаляемого `validate-extensions.py` | 4 |
| 1.1.0 (спека) | правка §4.5/§6.4: `desktop` (и `vino-vnc`) — `system` + `before` DM | `desktop`, автологин | 1 |
| **1.1.1** | исправление: стадия `cloud-user` запускается и при выключенном cloud-init (Р14) | `code-server`, `wallpaper`, `jetson-stats` | вне плана (cream), подъём пина — одна правка `tools/cream-pin.env` |
| **1.1.0** | аддитивный `cream resolve --installed <файл реестра>`: резолв слоя с учётом расширений базы `FROM` (из плана bisquite) | bisquite (`EXTENSION` поверх базового образа) | 1 (вместе со стадиями) или соседняя задача cream той же волны; владелец — исполнитель Task 1, приёмка — контроллер плана bisquite |

**Сознательно не нужно** (перевод обходится без ожидания): `hooks.secret`/`secret: hook` (Р4), `hooks.check` и
`cream status` (здоровье — действие `status`), `bin` (Р7), `targets.build: files` и `cream stage` (`nocloud-cidata`,
`cloud-growroot` — `exec` на машине цели, §4.4), git-источник (каталог доставляется архивом), `cream assume`,
`--with-deps` (живой стенд ставит `--deps` по порядку), `cream path` (путь библиотеки стабилен).
Кандидаты на 1.2+ без блокировки этого плана: `--with-deps` (удобство живых тестов и Stvor), `build: files` — когда
понадобится `raspios-normalized` на arm64 со сборкой на amd64.

## Риски исполнения
1. **Задержка cream 1.1.0 останавливает 9 расширений.** Смягчение — запасной порядок волн (выше); Task 1 стартует в
   волне 1, пин поднимает одна задача (7). Манифест с `cream: ">=1.1.0"` на пине 1.0 валит `make cream-validate` у всех —
   поэтому такие расширения не сливаются раньше Task 7.
2. **Контейнер — не машина.** Нет DM, GPU, ядер L4T, `/boot/firmware`: стадии `graphical` и железные configure в L
   проверяются только до кода 20. Это фиксируется явными P-строками в STATUS, а не считается «проверено». Порядок загрузки
   стадий проверяет Task 1 в интеграции cream, а не каталог.
3. **Живые прогоны тяжёлые и сетевые** (apt `gnome` — гигабайты; диск хоста уже забивался кешем): `live-test.sh` под
   `flock`, по одному, удаляет контейнер и образ; `gnome`/`lxde` — только ночью; перед волной — `df -h /` < 85 %.
4. **Смешанный каталог на время миграции.** layout 2 и cream/v1 живут рядом в `main`; `lib/` нужен оставшимся layout 2 —
   исполнители его не правят и не удаляют (только Task 28). Промежуточный release PR не сливается (Р12); bisquite не
   получает смешанный каталог, пока выключен `BISQUITE_BUMP_ENABLED`.
5. **Контракты между расширениями, которые не видит валидатор**: `apps.d` (`code-server`, `selkies` → `teleport`),
   правило dconf-профиля (`locale` ↔ `desktop`), `daemon.json` (`docker` ↔ `nvidia-container-toolkit`). Смягчение — H-тесты
   сверяют формат с кодом расширения-читателя, L — совместной установкой через `--deps`.
6. **Переименования ломают потребителей вне каталога**: ключи `BISQUITE_*` (Р8), юниты `bisquite-*`, CLI `bisquite-firewall`,
   `bisquite-desktop set` в примерах VMFILE и `firstboot-commands` bisquite. Таблица переименований — обязательная часть
   каждого PR и CHANGELOG 5.0.0; правка примеров — в плане bisquite (шаг 4 §16).
7. **Идемпотентность.** Двойной прогон `--reinstall` в L впервые проверяет её сплошь; найдутся дефекты кроме
   `l4t-board-fdt` (бэкапы, дописывание в `/etc/environment`, `daemon.json`). Найденное чинится в задаче расширения,
   а не откладывается.
8. **Параллельные worktree и lefthook**: общий stash всплывает в чужом worktree — коммитить целыми файлами, `git add <пути>`;
   у файла один владелец; `make ci` и живые прогоны на хосте — по одному.
9. **P-проверки (плата, ВМ с GPU, сборка через bisquite) — вне CI.** Выпуск 5.0.0 их не ждёт (машин нет, решение владельца),
   но STATUS перечисляет каждую; первая сборка образа через bisquite с cream — приёмка плана bisquite.

**Заметка для Task 29 (squash в main):** из BREAKING CHANGE коммита 68f5f0f (firewall) не переносить фразу об открытом по умолчанию SSH — исправлено 12fefd9, SSH закрыт как раньше.
