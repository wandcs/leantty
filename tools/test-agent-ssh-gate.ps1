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
foreach ($name in @('Wait-AppLog', 'Connect-AgentServer', 'Disconnect-AgentServer',
        'Invoke-AgentSelectedChecks', 'Invoke-AgentInteractionOnlyCheck',
        'Invoke-AgentProtocolInteractionCheck', 'Invoke-AgentModeCheck',
        'Invoke-Osc99CapabilityProbeCheck', 'Invoke-AgentSshPrerequisiteCheck')) {
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
            $result = [pscustomobject]@{ server = @{ user = 'controlled' }; checks = @() }
            $Agents = @('codex', 'opencode')
            $Modes = @('direct', 'tmux')
            $Osc99CapabilityProbe = $false
            $InteractionOnlyProbe = $true
            $ProtocolInteractionProbe = $false
            $SshPrerequisiteProbe = $false
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
            function Invoke-LeanTTYDeviceText {
                $script:trace.Add('text')
                if ($script:fault -eq 'text') { throw '[environment] controlled-text-failure' }
            }
            function Invoke-LeanTTYDeviceKey {
                $script:trace.Add('enter')
                if ($script:fault -eq 'enter') { throw '[infrastructure] controlled-enter-failure' }
            }
            function Invoke-LeanTTYDeviceCtrlD { $script:trace.Add('ctrl-d') }
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
    Assert-Gate (($script:trace[0] -eq 'clear-logs') -and $script:agentSshBoundary -eq 'local') `
        'A fresh close observation must precede local cleanup permission'
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
