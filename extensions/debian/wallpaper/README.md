# wallpaper

Обои GNOME, Xfce, Xubuntu, LXDE (pcmanfm) и LXQt (pcmanfm-qt) из
`/opt/cream/ext/wallpaper/images/`. Системные умолчания; обратимое изменение личных
wallpaper-свойств — только с явным `WALLPAPER_OVERRIDE_USER=1`.

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

## Дизайн #156

1. GNOME: системная база dconf с замками; личная база не меняется.
2. Xfce: системный канал плюс отдельный XDG-слой `/etc/xdg/cream-wallpaper`.
3. Xsession ставит этот слой перед `xdg-xubuntu`; пакетные файлы Xubuntu не правятся.
4. `WALLPAPER_OVERRIDE_USER=1` разрешает менять только wallpaper-свойства Xfce/pcmanfm.
5. Помощник работает от имени каждого обычного пользователя, root в его дом не пишет.
6. Снимок исходных свойств и метка — `~/.config/cream-wallpaper/state.json`, режим 0600.
7. Первый снимок сохраняется при повторе и смене картинки; Xsession охватывает новых пользователей.
8. Configure/remove с личными изменениями требуют выхода из графических сеансов.
9. Remove возвращает исходные свойства, убирает наши добавленные, сохраняет прочие настройки.
10. Последующая личная правка управляемого значения сохраняется, если оно уже не наше.
11. LXDE: `desktop-items-*.conf` `[ * ]` (без пробелов); LXQt: `settings.conf` `[Desktop]`.
12. **Рулинг, проверить владельцу:** явный флаг и выход из сеансов вместо замка всего
    канала Xfce; выбор флага подтверждён владельцем, экранная приёмка ещё обязательна.

## Что делает

- `install`: проверяет картинку, при необходимости ставит `dconf-cli` и `python3`.
- `configure`: стадия `cloud-user`; системные умолчания dconf, xfconf и pcmanfm,
  XDG-слой и Xsession-хук. При явном флаге — личные wallpaper-свойства пользователей
  с UID 1000–65533 и обычной оболочкой, затем тех, кто впервые входит в X11.
- `remove`: сначала восстанавливает личные свойства (если ими управляли), затем
  снимает наши системные файлы и возвращает исходные значения `pcmanfm.conf`.
  Без выхода из графических сеансов — отказ до изменений, снимки остаются для повтора.

| Стол | Системный файл | Личные свойства под флагом |
|---|---|---|
| GNOME | `/etc/dconf/db/local.d/50-wallpaper`, `locks/50-wallpaper` | не меняются; `picture-uri`, `picture-uri-dark`, `picture-options` блокируются в системе |
| Xfce / Xubuntu | `/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml` и копия в XDG-слое | только `backdrop`: `image-path`, `last-image`, `image-style`, `image-show`, `backdrop-cycle-enable` |
| LXDE | `/etc/xdg/pcmanfm/LXDE/pcmanfm.conf` | `wallpaper`, `wallpaper_mode`, `wallpaper_common` в `[ * ]` (без пробелов) |
| LXQt | `/etc/xdg/cream-wallpaper/pcmanfm-qt/lxqt/settings.conf` | `Wallpaper`, `WallpaperMode`, `WallpaperCommon`, `PerScreenWallpaper`, `SlideShowInterval` в `[Desktop]` |

Ссылки в личном пути отвергаются; помощник от root отказывается работать.
Пользовательские процессы не получают окружение и файловые дескрипторы cream,
включая его блокировку; время ограничено. Прочие XML/INI-свойства сохраняются.
Если других изменений не было, remove возвращает исходный личный файл побайтно;
при посторонних изменениях возвращаются только управляемые свойства.
Исходно отсутствующий файл удаляется, если в нём не появилось чужих настроек.

## Параметры

<!-- catalog:params -->
| Ключ | Тип | Умолчание | Что задаёт |
|---|---|---|---|
| `WALLPAPER_IMAGE` | строка `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.(jpg\|jpeg\|png\|svg)$` | `dst_1080.jpg` | картинка — имя файла в /opt/cream/ext/wallpaper/images (без каталогов) |
| `WALLPAPER_MODE` | `zoom` \| `scaled` \| `centered` \| `stretched` \| `spanned` \| `wallpaper` | `zoom` | как вписать: zoom — заполнить с обрезкой, scaled — целиком, centered, stretched, spanned, wallpaper — плиткой |
| `WALLPAPER_OVERRIDE_USER` | `bool` | `0` | явно разрешить обратимое изменение только wallpaper-свойств Xfce/LXDE/LXQt; перед configure/remove выйти из графических сеансов |
<!-- /catalog:params -->

Картинка — обычный файл непосредственно в `images/`: без путей, ссылок и пробелов.
Без файла install/configure отказывают. `zoom`, `scaled`, `centered`, `stretched`,
`spanned`, `wallpaper` соответствуют режимам DE; LXQt для spanned использует stretch.

## Установка

Сначала завершите графические сеансы пользователей, чьи настройки меняются.
Из терминала SSH/TTY машины с подключённым каталогом:

```bash
sudo cream install --with-deps wallpaper WALLPAPER_OVERRIDE_USER=1
# Войдите в графический сеанс: обои применены.
# Для смены/снятия снова завершите графические сеансы.
sudo cream set wallpaper WALLPAPER_IMAGE=dst_1080.jpg WALLPAPER_MODE=scaled
sudo cream remove wallpaper
```

`cream set wallpaper WALLPAPER_OVERRIDE_USER=0` после выхода восстанавливает
личные свойства и оставляет только системные умолчания. Повторная установка
создаёт новый снимок актуальных исходных настроек.

## Ограничения

- Без явного флага личные настройки Xfce/LXDE/LXQt сильнее системного умолчания;
  configure предупреждает об известных личных каналах cloud-init пользователя.
- GNOME блокирует смену обоев до remove (так он также побеждает L4T nvbackground.sh).
- X11: эффект XDG-слоя и личных правок — после следующего входа, без рестарта DM.
  Wayland GNOME обслуживает dconf; личные настройки других Wayland-композиторов не поддержаны.
- Если после выхода остался `xfconfd`, `pcmanfm` или `pcmanfm-qt`, личный помощник
  откажет до правки: пользователь должен остановить свой оставшийся процесс и повторить.
- Пользовательские `XDG_CONFIG_HOME` вне `~/.config` и нестандартные профили DE
  требуют отдельной приёмки; стандартные существующие профили pcmanfm перебираются.
- Чужой системный канал Xfce или файл нашего XDG-слоя — отказ до записей.
  С kiosk 4.x сначала обновите kiosk до 5.0.0; с kiosk 5.x канал принадлежит wallpaper.
  Полноэкранный kiosk скрывает обои; для приёмки нужен обычный сеанс.

## Проверки

H: `tests/test-wallpaper.sh` и `tests/test-user-wallpaper.sh` — порядок XDG,
личные настройки каждой DE, первый вход, remove, reinstall, сохранность других
свойств, ссылки и активные сеансы. Полный гейт — `make ci`.
L: `make test-live EXT=wallpaper` проверяет системные умолчания в контейнере.
Экранная приёмка четырёх DE и её текущие ограничения —
[runbook 05, #156](../../../docs/runbooks/05_existing-desktop-acceptance.md#156).
