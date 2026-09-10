#!/bin/bash
# Build TabTerm and zip it for copying to another Mac.
#
# Usage: scripts/package.sh
# Produces: build/TabTerm-<version>.zip
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/bundle.sh" release

APP="$ROOT/build/TabTerm.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"
STAMP="$(date +%Y%m%d-%H%M)"
ZIP="$ROOT/build/TabTerm-$VERSION-$STAMP.zip"

echo "==> Verifying the bundle"
# Everything it links must be a system library; anything else wouldn't exist on
# the other machine.
if otool -L "$APP/Contents/MacOS/TabTerm" | tail -n +2 \
    | grep -vE '/usr/lib/|/System/' | grep -q .; then
    echo "error: bundle links something outside the system:" >&2
    otool -L "$APP/Contents/MacOS/TabTerm" | tail -n +2 \
        | grep -vE '/usr/lib/|/System/' >&2
    exit 1
fi

ARCHS="$(lipo -archs "$APP/Contents/MacOS/TabTerm")"
echo "    architectures: $ARCHS"
if [ "$ARCHS" = "arm64" ]; then
    echo "    note: Apple Silicon only — this will not run on an Intel Mac."
fi

codesign --verify --deep --strict "$APP" && echo "    signature ok (ad-hoc)"

echo "==> Zipping"
rm -f "$ZIP"
# ditto, not zip: it preserves the bundle's symlinks and extended attributes.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo
echo "==> $ZIP"
echo "    $(du -h "$ZIP" | cut -f1)"
echo
echo "On the other Mac:"
echo "  1. Unzip and drag TabTerm.app to /Applications"
echo "  2. First launch only: right-click the app and choose Open, then Open"
echo "     again at the prompt. macOS blocks double-clicking it because it is"
echo "     signed ad-hoc rather than with a Developer ID."
echo "     Or from a terminal: xattr -dr com.apple.quarantine /Applications/TabTerm.app"
echo
echo "Your data lives in ~/Library/Application Support/TabTerm/tabterm.sqlite,"
echo "outside the app, so replacing TabTerm.app keeps repositories, pins and tabs."
