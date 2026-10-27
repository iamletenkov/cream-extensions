# Выпуск

Версию каталога, тег и `CHANGELOG.md` ведёт release-please; руками их не трогают.
Здесь — как устроены версии, что запускает выпуск и куда он уходит. Пошаговый
чек-лист с проверками — [runbook 01](../runbooks/01_release-catalog.md).

## Две версии

| Что | Где | Кто поднимает |
|---|---|---|
| версия каталога | тег `vX.Y.Z`, `version` в `cream-catalog.yaml`, строка в README | release-please по Conventional Commits |
| версия расширения | `version` в `extensions/debian/<имя>/extension.yaml` | автор PR, в том же коммите, что и правка |

### Версия расширения

**Дерево расширения изменилось — его версия выросла.** cream хранит на машине номер
версии и отпечаток дерева расширения; обновление с тем же номером и другим
отпечатком он отвергает (`version.same_digest`). В выпуске 5.1.1 правка README у
`teleport` и `stvor-agent` без подъёма версий сломала обновление роботам с 5.1.0.

- Любая правка под `extensions/debian/<имя>/` — даже README или тест — подъём
  версии: patch — без смены поведения, minor — новое поведение или ключ, major —
  несовместимая правка ключей, путей, юнитов.
- Проверяет `tools/check-version-bump.sh` (в `make test`): сравнивает дерево каждого
  расширения с последним тегом `v*`; изменилось, а версия не выше — отказ с
  подсказкой. В CI нужен checkout с тегами (`fetch-depth: 0`).
- Под строкой `version:` — комментарий, что изменилось (`# 2.1.1: только README …`).

### Версия каталога

