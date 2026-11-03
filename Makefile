.PHONY: build test bundle install run clean

CODESIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development/{print $$2; exit}')
VERSION ?= 0.1.0
BUILD ?= 1
CODESIGN_OPTS ?=

# Install over the Homebrew cask's location so a local dev build replaces the
# installed app instead of creating a second copy. A later `brew upgrade`
# cleanly overwrites the dev build with the real signed release.
INSTALL_DIR ?= /Applications

APP_BUNDLE := dist/GrokBar.app

build:
	swift build -c release

test:
	swift build --build-tests
	bundle="$$(find .build \( -name GrokBarCoreTests.xctest -o -name GrokBarPackageTests.xctest \) -type d | head -1)"; \
	test -n "$$bundle" || { echo "No XCTest bundle under .build" >&2; exit 1; }; \
	xcrun xctest "$$bundle"

bundle: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	cp .build/release/GrokBar $(APP_BUNDLE)/Contents/MacOS/
	cp Packaging/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp Packaging/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/
	cp LICENSE $(APP_BUNDLE)/Contents/Resources/
	/usr/libexec/PlistBuddy \
		-c "Set :CFBundleShortVersionString $(VERSION)" \
		-c "Set :CFBundleVersion $(BUILD)" \
		$(APP_BUNDLE)/Contents/Info.plist
	IDENT="$(CODESIGN_IDENTITY)"; [ -n "$$IDENT" ] || IDENT="-"; \
	codesign --force --sign "$$IDENT" --identifier com.gordonbeeming.GrokBar $(CODESIGN_OPTS) $(APP_BUNDLE)

install: bundle
	pkill -x GrokBar || true
	ditto $(APP_BUNDLE) $(INSTALL_DIR)/GrokBar.app
	rm -rf dist
	@echo "Launch with: open $(INSTALL_DIR)/GrokBar.app"

run:
	swift run

clean:
	rm -rf .build dist
