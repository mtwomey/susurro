# Susurro — build and bundle
#
#   make app      — build release binary and assemble build/Susurro.app
#   make run      — build, bundle, and (re)launch the app
#   make test     — run unit tests
#   make clean    — remove build artifacts

APP_NAME   = Susurro
BUILD_DIR  = build
APP        = $(BUILD_DIR)/$(APP_NAME).app
BINARY     = .build/release/$(APP_NAME)

.PHONY: app run test clean

app:
	swift build -c release
	@mkdir -p $(APP)/Contents/MacOS
	@cp $(BINARY) $(APP)/Contents/MacOS/$(APP_NAME)
	@cp Support/Info.plist $(APP)/Contents/Info.plist
	@codesign --force --sign - $(APP)
	@echo "✓ $(APP)"

run: app
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@sleep 0.3
	open $(APP)

test:
	swift test

clean:
	rm -rf .build $(BUILD_DIR)
