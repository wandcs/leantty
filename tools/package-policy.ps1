function Assert-LeanTTYReleasePackageExcludesAcceptanceMarkers {
    param(
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [string[]]$Markers = @(
            'CHECKPOINT_DIAG',
            'LTTY_PERF_PING_',
            'LTTY_PERF_BEGIN__:',
            'LTTY_PERF_END__:',
            'observePerfInput',
            'observePerfOutput',
            'reportPerfResult',
            'perfRender',
            'ACCEPTANCE_INPUT_SUBMIT',
            'ACCEPTANCE_INPUT_NATIVE',
            'acceptanceInputMetrics',
            'acceptanceInputOrder',
            'acceptanceInputAttribution',
            'acceptanceInputSynthetic',
            'ACCEPTANCE_INPUT_ORDER',
            'ACCEPTANCE_OBSERVER_',
            'acceptanceObserverQuiet',
            '__acceptance_input_trace_',
            '__acceptance_input_probe',
            'ACCEPTANCE_DOWNLOADS_NOREPLACE',
            'ACCEPTANCE_DOWNLOADS_FD',
            'ACCEPTANCE_STARTUP_PREP',
            'ACCEPTANCE_BACKGROUND_BELL',
            'ACCEPTANCE_NOTIFICATION_SETTINGS',
            'ACCEPTANCE_TERMINAL_FINGERPRINT',
            'ACCEPTANCE_RUNTIME_RECLAIM',
            'ACCEPTANCE_RUNTIME_RECOVERY',
            'ACCEPTANCE_MOSH_INPUT_REJECTION',
            'mosh_arm_input_rejection_for_acceptance',
            'moshArmInputRejectionForAcceptance',
            'armMoshInputRejectionForAcceptance',
            'acceptance_reject_input',
            'acceptanceRejectMoshInput',
            'reclaimRuntimeForAcceptance',
            'reclaimRuntimeStateForAcceptance',
            'localInputUnitsForAcceptance',
            'runtimeWorkspaceIdentityForAcceptance',
            'observeRuntimeRecoveryForAcceptance',
            'acceptanceRuntimeWorkspace',
            'ACCEPTANCE_SEARCH_RESULT',
            'acceptanceTerminalFingerprint',
            'acceptanceSearchResult',
            'STARTUP_PERF phase=',
            'STARTUP_WARM phase=',
            "KIND_STARTUP_PERF: string = 'startupPerf'",
            'Acceptance: Rebuild Renderer',
            'Acceptance: Downloads No-Replace',
            'Acceptance: Downloads FD Boundary',
            'Acceptance: Background BEL',
            'Acceptance: Notification Settings',
            'Acceptance renderer',
            'terminateRendererForAcceptance',
            'runDownloadsNoReplaceProbeForAcceptance',
            'runDownloadsFileDescriptorProbeForAcceptance',
            'ssh_acceptance_probe_file_descriptor',
            'pasteClipboardForAcceptance',
            'logAcceptanceInputSubmit',
            'acceptanceInputSequence',
            'captureTerminalFingerprintForAcceptance'
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
