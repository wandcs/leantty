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
$phaseChangedPaths = @()
$phaseChangeIndependentSsh = $false
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
    . (Join-Path $PSScriptRoot 'candidate-store.ps1')
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
if ($leaf -eq 'verify-agent-compatibility-pc.ps1') { $record.runMode='acceptance' }
Write-LeanTTYAtomicJson -Path (Join-Path $EvidenceDirectory $resultFile) -Value $record -Depth 12
if ($false) {
    function Wait-AuthPasteReady {}
    function Invoke-LeanTTYPasteShortcut {}
    if (Test-AuthStageSelected -Name 'terminal-key-input') {}
    if (Test-AuthStageSelected -Name 'transport-main-path') {}
    if (Test-AuthStageSelected -Name 'ssh-escape') {}
}
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
        if ($args -contains 'merge-base') { return }
        if ($args -contains 'diff') { foreach ($changedPath in $phaseChangedPaths) { $changedPath }; return }
        if ($args -contains 'show') {
            Get-Content (Join-Path $fixtureTools 'verify-ssh-auth-pc.ps1')
            if ($phaseChangeIndependentSsh) { '# changed an independent SSH owner' }
            return
        }
        if ($args -contains 'HEAD^{tree}') { return ('c'*40) }
        if ($args -contains 'HEAD') { return ('b'*40) }
        if ($args -contains (('b'*40)+'^{tree}')) { return ('c'*40) }
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

    # Real cross-harness policy and entry: synthetic old failure remains immutable;
    # its independent prefix is reused, new QH/Agent/suffix execute, operator waits.
    function Pin-PhaseJson([string]$Name, $Value) {
        $path=Join-Path $testRoot $Name
        Write-LeanTTYAtomicJson -Path $path -Value $Value -Depth 20
        @{path=$path;sha256=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    $old=& $readReport
    $old.result='failed'; $old.completeApplicablePhysicalMatrixClaimed=$false
    $agentIndex=[Array]::IndexOf(@($old.stageOrder),'agent-compatibility')
    $failedStage=$old.stages[$agentIndex]
    $agentEvidence=Get-Content $failedStage.resultPath -Raw | ConvertFrom-Json -Depth 20
    $agentEvidence.result='failed'; $agentEvidence.runMode='acceptance'
    $resources=@{knownHostEndpoint='[127.0.0.1]:32000';tabCleanup=@{ownedTabRemoved=$true;originalTabsRestored=$true;originalActiveTabRestored=$true};notificationPermission=@{restored=$true}}
    $agentEvidence | Add-Member resources $resources
    $agentRef=Pin-PhaseJson 'r2-original-agent.json' $agentEvidence
    $failedStage.status='failed';$failedStage.resultPath=$agentRef.path
    for($index=$agentIndex+1;$index -lt $old.stages.Count;$index++) {
        $old.stages[$index].status='pending';$old.stages[$index].attemptCount=0
    }
    $oldRef=Pin-PhaseJson 'r2-original/release-report.json' $old
    $recovery=Pin-PhaseJson 'r2-recovery.json' @{result='passed';attemptId=$failedStage.attemptId;
        originalReleaseReportSha256=$oldRef.sha256;originalAgentReportSha256=$agentRef.sha256;
        knownHostEndpoint=$resources.knownHostEndpoint;originalReportsUnchanged=$true;knownHostAbsent=$true}
    $audit=@{gate='agent-continuation-state-audit';result='passed';sourceReportSha256=$oldRef.sha256;
        failedAgentSha256=$agentRef.sha256;candidateSha256=$old.candidate.sha256;target=$arguments.Target;
        observedAt=[DateTimeOffset]::UtcNow.ToString('o');
        agentScriptSha256=(Get-FileHash (Join-Path $fixtureTools 'verify-agent-compatibility-pc.ps1')).Hash.ToLowerInvariant()}
    foreach($field in @('readOnly','knownHostsAbsent','fixtureProcessesAbsent','fixtureDirectoriesAbsent',
        'listenersAbsent','hdcMappingsEmpty','workspaceRestored','notificationRestored','platformUnchanged','prefixIndependent')) {$audit[$field]=$true}
    $manifest=Pin-PhaseJson 'r2-manifest.json' @{schemaVersion=1;scope='agent-split-R2';
        sourceReport=$oldRef;recovery=$recovery;admission=(Pin-PhaseJson 'r2-audit.json' $audit)}
    $arguments.EvidenceDirectory=Join-Path $testRoot 'r2-continued'
    $r2Start=$phaseCalls.Count
    & $entry @arguments -Phase automatic -ContinuationPath $manifest.path
    $continuedPath=Join-Path $arguments.EvidenceDirectory 'release-report.json'
    $continued=Get-Content $continuedPath -Raw | ConvertFrom-Json -Depth 20
    Assert-Phase ($continued.result -eq 'awaiting-operator' -and
        @($continued.stages | Where-Object status -eq 'reused').Count -eq 16) 'R2 split did not preserve candidate plus fifteen independent stages'
    $freshCalls=@($phaseCalls | Select-Object -Skip $r2Start)
    Assert-Phase ($freshCalls.Count -eq 9 -and $freshCalls[0] -eq 'qualify-acceptance-harness-pc.ps1' -and
        $freshCalls[1] -eq 'verify-agent-compatibility-pc.ps1' -and
        @($freshCalls | Where-Object {$_ -like 'operator-*'}).Count -eq 0) 'R2 repeated its prefix or started operator work'
    Assert-Phase ((Get-FileHash $oldRef.path).Hash -ieq $oldRef.sha256) 'R2 changed its original failure'
    & $entry @arguments -Phase operator -Resume
    Assert-Phase ($phaseCalls.Count -eq ($r2Start+11)) 'R2 operator resume repeated an automatic stage'
    $continued=Get-Content $continuedPath -Raw | ConvertFrom-Json -Depth 20
    Assert-Phase ($continued.completeApplicablePhysicalMatrixClaimed) 'R2 could not complete its real validated operator suffix'

    # SSH-local clipboard repair reuses the completed Agent stage as well. Run
    # the real entry and policy, including operator resume, with no model calls.
    $sshOld = $report | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $sshOld.result = 'failed'; $sshOld.completeApplicablePhysicalMatrixClaimed = $false
    $sshIndex = [Array]::IndexOf(@($sshOld.stageOrder), 'ssh-physical-matrix')
    $sshStage = $sshOld.stages[$sshIndex]
    $clipboardFailure = 'Timed out waiting for LeanTTY device state: OSC 52 clipboard write success=true,length=17'
    $sshCandidate = $sshOld.candidate | ConvertTo-Json | ConvertFrom-Json
    $sshCandidate | Add-Member retained $true
    $group = @{result='failed';runMode='acceptance';executionGroup='transport-performance';
        candidate=$sshCandidate;harness=$sshOld.harness;attemptId=('2'*32);failure=$clipboardFailure;
        checks=@(@{name='fixture-and-device-preflight';result='passed'},@{name='ssh-diagnostics';result='passed'});
        performanceMatrix=@{selected=$false};preferences=@{allowedMutation='none'};
        cleanup=@{result='passed';independentKeyAbsenceAudit=$true;independentEcdsaKeyAbsenceAudit=$true;
            knownHostRemovalCommandCompleted=$true;reverseMappingAbsenceAudit=$true;fixtureProcessAbsenceAudit=$true}}
    $groupRef = Pin-PhaseJson 'ssh-original/transport-performance/device-ssh-auth.json' $group
    $matrix = @{schemaVersion=2;scenario='ssh-physical-matrix';result='failed';completedGroups=@();
        fixedOrder=@('transport-performance','authentication-methods','lifecycle-recovery','pane-focus-attention');
        candidate=$sshCandidate;harness=$sshOld.harness;failure=$clipboardFailure}
    $matrixRef = Pin-PhaseJson 'ssh-original/ssh-matrix.json' $matrix
    $sshStage.status='failed'; $sshStage.resultPath=$matrixRef.path; $sshStage.failure=$clipboardFailure
    $sshStage.attemptId=''
    for($index=$sshIndex+1;$index -lt $sshOld.stages.Count;$index++) {
        $sshOld.stages[$index].status='pending'; $sshOld.stages[$index].attemptCount=0
    }
    $sshOldRef = Pin-PhaseJson 'ssh-source/release-report.json' $sshOld
    $sshAudit = @{gate='ssh-continuation-state-audit';result='passed';sourceReportSha256=$sshOldRef.sha256;
        failedGroupSha256=$groupRef.sha256;failedMatrixSha256=$matrixRef.sha256;
        candidateSha256=$sshOld.candidate.sha256;target=$arguments.Target;observedAt=[DateTimeOffset]::UtcNow.ToString('o');
        sshScriptSha256=(Get-FileHash (Join-Path $fixtureTools 'verify-ssh-auth-pc.ps1')).Hash.ToLowerInvariant()}
    foreach($field in @('readOnly','knownHostsAbsent','fixtureProcessesAbsent','fixtureDirectoriesAbsent',
        'listenersAbsent','hdcMappingsEmpty','workspaceRestored','notificationRestored','platformUnchanged','prefixIndependent')) {$sshAudit[$field]=$true}
    $sshManifestValue = @{schemaVersion=1;scope='ssh-native-clipboard-R2';sourceReport=$sshOldRef;
        failedGroup=$groupRef;admission=(Pin-PhaseJson 'ssh-audit.json' $sshAudit)}
    $sshManifest = Pin-PhaseJson 'ssh-manifest.json' $sshManifestValue
    $arguments.EvidenceDirectory=Join-Path $testRoot 'ssh-continued'
    $sshStart=$phaseCalls.Count
    & $entry @arguments -Phase automatic -ContinuationPath $sshManifest.path
    $sshContinued=Get-Content (Join-Path $arguments.EvidenceDirectory 'release-report.json') -Raw | ConvertFrom-Json -Depth 30
    $sshFreshCalls=@($phaseCalls | Select-Object -Skip $sshStart)
    Assert-Phase ($sshContinued.result -eq 'awaiting-operator' -and
        @($sshContinued.stages | Where-Object status -eq 'reused').Count -eq 17 -and
        $sshContinued.continuation.newPlannedModelRequests -eq 0) 'SSH continuation lost its formal prefix or zero-model scope'
    Assert-Phase ($sshFreshCalls.Count -eq 8 -and $sshFreshCalls[0] -eq 'qualify-acceptance-harness-pc.ps1' -and
        $sshFreshCalls[1] -eq 'verify-ssh-matrix-pc.ps1' -and
        @($sshFreshCalls | Where-Object {$_ -match 'agent|long-task|operator'}).Count -eq 0) 'SSH continuation repeated model work or skipped qualification/SSH'
    & $entry @arguments -Phase operator -Resume
    Assert-Phase ($phaseCalls.Count -eq ($sshStart+10)) 'SSH continuation repeated automatic work during operator resume'
    Assert-Phase ((Get-FileHash $sshOldRef.path).Hash -ieq $sshOldRef.sha256) 'SSH continuation rewrote its original failure'
    . (Join-Path $fixtureTools 'release-agent-continuation.ps1')
    $sshPolicy = @{Manifest=$sshManifestValue;Candidate=$sshOld.candidate;Invocation=$sshOld.invocation;RepoRoot=$fixtureRoot}
    foreach($field in @('independentKeyAbsenceAudit','independentEcdsaKeyAbsenceAudit','knownHostRemovalCommandCompleted',
        'reverseMappingAbsenceAudit','fixtureProcessAbsenceAudit')) {
        $group.cleanup[$field]=$false
        $sshManifestValue.failedGroup=Pin-PhaseJson 'ssh-original/transport-performance/device-ssh-auth.json' $group
        Assert-PhaseRejected { Get-LeanTTYReleaseContinuation @sshPolicy } '*SSH cleanup is unproved*'
        $group.cleanup[$field]=$true
    }
    $group.failure='different product failure'
    $sshManifestValue.failedGroup=Pin-PhaseJson 'ssh-original/transport-performance/device-ssh-auth.json' $group
    Assert-PhaseRejected { Get-LeanTTYReleaseContinuation @sshPolicy } '*outside the qualified clipboard repair*'
    $group.failure=$clipboardFailure
    $sshManifestValue.failedGroup=Pin-PhaseJson 'ssh-original/transport-performance/device-ssh-auth.json' $group
    $matrix.completedGroups=@(@{name='transport-performance';result='passed'})
    $null=Pin-PhaseJson 'ssh-original/ssh-matrix.json' $matrix
    Assert-PhaseRejected { Get-LeanTTYReleaseContinuation @sshPolicy } '*original first-group failure*'
    $matrix.completedGroups=@(); $null=Pin-PhaseJson 'ssh-original/ssh-matrix.json' $matrix
    foreach($path in @('tools/verify-ssh-auth-pc.ps1','tools/test-device-regression.ps1',
        'tools/verify-release-pc.ps1','tools/release-agent-continuation.ps1','tools/test-release-agent-continuation.ps1',
        'tools/test-release-phases.ps1','docs/next-work.md','docs/quality-strategy.md')) {
        $phaseChangedPaths=@($path)
        $qualified=Get-LeanTTYReleaseContinuation @sshPolicy
        Assert-Phase ($qualified.newPlannedModelRequests -eq 0) 'Allowed SSH tool repair lost zero-model continuation'
    }
    foreach($path in @('tools/device-regression.ps1','tools/hdc-common.ps1','tools/verify-agent-compatibility-pc.ps1',
        'tools/verify-long-task-notification-pc.ps1','tools/verify-mosh-pc.ps1','entry/src/main/ets/model/terminal/NativeTerminalController.ets')) {
        $phaseChangedPaths=@($path)
        Assert-PhaseRejected { Get-LeanTTYReleaseContinuation @sshPolicy } '*'
    }
    $phaseChangedPaths=@()
    $phaseChangedPaths=@('tools/verify-ssh-auth-pc.ps1'); $phaseChangeIndependentSsh=$true
    Assert-PhaseRejected { Get-LeanTTYReleaseContinuation @sshPolicy } '*outside native terminal owners*'
    $phaseChangedPaths=@(); $phaseChangeIndependentSsh=$false
    $group.runMode='diagnostic'
    $sshManifestValue.failedGroup=Pin-PhaseJson 'ssh-original/transport-performance/device-ssh-auth.json' $group
    Assert-PhaseRejected { Get-LeanTTYReleaseContinuation @sshPolicy } '*original first-group failure*'
    $group.runMode='acceptance'; $group.performanceMatrix.selected=$true
    $sshManifestValue.failedGroup=Pin-PhaseJson 'ssh-original/transport-performance/device-ssh-auth.json' $group
    Assert-PhaseRejected { Get-LeanTTYReleaseContinuation @sshPolicy } '*pre-performance clipboard boundary*'
    $group.performanceMatrix.selected=$false
    $sshManifestValue.failedGroup=Pin-PhaseJson 'ssh-original/transport-performance/device-ssh-auth.json' $group
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
