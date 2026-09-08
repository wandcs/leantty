param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-tooling.ps1')
. (Join-Path $PSScriptRoot 'package-policy.ps1')

function Assert-RuntimeContract {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-RuntimeContractRejected {
    param([scriptblock]$Action, [string]$Message)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-RuntimeContract $rejected $Message
}

# Load the real pure readers, not the verifiers' device entry points.
foreach ($source in @(
    @{ path = 'verify-mosh-pc.ps1'; name = 'Get-MoshRuntimeReclaimObservation' },
    @{ path = 'verify-mosh-matrix-pc.ps1'; name = 'Assert-MoshScenarioEvidence' }
)) {
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot $source.path), [ref]$null, [ref]$null)
    $definitions = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $source.name
    }, $true))
    Assert-RuntimeContract ($definitions.Count -eq 1) "Missing or ambiguous reader: $($source.name)"
    Invoke-Expression $definitions[0].Extent.Text
}

$expectedOrder = @('compatibility', 'runtime-reclaim', 'pause-recovery', 'suspend-recovery',
    'operator-lock-recovery', 'operator-lid-recovery', 'wifi-pause-recovery', 'wifi-network-switch')
Assert-RuntimeContract (((Get-LeanTTYMoshFormalScenarios) -join ',') -ceq ($expectedOrder -join ',')) (
    'Formal Mosh order must prove controlled recovery before operator/network actions'
)
foreach ($path in @('verify-mosh-pc.ps1', 'verify-mosh-matrix-pc.ps1')) {
    Assert-RuntimeContract ((Get-Content (Join-Path $PSScriptRoot $path) -Raw).Contains(
        '@(Get-LeanTTYMoshFormalScenarios)')) "Verifier has a separate scenario owner: $path"
}

$logs = @(
    'ACCEPTANCE_RUNTIME_RECLAIM state=dropped,pane=fixture-pane',
    'Terminal input withheld for runtime recovery',
    'Runtime session state reclaimed; workspace-only recovery=true,panes=1,nativeCancelRequests=1',
    'ACCEPTANCE_RUNTIME_RECOVERY workspaceSame=true,localBufferUnits=0'
) -join "`n"
$contract = Get-MoshRuntimeReclaimObservation -Logs ($logs + "`nignored-private-text")
Assert-RuntimeContract ($contract.localBufferUnits -eq 0 -and $contract.nativeCancelRequests -eq 1 -and
    $contract.graphDropped -and $contract.firstInputWithheld -and $contract.workspaceIdentityPreserved) (
    'Owner observations were not parsed correctly'
)
Assert-RuntimeContract (($contract | ConvertTo-Json -Depth 8) -notmatch 'ignored-private-text|fixture-pane') (
    'Observation reader retained raw content or workspace identifiers'
)
foreach ($invalid in @('no-observations', ($logs + "`n" + $logs),
    $logs.Replace('localBufferUnits=0', 'localBufferUnits=unknown'),
    $logs.Replace('nativeCancelRequests=1', 'nativeCancelRequests=unknown'))) {
    Assert-RuntimeContractRejected { Get-MoshRuntimeReclaimObservation -Logs $invalid } (
        'Missing, malformed or ambiguous observations were accepted'
    )
}
$contract.beforeProcess = @{ processId = '123'; startTimeTicks = '456' }
$contract.afterProcess = @{ processId = '123'; startTimeTicks = '456' }
$contract.serverAbsent = $true
$contract.ptyAbsent = $true
$contract.localCommandPassed = $true
Assert-LeanTTYRuntimeReclaimEvidence -Evidence $contract
$validJson = $contract | ConvertTo-Json -Depth 8

