#!/usr/bin/env bash
# 生成未签名 IPA。macOS 上跑，或者交给 GitHub Actions 的 macos runner。
# 用法: bash scripts/build_ipa.sh [版本号]
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-1.7.0}"
APP_NAME="CocoVideo"
OUT_DIR="build"
IPA_NAME="开心视频_v${VERSION}_ios.ipa"

if command -v xcodegen >/dev/null 2>&1; then
  echo ">> xcodegen: 用 project.yml 重建工程"
  xcodegen generate
elif [ ! -d "CocoVideo.xcodeproj" ]; then
  echo "!! 既没有 xcodegen 也没有 CocoVideo.xcodeproj"; exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo ">> archive (未签名)"
xcodebuild \
  -project CocoVideo.xcodeproj \
  -scheme "$APP_NAME" \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath "$OUT_DIR/$APP_NAME.xcarchive" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  archive

APP_PATH="$OUT_DIR/$APP_NAME.xcarchive/Products/Applications/$APP_NAME.app"
[ -d "$APP_PATH" ] || { echo "!! 没找到 $APP_PATH"; exit 1; }

echo ">> 打包 Payload"
mkdir -p "$OUT_DIR/Payload"
cp -R "$APP_PATH" "$OUT_DIR/Payload/"
rm -rf "$OUT_DIR/Payload/$APP_NAME.app/_CodeSignature"

cd "$OUT_DIR"
zip -qry "$IPA_NAME" Payload
cd ..

echo ""
echo "OK -> $(pwd)/$OUT_DIR/$IPA_NAME"
ls -lh "$OUT_DIR/$IPA_NAME"
