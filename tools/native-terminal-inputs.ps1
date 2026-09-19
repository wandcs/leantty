# Fixed download inputs survive a clean build. Expanded files are reconciled
# against the verified archive on every use, including the Zig standard library.
function Get-LeanTTYNativeArchive {
    param([string]$RepoRoot, [string]$Name, [string]$Url, [string]$Sha256, [switch]$Offline)
    $directory = Join-Path $RepoRoot '.cache/native-terminal'
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $archive = Join-Path $directory ($Sha256 + '-' + $Name)
    if (-not (Test-Path -LiteralPath $archive)) {
        $legacy = Join-Path $RepoRoot ('build/native-terminal/dist/' + $Name)
        if ((Test-Path -LiteralPath $legacy) -and
            (Get-FileHash -LiteralPath $legacy -Algorithm SHA256).Hash -ieq $Sha256) {
            Copy-Item -LiteralPath $legacy -Destination $archive
        } elseif ($Offline) {
            throw "Missing pinned archive: $Name. Run prepare-formal-build-inputs.ps1 first."
        } else {
            $partial = $archive + '.partial'
            try {
                Invoke-WebRequest -Uri $Url -OutFile $partial
                if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ine $Sha256) {
                    throw "Pinned archive digest mismatch: $Name"
                }
                Move-Item -LiteralPath $partial -Destination $archive -Force
            } finally {
                if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
            }
        }
    }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $Sha256) {
        throw "Pinned archive digest mismatch: $Name"
    }
    return $archive
}

function Read-LeanTTYPinnedZipText {
    param([string]$Archive, [string]$Entry)
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $member = $zip.GetEntry($Entry)
        if ($null -eq $member) { throw "Pinned ZIP entry missing: $Entry" }
        $reader = [IO.StreamReader]::new($member.Open())
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
}

function Sync-LeanTTYPinnedZip {
    param([string]$Archive, [string]$Destination, [hashtable]$Overrides = @{})
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $restored = 0
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    $checkedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($member in $zip.Entries) {
            if ($member.FullName.EndsWith('/')) { continue }
            $path = [IO.Path]::GetFullPath((Join-Path $root $member.FullName))
            if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Pinned ZIP entry escapes destination: $($member.FullName)"
            }
            # Never follow a local junction or symlink while restoring build inputs.
            $ancestor = $path
            while ($ancestor.Length -ge $root.TrimEnd('\', '/').Length) {
                if (-not $checkedPaths.Add($ancestor)) { break }
                if (([IO.File]::Exists($ancestor) -or [IO.Directory]::Exists($ancestor)) -and
                    ([IO.File]::GetAttributes($ancestor) -band [IO.FileAttributes]::ReparsePoint)) {
                    throw "Pinned input contains a reparse point: $ancestor"
                }
                $ancestor = [IO.Path]::GetDirectoryName($ancestor)
            }
            $stream = if ($Overrides.ContainsKey($member.FullName)) {
                [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes([string]$Overrides[$member.FullName]))
            } else { $member.Open() }
            try {
                $bytes = [IO.MemoryStream]::new()
                try {
                    $stream.CopyTo($bytes)
                    $expected = $bytes.ToArray()
                } finally { $bytes.Dispose() }
            } finally { $stream.Dispose() }
            $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($expected))
            if ([IO.File]::Exists($path)) {
                $file = [IO.File]::OpenRead($path)
                try { $actualHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($file)) }
                finally { $file.Dispose() }
                if ($actualHash -ceq $hash) { continue }
            }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
            [IO.File]::WriteAllBytes($path, $expected)
            $restored++
        }
    } finally { $zip.Dispose() }
    Write-Host ("Pinned inputs checked: {0}; restored={1}; seconds={2:N1}" -f
        [IO.Path]::GetFileName($Archive), $restored, $timer.Elapsed.TotalSeconds)
}
