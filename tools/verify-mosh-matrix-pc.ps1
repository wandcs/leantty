<#
.SYNOPSIS
  Run the formal LeanTTY Mosh network and lifecycle matrix in one fixed order.
.DESCRIPTION
  Reuses one retained candidate while each authoritative Mosh scenario owns its
  fixture, network impairment and cleanup. The matrix stops at the first failure
  and never retries automatically. -Resume validates exact identities and every
  passing checkpoint before rerunning the failed scenario and remaining suffix.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Target,
    [string]$HapPath = '',
    [string]$CandidateBasePath = '',
    [ValidateRange(1024, 65535)][int]$FixturePort = 2223,
    [ValidateRange(1024, 65535)][int]$FixtureBackendPort = 32223,
    [string]$ServerAddress = '192.168.1.4',
    [string]$RemoteScope = '192.168.1.0/24',
    [Parameter(Mandatory = $true)][string]$AlternateWifiSsid,
    [ValidateRange(1024, 65535)][int]$SshComparisonPort = 2222,
    [string]$SshComparisonUser = '',
    [ValidateSet('id_ed25519', 'id_rsa', 'id_ecdsa')]
    [string]$SshComparisonIdentity = 'id_ed25519',
    [ValidateRange(30, 300)][int]$OperatorWaitSeconds = 120,
    [string]$Distribution = $env:LEANTTY_WSL_DISTRO,
    [string]$EvidenceDirectory = '',
    [switch]$Resume
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'candidate-store.ps1')
. (Join-Path $PSScriptRoot 'release-tooling.ps1')

