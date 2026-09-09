param([string]$EvidencePath = '')
$ErrorActionPreference = 'Stop'
$checks = [Collections.Generic.List[object]]::new()
function Assert-Probe([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Test-Probe([string]$Name, [scriptblock]$Action) {
    try { & $Action; $checks.Add(@{ name = $Name; result = 'passed' }) }
    catch { $checks.Add(@{ name = $Name; result = 'failed'; failure = $_.Exception.Message }) }
}
function Read-ProbeAst([string]$FileName) {
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot $FileName), [ref]$null, [ref]$parseErrors)
    Assert-Probe ($parseErrors.Count -eq 0) "Parse error in $FileName"
    return $ast
}
$moshAst = Read-ProbeAst 'verify-mosh-pc.ps1'
$searchAst = Read-ProbeAst 'verify-terminal-search-pc.ps1'

# Execute each actual scenario submission, replacing only the device-command boundary.
foreach ($stage in @('mosh-runtime-reclaim-local-command', 'process-recovery-local-command',
    'operator-lid-local-command', 'operator-lid-runtime-local-command')) {
    Test-Probe $stage {
        $calls = @($moshAst.FindAll({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Submit-LocalCommand' -and
            $node.CommandElements[-1].Value -eq $stage
        }, $true))
        Assert-Probe ($calls.Count -eq 1) "Missing or ambiguous recovery submission: $stage"
        $sent = [Collections.Generic.List[object]]::new()
        function Submit-LocalCommand { param($Command, $Stage) $sent.Add(@{ command = $Command; stage = $Stage }) }
        & ([scriptblock]::Create($calls[0].Extent.Text))
        Assert-Probe ($sent.Count -eq 1 -and $sent[0].command -ceq 'help mosh' -and
            $sent[0].stage -ceq $stage) 'Recovery probe must use one permission-free topic-help command'
    }
}
Test-Probe 'runtime-output-oracle-matches-topic-help' {
    $calls = @($moshAst.FindAll({ param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Test-MoshTerminalSearch' -and
        $node.CommandElements[-1].Value -eq 'mosh-runtime-reclaim-help-output-search'
    }, $true))
    Assert-Probe ($calls.Count -eq 1) 'Missing recovery output assertion'
    function Test-MoshTerminalSearch { param($Query, $ExpectMatch, $Name)
        Assert-Probe ($Query -ceq 'Usage: mosh' -and $ExpectMatch) 'Output oracle still expects top-level help'
        return $true
    }
    Assert-Probe (& ([scriptblock]::Create($calls[0].Extent.Text))) 'Output assertion did not run'
}
Test-Probe 'search-scrollback-fixture-without-downloads' {
    $branches = @($searchAst.FindAll({ param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -ceq "`$Only -contains 'pane-tab-ownership'"
    }, $true))
    Assert-Probe ($branches.Count -eq 1) 'Missing search ownership scenario'
    $setup = [Collections.Generic.List[string]]::new()
    foreach ($statement in $branches[0].Clauses[0].Item2.Statements) {
        if ($statement.Extent.Text -ceq 'Invoke-TerminalSearchShortcut') { break }
        $setup.Add($statement.Extent.Text)
    }
    $commands = [Collections.Generic.List[string]]::new()
    function Wait-TerminalWorkspaceState {}
    function Invoke-LocalTerminalCommand { param($Command) $commands.Add($Command) }
    & ([scriptblock]::Create($setup -join "`n"))
    Assert-Probe ($commands.Count -eq 6 -and @($commands | Where-Object { $_ -cne 'help mosh' }).Count -eq 0) (
        'Scrollback fixture must retain multiline output without requesting Downloads access')
    $queries = @($branches[0].Clauses[0].Item2.FindAll({ param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Wait-TerminalSearchQueryState'
    }, $true))
    Assert-Probe ($queries.Count -eq 6) 'Search ownership coverage changed'
    function Wait-TerminalSearchQueryState { param($ExpectedQuery)
        Assert-Probe ($ExpectedQuery -ceq 'Usage: mosh') 'Search token differs from its fixture output'
    }
    foreach ($query in $queries) { & ([scriptblock]::Create($query.Extent.Text)) }
    $inputs = @($branches[0].Clauses[0].Item2.FindAll({ param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Invoke-LeanTTYDeviceText'
    }, $true))
    Assert-Probe ($inputs.Count -eq $queries.Count) 'Search inputs and assertions are not paired'
    function Invoke-LeanTTYDeviceText { param($Hdc, $Target, $Text)
        Assert-Probe ($Text -ceq 'Usage: mosh') 'Injected query differs from the asserted query'
    }
    foreach ($inputCall in $inputs) { & ([scriptblock]::Create($inputCall.Extent.Text)) }
}
Test-Probe 'renderer-recovery-command-without-downloads' {
    $branch = @($searchAst.FindAll({ param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -ceq "`$Only -contains 'window-renderer-lifecycle'"
    }, $true))
    Assert-Probe ($branch.Count -eq 1) 'Missing renderer lifecycle scenario'
    $calls = @($branch[0].Clauses[0].Item2.FindAll({ param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Invoke-LocalTerminalCommand'
    }, $true))
    Assert-Probe ($calls.Count -eq 1) 'Renderer must use one local command'
    function Invoke-LocalTerminalCommand { param($Command)
        Assert-Probe ($Command -ceq 'help mosh') 'Renderer probe must not request Downloads permission'
    }
    & ([scriptblock]::Create($calls[0].Extent.Text))
}

$failed = @($checks | Where-Object result -eq 'failed')
if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
    . (Join-Path $PSScriptRoot 'release-tooling.ps1')
    Write-LeanTTYAtomicJson -Path $EvidencePath -Depth 5 -Value ([ordered]@{
        gate = 'recovery-command-probe-contract'; result = $(if ($failed.Count) { 'failed' } else { 'passed' })
        acceptanceEligible = $false; deviceOperations = 0; modelRequests = 0; checks = @($checks)
    })
}
if ($failed.Count) { throw ($failed.failure -join '; ') }
Write-Host "Recovery command probes passed: $($checks.Count) real-script boundaries."
