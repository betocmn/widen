# Widen — build helpers.
#
# FoundationModels requires the macOS 26 SDK, which ships with Xcode 26.
# The default Xcode on this machine may be older, so every target pins
# DEVELOPER_DIR to Xcode-26.app. Override with:
#   make build DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

DEVELOPER_DIR ?= /Applications/Xcode-26.app/Contents/Developer
export DEVELOPER_DIR

XCODEBUILD := xcodebuild -project Widen.xcodeproj -scheme Widen -configuration Debug -derivedDataPath build

APP := build/Build/Products/Debug/Widen.app

.PHONY: project build test test-db test-fm setup run run-conductor release release-mac xcode clean

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
	TEST_RUNNER_WIDEN_TEST_DB=$${WIDEN_TEST_DB:-1} $(XCODEBUILD) test

## Run unit + Foundation Models smoke tests (requires Apple Intelligence enabled)
test-fm:
	TEST_RUNNER_WIDEN_FM_TEST=1 $(XCODEBUILD) test

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
