# amneziawg

Интерфейс AmneziaWG на OpenWrt: ключ машины, интерфейс netifd `proto amneziawg` и пир
сервера в `/etc/config/network` из параметров. Пакеты (`kmod-amneziawg`,
`amneziawg-tools`, `luci-proto-amneziawg`) — из образа openwrt-builder, расширение их
только настраивает.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | OpenWrt ≥ 25.12 |
| Архитектура | amd64, arm64 |
| cream | ≥ 1.3.0 |
| Даёт | `vpn-amneziawg` |
| Требует | — |
| Зависит от | — |
| Конфликтует с | — |
| Хуки | `install`, `configure`, `remove` |
| Настройка на загрузке | стадия `early`, по отметке выполнения |
| Действия | `cream run amneziawg pubkey` |
| Живая машина | да |
<!-- /catalog:facts -->

## Что делает

- **`install`** — проверяет пакеты образа (`kmod-amneziawg`, `amneziawg-tools`); нет —
  код 20 «здесь неприменимо», ничего не меняет. Модуль ядра собран под ядро выпуска
  OpenWrt и в фидах его нет: пакеты приходят только с образом
  [openwrt-builder](https://github.com/iamletenkov/openwrt-builder) v0.3.0+.
- **`configure`** — закрытый ключ: секрет `AMNEZIAWG_PRIVATE_KEY`, а если он пуст —
  ключ, сгенерированный на машине (`awg genkey`) при первом запуске и сохранённый в
  `/opt/cream/var/ext/amneziawg/private.key` (0600). Интерфейс и секция пира
  `<интерфейс>_peer` пишутся одним `uci batch` со stdin — ключи не попадают в argv;
  `/etc/config/network` получает режим 0600. На живой машине (не на загрузке) —
  `ubus call network reload` и `ifup` фоном.
- **`remove`** — интерфейс и все его пиры из `/etc/config/network` (на живой машине —
  `ifdown` и перечитывание netifd). Ключ остаётся в состоянии до `cream remove --purge`.
- **`files`** — `/lib/upgrade/keep.d/amneziawg`: `sysupgrade` сохраняет ключ машины
  (только состояние; само расширение после обновления прошивки ставится заново).
- **Действие `pubkey`** — открытый ключ машины для сервера: `cream run amneziawg pubkey`.

## Параметры

<!-- catalog:params -->
| Ключ | Тип | Умолчание | Что задаёт |
|---|---|---|---|
| `AMNEZIAWG_IFACE` | строка `^[a-z][a-z0-9_]{0,10}$` | `awg0` | имя интерфейса netifd и устройства (до 11 знаков: пир — секция <имя>_peer) |
| `AMNEZIAWG_PRIVATE_KEY` | строка `^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw480]=$` | пусто | закрытый ключ (base64); пусто — генерируется на машине при первом configure и хранится в состоянии *(секрет: `KEY=-` со stdin или `--params-file`, не в argv)* |
| `AMNEZIAWG_ADDRESSES` | список через пробел, элемент `^[0-9a-fA-F.:]{2,39}/[0-9]{1,3}$` | пусто | адреса интерфейса CIDR через пробел (10.8.0.2/32) |
| `AMNEZIAWG_LISTEN_PORT` | строка `^[0-9]{1,5}$` | пусто | порт прослушивания; пусто — случайный |
| `AMNEZIAWG_MTU` | строка `^[0-9]{3,4}$` | пусто | MTU; пусто — умолчание netifd |
| `AMNEZIAWG_JC` | строка `^[0-9]{1,5}$` | пусто | обфускация Jc — число мусорных пакетов (как на сервере) |
| `AMNEZIAWG_JMIN` | строка `^[0-9]{1,5}$` | пусто | обфускация Jmin |
| `AMNEZIAWG_JMAX` | строка `^[0-9]{1,5}$` | пусто | обфускация Jmax |
| `AMNEZIAWG_S1` | строка `^[0-9]{1,5}$` | пусто | обфускация S1 |
| `AMNEZIAWG_S2` | строка `^[0-9]{1,5}$` | пусто | обфускация S2 |
| `AMNEZIAWG_S3` | строка `^[0-9]{1,5}$` | пусто | обфускация S3 (AmneziaWG 2) |
| `AMNEZIAWG_S4` | строка `^[0-9]{1,5}$` | пусто | обфускация S4 (AmneziaWG 2) |
| `AMNEZIAWG_H1` | строка `^[0-9]{1,10}(-[0-9]{1,10})?$` | пусто | обфускация H1 (число или диапазон a-b) |
| `AMNEZIAWG_H2` | строка `^[0-9]{1,10}(-[0-9]{1,10})?$` | пусто | обфускация H2 |
| `AMNEZIAWG_H3` | строка `^[0-9]{1,10}(-[0-9]{1,10})?$` | пусто | обфускация H3 |
| `AMNEZIAWG_H4` | строка `^[0-9]{1,10}(-[0-9]{1,10})?$` | пусто | обфускация H4 |
| `AMNEZIAWG_PEER_PUBLIC_KEY` | строка `^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw480]=$` | пусто | открытый ключ сервера; пусто — интерфейс без пира |
| `AMNEZIAWG_PEER_PRESHARED_KEY` | строка `^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw480]=$` | пусто | общий ключ пира (base64), если сервер его требует *(секрет: `KEY=-` со stdin или `--params-file`, не в argv)* |
| `AMNEZIAWG_PEER_ENDPOINT` | строка `^([A-Za-z0-9.-]{1,253}\|\[[0-9a-fA-F:]{2,39}\]):[0-9]{1,5}$` | пусто | адрес сервера host:порт ([IPv6]:порт) |
| `AMNEZIAWG_PEER_ALLOWED_IPS` | список через пробел, элемент `^[0-9a-fA-F.:]{2,39}/[0-9]{1,3}$` | `0.0.0.0/0 ::/0` | сети через туннель (allowed_ips пира) |
| `AMNEZIAWG_PEER_KEEPALIVE` | строка `^[0-9]{1,5}$` | `25` | persistent keepalive, с; пусто — выключен |
| `AMNEZIAWG_ROUTE_ALLOWED_IPS` | `bool` | `0` | 1 — маршруты на allowed_ips через туннель (весь трафик при 0.0.0.0/0); 0 — маршрутизацию решает другой (podkop) |
<!-- /catalog:params -->

Параметры обфускации (`AMNEZIAWG_JC` … `AMNEZIAWG_H4`) должны совпадать с сервером;
пустые не пишутся. `AMNEZIAWG_I1`–`I5` (сигнатурные пакеты AmneziaWG 2) расширение не
задаёт — см. «Известные ограничения». Все значения попадают в `uci batch` в одинарных
кавычках, поэтому типы ключей не допускают кавычек, пробелов и обратной косой.

## Установка

На машине с OpenWrt и подключённым каталогом ([cream на OpenWrt](https://github.com/iamletenkov/cream/blob/main/docs/guides/openwrt.md)):

```sh
cream install amneziawg AMNEZIAWG_ADDRESSES=10.8.0.2/32 \
  AMNEZIAWG_PEER_PUBLIC_KEY=<ключ сервера> AMNEZIAWG_PEER_ENDPOINT=vpn.example.org:51820 \
  AMNEZIAWG_JC=4 AMNEZIAWG_JMIN=40 AMNEZIAWG_JMAX=70
cream run amneziawg pubkey          # открытый ключ — на сервер
```

В образе bisquite (VMFILE):

```dockerfile
RUN_COMMAND cream install amneziawg AMNEZIAWG_ADDRESSES=10.8.0.2/32 AMNEZIAWG_PEER_PUBLIC_KEY=<ключ> AMNEZIAWG_PEER_ENDPOINT=vpn.example.org:51820
```

Закрытый ключ в образ не кладите: без `AMNEZIAWG_PRIVATE_KEY` у каждой машины свой ключ
с первой загрузки (ключ, заданный при сборке, `install` встречает предупреждением: он
останется в образе и будет у всех его машин). `scope: build` здесь не помогает — ключ нужен
`configure` в `/etc/config/network` машины. Если ключ всё же задан — только секретом: `KEY=-` со stdin или
`--params-file` (в VMFILE — `--mount=type=secret`), не литералом.

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | проверка пакетов образа; в сборке configure только включается (стадия `early`) |
| загрузка (`S19cream-configure-early`, до `S20network`) | ключ (первая загрузка — генерация), интерфейс и пир в uci; сеть поднимает их сама. Дальше — только если что-то изменилось (отметка выполнения) |
| `cream set` | хук `configure` сразу: uci, `network reload`, `ifup` фоном |
| `cream remove` | интерфейс и пиры из uci; `--purge` убирает и ключ |

## Известные ограничения

- Только образы openwrt-builder v0.3.0+ (OpenWrt 25.12, `apk`): модуля `kmod-amneziawg` в
  фидах OpenWrt нет.
- Один пир на интерфейс (секция `<интерфейс>_peer`). Интерфейс расширение считает своим
  целиком: `configure` и `remove` переписывают **все** секции `amneziawg_<интерфейс>`,
  в том числе пиры, добавленные вручную или через LuCI.
- Зону файрвола интерфейсу расширение не назначает: маршрутизацией и правилами занимается
  [podkop](../podkop/README.md) (режим `vpn`) или администратор.
- `AMNEZIAWG_I1`–`I5`, `S3`/`S4` в связке с серверами AmneziaWG 1.x — не проверялись.

## Подробности

### Почему configure не на каждой загрузке

Признаки А1–А6 ([настройка на загрузке](../../../docs/guides/configure-lifecycle.md)): uci и
ключ лежат на диске (`/etc/config`, `/opt/cream/var`) и живут до перезагрузки (не А1);
пользователей и железа хук не касается (не А2, А3, А6), повтор себе не ставит (не А4),
файлов, которые переписывает приложение, не правит (не А5). Интерфейс на каждой загрузке
поднимает netifd. `every_boot` не нужен.

### Стадия `early`

Скрипт `S19cream-configure-early` идёт до `S20network`: на первой загрузке интерфейс уже
в конфиге, когда netifd стартует, — без перезапуска сети.

## Проверки

- **V** — `make cream-validate`, `make cream-check` (openwrt:25.12), `tools/lint-hooks.sh`.
- **H** — `tests/test-amneziawg.sh`: пакеты образа и код 20, генерация ключа один раз,
  ключи из `CREAM_SECRETS_FILE` и не в argv, пакет `uci batch`, смена имени интерфейса,
  netifd только на живой машине, `remove`, действие `pubkey`.
- **L** — `make test-openwrt` (`tools/test-openwrt.sh`): корневая ФС openwrt-builder v0.3.0
  в контейнере, настоящие cream, `uci` и `awg`: сборка, «загрузка» `S19`, интерфейс в
  `/etc/config/network`, ключ 0600, `pubkey`, вторая загрузка — пропуск по отметке, `remove`.
