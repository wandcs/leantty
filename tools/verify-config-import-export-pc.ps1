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
$runId = [Guid]::NewGuid().ToString('N').Substring(0, 12)
$prefix = "leantty-config-$runId"
$fixtureName = "$prefix-import.conf"
$originalName = "$prefix-original.conf"
$cleanupName = "$prefix-cleanup.conf"
$exportName = "$prefix-export.conf"
$reopenName = "$prefix-reopen.conf"
$restoredName = "$prefix-restored.conf"
$deviceDownloads = '/storage/Users/currentUser/Download'
$deviceNames = @($fixtureName, $originalName, $cleanupName, $exportName, $reopenName, $restoredName)
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') +
    [IO.Path]::DirectorySeparatorChar
$localRoot = [IO.Path]::GetFullPath((Join-Path $temporaryRoot "leantty-config-$runId"))
if (-not $localRoot.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Config import/export temporary root escaped the system temporary directory'
}

if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $repoRoot (
        'build\verification\config-import-export-' + $startedAt.ToString('yyyyMMdd-HHmmss')
    )
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null
New-Item -ItemType Directory -Path $localRoot | Out-Null

$fixturePath = Join-Path $localRoot $fixtureName
$originalPath = Join-Path $localRoot $originalName
$cleanupPath = Join-Path $localRoot $cleanupName
$exportPath = Join-Path $localRoot $exportName
$reopenPath = Join-Path $localRoot $reopenName
$restoredPath = Join-Path $localRoot $restoredName
$conflictPath = Join-Path $localRoot ('conflict-' + $exportName)
$restoredUnmanagedPath = Join-Path $localRoot ('unmanaged-' + $restoredName)

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

