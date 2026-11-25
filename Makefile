.PHONY: help mac-dev mac-test app universal windows web-dev icons clean

help:
	@echo "make mac-dev     - roda o app macOS via 'swift run' (desenvolvimento)"
	@echo "make mac-test    - autoteste do app macOS (shell real, barra lateral, histórico)"
	@echo "make app         - gera dist/RonicJustTerminal.app e o .zip para o GitHub Releases"
	@echo "make universal   - igual a 'make app', binário universal arm64 + x86_64 (requer Xcode completo)"
	@echo "make windows     - gera dist/RonicJustTerminal-Windows.zip (compila daqui mesmo, sem precisar de Windows)"
	@echo "make web-dev     - abre a interface no navegador em modo demonstração (sem PTY)"
	@echo "make icons       - regenera o logo e os ícones (.icns e .ico)"
	@echo "make clean       - remove artefatos de build"

mac-dev:
	swift run --package-path macos RonicJustTerminal

mac-test:
	@mkdir -p build/selftest/data
	JT_SELFTEST=$(CURDIR)/build/selftest JT_DATA_DIR=$(CURDIR)/build/selftest/data \
		swift run --package-path macos RonicJustTerminal
	@cat build/selftest/selftest-*.json

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
