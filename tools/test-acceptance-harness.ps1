<#
.SYNOPSIS
  Run the focused regression gate for acceptance-harness-only changes.
.DESCRIPTION
  Checks public source, candidate/package workflow policy, device helpers and
  text diffs without rebuilding the product. This command is diagnostic; it
  never creates or promotes a product candidate and never replaces the full
  software gate required after product inputs change.
#>
[CmdletBinding()]
param([string]$EvidencePath = '')

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$startedAt = [DateTimeOffset]::UtcNow
$results = [Collections.Generic.List[object]]::new()
if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $EvidencePath = Join-Path $repoRoot (
        'build\verification\acceptance-harness-' +
        $startedAt.ToString('yyyyMMddTHHmmssfffZ') + '.json'
    )
}
$EvidencePath = [IO.Path]::GetFullPath($EvidencePath)
New-Item -ItemType Directory -Path (Split-Path $EvidencePath -Parent) -Force | Out-Null

function Invoke-HarnessCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "[acceptance-harness] $Name" -ForegroundColor Cyan
    try {
        & $Action
        $results.Add([pscustomobject]@{
            name = $Name
            result = 'passed'
            durationMs = $timer.ElapsedMilliseconds
            detail = ''
        })
    } catch {
        $results.Add([pscustomobject]@{
            name = $Name
            result = 'failed'
            durationMs = $timer.ElapsedMilliseconds
            detail = $_.Exception.Message
        })
        throw
    }
}

$failure = ''
try {
    Invoke-HarnessCheck -Name 'public-source-policy' -Action {
        & (Join-Path $PSScriptRoot 'check-public-source.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Public-source policy failed' }
    }
    Invoke-HarnessCheck -Name 'build-workflow-regressions' -Action {
        & (Join-Path $PSScriptRoot 'test-build-workflows.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Build workflow regression failed' }
    }
    Invoke-HarnessCheck -Name 'device-regression-helpers' -Action {
        & (Join-Path $PSScriptRoot 'test-device-regression.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Device regression helper test failed' }
    }
    Invoke-HarnessCheck -Name 'agent-compatibility-verdict' -Action {
        & (Join-Path $PSScriptRoot 'test-agent-compatibility.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Agent compatibility verdict test failed' }
    }
    Invoke-HarnessCheck -Name 'git-diff-check' -Action {
        & git -C $repoRoot diff --check
        if ($LASTEXITCODE -ne 0) { throw 'Unstaged diff check failed' }
        & git -C $repoRoot diff --cached --check
        if ($LASTEXITCODE -ne 0) { throw 'Staged diff check failed' }
    }
} catch {
    $failure = $_.Exception.Message
} finally {
    $evidence = [ordered]@{
        schemaVersion = 1
        gate = 'acceptance-harness-diagnostic'
        result = $(if ($failure) { 'failed' } else { 'passed' })
        startedAt = $startedAt.ToString('o')
        completedAt = [DateTimeOffset]::UtcNow.ToString('o')
        checks = @($results)
        failure = $failure
    }
    [IO.File]::WriteAllText(
        $EvidencePath,
        (ConvertTo-Json -InputObject $evidence -Depth 5),
        [Text.UTF8Encoding]::new($false)
    )
}
if ($failure) { throw $failure }
Write-Host "ACCEPTANCE HARNESS SUCCESS: $EvidencePath" -ForegroundColor Green
