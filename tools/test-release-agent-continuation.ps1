param([string]$EntrySourceRevision = '', [switch]$SplitOperator)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$entry = if ($EntrySourceRevision) {
    (& git -C $repoRoot show ($EntrySourceRevision + ':tools/verify-release-pc.ps1')) -join "`n"
} else { Get-Content -LiteralPath (Join-Path $PSScriptRoot 'verify-release-pc.ps1') -Raw }
if ($entry -notmatch '\[string\]\$ContinuationPath') { throw 'Formal entry cannot represent Agent R2 continuation' }
. (Join-Path $PSScriptRoot 'candidate-store.ps1')
. (Join-Path $PSScriptRoot 'release-tooling.ps1')
. (Join-Path $PSScriptRoot 'release-agent-continuation.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('leantty-continuation-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$passed = 0
function Pin-TestJson($Name, $Value) {
    $path = Join-Path $testRoot $Name
    Write-LeanTTYAtomicJson -Path $path -Value $Value -Depth 20
    [pscustomobject]@{path=$path;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
}
function Assert-Rejected($Name, [scriptblock]$Action) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw "Continuation incorrectly accepted: $Name" }
    $script:passed++
}
$script:changedPaths = @()
function git {
    $global:LASTEXITCODE = 0
    if ($args -contains 'rev-parse') { return ('b' * 40) }
    if ($args -contains 'diff') { return $script:changedPaths }
    if ($args -contains 'show') {
        $relative=($args[-1] -split ':',2)[1]
        Get-Content -LiteralPath (Join-Path $repoRoot $relative)
        if ($script:changeIndependentBody) { '# changed independent behavior boundary' }
    }
}
try {
    $candidate = [pscustomobject]@{gitCommit=('c'*40);gitTree=('d'*40);sha256=('e'*64);gitDirty=$false}
    $invocation = [pscustomobject]@{target='fixture';candidateBasePath='';fixturePort=22000;longTaskPort=23000;agentPort=0;moshAlternateWifiSsidIdentity=('f'*64);distribution='test-wsl'}
    $harness = @{gitCommit=('a'*40);gitTree=('b'*40);gitDirty=$false}
    $defs = @(Get-LeanTTYReleaseVerificationStages -SplitOperator:$SplitOperator)
    $failedIndex = [Array]::IndexOf(@($defs.name), 'agent-compatibility')
    $stages = @($defs | ForEach-Object {
        $evidence = @{result='passed';cleanup=@{result='passed'};candidate=$candidate;harness=$harness;reviewTestHap=@{sha256=$candidate.sha256};releaseEligible=$true;runMode='formal'}
        $reference = Pin-TestJson ($_.name + '.json') $evidence
        [pscustomobject]@{name=$_.name;script=$_.script;status='passed';resultPath=$reference.path;attemptId='';attemptCount=1}
    })
    $resources = @{knownHostEndpoint='[127.0.0.1]:32000';tabCleanup=@{ownedTabRemoved=$true;originalTabsRestored=$true;originalActiveTabRestored=$true};notificationPermission=@{restored=$true}}
    $agent = @{status='invalid/interrupted';runMode='acceptance';harness=$harness;candidate=$candidate;attemptId='original-attempt';resources=$resources;cleanup=@{result=$(if ($SplitOperator) {'passed'} else {'failed'})}}
    $agentRef = Pin-TestJson 'failed-agent.json' $agent
    $stages[$failedIndex].status='failed'; $stages[$failedIndex].attemptId='original-attempt'; $stages[$failedIndex].resultPath=$agentRef.path
    for ($index=$failedIndex+1;$index -lt $stages.Count;$index++) {
        $stages[$index].status='pending'; $stages[$index].attemptCount=0
    }
    $old = [pscustomobject]@{schemaVersion=1;gate='registered-release-verification';result='failed';stageOrder=@($defs.name);stages=$stages;candidate=$candidate;harness=$harness;invocation=$invocation}
    $oldRef = Pin-TestJson 'old.json' $old
    $recovery = [pscustomobject]@{result='passed';attemptId='original-attempt';originalReleaseReportSha256=$oldRef.sha256;originalAgentReportSha256=$agentRef.sha256;knownHostEndpoint=$resources.knownHostEndpoint;originalReportsUnchanged=$true;knownHostAbsent=$true}
    $recoveryRef = Pin-TestJson 'recovery.json' $recovery
    $admission = [pscustomobject]@{gate='agent-continuation-state-audit';result='passed';sourceReportSha256=$oldRef.sha256;failedAgentSha256=$agentRef.sha256;candidateSha256=$candidate.sha256;target='fixture';observedAt=[DateTimeOffset]::UtcNow.ToString('o');agentScriptSha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'verify-agent-compatibility-pc.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()}
    $stateFields = @('readOnly','knownHostsAbsent','fixtureProcessesAbsent','fixtureDirectoriesAbsent','listenersAbsent','hdcMappingsEmpty','workspaceRestored','notificationRestored','platformUnchanged','prefixIndependent')
    foreach ($field in $stateFields) { $admission | Add-Member $field $true }
    $manifest = [pscustomobject]@{schemaVersion=1;scope=$(if ($SplitOperator) {'agent-split-R2'} else {'agent-exit-boundary-R2'});sourceReport=$oldRef;recovery=$recoveryRef;admission=(Pin-TestJson 'admission.json' $admission)}
    $argsForPolicy = @{Manifest=$manifest;Candidate=$candidate;Invocation=$invocation;RepoRoot=$repoRoot}
    $result = Get-LeanTTYReleaseContinuation @argsForPolicy
    if ($result.prefix.Count -ne ($failedIndex-2) -or $result.failedIndex -ne $failedIndex -or $result.failedAttemptId -cne 'original-attempt' -or
        $result.prefix.stage.name -contains 'harness-qualification' -or
        (Read-LeanTTYPinnedReleaseJson $oldRef).result -cne 'failed') { throw 'Valid continuation lost its prefix, fresh QH or immutable failure' }
    $passed++
    $newStages = $stages | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    foreach ($inherited in $result.prefix) {
        $stage = $newStages[$inherited.index]
        $stage.status='reused'
        $stage | Add-Member sourceEvidenceSha256 $inherited.sha256
        $stage | Add-Member cleanup 'passed'
    }
    $continuedReport = [pscustomobject]@{stages=$newStages}
    Assert-LeanTTYInheritedReleaseStages -Report $continuedReport -Validated $result; $passed++
    foreach ($field in @('name','status','resultPath','sourceEvidenceSha256','cleanup')) {
        $saved = $newStages[2].$field; $newStages[2].$field='changed'
        Assert-Rejected "imported checkpoint $field" { Assert-LeanTTYInheritedReleaseStages -Report $continuedReport -Validated $result }
        $newStages[2].$field=$saved
    }
    $oldBaseline = $old | ConvertTo-Json -Depth 20
    $oldMutations = @(
        {param($x) $x.stageOrder[2]='other'},
        {param($x) $x.stages[0].status='pending'},
        {param($x) $x.stages[2].name='other'},
        {param($x) $x.stages[2].status='failed'},
        {param($x) $x.stages[$failedIndex].status='passed'},
        {param($x) $x.stages[-1].attemptCount=1},
        {param($x) $x.harness.gitDirty=$true},
        {param($x) $x.candidate.gitDirty=$true}
    )
    foreach ($mutation in $oldMutations) {
        $changedOld=$oldBaseline | ConvertFrom-Json -Depth 20
        & $mutation $changedOld
        $manifest.sourceReport=Pin-TestJson 'old.json' $changedOld
        $recovery.originalReleaseReportSha256=$manifest.sourceReport.sha256
        $manifest.recovery=Pin-TestJson 'recovery.json' $recovery
        $admission.sourceReportSha256=$manifest.sourceReport.sha256
        $manifest.admission=Pin-TestJson 'admission.json' $admission
        Assert-Rejected 'malformed original checkpoint' { Get-LeanTTYReleaseContinuation @argsForPolicy }
    }
    $manifest.sourceReport=Pin-TestJson 'old.json' $old
    $recovery.originalReleaseReportSha256=$manifest.sourceReport.sha256
    $manifest.recovery=Pin-TestJson 'recovery.json' $recovery
    $admission.sourceReportSha256=$manifest.sourceReport.sha256
    $manifest.admission=Pin-TestJson 'admission.json' $admission
    if ($SplitOperator) {
        $agent.cleanup.result='failed'
        $null=Pin-TestJson 'failed-agent.json' $agent
        Assert-Rejected 'split cleanup cannot be waived by recovery' { Get-LeanTTYReleaseContinuation @argsForPolicy }
        $agent.cleanup.result='passed'
        $null=Pin-TestJson 'failed-agent.json' $agent
    }
    foreach ($field in $stateFields) {
        $admission.$field = $false; $manifest.admission = Pin-TestJson 'admission.json' $admission
        Assert-Rejected $field { Get-LeanTTYReleaseContinuation @argsForPolicy }
        $admission.$field = $true
    }
    $admission.observedAt = [DateTimeOffset]::UtcNow.AddMinutes(-11).ToString('o')
    $manifest.admission = Pin-TestJson 'admission.json' $admission
    Assert-Rejected 'stale admission' { Get-LeanTTYReleaseContinuation @argsForPolicy }
    Get-LeanTTYReleaseContinuation @argsForPolicy -Recheck | Out-Null; $passed++
    $admission.observedAt = [DateTimeOffset]::UtcNow.ToString('o')
    $admission.agentScriptSha256 = '0'*64; $manifest.admission=Pin-TestJson 'admission.json' $admission
    Assert-Rejected 'repaired script drift' { Get-LeanTTYReleaseContinuation @argsForPolicy }
    $admission.agentScriptSha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'verify-agent-compatibility-pc.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest.admission=Pin-TestJson 'admission.json' $admission
    foreach ($field in @('gitCommit','gitTree','sha256')) {
        $saved=$candidate.$field; $candidate.$field='0'*$saved.Length
        Assert-Rejected "candidate $field" { Get-LeanTTYReleaseContinuation @argsForPolicy }
        $candidate.$field=$saved
    }
    foreach ($field in $invocation.PSObject.Properties.Name) {
        $saved=$invocation.$field; $invocation.$field='changed'
        Assert-Rejected "invocation $field" { Get-LeanTTYReleaseContinuation @argsForPolicy }
        $invocation.$field=$saved
    }
    foreach ($path in @('tools/test-agent-attention-gate.ps1', 'tools/agent-compatibility-policy.ps1', 'AGENTS.md',
            'tools/agent-compatibility/capture_notification.sh',
            'tools/agent-compatibility/start_gate.py',
            'tools/agent-compatibility/test_start_gate.py',
            'tools/agent-compatibility/observe_attention.py',
            'tools/agent-compatibility/attention_observer_probe.py',
            'tools/agent-compatibility/test_observe_attention.py',
            'tools/agent-compatibility/test_observe_attention_pty.py')) {
        $script:changedPaths=@($path)
        Get-LeanTTYReleaseContinuation @argsForPolicy | Out-Null
        $passed++
    }
    $script:changedPaths=@('docs/design/agent-notification-order-20260912.md')
    Get-LeanTTYReleaseContinuation @argsForPolicy | Out-Null
    $passed++
    foreach($owner in @('tools/verify-ssh-auth-pc.ps1','tools/verify-mosh-pc.ps1',
            'tools/verify-terminal-search-pc.ps1','tools/verify-long-task-notification-pc.ps1')) {
        $script:changedPaths=@($owner)
        Get-LeanTTYReleaseContinuation @argsForPolicy | Out-Null
        $passed++
        $script:changeIndependentBody=$true
        Assert-Rejected 'independent owner changed outside admission array' { Get-LeanTTYReleaseContinuation @argsForPolicy }
        $script:changeIndependentBody=$false
    }
    foreach ($path in @('tools/device-regression.ps1','tools/hdc-common.ps1','tools/release-tooling.ps1','entry/src/main/ets/Test.ets','leantty_ssh/Cargo.lock','tools/notification-regression.ps1','tools/agent-compatibility-wsl.sh','tools/agent-compatibility/analyze_capture.py', 'docs/design/unreviewed.md', 'docs/design/agent-notification-order-20260912.md.ps1')) {
        $script:changedPaths=@($path)
        Assert-Rejected "shared or product path $path" { Get-LeanTTYReleaseContinuation @argsForPolicy }
    }
    $script:changedPaths=@()
    $originalHash=$manifest.sourceReport.sha256; $manifest.sourceReport.sha256='0'*64
    Assert-Rejected 'old report hash' { Get-LeanTTYReleaseContinuation @argsForPolicy }
    $manifest.sourceReport.sha256=$originalHash
    $prefixPath=$stages[2].resultPath
    Write-LeanTTYAtomicJson -Path $prefixPath -Value @{result='failed';cleanup=@{result='passed'}}
    Assert-Rejected 'failed prefix evidence' { Get-LeanTTYReleaseContinuation @argsForPolicy }
    Write-LeanTTYAtomicJson -Path $prefixPath -Value @{result='passed';cleanup=@{result='failed'}}
    Assert-Rejected 'unproved prefix cleanup' { Get-LeanTTYReleaseContinuation @argsForPolicy }
    Write-Host "AGENT RELEASE CONTINUATION TESTS PASSED: $passed"
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $resolved -Leaf) -like 'leantty-continuation-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
if (-not $SplitOperator) { & $PSCommandPath -SplitOperator -EntrySourceRevision $EntrySourceRevision }
