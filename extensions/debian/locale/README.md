# locale

Системная локаль и раскладки клавиатуры — везде, где они читаются:
система, консоль, Xorg и экран входа GDM, умолчания GNOME. По умолчанию
`en_US.UTF-8` и раскладки `us,ru`.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | amd64, arm64 |
| cream | ≥ 1.0.0 |
| Даёт | `system-locale` |
| Требует | — |
| Зависит от | — |
| Конфликтует с | — |
| Хуки | `install`, `apply`, `remove` |
| Настройка на загрузке | — |
| Живая машина | да |
<!-- /catalog:facts -->

## Что делает

- **`install`** — пакеты `locales`, `keyboard-configuration`, `console-setup`,
  `xkb-data`, затем зовёт `hooks/apply`: одна и та же отрисовка при сборке и на
  работающей машине. Только apt-пакеты и файлы; повтор не меняет ничего.
- **`apply`** — собственный хук (спека cream §8.4): применение — не перезапуск
  configure, а перерисовка файлов; `configure` на загрузке не нужен. Зовётся
  из `install` и после `cream set locale …`; генерирует локаль и переписывает
  файлы клавиатуры; `systemctl` не зовёт вовсе.
- **`remove`** — снимает умолчания GNOME (см. «Удаление»).

Куда пишет `apply`:

| Файл | Кто читает |
|---|---|
| `/etc/locale.gen` + `locale-gen` | откомпилированная локаль (`locale -a`); уже откомпилированная не пересобирается |
| `/etc/default/locale` (`update-locale --reset LANG=…`) | PAM/сессии, systemd-localed; переписывается только при смене |
| `/etc/default/keyboard` | консоль (`console-setup`, кэш обновляется `setupcon --save-only` только при смене раскладок), Xorg через udev, systemd-localed |
| `/etc/X11/xorg.conf.d/00-keyboard.conf` | Xorg и экран входа GDM (тот же формат, что пишет `localectl set-x11-keymap`) |
| `/etc/dconf/db/local.d/40-locale` | GNOME: `org.gnome.desktop.input-sources` `sources`/`xkb-options` по умолчанию |
| `/etc/dconf/db/gdm.d/40-locale` | экран входа GDM, если у gdm есть профиль dconf |

Умолчания GNOME — **без locks**: пользователь меняет раскладки в
«Настройках», и его выбор сильнее. Обратная сторона: у пользователя, который
уже выбрал свои источники ввода, умолчание не видно — так и задумано.
Профиль `/etc/dconf/profile/user` дополняется `system-db:local` по тому же
правилу, что в расширении `desktop` (код свой — зависимость от `desktop` не
нужна). Нет `dconf` (не GNOME) — файлы пишутся, база соберётся `dconf update`,
когда он появится.

Повторный `install` (и `install --reinstall`) не меняет ни одного файла:
локаль, `/etc/default/locale`, кэш консоли и база dconf пересобираются только
при смене значений.

## Параметры

<!-- catalog:params -->
| Ключ | Тип | Умолчание | Что задаёт |
|---|---|---|---|
| `LOCALE` | строка `^[a-z]{2,3}_[A-Z]{2}\.UTF-8(@[a-z]+)?$` | `en_US.UTF-8` | системная локаль (LANG в /etc/default/locale); только UTF-8 и только из /usr/share/i18n/SUPPORTED |
| `KEYBOARD_LAYOUTS` | строка `^[a-z]{2,8}(\([a-z0-9_]+\))?(,[a-z]{2,8}(\([a-z0-9_]+\))?)*$` | `us,ru` | раскладки XKB через запятую, вариант в скобках: us,ru(phonetic); первая — основная |
| `KEYBOARD_TOGGLE` | строка `^grp:[a-z0-9_]+$` | пусто | переключение раскладок (опция XKB), например grp:alt_shift_toggle; пусто — без опции (в GNOME — Super+Пробел) |
<!-- /catalog:params -->

Домен `locale`, файл `/etc/cream/locale/config` (`cream show/set locale`).
`KEYBOARD_TOGGLE` пусто — в GNOME работает Super+Пробел, в консоли и голом
Xorg переключения нет.

## Установка

На машине с подключённым каталогом ([как подключить](../../../docs/getting-started.md)):

```bash
sudo cream install --with-deps locale
sudo cream install --with-deps locale KEYBOARD_TOGGLE=grp:alt_shift_toggle
cream show locale
```

В образе bisquite (VMFILE):

```dockerfile
RUN_COMMAND cream install --with-deps locale
RUN_COMMAND cream install --with-deps locale LOCALE=en_US.UTF-8 KEYBOARD_LAYOUTS=us,ru KEYBOARD_TOGGLE=grp:alt_shift_toggle
```

### Манифест записи / развёртывания

```yaml
firstboot-commands:
  - "cream set locale KEYBOARD_TOGGLE=grp:alt_shift_toggle"
```

(`firstboot_commands` в манифесте развёртывания ВМ.) Хук `apply` не зовёт
`systemctl`, поэтому `cream set` безопасен и на первой загрузке.

### На работающей машине

```bash
cream show locale
sudo cream set locale KEYBOARD_LAYOUTS='us,ru(phonetic)' KEYBOARD_TOGGLE=grp:caps_toggle
sudo cream set locale LOCALE=ru_RU.UTF-8
```

## Этапы

| Когда | Что происходит |
|---|---|
| сборка образа / `cream install` | пакеты, затем `apply` |
| загрузка | ничего: `configure` нет |
| `cream set` (хук `apply`) | файлы переписываются, локаль компилируется — только при смене значений |
| `cream remove` | умолчания GNOME снимаются, база dconf пересобирается; локаль и раскладки остаются |

После `apply` изменения подхватывают: локаль — новый вход в сессию; консоль —
`sudo setupcon` или перезагрузка; GNOME — сразу (база dconf меняется на лету) у
тех, кто не выбрал свои источники; экран входа — перезапуск `gdm3` или
перезагрузка.

## Известные ограничения

- `remove` не откатывает локаль и раскладки (см. «Удаление»).
- GDM и живая сессия GNOME в контейнере не проверяются; на arm64 те же пакеты,
  но прогона не было.

## Подробности

### Удаление

`cream remove locale` снимает умолчания GNOME (`40-locale` в `local.d` и
`gdm.d`) и пересобирает базу dconf. **Не** откатываются: `/etc/default/locale`,
`/etc/default/keyboard`, `00-keyboard.conf` и откомпилированная локаль —
машина без локали и раскладки хуже, чем с последней выбранной; пакеты
`locales` и `keyboard-configuration` — часть любой базы Debian/Ubuntu.

### Как проверить на машине

```bash
locale                                   # LANG=en_US.UTF-8
localectl status                         # X11 Layout: us,ru
cat /etc/default/keyboard
gsettings get org.gnome.desktop.input-sources sources   # [('xkb', 'us'), ('xkb', 'ru')]
```

## Проверки

- **V** — `make cream-validate`, `tools/lint-hooks.sh`, `make check-names`.
- **H** — `tests/test-locale.sh` (хуки на подменённом корне: умолчания,
  Ubuntu, варианты и опция, профиль gdm, отказ на локали не из `SUPPORTED`,
  повтор без изменений, `remove`).
- **L** — `make test-live EXT=locale` (`debian-12`, `ubuntu-24.04`). GDM и живая
  сессия GNOME в контейнере не проверяются.
