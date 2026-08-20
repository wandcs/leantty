<#
.SYNOPSIS
  Verify ssh-keygen passphrase behavior on the exact retained HarmonyOS PC candidate.
.DESCRIPTION
  Installs one retained signed HAP, drives the terminal through HDC, waits on
  non-secret structured application logs, checks accessibility snapshots for
  secret exposure, covers positive and negative paths, and cleans disposable
  key data. It never rebuilds the candidate.
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [string]$HapPath = '',
    [string]$EvidenceDirectory = '',
    [string]$CandidateBasePath = '',
    [string]$UnlockPasswordPath = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'candidate-store.ps1')
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')

$harnessStatus = @(git -C $repoRoot status --porcelain --untracked-files=all 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect device behavior harness source state' }
if ($harnessStatus.Count -gt 0) {
    throw 'Device behavior harness requires a clean committed tree'
}
$harnessCommit = (& git -C $repoRoot rev-parse HEAD 2>&1).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve device behavior harness commit' }
$harnessTree = (& git -C $repoRoot rev-parse 'HEAD^{tree}' 2>&1).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve device behavior harness tree' }

$hdc = Resolve-Hdc
$Target = Resolve-LeanTTYRegressionTarget -Hdc $hdc -Target $Target
if ([string]::IsNullOrWhiteSpace($UnlockPasswordPath)) {
    $UnlockPasswordPath = Get-LeanTTYDeviceUnlockPasswordPath
}
Assert-LeanTTYCredentialPathOutsideRepository `
    -CredentialPath $UnlockPasswordPath `
    -RepositoryRoot $repoRoot
$candidateRoot = Get-LeanTTYCandidateRoot `
    -RepoRoot $repoRoot `
    -CandidateBasePath $CandidateBasePath
$candidateRecords = @(Get-LeanTTYCandidateRecords -CandidateRoot $candidateRoot)
if ([string]::IsNullOrWhiteSpace($HapPath)) {
    $candidate = $candidateRecords | Select-Object -First 1
    if ($null -eq $candidate) {
        throw 'No retained candidate exists; run tools/verify-pc.ps1 first'
    }
} else {
    $resolvedHap = [IO.Path]::GetFullPath($HapPath)
    if (-not (Test-Path -LiteralPath $resolvedHap -PathType Leaf)) {
        throw "Candidate HAP is missing: $resolvedHap"
    }
    $requestedHash = (Get-FileHash -LiteralPath $resolvedHap -Algorithm SHA256).Hash.ToLowerInvariant()
    $candidate = $candidateRecords | Where-Object { $_.sha256 -eq $requestedHash } | Select-Object -First 1
    if ($null -eq $candidate) {
        throw 'The selected HAP is not a retained verified candidate'
    }
}
if ($candidate.gitDirty) {
    throw 'Device behavior evidence requires a clean committed candidate; rerun tools/verify-pc.ps1 after committing'
}

if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $repoRoot (
        'build\verification\device-key-passphrase-' +
        [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    )
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$evidencePath = Join-Path $EvidenceDirectory 'device-key-passphrase.json'
$checks = [Collections.Generic.List[object]]::new()
$commandObservations = [Collections.Generic.List[object]]::new()
$startedAt = [DateTimeOffset]::UtcNow
$keyName = 'ltty_reg_' + [Guid]::NewGuid().ToString('N').Substring(0, 10)
$secretA = New-LeanTTYRegressionSecret
$secretB = New-LeanTTYRegressionSecret
$mismatchSecret = New-LeanTTYRegressionSecret
$wrongSecret = New-LeanTTYRegressionSecret
$secrets = @($secretA, $secretB, $mismatchSecret, $wrongSecret)
$keyCleanupRequired = $false
$deviceModel = ''
$deviceAbi = ''
$deviceTransport = ''
$appPid = ''
$failure = ''
$cleanupResult = 'not-required'
$cleanupFailure = ''
$awakeLeaseActive = $false
$awakeLeaseResult = 'not-acquired'
$awakeLeaseFailure = ''
$deviceUnlockResult = 'not-attempted'
$stageStartedAt = $null
$currentBehaviorStage = 'initialization'

function Add-BehaviorCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][long]$DurationMs
    )

    $checks.Add([pscustomobject]@{
        name = $Name
        result = 'passed'
        durationMs = $DurationMs
    })
    Write-Host "[device] PASS $Name ($DurationMs ms)" -ForegroundColor Green
}

