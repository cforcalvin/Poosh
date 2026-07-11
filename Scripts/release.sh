#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEME="Poosh"
CONFIGURATION="Release"
TEAM_ID="GSLU4J8LYR"
SIGN_IDENTITY="Developer ID Application: Calvin Chan (GSLU4J8LYR)"
NOTARY_PROFILE="${NOTARY_PROFILE:-Poosh-Notary}"

DIST="$ROOT/dist"
ARCHIVE_PATH="$DIST/Poosh.xcarchive"
EXPORT_PATH="$DIST/export"
APP_PATH="$EXPORT_PATH/Poosh.app"
ZIP_PATH="$DIST/Poosh.zip"
DERIVED="$DIST/DerivedData"

echo "==> Cleaning dist/"
rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> Archiving (Developer ID)"
xcodebuild archive \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp"

mkdir -p "$EXPORT_PATH"
rm -rf "$APP_PATH"
cp -R "$ARCHIVE_PATH/Products/Applications/Poosh.app" "$APP_PATH"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Zipping for notarization"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting to Apple notary service (profile: $NOTARY_PROFILE)"
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> Stapling ticket"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "==> Re-zipping stapled app"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo ""
echo "Done."
echo "  App: $APP_PATH"
echo "  Zip: $ZIP_PATH"
codesign -dv --verbose=4 "$APP_PATH" 2>&1 | head -20
