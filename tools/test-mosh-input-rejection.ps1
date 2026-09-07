param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'build-lock.ps1')
. (Join-Path $PSScriptRoot 'acceptance-source.ps1')
. (Join-Path $PSScriptRoot 'rust-wsl.ps1')

# Compile the same native transformation used by the dedicated test HAP.
# Always restore original source/types; no test helper is left in product code.
Invoke-WithLeanTTYBuildLock -RepoRoot $repoRoot -Operation 'test-mosh-input-rejection' -Action {
    $paths = @('leantty_ssh/src/lib.rs', 'entry/src/main/cpp/types/libleantty_ssh/index.d.ts')
    $hashes = @{}
    foreach ($path in $paths) { $hashes[$path] = (Get-FileHash (Join-Path $repoRoot $path)).Hash }
    try {
        Invoke-WithLeanTTYNativeAcceptanceSource -RepoRoot $repoRoot -MoshInputRejectionOnly -Action {
            Invoke-LeanTTYRustWsl -RepoRoot (Join-Path $repoRoot 'leantty_ssh') `
                -CargoArguments @('test', '--offline', '--lib', 'mosh_input_acceptance', '--', '--nocapture')
            if ($LASTEXITCODE -ne 0) { throw 'Mosh native input-rejection trigger tests failed' }
        }
    } finally {
        foreach ($path in $paths) {
            if ((Get-FileHash (Join-Path $repoRoot $path)).Hash -cne $hashes[$path]) {
                throw "Native input-rejection source was not restored: $path"
            }
        }
    }
}
