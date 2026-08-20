<#
.SYNOPSIS
  Verify SSH readiness retry and background concurrency on a physical PC.
.DESCRIPTION
  Builds an acceptance-only HAP whose first preparation fails and whose second
  attempt is delayed. The verifier submits a real SSH-dependent local command,
  backgrounds the app during the retry, and requires the production preparation
  path to complete exactly once without losing the process.
#>
param(
    [string]$Target = '',
    [string]$EvidenceDirectory = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')
. (Join-Path $PSScriptRoot 'startup-readiness-source.ps1')

function Get-StartupReadinessLogs {
    param([Parameter(Mandatory = $true)][string]$ProcessId)

    $output = @(& $script:readinessHdc -t $script:readinessTarget shell (
        "hilog -z 500 -t app -P $ProcessId " +
        '-T StartupReadinessAcceptance,SessionViewModel,EntryAbility -v msec'
    ) 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read startup readiness diagnostic logs' }
    return $output -join "`n"
}

function Wait-StartupReadinessLog {
    param(
        [Parameter(Mandatory = $true)][string]$ProcessId,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [ValidateRange(1, 30)][int]$TimeoutSeconds = 10
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $logs = Get-StartupReadinessLogs -ProcessId $ProcessId
        if ($logs -match $Pattern) { return $logs }
        if ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            Start-Sleep -Milliseconds 200
        }
    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw "Timed out waiting for startup readiness state: $Pattern"
}

$hdc = Resolve-Hdc
$targetId = Resolve-LeanTTYRegressionTarget -Hdc $hdc -Target $Target
$script:readinessHdc = $hdc
$script:readinessTarget = $targetId
$transport = Get-HdcTargetTransport -Hdc $hdc -Target $targetId
if ($transport -ne 'usb') {
    throw "Startup readiness verification requires a USB-connected physical PC, got $transport"
}
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $repoRoot (
        'build\verification\startup-readiness-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    )
}
$evidencePath = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Force -Path $evidencePath | Out-Null
$commandObservations = [Collections.Generic.List[object]]::new()

$awakeLease = $false
try {
    Start-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $targetId
    $awakeLease = $true

    Invoke-WithLeanTTYStartupReadinessSource -RepoRoot $repoRoot -Action {
        & (Join-Path $PSScriptRoot 'dev-pc.ps1') -Target $targetId -NoLaunch
        if ($LASTEXITCODE -ne 0) { throw 'Startup readiness diagnostic deployment failed' }
    }

    $hapPath = Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
    $hapSha256 = (Get-FileHash -LiteralPath $hapPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
    $start = Start-LeanTTYRegressionApp `
        -Hdc $hdc `
        -Target $targetId `
        -CredentialPath (Get-LeanTTYDeviceUnlockPasswordPath) `
        -RepositoryRoot $repoRoot
    Wait-LeanTTYTerminalInputLayout `
        -Hdc $hdc `
        -Target $targetId `
        -LocalPath (Join-Path $evidencePath 'initial-ready.json') `
        -TimeoutSeconds 20 | Out-Null
    Wait-StartupReadinessLog `
        -ProcessId $start.processId `
        -Pattern 'ACCEPTANCE_STARTUP_PREP attempt=1 state=failed' `
        -TimeoutSeconds 10 | Out-Null

    Submit-LeanTTYDeviceCommand `
        -Hdc $hdc `
        -Target $targetId `
        -ProcessId $start.processId `
        -Command 'key list' `
        -Stage 'first-ssh-dependent-command-after-retry' `
        -ObservationSink $commandObservations `
        -InputNodeProvider {
            param($inputAttempt)
            Get-LeanTTYSingleFocusedTerminalInputNode `
                -Hdc $hdc `
                -Target $targetId `
                -LocalPath (Join-Path $evidencePath (
                        'command-focus-' + $inputAttempt.ToString() + '.json'
                    ))
        } | Out-Null
    Wait-StartupReadinessLog `
        -ProcessId $start.processId `
        -Pattern 'ACCEPTANCE_STARTUP_PREP attempt=2 state=started' `
        -TimeoutSeconds 10 | Out-Null
    & $hdc -t $targetId shell 'uitest uiInput keyEvent Home' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to background LeanTTY during SSH preparation' }
    Wait-StartupReadinessLog `
        -ProcessId $start.processId `
        -Pattern 'ACCEPTANCE_STARTUP_PREP attempt=2 state=completed' `
        -TimeoutSeconds 15 | Out-Null

    $processId = (@(& $hdc -t $targetId shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or $processId -ne $start.processId) {
        throw 'LeanTTY did not retain the same process during the delayed preparation retry'
    }
    $logs = Get-StartupReadinessLogs -ProcessId $start.processId
    $failedCount = ([regex]::Matches(
        $logs,
        'ACCEPTANCE_STARTUP_PREP attempt=1 state=failed'
    )).Count
    $completedCount = ([regex]::Matches(
        $logs,
        'ACCEPTANCE_STARTUP_PREP attempt=2 state=completed'
    )).Count
    if ($failedCount -ne 1 -or $completedCount -ne 1) {
        throw 'SSH preparation retry did not produce exactly one injected failure and one completion'
    }
    if ($logs -match 'Deferred durable garbage collection failed') {
        throw 'Deferred garbage collection failed while SSH preparation was in flight'
    }

    Start-LeanTTYRegressionApp `
        -Hdc $hdc `
        -Target $targetId `
        -CredentialPath (Get-LeanTTYDeviceUnlockPasswordPath) `
        -RepositoryRoot $repoRoot | Out-Null
    Wait-LeanTTYTerminalInputLayout `
        -Hdc $hdc `
        -Target $targetId `
        -LocalPath (Join-Path $evidencePath 'foreground-ready.json') `
        -TimeoutSeconds 20 | Out-Null
    Save-LeanTTYDeviceScreenshot `
        -Hdc $hdc `
        -Target $targetId `
        -LocalPath (Join-Path $evidencePath 'retry-completed.png')

    $summary = [ordered]@{
        schemaVersion = 1
        capturedAt = (Get-Date).ToString('o')
        scenario = 'first-preparation-fails-second-completes-while-backgrounded'
        gitCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
        target = $targetId
        transport = $transport
        diagnosticHapSha256 = $hapSha256
        firstAttemptFailureCount = $failedCount
        secondAttemptCompletionCount = $completedCount
        sameProcessRetained = $true
        deferredGarbageCollectionFailureAbsent = $true
        automation = Get-LeanTTYDeviceCommandAutomationSummary `
            -Observations $commandObservations `
            -BusinessVerdict 'passed' `
            -BusinessPostcondition 'startup-retry-completed-and-first-ssh-command-succeeded'
    }
    $summaryPath = Join-Path $evidencePath 'summary.json'
    [IO.File]::WriteAllText($summaryPath, (ConvertTo-Json $summary -Depth 6) + "`n")
    Write-Host "STARTUP READINESS EVIDENCE: $summaryPath" -ForegroundColor Green
} finally {
    if ($awakeLease) {
        Stop-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $targetId
    }
}
