#!/usr/bin/env bash
# 把 IPA 挂到 GitHub Release（公开仓库匿名可下载）。多次调用 = 多个变体共用一个 Release。
set -uo pipefail

IPA="$1"
[ -f "$IPA" ] || { echo "PUBLISH: ipa not found: $IPA"; exit 0; }

REPO="${GITHUB_REPOSITORY:-fushengan123/coco-}"
TAG="v1.7.0"
NAME=$(basename "$IPA")
echo "PUBLISH: $NAME -> $REPO $TAG"

HDR=$(git config --get http.https://github.com/.extraheader || true)
B64=$(printf '%s' "$HDR" | sed -e 's/^.*[Bb]asic //' -e 's/[[:space:]]*$//')
TOKEN=$(python3 -c "import base64,sys
try:
    print(base64.b64decode(sys.argv[1]).decode().split(':',1)[1])
except Exception:
    print('')" "$B64")

if [ -z "$TOKEN" ]; then echo "PUBLISH_FAILED: no token"; exit 0; fi

API="https://api.github.com/repos/$REPO"
AUTH="Authorization: Bearer $TOKEN"

REL_ID=$(curl -s -H "$AUTH" "$API/releases/tags/$TAG" | python3 -c "import json,sys
try:
    print(json.load(sys.stdin).get('id',''))
except Exception:
    print('')")

if [ -z "$REL_ID" ]; then
  REL_ID=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
    -d "{\"tag_name\":\"$TAG\",\"name\":\"开心视频 iOS 1.7.0\",\"body\":\"Unsigned IPAs. Sideload with Sideloadly.\"}" \
    "$API/releases" | python3 -c "import json,sys
try:
    print(json.load(sys.stdin).get('id',''))
except Exception:
    print('')")
fi
if [ -z "$REL_ID" ]; then echo "PUBLISH_FAILED: cannot create release"; exit 0; fi

OLD_ASSET=$(curl -s -H "$AUTH" "$API/releases/$REL_ID/assets" | python3 -c "import json,sys
name=sys.argv[1]
try:
    for a in json.load(sys.stdin):
        if a.get('name')==name:
            print(a.get('id'))
except Exception:
    pass" "$NAME")
if [ -n "$OLD_ASSET" ]; then
  curl -s -X DELETE -H "$AUTH" "$API/releases/assets/$OLD_ASSET" >/dev/null
fi

ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$NAME")
UP=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/octet-stream" \
  --data-binary @"$IPA" \
  "https://uploads.github.com/repos/$REPO/releases/$REL_ID/assets?name=$ENC")
echo "PUBLISH_ASSET: $UP"
