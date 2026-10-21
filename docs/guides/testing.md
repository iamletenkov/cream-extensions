# Тестирование

Расширение проверяется на трёх уровнях: **V** — статика каталога, **H** — хуки на
подменённом корне, **L** — живой прогон настоящим cream в контейнере с systemd.
Четвёртый, **P**, — ручная проверка на железе или в сборке bisquite; README
расширения пишет, где она была.

```bash
make ci                                  # V и H, то же, что CI: shellcheck + tools/check.sh
make test-live EXT=<имя>                 # L на debian-12
make test-live EXT=<имя> DISTRO=ubuntu-24.04
```

Нужны bash, git, Python 3 с PyYAML (`apt install python3-yaml`) и docker; cream
берётся по пину [`tools/cream-pin.env`](../../tools/cream-pin.env) и работает в
контейнере `debian:12`. Хост общий: один `make ci` и один живой прогон за раз.

## V — статика каталога

| Проверка | Команда | Что ловит |
|---|---|---|
| `cream validate` | `make cream-validate` | манифесты, повторяющиеся имена, граф: `depends` на отсутствующее или цикл — ошибка, `requires` без поставщика — предупреждение; сверка юнитов с действиями |
| `cream check` | `make cream-check` | каждое расширение строкой образа на `debian:12/13`, `ubuntu:22.04/24.04` с поставщиками своих `requires`: платформа, `depends`, `requires`, `conflicts`, диапазон `cream:` |
| линт хуков | `tools/lint-hooks.sh` | шапки, `--no-block`, секреты в argv, `CREAM_*`, стадия и `every_boot` |
| гейт имён | `make check-names` | прежние пути, ключи, юниты сборщика |
| правило версий | `tools/check-version-bump.sh` | дерево расширения изменилось, а версия нет |
| документация | `tools/catalog-docs.sh --check`, `tools/check-links.sh` | устаревшие таблицы из манифестов, битые ссылки и якоря |
| shellcheck | `make lint` | скрипты расширений — уровень `warning`, остальное — `error` |

Каждое правило и его исключения — [правила проверок](../reference/lint-rules.md).

## H — хуки на подменённом корне

Тест расширения — исполняемый `extensions/debian/<имя>/tests/test-*.sh`, код 0 —
прошёл. `tools/check.sh` находит такие файлы сам. Обвязка — `tools/hooktest.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../../../tools/hooktest.sh"
ht_init
ht_root "$(dirname "$HERE")"              # свежий корень + копия расширения
ht_fake apt-get 'exit 0'                  # подставная команда с журналом вызовов
ht_hook install DEMO_COLOR=red; eq "install — 0" 0 "$?"
check "apt-get позван" ht_called '^apt-get install '
ht_done                                   # итог; код 0 — все проверки прошли
```

- `ht_hook <хук> [KEY=VALUE…]` — очищенное окружение, `CREAM_*`, несекретные ключи
  с умолчаниями, cwd — каталог расширения; `ht_secret` кладёт секрет в
  `CREAM_SECRETS_FILE`, `ht_action` зовёт действие.
- Опасные на хосте команды (`apt-get`, `dpkg`, `systemctl`, `curl`, …) закрыты
  сторожем с кодом 127, пока тест их не подставит.
- Полное описание — шапка `tools/hooktest.sh`, образец всех приёмов — `tools/test-hooktest.sh`.

Пишется **до** правки хука: сначала красный тест на поведение или отказ, потом код.

## L — живой прогон

`tools/live-test.sh` (`make test-live`): контейнер `debian:12`, `debian:13`,
`ubuntu:20.04`, `ubuntu:22.04` или `ubuntu:24.04` с systemd как PID 1 (без
`--privileged`), настоящий cream по пину, каталог — источник `path`. Сценарий:

1. зависимости из `LIVE_DEPS` (с `--allow-skip`);
2. `install`, повтор (`changed: false`), `install --reinstall` — ни один файл в
   `/etc`, `/opt/cream`, `/usr/local`, `/var/lib/cream/ext` не меняется;
3. две перезагрузки: `configure` на загрузке успешен и соблюдает отметку
   выполнения (с `every_boot` — отработал, без него — пропущен, код 20 — снял
   отметку), `systemctl --failed` пуст, нет `ordering cycle`;
4. значения секретов не видны в `ps`, журнале, реестре;
5. `remove`, если есть хук.

L-расширение — то, у которого есть `tests/live.env`: умолчания прогона (данные
`KEY=value`, не скрипт), флаги `make test-live ARGS='…'` их перекрывают.

| Ключ | Что задаёт |
|---|---|
| `LIVE_DISTROS` | дистрибутивы прогона (умолчание `debian-12 ubuntu-24.04`) |
| `LIVE_DEPS` | расширения, которые ставятся раньше (`apt-guard` — первым) |
| `LIVE_PARAMS`, `LIVE_SECRETS` | параметры и секреты установки |
| `LIVE_ACCEPT_RISK=1` | ставить с `--accept-risk` |
| `LIVE_EXPECT_SKIP=1` | `install` вправе ответить 20 (нет железа в контейнере) |
| `LIVE_BOOT_CONFIGURE=optional` | `configure` на загрузке вправе не отработать |
| `LIVE_FAILED_IGNORE` | ERE `^…$` юнитов, которые роняет контейнер, а не расширение; печатаются строкой «разрешено упасть» |
| `LIVE_CAPS`, `LIVE_MEMORY` | capabilities контейнера (`firewall` — `NET_ADMIN`), память |
| `LIVE_SNAPSHOT_IGNORE` | пути, которым разрешено меняться при `--reinstall` |
| `LIVE_NIGHTLY_ONLY=1` | тяжёлое расширение — только ночью и вручную, не на PR |

Журналы — `.scratchpad/live/<имя>-<дистрибутив>/`, итог — последняя строка
(`проверок N, не прошло M`). Разбор падений (расширение / стенд / окружение) —
[runbook 04](../runbooks/04_live-runs.md). Самопроверка раннера на фикстурах
`tools/testdata/live/` — `make test-live-self`.

## Где это идёт само

- **PR и push в `main`** — `.github/workflows/ci-release.yml`: gitleaks,
  `tools/check.sh`, `make lint`, сухой прогон снимка. Те же команды, что локально.
- **Живые прогоны** — `.github/workflows/live.yml`: на PR — изменённые
  L-расширения (и те, чьи `LIVE_DEPS` изменились; смена пина cream — все), ночью —
  все; матрицу считает `tools/live-matrix.sh`. Вручную:
  `gh workflow run live.yml -f ext=<имя>`.
- **pre-push** lefthook — `make ci`.
