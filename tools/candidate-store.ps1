function Get-LeanTTYHashIdentity {
    param([Parameter(Mandatory = $true)][string]$Value)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))
    } finally {
        $sha256.Dispose()
    }
    return ([BitConverter]::ToString($digest).Replace('-', '')).ToLowerInvariant()
}

function Get-LeanTTYCandidateRoot {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$CandidateBasePath = ''
    )

    $commonDirectoryOutput = @(
        & git -C $RepoRoot rev-parse --git-common-dir 2>&1
    )
    if ($LASTEXITCODE -ne 0 -or $commonDirectoryOutput.Count -ne 1) {
        throw 'Unable to resolve the Git common directory for candidate storage'
    }
    $commonDirectory = [string]$commonDirectoryOutput[0]
    if (-not [IO.Path]::IsPathRooted($commonDirectory)) {
        $commonDirectory = Join-Path $RepoRoot $commonDirectory
    }
    $repositoryIdentity = Get-LeanTTYHashIdentity -Value (
        [IO.Path]::GetFullPath($commonDirectory).TrimEnd('\').ToUpperInvariant()
    )

    if ([string]::IsNullOrWhiteSpace($CandidateBasePath)) {
        $localAppData = [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::LocalApplicationData
        )
        if ([string]::IsNullOrWhiteSpace($localAppData)) {
            throw 'Local application data directory is unavailable'
        }
        $CandidateBasePath = Join-Path $localAppData 'LeanTTY\verified-candidates'
    }

    return Join-Path ([IO.Path]::GetFullPath($CandidateBasePath)) $repositoryIdentity
}

