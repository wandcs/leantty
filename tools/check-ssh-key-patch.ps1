[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$patchRoot = Join-Path $repoRoot 'third-party/ssh-key'
$provenance = Get-Content -LiteralPath (Join-Path $patchRoot 'provenance.json') -Raw |
    ConvertFrom-Json -AsHashtable
$crateRoot = Join-Path $patchRoot ('ssh-key-' + $provenance.version)
$expected = $provenance.upstreamFiles
foreach ($path in $provenance.patchedFiles.Keys) {
    if (-not $expected.ContainsKey($path)) { throw "Patch adds undeclared upstream file: $path" }
    $expected[$path] = $provenance.patchedFiles[$path]
}
$actual = @(Get-ChildItem -LiteralPath $crateRoot -Recurse -File -Force)
if ($actual.Count -ne $expected.Count) { throw 'ssh-key package file inventory changed' }
foreach ($file in $actual) {
    $relative = [IO.Path]::GetRelativePath($crateRoot, $file.FullName).Replace('\', '/')
    if (-not $expected.ContainsKey($relative) -or
        (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $expected[$relative]) {
        throw "ssh-key source drift: $relative; follow third-party/ssh-key/README.md"
    }
}
if ((Get-FileHash -LiteralPath (Join-Path $patchRoot 'positive-scalar.patch') -Algorithm SHA256).Hash -ne
    $provenance.patchSha256) { throw 'ssh-key patch diff changed without provenance update' }
$manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'leantty_ssh/Cargo.toml') -Raw
$override = 'ssh-key = { path = "../third-party/ssh-key/ssh-key-' + $provenance.version + '" }'
if (-not $manifest.Contains("[patch.crates-io]`n$override") -and
    -not $manifest.Contains("[patch.crates-io]`r`n$override")) {
    throw 'ssh-key patch override changed; review upgrade or remove patch checks explicitly'
}
$lock = Get-Content -LiteralPath (Join-Path $repoRoot 'leantty_ssh/Cargo.lock') -Raw
$entries = @([regex]::Matches($lock, '(?ms)^\[\[package\]\]\r?\nname = "ssh-key"\r?\n.*?(?=^\[|\z)'))
if ($entries.Count -ne 1 -or
    $entries[0].Value -notmatch ('(?m)^version = "' + [regex]::Escape($provenance.version) + '"\r?$') -or
    $entries[0].Value -match '(?m)^(source|checksum) =') {
    throw 'Cargo no longer resolves only the local ssh-key patch; review the dependency upgrade'
}
Write-Host "ssh-key patch provenance passed ($($actual.Count) files, one local dependency)."
