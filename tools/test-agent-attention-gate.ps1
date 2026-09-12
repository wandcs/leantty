param([string]$HarnessPath = (Join-Path $PSScriptRoot 'verify-agent-compatibility-pc.ps1'))
$ErrorActionPreference = 'Stop'
$ast = [Management.Automation.Language.Parser]::ParseFile($HarnessPath, [ref]$null, [ref]$null)
foreach ($name in @('Assert-NotificationAndReturn', 'Get-AgentAttentionFailure', 'Hide-AgentNotificationWindow',
        'Start-AgentNotificationAfterHidden')) {
    $function = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if ($null -ne $function) { . ([scriptblock]::Create($function.Extent.Text)) }
}
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('leantty-attention-gate-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory | Out-Null
try {
    $capturePath = Join-Path $testDirectory 'qwen-tmux-notification.json'
    @{ childExitCode = 0; output = @{ nativeAttentionSignalObserved = $true } } |
        ConvertTo-Json | Set-Content -LiteralPath $capturePath
    $hdc = 'no-device'; $Target = 'no-device'; $appProcessId = '0'
    $wslToolPath = 'no-wsl'; $wslFixtureDirectory = 'no-fixture'
    $script:published = $false
    function Get-LeanTTYAppLogs {
        if ($script:published) { return 'Background BEL notification published: paneId=pane-1' }
        return ''
    }
    function wsl.exe { $global:LASTEXITCODE = 0 }
    $script:outer = $null
    function Get-AgentOuterAttention { return $script:outer }
    function Open-NotificationPanel { return @{} }
    function Get-LeanTTYLayoutNodes {
        return @{ attributes = @{ text = 'LeanTTY, A terminal needs your attention.' } }
    }
    function Click-Node { $script:returnClicked = $true }
    function Wait-AppLog { $script:returnObserved = $true }
    $failure = ''
    try { Assert-NotificationAndReturn -Stage controlled -CaptureResultPath $capturePath }
    catch { $failure = $_.Exception.Message }
    if ($failure -notmatch '^\[harness\].*outer') {
        throw "Inner-only attention must remain a harness evidence gap, received: $failure"
    }
    Write-Host 'Actual notification assertion rejects inner-only attribution.'
    foreach ($case in @(
        @{ count = 1; late = 0; pattern = '^\[harness\].*before minimize' },
        @{ count = 0; late = 0; pattern = '^\[unknown\].*without outer' },
        @{ count = 1; late = 1; pattern = '^\[unknown\].*client receipt' }
    )) {
        $script:outer = @{ checkpoints = @{ 'after-hidden' = 10 }; attentionCount = $case.count; afterHiddenCount = $case.late }
        $failure = ''
        try { Assert-NotificationAndReturn -Stage controlled -CaptureResultPath $capturePath }
        catch { $failure = $_.Exception.Message }
        if ($failure -notmatch $case.pattern) { throw "Incorrect attribution: $failure" }
    }
    $script:published = $true
    $script:returnClicked = $false; $script:returnObserved = $false
    $observation = @{}
    Assert-NotificationAndReturn -Stage controlled -CaptureResultPath $capturePath -Observation $observation
    if (-not $script:returnClicked -or -not $script:returnObserved -or $observation.outer.afterHiddenCount -ne 1) {
        throw 'Post-hide signal must still require the actual generic-card and return observations'
    }
    $script:outer.afterHiddenCount = 0
    try {
        Assert-NotificationAndReturn -Stage controlled -CaptureResultPath $capturePath
        throw 'Pre-hide signal with publication must not bypass ordering'
    } catch {
        if ($_.Exception.Message -notmatch '^\[harness\].*before minimize') { throw }
    }
    $script:trace = [Collections.Generic.List[string]]::new()
    function Get-FullLayout { return @{} }
    function Get-MinimizeButton { return @{} }
    function Get-AgentOuterAttention { param($CaptureResultPath, $Action); $script:trace.Add($Action); return @{} }
    function Click-Node { $script:trace.Add('minimize') }
    function Wait-AppLog { param($Pattern); $script:trace.Add($Pattern) }
    Hide-AgentNotificationWindow -Stage controlled -CaptureResultPath $capturePath -Observation @{}
    if (($script:trace -join '|') -ne 'before-minimize|minimize|Window visibility changed: visible=false|after-hidden') {
        throw 'Byte barriers must bracket the action and actual window-hidden observation'
    }
    $script:trace.Clear()
    function Wait-AppLog { throw '[harness] hidden event unavailable' }
    try {
        Hide-AgentNotificationWindow -Stage controlled -CaptureResultPath $capturePath -Observation @{}
        throw 'Missing hidden event must stop the observer'
    } catch {
        if ($_.Exception.Message -ne '[harness] hidden event unavailable') { throw }
    }
    if ($script:trace -contains 'after-hidden') { throw 'Missing hidden event cannot create a hidden barrier' }
    function Wait-File { $script:trace.Add('wait-ready') }
    function Set-AgentStartGate { param($CaptureResultPath, $Action); $script:trace.Add($Action) }
    function Wait-AppLog { param($Pattern); $script:trace.Add($Pattern) }
    $script:trace.Clear()
    Start-AgentNotificationAfterHidden -Agent pi -Stage controlled -CaptureResultPath $capturePath -Observation @{}
    if (($script:trace -join '|') -ne 'wait-ready|ready|before-minimize|minimize|Window visibility changed: visible=false|after-hidden|release') {
        throw 'Agent workload must be released only after actual hidden-window evidence'
    }
    $script:trace.Clear()
    Start-AgentNotificationAfterHidden -Agent opencode -Stage controlled -CaptureResultPath $capturePath -Observation @{}
    if (($script:trace -join '|') -ne 'before-minimize|minimize|Window visibility changed: visible=false|after-hidden') {
        throw 'OpenCode interactive setup must not wait for an argv-prompt gate'
    }
    foreach ($failAt in @('ready', 'hidden', 'release')) {
        $script:trace.Clear()
        function Set-AgentStartGate {
            param($CaptureResultPath, $Action)
            $script:trace.Add($Action)
            if ($Action -eq $failAt) { throw "[harness] controlled $Action failure" }
        }
        function Wait-AppLog {
            if ($failAt -eq 'hidden') { throw '[harness] hidden event unavailable' }
        }
        $failure = ''
        try { Start-AgentNotificationAfterHidden -Agent pi -Stage controlled -CaptureResultPath $capturePath -Observation @{} }
        catch { $failure = $_.Exception.Message }
        if ($failure -notmatch '^\[harness\].*startup failed' -or $script:trace[-1] -ne 'cancel' -or
            ($failAt -ne 'release' -and $script:trace -contains 'release')) {
            throw 'Failed startup must cancel once, stop the scenario and never release before hidden'
        }
    }
    $missingInner = Get-AgentAttentionFailure -Outer @{ checkpoints = @{ 'after-hidden' = 0 }; attentionCount = 0; afterHiddenCount = 0 } `
        -InnerObserved $false -InnerAvailable $false
    if ($missingInner -notmatch '^\[harness\].*absence of emission is unproved') { throw 'Missing inner evidence must not authorize no-emission applicability' }
    . (Join-Path $PSScriptRoot 'candidate-store.ps1')
    foreach ($caller in @('verify-agent-compatibility-pc.ps1', 'verify-ssh-auth-pc.ps1')) {
        $callerAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $caller), [ref]$null, [ref]$null)
        $command = $callerAst.Find({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Assert-LeanTTYCandidateHarnessCompatibility'
        }, $true)
        $parameter = @($command.CommandElements | Where-Object {
            $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'AllowedHarnessPaths'
        })
        $allowed = $command.CommandElements[$command.CommandElements.IndexOf($parameter[0]) + 1].SafeGetValue()
        Assert-LeanTTYHarnessOnlyPaths -AllowedPaths $allowed -ChangedPaths @(
            'tools/test-agent-attention-gate.ps1', 'tools/agent-compatibility/capture_notification.sh',
            'tools/agent-compatibility/start_gate.py', 'tools/agent-compatibility/test_start_gate.py',
            'tools/agent-compatibility/observe_attention.py', 'tools/agent-compatibility/attention_observer_probe.py',
            'tools/agent-compatibility/test_observe_attention.py', 'tools/agent-compatibility/test_observe_attention_pty.py')
        $rejected = $false
        try { Assert-LeanTTYHarnessOnlyPaths -AllowedPaths $allowed -ChangedPaths @('leantty_ssh/Cargo.lock') }
        catch { $rejected = $true }
        if (-not $rejected) { throw 'Observer admission must not accept a product dependency change' }
    }
    Write-Host 'Agent attention gate: 16 actual-owner cases passed; no device or model requests.'
} finally {
    Remove-Item -LiteralPath $testDirectory -Recurse -Force
}
