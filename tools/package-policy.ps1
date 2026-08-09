function Assert-LeanTTYReleasePackageExcludesAcceptanceMarkers {
    param(
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [string[]]$Markers = @(
            'ACCEPTANCE_INPUT_SUBMIT',
            'ACCEPTANCE_DOWNLOADS_NOREPLACE',
            'ACCEPTANCE_DOWNLOADS_FD',
            'Acceptance: Rebuild Renderer',
            'Acceptance: Downloads No-Replace',
            'Acceptance: Downloads FD Boundary',
            'Acceptance renderer',
            'terminateRendererForAcceptance',
            'runDownloadsNoReplaceProbeForAcceptance',
            'runDownloadsFileDescriptorProbeForAcceptance',
            'ssh_acceptance_probe_file_descriptor',
            'pasteClipboardForAcceptance',
            'logAcceptanceInputSubmit',
            'acceptanceInputSequence'
        )
    )

    $resolvedPackage = [IO.Path]::GetFullPath($PackagePath)
    if (-not (Test-Path -LiteralPath $resolvedPackage -PathType Leaf)) {
        throw "Release package is missing: $resolvedPackage"
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($resolvedPackage)
    try {
        foreach ($entry in $archive.Entries) {
            if ($entry.Length -eq 0) { continue }
            $stream = $entry.Open()
            try {
                $memory = [IO.MemoryStream]::new()
                try {
                    $stream.CopyTo($memory)
                    $bytes = $memory.ToArray()
                } finally {
                    $memory.Dispose()
                }
            } finally {
                $stream.Dispose()
            }
            $singleByteText = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
            $utf16Text = [Text.Encoding]::Unicode.GetString($bytes)
            foreach ($marker in $Markers) {
                if ($singleByteText.IndexOf($marker, [StringComparison]::Ordinal) -ge 0 -or
                    $utf16Text.IndexOf($marker, [StringComparison]::Ordinal) -ge 0) {
                    throw "Release package contains acceptance-only marker '$marker' in $($entry.FullName)"
                }
            }
        }
    } finally {
        $archive.Dispose()
    }
}
