<#
.SYNOPSIS
  Run focused physical-PC gates for LeanTTY file transfer development.
.DESCRIPTION
  The current gate validates same-directory Downloads commits with
  fs.moveFileSync(..., 1). It builds and installs the debug acceptance package,
  locates the compile-time-only menu action through the UI layout, executes it,
  and saves an ignored JSON evidence record.
#>
param(
    [string]$Target = '',
    [switch]$SkipBuild,
    [string]$EvidenceDirectory = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')
. (Join-Path $PSScriptRoot 'acceptance-source.ps1')

$hdc = Resolve-Hdc
if ([string]::IsNullOrWhiteSpace($Target)) {
    $readyTargets = @(Get-HdcTargets -Hdc $hdc | Where-Object {
        $_.transport -match '^(USB|TCP)$' -and $_.status -match '^(Ready|Connected)$'
    })
    $usbTargets = @($readyTargets | Where-Object { $_.transport -eq 'USB' })
    $candidates = if ($usbTargets.Count -gt 0) { $usbTargets } else { $readyTargets }
    if ($candidates.Count -ne 1) {
        throw 'Exactly one ready physical HarmonyOS PC is required, or pass -Target explicitly.'
    }
    $Target = $candidates[0].key
}

if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $EvidenceDirectory = Join-Path $repoRoot "build\verification\file-transfer-$stamp"
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null

$devArgs = @{ Target = $Target; NoLaunch = $true; ForceNative = $true }
if ($SkipBuild) {
    $devArgs.Remove('ForceNative')
    $devArgs['SkipBuild'] = $true
    & (Join-Path $PSScriptRoot 'dev-pc.ps1') @devArgs
} else {
    Invoke-WithLeanTTYNativeAcceptanceSource -RepoRoot $repoRoot -Action {
        & (Join-Path $PSScriptRoot 'dev-pc.ps1') @devArgs
    }
}
if ($LASTEXITCODE -ne 0) { throw 'LeanTTY debug deployment failed' }

$credentialPath = Get-LeanTTYDeviceUnlockPasswordPath
$launchResult = Start-LeanTTYRegressionApp `
    -Hdc $hdc `
    -Target $Target `
    -CredentialPath $credentialPath `
    -RepositoryRoot $repoRoot
$appProcessId = $launchResult.processId

$beforeLayoutPath = Join-Path $EvidenceDirectory 'layout-before.json'
$beforeLayout = Wait-LeanTTYTerminalInputLayout `
    -Hdc $hdc -Target $Target -LocalPath $beforeLayoutPath -TimeoutSeconds 30
$moreButton = @(Get-LeanTTYLayoutNodes -Node $beforeLayout | Where-Object {
    [string]$_.attributes.type -eq 'Stack' -and
    [string]$_.attributes.clickable -eq 'true' -and
    [string]$_.attributes.description -eq ''
} | Sort-Object {
    (Get-LeanTTYBoundsCenter -Bounds ([string]$_.attributes.bounds)).x
} -Descending | Select-Object -First 1)
if ($moreButton.Count -ne 1) { throw 'LeanTTY four-dot menu button was not found' }
$moreCenter = Get-LeanTTYBoundsCenter -Bounds ([string]$moreButton[0].attributes.bounds)

Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
& $hdc -t $Target shell "uitest uiInput click $($moreCenter.x) $($moreCenter.y)" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'LeanTTY four-dot menu could not be opened' }
Start-Sleep -Milliseconds 300

$menuLayoutPath = Join-Path $EvidenceDirectory 'layout-menu.json'
$menuLayout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $menuLayoutPath
$probeLabel = 'Acceptance: Downloads No-Replace'
$probeNode = @(Get-LeanTTYLayoutNodes -Node $menuLayout | Where-Object {
    [string]$_.attributes.text -eq $probeLabel -or
    [string]$_.attributes.originalText -eq $probeLabel
} | Select-Object -First 1)
if ($probeNode.Count -ne 1) {
    throw 'The debug package does not expose the bounded Downloads no-replace action'
}
$probeCenter = Get-LeanTTYBoundsCenter -Bounds ([string]$probeNode[0].attributes.bounds)
& $hdc -t $Target shell "uitest uiInput click $($probeCenter.x) $($probeCenter.y)" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'The Downloads no-replace action could not be triggered' }

$pattern = 'ACCEPTANCE_DOWNLOADS_NOREPLACE passed=true'
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$matchingLine = ''
do {
    $logs = (@(& $hdc -t $Target shell "hilog -z 1200 -t app -P $appProcessId" 2>&1) -join "`n")
    $matchingLine = @($logs -split "`n" | Where-Object { $_ -match $pattern } | Select-Object -Last 1)
    if ($matchingLine.Count -eq 1) { break }
    if ($logs -match 'ACCEPTANCE_DOWNLOADS_NOREPLACE passed=false') {
        throw 'The Downloads no-replace probe reported failure'
    }
    Start-Sleep -Milliseconds 200
} while ($stopwatch.Elapsed.TotalSeconds -lt 10)
if ($matchingLine.Count -ne 1) { throw 'Timed out waiting for the Downloads no-replace result' }

