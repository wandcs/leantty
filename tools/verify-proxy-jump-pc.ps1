<#
.SYNOPSIS
  Verify first-use and known-host password ProxyJump paths on a physical HarmonyOS PC.
.DESCRIPTION
  Starts two repository-only temporary SSH fixtures in WSL. The jump fixture
  permits direct-tcpip only to the target fixture. It deploys the current
  signed development HAP, drives the real LeanTTY command/authentication path,
  captures bounded evidence, and removes the HDC mapping, temporary credentials
  and known_hosts entries.
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [ValidateRange(1024, 65535)][int]$JumpPort = 22222,
    [ValidateRange(1024, 65535)][int]$TargetPort = 22223,
    [string]$EvidenceDirectory = '',
    [string]$Distribution = $env:LEANTTY_WSL_DISTRO,
    [switch]$IncludeHostKeyRotation,
    [ValidateSet('Target', 'Jump', 'Both')][string]$HostKeyRotationLayer = 'Both'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')
. (Join-Path $PSScriptRoot 'rust-wsl.ps1')

if ($JumpPort -eq $TargetPort) { throw 'Jump and target fixture ports must differ' }
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + `
    [IO.Path]::DirectorySeparatorChar
$fixtureRoot = Join-Path $temporaryRoot ('leantty-proxy-jump-' + [guid]::NewGuid().ToString('N'))
$fixtureRoot = [IO.Path]::GetFullPath($fixtureRoot)
if (-not $fixtureRoot.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ProxyJump fixture root escaped the system temporary directory'
}
$targetControl = Join-Path $fixtureRoot 'target-control'
$jumpControl = Join-Path $fixtureRoot 'jump-control'
$targetStdout = Join-Path $fixtureRoot 'target-stdout.log'
$targetStderr = Join-Path $fixtureRoot 'target-stderr.log'
$jumpStdout = Join-Path $fixtureRoot 'jump-stdout.log'
$jumpStderr = Join-Path $fixtureRoot 'jump-stderr.log'
$targetProcess = $null
$jumpProcess = $null
$targetLinuxPid = 0
$jumpLinuxPid = 0
$mappingActive = $false
$awakeLeaseActive = $false
$appPid = ''
$result = 'failed'
$failure = ''

function Start-ProxyFixture {
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
        '-ListenAddress', "0.0.0.0:$Port",
        '-RunSeconds', ($IncludeHostKeyRotation ? '600' : '240'),
        '-ControlDirectory', $ControlDirectory,
        '-DirectTcpipTarget', $DirectTarget
    )
    if (-not [string]::IsNullOrWhiteSpace($Distribution)) {
        $arguments += @('-Distribution', $Distribution)
    }
    return Start-Process `
        -FilePath (Get-Process -Id $PID).Path `
        -ArgumentList $arguments `
        -RedirectStandardOutput $StdoutPath `
        -RedirectStandardError $StderrPath `
        -WindowStyle Hidden `
        -PassThru
}

function Wait-ProxyFixture {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$ControlDirectory
    )
    $readyPath = Join-Path $ControlDirectory 'fixture-ready'
    $credentialsPath = Join-Path $ControlDirectory 'server-credentials'
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 45) {
        $Process.Refresh()
        if ($Process.HasExited) {
            throw "SSH fixture launcher exited before readiness (exit=$($Process.ExitCode))"
        }
        if ((Test-Path -LiteralPath $readyPath -PathType Leaf) -and
            (Test-Path -LiteralPath $credentialsPath -PathType Leaf)) {
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
        Start-Sleep -Milliseconds 200
    }
    throw 'Timed out waiting for an SSH fixture'
}

function Stop-ProxyFixture {
    param(
        [Diagnostics.Process]$Process,
        [int]$LinuxPid
    )
    if ($LinuxPid -gt 0) {
        $wslPrefix = Get-LeanTTYWslPrefix -Distribution $Distribution
        & wsl.exe @wslPrefix --exec kill -TERM $LinuxPid 2>$null
    }
    if ($null -ne $Process -and -not $Process.HasExited) {
        Wait-Process -Id $Process.Id -Timeout 10 -ErrorAction SilentlyContinue
        $Process.Refresh()
        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

function Wait-ProxyLog {
    param([Parameter(Mandatory = $true)][string]$Pattern, [int]$TimeoutSeconds = 15)
    Wait-ProxyLogText -Pattern $Pattern -TimeoutSeconds $TimeoutSeconds | Out-Null
}

function Wait-ProxyLogText {
    param([Parameter(Mandatory = $true)][string]$Pattern, [int]$TimeoutSeconds = 15)
    return Wait-LeanTTYAppLog `
        -Hdc $script:proxyHdc `
        -Target $script:proxyTarget `
        -ProcessId $script:proxyAppPid `
        -Pattern $Pattern `
        -TimeoutSeconds $TimeoutSeconds
}

