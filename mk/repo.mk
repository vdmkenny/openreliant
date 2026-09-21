# The firewall between the repository and the game's files: a check that fails on anything that
# looks like one, run over every commit by `make check-files` and CI, and over each new commit by
# the pre-commit hook `make hooks` installs.

##@ Repository

.PHONY: check-files
check-files: ## Fail if any commit holds a file from the game, or one that looks like it
	scripts/check-files.sh --history

.PHONY: hooks
hooks: ## Use the repository's git hooks, which refuse commits holding the game's files
	git config core.hooksPath scripts/hooks
