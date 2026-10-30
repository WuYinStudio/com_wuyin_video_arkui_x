# 从 ArkUI-X SDK 同步 Android 侧运行库到 .arkui-x/android/app/libs
#
# 用途：Android 壳工程编译期需要 arkui_android_adapter.jar（ohos.stage.ability.adapter /
# ohos.ace.adapter.capability.bridge 等类都由它提供）；运行期还需要引擎与插件 .so。
# 这些二进制不随源码仓库分发，用本脚本从本机 ArkUI-X SDK 复制。
#
# 用法（在工程根目录执行）：
#   pwsh scripts/sync_arkui_android_libs.ps1                  # 只复制 adapter jar（够编译）
#   pwsh scripts/sync_arkui_android_libs.ps1 -WithRuntimeLibs # 再复制 arm64-v8a 运行期 .so
#   pwsh scripts/sync_arkui_android_libs.ps1 -Abi arm              # armeabi-v7a
#
# SDK 根目录取自 local.properties 的 arkui-x.dir，或 -SdkRoot 参数。

param(
    [string]$SdkRoot = "",
    [ValidateSet("arm64-v8a", "armeabi-v7a", "x86_64")]
    [string]$Abi = "arm64-v8a",
    [switch]$WithRuntimeLibs
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$libs = Join-Path $repo ".arkui-x\android\app\libs"

# DevEco Studio 写 local.properties 时会按 Java properties 规则转义路径
# （`F\:\\APPS\\ArkUI-X\\Sdk`）：冒号和反斜杠都带反斜杠。直接当路径用会落到
# 不存在的 `F\:` 上，Get-ChildItem 甚至会报“找不到 Directory 参数”。这里统一还原。
function ConvertFrom-PropertyPath {
    param([string]$Value)
    $p = $Value.Trim()
    if ($p.Length -ge 2 -and $p.StartsWith('"') -and $p.EndsWith('"')) { $p = $p.Substring(1, $p.Length - 2) }
    $p = $p -replace '\\\\', '\'
    $p = $p -replace '\\:', ':'
    $p = $p -replace '\\=', '='
    return $p.Replace('/', '\')
}

function Resolve-SdkRoot {
    param([string]$Explicit)
    if ($Explicit) { return (ConvertFrom-PropertyPath $Explicit) }
    $localProps = Join-Path $repo "local.properties"
    if (Test-Path $localProps) {
        foreach ($line in Get-Content $localProps) {
            if ($line -match '^\s*arkui-x\.dir\s*=\s*(.+?)\s*$') {
                return (ConvertFrom-PropertyPath $Matches[1])
            }
        }
    }
    throw "找不到 ArkUI-X SDK：请在 local.properties 里配置 arkui-x.dir，或传 -SdkRoot"
}

# ArkUI-X SDK 里的版本目录（26.0.0 等）自动识别
function Resolve-EngineDir {
    param([string]$Root)
    $candidates = @(Get-ChildItem $Root -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "arkui-x\engine\lib") })
    if ($candidates.Count -eq 0) {
        if (Test-Path (Join-Path $Root "arkui-x\engine\lib")) { return $Root }
        throw "在 $Root 下找不到 arkui-x/engine/lib"
    }
    return $candidates[0].FullName
}

$sdk = Resolve-SdkRoot -Explicit $SdkRoot
$engineRoot = Resolve-EngineDir -Root $sdk
$engine = Join-Path $engineRoot "arkui-x"
$plugins = Join-Path $engine "plugins"

Write-Host "ArkUI-X SDK : $sdk"
Write-Host "engine      : $engine"
Write-Host "ABI         : $Abi"

New-Item -ItemType Directory -Force -Path $libs | Out-Null

# 1) 编译必需：适配层 jar
$adapter = Join-Path $engine "engine\lib\arkui\arkui_android_adapter.jar"
if (-not (Test-Path $adapter)) { throw "缺少 $adapter" }
Copy-Item $adapter $libs -Force
Write-Host "  + arkui_android_adapter.jar"

if (-not $WithRuntimeLibs) {
    Write-Host ""
    Write-Host "只复制了编译所需的 adapter jar。要出可运行的 APK，请加 -WithRuntimeLibs 复制引擎 .so。"
    exit 0
}

# 2) 运行期：引擎 / third_party / utils / 各 API 与组件插件
$abiDir = switch ($Abi) {
    "arm64-v8a"   { "android-arm64-release" }
    "armeabi-v7a" { "android-arm-release" }
    "x86_64"      { "android-x86_64" }
}
$jniDest = Join-Path $libs $Abi
New-Item -ItemType Directory -Force -Path $jniDest | Out-Null

$patterns = @(
    "engine\lib\arkui\$abiDir\*.so",
    "engine\lib\third_party\$abiDir\*.so",
    "engine\lib\utils\$abiDir\*.so"
)

$copied = 0
foreach ($pattern in $patterns) {
    $full = Join-Path $engine $pattern
    Get-ChildItem -Path $full -Filter *.so -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item $_.FullName $jniDest -Force
        $copied++
    }
}

# 插件 .so 分散在 plugins\api\lib\<模块>\<abi>\ 与 plugins\component\lib\<模块>\<abi>\，
# 层级不统一（data 一层、advanced\chip 两层），所以按“目录名等于 ABI 目录”递归筛选。
# 注意：漏掉这一批会导致运行时 @ohos.data.preferences / display / net 等模块加载失败
# （logcat: Load native module failed: @ohos:data.preferences）。
foreach ($root in @("plugins\api\lib", "plugins\component\lib")) {
    $fullRoot = Join-Path $engine $root
    if (-not (Test-Path $fullRoot)) { continue }
    Get-ChildItem $fullRoot -Recurse -File -Filter *.so -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -eq $abiDir } |
        ForEach-Object {
            Copy-Item $_.FullName $jniDest -Force
            $copied++
        }
}

# 插件 jar（部分能力以 jar 形式提供，如 http/media/pasteboard）
Get-ChildItem (Join-Path $engine "plugins\api\lib") -Recurse -Filter "*_android.jar" -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item $_.FullName $libs -Force
    $copied++
}

Write-Host "  + $copied 个运行库文件 -> $jniDest"
Write-Host ""
Write-Host "下一步：在 .arkui-x/android 目录执行 gradlew assembleDebug"
