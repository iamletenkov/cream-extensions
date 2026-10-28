# Changelog

## [5.9.3](https://github.com/iamletenkov/cream-extensions/compare/v5.9.2...v5.9.3) (2026-10-28)


### Исправлено

* **openwrt:** пины агента и Teleport для восстановления после sysupgrade ([#75](https://github.com/iamletenkov/cream-extensions/issues/75)) ([a52b13e](https://github.com/iamletenkov/cream-extensions/commit/a52b13eb377e1f86a0e7259d42f831a87e2a209b))

## [5.9.2](https://github.com/iamletenkov/cream-extensions/compare/v5.9.1...v5.9.2) (2026-10-27)


### Исправлено

* **release:** подписанный релиз не переподписывается и не перезаписывается ([#71](https://github.com/iamletenkov/cream-extensions/issues/71)) ([57f9c7c](https://github.com/iamletenkov/cream-extensions/commit/57f9c7c10ef5a2dc5e10202fec1c7f650a034c0d))

## [5.9.1](https://github.com/iamletenkov/cream-extensions/compare/v5.9.0...v5.9.1) (2026-10-27)


### Исправлено

* **teleport:** та же версия с новой суммой набора ставится заново ([#68](https://github.com/iamletenkov/cream-extensions/issues/68)) ([ac2c4e3](https://github.com/iamletenkov/cream-extensions/commit/ac2c4e390a69cc6e676854e338124a767fb48ad4))

## [5.9.0](https://github.com/iamletenkov/cream-extensions/compare/v5.8.0...v5.9.0) (2026-10-26)


### Добавлено

* **stvor-agent:** пин агента 4.3.0 ([#66](https://github.com/iamletenkov/cream-extensions/issues/66)) ([36e660c](https://github.com/iamletenkov/cream-extensions/commit/36e660c5c245cce75771930c024dca63106c1f3d))

## [5.8.0](https://github.com/iamletenkov/cream-extensions/compare/v5.7.0...v5.8.0) (2026-10-25)


### Добавлено

* **stvor-agent:** пин агента 4.2.0 ([#64](https://github.com/iamletenkov/cream-extensions/issues/64)) ([cb47400](https://github.com/iamletenkov/cream-extensions/commit/cb4740099c209fcc865113fbb4c48f91b95b5923))

## [5.7.0](https://github.com/iamletenkov/cream-extensions/compare/v5.6.0...v5.7.0) (2026-10-23)


### Добавлено

* **openwrt:** робот переживает sysupgrade тем же узлом ([#62](https://github.com/iamletenkov/cream-extensions/issues/62)) ([1b139d3](https://github.com/iamletenkov/cream-extensions/commit/1b139d3b2c23828c4f8bb4c962cbeddef6822445))


### Исправлено

* **stvor-agent-openwrt:** sysupgrade хранит только machine-id, права состояния чинятся сами ([#60](https://github.com/iamletenkov/cream-extensions/issues/60)) ([e582eab](https://github.com/iamletenkov/cream-extensions/commit/e582eabf2bd72d7baaff61d7acf08c195250368d))

## [5.6.0](https://github.com/iamletenkov/cream-extensions/compare/v5.5.0...v5.6.0) (2026-10-22)


### Добавлено

* **stvor-agent-openwrt:** агент Stvor на OpenWrt из tar.gz, службы procd ([#57](https://github.com/iamletenkov/cream-extensions/issues/57)) ([3fad493](https://github.com/iamletenkov/cream-extensions/commit/3fad49397b11ae6c2aec837737422c829a818001))
* **stvor-agent:** пин агента 4.1.0 и учёт службы телеметрии ([#59](https://github.com/iamletenkov/cream-extensions/issues/59)) ([753157d](https://github.com/iamletenkov/cream-extensions/commit/753157dda3a2ab3daa1998332356b8d96a204fc8))

## [5.5.0](https://github.com/iamletenkov/cream-extensions/compare/v5.4.2...v5.5.0) (2026-10-22)


### Добавлено

* **teleport:** общее ядро lib/teleport-core.sh и расширение teleport-openwrt ([#52](https://github.com/iamletenkov/cream-extensions/issues/52)) ([781c270](https://github.com/iamletenkov/cream-extensions/commit/781c2706c946dd4af4242c73287036f83bb94fde))


### Исправлено

* **fetch:** selkies, code-server и rustdesk ставятся без cream install fetch ([#56](https://github.com/iamletenkov/cream-extensions/issues/56)) ([8bdec18](https://github.com/iamletenkov/cream-extensions/commit/8bdec18da2b1c2bb0244573fc2c27915e5909767))

## [5.4.2](https://github.com/iamletenkov/cream-extensions/compare/v5.4.1...v5.4.2) (2026-10-22)


### Исправлено

* **fetch:** загрузка больших файлов переживает обрыв соединения на curl 7.68 ([#53](https://github.com/iamletenkov/cream-extensions/issues/53)) ([ddd924e](https://github.com/iamletenkov/cream-extensions/commit/ddd924edf39964d8a60290d6c9d222343a79bf65))

## [5.4.1](https://github.com/iamletenkov/cream-extensions/compare/v5.4.0...v5.4.1) (2026-10-22)


### Исправлено

* **amneziawg:** интерфейс переживает wrt.cloudinit — стадия system и every_boot ([#49](https://github.com/iamletenkov/cream-extensions/issues/49)) ([17a8212](https://github.com/iamletenkov/cream-extensions/commit/17a82121a748f2497067907b267da42c62fb555f))

## [5.4.0](https://github.com/iamletenkov/cream-extensions/compare/v5.3.1...v5.4.0) (2026-10-22)


### Добавлено

* **openwrt:** корень extensions/openwrt — amneziawg, podkop, luci-apps для cream 1.3.0 ([#47](https://github.com/iamletenkov/cream-extensions/issues/47)) ([703418e](https://github.com/iamletenkov/cream-extensions/commit/703418eba621fd976236c190354dd88f0c50e413))

## [5.3.1](https://github.com/iamletenkov/cream-extensions/compare/v5.3.0...v5.3.1) (2026-10-21)


### Исправлено

* **catalog:** документация по задачам и README расширений по единому шаблону ([#44](https://github.com/iamletenkov/cream-extensions/issues/44)) ([ceb5263](https://github.com/iamletenkov/cream-extensions/commit/ceb52631b1487c895387edbb13522d664c46224f))

## [5.3.0](https://github.com/iamletenkov/cream-extensions/compare/v5.2.0...v5.3.0) (2026-10-21)


### Добавлено

* **catalog:** каталог под cream 1.2.0 — `hooks.configure.every_boot: true` и `cream: ">=1.2.0"` у 12 расширений (code-server, desktop, docker, firewall, jetson-stats, kiosk, pixelflux-tegra, pixelflux-v4l2m2m, rustdesk, selkies, vino-vnc, x11vnc; версии подняты минором), `wallpaper` — исключение `every-boot-not-needed` (3.0.1); правило `[every-boot]` в `lint-hooks` — ошибка по умолчанию; `cream check` по каталогу в CI (`tools/cream-check.sh`, `make cream-check`); `rustdesk` ставит повторную сверку `cream configure --again rustdesk`; L-раннер проверяет отметку configure на второй загрузке ([#42](https://github.com/iamletenkov/cream-extensions/issues/42)) ([4715dbd](https://github.com/iamletenkov/cream-extensions/commit/4715dbda7ba48f97d174711a514cba3372648045))
* **tools:** аудит хуков configure и правило every-boot в lint-hooks ([#39](https://github.com/iamletenkov/cream-extensions/issues/39)) ([3c7596b](https://github.com/iamletenkov/cream-extensions/commit/3c7596b9d033b5d3de157234915666fac0213b3e))

## [5.2.0](https://github.com/iamletenkov/cream-extensions/compare/v5.1.2...v5.2.0) (2026-10-21)


### Добавлено

* **stvor-agent:** пин агента 4.0.1 ([#37](https://github.com/iamletenkov/cream-extensions/issues/37)) ([6cc7c4c](https://github.com/iamletenkov/cream-extensions/commit/6cc7c4c110da36e19207c8c0b0dbc60ca24af6b4))

## [5.1.2](https://github.com/iamletenkov/cream-extensions/compare/v5.1.1...v5.1.2) (2026-10-20)


### Исправлено

* версия расширения растёт при каждом изменении его дерева ([#32](https://github.com/iamletenkov/cream-extensions/issues/32)) ([c5aeb4b](https://github.com/iamletenkov/cream-extensions/commit/c5aeb4b97016f283886753a9b3feabd297e6061a))

## [5.1.1](https://github.com/iamletenkov/cream-extensions/compare/v5.1.0...v5.1.1) (2026-10-20)


### Исправлено

* бэклог 5.0 — суммы исходников L4T, хеши PyPI, пароль jetpack; runbooks ([#28](https://github.com/iamletenkov/cream-extensions/issues/28)) ([3e7708b](https://github.com/iamletenkov/cream-extensions/commit/3e7708bfcca6e0bc7f8c376262c62801901e1021))

## [5.1.0](https://github.com/iamletenkov/cream-extensions/compare/v5.0.0...v5.1.0) (2026-10-20)


### Добавлено

* Jetson Nano (L4T r32) — cuda 10.2, yq на Ubuntu 18.04+, l4t-vendor-desktop, teleport на Ubuntu 20.04 ([#25](https://github.com/iamletenkov/cream-extensions/issues/25)) ([6e8c118](https://github.com/iamletenkov/cream-extensions/commit/6e8c11875ca29994b11755c8a44cf770529fe461))


### Исправлено

* remove не снимает чужие пакеты, can-usb сверяет архив до распаковки ([77b778d](https://github.com/iamletenkov/cream-extensions/commit/77b778d32719a093e924011554c1a95298773208))

## [5.0.0](https://github.com/iamletenkov/cream-extensions/compare/v4.0.0...v5.0.0) (2026-10-19)


### ⚠ BREAKING CHANGES

* каталог только на cream/v1. Расширения живут в `/opt/cream/ext/<имя>`, настройки — `/etc/cream/<имя>/config` (секреты — `secrets`, 0600), состояние — `/var/lib/cream/ext/<имя>`; `lib/` и раскладка 2 (`install.sh`, `configure.sh`, `knobs`) удалены из каталога и инструментов. nft: таблица `inet bisquite` → `inet cream`, цепочка `BISQUITE-INPUT` → `CREAM-INPUT`, без миграции загруженных правил. `extensions/openwrt` перенесён в bisquite (берёт файлы по тегу `v3.3.0`). `x11vnc`, `vino-vnc`, `selkies`, `code-server` без пароля не стартуют. Общее для всех: `/opt/bisquite/<имя>` → `/opt/cream/ext/<имя>`; `/etc/bisquite/<имя>/config` → `/etc/cream/<имя>/config`; `/var/lib/bisquite/<имя>` → `/var/lib/cream/ext/<имя>`; `bisquite-conf set|show <имя>` → `cream set|show <имя>`; `install.sh`, `configure.sh`, `knobs.apply` → `hooks/install|configure|apply`; `configure-<имя>.service` → `cream-configure@<имя>`; списки в ключах — через пробел. По расширениям:
    - `teleport` — `bisquite-teleport <команда>` → `cream run teleport <действие>`; юниты
      `bisquite-teleport-{apps,token,join}.*` → `teleport-{apps,token,join}.*`; метки `managed_by`,
      `bisquite_agent_version` не ставятся (признак агента — `stvor_agent`); `TELEPORT_TOKEN` →
      `TELEPORT_REGISTRATION_SECRET=-`; `labels-enable`, `pull`, `TELEPORT_LABELS_URL` удалены.
    - `desktop` (новое, вместо `lib/bisquite-desktop`, `lib/knobs/desktop`) — `bisquite-desktop set` →
      `cream set desktop`; `bisquite-desktop apply|defaults|status` → `cream run desktop …`;
      `bisquite-desktop install` → `depends: desktop`; `bisquite-desktop.service` →
      `cream-configure@desktop`; `50-bisquite-screen-{lock,blank}` → `50-desktop-screen-{lock,blank}`;
      `90-bisquite-disable-dpms` → `90-desktop-disable-dpms`; `xfce4-*.bisquite.xml` →
      `xfce4-*.desktop-ext.xml`.
    - `cloud-user`, `l4t` (новые библиотеки) — `lib/get_cloud_user.sh` →
      `/opt/cream/ext/cloud-user/get_cloud_user.sh`; `lib/l4t` → библиотека `l4t`.
    - `gnome`, `xfce4`, `lxde` — `conflicts` перечнем → `conflicts.capabilities: [desktop-session]`;
      `lightdm.conf` из шаблона → drop-in `/etc/xdg/lightdm/lightdm.conf.d/60-<стол>.conf`; браузер —
      только `firefox-esr`; `gnome` — `WaylandEnable=false` в конфиге пакета.
    - `cloud-user-desktop` — ручки стола через `cream set desktop DESKTOP_AUTOLOGIN=1 …`.
    - `wallpaper` — `WALLPAPER_IMAGE=images/dst_1080.jpg` → `dst_1080.jpg`; копии
      `/usr/share/backgrounds/bisquite-wallpaper.jpg` нет; dconf пользователя →
      `/etc/dconf/db/local.d/50-wallpaper`.
    - `locale` — `40-bisquite-locale` (dconf `local.d`, `gdm.d`) → `40-locale`.
    - `can` — нет ядра → код 20 вместо 1; `BISQUITE_CONF_ROOT` → `CREAM_ROOT`.
    - `docker` — `bisquite-docker-iptables-raw-check` → `docker-iptables-raw-check`;
      `10-bisquite-iptables-raw.conf` → `10-docker-iptables-raw.conf`;
      `/run/bisquite-docker/iptables-raw.env` → `/run/docker-iptables-raw/env`.
    - `firewall` — `bisquite-firewall.service` → `cream-configure@firewall` (стадия `early`);
      `bisquite-firewall show|backend|check` → `cream run firewall status|check`;
      `systemctl restart bisquite-firewall` → `cream run firewall reload`; `bisquite-firewall off` →
      `cream set firewall FIREWALL_ENABLE=0`; `/run/bisquite-firewall/` → `/run/firewall/`; тестовые
      `BISQUITE_FIREWALL_*` удалены.
    - `nocloud-cidata` — `zz-bisquite-nocloud.cfg` → `zz-cream-nocloud.cfg`.
    - `kiosk` — `run-kiosk.sh` → `/usr/local/lib/kiosk/run-kiosk.sh`; xfconf — в `/etc/xdg`,
      клавиатура — `/etc/dconf/db/local.d/50-kiosk-keyboard`; в `$HOME` не пишет; только Debian.
    - `chromium-kiosk` — ключ и репозиторий → `/etc/apt/keyrings/chromium-kiosk-salamek.asc`,
      `chromium-kiosk-salamek.sources`; системную локаль не меняет.
    - `rustdesk` — `BISQUITE_RUSTDESK_FOLLOWUP` → счётчик `/run/rustdesk/followup`.
    - `selkies` — `BISQUITE_SELKIES_ALLOW_NO_AUTH=true` → `SELKIES_ALLOW_NO_AUTH=1`;
      `SELKIES_ENABLE_BASIC_AUTH` не нужен (basic auth включает пароль).
    - `code-server` — `CODE_SERVER_PASSWORD=none` → `CODE_SERVER_ALLOW_NO_AUTH=1`; `CODE_SERVER_BIND`
      по умолчанию `127.0.0.1`; `CODE_SERVER_VERSION` и mkcert удалены (пин `.deb`, `cert: true`);
      `code-server@` не включается; остатки 4.x блокируют установку.
    - `x11vnc` — `X11VNC_PASSFILE` удалён (файл — `/etc/x11vnc/passwd`); `-nopw` — только
      `X11VNC_ALLOW_NO_PASSWORD=1`.
    - `vino-vnc` — домен `vino` → `vino-vnc`; `VINO_PASSWORD_FILE` удалён; автозапуск —
      `/etc/xdg/autostart`.
    - `pixelflux-tegra`, `pixelflux-v4l2m2m` — `verify-<имя>.service` → `cream-configure@<имя>`;
      отпечаток `.bisquite-<имя>` → `/var/lib/cream/ext/<имя>/stamp`;
      `/opt/bisquite/pixelflux-tegra-runtime/gbm_shim.so` →
      `/var/lib/cream/ext/pixelflux-tegra/gbm_shim.so`.
    - `sensing-gmsl2-camera` — `bisquite-sensing-camera-ctl` →
      `cream run sensing-gmsl2-camera camera-profile|boost-clock`; `bisquite-sensing-camera@.service`,
      `bisquite-sensing-clock.service` → `sensing-gmsl2-camera@.service`, `sensing-gmsl2-clock.service`;
      `99-bisquite-sensing-camera.rules` → `99-sensing-gmsl2-camera.rules`;
      `bisquite-sensing-gmsl2.conf` (modprobe.d) → `sensing-gmsl2-camera.conf`;
      `SENSING_CAMERA_PKG_REL` удалён.
    - `l4t-boot-verify` — `bisquite-l4t-boot-verify.service` → `l4t-boot-verify.service`.
    - `nvidia-jetpack` — `phase: [build]` → `targets: {build: exec, live: confirm}`; скрипты —
      `/opt/cream/ext/nvidia-jetpack/scripts/`.

### Добавлено

* каталог на формате cream/v1 ([f163a3f](https://github.com/iamletenkov/cream-extensions/commit/f163a3f71b4a1b96fc28797c3978ae8e567c7d6e))

## [4.0.0](https://github.com/iamletenkov/cream-extensions/compare/v3.3.0...v4.0.0) (2026-10-19)


### ⚠ BREAKING CHANGES

* расширение teleport-agent удалено; apps.d переехал в /etc/cream/teleport/apps.d/.

### Добавлено

* пилот cream/v1 — расширения teleport и stvor-agent ([abfaa52](https://github.com/iamletenkov/cream-extensions/commit/abfaa52be924a2e9f49ee3115a9e42c2564466f8))

## [3.3.0](https://github.com/iamletenkov/bisquite-extensions/compare/v3.2.0...v3.3.0) (2026-10-15)


### Добавлено

* **can-usb:** модули gs_usb, peak_usb и slcan для ядра Sensing на AGX Orin ([89ec546](https://github.com/iamletenkov/bisquite-extensions/commit/89ec546d866809dca39da28c5d0db91e26851ba2))
* **can-usb:** модули gs_usb, peak_usb и slcan для ядра Sensing на AGX Orin ([da67136](https://github.com/iamletenkov/bisquite-extensions/commit/da671366f58463a20120f06300941c6cd0c1fe45))

## [3.2.0](https://github.com/iamletenkov/bisquite-extensions/compare/v3.1.0...v3.2.0) (2026-10-15)


### Добавлено

* **firewall:** iptables-legacy backend for kernels without nft_ct ([46e6876](https://github.com/iamletenkov/bisquite-extensions/commit/46e6876837b50de0d4a3489ddad58f60aaec2223))
* **sensing-gmsl2-camera:** pin the L4T kernel packages at build time ([2372fba](https://github.com/iamletenkov/bisquite-extensions/commit/2372fba17c3608d80fad289f3a34558ed889d0e9))

## [3.1.0](https://github.com/iamletenkov/bisquite-extensions/compare/v3.0.0...v3.1.0) (2026-10-15)


### Добавлено

* **can:** arm64 and L4T kernels are checked without linux-modules-extra ([390643d](https://github.com/iamletenkov/bisquite-extensions/commit/390643d0df657fc58c414f74cc97dfb4ed93b695))
* **rustdesk:** arm64 installs the aarch64 release package with its own pinned sha256 ([58ddcfa](https://github.com/iamletenkov/bisquite-extensions/commit/58ddcfa2eae9a3f4e43d24bc3f6cd820510978e6))


### Исправлено

* **firewall:** refuse an image kernel without nft_ct instead of booting unfiltered ([1b79f87](https://github.com/iamletenkov/bisquite-extensions/commit/1b79f87fe1e2764c6599dc082e3a3e970f9ca281))

## [3.0.0](https://github.com/iamletenkov/bisquite-extensions/compare/v2.0.0...v3.0.0) (2026-10-14)


### ⚠ BREAKING CHANGES

* **nvidia:** Ubuntu 20.04 dropped; a missing branch is a build error.

### Добавлено

* **can:** CAN modules for the image kernel, can-utils and autoload list ([8885cca](https://github.com/iamletenkov/bisquite-extensions/commit/8885cca81fb1242895dcf792ecf64214bc5d977d))
* **firewall:** nftables table inet bisquite rebuilt on every boot, Docker chains untouched ([c8d91d5](https://github.com/iamletenkov/bisquite-extensions/commit/c8d91d54f887023f99aa5f6333e8108c6f5a7a4d))
* **locale:** system locale and keyboard layouts for console, Xorg/GDM and GNOME ([3dc3397](https://github.com/iamletenkov/bisquite-extensions/commit/3dc33970fcb23d456fb6e22fc52cc304704ba903))
* **nvidia:** 2.0.0 — pinned driver branch built for the image kernel; add nvidia-container-toolkit 1.0.0 ([4bf2c86](https://github.com/iamletenkov/bisquite-extensions/commit/4bf2c864e0d3ecb10f6c99a66f2c44f162004d9f))
* robot workstation extensions — nvidia 2.0, container toolkit, can, firewall, locale, rustdesk ([5a03da3](https://github.com/iamletenkov/bisquite-extensions/commit/5a03da3f3d467073b51b9a400d8e02c472ff5eae))
* **rustdesk:** pinned .deb, server settings rendered per device, no identity in the image ([464bc09](https://github.com/iamletenkov/bisquite-extensions/commit/464bc09c22d63cd7b610423163b6a07897745aa3))
* **teleport-agent:** 3.1.0 pins bisquite-teleport-agent 3.1.0 ([6ffd94f](https://github.com/iamletenkov/bisquite-extensions/commit/6ffd94f26fa1cb7b8f8b856b209a93bd4f52fc58))
* **teleport-agent:** 3.1.0 pins bisquite-teleport-agent 3.1.0 — join waits for the network and retries ([a4190ad](https://github.com/iamletenkov/bisquite-extensions/commit/a4190ad568f65c52fb4c19fb183cb2a2af2171fb))


### Исправлено

* **firefox:** trust only the pinned Mozilla key, not every key in the downloaded file ([06a3680](https://github.com/iamletenkov/bisquite-extensions/commit/06a36806e847df24c4401a594bb7264eb7d36394))
* **locale:** typed empty xkb-options so dconf update accepts the GNOME defaults ([7d20348](https://github.com/iamletenkov/bisquite-extensions/commit/7d20348e0b0f7a17db315d3a022acb7a9db94d8a))
* **nvidia-container-toolkit:** a missing daemon.json is not a default-runtime change ([80b9009](https://github.com/iamletenkov/bisquite-extensions/commit/80b9009ea988682ccaad08aad56a5704f1f3897c))
* **nvidia:** name an OOM-killed DKMS build and the --memsize that fixes it ([25246fa](https://github.com/iamletenkov/bisquite-extensions/commit/25246fac5d1db6d824cdae4d603cfa57be47d220))
* **nvidia:** trust only the pinned repository key, not every key in the downloaded file ([212cd44](https://github.com/iamletenkov/bisquite-extensions/commit/212cd441a5470c66c5f9e23d921c291d4f7fe57f))
* **rustdesk:** re-check the rendered server settings after RustDesk's first run ([b889084](https://github.com/iamletenkov/bisquite-extensions/commit/b88908409480ad2b4a56da90589eb6aab09c9e4e))
