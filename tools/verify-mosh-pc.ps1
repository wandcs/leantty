<#
.SYNOPSIS
  Verify one LeanTTY Mosh compatibility or network-lifecycle scenario on a physical HarmonyOS PC.
.DESCRIPTION
  Runs the repository SSH fixture through a run-scoped HDC reverse mapping,
  then uses the wired LAN for a real stock mosh-server with a controlled PTY.
  The default proves an exact command, real
  Bash, tmux, Vim, less, UTF-8/wide text, alternate screen, interactive
  scrollback, resize and sustained I/O. Named scenarios prove a requested
  fixed UDP range, one absolute server path, prediction modes, active-Pane
  disposal, concurrent Session isolation, exact-port UDP pause/recovery,
  system suspend/recovery or controlled server disappearance.
  Every scenario checks secret boundaries and Ctrl-^ . cleanup.
  The persistent Windows UDP firewall boundary must first be enabled once with
  configure-mosh-test-network.ps1. This routine runs without elevation, owns
  only its temporary HDC mapping and never changes firewall or portproxy state.
#>
[CmdletBinding()]
param(
    [ValidateSet('compatibility', 'agent-tui', 'fixed-endpoint', 'server-path', 'prediction', 'surface-rebuild', 'page-rebuild', 'abnormal-exit', 'process-recovery', 'pane-close', 'session-isolation', 'pause-recovery', 'wifi-pause-recovery', 'suspend-recovery', 'operator-lock-recovery', 'operator-lid-recovery', 'server-disappearance')]
    [string]$Scenario = 'compatibility',
    [string]$Target = '',
    [string]$HapPath = '',
    [ValidateRange(1024, 65535)][int]$FixturePort = 2223,
    [ValidateRange(1024, 65535)][int]$FixtureBackendPort = 32223,
    [string]$ServerAddress = '192.168.1.4',
    [string]$RemoteScope = '192.168.1.0/24',
    [string]$EvidenceDirectory = '',
    [ValidateRange(30, 300)][int]$OperatorWaitSeconds = 120,
    [string]$Distribution = $env:LEANTTY_WSL_DISTRO
)

$ErrorActionPreference = 'Stop'
$moshUdpPortMin = 60000
$moshUdpPortMax = 61000
$fixedUdpPortStart = 60042
$fixedUdpPortEnd = 60044
$customMoshServerPath = '/usr/bin/mosh-server'
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
    throw "Mosh signed HAP is missing: $selectedHapPath"
}
if ((Split-Path $selectedHapPath -Leaf) -match '(?i)unsigned') {
    throw 'Mosh verification requires a signed HAP'
}
if ($FixtureBackendPort -eq $FixturePort) {
    throw 'FixtureBackendPort must differ from the external FixturePort'
}

$startedAt = [DateTimeOffset]::UtcNow
$attemptId = [Guid]::NewGuid().ToString('N')
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $repoRoot (
        'build\verification\device-mosh-' + $startedAt.ToString('yyyyMMddTHHmmssfffZ')
    )
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$evidencePath = Join-Path $EvidenceDirectory 'device-mosh.json'
$liveStatusPath = Join-Path $EvidenceDirectory 'live-status.json'
$networkStatusPath = Join-Path $EvidenceDirectory 'network-status.json'

$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') +
    [IO.Path]::DirectorySeparatorChar
$fixtureRoot = [IO.Path]::GetFullPath(
    (Join-Path $temporaryRoot ('leantty-mosh-' + $attemptId))
)
if (-not $fixtureRoot.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Mosh fixture root escaped the system temporary directory'
}
$fixtureControl = Join-Path $fixtureRoot 'control'
$fixtureStdout = Join-Path $fixtureRoot 'stdout.log'
$fixtureStderr = Join-Path $fixtureRoot 'stderr.log'
$fixtureInputSnapshot = Join-Path $fixtureControl 'mosh-input-snapshot'
$fixtureEvent = Join-Path $fixtureControl 'mosh-event'
$fixtureSession = Join-Path $fixtureControl 'mosh-session'
$fixtureTerminalReady = Join-Path $fixtureControl 'mosh-terminal-ready'
$fixtureTerminalPidPath = Join-Path $fixtureControl 'mosh-terminal-pid'
$fixtureShellEvent = Join-Path $fixtureControl 'mosh-shell-event'
$fixtureShellReady = Join-Path $fixtureControl 'mosh-shell-ready'
$fixtureTmuxEvent = Join-Path $fixtureControl 'mosh-tmux-event'
$fixtureTmuxReady = Join-Path $fixtureControl 'mosh-tmux-ready'
$fixtureEditorEvent = Join-Path $fixtureControl 'mosh-editor-event'
$fixtureEditorReady = Join-Path $fixtureControl 'mosh-editor-ready'
$fixtureResizeEvent = Join-Path $fixtureControl 'mosh-resize-event'
$fixtureStreamEvent = Join-Path $fixtureControl 'mosh-stream-event'
$fixtureUnicodeEvent = Join-Path $fixtureControl 'mosh-unicode-event'
$fixtureScrollbackEvent = Join-Path $fixtureControl 'mosh-scrollback-event'
$fixtureLessEvent = Join-Path $fixtureControl 'mosh-less-event'
$fixtureAlternateEvent = Join-Path $fixtureControl 'mosh-alternate-event'
$fixtureKernelEcho = Join-Path $fixtureControl 'mosh-kernel-echo'
$fixturePredictionRelay = Join-Path $fixtureControl 'mosh-prediction-relay'
$fixturePredictionRelayPause = Join-Path $fixtureControl 'mosh-prediction-relay-paused'
$fixturePredictionRelayStats = Join-Path $fixtureControl 'mosh-prediction-relay-stats'
$fixturePredictionEvent = Join-Path $fixtureControl 'mosh-prediction-event'
$fixtureSessionIsolation = Join-Path $fixtureControl 'mosh-session-isolation'
$fixturePredictionEventWsl = ConvertTo-LeanTTYWslPath `
    -WindowsPath $fixturePredictionEvent -Distribution $Distribution
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null

$alias = '__ltty_mosh'
$sshAlias = '__ltty_mosh_ssh'
$fixtureSshAddress = '127.0.0.1'
$caseId = 'shell_' + $attemptId.Substring(0, 12)
$agentToolWsl = ConvertTo-LeanTTYWslPath `
    -WindowsPath (Join-Path $PSScriptRoot 'agent-compatibility-wsl.sh') `
    -Distribution $Distribution
$fixtureAgentRoot = Join-Path $fixtureControl "leantty-agent-compat-$caseId"
$fixtureAgentRootWsl = ConvertTo-LeanTTYWslPath `
    -WindowsPath $fixtureAgentRoot -Distribution $Distribution
$fixtureAgentPrepared = Join-Path $fixtureControl 'mosh-agent-prepared'
$fixtureAgentEvent = Join-Path $fixtureControl 'mosh-agent-event'
$fixtureAgentCapture = Join-Path $fixtureAgentRoot 'results\codex-direct-interaction.json'
$commandObservations = [Collections.Generic.List[object]]::new()
$connectedInputObservations = [Collections.Generic.List[object]]::new()
$fixtureProcess = $null
$fixtureMappingActive = $false
$fixtureMappingRemoved = $true
$fixtureLinuxPid = 0
$moshServerPid = 0
$moshServerPort = 0
$moshActualServerPort = 0
$udpEndpointMatchesRequest = ($Scenario -ne 'fixed-endpoint')
$serverPathMatchesRequest = ($Scenario -ne 'server-path')
$fixturePassword = ''
$awakeLeaseActive = $false
$appPid = ''
$targetId = ''
$resolvedServerAddress = ''
$resolvedRemoteScope = ''
$networkStateReady = $false
$localPromptReady = $false
$deviceStateCleaned = $false
$deviceCleanupRecovery = 'none'
$fixtureCleaned = $false
$result = 'failed'
$failure = ''
$failureDomain = 'none'
$lastProvenBoundary = 'none'
$gracefulServerExitElapsedMs = -1
$authenticatedGracefulClose = $false
$localCloseElapsedMs = -1
$fixtureTerminalPid = 0
$remoteShellAliveBefore = $false
$remoteShellAliveAfter = $false
$networkPauseDurationMs = -1
$systemSuspendMs = -1
$resumeCommandElapsedMs = -1
$sameAppProcessAfterResume = $false
$initialAppProcessId = ''
$resumedAppProcessId = ''
$initialAppProcessStartTimeTicks = ''
$resumedAppProcessStartTimeTicks = ''
$remoteShellAliveAtProcessChange = $false
$serverAliveAtProcessChange = $false
$recoveryInputMethod = 'not-run'
$deviceUnlockAfterResume = 'not-run'
$operatorLockObserved = $false
$operatorUnlockObserved = $false
$operatorLockDurationMs = -1
$operatorDeviceInactiveState = 'not-observed'
$operatorRecoveryOutcome = 'not-run'
$processRecoveryWorkspaceRestored = $false
$processRecoveryRemoteContentAbsent = $false
$processRecoverySessionNotRestored = $false
$moshNetworkTimeoutSeconds = if ($Scenario -in @(
    'operator-lock-recovery', 'operator-lid-recovery'
)) {
    [Math]::Min(7200, $OperatorWaitSeconds + 60)
} else { 30 }
$sessionStayedConnected = $false
$recoveryCommandPassed = $false
$automaticCloseObserved = $false
$automaticErrorObserved = $false
$interruptionObserved = $false
$interruptionReason = 'not-observed'
$recoveredStatusObserved = $false
$userCloseRequired = $false
$observedErrorCategory = 'not-run'
$udpImpairmentInterface = 'eth0'
$udpImpairmentPreference = 49152
$udpImpairmentOwnsQdisc = $false
$udpImpairmentCleanupVerified = $true
$wifiDisabledByScenario = $false
$wifiControlCleanupVerified = $true
$windowToggled = $false
$shellCompatibilityPassed = $false
$tmuxCompatibilityPassed = $false
$editorCompatibilityPassed = $false
$resizeCompatibilityPassed = $false
$streamCompatibilityPassed = $false
$streamOutputObserved = $false
$unicodeCompatibilityPassed = $false
$unicodeOutputObserved = $false
$unicodeScreenshot = ''
$scrollbackCompatibilityPassed = $false
$scrollbackBottomObserved = $false
$scrollbackTopAbsent = $false
$lessCompatibilityPassed = $false
$lessFirstLineObserved = $false
$lessLastLineObserved = $false
$alternateScreenCompatibilityPassed = $false
$alternateScreenActiveObserved = $false
$alternateScreenClosedObserved = $false
$alternateScreenHistoryRetained = $false
$alternateScreenActiveScreenshot = ''
$alternateScreenClosedScreenshot = ''
$originalPageMarker = "LTTY_MOSH_ORIGINAL:$caseId"
$originalPageHiddenDuringSession = $false
$originalPageRestoredAfterSession = $false
$moshPageDiscardedAfterSession = $false
$agentCompatibilityPassed = $false
$agentVersion = ''
$agentCaptureSummary = $null
$agentTermiosBefore = $null
$agentTermiosAfter = $null
$bootstrapTerminalAbsent = $false
$preferencesDigestBefore = ''
$preferencesDigestAfter = ''
$preferencesUnchanged = $false
$secretAuditPassed = $false
$predictionAlwaysVisibleBeforeAuthority = $false
$predictionNeverHiddenBeforeAuthority = $false
$predictionAuthorityConverged = $false
$predictionSessionsIsolated = $false
$predictionAlwaysClosedGracefully = $false
$predictionRelayDelayMs = 40
$predictionRttBaselineMs = -1
$predictionConfirmationThresholdMs = -1
$predictionVisibleLatencyMs = -1
$predictionRenderLatencyMs = -1
$predictionOutageVisibleLatencyMs = -1
$predictionOutageRenderLatencyMs = -1
$predictionRelayDroppedPackets = 0
$predictionWarmupSamples = [Collections.Generic.List[object]]::new()
$paneCloseOldOutputAbsent = $false
$paneCloseSurvivorCommandPassed = $false
$paneCloseOldServerExitElapsedMs = -1
$twoMoshOutputIsolated = $false
$twoMoshInputIsolated = $false
$twoMoshCloseIsolated = $false
$sshMoshOutputIsolated = $false
$sshMoshInputIsolated = $false
$sshMoshCloseIsolated = $false
$sessionIsolationServerPidsDistinct = $false
$sessionIsolationKeysDistinct = $false
$surfaceRebuildRequested = $false
$surfaceRebuildPageRetained = $false
$surfaceRebuildCommandPassed = $false
$pageRebuildRequested = $false
$pageRebuildProcessPreserved = $false
$pageRebuildWorkspaceReused = $false
$pageRebuildPageRetained = $false
$pageRebuildCommandPassed = $false
$abnormalExitInjected = $false
$abnormalExitObserved = $false
$activeMoshControlDirectory = $fixtureControl

function Write-LiveStatus {
    param([Parameter(Mandatory = $true)][string]$Stage)
    $status = [ordered]@{
        schemaVersion = 1
        gate = 'mosh-physical-diagnostic'
        attemptId = $attemptId
        stage = $Stage
        updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        lastProvenBoundary = $lastProvenBoundary
    }
    [IO.File]::WriteAllText(
        $liveStatusPath,
        (ConvertTo-Json $status -Depth 5) + "`n",
        [Text.UTF8Encoding]::new($false)
    )
    Write-Host "[mosh-device] stage=$Stage" -ForegroundColor Cyan
}

