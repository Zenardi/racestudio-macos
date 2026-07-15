# RaceStudio-macOS — developer task runner.
#
# `coverage` is wired (Rust gate 0.2 + Swift gate 0.3). The remaining targets
# are placeholders fleshed out in issue 0.6 (DoD wiring).

.PHONY: setup test coverage e2e lint ci xcframework fixtures

setup:   ## Install toolchains & dev dependencies (wired in 0.6)
	@echo "setup: placeholder — wired in issue 0.6"

xcframework: ## Build the universal RaceStudioFFI.xcframework + Swift bindings
	bash scripts/build_xcframework.sh

fixtures: ## Fetch .xrk samples + regenerate libxrk golden JSON oracle
	bash scripts/fetch_fixtures.sh

test:    ## Run Rust + Swift test suites (wired in 0.6)
	@echo "test: placeholder — wired in issue 0.6"

coverage: ## Enforce the Rust + Swift line-coverage gate (≥95% on the logic core)
	bash scripts/coverage.sh

e2e:     ## Run end-to-end checks (wired in 0.6)
	@echo "e2e: placeholder — wired in issue 0.6"

lint:    ## clippy + rustfmt + swiftlint (wired in 0.6)
	@echo "lint: placeholder — wired in issue 0.6"

ci:      ## Aggregate gate run in CI (wired in 0.6)
	@echo "ci: placeholder — wired in issue 0.6"
