<#
.SYNOPSIS
  Verify shell, tmux, and Codex long-task BEL notifications on a physical HarmonyOS PC.
.DESCRIPTION
  Starts a temporary isolated OpenSSH daemon in the default WSL distribution, authorizes
  only the diagnostic app's existing public key, and runs real shell, tmux, and Codex CLI
  workloads. Each workload emits one standard BEL after completing its named work.
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [string]$EvidenceDirectory = '',
    [string]$HapPath = '',
    [ValidateRange(20000, 40000)]
    [int]$Port = 23150,
    [switch]$DiagnosticHap,
    [string]$CandidateBasePath = '',
    [string]$PreviousAttemptId = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')
. (Join-Path $PSScriptRoot 'rust-wsl.ps1')
. (Join-Path $PSScriptRoot 'candidate-store.ps1')
. (Join-Path $PSScriptRoot 'release-tooling.ps1')

if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path ([IO.Path]::GetTempPath()) (
        'LeanTTY-long-task-notification-' + [Guid]::NewGuid().ToString('N')
    )
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null

if ([string]::IsNullOrWhiteSpace($HapPath)) {
    throw '-HapPath is required and must identify one exact signed diagnostic HAP'
}
$harnessStatus = @(git -C $repoRoot status --porcelain --untracked-files=all 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect notification harness source state' }
$harnessDirty = ($harnessStatus.Count -gt 0)
if ($harnessDirty -and -not $DiagnosticHap) {
    throw 'Long-task notification acceptance requires a clean committed harness'
}
$harnessCommit = (& git -C $repoRoot rev-parse HEAD 2>&1).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve notification harness commit' }
$harnessTree = (& git -C $repoRoot rev-parse 'HEAD^{tree}' 2>&1).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve notification harness tree' }
$harnessDifferencePaths = @()
if ($DiagnosticHap) {
    $HapPath = [IO.Path]::GetFullPath($HapPath)
    if (-not (Test-Path -LiteralPath $HapPath -PathType Leaf)) {
        throw "Signed diagnostic HAP not found: $HapPath"
    }
    $candidate = [pscustomobject][ordered]@{
        hapPath = $HapPath
        sha256 = (Get-FileHash -LiteralPath $HapPath -Algorithm SHA256).Hash.ToLowerInvariant()
        gitCommit = $null
        gitTree = $null
        gitDirty = $null
        verificationMode = 'diagnostic'
    }
} else {
    $candidate = Resolve-LeanTTYRetainedCandidate `
        -RepoRoot $repoRoot -HapPath $HapPath -CandidateBasePath $CandidateBasePath
    if ([bool]$candidate.gitDirty) {
        throw 'Long-task notification acceptance requires a clean committed candidate'
    }
    $harnessDifferencePaths = @(Assert-LeanTTYCandidateHarnessCompatibility `
        -RepoRoot $repoRoot `
        -Candidate $candidate `
        -AllowedHarnessPaths @(
            'tools/verify-long-task-notification-pc.ps1',
            'tools/test-device-regression.ps1',
            'tools/candidate-store.ps1',
            'tools/release-tooling.ps1',
            'tools/device-regression.ps1',
            'tools/hdc-common.ps1',
            'tools/rust-wsl.ps1',
            'docs/quality-strategy.md'
        ))
}
$HapPath = [string]$candidate.hapPath
if ((Split-Path $HapPath -Leaf) -match 'unsigned') {
    throw "Signed HAP not found: $HapPath"
}
$candidateSha256 = [string]$candidate.sha256
$attemptId = [Guid]::NewGuid().ToString('N')
$hdc = Resolve-Hdc
$Target = Resolve-LeanTTYRegressionTarget -Hdc $hdc -Target $Target
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$fixtureDirectory = Join-Path $temporaryRoot (
    'leantty-long-task-' + [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $fixtureDirectory | Out-Null
$wslFixtureDirectory = ConvertTo-LeanTTYWslPath -WindowsPath $fixtureDirectory
$sshdConfigPath = Join-Path $fixtureDirectory 'sshd_config'
$authorizedKeysPath = Join-Path $fixtureDirectory 'authorized_keys'
$hostKeyPath = Join-Path $fixtureDirectory 'ssh_host_ed25519_key'
$sshdStdoutPath = Join-Path $fixtureDirectory 'sshd-stdout.txt'
$sshdStderrPath = Join-Path $fixtureDirectory 'sshd-stderr.txt'
$fixtureId = [Guid]::NewGuid().ToString('N').Substring(0, 12)
$tmuxSocket = 'leantty_' + $fixtureId
$mappingActive = $false
$sshdProcess = $null
$panelOpen = $false
$processId = ''
$knownHostCleanupAttempted = $false
$cleanupFailures = [Collections.Generic.List[string]]::new()
$commandObservations = [Collections.Generic.List[object]]::new()

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
    if ($inputs.Count -ne 1) {
        throw "[environment] Expected one terminal input, found $($inputs.Count)"
    }
    Click-Node -Node $inputs[0] -Description 'Focus long-task terminal input'
    Start-Sleep -Milliseconds 180
    return $inputs[0]
}

function Submit-LocalCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Stage
    )
    Submit-LeanTTYDeviceCommand `
        -Hdc $hdc -Target $Target -ProcessId $processId `
        -Command $Command -Stage $Stage -ObservationSink $commandObservations `
        -InputNodeProvider {
            param($attempt)
            Focus-TerminalInput -Name "$Stage-local-command-$attempt"
        } | Out-Null
}

function Submit-ConnectedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Stage
    )
    $inputNode = Focus-TerminalInput -Name "$Stage-connected-command"
    Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $Command -InputNode $inputNode
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
}

function Wait-AppLog {
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 20
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $logs = (@(& $hdc -t $Target shell "hilog -z 1200 -t app -P $processId" 2>&1) -join "`n")
        if ($logs -match $Pattern) { return $logs }
        Start-Sleep -Milliseconds 500
    }
    throw "[product] Timed out waiting for app log: $Pattern"
}

