# Widen — build helpers.
#
# FoundationModels requires the macOS 26 SDK, which ships with Xcode 26.
# The default Xcode on this machine may be older, so every target pins
# DEVELOPER_DIR to Xcode-26.app. Override with:
#   make build DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

DEVELOPER_DIR ?= /Applications/Xcode-26.app/Contents/Developer
export DEVELOPER_DIR

XCODEBUILD := xcodebuild -project Widen.xcodeproj -scheme Widen -configuration Debug -derivedDataPath build
EVAL_XCODEBUILD := xcodebuild -project Widen.xcodeproj -scheme WidenEval -configuration Debug -derivedDataPath build

APP := build/Build/Products/Debug/Widen.app
EVAL := build/Build/Products/Debug/WidenEval
MODEL ?= openai/gpt-5.5
BACKEND ?= local
RETRIEVER ?= both
CLOUD_AGENT ?= tools
RELEASE_VERSION ?= $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Widen/Info.plist 2>/dev/null || echo 0.1.0)
EVAL_ARGS := --suite Evals/suites/text-to-sql-v1.json
ifdef CASE
EVAL_ARGS += --case $(CASE)
endif
ifdef REPEAT
EVAL_ARGS += --repeat $(REPEAT)
endif
ifdef CASE_TIMEOUT_SECONDS
EVAL_ARGS += --case-timeout-seconds $(CASE_TIMEOUT_SECONDS)
endif
ifdef OUTPUT
EVAL_ARGS += --output $(OUTPUT)
endif
ifdef FAIL_UNDER
EVAL_ARGS += --fail-under $(FAIL_UNDER)
endif

.PHONY: project build test test-db test-fm eval-build eval-local eval-cloud eval-cloud-agent eval-all eval-case eval-cloud-agent-case eval-retrieval eval-retrieval-case eval-schema-tools eval-inspection-tools eval-db-local eval-db-cloud eval-db-cloud-agent eval-release eval-release-triage eval-db-case eval-openrouter-smoke setup run run-conductor release release-mac xcode clean

## Regenerate Widen.xcodeproj from project.yml
project:
	xcodegen generate

## Resolve Swift package dependencies
setup:
	$(XCODEBUILD) -resolvePackageDependencies

## Build the app (Debug)
build:
	$(XCODEBUILD) build

## Run unit tests (integration tests are skipped unless gated env vars are set)
test:
	$(XCODEBUILD) test

## Run unit + Postgres integration tests against a local database.
## Each test provisions and drops its own throwaway database, so this only
## needs a local PostgreSQL whose role can CREATE DATABASE — no manual seeding.
## Override host/port/user/maintenance DB by exporting WIDEN_TEST_DB_HOST,
## WIDEN_TEST_DB_PORT, WIDEN_TEST_DB_USER, WIDEN_TEST_DB_MAINTENANCE_DB; the
## TEST_RUNNER_ prefix is what xcodebuild forwards into the test bundle.
test-db:
	env -u WIDEN_TEST_DB -u TEST_RUNNER_WIDEN_TEST_DB $(XCODEBUILD) test
	TEST_RUNNER_WIDEN_TEST_DB=$${WIDEN_TEST_DB:-1} \
	TEST_RUNNER_WIDEN_TEST_DB_HOST="$${WIDEN_TEST_DB_HOST:-}" \
	TEST_RUNNER_WIDEN_TEST_DB_PORT="$${WIDEN_TEST_DB_PORT:-}" \
	TEST_RUNNER_WIDEN_TEST_DB_USER="$${WIDEN_TEST_DB_USER:-}" \
	TEST_RUNNER_WIDEN_TEST_DB_MAINTENANCE_DB="$${WIDEN_TEST_DB_MAINTENANCE_DB:-}" \
	$(XCODEBUILD) test -only-testing:WidenTests/PostgresIntegrationTests -only-testing:WidenTests/QueryExecutionIntegrationTests -only-testing:WidenTests/TextToSQLSemanticDatabaseIntegrationTests

## Run unit + Foundation Models smoke tests (requires Apple Intelligence enabled)
test-fm:
	$(XCODEBUILD) test
	TEST_RUNNER_WIDEN_FM_TEST=1 $(XCODEBUILD) test -only-testing:WidenTests/FoundationModelsSmokeTests

## Build the native text-to-SQL eval runner
eval-build:
	$(EVAL_XCODEBUILD) build

## Run the text-to-SQL eval suite against local Foundation Models
eval-local: eval-build
	$(EVAL) --backend local $(EVAL_ARGS)

## Run the text-to-SQL eval suite against OpenRouter
eval-cloud: eval-build
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --backend cloud --model "$(MODEL)" $(EVAL_ARGS)

## Run the text-to-SQL eval suite against OpenRouter with --cloud-agent legacy|tools
eval-cloud-agent: eval-build
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --backend cloud --model "$(MODEL)" --cloud-agent "$(CLOUD_AGENT)" $(EVAL_ARGS)

