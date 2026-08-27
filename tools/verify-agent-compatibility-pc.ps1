<#
.SYNOPSIS
  Verify native Agent TUI attention and core interaction over WSL OpenSSH on a physical PC.
.DESCRIPTION
  Starts an isolated OpenSSH daemon in the default WSL distribution, uses the diagnostic
  app's existing public key, and runs authenticated Codex, OpenCode, Pi Agent and
  Qwen Code TUIs in direct SSH and tmux. Raw PTY captures are summarized without content
  and deleted. Missing Agent authentication is recorded as not assessed, never as pass.
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [Parameter(Mandatory = $true)][string]$HapPath,
    [string]$EvidenceDirectory = '',
    [ValidateRange(0, 65535)][int]$Port = 0,
    [ValidateSet('codex', 'opencode', 'pi', 'qwen')]
    [string[]]$Agents = @('codex', 'opencode', 'pi', 'qwen'),
    [ValidateSet('direct', 'tmux')]
    [string[]]$Modes = @('direct', 'tmux'),
    [switch]$AllowPartialAuthentication,
    [switch]$Osc99CapabilityProbe,
    [switch]$InteractionOnlyProbe,
    [switch]$ProtocolInteractionProbe,
    [switch]$OpenCodeForceOsc99Protocol,
    [switch]$DiagnosticHap,
    [string]$CandidateBasePath = '',
    [string]$PreviousAttemptId = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'candidate-store.ps1')
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')
. (Join-Path $PSScriptRoot 'rust-wsl.ps1')
. (Join-Path $PSScriptRoot 'agent-compatibility-policy.ps1')
. (Join-Path $PSScriptRoot 'release-tooling.ps1')

$harnessStatus = @(git -C $repoRoot status --porcelain --untracked-files=all 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect Agent compatibility harness source state' }
$harnessDirty = ($harnessStatus.Count -gt 0)
if ($harnessDirty -and -not $DiagnosticHap) {
    throw 'Agent compatibility harness requires a clean committed tree for acceptance evidence'
}
$harnessCommit = (& git -C $repoRoot rev-parse HEAD 2>&1).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve Agent compatibility harness commit' }
$harnessTree = (& git -C $repoRoot rev-parse 'HEAD^{tree}' 2>&1).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve Agent compatibility harness tree' }

$harnessDifferencePaths = @()
if ($DiagnosticHap) {
    $resolvedHap = [IO.Path]::GetFullPath($HapPath)
    if (-not (Test-Path -LiteralPath $resolvedHap -PathType Leaf)) {
        throw "Diagnostic HAP is missing: $resolvedHap"
    }
    $candidate = [pscustomobject][ordered]@{
        sha256 = (Get-FileHash -LiteralPath $resolvedHap -Algorithm SHA256).Hash.ToLowerInvariant()
        hapPath = $resolvedHap
        gitCommit = $null
        gitTree = $null
        gitDirty = $null
        verificationMode = 'diagnostic'
    }
} else {
    $candidate = Resolve-LeanTTYRetainedCandidate `
        -RepoRoot $repoRoot `
        -HapPath $HapPath `
        -CandidateBasePath $CandidateBasePath
    if ([bool]$candidate.gitDirty) {
        throw 'Agent compatibility evidence requires a clean committed candidate'
    }
    $harnessDifferencePaths = @(Assert-LeanTTYCandidateHarnessCompatibility `
        -RepoRoot $repoRoot `
        -Candidate $candidate `
        -AllowedHarnessPaths @(
            'tools/verify-agent-compatibility-pc.ps1',
            'tools/agent-compatibility-policy.ps1',
            'tools/agent-compatibility-wsl.sh',
            'tools/agent-compatibility/*',
            'tools/test-agent-compatibility.ps1',
            'tools/test-acceptance-harness.ps1',
            'tools/qualify-acceptance-harness-pc.ps1',
            'tools/test-build-workflows.ps1',
            'tools/candidate-store.ps1',
            'tools/device-regression.ps1',
            'tools/hdc-common.ps1',
            'tools/rust-wsl.ps1',
            'docs/quality-strategy.md',
            'docs/design/agent-tui-compatibility.md'
        ))
}
$HapPath = [string]$candidate.hapPath
if ((Split-Path $HapPath -Leaf) -match 'unsigned') {
    throw 'Agent compatibility device verification requires a signed HAP'
}
if ($Port -eq 0) { $Port = Get-Random -Minimum 30000 -Maximum 45000 }
$probeModeCount = 0
foreach ($probeEnabled in @($Osc99CapabilityProbe, $InteractionOnlyProbe, $ProtocolInteractionProbe)) {
    if ($probeEnabled) { $probeModeCount++ }
}
if ($probeModeCount -gt 1) {
    throw '-Osc99CapabilityProbe, -InteractionOnlyProbe and -ProtocolInteractionProbe are mutually exclusive'
}
if ($ProtocolInteractionProbe -and
    ($Agents.Count -ne 1 -or $Agents[0] -ne 'qwen')) {
    throw '-ProtocolInteractionProbe requires -Agents qwen'
}
if ($OpenCodeForceOsc99Protocol -and
    ($Agents.Count -ne 1 -or $Agents[0] -ne 'opencode')) {
    throw '-OpenCodeForceOsc99Protocol requires -Agents opencode'
}
$startedAt = [DateTimeOffset]::UtcNow
$attemptId = [Guid]::NewGuid().ToString('N')
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $repoRoot (
        'build\verification\agent-compatibility-' + $startedAt.ToString('yyyyMMddTHHmmssfffZ')
    )
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null

$hdc = Resolve-Hdc
$Target = Resolve-LeanTTYRegressionTarget -Hdc $hdc -Target $Target
$candidateSha256 = [string]$candidate.sha256
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$fixtureDirectory = Join-Path $temporaryRoot (
    'leantty-agent-compat-' + [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $fixtureDirectory | Out-Null
$wslFixtureDirectory = ConvertTo-LeanTTYWslPath -WindowsPath $fixtureDirectory
$wslToolPath = ConvertTo-LeanTTYWslPath `
    -WindowsPath (Join-Path $PSScriptRoot 'agent-compatibility-wsl.sh')
$hostKeyPath = Join-Path $fixtureDirectory 'ssh_host_ed25519_key'
$authorizedKeysPath = Join-Path $fixtureDirectory 'authorized_keys'
$sshdConfigPath = Join-Path $fixtureDirectory 'sshd_config'
$sshdPidPath = Join-Path $fixtureDirectory 'sshd.pid'
$sshdStdoutPath = Join-Path $fixtureDirectory 'sshd-stdout.txt'
$sshdStderrPath = Join-Path $fixtureDirectory 'sshd-stderr.txt'
$snapshotPath = Join-Path $fixtureDirectory 'current-line'
$wslSnapshotPath = "$wslFixtureDirectory/current-line"
$shellReadyPath = Join-Path $fixtureDirectory 'shell-ready'
$wslShellReadyPath = "$wslFixtureDirectory/shell-ready"
$localeProbePath = Join-Path $fixtureDirectory 'terminal-locale'
$wslLocaleProbePath = "$wslFixtureDirectory/terminal-locale"
$mappingActive = $false
$sshdProcess = $null
$awakeLeaseAcquired = $false
$panelOpen = $false
$appProcessId = ''
$knownHostCleanupAttempted = $false
$isolatedTabCreated = $false
$cleanupFailures = [Collections.Generic.List[string]]::new()
$commandObservations = [Collections.Generic.List[object]]::new()
$connectedCommandObservations = [Collections.Generic.List[object]]::new()
$controlledLocaleChecked = $false

$result = [ordered]@{
    schemaVersion = 2
    scenario = $(if ($Osc99CapabilityProbe) {
        'osc99-capability-response-over-default-wsl-openssh'
    } elseif ($InteractionOnlyProbe) {
        'zero-model-agent-tui-interaction-over-default-wsl-openssh'
    } elseif ($ProtocolInteractionProbe) {
        'qwen-native-osc52-scrollback-with-osc8-observation-over-default-wsl-openssh'
    } else {
        'native-agent-tui-compatibility-over-default-wsl-openssh'
    })
    startedAt = $startedAt.ToString('o')
    attemptId = $attemptId
    previousAttemptId = $PreviousAttemptId
    runMode = $(if ($DiagnosticHap) { 'diagnostic' } else { 'acceptance' })
    releaseEligible = (-not $DiagnosticHap)
    target = $Target
    candidate = [ordered]@{
        hapPath = $HapPath
        sha256 = $candidateSha256
        role = $(if ($DiagnosticHap) { 'test-signed-diagnostic-hap' } else { 'retained-test-candidate' })
        gitCommit = $candidate.gitCommit
        gitTree = $candidate.gitTree
        gitDirty = $candidate.gitDirty
        verificationMode = $candidate.verificationMode
        retained = (-not $DiagnosticHap)
        reusedAcrossHarnessOnlyChanges = ($harnessDifferencePaths.Count -gt 0)
    }
    harness = [ordered]@{
        gitCommit = $harnessCommit
        gitTree = $harnessTree
        gitDirty = $harnessDirty
        differencePathsFromCandidate = @($harnessDifferencePaths)
    }
    server = [ordered]@{
        environment = 'default-wsl-isolated-openssh'
        port = $Port
        authentication = 'existing-app-ed25519-public-key-only'
        terminalLocale = 'pending'
    }
    inventory = $null
    selectedAgents = $(if ($Osc99CapabilityProbe) { @() } else { @($Agents) })
    selectedModes = $(if ($Osc99CapabilityProbe) { @() } else { @($Modes) })
    plannedModelRequests = $(if ($Osc99CapabilityProbe -or $InteractionOnlyProbe) {
        0
    } else {
        $Agents.Count * $Modes.Count
    })
    diagnosticOverrides = $(if ($OpenCodeForceOsc99Protocol) {
        @('OPENTUI_NOTIFICATION_PROTOCOL=osc99')
    } else {
        @()
    })
    checks = @()
    commandAutomation = $null
    cleanup = [ordered]@{ result = 'pending'; detail = '' }
    status = 'invalid/interrupted'
}

function Write-AgentCompatibilityProgress {
    param([Parameter(Mandatory = $true)][string]$Stage)
    Write-LeanTTYAtomicJson -Path (Join-Path $EvidenceDirectory 'progress.json') -Value ([ordered]@{
        schemaVersion = 1
        scenario = $result.scenario
        attemptId = $attemptId
        previousAttemptId = $PreviousAttemptId
        stage = $Stage
        completedCheckCount = @($result.checks).Count
        plannedCheckCount = $(if ($Osc99CapabilityProbe) { 1 } else { $Agents.Count * $Modes.Count })
        updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        contentRecorded = $false
    })
}

function Get-FullLayout {
    param([Parameter(Mandatory = $true)][string]$Name)
    return Get-LeanTTYDeviceLayout `
        -Hdc $hdc -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory "$Name.json") `
        -BundleName ''
}

function Find-OneNode {
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)][scriptblock]$Predicate,
        [Parameter(Mandatory = $true)][string]$Description
    )
    $matches = @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object $Predicate)
    if ($matches.Count -ne 1) {
        throw "[harness] Expected one $Description node, found $($matches.Count)"
    }
    return $matches[0]
}

function Click-Node {
    param(
        [Parameter(Mandatory = $true)]$Node,
        [Parameter(Mandatory = $true)][string]$Description
    )
    $center = Get-LeanTTYBoundsCenter -Bounds ([string]$Node.attributes.bounds)
    Invoke-LeanTTYDeviceClick `
        -Hdc $hdc -Target $Target -X $center.x -Y $center.y -Operation $Description
}

