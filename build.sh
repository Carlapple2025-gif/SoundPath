#!/bin/bash
# 构建「声路」菜单栏 App：输出 dist/声路.app
#
# 用法：
#   bash build.sh                        # 当前架构 + ad-hoc 签名（开发用）
#   SOUNDPATH_UNIVERSAL=1 bash build.sh  # arm64 + x86_64 通用二进制
#   SOUNDPATH_SIGN_IDENTITY="Developer ID Application: 名字 (TEAMID)" bash build.sh
#
# 正式发版（签名 + 公证 + 装订）请用 release.sh。
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="声路"
EXECUTABLE="SoundPath"
APP_PATH="dist/${APP_NAME}.app"
BIN_PATH=".build/${EXECUTABLE}"

ARCHS="${SOUNDPATH_ARCHS:-$(uname -m)}"
if [[ "${SOUNDPATH_UNIVERSAL:-0}" == "1" ]]; then
    ARCHS="arm64 x86_64"
fi

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

mkdir -p .build-cache/clang-modules .build-cache/clang
SLICES=()
for ARCH in $ARCHS; do
    SLICE=".build/${EXECUTABLE}-${ARCH}"
    echo "==> 编译 ${ARCH}（${ARCH}-apple-macos14.4）"
    "$SWIFTC" -O -parse-as-library \
        -sdk "$SDK" \
        -target "${ARCH}-apple-macos14.4" \
        -module-cache-path "$PWD/.build-cache/swift-modules" \
        -Xcc -fmodules-cache-path="$PWD/.build-cache/clang-modules" \
        -o "$SLICE" \
        Sources/SoundPath/*.swift
    SLICES+=("$SLICE")
done

if [[ ${#SLICES[@]} -gt 1 ]]; then
    echo "==> 合并通用二进制"
    lipo -create "${SLICES[@]}" -output "$BIN_PATH"
else
    cp "${SLICES[0]}" "$BIN_PATH"
fi

echo "==> 组装 App Bundle"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH" "$APP_PATH/Contents/MacOS/$EXECUTABLE"
cp "Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"

SIGN_IDENTITY="${SOUNDPATH_SIGN_IDENTITY:-}"
if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> Developer ID 签名（hardened runtime + timestamp）"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" \
        "$APP_PATH/Contents/MacOS/$EXECUTABLE"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" \
        "$APP_PATH"
    codesign --verify --strict --verbose=2 "$APP_PATH"
    echo "签名身份：$SIGN_IDENTITY"
else
    echo "==> 临时签名（ad-hoc，仅本机可用）"
    codesign --force --deep --sign - "$APP_PATH" >/dev/null
fi

echo "==> 架构：$(lipo -archs "$APP_PATH/Contents/MacOS/$EXECUTABLE")"
echo
echo "构建完成：$PWD/$APP_PATH"
echo "启动：open \"$PWD/$APP_PATH\""
echo "预览（普通窗口）：\"$PWD/$APP_PATH/Contents/MacOS/$EXECUTABLE\" --preview"
