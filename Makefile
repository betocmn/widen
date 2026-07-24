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
PINNED_OPENROUTER_MODEL := openai/gpt-5.6-sol
MODEL ?= $(PINNED_OPENROUTER_MODEL)
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
CLOUD_COST_ARGS :=
ifdef MAX_CLOUD_COST_USD
CLOUD_COST_ARGS := --max-cloud-cost-usd $(MAX_CLOUD_COST_USD)
EVAL_ARGS += $(CLOUD_COST_ARGS)
endif

# Release-gate targets publish docs/evals/<version>.md and must run the pinned
# production model. Engineering comparisons must opt in explicitly. The same
# rule is enforced inside WidenEval (--allow-model-override), so direct binary
# invocations cannot bypass it either.
REQUIRE_PINNED_MODEL = @test "$(MODEL)" = "$(PINNED_OPENROUTER_MODEL)" || test "$(ALLOW_MODEL_OVERRIDE)" = "1" || { echo "error: release gate requires MODEL=$(PINNED_OPENROUTER_MODEL) but got MODEL=$(MODEL); set ALLOW_MODEL_OVERRIDE=1 to run an engineering comparison" >&2; exit 1; }
MODEL_OVERRIDE_ARGS = $(if $(filter 1,$(ALLOW_MODEL_OVERRIDE)),--allow-model-override,)

.PHONY: project build test test-db test-fm eval-build eval-local eval-cloud eval-cloud-agent eval-all eval-case eval-cloud-agent-case eval-retrieval eval-retrieval-case eval-schema-tools eval-inspection-tools eval-db-local eval-db-cloud eval-db-cloud-agent eval-db-cloud-agent-case eval-release eval-release-triage eval-release-preseason eval-release-overclarification eval-release-sql-shape eval-release-resume eval-db-case eval-openrouter-smoke setup run run-conductor release release-mac xcode clean

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

## Run one seeded Postgres semantic OpenRouter cloud-agent eval case.
eval-db-cloud-agent-case: eval-build
	@test -n "$(CASE)" || (echo "error: CASE is required" >&2; exit 1)
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --backend cloud --model "$(MODEL)" --cloud-agent "$(CLOUD_AGENT)" --semantic-db $(EVAL_ARGS)

## Run the PR 12 text-to-SQL release gate
eval-release: eval-build
	$(REQUIRE_PINNED_MODEL)
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --backend cloud --model "$(MODEL)" --cloud-agent tools --suite Evals/suites/text-to-sql-v1.json --semantic-db --repeat 3 --release-gate-version "$(RELEASE_VERSION)" $(MODEL_OVERRIDE_ARGS) $(CLOUD_COST_ARGS)

## Run the release gate and write redacted failure triage artifacts
eval-release-triage: eval-build
	$(REQUIRE_PINNED_MODEL)
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --backend cloud --model "$(MODEL)" --cloud-agent tools --suite Evals/suites/text-to-sql-v1.json --semantic-db --repeat 3 --release-gate-version "$(RELEASE_VERSION)" --write-release-triage --release-triage-version "$(RELEASE_VERSION)" $(MODEL_OVERRIDE_ARGS) $(CLOUD_COST_ARGS)

## Run focused Preseason release-gate regressions with triage output
eval-release-preseason: eval-build
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --backend cloud --model "$(MODEL)" --cloud-agent tools --suite Evals/suites/text-to-sql-v1.json --case preseason.top-wins-ambiguous --case preseason.top-wins-defined --semantic-db --repeat 3 --write-release-triage $(CLOUD_COST_ARGS)

## Run focused release-gate over-clarification cases with triage output
eval-release-overclarification: eval-build
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --backend cloud --model "$(MODEL)" --cloud-agent tools --schema-agent-clarification-correction experimental --schema-agent-intent-coverage experimental --suite Evals/suites/text-to-sql-v1.json --case commerce.average-order-value-country --case commerce.customer-paid-revenue --case commerce.customers-without-orders --case saas.expiring-subscriptions --case saas.overallocated-seats --case saas.users-without-membership --case support.average-first-response --case support.frequent-feedback-cluster --case support.unclustered-feedback --case support.unresolved-by-assignee --semantic-db --repeat 3 --write-release-triage $(CLOUD_COST_ARGS)

## Run focused release-gate SQL-shape semantic mismatch cases with triage output
eval-release-sql-shape: eval-build
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --backend cloud --model "$(MODEL)" --cloud-agent tools --suite Evals/suites/text-to-sql-v1.json --case commerce.average-order-value-country --case commerce.customer-paid-revenue --case commerce.customers-without-orders --case preseason.active-match-configs --case preseason.verified-tools --case saas.expiring-subscriptions --case saas.overallocated-seats --case support.frequent-feedback-cluster --case support.unclustered-feedback --case support.unresolved-by-assignee --semantic-db --repeat 3 --write-release-triage $(CLOUD_COST_ARGS)

## Resume a previous release-gate run without rerunning completed cases.
## The pinned model is passed explicitly so resume compatibility rejects a
## non-production manifest; an ALLOW_MODEL_OVERRIDE=1 resume without an
## explicit MODEL inherits the manifest model instead, matching how the
## overridden run was started.
RESUME_MODEL_ARGS := --model "$(MODEL)"
ifeq ($(ALLOW_MODEL_OVERRIDE),1)
ifeq ($(origin MODEL),file)
RESUME_MODEL_ARGS :=
endif
endif
eval-release-resume: eval-build
	@test -n "$(RESUME)" || (echo "error: RESUME is required" >&2; exit 1)
	$(REQUIRE_PINNED_MODEL)
	@set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a; \
	$(EVAL) --resume-run "$(RESUME)" --resume-missing $(RESUME_MODEL_ARGS) --release-gate-version "$(RELEASE_VERSION)" --write-release-triage $(MODEL_OVERRIDE_ARGS) $(CLOUD_COST_ARGS)

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
