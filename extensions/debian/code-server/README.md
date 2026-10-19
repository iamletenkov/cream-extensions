# code-server

[code-server](https://github.com/coder/code-server) — VS Code в браузере от имени
пользователя машины (`code-server@<пользователь>`). Формат cream/v1 (план
2026-10-19, Task 15).

**Без пароля не стартует.** Пока не задан `CODE_SERVER_PASSWORD` или явно не
разрешено `CODE_SERVER_ALLOW_NO_AUTH=1`, служба не запускается ни на каком адресе,
включая петлю: code-server — это шелл пользователя, и петля не защищает его от
других учёток и служб той же машины. По умолчанию слушает `127.0.0.1:9001` (TLS);
снаружи — через Teleport или ssh-туннель.

## Манифест

| Поле | Значение |
|---|---|
| `version` | `5.0.0`, `cream: ">=1.1.1"` (стадия `cloud-user`, рулинг Р14) |
| `platform.arch` | `amd64`, `arm64` (`.deb` релиза; `armhf` не собирается и не объявлен) |
| `targets` | `build: exec`, `live: yes` |
| `provides` | `web-ide` |
| `depends` | `cloud-user >=1.0.0 <2` — пользователь по умолчанию |
| хуки | `install`, `configure` (стадия `cloud-user`), `apply` (свой), `remove` |
| `files` | `code-server@.service` → `/etc/systemd/system/code-server@.service` (перекрывает юнит пакета) |

## Что делает

- **`install`** — `.deb` code-server **4.135.0** из релиза GitHub по закреплённому
  sha256 на архитектуру (`apt-get install` проверенного файла; чужая сумма — отказ,
  ничего не ставится); `openssl` — им code-server выпускает свой сертификат.
  Службу не запускает, настроек и домашних каталогов не трогает. Повтор при
  установленной версии сеть не трогает.
- **`configure`** — на каждой загрузке (стадия `cloud-user`: после `cloud-final`,
  пользователь уже есть; без cloud-init — после `multi-user.target`) и после
  `install` на живой машине:
  1. проверка значений (форма адреса, порта, имени; иначе сбой до любой записи);
  2. аутентификация (ниже); нет — объявление для Teleport снимается, запущенные
     `code-server@*` гасятся (`--no-block`), прежний `config.yaml` пользователя
     переписывается с `auth: none` без пароля (снятый пароль не остаётся в домашнем
     каталоге, ручной `systemctl start` обёртка отклонит), предупреждение, код 0;
  3. пользователь: `CODE_SERVER_USER` или пользователь cloud-init (библиотека
     `cloud-user`; на загрузке ждёт до 30 с); нет, root, нет домашнего каталога
     или имя не годится для юнита — предупреждение, код 0 (рулинг Р11);
  4. `~/.config/code-server/config.yaml` пишется **от имени пользователя** (ниже);
     не вышло — предупреждение, служба не запускается, код 0;
  5. объявление `/etc/cream/teleport/apps.d/code-server.conf`;
  6. экземпляры других пользователей гасятся, `systemctl start --no-block
     code-server@<пользователь>` (после `install` — `restart`). Экземпляр **не
     включается** (`enable`): его каждый раз запускает configure, проверив пароль.
- **`apply`** — после `cream set code-server …`: то же без ожидания пользователя,
  `restart --no-block` (или останов, если аутентификации больше нет).
- **`remove`** — останавливает `code-server@*` (и снимает их из `--failed`), снимает объявление, удаляет пакет
  (`apt-get purge`). `~/.config/code-server` и `~/.local/share/code-server`
  пользователя (настройки редактора, расширения VS Code, сертификат) остаются.
  Юнит удаляет cream (`files`).
- **`files/code-server.sh start`** — обёртка юнита (от имени пользователя,
  `User=%i`): ещё раз проверяет `config.yaml` — `auth: none` без
  `CODE_SERVER_ALLOW_NO_AUTH=1` или `auth: password` без пароля → код 78
  (`RestartPreventExitStatus=78`, без цикла перезапусков); запускает code-server
  с чистым окружением и одним `--config`.

## Аутентификация и пароль

| Пароль | `CODE_SERVER_ALLOW_NO_AUTH` | Что будет |
|---|---|---|
| задан | любое | `auth: password` |
| нет | `0` (умолчание) | служба не стартует; предупреждение в каждом configure/apply и в журнале юнита |
| нет | `1` | стартует **без аутентификации** (`auth: none`); предупреждение при каждом configure, apply и старте, громче — на адресе не петли |
| не по типу | любое | сбой configure (код 1), запущенный экземпляр гасится — кривой пароль не открывает |

- Пароль — `secret: file` в `/etc/cream/code-server/secrets` (0600, root; пишет
  cream): 8–128 знаков `A-Za-z0-9` и `!#%&()*+,./:;<=>?@^_{|}~[]-` (без пробелов,
  кавычек, `$`, обратной косой — значение ложится в YAML). Прежнее `none` под тип
  не подходит: «без пароля» — только `CODE_SERVER_ALLOW_NO_AUTH=1`.
- Хук читает пароль из `CREAM_SECRETS_FILE` в переменную оболочки (не
  экспортируется) и отдаёт его **только на stdin** процессу, который пишет
  `config.yaml` от имени пользователя: `timeout -k 5 30 runuser -u <пользователь>
  -- env -i PATH=… code-server.sh write-config …`, все дескрипторы выше stderr
  (и замок cream) закрыты. В argv, окружение, журнал и реестр пароль не попадает.
- `config.yaml` — `0600` владельца-пользователя, каталог `~/.config/code-server` —
  `0700`; запись с `umask 077` во временный файл и `rename`: по ссылке не пишет;
  `~/.config` или `~/.config/code-server` — ссылка или не пользователя — отказ.
  Худшее, куда дотянется подложенная ссылка, — то, что пользователь и так может
  писать. Файл переписывается только при изменении содержимого.
- Сам code-server пароль видит в своём `config.yaml` (его читает и пользователь —
  это его шелл); в окружение службы пароль не кладётся (`EnvironmentFile` — только
  несекретный `config`), `PASSWORD`/`HASHED_PASSWORD` из окружения не доходят.
- Пароль задают на машине, а не в VMFILE (строка VMFILE остаётся в образе):

  ```bash
  echo '<пароль>' | sudo cream set code-server CODE_SERVER_PASSWORD=-
  ```

TLS всегда: `cert: true` — code-server при первом старте выпускает самоподписанный
сертификат на `localhost` в `~/.local/share/code-server` (через `openssl`). Браузер
на другой машине его не признает: TLS закрывает петлю, а не публикует сервис.

## Ручки (`/etc/cream/code-server/config`)

| Ключ | Умолчание | Что делает |
|---|---|---|
| `CODE_SERVER_USER` | пусто | пользователь; пусто — пользователь cloud-init; root — нельзя |
| `CODE_SERVER_PASSWORD` | пусто | пароль (секрет, `secrets`); без него служба не стартует |
| `CODE_SERVER_PORT` | `9001` | порт |
| `CODE_SERVER_BIND` | `127.0.0.1` | адрес; `0.0.0.0` открывает сети (с паролем и TLS), `::1` — петля IPv6 |
| `CODE_SERVER_ALLOW_NO_AUTH` | `0` | `1` — запускать без пароля (предупреждение при каждом старте) |

Версия code-server — не ручка: она закреплена вместе с sha256 в
`files/code-server.sh` (`CS_VERSION`, `DEB_SHA256`); обновление — правка
расширения.

## Подключение

```vmfile
EXTENSION code-server CODE_SERVER_PORT=9002
```

Пароль — на машине (см. выше). На работающей машине:

```bash
sudo cream install code-server
echo '<пароль>' | sudo cream set code-server CODE_SERVER_PASSWORD=-
sudo cream set code-server CODE_SERVER_BIND=0.0.0.0     # открыть в сеть (TLS, пароль)
```

Правка `~/.config/code-server/config.yaml` руками живёт до следующего configure
(загрузка, `cream set`): файл принадлежит расширению.

## Веб-приложение Teleport

`configure` и `apply` кладут `/etc/cream/teleport/apps.d/code-server.conf` в
формате расширения `teleport` (`files/teleport.sh`, `read_decl`; H-тест прогоняет
настоящий `teleport.sh render` по этому файлу):

```
NAME=code-server
URI=https://127.0.0.1:9001     # порт — CODE_SERVER_PORT; ::1 — https://[::1]:…
ICON=laptop
```

Объявление есть, только когда служба может работать (аутентификация есть) и
слушает петлю (`127.0.0.1`, `localhost`, `0.0.0.0`, `::1`, `::`); пишется атомарно
(`mktemp` в `apps.d` и `rename`), root, `0644`, не по ссылкам; `remove` его
снимает. Петля по https — Teleport ходит с `insecure_skip_verify`. Кому видно —
метка `env` ноды и роли кластера; не публиковать —
`cream set teleport TELEPORT_APPS_DISABLE=code-server`. `ICON=laptop` — ближайшая
к редактору кода иконка встроенного набора прокси.

## Остатки 4.x — отказ установки и запуска

Переходной совместимости нет (рулинг Р1). Расширение 4.x оставляло то, что
запускает code-server **в обход проверки пароля** или держит **доверенный
корневой CA**. Пока хоть что-то из этого есть на машине, `install` отказывает
(код 1) **до любых изменений**, а `configure` и `apply` — с кодом 1, служба не
запускается (запущенные `code-server@*` гасятся, объявление снимается). В
сообщении — перечень найденного и команды уборки.

| Остаток | Где |
|---|---|
| юнит экземпляра и его drop-in | `/etc/systemd/system/code-server@<пользователь>.service[.d]` (свой шаблон `code-server@.service` — не остаток) |
| ссылки включения экземпляров | `/etc/systemd/system/*.wants/code-server@*.service`, `*.requires/…` (это расширение экземпляры не включает) |
| служба настройки 4.x и её включение | `/etc/systemd/system/configure-code-server.service[.d]`, `*.wants/configure-code-server.service` |
| CA mkcert в системном хранилище | `/usr/local/share/ca-certificates/mkcert_development_CA_*.crt` |

Проверяются **только пути во владении root**. Файлы в домашних каталогах root не
открывает вовсе: иначе любой локальный пользователь положил бы себе `config.yaml` с
`auth: none` и тем погасил бы службу или заблокировал установку, а FIFO на месте
файла подвесил бы хук. Прежний `config.yaml` пользователя безвреден: configure
переписывает его от имени пользователя, а обёртка не запустит `auth: none` без
`CODE_SERVER_ALLOW_NO_AUTH=1`. Со стороны root к домашнему каталогу — только `stat`
(есть ли каталог и `config.yaml`), без открытия файлов.

Уборка:

```bash
sudo systemctl disable --now configure-code-server.service 'code-server@*.service'
sudo rm -r -f -- /etc/systemd/system/configure-code-server.service* /etc/systemd/system/code-server@?*.service* \
    /etc/systemd/system/*.wants/configure-code-server.service /etc/systemd/system/*.wants/code-server@*.service
sudo systemctl daemon-reload
# CA mkcert: его же инструментом…
sudo CAROOT=~<пользователь>/.local/share/code-server/certs mkcert -uninstall
# …или руками
sudo rm /usr/local/share/ca-certificates/mkcert_development_CA_*.crt && sudo update-ca-certificates --fresh
```

После CA стоит убрать и сам каталог `~/.local/share/code-server/certs` (в нём
закрытый ключ CA). Затем — `sudo cream install code-server` заново.

## Проверки

- **V** — `make cream-validate`.
- **H** — `tests/test-code-server.sh`: манифест и типы ключей (без `\n`, кавычек,
  `$`; `none` — не пароль), юнит, `install` (установленная версия — без сети;
  чужой sha256 — отказ; ставится ровно проверенный файл; `openssl`), `configure`
  (fail-closed без пароля и с пустым; снятый пароль убирается из `config.yaml`; кривой пароль — сбой и останов даже с
  `CODE_SERVER_ALLOW_NO_AUTH=1`; `config.yaml` через `runuser`/`timeout`, без fd
  замка, 0600 в каталоге 0700, повтор без перезаписи; пароль не в выводе, argv,
  окружении `runuser`/`timeout`, объявлении; ссылки в домашнем каталоге и в
  `apps.d`; адреса; пользователь — явный, cloud-init, root, без дома, кривое имя;
  чужие экземпляры гасятся; только `--no-block`), объявление через настоящий
  `teleport/files/teleport.sh render`, `apply`, `remove`, обёртка `start` (отказ
  78, чистое окружение code-server), `write-config` (не по форме, чужой каталог), остатки 4.x (каждый вид — отказ
  `install` до сети и apt и отказ `configure` без старта; свой шаблон и свой
  `config.yaml` с `auth: none` — не остатки; чужой `config.yaml` с `auth: none` и
  FIFO в чужом доме не мешают `install`/`configure` и не гасят службу — сторож 20 с).
- **L** — `make test-live EXT=code-server` (`tests/live.env`: dep `cloud-user`,
  пароль — случайный секрет): установка `.deb`, повтор, `--reinstall` без
  изменений, аудит секрета (`ps`, журнал, реестр, `config`), загрузка, `remove`.
  В контейнере нет пользователя cloud-init — configure предупреждает и выходит 0.
  Служба с паролем проверена тем же стендом с добавленной учёткой (2026-10-19,
  debian-12 и ubuntu-24.04): `code-server@alice` active, `config.yaml` 600 alice
  в каталоге 700, вход верным паролем — 302, неверным — 200; пароля нет в `ps`,
  журнале, реестре и окружении процессов (включая code-server); `cream set
  code-server CODE_SERVER_PASSWORD=` гасит службу и снимает объявление.

## Не проверено

Формат cream/v1 на железе (P): вход в code-server через Teleport с паролем из
`secrets`, `cert: true` на arm64.

## Диагностика

```bash
systemctl status code-server@<пользователь>
journalctl -u cream-configure@code-server -b
journalctl -u code-server@<пользователь> -b
sudo cream show code-server
ss -ltnp | grep 9001
```
