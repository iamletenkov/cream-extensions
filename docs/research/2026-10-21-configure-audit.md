# Аудит хуков configure: кому нужен `every_boot`

> 2026-10-21. Вход для Task 3 и Task 19 плана cream
> `docs/plans/2026-10-21-bisquite-bundled-cream.md`; признаки А1–А6 — спека cream
> `docs/specs/2026-10-21-bisquite-bundled-cream.md` §10.7. Каталог — 5.2.0 (пин cream 1.1.4).

## Зачем
С cream 1.2.0 хук configure на загрузке идёт, только если нет отметки выполнения или она устарела (версия, дерево,
параметры, `secrets_rev`, `machine_id`). Хуку, которому одного успешного прогона мало, нужен
`hooks.configure.every_boot: true` (и `cream: ">=1.2.0"`, спека §10.9) — иначе после перезагрузки он не запустится.
Признак `every_boot` — **любой** из А1–А6:

| № | Признак |
|---|---|
| А1 | восстанавливает состояние, не живущее до перезагрузки (правила ядра, `ip link`, `/run`, модули, запущенный, но не включённый юнит) |
| А2 | перебирает пользователей или домашние каталоги (`getent passwd`, `/home/*`, UID 1000+) |
| А3 | ждёт пользователя cloud-init (`get_cloud_user.sh`, стадия `cloud-user`) |
| А4 | сам перезапускает `cream-configure@<ext>` (таймер повтора) |
| А5 | правит файлы, которые переписывает само приложение |
| А6 | зависит от железа (GPU, кодер, `/dev/*`, плата Jetson) |

Хуки читались целиком вместе с файлами, которым они передают работу (`exec "$CREAM_EXT_DIR/files/…"`). Строки —
номера в каталоге 5.2.0 (`8e9d63f`).

## Таблица решений
| Расширение | Стадия | Признаки (подтверждено чтением) | `every_boot` | Обоснование | `--again` вместо `systemctl restart` |
|---|---|---|---|---|---|
| `chromium-kiosk` | system | нет: собирает `/etc/chromium-kiosk/config.yml` только из ключей (`hooks/configure:135`) | **нет** | вход — только параметры cream; файл живёт до перезагрузки, приложение его не переписывает | нет |
| `code-server` | cloud-user | А1: экземпляр не включён, configure запускает его на каждой загрузке (`files/code-server.sh:50`, `:394`); А2: `getent passwd`, `config.yaml` в домашнем каталоге (`:277`); А3: `get_cloud_user` (`:56`, `:275`) | **да** | без прогона на загрузке сервис после перезагрузки не стартует | нет |
| `desktop` | system | А2: `getent passwd`, группы `video`/`render`… пользователю (`files/desktop.sh:82`, `:115`); А3: `get_cloud_user`, ожидание до 30 с, без пользователя автологин выключается (`:33`, `:554`) | **да** | пользователь, появившийся позже первого прогона, без групп и автологина; А4 из предварительной выборки не подтвердился — перезапускается менеджер входа, не configure | нет |
| `docker` | system | А3: `get_cloud_user`, «группа назначится на следующей» загрузке (`hooks/configure:37`, `:56`); А6: `nv_tegra_release` + `nvidia-ctk`, `cmdline.txt` Pi (`:103`, `:81`) | **да** | гонка с cloud-init на первой загрузке закрывается повтором; среда NVIDIA зависит от платы | нет |
| `firewall` | early | А1: правила nftables/iptables-legacy в ядре, без сохранения; `/run/firewall` (`firewall.sh:51`, `:57`, `:186`) | **да** | после перезагрузки правил нет — без прогона машина открыта; А4 не подтвердился (только комментарий) | нет |
| `jetson-stats` | cloud-user | А2/А3: `get_cloud_user` + `getent passwd`, пользователь в группу `jtop` (`hooks/configure:21`, `:35`); А6: `/etc/nv_tegra_release` (`:23`) | **да** | новый или сменившийся пользователь cloud-init без группы не видит `jtop` | нет |
| `kiosk` | graphical | А2/А3: `get_cloud_user` с ожиданием 60 с, `getent passwd` (`hooks/configure:28`, `:103`); без пользователя браузер не включается | **да** | гонка с cloud-init и смена `KIOSK_USER`/пользователя лечатся повтором; А4 и А6 из предварительной выборки не подтвердились (комментарий; проверка `gnome-shell`, не железо) | нет |
| `pixelflux-tegra` | graphical | А6: узлы кодера `/dev/nvhost-msenc`, `/dev/v4l2-nvenc` (`hooks/configure:54`); А3: `get_cloud_user`, пользователь в группу `video`/`render` (`:26`, `:92`) | **да** | узел кодера и права на него появляются и меняются между загрузками | нет |
| `pixelflux-v4l2m2m` | graphical | А6: перебор `/dev/video*`, проба кодера (`hooks/configure:42`) — по тексту не ловится | **да** | проверка железа; устройство может появиться позже (с 1.2.0 «кодера нет» — кандидат на код `20`, §10.8) | нет |
| `rustdesk` | system | А1: счётчик повтора в `/run/rustdesk` (`hooks/configure:38`); А2: все UID 1000+ (`files/common.sh:50`, `hooks/configure:110`); А3: `get_cloud_user` (`:39`); А4: `systemd-run … restart cream-configure@rustdesk` (`:141`); А5: `RustDesk2.toml` переписывает приложение (`:97`, `:104`) | **да** | эталон спеки §10.7: цикл «каждая загрузка до сходимости» | **да**: `:140–141` — `cream configure --again rustdesk` вместо прямого `systemctl --no-block restart cream-configure@rustdesk.service` |
| `selkies` | graphical | А1: экземпляр не включён, configure запускает его на каждой загрузке (`files/selkies.sh:26`, `:196`); А3: `get_cloud_user` (`:34`, `:160`) | **да** | без прогона на загрузке Selkies после перезагрузки не стартует | нет |
| `vino-vnc` | system | А3: `get_cloud_user` (`files/vino-vnc.sh:49`, `:72`); А2: `getent passwd` для проверки личной группы (`:159`); база пароля получает группу пользователя | **да** | без пользователя на первом прогоне база пароля остаётся root-only и vino отказывает всем — нужен повтор | нет |
| `wallpaper` | cloud-user | А2/А3 по тексту: `get_cloud_user`, `getent passwd` (`files/wallpaper.sh:271`, `:273`) — только для предупреждения о личных настройках стола, в домашний каталог ничего не пишется | **нет** | пишет системные умолчания с блокировками dconf (`/etc`), они живут до перезагрузки; А5 (L4T `nvbackground.sh`) закрыт блокировкой, а не повтором; рабочий стол, поставленный позже, — `cream configure --force wallpaper`. В Task 19 — исключение `# cream-lint: every-boot-not-needed …` в хуке | нет |
| `x11vnc` | graphical | А3: `get_cloud_user` с ожиданием 30 с (`files/x11vnc.sh:48`, `:73`); без пользователя сервер не включается, файл пароля без владельца | **да** | гонка с cloud-init и смена пользователя лечатся повтором; юнит `x11vnc@<user>` включается (`systemctl enable`), но выбор пользователя — на каждой загрузке | нет |

