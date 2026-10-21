# firefox

Firefox из APT-репозитория Mozilla (`packages.mozilla.org`) — настоящий
`.deb`, а не снап.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | amd64, arm64 |
| cream | ≥ 1.0.0 |
| Даёт | `web-browser` |
| Требует | — |
| Зависит от | [`apt-guard`](../apt-guard/README.md) |
| Конфликтует с | — |
| Хуки | `install`, `remove` |
| Настройка на загрузке | — |
| Живая машина | да |
<!-- /catalog:facts -->

## Что делает

- **`install`** — подключает репозиторий Mozilla с пином и ставит `firefox`
  (и языковой пакет, если задан `FIREFOX_LANGPACK`); для скачивания ключа ставит
  `ca-certificates`, `curl`, `gnupg`. Если после установки остался snap-пакет —
  отказ. Кладёт в систему:

| Путь | Что |
|---|---|
| `/etc/apt/keyrings/packages.mozilla.org.asc` | ключ репозитория; в файле должен быть ровно один основной ключ с отпечатком `35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3`; записывается экспорт этого ключа, не скачанный файл |
| `/etc/apt/sources.list.d/mozilla.list` | `deb https://packages.mozilla.org/apt mozilla main` |
| `/etc/apt/preferences.d/mozilla` | `Pin-Priority: 1000` для `firefox*` с этого источника |
| `/usr/lib/firefox/` | сам браузер; `x-www-browser` указывает на него |
| `/var/lib/cream/ext/firefox/packages` | пакеты, которые поставил `install` (не стоявшие до него) |

  Пин нужен, чтобы заменить транзитный пакет: у него эпоха `1:`, и без пина
  apt считает его новее. Пин ограничен пакетами `firefox*`, чтобы репозиторий
  Mozilla не перехватывал ничего другого.
- **`remove`** — `apt-get purge` пакетов из `/var/lib/cream/ext/firefox/packages`,
  затем ключ, источник и пин Mozilla и `apt-get update`.

## Параметры

<!-- catalog:params -->
| Ключ | Тип | Умолчание | Что задаёт |
|---|---|---|---|
| `FIREFOX_LANGPACK` | строка `^[a-z]{2,3}(-[A-Za-z]{2,4})?$` | пусто | языковой пакет: ru → firefox-l10n-ru; пусто — без него *(только при установке)* |
<!-- /catalog:params -->

`FIREFOX_LANGPACK` — код вида `ru`, `pt-BR`; `scope: install`: смена ключа через
`cream set` перезапускает `install`.

## Установка

На машине с подключённым каталогом ([как подключить](../../../docs/getting-started.md)):

```bash
sudo cream install --with-deps firefox FIREFOX_LANGPACK=ru
cream show firefox
sudo cream remove firefox
```

В образе bisquite (VMFILE):

```dockerfile
RUN_COMMAND cream install --with-deps firefox FIREFOX_LANGPACK=ru
```

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | репозиторий, ключ и пин Mozilla, пакет `firefox` и языковой пакет |
| загрузка | ничего: хука `configure` нет |
| `cream set FIREFOX_LANGPACK=…` | ключ `scope: install` — `install` перезапускается |
| `cream remove` | снимает свои пакеты, ключ, источник и пин |

## Известные ограничения

- Firefox, стоявший до cream (на Ubuntu — транзитный пакет, который `install`
  заменил сборкой Mozilla), `remove` не удаляет: после `remove` остаётся сборка
  Mozilla без источника обновлений. `ca-certificates`, `curl`, `gnupg` тоже
  остаются.
- Версия браузера фиксируется на момент сборки: разные образы, собранные в
  разные дни, получат разные версии Firefox. Дальше браузер обновляется обычным
  `apt upgrade` из того же репозитория.

## Подробности

### Зачем

На Ubuntu 22.04 и новее пакет `firefox` из дистрибутива транзитный
(`1:1snap1-0ubuntu2`): он ставит снап при первом запуске. В образах bisquite
snapd не посеян, и без сети на первой загрузке браузера нет. Так было на
роботе AGX Orin: ярлык есть, запуск отвечает «requires the firefox snap».
Chromium на arm64 устроен так же. Mozilla собирает amd64 и arm64 сама,
поэтому браузер ставится на сборке и работает без сети.

### Проверено на

AGX Orin, L4T 36.4.3 (Ubuntu 22.04, arm64), 2026-09-14: транзитный пакет
заменён, `firefox --version` — `Mozilla Firefox 155.0.1`, установлен
`firefox-l10n-ru`.

## Проверки

- **V** — `make cream-validate`, `tools/check-names.sh`.
- **H** — `tests/test-firefox.sh`: ключ (отпечаток, ровно один основной), источник
  и пин, языковой пакет, отказ при оставшемся snap-пакете, повтор без изменений
  файлов, `remove` только своего.
- **L** — `make test-live EXT=firefox` на `debian-12` и `ubuntu-24.04`
  (`tests/live.env`; сеть до `packages.mozilla.org`).
