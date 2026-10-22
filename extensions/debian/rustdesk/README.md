# rustdesk

Удалённый доступ RustDesk: пакет `.deb` с GitHub по версии и sha256, служба
`rustdesk` в автозапуске, адреса **своего** сервера RustDesk — из ключей домена
устройства, а не из образа.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | amd64, arm64 |
| cream | ≥ 1.2.0 |
| Даёт | `remote-support` |
| Требует | — |
| Зависит от | [`cloud-user`](../cloud-user/README.md), [`apt-guard`](../apt-guard/README.md) |
| Конфликтует с | — |
| Хуки | `install`, `configure`, `remove` |
| Настройка на загрузке | стадия `system`, на каждой загрузке (`every_boot`) |
| Живая машина | да |
<!-- /catalog:facts -->

Образ один на флот и без секретов: **адресов и ключа сервера в образе нет**,
и **нет идентичности RustDesk** (`RustDesk.toml` с ID, парой ключей и
паролем). ID каждое устройство делает себе само при первом старте службы — из
`/etc/machine-id`, который сбрасывает завершающий `virt-sysprep` сборки.

## Что делает

- **`install`** — `.deb` своей архитектуры (`dpkg --print-architecture`):
  скачивается во временный каталог `fetch_verified` из [`lib/fetch.sh`](../../../lib/fetch.sh) (5
  попыток на обрыв), **sha256 сверяется до того, как файл увидит
  apt**; юнит `/usr/lib/systemd/system/rustdesk.service`, если его не положил
  postinst (в appliance сборки PID 1 — не systemd); служба включена. В **сборке**
  удаляются `RustDesk*.toml` у `/root`, `/etc/skel` и пользователей с UID ≥ 1000
  (у пользователей — **от их имени**), остаток — отказ сборки. Живая установка
  идентичность RustDesk (ID машины) не трогает.
- **`configure`** — на каждой загрузке (`every_boot: true`; стадия `system`,
  после cloud-init, до `rustdesk.service`) и после `cream set`: проверяет форму
  каждого значения (вне формы — отказ, ничего не пишется), пишет `[options]` в
  `/root/.config/rustdesk/RustDesk2.toml` (его читает служба) и в
  `~/.config/rustdesk/RustDesk2.toml` каждого пользователя с UID 1000…65533.
  Файл пользователя правит процесс **от его имени** (`runuser`, пустое
  окружение, закрытые дескрипторы, предел 30 с); root в домашние каталоги не
  пишет. Пустой ключ убирается, только если его ставили мы (`managed`); все
  пусты и не ставились — файлы не трогаются (публичные серверы). Изменился
  файл — `rustdesk.service` перезапускается (`--no-block`). Пока RustDesk не
  запускался у кого-то из пользователей или значения пришлось вернуть —
  повторная сверка через 30 с (`cream configure --again rustdesk` по таймеру
  `systemd-run`, мимо отметки configure), не больше 10 раз за загрузку (первый
  запуск RustDesk на свежей машине переписывал `RustDesk2.toml` своими
  умолчаниями). Состояние — `/var/lib/cream/ext/rustdesk/`.
- **`remove`** — свои опции убраны из всех `RustDesk2.toml`, пакет снят (если
  ставили мы), положенный нами юнит снят. `RustDesk.toml` (ID машины) остаётся.

## Параметры

