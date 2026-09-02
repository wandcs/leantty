<#
.SYNOPSIS
  Verify that ordinary uninstall removes the unexpected-exit workspace record.
.DESCRIPTION
  Installs one exact signed HAP, creates a two-Tab workspace with two Panes in
  the active Tab, force-stops the process, uninstalls without keeping app data,
  reinstalls the same HAP, and proves the new installation starts at generation
  one with a default single Pane. HarmonyOS Asset Store data is neither read nor
  mutated by this scenario.
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [Parameter(Mandatory = $true)][string]$HapPath,
    [string]$EvidenceDirectory = '',
    [string]$UnlockPasswordPath = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')

if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path ([IO.Path]::GetTempPath()) (
        'LeanTTY-unexpected-recovery-uninstall-' + [Guid]::NewGuid().ToString('N')
    )
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null

$HapPath = [IO.Path]::GetFullPath($HapPath)
if (-not (Test-Path -LiteralPath $HapPath -PathType Leaf) -or
    (Split-Path $HapPath -Leaf) -match 'unsigned') {
    throw "Signed HAP not found: $HapPath"
}

$hdc = Resolve-Hdc
$Target = Resolve-LeanTTYRegressionTarget -Hdc $hdc -Target $Target
$candidateSha256 = (Get-FileHash -LiteralPath $HapPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($UnlockPasswordPath)) {
    $UnlockPasswordPath = Get-LeanTTYDeviceUnlockPasswordPath
}

function Install-ExactCandidate {
    Invoke-HdcChecked `
        -Hdc $hdc -Target $Target `
        -Arguments @('install', '-r', $HapPath) `
        -Operation 'exact LeanTTY candidate install' | Out-Null
}

function Uninstall-LeanTTYApplication {
    # Intentionally omit -k: the contract under test is removal of app-private
    # Preferences. Durable SSH assets live in HarmonyOS Asset Store instead.
    Invoke-HdcChecked `
        -Hdc $hdc -Target $Target `
        -Arguments @('uninstall', 'com.leantty.app') `
        -Operation 'ordinary LeanTTY uninstall' | Out-Null
}

function Wait-LeanTTYProcessAbsent {
    param([ValidateRange(1, 30)][int]$TimeoutSeconds = 15)

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $pidText = (@(& $hdc -t $Target shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
        if ([string]::IsNullOrWhiteSpace($pidText)) { return }
        Start-Sleep -Milliseconds 250
    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw '[environment] LeanTTY process remained present after force-stop'
}

function Get-TerminalContentTop {
    param([Parameter(Mandatory = $true)]$Layout)

    $tops = @(Get-LeanTTYLayoutNodes -Node $Layout | ForEach-Object {
        if ([string]$_.attributes.type -eq 'Web' -and
            [string]$_.attributes.visible -eq 'true' -and
            [string]$_.attributes.originalText -match 'terminal\.html$' -and
            [string]$_.attributes.bounds -match '^\[\d+,(?<top>\d+)\]\[\d+,\d+\]$') {
            [int]$Matches.top
        }
    })
    if ($tops.Count -eq 0) {
        throw '[harness] LeanTTY terminal content boundary was unavailable'
    }
    return [int](($tops | Measure-Object -Minimum).Minimum)
}

function Get-WorkspaceState {
    param([Parameter(Mandatory = $true)]$Layout)

    $contentTop = Get-TerminalContentTop -Layout $Layout
    $tabs = @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object {
        if ([string]$_.attributes.type -ne 'Stack' -or
            [string]$_.attributes.clickable -ne 'true' -or
            [string]::IsNullOrWhiteSpace([string]$_.attributes.description) -or
            [string]$_.attributes.bounds -notmatch
                '^\[\d+,(?<top>\d+)\]\[\d+,(?<bottom>\d+)\]$') {
            return $false
        }
        [int]$Matches.top -lt $contentTop -and [int]$Matches.bottom -le $contentTop
    })
    $activeSurfaces = @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object {
        if ([string]$_.attributes.type -ne '__Common__' -or
            [string]$_.attributes.opacity -ne '1.000000' -or
            [string]$_.attributes.zIndex -ne '1' -or
            [string]$_.attributes.bounds -notmatch
                '^\[\d+,(?<top>\d+)\]\[\d+,(?<bottom>\d+)\]$' -or
            [int]$Matches.top -lt $contentTop -or [int]$Matches.bottom -le ($contentTop + 20)) {
            return $false
        }
        @(Get-LeanTTYLayoutNodes -Node $_ | Where-Object {
            [string]$_.attributes.type -eq 'Web' -and
            [string]$_.attributes.visible -eq 'true' -and
            [string]$_.attributes.originalText -match 'terminal\.html$'
        }).Count -eq 1
    })
    return [pscustomobject]@{
        tabCount = $tabs.Count
        paneCount = $activeSurfaces.Count
    }
}

