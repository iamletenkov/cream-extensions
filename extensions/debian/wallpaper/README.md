# wallpaper

Обои рабочего стола — **системным умолчанием** в `/etc` из картинки, которая
лежит в дереве расширения (`/opt/cream/ext/wallpaper/images/`).

> **3.0.0 — cream/v1.** Хуки `install`, `configure` (стадия `cloud-user` — после
> `cloud-final`, как прежняя служба первой загрузки; без порядка относительно
> менеджера входа; нужен cream ≥ 1.1.1, рулинг Р14 плана) и `remove`; своего
> `configure-wallpaper.service` нет. Обои больше не пишутся в dconf пользователя
> через `gsettings` — root не заходит в домашний каталог: GNOME получает системную
> базу dconf **с замками**, Xfce — системный канал xfconf, LXDE — `pcmanfm.conf`.
> Поэтому расширение больше не «только GNOME». `WALLPAPER_IMAGE` — имя файла в
> `images/`, без каталогов; новый ключ `WALLPAPER_MODE`.

## Манифест

| Поле | Значение |
|---|---|
| `platform.arch` | `amd64`, `arm64` |
| `targets` | `build: exec`, `live: yes` |
| `provides` | `wallpaper` |
| `requires` | `desktop-session` — без стола ключи читать некому; отказ приходит на сборке |
| `depends` | `cloud-user` (библиотека: пользователь cloud-init — только для предупреждения) |
| хуки | `install`, `configure` (`cloud-user`), `remove` |

## Подключение

```vmfile
EXTENSION wallpaper WALLPAPER_IMAGE=dst_1080.jpg WALLPAPER_MODE=zoom
```

На живой машине — `sudo cream install wallpaper`; сменить — `sudo cream set wallpaper
WALLPAPER_MODE=scaled` (`configure` перезапускается сам).

## Параметры

| Ключ | Умолчание | Что делает |
|---|---|---|
| `WALLPAPER_IMAGE` | `dst_1080.jpg` | имя файла в `/opt/cream/ext/wallpaper/images/`: буквы, цифры, `.` `_` `-`, расширение `.jpg` `.jpeg` `.png` `.svg`; каталогов, абсолютных путей и ссылок нет |
| `WALLPAPER_MODE` | `zoom` | `zoom` — заполнить с обрезкой, `scaled` — целиком, `centered`, `stretched`, `spanned`, `wallpaper` — плиткой |

<!-- check-names: off -->
| Было (layout 2) | Стало (cream/v1) |
|---|---|
| `WALLPAPER_IMAGE=images/dst_1080.jpg` | `WALLPAPER_IMAGE=dst_1080.jpg` |
| `/usr/share/backgrounds/bisquite-wallpaper.jpg` (копия) | `/opt/cream/ext/wallpaper/images/<файл>` (на месте) |
| `configure-wallpaper.service` | `cream-configure@wallpaper.service` (стадия `cloud-user`) |
| `gsettings` в dconf пользователя, маркеры `nvbackground_*` в его доме | `/etc/dconf/db/local.d/50-wallpaper` + замки |
<!-- check-names: on -->

## Что и куда пишется

| Стол | Файл | Как |
|---|---|---|
| GNOME | `/etc/dconf/db/local.d/50-wallpaper`, `locks/50-wallpaper`; профиль `/etc/dconf/profile/user` (`system-db:local`, правило общее с `desktop` и `locale`) | `picture-uri`, `picture-uri-dark` (GNOME 42+; старшему ключ не мешает), `picture-options` — **под замком** |
| Xfce | `/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml` | раскладка Xubuntu: `monitor0…3/image-path`, `image-style` — xfdesktop переносит её на монитор с любым именем; чужой файл не перезаписывается (предупреждение) |
| LXDE | `/etc/xdg/pcmanfm/LXDE/pcmanfm.conf` (`lxde-common`), секция `[desktop]` | `wallpaper`, `wallpaper_mode`; прежние значения — в `/var/lib/cream/ext/wallpaper/pcmanfm.orig`, `remove` их возвращает |

Запись — во временный файл рядом и `rename`: ссылка на месте нашего файла
заменяется, а не проходится; `pcmanfm.conf`, который сам ссылка, не правится
(предупреждение). Режим и владелец `pcmanfm.conf` сохраняются. Повтор не меняет
ни одного файла и не зовёт `dconf update`.

## Почему замок в GNOME

На L4T пакет `nvidia-l4t-configs` кладёт `/etc/xdg/autostart/nvbackground.sh`, и тот
на **каждом** старте сессии делает `gsettings set … NVIDIA_Wallpaper.jpg`. Замеры на
платах 2026-09-12 и 2026-09-15: наши значения переписывались через минуту-другую.
Прежде это обходилось маркерами в доме пользователя; замок системной базы делает
ключ незаписываемым для любого `gsettings` сеанса — и для вендорского скрипта, и для
старого значения в базе пользователя. Цена: в GNOME пользователь не сменит обои сам,
пока расширение стоит (`cream remove wallpaper` снимает замок).

В Xfce и LXDE замка нет: это умолчание, и **собственные настройки пользователя
побеждают**. `configure` смотрит (только наличие файла, ничего не читая и не правя),
есть ли у пользователя cloud-init свой `xfce4-desktop.xml` или `desktop-items-0.conf`,
и предупреждает.

## Картинки

Картинки — в `images/` дерева расширения: cream кладёт его в
`/opt/cream/ext/wallpaper/` целиком, и обои ссылаются туда же, без копии.
**Нет файла — отказ `install`** (и `configure`): слой ставят затем, чтобы на столе
была заданная картинка, и молча собрать образ без неё значит отдать роботу не то,
что просили.

## Проверки

- **V** — `make cream-validate` (с пином cream ≥ 1.1.1), `tools/lint-hooks.sh`, `tools/check-names.sh`.
- **H** — `tests/test-wallpaper.sh`: три стола, режимы, повтор без изменений, отказ
  на имени картинки чужой формы, на ссылке и на отсутствующем файле, ссылки на
  месте наших файлов и `pcmanfm.conf`, дом пользователя не тронут, `remove` и повтор.
- **L** — `make test-live EXT=wallpaper` поверх `xfce4` (`tests/live.env`).
- **P** — что картинка видна на экране (GNOME на Jetson с `nvbackground.sh`, Xfce,
  LXDE) — глазами на машине с монитором; в контейнере экрана нет.
