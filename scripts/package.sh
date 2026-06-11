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

echo "== notarize =="
ditto -c -k --keepParent dist/Helipad.app dist/Helipad-notarize.zip
xcrun notarytool submit dist/Helipad-notarize.zip \
  --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
  --wait
xcrun stapler staple dist/Helipad.app

echo "== package =="
ditto -c -k --keepParent dist/Helipad.app "dist/Helipad-$VERSION.zip"
echo "dist/Helipad-$VERSION.zip"
