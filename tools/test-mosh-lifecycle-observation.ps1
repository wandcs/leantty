param([string]$EvidencePath = '')
$ErrorActionPreference = 'Stop'
$checks = [Collections.Generic.List[object]]::new()
function Assert-Observation([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Test-Observation([string]$Name, [scriptblock]$Action) {
    try { & $Action; $checks.Add(@{ name = $Name; result = 'passed' }) }
    catch { $checks.Add(@{ name = $Name; result = 'failed'; failure = $_.Exception.Message }) }
}
function Assert-MissingObservation([scriptblock]$Action) {
    $failure = ''
    try { & $Action | Out-Null } catch { $failure = $_.Exception.Message }
    Assert-Observation ($failure -like '[[]harness[]] Mosh lifecycle log snapshot is empty*') (
        'Missing lifecycle evidence was accepted or misclassified')
}

# Load the real owner without running device setup. Only the HDC read is replaced.
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'verify-mosh-pc.ps1'), [ref]$null, [ref]$parseErrors)
Assert-Observation ($parseErrors.Count -eq 0) 'Mosh verifier did not parse'
$definitions = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Get-MoshLifecycleObservation'
}, $true))
Assert-Observation ($definitions.Count -eq 1) 'Missing or ambiguous lifecycle owner'
. ([scriptblock]::Create($definitions[0].Extent.Text))
$hdc = 'test-hdc'
$targetId = 'test-target'
$appPid = '31415'
$reads = [Collections.Generic.List[object]]::new()
$readerState = @{ logs = ''; failure = '' }
function Get-LeanTTYAppLogs { param($Hdc, $Target, $ProcessId)
    $reads.Add(@{ hdc = $Hdc; target = $Target; processId = $ProcessId })
    if ($readerState.failure) { throw $readerState.failure }
    return $readerState.logs
}

Test-Observation 'default-reads-current-process-once' {
    $reads.Clear()
    $readerState.logs = "Mosh reachability state=interrupted reason=no_recent_contact`n" +
        'Mosh reachability state=responsive transition=recovered'
    $observed = Get-MoshLifecycleObservation
    Assert-Observation ($reads.Count -eq 1) 'Default observation skipped or repeated its HDC read'
    Assert-Observation ($reads[0].hdc -ceq $hdc -and $reads[0].target -ceq $targetId -and
        $reads[0].processId -ceq $appPid) 'Default observation read another process or target'
    Assert-Observation ($observed.logs -ceq $readerState.logs -and $observed.interrupted -and
        $observed.recovered -and $observed.interruptionReason -ceq 'no_recent_contact' -and
        -not $observed.error -and -not $observed.closed) 'Default observation lost the captured lifecycle'
}
Test-Observation 'explicit-snapshot-never-queries-device' {
    $reads.Clear()
    $readerState.failure = '[environment] A captured snapshot must not query HDC'
    try {
        $observed = Get-MoshLifecycleObservation -Logs 'Mosh reachability state=interrupted reason=no_recent_reply'
        Assert-Observation ($reads.Count -eq 0 -and $observed.interrupted -and
            $observed.interruptionReason -ceq 'no_recent_reply') 'Explicit snapshot was replaced or lost'
    } finally { $readerState.failure = '' }
}
foreach ($missing in @($null, '', " `r`n`t")) {
    Test-Observation ('missing-explicit-' + $checks.Count) {
        $reads.Clear()
        Assert-MissingObservation { Get-MoshLifecycleObservation -Logs $missing }
        Assert-Observation ($reads.Count -eq 0) 'Explicit missing snapshot silently fell back to HDC'
    }
    Test-Observation ('missing-default-' + $checks.Count) {
        $reads.Clear()
        $readerState.logs = $missing
        Assert-MissingObservation { Get-MoshLifecycleObservation }
        Assert-Observation ($reads.Count -eq 1) 'Missing default snapshot was retried or never read'
    }
}
Test-Observation 'reader-error-propagates' {
    $reads.Clear()
    $readerState.failure = '[environment] test HDC failed'
    $failure = ''
    try { Get-MoshLifecycleObservation | Out-Null } catch { $failure = $_.Exception.Message }
    finally { $readerState.failure = '' }
    Assert-Observation ($failure -ceq '[environment] test HDC failed' -and $reads.Count -eq 1) (
        'HDC failure was converted to a clean lifecycle observation')
}
foreach ($captureMode in @('default', 'explicit')) {
    foreach ($signal in @('error', 'closed', 'both')) {
        Test-Observation "$captureMode-$signal-survives-recovery" {
            $reads.Clear()
            $readerState.logs = 'Mosh reachability state=responsive transition=recovered'
            if ($signal -in @('error', 'both')) { $readerState.logs += "`nMosh error stage=mosh_udp" }
            if ($signal -in @('closed', 'both')) {
                $readerState.logs += "`nMosh close reason=remote_closed`nMosh Session closed"
            }
            $observed = if ($captureMode -eq 'default') { Get-MoshLifecycleObservation }
                else { Get-MoshLifecycleObservation -Logs $readerState.logs }
            Assert-Observation ($observed.recovered -and
                $observed.error -eq ($signal -in @('error', 'both')) -and
                $observed.closed -eq ($signal -in @('closed', 'both')) -and
                $reads.Count -eq $(if ($captureMode -eq 'default') { 1 } else { 0 })) (
                'Recovery marker hid an error or close event')
            if ($observed.closed) {
                Assert-Observation ($observed.closeReason -ceq 'remote_closed') 'Close reason was lost'
            }
        }
    }
}
Test-Observation 'nonempty-without-lifecycle-marks-is-not-recovery' {
    $observed = Get-MoshLifecycleObservation -Logs 'ACCEPTANCE_OUTPUT_ACK pane=test'
    Assert-Observation (-not $observed.interrupted -and -not $observed.recovered -and
        -not $observed.error -and -not $observed.closed -and
        $observed.interruptionReason -ceq 'not-observed' -and $observed.closeReason -ceq 'not-observed') (
        'Unrelated nonempty logs manufactured lifecycle evidence')
}

