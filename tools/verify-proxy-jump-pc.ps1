<#
.SYNOPSIS
  Verify password ProxyJump success, host-key rotation and layered authentication failures on a physical HarmonyOS PC.
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
    [ValidateRange(1024, 65535)][int]$SecondJumpPort = 22224,
    [ValidateRange(1024, 65535)][int]$SecondTargetPort = 22225,
    [string]$EvidenceDirectory = '',
    [string]$Distribution = $env:LEANTTY_WSL_DISTRO,
    [switch]$IncludeHostKeyRotation,
    [ValidateSet('Target', 'Jump', 'Both')][string]$HostKeyRotationLayer = 'Both',
    [switch]$ParallelPanes,
    [ValidateSet(
        'None', 'JumpAuthentication', 'TargetAuthentication',
        'DirectTcpipRejected', 'TargetUnreachable', 'DirectTcpipTimeout',
        'CancelAtTargetAuthentication', 'TargetDisconnected', 'JumpDisconnected'
    )]
    [string]$FailureScenario = 'None'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')
. (Join-Path $PSScriptRoot 'rust-wsl.ps1')

$uniqueFixturePorts = @(
    @($JumpPort, $TargetPort, $SecondJumpPort, $SecondTargetPort) | Select-Object -Unique
)
if ($uniqueFixturePorts.Count -ne 4) {
    throw 'All ProxyJump fixture ports must differ'
}
if ($IncludeHostKeyRotation -and $FailureScenario -ne 'None') {
    throw 'Host-key rotation and expected-failure scenarios must run independently'
}
if ($ParallelPanes -and ($IncludeHostKeyRotation -or $FailureScenario -ne 'None')) {
    throw 'Parallel Pane verification must run independently'
}
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
$secondTargetControl = Join-Path $fixtureRoot 'second-target-control'
$secondJumpControl = Join-Path $fixtureRoot 'second-jump-control'
$secondTargetStdout = Join-Path $fixtureRoot 'second-target-stdout.log'
$secondTargetStderr = Join-Path $fixtureRoot 'second-target-stderr.log'
$secondJumpStdout = Join-Path $fixtureRoot 'second-jump-stdout.log'
$secondJumpStderr = Join-Path $fixtureRoot 'second-jump-stderr.log'
$targetProcess = $null
$jumpProcess = $null
$targetLinuxPid = 0
$jumpLinuxPid = 0
$secondTargetProcess = $null
$secondJumpProcess = $null
$secondTargetLinuxPid = 0
$secondJumpLinuxPid = 0
$mappingActive = $false
$secondMappingActive = $false
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
        '-RunSeconds', (($IncludeHostKeyRotation -or $ParallelPanes) ? '600' : '240'),
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

function Read-ProxyFixtureLog {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally {
        $stream.Dispose()
    }
}

function Wait-ProxyFixtureLog {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [int]$TimeoutSeconds = 15
    )
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ((Read-ProxyFixtureLog -Path $Path) -match $Pattern) { return }
        Start-Sleep -Milliseconds 200
    }
    throw "Timed out waiting for SSH fixture evidence: $Pattern"
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
        $focusedNodes = @($nodes | Where-Object {
            [string]$_.attributes.focused -eq 'true'
        })
        $inputNode = if ($focusedNodes.Count -eq 1) {
            $focusedNodes[0]
        } elseif ($nodes.Count -eq 1) {
            $nodes[0]
        } else {
            $null
        }
        if ($null -ne $inputNode) {
            if ([string]$inputNode.attributes.focused -eq 'true') {
                return
            }
            Set-LeanTTYTerminalInputFocus `
                -Hdc $script:proxyHdc `
                -Target $script:proxyTarget `
                -InputNode $inputNode `
                -LocalPath $layoutPath `
                -TimeoutSeconds 10 | Out-Null
            return
        }
        Start-Sleep -Milliseconds 200
    } while ($stopwatch.Elapsed.TotalSeconds -lt 10)
    throw 'Unable to identify the active LeanTTY command input'
}

function Invoke-ProxySplitShortcut {
    & $script:proxyHdc -t $script:proxyTarget shell (
        'uinput -K -d 2072 -d 2047 -d 2020 -u 2020 -u 2047 -u 2072'
    ) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to invoke LeanTTY split shortcut' }
}

function Wait-ProxyPaneCount {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 2)][int]$Count,
        [Parameter(Mandatory = $true)][string]$LayoutName
    )
    return Wait-LeanTTYTerminalInputCount `
        -Hdc $script:proxyHdc `
        -Target $script:proxyTarget `
        -LocalPath (Join-Path $EvidenceDirectory $LayoutName) `
        -Count $Count `
        -TimeoutSeconds 20
}

