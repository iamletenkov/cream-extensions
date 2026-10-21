# luci-apps

Приложения LuCI из подписанных фидов OpenWrt (`apk`) по списку. Расширение помнит, что
поставило само, и снимает только это — пакеты образа и соседей не трогает.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | OpenWrt ≥ 25.12 |
| Архитектура | amd64, arm64 |
| cream | ≥ 1.3.0 |
| Даёт | — |
| Требует | — |
| Зависит от | — |
| Конфликтует с | — |
| Хуки | `install`, `remove` |
| Настройка на загрузке | — |
| Живая машина | да |
<!-- /catalog:facts -->

## Что делает

- **`install`** — отказ, если `/etc/apk/config` (или `APK_CONFIG` сборки) разрешает
  неподписанные пакеты (`allow-untrusted`); иначе `apk update` и `apk add` недостающих
  пакетов списка — подпись индекса и пакетов проверяет сам apk по `/etc/apk/keys`.
  Пакеты, которые расширение поставило раньше и которых больше нет в списке, — `apk del`.
  Поставленное записывается в `/opt/cream/var/ext/luci-apps/added`. В сборке образа
  (cream передаёт `IPKG_INSTROOT=/`) пакеты включаются без запуска; на живой машине
  сбрасываются кеши LuCI и `rpcd` перечитывается фоном.
- **`remove`** — `apk del` того, что поставило расширение.

## Параметры

<!-- catalog:params -->
| Ключ | Тип | Умолчание | Что задаёт |
|---|---|---|---|
| `LUCI_APPS_PACKAGES` | список через пробел, элемент `^luci-(app\|theme\|proto\|i18n\|mod)-[a-z0-9][a-z0-9._+-]{0,63}$` | пусто | пакеты LuCI через пробел (luci-app-sqm luci-i18n-sqm-ru) *(только при установке)* |
<!-- /catalog:params -->

Список — параметр установки (`scope: install`): поменять — `cream install luci-apps
LUCI_APPS_PACKAGES="…"`, хук `install` пойдёт снова и доведёт пакеты до списка.

## Установка

На машине с OpenWrt и подключённым каталогом ([cream на OpenWrt](https://github.com/iamletenkov/cream/blob/main/docs/guides/openwrt.md)):

```sh
cream install luci-apps LUCI_APPS_PACKAGES="luci-app-ddns luci-i18n-ddns-ru"
```

В образе bisquite (VMFILE):

```dockerfile
RUN_COMMAND cream install luci-apps LUCI_APPS_PACKAGES="luci-app-ddns luci-i18n-base-ru"
```

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | `apk update`, `apk add` недостающих из подписанных фидов, `apk del` выбывших своих |
| загрузка | ничего: хука `configure` нет, `uci-defaults` пакетов отрабатывают сами на первой загрузке |
| `cream install` с новым списком | то же, что при установке |
| `cream remove` | `apk del` своих пакетов |

## Известные ограничения

- Нужна сеть до `downloads.openwrt.org` (или зеркала из `/etc/apk/repositories.d/`) во время
  установки; версии пакетов — те, что в фиде выпуска на момент сборки (фиды выпуска
  OpenWrt не меняются, кроме исправлений).
- Только пакеты `luci-app-*`, `luci-theme-*`, `luci-proto-*`, `luci-i18n-*`, `luci-mod-*`;
  зависимости они тянут сами.
- Пакет, поставленный расширением и затем снятый вручную, `remove` и сокращение списка
  пропускают молча (расширение его просто забывает); если он остался в списке — `install`
  поставит его снова.

## Проверки

- **V** — `make cream-validate`, `make cream-check` (openwrt:25.12), `tools/lint-hooks.sh`.
- **H** — `tests/test-luci-apps.sh`: пустой список, только недостающее, повтор без
  изменений, сокращение списка снимает только своё, `remove`, отказ при `allow-untrusted`
  (и в `APK_CONFIG`), сбой `apk add`, кеши LuCI и `rpcd` на живой машине.
- **L** — `make test-openwrt` (`tools/test-openwrt.sh`): корневая ФС openwrt-builder v0.3.0
  в контейнере без сети, настоящий cream и `apk`: пустой список в сборке, отказ при
  `allow-untrusted`. Пакеты из подписанных фидов — на ВМ (сборка примера bisquite).
