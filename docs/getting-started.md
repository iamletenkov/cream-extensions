# Первые шаги

От пустой машины до работающего расширения: поставить cream, подключить каталог,
поставить расширение, поменять его настройку и снять его. Всё — на живой машине
Debian или Ubuntu от root; для образа — [расширения в образе bisquite](guides/use-in-bisquite.md).

## 1. cream

Каталогу нужен cream 1.2.0 или новее. Установка `.deb` из выпуска cream с проверкой
суммы — [README cream](https://github.com/iamletenkov/cream#установка). Проверить:

```bash
cream version          # cream 1.2.0 или новее
```

## 2. Каталог

Каталог выходит снимком: `cream-extensions-<версия>.tar.gz` и `SHA256SUMS` в каждом
[выпуске](https://github.com/iamletenkov/cream-extensions/releases). cream скачивает
снимок по `https://` и сверяет sha256 **до** распаковки; сумму берите из
`SHA256SUMS` того же выпуска.

```bash
CV=5.9.1 # x-release-please-version
URL="https://github.com/iamletenkov/cream-extensions/releases/download/v$CV"
curl -fLO "$URL/SHA256SUMS"
SUM=$(awk -v f="cream-extensions-$CV.tar.gz" '$2 == f {print $1}' SHA256SUMS)
sudo cream source add core --archive "$URL/cream-extensions-$CV.tar.gz" --sha256 "$SUM" --sync
cream source show core     # sha256, версия каталога, время синхронизации
```

Без сети на машине — тот же файл любым способом и `--archive file:///путь/…`.
Новая версия каталога — `cream source add core … --replace --sync`, затем
`sudo cream upgrade --all`. Источники, приоритет и локальный каталог для
разработки — [подключить каталог](https://github.com/iamletenkov/cream/blob/main/docs/guides/add-catalog.md)
в документации cream.

## 3. Расширение

Список расширений с параметрами — [таблица в README](../README.md#расширения),
подробности — README расширения.

```bash
sudo cream install --with-deps btop                  # --with-deps ставит и depends
sudo cream install --with-deps locale LOCALE=ru_RU.UTF-8
cream list                                           # что стоит и в каких версиях
```

- Параметры — `KEY=VALUE` после имени, имена — из таблицы «Параметры» README.
  Неверное значение отвергается до запуска хуков.
- `--with-deps` добирает `depends`, но не способности из `requires`: расширение,
  которому нужен, например, `x11-server` (`x11vnc`, `kiosk`), ставится после
  поставщика (`gnome`, `xfce4`, `lxde`) — строка «Требует» в его README.
- Секрет — `KEY=-` со stdin (`echo 'пароль' | sudo cream set x11vnc X11VNC_PASSWORD=-`)
  или файлом `--params-file` (0600, владелец root); в argv cream секрет не примет.
- Расширение, которое заметно меняет работающую машину (сеть, экран входа, ядро),
  ставится только с `--accept-risk`; что именно оно меняет — строка «Живая машина»
  в его README. Расширения «только образ» на живую машину не ставятся вовсе.
- Код выхода 20 у `install` — «здесь неприменимо» (нет устройства, ядра, GPU); с
  `--allow-skip` это не ошибка. Коды — [справочник cream](https://github.com/iamletenkov/cream/blob/main/docs/reference/exit-codes.md).

## 4. Настройки

```bash
cream show locale                                    # ключи, значения, умолчания; секреты — маской
sudo cream set locale KEYBOARD_LAYOUTS=us,ru         # проверка по схеме, запись, хук apply
cream run firewall status                            # действие расширения
```

Когда правка действует (сразу, на следующей загрузке, только переустановкой) —
[настройки на работающей машине](guides/settings.md).

## 5. Снять

```bash
sudo cream remove locale            # хук remove снимает только своё
sudo cream remove --purge locale    # и настройки /etc/cream/locale, и состояние
```

`remove` снимает пакет apt, только если его поставило это расширение, и только
после симуляции apt: если apt снял бы что-то чужое — отказ до любых изменений.

## Дальше

- [Расширения в образе bisquite](guides/use-in-bisquite.md)
- [Написать своё расширение](guides/write-extension.md)
- [Диагностика](https://github.com/iamletenkov/cream/blob/main/docs/guides/diagnostics.md) — статусы, журналы, блокировки
