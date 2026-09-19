$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native-terminal-inputs.ps1')
. (Join-Path $PSScriptRoot 'formal-build-environment.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('LeanTTY-native-inputs-' + [guid]::NewGuid().ToString('N'))
function Assert-Input([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-InputThrows([scriptblock]$Action, [string]$Message) {
    try { & $Action } catch { return }
    throw $Message
}
try {
    New-Item -ItemType Directory -Force -Path "$root/build/native-terminal/dist" | Out-Null
    $zipPath = "$root/build/native-terminal/dist/source.zip"
    $zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in @('source/build.zig', 'source/allocator.zig')) {
            $writer = [IO.StreamWriter]::new($zip.CreateEntry($name).Open())
            try { $writer.Write('original') } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose() }
    $hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash
    $archive = Get-LeanTTYNativeArchive -RepoRoot $root -Name source.zip -Url 'https://invalid.example' -Sha256 $hash -Offline
    $buildPath = [IO.Path]::GetFullPath("$root/build")
    Assert-Input ($buildPath.StartsWith([IO.Path]::GetFullPath($root) + [IO.Path]::DirectorySeparatorChar)) 'Unsafe test cleanup'
    Remove-Item -LiteralPath $buildPath -Recurse -Force
    Assert-Input ((Get-LeanTTYNativeArchive -RepoRoot $root -Name source.zip -Url 'https://invalid.example' -Sha256 $hash -Offline) -eq $archive) 'Clean erased offline inputs'
    Assert-InputThrows { Get-LeanTTYNativeArchive -RepoRoot $root -Name missing.zip -Url 'https://invalid.example' -Sha256 ('0'*64) -Offline } 'Offline missing input accepted'
    $out = "$root/build/generated"
    Sync-LeanTTYPinnedZip -Archive $archive -Destination $out -Overrides @{ 'source/build.zig' = 'current-overlay' }
    [IO.File]::WriteAllText("$out/source/allocator.zig", 'stale-diagnostic')
    Sync-LeanTTYPinnedZip -Archive $archive -Destination $out -Overrides @{ 'source/build.zig' = 'next-overlay' }
    Assert-Input ([IO.File]::ReadAllText("$out/source/allocator.zig") -ceq 'original') 'Cached source drift survived'
    Assert-Input ([IO.File]::ReadAllText("$out/source/build.zig") -ceq 'next-overlay') 'Previous overlay survived'
    Sync-LeanTTYPinnedZip -Archive $archive -Destination $out
    Assert-Input ([IO.File]::ReadAllText("$out/source/build.zig") -ceq 'original') 'Overlay rollback failed'
    $stamp = (Get-Item "$out/source/build.zig").LastWriteTimeUtc
    Sync-LeanTTYPinnedZip -Archive $archive -Destination $out
    Assert-Input ((Get-Item "$out/source/build.zig").LastWriteTimeUtc -eq $stamp) 'Unchanged files were rewritten'
    [IO.File]::AppendAllText($archive, 'corrupt')
    Assert-InputThrows { Get-LeanTTYNativeArchive -RepoRoot $root -Name source.zip -Url 'https://invalid.example' -Sha256 $hash -Offline } 'Corrupt cached archive accepted'

    $badZip = "$root/escape.zip"
    $zip = [IO.Compression.ZipFile]::Open($badZip, [IO.Compression.ZipArchiveMode]::Create)
    try { $zip.CreateEntry('../escape.txt').Open().Dispose() } finally { $zip.Dispose() }
    Assert-InputThrows { Sync-LeanTTYPinnedZip -Archive $badZip -Destination "$root/safe" } 'Archive traversal accepted'

    $devEco = "$root/DevEco Studio"
    $sdk = "$devEco/sdk/default/openharmony"
    foreach ($part in @('native','ets')) {
        New-Item -ItemType Directory -Force -Path "$sdk/$part" | Out-Null
        '{"apiVersion":"24","version":"6.1.1.test"}' | Set-Content "$sdk/$part/oh-uni-package.json"
    }
    $resolved = Resolve-LeanTTYHarmonySdk -DevEcoHome $devEco -NativeHome ''
    Assert-Input ($resolved.native -eq [IO.Path]::GetFullPath("$sdk/native")) 'SDK requires machine-specific alias'
    $override = Resolve-LeanTTYHarmonySdk -DevEcoHome "$root/unused" -NativeHome "$sdk/native"
    Assert-Input ($override.sdkHome -eq $resolved.sdkHome) 'SDK override split the pipeline'
    '{"apiVersion":"23","version":"older"}' | Set-Content "$sdk/ets/oh-uni-package.json"
    Assert-InputThrows { Resolve-LeanTTYHarmonySdk -DevEcoHome $devEco -NativeHome '' } 'Mixed SDK accepted'
    Write-Host 'PASS native inputs: clean/offline, missing/corrupt archive, source repair, overlay update/rollback, unchanged timestamps, path containment and coherent SDK'
} finally {
    $absolute = [IO.Path]::GetFullPath($root)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $absolute.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test root' }
    if (Test-Path -LiteralPath $absolute) { Remove-Item -LiteralPath $absolute -Recurse -Force }
}