function Submit-SecretOrDecision {
    param([Parameter(Mandatory = $true)][string]$Text)
    Focus-ProxyCommandInput
    Invoke-LeanTTYDeviceText -Hdc $script:proxyHdc -Target $script:proxyTarget -Text $Text
    Invoke-LeanTTYDeviceKey -Hdc $script:proxyHdc -Target $script:proxyTarget -KeyCode 2054
}

function Focus-ProxyCommandInput {
    $layoutPath = Join-Path $EvidenceDirectory 'command-focus.json'
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $layout = Get-LeanTTYDeviceLayout `
            -Hdc $script:proxyHdc `
            -Target $script:proxyTarget `
            -LocalPath $layoutPath
        $nodes = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
        if ($nodes.Count -eq 1) {
            if ([string]$nodes[0].attributes.focused -eq 'true') {
                return
            }
            Set-LeanTTYTerminalInputFocus `
                -Hdc $script:proxyHdc `
                -Target $script:proxyTarget `
                -InputNode $nodes[0] `
                -LocalPath $layoutPath `
                -TimeoutSeconds 10 | Out-Null
            return
        }
        Start-Sleep -Milliseconds 200
    } while ($stopwatch.Elapsed.TotalSeconds -lt 10)
    throw 'Unable to identify the active LeanTTY command input'
}

function Submit-ProxyCommand {
    param([Parameter(Mandatory = $true)][string]$Command)
    $submittedPattern =
        'ACCEPTANCE_INPUT_SUBMIT.*kind=command,input=' + [regex]::Escape($Command)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Invoke-LeanTTYDeviceCtrlC -Hdc $script:proxyHdc -Target $script:proxyTarget
        Focus-ProxyCommandInput
        Clear-LeanTTYAppLogs -Hdc $script:proxyHdc -Target $script:proxyTarget
        Submit-LeanTTYDeviceCommand `
            -Hdc $script:proxyHdc `
            -Target $script:proxyTarget `
            -Command $Command
        try {
            Wait-ProxyLog -Pattern $submittedPattern -TimeoutSeconds 10
            return
        } catch {
            if ($attempt -ge 3) {
                throw 'Device did not submit the exact ProxyJump verification command'
            }
        }
    }
}

function Submit-HostKeyDecisionUntilResult {
    param([Parameter(Mandatory = $true)][string]$ExpectedPattern)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Submit-SecretOrDecision -Text 'yes'
        try {
            Wait-ProxyLog -Pattern $ExpectedPattern -TimeoutSeconds 6
            return
        } catch {
            if ($attempt -ge 3) {
                throw '[harness] Host-key confirmation was not accepted after three attempts'
            }
        }
    }
}

function Submit-JumpPasswordUntilResult {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$JumpPassword,
        [Parameter(Mandatory = $true)][string]$ExpectedPattern,
        [switch]$CurrentPrompt
    )
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if ($attempt -gt 1 -or -not $CurrentPrompt) {
            Submit-ProxyCommand -Command $Command
            Wait-ProxyLog -Pattern 'native auth event kind=password, layer=jump'
        }
        Submit-SecretOrDecision -Text $JumpPassword
        $logs = Wait-ProxyLogText -Pattern (
            $ExpectedPattern + '|rust event: AUTH:jump:authentication was rejected'
        )
        if ($logs -match $ExpectedPattern) { return }
    }
    throw '[harness] Jump password injection was rejected after three connection attempts'
}

function Complete-KnownHostProxyConnection {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$JumpPassword,
        [Parameter(Mandatory = $true)][string]$TargetPassword
    )
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Submit-ProxyCommand -Command $Command
        Wait-ProxyLog -Pattern 'native auth event kind=password, layer=jump'
        Submit-SecretOrDecision -Text $JumpPassword
        $jumpLogs = Wait-ProxyLogText -Pattern (
            'native auth event kind=password, layer=target|' +
                'rust event: AUTH:jump:authentication was rejected'
        )
        if ($jumpLogs -notmatch 'native auth event kind=password, layer=target') { continue }
        Submit-SecretOrDecision -Text $TargetPassword
        $targetLogs = Wait-ProxyLogText -Pattern (
            'rust event: CONNECTED|rust event: AUTH:target:authentication was rejected'
        )
        if ($targetLogs -match 'rust event: CONNECTED') { return }
    }
    throw '[harness] ProxyJump password injection was rejected after three connection attempts'
}

function Submit-CurrentTargetPasswordWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$JumpPassword,
        [Parameter(Mandatory = $true)][string]$TargetPassword
    )
    Submit-SecretOrDecision -Text $TargetPassword
    $logs = Wait-ProxyLogText -Pattern (
        'rust event: CONNECTED|rust event: AUTH:target:authentication was rejected'
    )
    if ($logs -match 'rust event: CONNECTED') { return }
    Complete-KnownHostProxyConnection `
        -Command $Command `
        -JumpPassword $JumpPassword `
        -TargetPassword $TargetPassword
}