function Focus-TerminalInput {
    param([Parameter(Mandatory = $true)][string]$Name)
    $layout = Get-FullLayout -Name $Name
    $inputs = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
    $focusedInputs = @($inputs | Where-Object {
        [string]$_.attributes.focused -eq 'true'
    })
    $input = if ($focusedInputs.Count -eq 1) {
        $focusedInputs[0]
    } elseif ($inputs.Count -eq 1) {
        $inputs[0]
    } else {
        throw "[environment] Expected one active terminal input, found $($inputs.Count) mounted and $($focusedInputs.Count) focused"
    }
    Click-Node -Node $input -Description 'Focus Agent compatibility terminal input'
    Start-Sleep -Milliseconds 200
    return $input
}

function Invoke-AgentWorkspaceChord {
    param([Parameter(Mandatory = $true)][ValidateSet('new-tab', 'close-active')][string]$Action)
    $command = if ($Action -eq 'new-tab') {
        'uinput -K -d 2072 -d 2047 -d 2036 -u 2036 -u 2047 -u 2072'
    } else {
        'uinput -K -d 2072 -d 2047 -d 2039 -u 2039 -u 2047 -u 2072'
    }
    & $hdc -t $Target shell $command | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "[environment] Unable to invoke isolated Agent $Action" }
}

