#!/usr/bin/env bash
# 用免费 Apple ID（个人开发团队）直接出签名 IPA。需要 macOS + Xcode。
# 免费证书规则：有效期 7 天、最多 3 个 App、设备 UDID 必须已注册。
# 用法: TEAM_ID=ABCDE12345 bash scripts/sign_ipa_macos.sh
set -euo pipefail

cd "$(dirname "$0")/.."

: "${TEAM_ID:?请给 TEAM_ID，例如 TEAM_ID=ABCDE12345 bash scripts/sign_ipa_macos.sh}"
BUNDLE_ID="${BUNDLE_ID:-com.coco.video}"
VERSION="${VERSION:-1.6.0}"
APP_NAME="CocoVideo"

echo ">> Xcode 里的团队：$TEAM_ID"
echo "   (Xcode -> Settings -> Accounts 添加 Apple ID 后，Team ID 就在团队名后面)"

rm -rf build/signed.xcarchive build/export
mkdir -p build

xcodebuild \
  -project CocoVideo.xcodeproj \
  -scheme "$APP_NAME" \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath build/signed.xcarchive \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGN_STYLE=Automatic \
  archive

cp scripts/export_options.plist build/export_options.plist
/usr/libexec/PlistBuddy -c "Set :teamID $TEAM_ID" build/export_options.plist

xcodebuild -exportArchive \
  -archivePath build/signed.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist build/export_options.plist \
  -allowProvisioningUpdates

SRC=$(ls build/export/*.ipa | head -n 1)
cp "$SRC" "build/COCO影视_v${VERSION}_ios_signed.ipa"
echo ""
echo "OK -> build/COCO影视_v${VERSION}_ios_signed.ipa"
codesign -dv --verbose=2 build/signed.xcarchive/Products/Applications/$APP_NAME.app 2>&1 | head -n 12 || true
