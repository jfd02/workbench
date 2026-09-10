#!/bin/bash
# Rebuild GhosttyKit.xcframework (libghostty) and refresh the bundled Ghostty
# resources from a Ghostty source checkout.
#
# Requires: zig (version must match ghostty's build.zig.zon minimum_zig_version)
#           and xcodebuild, which assembles the xcframework.
#
# Usage: scripts/build-ghostty.sh [/path/to/ghostty/checkout]
#        With no argument, a shallow clone is made into build/ghostty-src.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$ROOT/build/ghostty-src}"

if [ ! -d "$SRC" ]; then
    echo "==> Cloning ghostty into $SRC"
    mkdir -p "$(dirname "$SRC")"
    git clone --depth 1 https://github.com/ghostty-org/ghostty.git "$SRC"
fi

echo "==> Building libghostty (this takes a while)"
cd "$SRC"
zig build \
    -Doptimize=ReleaseFast \
    -Demit-xcframework=true \
    -Dxcframework-target=native \
    -Dapp-runtime=none

if [ ! -d "$SRC/macos/GhosttyKit.xcframework" ]; then
    echo "error: GhosttyKit.xcframework was not produced" >&2
    exit 1
fi

echo "==> Installing into $ROOT/Frameworks and $ROOT/Resources"
rm -rf "$ROOT/Frameworks/GhosttyKit.xcframework"
cp -R "$SRC/macos/GhosttyKit.xcframework" "$ROOT/Frameworks/"

rm -rf "$ROOT/Resources/terminfo" "$ROOT/Resources/ghostty"
cp -R "$SRC/zig-out/share/terminfo" "$ROOT/Resources/terminfo"
cp -R "$SRC/zig-out/share/ghostty" "$ROOT/Resources/ghostty"

cp "$SRC/LICENSE" "$ROOT/Frameworks/GHOSTTY-LICENSE"

echo "==> Done. Now run scripts/bundle.sh"
