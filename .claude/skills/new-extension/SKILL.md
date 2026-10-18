---
name: new-extension
description: Завести новое расширение по текущему формату (extension.yaml layout 2, install.sh, configure.sh) через tools/new-extension.sh — не копированием соседа.
argument-hint: <имя> [--family deb|openwrt] [--arch amd64,arm64] [--no-firstboot] [--no-shared-user]
---
# /new-extension $ARGUMENTS

Формат — текущий, из [docs/extensions.md](../../../docs/extensions.md) («Как добавить расширение», «Манифест `extension.yaml`»). **Формат переезжает под cream** (исполнитель расширений на Go, спека в репозитории cream): до неё не изобретай новых полей и путей — `bisquite-*`, `/opt/bisquite/<имя>`, `/etc/bisquite/<имя>`, `/var/lib/bisquite/<имя>` остаются.

1. Классифицируй: новое расширение — минимум bounded; новая способность или правка `lib/` — архитектурная (спека).
2. Каркас: `tools/new-extension.sh <имя> [ключи]` (`--help` — справка). Копировать соседний каталог нельзя: вместе с ним копируются чужие способности и пути.
3. Тест первым: `tools/test-<имя>.sh` на подменённом корне (образец — `tools/test-firewall.sh`), подключи его в `tools/check.sh`.
4. `install.sh` — идемпотентный, от root в госте, параметры из окружения; донастройка — `configure.sh` + `configure-<имя>.service`; общий код — `"$SCRIPT_DIR/lib/…"`, не копией. Скачанное — по пину версии и sha256.
5. `extension.yaml`: `provides`/`requires` выводятся из кода, а не придумываются.
6. `README.md` расширения: что делает в каждой фазе и **таблица параметров** окружения.
7. `make ci` зелёный → reviewer → PR `feat(<имя>): …` (по-русски). Релиз и тег — release-please, не руками.
