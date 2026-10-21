# Переход на cream/v1

До выпуска 5.0.0 (2026-10-19) каталог назывался bisquite-extensions и жил в
формате сборщика bisquite («раскладка 2»). Выпуск 5.0.0 перевёл все расширения на
формат `cream/v1`, который исполняет [cream](https://github.com/iamletenkov/cream);
выпуск 5.3.0 — под cream 1.2.0 и bisquite 3. План перехода —
[plans/2026-10-19-cream-v1-migration.md](../plans/2026-10-19-cream-v1-migration.md);
построчно — [CHANGELOG.md](../../CHANGELOG.md), раздел 5.0.0.

## Что было и что стало

| Было (раскладка 2, bisquite 2.x) | Стало (`cream/v1`) |
|---|---|
| `install.sh`, `configure.sh`, `knobs.apply` в корне расширения | хуки `hooks/install`, `hooks/configure`, `hooks/apply`, плюс `remove` |
| схема настроек `knobs`, CLI `bisquite-conf set\|show <имя>` | `config.keys` манифеста, `cream set\|show <имя>` |
| `/opt/bisquite/<имя>`, `/etc/bisquite/<имя>/config`, `/var/lib/bisquite/<имя>` | `/opt/cream/ext/<имя>`, `/etc/cream/<имя>/config` (секреты — `secrets`, 0600), `/var/lib/cream/ext/<имя>` |
| свои юниты `configure-<имя>.service` | `cream-configure@<имя>` на стадии `early`, `system`, `cloud-user` или `graphical` |
| общий код в `lib/` корня (`get_cloud_user.sh`, файл L4T, `bisquite-desktop`), копировался в каждого потребителя | библиотеки `kind: library`: `cloud-user`, `l4t`, `apt-guard`; домен `desktop` |
| самописные CLI `bisquite-<имя>` (`bisquite-teleport`, `bisquite-desktop`, `bisquite-firewall`) | действия `cream run <имя> <действие>` |
| инструкция VMFILE `EXTENSION [src/]имя[@v] K=V` | `RUN_COMMAND cream install [--source src] имя[@v] K=V` (bisquite 3) |
| `bs extension sync` (кеш каталога сборщика), `bs extension new` (каркас) | снимок каталога в выпуске и `cream source add`; каркас — `tools/new-extension.sh` |
| `extensions/openwrt/` в этом репозитории | перенесён в bisquite: его файлы bisquite берёт по тегу `v3.3.0` каталога |
| таблица nft `inet bisquite`, цепочка `BISQUITE-INPUT` | `inet cream`, `CREAM-INPUT`, без миграции загруженных правил |
| списки в ключах через запятую | через пробел |
| `cream resolve --phase build` для применимости слоя | `cream check` по строкам образа (cream 1.2.0) |

Обёртка `teleport-agent` (пакет `bisquite-teleport-agent` 3.x) удалена: узел
Teleport ведёт расширение `teleport`, агент портала ставит обёртка `stvor-agent` по
пину версии и sha256 на архитектуру.

## Решения, принятые по дороге

- **Docker — одно расширение, а не два.** Было `docker` (через `get.docker.com`) и
  `docker-ce` (через apt-репозиторий): считалось, что старым системам нужен скрипт.
  Замер 2026-09-03: скрипт ставит из того же `download.docker.com`, а на bionic
  ломает сборку (`version_gte` при пустом `VERSION` всегда истинна и тянет
  `docker-model-plugin`, которого для bionic нет). Расширения слиты; разбор — в
  README `docker`.
- **Расширение `chromium` удалено.** На arm64 нативного Chromium нет ни в Ubuntu
  ports, ни у NVIDIA: `chromium-browser` — переходный пакет к снапу, и `configure`
  ходил в сеть (`snap install`) на первой загрузке. Браузер без снапа — `firefox`.
- **`apt-guard`.** До библиотеки проверка симуляцией apt жила копиями в шести хуках
  стека L4T, а половина хуков каталога обходилась без неё; это вскрыло финальное
  ревью выпуска 5.0.0.
- **Рабочие столы взаимоисключаются по способности** `desktop-session`, а не
  перечнем имён; настройки столов переехали в домен `desktop`.
- **Без пароля не стартуют** `x11vnc`, `vino-vnc`, `selkies`, `code-server`; без
  пароля — только явным ключом разрешения.

## Заметки по расширениям

- **apt-guard** — библиотека с 5.0.0 (см. выше).
- **btop** — 2.0.0: cream/v1 (`install.sh` → `hooks/install`, появился `remove`);
  1.2.0 — запасная статическая сборка релиза для focal.
- **can** — 2.0.0: `install.sh`, `knobs.apply` и `render-modules-load.sh` слиты в
  хуки `install`/`apply`, схема `knobs` стала `config.keys`. До перехода проверено
  в 1.x, L4T — в 1.1.0.
- **can-usb** — 2.0.0: cream/v1, `live: confirm`; H-тест — порт прежнего `canusb.sh`.
- **chromium-kiosk** — 4.0.0: репозиторий и ключ — `files` вместо `wget` при
  установке, списки через пробел, `ru_RU.UTF-8` больше не навязывается.
- **cloud-growroot** — 2.0.0: cream/v1, `remove`; вписываются только недостающие
  модули (прежде модуль задваивался), существующий бэкап не перезаписывается.
- **cloud-user** — 1.0.0 в каталоге 5.0.0 заменила общий файл раскладки 2,
  копировавшийся в каждого потребителя; прежде `user:` словарём давал YAML
  словаря, а не `.user.name`.
- **cloud-user-desktop** — 5.0.0: ручки через `depends` на `desktop` вместо копии
  общего кода; прежде группы вносила своя служба после `cloud-final` (проиграла
  гонку на AGX Orin); удаление учётки ужесточено (uid ≥ 1000, имя по форме,
  пережившая `userdel` учётка — отказ).
- **code-server** — 5.0.0: cream/v1 без переходной совместимости; прежний пароль
  `none` больше не допустим.
- **cuda-toolkit** — 2.0.0: cream/v1, код 20 вне Jetson; 2.1.0 — Nano R32
  (CUDA 10.2, свой источник r32.x).
- **desktop** — новое расширение (1.0.0, каталог 5.0.0) вместо общего кода раскладки 2 и CLI
  `bisquite-desktop` (`set` → `cream set desktop`, `apply|defaults|status` →
  `cream run desktop …`, служба `bisquite-desktop.service` → `cream-configure@desktop`);
  стадия `system` до менеджера входа.
- **docker** — 4.0.0: убран `configure-docker.service`, iptables-raw через `files`,
  `cloud-user` вместо общего скрипта (запасная копия поиска пользователя жила в
  `configure.sh`). OpenWrt: там `opkg` (24.10) или `apk` (25.12) и нет systemd; в
  25.12 пакета `dockerd` нет для x86_64, aarch64_generic, aarch64_cortex-a53,
  aarch64_cortex-a76 (проверено по шести точечным выпускам).
- **firefox** — 2.0.0: cream/v1, `remove`, `FIREFOX_LANGPACK` — ключ `config.keys`.
- **firewall** — 2.0.0: `install.sh` → хук `install`, `configure.sh` → общий
  `firewall.sh`; своей службы нет, на загрузке — `cream-configure@firewall` (стадия
  `early`); CLI-обёртку заменили действия `status|check|reload`; таблица и цепочка
  переименованы без миграции (старые снимаются перезагрузкой или руками); появился
  `FIREWALL_SSH_PORTS`.
- **gnome**, **lxde**, **xfce4** — 5.0.0: cream/v1, ключи переехали в домен
  `desktop`, взаимоисключение по способности; пробу snap-`firefox` на Ubuntu убрали.
- **jetson-stats** — 3.0.0: стадия `cloud-user` (cream ≥ 1.1.1), убран
  `configure-jetson-stats.service`; 3.1.0 — `--require-hashes`.
- **kiosk** — 4.0.0: убран свой `configure-kiosk.service`; в домашний каталог больше
  не пишет (панель и стол Xfce4 — `/etc/xdg`, клавиатура — dconf); Ubuntu снята.
- **l4t** — 1.0.0: перенесена из общего L4T-файла `lib/` раскладки 2.
- **l4t-board-fdt** — 2.0.0: копия `extlinux.conf` `.cream-orig` вместо
  `.before-board-fdt`, который перезаписывался каждым прогоном (после второго
  прогона «откат» возвращал уже изменённый файл); `L4T_BOARD` — параметр установки,
  код 10; маска отказа `tegra210-*-kvm.dtb` → `*-kvm.dtb` (давала ложную подсказку
  на другой Tegra). До выбора деревьев отдельным слоем образ был привязан к одной
  паре модуль+несущая (7 сборок по 2 ч).
- **l4t-boot-verify** — 2.0.0: служба переименована в `l4t-boot-verify.service`,
  её раскладывает cream.
- **l4t-gstreamer**, **l4t-opencv**, **tensorrt**, **l4t-tensorflow** — 2.0.0:
  cream/v1, хук `remove`, `live: yes`, общий L4T-код — библиотека `l4t`, не Jetson —
  код 20 вместо 1; ветка R32 — с 1.2.0; `l4t-tensorflow` 2.1.0 — pip только по хешам.
- **l4t-kernel-kvm** — 1.2.0: `L4T_KERNEL_JOBS` ограничен ядрами и памятью
  appliance; 1.3.0 — `root=PARTUUID`; 2.0.0 — `.cream-orig` вместо `.before-kvm`,
  коды 20/10, таймаут 6 ч; проверка t210 — сборки на t186/t194/t234 отказывают в
  первую минуту.
- **l4t-pytorch** — 2.0.0: cream/v1, `live: yes`, библиотека `l4t`, код 20,
  `TORCH_CUDA_ARCH_LIST` — ключ; 2.1.0 — хеши PyPI; 1.2.0 — ветка R32 (проверка на
  Nano 2026-09-15 была на 1.2.0).
- **l4t-vendor-desktop** — без него цепочка `jetson-nano-robot` на каталоге 5.0.0
  не разрешалась.
- **locale** — 2.0.0: `install.sh`/`apply.sh` — хуки, `knobs` — `config.keys`,
  появился `remove`; ключи не переименованы.
- **network-manager** — 2.0.0: проверка `ID` из os-release ушла в `platform.os`;
  2.1.0 — живой прогон на ubuntu-22.04.
- **nocloud-cidata** — 2.0.0: файл в `cloud.cfg.d` переименован в
  `zz-cream-nocloud.cfg` (прежде `zz-bisquite-nocloud.cfg`).
- **nvidia** — 2.0.0: несовместимо с 1.x — убраны `ubuntu-drivers autoinstall`,
  откаты на 535/525/470 и Ubuntu 20.04; 3.0.0 — cream/v1, ключи без переименований,
  без `remove`.
- **nvidia-container-toolkit** — 2.0.0: cream/v1; отсутствие драйвера перестало быть
  отказом.
- **nvidia-jetpack** — 3.0.0: скрипты больше не копируются в `/opt/nvidia-jetpack/`;
  прежде станция жила в `.scratchpad/jetson-orin/` под `.gitignore` и была
  невоспроизводима.
- **pixelflux-tegra**, **pixelflux-v4l2m2m** — 3.0.0 и 2.0.0: cream/v1; службы
  `verify-pixelflux-*.service` стали `configure`; с Selkies 2.0.0 колесо больше не
  подменяется и не патчится — расширение свелось к проверке.
- **rustdesk** — 2.0.0: хуки `install`/`configure`/`remove`, домен
  `/etc/cream/rustdesk/config`.
- **selkies** — 6.0.0: cream/v1. До 2.0.0 настройки лежали в
  `/etc/default/bisquite-selkies`, затем `bisquite-conf` (схема `knobs`): правка —
  `bisquite-conf set selkies`, автологин — `bisquite-desktop set …`.
- **sensing-gmsl2-camera** — 4.0.0: камеры ушли из базового образа `nvidia-jetpack`
  (до 2026-09-19 `libnvisppg` подкладывал шаг 03); прежде проверялась только плата,
  без выпуска; был зашит пакет `_YUV_`. 4.1.0 — hold ядра. 5.0.0 — cream/v1, ключи
  cream вместо домена `sensing-camera` раскладки 2; диагностика перенесена из
  `nvidia-jetpack/scripts/README.md`.
- **stvor-agent** — 4.0.2: метку применяет `teleport` через `reload-apps`, хуки не
  запускают `teleport-apps.service`; 4.1.0 — Ubuntu 20.04 (Nano).
- **teleport** — 4.0.0: перенос `bisquite-teleport-agent` 3.x (`bisquite-teleport
  <команда>` → `cream run teleport <действие>`; юниты `bisquite-teleport-{apps,token,join}.*`
  → `teleport-{apps,token,join}.*`; `TELEPORT_TOKEN` → `TELEPORT_REGISTRATION_SECRET=-`);
  4.0.1 — HUP через `systemctl kill --kill-who=main`; 4.0.2 — `reload-apps` с
  `lock: exclusive`, `ExecReload` — действие `hup`; 4.1.0 — Ubuntu ≥ 20.04.
- **vino-vnc** — 5.0.0: в дом не пишет; без пароля выключен, если нет
  `VINO_ALLOW_NO_PASSWORD=1`; файл `/etc/vino/vnc-password.b64` — из 4.x.
- **wallpaper** — 3.0.0: служба `configure-wallpaper.service` заменена стадией
  `cloud-user`; прежде обои писались в dconf пользователя через gsettings
  (только GNOME), `nvbackground.sh` обходили маркерами в доме; `WALLPAPER_MODE` —
  новый, `WALLPAPER_IMAGE` — имя файла в `images/`.
- **x11vnc** — 5.0.0: пароль в `secrets` домена, `configure` на стадии `graphical`,
  fail-closed без пароля; прежде при ненайденном X authority был немой цикл
  рестарта каждые 5 с; файл пароля мог остаться от 4.x.
- **yq** — 2.0.0: cream/v1, `curl` вместо `wget`, сверка sha256 по пину (прежде
  проверки не было); 2.1.0 — Ubuntu 18.04 и 20.04.
