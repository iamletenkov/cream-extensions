# fetch

**Устарела с каталога 5.5.0 — ставить не нужно.** `fetch_verified` теперь
лежит в git одной копией, [`lib/fetch.sh`](../../../lib/fetch.sh), и снимок
каталога кладёт её в `files/fetch.sh` каждого потребителя (`selkies`,
`code-server`, `rustdesk`): у них больше нет `depends` на `fetch`, и VMFILE не
нужна строка `cream install fetch`. Расширение осталось в каталоге для
совместимости: `cream upgrade --all` на машине с каталогом 5.4.2 находит его
(установленное расширение, пропавшее из источника, блокирует обновление), а
потребители 5.4.2, ещё не обновлённые, берут `/opt/cream/ext/fetch/fetch.sh` —
теперь это прослойка к `files/fetch.sh`. Хуков нет.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | amd64, arm64 |
| cream | ≥ 1.0.0 |
| Вид | библиотека (`kind: library`): общий код других расширений, без хуков |
| Даёт | — |
| Требует | — |
| Зависит от | — |
| Конфликтует с | — |
| Живая машина | да |
<!-- /catalog:facts -->

## Что делает

`/opt/cream/ext/fetch/fetch.sh` — прослойка: подключает `files/fetch.sh` (копию
[`lib/fetch.sh`](../../../lib/fetch.sh), её кладёт снимок) и даёт
`fetch_verified ПУТЬ SHA256 АДРЕС…` потребителям каталога 5.4.2:

- адреса по очереди, на каждый — `FETCH_ATTEMPTS` попыток (умолчание 5) с паузой
  `FETCH_DELAY` с (умолчание 10); файл пишется в `ПУТЬ.part` и становится `ПУТЬ`
  только при совпавшей sha256;
- коды: 0 — закреплённый файл; 1 — ни один адрес не отдал файл; 2 — sha256 не
  та (без повторов); 3 — неверный вызов. `ПУТЬ.part` не остаётся.

## Параметры

<!-- catalog:params -->
Параметров нет.
<!-- /catalog:params -->

Ключей нет; `FETCH_ATTEMPTS` и `FETCH_DELAY` — переменные окружения хука
потребителя, не ключи cream.

## Установка

Не нужна. Убрать после обновления потребителей до каталога 5.5.0 (`selkies`
6.2.1, `code-server` 5.2.2, `rustdesk` 2.2.1):

```bash
sudo cream upgrade --all
sudo cream remove fetch
```

### Как подключить к своему расширению

Не через `depends`: строка `<семейство>/<имя>` в
[`lib/fetch.consumers`](../../../lib/fetch.consumers) — и хук берёт копию из
своего дерева:

```bash
FETCH_LIB="${CREAM_EXT_DIR:?run by cream}/files/fetch.sh"
[[ -f "$FETCH_LIB" ]] || { log_error "нет $FETCH_LIB"; exit 1; }
# shellcheck source=../../../../lib/fetch.sh
source "$FETCH_LIB"
rc=0
fetch_verified "$WORK/asset" "$SHA256" "$URL" "$MIRROR_URL" || rc=$?
case "$rc" in
    0) ;;
    2) log_error "sha256 не совпала — не ставлю"; exit 1 ;;
    *) log_error "файл не скачался"; exit 1 ;;
esac
```

## Известные ограничения

- Докачки (`-C -`) нет: оборванная попытка начинается заново. Сервер без
  поддержки диапазонов дал бы на докачке отказ, а сумма проверяется всё равно.
- Мелкие загрузки (ключи apt, `.sha256`) каталог через библиотеку не ведёт: им
  хватает `--retry` curl.

## Подробности

### Зачем

curl 7.68 (Ubuntu 20.04 focal — корневая ФС L4T Jetson Nano) не повторяет
«Connection reset by peer» (curl 56) даже с `--retry 5`, а `--retry-all-errors`
появился только в 7.71. На приёмке на Jetson Nano (2026-10-22) установка
`selkies` падала на первом же обрыве. Поэтому попытки — свой цикл вокруг curl
на любую его ошибку; собственный `--retry` curl не используется — он умножил бы
ожидание.

### Почему не библиотека в `depends`

В 5.4.2 `fetch` была отдельной библиотекой, и `selkies`, `code-server`,
`rustdesk` требовали её до себя: `cream install selkies` без `cream install
fetch` падал с `deps.missing` (67), ломая существующие VMFILE и `cream upgrade` на
живых машинах. Одна копия в `lib/` и раскладка снимком (как ядро Teleport,
рулинг Р11) убирают зависимость, не размножая код в git.

## Проверки

- **V** — `make cream-validate`, `make check-names`, `tools/lint-hooks.sh`.
- **H** — `tests/test-fetch.sh` (прослойка даёт `fetch_verified`; через неё —
  curl 56 дважды и успех третьей попыткой, исчерпанные попытки и следующий адрес,
  чужая sha256 без повторов, неверный вызов, никаких `.part`) и H-тест каждого
  потребителя «curl 56 дважды — третья попытка» без библиотеки `fetch` на корне.
- **Копии** — `tools/check-shared-libs.sh`: копий `lib/fetch.sh` в git нет,
  staged-копии равны `lib/`.
