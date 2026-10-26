#!/bin/bash
# 把「声路」安装到 ~/Applications 并启动
set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -d "dist/声路.app" ]]; then
    bash build.sh
fi

INSTALL_DIR="$HOME/Applications"
APP_PATH="$INSTALL_DIR/声路.app"

mkdir -p "$INSTALL_DIR"
rm -rf "$APP_PATH"
cp -R "dist/声路.app" "$APP_PATH"
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

open "$APP_PATH"
echo "已安装到：$APP_PATH"
