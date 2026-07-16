#!/bin/bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
APP_NAME="BUS"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Info.plist")"
BUNDLE_ID="de.heikogrosse.batteryusagescore"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/BUS.app"
TARGET="/Applications/BUS.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

on_error() {
  local code=$?
  echo
  echo "❌ Vorgang abgebrochen (Fehlercode $code)."
  exit "$code"
}
trap on_error ERR

echo
echo "============================================================"
echo " BUS – Battery Usage Score $VERSION (Build $BUILD_NUMBER)"
echo " Kompilieren und installieren"
echo "============================================================"
echo

[[ "$(uname -s)" == "Darwin" ]] || { echo "Nur unter macOS möglich."; exit 1; }
for tool in swift xcrun clang codesign plutil ditto sips iconutil; do
  command -v "$tool" >/dev/null || { echo "Fehlt: $tool"; exit 1; }
done

xattr -dr com.apple.quarantine "$ROOT" 2>/dev/null || true
bash "$ROOT/swiftui-preflight.sh"
bash "$ROOT/privacy-audit.sh"

# Keep compiler caches inside the project. This also makes builds reliable on
# systems where the user-level SwiftPM/Clang cache is unavailable or read-only.
mkdir -p "$ROOT/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/module-cache"

export MACOSX_DEPLOYMENT_TARGET=27.0

MACOS_VERSION="$(sw_vers -productVersion)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"

version_at_least_27() {
  /usr/bin/awk -v version="$1" 'BEGIN {
    split(version, p, ".");
    exit !((p[1] + 0) >= 27)
  }'
}

if ! version_at_least_27 "$MACOS_VERSION"; then
  echo "❌ BUS $VERSION benötigt macOS 27.0 oder neuer."
  echo "   Gefunden: macOS $MACOS_VERSION"
  exit 1
fi

if ! version_at_least_27 "$SDK_VERSION"; then
  echo "❌ Zum Kompilieren wird das macOS-27-SDK benötigt."
  echo "   Gefundenes SDK: $SDK_VERSION"
  exit 1
fi

echo "macOS: $MACOS_VERSION"
echo "Swift: $(swift --version | head -n 1)"
echo "SDK:   $SDK_VERSION"
echo "Target: macOS 27.0"
echo

rm -rf "$ROOT/.build" "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
mkdir -p "$ROOT/.build/module-cache"

echo "▶ BUS kompilieren …"
swift build --configuration release --scratch-path "$ROOT/.build"
BIN_DIR="$(swift build --configuration release --scratch-path "$ROOT/.build" --show-bin-path)"

echo "▶ Read-only Hardware Helper kompilieren …"
HELPER_BUILD="$BUILD_DIR/de.heikogrosse.bus.hardware"
xcrun clang \
  -std=gnu17 \
  -O2 \
  -Wall \
  -Wextra \
  -mmacosx-version-min=27.0 \
  -framework IOKit \
  -framework CoreFoundation \
  "$ROOT/HardwareHelper/BUSHardwareHelper.c" \
  -o "$HELPER_BUILD"
chmod 755 "$HELPER_BUILD"

echo "▶ App-Icon erzeugen …"
ICONSET="$BUILD_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
  size="${spec%% *}"; name="${spec#* }"
  sips -z "$size" "$size" "$ROOT/Resources/AppIcon-1024.png" --out "$ICONSET/icon_${name}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"

echo "▶ App-Bundle erstellen …"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 755 "$BIN_DIR/BUS" "$APP/Contents/MacOS/BUS"
install -m 644 "$ROOT/Info.plist" "$APP/Contents/Info.plist"
install -m 644 "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
xattr -cr "$APP" 2>/dev/null || true
find "$APP" -name '._*' -delete 2>/dev/null || true
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "▶ Signieren …"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

echo "▶ Installieren …"
osascript -e 'tell application "BUS" to quit' >/dev/null 2>&1 || true
pkill -x BUS >/dev/null 2>&1 || true
sudo rm -rf "$TARGET"
sudo ditto --noextattr --noqtn "$APP" "$TARGET"
sudo chown -R root:wheel "$TARGET"
sudo xattr -cr "$TARGET" 2>/dev/null || true
sudo find "$TARGET" -name '._*' -delete 2>/dev/null || true
sudo xattr -dr com.apple.FinderInfo "$TARGET" 2>/dev/null || true
sudo xattr -dr com.apple.ResourceFork "$TARGET" 2>/dev/null || true
sudo xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
codesign --verify --strict --verbose=2 "$TARGET"

echo "▶ Read-only Hardware Helper installieren …"
HELPER_TARGET="/Library/PrivilegedHelperTools/de.heikogrosse.bus.hardware"
DAEMON_TARGET="/Library/LaunchDaemons/de.heikogrosse.bus.hardware.plist"

sudo launchctl bootout system/de.heikogrosse.bus.hardware \
  >/dev/null 2>&1 || true
sudo install -d -m 755 /Library/PrivilegedHelperTools
sudo install -d -m 755 "/Library/Application Support/BUS"
sudo install -m 755 "$HELPER_BUILD" "$HELPER_TARGET"
sudo install -m 644 \
  "$ROOT/HardwareHelper/de.heikogrosse.bus.hardware.plist" \
  "$DAEMON_TARGET"
sudo chown root:wheel "$HELPER_TARGET" "$DAEMON_TARGET"
sudo plutil -lint "$DAEMON_TARGET" >/dev/null
sudo launchctl bootstrap system "$DAEMON_TARGET"
sudo launchctl enable system/de.heikogrosse.bus.hardware
sleep 3

if [[ -f "/Library/Application Support/BUS/hardware.json" ]]; then
  echo "✅ Hardware Helper liefert lokale Messdaten."
else
  echo "⚠️ Hardware Helper läuft, aber dieses Mac-Modell liefert noch keine Messdatei."
fi

echo "▶ Starten …"
open -n "$TARGET"
sleep 4
pgrep -x BUS >/dev/null || { echo "BUS wurde nicht als laufender Prozess gefunden."; exit 1; }

echo
echo "✅ BUS $VERSION wurde installiert und läuft in der Menüleiste."
echo "   $TARGET"
echo
