#!/bin/bash
# Build Workbench and assemble it into a runnable .app bundle.
#
# Usage: scripts/bundle.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/Workbench.app"
CONTENTS="$APP/Contents"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Workbench"

if [ ! -x "$BIN" ]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN" "$CONTENTS/MacOS/Workbench"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

# libghostty locates its resources by walking up from the executable looking
# for Contents/Resources/terminfo/78/xterm-ghostty, then uses
# Contents/Resources/ghostty for shell integration and themes.
cp -R "$ROOT/Resources/terminfo" "$CONTENTS/Resources/terminfo"
cp -R "$ROOT/Resources/ghostty" "$CONTENTS/Resources/ghostty"

# Optional: images looked up by name, such as a claude.png to replace the
# stand-in Claude mark on terminal tabs.
if [ -d "$ROOT/Resources/Icons" ]; then
    cp -R "$ROOT/Resources/Icons/." "$CONTENTS/Resources/"
fi

if [ ! -f "$CONTENTS/Resources/terminfo/78/xterm-ghostty" ]; then
    echo "error: terminfo sentinel missing; libghostty won't find its resources" >&2
    exit 1
fi

echo "==> Signing (ad-hoc)"
codesign --force --sign - \
    --entitlements "$ROOT/Resources/TabTerm.entitlements" \
    --timestamp=none \
    "$APP" 2>&1 | sed 's/^/    /'

echo "==> Done: $APP"
echo "    Run with: open $APP"
