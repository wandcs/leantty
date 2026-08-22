<#
.SYNOPSIS
  Verify LeanTTY 1.5 ConnectTimeout behavior on a physical HarmonyOS PC.
.DESCRIPTION
  Uses two bounded TCP handshake stalls plus the repository SSH fixture to
  verify direct target timeout, jump timeout, target-over-jump timeout,
  Ctrl+C cancellation, recovery, and the default successful connection path.
  The script deploys only an explicitly selected signed HAP (or the current
  signed development HAP) and removes Host entries, known_hosts entries, HDC
  mappings, fixture processes, and temporary credentials when it finishes.
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [string]$HapPath = '',
    [ValidateRange(1024, 65535)][int]$JumpPort = 22322,
    [ValidateRange(1024, 65535)][int]$TargetPort = 22323,
    [ValidateRange(1024, 65535)][int]$JumpStallPort = 22324,
    [ValidateRange(1024, 65535)][int]$TargetStallPort = 22325,
    [string]$EvidenceDirectory = '',
    [string]$Distribution = $env:LEANTTY_WSL_DISTRO
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')
. (Join-Path $PSScriptRoot 'rust-wsl.ps1')

$selectedHapPath = if ([string]::IsNullOrWhiteSpace($HapPath)) {
    Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
} else {
    [IO.Path]::GetFullPath($HapPath)
}
if (-not (Test-Path -LiteralPath $selectedHapPath -PathType Leaf)) {
    throw "ConnectTimeout signed HAP is missing: $selectedHapPath"
}
if ((Split-Path $selectedHapPath -Leaf) -match '(?i)unsigned') {
    throw 'ConnectTimeout verification requires a signed HAP'
}
if (@($JumpPort, $TargetPort, $JumpStallPort, $TargetStallPort |
        Select-Object -Unique).Count -ne 4) {
    throw 'All ConnectTimeout fixture ports must differ'
}

$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + `
    [IO.Path]::DirectorySeparatorChar
$fixtureRoot = Join-Path $temporaryRoot ('leantty-connect-timeout-' + [guid]::NewGuid().ToString('N'))
$fixtureRoot = [IO.Path]::GetFullPath($fixtureRoot)
if (-not $fixtureRoot.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ConnectTimeout fixture root escaped the system temporary directory'
}

$targetControl = Join-Path $fixtureRoot 'target-control'
$jumpControl = Join-Path $fixtureRoot 'jump-control'
$jumpStallControl = Join-Path $fixtureRoot 'jump-stall-control'
$targetStallControl = Join-Path $fixtureRoot 'target-stall-control'
$targetStdout = Join-Path $fixtureRoot 'target-stdout.log'
$targetStderr = Join-Path $fixtureRoot 'target-stderr.log'
$jumpStdout = Join-Path $fixtureRoot 'jump-stdout.log'
$jumpStderr = Join-Path $fixtureRoot 'jump-stderr.log'
$jumpStallStdout = Join-Path $fixtureRoot 'jump-stall-stdout.log'
$jumpStallStderr = Join-Path $fixtureRoot 'jump-stall-stderr.log'
$targetStallStdout = Join-Path $fixtureRoot 'target-stall-stdout.log'
$targetStallStderr = Join-Path $fixtureRoot 'target-stall-stderr.log'
$targetProcess = $null
$jumpProcess = $null
$jumpStallProcess = $null
$targetStallProcess = $null
$targetLinuxPid = 0
$jumpLinuxPid = 0
$mappedPorts = [Collections.Generic.List[int]]::new()
$awakeLeaseActive = $false
$appPid = ''
$deviceDataCleaned = $false
$result = 'failed'
$failure = ''
$commandObservations = [Collections.Generic.List[object]]::new()
$scenarioEvidence = [Collections.Generic.List[object]]::new()
$hostAliases = @('__ltty_ct_direct', '__ltty_ct_jump_stall', '__ltty_ct_jump',
    '__ltty_ct_target_jump', '__ltty_ct_default')

function Start-SshFixture {
    param(
        [Parameter(Mandatory = $true)][string]$ControlDirectory,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$DirectTarget
    )
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $PSScriptRoot 'start-ssh-auth-fixture.ps1'),
        '-ListenAddress', "0.0.0.0:$Port", '-RunSeconds', '360',
        '-ControlDirectory', $ControlDirectory, '-DirectTcpipTarget', $DirectTarget
    )
    if (-not [string]::IsNullOrWhiteSpace($Distribution)) {
        $arguments += @('-Distribution', $Distribution)
    }
    return Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments `
        -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath `
        -WindowStyle Hidden -PassThru
}

function Start-StallFixture {
    param(
        [Parameter(Mandatory = $true)][string]$ControlDirectory,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [Parameter(Mandatory = $true)][int]$Port
    )
    return Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $PSScriptRoot 'start-tcp-stall-fixture.ps1'),
        '-Port', $Port.ToString(), '-RunSeconds', '360',
        '-ControlDirectory', $ControlDirectory
    ) -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath `
        -WindowStyle Hidden -PassThru
}

