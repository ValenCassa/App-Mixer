#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
CONFIGURATION="${1:-release}"
APP_DIR="$PROJECT_DIR/dist/App Mixer.app"
CONTENTS_DIR="$APP_DIR/Contents"

cd "$PROJECT_DIR"
swift build -c "$CONFIGURATION"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BIN_DIR/AppMixer" "$CONTENTS_DIR/MacOS/AppMixer"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
# Give local ad-hoc builds a stable designated requirement. Without this,
# codesign falls back to a requirement based on the executable's changing
# cdhash and macOS forgets System Audio Recording approval after every rebuild.
codesign \
    --force \
    --deep \
    --sign - \
    --identifier "com.valentincassarino.AppMixer" \
    --requirements '=designated => identifier "com.valentincassarino.AppMixer"' \
    "$APP_DIR"

echo "$APP_DIR"