function Submit-LocalCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Stage
    )
    Submit-LeanTTYDeviceCommand `
        -Hdc $hdc -Target $Target -ProcessId $appProcessId `
        -Command $Command -Stage $Stage -ObservationSink $commandObservations `
        -InputNodeProvider {
            param($attempt)
            Focus-TerminalInput -Name "$Stage-local-command-$attempt"
        } | Out-Null
}

function Wait-AppLog {
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [ValidateRange(1, 180)][int]$TimeoutSeconds = 30
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $logs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appProcessId
        if ($logs -match $Pattern) { return $logs }
        Start-Sleep -Milliseconds 500
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw "[product] Timed out waiting for app log: $Pattern"
}

function Wait-File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateRange(1, 180)][int]$TimeoutSeconds = 30
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return }
        Start-Sleep -Milliseconds 200
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw "[harness] Timed out waiting for file: $(Split-Path $Path -Leaf)"
}

function Submit-ConnectedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Stage
    )
    if (Test-Path -LiteralPath $snapshotPath) {
        Remove-Item -LiteralPath $snapshotPath -Force
    }
    $inputNode = Focus-TerminalInput -Name "$Stage-before-input"
    Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $Command -InputNode $inputNode
    & $hdc -t $Target shell 'uinput -K -d 2072 -d 2040 -u 2040 -u 2072' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '[environment] Unable to inject Ctrl+X snapshot prefix' }
    & $hdc -t $Target shell 'uinput -K -d 2072 -d 2028 -u 2028 -u 2072' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '[environment] Unable to inject Ctrl+L snapshot suffix' }
    Wait-File -Path $snapshotPath -TimeoutSeconds 10
    $actual = [IO.File]::ReadAllText($snapshotPath)
    $mismatch = Get-LeanTTYTextMismatchIndex -Expected $Command -Actual $actual
    $observation = [pscustomobject][ordered]@{
        stage = $Stage
        expectedLength = $Command.Length
        actualLength = $actual.Length
        mismatchIndex = $mismatch
        inputAttempts = 1
        enterCount = 0
    }
    $connectedCommandObservations.Add($observation)
    Remove-Item -LiteralPath $snapshotPath -Force
    if ($mismatch -ne -1) {
        Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $Target
        throw "[harness] Connected command mismatch at index $mismatch"
    }
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
    $observation.enterCount = 1
}

function Connect-AgentServer {
    param([Parameter(Mandatory = $true)][string]$Stage)
    if (Test-Path -LiteralPath $shellReadyPath) {
        Remove-Item -LiteralPath $shellReadyPath -Force
    }
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-LocalCommand `
        -Command "ssh -p $Port -i id_ed25519 $($result.server.user)@127.0.0.1" `
        -Stage "$Stage-connect"
    try {
        Wait-AppLog -Pattern 'native control event: host_key_prompt:' -TimeoutSeconds 5 | Out-Null
        $inputNode = Focus-TerminalInput -Name "$Stage-host-key"
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text 'yes' -InputNode $inputNode
        Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
    } catch {
        # A trusted key for this run-scoped endpoint skips the prompt.
    }
    Wait-AppLog -Pattern 'SSH session connected' -TimeoutSeconds 30 | Out-Null
    Wait-File -Path $shellReadyPath -TimeoutSeconds 10
    if (-not $script:controlledLocaleChecked) {
        if (Test-Path -LiteralPath $localeProbePath) {
            Remove-Item -LiteralPath $localeProbePath -Force
        }
        Submit-ConnectedCommand `
            -Command "locale charmap > '$wslLocaleProbePath'" `
            -Stage "$Stage-locale"
        Wait-File -Path $localeProbePath -TimeoutSeconds 10
        $terminalLocale = [IO.File]::ReadAllText($localeProbePath).Trim()
        Remove-Item -LiteralPath $localeProbePath -Force
        if ($terminalLocale -ne 'UTF-8') {
            throw "[environment] Controlled SSH shell is not using a UTF-8 locale: $terminalLocale"
        }
        $result.server.terminalLocale = $terminalLocale
        $script:controlledLocaleChecked = $true
    }
}

function Disconnect-AgentServer {
    Invoke-LeanTTYDeviceCtrlD -Hdc $hdc -Target $Target
    Wait-AppLog -Pattern 'SSH closed, exitCode=' -TimeoutSeconds 20 | Out-Null
}

function Get-MinimizeButton {
    param([Parameter(Mandatory = $true)]$Layout)
    $root = Find-OneNode -Layout $Layout -Description 'LeanTTY root' -Predicate {
        [string]$_.attributes.bundleName -eq 'com.leantty.app' -and
        [string]$_.attributes.type -eq 'root'
    }
    $windowId = [string]$root.attributes.hostWindowId
    return Find-OneNode -Layout $Layout -Description 'LeanTTY minimize button' -Predicate {
        [string]$_.attributes.hostWindowId -eq $windowId -and
        [string]$_.attributes.id -eq 'EnhanceMinimizeBtn'
    }
}

function Open-NotificationPanel {
    param([Parameter(Mandatory = $true)][string]$Stage)
    $desktop = Get-FullLayout -Name "$Stage-desktop"
    $button = Find-OneNode -Layout $desktop -Description 'system notification panel button' -Predicate {
        [string]$_.attributes.id -eq 'PluginRootComponent_Stack_status_bar_notification_panel'
    }
    Click-Node -Node $button -Description 'Open HarmonyOS notification panel'
    $script:panelOpen = $true
    Start-Sleep -Milliseconds 700
    return Get-FullLayout -Name "$Stage-notification-panel"
}

function Assert-NotificationAndReturn {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$CaptureResultPath
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $published = $false
    $agentSignalObservedAt = $null
    $captureName = [IO.Path]::GetFileNameWithoutExtension($CaptureResultPath)
    $liveProbePath = Join-Path (Split-Path $CaptureResultPath -Parent) "$captureName-live.json"
    do {
        $logs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appProcessId
        if ($logs -match 'Background BEL notification published: paneId=pane-\d+') {
            $published = $true
            break
        }
        & wsl.exe --exec bash $wslToolPath probe $wslFixtureDirectory $captureName 2>$null
        if (Test-Path -LiteralPath $liveProbePath -PathType Leaf) {
            $liveProbe = Get-Content -LiteralPath $liveProbePath -Raw |
                ConvertFrom-Json -Depth 30
            if ($liveProbe.output.nativeAttentionSignalObserved -and
                $null -eq $agentSignalObservedAt) {
                $agentSignalObservedAt = [DateTimeOffset]::UtcNow
            }
            if ($null -ne $agentSignalObservedAt -and
                ([DateTimeOffset]::UtcNow - $agentSignalObservedAt).TotalSeconds -ge 10) {
                throw '[product] Agent emitted native attention but LeanTTY did not publish it'
            }
        }
        if (Test-Path -LiteralPath $CaptureResultPath -PathType Leaf) {
            $earlyCapture = Get-Content -LiteralPath $CaptureResultPath -Raw |
                ConvertFrom-Json -Depth 30
            if ($earlyCapture.output.nativeAttentionSignalObserved) {
                throw '[product] Agent emitted native attention but LeanTTY did not publish it'
            }
            throw (
                '[external-agent] Agent exited without native attention, childExitCode=' +
                [string]$earlyCapture.childExitCode
            )
        }
        Start-Sleep -Milliseconds 500
    } while ($watch.Elapsed.TotalSeconds -lt 180)
    if (-not $published) {
        throw '[external-agent] Timed out without an Agent native attention signal'
    }
    $panel = Open-NotificationPanel -Stage $Stage
    $cards = @(Get-LeanTTYLayoutNodes -Node $panel | Where-Object {
        [string]$_.attributes.text -match '^LeanTTY, .*(?:A terminal needs your attention\.|终端有新提示)$'
    })
    if ($cards.Count -ne 1) {
        throw "[product] Expected one generic Agent notification, found $($cards.Count)"
    }
    if ([string]$cards[0].attributes.text -match '\b(?:agent|codex|opencode|pi|qwen|host|ssh|tmux)\b|@') {
        throw '[privacy] Agent notification exposed source or workload information'
    }
    Click-Node -Node $cards[0] -Description 'Return to native Agent notification source'
    $script:panelOpen = $false
    Wait-AppLog -Pattern 'Background BEL return applied: paneId=pane-\d+' -TimeoutSeconds 20 |
        Out-Null
}

function Wait-AgentTuiReady {
    param(
        [Parameter(Mandatory = $true)][string]$CaptureResultPath,
        [ValidateRange(1, 30)][int]$TimeoutSeconds = 15
    )
    $captureName = [IO.Path]::GetFileNameWithoutExtension($CaptureResultPath)
    $liveProbePath = Join-Path (Split-Path $CaptureResultPath -Parent) "$captureName-live.json"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        & wsl.exe --exec bash $wslToolPath probe $wslFixtureDirectory $captureName 2>$null
        if (Test-Path -LiteralPath $liveProbePath -PathType Leaf) {
            $liveProbe = Get-Content -LiteralPath $liveProbePath -Raw |
                ConvertFrom-Json -Depth 30
            if ($liveProbe.output.alternateScreen.enterCount -gt 0) { return }
        }
        if (Test-Path -LiteralPath $CaptureResultPath -PathType Leaf) {
            throw '[external-agent] Agent exited before the interactive TUI became ready'
        }
        Start-Sleep -Milliseconds 200
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw '[harness] Timed out waiting for the interactive Agent TUI'
}

function Wait-AgentInteractionReady {
    param(
        [Parameter(Mandatory = $true)][string]$CaptureResultPath,
        [ValidateRange(1, 30)][int]$TimeoutSeconds = 20
    )
    $captureName = [IO.Path]::GetFileNameWithoutExtension($CaptureResultPath)
    $liveProbePath = Join-Path (Split-Path $CaptureResultPath -Parent) "$captureName-live.json"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        & wsl.exe --exec bash $wslToolPath probe $wslFixtureDirectory $captureName 2>$null
        if (Test-Path -LiteralPath $liveProbePath -PathType Leaf) {
            $liveProbe = Get-Content -LiteralPath $liveProbePath -Raw |
                ConvertFrom-Json -Depth 30
            if ($liveProbe.output.bytes -gt 256 -and (
                $liveProbe.output.bracketedPaste.enableCount -gt 0 -or
                $liveProbe.output.alternateScreen.enterCount -gt 0 -or
                $liveProbe.output.osc8HyperlinkCount -gt 0
            )) {
                return
            }
        }
        if (Test-Path -LiteralPath $CaptureResultPath -PathType Leaf) {
            throw '[external-agent] Agent exited before the zero-model interaction probe became ready'
        }
        Start-Sleep -Milliseconds 200
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw '[harness] Timed out waiting for the zero-model Agent interaction probe'
}

function Get-AgentTermiosSample {
    param(
        [Parameter(Mandatory = $true)][string]$CaptureName,
        [Parameter(Mandatory = $true)][ValidateSet('before-resize', 'after-resize')]
        [string]$SampleName
    )
    & wsl.exe --exec bash $wslToolPath termios-probe `
        $wslFixtureDirectory $CaptureName $SampleName
    if ($LASTEXITCODE -ne 0) {
        throw "[harness] Unable to sample controlled Agent PTY termios: $SampleName"
    }
    $samplePath = Join-Path $fixtureDirectory (
        "results\$CaptureName-$SampleName-termios.json"
    )
    return Get-Content -LiteralPath $samplePath -Raw | ConvertFrom-Json -Depth 10
}

function Get-AgentExpectedAttentionKind {
    param([Parameter(Mandatory = $true)][string]$Agent)
    switch ($Agent) {
        'opencode' { return 'osc-99' }
        'pi' { return 'osc-777' }
        'qwen' { return 'bel' }
        'codex' { return 'bel' }
        default { return '' }
    }
}

function Get-WindowSizeToggleButton {
    param([Parameter(Mandatory = $true)]$Layout)
    return Find-OneNode -Layout $Layout -Description 'HarmonyOS maximize or restore button' -Predicate {
        [string]$_.attributes.id -match '^Enhance(?:Maximize|Recover)Btn$' -and
        [string]$_.attributes.clickable -eq 'true'
    }
}

function Resume-AgentAfterAttention {
    param([Parameter(Mandatory = $true)][string]$Agent)
    if ($Agent -ne 'qwen') { return }
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
    Start-Sleep -Milliseconds 700
}

function Reset-AppAfterAgentFailure {
    & $hdc -t $Target shell 'aa force-stop com.leantty.app' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '[environment] LeanTTY force-stop failed during recovery' }
    Start-Sleep -Milliseconds 500
    & $hdc -t $Target shell 'aa start -a EntryAbility -b com.leantty.app' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '[environment] LeanTTY restart failed during recovery' }
    Start-Sleep -Milliseconds 700
    $script:appProcessId = (@(& $hdc -t $Target shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
    if ($script:appProcessId -notmatch '^\d+$') {
        throw '[environment] LeanTTY PID is unavailable after failure recovery'
    }
    Wait-LeanTTYTerminalInputLayout `
        -Hdc $hdc -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory 'failure-recovery-layout.json') `
        -TimeoutSeconds 20 | Out-Null
}

function Save-CurrentAppLogs {
    param([Parameter(Mandatory = $true)][string]$Name)
    try {
        $logs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appProcessId
        [IO.File]::WriteAllText(
            (Join-Path $EvidenceDirectory "$Name-app.log"),
            $logs,
            [Text.UTF8Encoding]::new($false)
        )
    } catch {}
}

function Restore-AgentAppForContinuation {
    & $hdc -t $Target shell 'aa start -a EntryAbility -b com.leantty.app' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '[environment] Unable to restore LeanTTY after notification failure' }
    Start-Sleep -Milliseconds 700
    Wait-LeanTTYTerminalInputLayout `
        -Hdc $hdc -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory 'notification-failure-restored-layout.json') `
        -TimeoutSeconds 20 | Out-Null
}

