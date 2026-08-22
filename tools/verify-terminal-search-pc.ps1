<#
.SYNOPSIS
  Verify named terminal-search behavior on a physical HarmonyOS PC.
.DESCRIPTION
  Installs one retained verified candidate (or an explicitly requested
  diagnostic HAP), drives the production
  Ctrl+Alt+F search route, and records candidate, harness, device, layout,
  screenshot, timing, failure-domain, and cleanup evidence.
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [string]$HapPath = '',
    [switch]$DiagnosticHap,
    [string]$CandidateBasePath = '',
    [string]$EvidenceDirectory = '',
    [string]$UnlockPasswordPath = '',
    [ValidateSet(
        'open-close-focus',
        'ascii-query-navigation',
        'pane-tab-ownership',
        'warm-tab-eviction',
        'window-renderer-lifecycle'
    )]
    [string[]]$Only = @('open-close-focus')
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')
. (Join-Path $PSScriptRoot 'candidate-store.ps1')

$harnessStatus = @(git -C $repoRoot status --porcelain --untracked-files=all 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect terminal-search harness source state' }
$harnessDirty = $harnessStatus.Count -gt 0
if ($harnessDirty -and -not $DiagnosticHap) {
    throw 'Terminal-search device harness requires a clean committed tree'
}
$harnessCommit = (& git -C $repoRoot rev-parse HEAD 2>&1).Trim()
$harnessTree = (& git -C $repoRoot rev-parse 'HEAD^{tree}' 2>&1).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve terminal-search harness identity' }

$harnessDifferencePaths = @()
if ($DiagnosticHap) {
    if ([string]::IsNullOrWhiteSpace($HapPath)) {
        throw '-DiagnosticHap requires an explicit -HapPath'
    }
    $resolvedHap = [IO.Path]::GetFullPath($HapPath)
    if (-not (Test-Path -LiteralPath $resolvedHap -PathType Leaf)) {
        throw "Diagnostic HAP is missing: $resolvedHap"
    }
    $candidate = [pscustomobject][ordered]@{
        sha256 = (Get-FileHash -LiteralPath $resolvedHap -Algorithm SHA256).Hash.ToLowerInvariant()
        hapPath = $resolvedHap
        gitCommit = $null
        gitTree = $null
        gitDirty = $null
    }
} else {
    $candidate = Resolve-LeanTTYRetainedCandidate `
        -RepoRoot $repoRoot `
        -HapPath $HapPath `
        -CandidateBasePath $CandidateBasePath
}
if (-not $DiagnosticHap) {
    if ($candidate.gitDirty) { throw 'Terminal-search evidence requires a clean committed candidate' }
    $harnessDifferencePaths = @(Assert-LeanTTYCandidateHarnessCompatibility `
        -RepoRoot $repoRoot `
        -Candidate $candidate `
        -AllowedHarnessPaths @(
            'tools/verify-ssh-auth-pc.ps1',
            'tools/verify-terminal-search-pc.ps1',
            'tools/verify-file-transfer-pc.ps1',
            'tools/verify-put-get-pc.ps1',
            'tools/verify-proxy-jump-pc.ps1',
            'tools/device-regression.ps1',
            'tools/hdc-common.ps1',
            'tools/start-ssh-auth-fixture.ps1',
            'tools/test-device-regression.ps1',
            'leantty_ssh/ssh-auth-fixture/src/main.rs',
            'docs/quality-strategy.md',
            'docs/design/terminal-search.md',
            'docs/design/ui-interaction-polish.md',
            'docs/next-work.md'
        ))
}
$HapPath = [string]$candidate.hapPath
if ((Split-Path $HapPath -Leaf) -match 'unsigned') {
    throw 'Terminal-search device verification requires a signed HAP'
}
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path ([IO.Path]::GetTempPath()) (
        'LeanTTY-terminal-search-' + [Guid]::NewGuid().ToString('N')
    )
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null

$hdc = Resolve-Hdc
$Target = Resolve-LeanTTYRegressionTarget -Hdc $hdc -Target $Target
if ([string]::IsNullOrWhiteSpace($UnlockPasswordPath)) {
    $UnlockPasswordPath = Get-LeanTTYDeviceUnlockPasswordPath
}
Assert-LeanTTYCredentialPathOutsideRepository `
    -CredentialPath $UnlockPasswordPath `
    -RepositoryRoot $repoRoot

$startedAt = [DateTimeOffset]::UtcNow
$attemptId = [Guid]::NewGuid().ToString('N')
$checks = [Collections.Generic.List[object]]::new()
$commandObservations = [Collections.Generic.List[object]]::new()
$failure = ''
$failureDomain = 'none'
$cleanupFailure = ''
$awakeLeaseAcquired = $false
$searchClosed = $false
$workspaceRestored = $false
$appPid = ''
$deviceUnlockResult = ''
$deviceModel = ''
$deviceAbi = ''
$deviceTransport = ''
$hapHash = [string]$candidate.sha256
$hapLength = (Get-Item -LiteralPath $HapPath).Length

function Get-TerminalSearchInputNodes {
    param([Parameter(Mandatory = $true)]$Layout)
    return @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object {
        [string]$_.attributes.type -eq 'textField' -and
        [string]$_.attributes.hint -match '^Search text' -and
        [string]$_.attributes.visible -eq 'true'
    })
}

function Get-TerminalSearchContainerNodes {
    param([Parameter(Mandatory = $true)]$Layout)
    return @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object {
        [string]$_.attributes.type -eq 'search' -and
        [string]$_.attributes.text -eq 'Find in terminal' -and
        [string]$_.attributes.visible -eq 'true'
    })
}

function Get-LeanTTYTerminalContentTop {
    param([Parameter(Mandatory = $true)]$Layout)

    $contentTops = @(Get-LeanTTYLayoutNodes -Node $Layout | ForEach-Object {
        if ([string]$_.attributes.type -ne 'Web' -or
            [string]$_.attributes.visible -ne 'true' -or
            [string]$_.attributes.originalText -notmatch 'terminal\.html$') {
            return
        }
        $bounds = [string]$_.attributes.bounds
        if ($bounds -match '^\[\d+,(?<top>\d+)\]\[\d+,\d+\]$') {
            return [int]$Matches.top
        }
    })
    if ($contentTops.Count -eq 0) {
        throw '[harness] LeanTTY terminal content boundary was unavailable'
    }
    return [int](($contentTops | Measure-Object -Minimum).Minimum)
}

