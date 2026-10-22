# Структура каталога

## Репозиторий

```
cream-catalog.yaml          корень каталога cream: schema, name, version (ведёт release-please), roots
extensions/
├── debian/                 roots: расширения для Debian и Ubuntu (семейство deb)
│   └── <имя>/              одно расширение, имя каталога = name манифеста
└── openwrt/                roots: расширения для OpenWrt 25.12+ (семейство openwrt, cream ≥ 1.3.0)
lib/                        общий код нескольких расширений, одна копия в git:
                            teleport-core.sh (ядро teleport и teleport-openwrt),
                            teleport-core.consumers (кому его класть), tests/
tools/                      проверки, генераторы, раннеры тестов, пин cream (tools/cream-pin.env)
docs/                       документация: guides/, reference/, runbooks/, history/, adr/, specs/, plans/, research/
.github/workflows/          ci-release.yml (проверки и выпуск), live.yml (живые прогоны),
                            cream-bump.yml и agent-bump.yml (подъём пинов)
.github/release_please/     конфиг и манифест release-please
Makefile                    публичные команды: make help
```

`cream-catalog.yaml` перечисляет `roots`; каждое расширение обязано лежать под одним
из них — иначе его не увидят ни `cream validate --catalog .`, ни снимок
(`tools/catalog-snapshot.sh` отказывает на непокрытом расширении).

Общее ядро Teleport (`lib/teleport-core.sh`) в git лежит одной копией; в
`files/teleport-core.sh` каждого потребителя из `lib/teleport-core.consumers` его кладут
снимок (из коммита) и `tools/stage-catalog.sh` (из рабочего дерева — для `cream validate`,
`cream check`, H- и живых тестов и path-источника). Потребитель объявляет
`files/teleport-core.sh` в `files`, поэтому дерево без ядра `cream validate` не примет;
копию в `extensions/` отвергает `tools/check-teleport-core.sh`.

Каталог называется `debian/`, а семейство в манифесте — `platform.family: deb`; это
разные вещи. Ubuntu берёт расширения из того же `debian/`. Группировка — удобство
автора, а не контракт: cream ищет расширение по `name` в кеше источника, а не по
пути, и другой каталог вправе разложить дерево иначе.

## Расширение

```
extensions/debian/<имя>/
├── extension.yaml      манифест cream/v1: name, version, summary, cream, platform, targets,
│                       provides/requires/depends/conflicts, hooks, config.keys, actions, files
├── hooks/              install (обязателен, кроме kind: library), upgrade, configure, apply,
│                       secret, remove, check — только объявленные в манифесте; исполняемые
├── actions/<действие>  cream run <имя> <действие>; исполняемые
├── files/…             юниты, правила udev, шаблоны — раскладывает cream (поле files)
├── tests/              H-тесты test-*.sh и live.env; в снимок не попадают
└── README.md           по шаблону docs/reference/extension-readme.md
```

Библиотека (`kind: library`: `apt-guard`, `cloud-user`, `l4t`) хуков не имеет; её
код лежит в корне каталога расширения, потребитель зовёт его по пути
`"${CREAM_ROOT:-}/opt/cream/ext/<библиотека>/…"`.

## На машине

| Что | Где |
|---|---|
| код и данные расширения (копия каталога без `tests/`) | `/opt/cream/ext/<имя>/` |
| настройки домена: `config`, `secrets` (0600), `apps.d` у `teleport` | `/etc/cream/<имя>/` |
| состояние расширения | `/var/lib/cream/ext/<имя>/` |
| отметка выполнения `configure` | `/var/lib/cream/configured/<имя>.json` |
| донастройка на загрузке | `cream-configure@<имя>.service` (ставит cream; своих юнитов донастройки у расширений нет) |
| состав образа для меток | `/etc/image-labels.d/cream.json` |
| источники и кеш каталога | `/etc/cream/sources.yaml`, `/var/cache/cream/sources/<источник>/` |

Префикс `cream-` в именах юнитов и путях `files` зарезервирован за cream: юниты
расширения называются по расширению (`teleport-join.timer`, `x11vnc@.service`).
Полный список путей cream — [файлы и переменные окружения](https://github.com/iamletenkov/cream/blob/main/docs/reference/files-and-environment.md).

## Снимок

`cream-extensions-<версия>.tar.gz` выпуска содержит `cream-catalog.yaml`, `LICENSE`,
`NOTICE` и `roots` без `tests/` расширений — по тем же путям, что в репозитории.
Как собирается — [выпуск](../guides/release.md#снимок-каталога).
