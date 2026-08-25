<#
.SYNOPSIS
  Verify the diagnostic background-BEL notification chain on a physical HarmonyOS PC.
.DESCRIPTION
  Requires an installed and launched signed diagnostic HAP containing the acceptance
  menu. Drives only the acceptance BEL source; production notification policy,
  publishing, background-episode suppression, WantAgent return, and cleanup remain unchanged.
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [string]$EvidenceDirectory = '',
    [string]$HapPath = '',
    [switch]$Suppression,
    [switch]$ColdStale,
    [switch]$LateHandled,
    [switch]$LateDestroyed,
    [switch]$ManualDismiss
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')

$selectedModes = @($Suppression, $ColdStale, $LateHandled, $LateDestroyed, $ManualDismiss) |
    Where-Object { [bool]$_ }
if ($selectedModes.Count -gt 1) {
    throw 'Use only one of -Suppression, -ColdStale, -LateHandled, -LateDestroyed, or -ManualDismiss'
}
$needsSplit = [bool]($Suppression -or $LateDestroyed -or $ManualDismiss)

if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path ([IO.Path]::GetTempPath()) (
        'LeanTTY-background-bell-' + [Guid]::NewGuid().ToString('N')
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
& (Join-Path $PSScriptRoot 'dev-pc.ps1') `
    -Target $Target -HapPath $HapPath -SkipBuild
if ($LASTEXITCODE -ne 0) {
    throw '[infrastructure] Failed to install and launch the exact diagnostic HAP'
}
$processId = (@(& $hdc -t $Target shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
if ($processId -notmatch '^\d+$') {
    throw '[environment] LeanTTY must be installed and launched before this scenario'
}

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
    $layout = Get-FullLayout -Name 'app-before-menu'
    $appRoot = Find-OneNode -Layout $layout -Description 'LeanTTY root' -Predicate {
        [string]$_.attributes.bundleName -eq 'com.leantty.app' -and
        [string]$_.attributes.type -eq 'root'
    }
    $appWindowId = [string]$appRoot.attributes.hostWindowId
    $minimize = Find-OneNode -Layout $layout -Description 'LeanTTY minimize button' -Predicate {
        [string]$_.attributes.hostWindowId -eq $appWindowId -and
        [string]$_.attributes.id -eq 'EnhanceMinimizeBtn'
    }
    $minimizeBounds = [regex]::Match([string]$minimize.attributes.bounds,
        '^\[(?<x1>\d+),(?<y1>\d+)\]\[(?<x2>\d+),(?<y2>\d+)\]$')
    $buttonCandidates = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
        $bounds = [regex]::Match([string]$_.attributes.bounds,
            '^\[(?<x1>\d+),(?<y1>\d+)\]\[(?<x2>\d+),(?<y2>\d+)\]$')
        [string]$_.attributes.hostWindowId -eq $appWindowId -and
        [string]$_.attributes.clickable -eq 'true' -and $bounds.Success -and
        [string]$_.attributes.id -notmatch '^Enhance' -and
        [int]$bounds.Groups['y1'].Value -lt [int]$minimizeBounds.Groups['y2'].Value -and
        [int]$bounds.Groups['x2'].Value -le [int]$minimizeBounds.Groups['x1'].Value
    } | Sort-Object {
        [int]([regex]::Match([string]$_.attributes.bounds, '^\[(?<x1>\d+),').Groups['x1'].Value)
    } -Descending)
    if ($buttonCandidates.Count -eq 0) {
        throw '[harness] LeanTTY menu button was not found before the window controls'
    }
    $button = $buttonCandidates[0]
    Click-Node -Node $button -Description 'Open LeanTTY menu'
    Start-Sleep -Milliseconds 250
    return Get-FullLayout -Name 'app-menu'
}

function Get-RawAppLogs {
    return (@(& $hdc -t $Target shell "hilog -z 1200 -t app -P $processId" 2>&1) -join "`n")
}

function Wait-RawAppLog {
    param([Parameter(Mandatory = $true)][string]$Pattern)
    for ($attempt = 0; $attempt -lt 12; $attempt++) {
        $logs = Get-RawAppLogs
        if ($logs -match $Pattern) { return $logs }
        Start-Sleep -Milliseconds 500
    }
    throw "[product] Timed out waiting for app log: $Pattern"
}

