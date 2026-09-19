<#
.SYNOPSIS
  LeanTTY 快速开发构建（不含 native，仅 ArkTS + 资源）
.DESCRIPTION
  跳过 Rust native 交叉编译，仅触发 ArkTS/资源构建
  用法:
  .\tools\dev-build.ps1              # 增量构建
  .\tools\dev-build.ps1 -Clean       # 全量重建
#>
param(
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'build-lock.ps1')
. (Join-Path $PSScriptRoot 'acceptance-source.ps1')
. (Join-Path $PSScriptRoot 'formal-build-environment.ps1')

Invoke-WithLeanTTYBuildLock -RepoRoot $repoRoot -Operation 'dev-build' -Action {
$deveco = $env:DEVECO_HOME
if (-not $deveco) {
    $candidates = @('C:\Program Files\Huawei\DevEco Studio', 'D:\Program Files\Huawei\DevEco Studio')
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { $deveco = $c; break }
    }
}
if (-not $deveco) { throw 'DevEco Studio not found. Set DEVECO_HOME.' }

$nodeExe  = Join-Path $deveco 'tools\node\node.exe'
$hvigorJs = Join-Path $deveco 'tools\hvigor\bin\hvigorw.js'
$jbrBin   = Join-Path $deveco 'jbr\bin'

$env:NODE_OPTIONS = ''
$env:DEVECO_SDK_HOME = (Resolve-LeanTTYHarmonySdk -DevEcoHome $deveco).sdkHome
$env:JAVA_HOME = Join-Path $deveco 'jbr'
$env:PATH = "$jbrBin;$env:PATH"

if ($Clean) {
    $dirs = @(
        (Join-Path $repoRoot 'entry\build'),
        (Join-Path $repoRoot 'build'),
        (Join-Path $repoRoot '.hvigor')
    )
    foreach ($d in $dirs) {
        if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
    }
}

$start = Get-Date
$hvigorArgs = @($hvigorJs, '--mode', 'module', '-p', 'module=entry@default', 'assembleHap', '-p', 'buildMode=debug')
Invoke-WithLeanTTYAcceptanceSource -RepoRoot $repoRoot -Enabled $true -Action {
    & $nodeExe @hvigorArgs
    if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
}

$elapsed = (Get-Date) - $start
Write-Host "BUILD SUCCESS in $([math]::Round($elapsed.TotalSeconds, 1))s" -ForegroundColor Green
}
