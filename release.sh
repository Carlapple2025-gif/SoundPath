#!/bin/bash
# 正式发版：通用二进制 + Developer ID 签名 + 公证 + 装订（+ 可选上传）
#
# 用法：
#   SOUNDPATH_NOTARY_PROFILE=soundpath-notary bash release.sh
#   APPLE_ID=... APPLE_TEAM_ID=... APPLE_APP_PASSWORD=... bash release.sh
#   bash release.sh --upload        # 最后把 zip 传到已有的 GitHub Release
#
# 前置条件见 docs/RELEASING.md（Apple Developer Program、证书、公证凭据）。
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="声路"
APP_PATH="dist/${APP_NAME}.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
# Info.plist 里可能写 1.0，而 tag/附件统一用三段式 1.0.0。
IFS=. read -r VERSION_MAJOR VERSION_MINOR VERSION_PATCH <<<"$VERSION"
SEMVER="${VERSION_MAJOR}.${VERSION_MINOR:-0}.${VERSION_PATCH:-0}"
TAG="v${SEMVER}"
ARCHIVE="dist/SoundPath-${SEMVER}-universal.zip"

UPLOAD=0
if [[ "${1:-}" == "--upload" ]]; then
    UPLOAD=1
fi

# --- 签名身份 ---------------------------------------------------------------
IDENTITY="${SOUNDPATH_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi
if [[ -z "$IDENTITY" ]]; then
    cat <<'MSG'
找不到 Developer ID Application 证书。

先报名 Apple Developer Program 并安装证书（见 docs/RELEASING.md），
或显式指定身份：
  SOUNDPATH_SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" bash release.sh
MSG
    exit 1
fi

# --- 代码状态检查 -----------------------------------------------------------
if ! git diff --quiet HEAD -- .; then
    echo "工作区有未提交的改动；发版必须基于提交，请先提交。"
    exit 1
fi
if ! git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    echo "本地没有 tag ${TAG}；先改好版本号并打 tag 再发版（见 docs/RELEASING.md）。"
    exit 1
fi
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse "${TAG}^{commit}")" ]]; then
    echo "HEAD 与 ${TAG} 不一致，发版包必须对应 tag 提交。"
    echo "  HEAD=$(git rev-parse --short HEAD)  ${TAG}=$(git rev-parse --short "${TAG}^{commit}")"
    exit 1
fi

# --- 公证凭据 ---------------------------------------------------------------
NOTARY_ARGS=()
if [[ -n "${SOUNDPATH_NOTARY_PROFILE:-}" ]]; then
    NOTARY_ARGS=(--keychain-profile "$SOUNDPATH_NOTARY_PROFILE")
else
    : "${APPLE_ID:?需要 APPLE_ID，或设置 SOUNDPATH_NOTARY_PROFILE（推荐）}"
    : "${APPLE_TEAM_ID:?需要 APPLE_TEAM_ID}"
    : "${APPLE_APP_PASSWORD:?需要 APPLE_APP_PASSWORD（App 专用密码）}"
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
fi

echo "==> 发版：${APP_NAME} ${VERSION}（build ${BUILD_NUMBER}），tag ${TAG}"
echo "==> 签名身份：${IDENTITY}"

# --- 构建并签名 -------------------------------------------------------------
SOUNDPATH_UNIVERSAL=1 SOUNDPATH_SIGN_IDENTITY="$IDENTITY" bash build.sh

codesign --verify --strict --verbose=2 "$APP_PATH"

# --- 压缩（公证用） ---------------------------------------------------------
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE"

# --- 公证 -------------------------------------------------------------------
echo "==> 提交公证（可能需要几分钟）"
SUBMIT_JSON="$(xcrun notarytool submit "$ARCHIVE" "${NOTARY_ARGS[@]}" --wait --output-format json)"
printf '%s\n' "$SUBMIT_JSON"

read -r STATUS SUBMISSION_ID <<<"$(printf '%s' "$SUBMIT_JSON" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data.get("status", ""), data.get("id", ""))
')"
if [[ "$STATUS" != "Accepted" ]]; then
    echo "公证未通过：${STATUS:-未知状态}"
    if [[ -n "${SUBMISSION_ID:-}" ]]; then
        echo "--- 公证日志 ---"
        xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_ARGS[@]}" || true
    fi
    exit 1
fi

# --- 装订票据并重新打包 -----------------------------------------------------
echo "==> 装订公证票据"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE"

# --- 本机 Gatekeeper 验收 ---------------------------------------------------
echo "==> Gatekeeper 验收"
if ! spctl -a -vvv -t exec "$APP_PATH"; then
    echo "Gatekeeper 校验失败：签名或公证链有问题"
    exit 1
fi

echo
echo "完成：$PWD/$ARCHIVE"
echo "架构：$(lipo -archs "$APP_PATH/Contents/MacOS/SoundPath")"
echo "SHA256：$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"

# --- 可选：上传到 GitHub Release -------------------------------------------
if [[ $UPLOAD -eq 1 ]]; then
    echo "==> 上传到 GitHub Release ${TAG}"
    if ! gh release view "$TAG" >/dev/null 2>&1; then
        echo "Release ${TAG} 不存在，先创建："
        echo "  gh release create ${TAG} --title \"声路 ${VERSION}\" --notes \"...\""
        exit 1
    fi
    gh release upload "$TAG" "$ARCHIVE" --clobber
    echo "已上传：$(gh release view "$TAG" --json url --jq .url)"
fi
