# firefox

Firefox из APT-репозитория Mozilla (`packages.mozilla.org`) — настоящий
`.deb`, а не снап.

```
cream install firefox FIREFOX_LANGPACK=ru           # живая машина
cream remove firefox
EXTENSION firefox FIREFOX_LANGPACK=ru               # образ bisquite
```

> **С 2.0.0 — cream/v1.** `install.sh` стал хуком `hooks/install`, появился хук
> `remove`; `FIREFOX_LANGPACK` — ключ настроек `config.keys` (`scope: install`:
> смена ключа через `cream set` перезапускает `install`). Каталог в госте —
> `/opt/cream/ext/firefox/`.

## Зачем

На Ubuntu 22.04 и новее пакет `firefox` из дистрибутива транзитный
(`1:1snap1-0ubuntu2`): он ставит снап при первом запуске. В образах bisquite
snapd не посеян, и без сети на первой загрузке браузера нет. Так было на
роботе AGX Orin: ярлык есть, запуск отвечает «requires the firefox snap».
Chromium на arm64 устроен так же. Mozilla собирает amd64 и arm64 сама,
поэтому браузер ставится на сборке и работает без сети.

## Параметры

| Ключ | Умолчание | Что делает |
|---|---|---|
| `FIREFOX_LANGPACK` | пусто | языковой пакет: `ru` → `firefox-l10n-ru` (код вида `ru`, `pt-BR`) |

## Что кладётся в систему

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

## Что снимает `remove`

`apt-get purge` пакетов из `/var/lib/cream/ext/firefox/packages`, затем ключ,
источник и пин Mozilla и `apt-get update`. Firefox, стоявший до cream (на Ubuntu —
транзитный пакет, который `install` заменил сборкой Mozilla), не удаляется:
после `remove` остаётся сборка Mozilla без источника обновлений. `ca-certificates`,
`curl`, `gnupg`, которые `install` ставит для скачивания ключа, остаются.

## Обновления

Браузер обновляется обычным `apt upgrade` из того же репозитория. Сборка
фиксирует версию на момент сборки; разные образы, собранные в разные дни,
получат разные версии Firefox.

## Проверки

- **V** — `make cream-validate`, `tools/check-names.sh`.
- **H** — `tests/test-firefox.sh`: ключ (отпечаток, ровно один основной), источник
  и пин, языковой пакет, отказ при оставшемся snap-пакете, повтор без изменений
  файлов, `remove` только своего.
- **L** — `make test-live EXT=firefox` на `debian-12` и `ubuntu-24.04`
  (`tests/live.env`; сеть до `packages.mozilla.org`).

AGX Orin, L4T 36.4.3 (Ubuntu 22.04, arm64), 2026-09-14: транзитный пакет
заменён, `firefox --version` — `Mozilla Firefox 155.0.1`, установлен
`firefox-l10n-ru`.
