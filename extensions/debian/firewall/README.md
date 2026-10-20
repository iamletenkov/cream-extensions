# firewall

Файрвол машины: входящее — только разрешённое, исходящее — всё. Два
бэкенда с одними и теми же правилами по умолчанию:

- **nftables** — своя таблица `inet cream`, файлы `*.nft`;
- **iptables** (`iptables-legacy`) — своя цепочка `CREAM-INPUT` в таблице
  `filter` IPv4 и IPv6, файлы `*.rules` и `*.rules6`. Для ядер без `nft_ct` —
  прежде всего штатного ядра L4T r36.4.3 на Jetson.

```
cream install --accept-risk firewall    # живая машина (live: confirm)
cream run firewall status               # бэкенд и правила, как они в ядре
cream remove firewall                   # снять свою таблицу и цепочки
EXTENSION firewall                      # образ bisquite
```

Бэкенд выбирается **при установке и на каждой загрузке** по спискам модулей
ядра (раздел «Выбор бэкенда»). Правила — файлы в
`/etc/cream/firewall/rules.d/`; их собирает хук `configure` в
`cream-configure@firewall` на стадии `early` — **на каждой загрузке до сети**
(`Before=network-pre.target`), после установки на живой машине и после
`cream set firewall …`.

> **С 2.0.0 — cream/v1.** `install.sh` стал хуком `hooks/install`,
> `configure.sh` — общим `firewall.sh`, который зовут хук `configure`,
> действия и хук `remove`. Своей службы больше нет: на загрузке правила
> собирает `cream-configure@firewall` (стадия `early`, нужен cream ≥ 1.1.0).
> Команда-обёртка заменена действиями `cream run firewall status|check|reload`.
> Таблица и цепочка переименованы **без миграции** (решение владельца):
> обновлённая машина получает новую таблицу, старая снимается перезагрузкой
> или руками. SSH, как и прежде, закрыт; новый ключ `FIREWALL_SSH_PORTS`
> открывает его порты и в правилах, и в запасном наборе.

Ключи `FIREWALL_ENABLE`, `FIREWALL_BACKEND` — прежние; новый — `FIREWALL_SSH_PORTS`.

## Манифест

| Поле | Значение |
|---|---|
| `cream` | `>=1.1.0` — стадия `early` появилась в 1.1.0 |
| `platform.arch` | `amd64`, `arm64` — пакеты и скрипты, архитектура не участвует |
| `targets` | `build: exec`, `live: confirm` — `live_note` ниже |
| `provides` | `host-firewall` |
| `hooks` | `install` (15 мин), `configure` (стадия `early`, после `nftables.service`, 2 мин), `remove` (2 мин); своего `apply` нет — применение = перезапуск configure (спека cream §8.4) |
| `actions` | `status` (`lock: none`), `check` (`lock: none`), `reload` (`lock: exclusive`) |

### Почему `live: confirm`

Сразу после установки на живой машине входящее закрыто (`policy drop`),
кроме петли и ответов на исходящие соединения. Обратный туннель Teleport
работает (узел сам звонит прокси, сервис — на `127.0.0.1:3022`), поэтому
роботу входящий SSH не нужен и **по умолчанию закрыт**. Любая входящая служба
отрезана, пока её не откроет файл правил. Поэтому без `--accept-risk` cream не
ставит; текст риска — `targets.live_note`.

**На живой машине, куда вы вошли по SSH, сначала
`cream set firewall FIREWALL_SSH_PORTS=22` (или установите с этим
параметром), иначе сессия оборвётся:**

```
sudo cream install --accept-risk firewall FIREWALL_SSH_PORTS=22
```

`install` в фазе live при пустом `FIREWALL_SSH_PORTS` и открытой сессии SSH
(установленное TCP-соединение на `:22` по `ss`, иначе удалённый вход по `who`)
предупреждает об этом в stderr — это не отказ.

## Что делает

| Шаг | Что |
|---|---|
| `install` (сборка и живая машина) | выбор бэкенда по каждому ядру образа (отказ, если ядро не тянет ни один — до apt); пакеты `nftables` и `iptables`; `/etc/cream/firewall/rules.d/10-defaults.{nft,rules,rules6}` и `README` (если их ещё нет; правленая копия остаётся, о расхождении — предупреждение); проверка файлов обоих бэкендов (`firewall.sh check nft|iptables`: формат `*.rules` — отказ, `nft -c`/`restore --test` без модулей ядра — предупреждение); `/var/lib/cream/ext/firewall/backend` — выбор сборки. В ядро ничего не грузится |
| `configure` (каждая загрузка, стадия `early`; после `install`; `cream set`) | выбор бэкенда по работающему ядру; nftables — таблица заново одной транзакцией `nft -f`; iptables — цепочка заново одной транзакцией `iptables-legacy-restore --noflush` на семейство и один переход первым правилом `INPUT`; затем снимается таблица или цепочка другого бэкенда |
| `remove` | снимает **только** таблицу `inet cream` и цепочку `CREAM-INPUT` с её переходом из `INPUT`; входящее больше не фильтруется. Файлы правил оператора и пакеты остаются (`--purge` снимет и `/etc/cream/firewall`) |

