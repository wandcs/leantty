<#
.SYNOPSIS
  Check the HarmonyOS PC control channels before a named physical scenario.
.DESCRIPTION
  Performs a bounded, read-only HDC and UiTest preflight. It does not install,
  launch, unlock or otherwise repair the device, and it does not claim product
  behavior. A passing result only authorizes the selected named scenario to
  begin its own setup.
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [string]$EvidencePath = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')

$startedAt = [DateTimeOffset]::UtcNow
$hdc = Resolve-Hdc
$resolvedTarget = ''
$targetInfo = $null
$layoutSummary = $null
$commandChannelPassed = $false
$serializedLayoutPassed = $false
$temporaryLayoutPath = Join-Path (
    [IO.Path]::GetTempPath()
) ('LeanTTY-device-preflight-' + [Guid]::NewGuid().ToString('N') + '.json')

if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $evidenceDirectory = Join-Path $repoRoot 'build\verification'
    $EvidencePath = Join-Path $evidenceDirectory (
        'device-preflight-' + $startedAt.ToString('yyyyMMddTHHmmssfffZ') + '.json'
    )
} else {
    $EvidencePath = [IO.Path]::GetFullPath($EvidencePath)
    $evidenceDirectory = Split-Path $EvidencePath -Parent
}
New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null

function Get-PreflightFailureDomain {
    param([string]$Message)

    $match = [regex]::Match($Message, '^\[(?<domain>infrastructure|environment|harness)\]')
    if ($match.Success) { return $match.Groups['domain'].Value }
    return 'harness'
}

function Write-DevicePreflightEvidence {
    param(
        [ValidateSet('passed', 'failed')][string]$Result,
        [string]$Failure = '',
        [string]$FailureDomain = ''
    )

    $evidence = [ordered]@{
        schemaVersion = 1
        gate = 'device-control-preflight'
        result = $Result
        acceptanceEligible = $false
        productBehaviorClaimed = $false
        startedAt = $startedAt.ToString('o')
        completedAt = [DateTimeOffset]::UtcNow.ToString('o')
        durationMs = [int]([DateTimeOffset]::UtcNow - $startedAt).TotalMilliseconds
        target = $(if ($null -eq $targetInfo) {
                $resolvedTarget
            } else {
                [ordered]@{
                    key = $targetInfo.key
                    transport = $targetInfo.transport
                    status = $targetInfo.status
                }
            })
        checks = [ordered]@{
            readyTarget = ($null -ne $targetInfo)
            commandChannel = $commandChannelPassed
            serializedUiTestLayout = $serializedLayoutPassed
            layout = $layoutSummary
        }
        failureDomain = $FailureDomain
        failure = $Failure
    }
    [IO.File]::WriteAllText(
        $EvidencePath,
        (ConvertTo-Json -InputObject $evidence -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )
}

try {
    $resolvedTarget = Resolve-LeanTTYRegressionTarget -Hdc $hdc -Target $Target
    $targetInfo = Assert-HdcTargetReady -Hdc $hdc -Target $resolvedTarget

    $probe = Invoke-HdcChecked `
        -Hdc $hdc `
        -Target $resolvedTarget `
        -Arguments @('shell', 'printf LEANTTY_DEVICE_PREFLIGHT') `
        -Operation 'HarmonyOS HDC command-channel preflight'
    if ($probe.Trim() -ne 'LEANTTY_DEVICE_PREFLIGHT') {
        throw '[infrastructure] HarmonyOS HDC command channel returned an unexpected probe result'
    }
    $commandChannelPassed = $true

    $layout = Get-LeanTTYDeviceLayout `
        -Hdc $hdc `
        -Target $resolvedTarget `
        -LocalPath $temporaryLayoutPath `
        -BundleName ''
    $allNodes = @(Get-LeanTTYLayoutNodes -Node $layout)
    $rootBounds = [string]$layout.attributes.bounds
    $boundsMatch = [regex]::Match(
        $rootBounds,
        '^\[(?<x1>\d+),(?<y1>\d+)\]\[(?<x2>\d+),(?<y2>\d+)\]$'
    )
    if (-not $boundsMatch.Success -or
        [int]$boundsMatch.Groups['x2'].Value -le [int]$boundsMatch.Groups['x1'].Value -or
        [int]$boundsMatch.Groups['y2'].Value -le [int]$boundsMatch.Groups['y1'].Value) {
        throw '[environment] HarmonyOS UiTest layout has no interactive screen bounds'
    }
    $focusedNodes = @($allNodes | Where-Object {
        [string]$_.attributes.focused -eq 'true'
    })
    $layoutSummary = [ordered]@{
        rootBounds = $rootBounds
        nodeCount = $allNodes.Count
        focusedNodeCount = $focusedNodes.Count
    }
    $serializedLayoutPassed = $true

    Write-DevicePreflightEvidence -Result 'passed'
    Write-Host (
        "DEVICE CONTROL PREFLIGHT SUCCESS: target=$resolvedTarget, " +
        "layoutNodes=$($allNodes.Count), evidence=$EvidencePath"
    ) -ForegroundColor Green
} catch {
    $message = $_.Exception.Message
    $domain = Get-PreflightFailureDomain -Message $message
    Write-DevicePreflightEvidence `
        -Result 'failed' `
        -Failure $message `
        -FailureDomain $domain
    throw
} finally {
    if (Test-Path -LiteralPath $temporaryLayoutPath -PathType Leaf) {
        Remove-Item -LiteralPath $temporaryLayoutPath -Force
    }
}
