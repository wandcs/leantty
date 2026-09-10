param([string]$EvidencePath = '')
$ErrorActionPreference = 'Stop'
$checks = [Collections.Generic.List[object]]::new()
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Test-Case([string]$Name, [scriptblock]$Action) {
    try { & $Action; $checks.Add(@{name=$Name; result='passed'}) }
    catch { $checks.Add(@{name=$Name; result='failed'; failure=$_.Exception.Message}) }
}
. (Join-Path $PSScriptRoot 'device-regression.ps1')
. (Join-Path $PSScriptRoot 'notification-regression.ps1')

# Run the actual scenario's publication decisions with only its log channel replaced.
function Invoke-PublicationCase([bool]$Split, [bool]$Delayed, [bool]$WrongPane = $false) {
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'verify-background-bell-notification-pc.ps1'), [ref]$null, [ref]$null)
    $physical = @($ast.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.TryStatementAst]
    })[0]
    $statements = @($physical.Body.Statements)
    $first = -1; $last = -1
    for ($i = 0; $i -lt $statements.Count; $i++) {
        if ($statements[$i].Extent.Text.StartsWith('$publishPattern =')) { $first = $i }
        if ($statements[$i].Extent.Text.StartsWith('if ($ColdStale)')) { $last = $i - 1; break }
    }
    Assert-True ($first -ge 0 -and $last -gt $first) 'Missing real publication boundary'
    $fixture = @{reads=0}
    $needsSplit = $Split
    $result = @{firedPaneIds=@();publishedPaneId='';suppressedPaneId=''}
    $firedLogs = "ACCEPTANCE_BACKGROUND_BELL state=fired,paneId=pane-285-5`n"
    if ($Split) { $firedLogs += "ACCEPTANCE_BACKGROUND_BELL state=suppression-fired,paneId=pane-285-6`n" }
    $publication = 'Background BEL notification published: paneId=' + $(if ($WrongPane) {'pane-285-50'} else {'pane-285-5'})
    if ($Split) { $publication += "`nBackground BEL notification suppressed for current background episode: paneId=pane-285-6" }
    function Wait-RawAppLog {
        param([string]$Pattern)
        $fixture.reads++
        $sample = $firedLogs
        if (-not $Delayed -or $fixture.reads -gt 1) { $sample += $publication }
        if ($sample -notmatch $Pattern) { throw '[product] controlled wait expired' }
        return $sample
    }
    $code = (@($statements[$first..$last] | ForEach-Object { $_.Extent.Text }) -join "`n")
    . ([scriptblock]::Create($code))
    Assert-True ($result.publishedPaneId -ceq 'pane-285-5') 'Full Pane ID was truncated'
    if ($Split) { Assert-True ($result.suppressedPaneId -ceq 'pane-285-6') 'Suppressed Pane identity was aliased' }
}
Test-Case 'checked-log-channel-failure-is-not-product-timeout' {
    $hdc='unused';$Target='unused';$processId='1'
    function Invoke-HdcChecked { throw '[infrastructure] controlled log channel failure' }
    $caught = ''
    try { Wait-RawAppLog -Pattern 'published' | Out-Null } catch { $caught=$_.Exception.Message }
    Assert-True ($caught -match '^\[infrastructure\]') 'Log channel failure became a missing product publication'
}
Test-Case 'actual-wait-observes-later-publication' {
    $samples = [Collections.Generic.Queue[string]]::new()
    $samples.Enqueue('fired')
    $samples.Enqueue('published')
    function Get-RawAppLogs { return $samples.Dequeue() }
    function Start-Sleep {}
    $observed = Wait-RawAppLog -Pattern 'published'
    Assert-True ($observed -eq 'published' -and $samples.Count -eq 0) 'Wait returned at the earlier fired boundary'
}
Test-Case 'complete-pane-id' { Invoke-PublicationCase $false $false }
Test-Case 'async-publication-after-fired' { Invoke-PublicationCase $false $true }
Test-Case 'same-epoch-distinct-panes' { Invoke-PublicationCase $true $false }
Test-Case 'prefix-pane-must-not-qualify' {
    $rejected = $false
    try { Invoke-PublicationCase $false $false $true } catch {
        if ($_.Exception.Message -notmatch 'controlled wait expired') { throw }
        $rejected = $true
    }
    Assert-True $rejected 'Another Pane publication qualified'
}