function Start-BehaviorStage {
    param([Parameter(Mandatory = $true)][string]$Name)

    Write-Host "[device] START $Name"
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    $script:currentBehaviorStage = $Name
    $script:stageStartedAt = [Diagnostics.Stopwatch]::StartNew()
}

function Complete-BehaviorStage {
    param([Parameter(Mandatory = $true)][string]$Name)

    $logs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appPid
    foreach ($secret in $secrets) {
        if ($logs.Contains($secret)) {
            throw 'HarmonyOS application logs exposed a runtime regression secret'
        }
    }
    if ($null -eq $stageStartedAt) { throw 'Device behavior stage timing was not started' }
    Add-BehaviorCheck -Name $Name -DurationMs $stageStartedAt.ElapsedMilliseconds
    $script:stageStartedAt = $null
}

function Submit-Command {
    param([Parameter(Mandatory = $true)][string]$Command)

    Submit-LeanTTYDeviceCommand `
        -Hdc $hdc `
        -Target $Target `
        -ProcessId $appPid `
        -Command $Command `
        -Stage $currentBehaviorStage `
        -ObservationSink $commandObservations `
        -InputNodeProvider {
            param($inputAttempt)
            $layoutPath = Join-Path $EvidenceDirectory (
                'layout-command-focus-' + $inputAttempt.ToString() + '-' +
                [Guid]::NewGuid().ToString('N') + '.json'
            )
            $layout = Wait-LeanTTYTerminalInputLayout `
                -Hdc $hdc -Target $Target -LocalPath $layoutPath -TimeoutSeconds 10
            $inputNodes = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
            if ($inputNodes.Count -ne 1) {
                throw '[environment] Unable to identify the terminal input before command submission'
            }
            $focusedLayout = Set-LeanTTYTerminalInputFocus `
                -Hdc $hdc -Target $Target -InputNode $inputNodes[0] `
                -LocalPath $layoutPath -TimeoutSeconds 10
            return @(Get-LeanTTYTerminalInputNodes -Layout $focusedLayout | Where-Object {
                    [string]$_.attributes.focused -eq 'true'
                })[0]
        } | Out-Null
}