New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $repoRoot (
        'build\verification\proxy-jump-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    )
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null

try {
    $hdc = Resolve-Hdc
    $targetId = Resolve-LeanTTYRegressionTarget -Hdc $hdc -Target $Target
    $script:proxyHdc = $hdc
    $script:proxyTarget = $targetId
    if ((Get-HdcTargetTransport -Hdc $hdc -Target $targetId) -ne 'usb') {
        throw 'ProxyJump verification requires a USB-connected physical PC'
    }

    $targetProcess = Start-ProxyFixture `
        -ControlDirectory $targetControl `
        -StdoutPath $targetStdout `
        -StderrPath $targetStderr `
        -Port $TargetPort `
        -DirectTarget 'none'
    $targetFixture = Wait-ProxyFixture -Process $targetProcess -ControlDirectory $targetControl
    $targetLinuxPid = $targetFixture.linuxPid

    $jumpProcess = Start-ProxyFixture `
        -ControlDirectory $jumpControl `
        -StdoutPath $jumpStdout `
        -StderrPath $jumpStderr `
        -Port $JumpPort `
        -DirectTarget "127.0.0.1:$TargetPort"
    $jumpFixture = Wait-ProxyFixture -Process $jumpProcess -ControlDirectory $jumpControl
    $jumpLinuxPid = $jumpFixture.linuxPid

    $existingMappings = @(& $hdc -t $targetId fport ls 2>&1) -join "`n"
    if ($existingMappings -match "(?m)tcp:$JumpPort\s+tcp:$JumpPort\s+\[Reverse\]") {
        throw "HDC reverse mapping already exists for fixture port $JumpPort"
    }
    $mappingOutput = @(& $hdc -t $targetId rport "tcp:$JumpPort" "tcp:$JumpPort" 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $mappingOutput -notmatch 'Forwardport result:OK') {
        throw "Unable to create HDC reverse mapping: $mappingOutput"
    }
    $mappingActive = $true
    Start-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $targetId
    $awakeLeaseActive = $true

    $hapPath = Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
    & (Join-Path $PSScriptRoot 'dev-pc.ps1') `
        -Target $targetId `
        -HapPath $hapPath `
        -SkipBuild `
        -NoLaunch
    if ($LASTEXITCODE -ne 0) { throw 'ProxyJump development HAP deployment failed' }
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
    $start = Start-LeanTTYRegressionApp `
        -Hdc $hdc `
        -Target $targetId `
        -CredentialPath (Get-LeanTTYDeviceUnlockPasswordPath) `
        -RepositoryRoot $repoRoot
    $appPid = $start.processId
    $script:proxyAppPid = $appPid
    Wait-LeanTTYTerminalInputLayout `
        -Hdc $hdc `
        -Target $targetId `
        -LocalPath (Join-Path $EvidenceDirectory 'ready.json') `
        -TimeoutSeconds 20 | Out-Null

    Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$JumpPort"
    Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$TargetPort"
    $proxyCommand = "ssh -p $TargetPort -J password@127.0.0.1:$JumpPort password@127.0.0.1"
    Submit-ProxyCommand -Command $proxyCommand

    Wait-ProxyLog -Pattern 'rust event: HOST_KEY_PROMPT:jump\t'
    Submit-HostKeyDecisionUntilResult `
        -ExpectedPattern 'native auth event kind=password, layer=jump'
    Submit-JumpPasswordUntilResult `
        -Command $proxyCommand `
        -JumpPassword $jumpFixture.password `
        -ExpectedPattern 'rust event: HOST_KEY_PROMPT:target\t' `
        -CurrentPrompt
    Submit-HostKeyDecisionUntilResult `
        -ExpectedPattern 'native auth event kind=password, layer=target'
    Submit-CurrentTargetPasswordWithRetry `
        -Command $proxyCommand `
        -JumpPassword $jumpFixture.password `
        -TargetPassword $targetFixture.password

    Save-LeanTTYDeviceScreenshot `
        -Hdc $hdc `
        -Target $targetId `
        -LocalPath (Join-Path $EvidenceDirectory 'connected.png')
    Submit-SecretOrDecision -Text 'ltty-exit'
    Wait-ProxyLog -Pattern 'SSH closed, exitCode=0'

    if (-not $IncludeHostKeyRotation) {
        Complete-KnownHostProxyConnection `
            -Command $proxyCommand `
            -JumpPassword $jumpFixture.password `
            -TargetPassword $targetFixture.password
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc `
            -Target $targetId `
            -LocalPath (Join-Path $EvidenceDirectory 'known-hosts-reconnect.png')
        Submit-SecretOrDecision -Text 'ltty-exit'
        Wait-ProxyLog -Pattern 'SSH closed, exitCode=0'
    }

    if ($IncludeHostKeyRotation -and $HostKeyRotationLayer -in @('Target', 'Both')) {
        Stop-ProxyFixture -Process $targetProcess -LinuxPid $targetLinuxPid
        $targetProcess = $null
        $targetLinuxPid = 0
        $targetProcess = Start-ProxyFixture `
            -ControlDirectory $targetControl `
            -StdoutPath $targetStdout `
            -StderrPath $targetStderr `
            -Port $TargetPort `
            -DirectTarget 'none'
        $targetFixture = Wait-ProxyFixture -Process $targetProcess -ControlDirectory $targetControl
        $targetLinuxPid = $targetFixture.linuxPid

        Submit-ProxyCommand -Command $proxyCommand
        Wait-ProxyLog -Pattern 'native auth event kind=password, layer=jump'
        Submit-JumpPasswordUntilResult `
            -Command $proxyCommand `
            -JumpPassword $jumpFixture.password `
            -ExpectedPattern 'rust event: HOST_KEY_CHANGED:target\t' `
            -CurrentPrompt
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc `
            -Target $targetId `
            -LocalPath (Join-Path $EvidenceDirectory 'target-host-key-changed.png')
        Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$TargetPort"
        Submit-ProxyCommand -Command $proxyCommand
        Wait-ProxyLog -Pattern 'native auth event kind=password, layer=jump'
        Submit-JumpPasswordUntilResult `
            -Command $proxyCommand `
            -JumpPassword $jumpFixture.password `
            -ExpectedPattern 'rust event: HOST_KEY_PROMPT:target\t' `
            -CurrentPrompt
        Submit-HostKeyDecisionUntilResult `
            -ExpectedPattern 'native auth event kind=password, layer=target'
        Submit-CurrentTargetPasswordWithRetry `
            -Command $proxyCommand `
            -JumpPassword $jumpFixture.password `
            -TargetPassword $targetFixture.password
        Submit-SecretOrDecision -Text 'ltty-exit'
        Wait-ProxyLog -Pattern 'SSH closed, exitCode=0'
    }

    if ($IncludeHostKeyRotation -and $HostKeyRotationLayer -in @('Jump', 'Both')) {
        Stop-ProxyFixture -Process $jumpProcess -LinuxPid $jumpLinuxPid
        $jumpProcess = $null
        $jumpLinuxPid = 0
        $jumpProcess = Start-ProxyFixture `
            -ControlDirectory $jumpControl `
            -StdoutPath $jumpStdout `
            -StderrPath $jumpStderr `
            -Port $JumpPort `
            -DirectTarget "127.0.0.1:$TargetPort"
        $jumpFixture = Wait-ProxyFixture -Process $jumpProcess -ControlDirectory $jumpControl
        $jumpLinuxPid = $jumpFixture.linuxPid

        Submit-ProxyCommand -Command $proxyCommand
        Wait-ProxyLog -Pattern 'rust event: HOST_KEY_CHANGED:jump\t'
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc `
            -Target $targetId `
            -LocalPath (Join-Path $EvidenceDirectory 'jump-host-key-changed.png')
        Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$JumpPort"
        Submit-ProxyCommand -Command $proxyCommand
        Wait-ProxyLog -Pattern 'rust event: HOST_KEY_PROMPT:jump\t'
        Submit-HostKeyDecisionUntilResult `
            -ExpectedPattern 'native auth event kind=password, layer=jump'
        Submit-JumpPasswordUntilResult `
            -Command $proxyCommand `
            -JumpPassword $jumpFixture.password `
            -ExpectedPattern 'native auth event kind=password, layer=target' `
            -CurrentPrompt
        Submit-CurrentTargetPasswordWithRetry `
            -Command $proxyCommand `
            -JumpPassword $jumpFixture.password `
            -TargetPassword $targetFixture.password
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc `
            -Target $targetId `
            -LocalPath (Join-Path $EvidenceDirectory 'host-key-rotation-recovered.png')
        Submit-SecretOrDecision -Text 'ltty-exit'
        Wait-ProxyLog -Pattern 'SSH closed, exitCode=0'
    }

    Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$JumpPort"
    Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$TargetPort"

    $result = 'passed'
    $summary = [ordered]@{
        schemaVersion = 1
        capturedAt = (Get-Date).ToString('o')
        result = $result
        target = $targetId
        transport = 'usb'
        jumpPort = $JumpPort
        targetPort = $TargetPort
        authentication = 'password-per-layer-with-distinct-temporary-secrets'
        hostKeyVerification = if ($IncludeHostKeyRotation) {
            'first-use-confirmed-and-' + $HostKeyRotationLayer.ToLowerInvariant() +
                '-host-key-rotation-recovered'
        } else {
            'first-use-confirmed-and-known-match-reused-independently-per-layer'
        }
        knownHostReconnect = -not [bool]$IncludeHostKeyRotation
        targetHostKeyRotationRecovered = [bool]$IncludeHostKeyRotation -and
            $HostKeyRotationLayer -in @('Target', 'Both')
        jumpHostKeyRotationRecovered = [bool]$IncludeHostKeyRotation -and
            $HostKeyRotationLayer -in @('Jump', 'Both')
        targetShellOpened = $true
        targetShellClosedCleanly = $true
        hapSha256 = (Get-FileHash -LiteralPath $hapPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $summaryPath = Join-Path $EvidenceDirectory 'summary.json'
    [IO.File]::WriteAllText($summaryPath, (ConvertTo-Json $summary -Depth 5) + "`n")
    Write-Host "PROXYJUMP PC EVIDENCE: $summaryPath" -ForegroundColor Green
} catch {
    $failure = $_.Exception.Message
    throw
} finally {
    if ($mappingActive) {
        & $script:proxyHdc -t $script:proxyTarget fport rm "tcp:$JumpPort" "tcp:$JumpPort" 2>$null | Out-Null
        $mappingActive = $false
    }
    try { Stop-ProxyFixture -Process $jumpProcess -LinuxPid $jumpLinuxPid } catch {}
    try { Stop-ProxyFixture -Process $targetProcess -LinuxPid $targetLinuxPid } catch {}
    if ($awakeLeaseActive) {
        Stop-LeanTTYDeviceAwakeLease -Hdc $script:proxyHdc -Target $script:proxyTarget
    }
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
    $jumpFixture = $null
    $targetFixture = $null
    if ($result -ne 'passed' -and -not [string]::IsNullOrWhiteSpace($failure)) {
        Write-Warning "ProxyJump physical-PC verification failed: $failure"
    }
}
