#!/bin/bash
# 构建「声路」菜单栏 App：输出 dist/声路.app
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="声路"
EXECUTABLE="SoundPath"
APP_PATH="dist/${APP_NAME}.app"
BIN_PATH=".build/${EXECUTABLE}"

mkdir -p .build .build-cache/tmp
export TMPDIR="$PWD/.build-cache/tmp"

# 优先使用 Command Line Tools：即使本机装了 Xcode 但许可证未接受，
# 也不会中断构建。
CLT="/Library/Developer/CommandLineTools"
if [[ -x "$CLT/usr/bin/swiftc" && -d "$CLT/SDKs/MacOSX.sdk" ]]; then
    SWIFTC="$CLT/usr/bin/swiftc"
    SDK="$CLT/SDKs/MacOSX.sdk"
    export DEVELOPER_DIR="$CLT"
else
    SWIFTC="$(xcrun --find swiftc)"
    SDK="$(xcrun --show-sdk-path)"
fi

TARGET="$(uname -m)-apple-macos14.4"

echo "==> 编译（${TARGET}）"
mkdir -p .build-cache/clang-modules .build-cache/clang
"$SWIFTC" -O -parse-as-library \
    -sdk "$SDK" \
    -target "$TARGET" \
    -module-cache-path "$PWD/.build-cache/swift-modules" \
    -Xcc -fmodules-cache-path="$PWD/.build-cache/clang-modules" \
    -o "$BIN_PATH" \
    Sources/SoundPath/*.swift

echo "==> 组装 App Bundle"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH" "$APP_PATH/Contents/MacOS/$EXECUTABLE"
cp "Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"

echo "==> 临时签名（ad-hoc）"
codesign --force --deep --sign - "$APP_PATH" >/dev/null

echo
echo "构建完成：$PWD/$APP_PATH"
echo "启动：open \"$PWD/$APP_PATH\""
echo "预览（普通窗口）：\"$PWD/$APP_PATH/Contents/MacOS/$EXECUTABLE\" --preview"
