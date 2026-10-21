# apt-guard

Библиотека хуков `remove`: снять пакеты apt, которые поставил `install`, и
**ничего сверх них**. Хуков нет: cream раскладывает `apt-guard.sh` в
`/opt/cream/ext/apt-guard/` и держит его, пока от библиотеки зависит хотя бы одно
расширение (спека cream §4.5).

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | amd64, arm64 |
| cream | ≥ 1.0.0 |
| Вид | библиотека (`kind: library`): общий код других расширений, без хуков |
| Даёт | — |
| Требует | — |
| Зависит от | — |
| Конфликтует с | — |
| Живая машина | да |
<!-- /catalog:facts -->

## Что делает

Даёт потребителям две функции из `${CREAM_ROOT:-}/opt/cream/ext/apt-guard/apt-guard.sh`:

| Функция | Что делает |
|---|---|
| `apt_guard_check ДЕЙСТВИЕ ПАКЕТ…` | `ДЕЙСТВИЕ` — `remove` или `purge`. `apt-get -s ДЕЙСТВИЕ ПАКЕТ…`; строки `Remv`/`Purg` с чужим пакетом — код 1, чужие пакеты и выход названы в stderr. Ничего не меняет |
| `apt_guard_remove ДЕЙСТВИЕ ПАКЕТ…` | `apt_guard_check`, затем `apt-get -q -y ДЕЙСТВИЕ ПАКЕТ…`; отказ или сбой apt — код 1 |

- Пустой список — код 0, apt не зовётся.
- Имя из записи, не похожее на имя пакета Debian (`-o…`, путь, управляющие
  символы), — отказ без вызова apt: запись — файл состояния, а не доверенный ввод.
- Имя в ответе симуляции сравнивается с суффиксом `:arch` и без него.
- Выход при отказе — `APT_GUARD_HINT`, если вызывающий его задал, иначе
  `сними руками или забудь запись: cream remove --forget <расширение>`.
- Сообщения — через `log_error` вызывающего, если он определён; иначе stderr.

## Параметры

<!-- catalog:params -->
Параметров нет.
<!-- /catalog:params -->

Ключей нет.

## Установка

Обычно библиотеку ставит cream по `depends` потребителя. Вручную, на машине с
подключённым каталогом ([как подключить](../../../docs/getting-started.md)):

```bash
sudo cream install apt-guard
cream show apt-guard
```

В образе bisquite (VMFILE) — слоем раньше потребителей:

```dockerfile
RUN_COMMAND cream install apt-guard
```

### Как подключить к своему расширению

Манифест потребителя:

```yaml
depends:
  - {name: apt-guard, version: ">=1.0.0 <2"}
```

Хук `remove` (библиотека нужна, только когда есть что снимать):

```bash
APT_GUARD="$R/opt/cream/ext/apt-guard/apt-guard.sh"
[[ -f "$APT_GUARD" ]] || { log_error "нет библиотеки apt-guard ($APT_GUARD) — cream ставит её по depends"; exit 1; }
# shellcheck source=../../apt-guard/apt-guard.sh
source "$APT_GUARD"
apt_guard_remove remove "${ours[@]}" || exit 1      # проверка и снятие разом
# или: apt_guard_check purge "${ours[@]}" || exit 1  # в начале хука, снятие — позже
```

## Известные ограничения

- Нет: библиотека защищает только `remove` от снятия чужих пакетов; что ставить
  в `install`, решает потребитель.

## Подробности

### Зачем

`apt-get remove X` снимает и всё, что от X зависит. `remove` расширения
`network-manager` на машине со столом снял бы `network-manager-gnome`, а с ним
метапакет стола; `docker` — то, что оператор поставил позже поверх
`containerd.io`. Хук не знает, что ставили после него, поэтому apt сначала
спрашивается симуляцией (`apt-get -s`), и любой пакет в ответе, кроме своих, —
отказ **до каких-либо изменений**.

### Потребители

`network-manager`, `docker`, `firefox`, `nvidia-container-toolkit`, `kiosk`,
`chromium-kiosk`, `jetson-stats`, `can`, `nvidia-jetpack`, `btop`, `x11vnc`,
`vino-vnc`, `rustdesk`, `l4t-gstreamer`, `l4t-opencv`, `l4t-pytorch`,
`l4t-tensorflow`, `cuda-toolkit`, `tensorrt`, `can-usb`, `sensing-gmsl2-camera`.

## Проверки

- **V** — `make cream-validate`, `make check-names`, `tools/lint-hooks.sh`.
- **H** — `tests/test-apt-guard.sh` (своё и чужое в симуляции, `remove` и `purge`,
  провал симуляции и apt, мусор в записи, `:arch`, подсказка вызывающего) и
  H-тест каждого потребителя «симуляция снимает чужой пакет → отказ, ничего не
  снято».
- **L** — через живые прогоны потребителей (`LIVE_DEPS` начинается с `apt-guard`).