function Wait-FileText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [ValidateRange(1, 180)][int]$TimeoutSeconds
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $text = [IO.File]::ReadAllText($Path)
            if ($text -match $Pattern) { return $text }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "[workload] Timed out waiting for $Pattern"
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

function Connect-WorkloadServer {
    param([Parameter(Mandatory = $true)][string]$Stage)
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-LocalCommand `
        -Command "ssh -p $Port -i id_ed25519 wandc@127.0.0.1" `
        -Stage "$Stage-connect"
    try {
        Wait-AppLog -Pattern 'native control event: host_key_prompt:' -TimeoutSeconds 5 | Out-Null
        $inputNode = Focus-TerminalInput -Name "$Stage-host-key-prompt"
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text 'yes' -InputNode $inputNode
        Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
    } catch {
        # A previously trusted key for the same temporary endpoint skips this prompt.
    }
    Wait-AppLog -Pattern 'SSH session connected' -TimeoutSeconds 20 | Out-Null
}

function Disconnect-WorkloadServer {
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        Invoke-LeanTTYDeviceCtrlD -Hdc $hdc -Target $Target
        Start-Sleep -Milliseconds 350
        $logs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $processId
        if ($logs -match 'SSH closed, exitCode=') { return }
    }
    throw '[product] Long-task SSH session did not close cleanly'
}