<!-- catalog:params -->
| Ключ | Тип | Умолчание | Что задаёт |
|---|---|---|---|
| `RUSTDESK_VERSION` | строка `^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$` | `1.5.0` | тег релиза github.com/rustdesk/rustdesk; для версии без закреплённой суммы нужен RUSTDESK_SHA256* *(только при установке)* |
| `RUSTDESK_SHA256_AMD64` | строка `^[0-9a-f]{64}$` | пусто | sha256 rustdesk-<версия>-x86_64.deb; перекрывает RUSTDESK_SHA256 *(только при установке)* |
| `RUSTDESK_SHA256_ARM64` | строка `^[0-9a-f]{64}$` | пусто | sha256 rustdesk-<версия>-aarch64.deb; перекрывает RUSTDESK_SHA256 *(только при установке)* |
| `RUSTDESK_SHA256` | строка `^[0-9a-f]{64}$` | пусто | sha256 пакета для архитектуры машины *(только при установке)* |
| `RUSTDESK_URL` | строка `^https?://[A-Za-z0-9.:/_~%+-]+$` | пусто | полный адрес .deb (зеркало); пусто — ассет релиза GitHub *(только при установке)* |
| `RUSTDESK_ID_SERVER` | строка `^[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?$` | пусто | ID-сервер (custom-rendezvous-server): хост[:порт] |
| `RUSTDESK_RELAY_SERVER` | строка `^[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?$` | пусто | relay-сервер (relay-server): хост[:порт] |
| `RUSTDESK_API_SERVER` | строка `^https?://[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$` | пусто | API-сервер (api-server): URL |
| `RUSTDESK_KEY` | строка `^[A-Za-z0-9+/]{1,512}={0,2}$` | пусто | ПУБЛИЧНЫЙ ключ сервера (key, base64 из id_ed25519.pub сервера) — не секрет |
<!-- /catalog:params -->

**Ключи установки** (`RUSTDESK_VERSION`, `RUSTDESK_SHA256*`, `RUSTDESK_URL`) —
`scope: install`, смена — повтор `cream install rustdesk KEY=…`. Для 1.5.0 суммы
обеих архитектур закреплены; для версии без закреплённой суммы нужен один из
`RUSTDESK_SHA256_AMD64`, `RUSTDESK_SHA256_ARM64`, `RUSTDESK_SHA256`.

**Ключи сервера** (`cream set rustdesk …`) ложатся в `RustDesk2.toml [options]`:

| Ключ | `RustDesk2.toml [options]` | Форма |
|---|---|---|
| `RUSTDESK_ID_SERVER` | `custom-rendezvous-server` | `хост[:порт]` |
| `RUSTDESK_RELAY_SERVER` | `relay-server` | `хост[:порт]` |
| `RUSTDESK_API_SERVER` | `api-server` | `http(s)://хост[:порт][/путь]` |
| `RUSTDESK_KEY` | `key` | base64 **открытого** ключа сервера (`id_ed25519.pub`) — не секрет |

Конфигурация домена — `/etc/cream/rustdesk/config`.

## Установка

На машине с подключённым каталогом ([как подключить](../../../docs/getting-started.md)):

```bash
sudo cream install --with-deps rustdesk
sudo cream set rustdesk RUSTDESK_ID_SERVER=rustdesk.example.com RUSTDESK_KEY=<открытый ключ>
cream show rustdesk
```

В образе bisquite (VMFILE) — без адресов сервера, их задают на устройстве:

```dockerfile
RUN_COMMAND cream install --with-deps rustdesk
```

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа | пакет по sha256, юнит, служба включена; идентичность RustDesk удаляется |
| `cream install` на живой машине | то же, но идентичность (ID машины) не трогается |
| загрузка (`cream-configure@rustdesk`) | на каждой загрузке: `[options]` в `RustDesk2.toml` root и пользователей, перезапуск службы при изменении, повторные сверки |
| `cream set` | тот же `configure` |
| `cream remove` | свои опции, свой пакет и свой юнит сняты; `RustDesk.toml` остаётся |

## Известные ограничения

- Только amd64 и arm64: armhf (клиент на Sciter) — другая программа, не
  проверялась.
- Пароль и режим доступа расширение не задаёт — см. «Доступ и пароль».

## Подробности

### Доступ и пароль

Расширение **не задаёт** ни постоянного пароля, ни способа проверки
(`verification-method`), ни режима подтверждения (`approve-mode`): доступ
остаётся таким, как его поставляет RustDesk, — одноразовый пароль, видимый
только на экране машины. Тихого доступа без аутентификации расширение не
открывает; постоянный пароль задаёт человек на машине.

### Проверка на машине

```console
$ systemctl status rustdesk cream-configure@rustdesk
$ sudo cat /root/.config/rustdesk/RustDesk2.toml
$ cream show rustdesk
```

## Проверки

- **H** — `tests/test-rustdesk.sh`.
- **L** — `make test-live EXT=rustdesk` (`debian-12`, `ubuntu-24.04`).