## Run a tiny OpenRouter transport and structured-response smoke suite
eval-openrouter-smoke: eval-build
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --backend cloud --model "$(MODEL)" --suite Evals/suites/openrouter-smoke-v1.json $(filter-out --suite Evals/suites/text-to-sql-v1.json,$(EVAL_ARGS))

## Run the text-to-SQL eval suite against local and cloud backends
eval-all: eval-build
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --backend both --model "$(MODEL)" $(EVAL_ARGS)

## Run one eval case. Example: make eval-case CASE=preseason.top-wins-defined BACKEND=cloud
eval-case: eval-build
	@test -n "$(CASE)" || (echo "error: CASE is required" >&2; exit 1)
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --backend "$(BACKEND)" --model "$(MODEL)" $(EVAL_ARGS)

## Run one OpenRouter cloud-agent eval case. Example: make eval-cloud-agent-case CASE=preseason.top-wins-defined CLOUD_AGENT=tools
eval-cloud-agent-case: eval-build
	@test -n "$(CASE)" || (echo "error: CASE is required" >&2; exit 1)
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --backend cloud --model "$(MODEL)" --cloud-agent "$(CLOUD_AGENT)" $(EVAL_ARGS)

## Run deterministic schema retrieval evals with --retriever legacy|index|both
eval-retrieval: eval-build
	$(EVAL) --suite Evals/suites/schema-retrieval-v1.json --retriever "$(RETRIEVER)" $(filter-out --suite Evals/suites/text-to-sql-v1.json,$(EVAL_ARGS))

## Run one schema retrieval eval case. Example: make eval-retrieval-case CASE=preseason.top-wins-defined RETRIEVER=index
eval-retrieval-case: eval-build
	@test -n "$(CASE)" || (echo "error: CASE is required" >&2; exit 1)
	$(EVAL) --suite Evals/suites/schema-retrieval-v1.json --retriever "$(RETRIEVER)" $(filter-out --suite Evals/suites/text-to-sql-v1.json,$(EVAL_ARGS))

## Run deterministic bounded schema tool contract evals with no model or database calls
eval-schema-tools: eval-build
	$(EVAL) --schema-tools $(filter-out --suite Evals/suites/text-to-sql-v1.json,$(EVAL_ARGS))

## Run deterministic privacy-gated database inspection tool evals with no model calls
eval-inspection-tools: eval-build
	$(EVAL) --inspection-tools $(filter-out --suite Evals/suites/text-to-sql-v1.json,$(EVAL_ARGS))

## Run the text-to-SQL eval suite with seeded Postgres semantic grading locally
eval-db-local: eval-build
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --backend local --semantic-db $(EVAL_ARGS)

## Run the text-to-SQL eval suite with seeded Postgres semantic grading through OpenRouter
eval-db-cloud: eval-build
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --backend cloud --model "$(MODEL)" --semantic-db $(EVAL_ARGS)

## Run seeded Postgres semantic grading through OpenRouter with --cloud-agent legacy|tools
eval-db-cloud-agent: eval-build
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --backend cloud --model "$(MODEL)" --cloud-agent "$(CLOUD_AGENT)" --semantic-db $(EVAL_ARGS)

## Run the PR 12 text-to-SQL release gate
eval-release: eval-build
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --backend cloud --model "$(MODEL)" --cloud-agent tools --suite Evals/suites/text-to-sql-v1.json --semantic-db --repeat 3 --release-gate-version "$(RELEASE_VERSION)"

## Run the release gate and write redacted failure triage artifacts
eval-release-triage: eval-build
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --backend cloud --model "$(MODEL)" --cloud-agent tools --suite Evals/suites/text-to-sql-v1.json --semantic-db --repeat 3 --release-gate-version "$(RELEASE_VERSION)" --write-release-triage --release-triage-version "$(RELEASE_VERSION)"

## Run one seeded Postgres semantic eval case
eval-db-case: eval-build
	@test -n "$(CASE)" || (echo "error: CASE is required" >&2; exit 1)
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --backend "$(BACKEND)" --model "$(MODEL)" --semantic-db $(EVAL_ARGS)

## Build and launch the app
run: build
	open $(APP)

## Build and launch the app, blocking until it quits (for Conductor run tab)
run-conductor: build
	open -W -n $(APP)

## Build, notarize, package, and stage a Developer ID macOS release
release-mac: project
	./scripts/release_mac.sh

PUBLISH_RELEASE_FLAGS :=
ifdef BUILD
PUBLISH_RELEASE_FLAGS += --build $(BUILD)
endif
ifeq ($(DRY_RUN),1)
PUBLISH_RELEASE_FLAGS += --dry-run
endif
ifeq ($(NO_OPEN),1)
PUBLISH_RELEASE_FLAGS += --no-open
endif

## Bump, build, notarize, tag, and create a draft GitHub Release
release:
	@test -n "$(VERSION)" || (echo "error: VERSION is required, e.g. make release VERSION=0.1.0" >&2; exit 1)
	./scripts/publish_release.sh "$(VERSION)" $(PUBLISH_RELEASE_FLAGS)

## Open the project in Xcode 26
xcode:
	open -a "Xcode-26" Widen.xcodeproj

clean:
	rm -rf build
