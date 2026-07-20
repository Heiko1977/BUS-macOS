#!/bin/bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP_NAME="BUS"
BUNDLE_ID="de.heikogrosse.batteryusagescore"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Info.plist")"
DIST_DIR="$ROOT/dist"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/BUS-release.XXXXXX")"
PAYLOAD="$WORK_DIR/payload"
APP="$PAYLOAD/Applications/BUS.app"
PKG="$WORK_DIR/BUS-${VERSION}.pkg"
DMG="$DIST_DIR/BUS-${VERSION}.dmg"

# For a public release, set these to the exact names shown by `security
# find-identity -v -p codesigning` and `security find-identity -v -p basic`.
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:--}"
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-}"
# Optional: name of a profile created with `xcrun notarytool store-credentials`.
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

cleanup() {
  if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" ]]; then
    rm -rf "$WORK_DIR"
  fi
  return 0
}
trap cleanup EXIT
trap 'code=$?; echo "❌ Release-Build abgebrochen (Fehlercode $code)."; exit "$code"' ERR

for tool in swift xcrun clang codesign plutil ditto sips iconutil pkgbuild hdiutil; do
  command -v "$tool" >/dev/null || { echo "❌ Werkzeug fehlt: $tool"; exit 1; }
done

echo "▶ Vorabprüfungen"
bash "$ROOT/swiftui-preflight.sh"
bash "$ROOT/privacy-audit.sh"

mkdir -p "$PAYLOAD/Applications" \
  "$PAYLOAD/Library/PrivilegedHelperTools" \
  "$PAYLOAD/Library/LaunchDaemons" \
  "$WORK_DIR/scripts" "$DIST_DIR" "$ROOT/.build/module-cache"

export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/module-cache"
export MACOSX_DEPLOYMENT_TARGET=27.0
export COPYFILE_DISABLE=1
export COPY_EXTENDED_ATTRIBUTES_DISABLE=1

echo "▶ Release-Binary kompilieren"
swift build --configuration release --scratch-path "$ROOT/.build"
BIN_DIR="$(swift build --configuration release --scratch-path "$ROOT/.build" --show-bin-path)"

echo "▶ Hardware Helper kompilieren"
xcrun clang -std=gnu17 -O2 -Wall -Wextra \
  -mmacosx-version-min=27.0 \
  -framework IOKit -framework CoreFoundation \
  "$ROOT/HardwareHelper/BUSHardwareHelper.c" \
  -o "$PAYLOAD/Library/PrivilegedHelperTools/de.heikogrosse.bus.hardware"
chmod 755 "$PAYLOAD/Library/PrivilegedHelperTools/de.heikogrosse.bus.hardware"
install -m 644 "$ROOT/HardwareHelper/de.heikogrosse.bus.hardware.plist" \
  "$PAYLOAD/Library/LaunchDaemons/de.heikogrosse.bus.hardware.plist"

echo "▶ App-Bundle erstellen"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 755 "$BIN_DIR/BUS" "$APP/Contents/MacOS/BUS"
install -m 644 "$ROOT/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

ICONSET="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in \
  "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
  "128 128x128" "256 128x128@2x" "256 256x256" \
  "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
  size="${spec%% *}"
  name="${spec#* }"
  sips -z "$size" "$size" "$ROOT/Resources/AppIcon-1024.png" \
    --out "$ICONSET/icon_${name}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

find "$PAYLOAD" -name '._*' -delete 2>/dev/null || true
xattr -cr "$PAYLOAD" 2>/dev/null || true
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "▶ App signieren"
codesign --force --sign "$APP_SIGN_IDENTITY" \
  $([[ "$APP_SIGN_IDENTITY" == "-" ]] || printf '%s' '--options runtime --timestamp') \
  --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
xattr -cr "$PAYLOAD" 2>/dev/null || true
find "$PAYLOAD" -name '._*' -delete 2>/dev/null || true

cat > "$WORK_DIR/scripts/postinstall" <<'POSTINSTALL'
#!/bin/bash
set -u
HELPER_ID="de.heikogrosse.bus.hardware"
PLIST="/Library/LaunchDaemons/${HELPER_ID}.plist"
install -d -m 755 "/Library/Application Support/BUS"
chown root:wheel \
  "/Library/PrivilegedHelperTools/${HELPER_ID}" \
  "$PLIST"
launchctl bootout "system/${HELPER_ID}" >/dev/null 2>&1 || true
launchctl bootstrap system "$PLIST"
launchctl enable "system/${HELPER_ID}"
exit 0
POSTINSTALL
chmod 755 "$WORK_DIR/scripts/postinstall"

echo "▶ Installationspaket erstellen"
PKG_ARGS=(
  --root "$PAYLOAD"
  --scripts "$WORK_DIR/scripts"
  --identifier "${BUNDLE_ID}.installer"
  --version "$VERSION"
  --install-location /
  --ownership recommended
)
[[ -z "$INSTALLER_SIGN_IDENTITY" ]] || PKG_ARGS+=(--sign "$INSTALLER_SIGN_IDENTITY")
pkgbuild "${PKG_ARGS[@]}" "$PKG"
pkgutil --check-signature "$PKG" || true

echo "▶ DMG erstellen"
DMG_ROOT="$WORK_DIR/dmg"
mkdir -p "$DMG_ROOT"
ditto "$PKG" "$DMG_ROOT/BUS ${VERSION} installieren.pkg"
cat > "$DMG_ROOT/Installation.txt" <<EOF
BUS – Battery Usage Score ${VERSION} (Build ${BUILD_NUMBER})

Öffnen Sie „BUS ${VERSION} installieren.pkg“ und folgen Sie dem Installer.
Die App wird nach /Applications installiert. Der lokale, rein lesende
Hardware Helper wird als LaunchDaemon eingerichtet.

Systemvoraussetzung: macOS 27.0 oder neuer.
EOF
rm -f "$DMG"
hdiutil create -volname "BUS ${VERSION}" -srcfolder "$DMG_ROOT" \
  -format UDZO -imagekey zlib-level=9 "$DMG"

if [[ -n "$NOTARY_PROFILE" ]]; then
  echo "▶ DMG notarifizieren"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

shasum -a 256 "$DMG" > "$DMG.sha256"
echo
echo "✅ Fertig: $DMG"
echo "   SHA-256: $(awk '{print $1}' "$DMG.sha256")"
if [[ "$APP_SIGN_IDENTITY" == "-" || -z "$INSTALLER_SIGN_IDENTITY" || -z "$NOTARY_PROFILE" ]]; then
  echo "⚠️  Dieser Build ist für lokale Tests geeignet, aber noch nicht vollständig"
  echo "   Developer-ID-signiert und notarifiziert."
fi
