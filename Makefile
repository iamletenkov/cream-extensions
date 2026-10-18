# cream-extensions — публичный API репозитория (`make help`).
# Проверки идут на хосте так же, как в CI: bash, python3 с PyYAML, shellcheck
# (нет на хосте — в контейнере koalaman/shellcheck).

.DEFAULT_GOAL := help
.PHONY: help lint test check ci

help: ## список целей
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-8s %s\n", $$1, $$2}'

lint: ## shellcheck всех shell-скриптов (планка -S error, см. tools/lint.sh)
	tools/lint.sh

test: ## tools/check.sh: валидация extension.yaml и тесты расширений
	tools/check.sh

check: lint test ## lint + test

ci: check ## то же, что CI: lint + test
