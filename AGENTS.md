# cream-extensions — регламент для агентов и людей

**cream-extensions** (бывший bisquite-extensions) — каталог расширений провизии: каталог `extensions/<семейство>/<имя>/` с манифестом `extension.yaml`, `install.sh` (фаза build) и при нужде `configure.sh` (донастройка на машине). Общий код — `lib/` (библиотека настроек `bisquite-conf`, схемы `knobs/`). Конвенция целиком — [docs/extensions.md](docs/extensions.md). Лицензия PolyForm Noncommercial (не менять без решения владельца).

Состояние работ — [docs/STATUS.md](docs/STATUS.md).

## Место в экосистеме
- **bisquite** — собирает образы ВМ, подключает расширения инструкцией `EXTENSION` и поднимает их версию после релиза этого репозитория.
- **cream** — новый исполнитель расширений (Go): формат `extension.yaml`, жизненный цикл и `cream set/show` переезжают под него по спеке cream. До неё действует текущий формат; имена `bisquite-*`, пути `/opt/bisquite`, `/etc/bisquite` не меняются.
- **stvor-agent** — агент портала Stvor на машине; ставится обёрткой `stvor-agent` (`cream/v1`) по пину версии и sha256 на архитектуру.
- **Stvor** — приватный портал (identity & access hub).

## Язык
Общение, документация, README — **по-русски**. Код, комментарии в коде, имена файлов и веток — **по-английски**. Коммиты и заголовки PR — Conventional Commits: тип и скоуп латиницей, текст **по-русски** (`feat(rustdesk): пакет для arm64 со своей суммой`). Заголовок ≤ 100 символов, строка тела ≤ 100. Заголовок PR = заголовок squash-коммита в `main`.

## Карта репозитория
```
extensions/debian/   — расширения для Debian/Ubuntu (install.sh, configure.sh, extension.yaml)
extensions/openwrt/  — конфиги OpenWrt (не расширения, см. docs/)
lib/                 — общий код, доставляется в гостя сборкой (/opt/bisquite/<имя>/lib)
tools/               — check.sh (валидация + тесты), check-names.sh, hooktest.sh (H), live-test.sh (L), lint.sh, new-extension.sh, agent-bump.sh
docs/                — README.md (индекс), STATUS.md, extensions.md, adr/, specs/, plans/, research/
.claude/             — агенты, skills, правила, хуки Claude Code
.github/             — CI (check.sh, shellcheck), release-please, подъём пина агента
Makefile             — публичный API (`make help`): lint, test, check, ci
```

## Как работать
1. **Классифицируй задачу** вслух: *тривиальная* → правка → `make lint` → коммит; *bounded* (одно расширение, 1–3 файла) → короткий дизайн → тест первым → reviewer → PR; *архитектурная* (формат манифеста, `lib/`, новые способности, контракт с bisquite/cream) → спека → skeptic → план с `## Progress Tracker` → TDD → reviewer → PR. Сомневаешься — путь тяжелее.
2. Новое расширение — только через `tools/new-extension.sh` (skill `/new-extension`), не копированием соседа.
3. **TDD:** тест на поведение (`extensions/<семейство>/<имя>/tests/test-*.sh` на подменённом корне, обвязка `tools/hooktest.sh`; `check.sh` находит его сам) пишется до правки; живой прогон — `make test-live EXT=<имя>` (по одному на хосте).
4. Хост общий и нагруженный: один `make ci` за раз.

## Definition of Done
Подтверждено **выводом**: `make ci` (shellcheck + `tools/check.sh`) зелёный; README расширения и `docs/` обновлены; новый документ — строка в `docs/README.md`; чекбокс плана отмечен в том же коммите.

## Git и выпуск
- Ветки `feature/`, `fix/`, `chore/`, `docs/`, `ci/` от свежего `origin/main`; в `main` — PR со squash.
- Версию и `CHANGELOG.md` ведёт **release-please** (тег — версия набора расширений); теги руками не ставят. Подробно — skill `/release`.
- `git add <пути>`, никогда `git add -A`. Хуки lefthook (`lefthook install`) не обходить: `--no-verify` запрещён.

## Гигиена и секреты
- Временное — только `.scratchpad/` (gitignored).
- Секреты — только в окружении, `.env` и секретах GitHub; в код, доки, коммиты, логи не попадают. Скачанное в расширениях — по пину версии и sha256. `.mcp.json` — из `.mcp.json.example`, ключи из env.