function Invoke-AgentInputProbes {
    param([Parameter(Mandatory = $true)][string]$Stage)
    $inputNode = Focus-TerminalInput -Name "$Stage-unicode-input"
    Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text 'English中文' -InputNode $inputNode
    Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $Target
    $inputNode = Focus-TerminalInput -Name "$Stage-large-input"
    Invoke-LeanTTYDeviceText `
        -Hdc $hdc -Target $Target -Text ('P' * 4096) -InputNode $inputNode
    Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $Target
    $inputNode = Focus-TerminalInput -Name "$Stage-shift-enter-prefix"
    Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text 'line-one' -InputNode $inputNode
    & $hdc -t $Target shell 'uinput -K -d 2047 -d 2054 -u 2054 -u 2047' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '[environment] Unable to inject physical Shift+Enter' }
    $inputNode = Focus-TerminalInput -Name "$Stage-shift-enter-suffix"
    Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text 'line-two' -InputNode $inputNode
    Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $Target
}

function Invoke-AgentPhysicalImeProbe {
    param([Parameter(Mandatory = $true)][string]$Stage)
    Focus-TerminalInput -Name "$Stage-physical-ime" | Out-Null
    $imeToggled = $false
    try {
        & $hdc -t $Target shell (
            'uinput -K ' +
            '-d 2028 -u 2028 -d 2021 -u 2021 -d 2017 -u 2017 ' +
            '-d 2030 -u 2030 -d 2036 -u 2036 -d 2036 -u 2036 ' +
            '-d 2041 -u 2041 -d 2025 -u 2025 -d 2029 -u 2029 -d 2021 -u 2021'
        ) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw '[environment] Physical English input failed' }
        Start-Sleep -Milliseconds 300
        Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $Target

        & $hdc -t $Target shell 'uinput -K -d 2047 -u 2047' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw '[environment] Unable to switch the HarmonyOS input method' }
        $imeToggled = $true
        Start-Sleep -Milliseconds 400
        & $hdc -t $Target shell (
            'uinput -K ' +
            '-d 2042 -u 2042 -d 2024 -u 2024 -d 2031 -u 2031 ' +
            '-d 2030 -u 2030 -d 2023 -u 2023 -d 2039 -u 2039 ' +
            '-d 2021 -u 2021 -d 2030 -u 2030 -d 2050 -u 2050'
        ) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw '[environment] Physical pinyin input failed' }
        Start-Sleep -Milliseconds 700
        Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $Target
    } finally {
        if ($imeToggled) {
            & $hdc -t $Target shell 'uinput -K -d 2047 -u 2047' 2>$null | Out-Null
        }
    }
}

function Assert-AgentSearch {
    param([Parameter(Mandatory = $true)][string]$Stage)
    & $hdc -t $Target shell 'uitest uiInput keyEvent 2072 2045 2022' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '[environment] Unable to invoke Ctrl+Alt+F terminal search' }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $layout = Get-FullLayout -Name "$Stage-search"
        $inputs = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
            [string]$_.attributes.type -eq 'textField' -and
            [string]$_.attributes.hint -match '^(?:Find text|Search text|查找内容)' -and
            [string]$_.attributes.visible -eq 'true'
        })
        if ($inputs.Count -eq 1) { break }
        Start-Sleep -Milliseconds 200
    } while ($watch.Elapsed.TotalSeconds -lt 15)
    if ($inputs.Count -ne 1) { throw '[product] Terminal search did not open over Agent output' }
    Invoke-LeanTTYDeviceText `
        -Hdc $hdc -Target $Target -Text 'LEANTTY_AGENT_DONE' -InputNode $inputs[0]
    $matched = $false
    $watch.Restart()
    do {
        $layout = Get-FullLayout -Name "$Stage-search-result"
        $labels = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
            [string]$_.attributes.text -match '^[1-9][0-9]*/[1-9][0-9]*$'
        })
        if ($labels.Count -eq 1) { $matched = $true; break }
        Start-Sleep -Milliseconds 200
    } while ($watch.Elapsed.TotalSeconds -lt 15)
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2070
    if (-not $matched) { throw '[product] LeanTTY search did not find controlled Agent output' }
}

function Stop-AgentTui {
    param([Parameter(Mandatory = $true)][string]$Agent)
    if ($Agent -eq 'codex') {
        $inputNode = Focus-TerminalInput -Name 'codex-exit'
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text '/exit' -InputNode $inputNode
        Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
        return
    }
    Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $Target
    Start-Sleep -Milliseconds 250
    Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $Target
    Start-Sleep -Milliseconds 250
    Invoke-LeanTTYDeviceCtrlD -Hdc $hdc -Target $Target
}

