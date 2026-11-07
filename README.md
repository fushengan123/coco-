# COCO影视 · iOS 版（v1.6.0）

安卓源码 (`COCO影视_v1.6.0_完整源码.zip`) 的 iOS 移植版：同一套 H5，换成 WKWebView 外壳 + 原生桥。
工程是完整的 Xcode 项目，产出 `.ipa`，可用免费 Apple ID 证书签名装到 iPhone。

## 目录

```
coco-ios/
├─ CocoVideo.xcodeproj/          Xcode 工程（已带共享 Scheme，双击可开）
├─ project.yml                   XcodeGen 描述（工程文件的源，CI 用这个重建）
├─ CocoVideo/
│  ├─ AppDelegate.swift
│  ├─ SceneDelegate.swift
│  ├─ Config.swift               站点 / UA / 注入脚本都在这
│  ├─ WebViewController.swift    主界面：本地 H5 + 进度条 + 启动页 + 失败重试 + 下拉刷新
│  ├─ WebPageViewController.swift 会员中心 / 找回密码 的内嵌浏览器
│  ├─ NativeBridge.swift         AndroidBridge 的 iOS 实现（request/post/cast/share/copy/openWeb）
│  ├─ NativeHTTP.swift           原生 HTTP 通道（带 Cookie、宽松 TLS）
│  ├─ LocalSchemeHandler.swift   cocoapp://local/ -> Bundle/web/
│  ├─ CastViewController.swift   AirPlay 投屏
│  ├─ Assets.xcassets/           AppIcon（脚本生成）+ 启动背景色
│  ├─ Info.plist                 ATS / 横竖屏 / 后台音频
│  └─ web/                       原封不动的 H5（index.html、js/app.js、hls.min.js ...）
├─ scripts/
│  ├─ build_ipa.sh               出未签名 IPA
│  ├─ sign_ipa_macos.sh          有 Mac：免费团队自动签名出 IPA
│  ├─ sign_free_windows.ps1      没 Mac：Windows + Sideloadly 签
│  └─ export_options.plist
└─ .github/workflows/ios.yml     没 Mac：GitHub Actions 的 macos-14 帮你编译
```

## 安卓功能 -> iOS 对应

| 安卓 | iOS |
|---|---|
| `file:///android_asset/web/index.html` | `cocoapp://local/index.html`（WKURLSchemeHandler，真 Origin） |
| `webView.addJavascriptInterface(..., "AndroidBridge")` | documentStart 注入同名对象，H5 一行没改 |
| OkHttp 绕过跨域 / 带 Cookie | `NativeHTTP`（URLSession + WebView Cookie 同步 + 信任全证书） |
| `AndroidBridge.request / post` | 同签名，回调仍是 `Coco._nativeResp(cbId, body, err)` |
| 乐播投屏 SDK（私有协议） | AVPlayer + AirPlay 路由选择；或用控制中心「屏幕镜像」 |
| `DownloadManager` 下载 | 未移植（iOS 侧用系统分享/拷贝链接） |
| 视频全屏横屏 | WKWebView 原生全屏播放器 + Info.plist 全方向 |
| SwipeRefreshLayout | UIRefreshControl |
| hls.js | 注入脚本把 `Hls.isSupported()` 置 false，走 iOS 原生 HLS（无跨域、可 AirPlay） |

## 三条出路

### 1) 有 Mac（最直）

```bash
open CocoVideo.xcodeproj      # 或 brew install xcodegen && xcodegen generate
# Xcode -> Settings -> Accounts -> 登录 Apple ID -> Manage Certificates -> + Apple Development
TEAM_ID=你的TeamID bash scripts/sign_ipa_macos.sh
```

产出 `build/COCO影视_v1.6.0_ios_signed.ipa`。免费账号直接连着手机 Run 也行，会自动装到设备上。

### 2) 没 Mac，有 GitHub

push 到仓库 -> Actions -> `build-ios` -> Run workflow -> 下产物里的 `COCO影视_v1.6.0_ios.ipa`（未签名）。
macos runner 自带 Xcode，编译这步不用你出机器。

### 3) Windows 签名装机

```powershell
# 装 Sideloadly（免费）：https://sideloadly.io/
powershell -ExecutionPolicy Bypass -File .\scripts\sign_free_windows.ps1 -Ipa .\COCO影视_v1.6.0_ios.ipa -AppleId 你的AppleID@example.com
```

Sideloadly 会拿你的免费 Apple ID 去 Apple 开发者接口申请 7 天个人证书、注册设备 UDID、签名并安装。
然后手机：设置 -> 通用 -> VPN与设备管理 -> 开发者应用 -> 信任。

## 免费证书的硬限制（苹果定的，不是工程问题）

- 证书 **7 天** 到期，到期重签一次即可，数据不丢
- 同时最多 **3 个** 自签 App
- 每 7 天最多注册 **10 个** App ID
- 设备 UDID 必须已注册（Sideloadly / Xcode 首次连接会自动注册）
- 想免 7 天反复重签：SideStore / AltStore + AltServer（同样是免费 Apple ID）

## BUILD NOTES

- 站点域名在 `Config.swift` 的 `Config.site` 和 `CocoVideo/web/js/app.js` 的 `SITE`，两处要一致。
- 换 Bundle ID：`project.pbxproj` 的 `PRODUCT_BUNDLE_IDENTIFIER`，或 Xcode 里改。免费证书下 Sideloadly 会自动加后缀（`com.coco.video.xxxx`），正常。
- 免费签名 + `NSAllowsArbitraryLoads`（ATS 全放行）是本工程默认配置，站点证书链不全也能取数。
- 原生通道超时 15s，和 H5 里的 `setTimeout(15000)` 对齐。
- 视频源若是私有加密 / 非标准 m3u8，原生 AVPlayer 会失败，走「屏幕镜像」即可。
