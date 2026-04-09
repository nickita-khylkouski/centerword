#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CenterWord"
PLIST_PATH="$ROOT_DIR/AppBundle/Info.plist"
BUILD_CONFIGURATION="release"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_PATH")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST_PATH")"
ARCH_SUFFIX="macos-arm64"
DIST_DIR="$ROOT_DIR/dist/$VERSION"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
FINAL_ZIP_PATH="$DIST_DIR/${APP_NAME}-${VERSION}-${ARCH_SUFFIX}.zip"
TEMP_ZIP_PATH="$DIST_DIR/${APP_NAME}-${VERSION}-${ARCH_SUFFIX}-notary.zip"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}-${ARCH_SUFFIX}.dmg"
CHECKSUM_PATH="$DIST_DIR/sha256.txt"
NOTARIZE=1

resolve_signing_identity() {
  if [[ -n "${CENTERWORD_SIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "$CENTERWORD_SIGN_IDENTITY"
    return 0
  fi

  security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Developer ID Application:/ { print $2; exit }'
}

for arg in "$@"; do
  case "$arg" in
    --skip-notarize)
      NOTARIZE=0
      ;;
    *)
      echo "Usage: ./scripts/package-release.sh [--skip-notarize]" >&2
      exit 1
      ;;
  esac
done

SIGNING_IDENTITY="$(resolve_signing_identity || true)"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "No Developer ID Application signing identity found." >&2
  exit 1
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cd "$ROOT_DIR"
swift build -c "$BUILD_CONFIGURATION" --product "$APP_NAME"

EXECUTABLE_PATH="$ROOT_DIR/.build/arm64-apple-macosx/${BUILD_CONFIGURATION}/${APP_NAME}"
cp "$EXECUTABLE_PATH" "$APP_DIR/Contents/MacOS/${APP_NAME}"
chmod +x "$APP_DIR/Contents/MacOS/${APP_NAME}"
cp "$ROOT_DIR/AppBundle/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -f "$ROOT_DIR/AppBundle/CenterWord.icns" ]]; then
  cp "$ROOT_DIR/AppBundle/CenterWord.icns" "$APP_DIR/Contents/Resources/CenterWord.icns"
fi

codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

if [[ "$NOTARIZE" -eq 1 ]]; then
  ditto -c -k --keepParent "$APP_DIR" "$TEMP_ZIP_PATH"
  asc notarization submit --file "$TEMP_ZIP_PATH" --wait --output json > "$DIST_DIR/notarization-zip.json"
  xcrun stapler staple "$APP_DIR"
fi

ditto -c -k --keepParent "$APP_DIR" "$FINAL_ZIP_PATH"

DMG_ROOT="$DIST_DIR/dmg-root"
rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
cp -R "$APP_DIR" "$DMG_ROOT/${APP_NAME}.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG_PATH" >/dev/null

if [[ "$NOTARIZE" -eq 1 ]]; then
  asc notarization submit --file "$DMG_PATH" --wait --output json > "$DIST_DIR/notarization-dmg.json"
  xcrun stapler staple "$DMG_PATH"
fi

shasum -a 256 "$FINAL_ZIP_PATH" "$DMG_PATH" > "$CHECKSUM_PATH"
rm -rf "$DMG_ROOT" "$TEMP_ZIP_PATH"

cat <<EOF
Packaged ${APP_NAME} ${VERSION} (${BUILD_NUMBER})

Artifacts:
- ${FINAL_ZIP_PATH}
- ${DMG_PATH}
- ${CHECKSUM_PATH}

Signing identity:
- ${SIGNING_IDENTITY}

Notarization:
- $( [[ "$NOTARIZE" -eq 1 ]] && echo "completed" || echo "skipped" )
EOF
