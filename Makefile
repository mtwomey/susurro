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

.PHONY: whisper app run test clean dist release

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
# launch (see ModelManager.seedFromLegacyIfNeeded + DEVELOPMENT.md). Kept out
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
	@cd $(BUILD_DIR) && ditto -c -k --keepParent $(APP_NAME).app Susurro-$$(defaults read $$(pwd)/$(APP_NAME).app/Contents/Info CFBundleShortVersionString).zip
	@ls -lh $(BUILD_DIR)/*.zip

clean:
	rm -rf .build $(BUILD_DIR)

# Build dist zip, compute SHA256, update homebrew-susurro tap, and open for review
# Usage: make release
# Requires: ../homebrew-susurro to exist (clone https://github.com/mtwomey/homebrew-susurro)
release: dist
	$(eval VERSION := $(shell defaults read $(CURDIR)/$(BUILD_DIR)/$(APP_NAME).app/Contents/Info CFBundleShortVersionString))
	$(eval ZIP := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).zip)
	$(eval SHA := $(shell shasum -a 256 $(ZIP) | awk '{print $$1}'))
	@echo "Version : $(VERSION)"
	@echo "SHA256  : $(SHA)"
	@CASK=../homebrew-susurro/Casks/susurro.rb; \
	sed -i '' "s/version \".*\"/version \"$(VERSION)\"/" $$CASK; \
	sed -i '' "s/sha256 \".*\"/sha256 \"$(SHA)\"/" $$CASK; \
	echo "✓ Updated $$CASK"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Upload $(ZIP) to a new GitHub release tagged v$(VERSION)"
	@echo "  2. cd ../homebrew-susurro && git diff   # verify the cask changes"
	@echo "  3. git -C ../homebrew-susurro commit -am 'Bump to $(VERSION)' && git push"
