param()

$ErrorActionPreference = 'Stop'
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$testRoot = Join-Path $tempBase ('LeanTTY-readiness-report-' + [guid]::NewGuid().ToString('N'))
$fixtureTools = Join-Path $testRoot 'tools'
New-Item -ItemType Directory -Path $fixtureTools | Out-Null

function Assert-ReadinessReport([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

try {
    # Execute the real entry and serialization path; substitute external effects only.
    foreach ($name in @('test-release-readiness.ps1', 'agent-compatibility-policy.ps1',
            'release-tooling.ps1', 'package-policy.ps1')) {
        [IO.File]::Copy((Join-Path $PSScriptRoot $name), (Join-Path $fixtureTools $name))
    }
    [IO.File]::WriteAllText((Join-Path $fixtureTools 'candidate-store.ps1'), @'
function Get-LeanTTYCandidateRoot {
    param([string]$RepoRoot, [string]$CandidateBasePath)
    return $CandidateBasePath
}
'@)
    [IO.File]::WriteAllText((Join-Path $fixtureTools 'test-regression.ps1'), @'
param([string[]]$Group)
$global:LASTEXITCODE = 0
'@)
    [IO.File]::WriteAllText((Join-Path $fixtureTools 'test-agent-compatibility.ps1'),
        '$global:LASTEXITCODE = 0')
    foreach ($role in @('production', 'review')) {
        $roleTools = Join-Path $testRoot "$role\tools"
        New-Item -ItemType Directory -Path $roleTools | Out-Null
        [IO.File]::WriteAllText((Join-Path $roleTools 'build-all.ps1'), @'
param([string]$BuildMode, [switch]$Metadata, [switch]$PreflightOnly, [string]$ReleaseId)
if (-not $Metadata -or -not $PreflightOnly -or $BuildMode -ne 'release') {
    throw 'Only a non-building release preflight is allowed in this fixture'
}
[pscustomobject]@{ commit=('a' * 40); tree=('b' * 40); signingProfileSha256=$PSScriptRoot }
'@)
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    foreach ($case in @('clean-package', 'rejected-package')) {
        $package = Join-Path $testRoot "$case.hap"
        $archive = [IO.Compression.ZipFile]::Open($package, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $writer = [IO.StreamWriter]::new($archive.CreateEntry('ets/modules.abc').Open())
            try {
                $writer.Write($(if ($case -eq 'rejected-package') { 'LTTY_PERF_PING_' } else { 'fixture' }))
            } finally { $writer.Dispose() }
        } finally { $archive.Dispose() }
        $reportPath = Join-Path $testRoot "$case.json"
        $failure = ''
        try {
            & (Join-Path $fixtureTools 'test-release-readiness.ps1') -ReleaseId 1.6.0 `
                -ProductionCheckout (Join-Path $testRoot 'production') `
                -ReviewCheckout (Join-Path $testRoot 'review') -ReleaseHapPath $package `
                -CandidateBasePath (Join-Path $testRoot 'candidates') -EvidencePath $reportPath
        } catch { $failure = $_.Exception.Message }
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 20
        $summary = $report.agentResultReadiness
        Assert-ReadinessReport ($null -ne $summary) 'Readiness report lost the verified Agent result summary'
        Assert-ReadinessReport ($summary.sha256 -ceq
            (Get-FileHash -LiteralPath $summary.path -Algorithm SHA256).Hash.ToLowerInvariant()) `
            'Readiness summary does not identify the generated Agent result'
        Assert-ReadinessReport ($summary.byteLength -eq (Get-Item -LiteralPath $summary.path).Length -and
            $summary.byteLength -ge 20000 -and $summary.checkCount -eq 8 -and
            $summary.plannedModelRequestsRepresented -eq 8 -and
            $summary.commandObservationCount -eq 40 -and $summary.atomicWriteAndReadBack -eq $true) `
            'Readiness summary lost complete round-trip evidence'
        Assert-ReadinessReport ($summary.actualModelInvocations -eq 0 -and
            $report.agentModelInvocations -eq 0 -and $report.releaseEligible -eq $false -and
            $report.candidateCreated -eq $false) 'Host-only readiness was promoted to candidate evidence'
        if ($case -eq 'clean-package') {
            Assert-ReadinessReport ($failure -eq '' -and $report.result -eq 'passed' -and
                @($report.checks).Count -eq 8) 'Clean fixture did not complete the readiness checks'
        } else {
            Assert-ReadinessReport ($failure -like "*acceptance-only marker 'LTTY_PERF_PING_'*" -and
                $report.failure -ceq $failure -and $report.result -eq 'failed' -and
                @($report.checks).Count -eq 4 -and $null -eq $report.productionPreflight) `
                'Later package failure was lost or subsequent preflight ran'
        }
    }
    Write-Host 'RELEASE READINESS REPORT TESTS PASSED: success and later-failure evidence; no model/build/device calls'
} finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolvedTestRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $resolvedTestRoot -Leaf) -notlike 'LeanTTY-readiness-report-*') {
        throw 'Refusing cleanup outside the run-owned readiness fixture'
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
