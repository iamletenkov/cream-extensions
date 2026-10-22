# Правила проверок

Всё ниже входит в `make ci` (`tools/lint.sh` + `tools/check.sh`) и в CI на каждый PR.
Находка печатается как `файл:строка: [правило] текст` или `файл:строка: текст`;
`tools/check.sh` доводит до конца все проверки, даже если первая упала.

| Проверка | Скрипт | Код ≠ 0, когда |
|---|---|---|
| shellcheck | `tools/lint.sh` (`make lint`) | скрипт расширения (хуки, действия, `files/`, `tests/`) с находкой уровня `warning`; остальной репозиторий — уровня `error` |
| линт хуков | `tools/lint-hooks.sh` | нарушено правило из таблицы ниже |
| `cream validate` | `tools/cream-validate.sh` | манифест не проходит схему cream, имя повторяется, `depends` на отсутствующее или цикл, юнит не сходится с действиями |
| `cream check` | `tools/cream-check.sh` | расширение не ставится строкой образа на одной из ОС матрицы; способности из `requires` никто не даёт |
| гейт имён | `tools/check-names.sh` | найдено прежнее имя сборщика (ниже) |
| правило версий | `tools/check-version-bump.sh` | дерево расширения изменилось с последнего тега `v*` (для потребителей ядра — и `lib/teleport-core.sh`), а `version` не выросла |
| таблицы из манифестов | `tools/catalog-docs.sh --check` | блок `catalog:*` в README устарел или маркеров нет |
| ссылки | `tools/check-links.sh` | относительная ссылка `.md` ведёт на несуществующий файл или заголовок |
| образцы контракта | `tools/check-contract-fixtures.sh` | образцы контракта `stvor-agent` ↔ `teleport` разошлись с пином `tools/contract-fixtures.sha256` |
| снимок | `tools/test-snapshot.sh` | две сборки снимка дают разные байты, cream его не принимает или ядро `lib/teleport-core.sh` лежит не у всех потребителей и не байт в байт |
| общее ядро | `tools/check-teleport-core.sh` | копия `teleport-core.sh` под `extensions/`, потребитель без строки `files/teleport-core.sh` в `files`, объявивший её не потребитель, staged-копия не равна `lib/` |
| тесты | `tools/test-*.sh`, `lib/tests/test-*.sh`, `extensions/*/*/tests/test-*.sh` | тест инструмента, общего кода или H-тест расширения не прошёл |

## Линт хуков: `tools/lint-hooks.sh`

Проверяет `hooks/*` и `actions/*` всех расширений (комментарии и `tests/` — нет).

| Правило | Что проверяет |
|---|---|
| `header` | shebang bash или sh; первая команда — `set -euo pipefail` (`set -eu` в sh) |
| `exec` | бит исполнения у `hooks/*` и `actions/*` |
| `hook-name` | имя хука из набора cream: `install upgrade configure apply secret remove check` |
| `systemctl-block` | блокирующий `systemctl start/restart/…` без `--no-block` в `apply`, `configure`, `secret` |
| `lock-none-set` | `cream set` / `cream config set` в действии с `lock: none` |
| `source-lib` | `source`/`.` пути `lib/` — общий код только библиотеками `kind: library` |
| `secret-argv` | секретный ключ (`config.keys.*.secret`, `params.*.secret: true`) в argv cream не как `KEY=-` |
| `cream-env` | присваивание `CREAM_*` или имя `CREAM_*`, которого cream не задаёт (опечатка) |
| `stage-cream` | `hooks.configure.stage: cloud-user` при `cream:` ниже `">=1.1.1"` |
| `every-boot` | хук `configure` (и файл расширения, которому он передаёт работу через `"${CREAM_EXT_DIR…}/путь"`) с текстовым признаком А1–А4 — `ip link`, `iptables`, `nft`, `modprobe`, запись в `/run/`; `getent passwd`, `/home/`, UID 1000; `get_cloud_user`; `cream-configure@` — без `hooks.configure.every_boot: true` и без строки `# cream-lint: every-boot-not-needed <причина>` в хуке |

`LINT_EVERY_BOOT=error` (умолчание, так гоняет `tools/check.sh`) делает находку
`every-boot` ошибкой, `warn` — предупреждением с кодом 0. Признаки А1–А6 —
[настройка на загрузке](../guides/configure-lifecycle.md#отметка-выполнения-и-every_boot).

## Гейт имён: `tools/check-names.sh`

Прежние имена сборщика не возвращаются ни в расширения, ни в документы:
прежние каталоги сборщика под `/opt`, `/etc` и `/var/lib`, его CLI и юниты,
ключи с префиксом прежнего сборщика, таблица и цепочка nft прежнего сборщика,
пути прежней общей библиотеки в `lib/`. Полный список — массив `FORBIDDEN` в скрипте.
Слово `bisquite` как имя сборщика образов разрешено.

- Проверяется каждый файл, который git отслеживает или отследил бы; двоичные —
  пропускаются.
- История не проверяется: `CHANGELOG.md`, `docs/history/`, `docs/research/`,
  `docs/plans/`.
- Исключение в тексте: строка с `check-names: allow` или блок между
  `check-names: off` и `check-names: on` — для теста, проверяющего отсутствие, и
  имён переменных GitHub.

## Правило версий: `tools/check-version-bump.sh`

База — старший тег `v*`, достижимый из `HEAD` (или `--base <ref>`); сравнивается
рабочее дерево. Расширение, которого в базе нет, и удалённое — без сравнения. Без
тегов — код 2 (в CI нужен checkout с `fetch-depth: 0`). Почему правило есть —
[выпуск](../guides/release.md#версия-расширения).

## Таблицы из манифестов: `tools/catalog-docs.sh`

Блоки между маркерами `<!-- catalog:<имя> -->` и `<!-- /catalog:<имя> -->`
строятся из `extension.yaml`:

| Файл | Блок |
|---|---|
| `README.md` | `table` — расширения и библиотеки |
| `docs/reference/catalog.md` | `reference` — связи и способности |
| `extensions/debian/<имя>/README.md` | `facts` — платформа и связи; `params` — `config.keys` |

`tools/catalog-docs.sh` переписывает блоки, `--check` показывает разницу и выходит
с кодом 1. Версий в блоках нет: `tools/agent-bump.sh` поднимает версию
`stvor-agent` сам, и сгенерированная версия устарела бы в его PR.

## Ссылки: `tools/check-links.sh`

Каждая относительная ссылка в каждом `.md` — существующий файл, `#якорь` —
заголовок этого файла по правилам GitHub. Ссылки в коде не проверяются.
`tools/check-links.sh --external` дополнительно опрашивает все `http(s)`-адреса —
вручную, перед выпуском документации (в CI сети не доверяем).
