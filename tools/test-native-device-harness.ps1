param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')
function Assert-NativeHarness($Condition, $Message) {
    if (-not $Condition) { throw $Message }
}
$searchAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'verify-terminal-search-pc.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Get-TerminalSearchInputNodes', 'Get-TerminalSearchContainerNodes',
    'Get-TerminalSearchResultNodes', 'Get-TerminalSearchResultLabel', 'Get-LeanTTYTerminalContentTop',
    'Get-LeanTTYTabNodes', 'Get-LeanTTYActiveTerminalInputNodes', 'Get-LeanTTYActiveTerminalSurfaceNodes')) {
    $definition = $searchAst.FindAll({param($n)
        $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
    }, $true) | Select-Object -First 1
    Invoke-Expression $definition.Extent.Text
}
function New-NativeHarnessLayout([string]$Case = 'same', [bool]$After = $false) {
    $node = [pscustomobject]@{ attributes = [pscustomobject]@{
        type = 'XComponent'; id = 'native-terminal-pane-1-1'; hostWindowId = '951'; accessibilityId = '100'
        hierarchy = 'ROOT951,0,0'; bounds = '[10,60][110,160]'; focused = 'true'; visible = 'true'
    }; children = @() }
    if ($After) {
        $node.attributes.hierarchy = 'ROOT951,1,0'
        $node.attributes.bounds = '[20,60][120,160]'
        switch ($Case) {
            'other-pane' { $node.attributes.id = 'native-terminal-pane-1-2' }
            'recreated' { $node.attributes.accessibilityId = '200' }
            'other-window' { $node.attributes.hostWindowId = '952' }
            'search' { $node.attributes.type = 'TextInput'; $node.attributes.id = 'native-search-pane-1-1' }
            'missing-id' { $node.attributes.accessibilityId = '' }
        }
    }
    $peers = @($node)
    if ($After -and $Case -in @('duplicate-platform-id', 'duplicate-pane-id', 'peer')) {
        $peers += [pscustomobject]@{attributes = @{
            type = 'XComponent'; id = $(if ($Case -eq 'duplicate-pane-id') { $node.attributes.id } else { 'native-terminal-pane-1-2' })
            hostWindowId = '951'; accessibilityId = $(if ($Case -eq 'duplicate-platform-id') { '100' } else { '300' })
            focused = 'false'; visible = 'true'; bounds = '[20,60][120,160]'
        }; children = @()}
    }
    # Retained inactive tabs are still returned by UiTest, including focused flags.
    $hidden = @{attributes = @{ type = '__Common__'; opacity = '0.000000'; hitTestBehavior = 'HitTestMode.None' }
        children = @(@{attributes = @{type = 'XComponent'; id = 'native-terminal-pane-1-3'; focused = 'true'}; children = @()})}
    return [pscustomobject]@{ attributes = @{}; children = @($hidden) + $peers }
}
foreach ($case in @('same', 'peer', 'other-pane', 'recreated', 'other-window', 'search', 'missing-id',
    'duplicate-platform-id', 'duplicate-pane-id')) {
    & {
        $script:nativeReads = 0; $script:nativeWrites = 0
        function Get-HdcUiLayout {
            $script:nativeReads++
            return New-NativeHarnessLayout -Case $case -After ($script:nativeReads -gt 1)
        }
        function Invoke-NativeFakeHdc { $script:nativeWrites++; $global:LASTEXITCODE = 0 }
        $failure = $null
        try { Invoke-LeanTTYDeviceText -Hdc Invoke-NativeFakeHdc -Target test -Text 'public-probe' }
        catch { $failure = $_.Exception }
        if ($case -in @('same', 'peer')) {
            Assert-NativeHarness ($null -eq $failure) "Same native target rejected: $case $failure"
        } else {
            Assert-NativeHarness ($null -ne $failure) "Changed native target accepted: $case"
            $detail = $failure.Data['LeanTTYTextInputFailure']
            Assert-NativeHarness ($detail.phase -eq 'after' -and
                ($detail | ConvertTo-Json -Depth 12) -notmatch 'public-probe|native-terminal|native-search|ROOT951') 'Failure leaked content or lost phase'
        }
        Assert-NativeHarness ($script:nativeReads -eq 2 -and $script:nativeWrites -eq 1) 'Input was retried or skipped'
    }
}
# Stale caller target must fail before text delivery, even at identical bounds.
& {
    $before = New-NativeHarnessLayout
    function Get-HdcUiLayout { New-NativeHarnessLayout -Case recreated -After $true }
    function Invoke-NativeFakeHdc { throw 'Unexpected text delivery' }
    $failure = $null
    try { Invoke-LeanTTYDeviceText -Hdc Invoke-NativeFakeHdc -Target test -Text public-probe `
        -InputNode @(Get-LeanTTYTerminalInputNodes -Layout $before)[0] -InputLayout $before }
    catch { $failure = $_.Exception }
    Assert-NativeHarness ($failure.Data['LeanTTYTextInputFailure'].phase -eq 'before') 'Stale target reached text injection'
}
# Native search nodes use the same Pane suffix; unrelated text cannot be a result.
$layout = New-NativeHarnessLayout
$layout.children += @(
    @{attributes=@{type='Row';id='native-search-panel-pane-1-1';visible='true'};children=@()},
    @{attributes=@{type='TextInput';id='native-search-pane-1-1';visible='true';focused='true';text='ssh';hostWindowId='951';accessibilityId='101'};children=@()},
    @{attributes=@{type='Text';id='native-search-result-pane-1-1';visible='true';text='0/0'};children=@()},
    @{attributes=@{type='Text';visible='true';text='7/7'};children=@()})
Assert-NativeHarness (@(Get-TerminalSearchInputNodes $layout).Count -eq 1) 'Native query was not located'
Assert-NativeHarness (@(Get-TerminalSearchContainerNodes $layout).Count -eq 1) 'Native panel was not located'
Assert-NativeHarness ((Get-TerminalSearchResultLabel $layout) -ceq '0/0') 'No-match result or unrelated text was misread'
Assert-NativeHarness (@(Get-LeanTTYTerminalInputNodes $layout).Count -eq 1) 'Hidden retained Pane was active'
Assert-NativeHarness ((Get-LeanTTYTerminalContentTop $layout) -eq 60) 'Native content boundary incorrect'
foreach ($case in @('missing-id', 'duplicate-platform-id', 'duplicate-pane-id')) {
    & {
        function Get-HdcUiLayout { New-NativeHarnessLayout -Case $case -After $true }
        function Invoke-NativeFakeHdc { throw 'Unexpected text delivery' }
        $failure = $null
        try { Invoke-LeanTTYDeviceText -Hdc Invoke-NativeFakeHdc -Target test -Text public-probe }
        catch { $failure = $_.Exception }
        Assert-NativeHarness ($failure.Data['LeanTTYTextInputFailure'].phase -eq 'before') 'Ambiguous native identity reached input delivery'
    }
}
& {
    $before = New-NativeHarnessLayout
    function Invoke-LeanTTYDeviceClick { param($X,$Y) Assert-NativeHarness ($X -eq 60 -and $Y -eq 110) 'Focus click missed current native bounds' }
    function Get-LeanTTYDeviceLayout { New-NativeHarnessLayout -After $true }
    $focused = Set-LeanTTYTerminalInputFocus -Hdc unused -Target unused `
        -InputNode @(Get-LeanTTYTerminalInputNodes $before)[0] -LocalPath unused
    Assert-NativeHarness (@(Get-LeanTTYTerminalInputNodes $focused)[0].attributes.bounds -eq '[20,60][120,160]') 'Focus locator depended on stale geometry'
}
# Exercise native selectors in the destructive recovery harness without any
# installation/uninstall, and Agent search without starting a model session.
foreach ($script in @('verify-unexpected-recovery-uninstall-pc.ps1','verify-agent-compatibility-pc.ps1')) {
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $script), [ref]$null, [ref]$null)
    foreach ($name in @('Get-TerminalContentTop','Get-WorkspaceState','Assert-AgentSearch')) {
        $definition = $ast.FindAll({param($n)
            $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
        }, $true) | Select-Object -First 1
        if ($null -ne $definition) { Invoke-Expression $definition.Extent.Text }
    }
}
$workspace = New-NativeHarnessLayout -Case peer -After $true
$workspace.children += @{attributes=@{type='Stack';clickable='true';description='ltty';bounds='[10,10][110,50]'};children=@()}
$state=Get-WorkspaceState $workspace
Assert-NativeHarness ($state.tabCount -eq 1 -and $state.paneCount -eq 2) 'Recovery selector confused native Panes, chrome or retained tabs'
& {
    $hdc='Invoke-NativeFakeHdc'; $Target='unused'; $script:agentQuery=$null
    function Invoke-NativeFakeHdc { $global:LASTEXITCODE=0 }
    function Get-FullLayout {
        $layout.children[4].attributes.text='1/1'
        return $layout
    }
    function Invoke-LeanTTYDeviceText { param($InputNode,$Text)
        Assert-NativeHarness ($InputNode.attributes.id -eq 'native-search-pane-1-1') 'Agent query targeted another field'
        $script:agentQuery=$Text
    }
    function Invoke-LeanTTYDeviceKey {}
    Assert-AgentSearch -Stage native-selector
    Assert-NativeHarness ($script:agentQuery -eq 'LEANTTY_AGENT_DONE') 'Agent search lost its controlled output query'
}
# Run the actual search report writer: nested command receipts must remain
# objects, not PowerShell type-name strings from a shallow JSON depth.
& {
    $EvidenceDirectory=Join-Path ([IO.Path]::GetTempPath()) ('native-search-report-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $EvidenceDirectory | Out-Null
    $evidence=@{automation=@{commands=@(@{attempts=@(@{records=@{submissions=@(@{sequence=1;kind='command'})}})})}}
    $writer=$searchAst.FindAll({param($n)
        $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Extent.Text -match 'device-terminal-search.json'
    },$true) | Select-Object -First 1
    try {
        Invoke-Expression $writer.Extent.Text
        $saved=Get-Content (Join-Path $EvidenceDirectory 'device-terminal-search.json') -Raw | ConvertFrom-Json -Depth 20
        Assert-NativeHarness ($saved.automation.commands[0].attempts[0].records.submissions[0].kind -ceq 'command') 'Search report truncated nested command evidence'
    } finally {
        Remove-Item -LiteralPath (Join-Path $EvidenceDirectory 'device-terminal-search.json') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $EvidenceDirectory -Force
    }
}
Write-Host 'Native device harness: 14 input identity/focus cases, search, Agent/recovery selectors and report depth passed.'