Сливаешь в `main` коммиты по [Conventional Commits](https://www.conventionalcommits.org/ru/):
`fix:` — patch, `feat:` — minor, `!` или `BREAKING CHANGE:` — major; `docs:`, `ci:`,
`chore:`, `build:` выпуска не вызывают. PR, который поднимает версии расширений,
должен быть `fix:` или `feat:` — иначе новые версии не попадут в снимок.

## Как выходит версия

1. PR сливается в `main` (squash, заголовок PR = заголовок коммита).
2. После зелёного `check` на `main` release-please открывает или обновляет PR
   «chore(main): release X.Y.Z» с разделом `CHANGELOG.md`.
3. Слияние этого PR — выпуск: тег `vX.Y.Z`, опубликованный релиз с заметками; job
   `release-assets` собирает на теге снимок и прикладывает
   `cream-extensions-X.Y.Z.tar.gz`, `BUILDINFO.json`, `SHA256SUMS` и подпись
   `SHA256SUMS.sig` / `SHA256SUMS.bundle.json` ([подпись выпуска](#подпись-выпуска)).
4. Тот же прогон рассылает выпуск потребителям (ниже).

## Снимок каталога

Потребители берут каталог не git-чекаутом, а снимком — `tar.gz`, собранным
`cream catalog pack`:

```bash
make snapshot        # dist/cream-extensions-<v>.tar.gz + dist/SHA256SUMS из HEAD
make snapshot-check  # две сборки дают одни байты; cream принимает снимок
```

Снимок собирается из коммита (`git archive`, не рабочее дерево) с
`SOURCE_DATE_EPOCH` — временем коммита, cream — по пину в `debian:12` без сети:
сборка одного коммита воспроизводима побайтно. В снимок попадают
`cream-catalog.yaml`, `LICENSE`, `NOTICE` и `roots` каталога без `tests/`
расширений; `tools/`, `docs/` и прочее — нет. Расширение под `extensions/`, не
покрытое `roots`, — отказ скрипта: оно не должно пропасть из снимка молча.

## Подпись выпуска

Схема — та же, что у релиза форка Teleport, stvor-agent и cream: ключ
`stvor-platform` (ECDSA P-256), cosign по пину `tools/cosign-pin.env`, без Rekor.
Подписывается один файл — `SHA256SUMS`; он покрывает снимок и `BUILDINFO.json`
(тег, коммит, время коммита, пин cream, сумма снимка, ссылка на прогон).

| Файл | Что это | Чем проверить |
|---|---|---|
| `SHA256SUMS.sig` | base64 ASN.1 ECDSA над sha256 `SHA256SUMS` | Go stdlib (`ecdsa.VerifyASN1`), `openssl dgst -sha256 -verify` |
| `SHA256SUMS.bundle.json` | та же подпись бандлом sigstore | `cosign verify-blob --bundle … --insecure-ignore-tlog=true` |

- Публичные ключи — `release/keys/stvor-platform.pub` (текущий, им подписывают) и
  `release/keys/stvor-platform-next.pub` (следующий, приватная часть — офлайн у
  владельца, в GitHub не кладётся).
- Приватный ключ — секреты `COSIGN_PRIVATE_KEY` и `COSIGN_PASSWORD` environment
  `release` (только ветка `main`); их видит только job `release-assets`. Код
  тега он не выполняет: снимок собирает job `release-build` без секретов и отдаёт
  artifact'ом, а `release-assets` берёт инструменты коммита workflow
  (`github.workflow_sha`), сверяет, что коммит тега — предок `main`, и сам пишет
  `BUILDINFO.json`. Нет секрета — job красный и ничего не загружает, `dispatch-*`
  не запускаются.
- Подпись проверяется на раннере без сети (`unshare -n`) публичным ключом из
  репозитория до загрузки. Перезапуск job'а при том же `SHA256SUMS` берёт уже
  выложенную подпись (ECDSA не детерминирована).
- На PR job `Snapshot (dry run)` гоняет тот же путь на одноразовом ключе;
  `tools/test-release-sign.sh` — в `make test` (без cosign — без круга подписи).

Проверка выпуска руками:

```bash
gh release download vX.Y.Z -R iamletenkov/cream-extensions -p 'SHA256SUMS*' -D rel
base64 -d rel/SHA256SUMS.sig > rel/sig.der
openssl dgst -sha256 -verify release/keys/stvor-platform.pub -signature rel/sig.der rel/SHA256SUMS
```

## Цепочка выпусков

Каталог стоит в середине цепочки cream → cream-extensions → bisquite и портал
Stvor. Входы и выходы этого репозитория:

| Направление | Кто запускает | Что делает | Выключатель / секрет |
|---|---|---|---|
| выпуск cream → сюда | job `dispatch-extensions` в `iamletenkov/cream` | `cream-bump.yml`: PR `build(tools): пин cream X.Y.Z` (`tools/cream-pin.env`, суммы из `SHA256SUMS`) | там: `EXTENSIONS_BUMP_ENABLED`, `EXTENSIONS_DISPATCH_TOKEN` |
| выпуск stvor-agent → сюда | job `dispatch-extensions` в `iamletenkov/stvor-agent` | `agent-bump.yml`: PR `feat(stvor-agent): пин агента X.Y.Z` (`files/pin.env`, patch расширения) | там: `EXTENSIONS_BUMP_ENABLED`, `EXTENSIONS_DISPATCH_TOKEN` |
| выпуск отсюда → bisquite | job `dispatch-bisquite` | `extensions-bump.yml` в bisquite: PR подъёма снимка каталога | здесь: `BISQUITE_BUMP_ENABLED`, `BISQUITE_DISPATCH_TOKEN` <!-- check-names: allow: имена переменной и секрета GitHub --> |
| выпуск отсюда → Stvor | job `dispatch-stvor` | `robot-pins-bump.yml` в stvor: PR `CREAM_EXTENSIONS_*` в `.env.example` | здесь: `STVOR_BUMP_ENABLED`, `STVOR_DISPATCH_TOKEN` |

- Выключатель — переменная репозитория (`gh variable set <ИМЯ> --body true`;
  выключить — `gh variable delete <ИМЯ>`). Без секрета job пишет предупреждение и
  выходит зелёным.
- Токены — fine-grained PAT только на целевой репозиторий с правом Actions: Read and
  write; срок действия токена bisquite — до 16.10.2027, до этой даты его
  перевыпускают, иначе job выпуска покраснеет.
- Пин cream вручную: Actions → Cream Bump → Run workflow (`tag` пустой — последний
  выпуск cream) или `tools/cream-bump.sh <тег> <SHA256SUMS>` — [runbook 03](../runbooks/03_cream-pin-bump.md).
- Пин агента руками не поднимают: его PR открывает `agent-bump.yml`; база PR — вход
  `base`, иначе переменная `AGENT_BUMP_BASE`, иначе `main`.