# Exercise the real toggle/read-back/restoration functions, replacing only UI I/O.
function Invoke-PermissionStateCase([bool]$Initial, [bool]$Desired, [string]$Failure = '') {
    $notificationState = @{originalEnabled=$null;settingsOpen=$false;restored=$false;promptRejected=$false}
    $system = @{enabled=$Initial;clicks=0;opens=0;failure=$Failure}
    function Get-FullLayout {
        return @{attributes=@{}; children=@(@{children=@();attributes=@{type='Toggle';checkable='true';checked=([string]$system.enabled).ToLowerInvariant()}})}
    }
    function Open-NotificationSettings {
        $system.opens++
        $notificationState.settingsOpen = $true
        return Get-FullLayout
    }
    function Click-Node {
        $system.clicks++
        $system.enabled = -not $system.enabled
        if ($system.failure -eq 'click') { throw 'controlled-click-outcome-unknown' }
    }
    function Close-NotificationSettings {
        if ($system.failure -eq 'confirm') { throw 'controlled-confirm-failed' }
        if ($system.failure -eq 'persist') { $system.enabled = $Initial }
        $notificationState.settingsOpen = $false
    }
    function Ensure-LeanTTYVisible { return Get-FullLayout }
    function Start-Sleep {}
    $caught = $false
    try { [void](Set-NotificationEnabled -Enabled $Desired -Stage 'fixture') }
    catch { $caught = $true }
    Assert-True ($notificationState.originalEnabled -eq $Initial) 'Original permission was not captured before mutation'
    if ($Failure) { Assert-True $caught 'Failed setting was accepted' }
    else {
        Assert-True (-not $caught -and $system.enabled -eq $Desired) 'Requested setting was not verified'
        Assert-True ($system.opens -eq 2) 'Persisted setting was not independently reopened'
        Assert-True ($system.clicks -eq [int]($Initial -ne $Desired)) 'Already-correct setting was toggled'
    }
    $system.failure = ''
    # The visible settings surface is the same system state; close uses the real restore owner.
    $notificationState.settingsOpen = $false
    Restore-NotificationPermission
    Assert-True ($system.enabled -eq $Initial -and $notificationState.restored) 'Original notification setting was not restored'
}
foreach ($initial in @($false,$true)) {
    foreach ($desired in @($false,$true)) {
        Test-Case "permission-$initial-to-$desired-and-restore" { Invoke-PermissionStateCase $initial $desired }
    }
}
foreach ($failureMode in @('click','confirm','persist')) {
    Test-Case "permission-$failureMode-failure-retains-original" { Invoke-PermissionStateCase $false $true $failureMode }
}
Test-Case 'unknown-toggle-state-is-not-disabled' {
    $rejected = $false
    try { Get-NotificationToggle -Layout @{children=@();attributes=@{type='Toggle';checkable='true';checked='unknown'}} | Out-Null }
    catch { $rejected = $true }
    Assert-True $rejected 'Unknown system state became disabled'
}
Test-Case 'permission-modal-is-not-pane-loss' {
    $notificationState = @{promptRejected=$false}
    $probe = @{prompt=$true;clicks=0}
    $hdc='unused';$Target='unused'
    function Invoke-HdcChecked {}
    function Start-Sleep {}
    function Get-FullLayout {
        if ($probe.prompt) {
            return @{attributes=@{};children=@(
                @{children=@();attributes=@{text='允许“LeanTTY”向你发送通知？'}},
                @{children=@();attributes=@{text='不允许';clickable='true'}})}
        }
        return @{children=@();attributes=@{hint='Terminal input'}}
    }
    function Get-LeanTTYTerminalInputNodes {
        param($Layout)
        if ($Layout.attributes.hint -eq 'Terminal input') { return $Layout }
    }
    function Click-Node { $probe.clicks++; $probe.prompt=$false }
    Ensure-LeanTTYVisible -Stage 'cleanup' -DismissPermissionPrompt | Out-Null
    Assert-True ($notificationState.promptRejected -and $probe.clicks -eq 1 -and -not $probe.prompt) 'Modal was not rejected exactly once before Pane observation'
}
Test-Case 'visible-singleton-is-not-launched-again' {
    $notificationState = @{promptRejected=$false}
    function Get-FullLayout { return @{children=@();attributes=@{hint='Terminal input'}} }
    function Get-LeanTTYTerminalInputNodes { return @{attributes=@{}} }
    function Invoke-HdcChecked { throw 'Visible singleton was launched again' }
    Ensure-LeanTTYVisible -Stage 'already-visible' | Out-Null
}
Test-Case 'unrelated-dialog-is-never-rejected' {
    $notificationState = @{promptRejected=$false}
    $hdc='unused';$Target='unused'
    function Invoke-HdcChecked {}
    function Start-Sleep {}
    function Get-FullLayout { return @{children=@();attributes=@{text='Cancel';clickable='true'}} }
    function Get-LeanTTYTerminalInputNodes { return @() }
    function Click-Node { throw 'unsafe-unrelated-dialog-click' }
    $caught = ''
    try { Ensure-LeanTTYVisible -Stage 'unrelated' -DismissPermissionPrompt | Out-Null } catch { $caught=$_.Exception.Message }
    Assert-True ($caught -match '^\[environment\]' -and -not $notificationState.promptRejected) 'Unrelated dialog was not left untouched'
}
foreach ($cardCount in @(0,1)) {
    Test-Case "cleanup-observes-$cardCount-cards-without-cancel-log" {
        $hdc='unused';$Target='unused'
        function Ensure-LeanTTYVisible { return @{children=@();attributes=@{hint='Terminal input'}} }
        function Get-LeanTTYTerminalInputNodes { return @{children=@();attributes=@{hint='Terminal input'}} }
        function Click-Node {}
        function Open-NotificationPanel { return @{attributes=@{}} }
        function Get-LeanTTYNotificationCards { if ($cardCount -eq 1) { return @{attributes=@{}} } }
        function Invoke-LeanTTYSerializedUiTest {}
        $caught = $false
        try { Assert-NotificationCleanup | Out-Null } catch { $caught = $true }
        Assert-True ($caught -eq ($cardCount -gt 0)) 'Cleanup did not use direct notification absence'
    }
}
foreach ($scriptName in @('verify-background-bell-notification-pc.ps1','verify-background-bell-permission-pc.ps1')) {
    foreach ($failureMode in @('none','permission','awake')) {
        Test-Case "$scriptName-finally-$failureMode" {
            $ast = [Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $PSScriptRoot $scriptName), [ref]$null, [ref]$null)
            $owner = @($ast.EndBlock.Statements | Where-Object {
                $_ -is [Management.Automation.Language.TryStatementAst]
            })[0]
            $code = [Collections.Generic.List[string]]::new()
            foreach ($statement in $owner.Finally.Statements) {
                if ($statement.Extent.Text.StartsWith('$result.completedAt')) { break }
                $code.Add($statement.Extent.Text)
            }
            $result = @{failure='original-business-failure'}
            $notificationState = @{originalEnabled=$false;restored=$false;promptRejected=$false}
            $cleanupFailure='';$panelOpen=$false;$awakeLease=$true;$fixtureReady=$true;$splitRequested=$false
            $hdc='unused';$Target='unused';$probe=@{awakeRestores=0}
            function Restore-NotificationPermission {
                if ($failureMode -eq 'permission') { throw 'controlled-permission-restore-failure' }
                $notificationState.restored=$true
            }
            function Ensure-LeanTTYVisible { return @{attributes=@{}} }
            function Get-LeanTTYTerminalInputNodes { return @{attributes=@{}} }
            function Assert-NotificationCleanup { return @{attributes=@{}} }
            function Stop-LeanTTYDeviceAwakeLease {
                $probe.awakeRestores++
                if ($failureMode -eq 'awake') { throw 'controlled-awake-restore-failure' }
            }
            . ([scriptblock]::Create($code -join "`n"))
            Assert-True ($probe.awakeRestores -eq 1) 'Permission failure prevented screen-timeout restoration'
            Assert-True ($result.cleanup.result -eq $(if ($failureMode -eq 'none') {'passed'} else {'failed'})) 'Cleanup failure qualified as success'
            Assert-True ($result.failure -eq 'original-business-failure') 'Cleanup rewrote the original business failure'
        }
    }
}
# Check actual caller wiring as well as the shared state machine above.
foreach ($scriptName in @('verify-long-task-notification-pc.ps1','verify-agent-compatibility-pc.ps1')) {
    Test-Case "$scriptName-owns-permission-before-work" {
        $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot $scriptName) -Raw
        Assert-True ($source.Contains(". (Join-Path `$PSScriptRoot 'notification-regression.ps1')")) 'Caller does not reuse notification permission owner'
        $prepare = $source.IndexOf('Set-NotificationEnabled -Enabled $true')
        $work = $source.LastIndexOf($(if ($scriptName -match 'long-task') { '$result.workloads += Invoke-WorkloadScenario' } else { 'Invoke-AgentSelectedChecks' }))
        Assert-True ($prepare -gt 0 -and $prepare -lt $work) 'Notification work can start without verified permission'
        Assert-True ($source.Contains('Restore-NotificationPermission') -and $source.Contains('Assert-NotificationCleanup')) 'Caller lacks restoration or direct notification absence audit'
        Assert-True ($source.Contains('notificationPermission = $notificationState')) 'Result loses permission state on early failure'
    }
}
Test-Case 'shell-only-cannot-qualify-as-formal-or-send-model-request' {
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'verify-long-task-notification-pc.ps1'), [ref]$null, [ref]$null)
    $guard = @($ast.EndBlock.Statements | Where-Object { $_.Extent.Text.StartsWith('if ($ShellOnlyProbe -and') })
    Assert-True ($guard.Count -eq 1) 'Missing diagnostic-only shell probe guard'
    $ShellOnlyProbe=$true; $DiagnosticHap=$false; $caught=$false
    try { . ([scriptblock]::Create($guard[0].Extent.Text)) } catch { $caught=$true }
    Assert-True $caught 'Shell probe accepted as formal evidence'
    $body = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and
        $n.Extent.Text.StartsWith('if (-not $ShellOnlyProbe)') }, $true))
    Assert-True ($body.Count -eq 1) 'Missing bounded workload selector'
    $probe=@{calls=0}
    function Invoke-WorkloadScenario { $probe.calls++ }
    . ([scriptblock]::Create($body[0].Extent.Text))
    Assert-True ($probe.calls -eq 0) 'Shell-only probe invoked extra workloads'
}
Test-Case 'known-host-removal-waits-for-postcondition-not-submission' {
    $hdc='unused'; $Target='unused'; $probe=@{reads=0}
    function Invoke-HdcChecked {
        $probe.reads++
        if ($probe.reads -eq 1) { return "[127.0.0.1]:23150 ssh-ed25519 AAAA`nLEANTTY_KNOWN_HOST_READ_OK" }
        return "[127.0.0.1]:23151 ssh-ed25519 AAAA`nLEANTTY_KNOWN_HOST_READ_OK"
    }
    function Start-Sleep {}
    Wait-LeanTTYDeviceKnownHostAbsent -Hdc $hdc -Target $Target -Port 23150
    Assert-True ($probe.reads -eq 2) 'Removal did not wait for the exact endpoint to disappear'
}
Test-Case 'unconfirmed-known-host-read-is-not-absence' {
    function Invoke-HdcChecked { return 'cat: permission denied' }
    $caught=''
    try { Wait-LeanTTYDeviceKnownHostAbsent -Hdc unused -Target unused -Port 23150 }
    catch { $caught=$_.Exception.Message }
    Assert-True ($caught -match '^\[infrastructure\]') 'Failed file read qualified as cleanup'
}
foreach ($submitted in @($false,$true)) {
    Test-Case "long-task-removal-submitted-$submitted-is-never-repeated" {
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot 'verify-long-task-notification-pc.ps1'), [ref]$null, [ref]$null)
        $cleanup = $ast.Find({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and
            $n.Extent.Text.StartsWith('if ($knownHostCleanupAttempted -and -not $knownHostRemoved)') }, $true)
        $knownHostCleanupAttempted=$true; $knownHostRemoved=$false; $knownHostRemovalSubmitted=$submitted
        $sshMayBeActive=$false; $hdc='unused'; $Target='unused'; $Port=23150
        $probe=@{submissions=0;reads=0}
        function Ensure-LeanTTYVisible {}
        function Submit-LocalCommand { $probe.submissions++ }
        function Wait-LeanTTYDeviceKnownHostAbsent { $probe.reads++ }
        . ([scriptblock]::Create($cleanup.Extent.Text))
        Assert-True ($probe.submissions -eq [int](-not $submitted) -and $probe.reads -eq 1 -and $knownHostRemoved) 'Unknown earlier submission was repeated or absence was not observed'
    }
}
foreach ($scriptName in @('verify-long-task-notification-pc.ps1','verify-agent-compatibility-pc.ps1')) {
    foreach ($failureMode in @('none','permission','audit','early')) {
        Test-Case "$scriptName-new-cleanup-$failureMode" {
            $parseErrors=$null
            $ast = [Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $PSScriptRoot $scriptName), [ref]$null, [ref]$parseErrors)
            Assert-True ($parseErrors.Count -eq 0) 'Caller has a PowerShell parse error'
            $owner = @($ast.EndBlock.Statements | Where-Object {
                $_ -is [Management.Automation.Language.TryStatementAst]
            })[-1]
            $fixture=@{restore=0;audit=0;writes=0}
            $notificationState=@{originalEnabled=$false;restored=$false}
            $processId=$appProcessId=$(if ($failureMode -eq 'early') { '' } else { '1' })
            $panelOpen=$mappingActive=$isolatedTabCreated=$awakeLeaseAcquired=$knownHostCleanupAttempted=$false
            $knownHostRemoved=$true; $sshdProcess=$null; $hdc='unused'; $Target='unused'
            $fixtureDirectory='unused';$wslToolPath='unused';$wslFixtureDirectory='unused';$tmuxSocket='unused'
            $EvidenceDirectory='unused';$attemptId='unused';$PreviousAttemptId='';$ShellOnlyProbe=$true
            $cleanupFailures=[Collections.Generic.List[string]]::new()
            $result=@{status='failed';failure='original-business-failure'}
            function Write-AgentCompatibilityProgress { $fixture.writes++ }
            function Write-LongTaskProgress { $fixture.writes++ }
            function Write-LeanTTYAtomicJson { $fixture.writes++ }
            function Restore-NotificationPermission {
                $fixture.restore++
                if ($failureMode -eq 'permission') { throw 'controlled-permission-failure' }
                $notificationState.restored=$true
            }
            function Assert-NotificationCleanup {
                $fixture.audit++
                if ($failureMode -eq 'audit') { throw 'controlled-audit-failure' }
                return @{attributes=@{}}
            }
            function Get-LeanTTYTerminalInputNodes { return @{attributes=@{}} }
            function Test-Path { return $false }
            function wsl.exe { $global:LASTEXITCODE=0 }
            . ([scriptblock]::Create($owner.Finally.Extent.Text.Trim().Substring(1).TrimEnd().TrimEnd('}')))
            Assert-True ($fixture.restore -eq [int]($failureMode -ne 'early')) 'Early exit skipped acquired permission or touched an unstarted app'
            Assert-True ($fixture.audit -eq [int]($failureMode -ne 'early')) 'Permission restore failure prevented independent notification audit'
            Assert-True ($result.cleanup.result -eq $(if ($failureMode -in @('permission','audit')) {'failed'} else {'passed'})) 'Cleanup result is incorrect'
            Assert-True ($result.failure -eq 'original-business-failure') 'Cleanup overwrote the primary failure'
            Assert-True ($fixture.writes -gt 0) 'Cleanup did not persist evidence'
        }
    }
}
. (Join-Path $PSScriptRoot 'candidate-store.ps1')
foreach ($scriptName in @('verify-long-task-notification-pc.ps1','verify-agent-compatibility-pc.ps1',
        'verify-mosh-pc.ps1','verify-ssh-auth-pc.ps1','verify-terminal-search-pc.ps1')) {
    Test-Case "$scriptName-permission-repair-is-harness-only" {
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot $scriptName), [ref]$null, [ref]$null)
        $call = $ast.Find({ param($n) $n -is [Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Assert-LeanTTYCandidateHarnessCompatibility' }, $true)
        $arguments = @($call.CommandElements)
        $position = [array]::FindIndex($arguments, [Predicate[object]]{ param($n)
            $n -is [Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -eq 'AllowedHarnessPaths' })
        Assert-True ($position -ge 0) 'Missing candidate compatibility gate'
        $allowed = $arguments[$position + 1].SafeGetValue()
        $paths = @('tools/device-regression.ps1','tools/test-notification-regression.ps1',
            'tools/test-agent-ssh-gate.ps1','tools/test-device-regression.ps1',
            'tools/verify-long-task-notification-pc.ps1','tools/verify-agent-compatibility-pc.ps1',
            'tools/verify-mosh-pc.ps1','tools/verify-ssh-auth-pc.ps1','tools/verify-terminal-search-pc.ps1',
            'docs/quality-strategy.md','docs/next-work.md','docs/design/notification-fixture-permission-20260911.md')
        Assert-LeanTTYHarnessOnlyPaths -ChangedPaths $paths -AllowedPaths $allowed
        $rejected=$false
        try { Assert-LeanTTYHarnessOnlyPaths -ChangedPaths @('entry/src/main/ets/model/ui/BackgroundBellNotification.ets') -AllowedPaths $allowed }
        catch { $rejected=$true }
        Assert-True $rejected 'Product permission code can reuse an old candidate'
    }
}
$report = @{checks=@($checks.ToArray()); failed=@($checks | Where-Object result -eq failed).Count}
if ($EvidencePath) {
    New-Item -ItemType Directory -Path (Split-Path $EvidencePath -Parent) -Force | Out-Null
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
}
$checks | ForEach-Object { Write-Host "$($_.result): $($_.name) $($_.failure)" }
if ($report.failed -gt 0) { throw "$($report.failed) notification regression(s) failed" }