function Resolve-MoshServerAddress {
    if (-not [string]::IsNullOrWhiteSpace($ServerAddress)) {
        $parsed = $null
        if (-not [Net.IPAddress]::TryParse($ServerAddress, [ref]$parsed) -or
            $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
            throw '[infrastructure] ServerAddress must be one IPv4 address'
        }
        $hostMatch = @(Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ServerAddress `
            -ErrorAction SilentlyContinue)
        if ($hostMatch.Count -ne 1) {
            throw '[infrastructure] ServerAddress is not assigned to this Windows host'
        }
        return $ServerAddress
    }

    $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' `
        -ErrorAction Stop | Where-Object { $_.State -eq 'Alive' } |
        Sort-Object RouteMetric, InterfaceMetric)
    foreach ($route in $routes) {
        $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex |
            Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' })
        if ($addresses.Count -eq 1) { return [string]$addresses[0].IPAddress }
    }
    throw '[infrastructure] Unable to resolve one active wired/LAN IPv4 address'
}

function Resolve-MoshRemoteScope {
    if (-not [string]::IsNullOrWhiteSpace($RemoteScope)) {
        if ($RemoteScope -notmatch '^\d+\.\d+\.\d+\.\d+/(?:[1-9]|[12]\d|3[0-2])$') {
            throw '[infrastructure] RemoteScope must be one IPv4 CIDR'
        }
        return $RemoteScope
    }
    $hostAddress = @(Get-NetIPAddress -AddressFamily IPv4 -IPAddress $resolvedServerAddress `
        -ErrorAction Stop)
    if ($hostAddress.Count -ne 1 -or $hostAddress[0].PrefixLength -lt 1) {
        throw '[infrastructure] Unable to derive the Mosh host LAN scope'
    }
    $bytes = ([Net.IPAddress]::Parse($resolvedServerAddress)).GetAddressBytes()
    $remaining = [int]$hostAddress[0].PrefixLength
    for ($index = 0; $index -lt 4; $index++) {
        $bits = [Math]::Min(8, [Math]::Max(0, $remaining))
        $mask = if ($bits -eq 0) { 0 } else { (0xff -shl (8 - $bits)) -band 0xff }
        $bytes[$index] = $bytes[$index] -band $mask
        $remaining -= $bits
    }
    return "$([Net.IPAddress]::new($bytes))/$($hostAddress[0].PrefixLength)"
}

function Assert-MoshTestNetworkReady {
    & (Join-Path $PSScriptRoot 'configure-mosh-test-network.ps1') -Mode Status `
        -ServerAddress $resolvedServerAddress -ExternalSshPort $FixturePort `
        -BackendAddress '127.0.0.1' -BackendSshPort $FixtureBackendPort `
        -RemoteScope $resolvedRemoteScope `
        -OutputPath $networkStatusPath | Out-Null
    $state = Get-Content -LiteralPath $networkStatusPath -Raw | ConvertFrom-Json
    $requiredUdpComponents = @('windowsUdpFirewall', 'hyperVUdpFirewall')
    $notReady = @($requiredUdpComponents | Where-Object {
        $state.components.$_ -ne 'ready'
    })
    $notReady += @($state.legacy.psobject.Properties |
            Where-Object { $_.Value -notin @('missing', 'unavailable') } |
            ForEach-Object { 'legacy.' + $_.Name })
    if ($notReady.Count -gt 0) {
        throw ('[infrastructure] Persistent Mosh test network is not ready: ' +
            ($notReady -join ', ') +
            '. Run configure-mosh-test-network.ps1 -Mode Enable once as Administrator.')
    }
    $script:networkStateReady = $true
}

function New-MoshFixtureMapping {
    $existing = @(& $hdc -t $targetId fport ls 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw '[infrastructure] Unable to inspect existing HDC port mappings'
    }
    if ($existing -match "(?m)tcp:$FixturePort\s+tcp:\d+\s+\[Reverse\]") {
        throw "[infrastructure] HDC reverse mapping already uses device port $FixturePort"
    }
    $output = @(
        & $hdc -t $targetId rport "tcp:$FixturePort" "tcp:$FixtureBackendPort" 2>&1
    ) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $output -notmatch 'Forwardport result:OK') {
        throw "[infrastructure] Unable to create Mosh HDC reverse mapping: $output"
    }
    $script:fixtureMappingActive = $true
    $script:fixtureMappingRemoved = $false
}

function Remove-MoshFixtureMapping {
    if (-not $fixtureMappingActive) { return }
    $output = @(
        & $hdc -t $targetId fport rm "tcp:$FixturePort" "tcp:$FixtureBackendPort" 2>&1
    ) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $output -notmatch 'Remove forward ruler success') {
        throw "HDC reverse mapping cleanup failed: $output"
    }
    $remaining = @(& $hdc -t $targetId fport ls 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or
        $remaining -match "(?m)tcp:$FixturePort\s+tcp:$FixtureBackendPort\s+\[Reverse\]") {
        throw 'HDC reverse mapping remained after cleanup'
    }
    $script:fixtureMappingActive = $false
    $script:fixtureMappingRemoved = $true
}

function Start-MoshFixture {
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $PSScriptRoot 'start-ssh-auth-fixture.ps1'),
        '-ListenAddress', "127.0.0.1:$FixtureBackendPort", '-RunSeconds', '600',
        '-ControlDirectory', $fixtureControl,
        '-MoshServerAddress', $resolvedServerAddress,
        '-MoshNetworkTimeoutSeconds', $moshNetworkTimeoutSeconds
    )
    if (-not [string]::IsNullOrWhiteSpace($Distribution)) {
        $arguments += @('-Distribution', $Distribution)
    }
    return Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments `
        -RedirectStandardOutput $fixtureStdout -RedirectStandardError $fixtureStderr `
        -WindowStyle Hidden -PassThru
}

function Wait-MoshFixtureReady {
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 45) {
        $fixtureProcess.Refresh()
        if ($fixtureProcess.HasExited) {
            throw '[infrastructure] Mosh fixture exited before readiness'
        }
        $readiness = Read-LeanTTYFixtureReadiness -ControlDirectory $fixtureControl
        if ($null -ne $readiness) { return $readiness }
        Start-Sleep -Milliseconds 200
    }
    throw '[infrastructure] Timed out waiting for the Mosh fixture'
}

function Wait-ControlFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 15
    )
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try { return Read-LeanTTYSharedTextFile -Path $Path } catch [IO.IOException] {}
        }
        Start-Sleep -Milliseconds 100
    }
    throw '[infrastructure] Timed out waiting for a controlled Mosh fixture file'
}

function Wait-ControlFileMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 15
    )
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                $contents = Read-LeanTTYSharedTextFile -Path $Path
                if ($contents -match $Pattern) { return $contents }
            } catch [IO.IOException] {}
        }
        Start-Sleep -Milliseconds 100
    }
    throw '[harness] Timed out waiting for a controlled Mosh workload result'
}

function Invoke-MoshAgentTool {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $prefix = Get-LeanTTYWslPrefix -Distribution $Distribution
    & wsl.exe @prefix --exec bash $agentToolWsl @Arguments
    return $LASTEXITCODE
}

function Wait-MoshAgentReady {
    $captureName = 'codex-direct-interaction'
    $livePath = Join-Path $fixtureAgentRoot 'results\codex-direct-interaction-live.json'
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 30) {
        $exitCode = Invoke-MoshAgentTool -Arguments @(
            'probe', $fixtureAgentRootWsl, $captureName
        ) 2>$null
        if ($exitCode -eq 0 -and (Test-Path -LiteralPath $livePath -PathType Leaf)) {
            $live = Get-Content -LiteralPath $livePath -Raw | ConvertFrom-Json -Depth 20
            if ([int]$live.output.bytes -gt 256 -and (
                [int]$live.output.bracketedPaste.enableCount -gt 0 -or
                [int]$live.output.alternateScreen.enterCount -gt 0 -or
                [int]$live.output.osc8HyperlinkCount -gt 0
            )) { return }
        }
        if (Test-Path -LiteralPath $fixtureAgentCapture -PathType Leaf) {
            throw '[external-agent] Codex exited before its zero-model TUI became ready'
        }
        Start-Sleep -Milliseconds 200
    }
    throw '[harness] Timed out waiting for the zero-model Codex TUI'
}

function Get-MoshAgentTermios {
    param([Parameter(Mandatory = $true)][ValidateSet('before-resize', 'after-resize')]
        [string]$Sample)
    $exitCode = Invoke-MoshAgentTool -Arguments @(
        'termios-probe', $fixtureAgentRootWsl, 'codex-direct-interaction', $Sample
    )
    if ($exitCode -ne 0) { throw "[harness] Unable to sample Codex PTY termios: $Sample" }
    $path = Join-Path $fixtureAgentRoot "results\codex-direct-interaction-$Sample-termios.json"
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 10
}

function Read-MoshSession {
    $text = Wait-ControlFile -Path $fixtureSession -TimeoutSeconds 20
    $portMatch = [regex]::Match($text, '(?m)^port=(?<value>\d{1,5})$')
    $serverPortMatch = [regex]::Match($text, '(?m)^serverPort=(?<value>\d{1,5})$')
    $pidMatch = [regex]::Match($text, '(?m)^pid=(?<value>\d+)$')
    $serverMatch = [regex]::Match($text, '(?m)^server=(?<value>[^\r\n]+)$')
    $keyDistinctMatch = [regex]::Match(
        $text,
        '(?m)^keyDistinctFromPrevious=(?<value>true|false)$'
    )
    $controlNameMatch = [regex]::Match(
        $text,
        '(?m)^controlName=(?<value>mosh-session-[1-9][0-9]*)$'
    )
    if (($Scenario -eq 'session-isolation' -and -not $controlNameMatch.Success) -or
        ($text -match '(?m)^controlName=' -and -not $controlNameMatch.Success)) {
        throw '[harness] Controlled Mosh session directory metadata is malformed'
    }
    if (-not $portMatch.Success -or -not $serverPortMatch.Success -or
        -not $pidMatch.Success -or -not $serverMatch.Success -or
        -not $keyDistinctMatch.Success) {
        throw '[harness] Controlled Mosh session metadata is malformed'
    }
    $port = [int]$portMatch.Groups['value'].Value
    $serverPort = [int]$serverPortMatch.Groups['value'].Value
    $sessionPid = [int]$pidMatch.Groups['value'].Value
    if ($port -lt $moshUdpPortMin -or $port -gt $moshUdpPortMax -or
        $serverPort -lt $moshUdpPortMin -or $serverPort -gt $moshUdpPortMax -or
        $sessionPid -le 0) {
        throw '[harness] Controlled Mosh session metadata is outside its contract'
    }
    return [pscustomobject]@{
        port = $port
        serverPort = $serverPort
        pid = $sessionPid
        serverPath = $serverMatch.Groups['value'].Value
        keyDistinctFromPrevious =
            ($keyDistinctMatch.Groups['value'].Value -ceq 'true')
        controlDirectory = $(if ($controlNameMatch.Success) {
            Join-Path $fixtureControl $controlNameMatch.Groups['value'].Value
        } else {
            $fixtureControl
        })
    }
}

function Test-WslProcessPresent {
    param([Parameter(Mandatory = $true)][int]$LinuxPid)
    $prefix = Get-LeanTTYWslPrefix -Distribution $Distribution
    & wsl.exe @prefix --exec kill -0 $LinuxPid 2>$null
    return $LASTEXITCODE -eq 0
}

function Wait-WslProcessAbsent {
    param([Parameter(Mandatory = $true)][int]$LinuxPid, [int]$TimeoutSeconds = 15)
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (-not (Test-WslProcessPresent -LinuxPid $LinuxPid)) {
            return [long]$stopwatch.Elapsed.TotalMilliseconds
        }
        Start-Sleep -Milliseconds 200
    }
    throw '[product] Mosh server remained after client disconnect'
}

function Read-ControlledLinuxPid {
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = Wait-ControlFile -Path $Path -TimeoutSeconds 20
    $parsed = 0
    if (-not [int]::TryParse($text.Trim(), [ref]$parsed) -or $parsed -le 0) {
        throw '[harness] Controlled Mosh terminal PID is malformed'
    }
    return $parsed
}

function Invoke-MoshWslRootBash {
    param([Parameter(Mandatory = $true)][string]$Script)
    $prefix = Get-LeanTTYWslPrefix -Distribution $Distribution
    $output = @(& wsl.exe @prefix --user root --exec bash -lc $Script 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw ('[infrastructure] WSL root network command failed: ' + ($output -join ' '))
    }
    return ($output -join "`n")
}

function Enable-MoshUdpImpairment {
    if ($moshServerPort -lt $moshUdpPortMin -or $moshServerPort -gt $moshUdpPortMax) {
        throw '[harness] Refusing to impair an unvalidated Mosh UDP port'
    }
    $qdiscs = Invoke-MoshWslRootBash -Script "tc qdisc show dev $udpImpairmentInterface"
    if ($qdiscs -match '(?m)\bclsact\b') {
        throw '[infrastructure] WSL eth0 already has clsact; refusing to overwrite external tc state'
    }
    Invoke-MoshWslRootBash -Script "tc qdisc add dev $udpImpairmentInterface clsact" | Out-Null
    $script:udpImpairmentOwnsQdisc = $true
    $script:udpImpairmentCleanupVerified = $false
    Invoke-MoshWslRootBash -Script (
        "tc filter add dev $udpImpairmentInterface ingress protocol ip pref " +
        "$udpImpairmentPreference flower ip_proto udp dst_port $moshServerPort action drop"
    ) | Out-Null
    Invoke-MoshWslRootBash -Script (
        "tc filter add dev $udpImpairmentInterface egress protocol ip pref " +
        "$udpImpairmentPreference flower ip_proto udp src_port $moshServerPort action drop"
    ) | Out-Null
    $ingress = Invoke-MoshWslRootBash -Script (
        "tc filter show dev $udpImpairmentInterface ingress pref $udpImpairmentPreference"
    )
    $egress = Invoke-MoshWslRootBash -Script (
        "tc filter show dev $udpImpairmentInterface egress pref $udpImpairmentPreference"
    )
    if ($ingress -notmatch "dst_port $moshServerPort" -or $ingress -notmatch '\bdrop\b' -or
        $egress -notmatch "src_port $moshServerPort" -or $egress -notmatch '\bdrop\b') {
        throw '[infrastructure] Exact Mosh UDP impairment filters were not observable'
    }
}

function Disable-MoshUdpImpairment {
    if (-not $udpImpairmentOwnsQdisc) { return }
    Invoke-MoshWslRootBash -Script "tc qdisc del dev $udpImpairmentInterface clsact" | Out-Null
    $script:udpImpairmentOwnsQdisc = $false
    $qdiscs = Invoke-MoshWslRootBash -Script "tc qdisc show dev $udpImpairmentInterface"
    if ($qdiscs -match '(?m)\bclsact\b') {
        throw '[infrastructure] Owned WSL Mosh UDP impairment remained after cleanup'
    }
    $script:udpImpairmentCleanupVerified = $true
}

function Read-MoshPredictionRelayDroppedPackets {
    $text = Wait-ControlFile -Path $fixturePredictionRelayStats -TimeoutSeconds 10
    $match = [regex]::Match($text, '(?m)^dropped=(?<value>\d+)$')
    if (-not $match.Success) {
        throw '[harness] Controlled Mosh prediction relay stats were malformed'
    }
    return [uint64]$match.Groups['value'].Value
}

function Enable-MoshPredictionRelayPause {
    if (Test-Path -LiteralPath $fixturePredictionRelayPause -PathType Leaf) {
        throw '[harness] Controlled Mosh prediction relay was already paused'
    }
    $script:predictionRelayDroppedPackets = Read-MoshPredictionRelayDroppedPackets
    [IO.File]::WriteAllText(
        $fixturePredictionRelayPause,
        "paused`n",
        [Text.UTF8Encoding]::new($false)
    )
    $script:udpImpairmentCleanupVerified = $false
}

function Wait-MoshPredictionRelayDrop {
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 5) {
        $dropped = Read-MoshPredictionRelayDroppedPackets
        if ($dropped -gt $predictionRelayDroppedPackets) {
            $script:predictionRelayDroppedPackets = $dropped
            return
        }
        Start-Sleep -Milliseconds 100
    }
    throw '[product] Mosh outage input did not reach the paused controlled UDP relay'
}

function Disable-MoshPredictionRelayPause {
    if (Test-Path -LiteralPath $fixturePredictionRelayPause -PathType Leaf) {
        Remove-Item -LiteralPath $fixturePredictionRelayPause -Force
    }
    if (Test-Path -LiteralPath $fixturePredictionRelayPause -PathType Leaf) {
        throw '[harness] Controlled Mosh prediction relay remained paused after cleanup'
    }
    $script:udpImpairmentCleanupVerified = $true
}

function Get-MoshLifecycleObservation {
    $logs = Get-LeanTTYAppLogs -Hdc $hdc -Target $targetId -ProcessId $appPid
    $interruption = [regex]::Match(
        $logs,
        'Mosh reachability state=interrupted reason=(?<reason>no_recent_contact|no_recent_reply)'
    )
    return [pscustomobject]@{
        logs = $logs
        closed = ($logs -match 'Mosh Session closed')
        error = ($logs -match 'Mosh error stage=')
        interrupted = $interruption.Success
        interruptionReason = $(if ($interruption.Success) {
            $interruption.Groups['reason'].Value
        } else { 'not-observed' })
        recovered = ($logs -match 'Mosh reachability state=responsive transition=recovered')
    }
}

function Get-MoshAppProcessIdentity {
    $processId = (@(& $hdc -t $targetId shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or $processId -notmatch '^\d+$') {
        return $null
    }
    $stat = (@(& $hdc -t $targetId shell "cat /proc/$processId/stat" 2>&1) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0) {
        throw '[infrastructure] Unable to read LeanTTY process start identity'
    }
    $commandEnd = $stat.LastIndexOf(') ')
    if ($commandEnd -lt 0) {
        throw '[infrastructure] LeanTTY process identity has an invalid /proc stat shape'
    }
    $fieldsFromState = @($stat.Substring($commandEnd + 2) -split '\s+')
    if ($fieldsFromState.Count -lt 20 -or $fieldsFromState[19] -notmatch '^\d+$') {
        throw '[infrastructure] LeanTTY process identity is missing the /proc start time'
    }
    $startTimeTicks = [string]$fieldsFromState[19]
    return [pscustomobject]@{
        processId = $processId
        startTimeTicks = $startTimeTicks
        key = $processId + ':' + $startTimeTicks
    }
}

function Test-MoshDeviceLocked {
    param([switch]$TolerateUnavailable)
    $launchOutput = @(
        & $hdc -t $targetId shell 'aa start -a EntryAbility -b com.leantty.app' 2>&1
    ) -join "`n"
    $launchExitCode = $LASTEXITCODE
    if ($launchOutput -match 'Error Code:10106102|device screen is locked') {
        return $true
    }
    if ($launchExitCode -ne 0 -or $launchOutput -match '(?i)\[Fail\]|error') {
        if ($TolerateUnavailable) { return $null }
        throw '[infrastructure] Unable to observe the operator-controlled device lock state'
    }
    return $false
}

function Wait-MoshDeviceLockState {
    param(
        [Parameter(Mandatory = $true)][bool]$ExpectedLocked,
        [switch]$TolerateUnavailable,
        [switch]$UnavailableCountsAsLocked
    )
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $OperatorWaitSeconds) {
        $locked = Test-MoshDeviceLocked -TolerateUnavailable:$TolerateUnavailable
        if ($null -eq $locked) {
            if ($ExpectedLocked -and $UnavailableCountsAsLocked) {
                $script:operatorDeviceInactiveState = 'unavailable'
                return [long]$stopwatch.Elapsed.TotalMilliseconds
            }
            Start-Sleep -Milliseconds 500
            continue
        }
        if ($locked -eq $ExpectedLocked) {
            if ($ExpectedLocked) { $script:operatorDeviceInactiveState = 'locked' }
            return [long]$stopwatch.Elapsed.TotalMilliseconds
        }
        Start-Sleep -Milliseconds 500
    }
    $expected = if ($ExpectedLocked) { 'lock' } else { 'unlock' }
    throw "[environment] Operator did not complete the requested device $expected action in time"
}

function Get-MoshCloseProtocolElapsedMs {
    param(
        [Parameter(Mandatory = $true)][string]$Logs,
        [Parameter(Mandatory = $true)][long]$FallbackElapsedMs
    )
    $escape = [regex]::Match(
        $Logs,
        '(?m)^(?<stamp>\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}).*Mosh escape action=disconnect$'
    )
    $closed = [regex]::Match(
        $Logs,
        '(?m)^(?<stamp>\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}).*Mosh Session closed$'
    )
    if (-not $escape.Success -or -not $closed.Success) { return $FallbackElapsedMs }
    $format = 'yyyy-MM-dd HH:mm:ss.fff'
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $year = [DateTimeOffset]::Now.Year
    $started = [DateTime]::ParseExact("$year-$($escape.Groups['stamp'].Value)", $format, $culture)
    $completed = [DateTime]::ParseExact("$year-$($closed.Groups['stamp'].Value)", $format, $culture)
    if ($completed -lt $started) { return $FallbackElapsedMs }
    return [long]($completed - $started).TotalMilliseconds
}

function Focus-ActiveTerminalInput {
    param([Parameter(Mandatory = $true)][string]$Name)
    $layoutPath = Join-Path $EvidenceDirectory $Name
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 10) {
        $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $targetId -LocalPath $layoutPath
        $nodes = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
        $focused = @($nodes | Where-Object { [string]$_.attributes.focused -eq 'true' })
        $node = if ($focused.Count -eq 1) { $focused[0] } elseif ($nodes.Count -eq 1) {
            $nodes[0]
        } else { $null }
        if ($null -ne $node) {
            if ([string]$node.attributes.focused -ne 'true') {
                Set-LeanTTYTerminalInputFocus -Hdc $hdc -Target $targetId `
                    -InputNode $node -LocalPath $layoutPath -TimeoutSeconds 10 | Out-Null
            }
            return $node
        }
        Start-Sleep -Milliseconds 200
    }
    throw '[environment] Unable to identify the active LeanTTY terminal input'
}

function Submit-LocalCommand {
    param([Parameter(Mandatory = $true)][string]$Command, [string]$Stage = 'mosh-command')
    Submit-LeanTTYDeviceCommand -Hdc $hdc -Target $targetId -ProcessId $appPid `
        -Command $Command -Stage $Stage -ObservationSink $commandObservations `
        -InputNodeProvider {
            param($inputAttempt)
            Focus-ActiveTerminalInput -Name ($Stage + '-focus-' + $inputAttempt + '.json')
        } | Out-Null
}

function Submit-InteractiveValue {
    param([Parameter(Mandatory = $true)][string]$Value, [string]$Name = 'interactive')
    $node = Focus-ActiveTerminalInput -Name ($Name + '-focus.json')
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
    Invoke-LeanTTYDeviceText -Hdc $hdc -Target $targetId -Text $Value -InputNode $node
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $targetId -KeyCode 2054
}

function Read-MoshInputSnapshot {
    param([string]$ControlDirectory = $activeMoshControlDirectory)
    $inputSnapshotPath = Join-Path $ControlDirectory 'mosh-input-snapshot'
    if (-not (Test-Path -LiteralPath $inputSnapshotPath -PathType Leaf)) {
        return [pscustomobject]@{ observed = $false; value = '' }
    }
    try {
        return [pscustomobject]@{
            observed = $true
            value = Read-LeanTTYSharedTextFile -Path $inputSnapshotPath
        }
    } catch [IO.IOException] {
        return [pscustomobject]@{ observed = $false; value = '' }
    }
}

function Wait-MoshInputSnapshot {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Expected,
        [string]$ControlDirectory = $activeMoshControlDirectory
    )
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 8) {
        $snapshot = Read-MoshInputSnapshot -ControlDirectory $ControlDirectory
        if ($snapshot.observed -and [string]$snapshot.value -ceq $Expected) { return $snapshot }
        Start-Sleep -Milliseconds 100
    }
    return Read-MoshInputSnapshot -ControlDirectory $ControlDirectory
}

function Submit-MoshInput {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$ControlDirectory = $activeMoshControlDirectory
    )
    $observation = [ordered]@{
        stage = 'mosh-shell-command'
        result = 'running'
        inputAttempts = 0
        inputMismatches = 0
        expectedLength = $Text.Length
        actualLength = 0
        firstMismatchIndex = $null
        enterCount = 0
        lastProvenBoundary = 'none'
    }
    try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $observation.inputAttempts = $attempt
            $node = Focus-ActiveTerminalInput -Name "mosh-connected-focus-$attempt.json"
            Invoke-LeanTTYDeviceText -Hdc $hdc -Target $targetId -Text $Text -InputNode $node
            $snapshot = Wait-MoshInputSnapshot -Expected $Text `
                -ControlDirectory $ControlDirectory
            $actual = if ($snapshot.observed) { [string]$snapshot.value } else { '' }
            $observation.actualLength = $actual.Length
            if ($actual -ceq $Text) {
                $observation.lastProvenBoundary = 'server-input-exact-before-enter'
                Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $targetId -KeyCode 2054
                $observation.enterCount = 1
                $observation.lastProvenBoundary = 'enter-dispatched-after-server-input-exact'
                $observation.result = 'passed'
                return
            }
            $idleState = Get-LeanTTYAcceptanceIdleInputState -Logs (
                Get-LeanTTYAppLogs -Hdc $hdc -Target $targetId -ProcessId $appPid
            )
            if ($null -ne $idleState -and [string]$idleState.input -ceq $Text) {
                throw '[product] LeanTTY input returned to the local prompt while the Mosh Session was expected'
            }
            $observation.inputMismatches++
            $observation.firstMismatchIndex = Get-LeanTTYTextMismatchIndex `
                -Expected $Text -Actual $actual
            if ($attempt -lt 3) {
                Focus-ActiveTerminalInput `
                    -Name "mosh-retry-interrupt-focus-$attempt.json" | Out-Null
                Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $targetId
                $cleared = Wait-MoshInputSnapshot -Expected '' `
                    -ControlDirectory $ControlDirectory
                if (-not $cleared.observed -or [string]$cleared.value -cne '') {
                    throw '[harness] Controlled Mosh input did not clear before retry'
                }
            }
        }
        throw '[harness] Controlled Mosh input could not be made exact before Enter'
    } finally {
        if ($observation.result -eq 'running') { $observation.result = 'failed' }
        $connectedInputObservations.Add([pscustomobject]$observation) | Out-Null
    }
}

function Submit-MoshChildInput {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [bool]$Submit = $true,
        [string]$Name = 'mosh-child-input'
    )
    $node = Focus-ActiveTerminalInput -Name ($Name + '.json')
    Invoke-LeanTTYDeviceText -Hdc $hdc -Target $targetId -Text $Text -InputNode $node
    if ($Submit) {
        Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $targetId -KeyCode 2054
    }
}

function Submit-MoshPredictionAscii {
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[a-z]$')][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name
    )
    Invoke-LeanTTYSerializedUiTest `
        -Hdc $hdc `
        -Target $targetId `
        -Arguments @('uiInput', 'text', $Text) `
        -Operation "Mosh prediction ASCII injection $Name" | Out-Null
}

function Submit-MoshCanonicalCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $node = Focus-ActiveTerminalInput -Name "$Name-focus.json"
    Invoke-LeanTTYDeviceText -Hdc $hdc -Target $targetId -Text $Text -InputNode $node
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $targetId -KeyCode 2054
}

function Submit-MoshShellMarker {
    param(
        [Parameter(Mandatory = $true)][string]$WindowsPath,
        [Parameter(Mandatory = $true)][string]$WslPath,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($WslPath -notmatch '^/[A-Za-z0-9_./-]+$' -or
        (Test-Path -LiteralPath $WindowsPath)) {
        throw '[harness] Mosh shell marker path was not a fresh shell-safe absolute path'
    }
    Submit-MoshCanonicalCommand -Text "touch -- $WslPath" -Name $Name
    Wait-ControlFile -Path $WindowsPath -TimeoutSeconds 10 | Out-Null
}

function ConvertFrom-MoshHilogTimestamp {
    param([Parameter(Mandatory = $true)][string]$Timestamp)
    return [DateTime]::ParseExact(
        "2000-$Timestamp",
        'yyyy-MM-dd HH:mm:ss.fff',
        [Globalization.CultureInfo]::InvariantCulture
    )
}

function Get-MoshPredictionTiming {
    param(
        [Parameter(Mandatory = $true)][string]$Logs,
        [Parameter(Mandatory = $true)][ValidateSet('always', 'never')][string]$Mode
    )
    if ($Logs -match 'Mosh terminal resized:') {
        throw '[harness] Prediction measurement was invalidated by a terminal resize'
    }
    $input = [regex]::Match(
        $Logs,
        '(?m)^(?<timestamp>\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d{3}).*D: 1 chars, mode=3\s*$'
    )
    $output = [regex]::Match(
        $Logs,
        "(?m)^(?<timestamp>\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d{3}).*" +
        "ACCEPTANCE_MOSH_OUTPUT mode=$Mode,bytes=[1-9][0-9]*\s*$"
    )
    $render = [regex]::Match(
        $Logs,
        '(?m)^(?<timestamp>\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d{3}).*' +
        'ACCEPTANCE_TERMINAL_WRITE_ACK bytes=[1-9][0-9]*\s*$'
    )
    if (-not $input.Success -or -not $output.Success -or -not $render.Success) {
        throw '[harness] Prediction timing did not contain one input, public VT output and renderer ACK'
    }
    $inputTime = ConvertFrom-MoshHilogTimestamp -Timestamp $input.Groups['timestamp'].Value
    $outputTime = ConvertFrom-MoshHilogTimestamp -Timestamp $output.Groups['timestamp'].Value
    $renderTime = ConvertFrom-MoshHilogTimestamp -Timestamp $render.Groups['timestamp'].Value
    if ($outputTime -lt $inputTime) { $outputTime = $outputTime.AddYears(1) }
    if ($renderTime -lt $inputTime) { $renderTime = $renderTime.AddYears(1) }
    return [pscustomobject][ordered]@{
        visibleLatencyMs = [long]($outputTime - $inputTime).TotalMilliseconds
        renderLatencyMs = [long]($renderTime - $inputTime).TotalMilliseconds
    }
}

function Invoke-MoshPredictionProbe {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('always', 'never')][string]$Mode,
        [Parameter(Mandatory = $true)][ValidatePattern('^[a-z]{6,16}$')][string]$Marker,
        [Parameter(Mandatory = $true)][bool]$ExpectVisible
    )
    $initial = Wait-MoshInputSnapshot -Expected ''
    if (-not $initial.observed -or [string]$initial.value -cne '') {
        throw '[harness] Prediction measurement did not start from an untouched remote input line'
    }
    Focus-ActiveTerminalInput -Name "mosh-prediction-$Mode-measurement-focus.json" | Out-Null
    Start-Sleep -Milliseconds 500

    $confirmedPrefix = ''
    $predictionObserved = $false
    $warmupLimit = if ($ExpectVisible) { $Marker.Length - 1 } else { 1 }
    for ($index = 0; $index -lt $warmupLimit; $index++) {
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
        $nextCharacter = $Marker.Substring($index, 1)
        $confirmedPrefix += $nextCharacter
        Submit-MoshPredictionAscii -Text $nextCharacter `
            -Name "mosh-prediction-$Mode-warmup-$index"
        $logs = Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
            -Pattern "ACCEPTANCE_MOSH_OUTPUT mode=$Mode,bytes=[1-9][0-9]*" `
            -TimeoutSeconds 10
        $logs = Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
            -Pattern 'ACCEPTANCE_TERMINAL_WRITE_ACK bytes=[1-9][0-9]*' -TimeoutSeconds 10
        $timing = Get-MoshPredictionTiming -Logs $logs -Mode $Mode
        $predictionWarmupSamples.Add([pscustomobject][ordered]@{
            mode = $Mode
            byteIndex = $index + 1
            visibleLatencyMs = $timing.visibleLatencyMs
            renderLatencyMs = $timing.renderLatencyMs
        }) | Out-Null
        if ($index -eq 0 -and $ExpectVisible) {
            $script:predictionRttBaselineMs = $timing.visibleLatencyMs
            if ($predictionRttBaselineMs -le $predictionRelayDelayMs) {
                throw '[harness] Controlled prediction relay delay was not observable in authoritative VT output'
            }
            $script:predictionConfirmationThresholdMs = $predictionRelayDelayMs
        } elseif ($ExpectVisible -and
            $timing.visibleLatencyMs -lt $predictionConfirmationThresholdMs) {
            $script:predictionVisibleLatencyMs = $timing.visibleLatencyMs
            $script:predictionRenderLatencyMs = $timing.renderLatencyMs
            $predictionObserved = $true
            break
        }
    }
    if ($ExpectVisible -and -not $predictionObserved) {
        throw '[product] Always did not produce actual VT output below the measured RTT'
    }

    # Match the upstream full-loss fixture: let the confirmed epoch settle, pause
    # both relay directions, then drain any packet that was already in flight.
    Start-Sleep -Milliseconds 400
    $outageCharacter = $Marker.Substring($confirmedPrefix.Length, 1)
    Enable-MoshPredictionRelayPause
    try {
        Start-Sleep -Milliseconds 300
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
        Submit-MoshPredictionAscii -Text $outageCharacter `
            -Name "mosh-prediction-$Mode-outage-ascii"
        if ($ExpectVisible) {
            $logs = Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
                -Pattern "ACCEPTANCE_MOSH_OUTPUT mode=$Mode,bytes=[1-9][0-9]*" `
                -TimeoutSeconds 10
            $logs = Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
                -Pattern 'ACCEPTANCE_TERMINAL_WRITE_ACK bytes=[1-9][0-9]*' -TimeoutSeconds 10
            $timing = Get-MoshPredictionTiming -Logs $logs -Mode $Mode
            if ($timing.visibleLatencyMs -gt 250) {
                throw '[product] Always prediction exceeded the bounded full-loss visibility interval'
            }
            $script:predictionOutageVisibleLatencyMs = $timing.visibleLatencyMs
            $script:predictionOutageRenderLatencyMs = $timing.renderLatencyMs
        } else {
            Start-Sleep -Milliseconds 1500
            $blockedLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $targetId -ProcessId $appPid
            if ($blockedLogs -match 'Mosh terminal resized:') {
                throw '[harness] Never prediction measurement was invalidated by a terminal resize'
            }
            if ($blockedLogs -match "ACCEPTANCE_MOSH_OUTPUT mode=$Mode,bytes=[1-9][0-9]*") {
                throw '[product] Never prediction emitted terminal output before remote authority'
            }
        }
        Wait-MoshPredictionRelayDrop
    } finally {
        Disable-MoshPredictionRelayPause
    }

    # Control-U and Enter are deliberately sent only after measurement and UDP
    # recovery. Match the upstream stock shell fixture: discard the probe line,
    # then use the real interactive shell to persist exact convergence evidence.
    Start-Sleep -Milliseconds 500
    Invoke-LeanTTYSerializedUiTest `
        -Hdc $hdc `
        -Target $targetId `
        -Arguments @('uiInput', 'keyEvent', 2072, 2037) `
        -Operation 'Mosh prediction Ctrl+U injection' | Out-Null
    $expectedAuthority = $confirmedPrefix + $outageCharacter
    $predictionEventPath = "$fixturePredictionEvent-$expectedAuthority"
    $predictionEventWslPath = "$fixturePredictionEventWsl-$expectedAuthority"
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
    Submit-MoshShellMarker -WindowsPath $predictionEventPath -WslPath $predictionEventWslPath `
        -Name "mosh-prediction-$Mode-authority"
    Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
        -Pattern "ACCEPTANCE_MOSH_OUTPUT mode=$Mode,bytes=[1-9][0-9]*" `
        -TimeoutSeconds 10 | Out-Null
    Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
        -Pattern 'ACCEPTANCE_TERMINAL_WRITE_ACK bytes=[1-9][0-9]*' -TimeoutSeconds 10 | Out-Null
    return [pscustomobject][ordered]@{
        confirmedPrefix = $confirmedPrefix
        outageCharacter = $outageCharacter
        authoritativeValue = $expectedAuthority
    }
}

function Clear-MoshSessionControlFiles {
    foreach ($path in @(
        $fixtureSession,
        $fixtureInputSnapshot,
        $fixtureEvent,
        $fixturePredictionEvent,
        $fixtureTerminalReady,
        $fixtureTerminalPidPath
    )) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}

function Clear-MoshLatestSessionMetadata {
    if (Test-Path -LiteralPath $fixtureSession -PathType Leaf) {
        Remove-Item -LiteralPath $fixtureSession -Force
    }
}

function Submit-MoshStreamPayload {
    param([Parameter(Mandatory = $true)][string]$Text)
    $node = Focus-ActiveTerminalInput -Name 'mosh-stream-input.json'
    Invoke-LeanTTYDeviceText -Hdc $hdc -Target $targetId -Text $Text -InputNode $node
    $snapshot = Wait-MoshInputSnapshot -Expected $Text
    if (-not $snapshot.observed -or [string]$snapshot.value -cne $Text) {
        throw '[harness] Controlled Mosh stream input did not reach the remote PTY exactly'
    }
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $targetId -KeyCode 2054
}

function Get-MoshWindowToggleButton {
    param([Parameter(Mandatory = $true)]$Layout)
    $buttons = @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object {
        [string]$_.attributes.id -match '^Enhance(?:Maximize|Recover)Btn$' -and
        [string]$_.attributes.clickable -eq 'true'
    })
    if ($buttons.Count -ne 1) {
        throw "[harness] Expected one HarmonyOS window size toggle, found $($buttons.Count)"
    }
    return $buttons[0]
}

function Toggle-MoshWindowSize {
    param([Parameter(Mandatory = $true)][string]$Name)
    $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $targetId `
        -LocalPath (Join-Path $EvidenceDirectory "$Name.json") -BundleName ''
    $button = Get-MoshWindowToggleButton -Layout $layout
    $center = Get-LeanTTYBoundsCenter -Bounds ([string]$button.attributes.bounds)
    Invoke-LeanTTYDeviceClick -Hdc $hdc -Target $targetId -X $center.x -Y $center.y `
        -Operation "Toggle HarmonyOS window size for $Name"
}

function Get-MoshPreferencesDigest {
    $preferencesPath = '/data/app/el2/100/base/com.leantty.app/haps/entry/preferences/leantty_settings'
    $output = @(& $hdc -t $targetId shell -b com.leantty.app "sha256sum $preferencesPath" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw '[harness] Unable to compute the LeanTTY Preferences digest'
    }
    $match = [regex]::Match(
        ($output -join "`n").Trim(),
        '^(?<digest>[0-9a-fA-F]{64})\s+/data/app/el2/100/base/com\.leantty\.app/haps/entry/preferences/leantty_settings$'
    )
    if (-not $match.Success) { throw '[harness] Unexpected LeanTTY Preferences digest response' }
    return $match.Groups['digest'].Value.ToLowerInvariant()
}

function Get-MoshTerminalSearchResultLabel {
    param([Parameter(Mandatory = $true)]$Layout)
    $nodes = @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object {
        [string]$_.attributes.visible -eq 'true' -and
        ([string]$_.attributes.text -match '^(?:No results|未找到结果|[1-9][0-9]*/[1-9][0-9]*)$' -or
            [string]$_.attributes.originalText -match '^(?:No results|未找到结果|[1-9][0-9]*/[1-9][0-9]*)$')
    })
    if ($nodes.Count -ne 1) { return '' }
    $text = [string]$nodes[0].attributes.text
    if (-not [string]::IsNullOrWhiteSpace($text)) { return $text }
    return [string]$nodes[0].attributes.originalText
}

function Test-MoshTerminalSearch {
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $true)][bool]$ExpectMatch,
        [Parameter(Mandatory = $true)][string]$Name
    )
    Focus-ActiveTerminalInput -Name "$Name-before.json" | Out-Null
    & $hdc -t $targetId shell 'uitest uiInput keyEvent 2072 2045 2022' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '[environment] Unable to open terminal search' }
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $input = $null
    while ($stopwatch.Elapsed.TotalSeconds -lt 15) {
        $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $targetId `
            -LocalPath (Join-Path $EvidenceDirectory "$Name-open.json")
        $inputs = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
            [string]$_.attributes.type -eq 'textField' -and
            [string]$_.attributes.hint -match '^(?:Find text|Search text|查找内容)' -and
            [string]$_.attributes.visible -eq 'true'
        })
        if ($inputs.Count -eq 1) { $input = $inputs[0]; break }
        Start-Sleep -Milliseconds 200
    }
    if ($null -eq $input) { throw '[product] Terminal search did not open over Mosh output' }
    Invoke-LeanTTYDeviceText -Hdc $hdc -Target $targetId -Text $Query -InputNode $input
    $expected = if ($ExpectMatch) { '^[1-9][0-9]*/[1-9][0-9]*$' } else { '^(?:No results|未找到结果)$' }
    $matchedState = $false
    $stopwatch.Restart()
    while ($stopwatch.Elapsed.TotalSeconds -lt 15) {
        $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $targetId `
            -LocalPath (Join-Path $EvidenceDirectory "$Name-result.json")
        $label = Get-MoshTerminalSearchResultLabel -Layout $layout
        if ($label -match $expected) { $matchedState = $true; break }
        Start-Sleep -Milliseconds 200
    }
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $targetId -KeyCode 2070
    if (-not $matchedState) {
        throw "[product] Terminal search result did not satisfy the Mosh query contract: $Name"
    }
    return $true
}

