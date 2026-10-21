# wallpaper

Обои рабочего стола — **системным умолчанием** в `/etc` для GNOME (dconf),
Xfce (xfconf) и LXDE (pcmanfm) из картинки, которая лежит в дереве расширения
(`/opt/cream/ext/wallpaper/images/`). В домашний каталог root не пишет.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | amd64, arm64 |
| cream | ≥ 1.1.1 |
| Даёт | `wallpaper` |
| Требует | `desktop-session` |
| Зависит от | [`cloud-user`](../cloud-user/README.md) |
| Конфликтует с | — |
| Хуки | `install`, `configure`, `remove` |
| Настройка на загрузке | стадия `cloud-user`, по отметке выполнения |
| Живая машина | да |
<!-- /catalog:facts -->

## Что делает

- **`install`** — ставит `dconf-cli`, если dconf нет; отказ (код 1), если
  выбранной картинки нет в `images/`.
- **`configure`** (стадия `cloud-user` — после `cloud-final`; без порядка
  относительно менеджера входа) — пишет три системных умолчания (таблица ниже) и
  предупреждает, если у пользователя cloud-init есть свои настройки Xfce/LXDE,
  которые их перекрывают; стола нет — предупреждение и 0. Пользователь
  cloud-init (библиотека [`cloud-user`](../cloud-user/README.md)) нужен только
  для этого предупреждения. Своей службы первой загрузки нет.
- **`remove`** — снимает наши файлы и возвращает `pcmanfm.conf` прежние значения.

Без рабочего стола (`requires: desktop-session`) ключи читать некому — отказ
приходит на сборке.

| Стол | Файл | Как |
|---|---|---|
| GNOME | `/etc/dconf/db/local.d/50-wallpaper`, `locks/50-wallpaper`; профиль `/etc/dconf/profile/user` (`system-db:local`, правило общее с `desktop` и `locale`) | `picture-uri`, `picture-uri-dark` (GNOME 42+; старшему ключ не мешает), `picture-options` — **под замком** |
| Xfce | `/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml` | раскладка Xubuntu: `monitor0…3/image-path`, `image-style` — xfdesktop переносит её на монитор с любым именем; чужой файл не перезаписывается (предупреждение) |
| LXDE | `/etc/xdg/pcmanfm/LXDE/pcmanfm.conf` (`lxde-common`), секция `[desktop]` | `wallpaper`, `wallpaper_mode`; прежние значения — в `/var/lib/cream/ext/wallpaper/pcmanfm.orig`, `remove` их возвращает |

Запись — во временный файл рядом и `rename`: ссылка на месте нашего файла
заменяется, а не проходится; `pcmanfm.conf`, который сам ссылка, не правится
(предупреждение). Режим и владелец `pcmanfm.conf` сохраняются. Повтор не меняет
ни одного файла и не зовёт `dconf update`.

## Параметры

<!-- catalog:params -->
| Ключ | Тип | Умолчание | Что задаёт |
|---|---|---|---|
| `WALLPAPER_IMAGE` | строка `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.(jpg\|jpeg\|png\|svg)$` | `dst_1080.jpg` | картинка — имя файла в /opt/cream/ext/wallpaper/images (без каталогов) |
| `WALLPAPER_MODE` | `zoom` \| `scaled` \| `centered` \| `stretched` \| `spanned` \| `wallpaper` | `zoom` | как вписать: zoom — заполнить с обрезкой, scaled — целиком, centered, stretched, spanned, wallpaper — плиткой |
<!-- /catalog:params -->

`WALLPAPER_IMAGE` — имя файла в `/opt/cream/ext/wallpaper/images/`: буквы,
цифры, `.` `_` `-`, расширение `.jpg` `.jpeg` `.png` `.svg`; каталогов,
абсолютных путей и ссылок нет. Картинки — в `images/` дерева расширения: cream
кладёт его в `/opt/cream/ext/wallpaper/` целиком, и обои ссылаются туда же, без
копии.

## Установка

На машине с подключённым каталогом ([как подключить](../../../docs/getting-started.md)):

```bash
sudo cream install --with-deps wallpaper WALLPAPER_IMAGE=dst_1080.jpg WALLPAPER_MODE=zoom
sudo cream set wallpaper WALLPAPER_MODE=scaled   # configure перезапускается сам
cream show wallpaper
```

В образе bisquite (VMFILE):

```dockerfile
RUN_COMMAND cream install --with-deps wallpaper WALLPAPER_IMAGE=dst_1080.jpg WALLPAPER_MODE=zoom
```

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | `dconf-cli` при необходимости; проверка, что картинка есть |
| загрузка (`cream-configure@wallpaper`, стадия `cloud-user`) | системные умолчания трёх столов, предупреждение о пользовательских настройках |
| `cream set` | cream перезапускает `configure` |
| `cream remove` | наши файлы сняты, замок GNOME снят, `pcmanfm.conf` возвращён |

## Известные ограничения

- В GNOME пользователь не сменит обои сам, пока расширение стоит (замок; см.
  ниже). `cream remove wallpaper` снимает замок.
- В Xfce и LXDE замка нет: это умолчание, и **собственные настройки пользователя
  побеждают**. `configure` смотрит (только наличие файла, ничего не читая и не
  правя), есть ли у пользователя cloud-init свой `xfce4-desktop.xml` или
  `desktop-items-0.conf`, и предупреждает.
- **Нет файла картинки — отказ `install`** (и `configure`): слой ставят затем,
  чтобы на столе была заданная картинка, и молча собрать образ без неё значит
  отдать роботу не то, что просили.

## Подробности

### Почему замок в GNOME

На L4T пакет `nvidia-l4t-configs` кладёт `/etc/xdg/autostart/nvbackground.sh`, и тот
на **каждом** старте сессии делает `gsettings set … NVIDIA_Wallpaper.jpg`. Замеры на
платах 2026-09-12 и 2026-09-15: наши значения переписывались через минуту-другую.
Замок системной базы делает ключ незаписываемым для любого `gsettings` сеанса —
и для вендорского скрипта, и для старого значения в базе пользователя.

## Проверки

- **V** — `make cream-validate` (с пином cream ≥ 1.1.1), `tools/lint-hooks.sh`, `tools/check-names.sh`.
- **H** — `tests/test-wallpaper.sh`: три стола, режимы, повтор без изменений, отказ
  на имени картинки чужой формы, на ссылке и на отсутствующем файле, ссылки на
  месте наших файлов и `pcmanfm.conf`, дом пользователя не тронут, `remove` и повтор.
- **L** — `make test-live EXT=wallpaper` поверх `xfce4` (`tests/live.env`).
- **P** — что картинка видна на экране (GNOME на Jetson с `nvbackground.sh`, Xfce,
  LXDE) — глазами на машине с монитором; в контейнере экрана нет.
