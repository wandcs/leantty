param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'device-regression.ps1')
function Assert-MoshEvidence($Ok, $Message) { if (-not $Ok) { throw $Message } }
function Assert-MoshReject([scriptblock]$Action) {
    $rejected=$false; try { & $Action } catch { $rejected=$true }
    Assert-MoshEvidence $rejected 'Invalid native Mosh evidence was accepted'
}
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'verify-mosh-pc.ps1'),[ref]$null,[ref]$null)
foreach($name in @('Get-MoshNativePageFingerprint','Test-MoshPageFingerprintRestored','Get-MoshSessionPageBaseline','Test-MoshTerminalSearch')) {
    $definition=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
    Assert-MoshEvidence ($definition.Count -eq 1) "Missing owner: $name"
    Invoke-Expression $definition[0].Extent.Text
}
$saved='ACCEPTANCE_NATIVE_PAGE pane=pane-1-1 sequence=10 action=saved page=10 cols=80 rows=24 screen=0 viewport=5 total=100 hash=1234567890abcdef'
$active=$saved.Replace('action=saved','action=active').Replace('viewport=5 total=100 hash=1234567890abcdef','viewport=0 total=24 hash=0123456789abcdef')
$restored=$saved.Replace('sequence=10 action=saved','sequence=20 action=restored')
$original=Get-MoshNativePageFingerprint -Action saved -PaneId pane-1-1 -Logs $saved
$after=Get-MoshNativePageFingerprint -Action restored -PaneId pane-1-1 -Logs $restored
Assert-MoshEvidence (Test-MoshPageFingerprintRestored $original $after) 'Same owning page was not restored'
foreach($replacement in @(@('hash=1234567890abcdef','hash=0123456789abcdef'),@('viewport=5','viewport=0'),@('total=100','total=101'),@('page=10','page=11'),@('sequence=20','sequence=9'),@('screen=0','screen=1'))) {
    $bad=Get-MoshNativePageFingerprint -Action restored -PaneId pane-1-1 -Logs ($restored.Replace($replacement[0],$replacement[1]))
    Assert-MoshEvidence (-not (Test-MoshPageFingerprintRestored $original $bad)) 'Changed state/page/order was accepted'
}
$foreign=Get-MoshNativePageFingerprint -Action restored -PaneId pane-2-1 -Logs ($restored.Replace('pane-1-1','pane-2-1'))
Assert-MoshEvidence (-not (Test-MoshPageFingerprintRestored $original $foreign)) 'Different Pane was accepted'
$geometry=Get-MoshNativePageFingerprint -Action restored -PaneId pane-1-1 -Logs ($restored.Replace('cols=80','cols=40'))
Assert-MoshReject { Test-MoshPageFingerprintRestored $original $geometry }
foreach($bad in @('unrelated',($saved+"`n"+$saved),$saved.Replace('pane-1-1','pane-2-1'),$saved.Replace('hash=1234567890abcdef','hash=invalid'))) {
    Assert-MoshReject { Get-MoshNativePageFingerprint -Action saved -PaneId pane-1-1 -Logs $bad }
}
$EvidenceDirectory=Join-Path (Split-Path $PSScriptRoot -Parent) 'build/verification/native-mosh-helper-tests'
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null
$state=@{logs="$saved`n$active";clears=0}
function Focus-ActiveTerminalInput { return @{attributes=@{id='native-terminal-pane-1-1'}} }
function Get-LeanTTYAppLogs { return $state.logs }
function Clear-LeanTTYAppLogs { $state.clears++ }
$baseline=Get-MoshSessionPageBaseline -Name qualified
Assert-MoshEvidence ($baseline.originalHidden -and $state.clears -eq 0) 'Native baseline must not erase lifecycle evidence'
foreach($bad in @($active,($saved+"`n"+$active.Replace('page=10','page=11')),($saved+"`n"+$active.Replace('sequence=10','sequence=11')))) {
    $state.logs=$bad; Assert-MoshReject { Get-MoshSessionPageBaseline -Name invalid }
}
& {
    # Exercise the real query and completed-generation reader together with layout.
    $state=@{reads=0;escapes=0;mode='match';query='PUBLIC';waits=0}
    function Invoke-LeanTTYSerializedUiTest {}
    function Invoke-LeanTTYDeviceText {}
    function Invoke-LeanTTYDeviceKey { $state.escapes++ }
    function Start-Sleep {}
    function Wait-LeanTTYAppLog {
        param($Hdc,$Target,$ProcessId,$Pattern,$TimeoutSeconds)
        $state.waits++
        $result=if($state.mode -eq 'empty'){'0,0'}else{'1,1'}
        $generation=if($state.mode -eq 'stale'){'4'}else{'5'}
        $logs="ACCEPTANCE_NATIVE_SEARCH_QUERY pane=pane-1-1 generation=5 length=6`nACCEPTANCE_NATIVE_SEARCH_RESULT pane=pane-1-1 generation=$generation result=$result"
        if($logs -notmatch $Pattern){throw 'controlled missing completed query'}
        return $logs
    }
    function Get-LeanTTYDeviceLayout {
        $state.reads++;if($state.reads -gt 4){throw 'controlled result timeout'}
        $label=if($state.mode -eq 'empty'){'0/0'}else{'1/1'}
        return @{attributes=@{};children=@(
            @{attributes=@{type='TextInput';id='native-search-pane-1-1';focused='true';text=$state.query;hostWindowId='1';accessibilityId='4'}}
            @{attributes=@{type='Text';id='native-search-result-pane-1-1';text=$label}}
        )}
    }
    Assert-MoshEvidence (Test-MoshTerminalSearch -Query PUBLIC -ExpectMatch $true -Name match) 'Native positive search failed'
    $state.mode='empty';$state.reads=0
    Assert-MoshEvidence (Test-MoshTerminalSearch -Query PUBLIC -ExpectMatch $false -Name empty) 'Native negative search failed'
    foreach($mode in @('stale','wrong-query','wrong-result')) {
        $state.mode=$mode;$state.reads=0;$state.query=if($mode -eq 'wrong-query'){'OTHER'}else{'PUBLIC'}
        Assert-MoshReject { Test-MoshTerminalSearch -Query PUBLIC -ExpectMatch $false -Name invalid }
    }
    Assert-MoshEvidence ($state.escapes -eq 5) 'Search failure did not close the panel'
}
& {
    # The real survivor branch must replace the closed Pane's baseline and reject
    # an already observed close before collecting new restoration evidence.
    $branches=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and
        $n.Clauses[0].Item1.Extent.Text -ceq '$Scenario -eq ''pane-close''' -and
        $n.Clauses[0].Item2.Extent.Text.Contains('$closedPaneServerPid =')},$true))
    Assert-MoshEvidence ($branches.Count -eq 1) 'Missing survivor branch'
    $body=[scriptblock]::Create(($branches[0].Clauses[0].Item2.Statements.Extent.Text -join "`n"))
    function Write-LiveStatus {}
    function Clear-LeanTTYAppLogs {}
    function Close-ActiveMoshPane {}
    function Test-MoshTerminalSearch { return $true }
    function Reset-LeanTTYDeviceCommandInput {}
    function Clear-MoshSessionControlFiles {}
    function Submit-LocalCommand {}
    function Wait-LeanTTYAppLog {}
    function Submit-InteractiveValue {}
    function Wait-ControlFile {}
    function Read-ControlledLinuxPid { return 202 }
    function Read-MoshSession { return @{pid=201;port=60042;serverPort=60042} }
    function Submit-MoshInput { $state.commands++ }
    function Wait-ControlFileMatch {}
    function Wait-WslProcessAbsent { return 10 }
    function Test-WslProcessPresent { return $true }
    function Get-MoshLifecycleObservation { return @{closed=$state.closed;error=$false} }
    function Get-MoshSessionPageBaseline { $state.baselines++; return $baseline }
    $attemptId='0123456789abcdef'
    foreach($oldCols in @(40,80)) {
        $originalPageFingerprint=@{pane='closed-pane';cols=$oldCols}
        $state=@{commands=0;baselines=0;closed=$false}
        . $body
        Assert-MoshEvidence ($originalPageFingerprint.pane -ceq $baseline.original.pane -and
            $originalPageFingerprint.identity -ceq $baseline.original.identity -and
            $moshPageFingerprint.identity -ceq $baseline.mosh.identity -and
            $state.commands -eq 1 -and $state.baselines -eq 1) 'Survivor retained the closed Pane baseline'
    }
    $state=@{commands=0;baselines=0;closed=$true}
    Assert-MoshReject { . $body }
    Assert-MoshEvidence ($state.baselines -eq 0) 'Survivor close must stop before new baseline capture'
}
Write-Host 'Native Mosh evidence passed: owning page/state/order, ambiguous records, exact query/completed generation, search cleanup and actual survivor reconnect branch.' -ForegroundColor Green
