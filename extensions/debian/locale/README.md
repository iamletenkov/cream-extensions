# locale

Системная локаль и раскладки клавиатуры — везде, где они читаются:
система, консоль, Xorg и экран входа GDM, умолчания GNOME. По умолчанию
`en_US.UTF-8` и раскладки `us,ru`.

```
cream install locale                                   # живая машина (live: yes)
cream install locale KEYBOARD_TOGGLE=grp:alt_shift_toggle
cream remove locale
EXTENSION locale                                       # образ bisquite
```

> **С 2.0.0 — cream/v1.** `install.sh` стал хуком `hooks/install`, `apply.sh` —
> хуком `hooks/apply` (его же зовёт `install`), схема `knobs` — `config.keys`
> манифеста; появился хук `remove`. Настройки — домен cream
> `/etc/cream/locale/config` (`cream show/set locale`), ключи не переименованы.
> Каталог в госте — `/opt/cream/ext/locale/`.

## Манифест

| Поле | Значение | Почему |
|---|---|---|
| `targets` | `build: exec`, `live: yes` | только apt-пакеты и файлы; повтор не меняет ничего |
| хуки | `install`, `apply`, `remove` | собственный `apply` (спека cream §8.4): применение — не перезапуск configure, а перерисовка файлов; `configure` на загрузке не нужен |
| `provides` | `system-locale` | `/etc/default/locale`, `/etc/default/keyboard`, X11 InputClass и умолчания GNOME |
| `depends` | нет | правило профиля dconf то же, что у расширения `desktop`, но код свой — зависимость не нужна |

## Что ставится и куда пишется

Пакеты: `locales`, `keyboard-configuration`, `console-setup`, `xkb-data`.
Работу делает `hooks/apply` — один и тот же хук при установке (его зовёт
`hooks/install`) и после `cream set` на работающей машине:

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
правилу, что в расширении `desktop`. Нет `dconf` (не GNOME) — файлы
пишутся, база соберётся `dconf update`, когда он появится.

Повторный `install` (и `install --reinstall`) не меняет ни одного файла:
локаль, `/etc/default/locale`, кэш консоли и база dconf пересобираются только
при смене значений.

## Настройки

Домен `locale`, файл `/etc/cream/locale/config`, схема — `config.keys` манифеста.

| Ключ | Умолчание | Что |
|---|---|---|
| `LOCALE` | `en_US.UTF-8` | `LANG`; только UTF-8 и только из `/usr/share/i18n/SUPPORTED` |
| `KEYBOARD_LAYOUTS` | `us,ru` | раскладки XKB через запятую, вариант в скобках: `us,ru(phonetic)`; первая — основная |
| `KEYBOARD_TOGGLE` | пусто | опция XKB переключения, например `grp:alt_shift_toggle`, `grp:caps_toggle`; пусто — без опции (в GNOME работает Super+Пробел, в консоли и голом Xorg переключения нет) |

## Сборка

```vmfile
EXTENSION locale
EXTENSION locale LOCALE=en_US.UTF-8 KEYBOARD_LAYOUTS=us,ru KEYBOARD_TOGGLE=grp:alt_shift_toggle
```

## Манифест записи / развёртывания

```yaml
firstboot-commands:
  - "cream set locale KEYBOARD_TOGGLE=grp:alt_shift_toggle"
```

(`firstboot_commands` в манифесте развёртывания ВМ.) Хук `apply` не зовёт
`systemctl`, поэтому `cream set` безопасен и на первой загрузке.

## На работающей машине

```bash
cream show locale
sudo cream set locale KEYBOARD_LAYOUTS='us,ru(phonetic)' KEYBOARD_TOGGLE=grp:caps_toggle
sudo cream set locale LOCALE=ru_RU.UTF-8
```

Хук `apply` переписывает файлы и компилирует локаль. Подхватывают их: локаль —
новый вход в сессию; консоль — `sudo setupcon` или перезагрузка; GNOME — сразу
(база dconf меняется на лету) у тех, кто не выбрал свои источники; экран
входа — перезапуск `gdm3` или перезагрузка.

## Удаление

`cream remove locale` снимает умолчания GNOME (`40-locale` в `local.d` и
`gdm.d`) и пересобирает базу dconf. **Не** откатываются: `/etc/default/locale`,
`/etc/default/keyboard`, `00-keyboard.conf` и откомпилированная локаль —
машина без локали и раскладки хуже, чем с последней выбранной; пакеты
`locales` и `keyboard-configuration` — часть любой базы Debian/Ubuntu.

## Проверка

```bash
locale                                   # LANG=en_US.UTF-8
localectl status                         # X11 Layout: us,ru
cat /etc/default/keyboard
gsettings get org.gnome.desktop.input-sources sources   # [('xkb', 'us'), ('xkb', 'ru')]
```

Тесты: H — `tests/test-locale.sh` (хуки на подменённом корне: умолчания,
Ubuntu, варианты и опция, профиль gdm, отказ на локали не из `SUPPORTED`,
повтор без изменений, `remove`); L — `make test-live EXT=locale`
(`debian-12`, `ubuntu-24.04`). GDM и живая сессия GNOME в контейнере не
проверяются.
