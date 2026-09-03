<#
.SYNOPSIS
  Run the registered LeanTTY candidate and physical verification stages in one order.
.DESCRIPTION
  This is a thin serial orchestrator over the existing authoritative scripts.
  It does not implement device behavior, retry model requests automatically, or
  replace production/review artifact preparation. Every stage writes to its own
  evidence directory. -Resume reuses only passing checkpoints after exact
  candidate, harness, target and invocation identity validation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
    [string]$HapPath = '',
    [string]$CandidateBasePath = '',
    [ValidateRange(1024, 65535)][int]$FixturePort = 22222,
    [ValidateRange(20000, 40000)][int]$LongTaskPort = 23150,
    [ValidateRange(0, 65535)][int]$AgentPort = 0,
    [string]$Distribution = $env:LEANTTY_WSL_DISTRO,
    [switch]$Resume
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'candidate-store.ps1')
. (Join-Path $PSScriptRoot 'release-tooling.ps1')

$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
$repoFullPath = [IO.Path]::GetFullPath($repoRoot).TrimEnd('\', '/')
$repoPrefix = $repoFullPath + [IO.Path]::DirectorySeparatorChar
if ($EvidenceDirectory.Equals($repoFullPath, [StringComparison]::OrdinalIgnoreCase) -or
    $EvidenceDirectory.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw '-EvidenceDirectory must be outside the repository because verify-pc performs a clean build'
}
$normalizedCandidateBasePath = if ([string]::IsNullOrWhiteSpace($CandidateBasePath)) {
    ''
} else {
    [IO.Path]::GetFullPath($CandidateBasePath)
}
$reportPath = Join-Path $EvidenceDirectory 'release-report.json'
$stageRoot = Join-Path $EvidenceDirectory 'stages'
$definitions = @(Get-LeanTTYReleaseVerificationStages)
$definitionNames = @($definitions | ForEach-Object { $_.name })

$sourceStatus = @(git -C $repoRoot status --porcelain --untracked-files=all 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect release verification harness state' }
if ($sourceStatus.Count -gt 0) {
    throw 'Formal release verification requires a clean committed harness'
}
$harnessCommit = (& git -C $repoRoot rev-parse HEAD 2>&1).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve release harness commit' }
$harnessTree = (& git -C $repoRoot rev-parse 'HEAD^{tree}' 2>&1).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve release harness tree' }

function New-ReleaseStageRecord {
    param([Parameter(Mandatory = $true)]$Definition)

    return [pscustomobject][ordered]@{
        name = [string]$Definition.name
        script = [string]$Definition.script
        status = 'pending'
        attemptCount = 0
        resumeCount = 0
        startedAt = $null
        completedAt = $null
        durationMs = 0
        plannedModelRequests = [int]$Definition.plannedModelRequests
        actualModelRequests = 'unavailable'
        automaticModelRetries = 0
        attemptId = ''
        previousAttemptId = ''
        cleanup = 'not-run'
        evidenceDirectory = ''
        resultPath = ''
        failure = ''
    }
}

function Assert-ReleaseResumeIdentity {
    param([Parameter(Mandatory = $true)]$ExistingReport)

    if ([int]$ExistingReport.schemaVersion -ne 1 -or
        [string]$ExistingReport.gate -ne 'registered-release-verification') {
        throw 'Release report schema or gate identity changed; start a new evidence directory'
    }
    if ((@($ExistingReport.stageOrder) -join '|') -ne ($definitionNames -join '|')) {
        throw 'Release stage contract changed; start a new evidence directory'
    }
    if (@($ExistingReport.stages).Count -ne $definitions.Count) {
        throw 'Release stage checkpoints are incomplete; start a new evidence directory'
    }
    if ([string]$ExistingReport.invocation.target -cne $Target -or
        [string]$ExistingReport.invocation.candidateBasePath -cne $normalizedCandidateBasePath -or
        [int]$ExistingReport.invocation.fixturePort -ne $FixturePort -or
        [int]$ExistingReport.invocation.longTaskPort -ne $LongTaskPort -or
        [int]$ExistingReport.invocation.agentPort -ne $AgentPort -or
        [string]$ExistingReport.invocation.distribution -cne [string]$Distribution) {
        throw 'Release invocation identity changed; resume with the original target, paths, ports and distribution'
    }
    if ([string]$ExistingReport.harness.gitCommit -ne $harnessCommit -or
        [string]$ExistingReport.harness.gitTree -ne $harnessTree -or
        [bool]$ExistingReport.harness.gitDirty) {
        throw 'Release harness identity changed; requalify the harness and start a new report'
    }
    if ($null -eq $ExistingReport.candidate -or
        [string]::IsNullOrWhiteSpace([string]$ExistingReport.candidate.hapPath)) {
        throw 'Release candidate was not completed; start a new evidence directory'
    }
    $resolved = Resolve-LeanTTYRetainedCandidate `
        -RepoRoot $repoRoot `
        -HapPath ([string]$ExistingReport.candidate.hapPath) `
        -CandidateBasePath $normalizedCandidateBasePath
    if ([string]$resolved.sha256 -ne [string]$ExistingReport.candidate.sha256 -or
        [string]$resolved.gitCommit -ne [string]$ExistingReport.candidate.gitCommit -or
        [string]$resolved.gitTree -ne [string]$ExistingReport.candidate.gitTree -or
        [bool]$resolved.gitDirty) {
        throw 'Release candidate identity changed; start a new report'
    }
    if (-not [string]::IsNullOrWhiteSpace($HapPath)) {
        $requestedCandidate = Resolve-LeanTTYRetainedCandidate `
            -RepoRoot $repoRoot -HapPath $HapPath `
            -CandidateBasePath $normalizedCandidateBasePath
        if ([string]$requestedCandidate.sha256 -ne [string]$resolved.sha256) {
            throw '-HapPath does not identify the candidate recorded by this release report'
        }
    }
    return $resolved
}

function Assert-PassingReleaseCheckpoints {
    param(
        [Parameter(Mandatory = $true)]$ExistingReport,
        [Parameter(Mandatory = $true)]$ResolvedCandidate
    )

    for ($index = 0; $index -lt $definitions.Count; $index++) {
        $definition = $definitions[$index]
        $stage = $ExistingReport.stages[$index]
        if ([string]$stage.status -ne 'passed') { continue }
        $summary = Get-LeanTTYReleaseEvidenceSummary `
            -Path ([string]$stage.resultPath) -StageName ([string]$stage.name)
        if ($definition.kind -eq 'harness') {
            if (-not [bool]$summary.evidence.releaseEligible -or
                [string]$summary.evidence.runMode -ne 'formal' -or
                [string]$summary.evidence.reviewTestHap.sha256 -ne [string]$ResolvedCandidate.sha256 -or
                [string]$summary.evidence.harness.gitCommit -ne $harnessCommit -or
                [string]$summary.evidence.harness.gitTree -ne $harnessTree) {
                throw 'Passing harness qualification no longer matches the candidate and harness identities'
            }
        }
        if ($definition.kind -eq 'ssh-matrix') {
            if ([string]$summary.evidence.candidate.sha256 -ne [string]$ResolvedCandidate.sha256 -or
                [string]$summary.evidence.harness.gitCommit -ne $harnessCommit -or
                [string]$summary.evidence.harness.gitTree -ne $harnessTree) {
                throw 'Passing SSH matrix no longer matches the candidate and harness identities'
            }
        }
    }
}

if ($Resume) {
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
        throw "-Resume requires an existing release report: $reportPath"
    }
    $report = [IO.File]::ReadAllText($reportPath, [Text.Encoding]::UTF8) |
        ConvertFrom-Json -Depth 20
    $candidate = Assert-ReleaseResumeIdentity -ExistingReport $report
    Assert-PassingReleaseCheckpoints -ExistingReport $report -ResolvedCandidate $candidate
    $report.resumeCount = [int]$report.resumeCount + 1
    $report.result = 'running'
    $report.failure = ''
    $report.completedAt = $null
    $report.sshResumeCommand = ''
} else {
    if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
        throw "Release report already exists; use -Resume or a new evidence directory: $reportPath"
    }
    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
    $report = [pscustomobject][ordered]@{
        schemaVersion = 1
        gate = 'registered-release-verification'
        result = 'running'
        registeredStagesPassed = $false
        completeApplicablePhysicalMatrixClaimed = $false
        startedAt = [DateTimeOffset]::UtcNow.ToString('o')
        completedAt = $null
        durationMs = 0
        resumeCount = 0
        stageOrder = $definitionNames
        invocation = [ordered]@{
            target = $Target
            candidateBasePath = $normalizedCandidateBasePath
            fixturePort = $FixturePort
            longTaskPort = $LongTaskPort
            agentPort = $AgentPort
            distribution = [string]$Distribution
        }
        candidate = $null
        harness = [ordered]@{
            gitCommit = $harnessCommit
            gitTree = $harnessTree
            gitDirty = $false
        }
        modelUsage = [ordered]@{
            plannedRequests = [int](($definitions | Measure-Object plannedModelRequests -Sum).Sum)
            actualRequests = 'unavailable'
            automaticRetries = 0
        }
        cleanup = [ordered]@{
            result = 'pending'
            detail = 'stage-owned cleanup is summarized after each authoritative script'
        }
        stages = @($definitions | ForEach-Object { New-ReleaseStageRecord -Definition $_ })
        sshResumeCommand = ''
        failure = ''
        remainingReleaseWork = @(
            'formal-mosh-network-and-lifecycle-matrix',
            'production-and-review-artifact-preparation',
            'signing-and-archive-audit',
            'immutable-tag-and-github-release',
            'maintainer-appgallery-submission'
        )
    }
    $candidate = $null
    $null = Write-LeanTTYReleaseReportArtifacts `
        -EvidenceDirectory $EvidenceDirectory -Report $report
}

function Set-ReleaseCandidate {
    param([Parameter(Mandatory = $true)]$ResolvedCandidate)

    $report.candidate = [pscustomobject][ordered]@{
        hapPath = [string]$ResolvedCandidate.hapPath
        manifestPath = [string]$ResolvedCandidate.manifestPath
        sha256 = [string]$ResolvedCandidate.sha256
        verificationMode = [string]$ResolvedCandidate.verificationMode
        gitCommit = [string]$ResolvedCandidate.gitCommit
        gitTree = [string]$ResolvedCandidate.gitTree
        gitDirty = [bool]$ResolvedCandidate.gitDirty
    }
}

function Add-OptionalArgument {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Arguments,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowEmptyString()][string]$Value
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) { $Arguments[$Name] = $Value }
}

function Update-ReleaseModelUsage {
    $modelStages = @($report.stages | Where-Object { [int]$_.plannedModelRequests -gt 0 })
    $numericActuals = @($modelStages | Where-Object {
            [string]$_.actualModelRequests -match '^\d+$'
        })
    $report.modelUsage.actualRequests = if ($modelStages.Count -gt 0 -and
        $numericActuals.Count -eq $modelStages.Count) {
        [int](($numericActuals | ForEach-Object {
                    [int]$_.actualModelRequests
                } | Measure-Object -Sum).Sum)
    } else { 'unavailable' }
}

function Invoke-AuthoritativeReleaseStage {
    param(
        [Parameter(Mandatory = $true)]$Definition,
        [Parameter(Mandatory = $true)][string]$StageEvidenceDirectory,
        [AllowEmptyString()][string]$PreviousAttemptId = '',
        [switch]$ResumeSsh
    )

    $scriptPath = Join-Path $PSScriptRoot ([string]$Definition.script)
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Authoritative release script is missing: $scriptPath"
    }
    switch ([string]$Definition.kind) {
        'candidate' {
            & $scriptPath -Target $Target -EvidenceDirectory $StageEvidenceDirectory
        }
        'harness' {
            $arguments = @{
                ReviewHapPath = [string]$candidate.hapPath
                Target = $Target
                EvidenceDirectory = $StageEvidenceDirectory
                CandidateBasePath = $normalizedCandidateBasePath
            }
            Add-OptionalArgument -Arguments $arguments -Name Distribution -Value $Distribution
            & $scriptPath @arguments
        }
        'key-passphrase' {
            & $scriptPath -Target $Target -HapPath ([string]$candidate.hapPath) `
                -CandidateBasePath $normalizedCandidateBasePath `
                -EvidenceDirectory $StageEvidenceDirectory
        }
        'ssh-auth-key-comment' {
            $arguments = @{
                Target = $Target; HapPath = [string]$candidate.hapPath; DiagnosticHap = $true
                CandidateBasePath = $normalizedCandidateBasePath
                EvidenceDirectory = $StageEvidenceDirectory; FixturePort = $FixturePort
                Only = @('key-comment-change-and-restart')
            }
            Add-OptionalArgument -Arguments $arguments -Name Distribution -Value $Distribution
            & $scriptPath @arguments
        }
        'ssh-auth-ecdsa' {
            $arguments = @{
                Target = $Target; HapPath = [string]$candidate.hapPath; DiagnosticHap = $true
                CandidateBasePath = $normalizedCandidateBasePath
                EvidenceDirectory = $StageEvidenceDirectory; FixturePort = $FixturePort
                Only = @('ecdsa-import-encrypted-and-restart')
            }
            Add-OptionalArgument -Arguments $arguments -Name Distribution -Value $Distribution
            & $scriptPath @arguments
        }
        'host-identity' {
            $arguments = @{
                Target = $Target; HapPath = [string]$candidate.hapPath
                EvidenceDirectory = $StageEvidenceDirectory
            }
            Add-OptionalArgument -Arguments $arguments -Name Distribution -Value $Distribution
            & $scriptPath @arguments
        }
        'host-identity-openssh' {
            $arguments = @{
                Target = $Target; HapPath = [string]$candidate.hapPath
                EvidenceDirectory = $StageEvidenceDirectory; OpenSshCompatibility = $true
            }
            Add-OptionalArgument -Arguments $arguments -Name Distribution -Value $Distribution
            & $scriptPath @arguments
        }
        'host-identity-default-ecdsa' {
            $arguments = @{
                Target = $Target; HapPath = [string]$candidate.hapPath
                EvidenceDirectory = $StageEvidenceDirectory; OpenSshCompatibility = $true
                DefaultEcdsa = $true; PreserveExistingEd25519 = $true
            }
            Add-OptionalArgument -Arguments $arguments -Name Distribution -Value $Distribution
            & $scriptPath @arguments
        }
        'background-bell' {
            & $scriptPath -Target $Target -HapPath ([string]$candidate.hapPath) `
                -EvidenceDirectory $StageEvidenceDirectory
        }
        'background-bell-suppression' {
            & $scriptPath -Target $Target -HapPath ([string]$candidate.hapPath) `
                -EvidenceDirectory $StageEvidenceDirectory -Suppression
        }
        'background-bell-cold-stale' {
            & $scriptPath -Target $Target -HapPath ([string]$candidate.hapPath) `
                -EvidenceDirectory $StageEvidenceDirectory -ColdStale
        }
        'background-bell-late-handled' {
            & $scriptPath -Target $Target -HapPath ([string]$candidate.hapPath) `
                -EvidenceDirectory $StageEvidenceDirectory -LateHandled
        }
        'background-bell-late-destroyed' {
            & $scriptPath -Target $Target -HapPath ([string]$candidate.hapPath) `
                -EvidenceDirectory $StageEvidenceDirectory -LateDestroyed
        }
        'background-bell-manual-dismiss' {
            & $scriptPath -Target $Target -HapPath ([string]$candidate.hapPath) `
                -EvidenceDirectory $StageEvidenceDirectory -ManualDismiss
        }
        'background-bell-permission' {
            & $scriptPath -Target $Target -HapPath ([string]$candidate.hapPath) `
                -EvidenceDirectory $StageEvidenceDirectory
        }
        'unexpected-recovery-uninstall' {
            & $scriptPath -Target $Target -HapPath ([string]$candidate.hapPath) `
                -EvidenceDirectory $StageEvidenceDirectory
        }
        'long-task' {
            & $scriptPath -Target $Target -HapPath ([string]$candidate.hapPath) `
                -CandidateBasePath $normalizedCandidateBasePath `
                -EvidenceDirectory $StageEvidenceDirectory -Port $LongTaskPort `
                -PreviousAttemptId $PreviousAttemptId
        }
        'agent' {
            & $scriptPath -Target $Target -HapPath ([string]$candidate.hapPath) `
                -CandidateBasePath $normalizedCandidateBasePath `
                -EvidenceDirectory $StageEvidenceDirectory -Port $AgentPort `
                -PreviousAttemptId $PreviousAttemptId
        }
        'ssh-matrix' {
            $arguments = @{
                Target = $Target; HapPath = [string]$candidate.hapPath
                CandidateBasePath = $normalizedCandidateBasePath
                EvidenceDirectory = $StageEvidenceDirectory; FixturePort = $FixturePort
            }
            Add-OptionalArgument -Arguments $arguments -Name Distribution -Value $Distribution
            if ($ResumeSsh) { $arguments['Resume'] = $true }
            & $scriptPath @arguments
        }
        default { throw "Unknown release stage kind: $($Definition.kind)" }
    }
}

$runStartedAt = [DateTimeOffset]::Parse([string]$report.startedAt)
$caughtError = $null
try {
    for ($index = 0; $index -lt $definitions.Count; $index++) {
        $definition = $definitions[$index]
        $stage = $report.stages[$index]
        if ([string]$stage.status -in @('passed', 'reused')) { continue }
        if ($Resume -and [string]$stage.status -eq 'running') {
            throw "Stage '$($stage.name)' was interrupted without cleanup evidence; audit it before a new run"
        }
        if ($Resume -and [string]$stage.status -eq 'failed' -and
            $definition.kind -ne 'ssh-matrix' -and [string]$stage.cleanup -ne 'passed') {
            throw "Stage '$($stage.name)' cannot resume because its cleanup is not proved"
        }

        if ($definition.kind -eq 'candidate' -and -not $Resume -and
            -not [string]::IsNullOrWhiteSpace($HapPath)) {
            $candidate = Resolve-LeanTTYRetainedCandidate `
                -RepoRoot $repoRoot -HapPath $HapPath `
                -CandidateBasePath $normalizedCandidateBasePath
            if ([bool]$candidate.gitDirty) { throw 'Formal release candidate must be clean' }
            Set-ReleaseCandidate -ResolvedCandidate $candidate
            $stage.status = 'reused'
            $stage.cleanup = 'not-applicable'
            $stage.resultPath = [string]$candidate.manifestPath
            $stage.completedAt = [DateTimeOffset]::UtcNow.ToString('o')
            $null = Write-LeanTTYReleaseReportArtifacts `
                -EvidenceDirectory $EvidenceDirectory -Report $report
            continue
        }

        $previousAttemptId = [string]$stage.attemptId
        $resumeSsh = ($definition.kind -eq 'ssh-matrix' -and [int]$stage.attemptCount -gt 0)
        $nextAttempt = [int]$stage.attemptCount + 1
        $stageEvidenceDirectory = if ($definition.kind -eq 'ssh-matrix') {
            Join-Path $stageRoot ([string]$definition.name)
        } else {
            Join-Path (Join-Path $stageRoot ([string]$definition.name)) "attempt-$nextAttempt"
        }
        New-Item -ItemType Directory -Path $stageEvidenceDirectory -Force | Out-Null
        $stage.resultPath = Join-Path $stageEvidenceDirectory ([string]$definition.resultFile)
        $stage.evidenceDirectory = $stageEvidenceDirectory
        $stage.status = 'running'
        $stage.attemptCount = $nextAttempt
        if ($Resume) { $stage.resumeCount = [int]$stage.resumeCount + 1 }
        $stage.startedAt = [DateTimeOffset]::UtcNow.ToString('o')
        $stage.completedAt = $null
        $stage.failure = ''
        $stage.cleanup = 'pending'
        $report.failure = ''
        $null = Write-LeanTTYReleaseReportArtifacts `
            -EvidenceDirectory $EvidenceDirectory -Report $report

        $stageWatch = [Diagnostics.Stopwatch]::StartNew()
        try {
            Invoke-AuthoritativeReleaseStage `
                -Definition $definition `
                -StageEvidenceDirectory $stageEvidenceDirectory `
                -PreviousAttemptId $previousAttemptId `
                -ResumeSsh:$resumeSsh
            if ($definition.kind -eq 'candidate') {
                $candidate = Resolve-LeanTTYRetainedCandidate `
                    -RepoRoot $repoRoot -CandidateBasePath $normalizedCandidateBasePath
                if ([bool]$candidate.gitDirty) { throw 'Formal release candidate must be clean' }
                Set-ReleaseCandidate -ResolvedCandidate $candidate
            }
            $summary = Get-LeanTTYReleaseEvidenceSummary `
                -Path ([string]$stage.resultPath) -StageName ([string]$stage.name)
            $stage.status = 'passed'
            $stage.cleanup = [string]$summary.cleanup
            $stage.actualModelRequests = [string]$summary.actualModelRequests
            if (-not [string]::IsNullOrWhiteSpace([string]$summary.attemptId)) {
                $stage.attemptId = [string]$summary.attemptId
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$summary.previousAttemptId)) {
                $stage.previousAttemptId = [string]$summary.previousAttemptId
            } elseif (-not [string]::IsNullOrWhiteSpace($previousAttemptId)) {
                $stage.previousAttemptId = $previousAttemptId
            }
        } catch {
            $stageError = $_
            $stage.status = 'failed'
            $stage.failure = $stageError.Exception.Message
            if (Test-Path -LiteralPath ([string]$stage.resultPath) -PathType Leaf) {
                try {
                    $metadata = Get-LeanTTYReleaseEvidenceMetadata `
                        -Path ([string]$stage.resultPath) -StageName ([string]$stage.name)
                    $stage.cleanup = [string]$metadata.cleanup
                    $stage.actualModelRequests = [string]$metadata.actualModelRequests
                    if (-not [string]::IsNullOrWhiteSpace([string]$metadata.attemptId)) {
                        $stage.attemptId = [string]$metadata.attemptId
                    }
                } catch {
                    $stage.cleanup = 'evidence-unreadable'
                }
            } else {
                $stage.cleanup = 'evidence-missing'
            }
            if ($definition.kind -eq 'ssh-matrix' -and $null -ne $candidate) {
                $report.sshResumeCommand = Get-LeanTTYReleaseSshResumeCommand `
                    -RepoRoot $repoRoot -Target $Target `
                    -HapPath ([string]$candidate.hapPath) `
                    -CandidateBasePath $normalizedCandidateBasePath `
                    -FixturePort $FixturePort -Distribution $Distribution `
                    -EvidenceDirectory $stageEvidenceDirectory
            }
            throw $stageError
        } finally {
            $stageWatch.Stop()
            $stage.durationMs = [long]$stage.durationMs + [long]$stageWatch.ElapsedMilliseconds
            $stage.completedAt = [DateTimeOffset]::UtcNow.ToString('o')
            $null = Write-LeanTTYReleaseReportArtifacts `
                -EvidenceDirectory $EvidenceDirectory -Report $report
        }
    }
    $report.result = 'passed'
    $report.registeredStagesPassed = $true
    $cleanupValues = @($report.stages | ForEach-Object { [string]$_.cleanup })
    $report.cleanup = [ordered]@{
        result = $(if ($cleanupValues -contains 'failed' -or
                $cleanupValues -contains 'evidence-missing' -or
                $cleanupValues -contains 'evidence-unreadable') {
                'failed'
            } elseif ($cleanupValues -contains 'not-separately-reported') {
                'passed-with-unreported-stage-cleanup'
            } else { 'passed' })
        detail = 'all authoritative stages completed their owned cleanup or reported no separate cleanup field'
    }
} catch {
    $caughtError = $_
    $report.result = 'failed'
    $report.registeredStagesPassed = $false
    $report.failure = $_.Exception.Message
    $report.cleanup = [ordered]@{
        result = $(if (@($report.stages | Where-Object {
                        [string]$_.cleanup -in @('failed', 'evidence-missing', 'evidence-unreadable')
                    }).Count -gt 0) { 'failed-or-unproved' } else { 'stage-owned-results-recorded' })
        detail = 'inspect the failed stage evidence before an explicit resume'
    }
} finally {
    $report.completedAt = [DateTimeOffset]::UtcNow.ToString('o')
    $report.durationMs = [long]([DateTimeOffset]::UtcNow - $runStartedAt).TotalMilliseconds
    Update-ReleaseModelUsage
    $artifacts = Write-LeanTTYReleaseReportArtifacts `
        -EvidenceDirectory $EvidenceDirectory -Report $report
}

if ($null -ne $caughtError) {
    if (-not [string]::IsNullOrWhiteSpace([string]$report.sshResumeCommand)) {
        Write-Host 'SSH matrix failed. Resume the same evidence directory with:' -ForegroundColor Yellow
        Write-Host $report.sshResumeCommand -ForegroundColor Yellow
    }
    Write-Host "Release report: $($artifacts.reportPath)" -ForegroundColor Yellow
    throw $caughtError
}
Write-Host "REGISTERED RELEASE STAGES PASSED: $($artifacts.reportPath)" -ForegroundColor Green
Write-Host "Maintainer summary: $($artifacts.summaryPath)" -ForegroundColor Green
