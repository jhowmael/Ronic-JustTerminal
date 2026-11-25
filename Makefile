.PHONY: help mac-dev mac-test screenshots app universal windows web-dev icons clean

help:
	@echo "make mac-dev     - run the macOS app with 'swift run' (development)"
	@echo "make mac-test    - macOS app self-test (real shell, sidebar, history)"
	@echo "make screenshots - take the README screenshots (real app, sample session) → docs/screenshot-*.png"
	@echo "make app         - build dist/RonicJustTerminal.app and the .zip for GitHub Releases"
	@echo "make universal   - same as 'make app', universal arm64 + x86_64 binary (requires full Xcode)"
	@echo "make windows     - build dist/RonicJustTerminal-Windows.zip (cross-compiles, no Windows needed)"
	@echo "make web-dev     - open the UI in the browser in demo mode (no PTY)"
	@echo "make icons       - regenerate the logo and icons (.icns and .ico)"
	@echo "make clean       - remove build artifacts"

mac-dev:
	swift run --package-path macos RonicJustTerminal

mac-test:
	@mkdir -p build/selftest/data
	JT_SELFTEST=$(CURDIR)/build/selftest JT_DATA_DIR=$(CURDIR)/build/selftest/data \
		swift run --package-path macos RonicJustTerminal
	@cat build/selftest/selftest-*.json

screenshots:
	@mkdir -p build/shots/data/RonicJustTerminal
	@echo '{"defaultProfile":"login","fontSize":13}' > build/shots/data/RonicJustTerminal/settings.json
	JT_SHOTS=$(CURDIR)/build/shots JT_DATA_DIR=$(CURDIR)/build/shots/data JT_DEMO_HOME=$(CURDIR) JT_RENDERER=dom \
		swift run --package-path macos RonicJustTerminal
	for s in main settings minimal; do \
		swift scripts/frame-screenshot.swift build/shots/shot-$$s.png docs/screenshot-$$s.png; done

app:
	./scripts/package-macos.sh

universal:
	UNIVERSAL=1 ./scripts/package-macos.sh

windows:
	./scripts/package-windows.sh

web-dev:
	open shared-web/index.html

icons:
	./branding/make-icons.sh

clean:
	rm -rf build dist macos/.build windows/RonicJustTerminal/bin windows/RonicJustTerminal/obj
