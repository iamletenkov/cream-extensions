# l4t

Библиотека (`kind: library`) расширений стека L4T — `tensorrt`, `l4t-gstreamer`,
`l4t-opencv`, `l4t-pytorch`. Хуков нет: cream раскладывает файл `l4t.sh` в
`/opt/cream/ext/l4t/` и держит его, пока от библиотеки зависит хотя бы одно
расширение (спека cream §4.5). Заменяет общий L4T-файл из `lib/` layout 2.

## Как подключить

Манифест потребителя:

```yaml
depends: [{name: l4t, version: ">=1.0.0 <2"}]
```

Хук потребителя:

```bash
# shellcheck source=/dev/null
source "${CREAM_ROOT:-}/opt/cream/ext/l4t/l4t.sh"
```

Ставится библиотека сама, по `depends`; руками — `cream install l4t`.

## Функции

| Функция | Что делает |
|---|---|
| `l4t_major` | мажор L4T из `/etc/nv_tegra_release` (`32` — Nano, `36` — Orin); нет файла или не разобрать — код 1 и пустой вывод. Путь перекрывает `L4T_RELEASE_FILE` |
| `l4t_openblas_pin ИМЯ` | `OPENBLAS_CORETYPE=ARMV8` для входов (`/etc/environment`) и служб (`/etc/systemd/system.conf.d/ИМЯ.conf`). Идемпотентна: повтор ничего не меняет, чужое значение ключа заменяется, а не дублируется |
| `l4t_openblas_check КОД` | `python3 -c КОД` под `env -i` дважды — с окружением входа и служб, собранным из файлов так, как их читают pam_env и systemd |

Журнал — `log_info`/`log_error` вызывающего, если они объявлены, иначе stderr.

Все пути берутся под `CREAM_ROOT` (на машине — `/`, в тестах — подменённый
корень), который cream передаёт хуку потребителя.

## Зачем OPENBLAS_CORETYPE

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
- **P** — на плате Jetson через потребителей (Task 22–23 плана миграции), платы в CI нет.

## Версии

- **1.0.0** — первая версия cream/v1, перенесена из общего кода layout 2; пути под `CREAM_ROOT`.