function Focus-ProxyPane {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('left', 'right')][string]$Side,
        [Parameter(Mandatory = $true)][string]$LayoutName
    )
    $path = Join-Path $EvidenceDirectory $LayoutName
    $layout = Wait-ProxyPaneCount -Count 2 -LayoutName $LayoutName
    $nodes = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
    $index = if ($Side -eq 'left') { 0 } else { 1 }
    $center = Get-LeanTTYBoundsCenter -Bounds ([string]$nodes[$index].attributes.bounds)
    & $script:proxyHdc -t $script:proxyTarget shell `
        "uitest uiInput click $($center.x) $($center.y)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to focus the $Side ProxyJump Pane" }

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $layout = Get-LeanTTYDeviceLayout `
            -Hdc $script:proxyHdc `
            -Target $script:proxyTarget `
            -LocalPath $path
        $nodes = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
        if ($nodes.Count -eq 2 -and
            [string]$nodes[$index].attributes.focused -eq 'true' -and
            [string]$nodes[1 - $index].attributes.focused -ne 'true') {
            return
        }
        Start-Sleep -Milliseconds 200
    } while ($stopwatch.Elapsed.TotalSeconds -lt 10)
    throw "Timed out focusing the $Side ProxyJump Pane"
}

function Submit-ConnectedProxyInput {
    param([Parameter(Mandatory = $true)][string]$Text)
    Focus-ProxyCommandInput
    Invoke-LeanTTYDeviceText `
        -Hdc $script:proxyHdc `
        -Target $script:proxyTarget `
        -Text $Text
    Invoke-LeanTTYDeviceKey `
        -Hdc $script:proxyHdc `
        -Target $script:proxyTarget `
        -KeyCode 2054
}

function Submit-ConnectedProxyInputUntilFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$FixtureLog,
        [Parameter(Mandatory = $true)][string]$ExpectedPattern
    )
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Submit-ConnectedProxyInput -Text $Text
        try {
            Wait-ProxyFixtureLog `
                -Path $FixtureLog `
                -Pattern $ExpectedPattern `
                -TimeoutSeconds 8
            return
        } catch {
            if ($attempt -ge 3) { throw }
            Invoke-LeanTTYDeviceCtrlC `
                -Hdc $script:proxyHdc `
                -Target $script:proxyTarget
        }
    }
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
        [int]$TimeoutSeconds = 15,
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
        ) -TimeoutSeconds $TimeoutSeconds
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

function Assert-ProxyCommandInputRecovered {
    param([Parameter(Mandatory = $true)][string]$ScreenshotName)
    $idleProbe = "ssh -G -J password@127.0.0.1:$JumpPort password@127.0.0.1"
    Submit-ProxyCommand -Command $idleProbe
    try {
        Wait-ProxyLog -Pattern 'rust event: CONNECTED' -TimeoutSeconds 2
        throw 'Finished ProxyJump work emitted a late CONNECTED event'
    } catch {
        if ($_.Exception.Message -eq 'Finished ProxyJump work emitted a late CONNECTED event') {
            throw
        }
    }
    Save-LeanTTYDeviceScreenshot `
        -Hdc $script:proxyHdc `
        -Target $script:proxyTarget `
        -LocalPath (Join-Path $EvidenceDirectory $ScreenshotName)
}