function Invoke-AgentModeCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Agent,
        [Parameter(Mandatory = $true)][string]$Mode
    )
    $stage = "$Agent-$Mode"
    $captureResultPath = Join-Path $fixtureDirectory "results\$stage-notification.json"
    $check = [ordered]@{
        agent = $Agent
        mode = $Mode
        status = 'failed'
        authentication = 'ready'
        expectedAttention = Get-AgentExpectedAttentionKind -Agent $Agent
        plannedModelRequests = 1
        tokenUsage = 'unavailable'
        nativeNotification = $false
        genericNotificationPayload = $false
        returnApplied = $false
        notificationAssessment = $null
        unicodeInput = 'harmony-uitest-semantic-unicode-not-physical-ime-composition'
        largeInputCharacters = 4096
        shiftEnter = 'physical-key-injected-captured-at-pty'
        search = $false
        reconnect = $false
        tmuxResume = $(if ($Mode -eq 'tmux') { $false } else { $null })
        captureSummary = $null
        failure = ''
        failureDomain = 'none'
        recovery = 'not-required'
    }
    $deferredFailure = ''
    try {
        Connect-AgentServer -Stage $stage
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Submit-ConnectedCommand `
            -Command "lat $Agent $Mode notification" `
            -Stage "$stage-launch"
        if ($Agent -eq 'opencode') {
            Wait-AgentTuiReady -CaptureResultPath $captureResultPath
            $inputNode = Focus-TerminalInput -Name "$stage-interactive-prompt"
            $prompt = 'Use the bash tool exactly once to run: sleep 12. Do not use any other tool. After it completes, reply exactly LEANTTY_AGENT_DONE.'
            Invoke-LeanTTYDeviceText `
                -Hdc $hdc -Target $Target -Text $prompt -InputNode $inputNode
            Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
        }
        Start-Sleep -Milliseconds 700
        $layout = Get-FullLayout -Name "$stage-before-minimize"
        $minimize = Get-MinimizeButton -Layout $layout
        Click-Node -Node $minimize -Description "Minimize LeanTTY for $stage native notification"
        try {
            Assert-NotificationAndReturn -Stage $stage -CaptureResultPath $captureResultPath
            $check.nativeNotification = $true
            $check.genericNotificationPayload = $true
            $check.returnApplied = $true
        } catch {
            $deferredFailure = $_.Exception.Message
            Save-CurrentAppLogs -Name "$stage-notification-failure"
            Restore-AgentAppForContinuation
        }
        Resume-AgentAfterAttention -Agent $Agent
        Assert-AgentSearch -Stage $stage
        $check.search = $true
        Invoke-AgentInputProbes -Stage $stage

        if ($Mode -eq 'tmux') {
            & $hdc -t $Target shell 'uinput -K -d 2072 -d 2018 -u 2018 -u 2072' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw '[environment] Unable to inject tmux prefix Ctrl+B' }
            Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2020
            Start-Sleep -Milliseconds 500
            Disconnect-AgentServer
            Connect-AgentServer -Stage "$stage-reconnect"
            Submit-ConnectedCommand `
                -Command "lat $Agent $Mode notification" `
                -Stage "$stage-reattach"
            Start-Sleep -Milliseconds 700
            Focus-TerminalInput -Name "$stage-reattached" | Out-Null
            $check.tmuxResume = $true
        }

        Stop-AgentTui -Agent $Agent
        Wait-File -Path $captureResultPath -TimeoutSeconds 30
        $capture = Get-Content -LiteralPath $captureResultPath -Raw | ConvertFrom-Json -Depth 30
        $expectedAttention = Get-AgentExpectedAttentionKind -Agent $Agent
        $nativeAttentionObserved = [bool]$capture.output.nativeAttentionSignalObserved
        if ($nativeAttentionObserved -and $expectedAttention.Length -gt 0 -and
            $capture.output.nativeAttentionSignalKinds -notcontains $expectedAttention) {
            throw "[compatibility] Agent PTY capture did not contain expected $expectedAttention"
        }
        if (-not $capture.input.containsCjkUtf8 -or $capture.input.bytes -lt 4100) {
            throw '[compatibility] Controlled Unicode or large input did not reach the Agent PTY'
        }
        $check.captureSummary = "results/$stage-notification.json"
        $notificationAssessment = Resolve-LeanTTYAgentNotificationAssessment `
            -Agent $Agent `
            -Mode $Mode `
            -NativeAttentionObserved $nativeAttentionObserved `
            -SystemNotificationCompleted ([bool]$check.nativeNotification) `
            -AgentChildExitCode ([int]$capture.childExitCode) `
            -NotificationFailure $deferredFailure
        $check.notificationAssessment = $notificationAssessment
        Disconnect-AgentServer
        Connect-AgentServer -Stage "$stage-final-reconnect"
        $check.reconnect = $true
        Disconnect-AgentServer
        if ($notificationAssessment.status -ne 'passed') {
            throw $notificationAssessment.failure
        }
        $check.status = 'passed'
    } catch {
        Save-CurrentAppLogs -Name "$stage-final-failure"
        $check.failure = $_.Exception.Message
        $check.failureDomain = if ($check.failure -match '^\[product\]') {
            'product'
        } elseif ($check.failure -match '^\[harness\]') {
            'harness'
        } elseif ($check.failure -match '^\[environment\]') {
            'environment'
        } elseif ($check.failure -match '^\[infrastructure\]') {
            'infrastructure'
        } elseif ($check.failure -match '^\[external-agent\]') {
            'external-agent'
        } elseif ($check.failure -match '^\[compatibility\]') {
            'compatibility'
        } elseif ($check.failure -match '^\[privacy\]') {
            'privacy'
        } else {
            'unknown'
        }
        try {
            Reset-AppAfterAgentFailure
            $check.recovery = 'application-restarted-to-local-command-state'
            if (Test-Path -LiteralPath $captureResultPath -PathType Leaf) {
                $check.captureSummary = "results/$stage-notification.json"
            }
        } catch {
            $check.recovery = 'failed: ' + $_.Exception.Message
        }
    }
    return [pscustomobject]$check
}

function Invoke-AgentInteractionOnlyCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Agent,
        [Parameter(Mandatory = $true)][string]$Mode
    )
    $stage = "$Agent-$Mode-interaction"
    $captureName = "$Agent-$Mode-interaction"
    $captureResultPath = Join-Path $fixtureDirectory "results\$captureName.json"
    $windowToggled = $false
    $agentStarted = $false
    $check = [ordered]@{
        agent = $Agent
        mode = $Mode
        status = 'failed'
        authentication = 'ready'
        plannedModelRequests = 0
        tokenUsage = 'zero-model-interaction-probe'
        rawMode = $false
        inputMethod = 'physical-harmony-ime-composition'
        englishPhysicalInput = $false
        cjkComposition = $false
        terminalSizeBefore = $null
        terminalSizeAfter = $null
        resize = $false
        alternateScreen = $null
        captureSummary = $null
        failure = ''
        failureDomain = 'none'
        recovery = 'not-required'
    }
    try {
        Connect-AgentServer -Stage $stage
        Submit-ConnectedCommand -Command "lat $Agent $Mode interaction" -Stage "$stage-launch"
        $agentStarted = $true
        Wait-AgentInteractionReady -CaptureResultPath $captureResultPath
        $before = Get-AgentTermiosSample -CaptureName $captureName -SampleName 'before-resize'
        $check.rawMode = [bool]$before.rawMode
        $check.terminalSizeBefore = [ordered]@{
            rows = [int]$before.rows
            columns = [int]$before.columns
        }
        if (-not $check.rawMode) {
            throw '[compatibility] Agent TUI did not place its controlled PTY in raw mode'
        }
        Invoke-AgentPhysicalImeProbe -Stage $stage

        $beforeLayout = Get-FullLayout -Name "$stage-before-resize"
        $toggle = Get-WindowSizeToggleButton -Layout $beforeLayout
        Click-Node -Node $toggle -Description "Toggle HarmonyOS window size for $stage"
        $windowToggled = $true
        Start-Sleep -Milliseconds 1200
        $after = Get-AgentTermiosSample -CaptureName $captureName -SampleName 'after-resize'
        $check.terminalSizeAfter = [ordered]@{
            rows = [int]$after.rows
            columns = [int]$after.columns
        }
        $check.resize = (
            [int]$before.rows -ne [int]$after.rows -or
            [int]$before.columns -ne [int]$after.columns
        )
        if (-not $check.resize) {
            throw '[product] Agent PTY dimensions did not change after the real HarmonyOS window resize'
        }

        $afterLayout = Get-FullLayout -Name "$stage-after-resize"
        $restore = Get-WindowSizeToggleButton -Layout $afterLayout
        Click-Node -Node $restore -Description "Restore HarmonyOS window size after $stage"
        $windowToggled = $false
        Start-Sleep -Milliseconds 700
        Stop-AgentTui -Agent $Agent
        $agentStarted = $false
        Wait-File -Path $captureResultPath -TimeoutSeconds 30
        $capture = Get-Content -LiteralPath $captureResultPath -Raw | ConvertFrom-Json -Depth 30
        $check.englishPhysicalInput = [bool]$capture.input.containsControlledEnglishMarker
        $check.cjkComposition = [bool]$capture.input.containsCjkUtf8
        if (-not $check.englishPhysicalInput) {
            throw '[compatibility] Physical English input did not reach the Agent PTY'
        }
        if (-not $check.cjkComposition) {
            throw '[compatibility] Physical HarmonyOS IME composition did not reach the Agent PTY'
        }
        $check.alternateScreen = [ordered]@{
            enterCount = [int]$capture.output.alternateScreen.enterCount
            exitCount = [int]$capture.output.alternateScreen.exitCount
            behavior = $(if ($capture.output.alternateScreen.enterCount -gt 0) {
                'entered-and-returned'
            } else {
                'not-requested-by-agent'
            })
        }
        if ($capture.output.alternateScreen.enterCount -gt 0 -and
            $capture.output.alternateScreen.exitCount -lt 1) {
            throw '[compatibility] Agent entered alternate screen but did not restore the normal screen on exit'
        }
        $check.captureSummary = "results/$captureName.json"
        Disconnect-AgentServer
        $check.status = 'passed'
    } catch {
        $check.failure = $_.Exception.Message
        $check.failureDomain = if ($check.failure -match '^\[product\]') {
            'product'
        } elseif ($check.failure -match '^\[harness\]') {
            'harness'
        } elseif ($check.failure -match '^\[environment\]') {
            'environment'
        } elseif ($check.failure -match '^\[infrastructure\]') {
            'infrastructure'
        } elseif ($check.failure -match '^\[external-agent\]') {
            'external-agent'
        } elseif ($check.failure -match '^\[compatibility\]') {
            'compatibility'
        } else {
            'unknown'
        }
        try {
            if ($windowToggled) {
                $layout = Get-FullLayout -Name "$stage-failure-window-restore"
                $restore = Get-WindowSizeToggleButton -Layout $layout
                Click-Node -Node $restore -Description "Restore HarmonyOS window after failed $stage"
                $windowToggled = $false
            }
            if ($agentStarted) { Stop-AgentTui -Agent $Agent }
            Disconnect-AgentServer
            $check.recovery = 'window-restored; agent-stopped; SSH disconnected'
        } catch {
            $check.recovery = 'failed: ' + $_.Exception.Message
        }
    }
    return [pscustomobject]$check
}

function Wait-AgentOsc52ClipboardCapture {
    param(
        [Parameter(Mandatory = $true)][string]$CaptureResultPath,
        [ValidateRange(1, 90)][int]$TimeoutSeconds = 60
    )
    $captureName = [IO.Path]::GetFileNameWithoutExtension($CaptureResultPath)
    $liveProbePath = Join-Path (Split-Path $CaptureResultPath -Parent) "$captureName-live.json"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        & wsl.exe --exec bash $wslToolPath probe $wslFixtureDirectory $captureName 2>$null
        if (Test-Path -LiteralPath $liveProbePath -PathType Leaf) {
            $liveProbe = Get-Content -LiteralPath $liveProbePath -Raw |
                ConvertFrom-Json -Depth 30
            if ($liveProbe.output.osc52ClipboardCount -gt 0) {
                return $liveProbe
            }
        }
        if (Test-Path -LiteralPath $CaptureResultPath -PathType Leaf) {
            throw '[external-agent] Agent exited before its native OSC 52 copy action was observed'
        }
        Start-Sleep -Milliseconds 250
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw "[compatibility] Timed out waiting for the Agent's native OSC 52 copy action"
}

function Invoke-AgentProtocolInteractionCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Agent,
        [Parameter(Mandatory = $true)][string]$Mode
    )
    $stage = "$Agent-$Mode-protocol"
    $captureResultPath = Join-Path $fixtureDirectory "results\$stage.json"
    $agentStarted = $false
    $check = [ordered]@{
        agent = $Agent
        mode = $Mode
        status = 'failed'
        authentication = 'ready'
        plannedModelRequests = 1
        tokenUsage = 'unavailable'
        osc8HyperlinkRendered = $false
        osc8HyperlinkCount = 0
        osc8Observation = 'pending'
        osc52ClipboardActivated = $false
        osc52ClipboardCount = 0
        copyAttempts = 0
        scrollback = $false
        scrollbackEvidence = $null
        captureSummary = $null
        failure = ''
        failureDomain = 'none'
        recovery = 'not-required'
    }
    try {
        Connect-AgentServer -Stage $stage
        Submit-ConnectedCommand -Command "lat $Agent $Mode protocol" -Stage "$stage-launch"
        $agentStarted = $true
        Wait-AgentTuiReady -CaptureResultPath $captureResultPath -TimeoutSeconds 20
        # The prompt is deliberately tiny. This delay is only a scheduling guard
        # before the local /copy action; OSC 52 remains the actual completion oracle.
        Start-Sleep -Seconds 20

        $osc52 = $null
        foreach ($attempt in 1..3) {
            $check.copyAttempts = $attempt
            Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
            $inputNode = Focus-TerminalInput -Name "$stage-copy-$attempt"
            Invoke-LeanTTYDeviceText `
                -Hdc $hdc -Target $Target -Text '/copy' -InputNode $inputNode
            Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
            try {
                Wait-AppLog -Pattern 'OSC 52 clipboard write success=true,length=[1-9][0-9]*' `
                    -TimeoutSeconds 10 | Out-Null
                $osc52 = Wait-AgentOsc52ClipboardCapture `
                    -CaptureResultPath $captureResultPath -TimeoutSeconds 10
                break
            } catch {
                if ($attempt -eq 3) { throw }
            }
        }
        if ($null -eq $osc52) {
            throw '[compatibility] Qwen native /copy did not activate OSC 52'
        }
        $check.osc52ClipboardActivated = $true
        $check.osc52ClipboardCount = [int]$osc52.output.osc52ClipboardCount
        $check.osc8HyperlinkCount = [int]$osc52.output.osc8HyperlinkCount
        $check.osc8HyperlinkRendered = $check.osc8HyperlinkCount -gt 0
        $check.osc8Observation = if ($check.osc8HyperlinkRendered) {
            'native-markdown-link-rendered'
        } else {
            'not-emitted-by-qwen-under-controlled-markdown-prompt'
        }
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory "$stage-protocol-response.png")

        $inputNode = Focus-TerminalInput -Name "$stage-scrollback-fill"
        Invoke-LeanTTYDeviceText `
            -Hdc $hdc -Target $Target -Text '!seq 1 120' -InputNode $inputNode
        Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
        Start-Sleep -Milliseconds 1500
        $bottomPath = Join-Path $EvidenceDirectory "$stage-scrollback-bottom.png"
        $pageUpPath = Join-Path $EvidenceDirectory "$stage-scrollback-page-up.png"
        $restoredPath = Join-Path $EvidenceDirectory "$stage-scrollback-restored.png"
        Save-LeanTTYDeviceScreenshot -Hdc $hdc -Target $Target -LocalPath $bottomPath
        Focus-TerminalInput -Name "$stage-scrollback-page-up" | Out-Null
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2068
        Start-Sleep -Milliseconds 700
        Save-LeanTTYDeviceScreenshot -Hdc $hdc -Target $Target -LocalPath $pageUpPath
        Focus-TerminalInput -Name "$stage-scrollback-ctrl-end" | Out-Null
        & $hdc -t $Target shell `
            'uinput -K -d 2072 -d 2082 -u 2082 -u 2072' | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw '[environment] Unable to inject Qwen Ctrl+End scrollback shortcut'
        }
        Start-Sleep -Milliseconds 700
        Save-LeanTTYDeviceScreenshot -Hdc $hdc -Target $Target -LocalPath $restoredPath
        $bottomHash = (Get-FileHash -LiteralPath $bottomPath -Algorithm SHA256).Hash
        $pageUpHash = (Get-FileHash -LiteralPath $pageUpPath -Algorithm SHA256).Hash
        if ($bottomHash -eq $pageUpHash) {
            throw '[compatibility] Qwen PageUp did not visibly change its controlled history viewport'
        }
        $check.scrollback = $true
        $check.scrollbackEvidence = [ordered]@{
            interaction = 'PageUp then Ctrl+End in Qwen virtualized history'
            bottom = [IO.Path]::GetFileName($bottomPath)
            pageUp = [IO.Path]::GetFileName($pageUpPath)
            restored = [IO.Path]::GetFileName($restoredPath)
            pageUpVisiblyChanged = $true
            ctrlEndRestoration = 'recorded-for-visual-review'
        }

        Stop-AgentTui -Agent $Agent
        $agentStarted = $false
        Wait-File -Path $captureResultPath -TimeoutSeconds 30
        $capture = Get-Content -LiteralPath $captureResultPath -Raw | ConvertFrom-Json -Depth 30
        if ($capture.output.osc52ClipboardCount -lt 1) {
            throw '[compatibility] Final Agent capture lost the native OSC 52 action'
        }
        $check.captureSummary = "results/$stage.json"
        Disconnect-AgentServer
        $check.status = 'passed'
    } catch {
        $check.failure = $_.Exception.Message
        $check.failureDomain = if ($check.failure -match '^\[product\]') {
            'product'
        } elseif ($check.failure -match '^\[harness\]') {
            'harness'
        } elseif ($check.failure -match '^\[environment\]') {
            'environment'
        } elseif ($check.failure -match '^\[infrastructure\]') {
            'infrastructure'
        } elseif ($check.failure -match '^\[external-agent\]') {
            'external-agent'
        } elseif ($check.failure -match '^\[compatibility\]') {
            'compatibility'
        } else {
            'unknown'
        }
        try {
            if ($agentStarted) { Stop-AgentTui -Agent $Agent }
            Disconnect-AgentServer
            $check.recovery = 'agent-stopped; SSH disconnected'
        } catch {
            $check.recovery = 'failed: ' + $_.Exception.Message
        }
    }
    return [pscustomobject]$check
}

