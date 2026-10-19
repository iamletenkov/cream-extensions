---
name: release
description: Как выходит версия набора расширений — release-please по Conventional Commits и автоподъём в bisquite; что проверить перед слиянием релизного PR.
---
# /release

Теги и `CHANGELOG.md` руками не трогают.

1. PR сливается squash-ем; заголовок PR = заголовок коммита в `main` (`feat(<расширение>): …` → minor, `fix(…)` → patch, `!` → major; текст по-русски).
2. На push в `main` после зелёного job `check.sh` job **Release Please** (`.github/workflows/ci-release.yml`, конфиг — `.github/release_please/`) ведёт PR «chore(main): release X.Y.Z».
3. Слияние релизного PR создаёт тег `vX.Y.Z` и релиз (файлов нет: версия — сам тег, его пинят `ref` источника и `EXT_VERSION`). Затем `dispatch-bisquite` запускает в bisquite `extensions-bump.yml` (секрет `BISQUITE_DISPATCH_TOKEN`).
4. Пин пакета агента в обёртке `stvor-agent` (`files/pin.env`) поднимает `agent-bump.yml` по релизу stvor-agent (или руками: `tools/agent-bump.sh`).
5. Перед слиянием релизного PR: `gh pr checks <N>` зелёный, `gh run list -L 3` — main зелёный, в changelog нет мусора (кривой заголовок — revert, история `main` не переписывается).