function Wait-WorkspaceState {
    param(
        [Parameter(Mandatory = $true)][int]$TabCount,
        [Parameter(Mandatory = $true)][int]$PaneCount,
        [Parameter(Mandatory = $true)][string]$LayoutName,
        [ValidateRange(1, 30)][int]$TimeoutSeconds = 20
    )

    $path = Join-Path $EvidenceDirectory $LayoutName
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $path
        $state = Get-WorkspaceState -Layout $layout
        if ($state.tabCount -eq $TabCount -and $state.paneCount -eq $PaneCount) {
            return $state
        }
        Start-Sleep -Milliseconds 250
    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw "[product] Workspace state mismatch: expected tabs=$TabCount,panes=$PaneCount; " +
        "observed tabs=$($state.tabCount),panes=$($state.paneCount)"
}

function Invoke-WorkspaceShortcut {
    param([Parameter(Mandatory = $true)][ValidateSet('new-tab', 'split')][string]$Action)

    $command = if ($Action -eq 'new-tab') {
        'uinput -K -d 2072 -d 2047 -d 2036 -u 2036 -u 2047 -u 2072'
    } else {
        'uinput -K -d 2072 -d 2047 -d 2020 -u 2020 -u 2047 -u 2072'
    }
    Invoke-HdcChecked `
        -Hdc $hdc -Target $Target -Arguments @('shell', $command) `
        -Operation "LeanTTY $Action physical shortcut" | Out-Null
}

function Get-RecoveryPreferencesDigest {
    $path = '/data/app/el2/100/base/com.leantty.app/haps/entry/preferences/' +
        'leantty_unexpected_exit_recovery'
    $output = @(& $hdc -t $Target shell -b com.leantty.app "sha256sum $path" 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or
        $output -notmatch '(?m)^(?<digest>[0-9a-fA-F]{64})\s+') {
        throw '[environment] Unexpected-exit Preferences digest was unavailable'
    }
    return $Matches.digest.ToLowerInvariant()
}

