#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
cd "$PROJECT_DIR"

swift build -c release

APP_DIR="$PROJECT_DIR/dist/CodexPotion.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

mkdir -p "$MACOS_DIR"
cp "$PROJECT_DIR/.build/release/CodexPotion" "$MACOS_DIR/CodexPotion"
cp "$PROJECT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
