#!/bin/bash
# Build a release: Developer ID signed, notarized and stapled app inside a notarized DMG.
#
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE=<notarytool keychain profile> scripts/release.sh
#
# Make the profile once with `xcrun notarytool store-credentials`. Output:
# build/NotchTV-<version>.dmg and its .sha256, ready to attach to a GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SIGN_IDENTITY:?set SIGN_IDENTITY to a Developer ID Application identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"
[ "$SIGN_IDENTITY" != "-" ] || { echo "releases need a Developer ID, not ad hoc signing" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Info.plist)"
APP=build/NotchTV.app
DMG="build/NotchTV-$VERSION.dmg"

notarize() {  # notarize <file>: submit, wait, fail loudly with Apple's log
  local out=build/notary-$(basename "$1").json
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$out"
  local status id
  status="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$out")"
  id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$out")"
  echo "notarization of $(basename "$1"): $status ($id)"
  if [ "$status" != "Accepted" ]; then
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
    exit 1
  fi
}

SIGN_IDENTITY="$SIGN_IDENTITY" scripts/build.sh --no-run

# 1. The app itself, so it opens offline on first launch wherever it gets copied.
rm -f build/NotchTV.zip
ditto -c -k --keepParent "$APP" build/NotchTV.zip
notarize build/NotchTV.zip
xcrun stapler staple "$APP"

# 2. The disk image around it.
STAGE=build/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/NotchTV.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "NotchTV" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

# Gatekeeper's verdict, as a downloader's Mac will see it.
spctl --assess --type open --context context:primary-signature -vv "$DMG"
spctl --assess --type execute -vv "$APP"
(cd build && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
echo "release ready: $DMG"
