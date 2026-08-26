<#
.SYNOPSIS
  Qualify and freeze the LeanTTY physical acceptance harness before a formal matrix.
.DESCRIPTION
  Runs the focused software harness gate, then exercises one minimal end-to-end
  SSH scenario against an explicit review-test HAP. The resulting record binds
  the review package, retained candidate (for formal runs), harness commit/tree,
  ordinary and secret input channels, UiTest layout, structured logs, controlled
  server and cleanup audit. It does not promote product behavior evidence.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ReviewHapPath,
    [string]$Target = '',
    [string]$EvidenceDirectory = '',
    [string]$CandidateBasePath = '',
    [string]$UnlockPasswordPath = '',
    [string]$Distribution = $env:LEANTTY_WSL_DISTRO,
    [switch]$Diagnostic
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'candidate-store.ps1')
. (Join-Path $PSScriptRoot 'harness-qualification.ps1')
. (Join-Path $PSScriptRoot 'release-tooling.ps1')

$startedAt = [DateTimeOffset]::UtcNow
$reviewHap = Assert-LeanTTYDeviceTestHapPath `
    -HapPath $ReviewHapPath `
    -ParameterName 'ReviewHapPath'
$reviewHapSha256 = (
    Get-FileHash -LiteralPath $reviewHap -Algorithm SHA256
).Hash.ToLowerInvariant()

