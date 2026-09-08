param([string]$EvidencePath = '')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-tooling.ps1')
$startedAt = [DateTimeOffset]::UtcNow
$checks = [Collections.Generic.List[object]]::new()
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('LeanTTY-evidence-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Rejected([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw "Expected rejection: $Pattern"
}
function Test-Case([string]$CaseName, [scriptblock]$Action) {
    try {
        & $Action
        $checks.Add([pscustomobject]@{ name=$CaseName; result='passed'; failure='' })
    } catch {
        $checks.Add([pscustomobject]@{ name=$CaseName; result='failed'; failure=$_.Exception.Message })
    }
}
function Assert-NoTemporaryFiles {
    Assert-True (@(Get-ChildItem -LiteralPath $testRoot -Force |
        Where-Object Name -Match '^\.(tmp|bak)-').Count -eq 0) 'Temporary evidence files leaked'
}

function Invoke-KeyCleanupEvidenceCase {
    param([hashtable]$Case)

    # Execute the real report owner and cleanup control flow, not the device entry.
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'verify-key-passphrase-pc.ps1'), [ref]$null, [ref]$errors)
    Assert-True ($errors.Count -eq 0) 'Key producer syntax failed'
    foreach ($name in @('Write-BehaviorEvidence', 'Remove-DisposableDeviceKey')) {
        $owner = @($ast.FindAll({param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
        }, $true))
        Assert-True ($owner.Count -eq 1) "Expected one real key owner: $name"
        . ([scriptblock]::Create($owner[0].Extent.Text))
    }
    $deviceAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'device-regression.ps1'), [ref]$null, [ref]$errors)
    Assert-True ($errors.Count -eq 0) 'Device summary syntax failed'
    $summaryOwner = $deviceAst.Find({param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Get-LeanTTYDeviceCommandAutomationSummary'
    }, $true)
    . ([scriptblock]::Create($summaryOwner.Extent.Text))
    $physicalTry = @($ast.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.TryStatementAst]
    })
    Assert-True ($physicalTry.Count -eq 1) 'Expected one key scenario try/finally owner'
    $normalStatements = @($physicalTry[0].Body.Statements)
    $deleteStart = -1
    for ($i = 0; $i -lt $normalStatements.Count; $i++) {
        if ($normalStatements[$i].Extent.Text -ceq
            "Start-BehaviorStage -Name 'deleted-disposable-key-by-native-layout-button'") { $deleteStart = $i }
    }
    Assert-True ($deleteStart -ge 0) 'Normal deletion stage is missing'
    $normalDelete = [scriptblock]::Create((@($normalStatements[$deleteStart..($normalStatements.Count - 1)] |
        ForEach-Object { $_.Extent.Text }) -join "`n"))
    $finalize = [scriptblock]::Create((@($physicalTry[0].Finally.Statements |
        ForEach-Object { $_.Extent.Text }) -join "`n"))

    $probes = [Collections.Generic.Queue[bool]]::new()
    foreach ($present in @($Case.presence)) { $probes.Enqueue([bool]$present) }
    $effects = [Collections.Generic.List[string]]::new()
    function Test-LeanTTYDeviceKeyFilesPresent {
        $effects.Add('absence-probe')
        if ($Case.probeFailure) { throw 'controlled-absence-probe-failure' }
        if ($probes.Count -eq 0) { throw 'Unexpected device probe' }
        return $probes.Dequeue()
    }
    function Submit-Command { $effects.Add('delete-request') }
    function Invoke-DeleteKeyDialog {}
    function Wait-State {}
    function Clear-LeanTTYDeviceInput {}
    function Clear-LeanTTYAppLogs {}
    function Start-BehaviorStage {}
    function Complete-BehaviorStage {}
    function Stop-LeanTTYDeviceAwakeLease {
        if ($Case.awakeFailure) { throw 'controlled-awake-restore-failure' }
    }
    $hdc = 'unused-host-fixture'; $Target = 'unused-host-fixture'; $keyName = 'disposable-fixture-key'
    $appPid = $(if ($Case.noProcess) { '' } else { '1' })
    $candidate = @{sha256=('a' * 64);gitCommit=('b' * 40);gitTree=('c' * 40);gitDirty=$false}
    $harnessCommit = 'd' * 40; $harnessTree = 'e' * 40
    $deviceModel = 'host-fixture'; $deviceAbi = 'not-a-device'; $deviceTransport = 'none'
    $startedAt = [DateTimeOffset]::UtcNow
    $commandObservations = @(); $checks = @()
    $evidencePath = Join-Path $testRoot 'key-producer.json'
    $cleanupResult = $(if ($Case.ContainsKey('detail')) { $Case.detail } else { 'not-required' })
    $cleanupFailure = ''; $awakeLeaseFailure = ''; $awakeLeaseResult = 'acquired'
    $awakeLeaseActive = $true; $deviceUnlockResult = 'not-required'
    $keyCleanupRequired = -not $Case.skipCleanup
    $failure = 'original-business-failure'; $scenarioResult = 'failed'
    if ($Case.mode -eq 'normal') {
        $failure = ''
        . $normalDelete
    } elseif ($Case.mode -eq 'report') {
        $keyCleanupRequired = [bool]$Case.required
        $cleanupFailure = [string]$Case.cleanupFailure
        $awakeLeaseFailure = [string]$Case.environmentFailure
        $scenarioResult = 'passed'; $failure = ''
    }
    if ($Case.mode -ne 'report') { . $finalize }
    # Execute the actual post-finally failure propagation, stopping before storage promotion.
    $tail = @($ast.EndBlock.Statements | Where-Object {
        $_.Extent.StartOffset -gt $physicalTry[0].Extent.EndOffset
    })
    foreach ($statement in $tail) {
        if ($statement.Extent.Text -ceq 'Write-BehaviorEvidence -Result $scenarioResult') { break }
        . ([scriptblock]::Create($statement.Extent.Text))
    }
    Write-BehaviorEvidence -Result $scenarioResult
    return [pscustomobject]@{
        metadata = Get-LeanTTYReleaseEvidenceMetadata $evidencePath key-passphrase
        effects = $effects.ToArray()
        required = $keyCleanupRequired
    }
}