function Submit-Secret {
    param([string]$Value = '')

    if (-not [string]::IsNullOrEmpty($Value)) {
        $focusPath = Join-Path $EvidenceDirectory (
            'layout-secret-focus-' + [Guid]::NewGuid().ToString('N') + '.json'
        )
        $focusLayout = Wait-LeanTTYTerminalInputLayout `
            -Hdc $hdc `
            -Target $Target `
            -LocalPath $focusPath `
            -TimeoutSeconds 10
        $inputNodes = @(Get-LeanTTYTerminalInputNodes -Layout $focusLayout)
        if ($inputNodes.Count -ne 1) {
            throw '[environment] Unable to identify the terminal input before secret submission'
        }
        Set-LeanTTYTerminalInputFocus `
            -Hdc $hdc `
            -Target $Target `
            -InputNode $inputNodes[0] `
            -LocalPath $focusPath `
            -TimeoutSeconds 10 | Out-Null
        Invoke-LeanTTYDeviceText `
            -Hdc $hdc `
            -Target $Target `
            -Text $Value `
            -InputNode $inputNodes[0]
        $layoutPath = Join-Path $EvidenceDirectory (
            'layout-secret-' + [Guid]::NewGuid().ToString('N') + '.json'
        )
        $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $layoutPath
        try {
            Assert-LeanTTYLayoutExcludesValues -Layout $layout -Values $secrets
        } catch {
            Remove-Item -LiteralPath $layoutPath -Force -ErrorAction SilentlyContinue
            throw
        }
    }
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
}

function Wait-State {
    param([Parameter(Mandatory = $true)][string]$Pattern)

    Wait-LeanTTYAppLog `
        -Hdc $hdc `
        -Target $Target `
        -ProcessId $appPid `
        -Pattern $Pattern `
        -TimeoutSeconds 15 | Out-Null
}

function Invoke-DeleteKeyDialog {
    param([Parameter(Mandatory = $true)][string]$LayoutName)

    $dialogStopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($dialogStopwatch.Elapsed.TotalSeconds -lt 10) {
        try {
            Invoke-LeanTTYDialogButton `
                -Hdc $hdc `
                -Target $Target `
                -ButtonText 'Delete key' `
                -LayoutPath (Join-Path $EvidenceDirectory $LayoutName)
            return
        } catch {
            Start-Sleep -Milliseconds 200
        }
    }
    throw 'Delete-key confirmation did not appear'
}

function Remove-DisposableDeviceKey {
    param([Parameter(Mandatory = $true)][string]$LayoutPrefix)

    if (-not (Test-LeanTTYDeviceKeyFilesPresent `
        -Hdc $hdc `
        -Target $Target `
        -KeyName $keyName)) {
        return 'already-absent'
    }

    Clear-LeanTTYDeviceInput `
        -Hdc $hdc `
        -Target $Target
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-Command -Command "key rm $keyName"
    Invoke-DeleteKeyDialog -LayoutName "$LayoutPrefix-dialog.json"
    Wait-State -Pattern 'KEY_DELETE result=success'
    if (Test-LeanTTYDeviceKeyFilesPresent `
        -Hdc $hdc `
        -Target $Target `
        -KeyName $keyName) {
        throw 'Disposable key files remain in the LeanTTY application sandbox after deletion'
    }
    return 'verified-absent'
}

function Write-BehaviorEvidence {
    param([Parameter(Mandatory = $true)][string]$Result)

    $automationVerdict = if (@($commandObservations | Where-Object {
        $_.result -eq 'unknown'
    }).Count -gt 0) { 'unknown' } else { $Result }
    $evidence = [ordered]@{
        schemaVersion = 2
        gate = 'device-behavior'
        scenario = 'ssh-keygen-passphrase'
        result = $Result
        startedAt = $startedAt.ToString('o')
        completedAt = [DateTimeOffset]::UtcNow.ToString('o')
        durationMs = [long]([DateTimeOffset]::UtcNow - $startedAt).TotalMilliseconds
        candidate = [ordered]@{
            sha256 = $candidate.sha256
            gitCommit = $candidate.gitCommit
            gitTree = $candidate.gitTree
            gitDirty = $candidate.gitDirty
        }
        harness = [ordered]@{
            gitCommit = $harnessCommit
            gitTree = $harnessTree
            gitDirty = $false
        }
        device = [ordered]@{
            model = $deviceModel
            abi = $deviceAbi
            transport = $deviceTransport
        }
        environment = [ordered]@{
            awakeLease = $awakeLeaseResult
            deviceUnlock = $deviceUnlockResult
            failure = $awakeLeaseFailure
        }
        input = [ordered]@{
            commandInjection = 'harmony-uitest-targeted-inputText-with-pre-submit-buffer-verification'
            secretInjection = 'harmony-uitest-targeted-inputText-runtime-generated-printable-ascii'
            postInputSettleMilliseconds = 500
            fixedDelayUsedAsVerdict = $false
        }
        automation = Get-LeanTTYDeviceCommandAutomationSummary `
            -Observations $commandObservations `
            -BusinessVerdict $automationVerdict `
            -BusinessPostcondition 'key-passphrase-checks-and-cleanup'
        checks = @($checks)
        cleanup = [ordered]@{
            result = $cleanupResult
            failure = $cleanupFailure
        }
        failure = $failure
    }
    [IO.File]::WriteAllText(
        $evidencePath,
        (ConvertTo-Json -InputObject $evidence -Depth 7),
        [Text.UTF8Encoding]::new($false)
    )
}

$caughtError = $null
$scenarioResult = 'failed'
try {
    $preflightStopwatch = [Diagnostics.Stopwatch]::StartNew()
    Write-Host '[device] START device-harness-preflight'
    Start-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $Target
    $awakeLeaseActive = $true
    $awakeLeaseResult = 'acquired'
    & (Join-Path $PSScriptRoot 'dev-pc.ps1') `
        -Target $Target `
        -HapPath $candidate.hapPath `
        -SkipBuild `
        -NoLaunch
    if ($LASTEXITCODE -ne 0) { throw 'Exact candidate deployment failed' }

    $appStart = Start-LeanTTYRegressionApp `
        -Hdc $hdc `
        -Target $Target `
        -CredentialPath $UnlockPasswordPath `
        -RepositoryRoot $repoRoot
    $appPid = $appStart.processId
    $deviceUnlockResult = $appStart.unlock
    Write-Host "LeanTTY started. PID=$appPid" -ForegroundColor Green
    if ($deviceUnlockResult -eq 'local-plaintext-credential') {
        Write-Host '[device] INFO unlocked regression PC from local credential file'
    }

    $deviceModel = (Invoke-HdcShell $hdc $Target 'param get const.product.model').Trim()
    $deviceAbi = (Invoke-HdcShell $hdc $Target 'param get const.product.cpu.abilist').Trim()
    $deviceTransport = Get-HdcTargetTransport -Hdc $hdc -Target $Target
    if ($deviceAbi -notmatch 'arm64-v8a') { throw "Device is not ARM64: $deviceAbi" }

    Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appPid | Out-Null
    $preflightLayoutPath = Join-Path $EvidenceDirectory 'layout-preflight.json'
    $preflightLayout = Wait-LeanTTYTerminalInputLayout `
        -Hdc $hdc `
        -Target $Target `
        -LocalPath $preflightLayoutPath `
        -TimeoutSeconds 20
    Get-LeanTTYTerminalInputText -Layout $preflightLayout | Out-Null
    Clear-LeanTTYDeviceInput `
        -Hdc $hdc `
        -Target $Target
    Add-BehaviorCheck `
        -Name 'device-harness-preflight' `
        -DurationMs $preflightStopwatch.ElapsedMilliseconds

    Start-BehaviorStage -Name 'generated-disposable-ed25519-key'
    $keyCleanupRequired = $true
    Submit-Command -Command "ssh-keygen -t ed25519 -f $keyName -C regression"
    Wait-State -Pattern 'Key generated:'
    Complete-BehaviorStage -Name 'generated-disposable-ed25519-key'

    Start-BehaviorStage -Name 'added-passphrase-without-layout-or-log-exposure'
    Submit-Command -Command "ssh-keygen -p -f $keyName"
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE stage=old'
    Submit-Secret
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE stage=new'
    Submit-Secret -Value $secretA
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE stage=confirm'
    Submit-Secret -Value $secretA
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE result=success'
    Complete-BehaviorStage -Name 'added-passphrase-without-layout-or-log-exposure'

    Start-BehaviorStage -Name 'mismatched-confirmation-made-no-change'
    Submit-Command -Command "ssh-keygen -p -f $keyName"
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE stage=old'
    Submit-Secret -Value $secretA
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE stage=new'
    Submit-Secret -Value $secretB
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE stage=confirm'
    Submit-Secret -Value $mismatchSecret
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE result=mismatch stage=old'
    Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $Target
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE result=cancelled'
    Complete-BehaviorStage -Name 'mismatched-confirmation-made-no-change'

    Start-BehaviorStage -Name 'wrong-old-passphrase-made-no-change'
    Submit-Command -Command "ssh-keygen -p -f $keyName"
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE stage=old'
    Submit-Secret -Value $wrongSecret
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE stage=new'
    Submit-Secret -Value $secretB
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE stage=confirm'
    Submit-Secret -Value $secretB
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE result=failure reason=native'
    Complete-BehaviorStage -Name 'wrong-old-passphrase-made-no-change'
    if (-not (Test-LeanTTYDeviceKeyFilesPresent `
        -Hdc $hdc `
        -Target $Target `
        -KeyName $keyName)) {
        throw 'Disposable key files disappeared after rejected old passphrase'
    }

    Start-BehaviorStage -Name 'recovered-after-negative-paths-with-original-passphrase'
    Submit-Command -Command "ssh-keygen -p -f $keyName"
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE stage=old'
    Submit-Secret -Value $secretA
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE stage=new'
    Submit-Secret -Value $secretB
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE stage=confirm'
    Submit-Secret -Value $secretB
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE result=success'
    Complete-BehaviorStage -Name 'recovered-after-negative-paths-with-original-passphrase'

    Start-BehaviorStage -Name 'ctrl-c-cancelled-and-cleared-secret-input'
    Submit-Command -Command "ssh-keygen -p -f $keyName"
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE stage=old'
    $cancelFocusPath = Join-Path $EvidenceDirectory 'layout-cancel-secret-focus.json'
    $cancelFocusLayout = Wait-LeanTTYTerminalInputLayout `
        -Hdc $hdc `
        -Target $Target `
        -LocalPath $cancelFocusPath `
        -TimeoutSeconds 10
    $cancelInputNodes = @(Get-LeanTTYTerminalInputNodes -Layout $cancelFocusLayout)
    if ($cancelInputNodes.Count -ne 1) {
        throw '[environment] Unable to identify the terminal input before cancellation secret'
    }
    Set-LeanTTYTerminalInputFocus `
        -Hdc $hdc `
        -Target $Target `
        -InputNode $cancelInputNodes[0] `
        -LocalPath $cancelFocusPath `
        -TimeoutSeconds 10 | Out-Null
    Invoke-LeanTTYDeviceText `
        -Hdc $hdc `
        -Target $Target `
        -Text $secretB `
        -InputNode $cancelInputNodes[0]
    $cancelLayoutPath = Join-Path $EvidenceDirectory 'layout-cancel-secret.json'
    $cancelLayout = Get-LeanTTYDeviceLayout `
        -Hdc $hdc `
        -Target $Target `
        -LocalPath $cancelLayoutPath
    try {
        Assert-LeanTTYLayoutExcludesValues -Layout $cancelLayout -Values $secrets
    } catch {
        Remove-Item -LiteralPath $cancelLayoutPath -Force -ErrorAction SilentlyContinue
        throw
    }
    Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $Target
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE result=cancelled'
    Complete-BehaviorStage -Name 'ctrl-c-cancelled-and-cleared-secret-input'

    Start-BehaviorStage -Name 'removed-passphrase'
    Submit-Command -Command "ssh-keygen -p -f $keyName"
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE stage=old'
    Submit-Secret -Value $secretB
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE stage=new'
    Submit-Secret
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE stage=confirm'
    Submit-Secret
    Wait-State -Pattern 'KEY_PASSPHRASE_CHANGE result=success'
    Complete-BehaviorStage -Name 'removed-passphrase'

    Start-BehaviorStage -Name 'deleted-disposable-key-by-native-layout-button'
    Submit-Command -Command "key rm $keyName"
    Invoke-DeleteKeyDialog -LayoutName 'layout-delete-dialog.json'
    Wait-State -Pattern 'KEY_DELETE result=success'
    if (Test-LeanTTYDeviceKeyFilesPresent `
        -Hdc $hdc `
        -Target $Target `
        -KeyName $keyName) {
        throw 'Disposable key files remain in the LeanTTY application sandbox after deletion'
    }
    $keyCleanupRequired = $false
    $cleanupResult = 'verified-absent'
    Complete-BehaviorStage -Name 'deleted-disposable-key-by-native-layout-button'
    $scenarioResult = 'passed'
} catch {
    $caughtError = $_
    $failure = $_.Exception.Message
    try {
        $failureLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appPid
        foreach ($secret in $secrets) {
            if (-not [string]::IsNullOrEmpty($secret)) {
                $failureLogs = $failureLogs.Replace($secret, '[REDACTED]')
            }
        }
        [IO.File]::WriteAllText(
            (Join-Path $EvidenceDirectory 'failure-app-logs.txt'),
            $failureLogs,
            [Text.UTF8Encoding]::new($false)
        )
        $failureLogs = ''
    } catch {}
    try {
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc `
            -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'failure.png')
    } catch {}
} finally {
    if ($keyCleanupRequired -and -not [string]::IsNullOrWhiteSpace($appPid)) {
        try {
            Write-Host '[device] START disposable-key-cleanup'
            $cleanupResult = Remove-DisposableDeviceKey -LayoutPrefix 'layout-cleanup'
            $keyCleanupRequired = $false
            Write-Host "[device] PASS disposable-key-cleanup ($cleanupResult)" -ForegroundColor Green
        } catch {
            $cleanupResult = 'failed'
            $cleanupFailure = $_.Exception.Message
            if ([string]::IsNullOrWhiteSpace($failure)) {
                $failure = "Cleanup failed: $cleanupFailure"
            }
        }
    }
    if ($awakeLeaseActive) {
        try {
            Stop-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $Target
            $awakeLeaseActive = $false
            $awakeLeaseResult = 'restored'
        } catch {
            $awakeLeaseResult = 'restore-failed'
            $awakeLeaseFailure = $_.Exception.Message
            if ([string]::IsNullOrWhiteSpace($failure)) {
                $failure = "Environment restore failed: $awakeLeaseFailure"
            }
        }
    }
    $secretA = ''
    $secretB = ''
    $mismatchSecret = ''
    $wrongSecret = ''
    $secrets = @()
}

if (-not [string]::IsNullOrWhiteSpace($cleanupFailure)) {
    $scenarioResult = 'failed'
}
if (-not [string]::IsNullOrWhiteSpace($awakeLeaseFailure)) {
    $scenarioResult = 'failed'
}
Write-BehaviorEvidence -Result $scenarioResult

if ($scenarioResult -ne 'passed') {
    if ($null -ne $caughtError) { throw $caughtError }
    throw $failure
}

Save-LeanTTYVerifiedCandidate `
    -RepoRoot $repoRoot `
    -HapPath $candidate.hapPath `
    -VerificationMode 'device-behavior' `
    -EvidencePaths @($evidencePath) `
    -CandidateBasePath $CandidateBasePath | Out-Null
Write-Host (
    'DEVICE BEHAVIOR SUCCESS: ssh-keygen-passphrase ' +
    "(SHA256=$($candidate.sha256), evidence=$evidencePath)"
) -ForegroundColor Green
