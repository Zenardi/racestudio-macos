# RaceStudio-macOS — developer task runner.
#
# Issue 0.1 ships only the skeleton: these are placeholder targets that are
# fleshed out in later M0 issues (0.2 Rust gate, 0.3 Swift gate, 0.6 DoD wiring).
# They intentionally do nothing yet beyond announcing themselves.

.PHONY: setup test coverage e2e lint ci

setup:   ## Install toolchains & dev dependencies (wired in 0.6)
	@echo "setup: placeholder — wired in issue 0.6"

test:    ## Run Rust + Swift test suites (wired in 0.6)
	@echo "test: placeholder — wired in issue 0.6"

coverage: ## Enforce the 95% line-coverage gate (wired in 0.2/0.3)
	@echo "coverage: placeholder — wired in issues 0.2 and 0.3"

e2e:     ## Run end-to-end checks (wired in 0.6)
	@echo "e2e: placeholder — wired in issue 0.6"

lint:    ## clippy + rustfmt + swiftlint (wired in 0.6)
	@echo "lint: placeholder — wired in issue 0.6"

ci:      ## Aggregate gate run in CI (wired in 0.6)
	@echo "ci: placeholder — wired in issue 0.6"
