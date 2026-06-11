#!/bin/bash
# Builds, signs, notarizes, and zips Helipad.app.
#
# Required env:
#   VERSION        e.g. 1.0.42
#   SIGN_ID        e.g. "Developer ID Application: Ron Reiter (8BKF8DY7Y4)"
#   NOTARY_KEY     path to the App Store Connect API .p8 key
#   NOTARY_KEY_ID  API key id
#   NOTARY_ISSUER  API key issuer id
set -euo pipefail

cd "$(dirname "$0")/.."
: "${VERSION:?}" "${SIGN_ID:?}" "${NOTARY_KEY:?}" "${NOTARY_KEY_ID:?}" "${NOTARY_ISSUER:?}"

echo "== build (universal) =="
swift build -c release --arch arm64 --arch x86_64
BIN=.build/apple/Products/Release/Helipad

echo "== bundle =="
rm -rf dist && mkdir -p dist/Helipad.app/Contents/MacOS dist/Helipad.app/Contents/Resources
cp "$BIN" dist/Helipad.app/Contents/MacOS/Helipad
cp packaging/AppIcon.icns dist/Helipad.app/Contents/Resources/AppIcon.icns
sed "s/VERSION_PLACEHOLDER/$VERSION/g" packaging/Info.plist > dist/Helipad.app/Contents/Info.plist
printf 'APPL????' > dist/Helipad.app/Contents/PkgInfo

echo "== sign =="
codesign --force --options runtime --timestamp --sign "$SIGN_ID" dist/Helipad.app
codesign --verify --strict dist/Helipad.app

echo "== dmg =="
rm -rf dist/dmg-root && mkdir dist/dmg-root
cp -R dist/Helipad.app dist/dmg-root/
ln -s /Applications dist/dmg-root/Applications
hdiutil create -volname "Helipad" -srcfolder dist/dmg-root -ov -format UDZO "dist/Helipad-$VERSION.dmg"
codesign --force --timestamp --sign "$SIGN_ID" "dist/Helipad-$VERSION.dmg"

echo "== notarize =="
xcrun notarytool submit "dist/Helipad-$VERSION.dmg" \
  --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
  --wait
xcrun stapler staple "dist/Helipad-$VERSION.dmg"

echo "dist/Helipad-$VERSION.dmg"