$harnessStatus = @(git -C $repoRoot status --porcelain --untracked-files=all 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect harness source state' }
$harnessDirty = ($harnessStatus.Count -gt 0)
$harnessCommit = (& git -C $repoRoot rev-parse HEAD 2>&1).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve harness commit' }
$harnessTree = (& git -C $repoRoot rev-parse 'HEAD^{tree}' 2>&1).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve harness tree' }
if (-not $Diagnostic -and $harnessDirty) {
    throw 'Formal harness qualification requires a clean committed harness'
}

$candidateRoot = Get-LeanTTYCandidateRoot `
    -RepoRoot $repoRoot `
    -CandidateBasePath $CandidateBasePath
$candidate = @(Get-LeanTTYCandidateRecords -CandidateRoot $candidateRoot |
    Where-Object { $_.sha256 -eq $reviewHapSha256 } |
    Select-Object -First 1)
if (-not $Diagnostic) {
    if ($candidate.Count -ne 1) {
        throw 'Formal harness qualification requires the explicit HAP to be a retained verified candidate'
    }
    if ([bool]$candidate[0].gitDirty) {
        throw 'Formal harness qualification requires a clean candidate identity'
    }
}

if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $repoRoot (
        'build\verification\harness-qualification-' +
        $startedAt.ToString('yyyyMMddTHHmmssfffZ')
    )
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$softwareEvidencePath = Join-Path $EvidenceDirectory 'software-harness.json'
$physicalEvidenceDirectory = Join-Path $EvidenceDirectory 'physical-minimum'
$physicalEvidencePath = Join-Path $physicalEvidenceDirectory 'device-ssh-auth.json'
$qualificationEvidencePath = Join-Path $EvidenceDirectory 'harness-qualification.json'
$softwareEvidence = $null
$physicalEvidence = $null
$physicalSummary = $null
$failure = ''

try {
    & (Join-Path $PSScriptRoot 'test-acceptance-harness.ps1') `
        -EvidencePath $softwareEvidencePath
    if ($LASTEXITCODE -ne 0) { throw 'Focused acceptance-harness software gate failed' }
    $softwareEvidence = Get-Content -LiteralPath $softwareEvidencePath -Raw | ConvertFrom-Json
    if ([string]$softwareEvidence.result -ne 'passed' -or
        @($softwareEvidence.checks | Where-Object { $_.result -ne 'passed' }).Count -gt 0) {
        throw 'Focused acceptance-harness software evidence is not passing'
    }

    $physicalArgs = @{
        Target = $Target
        HapPath = $reviewHap
        VerifyPreferencesUnchanged = $true
        EvidenceDirectory = $physicalEvidenceDirectory
        CandidateBasePath = $CandidateBasePath
        Only = @('password-success')
        Distribution = $Distribution
        DiagnosticHap = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($UnlockPasswordPath)) {
        $physicalArgs['UnlockPasswordPath'] = $UnlockPasswordPath
    }
    & (Join-Path $PSScriptRoot 'verify-ssh-auth-pc.ps1') @physicalArgs
    if ($LASTEXITCODE -ne 0) { throw 'Minimum physical harness scenario failed' }

    $physicalEvidence = Get-Content -LiteralPath $physicalEvidencePath -Raw | ConvertFrom-Json
    $physicalSummary = Assert-LeanTTYHarnessQualificationPhysicalEvidence `
        -Evidence $physicalEvidence `
        -ReviewHapSha256 $reviewHapSha256 `
        -HarnessCommit $harnessCommit `
        -HarnessTree $harnessTree `
        -RequireCleanHarness:(-not $Diagnostic)
} catch {
    $failure = $_.Exception.Message
} finally {
    $candidateIdentity = if ($candidate.Count -eq 1) {
        [ordered]@{
            retained = $true
            sha256 = $candidate[0].sha256
            verificationMode = $candidate[0].verificationMode
            gitCommit = $candidate[0].gitCommit
            gitTree = $candidate[0].gitTree
            gitDirty = $candidate[0].gitDirty
        }
    } else {
        [ordered]@{
            retained = $false
            sha256 = $reviewHapSha256
            verificationMode = 'unretained-diagnostic'
            gitCommit = $null
            gitTree = $null
            gitDirty = $null
        }
    }
    $qualificationId = Get-LeanTTYHashIdentity -Value (
        $reviewHapSha256 + '|' + $harnessCommit + '|' + $harnessTree + '|' +
        [string]$candidateIdentity.gitCommit + '|' + [string]$candidateIdentity.gitTree
    )
    $record = [ordered]@{
        schemaVersion = 1
        gate = 'acceptance-harness-qualification'
        qualificationId = $qualificationId
        runMode = $(if ($Diagnostic) { 'diagnostic' } else { 'formal' })
        result = $(if ($failure) { 'failed' } else { 'passed' })
        releaseEligible = (-not $Diagnostic -and -not $failure)
        productBehaviorClaimed = $false
        physicalCandidateAuthority = 'qualifier-validates-retained-candidate-inner-only-run-is-diagnostic'
        startedAt = $startedAt.ToString('o')
        completedAt = [DateTimeOffset]::UtcNow.ToString('o')
        reviewTestHap = [ordered]@{
            path = $reviewHap
            sha256 = $reviewHapSha256
            candidate = $candidateIdentity
        }
        harness = [ordered]@{
            gitCommit = $harnessCommit
            gitTree = $harnessTree
            gitDirty = $harnessDirty
        }
        contextOfUse = @(
            'device-and-serialized-uitest-preflight',
            'ordinary-command-exact-before-single-enter',
            'runtime-generated-secret-input',
            'semantic-layout-observation',
            'structured-app-and-fixture-log-observation',
            'repository-only-controlled-ssh-server',
            'known-host-reverse-mapping-fixture-and-preferences-cleanup',
            'release-package-acceptance-marker-exclusion-regression'
        )
        checks = [ordered]@{
            softwareHarness = $(if ($null -eq $softwareEvidence) { 'not-passed' } else { 'passed' })
            releaseModeAcceptanceOnlyMarkers = $(if ($null -eq $softwareEvidence) {
                    'not-passed'
                } else {
                    'negative-package-regression-passed'
                })
            physicalMinimum = $physicalSummary
        }
        evidence = [ordered]@{
            software = $softwareEvidencePath
            physical = $physicalEvidencePath
        }
        freeze = [ordered]@{
            scope = 'review-hap-candidate-harness-and-qualification-contract'
            invalidatedBy = @(
                'review-test-hap-bytes-or-retained-candidate-identity-change',
                'harness-commit-or-tree-change',
                'ordinary-or-secret-input-contract-change',
                'layout-log-fixture-or-cleanup-contract-change',
                'release-package-marker-policy-change',
                'device-os-test-kit-or-control-channel-change-before-formal-matrix'
            )
        }
        failure = $failure
    }
    [IO.File]::WriteAllText(
        $qualificationEvidencePath,
        (ConvertTo-Json -InputObject $record -Depth 12),
        [Text.UTF8Encoding]::new($false)
    )
}

if ($failure) { throw $failure }
$label = if ($Diagnostic) { 'DIAGNOSTIC HARNESS QUALIFICATION' } else { 'FORMAL HARNESS QUALIFICATION' }
Write-Host "$label SUCCESS: $qualificationEvidencePath" -ForegroundColor Green
