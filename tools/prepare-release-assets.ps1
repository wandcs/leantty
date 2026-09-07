param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-tooling.ps1')

function New-LeanTTYReleaseAssets {
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^\d+\.\d+\.\d+$')]
        [string]$ReleaseId,
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string]$ReleaseDirectory,
        [Parameter(Mandatory = $true)][string]$AppGalleryCopyPath
    )

    $checkoutFull = [IO.Path]::GetFullPath($Checkout)
    $releaseDirectoryFull = [IO.Path]::GetFullPath($ReleaseDirectory)
    $packageDirectory = Join-Path $releaseDirectoryFull 'package'
    $evidenceDirectory = Join-Path $releaseDirectoryFull 'evidence'
    $manifestPath = Join-Path $packageDirectory 'build-manifest.json'
    $appPath = Join-Path $packageDirectory "LeanTTY-$ReleaseId-arm64-v8a-signed.app"
    $licenseDirectory = Join-Path $checkoutFull 'build\outputs\release\licenses'
    $changelogPath = Join-Path $checkoutFull 'CHANGELOG.md'
    $copyPath = [IO.Path]::GetFullPath($AppGalleryCopyPath)
    foreach ($requiredFile in @($manifestPath, $appPath, $changelogPath, $copyPath)) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "Release asset input is missing: $requiredFile"
        }
    }
    if (-not (Test-Path -LiteralPath $licenseDirectory -PathType Container)) {
        throw "Release license directory is missing: $licenseDirectory"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ([string]$manifest.releaseId -ne $ReleaseId -or
        [string]$manifest.app.versionName -ne $ReleaseId -or
        [string]$manifest.buildMode -ne 'release') {
        throw 'Release asset manifest does not identify the requested release-mode build'
    }
    $appHash = (Get-FileHash -LiteralPath $appPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($appHash -ne ([string]$manifest.signedApp.sha256).ToLowerInvariant()) {
        throw 'AppGallery APP hash does not match the archived build manifest'
    }

    $changelog = Get-Content -LiteralPath $changelogPath -Raw
    $headingPattern = '(?m)^## \[' + [regex]::Escape($ReleaseId) + '\] - (?<date>\d{4}-\d{2}-\d{2})\s*$'
    $heading = [regex]::Match($changelog, $headingPattern)
    if (-not $heading.Success) {
        throw "CHANGELOG must contain a dated $ReleaseId section before release assets are prepared"
    }
    $sectionStart = $heading.Index + $heading.Length
    $nextHeading = [regex]::Match($changelog.Substring($sectionStart), '(?m)^## \[')
    $sectionLength = if ($nextHeading.Success) { $nextHeading.Index } else { $changelog.Length - $sectionStart }
    $section = $changelog.Substring($sectionStart, $sectionLength).Trim()
    if ([string]::IsNullOrWhiteSpace($section)) { throw "CHANGELOG $ReleaseId section is empty" }

    $storeCopy = Get-Content -LiteralPath $copyPath -Raw
    if ($storeCopy -notmatch ('(?<!\d)' + [regex]::Escape($ReleaseId) + '(?!\d)') -or
        $storeCopy -match '(?i)\b(?:TODO|TBD|PLACEHOLDER)\b|待补|占位') {
        throw 'AppGallery copy must name the release and contain no placeholder text'
    }

    New-Item -ItemType Directory -Path $packageDirectory, $evidenceDirectory -Force | Out-Null
    $licenseZip = Join-Path $packageDirectory "LeanTTY-$ReleaseId-licenses.zip"
    $releaseNotesPath = Join-Path $evidenceDirectory 'GITHUB-RELEASE-NOTES.md'
    $archivedStoreCopy = Join-Path $evidenceDirectory 'APPGALLERY-UPDATE.md'
    $handoffPath = Join-Path $evidenceDirectory 'APPGALLERY-HANDOFF.md'
    $attachmentsPath = Join-Path $evidenceDirectory 'ATTACHMENTS.md'
    foreach ($target in @($licenseZip, $releaseNotesPath, $archivedStoreCopy, $handoffPath, $attachmentsPath)) {
        if (Test-Path -LiteralPath $target) { throw "Refusing to overwrite release asset: $target" }
    }

    $archiveTimestamp = [DateTimeOffset]::ParseExact(
        $heading.Groups['date'].Value + 'T00:00:00Z',
        'yyyy-MM-ddTHH:mm:ssZ',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal
    )
    if ($env:SOURCE_DATE_EPOCH -match '^[0-9]+$') {
        $archiveTimestamp = [DateTimeOffset]::FromUnixTimeSeconds([long]$env:SOURCE_DATE_EPOCH)
    } elseif ($null -ne $manifest.git -and
        -not [string]::IsNullOrWhiteSpace([string]$manifest.git.commit)) {
        $commitTimestampOutput = @(
            & git -C $checkoutFull show -s --format=%ct ([string]$manifest.git.commit) 2>&1
        )
        if ($LASTEXITCODE -eq 0 -and $commitTimestampOutput.Count -eq 1 -and
            [string]$commitTimestampOutput[0] -match '^[0-9]+$') {
            $archiveTimestamp = [DateTimeOffset]::FromUnixTimeSeconds(
                [long]$commitTimestampOutput[0]
            )
        }
    }
    New-LeanTTYDeterministicZip `
        -SourceDirectory $licenseDirectory `
        -DestinationPath $licenseZip `
        -Timestamp $archiveTimestamp
    Write-LeanTTYAtomicText -Path $releaseNotesPath -Content ("# LeanTTY $ReleaseId`n`n$section`n")
    Write-LeanTTYAtomicText -Path $archivedStoreCopy -Content ($storeCopy.TrimEnd() + "`n")
    $handoff = @"
# LeanTTY $ReleaseId AppGallery handoff

- Upload only LeanTTY-$ReleaseId-arm64-v8a-signed.app.
- SHA-256: $appHash
- Confirm the filename and SHA-256 before upload.
- Use APPGALLERY-UPDATE.md and the reviewed screenshots/video for this exact version.
- Do not install the production release-Profile HAP with HDC.
- After submission, report `Submitted`, `In review`, `Rejected`, or `Released`; automation must not infer the state.
"@
    Write-LeanTTYAtomicText -Path $handoffPath -Content ($handoff.TrimEnd() + "`n")

    $attachmentFiles = @(
        Get-ChildItem -LiteralPath $packageDirectory -File
        Get-ChildItem -LiteralPath $evidenceDirectory -File |
            Where-Object { $_.FullName -ne $attachmentsPath }
    ) | Sort-Object FullName
    $attachmentLines = @('# Release attachments', '')
    foreach ($file in $attachmentFiles) {
        $relative = [IO.Path]::GetRelativePath($releaseDirectoryFull, $file.FullName).Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $attachmentLines += ('- {0} — {1}' -f $relative, $hash)
    }
    Write-LeanTTYAtomicText -Path $attachmentsPath -Content (($attachmentLines -join "`n") + "`n")

    return [pscustomobject][ordered]@{
        releaseId = $ReleaseId
        licenses = $licenseZip
        releaseNotes = $releaseNotesPath
        appGalleryCopy = $archivedStoreCopy
        handoff = $handoffPath
        attachments = $attachmentsPath
    }
}