Правила по умолчанию (`10-defaults.nft`; для iptables — `10-defaults.rules`
и `10-defaults.rules6` того же смысла):

- петля (`lo`) — всё;
- ответы на исходящие соединения (`ct state established,related`,
  `-m conntrack --ctstate ESTABLISHED,RELATED`), `invalid` — drop;
- UDP 7400–32000 на `127.0.0.1` (DDS/ROS 2);
- ICMPv6 обнаружения соседей (без них не работает IPv6, в т.ч. исходящий);
- SSH закрыт; TCP-порты из `FIREWALL_SSH_PORTS` (умолчание — пусто) открывает
  сам `configure` после файлов каталога;
- остальное входящее — `policy drop` (iptables — последнее правило цепочки
  `-j DROP`); исходящее — `policy accept` (iptables — `OUTPUT` не трогается).

Ping и прочие входящие закрыты: открыть — своим файлом правил.

### Docker не задевается

`flush ruleset`, `iptables -F` и смена политик не делаются никогда: Docker
держит свои цепочки (`DOCKER`, `DOCKER-USER`, `FORWARD`, таблица `nat`) в
iptables-nft или iptables-legacy, и сброс отрезал бы контейнеры. nftables:
наша таблица добавляет только базовую цепочку на хуке `input`. iptables:
транзакция `--noflush` объявляет и заменяет только `CREAM-INPUT`, в
`INPUT` добавляется ровно одно правило `-j CREAM-INPUT` (первым;
повторный `apply` его не дублирует), политика `INPUT` остаётся как была.
В обоих случаях проброс портов (`-p 8080:80`) идёт через DNAT и `forward`, выход
контейнеров в сеть — через `forward` и masquerade. Ни то, ни другое в `input`
не попадает. Не пропускается только обращение контейнера к службам **самой
машины** по адресу моста — нужно — своим правилом (пример ниже).

`nftables.service` дистрибутива не включается: его `/etc/nftables.conf`
начинается с `flush ruleset`. Если его включили — configure стоит после него
(`after: [nftables.service]`) и пересобирает свою таблицу, но цепочки Docker
он уже снёс (лечится `systemctl restart docker`).

## Настройки

Домен `firewall`, файл `/etc/cream/firewall/config`, схема — `config.keys`
манифеста. Смена через `cream set firewall …` перезапускает
`cream-configure@firewall`.

| Ключ | Умолчание | Что |
|---|---|---|
| `FIREWALL_ENABLE` | `1` | `0` — таблица и цепочки снимаются, входящее не фильтруется |
| `FIREWALL_BACKEND` | `auto` | `auto` — nftables, если в ядре есть `nf_tables` и `nft_ct`, иначе iptables, если есть модули `iptables-legacy`; `nft`, `iptables` — явно |
| `FIREWALL_SSH_PORTS` | пусто | TCP-порты SSH через пробел — открыты и правилами, и запасным набором; пусто — SSH закрыт. Значение не из портов — `configure` ничего не применяет и выходит с ошибкой (прежние правила остаются) |

Смена `FIREWALL_BACKEND`: новый бэкенд применяется, и только после этого
снимается таблица или цепочка прежнего — окна без файрвола нет.

### Выбор бэкенда

| Бэкенд | Нужно ядру (модуль в `modules.dep` или встроен — `modules.builtin`) |
|---|---|
| nftables | `nf_tables`, `nft_ct` |
| iptables | `ip_tables`, `iptable_filter`, `ip6_tables`, `ip6table_filter`, `nf_conntrack`, `xt_conntrack`, `xt_tcpudp` |

- **Установка** (`hooks/install`, до apt): для каждого ядра образа
  (`/lib/modules/*/` с `modules.order`, не `uname -r` appliance) —
  `auto`: nftables, иначе iptables, иначе **отказ** с перечнем недостающих
  модулей; явное `nft`/`iptables` без своих модулей — тоже отказ. Выбор
  пишется в `/var/lib/cream/ext/firewall/backend`. Ядра в образе нет
  (контейнер) — предупреждение, выбирает загрузка.