function Assert-MoshTerminalSurfaceFocused {
    $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $targetId `
        -LocalPath (Join-Path $EvidenceDirectory 'mosh-physical-key-focus.json')
    $inputs = @(Get-LeanTTYTerminalInputNodes -Layout $layout | Where-Object {
        [string]$_.attributes.focused -eq 'true'
    })
    if ($inputs.Count -eq 1) { return }
    $webs = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
        [string]$_.attributes.type -eq 'Web' -and
        [string]$_.attributes.visible -eq 'true' -and
        [string]$_.attributes.focused -eq 'true' -and
        [string]$_.attributes.originalText -match 'terminal\.html$'
    })
    if ($webs.Count -eq 1) { return }
    throw '[environment] Active Mosh terminal surface was not focused for physical key input'
}

function Wait-MoshPaneCount {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 2)][int]$Count,
        [Parameter(Mandatory = $true)][string]$Name
    )
    return Wait-LeanTTYTerminalInputCount `
        -Hdc $hdc -Target $targetId `
        -LocalPath (Join-Path $EvidenceDirectory "$Name.json") `
        -Count $Count -TimeoutSeconds 20
}

function Get-MoshFullDeviceLayout {
    param([Parameter(Mandatory = $true)][string]$Name)

    return Get-LeanTTYDeviceLayout `
        -Hdc $hdc -Target $targetId `
        -LocalPath (Join-Path $EvidenceDirectory "$Name.json") `
        -BundleName ''
}

function Get-MoshWifiToggle {
    param([Parameter(Mandatory = $true)]$Layout)

    return @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object {
        [string]$_.attributes.id -eq 'entry_toggle_wifi_switch' -and
        [string]$_.attributes.type -eq 'Toggle' -and
        [string]$_.attributes.visible -eq 'true' -and
        [string]$_.attributes.clickable -eq 'true'
    })
}

function Test-MoshWifiIpv4Active {
    $ifconfig = Invoke-HdcChecked `
        -Hdc $hdc -Target $targetId `
        -Arguments @('shell', 'ifconfig') `
        -Operation 'HarmonyOS Wi-Fi interface query'
    $wlan = [regex]::Match($ifconfig, '(?ms)^wlan0\s+.*?(?=^\S|\z)')
    return $wlan.Success -and $wlan.Value.Contains('inet addr:') -and $wlan.Value.Contains('UP')
}

function Set-MoshDeviceWifi {
    param(
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $layout = Get-MoshFullDeviceLayout -Name "$Name-before"
    $toggles = @(Get-MoshWifiToggle -Layout $layout)
    if ($toggles.Count -eq 0) {
        $panelButtons = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
            [string]$_.attributes.id -eq 'PluginRootComponent_Stack_status_bar_wifi_panel' -and
            [string]$_.attributes.visible -eq 'true' -and
            [string]$_.attributes.clickable -eq 'true'
        })
        if ($panelButtons.Count -ne 1) {
            throw '[environment] HarmonyOS Wi-Fi panel button was unavailable'
        }
        $panelCenter = Get-LeanTTYBoundsCenter -Bounds ([string]$panelButtons[0].attributes.bounds)
        Invoke-LeanTTYDeviceClick `
            -Hdc $hdc -Target $targetId -X $panelCenter.x -Y $panelCenter.y `
            -Operation 'Open HarmonyOS Wi-Fi panel'
        Start-Sleep -Milliseconds 500
        $layout = Get-MoshFullDeviceLayout -Name "$Name-panel"
        $toggles = @(Get-MoshWifiToggle -Layout $layout)
    }
    if ($toggles.Count -ne 1) {
        throw "[environment] Expected one visible HarmonyOS Wi-Fi toggle, found $($toggles.Count)"
    }

    $currentEnabled = [string]$toggles[0].attributes.checked -eq 'true'
    if ($currentEnabled -ne $Enabled) {
        $toggleCenter = Get-LeanTTYBoundsCenter -Bounds ([string]$toggles[0].attributes.bounds)
        Invoke-LeanTTYDeviceClick `
            -Hdc $hdc -Target $targetId -X $toggleCenter.x -Y $toggleCenter.y `
            -Operation $(if ($Enabled) { 'Enable HarmonyOS Wi-Fi' } else { 'Disable HarmonyOS Wi-Fi' })
    }

    $toggleMatches = $false
    $networkMatches = $false
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Milliseconds 500
        $stateLayout = Get-MoshFullDeviceLayout -Name "$Name-state"
        $stateToggles = @(Get-MoshWifiToggle -Layout $stateLayout)
        $toggleMatches = $stateToggles.Count -eq 1 -and
            (([string]$stateToggles[0].attributes.checked -eq 'true') -eq $Enabled)
        $networkMatches = (Test-MoshWifiIpv4Active) -eq $Enabled
        if ($toggleMatches -and $networkMatches) { break }
    } while ($stopwatch.Elapsed.TotalSeconds -lt 25)
    if (-not $toggleMatches -or -not $networkMatches) {
        throw "[environment] HarmonyOS Wi-Fi did not reach enabled=$Enabled"
    }

    $script:wifiDisabledByScenario = -not $Enabled
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $targetId -KeyCode 2070
    Start-Sleep -Milliseconds 300
}

function Wait-MoshWifiInterruptionOutcome {
    param([ValidateRange(1, 30)][int]$TimeoutSeconds = 20)

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $logs = Get-LeanTTYAppLogs -Hdc $hdc -Target $targetId -ProcessId $appPid
        if ($logs -match 'Mosh error stage=mosh_udp') {
            return [pscustomobject]@{ outcome = 'fatal-udp-error'; logs = $logs }
        }
        if ($logs -match 'Mosh reachability state=interrupted reason=no_recent_contact') {
            return [pscustomobject]@{ outcome = 'interrupted'; logs = $logs }
        }
        Start-Sleep -Milliseconds 500
    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw '[harness] Timed out waiting for a Mosh Wi-Fi interruption outcome'
}

function Focus-MoshPane {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('left', 'right')][string]$Side,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $layoutPath = Join-Path $EvidenceDirectory "$Name.json"
    $index = if ($Side -eq 'left') { 0 } else { 1 }
    $keyCode = if ($Side -eq 'left') { 2014 } else { 2015 }
    & $hdc -t $targetId shell (
        "uinput -K -d 2072 -d 2045 -d $keyCode -u $keyCode -u 2045 -u 2072"
    ) | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "[environment] Unable to invoke the LeanTTY $Side Pane focus shortcut"
    }

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $targetId -LocalPath $layoutPath
        $nodes = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
        if ($nodes.Count -eq 2 -and
            [string]$nodes[$index].attributes.focused -eq 'true' -and
            [string]$nodes[1 - $index].attributes.focused -ne 'true') {
            return
        }
        Start-Sleep -Milliseconds 200
    } while ($stopwatch.Elapsed.TotalSeconds -lt 10)
    throw "[environment] Timed out focusing the $Side Mosh isolation Pane"
}

