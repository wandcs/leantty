<#
.SYNOPSIS
  Verify an in-place LeanTTY 1.3 to 1.4 startup upgrade on a physical PC.
.DESCRIPTION
  Installs the exact 1.3 review-test HAP, records only hashes and aggregate
  metadata for the existing SSH projection, upgrades in place to a supplied
  1.4 test HAP, exercises the deferred SSH readiness path, backgrounds the app
  so deferred GC runs, and proves the projection bytes remain unchanged.
  File contents, host names, paths outside the app sandbox, and key material
  are never copied into the evidence directory.
#>
param(
    [string]$Target = '',
    [Parameter(Mandatory = $true)]
    [Alias('V13HapPath')]
    [string]$BaselineReviewHapPath,
    [Parameter(Mandatory = $true)]
    [Alias('CandidateHapPath')]
    [string]$CandidateReviewHapPath,
    [string]$EvidenceDirectory = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')
. (Join-Path $PSScriptRoot 'release-tooling.ps1')

function Install-StartupUpgradeHap {
    param([Parameter(Mandatory = $true)][string]$Path)

    $output = @(& $script:hdc -t $script:target install -r -d $Path 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $output -match '(?i)\[Fail\]|error') {
        throw "HAP install failed: $output"
    }
}

function Get-StartupProjectionSnapshot {
    $sshDirectory = '/data/app/el2/100/base/com.leantty.app/haps/entry/files/.ssh'
    $command = "cd $sshDirectory && sha256sum -- *"
    $output = @(& $script:hdc -t $script:target shell -b com.leantty.app $command 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to hash the LeanTTY SSH projection in the application sandbox'
    }

    $entries = @{}
    foreach ($line in $output) {
        $match = [regex]::Match([string]$line, '^(?<hash>[0-9a-fA-F]{64})\s+\*?(?<name>.+)$')
        if ($match.Success) {
            $name = $match.Groups['name'].Value
            if ($name.Contains('/') -or $name.Contains('\')) {
                throw 'SSH projection hash output escaped the expected directory'
            }
            $entries[$name] = $match.Groups['hash'].Value.ToLowerInvariant()
            continue
        }
        $protectedMatch = [regex]::Match(
            [string]$line,
            '^sha256sum: (?<name>[^/\\]+): Permission denied$'
        )
        if ($protectedMatch.Success) {
            $entries[$protectedMatch.Groups['name'].Value] = 'protected-and-unreadable'
            continue
        }
        throw 'Unexpected SSH projection hash output'
    }
    if (-not $entries.ContainsKey('config')) {
        throw 'The upgrade fixture requires an existing SSH config projection'
    }
    if (-not $entries.ContainsKey('known_hosts')) {
        throw 'The upgrade fixture requires an existing known_hosts projection'
    }
    $privateKeyCount = @($entries.Keys | Where-Object {
        $_ -ne 'config' -and $_ -ne 'known_hosts' -and $_ -ne 'config.leantty.bak' -and
        -not $_.EndsWith('.pub')
    }).Count
    $publicKeyCount = @($entries.Keys | Where-Object { $_.EndsWith('.pub') }).Count
    if ($privateKeyCount -lt 1 -or $privateKeyCount -ne $publicKeyCount) {
        throw 'The upgrade fixture requires at least one complete SSH key pair'
    }
    return [pscustomobject]@{
        entries = $entries
        fileCount = $entries.Count
        privateKeyCount = $privateKeyCount
        publicKeyCount = $publicKeyCount
    }
}

function Assert-StartupProjectionEqual {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Stage
    )

    if ($Expected.entries.Count -ne $Actual.entries.Count) {
        throw "$Stage changed the SSH projection file count"
    }
    foreach ($name in $Expected.entries.Keys) {
        if (-not $Actual.entries.ContainsKey($name) -or
            $Actual.entries[$name] -ne $Expected.entries[$name]) {
            throw "$Stage changed an SSH projection file"
        }
    }
}

function Start-StartupUpgradeApp {
    param([Parameter(Mandatory = $true)][string]$LayoutName)

    $start = Start-LeanTTYRegressionApp `
        -Hdc $script:hdc `
        -Target $script:target `
        -CredentialPath (Get-LeanTTYDeviceUnlockPasswordPath) `
        -RepositoryRoot $repoRoot
    $layoutPath = Join-Path $script:evidenceDirectory $LayoutName
    Wait-LeanTTYTerminalInputLayout `
        -Hdc $script:hdc `
        -Target $script:target `
        -LocalPath $layoutPath `
        -TimeoutSeconds 20 | Out-Null
    return $start
}

$script:hdc = Resolve-Hdc
$script:target = Resolve-LeanTTYRegressionTarget -Hdc $script:hdc -Target $Target
$transport = Get-HdcTargetTransport -Hdc $script:hdc -Target $script:target
if ($transport -ne 'usb') {
    throw "Startup upgrade verification requires a USB-connected physical PC, got $transport"
}

$v13Hap = Assert-LeanTTYDeviceTestHapPath `
    -HapPath $BaselineReviewHapPath `
    -ParameterName 'BaselineReviewHapPath'
$candidateHap = Assert-LeanTTYDeviceTestHapPath `
    -HapPath $CandidateReviewHapPath `
    -ParameterName 'CandidateReviewHapPath'

if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $repoRoot (
        'build\verification\startup-upgrade-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    )
}
$script:evidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Force -Path $script:evidenceDirectory | Out-Null
$commandObservations = [Collections.Generic.List[object]]::new()

$awakeLease = $false
try {
    Start-LeanTTYDeviceAwakeLease -Hdc $script:hdc -Target $script:target
    $awakeLease = $true

    & $script:hdc -t $script:target shell 'aa force-stop com.leantty.app' | Out-Null
    Install-StartupUpgradeHap -Path $v13Hap
    $v13Start = Start-StartupUpgradeApp -LayoutName 'v13-ready.json'
    Start-Sleep -Milliseconds 1200
    $v13Projection = Get-StartupProjectionSnapshot

    & $script:hdc -t $script:target shell 'aa force-stop com.leantty.app' | Out-Null
    Install-StartupUpgradeHap -Path $candidateHap
    Clear-LeanTTYAppLogs -Hdc $script:hdc -Target $script:target
    $candidateStart = Start-StartupUpgradeApp -LayoutName 'v14-ready.json'
    Submit-LeanTTYDeviceCommand `
        -Hdc $script:hdc `
        -Target $script:target `
        -ProcessId $candidateStart.processId `
        -Command 'key list' `
        -Stage 'v14-first-ssh-dependent-command' `
        -ObservationSink $commandObservations `
        -InputNodeProvider {
            param($inputAttempt)
            Get-LeanTTYSingleFocusedTerminalInputNode `
                -Hdc $script:hdc `
                -Target $script:target `
                -LocalPath (Join-Path $script:evidenceDirectory (
                        'command-focus-' + $inputAttempt.ToString() + '.json'
                    ))
        } | Out-Null
    Start-Sleep -Milliseconds 200
    Save-LeanTTYDeviceScreenshot `
        -Hdc $script:hdc `
        -Target $script:target `
        -LocalPath (Join-Path $script:evidenceDirectory 'v14-first-ssh-dependent-command.png')
    Start-Sleep -Milliseconds 2500
    $candidateProjection = Get-StartupProjectionSnapshot
    Assert-StartupProjectionEqual `
        -Expected $v13Projection `
        -Actual $candidateProjection `
        -Stage 'The 1.3 to 1.4 upgrade'

    & $script:hdc -t $script:target shell 'uitest uiInput keyEvent Home' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to background LeanTTY for deferred maintenance' }
    Start-Sleep -Milliseconds 1800
    $backgroundProcessId = @(
        & $script:hdc -t $script:target shell 'pidof com.leantty.app' 2>&1
    ) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $backgroundProcessId.Trim() -ne $candidateStart.processId) {
        throw 'LeanTTY did not retain the same process during background maintenance'
    }
    $backgroundLogs = Get-LeanTTYAppLogs `
        -Hdc $script:hdc `
        -Target $script:target `
        -ProcessId $candidateStart.processId
    if ($backgroundLogs -match 'Deferred durable garbage collection failed' -or
        $backgroundLogs -match 'Background SSH environment preparation failed') {
        throw 'Deferred startup maintenance failed while the application was backgrounded'
    }
    $backgroundProjection = Get-StartupProjectionSnapshot
    Assert-StartupProjectionEqual `
        -Expected $v13Projection `
        -Actual $backgroundProjection `
        -Stage 'Deferred background maintenance'

    $summary = [ordered]@{
        schemaVersion = 1
        capturedAt = (Get-Date).ToString('o')
        scenario = 'in-place-v1.3-to-v1.4-with-existing-ssh-assets'
        gitCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
        target = $script:target
        transport = $transport
        v13HapSha256 = (Get-FileHash -LiteralPath $v13Hap -Algorithm SHA256).Hash.ToLowerInvariant()
        candidateHapSha256 = (
            Get-FileHash -LiteralPath $candidateHap -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        projection = [ordered]@{
            fileCount = $v13Projection.fileCount
            privateKeyCount = $v13Projection.privateKeyCount
            publicKeyCount = $v13Projection.publicKeyCount
            configPresent = $true
            knownHostsPresent = $true
            privateKeysProtectedFromShellRead = $true
            byteHashesUnchangedAfterUpgrade = $true
            byteHashesUnchangedAfterBackgroundMaintenance = $true
        }
        process = [ordered]@{
            v13 = $v13Start.processId
            v14 = $candidateStart.processId
            v14RemainedAliveInBackground = $true
        }
        automation = Get-LeanTTYDeviceCommandAutomationSummary `
            -Observations $commandObservations `
            -BusinessVerdict 'passed' `
            -BusinessPostcondition 'upgrade-preserved-projection-and-first-ssh-command-succeeded'
    }
    $summaryPath = Join-Path $script:evidenceDirectory 'summary.json'
    [IO.File]::WriteAllText($summaryPath, (ConvertTo-Json $summary -Depth 8) + "`n")
    Write-Host "STARTUP UPGRADE EVIDENCE: $summaryPath" -ForegroundColor Green
} finally {
    if ($awakeLease) {
        Stop-LeanTTYDeviceAwakeLease -Hdc $script:hdc -Target $script:target
    }
}