function Wait-FixtureReady {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$ControlDirectory,
        [switch]$RequireCredentials
    )
    $readyPath = Join-Path $ControlDirectory 'fixture-ready'
    $credentialsPath = Join-Path $ControlDirectory 'server-credentials'
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 45) {
        $Process.Refresh()
        if ($Process.HasExited) {
            throw "Fixture launcher exited before readiness (exit=$($Process.ExitCode))"
        }
        if (Test-Path -LiteralPath $readyPath -PathType Leaf) {
            if (-not $RequireCredentials) { return $null }
            if (Test-Path -LiteralPath $credentialsPath -PathType Leaf) {
                $ready = [IO.File]::ReadAllText($readyPath)
                $pidMatch = [regex]::Match($ready, '(?m)^pid=(?<pid>\d+)$')
                $passwordLine = [IO.File]::ReadLines($credentialsPath) |
                    Where-Object { $_.StartsWith('password=', [StringComparison]::Ordinal) } |
                    Select-Object -First 1
                if ($pidMatch.Success -and -not [string]::IsNullOrWhiteSpace($passwordLine)) {
                    return [pscustomobject]@{
                        linuxPid = [int]$pidMatch.Groups['pid'].Value
                        password = $passwordLine.Substring('password='.Length)
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 200
    }
    throw 'Timed out waiting for a ConnectTimeout fixture'
}

function Read-SharedTextFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite
    )
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally {
        $stream.Dispose()
    }
}

function Stop-SshFixture {
    param([Diagnostics.Process]$Process, [int]$LinuxPid)
    try {
        if ($LinuxPid -gt 0) {
            $wslPrefix = Get-LeanTTYWslPrefix -Distribution $Distribution
            & wsl.exe @wslPrefix --exec kill -TERM $LinuxPid 2>$null
        }
    } finally {
        Stop-LocalFixture -Process $Process
    }
}

function Stop-LocalFixture {
    param([Diagnostics.Process]$Process)
    if ($null -ne $Process -and -not $Process.HasExited) {
        Stop-Process -Id $Process.Id -ErrorAction SilentlyContinue
        Wait-Process -Id $Process.Id -Timeout 10 -ErrorAction SilentlyContinue
        $Process.Refresh()
        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

function Focus-CommandInput {
    $layoutPath = Join-Path $EvidenceDirectory 'command-focus.json'
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $layout = Get-LeanTTYDeviceLayout -Hdc $script:ctHdc -Target $script:ctTarget `
            -LocalPath $layoutPath
        $nodes = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
        $focused = @($nodes | Where-Object { [string]$_.attributes.focused -eq 'true' })
        $node = if ($focused.Count -eq 1) { $focused[0] } elseif ($nodes.Count -eq 1) { $nodes[0] } else { $null }
        if ($null -ne $node) {
            if ([string]$node.attributes.focused -ne 'true') {
                Set-LeanTTYTerminalInputFocus -Hdc $script:ctHdc -Target $script:ctTarget `
                    -InputNode $node -LocalPath $layoutPath -TimeoutSeconds 10 | Out-Null
            }
            return $node
        }
        Start-Sleep -Milliseconds 200
    } while ($stopwatch.Elapsed.TotalSeconds -lt 10)
    throw 'Unable to identify the active LeanTTY command input'
}

function Submit-Command {
    param([Parameter(Mandatory = $true)][string]$Command, [string]$Stage = 'connect-timeout-command')
    Submit-LeanTTYDeviceCommand -Hdc $script:ctHdc -Target $script:ctTarget `
        -ProcessId $script:ctAppPid -Command $Command -Stage $Stage `
        -ObservationSink $commandObservations `
        -InputNodeProvider { param($inputAttempt) Focus-CommandInput } | Out-Null
}

function Submit-InteractiveValue {
    param([Parameter(Mandatory = $true)][string]$Text)
    $inputNode = Focus-CommandInput
    Invoke-LeanTTYDeviceText -Hdc $script:ctHdc -Target $script:ctTarget `
        -Text $Text -InputNode $inputNode
    Invoke-LeanTTYDeviceKey -Hdc $script:ctHdc -Target $script:ctTarget -KeyCode 2054
}