function Invoke-MoshSurfaceRebuild {
    Focus-ActiveTerminalInput -Name 'mosh-surface-rebuild-before-menu.json' | Out-Null
    $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $targetId `
        -LocalPath (Join-Path $EvidenceDirectory 'mosh-surface-rebuild-before-menu.json')
    $roots = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
        [string]$_.attributes.bundleName -eq 'com.leantty.app' -and
        [string]$_.attributes.type -eq 'root'
    })
    if ($roots.Count -ne 1) { throw '[harness] LeanTTY root was not found before Surface rebuild' }
    $windowId = [string]$roots[0].attributes.hostWindowId
    $minimize = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
        [string]$_.attributes.hostWindowId -eq $windowId -and
        [string]$_.attributes.id -eq 'EnhanceMinimizeBtn'
    })
    if ($minimize.Count -ne 1) { throw '[harness] LeanTTY window controls were not found' }
    $minimizeBounds = [regex]::Match(
        [string]$minimize[0].attributes.bounds,
        '^\[(?<x1>\d+),(?<y1>\d+)\]\[(?<x2>\d+),(?<y2>\d+)\]$'
    )
    $buttons = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
        $bounds = [regex]::Match(
            [string]$_.attributes.bounds,
            '^\[(?<x1>\d+),(?<y1>\d+)\]\[(?<x2>\d+),(?<y2>\d+)\]$'
        )
        [string]$_.attributes.hostWindowId -eq $windowId -and
        [string]$_.attributes.clickable -eq 'true' -and
        [string]$_.attributes.id -notmatch '^Enhance' -and $bounds.Success -and
        [int]$bounds.Groups['y1'].Value -lt [int]$minimizeBounds.Groups['y2'].Value -and
        [int]$bounds.Groups['x2'].Value -le [int]$minimizeBounds.Groups['x1'].Value
    } | Sort-Object {
        [int]([regex]::Match(
            [string]$_.attributes.bounds,
            '^\[(?<x1>\d+),'
        ).Groups['x1'].Value)
    } -Descending)
    if ($buttons.Count -eq 0) { throw '[harness] LeanTTY menu button was not found' }
    $menuCenter = Get-LeanTTYBoundsCenter -Bounds ([string]$buttons[0].attributes.bounds)
    Invoke-LeanTTYDeviceClick -Hdc $hdc -Target $targetId `
        -X $menuCenter.x -Y $menuCenter.y -Operation 'Open LeanTTY acceptance menu'
    Start-Sleep -Milliseconds 300

    $menuLayout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $targetId `
        -LocalPath (Join-Path $EvidenceDirectory 'mosh-surface-rebuild-menu.json')
    $actions = @(Get-LeanTTYLayoutNodes -Node $menuLayout | Where-Object {
        [string]$_.attributes.visible -eq 'true' -and
        ([string]$_.attributes.text -eq 'Acceptance: Rebuild Renderer' -or
            [string]$_.attributes.originalText -eq 'Acceptance: Rebuild Renderer')
    })
    if ($actions.Count -ne 1) {
        throw '[harness] Acceptance renderer rebuild action was not found'
    }
    $actionCenter = Get-LeanTTYBoundsCenter -Bounds ([string]$actions[0].attributes.bounds)
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
    Invoke-LeanTTYDeviceClick -Hdc $hdc -Target $targetId `
        -X $actionCenter.x -Y $actionCenter.y -Operation 'Rebuild active Mosh terminal renderer'
    Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
        -Pattern 'Acceptance renderer rebuild requested=true' -TimeoutSeconds 15 | Out-Null
    Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
        -Pattern 'Web terminal ready' -TimeoutSeconds 20 | Out-Null
}

function Invoke-MoshPageRebuild {
    Focus-ActiveTerminalInput -Name 'mosh-page-rebuild-before.json' | Out-Null
    $before = Get-MoshAppProcessIdentity
    if ($null -eq $before) {
        throw '[infrastructure] LeanTTY process identity disappeared before page replacement'
    }
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
    & $hdc -t $targetId shell (
        'uinput -K -d 2072 -d 2045 -d 2047 -d 2036 ' +
        '-u 2036 -u 2047 -u 2045 -u 2072'
    ) | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw '[environment] Unable to invoke the LeanTTY page rebuild shortcut'
    }
    Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
        -Pattern 'Acceptance page rebuild requested=true' -TimeoutSeconds 15 | Out-Null
    Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
        -Pattern 'Index page destroyed; application workspace retained' -TimeoutSeconds 15 | Out-Null
    Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
        -Pattern 'Index page initialized workspace=reused' -TimeoutSeconds 15 | Out-Null
    Wait-LeanTTYTerminalInputLayout -Hdc $hdc -Target $targetId `
        -LocalPath (Join-Path $EvidenceDirectory 'mosh-page-rebuild-after.json') `
        -TimeoutSeconds 20 | Out-Null
    $after = Get-MoshAppProcessIdentity
    if ($null -eq $after -or [string]$after.key -cne [string]$before.key) {
        throw '[product] Acceptance page replacement changed the LeanTTY process'
    }
    return [pscustomobject]@{ before = $before; after = $after }
}

function Split-MoshPane {
    Focus-ActiveTerminalInput -Name 'mosh-pane-close-before-split.json' | Out-Null
    & $hdc -t $targetId shell (
        'uinput -K -d 2072 -d 2047 -d 2020 -u 2020 -u 2047 -u 2072'
    ) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '[environment] Unable to invoke the LeanTTY split shortcut' }
    Wait-MoshPaneCount -Count 2 -Name 'mosh-pane-close-after-split' | Out-Null
}

function Close-ActiveMoshPane {
    $layout = Wait-MoshPaneCount -Count 2 -Name 'mosh-pane-close-before'
    $button = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
        [string]$_.attributes.text -eq '×' -and
        [string]$_.attributes.clickable -eq 'true' -and
        [string]$_.attributes.visible -eq 'true'
    } | Select-Object -First 1)
    if ($button.Count -ne 1) { throw '[harness] LeanTTY active-Pane close button was not found' }
    $center = Get-LeanTTYBoundsCenter -Bounds ([string]$button[0].attributes.bounds)
    Invoke-LeanTTYDeviceClick -Hdc $hdc -Target $targetId -X $center.x -Y $center.y `
        -Operation 'LeanTTY active Mosh Pane close button'

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 10) {
        try {
            Invoke-LeanTTYDialogButton `
                -Hdc $hdc -Target $targetId -ButtonText 'Close pane' `
                -LayoutPath (Join-Path $EvidenceDirectory 'mosh-pane-close-dialog.json')
            Wait-MoshPaneCount -Count 1 -Name 'mosh-pane-close-survivor' | Out-Null
            return
        } catch {
            Start-Sleep -Milliseconds 200
        }
    }
    throw '[harness] Mosh Pane close confirmation did not complete'
}

function Invoke-MoshDisconnectEscape {
    Assert-MoshTerminalSurfaceFocused
    & $hdc -t $targetId shell `
        'uitest uiInput keyEvent 2072 2047 2006' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw '[environment] Unable to inject physical Ctrl-^ prefix'
    }
    Start-Sleep -Milliseconds 250
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $targetId -KeyCode 2044
}

function Remove-DeviceState {
    if ([string]::IsNullOrWhiteSpace($appPid)) {
        $script:deviceStateCleaned = $true
        return
    }
    try {
        Submit-LocalCommand -Command "host rm $sshAlias" -Stage 'mosh-final-ssh-host-cleanup'
        Submit-LocalCommand -Command "host rm $alias" -Stage 'mosh-final-host-cleanup'
        Submit-LocalCommand -Command "ssh-keygen -R [$fixtureSshAddress]:$FixturePort" `
            -Stage 'mosh-final-known-host-cleanup'
        $script:deviceStateCleaned = $true
        return
    } catch {
        & $hdc -t $targetId shell 'aa force-stop com.leantty.app' 2>$null | Out-Null
        $start = Start-LeanTTYRegressionApp -Hdc $hdc -Target $targetId `
            -CredentialPath (Get-LeanTTYDeviceUnlockPasswordPath) -RepositoryRoot $repoRoot
        $script:appPid = $start.processId
        Wait-LeanTTYTerminalInputLayout -Hdc $hdc -Target $targetId `
            -LocalPath (Join-Path $EvidenceDirectory 'cleanup-relaunch.json') `
            -TimeoutSeconds 20 | Out-Null
        Reset-LeanTTYDeviceCommandInput -Hdc $hdc -Target $targetId -ProcessId $appPid
        Submit-LocalCommand -Command "host rm $sshAlias" -Stage 'mosh-recovered-ssh-host-cleanup'
        Submit-LocalCommand -Command "host rm $alias" -Stage 'mosh-recovered-host-cleanup'
        Submit-LocalCommand -Command "ssh-keygen -R [$fixtureSshAddress]:$FixturePort" `
            -Stage 'mosh-recovered-known-host-cleanup'
        $script:deviceCleanupRecovery = 'app-relaunch'
        $script:deviceStateCleaned = $true
    }
}

function Stop-MoshFixture {
    $prefix = Get-LeanTTYWslPrefix -Distribution $Distribution
    if ($moshServerPid -gt 0 -and (Test-WslProcessPresent -LinuxPid $moshServerPid)) {
        & wsl.exe @prefix --exec kill -TERM $moshServerPid 2>$null
    }
    if ($fixtureLinuxPid -gt 0 -and (Test-WslProcessPresent -LinuxPid $fixtureLinuxPid)) {
        & wsl.exe @prefix --exec kill -TERM $fixtureLinuxPid 2>$null
    }
    if ($fixtureTerminalPid -gt 0 -and (Test-WslProcessPresent -LinuxPid $fixtureTerminalPid)) {
        & wsl.exe @prefix --exec kill -TERM $fixtureTerminalPid 2>$null
    }
    if ($null -ne $fixtureProcess -and -not $fixtureProcess.HasExited) {
        Stop-Process -Id $fixtureProcess.Id -ErrorAction SilentlyContinue
        Wait-Process -Id $fixtureProcess.Id -Timeout 10 -ErrorAction SilentlyContinue
    }
    if ($moshServerPid -gt 0 -and (Test-WslProcessPresent -LinuxPid $moshServerPid)) {
        throw 'Controlled mosh-server remains after fixture cleanup'
    }
    if ($fixtureLinuxPid -gt 0 -and (Test-WslProcessPresent -LinuxPid $fixtureLinuxPid)) {
        throw 'Controlled SSH fixture remains after cleanup'
    }
    if ($fixtureTerminalPid -gt 0 -and (Test-WslProcessPresent -LinuxPid $fixtureTerminalPid)) {
        throw 'Controlled Mosh terminal remains after cleanup'
    }
    $script:fixtureCleaned = $true
}

function Save-MoshFailureLogs {
    foreach ($entry in @(
        @{ Source = $fixtureStdout; Name = 'failure-fixture-stdout.log' },
        @{ Source = $fixtureStderr; Name = 'failure-fixture-stderr.log' }
    )) {
        if (-not (Test-Path -LiteralPath $entry.Source -PathType Leaf)) { continue }
        $contents = Read-LeanTTYSharedTextFile -Path $entry.Source
        if (-not [string]::IsNullOrEmpty($fixturePassword)) {
            $contents = $contents.Replace($fixturePassword, '[REDACTED]')
        }
        $contents = [regex]::Replace(
            $contents,
            'MOSH CONNECT\s+\d+\s+[A-Za-z0-9+/]{22}',
            'MOSH CONNECT [REDACTED]'
        )
        [IO.File]::WriteAllText(
            (Join-Path $EvidenceDirectory $entry.Name),
            $contents,
            [Text.UTF8Encoding]::new($false)
        )
    }
    if (-not [string]::IsNullOrWhiteSpace($appPid) -and
        -not [string]::IsNullOrWhiteSpace($targetId) -and $null -ne $hdc) {
        $deviceContents = Get-LeanTTYAppLogs -Hdc $hdc -Target $targetId -ProcessId $appPid
        if (-not [string]::IsNullOrEmpty($fixturePassword)) {
            $deviceContents = $deviceContents.Replace($fixturePassword, '[REDACTED]')
        }
        $deviceContents = [regex]::Replace(
            $deviceContents,
            'MOSH CONNECT\s+\d+\s+[A-Za-z0-9+/]{22}',
            'MOSH CONNECT [REDACTED]'
        )
        [IO.File]::WriteAllText(
            (Join-Path $EvidenceDirectory 'failure-device-app.log'),
            $deviceContents + "`n",
            [Text.UTF8Encoding]::new($false)
        )
    }
    if (-not [string]::IsNullOrWhiteSpace($initialAppProcessId) -and
        -not [string]::IsNullOrWhiteSpace($targetId) -and $null -ne $hdc) {
        $processIds = @($initialAppProcessId, $resumedAppProcessId) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
        $processPattern = ($processIds | ForEach-Object { [regex]::Escape($_) }) -join '|'
        $remotePattern = 'com\.leantty\.app'
        if (-not [string]::IsNullOrWhiteSpace($processPattern)) {
            $remotePattern += '|' + $processPattern
        }
        $lifecycleContents = @(
            & $hdc -t $targetId shell (
                "hilog -z 30000 | grep -E '$remotePattern' | " +
                "grep -E 'Ability on|AppMgr|Process|Kill|Terminate|Fault|APP_CRASH|" +
                "AppFreeze|SUSPEND|Mosh|SessionViewModel' | tail -n 1200"
            ) 2>&1
        ) -join "`n"
        if (-not [string]::IsNullOrEmpty($fixturePassword)) {
            $lifecycleContents = $lifecycleContents.Replace($fixturePassword, '[REDACTED]')
        }
        $lifecycleContents = [regex]::Replace(
            $lifecycleContents,
            'MOSH CONNECT\s+\d+\s+[A-Za-z0-9+/]{22}',
            'MOSH CONNECT [REDACTED]'
        )
        [IO.File]::WriteAllText(
            (Join-Path $EvidenceDirectory 'failure-device-lifecycle.log'),
            $lifecycleContents + "`n",
            [Text.UTF8Encoding]::new($false)
        )
    }
}

