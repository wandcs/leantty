param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'device-regression.ps1')
$smokePath = Join-Path $PSScriptRoot 'verify-review-smoke-pc.ps1'
$tokens=$null; $errors=$null
$ast = [Management.Automation.Language.Parser]::ParseFile($smokePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Review smoke syntax error' }
$uiFunction = @($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-ReviewUiState'
}, $true))
if ($uiFunction.Count -ne 1) { throw 'Review UI contract function missing' }
Invoke-Expression $uiFunction[0].Extent.Text
function New-UiNode([hashtable]$Attributes, [object[]]$Children=@()) {
    return [pscustomobject]@{attributes=[pscustomobject]$Attributes;children=$Children}
}
function New-ReviewLayout([string]$ActiveLabel='Active tab: ', [int]$Panes=1, [switch]$Duplicate) {
    $children=@(New-UiNode @{type='Stack';clickable='true';description='ltty';text='';accessibilityId='45'})
    $children += New-UiNode @{type='Stack';clickable='true';description='ltty';text='';accessibilityId=$(if($Duplicate){'45'}else{'53'})}
    foreach ($index in 1..$Panes) {
        $children += New-UiNode @{hint='Terminal input';focused=$(if($index -eq $Panes){'true'}else{'false'})}
    }
    # A retained hidden Tab must not inflate the active Pane count.
    $children += New-UiNode @{type='__Common__';hitTestBehavior='HitTestMode.None'} @(
        New-UiNode @{hint='Terminal input';focused='false'})
    return New-UiNode @{} $children
}
foreach ($count in 1..2) {
    $state=Get-ReviewUiState (New-ReviewLayout -Panes $count) @{activeTabPosition=1;tabs=@(@{},@{})}
    if($state.activeId -cne '53' -or $state.inputs.Count -ne $count -or $state.focus.Count -ne 1){throw 'Review semantic state mismatch'}
}
foreach ($bad in @(
    @{layout=(New-ReviewLayout -Duplicate);workspace=@{activeTabPosition=1;tabs=@(@{},@{})}},
    @{layout=(New-ReviewLayout);workspace=@{activeTabPosition=2;tabs=@(@{},@{})}},
    @{layout=(New-ReviewLayout);workspace=@{activeTabPosition=0;tabs=@(@{})}}
)) {
    $rejected=$false
    try { Get-ReviewUiState $bad.layout $bad.workspace | Out-Null } catch {
        if ($_.Exception.Message -notmatch 'identity.*ambiguous') { throw }
        $rejected=$true
    }
    if (-not $rejected) { throw 'Ambiguous review Tab was not rejected' }
}
$commands=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true) | ForEach-Object { $_.GetCommandName() })
foreach ($forbidden in @('Submit-LeanTTYDeviceCommand','Invoke-LeanTTYDeviceText','Wait-LeanTTYAppLog','Reset-LeanTTYDeviceCommandInput')) {
    if ($forbidden -in $commands) { throw "Review smoke must not depend on input hooks: $forbidden" }
}
foreach ($file in @('dev-pc.ps1','diagnose-text-input-pc.ps1','verify-terminal-search-pc.ps1',
    'verify-startup-warm-pc.ps1','verify-startup-upgrade-pc.ps1','verify-unexpected-recovery-uninstall-pc.ps1')) {
    $content=Get-Content -LiteralPath (Join-Path $PSScriptRoot $file) -Raw
    if($content -notmatch '(?s)Assert-LeanTTYDeviceHap.*?install.*?-r') { throw "Installation missing package admission: $file" }
}
Write-Host 'REVIEW SMOKE CONTRACT TESTS PASSED'
