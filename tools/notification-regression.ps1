# Notification-only helpers shared by publication and permission scenarios.
# Callers own verdicts and provide hdc, Target, processId, EvidenceDirectory
# and notificationState. No product state or permission policy is replaced.

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


function Get-RawAppLogs {
    return Invoke-HdcChecked -Hdc $hdc -Target $Target -Arguments @(
        'shell', "hilog -z 1200 -t app -P $processId"
    ) -Operation 'Read notification app logs'
}

function Wait-RawAppLog {
    param([Parameter(Mandatory = $true)][string]$Pattern,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 12)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $logs = Get-RawAppLogs
        if ($logs -match $Pattern) { return $logs }
        Start-Sleep -Milliseconds 500
    }
    throw "[product] Timed out waiting for app log: $Pattern"
}

function Ensure-LeanTTYVisible {
    param([Parameter(Mandatory = $true)][string]$Stage, [switch]$DismissPermissionPrompt)
    $activated = $false
    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        $layout = Get-FullLayout -Name "$Stage-visible"
        $nodes = @(Get-LeanTTYLayoutNodes -Node $layout)
        $prompt = @($nodes | Where-Object {
            [string]$_.attributes.text -match '允许.*LeanTTY.*发送通知|Allow.*LeanTTY.*notifications'
        })
        if ($prompt.Count -gt 0) {
            if (-not $DismissPermissionPrompt) {
                throw '[environment] Notification permission prompt obstructs the fixture'
            }
            $reject = Find-OneNode -Layout $layout -Description 'notification permission rejection' -Predicate {
                [string]$_.attributes.clickable -eq 'true' -and
                [string]$_.attributes.text -in @('不允许', '拒绝', "Don't allow", 'Cancel')
            }
            Click-Node -Node $reject -Description 'Reject fixture notification permission prompt'
            $notificationState.promptRejected = $true
        } elseif (@(Get-LeanTTYTerminalInputNodes -Layout $layout).Count -gt 0) {
            return $layout
        } elseif (-not $activated) {
            Invoke-HdcChecked -Hdc $hdc -Target $Target -Arguments @(
                'shell', 'aa start -a EntryAbility -b com.leantty.app'
            ) -Operation 'Restore LeanTTY notification fixture' | Out-Null
            $activated = $true
        }
        Start-Sleep -Milliseconds 500
    }
    throw "[environment] LeanTTY did not become visible during $Stage"
}

function Open-NotificationSettings {
    param([Parameter(Mandatory = $true)][string]$Stage)
    Ensure-LeanTTYVisible -Stage "$Stage-app" | Out-Null
    $menu = Open-LeanTTYMenu
    $item = Find-OneNode -Layout $menu -Description 'notification settings acceptance item' -Predicate {
        [string]$_.attributes.text -eq 'Acceptance: Notification Settings'
    }
    # Set before sending: an uncertain click still requires a cleanup observation.
    $notificationState.settingsOpen = $true
    Click-Node -Node $item -Description 'Open LeanTTY notification settings'
    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        $layout = Get-FullLayout -Name "$Stage-settings"
        if (@(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
            [string]$_.attributes.id -eq 'NotificationMgmtHalfMode_View_Text_Confirm'
        }).Count -eq 1) { return $layout }
        Start-Sleep -Milliseconds 500
    }
    throw '[environment] Notification settings did not open'
}

function Get-NotificationToggle {
    param([Parameter(Mandatory = $true)]$Layout)
    $toggles = @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object {
        [string]$_.attributes.type -eq 'Toggle' -and [string]$_.attributes.checkable -eq 'true'
    })
    if ($toggles.Count -lt 1 -or [string]$toggles[0].attributes.checked -notin @('true', 'false')) {
        throw '[harness] Main notification toggle state is unavailable'
    }
    return $toggles[0]
}

function Close-NotificationSettings {
    param([Parameter(Mandatory = $true)]$Layout)
    $confirm = Find-OneNode -Layout $Layout -Description 'notification settings confirm button' -Predicate {
        [string]$_.attributes.id -eq 'NotificationMgmtHalfMode_View_Text_Confirm'
    }
    Click-Node -Node $confirm -Description 'Confirm LeanTTY notification setting'
    Ensure-LeanTTYVisible -Stage 'settings-confirmed' -DismissPermissionPrompt | Out-Null
    $notificationState.settingsOpen = $false
}

function Set-NotificationEnabled {
    param([Parameter(Mandatory = $true)][bool]$Enabled,
        [Parameter(Mandatory = $true)][string]$Stage)
    $settings = Open-NotificationSettings -Stage $Stage
    $toggle = Get-NotificationToggle -Layout $settings
    $wasEnabled = [string]$toggle.attributes.checked -eq 'true'
    # Capture before mutation, including failed click/confirm/read-back paths.
    if ($null -eq $notificationState.originalEnabled) { $notificationState.originalEnabled = $wasEnabled }
    if ($wasEnabled -ne $Enabled) {
        Click-Node -Node $toggle -Description "Set LeanTTY notifications enabled=$Enabled"
    }
    $observed = $false
    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        $settings = Get-FullLayout -Name "$Stage-toggle-readback"
        $actual = [string](Get-NotificationToggle -Layout $settings).attributes.checked -eq 'true'
        if ($actual -eq $Enabled) { $observed = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $observed) { throw '[environment] Notification toggle did not reach the requested state' }
    Close-NotificationSettings -Layout $settings
    # Reopen after confirmation: the click is not proof of persisted system state.
    $verified = Open-NotificationSettings -Stage "$Stage-verify"
    $actual = [string](Get-NotificationToggle -Layout $verified).attributes.checked -eq 'true'
    Close-NotificationSettings -Layout $verified
    if ($actual -ne $Enabled) { throw '[environment] Notification setting did not persist' }
    return $wasEnabled
}

function Restore-NotificationPermission {
    if ($notificationState.settingsOpen) {
        $layout = Get-FullLayout -Name 'cleanup-pending-settings'
        $confirm = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
            [string]$_.attributes.id -eq 'NotificationMgmtHalfMode_View_Text_Confirm'
        })
        if ($confirm.Count -eq 1) { Close-NotificationSettings -Layout $layout }
        else { Ensure-LeanTTYVisible -Stage 'cleanup-settings-dismissed' -DismissPermissionPrompt | Out-Null }
        $notificationState.settingsOpen = $false
    }
    Ensure-LeanTTYVisible -Stage 'cleanup-permission' -DismissPermissionPrompt | Out-Null
    if ($null -ne $notificationState.originalEnabled) {
        [void](Set-NotificationEnabled -Enabled $notificationState.originalEnabled -Stage 'restore-original')
        $notificationState.restored = $true
    }
}

function Assert-NotificationCleanup {
    $layout = Ensure-LeanTTYVisible -Stage 'cleanup-attention' -DismissPermissionPrompt
    $inputs = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
    foreach ($inputNode in $inputs) { Click-Node -Node $inputNode -Description 'Clear fixture Pane attention' }
    $panel = Open-NotificationPanel -Stage 'cleanup-audit'
    try {
        $cards = @(Get-LeanTTYNotificationCards -Layout $panel)
        if ($cards.Count -ne 0) { throw '[cleanup] LeanTTY notification remains after visible recovery' }
    } finally {
        Invoke-LeanTTYSerializedUiTest -Hdc $hdc -Target $Target -Arguments @('uiInput', 'keyEvent', 'Back') -Operation 'Close notification cleanup panel' | Out-Null
        $script:panelOpen = $false
    }
    return Ensure-LeanTTYVisible -Stage 'cleanup-final' -DismissPermissionPrompt
}
