param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'LeanTTY-build-workflow-test-' + [Guid]::NewGuid().ToString('N')
)

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Message
    )

    try {
        & $Action
    } catch {
        return
    }
    throw $Message
}

function Wait-ForPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateRange(1, 30)][int]$TimeoutSeconds = 5
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $Path)) {
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            throw "Timed out waiting for test signal: $Path"
        }
        Start-Sleep -Milliseconds 50
    }
}

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    $candidateScript = Join-Path $PSScriptRoot 'candidate-store.ps1'
    Assert-True (Test-Path -LiteralPath $candidateScript -PathType Leaf) (
        "Candidate store helper is missing: $candidateScript"
    )
    . $candidateScript
    $candidateScriptText = Get-Content -LiteralPath $candidateScript -Raw
    Assert-True (
        $candidateScriptText.Contains('diff --name-only $candidateCommit HEAD') -and
        -not $candidateScriptText.Contains('diff --name-only --diff-filter=')
    ) 'Candidate reuse comparison could omit deleted or otherwise changed product paths'

    $packagePolicyScript = Join-Path $PSScriptRoot 'package-policy.ps1'
    Assert-True (Test-Path -LiteralPath $packagePolicyScript -PathType Leaf) (
        "Package policy helper is missing: $packagePolicyScript"
    )
    . $packagePolicyScript

    $acceptanceSourceScript = Join-Path $PSScriptRoot 'acceptance-source.ps1'
    Assert-True (Test-Path -LiteralPath $acceptanceSourceScript -PathType Leaf) (
        "Acceptance source helper is missing: $acceptanceSourceScript"
    )
    . $acceptanceSourceScript
    $lfTarget = "first`nsecond`n"
    $lfResult = Set-LeanTTYAcceptanceSourceText `
        -Text $lfTarget `
        -Anchor "first`r`nsecond" `
        -Replacement "alpha`r`nbeta"
    Assert-True ($lfResult -ceq "alpha`nbeta`n") (
        'Acceptance source replacement did not normalize a CRLF anchor to an LF target'
    )
    $crlfTarget = "first`r`nsecond`r`n"
    $crlfResult = Set-LeanTTYAcceptanceSourceText `
        -Text $crlfTarget `
        -Anchor "first`nsecond" `
        -Replacement "alpha`nbeta"
    Assert-True ($crlfResult -ceq "alpha`r`nbeta`r`n") (
        'Acceptance source replacement did not normalize an LF anchor to a CRLF target'
    )
    $acceptanceArkTsPaths = @(
        Join-Path $repoRoot 'entry\src\main\ets\pages\Index.ets'
        Join-Path $repoRoot 'entry\src\main\ets\model\bridge\TerminalBridge.ets'
        Join-Path $repoRoot 'entry\src\main\ets\model\terminal\TerminalSurfaceController.ets'
        Join-Path $repoRoot 'entry\src\main\ets\viewmodel\SessionViewModel.ets'
        Join-Path $repoRoot 'entry\src\main\ets\model\transfer\TransferFileManager.ets'
        Join-Path $repoRoot 'entry\src\main\ets\model\transfer\FileTransferClient.ets'
    )
    $acceptanceSourceHashes = @{}
    foreach ($path in $acceptanceArkTsPaths) {
        $acceptanceSourceHashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    Invoke-WithLeanTTYAcceptanceSource -RepoRoot $repoRoot -Enabled $true -Action {
        $injectedText = $acceptanceArkTsPaths | ForEach-Object {
            Get-Content -LiteralPath $_ -Raw
        }
        Assert-True (($injectedText -join "`n").Contains('ACCEPTANCE_INPUT_SUBMIT')) (
            'Debug acceptance source injection omitted input telemetry'
        )
        Assert-True (($injectedText -join "`n").Contains('ACCEPTANCE_LOCAL_CLEANUP_FAILURE')) (
            'Debug acceptance source injection omitted local cleanup failure control'
        )
        Assert-True (($injectedText -join "`n").Contains('ACCEPTANCE_DOWNLOADS_NOREPLACE')) (
            'Debug acceptance source injection omitted the Downloads no-replace probe'
        )
        Assert-True (($injectedText -join "`n").Contains('ACCEPTANCE_DOWNLOADS_MANAGER')) (
            'Debug acceptance source injection omitted the production Downloads manager probe'
        )
        Assert-True (-not ($injectedText -join "`n").Contains('ACCEPTANCE_DOWNLOADS_FD')) (
            'Routine debug acceptance injection included the native-only Downloads FD probe'
        )
        Assert-True (($injectedText -join "`n").Contains('Acceptance: Rebuild Renderer')) (
            'Debug acceptance source injection omitted renderer trigger'
        )
        Assert-True (($injectedText -join "`n").Contains('Acceptance: Downloads No-Replace')) (
            'Debug acceptance source injection omitted the Downloads probe menu action'
        )
        Assert-True (($injectedText -join "`n").Contains('Acceptance: Downloads Manager Boundary')) (
            'Debug acceptance source injection omitted the Downloads manager boundary action'
        )
        Assert-True (($injectedText -join "`n").Contains('ACCEPTANCE_TRANSFER_FIXTURE')) (
            'Debug acceptance source injection omitted transfer fixture telemetry'
        )
        Assert-True (($injectedText -join "`n").Contains('force-put-source.bin')) (
            'Debug acceptance source injection omitted the force-termination PUT source'
        )
        Assert-True (($injectedText -join "`n").Contains('ACCEPTANCE_FILE_TRANSFER_LATE_EVENT')) (
            'Debug acceptance source injection omitted stale transfer event control'
        )
        Assert-True (($injectedText -join "`n").Contains(
                'ACCEPTANCE_FILE_TRANSFER_PREPARATION waiting=true'
            )) (
            'Debug acceptance source injection omitted the stalled preparation trigger'
        )
        Assert-True (($injectedText -join "`n").Contains('Acceptance: Transfer Fixture')) (
            'Debug acceptance source injection omitted the transfer fixture action'
        )
        Assert-True (-not ($injectedText -join "`n").Contains('Acceptance: Downloads FD Boundary')) (
            'Routine debug acceptance injection included the native-only Downloads FD menu action'
        )
        Assert-True (-not ($injectedText -join "`n").Contains('Debug Material')) (
            'Debug acceptance source injection must not restore the retired material comparator'
        )
        Assert-True (-not ($injectedText -join "`n").Contains('Acceptance: Open Search')) (
            'Debug acceptance source injection must reuse the production Search action'
        )
        Assert-True (($injectedText -join "`n").Contains('pasteClipboardForAcceptance')) (
            'Debug acceptance source injection omitted clipboard paste trigger'
        )
    }
    foreach ($path in $acceptanceArkTsPaths) {
        Assert-True (
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $acceptanceSourceHashes[$path]
        ) "Acceptance source injection did not restore $path byte-for-byte"
    }
    $nativeAcceptancePaths = @(
        Join-Path $repoRoot 'leantty_ssh\src\lib.rs'
        Join-Path $repoRoot 'entry\src\main\cpp\types\libleantty_ssh\index.d.ts'
    )
    $nativeAcceptanceHashes = @{}
    foreach ($path in $nativeAcceptancePaths) {
        $nativeAcceptanceHashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    Invoke-WithLeanTTYNativeAcceptanceSource -RepoRoot $repoRoot -Action {
        $nativeInjectedText = $nativeAcceptancePaths | ForEach-Object {
            Get-Content -LiteralPath $_ -Raw
        }
        Assert-True (($nativeInjectedText -join "`n").Contains('ssh_acceptance_probe_file_descriptor')) (
            'Debug native acceptance injection omitted the FD boundary probe'
        )
        Assert-True (($nativeInjectedText -join "`n").Contains(
                'ACCEPTANCE_LOCAL_TEMP_CLEANUP_FAILURE'
            )) (
            'Debug native acceptance injection omitted the local temporary cleanup failure control'
        )
        Assert-True (($nativeInjectedText -join "`n").Contains(
                'ACCEPTANCE_FILE_TRANSFER_DROPPED'
            )) (
            'Debug native acceptance injection omitted the transfer callback backpressure metric'
        )
        $borrowedFdImportCount = ([regex]::Matches(
                [IO.File]::ReadAllText((Join-Path $repoRoot 'leantty_ssh\src\lib.rs')),
                '(?m)^use std::os::fd::BorrowedFd;$'
            )).Count
        Assert-True ($borrowedFdImportCount -eq 1) (
            'Debug native acceptance injection duplicated the production BorrowedFd import'
        )
        Assert-True (($nativeInjectedText -join "`n").Contains(
                "): AcceptanceFileDescriptorProbeResult`nexport interface KnownHostsQueryResult"
            )) 'Debug native type injection merged adjacent declarations'
        Invoke-WithLeanTTYAcceptanceSource -RepoRoot $repoRoot -Enabled $true -Action {
            $fdInjectedText = $acceptanceArkTsPaths | ForEach-Object {
                Get-Content -LiteralPath $_ -Raw
            }
            Assert-True (($fdInjectedText -join "`n").Contains('ACCEPTANCE_DOWNLOADS_FD')) (
                'Native-backed acceptance injection omitted the Downloads FD boundary probe'
            )
            Assert-True (($fdInjectedText -join "`n").Contains('Acceptance: Downloads FD Boundary')) (
                'Native-backed acceptance injection omitted the Downloads FD menu action'
            )
            Assert-True (($fdInjectedText -join "`n").Contains('ACCEPTANCE_DOWNLOADS_MANAGER')) (
                'Native-backed acceptance injection omitted the production Downloads manager probe'
            )
        }
    }
    foreach ($path in $nativeAcceptancePaths) {
        Assert-True (
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $nativeAcceptanceHashes[$path]
        ) "Native acceptance source injection did not restore $path byte-for-byte"
    }

    Assert-LeanTTYHarnessOnlyPaths `
        -ChangedPaths @('tools/verify-ssh-auth-pc.ps1', 'docs/quality-strategy.md') `
        -AllowedPaths @('tools/verify-ssh-auth-pc.ps1', 'docs/*.md')
    Assert-Throws -Action {
        Assert-LeanTTYHarnessOnlyPaths `
            -ChangedPaths @('entry/src/main/ets/pages/Index.ets') `
            -AllowedPaths @('tools/verify-ssh-auth-pc.ps1', 'docs/*.md')
    } -Message 'Candidate reuse accepted a product-source change'

    $safeHap = Join-Path $testRoot 'safe-release.hap'
    $unsafeHap = Join-Path $testRoot 'unsafe-release.hap'
    foreach ($archiveCase in @(
        @{ path = $safeHap; content = 'ordinary release bytecode' },
        @{ path = $unsafeHap; content = 'ACCEPTANCE_INPUT_SUBMIT must not ship' }
    )) {
        $archiveStream = [IO.File]::Open($archiveCase.path, [IO.FileMode]::Create)
        try {
            $zip = [IO.Compression.ZipArchive]::new(
                $archiveStream,
                [IO.Compression.ZipArchiveMode]::Create,
                $false
            )
            try {
                $entry = $zip.CreateEntry('modules.abc')
                $entryStream = $entry.Open()
                try {
                    $bytes = [Text.Encoding]::UTF8.GetBytes($archiveCase.content)
                    $entryStream.Write($bytes, 0, $bytes.Length)
                } finally {
                    $entryStream.Dispose()
                }
            } finally {
                $zip.Dispose()
            }
        } finally {
            $archiveStream.Dispose()
        }
    }
    Assert-LeanTTYReleasePackageExcludesAcceptanceMarkers -PackagePath $safeHap
    Assert-Throws -Action {
        Assert-LeanTTYReleasePackageExcludesAcceptanceMarkers -PackagePath $unsafeHap
    } -Message 'Release package policy accepted an acceptance-only marker'

    $candidateBase = Join-Path $testRoot 'candidates'
    $latestSource = $null
    for ($index = 1; $index -le 7; $index++) {
        $source = Join-Path $testRoot "candidate-$index.hap"
        [IO.File]::WriteAllText(
            $source,
            "candidate-$index",
            [Text.UTF8Encoding]::new($false)
        )
        Save-LeanTTYVerifiedCandidate `
            -RepoRoot $repoRoot `
            -HapPath $source `
            -VerificationMode 'software' `
            -CandidateBasePath $candidateBase | Out-Null
        $latestSource = $source
        Start-Sleep -Milliseconds 10
    }

    $candidateRoot = Get-LeanTTYCandidateRoot `
        -RepoRoot $repoRoot `
        -CandidateBasePath $candidateBase
    $candidateDirectories = @(
        Get-ChildItem -LiteralPath $candidateRoot -Directory |
            Where-Object { $_.Name -match '^[0-9a-f]{64}$' }
    )
    Assert-True ($candidateDirectories.Count -eq 5) (
        "Expected exactly 5 retained candidates, found $($candidateDirectories.Count)"
    )

    $latestCandidate = Get-LeanTTYLatestVerifiedCandidate `
        -RepoRoot $repoRoot `
        -CandidateBasePath $candidateBase
    Assert-True ($null -ne $latestCandidate) 'Latest candidate was not returned'
    Assert-True (
        (Get-FileHash -LiteralPath $latestCandidate.hapPath -Algorithm SHA256).Hash -eq
        (Get-FileHash -LiteralPath $latestSource -Algorithm SHA256).Hash
    ) 'Latest candidate does not match the newest verified package'

    $behaviorEvidence = Join-Path $testRoot 'device-key-passphrase.json'
    [IO.File]::WriteAllText(
        $behaviorEvidence,
        '{"schemaVersion":1,"scenario":"ssh-keygen-passphrase","result":"passed"}',
        [Text.UTF8Encoding]::new($false)
    )
    Save-LeanTTYVerifiedCandidate `
        -RepoRoot $repoRoot `
        -HapPath $latestCandidate.hapPath `
        -VerificationMode 'device-behavior' `
        -EvidencePaths @($behaviorEvidence) `
        -CandidateBasePath $candidateBase | Out-Null
    $behaviorCandidate = Get-LeanTTYLatestVerifiedCandidate `
        -RepoRoot $repoRoot `
        -CandidateBasePath $candidateBase
    Assert-True ($behaviorCandidate.verificationMode -eq 'device-behavior') (
        'Device behavior evidence did not promote the retained candidate'
    )
    Assert-True ($behaviorCandidate.evidenceFiles.Count -eq 1) (
        'Device behavior evidence was not retained with the candidate'
    )
    Save-LeanTTYVerifiedCandidate `
        -RepoRoot $repoRoot `
        -HapPath $latestCandidate.hapPath `
        -VerificationMode 'software' `
        -CandidateBasePath $candidateBase | Out-Null
    $nonDowngradedCandidate = Get-LeanTTYLatestVerifiedCandidate `
        -RepoRoot $repoRoot `
        -CandidateBasePath $candidateBase
    Assert-True ($nonDowngradedCandidate.verificationMode -eq 'device-behavior') (
        'A later software-only save downgraded device behavior evidence'
    )

    $legacyManifestPath = Join-Path $candidateDirectories[0].FullName 'manifest.json'
    $legacyManifest = Get-Content -LiteralPath $legacyManifestPath -Raw | ConvertFrom-Json
    $legacyManifest.schemaVersion = 1
    $legacyManifest.verificationMode = 'device'
    $legacyManifest.PSObject.Properties.Remove('evidenceFiles')
    [IO.File]::WriteAllText(
        $legacyManifestPath,
        (ConvertTo-Json -InputObject $legacyManifest -Depth 4),
        [Text.UTF8Encoding]::new($false)
    )
    $legacyRecord = @(Get-LeanTTYCandidateRecords -CandidateRoot $candidateRoot |
        Where-Object { $_.manifestPath -eq $legacyManifestPath })
    Assert-True ($legacyRecord.Count -eq 1 -and
        $legacyRecord[0].verificationMode -eq 'device-deployed') (
        'Legacy device candidate mode was not normalized to device-deployed'
    )

    $wslScript = Join-Path $PSScriptRoot 'rust-wsl.ps1'
    . $wslScript
    Assert-True (
        (ConvertTo-LeanTTYWslPath -WindowsPath 'C:\src\project') -eq '/mnt/c/src/project'
    ) 'WSL repository path conversion is incorrect'
    Assert-True (
        (ConvertTo-LeanTTYWslPath -WindowsPath 'D:\SDK\native sysroot') -eq
        '/mnt/d/SDK/native sysroot'
    ) 'WSL path conversion did not preserve spaces'
    $mappedCargoPath = ConvertFrom-LeanTTYWslPathWithinRoot `
        -WslRoot '/home/test/.cargo' `
        -WindowsRoot '\\wsl.localhost\Ubuntu-26.04\home\test\.cargo' `
        -WslPath '/home/test/.cargo/registry/src/index.example/russh-0.62.5/Cargo.toml'
    Assert-True (
        $mappedCargoPath -eq
        '\\wsl.localhost\Ubuntu-26.04\home\test\.cargo\registry\src\index.example\russh-0.62.5\Cargo.toml'
    ) 'WSL Cargo path conversion did not preserve the path within Cargo home'
    Assert-Throws -Action {
        ConvertFrom-LeanTTYWslPathWithinRoot `
            -WslRoot '/home/test/.cargo' `
            -WindowsRoot '\\wsl.localhost\Ubuntu-26.04\home\test\.cargo' `
            -WslPath '/home/test/.cargo-foreign/registry/Cargo.toml'
    } -Message 'WSL Cargo path conversion accepted a path outside Cargo home'

    $devBuildText = Get-Content -LiteralPath (
        Join-Path $PSScriptRoot 'dev-build.ps1'
    ) -Raw
    Assert-True (
        $devBuildText.Contains('Invoke-WithLeanTTYBuildLock')
    ) 'dev-build.ps1 is not protected by the repository build lock'

    $devPcText = Get-Content -LiteralPath (
        Join-Path $PSScriptRoot 'dev-pc.ps1'
    ) -Raw
    Assert-True (
        $devPcText.Contains(". (Join-Path `$PSScriptRoot 'device-regression.ps1')") -and
        $devPcText.Contains('Start-LeanTTYRegressionApp') -and
        $devPcText.Contains('Get-LeanTTYDeviceUnlockPasswordPath')
    ) 'dev-pc.ps1 does not use the conditional regression-PC unlock flow'

    $verifyPcText = Get-Content -LiteralPath (
        Join-Path $PSScriptRoot 'verify-pc.ps1'
    ) -Raw
    Assert-True (
        $verifyPcText.Contains('[IO.Path]::GetTempPath()') -and
        -not $verifyPcText.Contains("Join-Path `$repoRoot 'build\verification'") -and
        $verifyPcText.Contains('verify-pc evidence directory must be outside the repository') -and
        $verifyPcText.Contains('$evidenceDirectoryFullPath.StartsWith(')
    ) 'verify-pc evidence would be deleted by its own clean build'
    Assert-True (
        $verifyPcText.Contains("'oh-package-lock.json5'") -and
        $verifyPcText.Contains("'entry/oh-package-lock.json5'") -and
        $verifyPcText.Contains('[IO.File]::ReadAllBytes($fullPath)') -and
        $verifyPcText.Contains('git -C $repoRoot hash-object -- $relativePath') -and
        $verifyPcText.Contains('[IO.File]::WriteAllBytes(') -and
        $verifyPcText.Contains('verify-pc build changed the committed formal-release candidate')
    ) 'verify-pc does not preserve generated OHPM lockfiles while rejecting content drift'

    $buildAllText = Get-Content -LiteralPath (
        Join-Path $PSScriptRoot 'build-all.ps1'
    ) -Raw
    Assert-True (
        $buildAllText.Contains('Assert-LeanTTYReleasePackageExcludesAcceptanceMarkers') -and
        $buildAllText.Contains("if (`$BuildMode -eq 'release')") -and
        $buildAllText.Contains('Invoke-WithLeanTTYAcceptanceSource')
    ) 'Formal release build does not reject acceptance-only package markers'
    Assert-True (
        $buildAllText.Contains("tools\ohpm\bin\ohpm.bat") -and
        $buildAllText.Contains('& $ohpm install --all --lockfile_stable_order') -and
        $buildAllText.Contains("entry\oh_modules\libleantty_ssh.so")
    ) 'Clean release build does not restore required OHPM dependencies'
    $projectBuildProfileText = Get-Content -LiteralPath (
        Join-Path $repoRoot 'build-profile.json5'
    ) -Raw
    Assert-True (
        $projectBuildProfileText.Contains('"x86_64/**"') -and
        -not (Test-Path -LiteralPath (Join-Path $repoRoot 'entry\libs\x86_64'))
    ) 'Project packaging no longer excludes the unsupported x86_64 native ABI'
    $arm64AbiGuard = '$nativeAbis.Count -ne 1 -or $nativeAbis[0] -ne ''arm64-v8a'''
    Assert-True (
        ([regex]::Matches(
            $buildAllText,
            [regex]::Escape($arm64AbiGuard)
        )).Count -ge 2 -and
        $buildAllText.Contains("entry\libs\arm64-v8a\libleantty_ssh.so") -and
        $buildAllText.Contains("abi = 'arm64-v8a'") -and
        $buildAllText.Contains("'--filter-platform', 'aarch64-unknown-linux-ohos'")
    ) 'Release packaging no longer enforces one ARM64 ABI across HAP, APP and metadata'
    Assert-True (
        $buildAllText.Contains("'THIRD_PARTY_NOTICES.md' =") -and
        $buildAllText.Contains('Unable to resolve locked ARM64 Rust dependencies for release notices') -and
        $buildAllText.Contains('Invoke-LeanTTYRustWsl') -and
        -not $buildAllText.Contains('& cargo metadata --locked --offline')
    ) 'Release artifacts no longer require locked dependency license notices'
    Assert-True (
        Test-Path -LiteralPath (Join-Path $PSScriptRoot 'test-acceptance-harness.ps1') -PathType Leaf
    ) 'Focused acceptance-harness regression command is missing'

    $workerPath = Join-Path $testRoot 'lock-worker.ps1'
    $workerSource = @'
param(
    [Parameter(Mandatory = $true)][string]$BuildLockScript,
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$AcquiredPath,
    [string]$ReleasePath
)
$ErrorActionPreference = 'Stop'
. $BuildLockScript
Invoke-WithLeanTTYBuildLock -RepoRoot $RepoRoot -Operation 'workflow-test' -Action {
    [IO.File]::WriteAllText($AcquiredPath, (Get-Date).ToString('o'))
    if ($ReleasePath) {
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $ReleasePath)) {
            if ($stopwatch.Elapsed.TotalSeconds -ge 5) {
                throw "Timed out waiting for release signal: $ReleasePath"
            }
            Start-Sleep -Milliseconds 50
        }
    }
}
'@
    [IO.File]::WriteAllText(
        $workerPath,
        $workerSource,
        [Text.UTF8Encoding]::new($false)
    )

    $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $firstAcquired = Join-Path $testRoot 'first-acquired'
    $secondAcquired = Join-Path $testRoot 'second-acquired'
    $releaseFirst = Join-Path $testRoot 'release-first'
    $firstProcess = Start-Process -FilePath $pwsh -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile',
        '-File', $workerPath,
        '-BuildLockScript', (Join-Path $PSScriptRoot 'build-lock.ps1'),
        '-RepoRoot', $repoRoot,
        '-AcquiredPath', $firstAcquired,
        '-ReleasePath', $releaseFirst
    )
    Wait-ForPath -Path $firstAcquired

    $secondProcess = Start-Process -FilePath $pwsh -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile',
        '-File', $workerPath,
        '-BuildLockScript', (Join-Path $PSScriptRoot 'build-lock.ps1'),
        '-RepoRoot', $repoRoot,
        '-AcquiredPath', $secondAcquired
    )
    Start-Sleep -Milliseconds 500
    Assert-True (-not (Test-Path -LiteralPath $secondAcquired)) (
        'Second build writer acquired the lock while the first still held it'
    )

    [IO.File]::WriteAllText($releaseFirst, 'release')
    Wait-ForPath -Path $secondAcquired
    [void]$firstProcess.WaitForExit(5000)
    [void]$secondProcess.WaitForExit(5000)
    Assert-True ($firstProcess.ExitCode -eq 0) 'First build-lock worker failed'
    Assert-True ($secondProcess.ExitCode -eq 0) 'Second build-lock worker failed'

    Write-Host 'Build workflow regression tests passed.' -ForegroundColor Green
} finally {
    $testRootFull = [IO.Path]::GetFullPath($testRoot)
    if ($testRootFull.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $testRootFull)) {
        Remove-Item -LiteralPath $testRootFull -Recurse -Force
    }
}