$scenarios = @(
    'compatibility',
    'pause-recovery',
    'suspend-recovery',
    'operator-lock-recovery',
    'operator-lid-recovery',
    'wifi-pause-recovery',
    'wifi-network-switch'
)
if ($FixtureBackendPort -eq $FixturePort) {
    throw 'FixtureBackendPort must differ from the external FixturePort'
}
if ([string]::IsNullOrWhiteSpace($AlternateWifiSsid) -or
    $AlternateWifiSsid.Length -gt 32 -or
    $AlternateWifiSsid -match '[\x00-\x1f\x7f]') {
    throw 'AlternateWifiSsid must name one saved Wi-Fi network without control characters'
}
$candidate = Resolve-LeanTTYRetainedCandidate `
    -RepoRoot $repoRoot -HapPath $HapPath -CandidateBasePath $CandidateBasePath
if ([bool]$candidate.gitDirty -or
    [string]$candidate.verificationMode -notin @('device-deployed', 'device-behavior')) {
    throw 'Formal Mosh matrix requires a clean device-deployed retained candidate'
}
$selectedHapPath = [string]$candidate.hapPath
$candidateSha256 = [string]$candidate.sha256
$candidateCommit = [string]$candidate.gitCommit
$candidateTree = [string]$candidate.gitTree

$harnessStatus = @(git -C $repoRoot status --porcelain --untracked-files=all 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect Mosh matrix harness state' }
if ($harnessStatus.Count -gt 0) { throw 'Formal Mosh matrix requires a clean committed harness' }
$harnessCommit = (& git -C $repoRoot rev-parse HEAD 2>&1).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve Mosh matrix harness commit' }
$harnessTree = (& git -C $repoRoot rev-parse 'HEAD^{tree}' 2>&1).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve Mosh matrix harness tree' }

$startedAt = [DateTimeOffset]::UtcNow
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    if ($Resume) { throw '-Resume requires an explicit existing EvidenceDirectory' }
    $EvidenceDirectory = Join-Path $repoRoot (
        'build\verification\device-mosh-matrix-' + $startedAt.ToString('yyyyMMddTHHmmssfffZ')
    )
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$matrixPath = Join-Path $EvidenceDirectory 'mosh-matrix.json'
$progressPath = Join-Path $EvidenceDirectory 'progress.json'
$completedScenarios = [Collections.Generic.List[object]]::new()
$attemptCounts = @{}
$resumeCount = 0
$failedScenario = ''
$failedAttemptId = ''
$failedEvidence = ''
$failure = ''
$matrixResult = 'failed'
$caughtError = $null
$alternateWifiSsidIdentity = Get-LeanTTYHashIdentity -Value $AlternateWifiSsid

function Get-MoshMatrixInvocation {
    return [ordered]@{
        target = $Target
        fixturePort = $FixturePort
        fixtureBackendPort = $FixtureBackendPort
        serverAddress = $ServerAddress
        remoteScope = $RemoteScope
        alternateWifiSsidIdentity = $alternateWifiSsidIdentity
        sshComparisonPort = $SshComparisonPort
        sshComparisonUserMode = $(if ([string]::IsNullOrWhiteSpace($SshComparisonUser)) {
            'default-wsl-user'
        } else { 'explicit' })
        sshComparisonUserIdentity = $(if ([string]::IsNullOrWhiteSpace($SshComparisonUser)) {
            ''
        } else { Get-LeanTTYHashIdentity -Value $SshComparisonUser })
        sshComparisonIdentity = $SshComparisonIdentity
        operatorWaitSeconds = $OperatorWaitSeconds
        distribution = [string]$Distribution
    }
}

function Write-MoshMatrixEvidence {
    Write-LeanTTYAtomicJson -Path $matrixPath -Value ([ordered]@{
        schemaVersion = 1
        gate = '1.6-mosh-formal-matrix'
        result = $matrixResult
        acceptanceEligible = ($matrixResult -eq 'passed')
        startedAt = $startedAt.ToString('o')
        completedAt = [DateTimeOffset]::UtcNow.ToString('o')
        durationMs = [long]([DateTimeOffset]::UtcNow - $startedAt).TotalMilliseconds
        resumeCount = $resumeCount
        fixedOrder = @($scenarios)
        invocation = Get-MoshMatrixInvocation
        candidate = [ordered]@{
            hapPath = $selectedHapPath
            sha256 = $candidateSha256
            gitCommit = $candidateCommit
            gitTree = $candidateTree
            verificationMode = [string]$candidate.verificationMode
        }
        harness = [ordered]@{
            gitCommit = $harnessCommit
            gitTree = $harnessTree
            gitDirty = $false
        }
        attempts = @($scenarios | Where-Object { $attemptCounts.ContainsKey($_) } |
            ForEach-Object { [ordered]@{ scenario = $_; count = [int]$attemptCounts[$_] } })
        completedScenarios = @($completedScenarios)
        failedScenario = $failedScenario
        failedAttemptId = $failedAttemptId
        failedEvidence = $failedEvidence
        failure = $failure
        cleanup = [ordered]@{
            result = $(if ($matrixResult -eq 'passed') { 'passed' } else { 'see-failed-stage' })
            policy = 'every-scenario-must-report-device-fixture-mapping-network-and-temporary-directory-cleanup'
        }
        resumePolicy = 'explicit-same-candidate-harness-invocation-and-valid-passing-prefix-only'
    }) -Depth 12
}

function Write-MoshMatrixProgress {
    param([Parameter(Mandatory = $true)][string]$Stage)

    Write-LeanTTYAtomicJson -Path $progressPath -Value ([ordered]@{
        schemaVersion = 1
        scenario = '1.6-mosh-formal-matrix'
        stage = $Stage
        completedScenarioCount = $completedScenarios.Count
        totalScenarioCount = $scenarios.Count
        updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        contentRecorded = $false
    })
}

function Assert-MoshScenarioEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Scenario
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Mosh scenario evidence is missing: $Path"
    }
    $evidence = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) |
        ConvertFrom-Json -Depth 20
    if ([int]$evidence.schemaVersion -lt 2 -or
        [string]$evidence.gate -ne '1.6-mosh-physical-acceptance' -or
        [string]$evidence.result -ne 'passed' -or
        -not [bool]$evidence.acceptanceEligible -or
        [string]$evidence.verificationMode -ne 'device-behavior-acceptance' -or
        [string]$evidence.scenario -ne $Scenario) {
        throw "Mosh scenario did not produce formal passing evidence: $Scenario"
    }
    if ([string]$evidence.candidate.hapSha256 -ne $candidateSha256 -or
        [string]$evidence.candidate.gitCommit -ne $candidateCommit -or
        [string]$evidence.candidate.gitTree -ne $candidateTree -or
        [bool]$evidence.candidate.gitDirty) {
        throw "Mosh candidate identity changed: $Scenario"
    }
    if ([string]$evidence.harness.gitCommit -ne $harnessCommit -or
        [string]$evidence.harness.gitTree -ne $harnessTree -or
        [bool]$evidence.harness.gitDirty) {
        throw "Mosh harness identity changed: $Scenario"
    }
    if ([string]$evidence.cleanup.result -ne 'passed' -or
        -not [bool]$evidence.cleanup.deviceStateRemoved -or
        -not [bool]$evidence.cleanup.fixtureProcessesAbsent -or
        -not [bool]$evidence.cleanup.fixtureReverseMappingRemoved -or
        -not [bool]$evidence.cleanup.persistentNetworkPreserved -or
        -not [bool]$evidence.cleanup.temporaryDirectoryRemoved -or
        -not [bool]$evidence.preferences.unchanged -or
        -not [bool]$evidence.checks.secretPatternAbsent -or
        -not [bool]$evidence.checks.bootstrapTextAbsentFromTerminal -or
        [string]$evidence.lastProvenBoundary -ne 'cleanup-complete') {
        throw "Mosh cleanup, Preferences or secret audit did not pass: $Scenario"
    }
    if ($Scenario -eq 'wifi-network-switch' -and
        -not [bool]$evidence.networkSwitchComparison.originalNetworkRestored) {
        throw 'Mosh network-switch scenario did not restore the original Wi-Fi network'
    }
    return $evidence
}

if ($Resume) {
    if (-not (Test-Path -LiteralPath $matrixPath -PathType Leaf)) {
        throw "Mosh matrix resume checkpoint is missing: $matrixPath"
    }
    $previous = [IO.File]::ReadAllText($matrixPath, [Text.Encoding]::UTF8) |
        ConvertFrom-Json -Depth 20
    if ([int]$previous.schemaVersion -ne 1 -or
        [string]$previous.gate -ne '1.6-mosh-formal-matrix' -or
        (@($previous.fixedOrder) -join '|') -ne ($scenarios -join '|')) {
        throw 'Mosh matrix contract changed; start a new evidence directory'
    }
    if ([string]$previous.candidate.sha256 -ne $candidateSha256 -or
        [string]$previous.candidate.gitCommit -ne $candidateCommit -or
        [string]$previous.candidate.gitTree -ne $candidateTree -or
        [string]$previous.harness.gitCommit -ne $harnessCommit -or
        [string]$previous.harness.gitTree -ne $harnessTree) {
        throw 'Mosh candidate or harness identity changed; start a new matrix'
    }
    $currentInvocation = Get-MoshMatrixInvocation
    if ((ConvertTo-Json $previous.invocation -Compress) -cne
        (ConvertTo-Json $currentInvocation -Compress)) {
        throw 'Mosh matrix invocation changed; resume with the original target, network and fixture inputs'
    }
    foreach ($attempt in @($previous.attempts)) {
        $attemptCounts[[string]$attempt.scenario] = [int]$attempt.count
    }
    foreach ($completed in @($previous.completedScenarios)) {
        $scenario = [string]$completed.scenario
        if ($scenario -ne $scenarios[$completedScenarios.Count]) {
            throw 'Mosh completed checkpoints are not a valid fixed-order prefix'
        }
        $scenarioEvidencePath = Join-Path $EvidenceDirectory ([string]$completed.evidence)
        $null = Assert-MoshScenarioEvidence -Path $scenarioEvidencePath -Scenario $scenario
        $completedScenarios.Add($completed)
    }
    $resumeCount = [int]$previous.resumeCount + 1
    $failedScenario = [string]$previous.failedScenario
    $failedAttemptId = [string]$previous.failedAttemptId
    $failedEvidence = [string]$previous.failedEvidence
    if (-not [string]::IsNullOrWhiteSpace($failedScenario)) {
        if ([string]::IsNullOrWhiteSpace($failedEvidence)) {
            throw 'Mosh failed-stage cleanup is unproved; audit it and start a new matrix'
        }
        $failedPath = Join-Path $EvidenceDirectory $failedEvidence
        if (-not (Test-Path -LiteralPath $failedPath -PathType Leaf)) {
            throw 'Mosh failed-stage evidence is missing; audit it and start a new matrix'
        }
        $failedRecord = [IO.File]::ReadAllText($failedPath, [Text.Encoding]::UTF8) |
            ConvertFrom-Json -Depth 20
        if ([string]$failedRecord.cleanup.result -ne 'passed') {
            throw 'Mosh failed-stage cleanup did not pass; audit it and start a new matrix'
        }
    }
    $startedAt = [DateTimeOffset]::Parse([string]$previous.startedAt)
}

Write-MoshMatrixEvidence
try {
    foreach ($scenario in @($scenarios | Select-Object -Skip $completedScenarios.Count)) {
        Write-MoshMatrixProgress -Stage $scenario
        $previousAttemptId = if ($scenario -eq $failedScenario) { $failedAttemptId } else { '' }
        $attemptCount = if ($attemptCounts.ContainsKey($scenario)) {
            [int]$attemptCounts[$scenario] + 1
        } else { 1 }
        $attemptCounts[$scenario] = $attemptCount
        $scenarioDirectory = Join-Path (Join-Path $EvidenceDirectory $scenario) "attempt-$attemptCount"
        New-Item -ItemType Directory -Path $scenarioDirectory -Force | Out-Null
        $failedScenario = $scenario
        $failedAttemptId = ''
        $failedEvidence = ''
        $failure = ''
        Write-MoshMatrixEvidence
        $scenarioArguments = @{
            Formal = $true
            Scenario = $scenario
            Target = $Target
            HapPath = $selectedHapPath
            CandidateBasePath = $CandidateBasePath
            FixturePort = $FixturePort
            FixtureBackendPort = $FixtureBackendPort
            ServerAddress = $ServerAddress
            RemoteScope = $RemoteScope
            AlternateWifiSsid = $AlternateWifiSsid
            SshComparisonPort = $SshComparisonPort
            SshComparisonUser = $SshComparisonUser
            SshComparisonIdentity = $SshComparisonIdentity
            OperatorWaitSeconds = $OperatorWaitSeconds
            EvidenceDirectory = $scenarioDirectory
            PreviousAttemptId = $previousAttemptId
        }
        if (-not [string]::IsNullOrWhiteSpace($Distribution)) {
            $scenarioArguments['Distribution'] = $Distribution
        }
        & (Join-Path $PSScriptRoot 'verify-mosh-pc.ps1') @scenarioArguments
        $scenarioEvidencePath = Join-Path $scenarioDirectory 'device-mosh.json'
        $scenarioEvidence = Assert-MoshScenarioEvidence `
            -Path $scenarioEvidencePath -Scenario $scenario
        $relativeEvidence = [IO.Path]::GetRelativePath($EvidenceDirectory, $scenarioEvidencePath)
        $completedScenarios.Add([pscustomobject][ordered]@{
            scenario = $scenario
            result = 'passed'
            durationMs = [long]$scenarioEvidence.durationMs
            attemptId = [string]$scenarioEvidence.attemptId
            previousAttemptId = [string]$scenarioEvidence.previousAttemptId
            cleanup = [string]$scenarioEvidence.cleanup.result
            evidence = $relativeEvidence
        })
        $failedScenario = ''
        $failedAttemptId = ''
        $failedEvidence = ''
        $failure = ''
        Write-MoshMatrixEvidence
    }
    $matrixResult = 'passed'
} catch {
    $caughtError = $_
    $failure = $_.Exception.Message
    if ($completedScenarios.Count -lt $scenarios.Count) {
        $failedScenario = $scenarios[$completedScenarios.Count]
        $failedDirectory = Join-Path (Join-Path $EvidenceDirectory $failedScenario) (
            'attempt-' + [string]$attemptCounts[$failedScenario]
        )
        $failedPath = Join-Path $failedDirectory 'device-mosh.json'
        if (Test-Path -LiteralPath $failedPath -PathType Leaf) {
            $failedEvidence = [IO.Path]::GetRelativePath($EvidenceDirectory, $failedPath)
            try {
                $failedRecord = [IO.File]::ReadAllText($failedPath, [Text.Encoding]::UTF8) |
                    ConvertFrom-Json -Depth 20
                $failedAttemptId = [string]$failedRecord.attemptId
            } catch {}
        }
    }
} finally {
    Write-MoshMatrixEvidence
    Write-MoshMatrixProgress -Stage $(if ($matrixResult -eq 'passed') { 'complete' } else { 'failed' })
}

if ($matrixResult -ne 'passed') {
    if ($null -ne $caughtError) { throw $caughtError }
    throw $failure
}
Write-Host "MOSH FORMAL MATRIX SUCCESS: $matrixPath" -ForegroundColor Green
