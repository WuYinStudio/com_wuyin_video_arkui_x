# 低内存机器上的 HAP/APP 构建包装脚本
#
# 背景：es2abc（ArkTS 字节码生成器）在系统提交内存紧张时会直接崩溃：
#   CHECK FAILED: (arenas_) != nullptr  IN: .../arena_allocator.cpp
# 这不是代码错误，而是原生分配失败。本脚本给 node 与 JVM 都设上限，
# 把内存留给 es2abc，避免它在编译中段抢不到 arena。
#
# 用法（在任意目录）：
#   pwsh scripts/build_hap.ps1                     # assembleHap（默认 debug）
#   pwsh scripts/build_hap.ps1 -Task assembleApp    # 出 APK
#   pwsh scripts/build_hap.ps1 -BuildMode release
#   pwsh scripts/build_hap.ps1 -SdkHome 'D:\DevEco Studio'

param(
    [string]$Task = 'assembleHap',
    [ValidateSet('debug', 'release')]
    [string]$BuildMode = 'debug',
    [string]$Product = 'default',
    [string]$Module = 'entry@default',
    [string]$SdkHome = ''
)

# hvigor 会往 stderr 写 WARN；这里不能把 stderr 当终止错误，否则脚本会在第一条警告处中断。
$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot

function Find-DevEcoHome {
    param([string]$Explicit)
    if ($Explicit) {
        if (Test-Path (Join-Path $Explicit 'tools\hvigor\bin\hvigorw.bat')) { return $Explicit }
        throw "不是有效的 DevEco 目录：$Explicit"
    }
    $candidates = @(
        $env:DEVECO_STUDIO_HOME,
        'F:\APPS\DevEcoStudio\DevEco Studio',
        'C:\Program Files\Huawei\DevEco Studio',
        'D:\Program Files\Huawei\DevEco Studio'
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path (Join-Path $candidate 'tools\hvigor\bin\hvigorw.bat'))) { return $candidate }
    }
    throw '找不到 DevEco Studio，请用 -SdkHome 指定安装目录'
}

$dev = Find-DevEcoHome -Explicit $SdkHome
$env:NODE_HOME = Join-Path $dev 'tools\node'
$env:DEVECO_SDK_HOME = Join-Path $dev 'sdk'
$env:JAVA_HOME = Join-Path $dev 'jbr'
$env:PATH = "$env:JAVA_HOME\bin;$env:NODE_HOME;$env:PATH"

# 关键：限制编译器与打包 JVM 的堆，给 es2abc 留出连续内存；关掉 Class Data Sharing，
# 避免低提交内存下 "Failed to commit static region"。
$env:NODE_OPTIONS = '--max-old-space-size=2048'
$env:JAVA_TOOL_OPTIONS = '-Xmx512m -Xms128m -XX:+UseSerialGC -Xshare:off'

Write-Host "DevEco      : $dev"
Write-Host "task        : $Task ($BuildMode, product=$Product, module=$Module)"
Write-Host "NODE_OPTIONS: $env:NODE_OPTIONS"
Write-Host "JAVA_OPTS   : $env:JAVA_TOOL_OPTIONS"

$hvigor = Join-Path $dev 'tools\hvigor\bin\hvigorw.bat'
$hvigorArgs = @(
    '--mode', 'module',
    '-p', "product=$Product",
    '-p', "module=$Module",
    '-p', "buildMode=$BuildMode",
    $Task,
    '--no-daemon'
)

Push-Location $repo
try {
    & $hvigor @hvigorArgs 2>&1 | ForEach-Object { Write-Host $_ }
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($code -ne 0) {
    Write-Host ''
    Write-Host "构建失败（exit $code）。若日志里出现 CHECK FAILED: (arenas_) != nullptr 或 'insufficient memory'，" -ForegroundColor Yellow
    Write-Host '说明系统提交内存不足：先关掉其它大程序（或重启）再重试；本脚本已经把上限压到较低值。' -ForegroundColor Yellow
} else {
    Write-Host ''
    Write-Host '构建成功。' -ForegroundColor Green
}
exit $code
