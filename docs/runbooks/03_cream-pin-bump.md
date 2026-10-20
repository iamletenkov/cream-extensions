# 03. Подъём пина cream

Пин исполнителя для проверок каталога — одна правка `tools/cream-pin.env`
(`cream validate`, снимок, живые прогоны берут cream оттуда).

## Шаги

1. Ветка `build/cream-<версия>` от свежего `origin/main`. Суммы — из `SHA256SUMS` релиза:
   ```sh
   gh release download v<версия> -R iamletenkov/cream -p SHA256SUMS -O - | grep -E '_(amd64|arm64)\.deb'
   ```
2. Правка `tools/cream-pin.env`: `CREAM_VERSION`, `CREAM_SHA256` (amd64), `CREAM_SHA256_ARM64`;
   строка в шапке файла — что изменилось в этой версии для каталога.
3. Если расширению нужна новая возможность cream — поднять его `cream: ">=…"` в
   `extension.yaml` (и минор расширения).
4. Проверки по одной:
   ```sh
   free -g
   make cream-validate          # новый cream принимает все манифесты; предупреждения — разобрать
   make ci
   make snapshot-check          # снимок собирается и принимается новым cream
   make test-live-self          # самопроверка L-раннера (тяжёлая)
   ```
5. PR `build(tools): пин cream <версия> — <что даёт>`; правка пина запускает в
   `live.yml` все L-расширения — дождаться зелёного.

## Проверка результата

`make cream-validate` без новых предупреждений, `make snapshot-check` зелёный, `live.yml`
на PR зелёный по всем L-расширениям. Кеш старого `.deb` (`.cache/cream/`) можно удалить.
