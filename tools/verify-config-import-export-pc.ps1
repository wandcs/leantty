<#
.SYNOPSIS
  Verify controlled OpenSSH config import/export on a physical HarmonyOS PC.
.DESCRIPTION
  Exercises the production command parser, Downloads authorization, config
  validation and durable projection through an exact signed debug HAP. It
  exports and restores the pre-existing config through product commands, checks
  no-replace export, restarts the application, compares only SHA-256 digests,
  and removes every run-scoped Downloads file.
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [string]$HapPath = '',
    [switch]$SkipBuild,
    [string]$EvidenceDirectory = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$deployedHapPath = if ([string]::IsNullOrWhiteSpace($HapPath)) {
    Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
} else {
    [IO.Path]::GetFullPath($HapPath)
}
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')
. (Join-Path $PSScriptRoot 'acceptance-source.ps1')

$startedAt = [DateTimeOffset]::UtcNow
$fixtureName = 'leantty-config-acceptance-import.conf'
$originalName = 'leantty-config-acceptance-original.conf'
$cleanupName = 'leantty-config-acceptance-cleanup.conf'
$exportName = 'leantty-config-acceptance-export.conf'
$reopenName = 'leantty-config-acceptance-reopen.conf'
$restoredName = 'leantty-config-acceptance-restored.conf'

if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $repoRoot (
        'build\verification\config-import-export-' + $startedAt.ToString('yyyyMMdd-HHmmss')
    )
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null

$hdc = Resolve-Hdc
$targetId = ''
$appPid = ''
$awakeLeaseActive = $false
$result = 'failed'
$failure = ''
$cleanupComplete = $false
$configModified = $false
$configRestored = $false
$commandObservations = [Collections.Generic.List[object]]::new()
$hashes = [ordered]@{}

