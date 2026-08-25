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
$settingsOpen = $false
$originalEnabled = $null
$currentEnabled = $null
$cleanupFailure = ''

function Get-FullLayout {
    param([Parameter(Mandatory = $true)][string]$Name)
    return Get-LeanTTYDeviceLayout `
        -Hdc $hdc -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory "$Name.json") `
        -BundleName ''
}

function Find-OneNode {
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)][scriptblock]$Predicate,
        [Parameter(Mandatory = $true)][string]$Description
    )
    $matches = @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object $Predicate)
    if ($matches.Count -ne 1) {
        throw "[harness] Expected one $Description node, found $($matches.Count)"
    }
    return $matches[0]
}

function Click-Node {
    param(
        [Parameter(Mandatory = $true)]$Node,
        [Parameter(Mandatory = $true)][string]$Description
    )
    $center = Get-LeanTTYBoundsCenter -Bounds ([string]$Node.attributes.bounds)
    Invoke-LeanTTYDeviceClick `
        -Hdc $hdc -Target $Target -X $center.x -Y $center.y -Operation $Description
}

function Get-RawAppLogs {
    return (@(& $hdc -t $Target shell "hilog -z 1200 -t app -P $processId" 2>&1) -join "`n")
}

function Wait-RawAppLog {
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 12
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $logs = Get-RawAppLogs
        if ($logs -match $Pattern) { return $logs }
        Start-Sleep -Milliseconds 500
    }
    throw "[product] Timed out waiting for app log: $Pattern"
}

function Open-LeanTTYMenu {
    $layout = Get-FullLayout -Name ('app-before-menu-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
    $root = Find-OneNode -Layout $layout -Description 'LeanTTY root' -Predicate {
        [string]$_.attributes.bundleName -eq 'com.leantty.app' -and
        [string]$_.attributes.type -eq 'root'
    }
    $windowId = [string]$root.attributes.hostWindowId
    $minimize = Find-OneNode -Layout $layout -Description 'LeanTTY minimize button' -Predicate {
        [string]$_.attributes.hostWindowId -eq $windowId -and
        [string]$_.attributes.id -eq 'EnhanceMinimizeBtn'
    }
    $minimizeBounds = [regex]::Match([string]$minimize.attributes.bounds,
        '^\[(?<x1>\d+),(?<y1>\d+)\]\[(?<x2>\d+),(?<y2>\d+)\]$')
    $buttons = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
        $bounds = [regex]::Match([string]$_.attributes.bounds,
            '^\[(?<x1>\d+),(?<y1>\d+)\]\[(?<x2>\d+),(?<y2>\d+)\]$')
        [string]$_.attributes.hostWindowId -eq $windowId -and
        [string]$_.attributes.clickable -eq 'true' -and
        [string]$_.attributes.id -notmatch '^Enhance' -and $bounds.Success -and
        [int]$bounds.Groups['y1'].Value -lt [int]$minimizeBounds.Groups['y2'].Value -and
        [int]$bounds.Groups['x2'].Value -le [int]$minimizeBounds.Groups['x1'].Value
    } | Sort-Object {
        [int]([regex]::Match([string]$_.attributes.bounds, '^\[(?<x1>\d+),').Groups['x1'].Value)
    } -Descending)
    if ($buttons.Count -eq 0) { throw '[harness] LeanTTY menu button was not found' }
    Click-Node -Node $buttons[0] -Description 'Open LeanTTY menu'
    Start-Sleep -Milliseconds 250
    return Get-FullLayout -Name ('app-menu-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
}

function Ensure-LeanTTYVisible {
    param([Parameter(Mandatory = $true)][string]$Stage)
    $layout = Get-FullLayout -Name "$Stage-before-activation"
    $inputs = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
    if ($inputs.Count -eq 1) { return $layout }
    & $hdc -t $Target shell 'aa start -a EntryAbility -b com.leantty.app' 2>$null | Out-Null
    Start-Sleep -Milliseconds 650
    $layout = Get-FullLayout -Name "$Stage-visible"
    $inputs = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
    if ($inputs.Count -ne 1) {
        throw "[environment] LeanTTY did not restore to one visible Pane during $Stage"
    }
    return $layout
}

function Open-NotificationSettings {
    param([Parameter(Mandatory = $true)][string]$Stage)
    Ensure-LeanTTYVisible -Stage "$Stage-app" | Out-Null
    $menu = Open-LeanTTYMenu
    $item = Find-OneNode -Layout $menu -Description 'notification settings acceptance item' -Predicate {
        [string]$_.attributes.text -eq 'Acceptance: Notification Settings'
    }
    Click-Node -Node $item -Description 'Open LeanTTY notification settings'
    $script:settingsOpen = $true
    Start-Sleep -Milliseconds 800
    return Get-FullLayout -Name "$Stage-settings"
}

function Set-NotificationEnabled {
    param(
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [Parameter(Mandatory = $true)][string]$Stage
    )
    $settings = Open-NotificationSettings -Stage $Stage
    $toggles = @(Get-LeanTTYLayoutNodes -Node $settings | Where-Object {
        [string]$_.attributes.type -eq 'Toggle' -and
        [string]$_.attributes.checkable -eq 'true'
    })
    if ($toggles.Count -lt 1) { throw '[harness] Main notification toggle was not found' }
    $wasEnabled = [string]$toggles[0].attributes.checked -eq 'true'
    if ($wasEnabled -ne $Enabled) {
        Click-Node -Node $toggles[0] -Description "Set LeanTTY notifications enabled=$Enabled"
        Start-Sleep -Milliseconds 350
    }
    $confirmLayout = Get-FullLayout -Name "$Stage-settings-before-confirm"
    $confirm = Find-OneNode -Layout $confirmLayout -Description 'notification settings confirm button' -Predicate {
        [string]$_.attributes.id -eq 'NotificationMgmtHalfMode_View_Text_Confirm' -or
        [string]$_.attributes.text -in @('确定', 'Confirm')
    }
    Click-Node -Node $confirm -Description 'Confirm LeanTTY notification setting'
    $script:settingsOpen = $false
    Start-Sleep -Milliseconds 500
    $script:currentEnabled = $Enabled
    return $wasEnabled
}

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
    Wait-RawAppLog -Pattern 'ACCEPTANCE_BACKGROUND_BELL state=fired,paneId=pane-\d+' |
        Out-Null
}

