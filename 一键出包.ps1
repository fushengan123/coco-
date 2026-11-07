# ============================================================
#  COCO影视 iOS —— 没有 Mac 的完整出包链路
#  1) git 推到 GitHub  2) Actions 的 macos runner 编译  3) 下载 IPA  4) Sideloadly 免费签名装机
#
#  用法（在 coco-ios 目录里）:
#    powershell -ExecutionPolicy Bypass -File .\一键出包.ps1 -Repo https://github.com/你的账号/coco-ios.git
#
#  只想签名已有的 IPA:
#    powershell -ExecutionPolicy Bypass -File .\一键出包.ps1 -SkipPush -Ipa .\COCO影视_v1.6.0_ios.ipa -AppleId you@example.com
# ============================================================
param(
    [string]$Repo = "",
    [string]$Ipa = "",
    [string]$AppleId = "",
    [switch]$SkipPush
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

function Say($msg, $color = "Gray") { Write-Host $msg -ForegroundColor $color }
function Head($msg) { Write-Host ""; Write-Host "== $msg" -ForegroundColor Cyan }

function Find-Git {
    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
        "C:\Program Files\Git\cmd\git.exe",
        "C:\Program Files (x86)\Git\cmd\git.exe",
        "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe"
    )) { if (Test-Path $p) { return $p } }
    return ""
}

function Find-Ipa {
    if ($Ipa -and (Test-Path $Ipa)) { return (Resolve-Path $Ipa).Path }
    $hit = Get-ChildItem -Path $root -Filter *.ipa -Recurse -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return ""
}

# ---------- 只要签名 ----------
if ($SkipPush) {
    $target = Find-Ipa
    if (-not $target) { throw "没找到 IPA，用 -Ipa 指定路径" }
    Say "签名: $target"
    & powershell -ExecutionPolicy Bypass -File "$root\scripts\sign_free_windows.ps1" -Ipa $target -AppleId $AppleId
    exit $LASTEXITCODE
}

# ---------- 1. 推仓库 ----------
Head "1/3 推送到 GitHub"
$git = Find-Git
if (-not $git) {
    Say "没装 Git。装一个: https://git-scm.com/download/win" "Yellow"
    Say "或者跳过这步 —— 直接把 coco-ios 文件夹拖进 GitHub 网页新建的仓库（drag & drop 保留目录结构）"
    exit 2
}

if (-not (Test-Path ".git")) {
    & $git init -b main 2>$null
    if ($LASTEXITCODE -ne 0) { & $git init; & $git checkout -b main }
}

& $git add -A
& $git -c user.name="coco-build" -c user.email="coco@local" commit -m "COCO影视 iOS 1.6.0" 2>$null

if ([string]::IsNullOrWhiteSpace($Repo)) {
    Say ""
    Say "在 https://github.com/new 建一个空仓库（Public 最省事，Private 也行）" "Yellow"
    Say "然后把地址粘进来，例如 https://github.com/you/coco-ios.git" "Yellow"
    $Repo = Read-Host "仓库地址"
}
if ([string]::IsNullOrWhiteSpace($Repo)) { throw "没给仓库地址" }

$existing = & $git remote 2>$null
if ($existing -contains "origin") { & $git remote set-url origin $Repo } else { & $git remote add origin $Repo }

Say "推送中……首次会弹 GitHub 登录窗口"
& $git push -u origin main
if ($LASTEXITCODE -ne 0) {
    Say "推送失败。常见原因：没登录 / 仓库不是空的 / 地址写错" "Yellow"
    Say "登录：Git Credential Manager 会弹窗，选 browser 登录即可"
    exit 3
}

$web = $Repo -replace "\.git$", ""
Say "仓库: $web" "Green"
Say "Actions: $web/actions" "Green"

# ---------- 2. 等编译 ----------
Head "2/3 编译（GitHub 的 macos-14 跑，约 3-6 分钟）"

$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) {
    Say ""
    Say "没装 GitHub CLI，这一步用浏览器手动完成：" "Yellow"
    Say "  1. 打开 $web/actions"
    Say "  2. 左边选 build-ios -> 右边 Run workflow -> 绿色按钮"
    Say "  3. 跑完点进那次运行，底部 Artifacts 下载 COCO-iOS-ipa"
    Say "  4. 解压得到 COCO影视_v1.6.0_ios.ipa，回来跑:"
    Say "     powershell -ExecutionPolicy Bypass -File .\一键出包.ps1 -SkipPush -Ipa .\COCO影视_v1.6.0_ios.ipa" "White"
    Say ""
    Say "装 gh 可以省掉这些点击: winget install --id GitHub.cli -e" "Gray"
    exit 0
}

Say "gh 在，自动触发"
& gh workflow run ios.yml
Start-Sleep -Seconds 6
$runId = & gh run list --workflow ios.yml --limit 1 --json databaseId --jq ".[0].databaseId"
if (-not $runId) { Say "拿不到 run id，去 $web/actions 手动看" "Yellow"; exit 4 }

& gh run watch $runId --exit-status
if ($LASTEXITCODE -ne 0) { Say "构建失败，日志: $web/actions/runs/$runId" "Red"; exit 5 }

Remove-Item -Recurse -Force "build\gh" -ErrorAction SilentlyContinue
& gh run download $runId -n COCO-iOS-ipa -D "build\gh"

$ipa = Get-ChildItem "build\gh" -Filter *.ipa -Recurse | Select-Object -First 1
if (-not $ipa) { Say "产物里没 IPA" "Red"; exit 6 }
Say "IPA: $($ipa.FullName)" "Green"

# ---------- 3. 签名 ----------
Head "3/3 免费证书签名"
& powershell -ExecutionPolicy Bypass -File "$root\scripts\sign_free_windows.ps1" -Ipa $ipa.FullName -AppleId $AppleId
