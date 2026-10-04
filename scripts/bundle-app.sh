#!/usr/bin/env bash
# Builds Cove.app from the SwiftPM executable, signs it with the Hardened
# Runtime, and (optionally) notarizes it. macOS only.
#
# Environment:
#   VERSION              marketing version (default: 0.1.0)
#   BUILD_NUMBER         bundle version (default: git commit count)
#   CODESIGN_IDENTITY    "Developer ID Application: …" (default: ad-hoc "-")
#   SPARKLE_PUBLIC_KEY   EdDSA public key for update verification
#   NOTARY_PROFILE       keychain profile for `xcrun notarytool` (optional)
#   UNIVERSAL=1          build arm64 + x86_64
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PKG="$ROOT/Apps/CoveMac"
DIST="$ROOT/dist"
APP="$DIST/Cove.app"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
IDENTITY="${CODESIGN_IDENTITY:--}"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "==> Building Cove $VERSION ($BUILD_NUMBER)"
swift build -c release --package-path "$APP_PKG" "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release --package-path "$APP_PKG" "${ARCH_FLAGS[@]}" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Cove" "$APP/Contents/MacOS/Cove"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
    -e "s|__SPARKLE_PUBLIC_KEY__|${SPARKLE_PUBLIC_KEY:-}|" \
    "$APP_PKG/Support/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# SwiftPM resource bundles (e.g. KeyboardShortcuts localizations).
find "$BIN_DIR" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

# Embed Sparkle and point the executable at Contents/Frameworks.
if [[ -d "$BIN_DIR/Sparkle.framework" ]]; then
  cp -R "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"
fi
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Cove" 2>/dev/null || true

echo "==> Signing with identity: $IDENTITY"
SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
if [[ "$IDENTITY" == "-" ]]; then
  SIGN=(codesign --force --sign -)
fi
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  for item in \
    "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE/Versions/B/Autoupdate" \
    "$SPARKLE/Versions/B/Updater.app"; do
    [[ -e "$item" ]] && "${SIGN[@]}" --preserve-metadata=entitlements "$item"
  done
  "${SIGN[@]}" "$SPARKLE"
fi
"${SIGN[@]}" --entitlements "$APP_PKG/Support/Cove.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

ZIP="$DIST/Cove-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "${NOTARY_PROFILE:-}" && "$IDENTITY" != "-" ]]; then
  echo "==> Notarizing"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
fi

echo "==> Done: $APP"
echo "    Archive: $ZIP"
