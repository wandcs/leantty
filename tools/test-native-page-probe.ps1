param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'acceptance-source.ps1')
$pageTestRoot = Split-Path $PSScriptRoot -Parent
$pageTestPin = Get-Content (Join-Path $PSScriptRoot 'native-terminal/dependencies.json') -Raw | ConvertFrom-Json
$pageTestBuild = Join-Path $pageTestRoot 'build/native-terminal'
$pageTestZig = Join-Path $pageTestBuild ("zig-x86_64-windows-$($pageTestPin.zigVersion)/zig.exe")
$pageTestInclude = Join-Path $pageTestBuild ("ghostty-$($pageTestPin.ghosttyCommit)/include")
$pageTestLib = Join-Path $pageTestBuild 'x86_64-windows-gnu/lib/libghostty-vt.a'
if (-not (Test-Path -LiteralPath $pageTestLib)) { throw 'Run build-terminal-native.ps1 -Offline -HostTests to prepare the pinned host VT first' }
$pageTestCpp = Join-Path $pageTestRoot 'entry/src/main/cpp/terminal'
$pageTestExe = Join-Path $pageTestBuild 'x86_64-windows-gnu/terminal-page-probe-tests.exe'
$pageTestPaths = @('TerminalRuntime.h','TerminalRuntime.cpp') | ForEach-Object { Join-Path $pageTestCpp $_ }
$pageTestHashes = @{}; foreach ($p in $pageTestPaths) { $pageTestHashes[$p] = (Get-FileHash $p).Hash }
Invoke-WithLeanTTYNativeDisplayAcceptanceSource -RepoRoot $pageTestRoot -Enabled $true -Action {
    & $pageTestZig c++ -std=c++17 -DGHOSTTY_STATIC -O1 -Wall -Wextra -Werror "-I$pageTestInclude" "-I$pageTestCpp" `
        (Join-Path $pageTestCpp 'TerminalRuntime.cpp') (Join-Path $pageTestCpp 'TerminalInteraction.cpp') `
        (Join-Path $pageTestCpp 'TerminalEffects.cpp') (Join-Path $PSScriptRoot 'native-terminal/page-probe-test.cpp') `
        $pageTestLib -o $pageTestExe
    if ($LASTEXITCODE -ne 0) { throw 'Native page probe test compilation failed' }
    & $pageTestExe
    if ($LASTEXITCODE -ne 0) { throw 'Native page probe worker contract failed' }
}
foreach ($p in $pageTestPaths) { if ((Get-FileHash $p).Hash -ne $pageTestHashes[$p]) { throw 'Native page source was not restored' } }
. (Join-Path $PSScriptRoot 'formal-build-environment.ps1')
$pageTestTools = Resolve-LeanTTYDevEcoBuildTools
$pageTestTs = Join-Path $pageTestTools.root 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'
Invoke-WithLeanTTYAcceptanceSource -RepoRoot $pageTestRoot -Enabled $true -Action {
    & $pageTestTools.node (Join-Path $PSScriptRoot 'test-native-terminal-controller.cjs') $pageTestTs page
    if ($LASTEXITCODE -ne 0) { throw 'Native page controller observation contracts failed' }
}