function Invoke-Osc99CapabilityProbeCheck {
    $stage = 'osc99-capability-probe'
    $probeResultPath = Join-Path $fixtureDirectory 'results\osc99-capability-probe.json'
    $check = [ordered]@{
        check = 'osc99-capability-response'
        status = 'failed'
        plannedModelRequests = 0
        responseObserved = $false
        responseCount = 0
        receivedBytes = 0
        evidence = $null
        failure = ''
        failureDomain = 'none'
        recovery = 'not-required'
    }
    $connected = $false
    try {
        Connect-AgentServer -Stage $stage
        $connected = $true
        Submit-ConnectedCommand -Command 'lat_osc99_probe' -Stage $stage
        Wait-File -Path $probeResultPath -TimeoutSeconds 10
        $probe = Get-Content -LiteralPath $probeResultPath -Raw |
            ConvertFrom-Json -Depth 10
        $check.responseObserved = [bool]$probe.responseObserved
        $check.responseCount = [int]$probe.responseCount
        $check.receivedBytes = [int]$probe.receivedBytes
        $check.evidence = 'results/osc99-capability-probe.json'
        if (-not $check.responseObserved -or $check.responseCount -ne 1) {
            throw '[product] OSC 99 capability response did not return to the remote PTY exactly once'
        }
        $check.status = 'passed'
    } catch {
        $check.failure = $_.Exception.Message
        $check.failureDomain = if ($check.failure -match '^\[product\]') {
            'product'
        } elseif ($check.failure -match '^\[harness\]') {
            'harness'
        } elseif ($check.failure -match '^\[environment\]') {
            'environment'
        } elseif ($check.failure -match '^\[infrastructure\]') {
            'infrastructure'
        } else {
            'unknown'
        }
    } finally {
        if ($connected) {
            try {
                Disconnect-AgentServer
                if ($check.status -eq 'failed') {
                    $check.recovery = 'ssh-session-closed'
                }
            } catch {
                $check.recovery = 'failed: ' + $_.Exception.Message
            }
        }
    }
    return [pscustomobject]$check
}