function Write-Evidence {
    $businessPostcondition = switch ($Scenario) {
        'pause-recovery' {
            'controlled-mosh-udp-pause-reported-interrupted-then-recovered-with-remote-shell-preserved'
        }
        'wifi-pause-recovery' {
            'physical-wifi-pause-reported-interrupted-then-recovered-with-remote-shell-preserved'
        }
        'suspend-recovery' {
            'controlled-system-suspend-and-wake-preserved-the-mosh-session-and-remote-shell'
        }
        'operator-lock-recovery' {
            'operator-lock-and-unlock-preserved-the-mosh-session-and-remote-shell'
        }
        'operator-lid-recovery' {
            'operator-physical-lid-close-open-produced-session-preservation-or-workspace-only-recovery'
        }
        'server-disappearance' {
            'controlled-mosh-server-disappearance-reported-interrupted-and-required-user-close'
        }
        'fixed-endpoint' {
            'controlled-mosh-fixed-udp-range-selected-and-disconnected'
        }
        'server-path' {
            'controlled-mosh-server-path-selected-and-disconnected'
        }
        'prediction' {
            'controlled-mosh-prediction-modes-visible-and-isolated'
        }
        'surface-rebuild' {
            'active-mosh-page-survived-arkweb-surface-rebuild-and-restored-the-original-page'
        }
        'page-rebuild' {
            'active-mosh-session-survived-current-page-destruction-and-replacement-in-the-same-process'
        }
        'abnormal-exit' {
            'injected-mosh-session-error-restored-the-original-page-and-rejected-session-output'
        }
        'process-recovery' {
            'forced-client-process-exit-restored-only-the-local-workspace-without-session-content'
        }
        'agent-tui' {
            'controlled-mosh-zero-model-real-codex-tui-completed'
        }
        'pane-close' {
            'active-mosh-pane-closed-and-surviving-pane-started-an-isolated-session'
        }
        'session-isolation' {
            'two-mosh-and-ssh-mosh-concurrent-sessions-kept-state-terminal-input-output-and-cleanup-isolated'
        }
        default { 'controlled-mosh-terminal-compatibility-and-disconnect-completed' }
    }
    $automation = Get-LeanTTYDeviceCommandAutomationSummary `
        -Observations $commandObservations `
        -BusinessVerdict $(if ($result -eq 'passed') { 'passed' } else { 'failed' }) `
        -BusinessPostcondition $businessPostcondition
    $evidence = [ordered]@{
        schemaVersion = 1
        gate = '1.6-mosh-physical-diagnostic'
        result = $result
        acceptanceEligible = $false
        verificationMode = 'device-behavior-diagnostic'
        startedAt = $startedAt.ToString('o')
        completedAt = [DateTimeOffset]::UtcNow.ToString('o')
        durationMs = [long]([DateTimeOffset]::UtcNow - $startedAt).TotalMilliseconds
        attemptId = $attemptId
        scenario = $Scenario
        candidate = [ordered]@{
            hapSha256 = (Get-FileHash -LiteralPath $selectedHapPath -Algorithm SHA256).Hash.ToLowerInvariant()
            provenance = 'explicit-current-test-signed-hap'
        }
        harness = [ordered]@{
            commit = (& git -C $repoRoot rev-parse HEAD).Trim()
            dirty = (@(git -C $repoRoot status --porcelain --untracked-files=all).Count -gt 0)
        }
        fixture = [ordered]@{
            stockMoshServer = $true
            sshAuthentication = 'run-scoped-password'
            sshBootstrapTransport = 'run-scoped-hdc-reverse'
            sshDeviceEndpoint = "${fixtureSshAddress}:$FixturePort"
            sshBackendEndpoint = "127.0.0.1:$FixtureBackendPort"
            udpPortPolicy = $(if ($Scenario -eq 'fixed-endpoint') {
                "requested-fixed-range-$fixedUdpPortStart-$fixedUdpPortEnd"
            } else { "stock-default-dynamic-$moshUdpPortMin-$moshUdpPortMax" })
            requestedUdpPortStart = $(if ($Scenario -eq 'fixed-endpoint') {
                $fixedUdpPortStart
            } else { 0 })
            requestedUdpPortEnd = $(if ($Scenario -eq 'fixed-endpoint') {
                $fixedUdpPortEnd
            } else { 0 })
            selectedUdpPort = $moshServerPort
            stockServerUdpPort = $moshActualServerPort
            serverPathPolicy = $(if ($Scenario -eq 'server-path') {
                'requested-absolute-path'
            } else { 'default-path-lookup' })
            requestedServerPath = $(if ($Scenario -eq 'server-path') {
                $customMoshServerPath
            } else { '' })
            serverNetworkTimeoutSeconds = $moshNetworkTimeoutSeconds
            primaryOracle = 'controlled-pty-current-line-and-result-files'
            predictionEchoContract = $(if ($Scenario -eq 'prediction') {
                'normal-pty-kernel-echo-real-interactive-shell'
            } else { 'not-enabled' })
            predictionRelay = $(if ($Scenario -eq 'prediction') {
                'fixture-owned-bidirectional-40ms-udp-relay'
            } else { 'not-enabled' })
        }
        network = [ordered]@{
            preparedStateVerified = $networkStateReady
            requiredPersistentBoundary = 'windows-and-hyper-v-udp-firewall'
            sshPortProxyRequired = $false
            mutatedByScenario = ($Scenario -in @('pause-recovery', 'wifi-pause-recovery', 'prediction'))
            persistentStateMutatedByScenario = $false
            statusEvidence = $networkStatusPath
        }
        networkBehavior = [ordered]@{
            impairmentMethod = $(if ($Scenario -eq 'prediction') {
                'fixture-udp-relay-bidirectional-pause'
            } elseif ($Scenario -eq 'pause-recovery') {
                'wsl-tc-exact-dynamic-port-bidirectional-drop'
            } elseif ($Scenario -eq 'wifi-pause-recovery') {
                'harmony-status-bar-wlan-toggle'
            } elseif ($Scenario -eq 'server-disappearance') {
                'server-sigkill'
            } else { 'none' })
            selectedUdpPort = $moshServerPort
            pauseDurationMs = $networkPauseDurationMs
            sessionStayedConnected = $sessionStayedConnected
            remoteTerminalPid = $fixtureTerminalPid
            remoteShellAliveBefore = $remoteShellAliveBefore
            remoteShellAliveAfter = $remoteShellAliveAfter
            recoveryCommandPassed = $recoveryCommandPassed
            automaticCloseObserved = $automaticCloseObserved
            automaticErrorObserved = $automaticErrorObserved
            interruptionObserved = $interruptionObserved
            interruptionReason = $interruptionReason
            recoveredStatusObserved = $recoveredStatusObserved
            userCloseRequired = $userCloseRequired
            observedErrorCategory = $observedErrorCategory
            localCloseElapsedMs = $localCloseElapsedMs
            authenticatedCloseAck = $authenticatedGracefulClose
            impairmentCleanupVerified = $udpImpairmentCleanupVerified
            wifiControlCleanupVerified = $wifiControlCleanupVerified
            predictionRelayDroppedPackets = $predictionRelayDroppedPackets
        }
        lifecycleBehavior = [ordered]@{
            exercised = ($Scenario -in @(
                'suspend-recovery', 'operator-lock-recovery', 'operator-lid-recovery'
            ))
            trigger = $(if ($Scenario -eq 'suspend-recovery') {
                'harmony-power-shell-suspend-then-wakeup'
            } elseif ($Scenario -eq 'operator-lock-recovery') {
                'operator-win-l-then-manual-unlock'
            } elseif ($Scenario -eq 'operator-lid-recovery') {
                'operator-physical-lid-close-open-then-manual-unlock'
            } else { 'none' })
            systemSuspendMs = $systemSuspendMs
            sameAppProcessAfterResume = $sameAppProcessAfterResume
            processIdentityMethod = 'pid-plus-proc-stat-starttime'
            initialAppProcessId = $initialAppProcessId
            resumedAppProcessId = $resumedAppProcessId
            initialAppProcessStartTimeTicks = $initialAppProcessStartTimeTicks
            resumedAppProcessStartTimeTicks = $resumedAppProcessStartTimeTicks
            remoteShellAliveAtProcessChange = $remoteShellAliveAtProcessChange
            serverAliveAtProcessChange = $serverAliveAtProcessChange
            recoveryInputMethod = $recoveryInputMethod
            deviceUnlockAfterResume = $deviceUnlockAfterResume
            resumeCommandElapsedMs = $resumeCommandElapsedMs
            remoteTerminalPid = $fixtureTerminalPid
            remoteShellAliveBefore = $remoteShellAliveBefore
            remoteShellAliveAfter = $remoteShellAliveAfter
            sessionStayedConnected = $sessionStayedConnected
            recoveryCommandPassed = $recoveryCommandPassed
            operatorLockObserved = $operatorLockObserved
            operatorUnlockObserved = $operatorUnlockObserved
            operatorLockDurationMs = $operatorLockDurationMs
            physicalLidExercised = ($Scenario -eq 'operator-lid-recovery' -and
                $operatorLockObserved -and $operatorUnlockObserved)
            operatorDeviceInactiveState = $operatorDeviceInactiveState
            recoveryOutcome = $operatorRecoveryOutcome
            userActionRequired = $(if ($Scenario -eq 'operator-lock-recovery') {
                'operator-lock-and-unlock'
            } elseif ($Scenario -eq 'operator-lid-recovery') {
                'operator-physical-lid-close-open-and-unlock'
            } else { 'none' })
        }
        prediction = [ordered]@{
            defaultMode = 'adaptive'
            testedModes = @('always', 'never')
            alwaysVisibleBeforeAuthority = $predictionAlwaysVisibleBeforeAuthority
            neverHiddenBeforeAuthority = $predictionNeverHiddenBeforeAuthority
            authorityConverged = $predictionAuthorityConverged
            sessionsIsolated = $predictionSessionsIsolated
            firstSessionClosedGracefully = $predictionAlwaysClosedGracefully
            predictionRttBaselineMs = $predictionRttBaselineMs
            predictionConfirmationThresholdMs = $predictionConfirmationThresholdMs
            controlledOneWayDelayMs = $predictionRelayDelayMs
            predictionVisibleLatencyMs = $predictionVisibleLatencyMs
            predictionRenderLatencyMs = $predictionRenderLatencyMs
            outageVisibleLatencyMs = $predictionOutageVisibleLatencyMs
            outageRenderLatencyMs = $predictionOutageRenderLatencyMs
            predictionWarmupSamples = $predictionWarmupSamples
            measurementContract = 'printable-ascii-only-no-enter-control-resize-repaint'
            confirmationBoundary = 'actual-vt-output-below-measured-rtt'
            outageBoundary = 'one-printable-ascii-visible-before-udp-recovery'
            primaryOracle = 'public-vt-output-and-xterm-write-ack-on-device-hilog-timeline'
        }
        paneOwnership = [ordered]@{
            exercised = ($Scenario -eq 'pane-close')
            closedPaneOutputAbsentFromSurvivor = $paneCloseOldOutputAbsent
            survivingPaneCommandPassed = $paneCloseSurvivorCommandPassed
            closedPaneServerExitElapsedMs = $paneCloseOldServerExitElapsedMs
            primaryOracle = 'surviving-pane-terminal-search-plus-second-controlled-pty-command'
        }
        sessionIsolation = [ordered]@{
            exercised = ($Scenario -eq 'session-isolation')
            twoMoshServerPidsDistinct = $sessionIsolationServerPidsDistinct
            twoMoshKeysDistinct = $sessionIsolationKeysDistinct
            twoMoshOutputIsolated = $twoMoshOutputIsolated
            twoMoshInputIsolated = $twoMoshInputIsolated
            closingOneMoshPreservedTheOther = $twoMoshCloseIsolated
            sshMoshOutputIsolated = $sshMoshOutputIsolated
            sshMoshInputIsolated = $sshMoshInputIsolated
            closingMoshPreservedSsh = $sshMoshCloseIsolated
            primaryOracle = 'per-pane-terminal-search-exact-controlled-remote-commands-distinct-server-pids-and-opposite-session-post-close-command'
        }
        surfaceLifecycle = [ordered]@{
            exercised = ($Scenario -eq 'surface-rebuild')
            rendererRebuildRequested = $surfaceRebuildRequested
            moshPageRetainedAfterRebuild = $surfaceRebuildPageRetained
            commandPassedAfterRebuild = $surfaceRebuildCommandPassed
            primaryOracle = 'acceptance-renderer-termination-log-terminal-search-and-controlled-pty-command'
        }
        pageLifecycle = [ordered]@{
            exercised = ($Scenario -eq 'page-rebuild')
            trigger = $(if ($Scenario -eq 'page-rebuild') {
                'acceptance-only-ui-context-router-current-page-replacement'
            } else { 'none' })
            rebuildRequested = $pageRebuildRequested
            sameProcess = $pageRebuildProcessPreserved
            workspaceReused = $pageRebuildWorkspaceReused
            moshPageRetainedAfterRebuild = $pageRebuildPageRetained
            commandPassedAfterRebuild = $pageRebuildCommandPassed
            primaryOracle = 'pid-plus-proc-starttime-page-lifecycle-logs-terminal-search-and-controlled-pty-command'
        }
        abnormalLifecycle = [ordered]@{
            exercised = ($Scenario -eq 'abnormal-exit')
            faultInjected = $abnormalExitInjected
            moshErrorObserved = $abnormalExitObserved
            originalPageRestored = $originalPageRestoredAfterSession
            moshPageDiscarded = $moshPageDiscardedAfterSession
            primaryOracle = 'acceptance-only-viewmodel-error-log-page-replacement-ack-and-terminal-search'
        }
        processRecovery = [ordered]@{
            exercised = ($Scenario -eq 'process-recovery' -or
                ($Scenario -eq 'operator-lid-recovery' -and -not $sameAppProcessAfterResume))
            trigger = $(if ($Scenario -eq 'operator-lid-recovery') {
                'physical-lid'
            } elseif ($Scenario -eq 'process-recovery') { 'controlled-force-stop' } else { 'none' })
            processReplaced = (-not $sameAppProcessAfterResume)
            workspaceWarningObserved = $processRecoveryWorkspaceRestored
            remoteContentAbsent = $processRecoveryRemoteContentAbsent
            sessionNotRestored = $processRecoverySessionNotRestored
            primaryOracle = 'pid-change-plus-terminal-search-positive-warning-and-negative-old-output-plus-local-command'
        }
        checks = [ordered]@{
            bootstrapAuthenticated = ($moshServerPid -gt 0)
            udpConnected = ($lastProvenBoundary -match 'connected|command|disconnect|cleanup')
            exactCommandObserved = ($lastProvenBoundary -match 'command|disconnect|cleanup')
            endpointMatchesRequest = $udpEndpointMatchesRequest
            serverPathMatchesRequest = $serverPathMatchesRequest
            ctrlCaretDisconnect = $(if ($Scenario -in @('abnormal-exit', 'process-recovery') -or
                ($Scenario -eq 'operator-lid-recovery' -and -not $sameAppProcessAfterResume)) {
                $false
            } else { $lastProvenBoundary -match 'disconnect|cleanup' })
            authenticatedGracefulClose = $authenticatedGracefulClose
            gracefulServerExitElapsedMs = $gracefulServerExitElapsedMs
            localPromptReady = $localPromptReady
            realShell = $shellCompatibilityPassed
            tmux = $tmuxCompatibilityPassed
            basicEditor = $editorCompatibilityPassed
            remotePtyResize = $resizeCompatibilityPassed
            sustainedInputOutput = $streamCompatibilityPassed
            streamOutputObservedInTerminal = $streamOutputObserved
            utf8WideAndCombiningOutput = $unicodeCompatibilityPassed
            unicodeOutputObservedInTerminal = $unicodeOutputObserved
            unicodeScreenshotCaptured = (-not [string]::IsNullOrWhiteSpace($unicodeScreenshot))
            interactiveLargeOutputAndScrollback = $scrollbackCompatibilityPassed
            scrollbackBottomObservedInTerminal = $scrollbackBottomObserved
            scrollbackTopAbsentUnderMoshStateSync = $scrollbackTopAbsent
            realLess = $lessCompatibilityPassed
            lessFirstLineObservedAfterHome = $lessFirstLineObserved
            lessLastLineObservedAfterEnd = $lessLastLineObserved
            alternateScreenEnterExit = $alternateScreenCompatibilityPassed
            alternateScreenActiveObserved = $alternateScreenActiveObserved
            alternateScreenClosedObserved = $alternateScreenClosedObserved
            alternateScreenPriorContentSearchableAfterExit = $alternateScreenHistoryRetained
            alternateScreenScreenshotsCaptured = `
                (-not [string]::IsNullOrWhiteSpace($alternateScreenActiveScreenshot) -and `
                -not [string]::IsNullOrWhiteSpace($alternateScreenClosedScreenshot))
            originalPageHiddenDuringSession = $originalPageHiddenDuringSession
            originalPageRestoredAfterSession = $originalPageRestoredAfterSession
            moshSessionPageDiscardedAfterSession = $moshPageDiscardedAfterSession
            representativeAgentTui = $agentCompatibilityPassed
            bootstrapTextAbsentFromTerminal = $bootstrapTerminalAbsent
            preferencesUnchanged = $preferencesUnchanged
            secretPatternAbsent = $secretAuditPassed
        }
        compatibility = [ordered]@{
            shell = 'GNU Bash 5.3'
            tmux = 'tmux 3.6'
            editor = 'Vim 9.1'
            pager = 'less'
            streamInputBytes = 512
            unicodeContract = 'UTF-8-locale-five-wide-CJK-codepoints-one-combining-sequence-visual-screenshot'
            largeOutputContract = 'paced-terminal-state-output-with-observed-local-scrollback-boundary'
            scrollbackLines = 242
            alternateScreen = 'DECSET-DECRST-1049'
            agent = [ordered]@{
                name = 'codex'
                version = $agentVersion
                mode = 'direct'
                plannedModelRequests = 0
                termiosBefore = $agentTermiosBefore
                termiosAfter = $agentTermiosAfter
                capture = $agentCaptureSummary
            }
            resizeMethod = 'HarmonyOS-maximize-restore-and-remote-stty'
        }
        preferences = [ordered]@{
            algorithm = 'SHA-256'
            contentReadOrExported = $false
            digestPersisted = $false
            beforeCaptured = (-not [string]::IsNullOrWhiteSpace($preferencesDigestBefore))
            afterCaptured = (-not [string]::IsNullOrWhiteSpace($preferencesDigestAfter))
            unchanged = $preferencesUnchanged
        }
        automation = $automation
        connectedInput = $connectedInputObservations
        cleanup = [ordered]@{
            deviceStateRemoved = $deviceStateCleaned
            deviceCleanupRecovery = $deviceCleanupRecovery
            fixtureProcessesAbsent = $fixtureCleaned
            fixtureReverseMappingRemoved = $fixtureMappingRemoved
            persistentNetworkPreserved = $networkStateReady
            temporaryDirectoryRemoved = -not (Test-Path -LiteralPath $fixtureRoot)
        }
        failureDomain = $failureDomain
        failure = $failure
        lastProvenBoundary = $lastProvenBoundary
    }
    [IO.File]::WriteAllText(
        $evidencePath,
        (ConvertTo-Json $evidence -Depth 10) + "`n",
        [Text.UTF8Encoding]::new($false)
    )
}

