# ============================================================
#  Windows 侧：用免费 Apple ID 给 IPA 签名并装机
#  依赖 Sideloadly（自带 Apple 开发者接口 + 免费证书申请）
#  用法:
#    powershell -ExecutionPolicy Bypass -File .\scripts\sign_free_windows.ps1 ^
#        -Ipa .\COCO影视_v1.6.0_ios.ipa -AppleId you@example.com
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Ipa,
    [string]$AppleId = "",
    [string]$BundleId = "com.coco.video",
    [string]$Sideloadly = ""
)

$ErrorActionPreference = "Stop"

function Resolve-Ipa([string]$p) {
    if (Test-Path $p) { return (Resolve-Path $p).Path }
    $guess = Get-ChildItem -Path . -Filter *.ipa -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($guess) { return $guess.FullName }
    throw "找不到 IPA: $p"
}

function Find-Sideloadly {
    $candidates = @(
        "$env:ProgramFiles\Sideloadly\sideloadly.exe",
        "${env:ProgramFiles(x86)}\Sideloadly\sideloadly.exe",
        "$env:LOCALAPPDATA\Programs\Sideloadly\sideloadly.exe",
        "$env:USERPROFILE\Desktop\Sideloadly\sideloadly.exe",
        "$env:USERPROFILE\Downloads\Sideloadly\sideloadly.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    $found = Get-ChildItem -Path "$env:ProgramFiles", "$env:LOCALAPPDATA", "$env:USERPROFILE\Downloads" -Filter "sideloadly.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    return ""
}

$ipaPath = Resolve-Ipa $Ipa
Write-Host "IPA   : $ipaPath"

if (-not (Test-Path $ipaPath)) { throw "IPA 不存在" }

if (-not $Sideloadly) { $Sideloadly = Find-Sideloadly }
if (-not $Sideloadly) {
    Write-Host ""
    Write-Host "没找到 sideloadly.exe。装一个（免费）:" -ForegroundColor Yellow
    Write-Host "  https://sideloadly.io/"
    Write-Host ""
    Write-Host "装好之后有两条路:" -ForegroundColor Yellow
    Write-Host "  A. 直接开 Sideloadly 界面：iPhone 插 USB -> 拖入 IPA -> 填 Apple ID -> Start"
    Write-Host "  B. 回到命令行再跑一次这个脚本，它会自动调 CLI"
    Write-Host ""
    Write-Host "免费证书限制: 7 天到期 / 同时最多 3 个 App / 首次要信任描述文件"
    Write-Host "  设置 -> 通用 -> VPN与设备管理 -> 开发者应用 -> 信任"
    exit 2
}

Write-Host "Sideloadly: $Sideloadly"

$cliArgs = @("-i", $ipaPath, "--bundleid", $BundleId)
if ($AppleId -ne "") { $cliArgs += @("--appleid", $AppleId) }

Write-Host ">> 开始签名安装（按提示输入 Apple ID 密码 / 二次验证码）"
& $Sideloadly @args

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "CLI 返回 $LASTEXITCODE。改用界面模式:" -ForegroundColor Yellow
    Start-Process $Sideloadly
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "完成。iPhone 上如果提示不受信任的开发者:" -ForegroundColor Green
Write-Host "  设置 -> 通用 -> VPN与设备管理 -> 开发者应用 -> 信任"
Write-Host "  7 天后到期，重跑一次这个脚本即可续期。"
