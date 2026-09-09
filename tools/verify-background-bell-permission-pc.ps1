<#
.SYNOPSIS
  Verify disabled and enabled background-BEL notification permission behavior.
.DESCRIPTION
  Uses LeanTTY's acceptance-only notification-settings entry on a physical HarmonyOS PC.
  Preserves the original system notification toggle and never clears app data or Preferences.
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [string]$EvidenceDirectory = '',
    [string]$HapPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')
. (Join-Path $PSScriptRoot 'notification-regression.ps1')

if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path ([IO.Path]::GetTempPath()) (
        'LeanTTY-background-bell-permission-' + [Guid]::NewGuid().ToString('N')
    )
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$hdc = Resolve-Hdc
$Target = Resolve-LeanTTYRegressionTarget -Hdc $hdc -Target $Target
if ([string]::IsNullOrWhiteSpace($HapPath)) {
    throw '-HapPath is required and must identify one exact signed diagnostic HAP'
}
$HapPath = [IO.Path]::GetFullPath($HapPath)
if (-not (Test-Path -LiteralPath $HapPath -PathType Leaf) -or
    (Split-Path $HapPath -Leaf) -match 'unsigned') {
    throw "Signed diagnostic HAP not found: $HapPath"
}
$candidateSha256 = (Get-FileHash -LiteralPath $HapPath -Algorithm SHA256).Hash
& (Join-Path $PSScriptRoot 'dev-pc.ps1') -Target $Target -HapPath $HapPath -SkipBuild
if ($LASTEXITCODE -ne 0) { throw '[infrastructure] Exact diagnostic HAP deployment failed' }
$processId = (@(& $hdc -t $Target shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
if ($processId -notmatch '^\d+$') { throw '[environment] LeanTTY process is not running' }

$panelOpen = $false
$notificationState = @{originalEnabled=$null; settingsOpen=$false; promptRejected=$false; restored=$false}
$awakeLease = $false
$cleanupFailure = ''

function Schedule-BackgroundBellAndMinimize {
    param([Parameter(Mandatory = $true)][string]$Stage)
    Ensure-LeanTTYVisible -Stage "$Stage-app" | Out-Null
    $menu = Open-LeanTTYMenu
    $bell = Find-OneNode -Layout $menu -Description 'background BEL acceptance item' -Predicate {
        [string]$_.attributes.text -eq 'Acceptance: Background BEL'
    }
    $layout = Get-FullLayout -Name "$Stage-before-schedule"
    $root = Find-OneNode -Layout $layout -Description 'LeanTTY schedule root' -Predicate {
        [string]$_.attributes.bundleName -eq 'com.leantty.app' -and
        [string]$_.attributes.type -eq 'root'
    }
    $windowId = [string]$root.attributes.hostWindowId
    $minimize = Find-OneNode -Layout $layout -Description 'LeanTTY schedule minimize button' -Predicate {
        [string]$_.attributes.hostWindowId -eq $windowId -and
        [string]$_.attributes.id -eq 'EnhanceMinimizeBtn'
    }
    Click-Node -Node $bell -Description 'Schedule background BEL permission probe'
    Start-Sleep -Milliseconds 250
    Click-Node -Node $minimize -Description 'Minimize LeanTTY for permission probe'
    $firedLogs = Wait-RawAppLog -Pattern 'ACCEPTANCE_BACKGROUND_BELL state=fired,paneId=pane-\d+(?:-\d+)?(?=[\s,]|$)'
    return [regex]::Match($firedLogs, 'state=fired,paneId=(pane-\d+(?:-\d+)?)(?=[\s,]|$)').Groups[1].Value
}

$result = [ordered]@{
    target = $Target
    candidate = [ordered]@{
        hapPath = $HapPath
        sha256 = $candidateSha256
        role = 'test-signed-diagnostic-hap'
    }
    originalEnabled = $null
    disabledDeferred = $false
    disabledNotificationCardCount = $null
    permissionPromptObserved = $false
    enabledPublished = $false
    enabledReturned = $false
    restoredOriginalSetting = $false
    cleanup = 'pending'
    status = 'failed'
}

try {
    Start-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $Target -TimeoutMilliseconds 600000
    $awakeLease = $true
    $initialLayout = Ensure-LeanTTYVisible -Stage 'initial'
    $initialInputs = @(Get-LeanTTYTerminalInputNodes -Layout $initialLayout)
    if ($initialInputs.Count -ne 1) { throw '[environment] Permission fixture requires one visible test Pane' }
    Click-Node -Node $initialInputs[0] -Description 'Clear prior Pane attention'
    [void](Set-NotificationEnabled -Enabled $false -Stage 'disable')
    $result.originalEnabled = $notificationState.originalEnabled

    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    $disabledPaneId = Schedule-BackgroundBellAndMinimize -Stage 'disabled'
    $disabledLogs = Wait-RawAppLog `
        -Pattern 'Background BEL notification deferred because notifications are disabled'
    if ($disabledLogs -match 'Background BEL notification published:') {
        throw '[product] Disabled permission unexpectedly published a notification'
    }
    $result.disabledDeferred = $true
    $disabledPanel = Open-NotificationPanel -Stage 'disabled'
    $disabledCards = Get-LeanTTYNotificationCards -Layout $disabledPanel
    $result.disabledNotificationCardCount = $disabledCards.Count
    if ($disabledCards.Count -ne 0) {
        throw "[product] Disabled permission left $($disabledCards.Count) LeanTTY notification card(s)"
    }
    Invoke-LeanTTYSerializedUiTest -Hdc $hdc -Target $Target -Arguments @('uiInput', 'keyEvent', 'Back') -Operation 'Close permission notification panel' | Out-Null
    $panelOpen = $false
    Ensure-LeanTTYVisible -Stage 'disabled-return' -DismissPermissionPrompt | Out-Null
    $result.permissionPromptObserved = $notificationState.promptRejected

    $handledLayout = Ensure-LeanTTYVisible -Stage 'disabled-attention-handle'
    $handledInputs = @(Get-LeanTTYTerminalInputNodes -Layout $handledLayout)
    if ($handledInputs.Count -ne 1) {
        throw '[harness] Disabled attention source was not available for user handling'
    }
    Click-Node -Node $handledInputs[0] -Description 'Handle disabled background BEL attention'
    Wait-RawAppLog -Pattern ('Pane attention cleared: ' + [regex]::Escape($disabledPaneId) + '(?=[\s,]|$)') | Out-Null

    [void](Set-NotificationEnabled -Enabled $true -Stage 'enable')
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    $enabledPaneId = Schedule-BackgroundBellAndMinimize -Stage 'enabled'
    Wait-RawAppLog -Pattern ('Background BEL notification published: paneId=' + [regex]::Escape($enabledPaneId) + '(?=[\s,]|$)') |
        Out-Null
    $result.enabledPublished = $true
    $enabledPanel = Open-NotificationPanel -Stage 'enabled'
    $enabledCards = Get-LeanTTYNotificationCards -Layout $enabledPanel
    if ($enabledCards.Count -ne 1) {
        throw "[product] Enabled permission expected one LeanTTY notification, found $($enabledCards.Count)"
    }
    Click-Node -Node $enabledCards[0] -Description 'Activate enabled background BEL notification'
    $panelOpen = $false
    Wait-RawAppLog -Pattern ('Background BEL return applied: paneId=' + [regex]::Escape($enabledPaneId) + '(?=[\s,]|$)') | Out-Null
    $result.enabledReturned = $true
    $result.status = 'passed'
} catch {
    $result.failure = $_.Exception.Message
    throw
} finally {
    try {
        if ($panelOpen) {
            Invoke-LeanTTYSerializedUiTest -Hdc $hdc -Target $Target -Arguments @('uiInput', 'keyEvent', 'Back') -Operation 'Close permission probe panel' | Out-Null
            $panelOpen = $false
        }
        Restore-NotificationPermission
        $result.originalEnabled = $notificationState.originalEnabled
        $result.restoredOriginalSetting = $notificationState.restored
        $cleanupLayout = Assert-NotificationCleanup
        $cleanupInputs = @(Get-LeanTTYTerminalInputNodes -Layout $cleanupLayout)
        if ($cleanupInputs.Count -ne 1) { throw '[cleanup] Permission fixture did not restore one visible Pane' }
    } catch {
        $cleanupFailure = $_.Exception.Message
    }
    try {
        if ($awakeLease) { Stop-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $Target }
    } catch {
        $cleanupFailure = $_.Exception.Message
    }
    if ([string]::IsNullOrWhiteSpace($cleanupFailure)) {
        $result.cleanup = [ordered]@{
            result = 'passed'
            detail = 'original-notification-setting-verified; app-visible; notification-absence-audited; screen-timeout-restored'
        }
    } else {
        $result.cleanup = [ordered]@{ result = 'failed'; detail = $cleanupFailure }
    }
    $result.completedAt = [DateTimeOffset]::UtcNow.ToString('o')
    [IO.File]::WriteAllText(
        (Join-Path $EvidenceDirectory 'result.json'),
        ($result | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )
}

if (-not [string]::IsNullOrWhiteSpace($cleanupFailure)) { throw '[cleanup] ' + $cleanupFailure }
Write-Host "BACKGROUND BEL PERMISSION SUCCESS: $EvidenceDirectory"
