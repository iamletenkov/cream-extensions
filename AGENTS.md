# cream-extensions — регламент для агентов и людей

**cream-extensions** (бывший bisquite-extensions) — каталог расширений провизии формата **cream/v1**: `extensions/<семейство>/<имя>/` с манифестом `extension.yaml` (`schema: cream/v1`), хуками `hooks/` (`install`, `configure`, `apply`, `remove`, …), действиями `actions/` и файлами `files/`; ставит и настраивает их cream. Общий код — библиотеки `kind: library` (`cloud-user`, `l4t`, `apt-guard`). Как писать расширение — [docs/guides/write-extension.md](docs/guides/write-extension.md), все документы — [docs/README.md](docs/README.md). Лицензия PolyForm Noncommercial (не менять без решения владельца).

Состояние работ — [docs/STATUS.md](docs/STATUS.md).

## Место в экосистеме
- **bisquite** — собирает образы ВМ; с 3.0 везёт cream и снимок этого каталога, расширения ставятся строками `RUN_COMMAND cream install` VMFILE; снимок поднимает после релиза этого репозитория.
- **cream** — новый исполнитель расширений (Go): формат `extension.yaml` (cream/v1), жизненный цикл, `cream set/show`, действия. Пин версии для проверок — `tools/cream-pin.env`. Прежних имён bisquite (пути, ключи, юниты, таблицы nft) в репозитории нет — гейт `tools/check-names.sh`, кроме истории.
- **stvor-agent** — агент портала Stvor на машине; ставится обёрткой `stvor-agent` (`cream/v1`) по пину версии и sha256 на архитектуру.
- **Stvor** — приватный портал (identity & access hub).

## Язык
Общение, документация, README — **по-русски**. Код, комментарии в коде, имена файлов и веток — **по-английски**. Коммиты и заголовки PR — Conventional Commits: тип и скоуп латиницей, текст **по-русски** (`feat(rustdesk): пакет для arm64 со своей суммой`). Заголовок ≤ 100 символов, строка тела ≤ 100. Заголовок PR = заголовок squash-коммита в `main`.

## Карта репозитория
```
extensions/debian/   — расширения для Debian/Ubuntu: cream/v1 (extension.yaml, hooks/, actions/, files/, tests/)
extensions/openwrt/  — расширения для OpenWrt 25.12+ (cream ≥ 1.3.0, busybox sh, uci): amneziawg, podkop, luci-apps, teleport-openwrt; L — make test-openwrt
lib/                 — общий код, одна копия в git: teleport-core.sh (ядро teleport и teleport-openwrt; в расширения кладут снимок и tools/stage-catalog.sh), teleport-core.consumers, tests/
cream-catalog.yaml   — корень каталога cream (roots, version — ведёт release-please)
tools/               — check.sh (все проверки make test), catalog-docs.sh (таблицы документации из манифестов), check-links.sh (ссылки .md), cream-validate.sh (V), cream-check.sh (cream check по каталогу), check-names.sh, lint-hooks.sh, hooktest.sh (H), live-test.sh (L), live-matrix.sh (матрица live.yml), lint.sh, new-extension.sh, catalog-snapshot.sh, stage-catalog.sh (staged-дерево: каталог с общим ядром — на нём cream validate/check, H- и живые тесты), check-teleport-core.sh, cream-deb.sh, cream-pin.env (cream 1.3.0), agent-bump.sh, check-contract-fixtures.sh + contract-fixtures.sha256; test-*.sh — тесты инструментов, testdata/ — фикстуры
docs/                — README.md (индекс), STATUS.md, getting-started.md, guides/, reference/, runbooks/, history/, adr/, specs/, plans/, research/
.claude/             — агенты, skills, правила, хуки Claude Code
.github/             — ci-release.yml (gitleaks, check.sh, shellcheck, release-please, снимок к релизу), live.yml (живые прогоны), agent-bump.yml (подъём пина stvor-agent); release_please/
Makefile             — публичный API (`make help`): lint, test, check, ci, check-names, cream-validate, cream-check, docs, check-links, test-live, test-live-self, snapshot, snapshot-check
```

## Как работать
1. **Классифицируй задачу** вслух: *тривиальная* → правка → `make lint` → коммит; *bounded* (одно расширение, 1–3 файла) → короткий дизайн → тест первым → reviewer → PR; *архитектурная* (формат манифеста, библиотеки, новые способности, контракт с bisquite/cream) → спека → skeptic → план с `## Progress Tracker` → TDD → reviewer → PR. Сомневаешься — путь тяжелее.
2. Новое расширение — только через `tools/new-extension.sh` (skill `/new-extension`), не копированием соседа.
3. **TDD:** тест на поведение (`extensions/<семейство>/<имя>/tests/test-*.sh` на подменённом корне, обвязка `tools/hooktest.sh`; `check.sh` находит его сам) пишется до правки; живой прогон — `make test-live EXT=<имя>` (по одному на хосте).
4. Хост общий и нагруженный: один `make ci` за раз.

## Definition of Done
Подтверждено **выводом**: `make ci` (shellcheck + `tools/check.sh`) зелёный; README расширения (по шаблону, блоки — `tools/catalog-docs.sh`) и `docs/` обновлены; новый документ — строка в `docs/README.md`; чекбокс плана отмечен в том же коммите.

## Git и выпуск
- Ветки `feature/`, `fix/`, `chore/`, `docs/`, `ci/` от свежего `origin/main`; в `main` — PR со squash.
- Версию и `CHANGELOG.md` ведёт **release-please** (тег — версия набора расширений); теги руками не ставят. Подробно — skill `/release`.
- `git add <пути>`, никогда `git add -A`. Хуки lefthook (`lefthook install`) не обходить: `--no-verify` запрещён.

## Гигиена и секреты
- Временное — только `.scratchpad/` (gitignored).
- Секреты — только в окружении, `.env` и секретах GitHub; в код, доки, коммиты, логи не попадают. Скачанное в расширениях — по пину версии и sha256. `.mcp.json` — из `.mcp.json.example`, ключи из env.
