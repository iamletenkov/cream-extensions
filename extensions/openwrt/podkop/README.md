# podkop

Выборочная маршрутизация на OpenWrt: [podkop](https://github.com/itdoginfo/podkop) с
sing-box ведёт через прокси (ссылка `vless://`, `ss://`, `trojan://`…) или через
VPN-интерфейс только трафик из списков сообществ и своих доменов. Пакеты `podkop`,
`luci-app-podkop` и `sing-box` — из образа openwrt-builder, расширение их только
настраивает через uci.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | OpenWrt ≥ 25.12 |
| Архитектура | amd64, arm64 |
| cream | ≥ 1.3.0 |
| Даёт | `selective-routing` |
| Требует | — |
| Зависит от | — |
| Конфликтует с | — |
| Хуки | `install`, `configure`, `remove` |
| Настройка на загрузке | стадия `system`, по отметке выполнения |
| Живая машина | да |
<!-- /catalog:facts -->

## Что делает

- **`install`** — проверяет пакеты образа (`podkop`, `sing-box`); нет — код 20 «здесь
  неприменимо», ничего не меняет.
- **`configure`** — секции `main` и `settings` в `/etc/config/podkop` одним `uci batch`
  со stdin (ссылка не попадает в argv), файл — 0600: ссылка несёт учётные данные прокси.
  Fail-closed: режим `proxy` без ссылки или `vpn` без интерфейса — podkop выключается
  (`/etc/init.d/podkop disable`, на живой машине и `stop`), предупреждение, код 0.
  Иначе — `enable`, на живой машине (не на загрузке) — `restart` фоном (podkop качает
  списки, хук его не ждёт).
- **`remove`** — снимает ссылку и интерфейс, выключает и останавливает podkop. Пакеты
  остаются: они часть образа.

## Параметры

<!-- catalog:params -->
| Ключ | Тип | Умолчание | Что задаёт |
|---|---|---|---|
| `PODKOP_CONNECTION_TYPE` | `proxy` \| `vpn` | `proxy` | proxy — через прокси по ссылке PODKOP_PROXY_STRING; vpn — через интерфейс PODKOP_INTERFACE |
| `PODKOP_PROXY_STRING` | строка `^(vless\|vmess\|trojan\|ss\|socks4\|socks4a\|socks5\|hysteria2\|hy2)://[!#-&(-\[\]-~]+$` | пусто | ссылка прокси (vless://…, ss://…, trojan://…); без неё режим proxy не включается *(секрет: `KEY=-` со stdin или `--params-file`, не в argv)* |
| `PODKOP_INTERFACE` | строка `^[a-z][a-z0-9_.-]{0,14}$` | пусто | интерфейс netifd для режима vpn (awg0 расширения amneziawg) |
| `PODKOP_COMMUNITY_LISTS` | список через пробел, элемент `^[a-z0-9_]{1,64}$` | `russia_inside` | списки сообществ podkop через пробел (russia_inside, youtube, telegram…) |
| `PODKOP_USER_DOMAINS` | список через пробел, элемент `^[A-Za-z0-9.-]{1,253}$` | пусто | свои домены через туннель, через пробел |
| `PODKOP_USER_SUBNETS` | список через пробел, элемент `^[0-9.]{7,15}(/[0-9]{1,2})?$` | пусто | свои подсети IPv4 через туннель (CIDR), через пробел |
| `PODKOP_SOURCE_INTERFACES` | список через пробел, элемент `^[a-z][a-z0-9_.-]{0,14}$` | `br-lan` | устройства, трафик которых маршрутизирует podkop |
<!-- /catalog:params -->

Ссылка `PODKOP_PROXY_STRING` — секрет: `KEY=-` со stdin или `--params-file`, не в argv.
Остальные настройки podkop (DNS, исключения, yacd, …) расширение не трогает: умолчания
образа или правка в LuCI («Службы → Podkop»). Повторный `configure` перезаписывает только
перечисленные здесь опции.

## Установка

На машине с OpenWrt и подключённым каталогом ([cream на OpenWrt](https://github.com/iamletenkov/cream/blob/main/docs/guides/openwrt.md)):

```sh
# через прокси: ссылка — со stdin
printf '%s' 'vless://…' | cream install podkop PODKOP_PROXY_STRING=-
# через туннель расширения amneziawg
cream install podkop PODKOP_CONNECTION_TYPE=vpn PODKOP_INTERFACE=awg0
```

В образе bisquite (VMFILE):

```dockerfile
RUN_COMMAND cream install amneziawg AMNEZIAWG_ADDRESSES=10.8.0.2/32 AMNEZIAWG_PEER_PUBLIC_KEY=<ключ> AMNEZIAWG_PEER_ENDPOINT=vpn.example.org:51820
RUN_COMMAND cream install podkop PODKOP_CONNECTION_TYPE=vpn PODKOP_INTERFACE=awg0
```

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | проверка пакетов образа; в сборке configure только включается (стадия `system`) |
| загрузка (`S95cream-configure`, до `S99podkop`) | uci podkop, `enable` или `disable` — podkop стартует сам своим `S99`. Дальше — только если что-то изменилось (отметка выполнения) |
| `cream set` | хук `configure` сразу: uci и `restart` фоном (или `stop` при fail-closed) |
| `cream remove` | ссылка и интерфейс сняты, podkop выключен |

## Известные ограничения

- Только образы openwrt-builder v0.3.0+ (OpenWrt 25.12): `podkop` в них — 0.7.24.
- Одна секция маршрутизации (`main`); `selector`/`urltest`, `outbound_json`, несколько
  секций — через LuCI или uci вручную (расширение их не трогает, но `main` перезапишет).
- `PODKOP_USER_SUBNETS` — только IPv4 (как в podkop).
- Выключение на загрузке (режим без ссылки или без интерфейса) действует со следующей
  загрузки: список `rc.d` procd уже прочитал, и `S99podkop` в этот раз стартует — и сам
  останавливается без исходящего соединения («Outbound section not found»).
- `luci-app-https-dns-proxy` с podkop конфликтует (оба правят `/etc/config/dhcp`) — в
  образе его нет.

## Подробности

### Почему configure не на каждой загрузке

Признаки А1–А6 ([настройка на загрузке](../../../docs/guides/configure-lifecycle.md)):
`/etc/config/podkop` на диске живёт до перезагрузки, правила nftables и sing-box
восстанавливает служба podkop своим `S99` (не А1); пользователей, железа, своего повтора и
файлов приложения хук не касается (не А2–А6). `every_boot` не нужен.

## Проверки

- **V** — `make cream-validate`, `make cream-check` (openwrt:25.12), `tools/lint-hooks.sh`.
- **H** — `tests/test-podkop.sh`: пакеты образа и код 20, режимы proxy и vpn, ссылка из
  `CREAM_SECRETS_FILE` и не в argv/выводе, 0600, fail-closed, enable/restart только на
  живой машине, `remove`.
- **L** — `make test-openwrt` (`tools/test-openwrt.sh`): корневая ФС openwrt-builder v0.3.0
  в контейнере, настоящие cream, uci и init-скрипт podkop: сборка, «загрузка» `S95`, режим
  `vpn` поверх `awg0`, `cream set` (proxy без ссылки — выключен, ссылка со stdin —
  включён), `/etc/config/podkop` 0600, `remove`.