$result = [ordered]@{
    target = $Target
    processId = $processId
    candidate = [ordered]@{
        hapPath = $HapPath
        sha256 = $candidateSha256
        role = 'test-signed-diagnostic-hap'
    }
    suppression = [bool]$Suppression
    coldStale = [bool]$ColdStale
    lateHandled = [bool]$LateHandled
    lateDestroyed = [bool]$LateDestroyed
    manualDismiss = [bool]$ManualDismiss
    notificationCardCount = 0
    firedPaneIds = @()
    publishedPaneId = ''
    suppressedPaneId = ''
    resetPublished = $false
    returnedPaneId = ''
    staleReturnIgnored = $false
    staleReturnReason = ''
    manualDismissed = $false
    noRetryAfterDismiss = $false
    genericPayload = $false
    status = 'failed'
}
$panelOpen = $false
$cleanupFailure = ''
try {
    $initial = Get-FullLayout -Name 'app-initial'
    $terminalInputs = @(Get-LeanTTYLayoutNodes -Node $initial | Where-Object {
        [string]$_.attributes.hint -eq 'Terminal input'
    })
    if ($terminalInputs.Count -eq 0) {
        throw '[harness] No terminal input node was found'
    }
    Click-Node -Node $terminalInputs[0] -Description 'Clear prior Pane attention'
    Start-Sleep -Milliseconds 200
    $menu = Open-LeanTTYMenu
    if ($needsSplit) {
        $split = Find-OneNode -Layout $menu -Description 'split menu item' -Predicate {
            [string]$_.attributes.text -in @('Split Pane', '新建分屏')
        }
        Click-Node -Node $split -Description 'Create suppression test Pane'
        Start-Sleep -Milliseconds 400
        $menu = Open-LeanTTYMenu
    }

    $bell = Find-OneNode -Layout $menu -Description 'acceptance background BEL menu item' -Predicate {
        [string]$_.attributes.text -eq 'Acceptance: Background BEL'
    }
    $layout = Get-FullLayout -Name 'app-before-schedule'
    $appRoot = Find-OneNode -Layout $layout -Description 'LeanTTY root' -Predicate {
        [string]$_.attributes.bundleName -eq 'com.leantty.app' -and
        [string]$_.attributes.type -eq 'root'
    }
    $appWindowId = [string]$appRoot.attributes.hostWindowId
    $minimize = Find-OneNode -Layout $layout -Description 'LeanTTY minimize button' -Predicate {
        [string]$_.attributes.hostWindowId -eq $appWindowId -and
        [string]$_.attributes.id -eq 'EnhanceMinimizeBtn'
    }
    Click-Node -Node $bell -Description 'Schedule acceptance background BEL'
    Start-Sleep -Milliseconds 250
    Click-Node -Node $minimize -Description 'Minimize LeanTTY'

    $publishPattern = if ($needsSplit) {
        'state=suppression-fired,paneId=pane-\d+'
    } else {
        'state=fired,paneId=pane-\d+'
    }
    $logs = Wait-RawAppLog -Pattern $publishPattern
    $firedMatches = @([regex]::Matches(
        $logs,
        'ACCEPTANCE_BACKGROUND_BELL state=(?:suppression-)?fired,paneId=(?<id>pane-\d+)'
    ))
    $requiredFireCount = if ($needsSplit) { 2 } else { 1 }
    if ($firedMatches.Count -lt $requiredFireCount) {
        throw "[harness] Expected $requiredFireCount acceptance BEL fire(s), found $($firedMatches.Count)"
    }
    $fired = @($firedMatches | Select-Object -Last $requiredFireCount |
        ForEach-Object { $_.Groups['id'].Value })
    if ($logs -notmatch "notification published: paneId=$($fired[0])") {
        throw "[product] Missing notification publication for $($fired[0])"
    }
    $result.firedPaneIds = $fired
    $result.publishedPaneId = $fired[0]
    if ($needsSplit) {
        if ($logs -notmatch "notification suppressed for current background episode: paneId=$($fired[1])") {
            throw "[product] Missing background-episode suppression for $($fired[1])"
        }
        if ($logs -match "notification published: paneId=$($fired[1])") {
            throw "[product] Suppressed Pane unexpectedly published a notification: $($fired[1])"
        }
        $result.suppressedPaneId = $fired[1]
    }
    if ($ColdStale) {
        & $hdc -t $Target shell 'aa force-stop com.leantty.app' | Out-Null
        Start-Sleep -Milliseconds 500
        $stoppedProcessId = (@(& $hdc -t $Target shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
        if (-not [string]::IsNullOrWhiteSpace($stoppedProcessId)) {
            throw '[product] LeanTTY process remained alive after cold-stale setup'
        }
    }
    Save-LeanTTYDeviceScreenshot `
        -Hdc $hdc -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory 'before-notification-panel.png')

    $desktop = Get-FullLayout -Name 'desktop-before-notification-panel'
    $panelButton = Find-OneNode -Layout $desktop -Description 'system notification panel button' -Predicate {
        [string]$_.attributes.id -eq 'PluginRootComponent_Stack_status_bar_notification_panel'
    }
    Click-Node -Node $panelButton -Description 'Open HarmonyOS notification panel'
    $panelOpen = $true
    Start-Sleep -Milliseconds 700

    $panel = Get-FullLayout -Name 'notification-panel'
    $cards = @(Get-LeanTTYLayoutNodes -Node $panel | Where-Object {
        [string]$_.attributes.text -match '^LeanTTY, .*(?:A terminal needs your attention\.|终端有新提示)$'
    })
    $result.notificationCardCount = $cards.Count
    if ($cards.Count -ne 1) {
        throw "[product] Expected one background-episode LeanTTY notification card, found $($cards.Count)"
    }
    $result.genericPayload = $cards[0].attributes.text -notmatch 'pane-|@|host|ssh|agent'
    if (-not $result.genericPayload) {
        throw '[privacy] Notification card exposed non-generic source information'
    }
    Save-LeanTTYDeviceScreenshot `
        -Hdc $hdc -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory 'notification-panel.png')

    $expectedReturn = $fired[0]
    if ($ManualDismiss) {
        $cardBounds = [regex]::Match([string]$cards[0].attributes.bounds,
            '^\[(?<x1>\d+),(?<y1>\d+)\]\[(?<x2>\d+),(?<y2>\d+)\]$')
        if (-not $cardBounds.Success) {
            throw '[harness] Notification card has invalid bounds for manual dismissal'
        }
        $swipeStartX = [int]$cardBounds.Groups['x2'].Value - 24
        $swipeEndX = [Math]::Max(24, [int]$cardBounds.Groups['x1'].Value - 260)
        $swipeY = [int](
            ([int]$cardBounds.Groups['y1'].Value + [int]$cardBounds.Groups['y2'].Value) / 2
        )
        & $hdc -t $Target shell (
            "uitest uiInput swipe $swipeStartX $swipeY $swipeEndX $swipeY 400"
        ) 2>$null | Out-Null
        Start-Sleep -Milliseconds 900
        $dismissedPanel = Get-FullLayout -Name 'notification-panel-after-manual-dismiss'
        $dismissedCards = @(Get-LeanTTYLayoutNodes -Node $dismissedPanel | Where-Object {
            [string]$_.attributes.text -match '^LeanTTY, .*(?:A terminal needs your attention\.|终端有新提示)$'
        })
        if ($dismissedCards.Count -ne 0) {
            throw '[product] LeanTTY notification remained after manual dismissal'
        }
        $result.manualDismissed = $true
        Start-Sleep -Seconds 2
        $settledPanel = Get-FullLayout -Name 'notification-panel-after-dismiss-settle'
        $settledCards = @(Get-LeanTTYLayoutNodes -Node $settledPanel | Where-Object {
            [string]$_.attributes.text -match '^LeanTTY, .*(?:A terminal needs your attention\.|终端有新提示)$'
        })
        if ($settledCards.Count -ne 0) {
            throw '[product] LeanTTY notification was retried after manual dismissal'
        }
        $result.noRetryAfterDismiss = $true
        & $hdc -t $Target shell 'uitest uiInput keyEvent Back' 2>$null | Out-Null
        $panelOpen = $false
    } elseif ($LateHandled -or $LateDestroyed) {
        & $hdc -t $Target shell 'uitest uiInput keyEvent Back' 2>$null | Out-Null
        $panelOpen = $false
        & $hdc -t $Target shell 'aa start -a EntryAbility -b com.leantty.app' 2>$null | Out-Null
        Start-Sleep -Milliseconds 600
        $visibleLayout = Get-FullLayout -Name 'app-before-late-return-setup'
        $visibleInputs = @(Get-LeanTTYLayoutNodes -Node $visibleLayout | Where-Object {
            [string]$_.attributes.hint -eq 'Terminal input'
        } | Sort-Object {
            [int]([regex]::Match(
                [string]$_.attributes.bounds, '^\[(?<x1>\d+),'
            ).Groups['x1'].Value)
        })
        $expectedPaneCount = if ($LateDestroyed) { 2 } else { 1 }
        if ($visibleInputs.Count -ne $expectedPaneCount) {
            throw "[harness] Expected $expectedPaneCount Pane(s) before stale-return setup, found $($visibleInputs.Count)"
        }
        Click-Node -Node $visibleInputs[0] -Description 'Handle the notification source before its late return'
        Start-Sleep -Milliseconds 350
        if ($LateDestroyed) {
            $closeMenu = Open-LeanTTYMenu
            $closePane = Find-OneNode -Layout $closeMenu -Description 'close stale source split item' -Predicate {
                [string]$_.attributes.text -in @('Close Pane', '关闭分屏')
            }
            Click-Node -Node $closePane -Description 'Destroy the notification source Pane'
            Start-Sleep -Milliseconds 500
        }
        & $hdc -t $Target shell (
            'aa start -a EntryAbility -b com.leantty.app ' +
            '--ps leanttyBackgroundBellSource background-bell-v1 ' +
            "--ps leanttyBackgroundBellPaneId $expectedReturn"
        ) 2>$null | Out-Null
        Wait-RawAppLog -Pattern 'Background BEL return ignored because the source is no longer pending' |
            Out-Null
        $processIdAfterLateReturn = (@(& $hdc -t $Target shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
        if ($processIdAfterLateReturn -ne $processId) {
            throw '[product] Stale-return probe did not remain in the hot LeanTTY process'
        }
        $afterLateReturn = Get-FullLayout -Name 'app-after-late-return'
        $afterLateInputs = @(Get-LeanTTYLayoutNodes -Node $afterLateReturn | Where-Object {
            [string]$_.attributes.hint -eq 'Terminal input'
        })
        if ($afterLateInputs.Count -ne 1) {
            throw "[product] Stale return changed the workspace to $($afterLateInputs.Count) Panes"
        }
        $result.staleReturnIgnored = $true
        $result.staleReturnReason = if ($LateDestroyed) { 'source-pane-destroyed' } else { 'source-handled-first' }
    } else {
        Click-Node -Node $cards[0] -Description 'Activate LeanTTY background BEL notification'
        $panelOpen = $false
    }
    if ($ColdStale) {
        $newProcessObserved = $false
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            $newProcessId = (@(& $hdc -t $Target shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
            if ($newProcessId -match '^\d+$' -and $newProcessId -ne $processId) {
                $processId = $newProcessId
                $newProcessObserved = $true
                break
            }
            Start-Sleep -Milliseconds 250
        }
        if (-not $newProcessObserved) {
            throw '[product] Notification click did not cold-start LeanTTY'
        }
        Wait-RawAppLog -Pattern 'Background BEL return ignored because the source is no longer pending' |
            Out-Null
        $result.processIdAfterClick = $processId
        $result.staleReturnIgnored = $true
    } elseif (-not ($LateHandled -or $LateDestroyed -or $ManualDismiss)) {
        Wait-RawAppLog -Pattern "Background BEL return applied: paneId=$expectedReturn" | Out-Null
        $result.returnedPaneId = $expectedReturn
    }
    if ($Suppression) {
        $resetMenu = Open-LeanTTYMenu
        $resetBell = Find-OneNode -Layout $resetMenu -Description 'reset background BEL menu item' -Predicate {
            [string]$_.attributes.text -eq 'Acceptance: Background BEL'
        }
        $resetLayout = Get-FullLayout -Name 'app-before-reset-schedule'
        $resetRoot = Find-OneNode -Layout $resetLayout -Description 'LeanTTY reset root' -Predicate {
            [string]$_.attributes.bundleName -eq 'com.leantty.app' -and
            [string]$_.attributes.type -eq 'root'
        }
        $resetWindowId = [string]$resetRoot.attributes.hostWindowId
        $resetMinimize = Find-OneNode -Layout $resetLayout -Description 'LeanTTY reset minimize button' -Predicate {
            [string]$_.attributes.hostWindowId -eq $resetWindowId -and
            [string]$_.attributes.id -eq 'EnhanceMinimizeBtn'
        }
        Click-Node -Node $resetBell -Description 'Schedule reset background BEL'
        Start-Sleep -Milliseconds 250
        Click-Node -Node $resetMinimize -Description 'Minimize LeanTTY after visible reset'
        $resetPattern = "state=reset-fired,paneId=$expectedReturn[\s\S]*" +
            "notification published: paneId=$expectedReturn"
        Wait-RawAppLog -Pattern $resetPattern | Out-Null

        $resetDesktop = Get-FullLayout -Name 'desktop-before-reset-notification-panel'
        $resetPanelButton = Find-OneNode -Layout $resetDesktop `
            -Description 'reset system notification panel button' -Predicate {
                [string]$_.attributes.id -eq 'PluginRootComponent_Stack_status_bar_notification_panel'
            }
        Click-Node -Node $resetPanelButton -Description 'Open reset notification panel'
        $panelOpen = $true
        Start-Sleep -Milliseconds 700
        $resetPanel = Get-FullLayout -Name 'reset-notification-panel'
        $resetCards = @(Get-LeanTTYLayoutNodes -Node $resetPanel | Where-Object {
            [string]$_.attributes.text -match '^LeanTTY, .*(?:A terminal needs your attention\.|终端有新提示)$'
        })
        if ($resetCards.Count -ne 1) {
            throw "[product] Expected one notification after visible reset, found $($resetCards.Count)"
        }
        Click-Node -Node $resetCards[0] -Description 'Activate reset background BEL notification'
        $panelOpen = $false
        $resetReturnPattern = "state=reset-fired,paneId=$expectedReturn[\s\S]*" +
            "Background BEL return applied: paneId=$expectedReturn"
        Wait-RawAppLog -Pattern $resetReturnPattern | Out-Null
        $result.resetPublished = $true
    }
    $result.status = 'passed'
} finally {
    try {
        if ($panelOpen) {
            & $hdc -t $Target shell 'uitest uiInput keyEvent Back' 2>$null | Out-Null
        }
        & $hdc -t $Target shell 'aa start -a EntryAbility -b com.leantty.app' 2>$null | Out-Null
        Start-Sleep -Milliseconds 500
        $cleanupLayout = Get-FullLayout -Name 'cleanup-visible'
        $cleanupInputs = @(Get-LeanTTYLayoutNodes -Node $cleanupLayout | Where-Object {
            [string]$_.attributes.hint -eq 'Terminal input'
        })
        if ($cleanupInputs.Count -gt 1) {
            $cleanupMenu = Open-LeanTTYMenu
            $closePane = Find-OneNode -Layout $cleanupMenu -Description 'close split cleanup item' -Predicate {
                [string]$_.attributes.text -in @('Close Pane', '关闭分屏')
            }
            Click-Node -Node $closePane -Description 'Remove suppression test Pane'
            Start-Sleep -Milliseconds 400
            $cleanupLayout = Get-FullLayout -Name 'cleanup-after-pane-removal'
            $cleanupInputs = @(Get-LeanTTYLayoutNodes -Node $cleanupLayout | Where-Object {
                [string]$_.attributes.hint -eq 'Terminal input'
            })
        }
        if ($cleanupInputs.Count -ne 1) {
            throw "Expected one Pane after cleanup, found $($cleanupInputs.Count)"
        }
        $result.cleanup = 'app-restored; notification-cancel-requested-by-visible-lifecycle; single-pane-confirmed'
    } catch {
        $cleanupFailure = $_.Exception.Message
        $result.cleanup = 'failed: ' + $cleanupFailure
    }
    $result.completedAt = [DateTimeOffset]::UtcNow.ToString('o')
    $result | ConvertTo-Json -Depth 8 | Set-Content `
        -LiteralPath (Join-Path $EvidenceDirectory 'result.json') -Encoding utf8
}

if (-not [string]::IsNullOrWhiteSpace($cleanupFailure)) {
    throw "[cleanup] $cleanupFailure"
}
Write-Host "BACKGROUND BEL NOTIFICATION SUCCESS: $EvidenceDirectory"
