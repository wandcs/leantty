param([string]$EvidencePath = '')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-tooling.ps1')
. (Join-Path $PSScriptRoot 'agent-compatibility-policy.ps1')
$devicePath = Join-Path $PSScriptRoot 'verify-agent-compatibility-pc.ps1'
$parseErrors = $null
$deviceAst = [Management.Automation.Language.Parser]::ParseFile(
    $devicePath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Agent harness has PowerShell parse errors' }
$functionSources = @{}
foreach ($name in @('Wait-AppLog', 'Connect-AgentServer', 'Disconnect-AgentServer', 'Stop-AgentTui', 'Confirm-AgentShellReady',
        'Invoke-AgentSelectedChecks', 'Invoke-AgentInteractionOnlyCheck',
        'Invoke-AgentProtocolInteractionCheck', 'Invoke-AgentModeCheck',
        'Invoke-Osc99CapabilityProbeCheck', 'Invoke-AgentSshPrerequisiteCheck',
        'Get-AgentTabState', 'Get-AgentOwnedTab', 'Close-AgentTestTab')) {
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