function Get-LeanTTYTabNodes {
    param([Parameter(Mandatory = $true)]$Layout)
    $contentTop = Get-LeanTTYTerminalContentTop -Layout $Layout
    return @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object {
        if ([string]$_.attributes.type -ne 'Stack' -or
            [string]$_.attributes.clickable -ne 'true' -or
            [string]::IsNullOrWhiteSpace([string]$_.attributes.description)) {
            return $false
        }
        $bounds = [string]$_.attributes.bounds
        if ($bounds -notmatch '^\[\d+,(?<top>\d+)\]\[\d+,(?<bottom>\d+)\]$') { return $false }
        return [int]$Matches.top -lt $contentTop -and [int]$Matches.bottom -le $contentTop
    })
}

function Get-LeanTTYActiveTerminalInputNodes {
    param([Parameter(Mandatory = $true)]$Layout)
    $result = [Collections.Generic.List[object]]::new()
    $visit = {
        param($Node, [bool]$InsideActiveSurface)
        if ($null -eq $Node) { return }
        $inside = $InsideActiveSurface
        if ([string]$Node.attributes.type -eq '__Common__') {
            $bounds = [string]$Node.attributes.bounds
            if ($bounds -match '^\[\d+,(?<top>\d+)\]\[\d+,(?<bottom>\d+)\]$' -and
                [int]$Matches.top -ge 100 -and [int]$Matches.bottom -gt 120) {
                $inside = [string]$Node.attributes.opacity -eq '1.000000' -and
                    [string]$Node.attributes.zIndex -eq '1'
            }
        }
        if ($inside -and
            [string]$Node.attributes.type -eq 'textField' -and
            [string]$Node.attributes.hint -eq 'Terminal input' -and
            [string]$Node.attributes.visible -eq 'true') {
            $result.Add($Node)
        }
        foreach ($child in @($Node.children)) {
            & $visit $child $inside
        }
    }
    & $visit $Layout $false
    return @($result)
}

function Get-LeanTTYActiveTerminalSurfaceNodes {
    param([Parameter(Mandatory = $true)]$Layout)

    return @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object {
        if ([string]$_.attributes.type -ne '__Common__' -or
            [string]$_.attributes.opacity -ne '1.000000' -or
            [string]$_.attributes.zIndex -ne '1') {
            return $false
        }
        $bounds = [string]$_.attributes.bounds
        if ($bounds -notmatch '^\[\d+,(?<top>\d+)\]\[\d+,(?<bottom>\d+)\]$' -or
            [int]$Matches.top -lt 100 -or [int]$Matches.bottom -le 120) {
            return $false
        }
        return @(Get-LeanTTYLayoutNodes -Node $_ | Where-Object {
            [string]$_.attributes.type -eq 'Web' -and
            [string]$_.attributes.visible -eq 'true' -and
            [string]$_.attributes.originalText -match 'terminal\.html$'
        }).Count -eq 1
    })
}

function Wait-TerminalWorkspaceState {
    param(
        [Parameter(Mandatory = $true)][int]$PaneCount,
        [Parameter(Mandatory = $true)][int]$TabCount,
        [Parameter(Mandatory = $true)][int]$SearchCount,
        [Parameter(Mandatory = $true)][string]$LayoutName,
        [ValidateSet('any', 'left', 'right')][string]$FocusedPane = 'any',
        [bool]$RequireTerminalFocus = $true,
        [ValidateRange(1, 40)][int]$TimeoutSeconds = 20
    )
    $path = Join-Path $EvidenceDirectory $LayoutName
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $path
        $terminalInputs = @(Get-LeanTTYActiveTerminalInputNodes -Layout $layout)
        $activePaneBounds = [Collections.Generic.List[string]]::new()
        foreach ($terminalInput in $terminalInputs) {
            $bounds = [string]$terminalInput.attributes.bounds
            if (-not $activePaneBounds.Contains($bounds)) { $activePaneBounds.Add($bounds) }
        }
        $activeSurfaces = @(Get-LeanTTYActiveTerminalSurfaceNodes -Layout $layout)
        $activePaneCount = if ($terminalInputs.Count -gt 0) {
            $activePaneBounds.Count
        } else {
            $activeSurfaces.Count
        }
        $focusedTerminalInputs = @($terminalInputs | Where-Object {
            [string]$_.attributes.focused -eq 'true'
        })
        $searchContainers = @(Get-TerminalSearchContainerNodes -Layout $layout)
        $searchInputs = @(Get-TerminalSearchInputNodes -Layout $layout)
        $tabs = @(Get-LeanTTYTabNodes -Layout $layout)
        $focusedIndex = if ($focusedTerminalInputs.Count -eq 1) {
            [Array]::IndexOf(
                $activePaneBounds,
                [string]$focusedTerminalInputs[0].attributes.bounds
            )
        } else {
            -1
        }
        $focusMatches = if (-not $RequireTerminalFocus -and $SearchCount -eq 0) {
            $true
        } elseif ($SearchCount -eq 1) {
            $searchInputs.Count -eq 1 -and
                [string]$searchInputs[0].attributes.focused -eq 'true' -and
                $focusedTerminalInputs.Count -eq 0
        } else {
            $focusedTerminalInputs.Count -eq 1 -and
                ($FocusedPane -eq 'any' -or
                    ($FocusedPane -eq 'left' -and $focusedIndex -eq 0) -or
                    ($FocusedPane -eq 'right' -and $focusedIndex -eq 1))
        }
        if ($activePaneCount -eq $PaneCount -and
            $tabs.Count -eq $TabCount -and
            $searchContainers.Count -eq $SearchCount -and
            $searchInputs.Count -eq $SearchCount -and
            $focusMatches) {
            return [pscustomobject]@{
                layout = $layout
                paneCount = $activePaneCount
                tabCount = $tabs.Count
                searchCount = $searchInputs.Count
                focusedPaneIndex = $focusedIndex
            }
        }
        Start-Sleep -Milliseconds 200
    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw (
        '[product] Timed out waiting for terminal workspace state: ' +
        "panes=$PaneCount,tabs=$TabCount,search=$SearchCount,focus=$FocusedPane," +
        "requireTerminalFocus=$RequireTerminalFocus"
    )
}

function Get-TerminalSearchResultNodes {
    param([Parameter(Mandatory = $true)]$Layout)
    return @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object {
        [string]$_.attributes.visible -eq 'true' -and
        ([string]$_.attributes.text -match '^(?:No results|[1-9][0-9]*/[1-9][0-9]*)$' -or
            [string]$_.attributes.originalText -match '^(?:No results|[1-9][0-9]*/[1-9][0-9]*)$')
    })
}

