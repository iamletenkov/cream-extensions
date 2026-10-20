# apt-guard

Библиотека (`kind: library`) хуков `remove`: снять пакеты apt, которые поставил
`install`, и **ничего сверх них**. Хуков нет: cream раскладывает `apt-guard.sh` в
`/opt/cream/ext/apt-guard/` и держит его, пока от библиотеки зависит хотя бы одно
расширение (спека cream §4.5).

```
cream install apt-guard          # живая машина (обычно ставится по depends)
EXTENSION apt-guard              # образ bisquite — слоем раньше потребителей
```

## Зачем

`apt-get remove X` снимает и всё, что от X зависит. `remove` расширения
`network-manager` на машине со столом снял бы `network-manager-gnome`, а с ним
метапакет стола; `docker` — то, что оператор поставил позже поверх
`containerd.io`. Хук не знает, что ставили после него, поэтому apt сначала
спрашивается симуляцией (`apt-get -s`), и любой пакет в ответе, кроме своих, —
отказ **до каких-либо изменений**. Раньше эта проверка жила копиями в шести
хуках стека L4T, а половина хуков каталога обходилась без неё (финальное ревью
каталога 5.0.0).

## Как подключить

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

## Функции

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

## Потребители

`network-manager`, `docker`, `firefox`, `nvidia-container-toolkit`, `kiosk`,
`chromium-kiosk`, `jetson-stats`, `can`, `nvidia-jetpack`, `btop`, `x11vnc`,
`vino-vnc`, `rustdesk`, `l4t-gstreamer`, `l4t-opencv`, `l4t-pytorch`,
`l4t-tensorflow`, `cuda-toolkit`, `tensorrt`, `can-usb`, `sensing-gmsl2-camera`.

## Манифест

| Поле | Значение |
|---|---|
| `kind` | `library` — путь `${CREAM_ROOT:-}/opt/cream/ext/apt-guard/apt-guard.sh` |
| `targets` | `build: exec`, `live: yes` |
| `platform.arch` | amd64 arm64 |

## Проверки

- **V** — `make cream-validate`, `make check-names`, `tools/lint-hooks.sh`.
- **H** — `tests/test-apt-guard.sh` (своё и чужое в симуляции, `remove` и `purge`,
  провал симуляции и apt, мусор в записи, `:arch`, подсказка вызывающего) и
  H-тест каждого потребителя «симуляция снимает чужой пакет → отказ, ничего не
  снято».
- **L** — через живые прогоны потребителей (`LIVE_DEPS` начинается с `apt-guard`).