function Wait-RecoveryStartupLog {
    param([Parameter(Mandatory = $true)][string]$ProcessId)

    $pattern = 'Recovery run started: generation=1, unexpected=false'
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $logs = Invoke-HdcChecked `
            -Hdc $hdc -Target $Target `
            -Arguments @('shell', "hilog -z 500 -t app -P $ProcessId -T UnexpectedExitRecoveryStore") `
            -Operation 'unexpected-exit recovery log query'
        if ($logs.Contains($pattern)) { return $logs }
        Start-Sleep -Milliseconds 500
    } while ($stopwatch.Elapsed.TotalSeconds -lt 15)
    throw '[product] Reinstalled application did not start as generation 1 without recovery'
}

$awakeLease = $false
$finalInstalled = $false
$result = [ordered]@{
    target = $Target
    candidate = [ordered]@{
        hapPath = $HapPath
        sha256 = $candidateSha256
        role = 'test-signed-diagnostic-hap'
    }
    scenario = 'ordinary-uninstall-removes-unexpected-workspace'
    status = 'running'
}

try {
    Start-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $Target -TimeoutMilliseconds 900000
    $awakeLease = $true

    # Establish a known fresh-install baseline before creating the record under test.
    Install-ExactCandidate
    Uninstall-LeanTTYApplication
    Install-ExactCandidate
    $finalInstalled = $true
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    $beforeStart = Start-LeanTTYRegressionApp `
        -Hdc $hdc -Target $Target -CredentialPath $UnlockPasswordPath -RepositoryRoot $repoRoot
    $baseline = Wait-WorkspaceState -TabCount 1 -PaneCount 1 -LayoutName 'baseline.json'

    Invoke-WorkspaceShortcut -Action 'new-tab'
    Wait-WorkspaceState -TabCount 2 -PaneCount 1 -LayoutName 'two-tabs.json' | Out-Null
    Invoke-WorkspaceShortcut -Action 'split'
    $beforeUninstall = Wait-WorkspaceState `
        -TabCount 2 -PaneCount 2 -LayoutName 'before-uninstall.json'
    $digestBefore = Get-RecoveryPreferencesDigest

    Invoke-HdcChecked `
        -Hdc $hdc -Target $Target `
        -Arguments @('shell', 'aa force-stop com.leantty.app') `
        -Operation 'unexpected LeanTTY process stop' | Out-Null
    Wait-LeanTTYProcessAbsent

    Uninstall-LeanTTYApplication
    $finalInstalled = $false
    Install-ExactCandidate
    $finalInstalled = $true
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    $afterStart = Start-LeanTTYRegressionApp `
        -Hdc $hdc -Target $Target -CredentialPath $UnlockPasswordPath -RepositoryRoot $repoRoot
    $afterReinstall = Wait-WorkspaceState `
        -TabCount 1 -PaneCount 1 -LayoutName 'after-reinstall.json'
    $startupLogs = Wait-RecoveryStartupLog -ProcessId $afterStart.processId
    $digestAfter = Get-RecoveryPreferencesDigest
    if ($digestAfter -eq $digestBefore) {
        throw '[product] Recovery Preferences digest survived ordinary uninstall unchanged'
    }
    if ($startupLogs -match 'unexpected=true|Workspace layout was recovered') {
        throw '[product] Reinstalled application reported stale workspace recovery'
    }

    $result.before = [ordered]@{
        processId = $beforeStart.processId
        tabCount = $beforeUninstall.tabCount
        activePaneCount = $beforeUninstall.paneCount
        recoveryPreferencesPresent = $true
    }
    $result.after = [ordered]@{
        processId = $afterStart.processId
        tabCount = $afterReinstall.tabCount
        activePaneCount = $afterReinstall.paneCount
        generationReset = $true
        unexpectedRecovery = $false
        recoveryPreferencesRecreated = $true
    }
    $result.contract = [ordered]@{
        uninstallKeptAppData = $false
        durableAssetStoreReadOrMutated = $false
        exactCandidateReinstalled = $true
    }
    $result.cleanup = [ordered]@{
        applicationInstalled = $true
        applicationVisibleWithDefaultWorkspace = $true
        deviceAwakeLeaseRestored = $false
    }
    $result.status = 'passed'
} catch {
    $result.status = 'failed'
    $result.failure = $_.Exception.Message
    throw
} finally {
    if (-not $finalInstalled) {
        try { Install-ExactCandidate; $finalInstalled = $true } catch {}
    }
    if ($awakeLease) {
        try {
            Stop-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $Target
            if ($result.Contains('cleanup')) {
                $result.cleanup.deviceAwakeLeaseRestored = $true
            }
        } catch {
            if ($result.status -eq 'passed') {
                $result.status = 'failed'
                $result.failure = 'HarmonyOS screen-timeout override was not restored'
            }
        }
    }
    $result.completedAt = [DateTimeOffset]::Now.ToString('o')
    [IO.File]::WriteAllText(
        (Join-Path $EvidenceDirectory 'result.json'),
        ($result | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false)
    )
}

if ($result.status -ne 'passed') {
    throw "Unexpected recovery uninstall scenario ended as $($result.status)"
}
Write-Host "UNEXPECTED RECOVERY UNINSTALL SUCCESS: $EvidenceDirectory" -ForegroundColor Green
