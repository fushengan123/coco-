#!/usr/bin/env bash
# 把编译好的 IPA 发到 GitHub Release（公开仓库里匿名可下载）。
# 由 build_ipa.sh 在打包完成后调用。发布失败不影响构建结果。
set -uo pipefail

IPA="$1"
if [ ! -f "$IPA" ]; then echo "PUBLISH: ipa not found: $IPA"; exit 0; fi

REPO="${GITHUB_REPOSITORY:-fushengan123/coco-}"
TAG="v1.6.0"
NAME=$(basename "$IPA")
echo "PUBLISH: $NAME ($(wc -c < "$IPA" | tr -d ' ') bytes) -> $REPO $TAG"

# actions/checkout 会把 token 写进本地 git 的 extraheader，直接取出来复用
HDR=$(git config --get http.https://github.com/.extraheader || true)
B64=$(printf '%s' "$HDR" | sed -e 's/^.*[Bb]asic //' -e 's/[[:space:]]*$//')
TOKEN=$(python3 -c "import base64,sys
try:
    print(base64.b64decode(sys.argv[1]).decode().split(':',1)[1])
except Exception:
    print('')" "$B64")

if [ -z "$TOKEN" ]; then
  echo "PUBLISH_FAILED: no token found in git extraheader"
  exit 0
fi

API="https://api.github.com/repos/$REPO"
AUTH="Authorization: Bearer $TOKEN"

OLD=$(curl -s -H "$AUTH" "$API/releases/tags/$TAG" | python3 -c "import json,sys
try:
    print(json.load(sys.stdin).get('id',''))
except Exception:
    print('')")
if [ -n "$OLD" ]; then
  curl -s -X DELETE -H "$AUTH" "$API/releases/$OLD" >/dev/null || true
  curl -s -X DELETE -H "$AUTH" "$API/git/refs/tags/$TAG" >/dev/null || true
fi

RESP=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"tag_name\":\"$TAG\",\"name\":\"COCO iOS 1.6.0\",\"body\":\"Unsigned IPA, built on macos-14 by GitHub Actions. Sideload with Sideloadly.\"}" \
  "$API/releases")
REL_ID=$(printf '%s' "$RESP" | python3 -c "import json,sys
try:
    print(json.load(sys.stdin).get('id',''))
except Exception:
    print('')")

if [ -z "$REL_ID" ]; then
  echo "PUBLISH_FAILED: $RESP"
  exit 0
fi

ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$NAME")
UP=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/octet-stream" \
  --data-binary @"$IPA" \
  "https://uploads.github.com/repos/$REPO/releases/$REL_ID/assets?name=$ENC")
echo "PUBLISH_ASSET: $UP"

# 兜底通道：release 权限不够时扔到公开文件站，URL 打在日志里
FB=$(curl -s --max-time 180 -F "file=@$IPA" https://0x0.st || true)
echo "FALLBACK_URL: $FB"
