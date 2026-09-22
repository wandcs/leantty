param([string]$EvidencePath = '')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hdc-common.ps1')

# Execute the production preflight and mapping boundary, never the device script.
$sourcePath = Join-Path $PSScriptRoot 'verify-put-get-pc.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'PUT/GET source did not parse' }
$mappingAssignment = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$existingMappings'
}, $true))
if ($mappingAssignment.Count -ne 1) { throw 'Expected one PUT/GET mapping preflight' }
$statements = @($mappingAssignment[0].Parent.Statements)
$start = [Array]::IndexOf($statements, $mappingAssignment[0])
$end = $start
while ($end -lt $statements.Count -and $statements[$end].Extent.Text -notmatch '^\$launch\s*=') { $end++ }
if ($start -lt 0 -or $end -ge $statements.Count) { throw 'PUT/GET mapping boundary was not found' }
$preflight = [scriptblock]::Create(($statements[$start..($end - 1)].Extent.Text -join "`n"))

function Invoke-PutGetMockHdc {
    $script:mappingCalls.Add(($args -join ' '))
    if (($args -join ' ') -eq '-t unit-target fport ls') {
        $global:LASTEXITCODE = $script:mappingCase.exitCode
        return $script:mappingCase.output
    }
    if (($args -join ' ') -eq '-t unit-target rport ls') {
        $global:LASTEXITCODE = 0
        return '[Fail]Incorrect forward command'
    }
    if (($args -join ' ') -eq '-t unit-target rport tcp:24001 tcp:24001') {
        $script:mappingCreates++
        $global:LASTEXITCODE = 0
        return 'Forwardport result:OK'
    }
    throw 'Unexpected HDC operation in isolated PUT/GET test'
}

$cases = @(
    @{ name='existing reverse mapping'; output='unit-target tcp:24001 tcp:24001 [Reverse]'; exitCode=0; reject=$true }
    @{ name='existing forward port'; output='unit-target tcp:24001 tcp:1234 [Forward]'; exitCode=0; reject=$true }
    @{ name='explicit empty list'; output='[Empty]'; exitCode=0; reject=$false }
    @{ name='unrelated mapping'; output='unit-target tcp:25000 tcp:25000 [Reverse]'; exitCode=0; reject=$false }
    @{ name='failure text with zero exit'; output='[Fail]Incorrect forward command'; exitCode=0; reject=$true }
    @{ name='nonzero exit'; output='[Empty]'; exitCode=7; reject=$true }
    @{ name='no output'; output=''; exitCode=0; reject=$true }
    @{ name='whitespace output'; output=" `r`n "; exitCode=0; reject=$true }
    @{ name='failure after unrelated row'; output="unit-target tcp:25000 tcp:25000 [Reverse]`n[Fail]Device not founded or connected."; exitCode=0; reject=$true }
)
$results = @(foreach ($entry in $cases) {
    $script:mappingCase = $entry
    $script:mappingCalls = [Collections.Generic.List[string]]::new()
    $script:mappingCreates = 0
    $hdc = 'Invoke-PutGetMockHdc'
    $Target = 'unit-target'
    $FixturePort = 24001
    $reverseMapped = $false
    $failure = ''
    try { . $preflight } catch { $failure = $_.Exception.Message }
    $rejected = -not [string]::IsNullOrWhiteSpace($failure)
    $expectedCreates = if ($entry.reject) { 0 } else { 1 }
    $passed = ($rejected -eq $entry.reject -and $script:mappingCreates -eq $expectedCreates -and
        $reverseMapped -eq (-not $entry.reject) -and
        $script:mappingCalls[0] -eq '-t unit-target fport ls')
    [pscustomobject]@{ name=$entry.name; passed=$passed; rejected=$rejected;
        creates=$script:mappingCreates; ownsMapping=$reverseMapped; calls=@($script:mappingCalls); failure=$failure }
})
$failed = @($results | Where-Object { -not $_.passed })
$evidence = [pscustomobject]@{ schemaVersion=1; mode='offline'; releaseEligible=$false;
    sourceSha256=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant();
    result=$(if ($failed.Count -eq 0) { 'passed' } else { 'failed' }); cases=$results }
if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($EvidencePath),
        ($evidence | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}
$results | Select-Object name,passed,rejected,creates | Format-Table | Out-Host
$global:LASTEXITCODE = 0
if ($failed.Count -gt 0) { throw "$($failed.Count)/$($cases.Count) PUT/GET mapping preflight cases failed" }
Write-Host "PUT/GET mapping preflight: $($cases.Count) offline cases passed"
