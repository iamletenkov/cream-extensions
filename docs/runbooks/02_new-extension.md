# 02. Новое расширение

Только каркасом `tools/new-extension.sh` (skill `/new-extension`), не копией соседа:
вместе с соседом копируются чужие способности и пути. Конвенция —
[docs/extensions.md](../extensions.md).

## Шаги

1. **Классифицировать:** новое расширение — минимум bounded (короткий дизайн в PR);
   новая библиотека (`kind: library`) или способность — архитектурная (спека).
2. **Каркас** (ветка `feature/<имя>` от свежего `origin/main`):
   ```sh
   tools/new-extension.sh --help
   tools/new-extension.sh <имя> [--stage system|early|cloud-user|graphical] [--live yes|confirm|no] [--arch amd64,arm64]
   ```
   Каркас сразу проходит `cream validate`, линт хуков и свой H-тест; TODO — то, что знает
   только автор.
3. **H — тест первым.** `extensions/debian/<имя>/tests/test-<имя>.sh` на подменённом корне
   (обвязка `tools/hooktest.sh`: `ht_root`, `ht_fake`, `ht_hook`): поведение и отказы —
   до правки хука.
   ```sh
   bash extensions/debian/<имя>/tests/test-<имя>.sh     # «проверок: N, не прошло: 0»
   ```
4. **Хуки и манифест.** `install` идемпотентный; ключи — `config.keys`, секреты — только
   `$CREAM_SECRETS_FILE`/stdin; скачанное — по пину версии и sha256; `remove` обязателен
   при `live: yes`; `systemctl` в `apply`/`configure` — с `--no-block`; общий код —
   библиотека в `depends`.
5. **L — живой прогон**, если расширение ставится на живую машину: `tests/live.env`
   (`LIVE_DISTROS`, `LIVE_DEPS`, …) и прогон — [runbook 04](04_live-runs.md).
6. **README расширения:** что делает, `cream install/set/run`, таблица ключей, «Проверки» (V/H/L/P).
7. **Проверки и PR:**
   ```sh
   free -g                      # available ≥ 6 ГБ; make ci — по одному на хосте
   make ci                      # shellcheck + tools/check.sh
   git push -u origin feature/<имя>
   gh pr create --title 'feat(<имя>): …' --body '…'
   ```

## Проверка результата

`make ci` зелёный, `make cream-validate` без ошибок (граф, способности), в CI PR зелёные
`check` и (для L-расширения) `live`. Новое расширение попадёт в снимок само — оно под
`roots` каталога (`cream-catalog.yaml`).
