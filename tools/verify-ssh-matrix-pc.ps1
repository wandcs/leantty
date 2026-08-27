<#
.SYNOPSIS
  Run the formal LeanTTY SSH physical matrix as isolated fixed-order groups.
.DESCRIPTION
  Reuses one retained candidate while each group starts and cleans up its own
  fixture, mapping and application state. A failed group stops the matrix. The
  operator may rerun that one group for diagnosis, then explicitly resume only
  the remaining groups after exact identity and cleanup validation.
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [string]$HapPath = '',
    [string]$CandidateBasePath = '',
    [string]$UnlockPasswordPath = '',
    [ValidateRange(1024, 65535)]
    [int]$FixturePort = 22222,
    [string]$Distribution = $env:LEANTTY_WSL_DISTRO,
    [string]$EvidenceDirectory = '',
    [switch]$Resume
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'candidate-store.ps1')
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'release-tooling.ps1')

$groups = @(
    'transport-performance',
    'authentication-methods',
    'lifecycle-recovery',
    'pane-focus-attention'
)
$authScript = Join-Path $PSScriptRoot 'verify-ssh-auth-pc.ps1'
if (-not (Test-Path -LiteralPath $authScript -PathType Leaf)) {
    throw "SSH authentication verifier is missing: $authScript"
}