- **Каждая загрузка** (`hooks/configure`): то же по ядру `uname -r`
  (`/lib/modules/$(uname -r)`). Списков модулей нет — бэкенд сборки, а без
  него nftables. Явный `FIREWALL_BACKEND`, которого ядро по спискам не
  тянет, всё равно пробуется (оператор так сказал) — с записью в журнал.
  `cream run firewall status` печатает, что выберет `apply`.

**Почему `iptables-legacy`, а не `iptables-nft`.** iptables-nft 1.8.7
(Ubuntu 22.04) не переводит `-m conntrack` в родное nft-выражение: это
`match name conntrack` через `nft_compat`, диапазон портов — `match name udp`
так же, и к каждому правилу добавляется `counter` (замер 2026-10-15,
`nft --debug=netlink`). В штатном ядре L4T нет ни `nft_compat`, ни
`nft_counter` — iptables-nft там правил по умолчанию не загрузит, а все семь
модулей legacy есть. Определить пригодность iptables-nft по спискам модулей
нельзя и в общем случае: на новых ядрах `counter` встроен в `nf_tables`
(на 6.1 `nft_counter.ko` нет).

### Файлы правил nftables (`*.nft`)

Включаются по алфавиту после пересоздания таблицы, в той же транзакции;
формат — команды nft к таблице `inet cream`:

```
# /etc/cream/firewall/rules.d/50-local.nft
# ping
add rule inet cream input icmp type echo-request accept
# служба машины для контейнеров Docker (мост docker0 и сети compose)
add rule inet cream input iifname "docker0" tcp dport 8000 accept
add rule inet cream input iifname "br-*" tcp dport 8000 accept
```

### Файлы правил iptables (`*.rules`, `*.rules6`)

`*.rules` — IPv4 (`iptables-legacy-restore`), `*.rules6` — IPv6
(`ip6tables-legacy-restore`). По алфавиту, одна транзакция на семейство:
своя цепочка объявляется (то есть очищается), затем строки файлов, правила
SSH, в конце `-A CREAM-INPUT -j DROP`. Строка — правило **своей цепочки** в
синтаксисе `iptables-restore`, полной формой или краткой (префикс добавится):

```
# /etc/cream/firewall/rules.d/50-local.rules
-p tcp --dport 8000 -j ACCEPT
# ping — то же полной формой
-A CREAM-INPUT -p icmp --icmp-type echo-request -j ACCEPT
# служба машины для контейнеров Docker
-i docker0 -p tcp --dport 8000 -j ACCEPT
-i br-+ -p tcp --dport 8000 -j ACCEPT
```

```
# /etc/cream/firewall/rules.d/50-local.rules6
-p tcp --dport 8000 -j ACCEPT
```

Пустые строки и `#` пропускаются. **Ошибка файла** — любая другая команда
(`-A INPUT`, `-I`, `-D`, `-F`, `-X`, `-P`, `-N`, `-t`, `*filter`, `COMMIT`,
`:ЦЕПОЧКА`) или строка не с `-`: файлы не могут тронуть чужие цепочки.
Формат проверяется и при установке (отказ), и на загрузке.

### Ошибка в файле

**Ошибка в любом файле выбранного бэкенда — не применяется ничего из
каталога:** грузится запасной набор (петля, ответы и только порты
`FIREWALL_SSH_PORTS`, если заданы; остальное входящее закрыто), `configure` выходит с
ошибкой — `cream-configure@firewall` в `failed`, причина — в
`journalctl -u cream-configure@firewall`. Закрытая машина, а не открытая;
заданный оператором SSH не отрезан. Файлы другого бэкенда не читаются (`*.nft` при
iptables и наоборот), но при установке проверяются оба набора.
`10-defaults.*` — тоже файлы оператора: повторная установка (дочерний образ,
`--reinstall`) их не перезаписывает, а предупреждает о расхождении.

## Сборка

```vmfile
EXTENSION firewall
EXTENSION firewall FIREWALL_ENABLE=0      # образ загрузится с выключенным файрволом
EXTENSION firewall FIREWALL_BACKEND=iptables   # iptables и на ядре с nft_ct
EXTENSION firewall FIREWALL_SSH_PORTS=22   # открыть SSH (по умолчанию закрыт, доступ — Teleport)
```

Свои файлы правил в образ — `UPLOAD` в `/etc/cream/firewall/rules.d/` после
`EXTENSION firewall`.

### Ядро образа и Jetson