foreach ($field in @('graphDropped', 'firstInputWithheld', 'workspaceIdentityPreserved',
    'serverAbsent', 'ptyAbsent', 'localCommandPassed')) {
    foreach ($value in @($false, $null, 'true')) {
        $bad = $validJson | ConvertFrom-Json -AsHashtable
        $bad[$field] = $value
        Assert-RuntimeContractRejected { Assert-LeanTTYRuntimeReclaimEvidence -Evidence $bad } (
            "Unproved boolean accepted: $field"
        )
    }
}
foreach ($case in @(
    @{ field = 'contractVersion'; value = 0 },
    @{ field = 'trigger'; value = 'physical-lid' },
    @{ field = 'localBufferUnits'; value = 1 },
    @{ field = 'localBufferUnits'; value = '0' },
    @{ field = 'localBufferUnits'; value = $null },
    @{ field = 'recoveredPaneCount'; value = 0 },
    @{ field = 'nativeCancelRequests'; value = 0 },
    @{ field = 'nativeCancelRequests'; value = -1 }
)) {
    $bad = $validJson | ConvertFrom-Json -AsHashtable
    $bad[$case.field] = $case.value
    Assert-RuntimeContractRejected { Assert-LeanTTYRuntimeReclaimEvidence -Evidence $bad } (
        "Invalid runtime contract accepted: $($case.field)"
    )
}
foreach ($field in @('processId', 'startTimeTicks')) {
    $bad = $validJson | ConvertFrom-Json -AsHashtable
    $bad.afterProcess[$field] = '999'
    Assert-RuntimeContractRejected { Assert-LeanTTYRuntimeReclaimEvidence -Evidence $bad } (
        "Process replacement or PID reuse accepted: $field"
    )
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('leantty-runtime-contract-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $candidateSha256 = 'a' * 64; $candidateCommit = 'b' * 40; $candidateTree = 'c' * 40
    $harnessCommit = 'd' * 40; $harnessTree = 'e' * 40
    $formal = @{
        schemaVersion = 2; gate = '1.6-mosh-physical-acceptance'; result = 'passed'
        acceptanceEligible = $true; verificationMode = 'device-behavior-acceptance'; scenario = 'runtime-reclaim'
        candidate = @{ hapSha256 = $candidateSha256; gitCommit = $candidateCommit; gitTree = $candidateTree; gitDirty = $false }
        harness = @{ gitCommit = $harnessCommit; gitTree = $harnessTree; gitDirty = $false }
        cleanup = @{ result = 'passed'; deviceStateRemoved = $true; fixtureProcessesAbsent = $true
            fixtureReverseMappingRemoved = $true; persistentNetworkPreserved = $true; temporaryDirectoryRemoved = $true }
        preferences = @{ unchanged = $true }
        checks = @{ secretPatternAbsent = $true; bootstrapTextAbsentFromTerminal = $true }
        lastProvenBoundary = 'cleanup-complete'; runtimeReclaim = $contract
        processRecovery = @{ exercised = $true; runtimeReclaimed = $true; workspaceWarningObserved = $true
            remoteContentAbsent = $true; sessionNotRestored = $true }
    }
    $evidencePath = Join-Path $testRoot 'runtime.json'
    [IO.File]::WriteAllText($evidencePath, ($formal | ConvertTo-Json -Depth 12))
    Assert-MoshScenarioEvidence -Path $evidencePath -Scenario runtime-reclaim | Out-Null
    foreach ($invalidContract in @($null, @{ contractVersion = 1 },
        ($validJson.Replace('"localBufferUnits": 0', '"localBufferUnits": 1') | ConvertFrom-Json))) {
        $formal.runtimeReclaim = $invalidContract
        [IO.File]::WriteAllText($evidencePath, ($formal | ConvertTo-Json -Depth 12))
        Assert-RuntimeContractRejected { Assert-MoshScenarioEvidence -Path $evidencePath -Scenario runtime-reclaim } (
            'Matrix accepted a headline pass without valid runtime evidence'
        )
    }
    $formal.runtimeReclaim = $contract
    foreach ($field in @('exercised', 'runtimeReclaimed', 'workspaceWarningObserved',
        'remoteContentAbsent', 'sessionNotRestored')) {
        $formal.processRecovery[$field] = $false
        [IO.File]::WriteAllText($evidencePath, ($formal | ConvertTo-Json -Depth 12))
        Assert-RuntimeContractRejected { Assert-MoshScenarioEvidence -Path $evidencePath -Scenario runtime-reclaim } (
            "Matrix accepted invalid local recovery evidence: $field"
        )
        $formal.processRecovery[$field] = $true
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    foreach ($marker in @('ACCEPTANCE_RUNTIME_RECLAIM', 'ACCEPTANCE_RUNTIME_RECOVERY',
        'reclaimRuntimeForAcceptance', 'reclaimRuntimeStateForAcceptance', 'localInputUnitsForAcceptance',
        'runtimeWorkspaceIdentityForAcceptance', 'observeRuntimeRecoveryForAcceptance', 'acceptanceRuntimeWorkspace')) {
        $packagePath = Join-Path $testRoot ($marker + '.hap')
        $zip = [IO.Compression.ZipFile]::Open($packagePath, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $stream = $zip.CreateEntry('modules.abc').Open()
            try { $bytes = [Text.Encoding]::UTF8.GetBytes($marker); $stream.Write($bytes, 0, $bytes.Length) }
            finally { $stream.Dispose() }
        } finally { $zip.Dispose() }
        Assert-RuntimeContractRejected { Assert-LeanTTYReleasePackageExcludesAcceptanceMarkers -PackagePath $packagePath } (
            "Production package accepted runtime test hook: $marker"
        )
    }
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if ((Split-Path $resolvedRoot -Parent) -cne $expectedParent -or
        (Split-Path $resolvedRoot -Leaf) -notmatch '^leantty-runtime-contract-[0-9a-f]{32}$') {
        throw 'Unsafe runtime-contract test cleanup path'
    }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
Write-Host 'Mosh runtime-reclaim observation, evidence, matrix and package contracts passed.'
