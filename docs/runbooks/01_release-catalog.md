# 01. Выпуск каталога

Версию, тег и `CHANGELOG.md` ведёт release-please; руками их не трогают. Как
устроены версии и цепочка — [выпуск](../guides/release.md). Runbook —
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
   `vX.Y.Z`; job `release-assets` (environment `release`) прикладывает
   `cream-extensions-X.Y.Z.tar.gz`, `BUILDINFO.json`, `SHA256SUMS`, `SHA256SUMS.sig`,
   `SHA256SUMS.bundle.json`; job `dispatch-bisquite` (при `BISQUITE_BUMP_ENABLED=true`) открывает в <!-- check-names: allow: имена job и переменной GitHub -->
   bisquite PR подъёма каталога.

## Приёмка

```sh
gh release view vX.Y.Z --json assets -q '.assets[].name'   # tar.gz, BUILDINFO.json, SHA256SUMS{,.sig,.bundle.json}
gh release download vX.Y.Z -p 'SHA256SUMS*' -D /tmp/rel
base64 -d /tmp/rel/SHA256SUMS.sig > /tmp/rel/sig.der
openssl dgst -sha256 -verify release/keys/stvor-platform.pub -signature /tmp/rel/sig.der /tmp/rel/SHA256SUMS   # Verified OK
grep tar.gz /tmp/rel/SHA256SUMS
# на машине с cream (или в контейнере debian:12 с cream по пину tools/cream-pin.env):
gh release download vX.Y.Z -p 'cream-extensions-*.tar.gz' -D /tmp/rel
cream check --catalog core=/tmp/rel/cream-extensions-X.Y.Z.tar.gz --os debian:12 --arch amd64 \
  --step 'install --with-deps teleport stvor-agent'
sudo cream source add core \
  --archive https://github.com/iamletenkov/cream-extensions/releases/download/vX.Y.Z/cream-extensions-X.Y.Z.tar.gz \
  --sha256 <сумма из SHA256SUMS> --sync
```

Результат верный, если: все пять ассетов на месте, подпись проверяется ключом
`stvor-platform`, `source add` принял сумму (неверная —
отказ), `cream check` отвечает без ошибок, в README строка `CV=` показывает новую версию, в
bisquite (и в stvor) открыт PR подъёма.
Неудача `release-assets` — перезапуск job (`gh run rerun <id> --failed`); тег не трогать.
Подписанный релиз неизменяем (`tools/release-sign.sh reconcile`): опубликованный файл, в том
числе `SHA256SUMS`, не совпал с пересборкой — job падает, ничего не переподписывает и не
заменяет; полная проверяемая подпись сохраняется, догружаются только недостающие файлы
(без `--clobber`); подписи нет или она неполная — подпись заново.
Красный шаг подписи «нет секрета COSIGN_PRIVATE_KEY» — завести секреты в environment
`release` (Settings → Environments) и перезапустить job.