**Jetson / L4T: штатное ядро r36.4.3 (`5.15.148-tegra`) собрано без
`CONFIG_NFT_CT`** (а также без `NFT_REJECT`, `NFT_COUNTER`, `NFT_COMPAT`;
`nf_tables` — модулем, конфиг — встроенный в `Image` из `nvidia-l4t-kernel`),
зато все модули `iptables-legacy` есть. `EXTENSION firewall` выбирает там
iptables. Ядро Sensing (расширение `sensing-gmsl2-camera` подменяет
`/boot/Image`, а списки модулей в `/lib/modules/5.15.148-tegra/` остаются
от L4T) на живой плате ещё не проверено: если в нём есть `nft_ct`, сборка
этого не увидит (смотрит на списки), а загрузка — тоже нет, по той же
причине; бэкенд останется iptables, и это рабочий вариант. Узнать на плате:
`zcat /proc/config.gz | grep -E 'NFT_CT|IP_NF_IPTABLES'`.

Docker на том же ядре правилами `-m conntrack` и `-m addrtype` тоже требует
либо `iptables-legacy`, либо `nft_compat`; его цепочки наш бэкенд не
трогает ни в одном из фреймворков.

## Манифест записи / развёртывания

`write_files` cloud-init, если манифест его даёт, или строкой первой
загрузки (`firstboot-commands` записи, `firstboot_commands` ВМ):

```yaml
firstboot-commands:
  - "echo 'add rule inet cream input tcp dport 8000 accept' > /etc/cream/firewall/rules.d/50-app.nft"
  # то же для бэкенда iptables (Jetson):
  - "echo '-p tcp --dport 8000 -j ACCEPT' > /etc/cream/firewall/rules.d/50-app.rules"
  - "cream run firewall reload"
  # или выключить совсем:
  - "cream set firewall FIREWALL_ENABLE=0"
```

## На работающей машине

```bash
sudo cream run firewall status           # бэкенд, что выберет apply, наши правила в ядре
sudoedit /etc/cream/firewall/rules.d/50-local.nft    # или 50-local.rules
sudo cream run firewall check            # проверить файлы (nft -c / restore --test), ничего не применяя
sudo cream run firewall reload           # применить (атомарно, без открытого окна)
sudo cream set firewall FIREWALL_SSH_PORTS="22 2222"   # порты SSH (перезапускает configure)
sudo cream set firewall FIREWALL_ENABLE=0   # выключить (таблица и цепочки снимаются)
```

`systemctl stop cream-configure@firewall` таблицу не снимает намеренно:
остановка внутри перезапуска была бы окном, когда машина открыта.

## Проверки

- **H** — `tests/test-firewall.sh` (`make test`): выбор бэкенда по спискам
  модулей; манифест; `configure` на подменённом корне с подставными `nft` и
  `iptables-legacy*` — таблица `inet cream` одной транзакцией, SSH закрыт по
  умолчанию, `FIREWALL_SSH_PORTS=22` — в правилах и в запасном наборе, битое значение, битый
  файл, `FIREWALL_ENABLE=0`, переключение бэкенда; формат `*.rules`
  (`check`, код 3); `install` — выбор по ядру образа, отказ до apt, предупреждение о сессии SSH на живой машине, умолчания
  не перезаписываются, повтор не меняет файлов; `remove` снимает только свою
  таблицу и цепочку, `flush ruleset` не звучит никогда.
- **L** — `make test-live EXT=firewall DISTRO=debian-12` и `ubuntu-24.04`
  (`tests/live.env`: `--accept-risk`, `NET_ADMIN` в собственном netns
  контейнера, не `--network host`): установка, повтор, `--reinstall` без
  изменения файлов, перезапуск контейнера — `cream-configure@firewall`
  успешен (поднять таблицу на загрузке — его работа), циклов порядка нет;
  `remove` — расширения нет в `cream list`, `systemctl --failed` пуст.

Проверено в 1.x (раскладка 2, те же правила и бэкенды) в systemd-контейнерах
`ubuntu:24.04` (с Docker CE из расширения `docker`), `debian:12` и
`ubuntu:22.04` arm64 со списками модулей L4T r36.4.3: порт без правила закрыт
снаружи и открыт с петли; проброс `-p 8080:80`, выход контейнеров в сеть и
`127.0.0.1:8080` работают при включённом файрволе и после перезапуска dockerd;
бэкенд iptables — переход первым в `INPUT` (v4, v6), повторный apply его не
дублирует; подставные цепочки Docker в iptables-legacy, ip6tables-legacy и
iptables-nft до и после каждого шага не менялись. Применить правила под
qemu-user нельзя вовсе: он не пропускает ни `IPT_SO_*`, ни сокет netlink
netfilter.