function Invoke-ConfigHdcFile {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('send', 'recv')][string]$Operation,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $output = @(& $script:hdc -t $script:targetId file $Operation $Source $Destination 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $output -match '(?i)\[Fail\]|error') {
        throw "[infrastructure] HDC file $Operation failed"
    }
}

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
    Wait-LeanTTYAppLog -Hdc $script:hdc -Target $script:targetId -ProcessId $script:appPid `
        -Pattern $SuccessPattern -TimeoutSeconds 30 | Out-Null
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

function Remove-ConfigManagedRegion {
    param([Parameter(Mandatory = $true)][string]$Text)
    $pattern = '(?ms)\A[ \t]*# >>> LeanTTY managed hosts >>>\r?\n.*?' +
        '^[ \t]*# <<< LeanTTY managed hosts <<<\r?\n(?:\r?\n)?'
    if ($Text -notmatch '# >>> LeanTTY managed hosts >>>') { return $Text }
    $clean = [regex]::Replace($Text, $pattern, '', 1)
    if ($clean -eq $Text -or $clean -match '# (?:>>>|<<<) LeanTTY managed hosts') {
        throw '[harness] Exported config contained an unexpected managed-region layout'
    }
    return $clean
}

function Remove-ConfigDeviceFiles {
    foreach ($name in $deviceNames) {
        if ($name -notmatch '^leantty-config-[0-9a-f]{12}-(?:import|original|cleanup|export|reopen|restored)\.conf$') {
            throw '[harness] Config cleanup name escaped the disposable namespace'
        }
        & $script:hdc -t $script:targetId shell "rm -f $deviceDownloads/$name" 2>$null | Out-Null
    }
    $remaining = @(& $script:hdc -t $script:targetId shell "ls $deviceDownloads" 2>&1) -join "`n"
    foreach ($name in $deviceNames) {
        if ($remaining -match "(?m)^$([regex]::Escape($name))$") {
            throw '[harness] A disposable config file remains in Downloads'
        }
    }
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

    Submit-ConfigCommand -Command "config export $originalName" -Stage 'backup-original' `
        -SuccessPattern 'CONFIG_EXPORT result=success'
    Invoke-ConfigHdcFile -Operation recv -Source "$deviceDownloads/$originalName" -Destination $originalPath
    $originalText = [IO.File]::ReadAllText($originalPath)
    $cleanupText = Remove-ConfigManagedRegion -Text $originalText
    [IO.File]::WriteAllText($cleanupPath, $cleanupText, [Text.UTF8Encoding]::new($false))
    $fixtureNewline = if ($originalText.Contains("`r`n")) { "`r`n" } else { "`n" }
    $fixtureText = '# LeanTTY controlled config fixture' + $fixtureNewline +
        'Host __ltty_config_fixture' + $fixtureNewline +
        '  HostName fixture.example.test' + $fixtureNewline +
        '  User deploy' + $fixtureNewline +
        '  Port 2222' + $fixtureNewline +
        '  ConnectTimeout 12' + $fixtureNewline +
        '  ServerAliveInterval 30' + $fixtureNewline +
        '  ServerAliveCountMax 3' + $fixtureNewline
    [IO.File]::WriteAllText($fixturePath, $fixtureText, [Text.UTF8Encoding]::new($false))
    Invoke-ConfigHdcFile -Operation send -Source $fixturePath `
        -Destination "$deviceDownloads/$fixtureName"
    Invoke-ConfigHdcFile -Operation send -Source $cleanupPath `
        -Destination "$deviceDownloads/$cleanupName"

    Submit-ConfigCommand -Command "config import $fixtureName --replace" -Stage 'import-fixture' `
        -SuccessPattern 'CONFIG_IMPORT result=success,replace=true'
    $configModified = $true
    $hashes.importProjection = Get-ConfigProjectionHash
    Submit-ConfigCommand -Command "config export $exportName" -Stage 'export-imported' `
        -SuccessPattern 'CONFIG_EXPORT result=success'
    Invoke-ConfigHdcFile -Operation recv -Source "$deviceDownloads/$exportName" -Destination $exportPath
    $hashes.exported = (Get-FileHash -LiteralPath $exportPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hashes.exported -ne $hashes.importProjection) {
        throw '[product] Exported config did not match the active projection'
    }
    if (-not [IO.File]::ReadAllText($exportPath).Contains($fixtureText)) {
        throw '[product] Exported config did not preserve the imported source bytes'
    }

    Clear-LeanTTYAppLogs -Hdc $hdc -Target $targetId
    Submit-LeanTTYDeviceCommand -Hdc $hdc -Target $targetId -ProcessId $appPid `
        -Command "config export $exportName" -Stage 'export-conflict' `
        -ObservationSink $commandObservations `
        -InputNodeProvider { param($inputAttempt) Get-ConfigInputNode } | Out-Null
    Wait-LeanTTYAppLog -Hdc $hdc -Target $targetId -ProcessId $appPid `
        -Pattern 'Config export failed:' -TimeoutSeconds 30 | Out-Null
    Invoke-ConfigHdcFile -Operation recv -Source "$deviceDownloads/$exportName" -Destination $conflictPath
    if ((Get-FileHash -LiteralPath $conflictPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hashes.exported) {
        throw '[product] Export conflict changed the existing Downloads file'
    }

    Restart-ConfigApp
    $hashes.reopenProjection = Get-ConfigProjectionHash
    if ($hashes.reopenProjection -ne $hashes.importProjection) {
        throw '[product] Restart did not reopen the imported durable config'
    }
    Submit-ConfigCommand -Command "config export $reopenName" -Stage 'export-after-restart' `
        -SuccessPattern 'CONFIG_EXPORT result=success'
    Invoke-ConfigHdcFile -Operation recv -Source "$deviceDownloads/$reopenName" -Destination $reopenPath
    $hashes.reopenedExport = (Get-FileHash -LiteralPath $reopenPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hashes.reopenedExport -ne $hashes.importProjection) {
        throw '[product] Export after restart did not match the imported config'
    }

    Submit-ConfigCommand -Command "config import $cleanupName --replace" -Stage 'restore-original' `
        -SuccessPattern 'CONFIG_IMPORT result=success,replace=true'
    $configRestored = $true
    Submit-ConfigCommand -Command "config export $restoredName" -Stage 'verify-restored' `
        -SuccessPattern 'CONFIG_EXPORT result=success'
    Invoke-ConfigHdcFile -Operation recv -Source "$deviceDownloads/$restoredName" -Destination $restoredPath
    $hashes.original = (Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $hashes.restored = (Get-FileHash -LiteralPath $restoredPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $restoredUnmanaged = Remove-ConfigManagedRegion -Text ([IO.File]::ReadAllText($restoredPath))
    [IO.File]::WriteAllText($restoredUnmanagedPath, $restoredUnmanaged, [Text.UTF8Encoding]::new($false))
    $hashes.originalUnmanaged = (Get-FileHash -LiteralPath $cleanupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $hashes.restoredUnmanaged = (
        Get-FileHash -LiteralPath $restoredUnmanagedPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    if ($hashes.restoredUnmanaged -ne $hashes.originalUnmanaged) {
        throw '[product] Product-path cleanup did not restore the original unmanaged config bytes'
    }

    Remove-ConfigDeviceFiles
    $cleanupComplete = (-not $configModified) -or $configRestored
    $result = 'passed'
} catch {
    $failure = $_.Exception.Message
    if ($failure -notmatch '^\[(product|harness|environment|infrastructure|unknown)\]') {
        $failure = '[harness] ' + $failure
    }
} finally {
    if (-not $cleanupComplete -and -not [string]::IsNullOrWhiteSpace($targetId)) {
        try {
            if ($configModified -and -not $configRestored -and
                (Test-Path -LiteralPath $cleanupPath -PathType Leaf)) {
                try {
                    $recoveryStart = Start-LeanTTYRegressionApp -Hdc $script:hdc -Target $script:targetId `
                        -CredentialPath (Get-LeanTTYDeviceUnlockPasswordPath) -RepositoryRoot $repoRoot
                    $script:appPid = $recoveryStart.processId
                    Wait-LeanTTYTerminalInputLayout -Hdc $script:hdc -Target $script:targetId `
                        -LocalPath (Join-Path $EvidenceDirectory 'cleanup-ready.json') `
                        -TimeoutSeconds 30 | Out-Null
                    Submit-ConfigCommand -Command "config import $cleanupName --replace" `
                        -Stage 'finally-restore-original' `
                        -SuccessPattern 'CONFIG_IMPORT result=success,replace=true'
                    $configRestored = $true
                } catch {}
            }
            Remove-ConfigDeviceFiles
            $cleanupComplete = (-not $configModified) -or $configRestored
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
    try {
        if (Test-Path -LiteralPath $localRoot) {
            Remove-Item -LiteralPath $localRoot -Recurse -Force
        }
    } catch {}
}

if ($result -ne 'passed') { throw "Config import/export physical verification failed: $failure" }
Write-Host "CONFIG IMPORT/EXPORT PC PASSED: $EvidenceDirectory" -ForegroundColor Green
