<#
.SYNOPSIS
  Run the formal LeanTTY SSH physical matrix as isolated fixed-order groups.
.DESCRIPTION
  Reuses one retained candidate while each group starts and cleans up its own
  fixture, mapping and application state. A failed group stops the matrix. The
  operator may rerun that one group for diagnosis, but this formal entry never
  skips or automatically resumes checkpoints.
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
    [string]$EvidenceDirectory = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'candidate-store.ps1')

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
    $EvidenceDirectory = Join-Path $repoRoot (
        'build\verification\device-ssh-matrix-' +
        [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    )
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$matrixEvidencePath = Join-Path $EvidenceDirectory 'ssh-matrix.json'
$startedAt = [DateTimeOffset]::UtcNow
$completedGroups = [Collections.Generic.List[object]]::new()
$matrixResult = 'failed'
$failure = ''
$caughtError = $null
$expectedCandidateSha256 = ([string]$candidate.sha256).ToLowerInvariant()
$expectedHarnessTree = ''

function Write-SshMatrixEvidence {
    $evidence = [ordered]@{
        schemaVersion = 1
        gate = 'device-behavior'
        scenario = 'ssh-physical-matrix'
        result = $matrixResult
        startedAt = $startedAt.ToString('o')
        completedAt = [DateTimeOffset]::UtcNow.ToString('o')
        durationMs = [long]([DateTimeOffset]::UtcNow - $startedAt).TotalMilliseconds
        fixedOrder = @($groups)
        candidateSha256 = $expectedCandidateSha256
        harnessGitTree = $expectedHarnessTree
        completedGroups = @($completedGroups)
        failure = $failure
        resumePolicy = 'rerun-failed-group-in-acceptance-then-run-only-remaining-groups-after-identity-validation'
    }
    [IO.File]::WriteAllText(
        $matrixEvidencePath,
        (ConvertTo-Json -InputObject $evidence -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )
}

try {
    foreach ($group in $groups) {
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
            evidence = "$group/device-ssh-auth.json"
        })
        Write-SshMatrixEvidence
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