try {
    Write-LiveStatus -Stage 'preflight'
    $hdc = Resolve-Hdc
    $targetId = Resolve-LeanTTYRegressionTarget -Hdc $hdc -Target $Target
    & (Join-Path $PSScriptRoot 'preflight-device.ps1') -Target $targetId `
        -EvidencePath (Join-Path $EvidenceDirectory 'device-preflight.json')
    if ($LASTEXITCODE -ne 0) { throw '[infrastructure] Device preflight failed' }
    $lastProvenBoundary = 'device-control-preflight'

    $resolvedServerAddress = Resolve-MoshServerAddress
    $resolvedRemoteScope = Resolve-MoshRemoteScope
    Write-LiveStatus -Stage 'network-fixture-check'
    Assert-MoshTestNetworkReady
    $fixtureProcess = Start-MoshFixture
    $readiness = Wait-MoshFixtureReady
    $fixtureLinuxPid = [int]$readiness.linuxPid
    $fixturePassword = [string]$readiness.credentials.password
    New-MoshFixtureMapping
    if ($Scenario -eq 'prediction') {
        foreach ($path in @($fixtureKernelEcho, $fixturePredictionRelay)) {
            [IO.File]::WriteAllText(
                $path,
                "enabled`n",
                [Text.UTF8Encoding]::new($false)
            )
        }
    }

    if ($Scenario -eq 'session-isolation') {
        [IO.File]::WriteAllText(
            $fixtureSessionIsolation,
            "enabled`n",
            [Text.UTF8Encoding]::new($false)
        )
    }
    $lastProvenBoundary = 'controlled-ssh-fixture-ready'

    Start-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $targetId
    $awakeLeaseActive = $true
    & (Join-Path $PSScriptRoot 'dev-pc.ps1') -Target $targetId -HapPath $selectedHapPath `
        -SkipBuild -NoLaunch
    if ($LASTEXITCODE -ne 0) { throw '[infrastructure] Mosh test HAP deployment failed' }
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
    $start = Start-LeanTTYRegressionApp -Hdc $hdc -Target $targetId `
        -CredentialPath (Get-LeanTTYDeviceUnlockPasswordPath) -RepositoryRoot $repoRoot
    $appPid = $start.processId
    $initialProcessIdentity = Get-MoshAppProcessIdentity
    if ($null -eq $initialProcessIdentity -or
        [string]$initialProcessIdentity.processId -cne $appPid) {
        throw '[infrastructure] LeanTTY launch did not produce a stable process identity'
    }
    $initialAppProcessId = [string]$initialProcessIdentity.processId
    $initialAppProcessStartTimeTicks = [string]$initialProcessIdentity.startTimeTicks
    Wait-LeanTTYTerminalInputLayout -Hdc $hdc -Target $targetId `
        -LocalPath (Join-Path $EvidenceDirectory 'app-ready.json') -TimeoutSeconds 20 | Out-Null
    $lastProvenBoundary = 'test-hap-launched'

    Write-LiveStatus -Stage 'device-state-setup'
    Reset-LeanTTYDeviceCommandInput -Hdc $hdc -Target $targetId -ProcessId $appPid
    Submit-LocalCommand -Command "host rm $sshAlias" -Stage 'mosh-initial-ssh-host-cleanup'
    Submit-LocalCommand -Command "host rm $alias" -Stage 'mosh-initial-host-cleanup'
    Submit-LocalCommand -Command "ssh-keygen -R [$fixtureSshAddress]:$FixturePort" `
        -Stage 'mosh-initial-known-host-cleanup'
    $preferencesDigestBefore = Get-MoshPreferencesDigest
    Submit-LocalCommand -Command "host add $alias mosh@${fixtureSshAddress}:$FixturePort" `
        -Stage 'mosh-host-setup'
    Submit-LocalCommand -Command $originalPageMarker -Stage 'mosh-original-page-marker'
    if ($Scenario -eq 'pane-close') {
        Write-LiveStatus -Stage 'pane-close-split'
        Split-MoshPane
    }

    Write-LiveStatus -Stage 'mosh-connect'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
    $moshCommand = if ($Scenario -eq 'fixed-endpoint') {
        "mosh -p $fixedUdpPortStart`:$fixedUdpPortEnd $alias"
    } elseif ($Scenario -eq 'server-path') {
        "mosh --server=/usr/bin/mosh-server $alias"
    } elseif ($Scenario -eq 'prediction') {
        "mosh --predict=always $alias"
    } else { "mosh $alias" }
    Submit-LocalCommand -Command $moshCommand -Stage 'mosh-connect-command'
    Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
        -Pattern 'Mosh host key prompt' -TimeoutSeconds 15 | Out-Null
    Submit-InteractiveValue -Value 'yes' -Name 'mosh-host-trust'
    Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
        -Pattern 'Mosh auth event kind=password' -TimeoutSeconds 15 | Out-Null
    Submit-InteractiveValue -Value $fixturePassword -Name 'mosh-password'
    Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
        -Pattern 'Mosh Session connected' -TimeoutSeconds 30 | Out-Null
    Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
        -Pattern 'MOSH_PAGE stage=ready' -TimeoutSeconds 15 | Out-Null
    $session = Read-MoshSession
    $activeMoshControlDirectory = $session.controlDirectory
    $activeMoshTerminalReady = Join-Path $activeMoshControlDirectory 'mosh-terminal-ready'
    $activeMoshTerminalPidPath = Join-Path $activeMoshControlDirectory 'mosh-terminal-pid'
    $activeMoshEvent = Join-Path $activeMoshControlDirectory 'mosh-event'
    Wait-ControlFile -Path $activeMoshTerminalReady -TimeoutSeconds 30 | Out-Null
    $fixtureTerminalPid = Read-ControlledLinuxPid -Path $activeMoshTerminalPidPath
    $moshServerPid = $session.pid
    $moshServerPort = $session.port
    $moshActualServerPort = $session.serverPort
    if ($Scenario -eq 'server-path') {
        $serverPathMatchesRequest = ($session.serverPath -ceq $customMoshServerPath)
        if (-not $serverPathMatchesRequest) {
            throw '[product] Mosh bootstrap did not execute the requested server path'
        }
    }
    if ($Scenario -eq 'fixed-endpoint') {
        $udpEndpointMatchesRequest =
            $moshServerPort -ge $fixedUdpPortStart -and $moshServerPort -le $fixedUdpPortEnd
        if (-not $udpEndpointMatchesRequest) {
            throw '[product] Mosh server selected a UDP port outside the requested range'
        }
    }

    if ($Scenario -eq 'server-path') {
        $remoteShellAliveAfter = $remoteShellAliveBefore
        $sessionStayedConnected = $remoteShellAliveBefore
        $observedErrorCategory = 'none'
        $lastProvenBoundary = 'custom-server-path-command-passed'
    }
    if (-not (Test-WslProcessPresent -LinuxPid $moshServerPid)) {
        throw '[product] Mosh server exited before the interactive session became ready'
    }
    $lastProvenBoundary = 'mosh-udp-connected'
    $originalPageHiddenDuringSession = Test-MoshTerminalSearch `
        -Query $originalPageMarker -ExpectMatch $false -Name 'mosh-original-page-hidden-search'

    $shellCommand = "$([string]'ltty-mosh-check') $caseId"
    if ($Scenario -ne 'prediction') {
        Write-LiveStatus -Stage 'interactive-shell'
        Submit-MoshInput -Text $shellCommand
        $event = Wait-ControlFile -Path $activeMoshEvent -TimeoutSeconds 15
        if ($event -notmatch "(?m)^case=$([regex]::Escape($caseId))$" -or
            $event -notmatch '(?m)^result=passed$') {
            throw '[product] Controlled Mosh PTY did not execute the exact command'
        }
        $lastProvenBoundary = 'controlled-command-passed'
    }

    $bootstrapTerminalAbsent = Test-MoshTerminalSearch `
        -Query 'MOSH CONNECT' -ExpectMatch $false -Name 'mosh-bootstrap-negative-search'
    $remoteShellAliveBefore = Test-WslProcessPresent -LinuxPid $fixtureTerminalPid
    if (-not $remoteShellAliveBefore) {
        throw '[product] Controlled remote Mosh terminal exited after the baseline command'
    }

    if ($Scenario -eq 'fixed-endpoint') {
        $remoteShellAliveAfter = $remoteShellAliveBefore
        $sessionStayedConnected = $remoteShellAliveBefore
        $observedErrorCategory = 'none'
        $lastProvenBoundary = 'fixed-udp-range-command-passed'
    }

    if ($Scenario -eq 'compatibility') {
    Write-LiveStatus -Stage 'real-shell'
    Submit-MoshInput -Text "ltty-mosh-shell $caseId"
    Wait-ControlFile -Path $fixtureShellReady -TimeoutSeconds 15 | Out-Null
    Submit-MoshChildInput -Text "ltty-shell-check $caseId" -Name 'mosh-real-shell-check'
    Wait-ControlFileMatch -Path $fixtureShellEvent `
        -Pattern '(?m)^result=passed$' -TimeoutSeconds 15 | Out-Null
    Submit-MoshChildInput -Text 'exit' -Name 'mosh-real-shell-exit'
    Wait-ControlFileMatch -Path $fixtureShellEvent `
        -Pattern '(?m)^closed=true$' -TimeoutSeconds 15 | Out-Null
    $shellCompatibilityPassed = $true

    Write-LiveStatus -Stage 'tmux'
    Submit-MoshInput -Text "ltty-mosh-tmux $caseId"
    Wait-ControlFile -Path $fixtureTmuxReady -TimeoutSeconds 15 | Out-Null
    Submit-MoshChildInput -Text "ltty-shell-check $caseId" -Name 'mosh-tmux-check'
    Wait-ControlFileMatch -Path $fixtureTmuxEvent `
        -Pattern '(?m)^result=passed$' -TimeoutSeconds 15 | Out-Null
    Submit-MoshChildInput -Text 'exit' -Name 'mosh-tmux-exit'
    Wait-ControlFileMatch -Path $fixtureTmuxEvent `
        -Pattern '(?m)^closed=true$' -TimeoutSeconds 15 | Out-Null
    $tmuxCompatibilityPassed = $true

    Write-LiveStatus -Stage 'editor'
    Submit-MoshInput -Text "ltty-mosh-editor $caseId"
    Wait-ControlFile -Path $fixtureEditorReady -TimeoutSeconds 15 | Out-Null
    Focus-ActiveTerminalInput -Name 'mosh-editor-insert-focus.json' | Out-Null
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $targetId -KeyCode 2025
    Submit-MoshChildInput -Text "editor_$caseId" -Submit $false -Name 'mosh-editor-text'
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $targetId -KeyCode 2070
    Submit-MoshChildInput -Text ':wq' -Name 'mosh-editor-save-exit'
    Wait-ControlFileMatch -Path $fixtureEditorEvent `
        -Pattern '(?ms)^kind=editor$.*^result=passed$.*^closed=true$' -TimeoutSeconds 20 | Out-Null
    $editorCompatibilityPassed = $true

    Write-LiveStatus -Stage 'sustained-input-output'
    Submit-MoshInput -Text "ltty-mosh-stream $caseId"
    Start-Sleep -Milliseconds 300
    Submit-MoshStreamPayload -Text ('P' * 512)
    Wait-ControlFileMatch -Path $fixtureStreamEvent `
        -Pattern '(?ms)^result=passed$.*^inputBytes=512$.*^outputFrames=32$' `
        -TimeoutSeconds 20 | Out-Null
    $streamCompatibilityPassed = $true
    $streamOutputObserved = Test-MoshTerminalSearch `
        -Query "LTTY_MOSH_STREAM_OK:$caseId" -ExpectMatch $true -Name 'mosh-stream-output-search'

    Write-LiveStatus -Stage 'unicode-wide-combining'
    Submit-MoshInput -Text "ltty-mosh-unicode $caseId"
    Wait-ControlFileMatch -Path $fixtureUnicodeEvent `
        -Pattern '(?ms)^result=passed$.*^localeCharmap=UTF-8$.*^wideCharacters=5$.*^combiningSequences=1$' `
        -TimeoutSeconds 15 | Out-Null
    $unicodeCompatibilityPassed = $true
    $unicodeOutputObserved = Test-MoshTerminalSearch `
        -Query "LTTY_MOSH_UNICODE:$caseId" -ExpectMatch $true -Name 'mosh-unicode-output-search'
    $unicodeScreenshot = 'mosh-unicode-wide-combining.png'
    Save-LeanTTYDeviceScreenshot -Hdc $hdc -Target $targetId `
        -LocalPath (Join-Path $EvidenceDirectory $unicodeScreenshot)

    Write-LiveStatus -Stage 'large-output-scrollback'
    Submit-MoshInput -Text "ltty-mosh-scrollback $caseId"
    Wait-ControlFileMatch -Path $fixtureScrollbackEvent `
        -Pattern '(?ms)^result=passed$.*^emittedLines=242$.*^contract=paced-terminal-state-output$' `
        -TimeoutSeconds 30 | Out-Null
    $scrollbackBottomObserved = Test-MoshTerminalSearch `
        -Query "LTTY_MOSH_SCROLL_BOTTOM:$caseId" -ExpectMatch $true `
        -Name 'mosh-scrollback-bottom-search'
    $scrollbackTopAbsent = Test-MoshTerminalSearch `
        -Query "LTTY_MOSH_SCROLL_TOP:$caseId" -ExpectMatch $false `
        -Name 'mosh-scrollback-top-search'
    $scrollbackCompatibilityPassed = $scrollbackBottomObserved -and $scrollbackTopAbsent

    Write-LiveStatus -Stage 'less'
    Submit-MoshInput -Text "ltty-mosh-less $caseId"
    Start-Sleep -Milliseconds 700
    Submit-MoshChildInput -Text 'g' -Submit $false -Name 'mosh-less-home'
    Start-Sleep -Milliseconds 300
    $lessFirstLineObserved = Test-MoshTerminalSearch `
        -Query "LTTY_MOSH_LESS_LINE_001:$caseId" -ExpectMatch $true `
        -Name 'mosh-less-first-search'
    Submit-MoshChildInput -Text 'G' -Submit $false -Name 'mosh-less-end'
    Start-Sleep -Milliseconds 300
    $lessLastLineObserved = Test-MoshTerminalSearch `
        -Query "LTTY_MOSH_LESS_LAST:$caseId" -ExpectMatch $true -Name 'mosh-less-last-search'
    Submit-MoshChildInput -Text 'q' -Submit $false -Name 'mosh-less-exit'
    Wait-ControlFileMatch -Path $fixtureLessEvent `
        -Pattern '(?ms)^result=passed$.*^documentLines=181$.*^closed=true$' `
        -TimeoutSeconds 15 | Out-Null
    $lessCompatibilityPassed = $lessFirstLineObserved -and $lessLastLineObserved

    Write-LiveStatus -Stage 'alternate-screen'
    Submit-MoshInput -Text "ltty-mosh-alternate $caseId"
    Start-Sleep -Milliseconds 500
    $alternateScreenActiveObserved = Test-MoshTerminalSearch `
        -Query "LTTY_MOSH_ALT_ACTIVE:$caseId" -ExpectMatch $true `
        -Name 'mosh-alternate-active-search'
    $alternateScreenActiveScreenshot = 'mosh-alternate-active.png'
    Save-LeanTTYDeviceScreenshot -Hdc $hdc -Target $targetId `
        -LocalPath (Join-Path $EvidenceDirectory $alternateScreenActiveScreenshot)
    Submit-MoshChildInput -Text 'x' -Submit $false -Name 'mosh-alternate-exit'
    Wait-ControlFileMatch -Path $fixtureAlternateEvent `
        -Pattern '(?ms)^result=passed$.*^entered=true$.*^closed=true$' `
        -TimeoutSeconds 15 | Out-Null
    $alternateScreenClosedScreenshot = 'mosh-alternate-closed.png'
    Save-LeanTTYDeviceScreenshot -Hdc $hdc -Target $targetId `
        -LocalPath (Join-Path $EvidenceDirectory $alternateScreenClosedScreenshot)
    $alternateScreenClosedObserved = Test-MoshTerminalSearch `
        -Query "LTTY_MOSH_ALT_CLOSED:$caseId" -ExpectMatch $true `
        -Name 'mosh-alternate-closed-search'
    $alternateScreenHistoryRetained = Test-MoshTerminalSearch `
        -Query "LTTY_MOSH_ALT_ACTIVE:$caseId" -ExpectMatch $true `
        -Name 'mosh-alternate-history-search'
    $alternateScreenCompatibilityPassed = $alternateScreenActiveObserved -and `
        $alternateScreenClosedObserved -and $alternateScreenHistoryRetained

    }

    if ($Scenario -in @('compatibility', 'agent-tui')) {
    Write-LiveStatus -Stage 'agent-tui-zero-model'
    Submit-MoshInput -Text "ltty-mosh-agent $caseId"
    Wait-ControlFile -Path $fixtureAgentPrepared -TimeoutSeconds 30 | Out-Null
    Wait-MoshAgentReady
    $inventory = Get-Content -LiteralPath (Join-Path $fixtureAgentRoot 'results\inventory.json') `
        -Raw | ConvertFrom-Json -Depth 20
    if (-not [bool]$inventory.tools.codex.installed -or
        -not [bool]$inventory.authenticationReady.codex) {
        throw '[external-agent] Installed Codex authentication is not ready'
    }
    $agentVersion = [string]$inventory.tools.codex.version
    $agentTermiosBefore = Get-MoshAgentTermios -Sample 'before-resize'
    if (-not [bool]$agentTermiosBefore.rawMode) {
        throw '[compatibility] Codex did not place its controlled PTY in raw mode'
    }
    Focus-ActiveTerminalInput -Name 'mosh-agent-physical-input.json' | Out-Null
    & $hdc -t $targetId shell (
        'uinput -K ' +
        '-d 2028 -u 2028 -d 2021 -u 2021 -d 2017 -u 2017 ' +
        '-d 2030 -u 2030 -d 2036 -u 2036 -d 2036 -u 2036 ' +
        '-d 2041 -u 2041 -d 2025 -u 2025 -d 2029 -u 2029 -d 2021 -u 2021'
    ) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '[environment] Physical Codex input failed' }
    Start-Sleep -Milliseconds 300
    Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $targetId
    Toggle-MoshWindowSize -Name 'mosh-agent-before-resize-toggle'
    $windowToggled = $true
    Start-Sleep -Milliseconds 1200
    $agentTermiosAfter = Get-MoshAgentTermios -Sample 'after-resize'
    if ([int]$agentTermiosBefore.rows -eq [int]$agentTermiosAfter.rows -and
        [int]$agentTermiosBefore.columns -eq [int]$agentTermiosAfter.columns) {
        throw '[product] Codex PTY dimensions did not follow the HarmonyOS window resize'
    }
    Toggle-MoshWindowSize -Name 'mosh-agent-after-resize-toggle'
    $windowToggled = $false
    Start-Sleep -Milliseconds 700
    Submit-MoshChildInput -Text '/exit' -Name 'mosh-agent-exit'
    Wait-ControlFileMatch -Path $fixtureAgentEvent `
        -Pattern '(?ms)^result=passed$.*^agent=codex$.*^plannedModelRequests=0$.*^closed=true$' `
        -TimeoutSeconds 45 | Out-Null
    $agentCaptureSummary = Get-Content -LiteralPath $fixtureAgentCapture -Raw |
        ConvertFrom-Json -Depth 30
    if ([int]$agentCaptureSummary.childExitCode -ne 0 -or
        -not [bool]$agentCaptureSummary.input.containsControlledEnglishMarker -or
        [int]$agentCaptureSummary.output.bytes -le 256 -or
        [bool]$agentCaptureSummary.privacy.rawInputRetained -or
        [bool]$agentCaptureSummary.privacy.rawOutputRetained) {
        throw '[compatibility] Codex zero-model content-free capture did not satisfy its contract'
    }
    $agentCompatibilityPassed = $true
    if ($Scenario -eq 'agent-tui') {
        $lastProvenBoundary = 'agent-tui-workload-passed'
        $remoteShellAliveAfter = Test-WslProcessPresent -LinuxPid $fixtureTerminalPid
        $sessionStayedConnected = $remoteShellAliveAfter
        $observedErrorCategory = 'none'
    }
    }

    if ($Scenario -eq 'compatibility') {
    Write-LiveStatus -Stage 'resize'
    Toggle-MoshWindowSize -Name 'mosh-before-resize-toggle'
    $windowToggled = $true
    Start-Sleep -Milliseconds 1200
    Submit-MoshInput -Text "ltty-mosh-resize $caseId"
    Wait-ControlFileMatch -Path $fixtureResizeEvent `
        -Pattern '(?m)^result=passed$' -TimeoutSeconds 15 | Out-Null
    $resizeCompatibilityPassed = $true
    Toggle-MoshWindowSize -Name 'mosh-after-resize-toggle'
    $windowToggled = $false
    Start-Sleep -Milliseconds 700
    $lastProvenBoundary = 'compatibility-workloads-passed'
    $remoteShellAliveAfter = Test-WslProcessPresent -LinuxPid $fixtureTerminalPid
    $sessionStayedConnected = $remoteShellAliveAfter
    $observedErrorCategory = 'none'
    }

    if ($Scenario -eq 'prediction') {
        Write-LiveStatus -Stage 'prediction-always'
        $alwaysMarker = 'abcdefghijk'
        Invoke-MoshPredictionProbe -Mode 'always' -Marker $alwaysMarker -ExpectVisible $true | Out-Null
        $predictionAlwaysVisibleBeforeAuthority = $true

        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
        Invoke-MoshDisconnectEscape
        Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
            -Pattern 'Mosh Session closed' -TimeoutSeconds 20 | Out-Null
        Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
            -Pattern 'MOSH_PAGE stage=ownership-released' -TimeoutSeconds 10 | Out-Null
        Wait-WslProcessAbsent -LinuxPid $moshServerPid -TimeoutSeconds 8 | Out-Null
        $predictionAlwaysClosedGracefully = $true
        Reset-LeanTTYDeviceCommandInput -Hdc $hdc -Target $targetId -ProcessId $appPid
        Clear-MoshSessionControlFiles

        Write-LiveStatus -Stage 'prediction-never-connect'
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
        Submit-LocalCommand -Command "mosh --predict=never $alias" `
            -Stage 'mosh-prediction-never-connect-command'
        Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
            -Pattern 'Mosh auth event kind=password' -TimeoutSeconds 15 | Out-Null
        Submit-InteractiveValue -Value $fixturePassword -Name 'mosh-prediction-never-password'
        Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
            -Pattern 'Mosh Session connected' -TimeoutSeconds 30 | Out-Null
        Wait-ControlFile -Path $fixtureTerminalReady -TimeoutSeconds 30 | Out-Null
        $fixtureTerminalPid = Read-ControlledLinuxPid -Path $fixtureTerminalPidPath
        $session = Read-MoshSession
        $moshServerPid = $session.pid
        $moshServerPort = $session.port
        $moshActualServerPort = $session.serverPort

        Write-LiveStatus -Stage 'prediction-never'
        $neverMarker = 'mnopqrstuvw'
        Invoke-MoshPredictionProbe -Mode 'never' -Marker $neverMarker -ExpectVisible $false | Out-Null
        $predictionNeverHiddenBeforeAuthority = $true
        $predictionAuthorityConverged = $true
        $predictionSessionsIsolated = $true
        Write-LiveStatus -Stage 'prediction-main-path-smoke'
        Submit-MoshShellMarker -WindowsPath "$fixturePredictionEvent-main" `
            -WslPath "$fixturePredictionEventWsl-main" -Name 'mosh-prediction-main-path'
        $remoteShellAliveAfter = Test-WslProcessPresent -LinuxPid $fixtureTerminalPid
        $sessionStayedConnected = $remoteShellAliveAfter
        $observedErrorCategory = 'none'
        $lastProvenBoundary = 'controlled-mosh-prediction-modes-visible-and-isolated'
    }

    if ($Scenario -eq 'surface-rebuild') {
        Write-LiveStatus -Stage 'surface-rebuild'
        Invoke-MoshSurfaceRebuild
        $surfaceRebuildRequested = $true
        $surfaceRebuildPageRetained = Test-MoshTerminalSearch `
            -Query "LTTY_MOSH_CHECK_OK:$caseId" -ExpectMatch $true `
            -Name 'mosh-surface-rebuild-page-search'
        $surfaceCaseId = 'surface_' + $attemptId.Substring(0, 12)
        Submit-MoshInput -Text "ltty-mosh-check $surfaceCaseId"
        Wait-ControlFileMatch -Path $activeMoshEvent `
            -Pattern "(?ms)^case=$([regex]::Escape($surfaceCaseId))$.*^result=passed$" `
            -TimeoutSeconds 20 | Out-Null
        $surfaceRebuildCommandPassed = Test-MoshTerminalSearch `
            -Query "LTTY_MOSH_CHECK_OK:$surfaceCaseId" -ExpectMatch $true `
            -Name 'mosh-surface-rebuild-command-search'
        $remoteShellAliveAfter = Test-WslProcessPresent -LinuxPid $fixtureTerminalPid
        $sessionStayedConnected = $remoteShellAliveAfter
        $observedErrorCategory = 'none'
        $lastProvenBoundary = 'surface-rebuilt-with-mosh-page-and-command-preserved'
    }

    if ($Scenario -eq 'page-rebuild') {
        Write-LiveStatus -Stage 'page-rebuild'
        $pageIdentity = Invoke-MoshPageRebuild
        $pageRebuildRequested = $true
        $pageRebuildProcessPreserved =
            [string]$pageIdentity.before.key -ceq [string]$pageIdentity.after.key
        $pageRebuildWorkspaceReused = $true
        $pageRebuildPageRetained = Test-MoshTerminalSearch `
            -Query "LTTY_MOSH_CHECK_OK:$caseId" -ExpectMatch $true `
            -Name 'mosh-page-rebuild-page-search'
        $pageCaseId = 'page_' + $attemptId.Substring(0, 12)
        Submit-MoshInput -Text "ltty-mosh-check $pageCaseId"
        Wait-ControlFileMatch -Path $activeMoshEvent `
            -Pattern "(?ms)^case=$([regex]::Escape($pageCaseId))$.*^result=passed$" `
            -TimeoutSeconds 20 | Out-Null
        $pageRebuildCommandPassed = Test-MoshTerminalSearch `
            -Query "LTTY_MOSH_CHECK_OK:$pageCaseId" -ExpectMatch $true `
            -Name 'mosh-page-rebuild-command-search'
        $remoteShellAliveAfter = Test-WslProcessPresent -LinuxPid $fixtureTerminalPid
        $sessionStayedConnected = $pageRebuildProcessPreserved -and
            $pageRebuildPageRetained -and $pageRebuildCommandPassed -and $remoteShellAliveAfter
        if (-not $sessionStayedConnected) {
            throw '[product] Mosh Session did not survive same-process page replacement'
        }
        $observedErrorCategory = 'none'
        $lastProvenBoundary = 'page-rebuilt-with-process-session-and-command-preserved'
    }

    if ($Scenario -eq 'abnormal-exit') {
        Write-LiveStatus -Stage 'abnormal-exit'
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
        Focus-ActiveTerminalInput -Name 'mosh-abnormal-exit-focus.json' | Out-Null
        & $hdc -t $targetId shell (
            'uinput -K -d 2072 -d 2045 -d 2047 -d 2034 ' +
            '-u 2034 -u 2047 -u 2045 -u 2072'
        ) | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw '[environment] Unable to inject the acceptance-only Mosh error shortcut'
        }
        Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
            -Pattern 'ACCEPTANCE_MOSH_ERROR state=injected' -TimeoutSeconds 15 | Out-Null
        $abnormalExitInjected = $true
        Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
            -Pattern 'Mosh error stage=client' -TimeoutSeconds 15 | Out-Null
        Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
            -Pattern 'MOSH_PAGE stage=ownership-released' -TimeoutSeconds 15 | Out-Null
        $abnormalExitObserved = $true
        Reset-LeanTTYDeviceCommandInput -Hdc $hdc -Target $targetId -ProcessId $appPid
        $localPromptReady = $true
        $originalPageRestoredAfterSession = Test-MoshTerminalSearch `
            -Query $originalPageMarker -ExpectMatch $true `
            -Name 'mosh-abnormal-original-page-restored-search'
        $moshPageDiscardedAfterSession = Test-MoshTerminalSearch `
            -Query $shellCommand -ExpectMatch $false `
            -Name 'mosh-abnormal-session-page-discarded-search'
        if (-not ($originalPageHiddenDuringSession -and $originalPageRestoredAfterSession -and
            $moshPageDiscardedAfterSession)) {
            throw '[product] Mosh abnormal-exit page isolation contract was not preserved'
        }
        $automaticErrorObserved = $true
        $observedErrorCategory = 'client-error'
        $sessionStayedConnected = $false
        $remoteShellAliveAfter = Test-WslProcessPresent -LinuxPid $fixtureTerminalPid
        $lastProvenBoundary = 'abnormal-exit-original-page-restored'
    }

    if ($Scenario -eq 'process-recovery') {
        Write-LiveStatus -Stage 'process-recovery-force-stop'
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
        $oldAppProcessIdentity = Get-MoshAppProcessIdentity
        if ($null -eq $oldAppProcessIdentity) {
            throw '[infrastructure] LeanTTY process identity disappeared before controlled force-stop'
        }
        & $hdc -t $targetId shell 'aa force-stop com.leantty.app' | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw '[environment] Unable to force-stop LeanTTY for process recovery'
        }
        $processStopwatch = [Diagnostics.Stopwatch]::StartNew()
        do {
            Start-Sleep -Milliseconds 100
            $remainingProcessId = (@(
                & $hdc -t $targetId shell 'pidof com.leantty.app' 2>&1
            ) -join "`n").Trim()
        } while ($remainingProcessId -match '^\d+$' -and
            $processStopwatch.Elapsed.TotalSeconds -lt 10)
        if ($remainingProcessId -match '^\d+$') {
            throw '[product] LeanTTY process remained after controlled force-stop'
        }

        $remoteShellAliveAtProcessChange = Test-WslProcessPresent -LinuxPid $fixtureTerminalPid
        $serverAliveAtProcessChange = Test-WslProcessPresent -LinuxPid $moshServerPid
        Write-LiveStatus -Stage 'process-recovery-relaunch'
        $restarted = Start-LeanTTYRegressionApp -Hdc $hdc -Target $targetId `
            -CredentialPath (Get-LeanTTYDeviceUnlockPasswordPath) -RepositoryRoot $repoRoot
        $appPid = $restarted.processId
        $resumedProcessIdentity = Get-MoshAppProcessIdentity
        if ($null -eq $resumedProcessIdentity) {
            throw '[infrastructure] Relaunched LeanTTY has no process identity'
        }
        $resumedAppProcessId = [string]$resumedProcessIdentity.processId
        $resumedAppProcessStartTimeTicks = [string]$resumedProcessIdentity.startTimeTicks
        $sameAppProcessAfterResume =
            [string]$resumedProcessIdentity.key -ceq [string]$oldAppProcessIdentity.key
        if ($sameAppProcessAfterResume) {
            throw '[product] Controlled process recovery did not create a new LeanTTY process'
        }
        Wait-LeanTTYTerminalInputLayout -Hdc $hdc -Target $targetId `
            -LocalPath (Join-Path $EvidenceDirectory 'process-recovery-ready.json') `
            -TimeoutSeconds 20 | Out-Null

        $processRecoveryWorkspaceRestored = Test-MoshTerminalSearch `
            -Query 'Workspace layout was recovered' -ExpectMatch $true `
            -Name 'process-recovery-warning-search'
        $processRecoveryRemoteContentAbsent = Test-MoshTerminalSearch `
            -Query $shellCommand -ExpectMatch $false `
            -Name 'process-recovery-old-output-negative-search'
        Reset-LeanTTYDeviceCommandInput -Hdc $hdc -Target $targetId -ProcessId $appPid
        Submit-LocalCommand -Command 'help' -Stage 'process-recovery-local-command'
        $localPromptReady = $true
        $recoveryLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $targetId -ProcessId $appPid
        $processRecoverySessionNotRestored =
            $processRecoveryRemoteContentAbsent -and $recoveryLogs -notmatch 'Mosh Session connected'
        if (-not ($processRecoveryWorkspaceRestored -and
            $processRecoveryRemoteContentAbsent -and $processRecoverySessionNotRestored)) {
            throw '[product] Process recovery restored remote Mosh state or lost the workspace warning'
        }
        $sessionStayedConnected = $false
        $remoteShellAliveAfter = Test-WslProcessPresent -LinuxPid $fixtureTerminalPid
        $observedErrorCategory = 'client-process-replaced'
        $lastProvenBoundary = 'client-process-replaced-local-workspace-only-recovered'
    }

    if ($Scenario -eq 'pane-close') {
        Write-LiveStatus -Stage 'pane-close-active-session'
        $closedPaneServerPid = $moshServerPid
        $closedPaneTerminalPid = $fixtureTerminalPid
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
        Close-ActiveMoshPane
        $paneCloseOldOutputAbsent = Test-MoshTerminalSearch `
            -Query "LTTY_MOSH_CHECK_OK:$caseId" -ExpectMatch $false `
            -Name 'mosh-pane-close-old-output-negative-search'

        Reset-LeanTTYDeviceCommandInput -Hdc $hdc -Target $targetId -ProcessId $appPid
        Clear-MoshSessionControlFiles
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
        Write-LiveStatus -Stage 'pane-close-survivor-connect'
        Submit-LocalCommand -Command "mosh $alias" -Stage 'mosh-pane-close-survivor-command'
        Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
            -Pattern 'Mosh auth event kind=password' -TimeoutSeconds 15 | Out-Null
        Submit-InteractiveValue -Value $fixturePassword -Name 'mosh-pane-close-survivor-password'
        Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
            -Pattern 'Mosh Session connected' -TimeoutSeconds 30 | Out-Null
        Wait-ControlFile -Path $fixtureTerminalReady -TimeoutSeconds 30 | Out-Null
        $fixtureTerminalPid = Read-ControlledLinuxPid -Path $fixtureTerminalPidPath
        $session = Read-MoshSession
        $moshServerPid = $session.pid
        $moshServerPort = $session.port
        $moshActualServerPort = $session.serverPort

        $survivorCaseId = 'survivor_' + $attemptId.Substring(0, 12)
        Submit-MoshInput -Text "ltty-mosh-check $survivorCaseId"
        Wait-ControlFileMatch -Path $fixtureEvent `
            -Pattern "(?ms)^case=$([regex]::Escape($survivorCaseId))$.*^result=passed$" `
            -TimeoutSeconds 20 | Out-Null
        $paneCloseSurvivorCommandPassed = $true
        $paneCloseOldServerExitElapsedMs = Wait-WslProcessAbsent `
            -LinuxPid $closedPaneServerPid -TimeoutSeconds 8
        Wait-WslProcessAbsent -LinuxPid $closedPaneTerminalPid -TimeoutSeconds 8 | Out-Null
        if (-not (Test-WslProcessPresent -LinuxPid $moshServerPid)) {
            throw '[product] Closed Pane lifecycle event terminated the surviving Pane Mosh Session'
        }
        $survivorObservation = Get-MoshLifecycleObservation
        if ($survivorObservation.closed -or $survivorObservation.error) {
            throw '[product] Closed Pane delivered a terminal lifecycle event into the surviving Pane'
        }
        $remoteShellAliveAfter = Test-WslProcessPresent -LinuxPid $fixtureTerminalPid
        $sessionStayedConnected = $remoteShellAliveAfter
        $observedErrorCategory = 'none'
        $lastProvenBoundary = 'pane-close-surviving-session-command-passed'
    }

    if ($Scenario -eq 'session-isolation') {
        Write-LiveStatus -Stage 'two-mosh-split'
        $leftMoshServerPid = $moshServerPid
        $leftMoshTerminalPid = $fixtureTerminalPid
        $leftMoshControlDirectory = $activeMoshControlDirectory
        $leftMoshEvent = Join-Path $leftMoshControlDirectory 'mosh-event'
        Split-MoshPane
        Clear-MoshLatestSessionMetadata
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId

        Write-LiveStatus -Stage 'two-mosh-right-connect'
        Submit-LocalCommand -Command "mosh $alias" -Stage 'two-mosh-right-connect-command'
        Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
            -Pattern 'Mosh auth event kind=password' -TimeoutSeconds 15 | Out-Null
        Submit-InteractiveValue -Value $fixturePassword -Name 'two-mosh-right-password'
        Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
            -Pattern 'Mosh Session connected' -TimeoutSeconds 30 | Out-Null
        $rightMoshSession = Read-MoshSession
        $rightMoshControlDirectory = $rightMoshSession.controlDirectory
        $rightMoshTerminalReady = Join-Path $rightMoshControlDirectory 'mosh-terminal-ready'
        $rightMoshTerminalPidPath = Join-Path $rightMoshControlDirectory 'mosh-terminal-pid'
        $rightMoshEvent = Join-Path $rightMoshControlDirectory 'mosh-event'
        Wait-ControlFile -Path $rightMoshTerminalReady -TimeoutSeconds 30 | Out-Null
        $rightMoshTerminalPid = Read-ControlledLinuxPid -Path $rightMoshTerminalPidPath
        $rightMoshServerPid = $rightMoshSession.pid
        $sessionIsolationServerPidsDistinct =
            $leftMoshServerPid -gt 0 -and $rightMoshServerPid -gt 0 -and
            $leftMoshServerPid -ne $rightMoshServerPid -and
            $leftMoshTerminalPid -ne $rightMoshTerminalPid
        $sessionIsolationKeysDistinct = $rightMoshSession.keyDistinctFromPrevious
        if (-not $sessionIsolationServerPidsDistinct) {
            throw '[product] Concurrent Mosh Panes did not own distinct server and PTY processes'
        }
        if (-not $sessionIsolationKeysDistinct) {
            throw '[product] Concurrent Mosh Panes reused one bootstrap encryption key'
        }

        $rightCaseId = 'right_' + $attemptId.Substring(0, 12)
        $activeMoshControlDirectory = $rightMoshControlDirectory
        Submit-MoshInput -Text "ltty-mosh-check $rightCaseId" `
            -ControlDirectory $rightMoshControlDirectory
        Wait-ControlFileMatch -Path $rightMoshEvent `
            -Pattern "(?ms)^case=$([regex]::Escape($rightCaseId))$.*^result=passed$" `
            -TimeoutSeconds 20 | Out-Null
        $rightOwnOutput = Test-MoshTerminalSearch `
            -Query "LTTY_MOSH_CHECK_OK:$rightCaseId" -ExpectMatch $true `
            -Name 'two-mosh-right-own-output'
        $rightForeignOutputAbsent = Test-MoshTerminalSearch `
            -Query "LTTY_MOSH_CHECK_OK:$caseId" -ExpectMatch $false `
            -Name 'two-mosh-right-foreign-output'

        Focus-MoshPane -Side 'left' -Name 'two-mosh-left-focus'
        $leftOwnOutput = Test-MoshTerminalSearch `
            -Query "LTTY_MOSH_CHECK_OK:$caseId" -ExpectMatch $true `
            -Name 'two-mosh-left-own-output'
        $leftForeignOutputAbsent = Test-MoshTerminalSearch `
            -Query "LTTY_MOSH_CHECK_OK:$rightCaseId" -ExpectMatch $false `
            -Name 'two-mosh-left-foreign-output'
        $twoMoshOutputIsolated = $rightOwnOutput -and $rightForeignOutputAbsent -and
            $leftOwnOutput -and $leftForeignOutputAbsent

        $leftInputCaseId = 'left_input_' + $attemptId.Substring(0, 8)
        $activeMoshControlDirectory = $leftMoshControlDirectory
        Submit-MoshInput -Text "ltty-mosh-check $leftInputCaseId" `
            -ControlDirectory $leftMoshControlDirectory
        Wait-ControlFileMatch -Path $leftMoshEvent `
            -Pattern "(?ms)^case=$([regex]::Escape($leftInputCaseId))$.*^result=passed$" `
            -TimeoutSeconds 20 | Out-Null
        Focus-MoshPane -Side 'right' -Name 'two-mosh-right-input-focus'
        $rightInputCaseId = 'right_input_' + $attemptId.Substring(0, 8)
        $activeMoshControlDirectory = $rightMoshControlDirectory
        Submit-MoshInput -Text "ltty-mosh-check $rightInputCaseId" `
            -ControlDirectory $rightMoshControlDirectory
        Wait-ControlFileMatch -Path $rightMoshEvent `
            -Pattern "(?ms)^case=$([regex]::Escape($rightInputCaseId))$.*^result=passed$" `
            -TimeoutSeconds 20 | Out-Null
        $twoMoshInputIsolated =
            (Test-WslProcessPresent -LinuxPid $leftMoshServerPid) -and
            (Test-WslProcessPresent -LinuxPid $rightMoshServerPid)

        Write-LiveStatus -Stage 'two-mosh-right-close'
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
        Close-ActiveMoshPane
        $rightCloseElapsedMs = Wait-WslProcessAbsent -LinuxPid $rightMoshServerPid -TimeoutSeconds 8
        Wait-WslProcessAbsent -LinuxPid $rightMoshTerminalPid -TimeoutSeconds 8 | Out-Null
        $leftAfterCloseCaseId = 'left_alive_' + $attemptId.Substring(0, 8)
        $activeMoshControlDirectory = $leftMoshControlDirectory
        Submit-MoshInput -Text "ltty-mosh-check $leftAfterCloseCaseId" `
            -ControlDirectory $leftMoshControlDirectory
        Wait-ControlFileMatch -Path $leftMoshEvent `
            -Pattern "(?ms)^case=$([regex]::Escape($leftAfterCloseCaseId))$.*^result=passed$" `
            -TimeoutSeconds 20 | Out-Null
        $twoMoshCloseIsolated = Test-WslProcessPresent -LinuxPid $leftMoshServerPid
        if (-not $twoMoshCloseIsolated) {
            throw '[product] Closing the right Mosh Session terminated the left Mosh Session'
        }

        Write-LiveStatus -Stage 'ssh-mosh-parallel-connect'
        Split-MoshPane
        Reset-LeanTTYDeviceCommandInput -Hdc $hdc -Target $targetId -ProcessId $appPid
        Submit-LocalCommand `
            -Command "host add $sshAlias password@${fixtureSshAddress}:$FixturePort" `
            -Stage 'ssh-mosh-host-setup'
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
        Submit-LocalCommand -Command "ssh $sshAlias" -Stage 'ssh-mosh-ssh-connect-command'
        Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
            -Pattern 'native auth event kind=password' -TimeoutSeconds 15 | Out-Null
        Submit-InteractiveValue -Value $fixturePassword -Name 'ssh-mosh-ssh-password'
        Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
            -Pattern 'SSH session connected' -TimeoutSeconds 30 | Out-Null

        $sshCaseId = 'ssh_' + $attemptId.Substring(0, 12)
        Submit-MoshChildInput -Text "ltty-input-check $sshCaseId" -Name 'ssh-mosh-ssh-command'
        $sshOwnOutput = Test-MoshTerminalSearch `
            -Query "LTTY_INPUT_OK:$sshCaseId" -ExpectMatch $true `
            -Name 'ssh-mosh-ssh-own-output'
        $sshForeignOutputAbsent = Test-MoshTerminalSearch `
            -Query "LTTY_MOSH_CHECK_OK:$leftAfterCloseCaseId" -ExpectMatch $false `
            -Name 'ssh-mosh-ssh-foreign-output'

        Focus-MoshPane -Side 'left' -Name 'ssh-mosh-left-focus'
        $moshParallelCaseId = 'mosh_parallel_' + $attemptId.Substring(0, 8)
        $activeMoshControlDirectory = $leftMoshControlDirectory
        Submit-MoshInput -Text "ltty-mosh-check $moshParallelCaseId" `
            -ControlDirectory $leftMoshControlDirectory
        Wait-ControlFileMatch -Path $leftMoshEvent `
            -Pattern "(?ms)^case=$([regex]::Escape($moshParallelCaseId))$.*^result=passed$" `
            -TimeoutSeconds 20 | Out-Null
        $moshOwnOutput = Test-MoshTerminalSearch `
            -Query "LTTY_MOSH_CHECK_OK:$moshParallelCaseId" -ExpectMatch $true `
            -Name 'ssh-mosh-mosh-own-output'
        $moshForeignOutputAbsent = Test-MoshTerminalSearch `
            -Query "LTTY_INPUT_OK:$sshCaseId" -ExpectMatch $false `
            -Name 'ssh-mosh-mosh-foreign-output'
        $sshMoshOutputIsolated = $sshOwnOutput -and $sshForeignOutputAbsent -and
            $moshOwnOutput -and $moshForeignOutputAbsent
        $sshMoshInputIsolated =
            (Test-WslProcessPresent -LinuxPid $leftMoshServerPid) -and
            (Test-WslProcessPresent -LinuxPid $leftMoshTerminalPid)

        Write-LiveStatus -Stage 'ssh-mosh-close-mosh'
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
        Close-ActiveMoshPane
        $leftCloseElapsedMs = Wait-WslProcessAbsent -LinuxPid $leftMoshServerPid -TimeoutSeconds 8
        Wait-WslProcessAbsent -LinuxPid $leftMoshTerminalPid -TimeoutSeconds 8 | Out-Null

        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
        $sshAfterCloseCaseId = 'ssh_alive_' + $attemptId.Substring(0, 8)
        Submit-MoshChildInput `
            -Text "ltty-input-check $sshAfterCloseCaseId" -Name 'ssh-after-mosh-close-command'
        $sshAfterMoshCloseOutput = Test-MoshTerminalSearch `
            -Query "LTTY_INPUT_OK:$sshAfterCloseCaseId" -ExpectMatch $true `
            -Name 'ssh-after-mosh-close-output'
        $parallelLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $targetId -ProcessId $appPid
        $sshMoshCloseIsolated = $sshAfterMoshCloseOutput -and
            $parallelLogs -notmatch 'SSH closed, exitCode='
        if (-not $sshMoshCloseIsolated) {
            throw '[product] Closing the Mosh Session terminated or corrupted the parallel SSH Session'
        }

        Write-LiveStatus -Stage 'ssh-mosh-close-ssh'
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
        Submit-MoshChildInput -Text 'ltty-exit' -Name 'ssh-mosh-ssh-exit'
        Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
            -Pattern 'SSH closed, exitCode=0' -TimeoutSeconds 20 | Out-Null
        Reset-LeanTTYDeviceCommandInput -Hdc $hdc -Target $targetId -ProcessId $appPid
        $localPromptReady = $true
        $authenticatedGracefulClose = $true
        $gracefulServerExitElapsedMs = [Math]::Max($rightCloseElapsedMs, $leftCloseElapsedMs)
        $localCloseElapsedMs = $leftCloseElapsedMs
        $remoteShellAliveAfter = $false
        $sessionStayedConnected = $twoMoshCloseIsolated -and $sshMoshCloseIsolated
        $observedErrorCategory = 'none'
        $lastProvenBoundary = 'two-mosh-and-ssh-mosh-session-isolation-passed'
    }

    if ($Scenario -eq 'suspend-recovery') {
        Write-LiveStatus -Stage 'system-suspend'
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
        $suspendStopwatch = [Diagnostics.Stopwatch]::StartNew()
        & $hdc -t $targetId shell 'power-shell suspend' | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw '[infrastructure] Unable to suspend the HarmonyOS PC during Mosh'
        }
        Start-Sleep -Seconds 5

        Write-LiveStatus -Stage 'system-wakeup'
        & $hdc -t $targetId shell 'power-shell wakeup' | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw '[infrastructure] Unable to wake the HarmonyOS PC during Mosh'
        }
        $systemSuspendMs = [long]$suspendStopwatch.Elapsed.TotalMilliseconds
        Start-Sleep -Seconds 2

        $resumedProcessIdentity = Get-MoshAppProcessIdentity
        $resumedAppProcessId = if ($null -eq $resumedProcessIdentity) {
            ''
        } else { [string]$resumedProcessIdentity.processId }
        $resumedAppProcessStartTimeTicks = if ($null -eq $resumedProcessIdentity) {
            ''
        } else { [string]$resumedProcessIdentity.startTimeTicks }
        $sameAppProcessAfterResume = $null -ne $resumedProcessIdentity -and
            [string]$resumedProcessIdentity.key -ceq [string]$initialProcessIdentity.key
        if (-not $sameAppProcessAfterResume) {
            $remoteShellAliveAtProcessChange = Test-WslProcessPresent -LinuxPid $fixtureTerminalPid
            $serverAliveAtProcessChange = Test-WslProcessPresent -LinuxPid $moshServerPid
            throw '[product] LeanTTY did not retain the same application process across Mosh suspend and wake'
        }
        $resume = Start-LeanTTYRegressionApp -Hdc $hdc -Target $targetId `
            -CredentialPath (Get-LeanTTYDeviceUnlockPasswordPath) -RepositoryRoot $repoRoot
        $deviceUnlockAfterResume = [string]$resume.unlock
        if ([string]$resume.processId -cne $appPid) {
            throw '[product] LeanTTY application process changed while restoring the suspended Mosh Session'
        }
        Wait-LeanTTYTerminalInputLayout -Hdc $hdc -Target $targetId `
            -LocalPath (Join-Path $EvidenceDirectory 'suspend-resumed.json') `
            -TimeoutSeconds 30 | Out-Null

        Write-LiveStatus -Stage 'suspend-recovery-command'
        $resumeCommandStopwatch = [Diagnostics.Stopwatch]::StartNew()
        $resumeCaseId = 'suspend_' + $attemptId.Substring(0, 10)
        Submit-MoshInput -Text "ltty-mosh-check $resumeCaseId"
        Wait-ControlFileMatch -Path $fixtureEvent `
            -Pattern "(?ms)^case=$([regex]::Escape($resumeCaseId))$.*^result=passed$" `
            -TimeoutSeconds 20 | Out-Null
        $resumeCommandElapsedMs = [long]$resumeCommandStopwatch.Elapsed.TotalMilliseconds

        $suspendObservation = Get-MoshLifecycleObservation
        $automaticCloseObserved = $suspendObservation.closed
        $automaticErrorObserved = $suspendObservation.error
        $interruptionObserved = $suspendObservation.interrupted
        $interruptionReason = $suspendObservation.interruptionReason
        $recoveredStatusObserved = $suspendObservation.recovered
        $remoteShellAliveAfter = Test-WslProcessPresent -LinuxPid $fixtureTerminalPid
        $serverAliveAfterResume = Test-WslProcessPresent -LinuxPid $moshServerPid
        $recoveryCommandPassed = -not $automaticCloseObserved -and -not $automaticErrorObserved
        $sessionStayedConnected = $recoveryCommandPassed -and $remoteShellAliveAfter -and `
            $serverAliveAfterResume
        if (-not $sessionStayedConnected) {
            throw '[product] Mosh Session or remote shell did not survive system suspend and wake'
        }
        $observedErrorCategory = 'none'
        $lastProvenBoundary = 'system-suspend-recovered-with-process-and-shell-preserved'
        [IO.File]::WriteAllText(
            (Join-Path $EvidenceDirectory 'lifecycle-device-app.log'),
            $suspendObservation.logs + "`n",
            [Text.UTF8Encoding]::new($false)
        )
    }

    if ($Scenario -in @('operator-lock-recovery', 'operator-lid-recovery')) {
        $operatorStage = if ($Scenario -eq 'operator-lid-recovery') {
            'operator-lid'
        } else { 'operator-lock' }
        Write-LiveStatus -Stage "await-$operatorStage-close"
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
        $operatorLockStopwatch = [Diagnostics.Stopwatch]::StartNew()
        if ($Scenario -eq 'operator-lid-recovery') {
            Wait-MoshDeviceLockState -ExpectedLocked $true `
                -TolerateUnavailable -UnavailableCountsAsLocked | Out-Null
        } else {
            Wait-MoshDeviceLockState -ExpectedLocked $true | Out-Null
        }
        $operatorLockObserved = $true

        Write-LiveStatus -Stage "await-$operatorStage-open-unlock"
        Wait-MoshDeviceLockState -ExpectedLocked $false `
            -TolerateUnavailable:($Scenario -eq 'operator-lid-recovery') | Out-Null
        $operatorUnlockObserved = $true
        $operatorLockDurationMs = [long]$operatorLockStopwatch.Elapsed.TotalMilliseconds
        $deviceUnlockAfterResume = 'operator'

        $resumedProcessIdentity = Get-MoshAppProcessIdentity
        $resumedAppProcessId = if ($null -eq $resumedProcessIdentity) {
            ''
        } else { [string]$resumedProcessIdentity.processId }
        $resumedAppProcessStartTimeTicks = if ($null -eq $resumedProcessIdentity) {
            ''
        } else { [string]$resumedProcessIdentity.startTimeTicks }
        $sameAppProcessAfterResume = $null -ne $resumedProcessIdentity -and
            [string]$resumedProcessIdentity.key -ceq [string]$initialProcessIdentity.key
        if (-not $sameAppProcessAfterResume) {
            $remoteShellAliveAtProcessChange = Test-WslProcessPresent -LinuxPid $fixtureTerminalPid
            $serverAliveAtProcessChange = Test-WslProcessPresent -LinuxPid $moshServerPid
            if ($Scenario -eq 'operator-lock-recovery') {
                throw '[product] LeanTTY did not retain the same application process across operator-lock recovery'
            }

            Write-LiveStatus -Stage 'operator-lid-workspace-recovery'
            $restarted = Start-LeanTTYRegressionApp -Hdc $hdc -Target $targetId `
                -CredentialPath (Get-LeanTTYDeviceUnlockPasswordPath) -RepositoryRoot $repoRoot
            $appPid = $restarted.processId
            $resumedAppProcessId = $appPid
            Wait-LeanTTYTerminalInputLayout -Hdc $hdc -Target $targetId `
                -LocalPath (Join-Path $EvidenceDirectory 'operator-lid-workspace-recovered.json') `
                -TimeoutSeconds 30 | Out-Null

            $processRecoveryWorkspaceRestored = Test-MoshTerminalSearch `
                -Query 'Workspace layout was recovered' -ExpectMatch $true `
                -Name 'operator-lid-recovery-warning-search'
            $processRecoveryRemoteContentAbsent = Test-MoshTerminalSearch `
                -Query $shellCommand -ExpectMatch $false `
                -Name 'operator-lid-old-output-negative-search'
            Reset-LeanTTYDeviceCommandInput -Hdc $hdc -Target $targetId -ProcessId $appPid
            Submit-LocalCommand -Command 'help' -Stage 'operator-lid-local-command'
            $localPromptReady = $true
            $recoveryLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $targetId -ProcessId $appPid
            $processRecoverySessionNotRestored =
                $processRecoveryRemoteContentAbsent -and
                $recoveryLogs -notmatch 'Mosh Session connected'
            if (-not ($processRecoveryWorkspaceRestored -and
                $processRecoveryRemoteContentAbsent -and $processRecoverySessionNotRestored)) {
                throw '[product] Physical-lid recovery restored remote Mosh state or lost the workspace warning'
            }

            $operatorRecoveryOutcome = 'client-process-replaced-workspace-only'
            $sessionStayedConnected = $false
            $recoveryCommandPassed = $true
            $remoteShellAliveAfter = Test-WslProcessPresent -LinuxPid $fixtureTerminalPid
            $observedErrorCategory = 'client-process-replaced'
            $lastProvenBoundary = 'operator-lid-client-process-replaced-workspace-only-recovered'
            [IO.File]::WriteAllText(
                (Join-Path $EvidenceDirectory 'operator-lid-device-app.log'),
                $recoveryLogs + "`n",
                [Text.UTF8Encoding]::new($false)
            )
        } else {
            Wait-LeanTTYTerminalInputLayout -Hdc $hdc -Target $targetId `
                -LocalPath (Join-Path $EvidenceDirectory "$operatorStage-resumed.json") `
                -TimeoutSeconds 30 | Out-Null

            Write-LiveStatus -Stage "$operatorStage-recovery-command"
            $resumeCommandStopwatch = [Diagnostics.Stopwatch]::StartNew()
            $resumeCaseId = if ($Scenario -eq 'operator-lid-recovery') {
                'lid_' + $attemptId.Substring(0, 10)
            } else { 'lock_' + $attemptId.Substring(0, 10) }
            $recoveryInputMethod = 'harmony-uitest-targeted-inputText'
            Submit-MoshInput -Text "ltty-mosh-check $resumeCaseId"
            Wait-ControlFileMatch -Path $fixtureEvent `
                -Pattern "(?ms)^case=$([regex]::Escape($resumeCaseId))$.*^result=passed$" `
                -TimeoutSeconds 20 | Out-Null
            $resumeCommandElapsedMs = [long]$resumeCommandStopwatch.Elapsed.TotalMilliseconds

            $lockObservation = Get-MoshLifecycleObservation
            $automaticCloseObserved = $lockObservation.closed
            $automaticErrorObserved = $lockObservation.error
            $interruptionObserved = $lockObservation.interrupted
            $interruptionReason = $lockObservation.interruptionReason
            $recoveredStatusObserved = $lockObservation.recovered
            $remoteShellAliveAfter = Test-WslProcessPresent -LinuxPid $fixtureTerminalPid
            $serverAliveAfterUnlock = Test-WslProcessPresent -LinuxPid $moshServerPid
            $recoveryCommandPassed = -not $automaticCloseObserved -and -not $automaticErrorObserved
            $sessionStayedConnected = $recoveryCommandPassed -and $remoteShellAliveAfter -and `
                $serverAliveAfterUnlock
            if (-not $sessionStayedConnected) {
                throw "[product] Mosh Session or remote shell did not survive $operatorStage recovery"
            }
            $operatorRecoveryOutcome = 'client-process-and-session-preserved'
            $observedErrorCategory = 'none'
            $lastProvenBoundary = "$operatorStage-recovered-with-process-and-shell-preserved"
            [IO.File]::WriteAllText(
                (Join-Path $EvidenceDirectory "$operatorStage-device-app.log"),
                $lockObservation.logs + "`n",
                [Text.UTF8Encoding]::new($false)
            )
        }
    }

    if ($Scenario -eq 'pause-recovery') {
        Write-LiveStatus -Stage 'udp-pause'
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
        $pauseStopwatch = [Diagnostics.Stopwatch]::StartNew()
        Enable-MoshUdpImpairment
        Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
            -Pattern 'Mosh reachability state=interrupted reason=no_recent_contact' `
            -TimeoutSeconds 15 | Out-Null
        $pauseObservation = Get-MoshLifecycleObservation
        $automaticCloseObserved = $pauseObservation.closed
        $automaticErrorObserved = $pauseObservation.error
        $interruptionObserved = $pauseObservation.interrupted
        $interruptionReason = $pauseObservation.interruptionReason
        $remoteShellAliveAfter = Test-WslProcessPresent -LinuxPid $fixtureTerminalPid
        $serverAliveDuringPause = Test-WslProcessPresent -LinuxPid $moshServerPid
        $sessionStayedConnected = -not $automaticCloseObserved -and -not $automaticErrorObserved
        if (-not $sessionStayedConnected) {
            throw '[product] Mosh Session terminated during a controlled UDP pause'
        }
        if (-not $serverAliveDuringPause -or -not $remoteShellAliveAfter) {
            throw '[product] Remote Mosh server or shell exited during a controlled UDP pause'
        }

        Write-LiveStatus -Stage 'udp-recovery'
        Disable-MoshUdpImpairment
        $networkPauseDurationMs = [long]$pauseStopwatch.Elapsed.TotalMilliseconds
        Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
            -Pattern 'Mosh reachability state=responsive transition=recovered' `
            -TimeoutSeconds 15 | Out-Null
        $recoveryCaseId = 'resume_' + $attemptId.Substring(0, 12)
        Submit-MoshInput -Text "ltty-mosh-check $recoveryCaseId"
        Wait-ControlFileMatch -Path $fixtureEvent `
            -Pattern "(?ms)^case=$([regex]::Escape($recoveryCaseId))$.*^result=passed$" `
            -TimeoutSeconds 20 | Out-Null
        $recoveryObservation = Get-MoshLifecycleObservation
        $automaticCloseObserved = $automaticCloseObserved -or $recoveryObservation.closed
        $automaticErrorObserved = $automaticErrorObserved -or $recoveryObservation.error
        $recoveredStatusObserved = $recoveryObservation.recovered
        $recoveryCommandPassed = -not $automaticCloseObserved -and -not $automaticErrorObserved
        $remoteShellAliveAfter = Test-WslProcessPresent -LinuxPid $fixtureTerminalPid
        if (-not $recoveryCommandPassed -or -not $remoteShellAliveAfter) {
            throw '[product] Mosh Session did not recover the controlled command after UDP resumed'
        }
        $observedErrorCategory = 'none'
        $lastProvenBoundary = 'udp-pause-recovered-with-shell-preserved'
        [IO.File]::WriteAllText(
            (Join-Path $EvidenceDirectory 'network-behavior-device-app.log'),
            $recoveryObservation.logs + "`n",
            [Text.UTF8Encoding]::new($false)
        )
    }

    if ($Scenario -eq 'wifi-pause-recovery') {
        Write-LiveStatus -Stage 'wifi-pause'
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
        $pauseStopwatch = [Diagnostics.Stopwatch]::StartNew()
        Set-MoshDeviceWifi -Enabled $false -Name 'mosh-wifi-off'
        $wifiControlCleanupVerified = $false
        $wifiOutcome = Wait-MoshWifiInterruptionOutcome -TimeoutSeconds 20
        $pauseObservation = Get-MoshLifecycleObservation
        $automaticCloseObserved = $pauseObservation.closed
        $automaticErrorObserved = $pauseObservation.error
        $interruptionObserved = $pauseObservation.interrupted
        $interruptionReason = $pauseObservation.interruptionReason
        $remoteShellAliveAfter = Test-WslProcessPresent -LinuxPid $fixtureTerminalPid
        $serverAliveDuringPause = Test-WslProcessPresent -LinuxPid $moshServerPid
        $sessionStayedConnected = -not $automaticCloseObserved -and -not $automaticErrorObserved
        $networkPauseDurationMs = [long]$pauseStopwatch.Elapsed.TotalMilliseconds
        if ($wifiOutcome.outcome -eq 'fatal-udp-error') {
            $observedErrorCategory = 'local-udp-io-error'
            $lastProvenBoundary = 'physical-wifi-disable-terminated-session'
            throw '[product] Physical Wi-Fi disable produced a fatal local UDP I/O error'
        }
        if (-not $sessionStayedConnected) {
            throw '[product] Mosh Session terminated while physical Wi-Fi was disabled'
        }
        if (-not $serverAliveDuringPause -or -not $remoteShellAliveAfter) {
            throw '[product] Remote Mosh server or shell exited while physical Wi-Fi was disabled'
        }

        Write-LiveStatus -Stage 'wifi-recovery'
        Set-MoshDeviceWifi -Enabled $true -Name 'mosh-wifi-on'
        $wifiControlCleanupVerified = $true
        Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
            -Pattern 'Mosh reachability state=responsive transition=recovered' `
            -TimeoutSeconds 25 | Out-Null
        Focus-ActiveTerminalInput -Name 'mosh-wifi-recovery-focus.json' | Out-Null
        $recoveryCaseId = 'wifi_' + $attemptId.Substring(0, 12)
        Submit-MoshInput -Text "ltty-mosh-check $recoveryCaseId"
        Wait-ControlFileMatch -Path $fixtureEvent `
            -Pattern "(?ms)^case=$([regex]::Escape($recoveryCaseId))$.*^result=passed$" `
            -TimeoutSeconds 25 | Out-Null
        $recoveryObservation = Get-MoshLifecycleObservation
        $automaticCloseObserved = $automaticCloseObserved -or $recoveryObservation.closed
        $automaticErrorObserved = $automaticErrorObserved -or $recoveryObservation.error
        $recoveredStatusObserved = $recoveryObservation.recovered
        $recoveryCommandPassed = -not $automaticCloseObserved -and -not $automaticErrorObserved
        $remoteShellAliveAfter = Test-WslProcessPresent -LinuxPid $fixtureTerminalPid
        if (-not $recoveryCommandPassed -or -not $remoteShellAliveAfter) {
            throw '[product] Mosh Session did not recover after physical Wi-Fi was re-enabled'
        }
        $observedErrorCategory = 'none'
        $lastProvenBoundary = 'physical-wifi-pause-recovered-with-shell-preserved'
        [IO.File]::WriteAllText(
            (Join-Path $EvidenceDirectory 'network-behavior-device-app.log'),
            $recoveryObservation.logs + "`n",
            [Text.UTF8Encoding]::new($false)
        )
    }

    if ($Scenario -eq 'server-disappearance') {
        Write-LiveStatus -Stage 'server-disappearance'
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
        $prefix = Get-LeanTTYWslPrefix -Distribution $Distribution
        & wsl.exe @prefix --exec kill -KILL $moshServerPid 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw '[infrastructure] Unable to remove the controlled Mosh server'
        }
        Wait-WslProcessAbsent -LinuxPid $moshServerPid -TimeoutSeconds 8 | Out-Null
        $disappearanceStopwatch = [Diagnostics.Stopwatch]::StartNew()
        Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
            -Pattern 'Mosh reachability state=interrupted reason=no_recent_contact' `
            -TimeoutSeconds 15 | Out-Null
        $networkPauseDurationMs = [long]$disappearanceStopwatch.Elapsed.TotalMilliseconds
        $disappearanceObservation = Get-MoshLifecycleObservation
        $automaticCloseObserved = $disappearanceObservation.closed
        $automaticErrorObserved = $disappearanceObservation.error
        $interruptionObserved = $disappearanceObservation.interrupted
        $interruptionReason = $disappearanceObservation.interruptionReason
        $sessionStayedConnected = -not $automaticCloseObserved -and -not $automaticErrorObserved
        $remoteShellAliveAfter = Test-WslProcessPresent -LinuxPid $fixtureTerminalPid
        $userCloseRequired = $sessionStayedConnected
        $observedErrorCategory = $(if ($sessionStayedConnected) {
            'network-silence-no-lifecycle-event'
        } elseif ($automaticErrorObserved) { 'client-error' } else { 'remote-close' })
        if (-not $sessionStayedConnected) {
            throw '[product] Mosh Session changed lifecycle state after unauthenticated server silence'
        }
        $lastProvenBoundary = 'server-disappeared-session-awaiting-user-close'
        [IO.File]::WriteAllText(
            (Join-Path $EvidenceDirectory 'network-behavior-device-app.log'),
            $disappearanceObservation.logs + "`n",
            [Text.UTF8Encoding]::new($false)
        )
    }

    $workspaceOnlyLidRecovery =
        $Scenario -eq 'operator-lid-recovery' -and -not $sameAppProcessAfterResume
    if ($Scenario -notin @('session-isolation', 'abnormal-exit', 'process-recovery') -and
        -not $workspaceOnlyLidRecovery) {
        Write-LiveStatus -Stage 'ctrl-caret-disconnect'
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
        $closeStopwatch = [Diagnostics.Stopwatch]::StartNew()
        Invoke-MoshDisconnectEscape
        Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
            -Pattern 'Mosh Session closed' -TimeoutSeconds 20 | Out-Null
        $localCloseElapsedMs = [long]$closeStopwatch.Elapsed.TotalMilliseconds
        if ($Scenario -eq 'server-disappearance') {
            $lastProvenBoundary = 'ctrl-caret-local-close-after-server-disappearance'
        } else {
            $gracefulServerExitElapsedMs = Wait-WslProcessAbsent `
                -LinuxPid $moshServerPid -TimeoutSeconds 8
            $authenticatedGracefulClose = $true
            $lastProvenBoundary = 'ctrl-caret-disconnect-and-server-exit'
        }
        $disconnectLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $targetId -ProcessId $appPid
        $localCloseElapsedMs = Get-MoshCloseProtocolElapsedMs `
            -Logs $disconnectLogs -FallbackElapsedMs $localCloseElapsedMs
        if ($Scenario -eq 'server-disappearance' -and $localCloseElapsedMs -gt 4250) {
            throw '[product] Local Mosh close exceeded the bounded server-silence close interval'
        }
        $disconnectLogs = [regex]::Replace(
            $disconnectLogs,
            'MOSH CONNECT\s+\d+\s+[A-Za-z0-9+/]{22}',
            'MOSH CONNECT [REDACTED]'
        )
        [IO.File]::WriteAllText(
            (Join-Path $EvidenceDirectory 'disconnect-device-app.log'),
            $disconnectLogs + "`n",
            [Text.UTF8Encoding]::new($false)
        )
        try {
            Reset-LeanTTYDeviceCommandInput -Hdc $hdc -Target $targetId -ProcessId $appPid
        } catch {
            throw '[product] Mosh closed but the local prompt did not become input-ready'
        }
        $localPromptReady = $true
        $originalPageRestoredAfterSession = Test-MoshTerminalSearch `
            -Query $originalPageMarker -ExpectMatch $true -Name 'mosh-original-page-restored-search'
        if ($Scenario -ne 'prediction') {
            $moshPageDiscardedAfterSession = Test-MoshTerminalSearch `
                -Query $shellCommand -ExpectMatch $false -Name 'mosh-session-page-discarded-search'
        } else {
            $moshPageDiscardedAfterSession = $true
        }
        if (-not ($originalPageHiddenDuringSession -and $originalPageRestoredAfterSession -and
            $moshPageDiscardedAfterSession)) {
            throw '[product] Mosh Session page isolation contract was not preserved'
        }
    }

    Write-LiveStatus -Stage 'cleanup'
    Remove-DeviceState
    $preferencesDigestAfter = Get-MoshPreferencesDigest
    $preferencesUnchanged = ($preferencesDigestBefore -ceq $preferencesDigestAfter)
    if (-not $preferencesUnchanged) {
        throw '[product] LeanTTY Preferences changed during the Mosh compatibility scenario'
    }
    Stop-MoshFixture
    Remove-MoshFixtureMapping
    $lastProvenBoundary = 'cleanup-complete'

    foreach ($path in @($fixtureStdout, $fixtureStderr)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $contents = Read-LeanTTYSharedTextFile -Path $path
            if ($contents.Contains($fixturePassword) -or
                $contents -match 'MOSH CONNECT\s+\d+\s+[A-Za-z0-9+/]{22}') {
                throw '[product] Mosh evidence exposed a temporary secret'
            }
        }
    }
    $deviceLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $targetId -ProcessId $appPid
    if ($deviceLogs.Contains($fixturePassword) -or
        $deviceLogs -match 'MOSH CONNECT\s+\d+\s+[A-Za-z0-9+/]{22}') {
        throw '[product] HarmonyOS application logs exposed a temporary Mosh secret'
    }
    if (-not $bootstrapTerminalAbsent) {
        throw '[product] Mosh bootstrap text was visible in the terminal surface'
    }
    $secretAuditPassed = $true
    [IO.File]::WriteAllText(
        (Join-Path $EvidenceDirectory 'device-app.log'),
        $deviceLogs + "`n",
        [Text.UTF8Encoding]::new($false)
    )
    $fixturePassword = ''
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
    $result = 'passed'
    Write-Evidence
    Write-Host "MOSH PC DIAGNOSTIC SUCCESS: $evidencePath" -ForegroundColor Green
} catch {
    $failure = $_.Exception.Message
    $failureDomain = if ($failure -match '^\[(product|harness|environment|infrastructure|unknown)\]') {
        $Matches[1]
    } else { 'harness' }
    try { Save-MoshFailureLogs } catch {}
    throw
} finally {
    if (Test-Path -LiteralPath $fixturePredictionRelayPause -PathType Leaf) {
        try { Disable-MoshPredictionRelayPause } catch {
            Write-Warning ("Unable to resume controlled Mosh prediction relay: " + $_.Exception.Message)
        }
    }
    if ($udpImpairmentOwnsQdisc) {
        try { Disable-MoshUdpImpairment } catch {
            Write-Warning ("Unable to remove owned Mosh UDP impairment: " + $_.Exception.Message)
        }
    }
    if ($wifiDisabledByScenario) {
        try {
            Set-MoshDeviceWifi -Enabled $true -Name 'mosh-wifi-failure-restore'
            $wifiControlCleanupVerified = $true
        } catch {
            $wifiControlCleanupVerified = $false
            Write-Warning ("Unable to restore HarmonyOS Wi-Fi: " + $_.Exception.Message)
        }
    }
    if ($windowToggled -and -not [string]::IsNullOrWhiteSpace($targetId) -and $null -ne $hdc) {
        try {
            Toggle-MoshWindowSize -Name 'mosh-failure-resize-restore'
            $windowToggled = $false
        } catch {}
    }
    if (-not $deviceStateCleaned) {
        try { Remove-DeviceState } catch {}
    }
    if (-not $fixtureCleaned) {
        try { Stop-MoshFixture } catch {}
    }
    if ($fixtureMappingActive) {
        try { Remove-MoshFixtureMapping } catch {}
    }
    if ($awakeLeaseActive) {
        Stop-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $targetId
    }
    if (Test-Path -LiteralPath $fixtureRoot) {
        try { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force } catch {}
    }
    if ($result -ne 'passed') {
        try {
            Write-Evidence
        } catch {
            Write-Warning ("Unable to write Mosh diagnostic evidence: " + $_.Exception.Message)
        }
        if (-not [string]::IsNullOrWhiteSpace($failure)) {
            Write-Warning "Mosh physical diagnostic failed: $failure"
        }
    }
}
