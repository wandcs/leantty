<#
.SYNOPSIS
  Start a bounded TCP fixture that accepts connections without sending bytes.
.DESCRIPTION
  Provides a repository-local initial-handshake stall for physical-PC timeout
  verification. The listener writes a ready marker, records accepted clients,
  and closes every socket when its bounded run ends or the process is stopped.
#>
[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)][int]$Port,
    [ValidateRange(1, 7200)][int]$RunSeconds = 240,
    [Parameter(Mandatory = $true)][string]$ControlDirectory
)

$ErrorActionPreference = 'Stop'
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + `
    [IO.Path]::DirectorySeparatorChar
$fixtureDirectory = [IO.Path]::GetFullPath($ControlDirectory)
if (-not $fixtureDirectory.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'TCP stall fixture control directory must be inside the system temporary directory'
}
if (Test-Path -LiteralPath $fixtureDirectory) {
    throw "TCP stall fixture control directory already exists: $fixtureDirectory"
}

$listener = $null
$clients = [Collections.Generic.List[Net.Sockets.TcpClient]]::new()
New-Item -ItemType Directory -Path $fixtureDirectory | Out-Null
try {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $Port)
    $listener.Start()
    [IO.File]::WriteAllText(
        (Join-Path $fixtureDirectory 'fixture-ready'),
        "pid=$PID`nport=$Port`n",
        [Text.UTF8Encoding]::new($false)
    )
    Write-Output "tcp-stall state=ready port=$Port"

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $RunSeconds) {
        if ($listener.Pending()) {
            $client = $listener.AcceptTcpClient()
            $clients.Add($client)
            Write-Output "tcp-stall state=accepted port=$Port count=$($clients.Count)"
        }
        Start-Sleep -Milliseconds 50
    }
} finally {
    foreach ($client in $clients) {
        $client.Dispose()
    }
    if ($null -ne $listener) {
        $listener.Stop()
    }
    if (Test-Path -LiteralPath $fixtureDirectory) {
        Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force
    }
}