function Get-ConfigInputNode {
    $layoutPath = Join-Path $EvidenceDirectory 'command-focus.json'
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $layout = Get-LeanTTYDeviceLayout -Hdc $script:hdc -Target $script:targetId -LocalPath $layoutPath
        $nodes = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
        $focused = @($nodes | Where-Object { [string]$_.attributes.focused -eq 'true' })
        $node = if ($focused.Count -eq 1) { $focused[0] } elseif ($nodes.Count -eq 1) { $nodes[0] } else { $null }
        if ($null -ne $node) {
            if ([string]$node.attributes.focused -ne 'true') {
                Set-LeanTTYTerminalInputFocus -Hdc $script:hdc -Target $script:targetId `
                    -InputNode $node -LocalPath $layoutPath -TimeoutSeconds 10 | Out-Null
            }
            return $node
        }
        Start-Sleep -Milliseconds 200
    } while ($stopwatch.Elapsed.TotalSeconds -lt 10)
    throw '[environment] Unable to identify the active LeanTTY command input'
}

function Submit-ConfigCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$SuccessPattern
    )
    Clear-LeanTTYAppLogs -Hdc $script:hdc -Target $script:targetId
    Submit-LeanTTYDeviceCommand -Hdc $script:hdc -Target $script:targetId `
        -ProcessId $script:appPid -Command $Command -Stage $Stage `
        -ObservationSink $commandObservations `
        -InputNodeProvider { param($inputAttempt) Get-ConfigInputNode } | Out-Null
    return Wait-LeanTTYAppLog -Hdc $script:hdc -Target $script:targetId -ProcessId $script:appPid `
        -Pattern $SuccessPattern -TimeoutSeconds 30
}

function Invoke-ConfigAcceptanceCommand {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('prepare', 'observe', 'verify', 'cleanup')][string]$Action,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Pattern
    )
    return Submit-ConfigCommand -Command "__acceptance_config_$Action" -Stage $Stage -SuccessPattern $Pattern
}

function Get-ConfigAcceptanceHashes {
    param([Parameter(Mandatory = $true)][string]$Logs, [Parameter(Mandatory = $true)][string]$State)
    $match = [regex]::Match($Logs,
        "ACCEPTANCE_CONFIG state=$State,.*?import=(?<import>[0-9a-f]{64}|missing)," +
        'original=(?<original>[0-9a-f]{64}|missing),cleanup=(?<cleanup>[0-9a-f]{64}|missing),' +
        'export=(?<export>[0-9a-f]{64}|missing),reopen=(?<reopen>[0-9a-f]{64}|missing),' +
        'restored=(?<restored>[0-9a-f]{64}|missing)')
    if (-not $match.Success) { throw '[harness] Config acceptance hash log was malformed' }
    return [ordered]@{
        import = $match.Groups['import'].Value
        original = $match.Groups['original'].Value
        cleanup = $match.Groups['cleanup'].Value
        export = $match.Groups['export'].Value
        reopen = $match.Groups['reopen'].Value
        restored = $match.Groups['restored'].Value
    }
}

function Restart-ConfigApp {
    & $script:hdc -t $script:targetId shell 'aa force-stop com.leantty.app' | Out-Null
    $start = Start-LeanTTYRegressionApp -Hdc $script:hdc -Target $script:targetId `
        -CredentialPath (Get-LeanTTYDeviceUnlockPasswordPath) -RepositoryRoot $repoRoot
    $script:appPid = $start.processId
    Wait-LeanTTYTerminalInputLayout -Hdc $script:hdc -Target $script:targetId `
        -LocalPath (Join-Path $EvidenceDirectory 'restart-ready.json') -TimeoutSeconds 30 | Out-Null
}

function Get-ConfigProjectionHash {
    $configPath = '/data/app/el2/100/base/com.leantty.app/haps/entry/files/.ssh/config'
    $output = @(& $script:hdc -t $script:targetId shell -b com.leantty.app "sha256sum $configPath" 2>&1)
    if ($LASTEXITCODE -ne 0) { throw '[harness] Unable to hash the app config projection' }
    $match = [regex]::Match(($output -join "`n"), '^(?<hash>[0-9a-fA-F]{64})\s+')
    if (-not $match.Success) { throw '[harness] App config projection hash was malformed' }
    return $match.Groups['hash'].Value.ToLowerInvariant()
}

try {
    $targetId = Resolve-LeanTTYRegressionTarget -Hdc $hdc -Target $Target
    $script:hdc = $hdc
    $script:targetId = $targetId
    & (Join-Path $PSScriptRoot 'preflight-device.ps1') -Target $targetId `
        -EvidencePath (Join-Path $EvidenceDirectory 'preflight.json')
    if ($LASTEXITCODE -ne 0) { throw '[infrastructure] Device preflight failed' }

    Start-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $targetId
    $awakeLeaseActive = $true
    if ([string]::IsNullOrWhiteSpace($HapPath)) {
        if ($SkipBuild) {
            & (Join-Path $PSScriptRoot 'dev-pc.ps1') -Target $targetId -SkipBuild -NoLaunch
        } else {
            Invoke-WithLeanTTYNativeAcceptanceSource -RepoRoot $repoRoot -Action {
                & (Join-Path $PSScriptRoot 'dev-pc.ps1') -Target $targetId -ForceNative -NoLaunch
            }
        }
    } else {
        & (Join-Path $PSScriptRoot 'dev-pc.ps1') -Target $targetId `
            -HapPath ([IO.Path]::GetFullPath($HapPath)) -SkipBuild -NoLaunch
    }
    if ($LASTEXITCODE -ne 0) { throw '[infrastructure] Config test HAP deployment failed' }

    $start = Start-LeanTTYRegressionApp -Hdc $hdc -Target $targetId `
        -CredentialPath (Get-LeanTTYDeviceUnlockPasswordPath) -RepositoryRoot $repoRoot
    $appPid = $start.processId
    $script:appPid = $appPid
    Wait-LeanTTYTerminalInputLayout -Hdc $hdc -Target $targetId `
        -LocalPath (Join-Path $EvidenceDirectory 'initial-ready.json') -TimeoutSeconds 30 | Out-Null

    $prepareLogs = Invoke-ConfigAcceptanceCommand -Action prepare -Stage 'prepare-fixtures' `
        -Pattern 'ACCEPTANCE_CONFIG state=prepared,.*staleCleaned=true'
    $prepareMatch = [regex]::Match($prepareLogs,
        'ACCEPTANCE_CONFIG state=prepared,fixture=(?<fixture>[0-9a-f]{64}),cleanup=(?<cleanup>[0-9a-f]{64})')
    if (-not $prepareMatch.Success) { throw '[harness] Config fixture preparation log was malformed' }
    $hashes.fixture = $prepareMatch.Groups['fixture'].Value
    $hashes.originalUnmanaged = $prepareMatch.Groups['cleanup'].Value

    $null = Submit-ConfigCommand -Command "config export $originalName" -Stage 'backup-original' `
        -SuccessPattern 'CONFIG_EXPORT result=success'
    $null = Submit-ConfigCommand -Command "config import $fixtureName --replace" -Stage 'import-fixture' `
        -SuccessPattern 'CONFIG_IMPORT result=success,replace=true'
    $configModified = $true
    $hashes.importProjection = Get-ConfigProjectionHash
    $null = Submit-ConfigCommand -Command "config export $exportName" -Stage 'export-imported' `
        -SuccessPattern 'CONFIG_EXPORT result=success'
    $beforeConflictLogs = Invoke-ConfigAcceptanceCommand -Action observe -Stage 'observe-before-conflict' `
        -Pattern 'ACCEPTANCE_CONFIG state=observed,.*export=[0-9a-f]{64}'
    $beforeConflictHashes = Get-ConfigAcceptanceHashes -Logs $beforeConflictLogs -State observed
    $hashes.original = $beforeConflictHashes.original
    $hashes.exported = $beforeConflictHashes.export
    if ($hashes.exported -ne $hashes.importProjection) {
        throw '[product] Exported config did not match the active projection'
    }

    Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
    Submit-LeanTTYDeviceCommand -Hdc $hdc -Target $targetId -ProcessId $appPid `
        -Command "config export $exportName" -Stage 'export-conflict' `
        -ObservationSink $commandObservations `
        -InputNodeProvider { param($inputAttempt) Get-ConfigInputNode } | Out-Null
    Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
        -Pattern 'Config export failed:' -TimeoutSeconds 30 | Out-Null
    $afterConflictLogs = Invoke-ConfigAcceptanceCommand -Action observe -Stage 'observe-after-conflict' `
        -Pattern 'ACCEPTANCE_CONFIG state=observed,.*export=[0-9a-f]{64}'
    $afterConflictHashes = Get-ConfigAcceptanceHashes -Logs $afterConflictLogs -State observed
    if ($afterConflictHashes.export -ne $hashes.exported) {
        throw '[product] Export conflict changed the existing Downloads file'
    }

    Restart-ConfigApp
    $hashes.reopenProjection = Get-ConfigProjectionHash
    if ($hashes.reopenProjection -ne $hashes.importProjection) {
        throw '[product] Restart did not reopen the imported durable config'
    }
    $null = Submit-ConfigCommand -Command "config export $reopenName" -Stage 'export-after-restart' `
        -SuccessPattern 'CONFIG_EXPORT result=success'
    $null = Submit-ConfigCommand -Command "config import $cleanupName --replace" -Stage 'restore-original' `
        -SuccessPattern 'CONFIG_IMPORT result=success,replace=true'
    $configRestored = $true
    $null = Submit-ConfigCommand -Command "config export $restoredName" -Stage 'export-restored' `
        -SuccessPattern 'CONFIG_EXPORT result=success'
    $verifyLogs = Invoke-ConfigAcceptanceCommand -Action verify -Stage 'verify-and-clean-fixtures' `
        -Pattern 'ACCEPTANCE_CONFIG state=verified,passed=true,.*cleanupComplete=true'
    $verifiedHashes = Get-ConfigAcceptanceHashes -Logs $verifyLogs -State verified
    $hashes.reopenedExport = $verifiedHashes.reopen
    $hashes.restored = $verifiedHashes.restored
    $hashes.restoredUnmanaged = $verifiedHashes.cleanup
    if ($hashes.reopenedExport -ne $hashes.importProjection) {
        throw '[product] Export after restart did not match the imported config'
    }
    if ($hashes.restoredUnmanaged -ne $hashes.originalUnmanaged) {
        throw '[product] Product-path cleanup did not restore the original unmanaged config bytes'
    }
    $cleanupComplete = $true
    $result = 'passed'
} catch {
    $failure = $_.Exception.Message
    if ($failure -notmatch '^\[(product|harness|environment|infrastructure|unknown)\]') {
        $failure = '[harness] ' + $failure
    }
} finally {
    if (-not $cleanupComplete -and -not [string]::IsNullOrWhiteSpace($targetId)) {
        try {
            if ($configModified -and -not $configRestored) {
                try {
                    $recoveryStart = Start-LeanTTYRegressionApp -Hdc $script:hdc -Target $script:targetId `
                        -CredentialPath (Get-LeanTTYDeviceUnlockPasswordPath) -RepositoryRoot $repoRoot
                    $script:appPid = $recoveryStart.processId
                    Wait-LeanTTYTerminalInputLayout -Hdc $script:hdc -Target $script:targetId `
                        -LocalPath (Join-Path $EvidenceDirectory 'cleanup-ready.json') `
                        -TimeoutSeconds 30 | Out-Null
                    $null = Submit-ConfigCommand -Command "config import $cleanupName --replace" `
                        -Stage 'finally-restore-original' `
                        -SuccessPattern 'CONFIG_IMPORT result=success,replace=true'
                    $configRestored = $true
                } catch {}
            }
            $cleanupLogs = Invoke-ConfigAcceptanceCommand -Action cleanup -Stage 'finally-clean-fixtures' `
                -Pattern 'ACCEPTANCE_CONFIG state=cleaned,cleanupComplete=true'
            $cleanupComplete = $cleanupLogs -match 'ACCEPTANCE_CONFIG state=cleaned,cleanupComplete=true' -and
                ((-not $configModified) -or $configRestored)
        } catch {}
    }
    if ($awakeLeaseActive) {
        Stop-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $targetId
    }

    $automation = Get-LeanTTYDeviceCommandAutomationSummary `
        -Observations $commandObservations `
        -BusinessVerdict $(if ($result -eq 'passed') { 'passed' } elseif ($failure -match '^\[unknown\]') {
            'unknown'
        } else { 'failed' }) `
        -BusinessPostcondition 'config import/export, no-replace, restart reopen and original-config restoration'
    $evidence = [ordered]@{
        schemaVersion = 1
        gate = 'config-import-export-physical-pc'
        result = $result
        acceptanceEligible = $false
        sourceBranch = (git -C $repoRoot branch --show-current)
        sourceCommit = (git -C $repoRoot rev-parse HEAD)
        sourceDirty = @(git -C $repoRoot status --short).Count -gt 0
        hapPath = $deployedHapPath
        hapSha256 = if (Test-Path -LiteralPath $deployedHapPath) {
            (Get-FileHash -LiteralPath $deployedHapPath -Algorithm SHA256).Hash.ToLowerInvariant()
        } else { '' }
        startedAt = $startedAt.ToString('o')
        completedAt = [DateTimeOffset]::UtcNow.ToString('o')
        hashes = $hashes
        commandAutomation = $automation
        cleanupComplete = $cleanupComplete
        failure = $failure
        research = [ordered]@{
            date = '2026-08-21'
            question = 'Downloads file IO, picker alternative and no-replace config migration on HarmonyOS PC'
            sources = @(
                'https://gitee.com/openharmony/docs/blob/39467f023bec8cfca8ec2f97b99039b1dbd141e5/en/application-dev/file-management/app-file-access.md',
                'https://gitee.com/openharmony/docs/blob/f71f4e0666cad9707f0aff890465534a5802c142/zh-cn/application-dev/file-management/save-user-file.md'
            )
            unresolved = 'Official docs do not guarantee cross-store transactionality; LeanTTY tests rollback and physical reopen.'
        }
    }
    [IO.File]::WriteAllText(
        (Join-Path $EvidenceDirectory 'config-import-export.json'),
        (ConvertTo-Json -InputObject $evidence -Depth 10),
        [Text.UTF8Encoding]::new($false)
    )
}

if ($result -ne 'passed') { throw "Config import/export physical verification failed: $failure" }
Write-Host "CONFIG IMPORT/EXPORT PC PASSED: $EvidenceDirectory" -ForegroundColor Green
