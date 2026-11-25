# MnnChat 一键编译 / 签名 / 装机脚本（LocAI 发行版）
# 用法：pwsh -File scripts\build-and-install.ps1            （编译 + 装机）
#       pwsh -File scripts\build-and-install.ps1 -BuildOnly  （只编译）
param(
    [switch]$BuildOnly
)

$ErrorActionPreference = 'Stop'

$ProjectDir = Split-Path -Parent $PSScriptRoot
$DevEcoDir = 'D:\Apps\DevEco Studio'

# hvigor 依赖 node / jbr(java) / 工具链 / 系统 cmd，全部要进 PATH
$env:PATH = @(
    'C:\Windows\System32',
    'C:\Windows',
    'C:\Windows\System32\Wbem',
    "$DevEcoDir\tools\node",
    "$DevEcoDir\tools\hvigor\bin",
    "$DevEcoDir\jbr\bin",
    "$DevEcoDir\sdk\default\openharmony\toolchains"
) -join ';' + ';' + $env:PATH
$env:DEVECO_SDK_HOME = "$DevEcoDir\sdk"

$hdc = "$DevEcoDir\sdk\default\openharmony\toolchains\hdc.exe"

Push-Location $ProjectDir
try {
    Write-Host '[1/3] 编译 HAP ...' -ForegroundColor Cyan
    hvigorw --mode module -p product=default -p module=entry@default assembleHap --no-daemon
    if ($LASTEXITCODE -ne 0) { throw '编译失败，请检查上方 hvigor 输出' }

    $outDir = Join-Path $ProjectDir 'entry\build\default\outputs\default'
    $signedHap = Get-ChildItem -LiteralPath $outDir -Filter '*-signed.hap' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $anyHap = Get-ChildItem -LiteralPath $outDir -Filter '*.hap' |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $anyHap) { throw "未找到 HAP 产物：$outDir" }
    Write-Host ("[2/3] 产物：" + $anyHap.FullName + " (" + [Math]::Round($anyHap.Length / 1MB, 2) + " MB)") -ForegroundColor Green

    if ($BuildOnly) { return }

    if (-not $signedHap) {
        Write-Host '[!] 当前没有已签名 HAP。请在 DevEco Studio 中打开 Project Structure → Signing Configs，' -ForegroundColor Yellow
        Write-Host '    勾选 “Automatically generate signature”（需已登录华为开发者账号并连接真机），再次运行本脚本。' -ForegroundColor Yellow
        return
    }

    Write-Host '[3/3] 安装到真机 ...' -ForegroundColor Cyan
    $targets = & $hdc list targets
    if (($targets | Out-String).Trim() -eq '[Empty]' -or ($targets | Out-String).Trim() -eq '') {
        throw 'hdc 未发现设备：请用 USB 连接手机，开启“开发者模式 / USB 调试”，并在手机上允许调试授权'
    }
    & $hdc install -r $signedHap.FullName
    if ($LASTEXITCODE -ne 0) { throw 'hdc install 失败' }

    & $hdc shell aa start -a EntryAbility -b com.henry.local
    Write-Host '安装并拉起完成 ✔' -ForegroundColor Green
}
finally {
    Pop-Location
}
