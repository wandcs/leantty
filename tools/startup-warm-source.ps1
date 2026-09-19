<#
.SYNOPSIS
  Temporarily inject warm-start paint markers into a diagnostic build.
.DESCRIPTION
  The probe observes the native input, echo and paint paths.
  It only emits T4 after the foreground focus has caused a paint,
  and T5 after the same ASCII byte returns through the local command path and
  is painted. The touched source file are restored byte-for-byte.
#>

. (Join-Path $PSScriptRoot 'acceptance-source.ps1')
. (Join-Path $PSScriptRoot 'native-startup-source.ps1')

function Invoke-WithLeanTTYStartupWarmSource {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    $nativeStartupPath = Join-Path $RepoRoot 'entry/src/main/ets/model/terminal/NativeTerminalController.ets'
    $nativeStartupBackup = [IO.File]::ReadAllBytes($nativeStartupPath)
    try {
        Add-LeanTTYNativeStartupSource -RepoRoot $RepoRoot -Mode warm
        & $Action
    } finally {
        Restore-LeanTTYAcceptanceSourceFile -Path $nativeStartupPath -Bytes $nativeStartupBackup
    }
}