function Get-TerminalSearchResultLabel {
    param([Parameter(Mandatory = $true)]$Layout)
    $nodes = @(Get-TerminalSearchResultNodes -Layout $Layout)
    if ($nodes.Count -ne 1) { return '' }
    $text = [string]$nodes[0].attributes.text
    if (-not [string]::IsNullOrWhiteSpace($text)) { return $text }
    return [string]$nodes[0].attributes.originalText
}

function Wait-TerminalSearchQueryState {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExpectedQuery,
        [Parameter(Mandatory = $true)][string]$LayoutName,
        [string]$ExpectedResultPattern = '',
        [bool]$RequireSearchInputFocus = $true,
        [ValidateRange(1, 30)][int]$TimeoutSeconds = 15
    )
    $path = Join-Path $EvidenceDirectory $LayoutName
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $path
        $searchInputs = @(Get-TerminalSearchInputNodes -Layout $layout)
        if ($searchInputs.Count -eq 1 -and
            (-not $RequireSearchInputFocus -or
                [string]$searchInputs[0].attributes.focused -eq 'true')) {
            $query = [string]$searchInputs[0].attributes.text
            if ([string]::IsNullOrEmpty($query)) {
                $query = [string]$searchInputs[0].attributes.originalText
            }
            $label = Get-TerminalSearchResultLabel -Layout $layout
            if ($query -ceq $ExpectedQuery -and
                ([string]::IsNullOrEmpty($ExpectedResultPattern) -or
                    $label -match $ExpectedResultPattern)) {
                return [pscustomobject]@{
                    layout = $layout
                    query = $query
                    resultLabel = $label
                }
            }
        }
        Start-Sleep -Milliseconds 200
    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw (
        "Timed out waiting for terminal search query '$ExpectedQuery'" +
        $(if ($ExpectedResultPattern) { " and result '$ExpectedResultPattern'" } else { '' })
    )
}

function ConvertFrom-TerminalSearchResultLabel {
    param([Parameter(Mandatory = $true)][string]$Label)
    if ($Label -notmatch '^(?<index>[1-9][0-9]*)/(?<count>[1-9][0-9]*)$') {
        throw "Terminal search result label is not a selected match: $Label"
    }
    $index = [int]$Matches.index
    $count = [int]$Matches.count
    if ($index -gt $count) { throw "Terminal search result index exceeds its count: $Label" }
    return [pscustomobject]@{ index = $index; count = $count }
}

function Wait-TerminalSearchState {
    param(
        [Parameter(Mandatory = $true)][bool]$Open,
        [Parameter(Mandatory = $true)][string]$LayoutName,
        [ValidateRange(1, 30)][int]$TimeoutSeconds = 15
    )
    $path = Join-Path $EvidenceDirectory $LayoutName
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $path
        $searchInputs = @(Get-TerminalSearchInputNodes -Layout $layout)
        if ($Open -and $searchInputs.Count -eq 1 -and
            [string]$searchInputs[0].attributes.focused -eq 'true') {
            return $layout
        }
        if (-not $Open -and $searchInputs.Count -eq 0) {
            $terminalInputs = @(Get-LeanTTYTerminalInputNodes -Layout $layout | Where-Object {
                [string]$_.attributes.focused -eq 'true'
            })
            if ($terminalInputs.Count -eq 1) { return $layout }
        }
        Start-Sleep -Milliseconds 200
    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    $state = if ($Open) { 'open and focused' } else { 'closed with terminal focus restored' }
    throw "Timed out waiting for terminal search to be $state"
}

function Invoke-TerminalSearchShortcut {
    & $hdc -t $Target shell 'uitest uiInput keyEvent 2072 2045 2022' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to invoke product Ctrl+Alt+F search shortcut' }
}

function Clear-TerminalSearchQuery {
    param([Parameter(Mandatory = $true)][ValidateRange(1, 4096)][int]$CharacterCount)

    # ArkWeb on this physical PC does not receive an injected Ctrl+A chord in
    # its focused HTML input. Delete the known bounded test query one character
    # at a time so this gate measures search behavior rather than that injector
    # limitation.
    for ($index = 0; $index -lt $CharacterCount; $index++) {
        Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2055
    }
}

function Invoke-TerminalSearchPrevious {
    $layout = Get-LeanTTYDeviceLayout `
        -Hdc $hdc `
        -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory 'layout-search-previous-control.json')
    $previous = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
        [string]$_.attributes.type -eq 'button' -and
        [string]$_.attributes.originalText -eq 'Previous match, Shift+Enter' -and
        [string]$_.attributes.visible -eq 'true'
    })
    if ($previous.Count -ne 1) {
        throw '[harness] Previous terminal search control was not uniquely available'
    }
    Invoke-LeanTTYLayoutNodeClick -Node $previous[0]
}

function Invoke-TerminalWorkspaceChord {
    param([Parameter(Mandatory = $true)][ValidateSet(
        'split', 'new-tab', 'close-active', 'next-tab', 'focus-left', 'focus-right'
    )][string]$Action)
    $command = switch ($Action) {
        'split' { 'uinput -K -d 2072 -d 2047 -d 2020 -u 2020 -u 2047 -u 2072' }
        'new-tab' { 'uinput -K -d 2072 -d 2047 -d 2036 -u 2036 -u 2047 -u 2072' }
        'close-active' { 'uinput -K -d 2072 -d 2047 -d 2039 -u 2039 -u 2047 -u 2072' }
        'next-tab' { 'uinput -K -d 2072 -d 2049 -u 2049 -u 2072' }
        'focus-left' { 'uinput -K -d 2072 -d 2045 -d 2014 -u 2014 -u 2045 -u 2072' }
        'focus-right' { 'uinput -K -d 2072 -d 2045 -d 2015 -u 2015 -u 2045 -u 2072' }
    }
    & $hdc -t $Target shell $command | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to invoke LeanTTY workspace action: $Action" }
}