$candidate = Resolve-LeanTTYRetainedCandidate `
    -RepoRoot $repoRoot `
    -HapPath $HapPath `
    -CandidateBasePath $CandidateBasePath
if ($candidate.gitDirty) { throw 'Formal SSH matrix requires a clean committed candidate' }
$selectedHapPath = [IO.Path]::GetFullPath([string]$candidate.hapPath)
if (-not (Test-Path -LiteralPath $selectedHapPath -PathType Leaf)) {
    throw "Retained candidate HAP is missing: $selectedHapPath"
}

if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    if ($Resume) { throw '-Resume requires an explicit existing EvidenceDirectory' }
    $EvidenceDirectory = Join-Path $repoRoot (
        'build\verification\device-ssh-matrix-' +
        [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    )
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$matrixEvidencePath = Join-Path $EvidenceDirectory 'ssh-matrix.json'
$progressPath = Join-Path $EvidenceDirectory 'progress.json'
$startedAt = [DateTimeOffset]::UtcNow
$completedGroups = [Collections.Generic.List[object]]::new()
$matrixResult = 'failed'
$failure = ''
$caughtError = $null
$expectedCandidateSha256 = ([string]$candidate.sha256).ToLowerInvariant()
$expectedCandidateCommit = ([string]$candidate.gitCommit).ToLowerInvariant()
$expectedCandidateTree = ([string]$candidate.gitTree).ToLowerInvariant()
$harnessCommit = (& git -C $repoRoot rev-parse HEAD 2>&1).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve SSH matrix harness commit' }
$harnessTree = (& git -C $repoRoot rev-parse 'HEAD^{tree}' 2>&1).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve SSH matrix harness tree' }
$expectedHarnessTree = $harnessTree
$resumeAudit = $null

function Write-SshMatrixEvidence {
    $evidence = [ordered]@{
        schemaVersion = 2
        gate = 'device-behavior'
        scenario = 'ssh-physical-matrix'
        result = $matrixResult
        startedAt = $startedAt.ToString('o')
        completedAt = [DateTimeOffset]::UtcNow.ToString('o')
        durationMs = [long]([DateTimeOffset]::UtcNow - $startedAt).TotalMilliseconds
        fixedOrder = @($groups)
        candidate = [ordered]@{
            sha256 = $expectedCandidateSha256
            gitCommit = $expectedCandidateCommit
            gitTree = $expectedCandidateTree
        }
        harness = [ordered]@{
            gitCommit = $harnessCommit
            gitTree = $expectedHarnessTree
        }
        completedGroups = @($completedGroups)
        resumeAudit = $resumeAudit
        failure = $failure
        resumePolicy = 'rerun-failed-group-in-acceptance-then-run-only-remaining-groups-after-identity-validation'
    }
    Write-LeanTTYAtomicJson -Path $matrixEvidencePath -Value $evidence -Depth 10
}

function Write-SshMatrixProgress {
    param([string]$Stage)
    Write-LeanTTYAtomicJson -Path $progressPath -Value ([ordered]@{
        schemaVersion = 1
        scenario = 'ssh-physical-matrix'
        stage = $Stage
        completedGroupCount = $completedGroups.Count
        totalGroupCount = $groups.Count
        updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        contentRecorded = $false
    })
}

if ($Resume) {
    if (-not (Test-Path -LiteralPath $matrixEvidencePath -PathType Leaf)) {
        throw "R3: resume checkpoint is missing: $matrixEvidencePath"
    }
    $previous = Get-Content -LiteralPath $matrixEvidencePath -Raw | ConvertFrom-Json
    if ([int]$previous.schemaVersion -lt 2 -or
        [string]$previous.candidate.sha256 -ne $expectedCandidateSha256 -or
        [string]$previous.candidate.gitCommit -ne $expectedCandidateCommit -or
        [string]$previous.candidate.gitTree -ne $expectedCandidateTree) {
        throw 'R4: product candidate identity changed; build and verify a new candidate'
    }
    if ([string]$previous.harness.gitCommit -ne $harnessCommit -or
        [string]$previous.harness.gitTree -ne $harnessTree) {
        throw 'R2: harness identity changed; requalify it and rerun the failed group before resuming'
    }
    if ((@($previous.fixedOrder) -join '|') -ne ($groups -join '|')) {
        throw 'R3: matrix group contract changed; restart the physical matrix'
    }
    foreach ($completed in @($previous.completedGroups)) {
        $groupName = [string]$completed.name
        if ($groupName -ne $groups[$completedGroups.Count]) {
            throw 'R3: completed checkpoints are not a valid fixed-order prefix'
        }
        $groupEvidencePath = Join-Path $EvidenceDirectory ([string]$completed.evidence)
        if (-not (Test-Path -LiteralPath $groupEvidencePath -PathType Leaf)) {
            throw "R3: completed checkpoint evidence is missing: $groupName"
        }
        $groupEvidence = Get-Content -LiteralPath $groupEvidencePath -Raw | ConvertFrom-Json
        if ([string]$groupEvidence.result -ne 'passed' -or
            [string]$groupEvidence.cleanup.result -ne 'passed' -or
            -not [bool]$groupEvidence.cleanup.reverseMappingAbsenceAudit -or
            -not [bool]$groupEvidence.cleanup.fixtureProcessAbsenceAudit) {
            throw "R3: completed checkpoint cleanup is not reusable: $groupName"
        }
        $completedGroups.Add($completed)
    }
    $hdc = Resolve-Hdc
    $resumeTarget = Resolve-LeanTTYRegressionTarget -Hdc $hdc -Target $Target
    $Target = $resumeTarget
    $reverseState = (@(& $hdc -t $resumeTarget fport ls 2>&1) -join "`n")
    if ($LASTEXITCODE -ne 0) { throw 'R3: unable to audit HDC reverse mappings before resume' }
    if ($reverseState -match "(?m)tcp:$FixturePort\s+tcp:$FixturePort\s+\[Reverse\]") {
        throw "R3: stale reverse mapping remains for fixture port $FixturePort"
    }
    $appProcess = (@(& $hdc -t $resumeTarget shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
    $resumeAudit = [ordered]@{
        recoveryLevel = 'R1'
        candidateIdentity = 'exact'
        harnessIdentity = 'exact'
        completedCheckpointCleanup = 'passed'
        reverseMapping = 'absent'
        fixture = 'absence-proved-by-each-completed-checkpoint'
        temporaryDirectories = 'only-recorded-evidence-directories-retained'
        applicationProcess = $(if ($appProcess) { 'running-observed-read-only' } else { 'not-running-observed-read-only' })
        nextGroup = $(if ($completedGroups.Count -lt $groups.Count) {
            $groups[$completedGroups.Count]
        } else { 'none' })
    }
    Write-SshMatrixProgress -Stage $resumeAudit.nextGroup
}

try {
    foreach ($group in @($groups | Select-Object -Skip $completedGroups.Count)) {
        Write-SshMatrixProgress -Stage $group
        $groupDirectory = Join-Path $EvidenceDirectory $group
        New-Item -ItemType Directory -Path $groupDirectory -Force | Out-Null
        $authArguments = @{
            Target = $Target
            HapPath = $selectedHapPath
            CandidateBasePath = $CandidateBasePath
            UnlockPasswordPath = $UnlockPasswordPath
            FixturePort = $FixturePort
            Distribution = $Distribution
            EvidenceDirectory = $groupDirectory
        }
        & $authScript @authArguments -Group $group -VerifyPreferencesUnchanged

        $groupEvidencePath = Join-Path $groupDirectory 'device-ssh-auth.json'
        if (-not (Test-Path -LiteralPath $groupEvidencePath -PathType Leaf)) {
            throw "SSH group did not write evidence: $group"
        }
        $groupEvidence = Get-Content -Raw -LiteralPath $groupEvidencePath | ConvertFrom-Json
        if ($groupEvidence.result -ne 'passed') {
            throw "SSH group failed: $group"
        }
        if ($groupEvidence.cleanup.result -ne 'passed') {
            throw "SSH group cleanup failed: $group"
        }
        if ($groupEvidence.runMode -ne 'acceptance' -or
            -not $groupEvidence.candidate.retained -or
            $groupEvidence.harness.gitDirty) {
            throw "SSH group did not produce formal acceptance evidence: $group"
        }
        if (-not $groupEvidence.preferences.unchanged) {
            throw "SSH group changed persistent preferences: $group"
        }
        if ($group -eq 'transport-performance') {
            if ([string]$groupEvidence.preferences.comparisonBoundary -ne
                    'before-transparency-performance' -or
                [string]$groupEvidence.preferences.allowedMutation -ne
                    'terminal-transparency-mode-restored' -or
                [string]$groupEvidence.performanceMatrix.initialMode -ne
                    [string]$groupEvidence.performanceMatrix.restoredMode) {
                throw 'SSH performance group did not restore its transparency preference boundary'
            }
        } elseif ([string]$groupEvidence.preferences.comparisonBoundary -ne
                'all-selected-stages' -or
            [string]$groupEvidence.preferences.allowedMutation -ne 'none') {
            throw "SSH group did not preserve the complete Preferences boundary: $group"
        }
        if ([string]$groupEvidence.executionGroup -ne $group) {
            throw "SSH group evidence identity mismatch: $group"
        }
        if ([string]$groupEvidence.candidate.sha256 -ne $expectedCandidateSha256) {
            throw "SSH candidate changed between groups: $group"
        }
        if ([string]::IsNullOrWhiteSpace($expectedHarnessTree)) {
            $expectedHarnessTree = [string]$groupEvidence.harness.gitTree
        } elseif ([string]$groupEvidence.harness.gitTree -ne $expectedHarnessTree) {
            throw "SSH harness changed between groups: $group"
        }
        $completedGroups.Add([pscustomobject][ordered]@{
            name = $group
            result = [string]$groupEvidence.result
            cleanup = [string]$groupEvidence.cleanup.result
            candidateSha256 = [string]$groupEvidence.candidate.sha256
            harnessGitTree = [string]$groupEvidence.harness.gitTree
            durationMs = [long]$groupEvidence.durationMs
            attemptId = [string]$groupEvidence.attemptId
            previousAttemptId = [string]$groupEvidence.previousAttemptId
            reverseMappingAbsenceAudit = [bool]$groupEvidence.cleanup.reverseMappingAbsenceAudit
            fixtureProcessAbsenceAudit = [bool]$groupEvidence.cleanup.fixtureProcessAbsenceAudit
            evidence = "$group/device-ssh-auth.json"
        })
        Write-SshMatrixEvidence
        Write-SshMatrixProgress -Stage $(if ($completedGroups.Count -lt $groups.Count) {
            $groups[$completedGroups.Count]
        } else { 'complete' })
    }
    $matrixResult = 'passed'
} catch {
    $caughtError = $_
    $failure = $_.Exception.Message
} finally {
    Write-SshMatrixEvidence
}

if ($matrixResult -ne 'passed') {
    if ($null -ne $caughtError) { throw $caughtError }
    throw $failure
}
Write-Host (
    'DEVICE BEHAVIOR SUCCESS: ssh-physical-matrix ' +
    "(SHA256=$expectedCandidateSha256, evidence=$matrixEvidencePath)"
) -ForegroundColor Green
