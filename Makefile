# cream-extensions — публичный API репозитория (`make help`).
# Проверки идут на хосте так же, как в CI: bash, git, python3 с PyYAML, shellcheck
# (нет на хосте — в контейнере koalaman/shellcheck), docker для cream validate
# (контейнер debian:12, tools/cream-validate.sh).

.DEFAULT_GOAL := help
.PHONY: help lint test check ci cream-validate cream-check check-names test-live test-live-self snapshot snapshot-check

help: ## список целей
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-15s %s\n", $$1, $$2}'

lint: ## shellcheck всех shell-скриптов (планка -S error, см. tools/lint.sh)
	tools/lint.sh

test: ## tools/check.sh: cream validate, гейт имён, линт хуков, тесты инструментов и расширений
	tools/check.sh

check-names: ## гейт имён bisquite по репозиторию, кроме истории (tools/check-names.sh)
	tools/check-names.sh

# Живой прогон: настоящий cream в контейнере с systemd, сеть, под замком flock.
# Умолчания расширения — его tests/live.env; DISTRO=debian-12|debian-13|ubuntu-20.04|ubuntu-22.04|ubuntu-24.04;
# прочие флаги tools/live-test.sh — в ARGS (ARGS="--accept-risk --deps 'cloud-user'").
DISTRO ?= debian-12
test-live: ## живой прогон: make test-live EXT=<имя> [DISTRO=…] [ARGS=…] (tools/live-test.sh)
	@test -n "$(EXT)" || { echo "make test-live: нужен EXT=<имя расширения>" >&2; exit 2; }
	tools/live-test.sh --distro "$(DISTRO)" $(ARGS) "$(EXT)"

test-live-self: ## самопроверка L-раннера на фикстурах tools/testdata/live [DISTRO=…] (тяжёлая)
	tools/test-live-test.sh "$(DISTRO)"

cream-validate: ## cream validate --catalog . по корню (пин tools/cream-pin.env или CREAM_DEB=<.deb>)
	tools/cream-validate.sh

cream-check: ## cream check: каждое расширение строкой образа (пин tools/cream-pin.env или CREAM_DEB=<.deb>)
	tools/cream-check.sh

snapshot: ## снимок каталога из HEAD: dist/cream-extensions-<v>.tar.gz + dist/SHA256SUMS (tools/catalog-snapshot.sh)
	tools/catalog-snapshot.sh

snapshot-check: ## две сборки снимка дают одни байты, cream принимает снимок (tools/test-snapshot.sh)
	tools/test-snapshot.sh

check: lint test ## lint + test

ci: check ## то же, что CI: lint + test
