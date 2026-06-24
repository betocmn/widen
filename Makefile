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

.PHONY: project build test test-db test-fm eval-build eval-local eval-cloud eval-all eval-case eval-db-local eval-db-cloud eval-db-case setup run run-conductor release release-mac xcode clean

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
test-db:
	env -u WIDEN_TEST_DB -u TEST_RUNNER_WIDEN_TEST_DB $(XCODEBUILD) test
	TEST_RUNNER_WIDEN_TEST_DB=$${WIDEN_TEST_DB:-1} $(XCODEBUILD) test -only-testing:WidenTests/PostgresIntegrationTests -only-testing:WidenTests/QueryExecutionIntegrationTests -only-testing:WidenTests/TextToSQLSemanticDatabaseIntegrationTests

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

## Run the text-to-SQL eval suite against local and cloud backends
eval-all: eval-build
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --backend both --model "$(MODEL)" $(EVAL_ARGS)

## Run one eval case. Example: make eval-case CASE=preseason.top-wins-defined BACKEND=cloud
eval-case: eval-build
	@test -n "$(CASE)" || (echo "error: CASE is required" >&2; exit 1)
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --backend "$(BACKEND)" --model "$(MODEL)" $(EVAL_ARGS)

## Run the text-to-SQL eval suite with seeded Postgres semantic grading locally
eval-db-local: eval-build
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --backend local --semantic-db $(EVAL_ARGS)

## Run the text-to-SQL eval suite with seeded Postgres semantic grading through OpenRouter
eval-db-cloud: eval-build
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --backend cloud --model "$(MODEL)" --semantic-db $(EVAL_ARGS)

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
