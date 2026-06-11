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

.PHONY: project build test test-db test-fm setup run run-conductor xcode clean

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

## Run unit + Postgres integration tests against a local database
## (requires a running local PostgreSQL and the widen_test sample database)
test-db:
	TEST_RUNNER_WIDEN_TEST_DB=$${WIDEN_TEST_DB:-widen_test} $(XCODEBUILD) test

## Run unit + Foundation Models smoke tests (requires Apple Intelligence enabled)
test-fm:
	TEST_RUNNER_WIDEN_FM_TEST=1 $(XCODEBUILD) test

## Build and launch the app
run: build
	open $(APP)

## Build and launch the app, blocking until it quits (for Conductor run tab)
run-conductor: build
	open -W -n $(APP)

## Open the project in Xcode 26
xcode:
	open -a "Xcode-26" Widen.xcodeproj

clean:
	rm -rf build