function Wait-AppLog {
    param([Parameter(Mandatory = $true)][string]$Pattern, [int]$TimeoutSeconds = 15)
    return Wait-LeanTTYAppLog -Hdc $script:ctHdc -Target $script:ctTarget `
        -ProcessId $script:ctAppPid -Pattern $Pattern -TimeoutSeconds $TimeoutSeconds
}

function Save-ScenarioEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ExpectedLayer,
        [Parameter(Mandatory = $true)][string]$ExpectedEvent,
        [Parameter(Mandatory = $true)][Diagnostics.Stopwatch]$Stopwatch
    )
    $logs = Get-LeanTTYAppLogs -Hdc $script:ctHdc -Target $script:ctTarget `
        -ProcessId $script:ctAppPid
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory ($Name + '.log')), $logs + "`n")
    Save-LeanTTYDeviceScreenshot -Hdc $script:ctHdc -Target $script:ctTarget `
        -LocalPath (Join-Path $EvidenceDirectory ($Name + '.png'))
    $scenarioEvidence.Add([ordered]@{
        name = $Name
        expectedLayer = $ExpectedLayer
        expectedEvent = $ExpectedEvent
        elapsedMs = [int]$Stopwatch.ElapsedMilliseconds
    })
}

function Clear-AppLogs {
    Clear-LeanTTYAppLogs -Hdc $script:ctHdc -Target $script:ctTarget
}

function Enter-IdleCommandState {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Clear-AppLogs
        Invoke-LeanTTYDeviceCtrlC -Hdc $script:ctHdc -Target $script:ctTarget
        try {
            Wait-AppLog -Pattern 'ACCEPTANCE_IDLE_INTERRUPT cleared=true' -TimeoutSeconds 3 | Out-Null
            return
        } catch {
            if ($attempt -ge 3) {
                throw '[harness] Unable to return the restored Pane to idle command state'
            }
        }
    }
}

function Assert-NoLateTimeout {
    param([int]$Seconds = 2)
    try {
        Wait-AppLog -Pattern 'native control event: error:(jump|target):(connect:network|tunnel:channel)' `
            -TimeoutSeconds $Seconds | Out-Null
        throw 'Cancelled connection emitted a late timeout event'
    } catch {
        if ($_.Exception.Message -eq 'Cancelled connection emitted a late timeout event') { throw }
    }
}