function Write-ProxySummary {
    param(
        [Parameter(Mandatory = $true)][string]$Scenario,
        [Parameter(Mandatory = $true)][string]$Authentication,
        [Parameter(Mandatory = $true)][string]$HostKeyVerification,
        [Parameter(Mandatory = $true)][bool]$KnownHostReconnect,
        [Parameter(Mandatory = $true)][bool]$TargetHostKeyRotationRecovered,
        [Parameter(Mandatory = $true)][bool]$JumpHostKeyRotationRecovered,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExpectedFailureLayer,
        [Parameter(Mandatory = $true)][bool]$TargetShellOpened,
        [Parameter(Mandatory = $true)][bool]$TargetShellClosedCleanly,
        [string]$Lifecycle = ''
    )
    $script:result = 'passed'
    $summary = [ordered]@{
        schemaVersion = 1
        capturedAt = (Get-Date).ToString('o')
        result = $script:result
        scenario = $Scenario
        target = $script:proxyTarget
        transport = 'usb'
        jumpPort = $JumpPort
        targetPort = $TargetPort
        authentication = $Authentication
        hostKeyVerification = $HostKeyVerification
        knownHostReconnect = $KnownHostReconnect
        targetHostKeyRotationRecovered = $TargetHostKeyRotationRecovered
        jumpHostKeyRotationRecovered = $JumpHostKeyRotationRecovered
        expectedFailureLayer = $ExpectedFailureLayer
        targetShellOpened = $TargetShellOpened
        targetShellClosedCleanly = $TargetShellClosedCleanly
        lifecycle = $Lifecycle
        hapSha256 = (Get-FileHash -LiteralPath $script:proxyHapPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $summaryPath = Join-Path $EvidenceDirectory 'summary.json'
    [IO.File]::WriteAllText($summaryPath, (ConvertTo-Json $summary -Depth 5) + "`n")
    Write-Host "PROXYJUMP PC EVIDENCE: $summaryPath" -ForegroundColor Green
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

    $jumpDirectTarget = switch ($FailureScenario) {
        'DirectTcpipRejected' { 'none' }
        'TargetUnreachable' { 'connect-failed' }
        'DirectTcpipTimeout' { 'stall' }
        default { "127.0.0.1:$TargetPort" }
    }
    $jumpProcess = Start-ProxyFixture `
        -ControlDirectory $jumpControl `
        -StdoutPath $jumpStdout `
        -StderrPath $jumpStderr `
        -Port $JumpPort `
        -DirectTarget $jumpDirectTarget
    $jumpFixture = Wait-ProxyFixture -Process $jumpProcess -ControlDirectory $jumpControl
    $jumpLinuxPid = $jumpFixture.linuxPid

    if ($ParallelPanes) {
        $secondTargetProcess = Start-ProxyFixture `
            -ControlDirectory $secondTargetControl `
            -StdoutPath $secondTargetStdout `
            -StderrPath $secondTargetStderr `
            -Port $SecondTargetPort `
            -DirectTarget 'none'
        $secondTargetFixture = Wait-ProxyFixture `
            -Process $secondTargetProcess `
            -ControlDirectory $secondTargetControl
        $secondTargetLinuxPid = $secondTargetFixture.linuxPid

        $secondJumpProcess = Start-ProxyFixture `
            -ControlDirectory $secondJumpControl `
            -StdoutPath $secondJumpStdout `
            -StderrPath $secondJumpStderr `
            -Port $SecondJumpPort `
            -DirectTarget "127.0.0.1:$SecondTargetPort"
        $secondJumpFixture = Wait-ProxyFixture `
            -Process $secondJumpProcess `
            -ControlDirectory $secondJumpControl
        $secondJumpLinuxPid = $secondJumpFixture.linuxPid

        $parallelPasswords = @(
            $targetFixture.password,
            $jumpFixture.password,
            $secondTargetFixture.password,
            $secondJumpFixture.password
        )
        if (@($parallelPasswords | Select-Object -Unique).Count -ne 4) {
            throw 'Parallel ProxyJump fixture passwords unexpectedly match'
        }
    }

    $existingMappings = @(& $hdc -t $targetId fport ls 2>&1) -join "`n"
    if ($existingMappings -match "(?m)tcp:$JumpPort\s+tcp:$JumpPort\s+\[Reverse\]") {
        throw "HDC reverse mapping already exists for fixture port $JumpPort"
    }
    $mappingOutput = @(& $hdc -t $targetId rport "tcp:$JumpPort" "tcp:$JumpPort" 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $mappingOutput -notmatch 'Forwardport result:OK') {
        throw "Unable to create HDC reverse mapping: $mappingOutput"
    }
    $mappingActive = $true
    if ($ParallelPanes) {
        if ($existingMappings -match "(?m)tcp:$SecondJumpPort\s+tcp:$SecondJumpPort\s+\[Reverse\]") {
            throw "HDC reverse mapping already exists for fixture port $SecondJumpPort"
        }
        $secondMappingOutput = @(
            & $hdc -t $targetId rport "tcp:$SecondJumpPort" "tcp:$SecondJumpPort" 2>&1
        ) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $secondMappingOutput -notmatch 'Forwardport result:OK') {
            throw "Unable to create second HDC reverse mapping: $secondMappingOutput"
        }
        $secondMappingActive = $true
    }
    Start-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $targetId
    $awakeLeaseActive = $true

    $hapPath = Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
    $script:proxyHapPath = $hapPath
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
    if ($ParallelPanes) {
        Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$SecondJumpPort"
        Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$SecondTargetPort"
    }
    $proxyCommand = "ssh -p $TargetPort -J password@127.0.0.1:$JumpPort password@127.0.0.1"
    if ($ParallelPanes) {
        $secondProxyCommand = (
            "ssh -p $SecondTargetPort " +
                "-J password@127.0.0.1:$SecondJumpPort password@127.0.0.1"
        )

        Submit-ProxyCommand -Command $proxyCommand
        Wait-ProxyLog -Pattern 'rust event: HOST_KEY_PROMPT:jump\t'
        Submit-HostKeyDecisionUntilResult `
            -ExpectedPattern 'native auth event kind=password, layer=jump'
        Submit-JumpPasswordUntilResult `
            -Command $proxyCommand `
            -JumpPassword $jumpFixture.password `
            -ExpectedPattern 'rust event: HOST_KEY_PROMPT:target\t' `
            -CurrentPrompt

        Invoke-ProxySplitShortcut
        Wait-ProxyPaneCount `
            -Count 2 `
            -LayoutName 'parallel-split-target-prompt-held.json' | Out-Null
        Focus-ProxyPane `
            -Side 'right' `
            -LayoutName 'parallel-right-focused.json'
        Submit-ProxyCommand -Command $secondProxyCommand
        Wait-ProxyLog -Pattern 'rust event: HOST_KEY_PROMPT:jump\t'
        Submit-HostKeyDecisionUntilResult `
            -ExpectedPattern 'native auth event kind=password, layer=jump'
        Submit-JumpPasswordUntilResult `
            -Command $secondProxyCommand `
            -JumpPassword $secondJumpFixture.password `
            -ExpectedPattern 'rust event: HOST_KEY_PROMPT:target\t' `
            -CurrentPrompt
        Submit-HostKeyDecisionUntilResult `
            -ExpectedPattern 'native auth event kind=password, layer=target'
        Submit-CurrentTargetPasswordWithRetry `
            -Command $secondProxyCommand `
            -JumpPassword $secondJumpFixture.password `
            -TargetPassword $secondTargetFixture.password
        Submit-ConnectedProxyInputUntilFixture `
            -Text 'ltty-input-check rightproxy' `
            -FixtureLog $secondTargetStderr `
            -ExpectedPattern 'input case=rightproxy result=matched'

        Focus-ProxyPane `
            -Side 'left' `
            -LayoutName 'parallel-left-resumed.json'
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
        Submit-HostKeyDecisionUntilResult `
            -ExpectedPattern 'native auth event kind=password, layer=target'
        Submit-CurrentTargetPasswordWithRetry `
            -Command $proxyCommand `
            -JumpPassword $jumpFixture.password `
            -TargetPassword $targetFixture.password
        Submit-ConnectedProxyInputUntilFixture `
            -Text 'ltty-input-check leftproxy' `
            -FixtureLog $targetStderr `
            -ExpectedPattern 'input case=leftproxy result=matched'

        $leftTargetLogs = Read-ProxyFixtureLog -Path $targetStderr
        $rightTargetLogs = Read-ProxyFixtureLog -Path $secondTargetStderr
        if ($leftTargetLogs -match 'input case=rightproxy' -or
            $rightTargetLogs -match 'input case=leftproxy') {
            throw 'Parallel ProxyJump target output crossed Pane ownership'
        }
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc `
            -Target $targetId `
            -LocalPath (Join-Path $EvidenceDirectory 'parallel-both-connected.png')

        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
        & $hdc -t $targetId shell (
            'uinput -K -d 2072 -d 2047 -d 2039 -u 2039 -u 2047 -u 2072'
        ) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to invoke active Pane close shortcut' }
        Invoke-LeanTTYDialogButton `
            -Hdc $hdc `
            -Target $targetId `
            -ButtonText 'Close pane' `
            -LayoutPath (Join-Path $EvidenceDirectory 'parallel-close-left-dialog.json')
        Wait-ProxyLog -Pattern 'SSH closed, exitCode=-1'
        Wait-ProxyPaneCount `
            -Count 1 `
            -LayoutName 'parallel-right-survived-left-close.json' | Out-Null
        Wait-ProxyFixtureLog `
            -Path $jumpStderr `
            -Pattern 'direct-tcpip result=closed'

        Submit-ConnectedProxyInputUntilFixture `
            -Text 'ltty-input-check rightafterclose' `
            -FixtureLog $secondTargetStderr `
            -ExpectedPattern 'input case=rightafterclose result=matched'
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc `
            -Target $targetId `
            -LocalPath (Join-Path $EvidenceDirectory 'parallel-right-after-left-close.png')
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
        Submit-ConnectedProxyInput -Text 'ltty-exit'
        Wait-ProxyLog -Pattern 'SSH closed, exitCode=0'

        Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$JumpPort"
        Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$TargetPort"
        Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$SecondJumpPort"
        Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$SecondTargetPort"

        $script:result = 'passed'
        $parallelSummary = [ordered]@{
            schemaVersion = 1
            capturedAt = (Get-Date).ToString('o')
            result = $script:result
            scenario = 'parallel-panes-independent-proxy-jump-routes'
            target = $targetId
            transport = 'usb'
            firstRoute = [ordered]@{ jumpPort = $JumpPort; targetPort = $TargetPort }
            secondRoute = [ordered]@{
                jumpPort = $SecondJumpPort
                targetPort = $SecondTargetPort
            }
            authentication = 'four-distinct-passwords-submitted-only-to-their-own-layer-and-pane'
            outputIsolation = 'leftproxy and rightproxy reached only their owning target fixture'
            cleanupIsolation = 'closing left route released its tunnel while right route remained interactive'
            hapSha256 = (
                Get-FileHash -LiteralPath $script:proxyHapPath -Algorithm SHA256
            ).Hash.ToLowerInvariant()
        }
        $parallelSummaryPath = Join-Path $EvidenceDirectory 'summary.json'
        [IO.File]::WriteAllText(
            $parallelSummaryPath,
            (ConvertTo-Json $parallelSummary -Depth 5) + "`n"
        )
        Write-Host "PROXYJUMP PC EVIDENCE: $parallelSummaryPath" -ForegroundColor Green
        return
    }
    Submit-ProxyCommand -Command $proxyCommand

    Wait-ProxyLog -Pattern 'rust event: HOST_KEY_PROMPT:jump\t'
    Submit-HostKeyDecisionUntilResult `
        -ExpectedPattern 'native auth event kind=password, layer=jump'
    if ($FailureScenario -eq 'JumpAuthentication') {
        if ($jumpFixture.password -eq $targetFixture.password) {
            throw 'Temporary fixture passwords unexpectedly match across layers'
        }
        Submit-SecretOrDecision -Text $targetFixture.password
        Wait-ProxyLog -Pattern 'rust event: AUTH:jump:authentication was rejected'
        Wait-ProxyLog -Pattern 'SSH error: jump:authentication was rejected'
        $failureLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $targetId -ProcessId $appPid
        if ($failureLogs -match 'native auth event kind=\S+, layer=target|rust event: CONNECTED') {
            throw 'Jump authentication failure continued into the target layer'
        }
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc `
            -Target $targetId `
            -LocalPath (Join-Path $EvidenceDirectory 'jump-authentication-rejected.png')
        Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$JumpPort"
        Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$TargetPort"
        Write-ProxySummary `
            -Scenario 'jump-authentication-rejected' `
            -Authentication 'wrong-target-secret-submitted-to-jump-and-rejected' `
            -HostKeyVerification 'jump-first-use-confirmed-before-authentication-failure' `
            -KnownHostReconnect $false `
            -TargetHostKeyRotationRecovered $false `
            -JumpHostKeyRotationRecovered $false `
            -ExpectedFailureLayer 'jump' `
            -TargetShellOpened $false `
            -TargetShellClosedCleanly $false
        return
    }
    if ($FailureScenario -eq 'DirectTcpipRejected') {
        Submit-JumpPasswordUntilResult `
            -Command $proxyCommand `
            -JumpPassword $jumpFixture.password `
            -ExpectedPattern 'rust event: CHANNEL:jump:direct-tcpip failed' `
            -CurrentPrompt
        Wait-ProxyLog -Pattern 'SSH error: jump:direct-tcpip failed'
        Wait-ProxyFixtureLog `
            -Path $jumpStderr `
            -Pattern 'direct-tcpip result=deny reason=disabled'
        $failureLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $targetId -ProcessId $appPid
        if ($failureLogs -match 'native auth event kind=\S+, layer=target|rust event: CONNECTED') {
            throw 'Rejected direct-tcpip channel continued into the target layer'
        }
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc `
            -Target $targetId `
            -LocalPath (Join-Path $EvidenceDirectory 'direct-tcpip-rejected.png')
        Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$JumpPort"
        Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$TargetPort"
        Write-ProxySummary `
            -Scenario 'direct-tcpip-rejected' `
            -Authentication 'jump-password-accepted-before-channel-rejection' `
            -HostKeyVerification 'jump-first-use-confirmed-before-channel-rejection' `
            -KnownHostReconnect $false `
            -TargetHostKeyRotationRecovered $false `
            -JumpHostKeyRotationRecovered $false `
            -ExpectedFailureLayer 'jump' `
            -TargetShellOpened $false `
            -TargetShellClosedCleanly $false
        return
    }
    if ($FailureScenario -in @('TargetUnreachable', 'DirectTcpipTimeout')) {
        $expectedEvent = if ($FailureScenario -eq 'TargetUnreachable') {
            'rust event: CHANNEL:jump:direct-tcpip failed'
        } else {
            'rust event: CHANNEL:jump:direct-tcpip timed out after \d+ ms'
        }
        Submit-JumpPasswordUntilResult `
            -Command $proxyCommand `
            -JumpPassword $jumpFixture.password `
            -ExpectedPattern $expectedEvent `
            -TimeoutSeconds ($FailureScenario -eq 'DirectTcpipTimeout' ? 25 : 15) `
            -CurrentPrompt
        Wait-ProxyLog -Pattern 'SSH error: jump:direct-tcpip (failed|timed out)'
        $fixturePattern = if ($FailureScenario -eq 'TargetUnreachable') {
            'direct-tcpip result=connect-failed'
        } else {
            'direct-tcpip result=stall'
        }
        Wait-ProxyFixtureLog `
            -Path $jumpStderr `
            -Pattern $fixturePattern `
            -TimeoutSeconds 20
        $failureLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $targetId -ProcessId $appPid
        if ($failureLogs -match 'native auth event kind=\S+, layer=target|rust event: CONNECTED') {
            throw "$FailureScenario continued into the target layer"
        }
        $failureScreenshot = if ($FailureScenario -eq 'TargetUnreachable') {
            'target-unreachable.png'
        } else {
            'direct-tcpip-timeout.png'
        }
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc `
            -Target $targetId `
            -LocalPath (Join-Path $EvidenceDirectory $failureScreenshot)
        Assert-ProxyCommandInputRecovered `
            -ScreenshotName ($FailureScenario.ToLowerInvariant() + '-recovered.png')
        Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$JumpPort"
        Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$TargetPort"
        Write-ProxySummary `
            -Scenario ($FailureScenario -eq 'TargetUnreachable' ?
                'target-unreachable' : 'direct-tcpip-timeout') `
            -Authentication 'jump-password-accepted-before-target-route-failure' `
            -HostKeyVerification 'jump-first-use-confirmed-before-target-route-failure' `
            -KnownHostReconnect $false `
            -TargetHostKeyRotationRecovered $false `
            -JumpHostKeyRotationRecovered $false `
            -ExpectedFailureLayer 'jump' `
            -TargetShellOpened $false `
            -TargetShellClosedCleanly $false `
            -Lifecycle 'pending route work ended, input recovered, no late CONNECTED'
        return
    }
    Submit-JumpPasswordUntilResult `
        -Command $proxyCommand `
        -JumpPassword $jumpFixture.password `
        -ExpectedPattern 'rust event: HOST_KEY_PROMPT:target\t' `
        -CurrentPrompt
    Submit-HostKeyDecisionUntilResult `
        -ExpectedPattern 'native auth event kind=password, layer=target'
    if ($FailureScenario -eq 'CancelAtTargetAuthentication') {
        Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $targetId
        Wait-ProxyFixtureLog `
            -Path $jumpStderr `
            -Pattern 'direct-tcpip result=closed'
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc `
            -Target $targetId `
            -LocalPath (Join-Path $EvidenceDirectory 'target-authentication-cancelled.png')
        $idleProbe = "ssh -G -J password@127.0.0.1:$JumpPort password@127.0.0.1"
        Submit-ProxyCommand -Command $idleProbe
        try {
            Wait-ProxyLog -Pattern 'rust event: CONNECTED' -TimeoutSeconds 2
            throw 'Cancelled ProxyJump emitted a late CONNECTED event'
        } catch {
            if ($_.Exception.Message -eq 'Cancelled ProxyJump emitted a late CONNECTED event') {
                throw
            }
        }
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc `
            -Target $targetId `
            -LocalPath (Join-Path $EvidenceDirectory 'target-authentication-cancel-recovered.png')
        Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$JumpPort"
        Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$TargetPort"
        Write-ProxySummary `
            -Scenario 'target-authentication-cancelled' `
            -Authentication 'cancelled-at-target-password-prompt' `
            -HostKeyVerification 'both-first-use-host-keys-confirmed-before-cancellation' `
            -KnownHostReconnect $false `
            -TargetHostKeyRotationRecovered $false `
            -JumpHostKeyRotationRecovered $false `
            -ExpectedFailureLayer '' `
            -TargetShellOpened $false `
            -TargetShellClosedCleanly $false
        return
    }
    if ($FailureScenario -eq 'TargetAuthentication') {
        if ($jumpFixture.password -eq $targetFixture.password) {
            throw 'Temporary fixture passwords unexpectedly match across layers'
        }
        Submit-SecretOrDecision -Text $jumpFixture.password
        Wait-ProxyLog -Pattern 'rust event: AUTH:target:authentication was rejected'
        Wait-ProxyLog -Pattern 'SSH error: target:authentication was rejected'
        $failureLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $targetId -ProcessId $appPid
        if ($failureLogs -match 'rust event: CONNECTED') {
            throw 'Target authentication failure opened a target shell'
        }
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc `
            -Target $targetId `
            -LocalPath (Join-Path $EvidenceDirectory 'target-authentication-rejected.png')
        Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$JumpPort"
        Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$TargetPort"
        Write-ProxySummary `
            -Scenario 'target-authentication-rejected' `
            -Authentication 'wrong-jump-secret-submitted-to-target-and-rejected' `
            -HostKeyVerification 'both-first-use-host-keys-confirmed-before-target-authentication-failure' `
            -KnownHostReconnect $false `
            -TargetHostKeyRotationRecovered $false `
            -JumpHostKeyRotationRecovered $false `
            -ExpectedFailureLayer 'target' `
            -TargetShellOpened $false `
            -TargetShellClosedCleanly $false
        return
    }
    Submit-CurrentTargetPasswordWithRetry `
        -Command $proxyCommand `
        -JumpPassword $jumpFixture.password `
        -TargetPassword $targetFixture.password

    Save-LeanTTYDeviceScreenshot `
        -Hdc $hdc `
        -Target $targetId `
        -LocalPath (Join-Path $EvidenceDirectory 'connected.png')
    if ($FailureScenario -in @('TargetDisconnected', 'JumpDisconnected')) {
        $disconnectName = $FailureScenario -eq 'TargetDisconnected' ? 'target' : 'jump'
        Submit-ConnectedProxyInputUntilFixture `
            -Text "ltty-terminal-dirty $disconnectName" `
            -FixtureLog $targetStderr `
            -ExpectedPattern "terminal dirty case=$disconnectName result=enabled"
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc `
            -Target $targetId `
            -LocalPath (Join-Path $EvidenceDirectory "$disconnectName-dirty-before-disconnect.png")
        if ($FailureScenario -eq 'TargetDisconnected') {
            Stop-ProxyFixture -Process $targetProcess -LinuxPid $targetLinuxPid
            $targetProcess = $null
            $targetLinuxPid = 0
            $targetFixture = $null
            Wait-ProxyFixtureLog `
                -Path $jumpStderr `
                -Pattern 'direct-tcpip result=closed'
        } else {
            Stop-ProxyFixture -Process $jumpProcess -LinuxPid $jumpLinuxPid
            $jumpProcess = $null
            $jumpLinuxPid = 0
            $jumpFixture = $null
        }
        Wait-ProxyLog -Pattern 'SSH closed, exitCode=-1'
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc `
            -Target $targetId `
            -LocalPath (Join-Path $EvidenceDirectory "$disconnectName-disconnected.png")
        Assert-ProxyCommandInputRecovered `
            -ScreenshotName "$disconnectName-disconnected-recovered.png"
        Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$JumpPort"
        Submit-ProxyCommand -Command "ssh-keygen -R [127.0.0.1]:$TargetPort"
        Write-ProxySummary `
            -Scenario "$disconnectName-disconnected-after-connect" `
            -Authentication 'both-layer-passwords-accepted-before-injected-disconnect' `
            -HostKeyVerification 'both-first-use-host-keys-confirmed-before-injected-disconnect' `
            -KnownHostReconnect $false `
            -TargetHostKeyRotationRecovered $false `
            -JumpHostKeyRotationRecovered $false `
            -ExpectedFailureLayer $disconnectName `
            -TargetShellOpened $true `
            -TargetShellClosedCleanly $false `
            -Lifecycle 'dirty terminal modes enabled; transport closed; terminal state and input recovered; no late CONNECTED'
        return
    }
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

    Write-ProxySummary `
        -Scenario ($IncludeHostKeyRotation ?
            ('host-key-rotation-' + $HostKeyRotationLayer.ToLowerInvariant()) : 'success') `
        -Authentication 'password-per-layer-with-distinct-temporary-secrets' `
        -HostKeyVerification $(if ($IncludeHostKeyRotation) {
            'first-use-confirmed-and-' + $HostKeyRotationLayer.ToLowerInvariant() +
                '-host-key-rotation-recovered'
        } else {
            'first-use-confirmed-and-known-match-reused-independently-per-layer'
        }) `
        -KnownHostReconnect (-not [bool]$IncludeHostKeyRotation) `
        -TargetHostKeyRotationRecovered ([bool]$IncludeHostKeyRotation -and
            $HostKeyRotationLayer -in @('Target', 'Both')) `
        -JumpHostKeyRotationRecovered ([bool]$IncludeHostKeyRotation -and
            $HostKeyRotationLayer -in @('Jump', 'Both')) `
        -ExpectedFailureLayer '' `
        -TargetShellOpened $true `
        -TargetShellClosedCleanly $true
} catch {
    $failure = $_.Exception.Message
    throw
} finally {
    if ($secondMappingActive) {
        & $script:proxyHdc -t $script:proxyTarget fport rm `
            "tcp:$SecondJumpPort" "tcp:$SecondJumpPort" 2>$null | Out-Null
        $secondMappingActive = $false
    }
    if ($mappingActive) {
        & $script:proxyHdc -t $script:proxyTarget fport rm "tcp:$JumpPort" "tcp:$JumpPort" 2>$null | Out-Null
        $mappingActive = $false
    }
    try {
        Stop-ProxyFixture `
            -Process $secondJumpProcess `
            -LinuxPid $secondJumpLinuxPid
    } catch {}
    try {
        Stop-ProxyFixture `
            -Process $secondTargetProcess `
            -LinuxPid $secondTargetLinuxPid
    } catch {}
    try { Stop-ProxyFixture -Process $jumpProcess -LinuxPid $jumpLinuxPid } catch {}
    try { Stop-ProxyFixture -Process $targetProcess -LinuxPid $targetLinuxPid } catch {}
    foreach ($fixtureLog in @(
        @{ Source = $jumpStdout; Name = 'jump-fixture-stdout.log' },
        @{ Source = $jumpStderr; Name = 'jump-fixture-stderr.log' },
        @{ Source = $targetStdout; Name = 'target-fixture-stdout.log' },
        @{ Source = $targetStderr; Name = 'target-fixture-stderr.log' },
        @{ Source = $secondJumpStdout; Name = 'second-jump-fixture-stdout.log' },
        @{ Source = $secondJumpStderr; Name = 'second-jump-fixture-stderr.log' },
        @{ Source = $secondTargetStdout; Name = 'second-target-fixture-stdout.log' },
        @{ Source = $secondTargetStderr; Name = 'second-target-fixture-stderr.log' }
    )) {
        try {
            if (Test-Path -LiteralPath $fixtureLog.Source -PathType Leaf) {
                Copy-Item `
                    -LiteralPath $fixtureLog.Source `
                    -Destination (Join-Path $EvidenceDirectory $fixtureLog.Name) `
                    -Force
            }
        } catch {}
    }
    if (-not [string]::IsNullOrWhiteSpace($appPid)) {
        try {
            $appLogs = Get-LeanTTYAppLogs `
                -Hdc $script:proxyHdc `
                -Target $script:proxyTarget `
                -ProcessId $appPid
            [IO.File]::WriteAllText(
                (Join-Path $EvidenceDirectory 'device-app.log'),
                $appLogs + "`n"
            )
        } catch {}
    }
    if ($awakeLeaseActive) {
        Stop-LeanTTYDeviceAwakeLease -Hdc $script:proxyHdc -Target $script:proxyTarget
    }
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
    $jumpFixture = $null
    $targetFixture = $null
    $secondJumpFixture = $null
    $secondTargetFixture = $null
    if ($result -ne 'passed' -and -not [string]::IsNullOrWhiteSpace($failure)) {
        Write-Warning "ProxyJump physical-PC verification failed: $failure"
    }
}