function Get-LeanTTYCandidateRecords {
    param([Parameter(Mandatory = $true)][string]$CandidateRoot)

    if (-not (Test-Path -LiteralPath $CandidateRoot -PathType Container)) {
        return @()
    }

    $records = @()
    foreach ($directory in @(
        Get-ChildItem -LiteralPath $CandidateRoot -Directory |
            Where-Object { $_.Name -match '^[0-9a-f]{64}$' }
    )) {
        $manifestPath = Join-Path $directory.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "Candidate manifest is missing: $manifestPath"
        }
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw |
                ConvertFrom-Json
            $schemaVersion = [int]$manifest.schemaVersion
            if ($schemaVersion -notin @(1, 2)) {
                throw 'Unsupported schema version'
            }
            $manifestHash = [string]$manifest.sha256
            if ($manifestHash -notmatch '^[0-9a-f]{64}$' -or
                $manifestHash -ne $directory.Name) {
                throw 'Candidate hash identity mismatch'
            }
            $hapFile = [string]$manifest.hapFile
            if ($hapFile -ne 'LeanTTY-test-signed.hap') {
                throw 'Unexpected candidate HAP name'
            }
            $verificationMode = [string]$manifest.verificationMode
            if ($verificationMode -eq 'device') {
                $verificationMode = 'device-deployed'
            }
            if ($verificationMode -notin @('software', 'device-deployed', 'device-behavior')) {
                throw 'Unexpected candidate verification mode'
            }
            $evidenceFiles = @()
            if ($schemaVersion -ge 2 -and $null -ne $manifest.evidenceFiles) {
                foreach ($evidenceFile in @($manifest.evidenceFiles)) {
                    $evidenceName = [string]$evidenceFile
                    if ($evidenceName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.json$') {
                        throw 'Unexpected candidate evidence file name'
                    }
                    $evidencePath = Assert-LeanTTYCandidatePath `
                        -CandidateRoot $CandidateRoot `
                        -Path (Join-Path $directory.FullName (Join-Path 'evidence' $evidenceName))
                    if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
                        throw "Candidate evidence is missing: $evidencePath"
                    }
                    $evidenceFiles += $evidencePath
                }
            }
            $verifiedAtValue = $manifest.verifiedAt
            if ($verifiedAtValue -is [DateTimeOffset]) {
                $verifiedAt = $verifiedAtValue
            } elseif ($verifiedAtValue -is [DateTime]) {
                $verifiedAt = [DateTimeOffset]::new($verifiedAtValue)
            } else {
                $verifiedAt = [DateTimeOffset]::Parse(
                    [string]$verifiedAtValue,
                    [Globalization.CultureInfo]::InvariantCulture
                )
            }
        } catch {
            throw "Candidate manifest is invalid: $manifestPath"
        }
        $records += [pscustomobject]@{
            directory = $directory.FullName
            manifestPath = $manifestPath
            hapPath = Assert-LeanTTYCandidatePath `
                -CandidateRoot $CandidateRoot `
                -Path (Join-Path $directory.FullName $hapFile)
            sha256 = $manifestHash
            verifiedAt = $verifiedAt
            verificationMode = $verificationMode
            gitCommit = [string]$manifest.git.commit
            gitTree = [string]$manifest.git.tree
            gitDirty = [bool]$manifest.git.dirty
            evidenceFiles = @($evidenceFiles)
        }
    }

    return @(
        $records | Sort-Object `
            @{ Expression = 'verifiedAt'; Descending = $true },
            @{ Expression = 'sha256'; Descending = $true }
    )
}

function Assert-LeanTTYCandidatePath {
    param(
        [Parameter(Mandatory = $true)][string]$CandidateRoot,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $rootPrefix = [IO.Path]::GetFullPath($CandidateRoot).TrimEnd('\') + '\'
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Candidate path is outside the managed root: $fullPath"
    }
    return $fullPath
}

function Assert-LeanTTYHarnessOnlyPaths {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ChangedPaths,
        [Parameter(Mandatory = $true)][string[]]$AllowedPaths
    )

    foreach ($changedPath in @($ChangedPaths)) {
        $normalized = ([string]$changedPath).Replace('\', '/').TrimStart('./')
        if ([string]::IsNullOrWhiteSpace($normalized)) { continue }
        $allowed = $false
        foreach ($allowedPath in $AllowedPaths) {
            $pattern = ([string]$allowedPath).Replace('\', '/').TrimStart('./')
            if ($normalized -like $pattern) {
                $allowed = $true
                break
            }
        }
        if (-not $allowed) {
            throw "Retained candidate cannot be reused after product input changed: $normalized"
        }
    }
}

function Assert-LeanTTYCandidateHarnessCompatibility {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][object]$Candidate,
        [Parameter(Mandatory = $true)][string[]]$AllowedHarnessPaths
    )

    $candidateCommit = [string]$Candidate.gitCommit
    if ($candidateCommit -notmatch '^[0-9a-f]{40}$') {
        throw 'Retained candidate has no valid source commit identity'
    }
    & git -C $RepoRoot merge-base --is-ancestor $candidateCommit HEAD 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Retained candidate source is not an ancestor of the current harness'
    }
    $changedPaths = @(& git -C $RepoRoot diff --name-only $candidateCommit HEAD 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to compare retained candidate and harness source'
    }
    Assert-LeanTTYHarnessOnlyPaths `
        -ChangedPaths $changedPaths `
        -AllowedPaths $AllowedHarnessPaths
    return @($changedPaths)
}

function Save-LeanTTYVerifiedCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$HapPath,
        [Parameter(Mandatory = $true)]
        [ValidateSet('software', 'device-deployed', 'device-behavior')]
        [string]$VerificationMode,
        [string[]]$EvidencePaths = @(),
        [string]$CandidateBasePath = ''
    )

    $sourceHap = [IO.Path]::GetFullPath($HapPath)
    if (-not (Test-Path -LiteralPath $sourceHap -PathType Leaf)) {
        throw "Verified candidate HAP is missing: $sourceHap"
    }
    if ([IO.Path]::GetExtension($sourceHap) -ne '.hap' -or
        (Split-Path $sourceHap -Leaf) -match '(?i)unsigned') {
        throw "Verified candidate must be a signed HAP: $sourceHap"
    }

    $candidateRoot = Get-LeanTTYCandidateRoot `
        -RepoRoot $RepoRoot `
        -CandidateBasePath $CandidateBasePath
    New-Item -ItemType Directory -Path $candidateRoot -Force | Out-Null

    $hapHash = (
        Get-FileHash -LiteralPath $sourceHap -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $candidateDirectory = Assert-LeanTTYCandidatePath `
        -CandidateRoot $candidateRoot `
        -Path (Join-Path $candidateRoot $hapHash)
    $candidateHapName = 'LeanTTY-test-signed.hap'
    $candidateHap = Join-Path $candidateDirectory $candidateHapName
    $manifestPath = Join-Path $candidateDirectory 'manifest.json'

    $modeRank = @{
        software = 1
        'device-deployed' = 2
        'device-behavior' = 3
    }
    $existingManifest = $null
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $existingManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $existingMode = [string]$existingManifest.verificationMode
        if ($existingMode -eq 'device') { $existingMode = 'device-deployed' }
        if ($modeRank.ContainsKey($existingMode) -and
            $modeRank[$existingMode] -gt $modeRank[$VerificationMode]) {
            $VerificationMode = $existingMode
        }
    }

    $gitCommit = (& git -C $RepoRoot rev-parse HEAD 2>&1).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve candidate Git commit' }
    $gitTree = (& git -C $RepoRoot rev-parse 'HEAD^{tree}' 2>&1).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve candidate Git tree' }
    $gitStatus = @(git -C $RepoRoot status --porcelain --untracked-files=all 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve candidate Git dirty state' }

    $manifestEvidenceFiles = [Collections.Generic.List[string]]::new()
    if ($null -ne $existingManifest -and $null -ne $existingManifest.evidenceFiles) {
        foreach ($existingEvidence in @($existingManifest.evidenceFiles)) {
            $manifestEvidenceFiles.Add([string]$existingEvidence)
        }
    }
    foreach ($evidencePath in @($EvidencePaths)) {
        $resolvedEvidence = [IO.Path]::GetFullPath($evidencePath)
        if (-not (Test-Path -LiteralPath $resolvedEvidence -PathType Leaf)) {
            throw "Candidate evidence file is missing: $resolvedEvidence"
        }
        if ([IO.Path]::GetExtension($resolvedEvidence) -ne '.json') {
            throw "Candidate evidence must be JSON: $resolvedEvidence"
        }
        $evidenceName = Split-Path $resolvedEvidence -Leaf
        if ($evidenceName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.json$') {
            throw "Candidate evidence file name is unsafe: $evidenceName"
        }
        if (-not $manifestEvidenceFiles.Contains($evidenceName)) {
            $manifestEvidenceFiles.Add($evidenceName)
        }
    }

    $gitManifest = if ($null -ne $existingManifest) {
        [ordered]@{
            commit = [string]$existingManifest.git.commit
            tree = [string]$existingManifest.git.tree
            dirty = [bool]$existingManifest.git.dirty
        }
    } else {
        [ordered]@{
            commit = $gitCommit
            tree = $gitTree
            dirty = ($gitStatus.Count -gt 0)
        }
    }

    $manifest = [ordered]@{
        schemaVersion = 2
        verifiedAt = [DateTimeOffset]::UtcNow.ToString('o')
        verificationMode = $VerificationMode
        hapFile = $candidateHapName
        sha256 = $hapHash
        size = (Get-Item -LiteralPath $sourceHap).Length
        git = $gitManifest
        evidenceFiles = @($manifestEvidenceFiles)
    }

    $temporaryDirectory = Assert-LeanTTYCandidatePath `
        -CandidateRoot $candidateRoot `
        -Path (Join-Path $candidateRoot ('.tmp-' + [Guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
    try {
        $temporaryHap = Join-Path $temporaryDirectory $candidateHapName
        $temporaryManifest = Join-Path $temporaryDirectory 'manifest.json'
        Copy-Item -LiteralPath $sourceHap -Destination $temporaryHap
        if ($manifestEvidenceFiles.Count -gt 0) {
            $temporaryEvidenceDirectory = Join-Path $temporaryDirectory 'evidence'
            New-Item -ItemType Directory -Path $temporaryEvidenceDirectory -Force | Out-Null
            if ($null -ne $existingManifest) {
                $existingEvidenceDirectory = Join-Path $candidateDirectory 'evidence'
                foreach ($existingEvidence in @($existingManifest.evidenceFiles)) {
                    $existingEvidencePath = Join-Path $existingEvidenceDirectory ([string]$existingEvidence)
                    if (Test-Path -LiteralPath $existingEvidencePath -PathType Leaf) {
                        Copy-Item -LiteralPath $existingEvidencePath -Destination $temporaryEvidenceDirectory
                    }
                }
            }
            foreach ($evidencePath in @($EvidencePaths)) {
                Copy-Item -LiteralPath ([IO.Path]::GetFullPath($evidencePath)) `
                    -Destination $temporaryEvidenceDirectory -Force
            }
        }
        [IO.File]::WriteAllText(
            $temporaryManifest,
            (ConvertTo-Json -InputObject $manifest -Depth 4),
            [Text.UTF8Encoding]::new($false)
        )

        if (Test-Path -LiteralPath $candidateDirectory -PathType Container) {
            Copy-Item -LiteralPath $temporaryHap -Destination $candidateHap -Force
            Copy-Item -LiteralPath $temporaryManifest -Destination $manifestPath -Force
            $temporaryEvidenceDirectory = Join-Path $temporaryDirectory 'evidence'
            if (Test-Path -LiteralPath $temporaryEvidenceDirectory -PathType Container) {
                $candidateEvidenceDirectory = Join-Path $candidateDirectory 'evidence'
                New-Item -ItemType Directory -Path $candidateEvidenceDirectory -Force | Out-Null
                Get-ChildItem -LiteralPath $temporaryEvidenceDirectory -File | ForEach-Object {
                    Copy-Item -LiteralPath $_.FullName -Destination $candidateEvidenceDirectory -Force
                }
            }
        } else {
            Move-Item -LiteralPath $temporaryDirectory -Destination $candidateDirectory
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryDirectory) {
            Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
        }
    }
    [IO.Directory]::SetLastWriteTimeUtc($candidateDirectory, [DateTime]::UtcNow)

    $records = @(Get-LeanTTYCandidateRecords -CandidateRoot $candidateRoot)
    foreach ($expiredCandidate in @($records | Select-Object -Skip 5)) {
        $expiredPath = Assert-LeanTTYCandidatePath `
            -CandidateRoot $candidateRoot `
            -Path $expiredCandidate.directory
        Remove-Item -LiteralPath $expiredPath -Recurse -Force
    }

    return Get-LeanTTYLatestVerifiedCandidate `
        -RepoRoot $RepoRoot `
        -CandidateBasePath $CandidateBasePath
}

function Get-LeanTTYLatestVerifiedCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$CandidateBasePath = ''
    )

    $candidateRoot = Get-LeanTTYCandidateRoot `
        -RepoRoot $RepoRoot `
        -CandidateBasePath $CandidateBasePath
    $latest = @(
        Get-LeanTTYCandidateRecords -CandidateRoot $candidateRoot
    ) | Select-Object -First 1
    if ($null -eq $latest) {
        return $null
    }
    if (-not (Test-Path -LiteralPath $latest.hapPath -PathType Leaf)) {
        throw "Candidate HAP is missing: $($latest.hapPath)"
    }
    $actualHash = (
        Get-FileHash -LiteralPath $latest.hapPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    if ($actualHash -ne $latest.sha256) {
        throw "Candidate HAP hash mismatch: $($latest.hapPath)"
    }
    return $latest
}

function Resolve-LeanTTYRetainedCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$HapPath = '',
        [string]$CandidateBasePath = ''
    )

    $candidateRoot = Get-LeanTTYCandidateRoot `
        -RepoRoot $RepoRoot `
        -CandidateBasePath $CandidateBasePath
    $records = @(Get-LeanTTYCandidateRecords -CandidateRoot $candidateRoot)
    if ([string]::IsNullOrWhiteSpace($HapPath)) {
        $candidate = $records | Select-Object -First 1
    } else {
        $resolvedHap = [IO.Path]::GetFullPath($HapPath)
        if (-not (Test-Path -LiteralPath $resolvedHap -PathType Leaf)) {
            throw "Candidate HAP is missing: $resolvedHap"
        }
        $requestedHash = (
            Get-FileHash -LiteralPath $resolvedHap -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        $candidate = $records |
            Where-Object { $_.sha256 -eq $requestedHash } |
            Select-Object -First 1
    }
    if ($null -eq $candidate) {
        throw 'No matching retained candidate exists; run tools/verify-pc.ps1 first'
    }
    return $candidate
}