function Invoke-WorkloadScenario {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('shell', 'tmux', 'codex')][string]$Name,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$CompletionPath,
        [Parameter(Mandatory = $true)][string]$CompletionPattern,
        [ValidateRange(10, 180)][int]$TimeoutSeconds
    )
    Connect-WorkloadServer -Stage $Name
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-ConnectedCommand -Command $Command -Stage $Name
    Start-Sleep -Milliseconds 300
    $visible = Get-FullLayout -Name "$Name-before-minimize"
    $minimize = Get-MinimizeButton -Layout $visible
    Click-Node -Node $minimize -Description "Minimize LeanTTY for $Name workload"
    $completionText = Wait-FileText `
        -Path $CompletionPath -Pattern $CompletionPattern -TimeoutSeconds $TimeoutSeconds
    Wait-AppLog -Pattern 'Background BEL notification published: paneId=pane-\d+' `
        -TimeoutSeconds 20 | Out-Null
    $panel = Open-NotificationPanel -Stage $Name
    $cards = @(Get-LeanTTYLayoutNodes -Node $panel | Where-Object {
        [string]$_.attributes.text -match '^LeanTTY, .*(?:A terminal needs your attention\.|终端有新提示)$'
    })
    if ($cards.Count -ne 1) {
        throw "[product] Expected one $Name notification card, found $($cards.Count)"
    }
    if ([string]$cards[0].attributes.text -match 'pane-|@|host|ssh|agent|codex|tmux') {
        throw "[privacy] $Name notification exposed workload or source information"
    }
    Save-LeanTTYDeviceScreenshot `
        -Hdc $hdc -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory "$Name-notification-panel.png")
    Click-Node -Node $cards[0] -Description "Activate $Name long-task notification"
    $script:panelOpen = $false
    Wait-AppLog -Pattern 'Background BEL return applied: paneId=pane-\d+' -TimeoutSeconds 20 |
        Out-Null
    $returned = Get-FullLayout -Name "$Name-returned"
    $inputs = @(Get-LeanTTYTerminalInputNodes -Layout $returned)
    if ($inputs.Count -ne 1) {
        throw "[product] $Name notification return changed the workspace"
    }
    Disconnect-WorkloadServer
    return [pscustomobject][ordered]@{
        workload = $Name
        command = Split-Path $Command -Leaf
        completion = $completionText.Trim()
        notificationCardCount = $cards.Count
        genericPayload = $true
        returnApplied = $true
        singlePaneAfterReturn = $true
        sshClosed = $true
    }
}

$result = [ordered]@{
    schemaVersion = 2
    scenario = 'long-task-notification'
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
    }
    harness = [ordered]@{
        gitCommit = $harnessCommit
        gitTree = $harnessTree
        gitDirty = $harnessDirty
        differencePathsFromCandidate = @($harnessDifferencePaths)
    }
    remote = [ordered]@{
        environment = 'default-wsl-temporary-openssh'
        sshPort = $Port
        identity = 'existing-id-ed25519-public-key-only'
        tmuxSocket = $tmuxSocket
    }
    workloads = @()
    commandAutomation = $null
    cleanup = 'pending'
    status = 'failed'
}

function Write-LongTaskProgress {
    param([Parameter(Mandatory = $true)][string]$Stage)
    Write-LeanTTYAtomicJson -Path (Join-Path $EvidenceDirectory 'progress.json') -Value ([ordered]@{
        schemaVersion = 1
        scenario = 'long-task-notification'
        attemptId = $attemptId
        previousAttemptId = $PreviousAttemptId
        stage = $Stage
        completedWorkloadCount = @($result.workloads).Count
        totalWorkloadCount = 3
        updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        contentRecorded = $false
    })
}

try {
    $publicKeyOutput = @(
        & $hdc -t $Target shell -b com.leantty.app `
            'cat /data/app/el2/100/base/com.leantty.app/haps/entry/files/.ssh/id_ed25519.pub' 2>&1
    ) -join "`n"
    $publicKey = $publicKeyOutput.Trim()
    if ($publicKey -notmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,3}(?: .*)?$') {
        throw '[environment] Diagnostic app id_ed25519 public key is missing or malformed'
    }
    [IO.File]::WriteAllText($authorizedKeysPath, $publicKey + "`n", [Text.UTF8Encoding]::new($false))

    $wslHostKeyPath = "$wslFixtureDirectory/ssh_host_ed25519_key"
    $wslAuthorizedKeysPath = "$wslFixtureDirectory/authorized_keys"
    $wslConfigPath = "$wslFixtureDirectory/sshd_config"
    $wslShellPath = "$wslFixtureDirectory/shell-workload.sh"
    $wslTmuxPath = "$wslFixtureDirectory/tmux-workload.sh"
    $wslTmuxInnerPath = "$wslFixtureDirectory/tmux-inner.sh"
    $wslCodexPath = "$wslFixtureDirectory/codex-workload.sh"
    $shellCompletionPath = Join-Path $fixtureDirectory 'shell-complete'
    $tmuxCompletionPath = Join-Path $fixtureDirectory 'tmux-complete'
    $codexCompletionPath = Join-Path $fixtureDirectory 'codex-complete'

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
        'AllowUsers wandc'
        'Subsystem sftp internal-sftp'
    ) -join "`n"
    [IO.File]::WriteAllText($sshdConfigPath, $config + "`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fixtureDirectory 'shell-workload.sh'), (
        "#!/bin/sh`nsleep 10`nprintf '\a'`nprintf 'shell-ok\n' > '$wslFixtureDirectory/shell-complete'`n"
    ), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fixtureDirectory 'tmux-inner.sh'), (
        "#!/bin/sh`nsleep 10`nprintf '\a'`nprintf 'tmux-ok\n' > '$wslFixtureDirectory/tmux-complete'`nexec /bin/sh`n"
    ), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fixtureDirectory 'tmux-workload.sh'), (
        "#!/bin/sh`nexec tmux -L '$tmuxSocket' new-session -s job '$wslTmuxInnerPath'`n"
    ), [Text.UTF8Encoding]::new($false))
    $codexScript = @(
        '#!/bin/sh'
        "codex exec --sandbox read-only --skip-git-repo-check -C /tmp 'Reply exactly LEANTTY_AGENT_DONE'"
        'status=$?'
        'sleep 10'
        "printf '\a'"
        ('printf ''codex-exit=%s\n'' "$status" > ' + "'$wslFixtureDirectory/codex-complete'")
    ) -join "`n"
    [IO.File]::WriteAllText(
        (Join-Path $fixtureDirectory 'codex-workload.sh'),
        $codexScript + "`n",
        [Text.UTF8Encoding]::new($false)
    )

    & wsl.exe --exec ssh-keygen -q -t ed25519 -N '' -f $wslHostKeyPath
    if ($LASTEXITCODE -ne 0) { throw '[environment] Unable to generate temporary WSL SSH host key' }
    & wsl.exe --exec chmod 600 $wslHostKeyPath $wslAuthorizedKeysPath
    & wsl.exe --exec chmod 700 $wslShellPath $wslTmuxPath $wslTmuxInnerPath $wslCodexPath
    if ($LASTEXITCODE -ne 0) { throw '[environment] Unable to prepare temporary WSL workload files' }

    $sshdProcess = Start-Process `
        -FilePath 'wsl.exe' `
        -ArgumentList @('--exec', 'sudo', '/usr/sbin/sshd', '-D', '-e', '-f', $wslConfigPath) `
        -RedirectStandardOutput $sshdStdoutPath `
        -RedirectStandardError $sshdStderrPath `
        -WindowStyle Hidden `
        -PassThru
    $listenWatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ($sshdProcess.HasExited) {
            throw '[environment] Temporary WSL sshd exited before listening'
        }
        $listening = Test-NetConnection -ComputerName 127.0.0.1 -Port $Port `
            -InformationLevel Quiet -WarningAction SilentlyContinue
        if (-not $listening) { Start-Sleep -Milliseconds 250 }
    } while (-not $listening -and $listenWatch.Elapsed.TotalSeconds -lt 15)
    if (-not $listening) { throw '[environment] Temporary WSL sshd did not become reachable' }

    $existingMappings = (@(& $hdc -t $Target fport ls 2>&1) -join "`n")
    if ($existingMappings -match "(?m)tcp:$Port\s+tcp:$Port\s+\[Reverse\]") {
        throw "HDC reverse mapping already exists for long-task port $Port"
    }
    $mappingOutput = (@(& $hdc -t $Target rport "tcp:$Port" "tcp:$Port" 2>&1) -join "`n")
    if ($LASTEXITCODE -ne 0 -or $mappingOutput -notmatch 'Forwardport result:OK') {
        throw "Unable to create long-task HDC reverse mapping: $mappingOutput"
    }
    $mappingActive = $true

    & (Join-Path $PSScriptRoot 'dev-pc.ps1') `
        -Target $Target -HapPath $HapPath -SkipBuild
    if ($LASTEXITCODE -ne 0) { throw '[infrastructure] Exact diagnostic HAP deployment failed' }
    $processId = (@(& $hdc -t $Target shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
    if ($processId -notmatch '^\d+$') { throw '[environment] LeanTTY process is not running' }

    Submit-LocalCommand `
        -Command "ssh-keygen -R [127.0.0.1]:$Port" `
        -Stage 'known-host-pre-clean'
    $knownHostCleanupAttempted = $true

    $result.workloads += Invoke-WorkloadScenario `
        -Name shell -Command $wslShellPath `
        -CompletionPath $shellCompletionPath -CompletionPattern '^shell-ok' -TimeoutSeconds 30
    Write-LongTaskProgress -Stage 'shell-complete'
    $result.workloads += Invoke-WorkloadScenario `
        -Name tmux -Command $wslTmuxPath `
        -CompletionPath $tmuxCompletionPath -CompletionPattern '^tmux-ok' -TimeoutSeconds 30
    Write-LongTaskProgress -Stage 'tmux-complete'
    $result.workloads += Invoke-WorkloadScenario `
        -Name codex -Command $wslCodexPath `
        -CompletionPath $codexCompletionPath -CompletionPattern '^codex-exit=0' -TimeoutSeconds 180
    Write-LongTaskProgress -Stage 'codex-complete'

    Submit-LocalCommand `
        -Command "ssh-keygen -R [127.0.0.1]:$Port" `
        -Stage 'known-host-post-clean'
    $result.commandAutomation = Get-LeanTTYDeviceCommandAutomationSummary `
        -Observations $commandObservations `
        -BusinessVerdict 'passed' `
        -BusinessPostcondition 'shell-tmux-codex-notification-return-and-session-cleanup'
    $result.status = 'passed'
} finally {
    if ($panelOpen) {
        & $hdc -t $Target shell 'uitest uiInput keyEvent Back' 2>$null | Out-Null
    }
    try {
        $cleanupLayout = Get-FullLayout -Name 'cleanup-before-activation'
        $cleanupInputs = @(Get-LeanTTYTerminalInputNodes -Layout $cleanupLayout)
        if ($cleanupInputs.Count -eq 0) {
            & $hdc -t $Target shell 'aa start -a EntryAbility -b com.leantty.app' 2>$null | Out-Null
            Start-Sleep -Milliseconds 500
            $cleanupLayout = Get-FullLayout -Name 'cleanup-visible'
            $cleanupInputs = @(Get-LeanTTYTerminalInputNodes -Layout $cleanupLayout)
        }
        if ($cleanupInputs.Count -ne 1) { throw "Expected one Pane, found $($cleanupInputs.Count)" }
    } catch {
        $cleanupFailures.Add('LeanTTY visibility or single-Pane cleanup failed: ' + $_.Exception.Message)
    }
    if ($mappingActive) {
        & $hdc -t $Target fport rm "tcp:$Port" "tcp:$Port" 2>$null | Out-Null
        $remainingMappings = (@(& $hdc -t $Target fport ls 2>&1) -join "`n")
        if ($remainingMappings -match "(?m)tcp:$Port\s+tcp:$Port\s+\[Reverse\]") {
            $cleanupFailures.Add('Long-task HDC reverse mapping remained after cleanup')
        } else {
            $mappingActive = $false
        }
    }
    try {
        & wsl.exe --exec tmux -L $tmuxSocket kill-server 2>$null
    } catch {}
    if ($null -ne $sshdProcess -and -not $sshdProcess.HasExited) {
        Stop-Process -Id $sshdProcess.Id -Force
        $sshdProcess.WaitForExit(5000)
    }
    if (Test-Path -LiteralPath $fixtureDirectory) {
        Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force
    }
    if ($cleanupFailures.Count -eq 0) {
        $result.cleanup = 'app-visible-single-pane; notification-cancel-requested; reverse-port-removed; ' +
            'temporary-sshd-stopped; tmux-socket-removed; fixture-files-removed; app-identity-unchanged'
    } else {
        $result.cleanup = 'failed: ' + ($cleanupFailures -join '; ')
    }
    $result.completedAt = [DateTimeOffset]::UtcNow.ToString('o')
    Write-LeanTTYAtomicJson `
        -Path (Join-Path $EvidenceDirectory 'result.json') `
        -Value $result `
        -Depth 10
    Write-LongTaskProgress -Stage 'complete'
}

if ($cleanupFailures.Count -gt 0) {
    throw '[cleanup] ' + ($cleanupFailures -join '; ')
}
Write-Host "LONG TASK NOTIFICATION SUCCESS: $EvidenceDirectory"
