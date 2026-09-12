param([string]$EvidencePath = '', [string]$HarnessPath = (Join-Path $PSScriptRoot 'verify-agent-compatibility-pc.ps1'))

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-tooling.ps1')
. (Join-Path $PSScriptRoot 'agent-compatibility-policy.ps1')
$devicePath = $HarnessPath
$parseErrors = $null
$deviceAst = [Management.Automation.Language.Parser]::ParseFile(
    $devicePath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Agent harness has PowerShell parse errors' }
$functionSources = @{}
foreach ($name in @('Wait-AppLog', 'Connect-AgentServer', 'Disconnect-AgentServer', 'Stop-AgentTui', 'Confirm-AgentShellReady',
        'Focus-TerminalInput', 'Submit-LocalCommand', 'Submit-ConnectedCommand',
        'Invoke-AgentSelectedChecks', 'Invoke-AgentInteractionOnlyCheck',
        'Invoke-AgentProtocolInteractionCheck', 'Invoke-AgentModeCheck',
        'Invoke-Osc99CapabilityProbeCheck', 'Invoke-AgentSshPrerequisiteCheck',
        'Get-AgentTabState', 'Get-AgentOwnedTab', 'Close-AgentTestTab', 'Get-AgentTmuxNotificationEnvironment')) {
    $function = $deviceAst.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if ($null -eq $function) { throw "Missing harness boundary: $name" }
    $functionSources[$name] = $function.Extent.Text
}
$startedAt = [DateTimeOffset]::UtcNow
$checks = [Collections.Generic.List[object]]::new()
function Assert-Gate([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Expect-GateError([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert-Gate ($null -ne $caught -and $caught -match $Pattern) "Expected $Pattern; received '$caught'"
}
function Test-Gate([string]$Name, [scriptblock]$Action) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $check = [ordered]@{ name = $Name; result = 'failed'; failure = ''; durationMs = 0 }
    try {
        # Execute actual orchestration; replace only external effects and observations.
        # No script entry point, HDC, WSL, SSH, real credentials or device input is used.
        & {
            foreach ($source in $functionSources.Values) { . ([scriptblock]::Create($source)) }
            $script:trace = [Collections.Generic.List[string]]::new()
            $script:agentSshBoundary = 'local'
            $script:controlledLocaleChecked = $true
            $script:knownHostRemoved = $false
            $script:waitNumber = 0
            $script:fault = ''
            $script:connectionMode = 'prompt'
            $script:logMode = 'empty'
            $hdc = 'Forbidden-DeviceCommand'
            $Target = 'no-device'
            $appProcessId = '1234'
            $Port = 39999
            $fixtureDirectory = $PSScriptRoot
            $shellReadyPath = Join-Path $PSScriptRoot 'controlled-absent-shell-ready'
            Assert-Gate (-not (Test-Path -LiteralPath $shellReadyPath)) 'Controlled marker must not exist'
            $result = [pscustomobject]@{ server = @{ user = 'controlled' }; checks = @(); resources=@{} }
            $Agents = @('codex', 'opencode')
            $Modes = @('direct', 'tmux')
            $Osc99CapabilityProbe = $false
            $InteractionOnlyProbe = $true
            $ProtocolInteractionProbe = $false
            $SshPrerequisiteProbe = $false
            $StopAtHostKeyPrompt = $false
            $inventory = [pscustomobject]@{
                tools = @{ codex = @{ installed = $true }; opencode = @{ installed = $true } }
                authenticationReady = @{ codex = $true; opencode = $true }
            }
            function Forbidden-DeviceCommand { $script:trace.Add('external-command'); throw '[harness] forbidden device command' }
            function Clear-LeanTTYAppLogs { $script:trace.Add('clear-logs') }
            function Submit-LocalCommand {
                param($Command, $Stage)
                $script:trace.Add("local:$Stage")
                if ($script:fault -eq 'submit') { throw '[harness] controlled-submit-failure' }
            }
            function Focus-TerminalInput {
                $script:trace.Add('focus')
                if ($script:fault -eq 'focus') { throw '[environment] controlled-focus-failure' }
                return @{ controlled = $true }
            }
            function Wait-LeanTTYDeviceKnownHostAbsent {
                $script:trace.Add('known-host-absent')
                if ($script:fault -eq 'known-host-read') { throw '[infrastructure] controlled-known-host-read-failure' }
            }
            function Invoke-LeanTTYDeviceText {
                param($Text)
                $script:trace.Add('text')
                if ($Text -in @('/exit','/quit')) { $script:trace.Add("exit-command:$Text") }
                if ($script:fault -eq 'text') { throw '[environment] controlled-text-failure' }
                if ($script:fault -eq 'text-owner') {
                    $failure = [InvalidOperationException]::new('[harness] controlled-owner-change')
                    $failure.Data['LeanTTYTextInputFailure'] = @{phase='after';focusedCount=1;targets=@()}
                    throw $failure
                }
            }
            function Invoke-LeanTTYDeviceKey {
                $script:trace.Add('enter')
                if ($script:fault -eq 'enter') { throw '[infrastructure] controlled-enter-failure' }
            }
            function Invoke-LeanTTYDeviceCtrlD { $script:trace.Add('ctrl-d') }
            function Invoke-LeanTTYDeviceCtrlC { $script:trace.Add('ctrl-c') }
            function Save-CurrentAppLogs { $script:trace.Add('save-logs') }
            function Reset-AppAfterAgentFailure { $script:trace.Add('whole-app-reset') }
            function Get-AgentExpectedAttentionKind { return 'bel' }
            function Wait-File {
                $script:trace.Add('shell-ready')
                if ($script:fault -eq 'shell-ready') { throw '[harness] controlled-shell-ready-failure' }
            }
            function Get-LeanTTYAppLogs {
                if ($script:logMode -eq 'error') { throw '[infrastructure] controlled-log-query-failure' }
                if ($script:logMode -eq 'ready') { return 'SSH session connected' }
                return ''
            }
            function Wait-AppLog {
                param($Pattern, $TimeoutSeconds)
                $script:trace.Add("wait:$Pattern")
                $script:waitNumber++
                if ($script:fault -eq 'observation' -and $script:waitNumber -eq 1) {
                    throw '[infrastructure] controlled-log-query-failure'
                }
                if ($script:fault -eq 'connection-timeout') { throw '[unknown] controlled-connection-timeout' }
                if ($Pattern -match 'SSH closed') {
                    if ($script:fault -eq 'close-timeout') { throw '[unknown] controlled-close-timeout' }
                    return 'SSH closed, exitCode=0'
                }
                if ($Pattern -match 'host_key_prompt' -and $script:waitNumber -eq 1) {
                    if ($script:connectionMode -eq 'trusted') {
                        if ($Pattern -notmatch 'SSH session connected') { throw '[unknown] no host-key prompt' }
                        return 'SSH session connected'
                    }
                    if ($script:connectionMode -eq 'already-connected') {
                        return "native control event: host_key_prompt: final`nSSH session connected"
                    }
                    return 'native control event: host_key_prompt: final'
                }
                return 'SSH session connected'
            }
            function Write-AgentCompatibilityProgress { param($Stage) $script:trace.Add("checkpoint:$Stage") }
            & $Action
        }
        $check.result = 'passed'
    } catch { $check.failure = $_.Exception.Message }
    $check.durationMs = $watch.ElapsedMilliseconds
    $checks.Add([pscustomobject]$check)
    Write-Host "$($check.result): $Name $($check.failure)"
}

Test-Gate 'prompt-confirms-once-before-shell-ready' {
    Connect-AgentServer -Stage 'case'
    Assert-Gate ((@($script:trace | Where-Object { $_ -eq 'text' }).Count -eq 1) -and
        (@($script:trace | Where-Object { $_ -eq 'enter' }).Count -eq 1) -and
        $script:agentSshBoundary -eq 'shell-ready') 'Prompt must confirm once and prove shell-ready'
}
Test-Gate 'host-key-owner-failure-retains-safe-evidence-without-enter' {
    $script:fault = 'text-owner'
    $SshPrerequisiteProbe = $true
    Invoke-AgentSelectedChecks
    Assert-Gate ($result.checks[0].status -eq 'failed' -and
        $result.hostKeyInputFailure.phase -eq 'after' -and
        $result.hostKeyInputFailure.focusedCount -eq 1) 'Caller discarded text-target failure evidence'
    Assert-Gate (@($script:trace | Where-Object { $_ -eq 'text' }).Count -eq 1 -and
        -not ($script:trace -contains 'enter') -and -not ($script:trace -contains 'ctrl-d')) 'Owner loss must not retry or submit input'
}
foreach ($mode in @('trusted', 'already-connected')) {
    Test-Gate "$mode-never-confirms-a-past-prompt" {
        $script:connectionMode = $mode
        Connect-AgentServer -Stage 'case'
        Assert-Gate (-not ($script:trace -contains 'text') -and -not ($script:trace -contains 'enter')) `
            'An already-connected session must not receive yes or Enter'
    }
}
foreach ($failure in @('submit', 'observation', 'focus', 'text', 'enter')) {
    Test-Gate "$failure-failure-stops-connect" {
        $script:fault = $failure
        $expected = if ($failure -eq 'observation') { 'controlled-log-query-failure' } else { "controlled-$failure-failure" }
        Expect-GateError { Connect-AgentServer -Stage 'case' } $expected
        Assert-Gate (-not ($script:trace -contains 'shell-ready')) 'Failed preparation must not wait for shell readiness'
        Assert-Gate ($script:agentSshBoundary -eq 'unconfirmed') 'Failure must leave connection unconfirmed'
    }
}
Test-Gate 'shell-readiness-failure-does-not-authorize-disconnect' {
    $script:fault = 'shell-ready'
    Expect-GateError { Connect-AgentServer -Stage 'case' } 'controlled-shell-ready-failure'
    Expect-GateError { Disconnect-AgentServer } 'unconfirmed'
    Assert-Gate (-not ($script:trace -contains 'ctrl-d')) 'Unconfirmed shell must not receive Ctrl+D'
}
Test-Gate 'failed-reconnect-invalidates-earlier-shell-proof' {
    Connect-AgentServer -Stage 'first'
    Disconnect-AgentServer
    $script:fault = 'connection-timeout'
    Expect-GateError { Connect-AgentServer -Stage 'second' } '^\[unknown\] controlled-connection-timeout$'
    Expect-GateError { Disconnect-AgentServer } 'unconfirmed'
    Assert-Gate (@($script:trace | Where-Object { $_ -eq 'ctrl-d' }).Count -eq 1) 'An earlier close cannot authorize recovery of a new attempt'
}
Test-Gate 'missing-log-is-unknown-not-product' {
    . ([scriptblock]::Create($functionSources['Wait-AppLog']))
    Expect-GateError { Wait-AppLog -Pattern 'SSH session connected' -TimeoutSeconds 1 } '^\[unknown\]'
}
Test-Gate 'log-query-failure-keeps-original-domain' {
    . ([scriptblock]::Create($functionSources['Wait-AppLog']))
    $script:logMode = 'error'
    Expect-GateError { Wait-AppLog -Pattern 'SSH session connected' -TimeoutSeconds 1 } '^\[infrastructure\] controlled-log-query-failure$'
}
Test-Gate 'observed-log-remains-success' {
    . ([scriptblock]::Create($functionSources['Wait-AppLog']))
    $script:logMode = 'ready'
    Assert-Gate ((Wait-AppLog -Pattern 'SSH session connected' -TimeoutSeconds 1) -eq 'SSH session connected') 'Actual observation must succeed'
}
Test-Gate 'disconnect-requires-current-shell-proof' {
    $script:agentSshBoundary = 'unconfirmed'
    Expect-GateError { Disconnect-AgentServer } 'unconfirmed'
    Assert-Gate (-not ($script:trace -contains 'ctrl-d')) 'Unconfirmed connection must not receive Ctrl+D'
}
Test-Gate 'disconnect-clears-stale-logs-and-proves-local' {
    $script:agentSshBoundary = 'shell-ready'
    Disconnect-AgentServer
    Assert-Gate (($script:trace -join ',') -eq 'shell-ready,clear-logs,ctrl-d,wait:SSH closed, exitCode=' -and
        $script:agentSshBoundary -eq 'local') 'Fresh shell proof and close observation must precede local cleanup permission'
}
Test-Gate 'failed-disconnect-cannot-be-repeated' {
    $script:agentSshBoundary = 'shell-ready'
    $script:fault = 'close-timeout'
    Expect-GateError { Disconnect-AgentServer } 'controlled-close-timeout'
    Expect-GateError { Disconnect-AgentServer } 'unconfirmed'
    Assert-Gate (@($script:trace | Where-Object { $_ -eq 'ctrl-d' }).Count -eq 1) 'Do not repeat an uncertain Ctrl+D'
}
Test-Gate 'failed-check-stops-selection-and-local-cleanup' {
    function Invoke-AgentInteractionOnlyCheck {
        param($Agent, $Mode)
        $script:trace.Add("check:$Agent-$Mode")
        return [pscustomobject]@{ status = 'failed'; failure = '[environment] controlled-first-failure' }
    }
    Invoke-AgentSelectedChecks
    Assert-Gate (@($result.checks).Count -eq 1) 'Do not run later Agent/mode checks after failure'
    Assert-Gate (-not ($script:trace -contains 'local:known-host-post-clean')) 'Do not submit cleanup after a failed check'
    Assert-Gate ($script:trace -contains 'checkpoint:codex-direct-complete') 'Persist the first failed check'
}
foreach ($agentName in @('codex','opencode','pi','qwen')) {
    Test-Gate "$agentName-exits-once-without-shell-control-keys" {
        $script:agentSshBoundary = 'shell-busy'
        Stop-AgentTui -Agent $agentName -CaptureResultPath 'pending-capture'
        $expected = if ($agentName -in @('pi','qwen')) { '/quit' } else { '/exit' }
        Assert-Gate (($script:trace -contains "exit-command:$expected") -and
            @($script:trace | Where-Object { $_ -eq 'enter' }).Count -eq 1 -and
            -not ($script:trace -contains 'ctrl-c') -and -not ($script:trace -contains 'ctrl-d')) `
            'One documented TUI exit must not spill Ctrl+C or Ctrl+D into Bash'
        Assert-Gate ($script:agentSshBoundary -eq 'shell-ready') 'Child exit alone is not shell-return proof'
    }
}
Test-Gate 'agent-already-exited-does-not-receive-an-exit-command' {
    function Test-Path { param($LiteralPath) return $LiteralPath -eq 'finished-capture' }
    $script:agentSshBoundary = 'shell-busy'
    Stop-AgentTui -Agent opencode -CaptureResultPath 'finished-capture'
    Assert-Gate (-not ($script:trace -contains 'text') -and -not ($script:trace -contains 'enter') -and
        -not ($script:trace -contains 'ctrl-d') -and -not ($script:trace -contains 'ctrl-c')) 'Already-exited TUI must be observation-only'
}
foreach ($missingBoundary in @('child', 'shell')) {
    Test-Gate "missing-$missingBoundary-acknowledgement-blocks-ssh-close" {
        $script:agentSshBoundary = 'shell-busy'
        function Wait-File {
            param($Path)
            if (($missingBoundary -eq 'child' -and $Path -eq 'pending-capture') -or
                ($missingBoundary -eq 'shell' -and $Path -eq $shellReadyPath)) {
                throw '[harness] controlled-boundary-timeout'
            }
            $script:trace.Add("ack:$Path")
        }
        Expect-GateError { Stop-AgentTui -Agent opencode -CaptureResultPath 'pending-capture' } 'controlled-boundary-timeout'
        Expect-GateError { Disconnect-AgentServer } 'unconfirmed'
        Assert-Gate (-not ($script:trace -contains 'ctrl-d')) 'Missing exit or shell ACK must not close SSH'
    }
}
Test-Gate 'busy-shell-needs-fresh-prompt-before-disconnect' {
    $script:agentSshBoundary = 'shell-busy'
    $script:fault = 'shell-ready'
    Expect-GateError { Disconnect-AgentServer } 'controlled-shell-ready-failure'
    Assert-Gate (-not ($script:trace -contains 'ctrl-d') -and $script:agentSshBoundary -eq 'unconfirmed') `
        'An old connection proof cannot authorize EOF while the shell is busy'
}
Test-Gate 'failed-tui-exit-cannot-be-resubmitted' {
    $script:agentSshBoundary = 'shell-busy'
    $script:fault = 'enter'
    Expect-GateError { Stop-AgentTui -Agent opencode -CaptureResultPath 'pending-capture' } 'controlled-enter-failure'
    Expect-GateError { Stop-AgentTui -Agent opencode -CaptureResultPath 'pending-capture' } 'unconfirmed|already requested'
    Expect-GateError { Disconnect-AgentServer } 'unconfirmed'
    Assert-Gate (@($script:trace | Where-Object { $_ -eq 'enter' }).Count -eq 1 -and
        -not ($script:trace -contains 'ctrl-d')) 'Unknown TUI outcome must not produce another input or shell EOF'
}
foreach ($caller in @('Invoke-AgentInteractionOnlyCheck','Invoke-AgentProtocolInteractionCheck')) {
    Test-Gate "$caller-does-not-type-into-an-uncertain-tui" {
        function Connect-AgentServer { $script:agentSshBoundary = 'shell-ready' }
        function Submit-ConnectedCommand { $script:agentSshBoundary = 'shell-busy' }
        function Wait-AgentInteractionReady { throw '[external-agent] controlled-tui-not-ready' }
        function Wait-AgentTuiReady { throw '[external-agent] controlled-tui-not-ready' }
        $check = & $caller -Agent opencode -Mode direct
        Assert-Gate ($check.status -eq 'failed' -and $check.failure -match 'controlled-tui-not-ready' -and
            $check.recovery -match 'isolated-tab-finalization-required') 'Failed TUI preparation must retain the original failure and defer to its Tab owner'
        Assert-Gate (-not ($script:trace -contains 'text') -and -not ($script:trace -contains 'enter') -and
            -not ($script:trace -contains 'ctrl-c') -and -not ($script:trace -contains 'ctrl-d')) 'The real caller must not attempt exit input after an uncertain interaction'
    }
}
foreach ($case in @('known-limit', 'unknown-version', 'product', 'privacy', 'search', 'input', 'reconnect', 'cleanup')) {
    Test-Gate "third-party-real-selection-$case" {
        $InteractionOnlyProbe = $false
        $Agents = @('pi', 'codex'); $Modes = @('tmux')
        $inventory.tools.pi = @{ installed = $true; version = '0.84.4' }
        $inventory.authenticationReady.pi = $true
        $fixtureDirectory = Join-Path ([IO.Path]::GetTempPath()) ('leantty-third-party-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $fixtureDirectory 'results') | Out-Null
        try {
            foreach ($agentName in $Agents) {
                $capture = @{ childExitCode = 0; input = @{ containsCjkUtf8 = $true; bytes = 4200 }
                    output = @{ nativeAttentionSignalObserved = $true; nativeAttentionSignalKinds = @('osc-777') } }
                if ($case -eq 'input') { $capture.input.bytes = 1 }
                $capture | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $fixtureDirectory "results/$agentName-tmux-notification.json")
            }
            function Start-Sleep {}
            function Controlled-Hdc { $global:LASTEXITCODE = 0 }
            $hdc = 'Controlled-Hdc'
            function Connect-AgentServer { param($Stage)
                if ($case -eq 'reconnect' -and $Stage -match 'reconnect') { throw '[product] controlled reconnect failure' }
                $script:agentSshBoundary = 'shell-ready'
            }
            function Submit-ConnectedCommand {}
            function Start-AgentNotificationAfterHidden {}
            function Get-AgentExpectedAttentionKind { return 'osc-777' }
            function Assert-NotificationAndReturn { param($Stage)
                if ($Stage -eq 'pi-tmux') {
                    if ($case -in @('product', 'privacy')) { throw "[$case] controlled notification failure" }
                    throw '[unknown] Agent inner attention observed without outer attention'
                }
            }
            function Restore-AgentAppForContinuation {}
            function Resume-AgentAfterAttention {}
            function Assert-AgentSearch { if ($case -eq 'search') { throw '[product] controlled search failure' } }
            function Invoke-AgentInputProbes {}
            function Stop-AgentTui { $script:agentSshBoundary = 'shell-ready' }
            function Disconnect-AgentServer { $script:agentSshBoundary = 'local' }
            function Get-AgentOuterAttention {
                return @{ boundary = 'remote-outer-pty-not-client-receipt'; complete = $true
                    childExitCode = 0; bytes = 100; attentionCount = 0; afterHiddenCount = 0
                    checkpoints = @{ 'before-minimize' = 0; 'after-hidden' = 0 } }
            }
            function Get-AgentTmuxNotificationEnvironment {
                return @{ piVersion = $(if ($case -eq 'unknown-version') { 'future' } else { '0.84.4' })
                    tmuxVersion = 'tmux 3.6'
                    notifyExtensionSha256 = '70e4333e09ce00d546c116fd2e918abf7616c70b5da6e88ba8ee21a326afd483'
                    tmuxConfigSha256 = 'c751ee4a8029da7cd247a32c1962d2195d2e801c448f5bc9a067c6811c323dd6' }
            }
            if ($case -eq 'cleanup') { $script:fault = 'known-host-read' }
            $selectionError = ''
            try { Invoke-AgentSelectedChecks } catch { $selectionError = $_.Exception.Message }
            if ($case -in @('known-limit', 'cleanup')) {
                Assert-Gate ($result.checks.Count -eq 2 -and $result.checks[1].status -eq 'passed') 'Known limitation must continue the real selection'
                $first = $result.checks[0]
                Assert-Gate ($first.notificationAssessment.status -eq 'not-applicable' -and
                    $first.notificationAssessment.classification -eq 'upstream-not-forwarded' -and
                    -not $first.nativeNotification -and -not $first.genericNotificationPayload -and -not $first.returnApplied -and
                    $first.search -and $first.reconnect -and $first.tmuxResume) 'Exclusion must retain independent assertions without inventing notification evidence'
                if ($case -eq 'cleanup') {
                    Assert-Gate ($selectionError -match 'known-host-read' -and -not $script:knownHostRemoved) 'Limitation must not bypass failed cleanup'
                } else { Assert-Gate ($selectionError -eq '' -and $script:knownHostRemoved) 'Successful continuation must still clean owned state' }
            } else {
                Assert-Gate ($result.checks.Count -eq 1 -and $result.checks[0].status -eq 'failed' -and
                    -not $script:knownHostRemoved) 'Unknown or independent failure must stop before the next Agent'
            }
        } finally {
            $ownedRoot = [IO.Path]::GetFullPath($fixtureDirectory)
            $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
            if (-not $ownedRoot.StartsWith($tempRoot) -or (Split-Path $ownedRoot -Leaf) -notmatch '^leantty-third-party-[0-9a-f]{32}$') {
                throw 'Unsafe controlled fixture cleanup path'
            }
            Remove-Item -LiteralPath $ownedRoot -Recurse -Force
        }
    }
}
Test-Gate 'successful-selection-cleans-known-host-once' {
    function Invoke-AgentInteractionOnlyCheck { return [pscustomobject]@{ status = 'passed' } }
    Invoke-AgentSelectedChecks
    Assert-Gate (@($result.checks).Count -eq 4 -and $script:knownHostRemoved) 'Keep all selected success paths'
    Assert-Gate (@($script:trace | Where-Object { $_ -eq 'local:known-host-post-clean' }).Count -eq 1) 'Clean once after success'
}
Test-Gate 'unconfirmed-local-state-blocks-cleanup-even-after-passed-check' {
    function Invoke-AgentInteractionOnlyCheck { return [pscustomobject]@{ status = 'passed' } }
    $script:agentSshBoundary = 'unconfirmed'
    Expect-GateError { Invoke-AgentSelectedChecks } 'Local command state is unconfirmed'
    Assert-Gate (-not ($script:trace -contains 'local:known-host-post-clean') -and
        -not $script:knownHostRemoved) 'A check verdict cannot replace a local-state postcondition'
}
Test-Gate 'known-host-read-failure-cannot-claim-removal' {
    function Invoke-AgentInteractionOnlyCheck { return [pscustomobject]@{ status = 'passed' } }
    $script:fault = 'known-host-read'
    Expect-GateError { Invoke-AgentSelectedChecks } 'controlled-known-host-read-failure'
    Assert-Gate (-not $script:knownHostRemoved) 'Submission ACK became removal proof'
    Assert-Gate (@($script:trace | Where-Object { $_ -eq 'local:known-host-post-clean' }).Count -eq 1) 'Failed observation must not repeat the command'
}
Test-Gate 'failed-capability-probe-does-not-submit-local-cleanup' {
    $Osc99CapabilityProbe = $true
    function Invoke-Osc99CapabilityProbeCheck { return [pscustomobject]@{ status = 'failed' } }
    Invoke-AgentSelectedChecks
    Assert-Gate (@($result.checks).Count -eq 1 -and
        ($script:trace -contains 'checkpoint:osc99-capability-complete') -and
        -not ($script:trace -contains 'local:known-host-post-clean')) 'Capability probes must share the same stop boundary'
}
Test-Gate 'failed-cleanup-is-not-marked-removed' {
    function Invoke-AgentInteractionOnlyCheck { return [pscustomobject]@{ status = 'passed' } }
    $script:fault = 'submit'
    Expect-GateError { Invoke-AgentSelectedChecks } 'controlled-submit-failure'
    Assert-Gate (-not $script:knownHostRemoved) 'Do not claim cleanup on failed command submission'
}
Test-Gate 'ssh-only-probe-connects-closes-and-cleans-without-agent-inventory' {
    $SshPrerequisiteProbe = $true
    $inventory = $null
    Invoke-AgentSelectedChecks
    Assert-Gate (@($result.checks).Count -eq 1 -and $result.checks[0].status -eq 'passed' -and
        $result.checks[0].lastProvenBoundary -eq 'local' -and $script:knownHostRemoved) 'SSH-only probe must keep its existing owners'
    Assert-Gate (@($script:trace | Where-Object { $_ -eq 'ctrl-d' }).Count -eq 1) 'Close exactly once after shell proof'
}
foreach ($probeFailure in @('focus','close-timeout')) {
    Test-Gate "ssh-only-probe-stops-at-$probeFailure" {
        $SshPrerequisiteProbe = $true
        $inventory = $null
        $script:fault = $probeFailure
        Invoke-AgentSelectedChecks
        Assert-Gate (@($result.checks).Count -eq 1 -and $result.checks[0].status -eq 'failed' -and
            $result.checks[0].lastProvenBoundary -eq 'unconfirmed' -and
            -not $script:knownHostRemoved -and
            -not ($script:trace -contains 'local:known-host-post-clean')) 'Unknown SSH outcome must not advance or clean via input'
    }
}
foreach ($checkFunction in @('Invoke-AgentModeCheck', 'Invoke-AgentInteractionOnlyCheck',
        'Invoke-AgentProtocolInteractionCheck', 'Invoke-Osc99CapabilityProbeCheck')) {
    Test-Gate "$checkFunction-retains-failed-connect" {
        $script:fault = 'focus'
        $check = if ($checkFunction -eq 'Invoke-Osc99CapabilityProbeCheck') { & $checkFunction } else {
            & $checkFunction -Agent 'codex' -Mode 'direct'
        }
        Assert-Gate ($check.status -eq 'failed' -and $check.failure -match 'controlled-focus-failure' -and
            $check.failureDomain -eq 'environment') 'Preserve the original failure through the caller'
        Assert-Gate (-not ($script:trace -contains 'ctrl-d') -and
            -not ($script:trace -contains 'whole-app-reset')) 'Do not recover an unconfirmed session by sending input or restarting the app'
    }
}
Test-Gate 'host-key-stop-is-zero-input-and-leaves-unconfirmed-session' {
    $SshPrerequisiteProbe = $true
    $StopAtHostKeyPrompt = $true
    Invoke-AgentSelectedChecks
    Assert-Gate ($result.checks[0].failure -match 'Diagnostic stop at host-key prompt' -and
        $script:agentSshBoundary -eq 'unconfirmed' -and -not ($script:trace -contains 'text') -and
        -not ($script:trace -contains 'enter') -and -not ($script:trace -contains 'ctrl-d')) 'Controlled stop advanced or sent input'
}
foreach ($case in @('idle', 'confirm-en', 'confirm-zh', 'wrong-owner', 'changed-process',
        'other-dialog', 'confirmation-owner-changed', 'cancelled')) {
    Test-Gate "owned-tab-cleanup-$case" {
        . (Join-Path $PSScriptRoot 'device-regression.ps1')
        . (Join-Path $PSScriptRoot 'notification-regression.ps1')
        $script:isolatedTabCreated = $true
        $isolatedTabId = 'tab-test'
        $isolatedTabUiId = '20'
        $baselineTabState = @{ids=@('10');activeId='10';windowId='1'}
        $fixture = @{removed=$false;closeCount=0;confirmCount=0;pending=$false;stateReads=0}
        function New-CleanupState {
            $ids = if ($fixture.removed) { @('10') } else { @('10','20') }
            $tabs = @($ids | ForEach-Object {
                @{attributes=@{accessibilityId=$_};children=@(
                    @{attributes=@{type='Text';text='✕';clickable='true';kind='close'};children=@()}
                )}
            })
            return @{ids=$ids;tabs=$tabs;windowId='1';activeId=$(if ($fixture.removed) {'10'} else {'20'})}
        }
        function Ensure-LeanTTYVisible {}
        function Invoke-HdcChecked { return $(if ($case -eq 'changed-process') {'9999'} else {'1234'}) }
        function Get-AgentTabState {
            $fixture.stateReads++
            $state = New-CleanupState
            if ($case -eq 'wrong-owner' -or ($case -eq 'confirmation-owner-changed' -and $fixture.stateReads -gt 1)) {
                $state.windowId = '2'
            }
            return $state
        }
        function Get-FullLayout {
            $title = if ($case -eq 'confirm-zh') {'关闭标签页？'} elseif ($case -eq 'other-dialog') {'Other operation?'} else {'Close this tab?'}
            return @{attributes=@{type='AlertDialog';hostWindowId='1'};children=@(
                @{attributes=@{type='Text';text=$title};children=@()},
                @{attributes=@{type='Text';text='Cancel'};children=@()},
                @{attributes=@{type='Text';text=$(if ($case -eq 'confirm-zh') {'关闭标签页'} else {'Close Tab'});kind='confirm'};children=@()}
            )}
        }
        function Click-Node {
            param($Node)
            if ($Node.attributes.kind -eq 'close') {
                $fixture.closeCount++
                if ($case -eq 'idle') { $fixture.removed=$true }
            } elseif ($Node.attributes.kind -eq 'confirm') {
                $fixture.confirmCount++
                if ($case -ne 'cancelled') { $fixture.removed=$true }
            } else { throw 'Unexpected cleanup click' }
        }
        function Clear-LeanTTYAppLogs {}
        function Get-LeanTTYAppLogs { if ($fixture.removed) { return 'Tab removed: tab-test' }; return '' }
        $failure = ''
        try { Close-AgentTestTab } catch { $failure=$_.Exception.Message }
        if ($case -in @('idle','confirm-en','confirm-zh')) {
            Assert-Gate ($failure -eq '' -and -not $script:isolatedTabCreated -and
                $result.resources.tabCleanup.originalTabsRestored -and $fixture.closeCount -eq 1 -and
                $fixture.confirmCount -eq [int]($case -ne 'idle')) 'Owned closure or restoration not proved'
        } else {
            Assert-Gate ($failure.Length -gt 0 -and $script:isolatedTabCreated) 'Unsafe/unknown closure was accepted'
            if ($case -in @('wrong-owner','changed-process')) { Assert-Gate ($fixture.closeCount -eq 0) 'Wrong owner received close' }
            if ($case -in @('other-dialog','confirmation-owner-changed')) { Assert-Gate ($fixture.confirmCount -eq 0) 'Unrelated dialog was accepted' }
            Assert-Gate ($fixture.closeCount -le 1 -and $fixture.confirmCount -le 1) 'Unknown close/confirmation was repeated'
        }
    }
}
foreach ($readFails in @($false,$true)) {
    Test-Gate "failed-trust-known-host-read-only-audit-$readFails" {
        $knownHostCleanupAttempted=$true; $knownHostRemoved=$false
        $cleanupFailures=[Collections.Generic.List[string]]::new()
        $script:fault=$(if ($readFails) {'known-host-read'} else {''})
        $audit=$deviceAst.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and
            $n.Extent.Text.StartsWith('if ($knownHostCleanupAttempted -and -not $knownHostRemoved)')},$true)
        . ([scriptblock]::Create($audit.Extent.Text))
        Assert-Gate ($knownHostRemoved -eq (-not $readFails) -and $cleanupFailures.Count -eq [int]$readFails -and
            @($script:trace | Where-Object {$_ -like 'local:*' -or $_ -in @('text','enter','ctrl-d')}).Count -eq 0) 'Unknown session received input or absence verdict was guessed'
    }
}
# Read each caller's real allowlist: this repair must retain the original HAP,
# without accepting product-source or dependency changes as harness-only.
. (Join-Path $PSScriptRoot 'candidate-store.ps1')
foreach ($caller in @('verify-agent-compatibility-pc.ps1', 'verify-mosh-pc.ps1',
        'verify-ssh-auth-pc.ps1', 'verify-terminal-search-pc.ps1',
        'verify-long-task-notification-pc.ps1')) {
    Test-Gate "agent-repair-candidate-boundary-$caller" {
        $callerAst = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot $caller), [ref]$null, [ref]$null)
        $command = $callerAst.Find({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Assert-LeanTTYCandidateHarnessCompatibility'
        }, $true)
        $parameter = @($command.CommandElements | Where-Object {
            $_ -is [Management.Automation.Language.CommandParameterAst] -and
            $_.ParameterName -eq 'AllowedHarnessPaths'
        })
        Assert-Gate ($parameter.Count -eq 1) 'Caller has no unique harness allowlist'
        $index = $command.CommandElements.IndexOf($parameter[0])
        $allowed = $command.CommandElements[$index + 1].SafeGetValue()
        Assert-LeanTTYHarnessOnlyPaths -AllowedPaths $allowed -ChangedPaths @(
            'docs/design/agent-tui-compatibility.md', 'docs/next-work.md',
            'tools/device-regression.ps1', 'tools/test-device-regression.ps1',
            'tools/test-agent-ssh-gate.ps1', 'tools/test-agent-compatibility.ps1',
            'tools/verify-agent-compatibility-pc.ps1', 'tools/verify-mosh-pc.ps1',
            'tools/verify-ssh-auth-pc.ps1', 'tools/verify-terminal-search-pc.ps1',
            'tools/verify-long-task-notification-pc.ps1')
        foreach ($productPath in @('entry/src/main/ets/pages/Index.ets', 'leantty_ssh/Cargo.lock')) {
            $rejected = $false
            try { Assert-LeanTTYHarnessOnlyPaths -AllowedPaths $allowed -ChangedPaths @($productPath) }
            catch { $rejected = $true }
            Assert-Gate $rejected 'Product inputs were accepted as harness-only'
        }
    }
}
foreach ($case in @('same-web-reindex', 'replaced-web', 'other-window', 'missing-web',
        'missing-id', 'duplicate-web', 'duplicate-terminal', 'post-input-owner-loss')) {
    Test-Gate "host-key-caller-context-$case" {
        # Keep the actual Focus -> Connect -> shared text guard. Only layout
        # observations and device effects are synthetic; no actual input occurs.
        . (Join-Path $PSScriptRoot 'device-regression.ps1')
        foreach ($name in @('Focus-TerminalInput', 'Connect-AgentServer')) {
            . ([scriptblock]::Create($functionSources[$name]))
        }
        function New-ContextLayout([bool]$Changed) {
            $leaf = [pscustomobject]@{ attributes = [pscustomobject]@{
                type='textField'; hint='Terminal input'; focused='true'; hostWindowId='1'
                hierarchy=$(if ($Changed) { 'ROOT1,1,2' } else { 'ROOT1,0,0,2' })
                accessibilityId=$(if ($Changed) { 'virtual-new' } else { 'virtual-old' })
                bounds='[10,10][30,30]'
            }; children=@() }
            $web = [pscustomobject]@{ attributes = [pscustomobject]@{
                type='Web'; hostWindowId='1'; accessibilityId='native-web'
                hierarchy=$(if ($Changed) { 'ROOT1,1' } else { 'ROOT1,0' })
            }; children=@($leaf) }
            if ($Changed) {
                switch ($case) {
                    'replaced-web' { $web.attributes.accessibilityId = 'replacement' }
                    'other-window' { $web.attributes.hostWindowId = '2'; $leaf.attributes.hostWindowId = '2' }
                    'missing-web' { $web.attributes.type = 'Column' }
                    'missing-id' { $web.attributes.accessibilityId = '' }
                    'duplicate-terminal' {
                        $web.children += [pscustomobject]@{attributes=@{
                            type='textField'; hint='Terminal input'; focused='false'
                        }; children=@()}
                    }
                }
            }
            $layout = [pscustomobject]@{attributes=@{}; children=@($web)}
            if ($Changed -and $case -eq 'duplicate-web') {
                $layout.children += [pscustomobject]@{attributes=@{
                    type='Web'; hostWindowId='1'; accessibilityId='native-web'
                }; children=@()}
            }
            return $layout
        }
        $script:layoutReads = 0
        function Get-FullLayout { return (New-ContextLayout $false) }
        function Click-Node { $script:trace.Add('focus-click') }
        function Clear-LeanTTYAppLogs { $script:trace.Add('clear-logs') }
        function Start-Sleep { }
        function Invoke-LeanTTYSerializedUiTest { param($Action) & $Action }
        function Get-HdcUiLayout {
            $script:layoutReads++
            $layout = New-ContextLayout $true
            if ($case -eq 'post-input-owner-loss' -and $script:layoutReads -eq 2) {
                $layout.children[0].attributes.accessibilityId = 'replacement'
            }
            return $layout
        }
        function Invoke-HdcChecked { $script:trace.Add('text-dispatch') }
        function Invoke-LeanTTYDeviceKey { $script:trace.Add('enter') }
        if ($case -eq 'same-web-reindex') {
            Connect-AgentServer -Stage 'context'
            Assert-Gate ($script:agentSshBoundary -eq 'shell-ready' -and
                @($script:trace | Where-Object { $_ -eq 'text-dispatch' }).Count -eq 1 -and
                @($script:trace | Where-Object { $_ -eq 'enter' }).Count -eq 1) 'Same native owner must confirm exactly once'
        } else {
            Expect-GateError { Connect-AgentServer -Stage 'context' } 'text target|intended target'
            $expectedDispatches = if ($case -eq 'post-input-owner-loss') { 1 } else { 0 }
            Assert-Gate (@($script:trace | Where-Object { $_ -eq 'text-dispatch' }).Count -eq $expectedDispatches -and
                -not ($script:trace -contains 'enter') -and -not ($script:trace -contains 'ctrl-c') -and
                $script:agentSshBoundary -eq 'unconfirmed') 'Owner loss must stop without retry, cancellation or Enter'
        }
    }
}
Test-Gate 'focus-result-keeps-node-and-layout-from-one-observation' {
    . ([scriptblock]::Create($functionSources['Focus-TerminalInput']))
    $leaf = @{attributes=@{focused='true'}}
    $layout = @{children=@($leaf)}
    function Get-FullLayout { return $layout }
    function Get-LeanTTYTerminalInputNodes { return $leaf }
    function Click-Node { }
    function Start-Sleep { }
    $context = Focus-TerminalInput -Name 'paired'
    Assert-Gate ([object]::ReferenceEquals($context.node, $leaf) -and
        [object]::ReferenceEquals($context.layout, $layout)) 'Context must preserve the actual node and its containing layout'
}
Test-Gate 'local-command-preparation-passes-the-paired-context' {
    . ([scriptblock]::Create($functionSources['Submit-LocalCommand']))
    $paired = @{node=@{attributes=@{hint='Terminal input'}};layout=@{controlled='layout'}}
    function Focus-TerminalInput { return $paired }
    function Submit-LeanTTYDeviceCommand {
        param($InputNodeProvider, $InputPreparer)
        Assert-Gate ($null -ne $InputPreparer) 'Local caller must retain context through its input preparer'
        $context = & $InputNodeProvider 1
        & $InputPreparer $context 1
    }
    function Invoke-LeanTTYDeviceText {
        param($Text, $InputNode, $InputLayout)
        Assert-Gate ($Text -ceq 'help ssh' -and [object]::ReferenceEquals($InputNode, $paired.node) -and
            [object]::ReferenceEquals($InputLayout, $paired.layout)) 'Local input discarded or mismatched context'
        $script:trace.Add('paired-input')
    }
    Submit-LocalCommand -Command 'help ssh' -Stage 'paired'
    Assert-Gate ($script:trace -contains 'paired-input') 'Local caller never dispatched through preparation'
}
Test-Gate 'every-agent-terminal-text-call-supplies-layout' {
    $calls = @($deviceAst.FindAll({param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Invoke-LeanTTYDeviceText'
    }, $true))
    foreach ($call in $calls) {
        # Search is a native field with its own operation-scoped identity.
        $owner = $call.Parent
        while ($null -ne $owner -and $owner -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $owner = $owner.Parent }
        if ($owner.Name -eq 'Assert-AgentSearch') { continue }
        $parameters = @($call.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] })
        Assert-Gate (@($parameters | Where-Object ParameterName -eq 'InputLayout').Count -eq 1) "Terminal caller omitted layout: $($owner.Name)"
    }
}
foreach ($lineEnding in @('LF', 'CRLF')) {
    foreach ($identityCase in @('valid', 'query-failed', 'missing-output', 'extra-output', 'malformed-hash',
            'unknown-pi', 'unknown-tmux', 'missing-pi', 'missing-tmux', 'changed-extension', 'changed-config', 'missing-config')) {
        Test-Gate "public-identity-$lineEnding-$identityCase" {
            # Keep the actual owner and classifier. Replace only WSL and file IO;
            # the separate WSL probe proves the real Bash interpretation.
            $source = $functionSources['Get-AgentTmuxNotificationEnvironment'].Replace("`r`n", "`n")
            if ($lineEnding -ceq 'CRLF') { $source = $source.Replace("`n", "`r`n") }
            . ([scriptblock]::Create($source))
            $inventory = @{tools=@{pi=@{version='0.84.4'}}}
            if ($identityCase -ceq 'unknown-pi') { $inventory.tools.pi.version = 'future' }
            if ($identityCase -ceq 'missing-pi') { $inventory.tools.pi.version = '' }
            $script:identityQueries = 0
            $script:configReads = 0
            function wsl.exe {
                $script:identityQueries++
                Assert-Gate ($args.Count -eq 4 -and ($args[0..2] -join '|') -ceq '--exec|bash|-lc') 'Public identity query changed execution scope'
                if ([string]$args[3] -match "`r" -or $identityCase -ceq 'query-failed') {
                    $global:LASTEXITCODE = 1
                    return
                }
                $global:LASTEXITCODE = 0
                if ($identityCase -ceq 'missing-output') { return 'tmux 3.6' }
                $version = switch ($identityCase) { 'unknown-tmux' { 'tmux future' }; 'missing-tmux' { '' }; default { 'tmux 3.6' } }
                $hash = switch ($identityCase) {
                    'malformed-hash' { 'invalid' }
                    'changed-extension' { 'a' * 64 }
                    default { '70e4333e09ce00d546c116fd2e918abf7616c70b5da6e88ba8ee21a326afd483' }
                }
                @($version, "$hash  /public/notify.ts")
                if ($identityCase -ceq 'extra-output') { 'unexpected third line' }
            }
            function Get-FileHash {
                param($LiteralPath, $Algorithm)
                $script:configReads++
                Assert-Gate ($LiteralPath -ceq (Join-Path $fixtureDirectory 'tmux.conf') -and $Algorithm -ceq 'SHA256') 'Public identity must hash the owned run config'
                if ($identityCase -ceq 'missing-config') { throw '[harness] controlled missing config' }
                @{Hash=$(if ($identityCase -ceq 'changed-config') { 'b' * 64 } else { 'c751ee4a8029da7cd247a32c1962d2195d2e801c448f5bc9a067c6811c323dd6' })}
            }
            if ($identityCase -in @('query-failed', 'missing-output', 'extra-output', 'malformed-hash', 'missing-config')) {
                Expect-GateError { Get-AgentTmuxNotificationEnvironment } '\[harness\]'
                Assert-Gate ($script:configReads -eq $(if ($identityCase -ceq 'missing-config') { 1 } else { 0 })) 'Failed public query must not proceed to fixture identity'
            } else {
                $publicEnvironment = Get-AgentTmuxNotificationEnvironment
                $outer = @{boundary='remote-outer-pty-not-client-receipt';complete=$true;childExitCode=0;bytes=100;attentionCount=0;afterHiddenCount=0;checkpoints=@{'before-minimize'=0;'after-hidden'=0}}
                $assessment = Resolve-LeanTTYAgentNotificationAssessment -Agent pi -Mode tmux -NativeAttentionObserved $true `
                    -SystemNotificationCompleted $false -AgentChildExitCode 0 `
                    -NotificationFailure '[unknown] Agent inner attention observed without outer attention' `
                    -UpstreamEnvironment $publicEnvironment -OuterObservation $outer
                if ($identityCase -ceq 'valid') {
                    Assert-Gate ($assessment.status -ceq 'not-applicable' -and $assessment.classification -ceq 'upstream-not-forwarded' -and
                        $assessment.systemNotification -ceq 'not-exercised') 'Exact identities must preserve the existing limitation, not claim a notification pass'
                } else {
                    Assert-Gate ($assessment.status -ceq 'failed') 'Unknown or missing identity must not receive an upstream exemption'
                }
                Assert-Gate ($script:configReads -eq 1) 'Owned config must be read exactly once'
            }
            Assert-Gate ($script:identityQueries -eq 1) 'Public identity failure must never trigger an automatic retry'
        }
    }
}
$report = [ordered]@{
    scenario = 'agent-ssh-gate-fault-injection'; acceptanceEligible = $false
    startedAt = $startedAt.ToString('o'); completedAt = [DateTimeOffset]::UtcNow.ToString('o')
    powershellVersion = $PSVersionTable.PSVersion.ToString()
    harnessSha256 = (Get-FileHash -LiteralPath $devicePath).Hash
    testSha256 = (Get-FileHash -LiteralPath $PSCommandPath).Hash
    deviceCommands = 0; plannedModelRequests = 0; actualModelRequests = 0
    checks = @($checks)
    result = $(if (@($checks | Where-Object result -eq 'failed').Count -eq 0) { 'passed' } else { 'failed' })
}
if ($EvidencePath.Length -gt 0) { Write-LeanTTYAtomicJson -Path $EvidencePath -Value $report -Depth 10 }
if ($report.result -ne 'passed') { throw "Agent SSH gate regression failed: $(@($checks | Where-Object result -eq 'failed').Count)/$($checks.Count)" }
Write-Host "Agent SSH gate fault injection passed: $($checks.Count) cases; no device or model calls."
