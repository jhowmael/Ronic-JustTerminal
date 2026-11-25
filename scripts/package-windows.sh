#!/usr/bin/env bash
# Packages Ronic JustTerminal for Windows (x64). Runs on macOS, Linux or Windows (Git Bash):
#   dist/RonicJustTerminal-Windows/        RonicJustTerminal.exe + web\ + conpty.dll + x64\, arm64\
#   dist/RonicJustTerminal-Windows.zip     ready for GitHub Releases
#
# Requires: .NET SDK 10+.   Optional variable: VERSION=0.2.0
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
OUT="$ROOT/dist/RonicJustTerminal-Windows"
ZIP="$ROOT/dist/RonicJustTerminal-Windows.zip"

echo "==> Ronic JustTerminal $VERSION (Windows x64)"
rm -rf "$OUT" "$ZIP" "$ROOT/build/windows-publish"
mkdir -p "$OUT"

echo "==> Building RonicJustTerminal.exe"
dotnet publish "$ROOT/windows/RonicJustTerminal/RonicJustTerminal.csproj" -c Release \
  -p:Version="$VERSION" -o "$ROOT/build/windows-publish" --nologo -v quiet
cp "$ROOT/build/windows-publish/RonicJustTerminal.exe" "$OUT/RonicJustTerminal.exe"
# Native libraries next to the .exe: WebView2Loader.dll, conpty.dll and OpenConsole.exe (x64\, arm64\).
find "$ROOT/build/windows-publish" -maxdepth 1 -name "*.dll" -exec cp {} "$OUT/" \;
# OpenConsole.exe (the up-to-date ConPTY host) comes from the Microsoft.Windows.Console.ConPTY NuGet package.
CSPROJ="$ROOT/windows/RonicJustTerminal/RonicJustTerminal.csproj"
CONPTY_VER="$(sed -n 's/.*Microsoft.Windows.Console.ConPTY" Version="\([^"]*\)".*/\1/p' "$CSPROJ")"
NUGET_DIR="$(dotnet nuget locals global-packages -l | sed 's/^global-packages: *//')"
CONPTY_PKG="$NUGET_DIR/microsoft.windows.console.conpty/$CONPTY_VER/build/native/runtimes"
for arch in x64 arm64; do
  if [[ ! -f "$CONPTY_PKG/$arch/OpenConsole.exe" ]]; then
    echo "ERROR: OpenConsole.exe ($arch) not found in $CONPTY_PKG" >&2; exit 1
  fi
  mkdir -p "$OUT/$arch" && cp "$CONPTY_PKG/$arch/OpenConsole.exe" "$OUT/$arch/"
done
[[ -f "$OUT/conpty.dll" ]] || { echo "ERROR: conpty.dll was not published" >&2; exit 1; }

echo "==> Copying the web UI"
cp -R "$ROOT/shared-web" "$OUT/web"

cat > "$OUT/README.txt" <<TXT
Ronic JustTerminal $VERSION for Windows 10 (1809+) and 11

1. Run RonicJustTerminal.exe (keep the "web", "x64" and "arm64" folders and the .dll files next to it).
2. If SmartScreen warns you, click "More info" > "Run anyway".

Closing the window keeps the app running in the system tray with your sessions open.
To quit: right-click the tray icon > Sair (Exit).

Shortcuts: Ctrl+Shift+T new tab, Ctrl+Shift+W close tab, Ctrl+Tab switch, Ctrl+Shift+B sidebar,
Ctrl+Shift+C / Ctrl+V copy/paste, Ctrl+, settings.

Requires the Microsoft Edge WebView2 Runtime (built into Windows 11 and up-to-date Windows 10).
More info: https://github.com/jhowmael/Ronic-JustTerminal
TXT

(cd "$ROOT/dist" && rm -f "$ZIP" && \
  if command -v zip >/dev/null; then zip -qr "$ZIP" "RonicJustTerminal-Windows"; \
  else powershell -NoProfile -Command "Compress-Archive -Path 'RonicJustTerminal-Windows' -DestinationPath 'RonicJustTerminal-Windows.zip'"; fi)

echo
echo "Done: $ZIP"
