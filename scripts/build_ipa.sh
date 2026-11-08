#!/usr/bin/env bash
# 生成未签名 IPA。一个变体绑一个站，BundleID 不同 → 可同时装多个 App。
# 用法:
#   bash scripts/build_ipa.sh [版本] [站点] [显示名] [BundleID] [输出文件名]
# 例:
#   bash scripts/build_ipa.sh 1.7.0 https://dutv.eu.org  开心视频 com.coco.video   kaixin_v1.7.0_ios.ipa
#   bash scripts/build_ipa.sh 1.7.0 https://191314.best  Coco    com.coco.video2  coco_v1.7.0_ios.ipa
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-1.7.0}"
SITE="${2:-https://dutv.eu.org}"
DISPLAY="${3:-开心视频}"
BUNDLE="${4:-com.coco.video}"
OUT_NAME="${5:-${DISPLAY}_v${VERSION}_ios.ipa}"

APP_NAME="CocoVideo"
OUT_DIR="build"
PB=/usr/libexec/PlistBuddy

echo ">> 变体: $DISPLAY ($BUNDLE) -> $SITE"

# 站点 / 显示名写进 Info.plist（直接参与打包，不需要额外配置）
$PB -c "Set :CocoSite $SITE" CocoVideo/Info.plist 2>/dev/null \
  || $PB -c "Add :CocoSite string $SITE" CocoVideo/Info.plist
$PB -c "Set :CFBundleDisplayName $DISPLAY" CocoVideo/Info.plist
$PB -c "Set :CFBundleName $DISPLAY" CocoVideo/Info.plist

if command -v xcodegen >/dev/null 2>&1; then
  echo ">> xcodegen"
  xcodegen generate
elif [ ! -d "CocoVideo.xcodeproj" ]; then
  echo "!! 既没有 xcodegen 也没有 CocoVideo.xcodeproj"; exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

if xcodebuild -project CocoVideo.xcodeproj -list 2>/dev/null | sed -n '/Schemes:/,$p' | grep -qw "$APP_NAME"; then
  TARGET_ARGS=(-scheme "$APP_NAME")
else
  TARGET_ARGS=(-target "$APP_NAME")
fi

ARCHIVE="$OUT_DIR/$BUNDLE.xcarchive"
echo ">> archive (未签名)"
xcodebuild \
  -project CocoVideo.xcodeproj \
  "${TARGET_ARGS[@]}" \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  archive

APP_PATH="$ARCHIVE/Products/Applications/$APP_NAME.app"
[ -d "$APP_PATH" ] || { echo "!! 没找到 $APP_PATH"; exit 1; }

echo ">> 打包 Payload"
mkdir -p "$OUT_DIR/Payload"
cp -R "$APP_PATH" "$OUT_DIR/Payload/"
rm -rf "$OUT_DIR/Payload/$APP_NAME.app/_CodeSignature"

cd "$OUT_DIR"
zip -qry "$OUT_NAME" Payload
cd ..

# 打包后自检：确认 IPA 里的标识/站点/名字确实是本次传入的值
echo ">> 自检 ($OUT_DIR/$OUT_NAME)"
CHECK_DIR="$OUT_DIR/_check"
rm -rf "$CHECK_DIR"; mkdir -p "$CHECK_DIR"
unzip -qo "$OUT_DIR/$OUT_NAME" -d "$CHECK_DIR"
CPL="$CHECK_DIR/Payload/$APP_NAME.app/Info.plist"
echo "   CFBundleIdentifier = $($PB -c 'Print :CFBundleIdentifier' "$CPL")"
echo "   CFBundleDisplayName = $($PB -c 'Print :CFBundleDisplayName' "$CPL")"
echo "   CocoSite = $($PB -c 'Print :CocoSite' "$CPL")"
rm -rf "$CHECK_DIR"

echo "OK -> $(pwd)/$OUT_DIR/$OUT_NAME"
ls -lh "$OUT_DIR/$OUT_NAME"

bash scripts/publish_ipa.sh "$OUT_DIR/$OUT_NAME" || echo "PUBLISH: skipped"
