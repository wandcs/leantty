<#
.SYNOPSIS
  Exercise normal UI in a release-mode, test-Profile HAP without acceptance hooks.
.DESCRIPTION
  Development evidence only. Installs the selected HAP, opens a disposable Tab,
  splits and closes a Pane by keyboard, then closes that Tab and independently
  checks the persisted workspace and Settings digest. Never submits command text.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$HapPath,
    [string]$Target = '',
    [string]$UnlockPasswordPath = '',
    [string]$EvidenceDirectory = '',
    [string]$PreviousAttemptId = ''
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'device-package.ps1')
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')
if (-not $EvidenceDirectory) {
    $EvidenceDirectory = Join-Path $repoRoot ('build/verification/review-smoke-' + [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$layoutPath = Join-Path $EvidenceDirectory 'current-layout.json'
$reportPath = Join-Path $EvidenceDirectory 'review-smoke.json'
$timer = [Diagnostics.Stopwatch]::StartNew()
$result = [ordered]@{
    schemaVersion=1; scenario='review-normal-product-path'; attemptId=[guid]::NewGuid().ToString('N');
    previousAttemptId=$PreviousAttemptId; startedAt=[DateTimeOffset]::UtcNow.ToString('o'); result='running';
    acceptanceEligible=$false; failureDomain=''; failure=''; candidate=$null; device=$null;
    harness=@(foreach ($file in @('verify-review-smoke-pc.ps1','device-package.ps1','package-policy.ps1','device-regression.ps1','hdc-common.ps1','dev-pc.ps1')) {
        @{file=$file;sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $file)).Hash.ToLowerInvariant()}
    });
    stages=@(); commandSubmissions=0; inputRetries=0; resources=@(); cleanup='not-needed'
}
$ownedTabId = ''
$baseline = $null
$baselineWorkspace = ''
$baselineSettings = ''
$awake = $false
$tabCreateSent = $false
function Write-ReviewStatus {
    $result['durationMs'] = $timer.ElapsedMilliseconds
    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportPath -Encoding utf8
}
function Invoke-ReviewStage([string]$Name, [scriptblock]$Action) {
    $stage = [ordered]@{name=$Name;result='running';durationMs=0}
    $result.stages += $stage
    Write-ReviewStatus
    Write-Host "[review-smoke] $Name start"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try { & $Action; $stage.result='passed' } catch { $stage.result='failed'; throw } finally {
        $stage.durationMs=$watch.ElapsedMilliseconds
        Write-ReviewStatus
        Write-Host "[review-smoke] $Name $($stage.result) ($($stage.durationMs) ms)"
    }
}
function Get-ReviewUiState([object]$Layout, [object]$Workspace) {
    $nodes = @(Get-LeanTTYLayoutNodes -Node $Layout)
    $tabs = @($nodes | Where-Object {
        $_.attributes.type -ceq 'Stack' -and $_.attributes.clickable -eq 'true' -and
        -not [string]::IsNullOrWhiteSpace([string]$_.attributes.description)
    })
    # Titles can repeat and UiTest 6.0.2.3 omits accessibilityText. Keep current
    # node identities and use the product-owned checkpoint for active position.
    $ids = @($tabs | ForEach-Object { [string]$_.attributes.accessibilityId })
    if ($tabs.Count -eq 0 -or '' -cin $ids -or @($ids | Select-Object -Unique).Count -ne $ids.Count -or
        @($Workspace.tabs).Count -ne $tabs.Count -or ($Workspace.activeTabPosition -isnot [long] -and $Workspace.activeTabPosition -isnot [int]) -or
        $Workspace.activeTabPosition -lt 0 -or $Workspace.activeTabPosition -ge $tabs.Count) {
        throw '[harness] Review Tab identity is unavailable or ambiguous'
    }
    $inputs = @(Get-LeanTTYTerminalInputNodes -Layout $Layout)
    $focus = @($inputs | Where-Object { $_.attributes.focused -eq 'true' })
    return [pscustomobject]@{tabs=$tabs;ids=$ids;activeId=$ids[$Workspace.activeTabPosition];inputs=$inputs;focus=$focus;layout=$Layout}
}
function Read-ReviewUi {
    $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $layoutPath
    return Get-ReviewUiState $layout (Get-ReviewWorkspace | ConvertFrom-Json)
}
function Wait-ReviewUi([int]$TabCount, [int]$PaneCount, [string]$ActiveId = '') {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $state = Read-ReviewUi
        if ($state.tabs.Count -eq $TabCount -and $state.inputs.Count -eq $PaneCount -and $state.focus.Count -eq 1 -and
            (-not $ActiveId -or $state.activeId -ceq $ActiveId)) { return $state }
        Start-Sleep -Milliseconds 250
    } while ($watch.Elapsed.TotalSeconds -lt 10)
    throw '[product] Review workspace/focus postcondition did not arrive within 10 seconds'
}
function Send-ReviewShortcut([int]$Key) {
    $state = Read-ReviewUi
    if ($state.focus.Count -ne 1 -or ($ownedTabId -and $state.activeId -cne $ownedTabId)) {
        throw '[harness] Refusing shortcut without the expected focused owner'
    }
    Invoke-HdcChecked -Hdc $hdc -Target $Target -Arguments @('shell',
        "uinput -K -d 2072 -d 2047 -d $Key -u $Key -u 2047 -u 2072") -Operation 'review smoke shortcut' | Out-Null
}
function Select-ReviewTab([string]$TabId) {
    $state = Read-ReviewUi
    $tab = @($state.tabs | Where-Object { $_.attributes.accessibilityId -ceq $TabId })
    if ($tab.Count -ne 1) { throw '[harness] Refusing to select an unidentified review Tab' }
    $center = Get-LeanTTYBoundsCenter -Bounds $tab[0].attributes.bounds
    Invoke-LeanTTYDeviceClick -Hdc $hdc -Target $Target -X $center.x -Y $center.y -Operation 'select exact review Tab'
}
function Get-ReviewWorkspace {
    $path = '/data/app/el2/100/base/com.leantty.app/haps/entry/preferences/leantty_unexpected_exit_recovery'
    $raw = Invoke-HdcChecked -Hdc $hdc -Target $Target -Arguments @('shell','-b','com.leantty.app',"cat $path") -Operation 'read workspace-only recovery state'
    [xml]$xml = $raw
    $recordNode = $xml.SelectSingleNode('/preferences/string[@key="record"]')
    if ($null -eq $recordNode) { throw '[harness] Persisted workspace record is missing' }
    $record = $recordNode.InnerText | ConvertFrom-Json
    if ($record.schemaVersion -ne 1 -or $null -eq $record.workspace.tabs) { throw '[harness] Unknown workspace schema' }
    return $record.workspace | ConvertTo-Json -Depth 5 -Compress
}
function Get-ReviewSettingsDigest {
    $path = '/data/app/el2/100/base/com.leantty.app/haps/entry/preferences/leantty_settings'
    $raw = Invoke-HdcChecked -Hdc $hdc -Target $Target -Arguments @('shell','-b','com.leantty.app',"sha256sum $path") -Operation 'Settings preservation digest'
    if ($raw -notmatch '(?m)^([0-9a-fA-F]{64})\s+') { throw '[harness] Settings digest is missing' }
    return $Matches[1].ToLowerInvariant()
}
try {
    Invoke-ReviewStage 'package-admission' {
        $result.candidate = Assert-LeanTTYDeviceHap -HapPath $HapPath -Purpose review-smoke
    }
    $hdc = Resolve-Hdc
    $Target = Resolve-LeanTTYRegressionTarget -Hdc $hdc -Target $Target
    Invoke-ReviewStage 'preflight' {
        & (Join-Path $PSScriptRoot 'preflight-device.ps1') -Target $Target -EvidencePath (Join-Path $EvidenceDirectory 'preflight.json')
        if ($LASTEXITCODE -ne 0) { throw '[infrastructure] Review smoke device preflight failed' }
        $result.device = @{target=$Target;model=(Invoke-HdcShell $hdc $Target 'param get const.product.model').Trim();
            api=(Invoke-HdcShell $hdc $Target 'param get const.ohos.apiversion').Trim();
            version=(Invoke-HdcShell $hdc $Target 'param get const.product.software.version').Trim();
            uiTest=(Invoke-HdcShell $hdc $Target 'uitest --version').Trim()}
    }
    Start-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $Target -TimeoutMilliseconds 300000
    $awake = $true
    Invoke-ReviewStage 'install-startup' {
        & (Join-Path $PSScriptRoot 'dev-pc.ps1') -SkipBuild -HapPath $HapPath -HapPurpose review-smoke -Target $Target -UnlockPasswordPath $UnlockPasswordPath
        if ($LASTEXITCODE -ne 0) { throw '[infrastructure] Review HAP deployment failed' }
        Wait-LeanTTYTerminalInputLayout -Hdc $hdc -Target $Target -LocalPath $layoutPath | Out-Null
    }
    $baseline = Read-ReviewUi
    if ($baseline.focus.Count -ne 1) { throw '[harness] Review startup has no unique focused terminal' }
    $baselineWorkspace = Get-ReviewWorkspace
    $baselineSettings = Get-ReviewSettingsDigest
    Invoke-ReviewStage 'new-tab' {
        $script:tabCreateSent = $true
        Send-ReviewShortcut 2036
        $state = Wait-ReviewUi ($baseline.tabs.Count + 1) 1
        $added = @($state.ids | Where-Object { $_ -cnotin $baseline.ids })
        if ($added.Count -ne 1 -or $state.activeId -cne $added[0] -or
            @($baseline.ids | Where-Object { $_ -cnotin $state.ids }).Count -ne 0) { throw '[harness] New review Tab identity not proved' }
        $script:ownedTabId = $added[0]
        $result.resources = @(@{kind='disposable-idle-tab';uiIdentity=$ownedTabId;identityObserved=$true;removed=$false})
    }
    Invoke-ReviewStage 'keyboard-split' {
        Send-ReviewShortcut 2020
        Wait-ReviewUi ($baseline.tabs.Count + 1) 2 $ownedTabId | Out-Null
    }
    Invoke-ReviewStage 'keyboard-close-pane' {
        Send-ReviewShortcut 2039
        Wait-ReviewUi ($baseline.tabs.Count + 1) 1 $ownedTabId | Out-Null
    }
    $result.result = 'passed'
} catch {
    $result.result='failed'; $result.failure=$_.Exception.Message
    $match = [regex]::Match($result.failure, '^\[(product|harness|environment|infrastructure)\]')
    $result.failureDomain = if ($match.Success) { $match.Groups[1].Value } else { 'harness' }
} finally {
    if ($tabCreateSent) {
        try {
            Invoke-ReviewStage 'cleanup' {
                # A missing acknowledgement never authorizes another shortcut.
                if (-not $ownedTabId) { throw '[harness] Unknown Tab creation outcome; manual inspection required' }
                Select-ReviewTab $ownedTabId
                $state = Read-ReviewUi
                $tab = @($state.tabs | Where-Object { $_.attributes.accessibilityId -ceq $ownedTabId })[0]
                $close = @(Get-LeanTTYLayoutNodes -Node $tab | Where-Object {
                    $_.attributes.type -ceq 'Text' -and $_.attributes.clickable -eq 'true' -and $_.attributes.text -ceq '✕'
                })
                if ($close.Count -ne 1) { throw '[harness] Exact disposable Tab close control is ambiguous' }
                $center = Get-LeanTTYBoundsCenter -Bounds $close[0].attributes.bounds
                Invoke-LeanTTYDeviceClick -Hdc $hdc -Target $Target -X $center.x -Y $center.y -Operation 'close disposable review Tab'
                Select-ReviewTab $baseline.activeId
                $restored = Wait-ReviewUi $baseline.tabs.Count $baseline.inputs.Count $baseline.activeId
                if (($restored.ids | ConvertTo-Json -Compress) -cne ($baseline.ids | ConvertTo-Json -Compress) -or
                    (Get-ReviewWorkspace) -cne $baselineWorkspace -or (Get-ReviewSettingsDigest) -cne $baselineSettings) {
                    throw '[product] Review cleanup did not preserve the baseline workspace and Settings'
                }
                $result.resources[0].removed=$true
                $result.cleanup='passed'
            }
        } catch {
            $result.cleanup='failed'; $result.result='invalid'; $result.failureDomain='harness'
            $result['cleanupFailure']=$_.Exception.Message
        }
    }
    if ($awake) {
        try { Stop-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $Target } catch {
            $result.result='invalid'; $result.cleanup='failed'; $result['awakeRestoreFailure']=$_.Exception.Message
        }
    }
    if (Test-Path -LiteralPath $layoutPath) { Remove-Item -LiteralPath $layoutPath -Force }
    Write-ReviewStatus
}
Write-Host "REVIEW SMOKE $($result.result.ToUpperInvariant()): $reportPath"
if ($result.result -ne 'passed') { exit 1 }
