# RaceStudio-macOS — developer task runner. One command per intent.
#
# `make ci` is the exact sequence CI runs, so a green `make ci` locally predicts
# a green pipeline. See docs/DEFINITION_OF_DONE.md for the shared bar.

COVERAGE_THRESHOLD ?= 95
export COVERAGE_THRESHOLD

# SwiftLint needs the Command-Line-Tools SourceKit only when no full Xcode is the
# active developer dir; omitted otherwise (e.g. the CI runner, which has Xcode).
SWIFTLINT_ENV := $(if $(findstring CommandLineTools,$(shell xcode-select -p 2>/dev/null)),DYLD_FRAMEWORK_PATH=/Library/Developer/CommandLineTools/usr/lib,)

.PHONY: setup test test-rust test-swift coverage e2e lint security fixtures xcframework ci clean

setup: ## Install toolchains + fetch test fixtures
	rustup target add aarch64-apple-darwin x86_64-apple-darwin
	rustup component add llvm-tools-preview clippy rustfmt
	command -v cargo-llvm-cov >/dev/null 2>&1 || cargo install cargo-llvm-cov
	command -v swiftlint >/dev/null 2>&1 || brew install swiftlint
	command -v trivy >/dev/null 2>&1 || brew install trivy
	bash scripts/fetch_fixtures.sh

test: test-rust test-swift ## Run the Rust + Swift test suites

test-rust: ## Run the Rust test suite
	cargo test --workspace

test-swift: ## Run the Swift test suite (builds the xcframework if missing)
	@[ -d app/RaceStudioFFI.xcframework ] || bash scripts/build_xcframework.sh
	bash scripts/swift_test.sh

coverage: ## Enforce the >=95% line-coverage gate (Rust + Swift)
	bash scripts/coverage.sh

e2e: ## Build the shipping pipeline + validate the decode oracle
	bash scripts/e2e.sh

lint: ## clippy -D warnings + cargo fmt --check + swiftlint
	cargo clippy --workspace --all-targets -- -D warnings
	cargo fmt --all --check
	cd app && $(SWIFTLINT_ENV) swiftlint lint --strict

security: ## Scan the tree with Trivy (vuln/secret/misconfig); fail on HIGH/CRITICAL
	trivy fs --scanners vuln,secret,misconfig --severity HIGH,CRITICAL \
		--ignore-unfixed --exit-code 1 --no-progress \
		--skip-dirs target --skip-dirs app/.build --skip-dirs .venv-fixtures --skip-dirs dist \
		.

fixtures: ## Fetch .xrk samples + regenerate libxrk golden JSON oracle
	bash scripts/fetch_fixtures.sh

xcframework: ## Build the universal RaceStudioFFI.xcframework + Swift bindings
	bash scripts/build_xcframework.sh

ci: lint coverage e2e ## The exact sequence CI runs (lint -> coverage -> e2e)

clean: ## Remove build artifacts
	rm -rf target app/.build app/RaceStudioFFI.xcframework dist .cache
