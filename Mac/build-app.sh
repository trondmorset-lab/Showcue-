#!/bin/bash
# Bygger ShowCue.app (krever Xcode eller Xcode Command Line Tools: xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

echo "Bygger ShowCue …"
if swift build -c release --arch arm64 --arch x86_64 2>/dev/null; then
    BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
    echo "Universell app (Apple Silicon + Intel)."
else
    swift build -c release
    BIN_DIR=$(swift build -c release --show-bin-path)
fi

APP=build/ShowCue.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ShowCue" "$APP/Contents/MacOS/ShowCue"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo ""
echo "Ferdig: $(pwd)/$APP"
echo "Dra den til Programmer-mappa, eller start med:  open \"$APP\""
