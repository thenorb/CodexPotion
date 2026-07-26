#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
APP_NAME="NotchUsage.app"
INSTALL_DIR="/Users/$USER/Applications"

"$PROJECT_DIR/build-app.sh"

mkdir -p "$INSTALL_DIR"
pkill -f "/$APP_NAME/Contents/MacOS/NotchUsage" 2>/dev/null || true
ditto "$PROJECT_DIR/dist/$APP_NAME" "$INSTALL_DIR/$APP_NAME"
open "$INSTALL_DIR/$APP_NAME"

echo "Installed to $INSTALL_DIR/$APP_NAME"
