#!/usr/bin/env bash
# Packages Ronic JustTerminal for macOS:
#   dist/RonicJustTerminal.app
#   dist/RonicJustTerminal-macOS.zip   (ready to attach to GitHub Releases)
#
# Optional variables:
#   VERSION=0.2.0            version written to Info.plist
#   UNIVERSAL=1              universal binary (arm64 + x86_64) — requires full Xcode
#   SIGN_IDENTITY="Developer ID Application: Jane Doe (TEAMID)"   real signing
#
# Default signing:
#   - on your machine: a stable local certificate (scripts/dev-signing.sh), so folder
#     permissions (Documents, Desktop…) keep working after rebuilds;
#   - on CI (CI variable set): ad-hoc ("-").
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  if [[ -n "${CI:-}" ]]; then
    SIGN_IDENTITY="-"
  else
    SIGN_IDENTITY="$("$ROOT/scripts/dev-signing.sh" 2>/dev/null || true)"
    [[ -n "$SIGN_IDENTITY" ]] || SIGN_IDENTITY="-"
  fi
fi
DIST="$ROOT/dist"
APP="$DIST/RonicJustTerminal.app"

echo "==> Ronic JustTerminal $VERSION (macOS)"
rm -rf "$APP"
mkdir -p "$DIST"

# 1) App Swift
echo "==> Building the Swift app"
SWIFT_ARGS=(-c release --package-path "$ROOT/macos")
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  SWIFT_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build "${SWIFT_ARGS[@]}"
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"

# 2) Assemble the .app bundle
echo "==> Assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/RonicJustTerminal" "$APP/Contents/MacOS/RonicJustTerminal"
cp "$ROOT/macos/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/macos/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$ROOT/shared-web" "$APP/Contents/Resources/web"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"

# 3) Signing (ad-hoc by default)
echo "==> Signing ($SIGN_IDENTITY)"
SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" == Developer\ ID* ]]; then
  SIGN_FLAGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"

# 4) Zip for GitHub Releases (ditto keeps the signature and attributes)
ZIP="$DIST/RonicJustTerminal-macOS.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "Done:"
echo "  App: $APP"
echo "  Zip: $ZIP"
echo "Open with: open \"$APP\""