try {
    & (Join-Path $PSScriptRoot 'preflight-device.ps1') `
        -Target $Target `
        -EvidencePath (Join-Path $EvidenceDirectory 'device-preflight.json')
    if ($LASTEXITCODE -ne 0) { throw '[infrastructure] Device preflight failed' }
    Start-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $Target -TimeoutMilliseconds 3600000
    $awakeLeaseAcquired = $true

    & (Join-Path $PSScriptRoot 'dev-pc.ps1') -Target $Target -HapPath $HapPath -SkipBuild
    if ($LASTEXITCODE -ne 0) { throw '[infrastructure] Exact diagnostic HAP deployment failed' }
    $appProcessId = (@(& $hdc -t $Target shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
    if ($appProcessId -notmatch '^\d+$') { throw '[environment] LeanTTY process is not running' }
    Invoke-AgentWorkspaceChord -Action 'new-tab'
    $isolatedTabCreated = $true
    Start-Sleep -Milliseconds 500
    Wait-LeanTTYTerminalInputLayout `
        -Hdc $hdc -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory 'isolated-test-tab.json') `
        -TimeoutSeconds 20 | Out-Null

    $publicKeyOutput = @(
        & $hdc -t $Target shell -b com.leantty.app `
            'cat /data/app/el2/100/base/com.leantty.app/haps/entry/files/.ssh/id_ed25519.pub' 2>&1
    ) -join "`n"
    $publicKey = $publicKeyOutput.Trim()
    if ($publicKey -notmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,3}(?: .*)?$') {
        throw '[environment] Diagnostic app public key is missing or malformed'
    }
    [IO.File]::WriteAllText(
        $authorizedKeysPath,
        $publicKey + "`n",
        [Text.UTF8Encoding]::new($false)
    )

    & wsl.exe --exec bash $wslToolPath prepare $wslFixtureDirectory
    if ($LASTEXITCODE -ne 0) { throw '[environment] Unable to prepare WSL Agent fixture' }
    if (-not $Osc99CapabilityProbe) {
        & wsl.exe --exec bash $wslToolPath configure $wslFixtureDirectory
        if ($LASTEXITCODE -ne 0) { throw '[environment] Unable to configure WSL Agent fixture' }
        & wsl.exe --exec bash $wslToolPath environment $wslFixtureDirectory
        if ($LASTEXITCODE -ne 0) { throw '[environment] Unable to capture run-scoped WSL Agent network environment' }
        & wsl.exe --exec bash $wslToolPath inventory $wslFixtureDirectory
        if ($LASTEXITCODE -ne 0) { throw '[environment] Unable to inventory WSL Agents' }
        $inventoryPath = Join-Path $fixtureDirectory 'results\inventory.json'
        $inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json -Depth 30
        if ($InteractionOnlyProbe) {
            $inventory.usageAccounting.plannedModelRequestsPerAgentMode = 0
            $inventory.usageAccounting.tokenUsage = 'zero-model-interaction-probe'
            [IO.File]::WriteAllText(
                (Join-Path $EvidenceDirectory 'inventory.json'),
                ($inventory | ConvertTo-Json -Depth 30) + "`n",
                [Text.UTF8Encoding]::new($false)
            )
        } else {
            Copy-Item -LiteralPath $inventoryPath `
                -Destination (Join-Path $EvidenceDirectory 'inventory.json')
        }
        $result.inventory = $inventory
        $networkEnvironmentPath = Join-Path $fixtureDirectory 'results\network-environment.json'
        $result.server.networkEnvironment = Get-Content -LiteralPath $networkEnvironmentPath -Raw |
            ConvertFrom-Json -Depth 10
    }
    $wslUser = (@(& wsl.exe --exec id -un 2>&1) -join "`n").Trim()
    if ($wslUser -notmatch '^[a-z_][a-z0-9_-]*$') {
        throw '[environment] Default WSL user name is unsupported by the isolated fixture'
    }
    $result.server.user = $wslUser

    $bashRcPath = Join-Path $fixtureDirectory 'bashrc'
    $controlledShellPath = Join-Path $fixtureDirectory 'controlled-shell.sh'
    $bashRc = @(
        "PS1='leantty-agent-test$ '"
        'set +o history'
        "printf 'ready\n' > '$wslShellReadyPath'"
        $(if ($OpenCodeForceOsc99Protocol) {
            'export LEANTTY_OPENCODE_FORCE_OSC99_PROTOCOL=1'
        } else {
            '# no OpenCode notification protocol override'
        })
        "lat() { '$wslToolPath' launch '$wslFixtureDirectory' `"`$@`"; }"
        "lat_osc99_probe() { '$wslToolPath' osc99-probe '$wslFixtureDirectory'; }"
        '__leantty_snapshot() {'
        '  umask 077'
        "  printf '%s' `"`$READLINE_LINE`" > '$wslSnapshotPath'"
        '}'
        'bind -x ''"\C-x\C-l":__leantty_snapshot'''
    ) -join "`n"
    [IO.File]::WriteAllText($bashRcPath, $bashRc + "`n", [Text.UTF8Encoding]::new($false))
    $controlledShell = @(
        '#!/usr/bin/env bash'
        "export LANG='C.UTF-8'"
        "export LC_ALL='C.UTF-8'"
        "exec bash --noprofile --rcfile '$wslFixtureDirectory/bashrc' -i"
    ) -join "`n"
    [IO.File]::WriteAllText(
        $controlledShellPath,
        $controlledShell + "`n",
        [Text.UTF8Encoding]::new($false)
    )

    $wslHostKeyPath = "$wslFixtureDirectory/ssh_host_ed25519_key"
    $wslAuthorizedKeysPath = "$wslFixtureDirectory/authorized_keys"
    $wslConfigPath = "$wslFixtureDirectory/sshd_config"
    $config = @(
        "Port $Port"
        'ListenAddress 0.0.0.0'
        "HostKey $wslHostKeyPath"
        "PidFile $wslFixtureDirectory/sshd.pid"
        "AuthorizedKeysFile $wslAuthorizedKeysPath"
        'PasswordAuthentication no'
        'KbdInteractiveAuthentication no'
        'PubkeyAuthentication yes'
        'PermitRootLogin no'
        'UsePAM no'
        'StrictModes no'
        'LogLevel VERBOSE'
        "AllowUsers $wslUser"
        "ForceCommand $wslFixtureDirectory/controlled-shell.sh"
    ) -join "`n"
    [IO.File]::WriteAllText($sshdConfigPath, $config + "`n", [Text.UTF8Encoding]::new($false))
    & wsl.exe --exec ssh-keygen -q -t ed25519 -N '' -f $wslHostKeyPath
    if ($LASTEXITCODE -ne 0) { throw '[environment] Unable to generate temporary SSH host key' }
    & wsl.exe --exec chmod 600 $wslHostKeyPath $wslAuthorizedKeysPath
    & wsl.exe --exec chmod 700 "$wslFixtureDirectory/controlled-shell.sh" $wslToolPath
    if ($LASTEXITCODE -ne 0) { throw '[environment] Unable to secure WSL fixture files' }

    $sshdProcess = Start-Process `
        -FilePath 'wsl.exe' `
        -ArgumentList @('--exec', 'sudo', '/usr/sbin/sshd', '-D', '-e', '-f', $wslConfigPath) `
        -RedirectStandardOutput $sshdStdoutPath `
        -RedirectStandardError $sshdStderrPath `
        -WindowStyle Hidden `
        -PassThru
    $listenWatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ($sshdProcess.HasExited) { throw '[infrastructure] Temporary WSL sshd exited early' }
        $listening = Test-NetConnection -ComputerName 127.0.0.1 -Port $Port `
            -InformationLevel Quiet -WarningAction SilentlyContinue
        if (-not $listening) { Start-Sleep -Milliseconds 250 }
    } while (-not $listening -and $listenWatch.Elapsed.TotalSeconds -lt 15)
    if (-not $listening) { throw '[infrastructure] Temporary WSL sshd did not listen' }

    $existingMappings = (@(& $hdc -t $Target fport ls 2>&1) -join "`n")
    if ($existingMappings -match "(?m)tcp:$Port\s+tcp:$Port\s+\[Reverse\]") {
        throw "[environment] HDC reverse mapping already exists for port $Port"
    }
    $mappingOutput = (@(& $hdc -t $Target rport "tcp:$Port" "tcp:$Port" 2>&1) -join "`n")
    if ($LASTEXITCODE -ne 0 -or $mappingOutput -notmatch 'Forwardport result:OK') {
        throw '[infrastructure] Unable to create HDC reverse mapping'
    }
    $mappingActive = $true

    Submit-LocalCommand `
        -Command "ssh-keygen -R [127.0.0.1]:$Port" `
        -Stage 'known-host-pre-clean'
    $knownHostCleanupAttempted = $true

    if ($Osc99CapabilityProbe) {
        $result.checks += Invoke-Osc99CapabilityProbeCheck
        Write-AgentCompatibilityProgress -Stage 'osc99-capability-complete'
    } else {
        $missingAuthentication = [Collections.Generic.List[string]]::new()
        foreach ($agent in $Agents) {
            $agentInventory = $inventory.tools.$agent
            $authReady = [bool]$inventory.authenticationReady.$agent
            if (-not $agentInventory.installed) {
                foreach ($mode in $Modes) {
                    $result.checks += [pscustomobject]@{
                        agent = $agent; mode = $mode; status = 'not-assessed'
                        authentication = 'not-checked'; failure = 'Agent is not installed'
                    }
                    Write-AgentCompatibilityProgress -Stage "$agent-$mode-not-assessed"
                }
                continue
            }
            if (-not $authReady) {
                $missingAuthentication.Add($agent)
                foreach ($mode in $Modes) {
                    $result.checks += [pscustomobject]@{
                        agent = $agent; mode = $mode; status = 'not-assessed'
                        authentication = 'missing'; failure = 'Interactive Agent authentication is required'
                    }
                    Write-AgentCompatibilityProgress -Stage "$agent-$mode-not-assessed"
                }
                continue
            }
            foreach ($mode in $Modes) {
                $modeCheck = $null
                if ($InteractionOnlyProbe) {
                    $modeCheck = Invoke-AgentInteractionOnlyCheck -Agent $agent -Mode $mode
                } elseif ($ProtocolInteractionProbe) {
                    $modeCheck = Invoke-AgentProtocolInteractionCheck -Agent $agent -Mode $mode
                } else {
                    $modeCheck = Invoke-AgentModeCheck -Agent $agent -Mode $mode
                }
                $result.checks += $modeCheck
                Write-AgentCompatibilityProgress -Stage "$agent-$mode-complete"
            }
        }
    }

    Submit-LocalCommand `
        -Command "ssh-keygen -R [127.0.0.1]:$Port" `
        -Stage 'known-host-post-clean'
    $failedChecks = @($result.checks | Where-Object { $_.status -eq 'failed' })
    $notAssessed = @($result.checks | Where-Object { $_.status -eq 'not-assessed' })
    $result.commandAutomation = [ordered]@{
        local = Get-LeanTTYDeviceCommandAutomationSummary `
            -Observations $commandObservations `
            -BusinessVerdict $(if ($failedChecks.Count -eq 0) { 'passed' } else { 'failed' }) `
            -BusinessPostcondition $(if ($Osc99CapabilityProbe) {
                'osc99-capability-response'
            } elseif ($InteractionOnlyProbe) {
                'zero-model-agent-tui-raw-alternate-resize'
            } elseif ($ProtocolInteractionProbe) {
                'qwen-native-osc52-scrollback-and-osc8-observation'
            } else {
                'agent-compatibility-selected-checks'
            })
        connected = [ordered]@{
            contract = 'controlled-bash-readline-snapshot-before-single-enter'
            observations = @($connectedCommandObservations)
        }
    }
    if ($failedChecks.Count -gt 0) {
        $result.status = 'failed'
    } elseif ($notAssessed.Count -gt 0 -and -not $AllowPartialAuthentication) {
        $result.status = 'blocked'
    } elseif ($notAssessed.Count -gt 0) {
        $result.status = 'partial'
    } else {
        $result.status = 'passed'
    }
} finally {
    if ($panelOpen) {
        & $hdc -t $Target shell 'uitest uiInput keyEvent Back' 2>$null | Out-Null
    }
    try {
        & wsl.exe --exec bash $wslToolPath cleanup $wslFixtureDirectory 2>$null
    } catch {}
    if ($isolatedTabCreated) {
        try {
            & $hdc -t $Target shell 'aa start -a EntryAbility -b com.leantty.app' | Out-Null
            Start-Sleep -Milliseconds 500
            Invoke-AgentWorkspaceChord -Action 'close-active'
            $isolatedTabCreated = $false
        } catch {
            $cleanupFailures.Add('Isolated Agent test tab cleanup failed')
        }
    }
    $captureEvidenceDirectory = Join-Path $EvidenceDirectory 'captures'
    $captureResultsDirectory = Join-Path $fixtureDirectory 'results'
    if (Test-Path -LiteralPath $captureResultsDirectory -PathType Container) {
        New-Item -ItemType Directory -Path $captureEvidenceDirectory -Force | Out-Null
        Get-ChildItem -LiteralPath $captureResultsDirectory -Filter '*.json' -File |
            Where-Object { $_.Name -notin @('inventory.json', 'network-environment.json') } |
            ForEach-Object {
            $destination = Join-Path $captureEvidenceDirectory $_.Name
            if ($_.BaseName.EndsWith('-live')) {
                $liveSummary = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 30
                $liveSummary.privacy.rawInputRetained = $false
                $liveSummary.privacy.rawOutputRetained = $false
                $liveSummary.privacy | Add-Member `
                    -NotePropertyName rawCaptureDeletedBeforeEvidenceCopy -NotePropertyValue $true -Force
                [IO.File]::WriteAllText(
                    $destination,
                    ($liveSummary | ConvertTo-Json -Depth 30),
                    [Text.UTF8Encoding]::new($false)
                )
            } else {
                Copy-Item -LiteralPath $_.FullName -Destination $destination
            }
        }
    }
    if ($mappingActive) {
        & $hdc -t $Target fport rm "tcp:$Port" "tcp:$Port" 2>$null | Out-Null
        $remaining = (@(& $hdc -t $Target fport ls 2>&1) -join "`n")
        if ($remaining -match "(?m)tcp:$Port\s+tcp:$Port\s+\[Reverse\]") {
            $cleanupFailures.Add('HDC reverse mapping remained')
        } else {
            $mappingActive = $false
        }
    }
    if ($null -ne $sshdProcess) {
        $wslSshdPid = if (Test-Path -LiteralPath $sshdPidPath -PathType Leaf) {
            [IO.File]::ReadAllText($sshdPidPath).Trim()
        } else {
            ''
        }
        if ($wslSshdPid -notmatch '^[1-9][0-9]*$') {
            $cleanupFailures.Add('Temporary WSL sshd PID is missing or malformed')
        } else {
            $sshdIdentity = (@(
                & wsl.exe --exec ps -p $wslSshdPid -o args= 2>&1
            ) -join "`n").Trim()
            if ($LASTEXITCODE -eq 0 -and
                $sshdIdentity.Contains("/usr/sbin/sshd -D -e -f $wslConfigPath")) {
                & wsl.exe --exec sudo kill -TERM -- $wslSshdPid 2>$null
                if ($LASTEXITCODE -ne 0) {
                    $cleanupFailures.Add('Temporary WSL sshd TERM failed')
                }
                $stopWatch = [Diagnostics.Stopwatch]::StartNew()
                do {
                    & wsl.exe --exec sudo kill -0 -- $wslSshdPid 2>$null
                    $sshdAlive = $LASTEXITCODE -eq 0
                    if ($sshdAlive) { Start-Sleep -Milliseconds 100 }
                } while ($sshdAlive -and $stopWatch.Elapsed.TotalSeconds -lt 5)
                if ($sshdAlive) {
                    & wsl.exe --exec sudo kill -KILL -- $wslSshdPid 2>$null
                    Start-Sleep -Milliseconds 100
                    & wsl.exe --exec sudo kill -0 -- $wslSshdPid 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        $cleanupFailures.Add('Temporary WSL sshd remained alive after TERM and KILL')
                    }
                }
            } elseif ($LASTEXITCODE -eq 0) {
                $cleanupFailures.Add('Temporary WSL sshd identity did not match its run-scoped config')
            }
        }
        if (-not $sshdProcess.HasExited) {
            Stop-Process -Id $sshdProcess.Id -Force
            $sshdProcess.WaitForExit(5000)
        }
    }
    if ($awakeLeaseAcquired) {
        try {
            Stop-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $Target
            $awakeLeaseAcquired = $false
        } catch {
            $cleanupFailures.Add('Screen timeout restore failed')
        }
    }
    if (Test-Path -LiteralPath $fixtureDirectory) {
        $resolvedFixture = [IO.Path]::GetFullPath($fixtureDirectory)
        $tempPrefix = $temporaryRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if ($resolvedFixture.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path $resolvedFixture -Leaf) -match '^leantty-agent-compat-[a-f0-9]{32}$') {
            Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
        } else {
            $cleanupFailures.Add('Fixture cleanup target failed validation')
        }
    }
    if ($cleanupFailures.Count -eq 0) {
        $result.cleanup = [ordered]@{
            result = 'passed'
            detail = 'tmux-stopped; reverse-port-removed; sshd-stopped; screen-timeout-restored; raw-captures-and-fixture-removed'
        }
    } else {
        $result.cleanup = [ordered]@{
            result = 'failed'
            detail = ($cleanupFailures -join '; ')
        }
        $result.status = 'invalid/interrupted'
    }
    $result.completedAt = [DateTimeOffset]::UtcNow.ToString('o')
    Write-LeanTTYAtomicJson `
        -Path (Join-Path $EvidenceDirectory 'result.json') `
        -Value $result `
        -Depth 30
    Write-AgentCompatibilityProgress -Stage 'complete'
}

if ($cleanupFailures.Count -gt 0) {
    throw '[cleanup] ' + ($cleanupFailures -join '; ')
}
if ($result.status -ne 'passed' -and
    -not ($result.status -eq 'partial' -and $AllowPartialAuthentication)) {
    throw "AGENT COMPATIBILITY $($result.status): $EvidenceDirectory"
}
Write-Host "AGENT COMPATIBILITY $($result.status.ToUpperInvariant()): $EvidenceDirectory"