New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $repoRoot ('build\verification\connect-timeout-' +
        (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null

try {
    $hdc = Resolve-Hdc
    $targetId = Resolve-LeanTTYRegressionTarget -Hdc $hdc -Target $Target
    $script:ctHdc = $hdc
    $script:ctTarget = $targetId
    if ((Get-HdcTargetTransport -Hdc $hdc -Target $targetId) -ne 'usb') {
        throw 'ConnectTimeout verification requires a USB-connected physical PC'
    }

    $targetProcess = Start-SshFixture -ControlDirectory $targetControl `
        -StdoutPath $targetStdout -StderrPath $targetStderr -Port $TargetPort -DirectTarget 'none'
    $targetFixture = Wait-FixtureReady -Process $targetProcess -ControlDirectory $targetControl `
        -RequireCredentials
    $targetLinuxPid = $targetFixture.linuxPid
    $jumpProcess = Start-SshFixture -ControlDirectory $jumpControl `
        -StdoutPath $jumpStdout -StderrPath $jumpStderr -Port $JumpPort -DirectTarget 'stall'
    $jumpFixture = Wait-FixtureReady -Process $jumpProcess -ControlDirectory $jumpControl `
        -RequireCredentials
    $jumpLinuxPid = $jumpFixture.linuxPid
    $jumpStallProcess = Start-StallFixture -ControlDirectory $jumpStallControl `
        -StdoutPath $jumpStallStdout -StderrPath $jumpStallStderr -Port $JumpStallPort
    Wait-FixtureReady -Process $jumpStallProcess -ControlDirectory $jumpStallControl
    $targetStallProcess = Start-StallFixture -ControlDirectory $targetStallControl `
        -StdoutPath $targetStallStdout -StderrPath $targetStallStderr -Port $TargetStallPort
    Wait-FixtureReady -Process $targetStallProcess -ControlDirectory $targetStallControl

    $existingMappings = @(& $hdc -t $targetId fport ls 2>&1) -join "`n"
    foreach ($port in @($JumpPort, $TargetPort, $JumpStallPort, $TargetStallPort)) {
        if ($existingMappings -match "(?m)tcp:$port\s+tcp:$port\s+\[Reverse\]") {
            throw "HDC reverse mapping already exists for fixture port $port"
        }
        $mappingOutput = @(& $hdc -t $targetId rport "tcp:$port" "tcp:$port" 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $mappingOutput -notmatch 'Forwardport result:OK') {
            throw "Unable to create HDC reverse mapping for $port`: $mappingOutput"
        }
        $mappedPorts.Add($port)
    }

    Start-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $targetId
    $awakeLeaseActive = $true
    & (Join-Path $PSScriptRoot 'dev-pc.ps1') -Target $targetId -HapPath $selectedHapPath `
        -SkipBuild -NoLaunch
    if ($LASTEXITCODE -ne 0) { throw 'ConnectTimeout selected HAP deployment failed' }
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
    $start = Start-LeanTTYRegressionApp -Hdc $hdc -Target $targetId `
        -CredentialPath (Get-LeanTTYDeviceUnlockPasswordPath) -RepositoryRoot $repoRoot
    $appPid = $start.processId
    $script:ctAppPid = $appPid
    Wait-LeanTTYTerminalInputLayout -Hdc $hdc -Target $targetId `
        -LocalPath (Join-Path $EvidenceDirectory 'ready.json') -TimeoutSeconds 20 | Out-Null

    Enter-IdleCommandState
    foreach ($alias in $hostAliases) { Submit-Command -Command "host rm $alias" -Stage 'initial-cleanup' }
    foreach ($port in @($JumpPort, $TargetPort, $JumpStallPort, $TargetStallPort)) {
        Submit-Command -Command "ssh-keygen -R [127.0.0.1]:$port" -Stage 'initial-cleanup'
    }
    Submit-Command -Command (
        "host add __ltty_ct_direct password@127.0.0.1:$TargetStallPort --connect-timeout 1"
    )
    Submit-Command -Command (
        "host add __ltty_ct_jump_stall password@127.0.0.1:$JumpStallPort --connect-timeout 1"
    )
    Submit-Command -Command (
        "host add __ltty_ct_jump password@127.0.0.1:$JumpPort --connect-timeout 3"
    )
    Submit-Command -Command (
        "host add __ltty_ct_target_jump password@127.0.0.1:$TargetPort " +
            '-J __ltty_ct_jump --connect-timeout 1'
    )
    Submit-Command -Command "host add __ltty_ct_default password@127.0.0.1:$TargetPort"

    Clear-AppLogs
    $directWatch = [Diagnostics.Stopwatch]::StartNew()
    Submit-Command -Command 'ssh __ltty_ct_direct' -Stage 'direct-target-timeout'
    Wait-AppLog -Pattern 'native control event: error:target:connect:network' `
        -TimeoutSeconds 8 | Out-Null
    Wait-AppLog -Pattern 'SSH error: target:connection timed out after 1000 ms' | Out-Null
    $directWatch.Stop()
    Save-ScenarioEvidence -Name 'direct-target-timeout' -ExpectedLayer 'target' `
        -ExpectedEvent 'error:target:connect:network' -Stopwatch $directWatch

    Submit-Command -Command (
        "host set __ltty_ct_target_jump password@127.0.0.1:$TargetPort " +
            '-J __ltty_ct_jump_stall --connect-timeout 2'
    )
    Clear-AppLogs
    $jumpWatch = [Diagnostics.Stopwatch]::StartNew()
    Submit-Command -Command 'ssh __ltty_ct_target_jump' -Stage 'jump-handshake-timeout'
    Wait-AppLog -Pattern 'native control event: error:jump:connect:network' `
        -TimeoutSeconds 8 | Out-Null
    Wait-AppLog -Pattern 'SSH error: jump:connection timed out after 1000 ms' | Out-Null
    $jumpWatch.Stop()
    Save-ScenarioEvidence -Name 'jump-handshake-timeout' -ExpectedLayer 'jump' `
        -ExpectedEvent 'error:jump:connect:network' -Stopwatch $jumpWatch

    Submit-Command -Command (
        "host set __ltty_ct_target_jump password@127.0.0.1:$TargetPort " +
            '-J __ltty_ct_jump --connect-timeout 1'
    )
    Clear-AppLogs
    $proxyWatch = [Diagnostics.Stopwatch]::StartNew()
    Submit-Command -Command 'ssh __ltty_ct_target_jump' -Stage 'target-over-jump-timeout'
    Wait-AppLog -Pattern 'native control event: host_key_prompt:jump' | Out-Null
    Submit-InteractiveValue -Text 'yes'
    Wait-AppLog -Pattern 'native auth event kind=password, layer=jump' | Out-Null
    Submit-InteractiveValue -Text $jumpFixture.password
    Wait-AppLog -Pattern 'native control event: error:jump:tunnel:channel' `
        -TimeoutSeconds 8 | Out-Null
    Wait-AppLog -Pattern 'SSH error: jump:direct-tcpip timed out after 1000 ms' | Out-Null
    $proxyWatch.Stop()
    Save-ScenarioEvidence -Name 'target-over-jump-timeout' -ExpectedLayer 'target-over-jump' `
        -ExpectedEvent 'error:jump:tunnel:channel' -Stopwatch $proxyWatch

    Submit-Command -Command (
        "host set __ltty_ct_direct password@127.0.0.1:$TargetStallPort --connect-timeout 5"
    )
    Clear-AppLogs
    $cancelWatch = [Diagnostics.Stopwatch]::StartNew()
    Submit-Command -Command 'ssh __ltty_ct_direct' -Stage 'direct-timeout-cancel'
    Start-Sleep -Milliseconds 700
    Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $targetId
    Submit-Command -Command 'ssh -G __ltty_ct_default' -Stage 'cancel-recovery-probe'
    Assert-NoLateTimeout -Seconds 2
    $cancelWatch.Stop()
    Save-ScenarioEvidence -Name 'direct-timeout-cancelled' -ExpectedLayer 'none' `
        -ExpectedEvent 'Ctrl+C returned to idle without a late timeout' -Stopwatch $cancelWatch

    Clear-AppLogs
    $defaultWatch = [Diagnostics.Stopwatch]::StartNew()
    Submit-Command -Command 'ssh __ltty_ct_default' -Stage 'default-success-recovery'
    Wait-AppLog -Pattern 'native control event: host_key_prompt:target' | Out-Null
    Submit-InteractiveValue -Text 'yes'
    Wait-AppLog -Pattern 'native auth event kind=password, layer=target' | Out-Null
    Submit-InteractiveValue -Text $targetFixture.password
    Wait-AppLog -Pattern 'native control event: connected' | Out-Null
    Submit-InteractiveValue -Text 'ltty-input-check connecttimeoutrecovery'
    $fixtureStopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($fixtureStopwatch.Elapsed.TotalSeconds -lt 10) {
        if ((Read-SharedTextFile -Path $targetStderr) -match
            'input case=connecttimeoutrecovery result=matched') { break }
        Start-Sleep -Milliseconds 200
    }
    if ($fixtureStopwatch.Elapsed.TotalSeconds -ge 10) {
        throw 'Default connection did not reach the controlled target shell'
    }
    Submit-InteractiveValue -Text 'ltty-exit'
    Wait-AppLog -Pattern 'SSH closed, exitCode=0' | Out-Null
    $defaultWatch.Stop()
    Save-ScenarioEvidence -Name 'default-success-recovery' -ExpectedLayer 'target' `
        -ExpectedEvent 'CONNECTED, fixture input matched, clean exit' -Stopwatch $defaultWatch

    foreach ($alias in $hostAliases) { Submit-Command -Command "host rm $alias" -Stage 'final-cleanup' }
    foreach ($port in @($JumpPort, $TargetPort, $JumpStallPort, $TargetStallPort)) {
        Submit-Command -Command "ssh-keygen -R [127.0.0.1]:$port" -Stage 'final-cleanup'
    }
    $deviceDataCleaned = $true

    $result = 'passed'
    $summary = [ordered]@{
        schemaVersion = 1
        capturedAt = (Get-Date).ToString('o')
        result = $result
        gate = '1.5-connect-timeout-physical-pc'
        target = $targetId
        transport = 'usb'
        hapSha256 = (Get-FileHash -LiteralPath $selectedHapPath -Algorithm SHA256).Hash.ToLowerInvariant()
        scenarios = $scenarioEvidence
        cleanup = 'Host aliases, known_hosts entries, HDC mappings, sockets, and credentials removed'
        automation = Get-LeanTTYDeviceCommandAutomationSummary -Observations $commandObservations `
            -BusinessVerdict 'passed' `
            -BusinessPostcondition 'layered-timeouts-cancellation-and-default-recovery-observed'
    }
    $summaryPath = Join-Path $EvidenceDirectory 'summary.json'
    [IO.File]::WriteAllText($summaryPath, (ConvertTo-Json $summary -Depth 8) + "`n")
    Write-Host "CONNECT TIMEOUT PC EVIDENCE: $summaryPath" -ForegroundColor Green
} catch {
    $failure = $_.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace($appPid) -and -not $deviceDataCleaned) {
        try {
            $failureLogs = Get-LeanTTYAppLogs -Hdc $script:ctHdc -Target $script:ctTarget `
                -ProcessId $appPid
            [IO.File]::WriteAllText(
                (Join-Path $EvidenceDirectory 'device-app-at-failure.log'),
                $failureLogs + "`n"
            )
            if ($failureLogs -match 'native control event: connected' -and
                $failureLogs -notmatch 'SSH closed, exitCode=') {
                Submit-InteractiveValue -Text 'ltty-exit'
                Wait-AppLog -Pattern 'SSH closed, exitCode=0' -TimeoutSeconds 8 | Out-Null
            }
        } catch {}
    }
    throw
} finally {
    if (-not [string]::IsNullOrWhiteSpace($appPid) -and -not $deviceDataCleaned) {
        foreach ($alias in $hostAliases) {
            try { Submit-Command -Command "host rm $alias" -Stage 'finally-cleanup' } catch {}
        }
        foreach ($port in @($JumpPort, $TargetPort, $JumpStallPort, $TargetStallPort)) {
            try {
                Submit-Command -Command "ssh-keygen -R [127.0.0.1]:$port" -Stage 'finally-cleanup'
            } catch {}
        }
        try {
            $logs = Get-LeanTTYAppLogs -Hdc $script:ctHdc -Target $script:ctTarget -ProcessId $appPid
            [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'device-app-final.log'), $logs + "`n")
        } catch {}
    }
    foreach ($port in @($mappedPorts)) {
        try { & $script:ctHdc -t $script:ctTarget fport rm "tcp:$port" "tcp:$port" 2>$null | Out-Null } catch {}
    }
    try { Stop-LocalFixture -Process $targetStallProcess } catch {}
    try { Stop-LocalFixture -Process $jumpStallProcess } catch {}
    try { Stop-SshFixture -Process $jumpProcess -LinuxPid $jumpLinuxPid } catch {}
    try { Stop-SshFixture -Process $targetProcess -LinuxPid $targetLinuxPid } catch {}
    foreach ($fixtureLog in @(
        @{ Source = $jumpStdout; Name = 'jump-fixture-stdout.log' },
        @{ Source = $jumpStderr; Name = 'jump-fixture-stderr.log' },
        @{ Source = $targetStdout; Name = 'target-fixture-stdout.log' },
        @{ Source = $targetStderr; Name = 'target-fixture-stderr.log' },
        @{ Source = $jumpStallStdout; Name = 'jump-stall-stdout.log' },
        @{ Source = $jumpStallStderr; Name = 'jump-stall-stderr.log' },
        @{ Source = $targetStallStdout; Name = 'target-stall-stdout.log' },
        @{ Source = $targetStallStderr; Name = 'target-stall-stderr.log' }
    )) {
        try {
            if (Test-Path -LiteralPath $fixtureLog.Source -PathType Leaf) {
                Copy-Item -LiteralPath $fixtureLog.Source `
                    -Destination (Join-Path $EvidenceDirectory $fixtureLog.Name) -Force
            }
        } catch {}
    }
    if ($awakeLeaseActive) {
        Stop-LeanTTYDeviceAwakeLease -Hdc $script:ctHdc -Target $script:ctTarget
    }
    try {
        if (Test-Path -LiteralPath $fixtureRoot) {
            Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
        }
    } catch {
        Write-Warning "ConnectTimeout temporary fixture cleanup was incomplete: $($_.Exception.Message)"
    }
    if ($result -ne 'passed' -and -not [string]::IsNullOrWhiteSpace($failure)) {
        Write-Warning "ConnectTimeout physical-PC verification failed: $failure"
    }
}