& $hdc -t $Target shell "uitest uiInput click $($moreCenter.x) $($moreCenter.y)" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'LeanTTY four-dot menu could not be reopened' }
Start-Sleep -Milliseconds 300
$fdMenuLayoutPath = Join-Path $EvidenceDirectory 'layout-fd-menu.json'
$fdMenuLayout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $fdMenuLayoutPath
$fdProbeLabel = 'Acceptance: Downloads FD Boundary'
$fdProbeNode = @(Get-LeanTTYLayoutNodes -Node $fdMenuLayout | Where-Object {
    [string]$_.attributes.text -eq $fdProbeLabel -or
    [string]$_.attributes.originalText -eq $fdProbeLabel
} | Select-Object -First 1)
if ($fdProbeNode.Count -ne 1) {
    throw 'The debug package does not expose the bounded Downloads FD action'
}
$fdProbeCenter = Get-LeanTTYBoundsCenter -Bounds ([string]$fdProbeNode[0].attributes.bounds)
& $hdc -t $Target shell "uitest uiInput click $($fdProbeCenter.x) $($fdProbeCenter.y)" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'The Downloads FD action could not be triggered' }

$fdPattern = 'ACCEPTANCE_DOWNLOADS_FD passed=true'
$fdStopwatch = [Diagnostics.Stopwatch]::StartNew()
$fdMatchingLine = ''
do {
    $logs = (@(& $hdc -t $Target shell "hilog -z 1200 -t app -P $appProcessId" 2>&1) -join "`n")
    $fdMatchingLine = @($logs -split "`n" | Where-Object { $_ -match $fdPattern } | Select-Object -Last 1)
    if ($fdMatchingLine.Count -eq 1) { break }
    if ($logs -match 'ACCEPTANCE_DOWNLOADS_FD passed=false') {
        throw 'The Downloads FD probe reported failure'
    }
    Start-Sleep -Milliseconds 200
} while ($fdStopwatch.Elapsed.TotalSeconds -lt 10)
if ($fdMatchingLine.Count -ne 1) { throw 'Timed out waiting for the Downloads FD result' }

& $hdc -t $Target shell "uitest uiInput click $($moreCenter.x) $($moreCenter.y)" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'LeanTTY four-dot menu could not be reopened for the manager probe' }
Start-Sleep -Milliseconds 300
$managerMenuLayoutPath = Join-Path $EvidenceDirectory 'layout-manager-menu.json'
$managerMenuLayout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $managerMenuLayoutPath
$managerProbeLabel = 'Acceptance: Downloads Manager Boundary'
$managerProbeNode = @(Get-LeanTTYLayoutNodes -Node $managerMenuLayout | Where-Object {
    [string]$_.attributes.text -eq $managerProbeLabel -or
    [string]$_.attributes.originalText -eq $managerProbeLabel
} | Select-Object -First 1)
if ($managerProbeNode.Count -ne 1) {
    throw 'The debug package does not expose the production Downloads manager boundary action'
}
$managerProbeCenter = Get-LeanTTYBoundsCenter -Bounds ([string]$managerProbeNode[0].attributes.bounds)
& $hdc -t $Target shell "uitest uiInput click $($managerProbeCenter.x) $($managerProbeCenter.y)" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'The Downloads manager boundary action could not be triggered' }

$managerPattern = 'ACCEPTANCE_DOWNLOADS_MANAGER passed=true'
$managerStopwatch = [Diagnostics.Stopwatch]::StartNew()
$managerMatchingLine = ''
do {
    $logs = (@(& $hdc -t $Target shell "hilog -z 1200 -t app -P $appProcessId" 2>&1) -join "`n")
    $managerMatchingLine = @($logs -split "`n" | Where-Object { $_ -match $managerPattern } | Select-Object -Last 1)
    if ($managerMatchingLine.Count -eq 1) { break }
    if ($logs -match 'ACCEPTANCE_DOWNLOADS_MANAGER passed=false') {
        throw 'The production Downloads manager boundary probe reported failure'
    }
    Start-Sleep -Milliseconds 200
} while ($managerStopwatch.Elapsed.TotalSeconds -lt 300)
if ($managerMatchingLine.Count -ne 1) { throw 'Timed out waiting for the Downloads manager boundary result' }

$deviceFacts = [ordered]@{}
foreach ($paramName in @(
        'const.product.model',
        'const.product.cpu.abilist',
        'const.ohos.apiversion',
        'const.product.software.version'
    )) {
    $deviceFacts[$paramName] = (@(& $hdc -t $Target shell "param get $paramName" 2>&1) -join "`n").Trim()
}

$hapPath = Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
$statusLines = @(git -C $repoRoot status --short)
$evidence = [ordered]@{
    recordedAt = (Get-Date).ToString('o')
    gate = '1.3-local-downloads-capability-boundary'
    result = 'passed'
    target = $Target
    device = $deviceFacts
    sourceBranch = (git -C $repoRoot branch --show-current)
    sourceCommit = (git -C $repoRoot rev-parse HEAD)
    sourceDirty = $statusLines.Count -gt 0
    unlock = $launchResult.unlock
    acceptanceSourceSha256 = (Get-FileHash `
            -LiteralPath (Join-Path $PSScriptRoot 'acceptance-source.ps1') `
            -Algorithm SHA256).Hash.ToLowerInvariant()
    hapSha256 = (Get-FileHash -LiteralPath $hapPath -Algorithm SHA256).Hash.ToLowerInvariant()
    observation = [string]$matchingLine[0]
    fdObservation = [string]$fdMatchingLine[0]
    managerObservation = [string]$managerMatchingLine[0]
    cleanup = 'verified by the application after deleting every exact probe path and symbolic link'
}
$evidencePath = Join-Path $EvidenceDirectory 'device-downloads-capability.json'
$evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $evidencePath -Encoding utf8NoBOM

Write-Host 'FILE TRANSFER PC GATE PASSED: Downloads no-replace + FD/no-follow + product manager boundary' `
    -ForegroundColor Green
Write-Host "Evidence: $evidencePath"
