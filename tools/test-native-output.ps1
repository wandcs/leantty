$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'formal-build-environment.ps1')
. (Join-Path $PSScriptRoot 'acceptance-source.ps1')
$outputTestRoot = Split-Path $PSScriptRoot -Parent
$outputTestTools = Resolve-LeanTTYDevEcoBuildTools
$outputTestTs = Join-Path $outputTestTools.root 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'
$outputTestPath = Join-Path $outputTestRoot 'entry/src/main/ets/model/terminal/NativeTerminalController.ets'
$outputTestHash = (Get-FileHash -LiteralPath $outputTestPath).Hash
Invoke-WithLeanTTYAcceptanceSource -RepoRoot $outputTestRoot -Enabled $true -Action {
    & $outputTestTools.node (Join-Path $PSScriptRoot 'test-native-terminal-controller.cjs') $outputTestTs output
    if ($LASTEXITCODE -ne 0) { throw 'Native full-output probe contracts failed' }
    $outputTestSource = [IO.File]::ReadAllText($outputTestPath)
    $outputTestImports = [regex]::Matches($outputTestSource, '(?m)^import\s')
    if ($outputTestImports[-1].Index -gt [regex]::Match($outputTestSource, '(?m)^const\s').Index) { throw 'Misplaced diagnostic import' }
}
try { Invoke-WithLeanTTYAcceptanceSource -RepoRoot $outputTestRoot -Enabled $true -Action { throw 'expected-output-test-failure' } }
catch { if ($_.Exception.Message -ne 'expected-output-test-failure') { throw } }
if ((Get-FileHash -LiteralPath $outputTestPath).Hash -ne $outputTestHash) { throw 'Native output source restoration failed' }