try {
    Test-Case 'key normal deletion writes a passing cleanup verdict and keeps absence detail' {
        $actual = Invoke-KeyCleanupEvidenceCase @{mode='normal';presence=@($false)}
        $saved = Get-LeanTTYReleaseEvidenceSummary (Join-Path $testRoot 'key-producer.json') key-passphrase
        Assert-True ($saved.cleanup -ceq 'passed' -and $saved.evidence.cleanup.detail -ceq 'verified-absent' -and
            -not $actual.required -and ($actual.effects -join ',') -ceq 'delete-request,absence-probe' -and
            $saved.evidence.environment.awakeLease -ceq 'restored') 'Normal key cleanup lost its audit or detail'
    }
    foreach ($case in @(
        @{name='already absent';presence=@($false);detail='already-absent';verdict='passed';effects='absence-probe'},
        @{name='deleted in finally';presence=@($true,$false);detail='verified-absent';verdict='passed';effects='absence-probe,delete-request,absence-probe'},
        @{name='files remain';presence=@($true,$true);detail='failed';verdict='failed';effects='absence-probe,delete-request,absence-probe'},
        @{name='probe failed';probeFailure=$true;detail='failed';verdict='failed';effects='absence-probe'},
        @{name='cleanup not executed';skipCleanup=$true;detail='not-required';verdict='unknown';effects=''},
        @{name='process unavailable';noProcess=$true;detail='not-required';verdict='unknown';effects=''}
    )) {
        Test-Case "key finally preserves business failure and cleanup outcome: $($case.name)" {
            $inputs = $case.Clone(); $inputs.Remove('detail')
            $actual = Invoke-KeyCleanupEvidenceCase $inputs
            Assert-True ($actual.metadata.cleanup -ceq $case.verdict -and
                $actual.metadata.evidence.cleanup.detail -ceq $case.detail -and
                $actual.metadata.evidence.failure -ceq 'original-business-failure' -and
                ($actual.effects -join ',') -ceq $case.effects) 'Finally cleanup was promoted, lost or resent'
            Assert-Rejected { Get-LeanTTYReleaseEvidenceSummary (Join-Path $testRoot 'key-producer.json') key-passphrase } 'passing result'
        }
    }
    Test-Case 'key awake restoration failure cannot hide behind successful key deletion' {
        $actual = Invoke-KeyCleanupEvidenceCase @{mode='normal';presence=@($false);awakeFailure=$true}
        Assert-True ($actual.metadata.cleanup -ceq 'failed' -and $actual.metadata.outcome -ceq 'failed' -and
            $actual.metadata.evidence.environment.failure -ceq 'controlled-awake-restore-failure') 'Awake failure was masked'
    }
    foreach ($case in @(
        @{detail='verified-absent';required=$true},
        @{detail='already-absent';cleanupFailure='controlled-cleanup-failure'},
        @{detail='verified-absent';environmentFailure='controlled-environment-failure'},
        @{detail='unknown'}, @{detail='not-required'}, @{detail='future-value'}, @{detail='passed'}, @{detail=''}
    )) {
        Test-Case "key unproved report is rejected: $($case | ConvertTo-Json -Compress)" {
            $inputs = $case.Clone(); $inputs.mode = 'report'
            $null = Invoke-KeyCleanupEvidenceCase $inputs
            Assert-Rejected { Get-LeanTTYReleaseEvidenceSummary (Join-Path $testRoot 'key-producer.json') key-passphrase } 'cleanup|passing result'
        }
    }
    Test-Case 'depth overflow preserves the previous checkpoint' {
        $path = Join-Path $testRoot 'depth.json'
        Write-LeanTTYAtomicJson $path @{ attempt=1; failure='original-failure' }
        $before = (Get-FileHash -LiteralPath $path).Hash
        $deep = @{ a=@{ b=@{ c=@{ d=@{ e='must-not-be-truncated' } } } } }
        $rejected = $false
        try { Write-LeanTTYAtomicJson $path $deep -Depth 2 } catch { $rejected=$true }
        Assert-True $rejected 'Depth overflow silently committed lossy evidence'
        Assert-True ((Get-FileHash -LiteralPath $path).Hash -ceq $before) 'Previous checkpoint changed'
        Assert-NoTemporaryFiles
    }
    Test-Case 'depth overflow does not create a first checkpoint' {
        $path = Join-Path $testRoot 'first.json'
        $deep = @{ a=@{ b=@{ c=@{ d=@{ e='nested' } } } } }
        $rejected = $false
        try { Write-LeanTTYAtomicJson $path $deep -Depth 2 } catch { $rejected=$true }
        Assert-True ($rejected -and -not (Test-Path -LiteralPath $path)) 'Lossy first checkpoint was admitted'
        Assert-NoTemporaryFiles
    }
    Test-Case 'failed replacement preserves the old file and removes temporary files' {
        $path = Join-Path $testRoot 'locked.json'
        Write-LeanTTYAtomicJson $path @{ attempt=1 }
        $before = (Get-FileHash -LiteralPath $path).Hash
        $lock = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $rejected = $false
            try { Write-LeanTTYAtomicJson $path @{ attempt=2 } } catch { $rejected=$true }
            Assert-True $rejected 'Locked destination replacement should fail on Windows'
        } finally { $lock.Dispose() }
        Assert-True ((Get-FileHash -LiteralPath $path).Hash -ceq $before) 'Failed replacement changed the checkpoint'
        Assert-NoTemporaryFiles
    }
    Test-Case 'successful replacement retains nested failure and zero usage' {
        $path = Join-Path $testRoot 'round-trip.json'
        Write-LeanTTYAtomicJson $path @{ attempt=1 }
        Write-LeanTTYAtomicJson $path @{ attempt=2; actualModelRequests=0;
            checks=@(@{ failure='original-failure'; cleanup=@{ result='failed'; detail='cleanup-failure' } }) }
        $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 20
        Assert-True ($saved.attempt -eq 2 -and $saved.actualModelRequests -eq 0 -and
            $saved.checks[0].failure -ceq 'original-failure' -and
            $saved.checks[0].cleanup.detail -ceq 'cleanup-failure') 'Round trip lost evidence'
        Assert-NoTemporaryFiles
    }
    Test-Case 'missing stage evidence is rejected' {
        Assert-Rejected { Get-LeanTTYReleaseEvidenceSummary (Join-Path $testRoot 'missing.json') synthetic } 'required evidence'
    }
    Test-Case 'malformed stage JSON is rejected' {
        $path = Join-Path $testRoot 'malformed.json'
        [IO.File]::WriteAllText($path, '{"status":')
        Assert-Rejected { Get-LeanTTYReleaseEvidenceSummary $path synthetic } 'unreadable JSON'
    }
    foreach ($outcome in @('failed', 'invalid/interrupted', 'unknown', 'running', '')) {
        Test-Case "non-passing outcome is rejected: $outcome" {
            $path = Join-Path $testRoot 'outcome.json'
            Write-LeanTTYAtomicJson $path @{ status=$outcome; cleanup=@{ result='passed' } }
            Assert-Rejected { Get-LeanTTYReleaseEvidenceSummary $path synthetic } 'passing result'
        }
    }
    foreach ($case in @(
        @{ name='failed string'; value='failed: synthetic' },
        @{ name='pending string'; value='pending' },
        @{ name='unknown string'; value='unknown' },
        @{ name='arbitrary prose'; value='cleanup was not confirmed' },
        @{ name='null'; value=$null },
        @{ name='empty object'; value=@{} },
        @{ name='failed object'; value=@{ result='failed' } },
        @{ name='unknown object'; value=@{ result='unknown' } },
        @{ name='absence detail as verdict'; value=@{ result='verified-absent' } },
        @{ name='already-absent detail as verdict'; value=@{ result='already-absent' } },
        @{ name='invalid object'; value=@{ result='invalid/interrupted' } },
        @{ name='missing object verdict'; value=@{ detail='no verdict' } },
        @{ name='false resource'; value=@{ mappingRemoved=$true; fixtureRemoved=$false } }
    )) {
        Test-Case "unproved cleanup is rejected: $($case.name)" {
            $path = Join-Path $testRoot 'cleanup.json'
            Write-LeanTTYAtomicJson $path @{ status='passed'; cleanup=$case.value }
            Assert-Rejected { Get-LeanTTYReleaseEvidenceSummary $path synthetic } 'cleanup'
        }
    }
    foreach ($cleanup in @('passed', @{result='passed';detail='owned cleanup'},
        @{mappingRemoved=$true;fixtureRemoved=$true})) {
        Test-Case "proved cleanup is accepted: $($checks.Count)" {
            $path = Join-Path $testRoot 'proved.json'
            Write-LeanTTYAtomicJson $path @{ result='passed'; cleanup=$cleanup; actualModelRequests=0;
                attemptId='attempt-2'; previousAttemptId='attempt-1' }
            $saved = Get-LeanTTYReleaseEvidenceSummary $path synthetic
            Assert-True ($saved.cleanup -ceq 'passed' -and $saved.actualModelRequests -ceq '0' -and
                $saved.attemptId -ceq 'attempt-2' -and $saved.previousAttemptId -ceq 'attempt-1') 'Summary changed owned metadata'
        }
    }
    Test-Case 'absent cleanup stays explicitly unreported and usage unavailable' {
        $path = Join-Path $testRoot 'unreported.json'
        Write-LeanTTYAtomicJson $path @{ result='passed' }
        $saved = Get-LeanTTYReleaseEvidenceSummary $path candidate
        Assert-True ($saved.cleanup -ceq 'not-separately-reported' -and
            $saved.actualModelRequests -ceq 'unavailable') 'Summary invented cleanup or model evidence'
    }
    Test-Case 'failed metadata preserves the first cause and incomplete cleanup' {
        $path = Join-Path $testRoot 'failed-metadata.json'
        Write-LeanTTYAtomicJson $path @{ status='failed'; failure='original-failure';
            cleanup=@{result='unknown';detail='cleanup-failure'}; actualModelRequests=0;
            attemptId='attempt-2'; previousAttemptId='attempt-1' }
        $saved = Get-LeanTTYReleaseEvidenceMetadata $path synthetic
        Assert-True ($saved.outcome -ceq 'failed' -and $saved.cleanup -ceq 'unknown' -and
            $saved.evidence.failure -ceq 'original-failure' -and $saved.actualModelRequests -ceq '0' -and
            $saved.previousAttemptId -ceq 'attempt-1') 'Failure metadata was masked'
    }
    foreach ($name in @('verify-background-bell-notification-pc.ps1',
        'verify-background-bell-permission-pc.ps1', 'verify-long-task-notification-pc.ps1',
        'verify-agent-compatibility-pc.ps1')) {
        Test-Case "cleanup producer writes typed pass and failure: $name" {
            # Evaluate the actual assignments only, never the physical entry point.
            $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $PSScriptRoot $name), [ref]$null, [ref]$errors)
            Assert-True ($errors.Count -eq 0) 'Producer syntax failed'
            $assignments = @($ast.FindAll({param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -ceq '$result.cleanup'
            }, $true))
            Assert-True ($assignments.Count -eq 2) 'Expected the success and failure cleanup assignments'
            $result = [pscustomobject]@{cleanup=$null}
            $cleanupFailure = 'controlled-cleanup-failure'
            $cleanupFailures = [Collections.Generic.List[string]]::new()
            $cleanupFailures.Add($cleanupFailure)
            foreach ($assignment in $assignments) {
                . ([scriptblock]::Create($assignment.Extent.Text))
                $path = Join-Path $testRoot 'producer.json'
                Write-LeanTTYAtomicJson $path $result
                $saved = Get-LeanTTYReleaseEvidenceMetadata $path synthetic
                Assert-True ($saved.cleanup -cin @('passed','failed')) 'Producer lacks a typed cleanup verdict'
                Assert-True (-not [string]::IsNullOrWhiteSpace($saved.evidence.cleanup.detail)) 'Producer lost cleanup detail'
            }
            Assert-True ($result.cleanup.result -ceq 'failed' -and
                $result.cleanup.detail -ceq $cleanupFailure) 'Producer masked the cleanup failure'
        }
    }
    foreach ($name in @('verify-ssh-auth-pc.ps1', 'verify-host-identity-pc.ps1', 'verify-mosh-matrix-pc.ps1')) {
        foreach ($passed in @($true, $false)) {
            Test-Case "registered nested cleanup reaches the real consumer: $name passed=$passed" {
                $errors = $null
                $ast = [Management.Automation.Language.Parser]::ParseFile(
                    (Join-Path $PSScriptRoot $name), [ref]$null, [ref]$errors)
                Assert-True ($errors.Count -eq 0) 'Registered producer syntax failed'
                $cleanupExpressions = @($ast.FindAll({param($node)
                    $node -is [Management.Automation.Language.HashtableAst]
                }, $true) | ForEach-Object { $_.KeyValuePairs } | Where-Object {
                    $_.Item1.Extent.Text -ceq 'cleanup' -and $_.Item2.Extent.Text.StartsWith('[ordered]@{')
                })
                Assert-True ($cleanupExpressions.Count -eq 1) 'Expected one nested cleanup report owner'
                $cleanupFailures = [Collections.Generic.List[string]]::new()
                if (-not $passed) { $cleanupFailures.Add('controlled-cleanup-failure') }
                $cleanupResult = $(if ($passed) { 'passed' } else { 'failed' })
                $matrixResult = $cleanupResult
                $cleanupFailure = $(if ($passed) { '' } else { 'controlled-cleanup-failure' })
                $cleanup = & ([scriptblock]::Create($cleanupExpressions[0].Item2.Extent.Text))
                $path = Join-Path $testRoot 'registered-nested.json'
                Write-LeanTTYAtomicJson $path @{result='passed';cleanup=$cleanup}
                if ($passed) {
                    $saved = Get-LeanTTYReleaseEvidenceSummary $path $name
                    Assert-True ($saved.cleanup -ceq 'passed') 'Registered success was rejected'
                } else {
                    Assert-Rejected { Get-LeanTTYReleaseEvidenceSummary $path $name } 'cleanup'
                }
            }
        }
    }
    Test-Case 'uninstall cleanup requires the actual awake-restored assignment before passing' {
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot 'verify-unexpected-recovery-uninstall-pc.ps1'), [ref]$null, [ref]$errors)
        Assert-True ($errors.Count -eq 0) 'Uninstall producer syntax failed'
        $assignments = @($ast.FindAll({param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -cin @('$result.cleanup', '$result.cleanup.deviceAwakeLeaseRestored')
        }, $true))
        Assert-True ($assignments.Count -eq 2) 'Expected cleanup initialization and audited restore update'
        $result = [pscustomobject]@{result='passed';cleanup=$null}
        $path = Join-Path $testRoot 'uninstall-cleanup.json'
        . ([scriptblock]::Create($assignments[0].Extent.Text))
        Write-LeanTTYAtomicJson $path $result
        Assert-Rejected { Get-LeanTTYReleaseEvidenceSummary $path uninstall } 'cleanup'
        . ([scriptblock]::Create($assignments[1].Extent.Text))
        Write-LeanTTYAtomicJson $path $result
        Assert-True ((Get-LeanTTYReleaseEvidenceSummary $path uninstall).cleanup -ceq 'passed') 'Audited restore was rejected'
    }
    Test-Case 'every registered report owner has an explicit cleanup contract audit' {
        $covered = @('verify-key-passphrase-pc.ps1', 'verify-ssh-auth-pc.ps1',
            'verify-host-identity-pc.ps1', 'verify-background-bell-notification-pc.ps1',
            'verify-background-bell-permission-pc.ps1', 'verify-unexpected-recovery-uninstall-pc.ps1',
            'verify-mosh-matrix-pc.ps1', 'verify-long-task-notification-pc.ps1',
            'verify-agent-compatibility-pc.ps1')
        # These reports have no top-level cleanup; qualification and SSH audit their owned nested evidence.
        $unreported = @('verify-pc.ps1', 'qualify-acceptance-harness-pc.ps1', 'verify-ssh-matrix-pc.ps1')
        $registered = @(Get-LeanTTYReleaseVerificationStages | Select-Object -ExpandProperty script -Unique)
        Assert-True (@(Compare-Object ($covered + $unreported) $registered).Count -eq 0) 'Review cleanup coverage for the changed release registry'
    }
    Test-Case 'JSON and maintainer summary retain failed stage and distinct model counts' {
        $report = [pscustomobject]@{
            result='failed'; completeApplicablePhysicalMatrixClaimed=$false
            candidate=@{sha256=('a' * 64)}; harness=@{gitCommit=('b' * 40);gitTree=('c' * 40)}
            modelUsage=@{plannedRequests=9;actualRequests=0;automaticRetries=0}
            stages=@(@{name='controlled-stage';status='failed';attemptCount=2;durationMs=123;
                cleanup='unknown';resultPath='controlled-stage.json'})
            failure='original-failure'; sshResumeCommand=''
        }
        $paths = Write-LeanTTYReleaseReportArtifacts $testRoot $report
        $saved = Get-Content -LiteralPath $paths.reportPath -Raw | ConvertFrom-Json -Depth 20
        $summary = Get-Content -LiteralPath $paths.summaryPath -Raw
        Assert-True ($saved.stages[0].cleanup -ceq 'unknown' -and
            -not $saved.completeApplicablePhysicalMatrixClaimed -and
            $summary.Contains('Actual model requests: 0') -and
            $summary.Contains('Planned model requests: 9') -and
            $summary.Contains('| controlled-stage | failed | 2 | 123 | unknown |') -and
            $summary.Contains('Failure: original-failure')) 'Summary promoted or lost failed evidence'
    }
} finally {
    $fullRoot = [IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $fullRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $fullRoot -Leaf) -notmatch '^LeanTTY-evidence-test-[0-9a-f]{32}$') {
        throw 'Unsafe evidence-test cleanup target'
    }
    Remove-Item -LiteralPath $fullRoot -Recurse -Force
}
$failures = @($checks | Where-Object result -EQ failed)
if ($EvidencePath) {
    # Keep this test report independent of the writer under test, including red runs.
    $report = [ordered]@{
        scenario='release-evidence-fault-injection'; acceptanceEligible=$false
        startedAt=$startedAt.ToString('o'); completedAt=[DateTimeOffset]::UtcNow.ToString('o')
        durationMs=[long]([DateTimeOffset]::UtcNow-$startedAt).TotalMilliseconds
        powershellVersion=$PSVersionTable.PSVersion.ToString()
        toolingSha256=(Get-FileHash (Join-Path $PSScriptRoot 'release-tooling.ps1')).Hash
        testSha256=(Get-FileHash $PSCommandPath).Hash
        deviceCommands=0; plannedModelRequests=0; actualModelRequests=0
        result=$(if ($failures.Count) {'failed'} else {'passed'}); checks=$checks.ToArray()
        cleanup='passed'
    }
    $resolvedEvidence = [IO.Path]::GetFullPath($EvidencePath)
    New-Item -ItemType Directory -Path (Split-Path $resolvedEvidence -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($resolvedEvidence, (ConvertTo-Json -InputObject $report -Depth 8 -WarningAction Stop))
}
foreach ($failure in $failures) { Write-Host "FAIL: $($failure.name): $($failure.failure)" }
if ($failures.Count) { throw "Release evidence tests: $($failures.Count)/$($checks.Count) failed" }
Write-Host "RELEASE EVIDENCE TESTS PASSED: $($checks.Count)"