function Invoke-LocalTerminalCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [ValidateNotNullOrEmpty()][string]$Stage = 'terminal-search-local-command'
    )

    Submit-LeanTTYDeviceCommand `
        -Hdc $hdc `
        -Target $Target `
        -ProcessId $appPid `
        -Command $Command `
        -Stage $Stage `
        -ObservationSink $commandObservations `
        -InputNodeProvider {
            param($inputAttempt)
            $layoutPath = Join-Path $EvidenceDirectory (
                "layout-local-command-$inputAttempt-" +
                [Guid]::NewGuid().ToString('N') + '.json'
            )
            $layout = Get-LeanTTYDeviceLayout `
                -Hdc $hdc -Target $Target -LocalPath $layoutPath
            $terminalInputs = @(Get-LeanTTYActiveTerminalInputNodes -Layout $layout)
            $focusedInputs = @($terminalInputs | Where-Object {
                    [string]$_.attributes.focused -eq 'true'
                })
            $inputNode = if ($focusedInputs.Count -eq 1) {
                $focusedInputs[0]
            } elseif ($terminalInputs.Count -eq 1) {
                $terminalInputs[0]
            } else {
                $null
            }
            if ($null -eq $inputNode) {
                throw '[environment] Unable to identify the active terminal input before local command submission'
            }
            if ([string]$inputNode.attributes.focused -eq 'true') { return $inputNode }
            $focusedLayout = Set-LeanTTYTerminalInputFocus `
                -Hdc $hdc -Target $Target -InputNode $inputNode `
                -LocalPath $layoutPath -TimeoutSeconds 10
            $focusedInputs = @(Get-LeanTTYActiveTerminalInputNodes -Layout $focusedLayout | Where-Object {
                    [string]$_.attributes.focused -eq 'true'
                })
            if ($focusedInputs.Count -ne 1) {
                throw '[environment] Local command input focus was not unique'
            }
            return $focusedInputs[0]
        } | Out-Null
    Start-Sleep -Milliseconds 500
}

function Invoke-LeanTTYLayoutNodeClick {
    param([Parameter(Mandatory = $true)]$Node)
    $center = Get-LeanTTYBoundsCenter -Bounds ([string]$Node.attributes.bounds)
    Invoke-LeanTTYDeviceClick `
        -Hdc $hdc -Target $Target -X $center.x -Y $center.y `
        -Operation 'LeanTTY layout node click'
}

function Invoke-TerminalMenuAction {
    param(
        [Parameter(Mandatory = $true)][string]$ActionText,
        [Parameter(Mandatory = $true)][string]$LayoutPrefix
    )
    $layout = Get-LeanTTYDeviceLayout `
        -Hdc $hdc `
        -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory "$LayoutPrefix-before-menu.json")
    $contentTop = Get-LeanTTYTerminalContentTop -Layout $layout
    $candidates = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
        if ([string]$_.attributes.type -ne 'Stack' -or
            [string]$_.attributes.clickable -ne 'true' -or
            -not [string]::IsNullOrWhiteSpace([string]$_.attributes.text) -or
            -not [string]::IsNullOrWhiteSpace([string]$_.attributes.description) -or
            -not [string]::IsNullOrWhiteSpace([string]$_.attributes.id)) {
            return $false
        }
        $bounds = [string]$_.attributes.bounds
        if ($bounds -notmatch '^\[(?<left>\d+),(?<top>\d+)\]\[(?<right>\d+),(?<bottom>\d+)\]$') {
            return $false
        }
        $width = [int]$Matches.right - [int]$Matches.left
        $height = [int]$Matches.bottom - [int]$Matches.top
        return [int]$Matches.left -gt 1000 -and [int]$Matches.bottom -le $contentTop -and
            $width -ge 40 -and $width -le 90 -and $height -ge 40 -and $height -le 90
    })
    if ($candidates.Count -ne 1) {
        throw '[harness] LeanTTY terminal menu button was not uniquely identified'
    }
    Invoke-LeanTTYLayoutNodeClick -Node $candidates[0]

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            Invoke-LeanTTYDialogButton `
                -Hdc $hdc `
                -Target $Target `
                -ButtonText $ActionText `
                -LayoutPath (Join-Path $EvidenceDirectory "$LayoutPrefix-menu.json")
            return
        } catch {
            Start-Sleep -Milliseconds 200
        }
    } while ($stopwatch.Elapsed.TotalSeconds -lt 10)
    throw "[environment] Diagnostic HAP menu action was unavailable: $ActionText"
}