# Execute the real callers, replacing device/fixture operations only. The
# post-command buffer deliberately lacks the earlier transition markers.
foreach ($scenarioName in @('pause-recovery', 'wifi-pause-recovery', 'server-disappearance')) {
    $branches = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -ceq "`$Scenario -eq '$scenarioName'" -and
        $node.Clauses[0].Item2.Extent.Text.Contains('Get-MoshLifecycleObservation')
    }, $true))
    Assert-Observation ($branches.Count -eq 1) "Missing or ambiguous scenario: $scenarioName"
    $statements = [Collections.Generic.List[string]]::new()
    foreach ($statement in $branches[0].Clauses[0].Item2.Statements) {
        if ($statement.Extent.Text.StartsWith('[IO.File]::WriteAllText(')) { break }
        $statements.Add($statement.Extent.Text)
    }
    $scenarioBody = [scriptblock]::Create($statements -join "`n")
    $variants = if ($scenarioName -eq 'server-disappearance') { @('normal') }
        else { @('normal', 'empty-after-command', 'late-error', 'late-close') }
    foreach ($variant in $variants) {
        Test-Observation "$scenarioName-$variant" {
            $reads.Clear()
            $readerState.logs = switch ($variant) {
                'empty-after-command' { '' }
                'late-error' { 'Mosh error stage=mosh_udp' }
                'late-close' { 'Mosh Session closed' }
                default { 'ACCEPTANCE_OUTPUT_ACK pane=test' }
            }
            $waits = [Collections.Generic.List[string]]::new()
            $commands = [Collections.Generic.List[string]]::new()
            function Write-LiveStatus {}
            function Clear-LeanTTYAppLogs {}
            function Enable-MoshUdpImpairment {}
            function Disable-MoshUdpImpairment {}
            function Set-MoshDeviceWifi {}
            function Focus-ActiveTerminalInput {}
            function Get-LeanTTYWslPrefix {}
            function wsl.exe { $global:LASTEXITCODE = 0 }
            function Wait-WslProcessAbsent {}
            function Test-WslProcessPresent { return $true }
            function Wait-LeanTTYAppLog { param($Hdc, $Target, $ProcessId, $Pattern, $TimeoutSeconds)
                $waits.Add($Pattern)
                return $Pattern
            }
            function Wait-MoshWifiInterruptionOutcome {
                return @{ outcome = 'interrupted'; logs =
                    'Mosh reachability state=interrupted reason=no_recent_contact' }
            }
            function Submit-MoshInput { param($Text) $commands.Add($Text) }
            function Wait-ControlFileMatch {}
            $attemptId = 'test0123456789'
            $fixtureEvent = 'test-only-control'
            $failure = ''
            try { . $scenarioBody } catch { $failure = $_.Exception.Message }
            if ($variant -eq 'empty-after-command') {
                Assert-Observation ($failure -like '[[]harness[]] Mosh lifecycle log snapshot is empty*') (
                    'Earlier captured transitions hid a missing post-command snapshot')
            } elseif ($variant -in @('late-error', 'late-close')) {
                Assert-Observation ($failure -like '[[]product[]]*') 'Late termination was accepted as recovery'
            } else {
                Assert-Observation (-not $failure -and $interruptionObserved -and
                    $interruptionReason -ceq 'no_recent_contact' -and $sessionStayedConnected -and
                    -not $automaticErrorObserved -and -not $automaticCloseObserved) (
                    "Captured interruption did not reach the scenario result: $failure")
                if ($scenarioName -eq 'server-disappearance') {
                    Assert-Observation ($userCloseRequired -and $reads.Count -eq 0 -and
                        $commands.Count -eq 0) 'Server silence must use captured warning and require user close'
                } else {
                    Assert-Observation ($recoveredStatusObserved -and $recoveryCommandPassed -and
                        $reads.Count -eq 1 -and $commands.Count -eq 1 -and
                        $recoveryObservation.logs.Contains('transition=recovered') -and
                        $recoveryObservation.logs.Contains('reason=no_recent_contact') -and
                        $recoveryObservation.logs.Contains('ACCEPTANCE_OUTPUT_ACK')) (
                        'Scenario lost a captured transition, repeated input, or skipped the final read')
                }
            }
        }
    }
}
$optionalBranches = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Clauses[0].Item1.Extent.Text -ceq '[string]::IsNullOrWhiteSpace($operatorPreRecoveryLogs)'
}, $true))
Assert-Observation ($optionalBranches.Count -eq 1) 'Missing old-process diagnostic boundary'
foreach ($optionalLogs in @('', " `n", 'Mosh error stage=mosh_udp', 'Mosh Session closed')) {
    Test-Observation ('old-process-optional-' + $checks.Count) {
        $reads.Clear()
        $operatorPreRecoveryLogs = $optionalLogs
        . ([scriptblock]::Create($optionalBranches[0].Extent.Text))
        if ([string]::IsNullOrWhiteSpace($optionalLogs)) {
            Assert-Observation ($null -eq $operatorPreRecoveryCloseObserved -and
                $null -eq $operatorPreRecoveryErrorObserved -and
                $null -eq $operatorPreRecoveryInterruptionObserved -and
                $operatorPreRecoveryInterruptionReason -ceq 'unknown' -and
                $operatorPreRecoveryCloseReason -ceq 'unknown') 'Missing old-process logs became false negatives'
        } else {
            Assert-Observation ($operatorPreRecoveryErrorObserved -eq ($optionalLogs -match 'error') -and
                $operatorPreRecoveryCloseObserved -eq ($optionalLogs -match 'closed')) (
                'Available old-process errors or close events were discarded')
        }
        Assert-Observation ($reads.Count -eq 0) 'Old-process diagnostics queried a different log snapshot'
    }
}

$failed = @($checks | Where-Object result -eq 'failed')
if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
    . (Join-Path $PSScriptRoot 'release-tooling.ps1')
    Write-LeanTTYAtomicJson -Path $EvidencePath -Depth 5 -Value ([ordered]@{
        gate = 'mosh-lifecycle-observation'; result = $(if ($failed.Count) { 'failed' } else { 'passed' })
        acceptanceEligible = $false; deviceOperations = 0; checks = @($checks)
    })
}
if ($failed.Count) { throw ($failed.failure -join '; ') }
Write-Host "Mosh lifecycle observation passed: $($checks.Count) real-owner checks."
