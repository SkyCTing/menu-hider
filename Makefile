# Build, test and install MenuHider. `make gen` needs xcodegen (brew install xcodegen).
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

SCHEME    := MenuHider
BUILD_DIR := build
APP       := $(BUILD_DIR)/Build/Products/Release/MenuHider.app

# Signing overrides (see project.yml). Put your defaults into local.mk, which is git-ignored:
#   SIGN_IDENTITY := Developer ID Application
#   TEAM          := XXXXXXXXXX
-include local.mk
SIGN_IDENTITY ?= -
TEAM          ?=
SIGN_FLAGS    := CODE_SIGN_IDENTITY="$(SIGN_IDENTITY)" DEVELOPMENT_TEAM="$(TEAM)"

XCODEBUILD := xcodebuild -project menu-hider.xcodeproj -scheme $(SCHEME) -derivedDataPath $(BUILD_DIR)

.PHONY: gen build test run install lint release clean

gen:
	xcodegen generate --use-cache

build: gen
	$(XCODEBUILD) -configuration Release $(SIGN_FLAGS) build | tail -5

test: gen
	$(XCODEBUILD) -configuration Debug test 2>&1 | grep -E 'Test Case|error|passed|failed|Executed' | tail -30

lint:
	swiftlint lint --quiet
	xcrun swift-format lint --recursive --configuration .swift-format MenuHider MenuHiderTests

run: build
	pkill -x MenuHider || true
	open $(APP)

install: build
	pkill -x MenuHider || true
	rm -rf /Applications/MenuHider.app
	cp -R $(APP) /Applications/MenuHider.app
	open /Applications/MenuHider.app

# One command per release: version, package, commit, tag, push, GitHub Release.
#   make release VERSION=1.0.0 NOTE="two hidden zones, one switch"
#   make release VERSION=1.0.0 NOTE="…" ARGS=--yes     # no confirmation prompt
release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=x.y.z [NOTE=\"…\"] [ARGS=--yes]"; exit 1; }
	SIGN_IDENTITY="$(SIGN_IDENTITY)" TEAM="$(TEAM)" scripts/release.sh "$(VERSION)" "$(NOTE)" $(ARGS)

clean:
	rm -rf $(BUILD_DIR) dist menu-hider.xcodeproj
