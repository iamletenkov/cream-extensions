# l4t

Библиотека расширений стека L4T — `tensorrt`, `l4t-gstreamer`, `l4t-opencv`,
`l4t-pytorch`: версия L4T и `OPENBLAS_CORETYPE` для Jetson. Хуков нет.

<!-- catalog:facts -->
| | |
|---|---|
| ОС | Debian, Ubuntu |
| Архитектура | arm64 |
| cream | ≥ 1.0.0 |
| Вид | библиотека (`kind: library`): общий код других расширений, без хуков |
| Даёт | — |
| Требует | — |
| Зависит от | — |
| Конфликтует с | — |
| Живая машина | да |
<!-- /catalog:facts -->

## Что делает

cream раскладывает файл `l4t.sh` в `/opt/cream/ext/l4t/` и держит его, пока от
библиотеки зависит хотя бы одно расширение (спека cream §4.5).

| Функция | Что делает |
|---|---|
| `l4t_major` | мажор L4T из `/etc/nv_tegra_release` (`32` — Nano, `36` — Orin); нет файла или не разобрать — код 1 и пустой вывод. Путь перекрывает `L4T_RELEASE_FILE` |
| `l4t_openblas_pin ИМЯ` | `OPENBLAS_CORETYPE=ARMV8` для входов (`/etc/environment`) и служб (`/etc/systemd/system.conf.d/ИМЯ.conf`). Идемпотентна: повтор ничего не меняет, чужое значение ключа заменяется, а не дублируется |
| `l4t_openblas_check КОД` | `python3 -c КОД` под `env -i` дважды — с окружением входа и служб, собранным из файлов так, как их читают pam_env и systemd |

Журнал — `log_info`/`log_error` вызывающего, если они объявлены, иначе stderr.

Все пути берутся под `CREAM_ROOT` (на машине — `/`, в тестах — подменённый
корень), который cream передаёт хуку потребителя.

## Параметры

<!-- catalog:params -->
Параметров нет.
<!-- /catalog:params -->

## Установка

Ставится сама, по `depends` потребителя; руками — `sudo cream install l4t`.
Манифест потребителя:

```yaml
depends: [{name: l4t, version: ">=1.0.0 <2"}]
```

Хук потребителя:

```bash
# shellcheck source=/dev/null
source "${CREAM_ROOT:-}/opt/cream/ext/l4t/l4t.sh"
```

## Известные ограничения

- На плате проверяется только через потребителей; платы в CI нет.

## Подробности

### Зачем OPENBLAS_CORETYPE

На Jetson Nano (Cortex-A57, L4T R32) OpenBLAS из numpy выбирает ядро, которого у
процессора нет, и `import numpy`, `cv2`, `torch` падают с `Illegal instruction`
(замер 2026-09-15 на живой Nano: rc=132 без переменной, чистый импорт с ней).
Образ производителя экспортировал её из `.bashrc` учётки `jetson`, которую цепочка
удаляет, поэтому переменная — системная настройка.

## Проверки

- **V** — `make cream-validate`, `tools/check-names.sh`.
- **H** — `tests/test-l4t.sh`: `l4t_major` на фикстурах R32/R36, запись и повтор
  `l4t_openblas_pin`, замена чужого значения, файл без перевода строки,
  `l4t_openblas_check` (оба источника, сброс `DefaultEnvironment=` в позднем drop-in).
- **P** — на плате Jetson через потребителей, платы в CI нет.