function Wait-SearchAppLog {
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [ValidateRange(1, 40)][int]$TimeoutSeconds = 20
    )
    return Wait-LeanTTYAppLog `
        -Hdc $hdc `
        -Target $Target `
        -ProcessId $appPid `
        -Pattern $Pattern `
        -TimeoutSeconds $TimeoutSeconds
}

function Invoke-RegressionWindowMinimize {
    $layout = Get-LeanTTYDeviceLayout `
        -Hdc $hdc `
        -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory 'layout-before-search-minimize.json')
    $buttons = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
        [string]$_.attributes.id -eq 'EnhanceMinimizeBtn' -and
        [string]$_.attributes.clickable -eq 'true'
    })
    if ($buttons.Count -ne 1) { throw '[environment] HarmonyOS minimize button was not found' }
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Invoke-LeanTTYLayoutNodeClick -Node $buttons[0]
    Wait-SearchAppLog -Pattern 'Window visibility changed: visible=false' | Out-Null
}

function Restore-RegressionWindow {
    & $hdc -t $Target shell 'aa start -a EntryAbility -b com.leantty.app' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '[environment] Unable to restore minimized LeanTTY window' }
    Wait-SearchAppLog -Pattern 'Window visibility changed: visible=true' | Out-Null
    $restoredPid = (@(& $hdc -t $Target shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
    if ($restoredPid -ne $appPid) { throw '[product] LeanTTY process changed during minimize/restore' }
}

function Restore-TerminalWorkspace {
    if ($appPid -notmatch '^\d+$') { return }
    & $hdc -t $Target shell 'aa start -a EntryAbility -b com.leantty.app' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to reactivate LeanTTY during cleanup' }
    for ($step = 0; $step -lt 8; $step++) {
        $layout = Get-LeanTTYDeviceLayout `
            -Hdc $hdc `
            -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory "layout-cleanup-workspace-$step.json")
        $searchInputs = @(Get-TerminalSearchInputNodes -Layout $layout)
        if ($searchInputs.Count -gt 0) {
            Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2070
            Start-Sleep -Milliseconds 300
            continue
        }
        $terminalInputs = @(Get-LeanTTYActiveTerminalInputNodes -Layout $layout)
        $activeSurfaces = @(Get-LeanTTYActiveTerminalSurfaceNodes -Layout $layout)
        $activePaneBounds = [Collections.Generic.List[string]]::new()
        foreach ($terminalInput in $terminalInputs) {
            $bounds = [string]$terminalInput.attributes.bounds
            if (-not $activePaneBounds.Contains($bounds)) { $activePaneBounds.Add($bounds) }
        }
        $tabs = @(Get-LeanTTYTabNodes -Layout $layout)
        $activePaneCount = if ($terminalInputs.Count -gt 0) {
            $activePaneBounds.Count
        } else {
            $activeSurfaces.Count
        }
        if ($activePaneCount -gt 1) {
            Invoke-TerminalWorkspaceChord -Action 'focus-right'
            Invoke-TerminalWorkspaceChord -Action 'close-active'
            Start-Sleep -Milliseconds 500
            continue
        }
        if ($tabs.Count -gt 1) {
            Invoke-TerminalWorkspaceChord -Action 'close-active'
            Start-Sleep -Milliseconds 500
            continue
        }
        Wait-TerminalWorkspaceState `
            -PaneCount 1 `
            -TabCount 1 `
            -SearchCount 0 `
            -LayoutName 'layout-cleanup-workspace-final.json' `
            -RequireTerminalFocus ($terminalInputs.Count -gt 0) `
            -TimeoutSeconds 10 | Out-Null
        return
    }
    throw 'Unable to restore one-tab, one-pane LeanTTY workspace during cleanup'
}

function Save-SearchAppLogs {
    param([Parameter(Mandatory = $true)][string]$FileName)
    if ($appPid -notmatch '^\d+$') { return }
    $logs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appPid
    [IO.File]::WriteAllText(
        (Join-Path $EvidenceDirectory $FileName),
        $logs,
        [Text.UTF8Encoding]::new($false)
    )
}

try {
    $deviceModel = (Invoke-HdcShell $hdc $Target 'param get const.product.model').Trim()
    $deviceAbi = (Invoke-HdcShell $hdc $Target 'param get const.product.cpu.abilist').Trim()
    $deviceTransport = Get-HdcTargetTransport -Hdc $hdc -Target $Target
    if ($deviceTransport -ne 'usb') { throw '[environment] Terminal-search scenario requires USB' }
    if ($deviceAbi -notmatch 'arm64-v8a') {
        throw '[environment] Terminal-search scenario requires an ARM64 HarmonyOS PC'
    }

    Start-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $Target
    $awakeLeaseAcquired = $true
    $installOutput = @(& $hdc -t $Target install -r $HapPath 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $installOutput -match '(?i)\[Fail\]|error') {
        throw "[environment] Diagnostic HAP install failed: $installOutput"
    }
    $start = Start-LeanTTYRegressionApp `
        -Hdc $hdc `
        -Target $Target `
        -CredentialPath $UnlockPasswordPath `
        -RepositoryRoot $repoRoot
    $appPid = [string]$start.processId
    $deviceUnlockResult = [string]$start.unlock

    $layout = Wait-LeanTTYTerminalInputLayout `
        -Hdc $hdc `
        -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory 'layout-ready.json')
    $terminalInputs = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
    $focused = @($terminalInputs | Where-Object { [string]$_.attributes.focused -eq 'true' })
    $terminalInput = if ($focused.Count -eq 1) { $focused[0] } else { $terminalInputs[0] }
    Set-LeanTTYTerminalInputFocus `
        -Hdc $hdc `
        -Target $Target `
        -InputNode $terminalInput `
        -LocalPath (Join-Path $EvidenceDirectory 'layout-terminal-focused.json') | Out-Null

    if ($Only -contains 'open-close-focus') {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-TerminalSearchShortcut
        Wait-TerminalSearchState `
            -Open $true `
            -LayoutName 'layout-search-open.json' | Out-Null
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc `
            -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'search-open.png')
        Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2070
        Wait-TerminalSearchState `
            -Open $false `
            -LayoutName 'layout-search-closed.json' | Out-Null
        $searchClosed = $true
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc `
            -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'search-closed.png')
        Save-SearchAppLogs -FileName 'app-logs.txt'
        $checks.Add([pscustomobject]@{
            name = 'open-close-focus'
            result = 'passed'
            durationMs = $timer.ElapsedMilliseconds
        })
    }

    if ($Only -contains 'ascii-query-navigation') {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $typedQueries = [Collections.Generic.List[string]]::new()
        $forwardLabels = [Collections.Generic.List[string]]::new()
        $backwardLabels = [Collections.Generic.List[string]]::new()
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-TerminalSearchShortcut
        $searchClosed = $false
        Wait-TerminalSearchState `
            -Open $true `
            -LayoutName 'layout-ascii-search-open.json' | Out-Null

        $query = ''
        foreach ($character in 'ltty'.ToCharArray()) {
            Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text ([string]$character)
            $query += $character
            $typed = Wait-TerminalSearchQueryState `
                -ExpectedQuery $query `
                -LayoutName ("layout-ascii-query-$($query.Length).json")
            $typedQueries.Add($typed.query)
        }
        $matching = Wait-TerminalSearchQueryState `
            -ExpectedQuery 'ltty' `
            -ExpectedResultPattern '^[1-9][0-9]*/[1-9][0-9]*$' `
            -LayoutName 'layout-ascii-query-match.json'

        Clear-TerminalSearchQuery -CharacterCount $query.Length
        Wait-TerminalSearchQueryState `
            -ExpectedQuery '' `
            -LayoutName 'layout-ascii-query-cleared.json' | Out-Null
        $missingQuery = 'LEANTTY_NO_RESULT_ZXQVK'
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $missingQuery
        $missing = Wait-TerminalSearchQueryState `
            -ExpectedQuery $missingQuery `
            -ExpectedResultPattern '^No results$' `
            -LayoutName 'layout-ascii-query-no-results.json'

        Clear-TerminalSearchQuery -CharacterCount $missingQuery.Length
        Wait-TerminalSearchQueryState `
            -ExpectedQuery '' `
            -LayoutName 'layout-ascii-navigation-cleared.json' | Out-Null
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text 't'
        $initial = Wait-TerminalSearchQueryState `
            -ExpectedQuery 't' `
            -ExpectedResultPattern '^[1-9][0-9]*/[1-9][0-9]*$' `
            -LayoutName 'layout-ascii-navigation-initial.json'
        $position = ConvertFrom-TerminalSearchResultLabel -Label $initial.resultLabel
        if ($position.count -lt 2) {
            throw '[harness] The fresh terminal did not provide two ASCII navigation matches'
        }

        $expectedIndex = $position.index
        for ($step = 1; $step -le $position.count; $step++) {
            Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
            $expectedIndex = ($expectedIndex % $position.count) + 1
            $next = Wait-TerminalSearchQueryState `
                -ExpectedQuery 't' `
                -ExpectedResultPattern "^$expectedIndex/$($position.count)$" `
                -LayoutName ("layout-ascii-next-$step.json")
            $forwardLabels.Add($next.resultLabel)
        }
        if ($expectedIndex -ne $position.index) {
            throw '[harness] Forward terminal search did not wrap to its starting match'
        }

        for ($step = 1; $step -le $position.count; $step++) {
            Invoke-TerminalSearchPrevious
            $expectedIndex = (($expectedIndex - 2 + $position.count) % $position.count) + 1
            $previous = Wait-TerminalSearchQueryState `
                -ExpectedQuery 't' `
                -ExpectedResultPattern "^$expectedIndex/$($position.count)$" `
                -RequireSearchInputFocus $false `
                -LayoutName ("layout-ascii-previous-$step.json")
            $backwardLabels.Add($previous.resultLabel)
        }
        if ($expectedIndex -ne $position.index) {
            throw '[harness] Backward terminal search did not wrap to its starting match'
        }

        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc `
            -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'ascii-query-navigation.png')
        Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2070
        Wait-TerminalSearchState `
            -Open $false `
            -LayoutName 'layout-ascii-query-closed.json' | Out-Null
        $searchClosed = $true
        Save-SearchAppLogs -FileName 'ascii-query-navigation-app-logs.txt'
        $checks.Add([pscustomobject]@{
            name = 'ascii-query-navigation'
            result = 'passed'
            durationMs = $timer.ElapsedMilliseconds
            typedQueries = @($typedQueries)
            firstQueryResult = $matching.resultLabel
            noResultLabel = $missing.resultLabel
            navigationQuery = 't'
            navigationMatchCount = $position.count
            forwardLabels = @($forwardLabels)
            backwardLabels = @($backwardLabels)
            wrappedForward = $true
            wrappedBackward = $true
            terminalFocusRestored = $true
        })
    }

    if ($Only -contains 'pane-tab-ownership') {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        Wait-TerminalWorkspaceState `
            -PaneCount 1 -TabCount 1 -SearchCount 0 `
            -LayoutName 'layout-ownership-single-pane.json' | Out-Null

        Invoke-LocalTerminalCommand -Command 'help'
        Invoke-LocalTerminalCommand -Command 'help'

        Invoke-TerminalSearchShortcut
        $searchClosed = $false
        Wait-TerminalSearchState `
            -Open $true -LayoutName 'layout-ownership-single-search.json' | Out-Null
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text 'Syntax'
        Wait-TerminalSearchQueryState `
            -ExpectedQuery 'Syntax' `
            -ExpectedResultPattern '^[1-9][0-9]*/[1-9][0-9]*$' `
            -LayoutName 'layout-ownership-single-query.json' | Out-Null

        Invoke-TerminalWorkspaceChord -Action 'split'
        $split = Wait-TerminalWorkspaceState `
            -PaneCount 2 -TabCount 1 -SearchCount 0 `
            -LayoutName 'layout-ownership-split.json'
        $searchClosed = $true
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'pane-scroll-after-split.png')
        Invoke-TerminalSearchShortcut
        $searchClosed = $false
        Wait-TerminalWorkspaceState `
            -PaneCount 2 -TabCount 1 -SearchCount 1 `
            -LayoutName 'layout-ownership-active-pane-search.json' | Out-Null
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text 'Syntax'
        Wait-TerminalSearchQueryState `
            -ExpectedQuery 'Syntax' `
            -ExpectedResultPattern '^No results$' `
            -LayoutName 'layout-ownership-right-no-result.json' | Out-Null

        Invoke-TerminalWorkspaceChord -Action 'focus-left'
        $left = Wait-TerminalWorkspaceState `
            -PaneCount 2 -TabCount 1 -SearchCount 0 -FocusedPane 'left' `
            -LayoutName 'layout-ownership-focus-left.json'
        $searchClosed = $true
        Invoke-TerminalSearchShortcut
        $searchClosed = $false
        Wait-TerminalWorkspaceState `
            -PaneCount 2 -TabCount 1 -SearchCount 1 `
            -LayoutName 'layout-ownership-left-search.json' | Out-Null
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text 'Syntax'
        Wait-TerminalSearchQueryState `
            -ExpectedQuery 'Syntax' `
            -ExpectedResultPattern '^[1-9][0-9]*/[1-9][0-9]*$' `
            -LayoutName 'layout-ownership-left-match.json' | Out-Null
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'pane-scroll-left-match.png')

        Invoke-TerminalWorkspaceChord -Action 'focus-right'
        $right = Wait-TerminalWorkspaceState `
            -PaneCount 2 -TabCount 1 -SearchCount 0 -FocusedPane 'right' `
            -LayoutName 'layout-ownership-focus-right.json'
        $searchClosed = $true
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'pane-scroll-after-focus-switch.png')
        Invoke-TerminalWorkspaceChord -Action 'close-active'
        Wait-TerminalWorkspaceState `
            -PaneCount 1 -TabCount 1 -SearchCount 0 `
            -LayoutName 'layout-ownership-pane-closed.json' | Out-Null

        Invoke-TerminalSearchShortcut
        $searchClosed = $false
        Wait-TerminalWorkspaceState `
            -PaneCount 1 -TabCount 1 -SearchCount 1 `
            -LayoutName 'layout-ownership-before-new-tab.json' | Out-Null
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text 'Syntax'
        Wait-TerminalSearchQueryState `
            -ExpectedQuery 'Syntax' `
            -ExpectedResultPattern '^[1-9][0-9]*/[1-9][0-9]*$' `
            -LayoutName 'layout-ownership-first-tab-match.json' | Out-Null
        Invoke-TerminalWorkspaceChord -Action 'new-tab'
        Wait-TerminalWorkspaceState `
            -PaneCount 1 -TabCount 2 -SearchCount 0 `
            -LayoutName 'layout-ownership-new-tab.json' | Out-Null
        $searchClosed = $true

        Invoke-TerminalSearchShortcut
        $searchClosed = $false
        Wait-TerminalWorkspaceState `
            -PaneCount 1 -TabCount 2 -SearchCount 1 `
            -LayoutName 'layout-ownership-second-tab-search.json' | Out-Null
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text 'Syntax'
        Wait-TerminalSearchQueryState `
            -ExpectedQuery 'Syntax' `
            -ExpectedResultPattern '^No results$' `
            -LayoutName 'layout-ownership-second-tab-no-result.json' | Out-Null
        Invoke-TerminalWorkspaceChord -Action 'next-tab'
        Wait-TerminalWorkspaceState `
            -PaneCount 1 -TabCount 2 -SearchCount 0 `
            -LayoutName 'layout-ownership-first-tab-return.json' | Out-Null
        $searchClosed = $true
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'tab-scroll-first-return.png')
        Invoke-TerminalSearchShortcut
        $searchClosed = $false
        Wait-TerminalWorkspaceState `
            -PaneCount 1 -TabCount 2 -SearchCount 1 `
            -LayoutName 'layout-ownership-first-tab-reopened.json' | Out-Null
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text 'Syntax'
        Wait-TerminalSearchQueryState `
            -ExpectedQuery 'Syntax' `
            -ExpectedResultPattern '^[1-9][0-9]*/[1-9][0-9]*$' `
            -LayoutName 'layout-ownership-first-tab-rematch.json' | Out-Null
        Invoke-TerminalWorkspaceChord -Action 'next-tab'
        Wait-TerminalWorkspaceState `
            -PaneCount 1 -TabCount 2 -SearchCount 0 `
            -LayoutName 'layout-ownership-second-tab-return.json' | Out-Null
        Invoke-TerminalWorkspaceChord -Action 'close-active'
        Wait-TerminalWorkspaceState `
            -PaneCount 1 -TabCount 1 -SearchCount 0 `
            -LayoutName 'layout-ownership-tab-closed.json' | Out-Null

        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'pane-tab-ownership.png')
        $checks.Add([pscustomobject]@{
            name = 'pane-tab-ownership'
            result = 'passed'
            durationMs = $timer.ElapsedMilliseconds
            singlePaneQueryClearedOnSplit = $true
            splitPaneFocusedAfterCreation = $split.focusedPaneIndex
            leftPaneFocusIndex = $left.focusedPaneIndex
            rightPaneFocusIndex = $right.focusedPaneIndex
            activePaneQueryClearedOnSwitch = $true
            rightPaneRejectedLeftScrollbackQuery = $true
            queryClearedOnNewTab = $true
            secondTabRejectedFirstTabScrollbackQuery = $true
            queryAbsentAfterRoundTrip = $true
            scrollViewportScreenshots = @(
                'pane-scroll-after-split.png',
                'pane-scroll-left-match.png',
                'pane-scroll-after-focus-switch.png',
                'tab-scroll-first-return.png'
            )
            paneAndTabCloseRestoredSingleWorkspace = $true
        })
    }

    if ($Only -contains 'warm-tab-eviction') {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        Wait-TerminalWorkspaceState `
            -PaneCount 1 -TabCount 1 -SearchCount 0 `
            -LayoutName 'layout-warm-initial.json' | Out-Null
        Invoke-TerminalWorkspaceChord -Action 'new-tab'
        Wait-TerminalWorkspaceState `
            -PaneCount 1 -TabCount 2 -SearchCount 0 `
            -LayoutName 'layout-warm-second-tab.json' | Out-Null
        Invoke-TerminalSearchShortcut
        $searchClosed = $false
        Wait-TerminalWorkspaceState `
            -PaneCount 1 -TabCount 2 -SearchCount 1 `
            -LayoutName 'layout-warm-search-open.json' | Out-Null

        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-TerminalWorkspaceChord -Action 'next-tab'
        Wait-TerminalWorkspaceState `
            -PaneCount 1 -TabCount 2 -SearchCount 0 `
            -LayoutName 'layout-warm-tab-inactive.json' | Out-Null
        $searchClosed = $true
        $evictionLogs = Wait-SearchAppLog `
            -Pattern 'TerminalBridge: PERF bridge reason=destroy' `
            -TimeoutSeconds 40
        if ($evictionLogs -match 'ArkWeb renderer exited') {
            throw '[environment] Renderer exit invalidated the warm-tab eviction observation'
        }
        Invoke-TerminalWorkspaceChord -Action 'next-tab'
        Wait-TerminalWorkspaceState `
            -PaneCount 1 -TabCount 2 -SearchCount 0 `
            -LayoutName 'layout-warm-tab-remounted.json' `
            -TimeoutSeconds 30 | Out-Null
        Invoke-TerminalWorkspaceChord -Action 'close-active'
        Wait-TerminalWorkspaceState `
            -PaneCount 1 -TabCount 1 -SearchCount 0 `
            -LayoutName 'layout-warm-cleaned.json' | Out-Null
        Save-SearchAppLogs -FileName 'warm-tab-eviction-app-logs.txt'
        $checks.Add([pscustomobject]@{
            name = 'warm-tab-eviction'
            result = 'passed'
            durationMs = $timer.ElapsedMilliseconds
            retentionMilliseconds = 30000
            productionEvictionObserved = $evictionLogs -match 'TerminalBridge: PERF bridge reason=destroy'
            queryAbsentAfterRemount = $true
            terminalFocusRestored = $true
        })
    }

    if ($Only -contains 'window-renderer-lifecycle') {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        Wait-TerminalWorkspaceState `
            -PaneCount 1 -TabCount 1 -SearchCount 0 `
            -LayoutName 'layout-lifecycle-initial.json' | Out-Null

        Invoke-TerminalSearchShortcut
        $searchClosed = $false
        Wait-TerminalWorkspaceState `
            -PaneCount 1 -TabCount 1 -SearchCount 1 `
            -LayoutName 'layout-lifecycle-before-minimize.json' | Out-Null
        Invoke-RegressionWindowMinimize
        Restore-RegressionWindow
        Wait-TerminalWorkspaceState `
            -PaneCount 1 -TabCount 1 -SearchCount 0 `
            -LayoutName 'layout-lifecycle-after-restore.json' `
            -TimeoutSeconds 30 | Out-Null
        $searchClosed = $true

        Invoke-TerminalSearchShortcut
        $searchClosed = $false
        Wait-TerminalWorkspaceState `
            -PaneCount 1 -TabCount 1 -SearchCount 1 `
            -LayoutName 'layout-lifecycle-before-renderer.json' | Out-Null
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text 'ltty'
        Wait-TerminalSearchQueryState `
            -ExpectedQuery 'ltty' `
            -ExpectedResultPattern '^[1-9][0-9]*/[1-9][0-9]*$' `
            -LayoutName 'layout-lifecycle-renderer-query.json' | Out-Null
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-TerminalMenuAction `
            -ActionText 'Acceptance: Rebuild Renderer' `
            -LayoutPrefix 'layout-lifecycle-renderer'
        $rendererLogs = Wait-SearchAppLog `
            -Pattern 'TerminalBridge: PERF bridge reason=destroy' `
            -TimeoutSeconds 20
        $rendererLogs = Wait-SearchAppLog `
            -Pattern 'TerminalBridge: Bridge initialized' `
            -TimeoutSeconds 20
        Wait-TerminalWorkspaceState `
            -PaneCount 1 -TabCount 1 -SearchCount 0 `
            -LayoutName 'layout-lifecycle-renderer-rebuilt.json' `
            -RequireTerminalFocus $false `
            -TimeoutSeconds 30 | Out-Null
        $searchClosed = $true
        Invoke-LocalTerminalCommand -Command 'help'
        $focusLogs = Wait-SearchAppLog `
            -Pattern 'ACCEPTANCE_INPUT_SUBMIT sequence=\d+,kind=command' `
            -TimeoutSeconds 20
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'window-renderer-lifecycle.png')
        Save-SearchAppLogs -FileName 'window-renderer-lifecycle-app-logs.txt'
        $checks.Add([pscustomobject]@{
            name = 'window-renderer-lifecycle'
            result = 'passed'
            durationMs = $timer.ElapsedMilliseconds
            processPreservedAcrossMinimizeRestore = $true
            queryClearedOnMinimize = $true
            rendererBridgeDestroyed = $rendererLogs -match 'TerminalBridge: PERF bridge reason=destroy'
            rendererBridgeReinitialized = $rendererLogs -match 'TerminalBridge: Bridge initialized'
            queryAbsentAfterRendererRebuild = $true
            terminalFocusRestoredByCommandSubmit = $focusLogs -match
                'ACCEPTANCE_INPUT_SUBMIT sequence=\d+,kind=command'
        })
    }
} catch {
    $failure = $_.Exception.Message
    $failureDomain = if ($failure -match '^\[environment\]') {
        'environment'
    } elseif ($failure -match '^\[harness\]') {
        'harness'
    } elseif ($failure -match '^\[unknown\]') {
        'unknown'
    } else {
        'product'
    }
    try {
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc `
            -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'failure.png')
    } catch {}
    try { Save-SearchAppLogs -FileName 'failure-app-logs.txt' } catch {}
} finally {
    if ($appPid -match '^\d+$') {
        try {
            Restore-TerminalWorkspace
            $searchClosed = $true
            $workspaceRestored = $true
        } catch {
            $cleanupFailure = $_.Exception.Message
        }
    }
    if ($awakeLeaseAcquired) {
        try {
            Stop-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $Target
        } catch {
            if ([string]::IsNullOrWhiteSpace($cleanupFailure)) {
                $cleanupFailure = $_.Exception.Message
            }
        }
    }

    $scenarioResult = if (-not $failure -and -not $cleanupFailure) { 'passed' } else { 'failed' }
    $automationVerdict = if (@($commandObservations | Where-Object {
        $_.result -eq 'unknown'
    }).Count -gt 0) { 'unknown' } else { $scenarioResult }
    $evidence = [ordered]@{
        schemaVersion = 2
        gate = $(if ($DiagnosticHap) { 'diagnostic' } else { 'device-behavior' })
        scenario = 'terminal-search'
        runMode = $(if ($DiagnosticHap) { 'diagnostic' } else { 'acceptance' })
        attemptId = $attemptId
        result = $scenarioResult
        startedAt = $startedAt.ToString('o')
        completedAt = [DateTimeOffset]::UtcNow.ToString('o')
        durationMs = [int]([DateTimeOffset]::UtcNow - $startedAt).TotalMilliseconds
        candidate = [ordered]@{
            sha256 = $hapHash
            bytes = $hapLength
            gitCommit = $candidate.gitCommit
            gitTree = $candidate.gitTree
            gitDirty = $candidate.gitDirty
            retained = (-not $DiagnosticHap)
            provenance = $(if ($DiagnosticHap) {
                'explicit-unretained-diagnostic-hap'
            } else {
                'retained-verified-candidate'
            })
            reusedAcrossHarnessOnlyChanges = ($harnessDifferencePaths.Count -gt 0)
        }
        harness = [ordered]@{
            gitCommit = $harnessCommit
            gitTree = $harnessTree
            gitDirty = $harnessDirty
            differencePathsFromCandidate = @($harnessDifferencePaths)
        }
        device = [ordered]@{
            model = $deviceModel
            abi = $deviceAbi
            transport = $deviceTransport
            unlock = $deviceUnlockResult
        }
        trigger = 'HarmonyOS-uitest-Ctrl-Alt-F-product-route'
        automationBoundary = (
            'HDC system-key injection validates the production event chain but does not ' +
            'satisfy physical-keyboard or Chinese/English IME acceptance.'
        )
        selectedScenarios = @($Only)
        checks = @($checks)
        automation = Get-LeanTTYDeviceCommandAutomationSummary `
            -Observations $commandObservations `
            -BusinessVerdict $automationVerdict `
            -BusinessPostcondition 'selected-terminal-search-checks-and-cleanup'
        failureDomain = $failureDomain
        failure = $failure
        cleanup = [ordered]@{
            result = $(if ($cleanupFailure) { 'failed' } else { 'passed' })
            transientSearchClosed = $searchClosed
            singleTabSinglePaneRestored = $workspaceRestored
            awakeLeaseRestored = $awakeLeaseAcquired -and -not $cleanupFailure
            failure = $cleanupFailure
        }
    }
    [IO.File]::WriteAllText(
        (Join-Path $EvidenceDirectory 'device-terminal-search.json'),
        (ConvertTo-Json -InputObject $evidence -Depth 7),
        [Text.UTF8Encoding]::new($false)
    )
}

if ($failure) { throw $failure }
if ($cleanupFailure) { throw "Terminal-search cleanup failed: $cleanupFailure" }
$evidencePath = Join-Path $EvidenceDirectory 'device-terminal-search.json'
if (-not $DiagnosticHap) {
    Save-LeanTTYVerifiedCandidate `
        -RepoRoot $repoRoot `
        -HapPath $candidate.hapPath `
        -VerificationMode 'device-behavior' `
        -EvidencePaths @($evidencePath) `
        -CandidateBasePath $CandidateBasePath | Out-Null
    Write-Host (
        'DEVICE BEHAVIOR SUCCESS: terminal-search ' +
        "(SHA256=$hapHash, scenarios=$($Only -join ','), evidence=$evidencePath)"
    ) -ForegroundColor Green
} else {
    Write-Host (
        'DIAGNOSTIC SUCCESS: terminal-search ' +
        "(scenarios=$($Only -join ','), evidence=$evidencePath; candidate not promoted)"
    ) -ForegroundColor Yellow
}
