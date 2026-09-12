param([string]$HarnessPath = (Join-Path $PSScriptRoot 'verify-agent-compatibility-pc.ps1'))
$ErrorActionPreference = 'Stop'
$ast = [Management.Automation.Language.Parser]::ParseFile($HarnessPath, [ref]$null, [ref]$null)
foreach ($name in @('Assert-NotificationAndReturn', 'Get-AgentAttentionFailure', 'Hide-AgentNotificationWindow',
        'Start-AgentNotificationAfterHidden', 'Invoke-AgentFocusReadinessProbe', 'Get-AgentNotificationEpisode')) {
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
    $hdc = 'no-device'; $Target = 'no-device'; $appProcessId = '101'
    $wslToolPath = 'no-wsl'; $wslFixtureDirectory = 'no-fixture'
    $hiddenLog = '09-12 12:00:00.100 101 101 I A00001/com.leantty.app/EntryAbility: Window visibility changed: visible=false'
    $attentionLog = '09-12 12:00:00.101 101 101 I A00001/com.leantty.app/AppViewModel: Pane attention set: pane-12-1'
    $publishedLog = '09-12 12:00:00.102 101 101 I A00001/com.leantty.app/BackgroundBellNotification: Background BEL notification published: paneId=pane-12-1'
    $validLogs = @($hiddenLog, $attentionLog, $publishedLog) -join "`n"
    $script:logs = ''
    function Get-LeanTTYAppLogs { return $script:logs }
    function wsl.exe { $global:LASTEXITCODE = 0 }
    $script:outer = $null
    function Get-AgentOuterAttention { return $script:outer }
    function Open-NotificationPanel { return @{} }
    $script:cardText = 'LeanTTY, A terminal needs your attention.'
    function Get-LeanTTYLayoutNodes { return @{ attributes = @{ text = $script:cardText } } }
    function Click-Node { $script:returnClicked = $true }
    $script:returnPane = 'pane-12-1'
    function Wait-AppLog {
        param($Pattern)
        if ("Background BEL return applied: paneId=$script:returnPane" -notmatch $Pattern) {
            throw '[harness] Expected source Pane return not observed'
        }
        $script:returnObserved = $true
    }
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
        $script:outer = @{ checkpoints = @{ 'before-minimize' = 0; 'after-hidden' = 10 }
            attentionCount = $case.count; afterHiddenCount = $case.late; afterMinimizeStartCount = $case.late }
        $failure = ''
        try { Assert-NotificationAndReturn -Stage controlled -CaptureResultPath $capturePath }
        catch { $failure = $_.Exception.Message }
        if ($failure -notmatch $case.pattern) { throw "Incorrect attribution: $failure" }
    }
    $script:logs = $validLogs
    $script:returnClicked = $false; $script:returnObserved = $false
    $observation = @{ windowHidden = $true }
    Assert-NotificationAndReturn -Stage controlled -CaptureResultPath $capturePath -Observation $observation
    if (-not $script:returnClicked -or -not $script:returnObserved -or $observation.outer.afterHiddenCount -ne 1) {
        throw 'Post-hide signal must still require the actual generic-card and return observations'
    }
    $script:outer.afterHiddenCount = 0
    $script:outer.afterMinimizeStartCount = 1
    $observation = @{ windowHidden = $true }
    Assert-NotificationAndReturn -Stage controlled -CaptureResultPath $capturePath -Observation $observation
    if ($observation.deviceEpisode.paneId -cne 'pane-12-1' -or $observation.outer.afterHiddenCount -ne 0) {
        throw 'A complete device episode must qualify a signal before the later host checkpoint'
    }
    # HarmonyOS may attach HiTrace metadata to asynchronous publication logs.
    $script:logs = $validLogs.Replace(': Background BEL', ': [a92ab143765732c 0 0]Background BEL')
    Assert-NotificationAndReturn -Stage controlled -CaptureResultPath $capturePath -Observation @{ windowHidden=$true }
    $script:logs = $validLogs
    foreach ($invalidLogs in @(
        '', $attentionLog, $publishedLog,
        (@($attentionLog, $publishedLog) -join "`n"),
        (@($hiddenLog, $publishedLog) -join "`n"),
        (@($publishedLog, $hiddenLog, $attentionLog) -join "`n"),
        (@($hiddenLog, $publishedLog, $attentionLog) -join "`n"),
        ($validLogs.Replace($attentionLog, $attentionLog.Replace('pane-12-1', 'pane-12-10'))),
        (@($hiddenLog, $attentionLog, $attentionLog.Replace('pane-12-1', 'pane-13'), $publishedLog) -join "`n"),
        ($validLogs + "`n" + $publishedLog),
        ($validLogs.Replace($attentionLog, $hiddenLog.Replace('visible=false', 'visible=true') + "`n" + $attentionLog)),
        ($validLogs + "`n" + $hiddenLog.Replace('visible=false', 'visible=true')),
        ($validLogs + "`n" + $publishedLog.Replace('published: paneId=pane-12-1', 'canceled')),
        ($validLogs + "`n" + $attentionLog.Replace('set:', 'cleared:')),
        ($validLogs.Replace('101 101', '102 102')),
        ($validLogs.Replace('101 101', '101 102')),
        ($validLogs.Replace('/BackgroundBellNotification:', '/TerminalBridge:')),
        ($validLogs.Replace(': Background BEL', ': [not-a-trace]Background BEL')),
        ($validLogs.Replace($publishedLog, 'terminal output: ' + $publishedLog)),
        ($validLogs.Replace('paneId=pane-12-1', 'paneId=pane-12-1-extra'))
    )) {
        $script:logs = $invalidLogs
        $failure = ''
        try { Assert-NotificationAndReturn -Stage controlled -CaptureResultPath $capturePath -Observation @{ windowHidden=$true } }
        catch { $failure = $_.Exception.Message }
        if ($failure -notmatch '^\[unknown\].*device episode') { throw "Invalid episode qualified: $failure" }
    }
    $script:logs = $validLogs
    foreach ($missing in @('before-minimize', 'after-hidden', 'windowHidden', 'afterMinimizeStartCount')) {
        $savedOuter = $script:outer
        $script:outer = @{ attentionCount=1; afterHiddenCount=0; afterMinimizeStartCount=1
            checkpoints=@{ 'before-minimize'=0; 'after-hidden'=10 } }
        $observation = @{ windowHidden=$true }
        if ($missing -eq 'windowHidden') { $observation.Clear() }
        elseif ($missing -eq 'afterMinimizeStartCount') { $script:outer.Remove($missing) }
        else { $script:outer.checkpoints.Remove($missing) }
        $failure = ''
        try { Assert-NotificationAndReturn -Stage controlled -CaptureResultPath $capturePath -Observation $observation }
        catch { $failure = $_.Exception.Message }
        if ($failure -notmatch '^\[(harness|unknown)\]') { throw "Missing $missing must not qualify: $failure" }
        $script:outer = $savedOuter
    }
    foreach ($wrongPane in @('pane-12', 'pane-12-10', 'pane-13')) {
        $script:returnPane = $wrongPane
        $failure = ''
        try { Assert-NotificationAndReturn -Stage controlled -CaptureResultPath $capturePath -Observation @{ windowHidden=$true } }
        catch { $failure = $_.Exception.Message }
        if ($failure -ne '[harness] Expected source Pane return not observed') { throw "Wrong return qualified: $failure" }
    }
    $script:returnPane = 'pane-12-1'
    $script:cardText = 'LeanTTY, qwen A terminal needs your attention.'
    $failure = ''
    try { Assert-NotificationAndReturn -Stage controlled -CaptureResultPath $capturePath -Observation @{ windowHidden=$true } }
    catch { $failure = $_.Exception.Message }
    if ($failure -notmatch '^\[privacy\]') { throw 'A valid episode cannot bypass notification privacy' }
    $script:cardText = 'LeanTTY, A terminal needs your attention.'
    $script:outer.afterMinimizeStartCount = 0
    try {
        Assert-NotificationAndReturn -Stage controlled -CaptureResultPath $capturePath -Observation @{ windowHidden=$true }
        throw 'Pre-hide signal with publication must not bypass ordering'
    } catch {
        if ($_.Exception.Message -notmatch '^\[harness\].*before minimize') { throw }
    }
    $script:trace = [Collections.Generic.List[string]]::new()
    function Get-FullLayout { return @{} }
    function Get-MinimizeButton { return @{} }
    function Clear-LeanTTYAppLogs { $script:trace.Add('clear-logs') }
    function Get-AgentOuterAttention { param($CaptureResultPath, $Action); $script:trace.Add($Action); return @{} }
    function Click-Node { $script:trace.Add('minimize') }
    function Wait-AppLog { param($Pattern); $script:trace.Add($Pattern) }
    Hide-AgentNotificationWindow -Stage controlled -CaptureResultPath $capturePath -Observation @{}
    if (($script:trace -join '|') -ne 'clear-logs|before-minimize|minimize|Window visibility changed: visible=false|after-hidden') {
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
    if (($script:trace -join '|') -ne 'wait-ready|ready|clear-logs|before-minimize|minimize|Window visibility changed: visible=false|after-hidden|release') {
        throw 'Agent workload must be released only after actual hidden-window evidence'
    }
    $script:trace.Clear()
    Start-AgentNotificationAfterHidden -Agent opencode -Stage controlled -CaptureResultPath $capturePath -Observation @{}
    if (($script:trace -join '|') -ne 'clear-logs|before-minimize|minimize|Window visibility changed: visible=false|after-hidden') {
        throw 'OpenCode interactive setup must not wait for an argv-prompt gate'
    }
    function Wait-AgentTuiReady {
        param($CaptureResultPath, [switch]$RequireFocusReporting)
        if (-not $RequireFocusReporting) { throw 'Qwen readiness must require focus reporting' }
        $script:trace.Add('focus-ready')
    }
    $script:trace.Clear()
    $focusObservation = @{}
    Start-AgentNotificationAfterHidden -Agent qwen -Stage controlled -CaptureResultPath $capturePath -Observation $focusObservation
    if (($script:trace -join '|') -ne 'focus-ready|clear-logs|before-minimize|minimize|Window visibility changed: visible=false|after-hidden' -or
        $focusObservation.focusReportingReady -ne $true) {
        throw 'Qwen must enable native focus reporting before the real minimize action, without an exec gate'
    }
    function Wait-AgentTuiReady { throw '[harness] native focus reporting unavailable' }
    $script:trace.Clear()
    $failure = ''
    try { Start-AgentNotificationAfterHidden -Agent qwen -Stage controlled -CaptureResultPath $capturePath -Observation @{} }
    catch { $failure = $_.Exception.Message }
    if ($failure -notmatch '^\[harness\].*startup failed' -or $script:trace.Count -ne 0) {
        throw 'Missing native focus readiness must stop before minimizing, without inventing a hidden state'
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
            'AGENTS.md', 'tools/agent-compatibility-policy.ps1',
            'tools/test-agent-attention-gate.ps1', 'tools/agent-compatibility/capture_notification.sh',
            'tools/agent-compatibility/start_gate.py', 'tools/agent-compatibility/test_start_gate.py',
            'tools/agent-compatibility/observe_attention.py', 'tools/agent-compatibility/attention_observer_probe.py',
            'tools/agent-compatibility/test_observe_attention.py', 'tools/agent-compatibility/test_observe_attention_pty.py')
        $rejected = $false
        try { Assert-LeanTTYHarnessOnlyPaths -AllowedPaths $allowed -ChangedPaths @('leantty_ssh/Cargo.lock') }
        catch { $rejected = $true }
        if (-not $rejected) { throw 'Observer admission must not accept a product dependency change' }
    }
    # Execute the actual readiness function, not just its caller's mock.
    $readyFunction = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-AgentTuiReady'
    }, $true)
    . ([scriptblock]::Create($readyFunction.Extent.Text))
    $livePath = Join-Path $testDirectory 'qwen-tmux-notification-live.json'
    foreach ($counts in @(@{ enable=1; disable=0; ready=$true }, @{ enable=0; disable=0; ready=$false },
            @{ enable=1; disable=1; ready=$false }, @{ enable=2; disable=1; ready=$false })) {
        @{ output=@{ alternateScreen=@{enterCount=1}; focusReporting=@{enableCount=$counts.enable;disableCount=$counts.disable} } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $livePath
        $ready = $true
        try { Wait-AgentTuiReady -CaptureResultPath $capturePath -RequireFocusReporting }
        catch { $ready = $false }
        if ($ready -ne $counts.ready) { throw 'Alternate screen or ambiguous counters do not establish native focus readiness' }
    }
    Wait-AgentTuiReady -CaptureResultPath $capturePath # Existing non-focus callers retain their TUI gate.
    function Wait-AgentTuiReady { $script:phase = 'ready' }
    function Clear-LeanTTYAppLogs {}
    function Get-FullLayout { return @{} }
    function Get-MinimizeButton { return @{} }
    function Click-Node { $script:phase = 'hidden' }
    function Restore-AgentAppForContinuation {
        $script:phase = 'restored'; $script:restoreCount++
        if ($script:probeFailure -eq 'restore') { throw '[environment] controlled restore failure' }
    }
    function Wait-AppLog {
        if ($script:probeFailure -eq 'visibility') { throw '[harness] controlled visibility failure' }
    }
    function wsl.exe {
        $global:LASTEXITCODE = 0
        $outCount = if ($script:phase -ne 'ready' -and $script:probeFailure -ne 'focus-out') { 1 } else { 0 }
        $inCount = if ($script:phase -eq 'restored' -and $script:probeFailure -ne 'focus-in') { 1 } else { 0 }
        @{ input=@{focusReporting=@{inCount=$inCount;outCount=$outCount}} } |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $livePath
    }
    foreach ($case in @('', 'visibility', 'focus-out', 'focus-in', 'restore')) {
        $script:probeFailure = $case
        $script:restoreCount = 0
        $observed = @{}
        $failure = ''
        try { Invoke-AgentFocusReadinessProbe -Stage controlled -CaptureResultPath $capturePath -Observation $observed -TimeoutSeconds 1 }
        catch { $failure = $_.Exception.Message }
        if (($case -eq '' -and ($failure -ne '' -or -not $observed.focusOutObserved -or -not $observed.focusInObserved)) -or
            ($case -ne '' -and $failure -eq '') -or $script:restoreCount -ne 1) {
            throw "Focus probe must require both real transitions and restore after failure: case=$case failure=$failure"
        }
    }
    Write-Host 'Agent attention gate: actual-owner ordering, rejection and focus cases passed; no device or model requests.'
} finally {
    Remove-Item -LiteralPath $testDirectory -Recurse -Force
}
