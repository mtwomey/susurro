# Susurro — build and bundle
#
#   make whisper  — build vendored whisper.cpp static libs (once, or after submodule update)
#   make app      — build release binary and assemble build/Susurro.app
#   make run      — build, bundle, and (re)launch the app
#   make test     — run unit tests
#   make clean    — remove build artifacts

APP_NAME    = Susurro
BUILD_DIR   = build
APP         = $(BUILD_DIR)/$(APP_NAME).app
BINARY      = .build/release/$(APP_NAME)
WHISPER_DIR = build-whisper
DEPLOY_TGT  = 15.0
# Stable self-signed identity — keeps TCC (Accessibility/mic) grants across rebuilds
SIGN_ID     = Susurro Dev
# Single source of truth for the version — `make app` copies this plist into the bundle
VERSION    := $(shell defaults read $(CURDIR)/Support/Info CFBundleShortVersionString)
ZIP         = $(BUILD_DIR)/$(APP_NAME)-$(VERSION).zip
TAP         = ../homebrew-susurro
CASK        = $(TAP)/Casks/susurro.rb

.PHONY: whisper app run test clean dist release verify-release

whisper:
	cmake -B $(WHISPER_DIR) vendor/whisper.cpp \
		-DBUILD_SHARED_LIBS=OFF \
		-DGGML_METAL=ON \
		-DGGML_METAL_EMBED_LIBRARY=ON \
		-DGGML_OPENMP=OFF \
		-DWHISPER_BUILD_EXAMPLES=OFF \
		-DWHISPER_BUILD_TESTS=OFF \
		-DWHISPER_BUILD_SERVER=OFF \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=$(DEPLOY_TGT) \
		-DCMAKE_BUILD_TYPE=Release
	cmake --build $(WHISPER_DIR) --config Release -j $$(sysctl -n hw.logicalcpu)

app:
	swift build -c release
	@mkdir -p $(APP)/Contents/MacOS
	@cp $(BINARY) $(APP)/Contents/MacOS/$(APP_NAME)
	@mkdir -p $(APP)/Contents/Resources
	@cp Support/AppIcon.icns $(APP)/Contents/Resources/
	@cp Support/Info.plist $(APP)/Contents/Info.plist
	@codesign --force --options runtime --entitlements Support/Susurro.entitlements --sign "$(SIGN_ID)" $(APP)
	@echo "✓ $(APP)"

# SUSURRO_DEV_SEED_LEGACY_MODEL=1 lets a dev machine with a local whisper.cpp
# checkout skip a 466 MB re-download by copying its small.en model in on first
# launch (see ModelManager.seedFromLegacyIfNeeded + docs/DEVELOPMENT.md). Kept out
# of `make install`/`make dist` on purpose -- production launches shouldn't
# reach outside their own sandboxed data.
run: app
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@sleep 0.3
	open --env SUSURRO_DEV_SEED_LEGACY_MODEL=1 $(APP)

test:
	swift test

# Install to /Applications and relaunch from there
install: app
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@sleep 0.3
	@ditto $(APP) /Applications/$(APP_NAME).app
	@open /Applications/$(APP_NAME).app
	@echo "✓ installed to /Applications/$(APP_NAME).app"
	@echo "  If 'Start at Login' was enabled, toggle it off/on once so it points here."

# Distributable zip (self-signed — recipients need the Gatekeeper "Open Anyway"
# step documented in the README; Developer ID + notarization removes that)
dist: app
	@cd $(BUILD_DIR) && ditto -c -k --keepParent $(APP_NAME).app $(APP_NAME)-$(VERSION).zip
	@ls -lh $(ZIP)

clean:
	rm -rf .build $(BUILD_DIR)

# Cut a release end-to-end: build the zip, pin its SHA256 in the tap, publish the
# GitHub release, push the tap, then verify the published asset matches the pin.
# Usage: make release
# Requires: gh authenticated, and $(TAP) to exist
#           (clone https://github.com/mtwomey/homebrew-susurro)
#
# A published version is an immutable contract: the cask pins a SHA256, so
# re-uploading a rebuilt zip over an existing release silently breaks
# `brew install` for every new user. That is exactly what happened to 0.1.9 --
# the asset was replaced 9 days after the cask was pinned, and installs failed
# with "Cask reports different checksum". Hence the guard below: this refuses to
# touch a tag that already exists. To ship a change, bump the version.
release: dist
	@if gh release view "v$(VERSION)" >/dev/null 2>&1; then \
		echo "✗ Release v$(VERSION) already exists — never overwrite a published asset."; \
		echo "  Bump CFBundleShortVersionString in Support/Info.plist and re-run."; \
		exit 1; \
	fi
	@test -f $(CASK) || { echo "✗ $(CASK) not found — clone the tap next to this repo"; exit 1; }
	$(eval SHA := $(shell shasum -a 256 $(ZIP) | awk '{print $$1}'))
	@echo "Version : $(VERSION)"
	@echo "SHA256  : $(SHA)"
	@sed -i '' "s/^  version \".*\"/  version \"$(VERSION)\"/" $(CASK)
	@sed -i '' "s/^  sha256 \".*\"/  sha256 \"$(SHA)\"/" $(CASK)
	@echo "✓ Pinned in $(CASK)"
	@gh release create "v$(VERSION)" $(ZIP) --title "$(APP_NAME) $(VERSION)" --generate-notes
	@echo "✓ Published release v$(VERSION)"
	@git -C $(TAP) commit -qam "Bump to $(VERSION)" && git -C $(TAP) push -q
	@echo "✓ Pushed tap"
	@$(MAKE) --no-print-directory verify-release

# Confirm the asset on GitHub still hashes to what the tap pins. Safe to run any
# time — this is the check that would have caught the 0.1.9 drift before a user did.
verify-release:
	@set -e; \
	CASK_VER=$$(awk -F'"' '/^  version /{print $$2; exit}' $(CASK)); \
	PINNED=$$(awk -F'"' '/^  sha256 /{print $$2; exit}' $(CASK)); \
	ASSET="$(APP_NAME)-$$CASK_VER.zip"; \
	echo "Cask pins  : $$CASK_VER / $$PINNED"; \
	LIVE=$$(gh release view "v$$CASK_VER" --json assets \
		--jq ".assets[] | select(.name==\"$$ASSET\") | .digest" | sed 's/^sha256://'); \
	if [ -z "$$LIVE" ]; then \
		echo "  (no digest from the API — downloading to hash)"; \
		TMP=$$(mktemp -d); \
		gh release download "v$$CASK_VER" --pattern "$$ASSET" --dir "$$TMP"; \
		LIVE=$$(shasum -a 256 "$$TMP/$$ASSET" | awk '{print $$1}'); \
		rm -rf "$$TMP"; \
	fi; \
	echo "Live asset : $$LIVE"; \
	if [ "$$PINNED" = "$$LIVE" ]; then \
		echo "✓ Cask matches the published asset"; \
	else \
		echo "✗ MISMATCH — brew install fails with 'Cask reports different checksum'"; \
		echo "  Re-pin the cask to $$LIVE, or restore the zip hashing $$PINNED."; \
		exit 1; \
	fi
