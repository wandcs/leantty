param()
$ErrorActionPreference = 'Stop'
function Assert-Perf($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Assert-PerfThrows([scriptblock]$Action, $Message) {
    $failed = $false
    try { & $Action } catch { $failed = $true }
    Assert-Perf $failed $Message
}
& {
    # Exercise the real shared log query: a valid parser is useless if its tag is
    # excluded before the record reaches it. No device or private log is read.
    . (Join-Path $PSScriptRoot 'device-regression.ps1')
    $queries = [Collections.Generic.List[string]]::new()
    function Invoke-HdcChecked {
        param($Hdc, $Target, $Arguments, $Operation)
        $queries.Add(($Arguments -join ' '))
        $tags = [regex]::Match(($Arguments -join ' '), '-T (?<tags>[^ ]+)').Groups['tags'].Value
        Assert-Perf (($tags -split ',').Count -le 10) 'HarmonyOS hilog permits at most ten tags per query'
        if ($tags -match 'NativeOutputPerformance' -and $tags -match 'MoshClient') {
            return "NATIVE_OUTPUT_PROBE public-fixture`nMOSH_PUBLIC_FIXTURE"
        }
        return 'SESSION_PUBLIC_FIXTURE'
    }
    $logs = Get-LeanTTYAppLogs -Hdc fixture -Target fixture -ProcessId 42
    Assert-Perf ($logs.Contains('NATIVE_OUTPUT_PROBE public-fixture') -and
        $logs.Contains('MOSH_PUBLIC_FIXTURE') -and $queries.Count -eq 2 -and
        @($queries | Where-Object { $_ -notmatch '-P 42 ' }).Count -eq 0) (
        'Shared application log query must include native performance and keep the process boundary')
}
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'verify-ssh-auth-pc.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Invoke-AuthPerfSample', 'Get-AuthPerfNativeRecord')) {
    $definitions = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true))
    Assert-Perf ($definitions.Count -eq 1) "Missing or ambiguous performance owner: $name"
    Invoke-Expression $definitions[0].Extent.Text
}
$state = @{ commands = [Collections.Generic.List[string]]::new(); failure = ''; waits = 0; logs = '' }
function Submit-ConnectedInput { param($Text) $state.commands.Add($Text) }
function Get-FixtureLogMatchCount { return 0 }
function Wait-FixtureLogMatchCount {
    $state.waits++
    if (($state.failure -eq 'prepare' -and $state.waits -eq 1) -or
        ($state.failure -eq 'run' -and $state.waits -eq 2)) { throw 'controlled fixture timeout' }
}
function Clear-LeanTTYAppLogs {}
function Wait-AuthLog { if ($state.failure -eq 'presentation') { throw 'controlled presentation timeout' } }
function Get-LeanTTYAppLogs { return $state.logs }
$valid = 'NATIVE_OUTPUT_PROBE case=fixture_01 expectedBytes=984000 actualBytes=984000' +
    ' expectedLines=12000 actualLines=12000 mismatches=0 contentOrdered=true' +
    ' parseMs=800 paintMs=830 observerMs=21 inputSamples=0 inputEchoBytes=0 inputValid=true'
$state.logs = "09-19 12:00:00.123 42 I tag: $valid"
$record = Invoke-AuthPerfSample -CaseId fixture_01
Assert-Perf ($record.schemaVersion -eq 3 -and $record.renderer -ceq 'native' -and
    $record.commandAttempts -eq 1 -and $state.commands.Count -eq 2 -and $record.paintMs -eq 830) (
    'Native consumed/presented evidence must prepare and run exactly once')
Assert-Perf (-not $record.PSObject.Properties['visibleTailConfirmed']) (
    'A native frame watermark must not claim a separately inspected VT or pixel snapshot')
$badRecords = @(
    $valid.Replace('actualBytes=984000', 'actualBytes=983999'),
    $valid.Replace('expectedBytes=984000', 'expectedBytes=983999'),
    $valid.Replace('actualLines=12000', 'actualLines=11999'),
    $valid.Replace('expectedLines=12000', 'expectedLines=11999'),
    $valid.Replace('mismatches=0', 'mismatches=1'),
    $valid.Replace('mismatches=0 ', ''),
    $valid.Replace('contentOrdered=true', 'contentOrdered=false'),
    $valid.Replace('paintMs=830', 'paintMs=799'),
    $valid.Replace('parseMs=800', 'parseMs=-1'),
    $valid.Replace('observerMs=21', 'observerMs=NaN'),
    $valid.Replace('inputValid=true', 'inputValid=false'),
    $valid.Replace('inputSamples=0', 'inputSamples=1'),
    $valid.Replace('inputEchoBytes=0', 'inputEchoBytes=1'),
    $valid.Replace('fixture_01', 'fixture_010'),
    $valid.Replace('actualBytes=984000', 'actualBytes=9999999999999999999999999'),
    ($valid + "`n" + $valid),
    $valid.Substring(0, $valid.Length - 3),
    'PERF render {"caseId":"fixture_01","completenessPercent":100}'
)
foreach ($bad in $badRecords) {
    $state.logs = $bad; $state.commands.Clear(); $state.waits = 0
    Assert-PerfThrows { Invoke-AuthPerfSample -CaseId fixture_01 } 'Invalid native evidence must fail'
    Assert-Perf ($state.commands.Count -eq 2) 'Rejected evidence must not resubmit the stream'
}
foreach ($failure in @('prepare', 'run', 'presentation')) {
    $state.logs = $valid; $state.failure = $failure; $state.commands.Clear(); $state.waits = 0
    Assert-PerfThrows { Invoke-AuthPerfSample -CaseId fixture_01 } 'Unknown outcomes must stop without retries'
    $expectedCommands = if ($failure -eq 'prepare') { 1 } else { 2 }
    Assert-Perf ($state.commands.Count -eq $expectedCommands) 'An uncertain stage dispatched more input'
}
Write-Host 'Native performance evidence passed: valid sample, 18 rejection cases, 3 uncertain boundaries.' -ForegroundColor Green
