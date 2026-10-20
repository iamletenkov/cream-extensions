# 01. Выпуск каталога

Версию, тег и `CHANGELOG.md` ведёт release-please; руками их не трогают. Runbook —
что сделать и что проверить, чтобы релиз дошёл до потребителей (Stvor, bisquite).

## Шаги

1. **Изменения в `main`.** Каждый PR — squash, заголовок PR = заголовок коммита по
   Conventional Commits: `fix(…)` — patch, `feat(…)` — minor, `!`/`BREAKING CHANGE:` — major.
   ```sh
   gh pr checks <N>            # зелёный check.sh (и live.yml для L-расширений)
   gh pr merge <N> --squash
   ```
2. **Релизный PR.** После зелёного `check` на `main` job `release-please`
   (`.github/workflows/ci-release.yml`) открывает или обновляет PR
   «chore(main): release X.Y.Z».
   ```sh
   gh pr list --search 'release in:title' --state open
   gh run list -L 3 --branch main          # main зелёный
   gh pr diff <N> | sed -n "/CHANGELOG.md/,/^diff --git/p"   # в заметках нет мусора
   ```
   Кривой заголовок в `main` — revert и новый PR, историю `main` не переписывают.
3. **Снимок до выпуска** (по желанию, локально, по одному на хосте):
   ```sh
   make snapshot-check   # две сборки HEAD дают одни байты; cream принимает снимок
   ```
4. **Выпуск** — слить релизный PR (решение владельца). release-please ставит тег
   `vX.Y.Z`; job `release-assets` прикладывает `cream-extensions-X.Y.Z.tar.gz` и
   `SHA256SUMS`; job `dispatch-bisquite` (при `BISQUITE_BUMP_ENABLED=true`) открывает в <!-- check-names: allow: имена job и переменной GitHub -->
   bisquite PR подъёма каталога.

## Приёмка

```sh
gh release view vX.Y.Z --json assets -q '.assets[].name'   # tar.gz и SHA256SUMS
gh release download vX.Y.Z -p SHA256SUMS -O - | grep tar.gz
# на машине с cream (или в контейнере debian:12 с cream по пину tools/cream-pin.env):
cream source add cream-extensions \
  --archive https://github.com/iamletenkov/cream-extensions/releases/download/vX.Y.Z/cream-extensions-X.Y.Z.tar.gz \
  --sha256 <сумма из SHA256SUMS> --sync
cream resolve --phase build --family deb --target-arch amd64 --host-arch amd64 teleport stvor-agent
```

Результат верный, если: оба ассета на месте, `source add` принял сумму (неверная —
отказ), `resolve` печатает порядок без ошибок, в bisquite открыт PR подъёма.
Неудача `release-assets` — перезапуск job (`gh run rerun <id> --failed`); тег не трогать.
