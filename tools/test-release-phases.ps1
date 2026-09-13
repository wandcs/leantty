param([string]$EntrySourceRevision = '')

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('LeanTTY-phases-' + [guid]::NewGuid().ToString('N'))
$fixtureRoot = Join-Path $testRoot 'checkout'
$fixtureTools = Join-Path $fixtureRoot 'tools'
New-Item -ItemType Directory -Path $fixtureTools -Force | Out-Null
$entryText = if ($EntrySourceRevision) {
    (& git -C (Split-Path $PSScriptRoot -Parent) show "${EntrySourceRevision}:tools/verify-release-pc.ps1") -join "`n"
} else { Get-Content (Join-Path $PSScriptRoot 'verify-release-pc.ps1') -Raw }
$phaseFailAt = ''
$phaseCalls = [Collections.Generic.List[string]]::new()
$checks = 0
function Assert-Phase([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Assert-PhaseRejected([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch {
        Assert-Phase ($_.Exception.Message -like $Pattern) "Unexpected failure: $($_.Exception.Message)"
        return
    }
    throw "Expected rejection: $Pattern"
}

try {
    [IO.File]::WriteAllText((Join-Path $fixtureTools 'verify-release-pc.ps1'), $entryText)
    foreach ($name in @('release-tooling.ps1', 'release-agent-continuation.ps1')) {
        [IO.File]::Copy((Join-Path $PSScriptRoot $name), (Join-Path $fixtureTools $name))
    }
    [IO.File]::WriteAllText((Join-Path $fixtureTools 'candidate-store.ps1'), @'
function Resolve-LeanTTYRetainedCandidate {
    param($RepoRoot, $HapPath, $CandidateBasePath)
    [pscustomobject]@{hapPath='fixture.hap';manifestPath='fixture-manifest.json';sha256=('1'*64);
        gitCommit=('a'*40);gitTree=('d'*40);gitDirty=$false;verificationMode='device-deployed'}
}
function Get-LeanTTYHashIdentity { param([string]$Value)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Value)))
}
'@)
    . (Join-Path $fixtureTools 'release-tooling.ps1')
    $definitions = @(Get-LeanTTYReleaseVerificationStages -SplitOperator)
    $stub = @'
param([string]$EvidenceDirectory, [string]$Scenario, [string[]]$Only,
    [switch]$Formal, [string]$PreviousAttemptId)
$leaf = Split-Path $PSCommandPath -Leaf
$phaseCalls.Add($(if ($Scenario) { $Scenario } else { $leaf }))
if ($leaf -eq $phaseFailAt) { throw 'injected stage failure' }
if ($leaf -eq 'verify-mosh-pc.ps1' -and -not $Formal) { throw 'Mosh must run in formal mode' }
$resultFile = switch ($leaf) {
    'qualify-acceptance-harness-pc.ps1' { 'harness-qualification.json' }
    'verify-key-passphrase-pc.ps1' { 'device-key-passphrase.json' }
    'verify-ssh-auth-pc.ps1' { 'device-ssh-auth.json' }
    'verify-host-identity-pc.ps1' { 'device-host-identity.json' }
    'verify-ssh-matrix-pc.ps1' { 'ssh-matrix.json' }
    'verify-mosh-pc.ps1' { 'device-mosh.json' }
    default { 'result.json' }
}
$record = [ordered]@{schemaVersion=2;result='passed';gate='1.6-mosh-physical-acceptance';
    verificationMode='device-behavior-acceptance';acceptanceEligible=$true;scenario=$Scenario;
    attemptId=[guid]::NewGuid().ToString('N');previousAttemptId=$PreviousAttemptId;
    candidate=@{sha256=('1'*64);hapSha256=('1'*64);gitCommit=('a'*40);gitTree=('d'*40);gitDirty=$false};
    harness=@{gitCommit=('b'*40);gitTree=('c'*40);gitDirty=$false};
    cleanup=@{result='passed';deviceStateRemoved=$true;fixtureProcessesAbsent=$true;
        fixtureReverseMappingRemoved=$true;persistentNetworkPreserved=$true;temporaryDirectoryRemoved=$true};
    preferences=@{unchanged=$true};checks=@{secretPatternAbsent=$true;bootstrapTextAbsentFromTerminal=$true};
    lastProvenBoundary='cleanup-complete';networkSwitchComparison=@{originalNetworkRestored=$true};
    releaseEligible=$true;runMode='formal';reviewTestHap=@{sha256=('1'*64)};
    actualModelRequests=$(if ($leaf -eq 'verify-agent-compatibility-pc.ps1') {8}
        elseif ($leaf -eq 'verify-long-task-notification-pc.ps1') {1} else {0})}
$record.runtimeReclaim=@{contractVersion=1;trigger='acceptance-only-runtime-state-reclaim';
    graphDropped=$true;firstInputWithheld=$true;workspaceIdentityPreserved=$true;serverAbsent=$true;
    ptyAbsent=$true;localCommandPassed=$true;localBufferUnits=0;recoveredPaneCount=1;nativeCancelRequests=1;
    beforeProcess=@{processId='123';startTimeTicks='456'};afterProcess=@{processId='123';startTimeTicks='456'}}
$record.processRecovery=@{exercised=$true;runtimeReclaimed=$true;workspaceWarningObserved=$true;
    remoteContentAbsent=$true;sessionNotRestored=$true}
Write-LeanTTYAtomicJson -Path (Join-Path $EvidenceDirectory $resultFile) -Value $record -Depth 12
$global:LASTEXITCODE=0
'@
    foreach ($name in @($definitions.script | Sort-Object -Unique)) {
        [IO.File]::WriteAllText((Join-Path $fixtureTools $name), $stub)
    }
    # The real entry, registry, validators and report writer run. Only Git identity,
    # candidate lookup and external stage effects are replaced; no device/model calls.
    function git {
        $global:LASTEXITCODE=0
        if ($args -contains 'status') { return }
        if ($args -contains 'HEAD^{tree}') { return ('c'*40) }
        if ($args -contains 'HEAD') { return ('b'*40) }
        throw 'Unexpected Git operation in phase fixture'
    }
    $entry = Join-Path $fixtureTools 'verify-release-pc.ps1'
    $arguments = @{Target='fixture-device';EvidenceDirectory=(Join-Path $testRoot 'run');
        HapPath='fixture.hap';MoshAlternateWifiSsid='fixture-wifi'}
    Assert-PhaseRejected { & $entry @arguments -Phase operator } '*Operator phase requires -Resume*'
    Assert-Phase ($phaseCalls.Count -eq 0) 'Operator phase started without an automatic checkpoint'
    & $entry @arguments -Phase automatic
    $reportPath = Join-Path $arguments.EvidenceDirectory 'release-report.json'
    $readReport = { Get-Content $reportPath -Raw | ConvertFrom-Json -Depth 20 }
    $report = & $readReport
    Assert-Phase ($report.result -eq 'awaiting-operator' -and -not $report.registeredStagesPassed -and
        -not $report.completeApplicablePhysicalMatrixClaimed) 'Automatic work claimed complete acceptance'
    Assert-Phase ($report.stages.Count -eq 27 -and @($report.stages | Where-Object status -eq 'pending').Count -eq 2) 'Wrong pending stage set'
    Assert-Phase (($report.stages[-2..-1].name -join '|') -eq 'mosh-operator-lock-recovery|mosh-operator-lid-recovery') 'Operator suffix is not exact'
    Assert-Phase ($phaseCalls.Count -eq 24 -and @($phaseCalls | Where-Object {$_ -like 'operator-*'}).Count -eq 0) 'Automatic phase invoked operator work or lost automatic stages'
    Assert-Phase ($report.modelUsage.actualRequests -eq 9 -and $report.modelUsage.automaticRetries -eq 0) 'Fixed synthetic model accounting changed'
    $automaticCalls = $phaseCalls.Count
    & $entry @arguments -Phase automatic -Resume
    Assert-Phase ($phaseCalls.Count -eq $automaticCalls) 'Automatic resume repeated completed work'
    Assert-PhaseRejected { & $entry @arguments -Phase full -Resume } '*stage contract changed*'
    $original = [IO.File]::ReadAllText($reportPath)
    foreach ($mutation in @(
        {param($r) $r.invocation.target='other'},
        {param($r) $r.harness.gitTree=('e'*40)},
        {param($r) $r.candidate.sha256=('2'*64)},
        {param($r) $r.stages[2].status='pending'},
        {param($r) $r.stages[2].status='reused'})) {
        $changed = $original | ConvertFrom-Json -Depth 20
        & $mutation $changed
        Write-LeanTTYAtomicJson -Path $reportPath -Value $changed -Depth 20
        Assert-PhaseRejected { & $entry @arguments -Phase operator -Resume } '*'
        Assert-Phase ($phaseCalls.Count -eq $automaticCalls) 'Invalid checkpoint performed an action'
    }
    [IO.File]::WriteAllText($reportPath, $original)
    $moshPath = [string]($report.stages | Where-Object name -eq 'mosh-compatibility').resultPath
    $moshOriginal = [IO.File]::ReadAllText($moshPath)
    $badMosh = $moshOriginal | ConvertFrom-Json -Depth 20
    $badMosh.cleanup.deviceStateRemoved=$false
    Write-LeanTTYAtomicJson -Path $moshPath -Value $badMosh -Depth 20
    Assert-PhaseRejected { & $entry @arguments -Phase operator -Resume } '*Mosh cleanup*'
    Assert-Phase ($phaseCalls.Count -eq $automaticCalls) 'Unproved Mosh cleanup admitted an operator'
    [IO.File]::WriteAllText($moshPath, $moshOriginal)
    & $entry @arguments -Phase operator -Resume
    $report = & $readReport
    Assert-Phase ($report.result -eq 'passed' -and $report.completeApplicablePhysicalMatrixClaimed) 'Operator suffix did not complete the matrix'
    Assert-Phase ($phaseCalls.Count -eq ($automaticCalls+2) -and
        (($phaseCalls | Select-Object -Last 2) -join '|') -eq 'operator-lock-recovery|operator-lid-recovery') 'Operator resume repeated automatic work'
    & $entry @arguments -Phase operator -Resume
    Assert-Phase ($phaseCalls.Count -eq ($automaticCalls+2)) 'Completed resume repeated operator actions'
    $phaseFailAt='verify-key-passphrase-pc.ps1'
    $beforeFailure=$phaseCalls.Count
    $arguments.EvidenceDirectory=Join-Path $testRoot 'failure'
    Assert-PhaseRejected { & $entry @arguments -Phase automatic } '*injected stage failure*'
    Assert-Phase ($phaseCalls.Count -eq ($beforeFailure+2)) 'First failure did not stop the automatic phase'
    Assert-PhaseRejected { & $entry @arguments -Phase operator -Resume } '*Automatic phase is incomplete*'
    Write-Host "RELEASE PHASE TESTS PASSED: $checks; real orchestration, zero device/model calls"
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $resolved -Leaf) -notlike 'LeanTTY-phases-*') { throw 'Refusing unowned phase fixture cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
