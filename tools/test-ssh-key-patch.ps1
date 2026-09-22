$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('leantty-patch-test-' + [guid]::NewGuid().ToString('N'))
try {
    foreach ($directory in @('tools', 'leantty_ssh', 'third-party')) {
        New-Item -ItemType Directory -Path (Join-Path $fixture $directory) -Force | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $repoRoot 'third-party/ssh-key') -Destination (Join-Path $fixture 'third-party') -Recurse
    foreach ($path in @('tools/check-ssh-key-patch.ps1', 'leantty_ssh/Cargo.toml', 'leantty_ssh/Cargo.lock')) {
        Copy-Item -LiteralPath (Join-Path $repoRoot $path) -Destination (Join-Path $fixture $path)
    }
    $check = Join-Path $fixture 'tools/check-ssh-key-patch.ps1'
    & $check
    foreach ($relative in @(
        'third-party/ssh-key/ssh-key-0.7.0-rc.11/src/private/ecdsa.rs',
        'third-party/ssh-key/ssh-key-0.7.0-rc.11/src/lib.rs',
        'third-party/ssh-key/positive-scalar.patch',
        'leantty_ssh/Cargo.lock'
    )) {
        $path = Join-Path $fixture $relative
        $original = [IO.File]::ReadAllBytes($path)
        try {
            if ($relative.EndsWith('Cargo.lock')) {
                $text = [IO.File]::ReadAllText($path).Replace('name = "ssh-key"', 'name = "ssh-key-retired"')
                [IO.File]::WriteAllText($path, $text)
            } else { [IO.File]::AppendAllText($path, '// drift') }
            $rejected = $false
            try { & $check } catch { $rejected = $true }
            if (-not $rejected) { throw "Patch guard accepted source/resolution drift: $relative" }
        } finally { [IO.File]::WriteAllBytes($path, $original) }
    }
    # Run the real native source hash with only the relevant optional input set.
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'build-native.ps1'), [ref]$null, [ref]$null)
    $function = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-SourceHash'
    }, $true)
    if ($null -eq $function) { throw 'Native source hash function missing' }
    & {
        . ([scriptblock]::Create($function.Extent.Text))
        $nativeBuildIdentity = 'test'
        $cargoManifest = $cargoLock = $buildScript = $coreManifest = $toolchainToml = $cargoConfig =
            $rustWslScript = $clangWslWrapper = $arWslWrapper = Join-Path $fixture 'absent'
        $rustSrcDir = $coreSrcDir = Join-Path $fixture 'absent'
        $sshKeyProvenance = Join-Path $fixture 'third-party/ssh-key/provenance.json'
        $before = Get-SourceHash
        [IO.File]::AppendAllText($sshKeyProvenance, ' ')
        if ((Get-SourceHash) -eq $before) { throw 'Native build ignored changed patch provenance' }
    }
    Write-Host 'ssh-key patch guards passed: source/diff/lock drift rejected; native cache invalidated.'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($prefix) -or (Split-Path $resolved -Leaf) -notlike 'leantty-patch-test-*') {
        throw 'Unsafe patch test cleanup path'
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
