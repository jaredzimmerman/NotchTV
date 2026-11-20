#!/bin/bash
# Build NotchTV.app (with its own Python), sign it, install it in Applications and launch it.
#   scripts/build.sh            build + install + launch
#   scripts/build.sh --no-run   build only (build/NotchTV.app)
#
# SIGN_IDENTITY picks the certificate: "-" (the default) signs ad hoc, which is enough to
# run it on the Mac that built it. Releases use a Developer ID (see scripts/release.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/NotchTV.app
IDENTITY="${SIGN_IDENTITY:--}"
if [ -w /Applications ]; then DEST=/Applications; else DEST="$HOME/Applications"; mkdir -p "$DEST"; fi

if [ ! -f App/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o App/AppIcon.icns
fi

scripts/bundle-python.sh

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -framework AppKit -framework Network -framework ServiceManagement \
  -o "$APP/Contents/MacOS/NotchTV" App/*.swift
cp App/Info.plist "$APP/Contents/Info.plist"
cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp helper/notchtv_helper.py "$APP/Contents/Resources/notchtv_helper.py"
cp build/ThirdPartyLicenses.txt "$APP/Contents/Resources/ThirdPartyLicenses.txt"
rsync -a build/python "$APP/Contents/Resources/"

# Sign inside out: every Mach-O in the bundled Python first, then the app around them.
# Hardened runtime only for real identities: its library validation requires the bundled
# python and its libraries to share a Team ID, which ad hoc signatures don't have.
SIGN=(codesign --force --sign "$IDENTITY")
[ "$IDENTITY" != "-" ] && SIGN+=(--options runtime --timestamp)
find "$APP/Contents/Resources/python" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0 |
  while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q 'Mach-O'; then "${SIGN[@]}" "$f" 2>/dev/null; fi
  done
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "built $APP ($(du -sh "$APP" | cut -f1), signed: $IDENTITY)"

[ "${1:-}" = "--no-run" ] && exit 0

pkill -x NotchTV 2>/dev/null && sleep 0.5 || true
rm -rf "$DEST/NotchTV.app"
ditto "$APP" "$DEST/NotchTV.app"
open "$DEST/NotchTV.app"
echo "installed and launched $DEST/NotchTV.app"