Итого: `every_boot: true` — 12 расширений; без него — `chromium-kiosk` и `wallpaper` (последнему — комментарий-исключение,
иначе `lint-hooks` в режиме `error` даст находку). `pixelflux-v4l2m2m` гейт не видит (А6 по тексту не ловится) —
решение держится только этой таблицей. Перезапуск мимо отметки (`--again`) нужен одному `rustdesk`.

## Гейт `lint-hooks`
`tools/lint-hooks.sh`, правило `[every-boot]`: хук configure (и файлы расширения, которым он передаёт работу через
`"${CREAM_EXT_DIR…}/<путь>"`) с текстовым признаком А1–А4 без `hooks.configure.every_boot: true` и без
`# cream-lint: every-boot-not-needed <причина>` в хуке — находка. Режим `LINT_EVERY_BOOT=warn` (умолчание): строка в
выводе, код 0 — каталог 5.2.x с пином cream 1.1.4 объявить `every_boot` не может. На 5.2.0 — 12 предупреждений, ровно
строки «да» таблицы кроме `pixelflux-v4l2m2m` плюс `wallpaper`. Task 19 (каталог под cream 1.2.0) объявляет
`every_boot`, ставит исключение `wallpaper`, переключает CI на `LINT_EVERY_BOOT=error`.

## Что делает Task 19 по этой таблице
1. `hooks.configure.every_boot: true` и `cream: ">=1.2.0"` — 12 расширений из строк «да» (подъём версии каждого —
   `tools/check-version-bump.sh`).
2. `wallpaper/hooks/configure` — исключение с причиной «пользователь только для предупреждения, умолчания — системные».
3. `rustdesk` — `cream configure --again rustdesk` вместо прямого перезапуска юнита.
4. `LINT_EVERY_BOOT=error` в `tools/check.sh`.
