# rustdesk

Удалённый доступ RustDesk: пакет `.deb` с GitHub по версии и sha256, служба
`rustdesk` в автозапуске, адреса **своего** сервера RustDesk — из ключей домена
устройства, а не из образа.

> **2.0.0 — cream/v1.** Хуки `install`, `configure` (стадия `system`, после
> cloud-init, до `rustdesk.service`) и `remove`; домен `/etc/cream/rustdesk/config`,
> `cream set rustdesk …`; состояние — `/var/lib/cream/ext/rustdesk/`. Идентичность
> RustDesk удаляется **только в сборке** — живая установка ID машины не трогает.

Образ один на флот и без секретов: **адресов и ключа сервера в образе нет**,
и **нет идентичности RustDesk** (`RustDesk.toml` с ID, парой ключей и
паролем). ID каждое устройство делает себе само при первом старте службы — из
`/etc/machine-id`, который сбрасывает завершающий `virt-sysprep` сборки.

## Подключение

```vmfile
EXTENSION rustdesk
```

На устройстве или живой машине:

```console
# cream install rustdesk
# cream set rustdesk RUSTDESK_ID_SERVER=rustdesk.example.com RUSTDESK_KEY=<открытый ключ>
```

### Параметры установки (`scope: install`, смена — повтор `cream install rustdesk KEY=…`)

| Ключ | Умолчание | Что делает |
|---|---|---|
| `RUSTDESK_VERSION` | `1.5.0` | тег релиза `github.com/rustdesk/rustdesk` |
| `RUSTDESK_SHA256_AMD64`, `RUSTDESK_SHA256_ARM64` | закреплённые для 1.5.0 | sha256 ассета своей архитектуры; перекрывают `RUSTDESK_SHA256` |
| `RUSTDESK_SHA256` | пусто | sha256 для архитектуры машины; для версии без закреплённой суммы нужен один из трёх |
| `RUSTDESK_URL` | пусто — ассет релиза | полный адрес `.deb` (зеркало) |

### Ключи сервера (`cream set rustdesk …`)

| Ключ | `RustDesk2.toml [options]` | Форма |
|---|---|---|
| `RUSTDESK_ID_SERVER` | `custom-rendezvous-server` | `хост[:порт]` |
| `RUSTDESK_RELAY_SERVER` | `relay-server` | `хост[:порт]` |
| `RUSTDESK_API_SERVER` | `api-server` | `http(s)://хост[:порт][/путь]` |
| `RUSTDESK_KEY` | `key` | base64 **открытого** ключа сервера (`id_ed25519.pub`) — не секрет |

## Что делают хуки

- **`install`** — `.deb` своей архитектуры (`dpkg --print-architecture`):
  скачивается во временный каталог, **sha256 сверяется до того, как файл увидит
  apt**; юнит `/usr/lib/systemd/system/rustdesk.service`, если его не положил
  postinst (в appliance сборки PID 1 — не systemd); служба включена. В **сборке**
  удаляются `RustDesk*.toml` у `/root`, `/etc/skel` и пользователей с UID ≥ 1000
  (у пользователей — **от их имени**), остаток — отказ сборки.
- **`configure`** — на каждой загрузке и после `cream set`: проверяет форму
  каждого значения (вне формы — отказ, ничего не пишется), пишет `[options]` в
  `/root/.config/rustdesk/RustDesk2.toml` (его читает служба) и в
  `~/.config/rustdesk/RustDesk2.toml` каждого пользователя с UID 1000…65533.
  Файл пользователя правит процесс **от его имени** (`runuser`, пустое
  окружение, закрытые дескрипторы, предел 30 с); root в домашние каталоги не
  пишет. Пустой ключ убирается, только если его ставили мы (`managed`); все
  пусты и не ставились — файлы не трогаются (публичные серверы). Изменился
  файл — `rustdesk.service` перезапускается (`--no-block`). Пока RustDesk не
  запускался у кого-то из пользователей или значения пришлось вернуть —
  повторная сверка через минуту, не больше 10 раз за загрузку (первый запуск
  RustDesk на свежей машине переписывал `RustDesk2.toml` своими умолчаниями).
- **`remove`** — свои опции убраны из всех `RustDesk2.toml`, пакет снят (если
  ставили мы), положенный нами юнит снят. `RustDesk.toml` (ID машины) остаётся.

## Доступ и пароль

Расширение **не задаёт** ни постоянного пароля, ни способа проверки
(`verification-method`), ни режима подтверждения (`approve-mode`): доступ
остаётся таким, как его поставляет RustDesk, — одноразовый пароль, видимый
только на экране машины. Тихого доступа без аутентификации расширение не
открывает; постоянный пароль задаёт человек на машине.

## Проверка

```console
$ systemctl status rustdesk cream-configure@rustdesk
$ sudo cat /root/.config/rustdesk/RustDesk2.toml
$ cream show rustdesk
```

H — `tests/test-rustdesk.sh`; L — `make test-live EXT=rustdesk` (`debian-12`,
`ubuntu-24.04`).
