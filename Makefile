# clamshell — use your Mac with the lid closed, on battery.
#
#   make            build the menu bar app
#   make test       run the test suite
#   sudo make install       install CLI + watcher (and the app, if built)
#   sudo make uninstall     remove everything

APP_NAME    := Clamshell
BUILD_DIR   := build
APP_BUNDLE  := $(BUILD_DIR)/$(APP_NAME).app
APP_BIN     := $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
SWIFT_SRC   := $(wildcard gui/Clamshell/*.swift)
INFO_PLIST  := gui/Clamshell/Info.plist
APP_DEST    := /Applications/$(APP_NAME).app

SWIFTC      := swiftc
SWIFTFLAGS  := -O -target arm64-apple-macos13.0

PREVIEW_DIR := $(BUILD_DIR)/preview
PREVIEW_SRC := gui/Clamshell/CLI.swift gui/Clamshell/Panel.swift gui/Preview/main.swift

.PHONY: all app preview test install install-cli install-app uninstall clean help

all: app

## Build the menu bar app bundle
app: $(APP_BIN)

$(APP_BIN): $(SWIFT_SRC) $(INFO_PLIST)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	@cp $(INFO_PLIST) $(APP_BUNDLE)/Contents/Info.plist
	$(SWIFTC) $(SWIFTFLAGS) -o $@ $(SWIFT_SRC)
	@codesign --force --sign - $(APP_BUNDLE) 2>/dev/null || true
	@echo "built $(APP_BUNDLE)"

## Render the panel to PNGs in build/preview
preview:
	@mkdir -p $(PREVIEW_DIR)
	$(SWIFTC) $(SWIFTFLAGS) -o $(PREVIEW_DIR)/render $(PREVIEW_SRC)
	@$(PREVIEW_DIR)/render $(PREVIEW_DIR)

## Run the test suite
test:
	@./tests/test-clamshell.sh

## Install the CLI and the background watcher (needs sudo)
install-cli:
	@./scripts/install.sh

## Install the menu bar app into /Applications
install-app: $(APP_BIN)
	@pkill -f "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	@rm -rf $(APP_DEST)
	@cp -R $(APP_BUNDLE) $(APP_DEST)
	@echo "installed $(APP_DEST)"
	@if [ -n "$(SUDO_USER)" ]; then \
		sudo -u "$(SUDO_USER)" open $(APP_DEST) && echo "relaunched $(APP_NAME)"; \
	else \
		echo "open it with: open $(APP_DEST)"; \
	fi

## Install everything
install: install-cli
	@if [ -d "$(APP_BUNDLE)" ]; then \
	    $(MAKE) install-app; \
	else \
	    echo ""; \
	    echo "Menu bar app not built. Build and install it with:"; \
	    echo "    make app && sudo make install-app"; \
	fi

## Remove the CLI, watcher and app
uninstall:
	@./scripts/uninstall.sh
	@rm -rf $(APP_DEST)
	@echo "removed $(APP_DEST)"

## Delete build artefacts
clean:
	@rm -rf $(BUILD_DIR)
	@echo "cleaned"

## Show this help
help:
	@echo "clamshell — make targets"
	@echo ""
	@echo "  make                    build the menu bar app"
	@echo "  make preview            render the panel to build/preview/*.png"
	@echo "  make test               run the test suite"
	@echo "  sudo make install       install CLI, watcher and app"
	@echo "  sudo make install-cli   CLI and watcher only"
	@echo "  sudo make install-app   menu bar app only"
	@echo "  sudo make uninstall     remove everything"
	@echo "  make clean              delete build artefacts"
