$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'formal-build-environment.ps1')
. (Join-Path $PSScriptRoot 'startup-performance-source.ps1')
. (Join-Path $PSScriptRoot 'startup-warm-source.ps1')
$startupTestRoot = Split-Path $PSScriptRoot -Parent
$startupTestTools = Resolve-LeanTTYDevEcoBuildTools
$startupTestTs = Join-Path $startupTestTools.root 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'
$startupTestController = Join-Path $startupTestRoot 'entry/src/main/ets/model/terminal/NativeTerminalController.ets'
$startupTestHash = (Get-FileHash -LiteralPath $startupTestController).Hash
foreach ($startupTestMode in @('cold', 'warm')) {
    $startupTestWrapper = if ($startupTestMode -eq 'cold') { 'Invoke-WithLeanTTYStartupPerformanceSource' } else { 'Invoke-WithLeanTTYStartupWarmSource' }
    & $startupTestWrapper -RepoRoot $startupTestRoot -Action {
        & $startupTestTools.node (Join-Path $PSScriptRoot 'test-native-terminal-controller.cjs') $startupTestTs $startupTestMode
        if ($LASTEXITCODE -ne 0) { throw "Native startup $startupTestMode contracts failed" }
        Invoke-WithLeanTTYAcceptanceSource -RepoRoot $startupTestRoot -Enabled $true -Action {
            & $startupTestTools.node (Join-Path $PSScriptRoot 'test-native-terminal-controller.cjs') $startupTestTs $startupTestMode
            if ($LASTEXITCODE -ne 0) { throw "Nested startup/acceptance $startupTestMode contracts failed" }
            $startupTestSource = [IO.File]::ReadAllText($startupTestController)
            $startupTestImports = [regex]::Matches($startupTestSource, '(?m)^import\s')
            $startupTestDeclaration = [regex]::Match($startupTestSource, '(?m)^const\s')
            if ($startupTestImports[-1].Index -gt $startupTestDeclaration.Index) { throw 'Nested startup/acceptance imports are misplaced' }
        }
    }
    if ((Get-FileHash -LiteralPath $startupTestController).Hash -ne $startupTestHash) { throw 'Startup source restore failed' }
    try { & $startupTestWrapper -RepoRoot $startupTestRoot -Action { throw 'expected-startup-test-failure' } }
    catch { if ($_.Exception.Message -ne 'expected-startup-test-failure') { throw } }
    if ((Get-FileHash -LiteralPath $startupTestController).Hash -ne $startupTestHash) { throw 'Failed startup action did not restore source' }
}
Write-Host 'Native cold/warm startup execution, nested imports and source restoration passed'
