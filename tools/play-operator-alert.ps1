<#
.SYNOPSIS
  Play the local operator-action alert through the default Windows audio device.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$alertPath = Join-Path $PSScriptRoot 'operator-alert.wav'
if (-not (Test-Path -LiteralPath $alertPath -PathType Leaf)) {
    throw "Operator alert WAV is missing: $alertPath"
}

$player = [System.Media.SoundPlayer]::new($alertPath)
try {
    $player.Load()
    $player.PlaySync()
}
finally {
    $player.Dispose()
}