function Open-NotificationPanel {
    param([Parameter(Mandatory = $true)][string]$Stage)
    $desktop = Get-FullLayout -Name "$Stage-desktop"
    $button = Find-OneNode -Layout $desktop -Description 'system notification panel button' -Predicate {
        [string]$_.attributes.id -eq 'PluginRootComponent_Stack_status_bar_notification_panel'
    }
    Click-Node -Node $button -Description 'Open HarmonyOS notification panel'
    $script:panelOpen = $true
    Start-Sleep -Milliseconds 700
    return Get-FullLayout -Name "$Stage-notification-panel"
}

function Get-LeanTTYNotificationCards {
    param([Parameter(Mandatory = $true)]$Layout)
    return @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object {
        [string]$_.attributes.text -match '^LeanTTY, .*(?:A terminal needs your attention\.|终端有新提示)$'
    })
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
    $initialLayout = Ensure-LeanTTYVisible -Stage 'initial'
    $initialInputs = @(Get-LeanTTYTerminalInputNodes -Layout $initialLayout)
    Click-Node -Node $initialInputs[0] -Description 'Clear prior Pane attention'
    $originalEnabled = Set-NotificationEnabled -Enabled $false -Stage 'disable'
    $currentEnabled = $false
    $result.originalEnabled = $originalEnabled

    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Schedule-BackgroundBellAndMinimize -Stage 'disabled'
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
    & $hdc -t $Target shell 'uitest uiInput keyEvent Back' 2>$null | Out-Null
    $panelOpen = $false
    Ensure-LeanTTYVisible -Stage 'disabled-return' | Out-Null
    Start-Sleep -Milliseconds 700
    $permissionLayout = Get-FullLayout -Name 'permission-request-observation'
    $rejectButtons = @(Get-LeanTTYLayoutNodes -Node $permissionLayout | Where-Object {
        [string]$_.attributes.clickable -eq 'true' -and
        [string]$_.attributes.text -in @('不允许', '拒绝', "Don't allow", 'Cancel')
    })
    if ($rejectButtons.Count -gt 0) {
        Click-Node -Node $rejectButtons[0] -Description 'Reject first notification permission request'
        $result.permissionPromptObserved = $true
        Start-Sleep -Milliseconds 500
    }

    $handledLayout = Ensure-LeanTTYVisible -Stage 'disabled-attention-handle'
    $handledInputs = @(Get-LeanTTYTerminalInputNodes -Layout $handledLayout)
    if ($handledInputs.Count -ne 1) {
        throw '[harness] Disabled attention source was not available for user handling'
    }
    Click-Node -Node $handledInputs[0] -Description 'Handle disabled background BEL attention'
    Wait-RawAppLog -Pattern 'Pane attention cleared: pane-\d+' | Out-Null

    [void](Set-NotificationEnabled -Enabled $true -Stage 'enable')
    $currentEnabled = $true
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Schedule-BackgroundBellAndMinimize -Stage 'enabled'
    Wait-RawAppLog -Pattern 'Background BEL notification published: paneId=pane-\d+' |
        Out-Null
    $result.enabledPublished = $true
    $enabledPanel = Open-NotificationPanel -Stage 'enabled'
    $enabledCards = Get-LeanTTYNotificationCards -Layout $enabledPanel
    if ($enabledCards.Count -ne 1) {
        throw "[product] Enabled permission expected one LeanTTY notification, found $($enabledCards.Count)"
    }
    Click-Node -Node $enabledCards[0] -Description 'Activate enabled background BEL notification'
    $panelOpen = $false
    Wait-RawAppLog -Pattern 'Background BEL return applied: paneId=pane-\d+' | Out-Null
    $result.enabledReturned = $true
    $result.status = 'passed'
} finally {
    try {
        if ($panelOpen) {
            & $hdc -t $Target shell 'uitest uiInput keyEvent Back' 2>$null | Out-Null
            $panelOpen = $false
        }
        if ($settingsOpen) {
            & $hdc -t $Target shell 'uitest uiInput keyEvent Back' 2>$null | Out-Null
            $settingsOpen = $false
        }
        Ensure-LeanTTYVisible -Stage 'cleanup' | Out-Null
        if ($null -ne $originalEnabled -and $currentEnabled -ne $originalEnabled) {
            [void](Set-NotificationEnabled -Enabled ([bool]$originalEnabled) -Stage 'restore-original')
            $currentEnabled = [bool]$originalEnabled
        }
        $cleanupLayout = Ensure-LeanTTYVisible -Stage 'cleanup-final'
        $cleanupInputs = @(Get-LeanTTYTerminalInputNodes -Layout $cleanupLayout)
        if ($cleanupInputs.Count -ne 1) { throw "Expected one Pane, found $($cleanupInputs.Count)" }
        $result.restoredOriginalSetting = $currentEnabled -eq $originalEnabled
        $result.cleanup = 'original-notification-setting-restored; app-visible; notification-cancel-requested; single-pane-confirmed'
    } catch {
        $cleanupFailure = $_.Exception.Message
        $result.cleanup = 'failed: ' + $cleanupFailure
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
