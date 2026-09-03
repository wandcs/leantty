<#
.SYNOPSIS
  Run the focused, non-candidate LeanTTY release-readiness drill.
.DESCRIPTION
  Exercises release tooling and offline product contracts before a release
  commit or retained candidate exists. It never invokes an Agent model and its
  evidence is never release-eligible.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$ReleaseId,
    [Parameter(Mandatory = $true)][string]$ProductionCheckout,
    [Parameter(Mandatory = $true)][string]$ReviewCheckout,
    [Parameter(Mandatory = $true)][string]$ReleaseHapPath,
    [string]$CandidateBasePath = '',
    [string]$EvidencePath = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'candidate-store.ps1')
. (Join-Path $PSScriptRoot 'package-policy.ps1')
. (Join-Path $PSScriptRoot 'agent-compatibility-policy.ps1')
. (Join-Path $PSScriptRoot 'release-tooling.ps1')

if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $EvidencePath = Join-Path $repoRoot (
        'build\verification\release-readiness-' +
        [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json'
    )
}
$EvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$productionFull = [IO.Path]::GetFullPath($ProductionCheckout)
$reviewFull = [IO.Path]::GetFullPath($ReviewCheckout)
$releaseHapFull = [IO.Path]::GetFullPath($ReleaseHapPath)
$startedAt = [DateTimeOffset]::UtcNow
$checks = [Collections.Generic.List[object]]::new()
$failure = ''
$result = 'failed'
$agentResultReadiness = $null

function Add-ReadinessCheck {
    param([string]$Name, [scriptblock]$Action)
    & $Action
    $checks.Add([ordered]@{ name = $Name; result = 'passed' })
}

try {
    Add-ReadinessCheck -Name 'focused-policy-tooling-web-arkts' -Action {
        & (Join-Path $PSScriptRoot 'test-regression.ps1') -Group policy,tooling,web,arkts
        if ($LASTEXITCODE -ne 0) { throw 'Focused readiness software gate failed' }
    }
    Add-ReadinessCheck -Name 'offline-agent-notification-replay' -Action {
        & (Join-Path $PSScriptRoot 'test-agent-compatibility.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Offline Agent compatibility replay failed' }
    }
    Add-ReadinessCheck -Name 'zero-model-agent-result-round-trip' -Action {
        $syntheticResult = New-LeanTTYAgentCompatibilityReadinessFixture -StartedAt $startedAt
        $syntheticPath = Join-Path (Split-Path $EvidencePath -Parent) (
            [IO.Path]::GetFileNameWithoutExtension($EvidencePath) + '-agent-result.json'
        )
        $roundTrip = Write-LeanTTYAgentCompatibilityResult `
            -Path $syntheticPath -Result $syntheticResult
        $persisted = $roundTrip.result
        $pairs = @($persisted.checks | ForEach-Object { "$($_.agent)|$($_.mode)" })
        if ($roundTrip.byteLength -lt 20000 -or
            $roundTrip.checkCount -ne 8 -or
            $roundTrip.plannedModelRequests -ne 8 -or
            @($pairs | Sort-Object -Unique).Count -ne 8 -or
            @($persisted.commandAutomation.local.commands).Count -ne 40 -or
            @($persisted.commandAutomation.connected.observations).Count -ne 40 -or
            $persisted.inventory.privacy.credentialContentRead -ne $false -or
            $persisted.cleanup.result -ne 'passed') {
            throw 'Synthetic Agent result did not survive the complete readiness round trip'
        }
        $agentResultReadiness = [ordered]@{
            path = $roundTrip.path
            sha256 = $roundTrip.sha256
            byteLength = $roundTrip.byteLength
            checkCount = $roundTrip.checkCount
            plannedModelRequestsRepresented = $roundTrip.plannedModelRequests
            actualModelInvocations = 0
            commandObservationCount = 40
            atomicWriteAndReadBack = $true
        }
    }
    $contract = Get-LeanTTYAgentCompatibilityContract
    Add-ReadinessCheck -Name 'exact-agent-allowlist' -Action {
        if (($contract.agents -join '|') -ne 'codex|opencode|pi|qwen' -or
            ($contract.modes -join '|') -ne 'direct|tmux' -or
            [int]$contract.requestCount -ne 8 -or
            [int]$contract.automaticRetries -ne 0) {
            throw 'Agent compatibility allowlist or request budget changed'
        }
    }
    Add-ReadinessCheck -Name 'release-package-marker-exclusion' -Action {
        Assert-LeanTTYReleasePackageExcludesAcceptanceMarkers -PackagePath $releaseHapFull
    }
    $productionCandidateRoot = Get-LeanTTYCandidateRoot `
        -RepoRoot $productionFull -CandidateBasePath $CandidateBasePath
    $reviewCandidateRoot = Get-LeanTTYCandidateRoot `
        -RepoRoot $reviewFull -CandidateBasePath $CandidateBasePath
    Add-ReadinessCheck -Name 'stable-candidate-namespace' -Action {
        if ($productionCandidateRoot -ne $reviewCandidateRoot) {
            throw 'Independent production and review checkouts resolved different candidate namespaces'
        }
    }
    $productionPreflight = & (Join-Path $productionFull 'tools\build-all.ps1') `
        -BuildMode release -Metadata -PreflightOnly -ReleaseId $ReleaseId
    Add-ReadinessCheck -Name 'production-release-preflight' -Action {
        if ($null -eq $productionPreflight -or -not $productionPreflight.signingProfileSha256) {
            throw 'Production release preflight omitted signing identity'
        }
    }
    $reviewPreflight = & (Join-Path $reviewFull 'tools\build-all.ps1') `
        -BuildMode release -Metadata -PreflightOnly -ReleaseId $ReleaseId
    Add-ReadinessCheck -Name 'review-release-preflight' -Action {
        if ($null -eq $reviewPreflight -or -not $reviewPreflight.signingProfileSha256) {
            throw 'Review release preflight omitted signing identity'
        }
        if ([string]$productionPreflight.commit -ne [string]$reviewPreflight.commit -or
            [string]$productionPreflight.tree -ne [string]$reviewPreflight.tree) {
            throw 'Production and review preflights do not identify the same source'
        }
        if ([string]$productionPreflight.signingProfileSha256 -eq
            [string]$reviewPreflight.signingProfileSha256) {
            throw 'Production and review signing Profiles must be different'
        }
    }
    $result = 'passed'
} catch {
    $failure = $_.Exception.Message
    throw
} finally {
    $evidence = [ordered]@{
        schemaVersion = 1
        gate = 'release-readiness-drill'
        result = $result
        releaseId = $ReleaseId
        startedAt = $startedAt.ToString('o')
        completedAt = [DateTimeOffset]::UtcNow.ToString('o')
        releaseEligible = $false
        candidateCreated = $false
        agentModelInvocations = 0
        agentContract = $contract
        agentResultReadiness = $agentResultReadiness
        package = [ordered]@{
            path = $releaseHapFull
            sha256 = $(if (Test-Path -LiteralPath $releaseHapFull -PathType Leaf) {
                (Get-FileHash -LiteralPath $releaseHapFull -Algorithm SHA256).Hash.ToLowerInvariant()
            } else { '' })
        }
        candidateNamespace = $(if ($productionCandidateRoot) { $productionCandidateRoot } else { '' })
        productionPreflight = $productionPreflight
        reviewPreflight = $reviewPreflight
        checks = @($checks)
        failure = $failure
    }
    Write-LeanTTYAtomicJson -Path $EvidencePath -Value $evidence -Depth 10
}

Write-Host "Release-readiness drill passed: $EvidencePath" -ForegroundColor Green
