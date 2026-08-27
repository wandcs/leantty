<#
.SYNOPSIS
  Build, compare and archive one immutable LeanTTY AppGallery candidate.
.DESCRIPTION
  Run this script from a detached, clean production release checkout. It
  performs the formal release preflight, builds and verifies the production
  APP/HAP, optionally builds a separate review HAP with a different test
  Profile, compares both builds, and archives only explicitly named artifacts.

  Production signing materials stay outside the checkout. This script never
  installs the production HAP: an AppGallery release Profile is not a trusted
  HDC installation source. Use the optional review checkout for device
  acceptance, screenshots and self-test video.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$ReleaseId,

    [Parameter(Mandatory = $true)]
    [string]$ReleaseRoot,

    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedCommit,

    [string]$ReviewCheckout,

    [Parameter(Mandatory = $true)]
    [string]$AppGalleryCopyPath,

    [switch]$SkipBuild,

    [switch]$SkipProductionBuild,

    [switch]$SkipReviewBuild
)

$ErrorActionPreference = 'Stop'
$productionCheckout = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'build-lock.ps1')
. (Join-Path $PSScriptRoot 'prepare-release-assets.ps1')
$productionBuildScript = Join-Path $PSScriptRoot 'build-all.ps1'
$releaseRootFull = [IO.Path]::GetFullPath($ReleaseRoot)
$releaseDirectory = Join-Path $releaseRootFull "releases\$ReleaseId"
$packageDirectory = Join-Path $releaseDirectory 'package'
$evidenceDirectory = Join-Path $releaseDirectory 'evidence'
$productionPrefix = [IO.Path]::GetFullPath($productionCheckout).TrimEnd('\') + '\'
$appGalleryCopyFull = [IO.Path]::GetFullPath($AppGalleryCopyPath)
if (-not $appGalleryCopyFull.StartsWith(
        $productionPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'AppGallery copy must be a reviewed file inside the production checkout'
}
$appGalleryCopyRelative = $appGalleryCopyFull.Substring($productionPrefix.Length).Replace('\', '/')
& git -C $productionCheckout ls-files --error-unmatch -- $appGalleryCopyRelative 2>$null |
    Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "AppGallery copy must be tracked by the release commit: $appGalleryCopyRelative"
}

function Get-PathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $rootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $candidate = [IO.Path]::GetFullPath(
        (Join-Path $Root ($RelativePath.Replace('/', '\')))
    )
    if (-not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Manifest path escapes its checkout: $RelativePath"
    }
    return $candidate
}

function Invoke-ReleasePreflight {
    param([Parameter(Mandatory = $true)][string]$Checkout)

    $buildScript = Join-Path $Checkout 'tools\build-all.ps1'
    if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) {
        throw "Release build script missing: $buildScript"
    }
    $result = & $buildScript -BuildMode release -Metadata -PreflightOnly `
        -ReleaseId $ReleaseId
    if ($null -eq $result) {
        throw "Release preflight returned no identity: $Checkout"
    }
    return $result
}

function Invoke-FormalBuild {
    param([Parameter(Mandatory = $true)][string]$Checkout)

    $buildScript = Join-Path $Checkout 'tools\build-all.ps1'
    & $buildScript -Clean -BuildMode release -Metadata -ReleaseId $ReleaseId
}

function Get-VerifiedManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string]$ExpectedGitCommit
    )

    $manifestPath = Join-Path $Checkout 'build\outputs\metadata\build-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Build manifest missing: $manifestPath"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ([int]$manifest.schemaVersion -lt 3) {
        throw "Build manifest schema is too old: $($manifest.schemaVersion)"
    }
    if ($manifest.releaseId -ne $ReleaseId -or
        $manifest.app.versionName -ne $ReleaseId) {
        throw "Build manifest version mismatch: $manifestPath"
    }
    if ($manifest.git.commit -ne $ExpectedGitCommit) {
        throw "Build manifest commit mismatch: $manifestPath"
    }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.git.tree)) {
        throw "Build manifest tree is missing: $manifestPath"
    }
    if ([bool]$manifest.git.dirty) {
        throw "Build manifest records a dirty checkout: $manifestPath"
    }
    if ($manifest.buildMode -ne 'release' -or $manifest.abi -ne 'arm64-v8a') {
        throw "Build manifest mode or ABI mismatch: $manifestPath"
    }
    foreach ($verification in @(
        $manifest.signatureVerification.hap,
        $manifest.signatureVerification.app
    )) {
        if ($null -eq $verification -or
            -not [bool]$verification.digestVerified -or
            -not [bool]$verification.verifyAppSuccess) {
            throw "Build manifest does not record successful signature verification: $manifestPath"
        }
    }

    foreach ($artifactProperty in @('signedApp', 'signedHap', 'nativeSo')) {
        $artifact = $manifest.$artifactProperty
        if ($null -eq $artifact -or [string]::IsNullOrWhiteSpace([string]$artifact.path)) {
            throw "Build manifest is missing '$artifactProperty': $manifestPath"
        }
        $artifactPath = Get-PathWithinRoot -Root $Checkout -RelativePath $artifact.path
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
            throw "Manifest artifact missing: $artifactPath"
        }
        $actualHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash
        if ($actualHash -ne $artifact.sha256) {
            throw "Manifest artifact hash mismatch: $artifactPath"
        }
    }

    return [pscustomobject]@{
        Path = $manifestPath
        Data = $manifest
        SignedApp = Get-PathWithinRoot -Root $Checkout -RelativePath $manifest.signedApp.path
        SignedHap = Get-PathWithinRoot -Root $Checkout -RelativePath $manifest.signedHap.path
        HapCertificate = Get-PathWithinRoot -Root $Checkout `
            -RelativePath $manifest.signatureVerification.hap.certificateChain
        HapProfile = Get-PathWithinRoot -Root $Checkout `
            -RelativePath $manifest.signatureVerification.hap.profile
        AppCertificate = Get-PathWithinRoot -Root $Checkout `
            -RelativePath $manifest.signatureVerification.app.certificateChain
        AppProfile = Get-PathWithinRoot -Root $Checkout `
            -RelativePath $manifest.signatureVerification.app.profile
    }
}

function Assert-ArchiveTargetsAbsent {
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $existing = @($Paths | Where-Object { Test-Path -LiteralPath $_ })
    if ($existing.Count -gt 0) {
        throw "Refusing to overwrite archived release evidence:`n$($existing -join "`n")"
    }
}

function Copy-CheckedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Copy-Item -LiteralPath $Source -Destination $Destination
    $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    $destinationHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    if ($sourceHash -ne $destinationHash) {
        throw "Archived file hash mismatch: $Destination"
    }
}

Invoke-WithLeanTTYBuildLock -RepoRoot $productionCheckout `
    -Operation "prepare AppGallery release $ReleaseId" -Action {
if (-not (Test-Path -LiteralPath $productionBuildScript -PathType Leaf)) {
    throw "Production build script missing: $productionBuildScript"
}
$productionPrefix = [IO.Path]::GetFullPath($productionCheckout).TrimEnd('\') + '\'
if ($releaseRootFull.StartsWith($productionPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ReleaseRoot must stay outside the production checkout'
}

$productionIdentity = Invoke-ReleasePreflight -Checkout $productionCheckout
if ($ExpectedCommit -and $productionIdentity.commit -ne $ExpectedCommit.ToLowerInvariant()) {
    throw "Production checkout is not at ExpectedCommit $ExpectedCommit"
}
$releaseCommit = [string]$productionIdentity.commit
$reviewIdentity = $null
$reviewCheckoutFull = $null
if ($ReviewCheckout) {
    $reviewCheckoutFull = [IO.Path]::GetFullPath($ReviewCheckout)
    if ($reviewCheckoutFull -eq [IO.Path]::GetFullPath($productionCheckout)) {
        throw 'ReviewCheckout must be independent from the production checkout'
    }
    $reviewIdentity = Invoke-ReleasePreflight -Checkout $reviewCheckoutFull
    if ($reviewIdentity.commit -ne $releaseCommit -or
        $reviewIdentity.tree -ne $productionIdentity.tree) {
        throw 'Production and review checkouts do not identify the same commit and tree'
    }
    if ($reviewIdentity.signingProfileSha256 -eq $productionIdentity.signingProfileSha256) {
        throw 'Review checkout must use a different test Profile from production'
    }
}

if ($SkipBuild) {
    $SkipProductionBuild = $true
    $SkipReviewBuild = $true
}
if ($SkipReviewBuild -and -not $reviewCheckoutFull) {
    throw '-SkipReviewBuild requires -ReviewCheckout'
}
if (-not $SkipProductionBuild) {
    Invoke-FormalBuild -Checkout $productionCheckout
}
if ($reviewCheckoutFull -and -not $SkipReviewBuild) {
    Invoke-FormalBuild -Checkout $reviewCheckoutFull
}

$production = Get-VerifiedManifest -Checkout $productionCheckout `
    -ExpectedGitCommit $releaseCommit
$review = $null
if ($reviewCheckoutFull) {
    $review = Get-VerifiedManifest -Checkout $reviewCheckoutFull `
        -ExpectedGitCommit $releaseCommit
    if ($review.Data.git.tree -ne $production.Data.git.tree -or
        $review.Data.nativeSo.sha256 -ne $production.Data.nativeSo.sha256 -or
        $review.Data.app.bundleName -ne $production.Data.app.bundleName -or
        $review.Data.app.versionCode -ne $production.Data.app.versionCode) {
        throw 'Production and review builds are not source/native/application-identical'
    }
}

$archiveTargets = @(
    (Join-Path $packageDirectory "LeanTTY-$ReleaseId-arm64-v8a-signed.app"),
    (Join-Path $packageDirectory "LeanTTY-$ReleaseId-arm64-v8a-signed.hap"),
    (Join-Path $packageDirectory 'build-manifest.json'),
    (Join-Path $packageDirectory 'SHA256SUMS.txt'),
    (Join-Path $evidenceDirectory 'release-identity.json'),
    (Join-Path $evidenceDirectory 'artifact-roles.txt'),
    (Join-Path $evidenceDirectory 'production-hap-signing-cert-chain.cer'),
    (Join-Path $evidenceDirectory 'production-hap-signing-profile.p7b'),
    (Join-Path $evidenceDirectory 'production-app-signing-cert-chain.cer'),
    (Join-Path $evidenceDirectory 'production-app-signing-profile.p7b'),
    (Join-Path $evidenceDirectory 'bundle-SHA256SUMS.txt')
)
if ($review) {
    $archiveTargets += @(
        (Join-Path $evidenceDirectory "LeanTTY-$ReleaseId-review-test-signed.hap"),
        (Join-Path $evidenceDirectory 'review-test-build-manifest.json'),
        (Join-Path $evidenceDirectory 'review-hap-signing-cert-chain.cer'),
        (Join-Path $evidenceDirectory 'review-hap-signing-profile.p7b')
    )
}
Assert-ArchiveTargetsAbsent -Paths $archiveTargets
New-Item -ItemType Directory -Force -Path $packageDirectory, $evidenceDirectory | Out-Null

$archivedApp = Join-Path $packageDirectory "LeanTTY-$ReleaseId-arm64-v8a-signed.app"
$archivedProductionHap = Join-Path $packageDirectory "LeanTTY-$ReleaseId-arm64-v8a-signed.hap"
$archivedManifest = Join-Path $packageDirectory 'build-manifest.json'
Copy-CheckedFile -Source $production.SignedApp -Destination $archivedApp
Copy-CheckedFile -Source $production.SignedHap -Destination $archivedProductionHap
Copy-CheckedFile -Source $production.Path -Destination $archivedManifest
Copy-CheckedFile -Source $production.HapCertificate -Destination (
    Join-Path $evidenceDirectory 'production-hap-signing-cert-chain.cer'
)
Copy-CheckedFile -Source $production.HapProfile -Destination (
    Join-Path $evidenceDirectory 'production-hap-signing-profile.p7b'
)
Copy-CheckedFile -Source $production.AppCertificate -Destination (
    Join-Path $evidenceDirectory 'production-app-signing-cert-chain.cer'
)
Copy-CheckedFile -Source $production.AppProfile -Destination (
    Join-Path $evidenceDirectory 'production-app-signing-profile.p7b'
)

$packageFiles = @($archivedApp, $archivedProductionHap, $archivedManifest)
$packageChecksums = @($packageFiles | ForEach-Object {
    '{0}  {1}' -f (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash,
        (Split-Path $_ -Leaf)
})
Write-LeanTTYAtomicText `
    -Path (Join-Path $packageDirectory 'SHA256SUMS.txt') `
    -Content (($packageChecksums -join "`n") + "`n")

$identity = [ordered]@{
    releaseId = $ReleaseId
    commit = $production.Data.git.commit
    tree = $production.Data.git.tree
    bundleName = $production.Data.app.bundleName
    versionName = $production.Data.app.versionName
    versionCode = $production.Data.app.versionCode
    buildMode = $production.Data.buildMode
    abi = $production.Data.abi
    nativeSha256 = $production.Data.nativeSo.sha256
    production = [ordered]@{
        signedAppSha256 = $production.Data.signedApp.sha256
        signedHapSha256 = $production.Data.signedHap.sha256
        signingProfileSha256 = (
            Get-FileHash -LiteralPath $production.AppProfile -Algorithm SHA256
        ).Hash
    }
    review = if ($review) {
        [ordered]@{
            signedHapSha256 = $review.Data.signedHap.sha256
            signingProfileSha256 = (
                Get-FileHash -LiteralPath $review.HapProfile -Algorithm SHA256
            ).Hash
            sameCommitTreeAndNative = $true
        }
    } else {
        $null
    }
}
Write-LeanTTYAtomicJson `
    -Path (Join-Path $evidenceDirectory 'release-identity.json') `
    -Value $identity `
    -Depth 5

$artifactRoles = @(
    "LeanTTY-$ReleaseId-arm64-v8a-signed.app: upload this production APP to AppGallery.",
    "LeanTTY-$ReleaseId-arm64-v8a-signed.hap: production identity evidence; do not use HDC to install it.",
    'AppGallery release-Profile HAP installation by HDC is expected to fail as an untrusted app source.'
)
if ($review) {
    $artifactRoles += "LeanTTY-$ReleaseId-review-test-signed.hap: device acceptance and media capture only; never upload it to AppGallery."
}
Write-LeanTTYAtomicText `
    -Path (Join-Path $evidenceDirectory 'artifact-roles.txt') `
    -Content (($artifactRoles -join "`n") + "`n")

if ($review) {
    Copy-CheckedFile -Source $review.SignedHap -Destination (
        Join-Path $evidenceDirectory "LeanTTY-$ReleaseId-review-test-signed.hap"
    )
    Copy-CheckedFile -Source $review.Path -Destination (
        Join-Path $evidenceDirectory 'review-test-build-manifest.json'
    )
    Copy-CheckedFile -Source $review.HapCertificate -Destination (
        Join-Path $evidenceDirectory 'review-hap-signing-cert-chain.cer'
    )
    Copy-CheckedFile -Source $review.HapProfile -Destination (
        Join-Path $evidenceDirectory 'review-hap-signing-profile.p7b'
    )
}

New-LeanTTYReleaseAssets `
    -ReleaseId $ReleaseId `
    -Checkout $productionCheckout `
    -ReleaseDirectory $releaseDirectory `
    -AppGalleryCopyPath $appGalleryCopyFull | Out-Null

$prohibitedExtensions = @('.jks', '.key', '.keystore', '.p12', '.pem', '.pfx')
$prohibitedNames = @('password.txt', 'signing.local.json5')
$archivedFiles = @(Get-ChildItem -LiteralPath $packageDirectory, $evidenceDirectory -File)
$secretLikeFiles = @($archivedFiles | Where-Object {
    $_.Extension.ToLowerInvariant() -in $prohibitedExtensions -or
    $_.Name.ToLowerInvariant() -in $prohibitedNames
})
if ($secretLikeFiles.Count -gt 0) {
    throw "Secret-like files reached the archive:`n$($secretLikeFiles.FullName -join "`n")"
}

$bundleChecksumPath = Join-Path $evidenceDirectory 'bundle-SHA256SUMS.txt'
$bundleChecksums = @($archivedFiles |
    Where-Object { $_.FullName -ne $bundleChecksumPath } |
    Sort-Object FullName |
    ForEach-Object {
        $relative = $_.FullName.Substring(
            [IO.Path]::GetFullPath($releaseDirectory).TrimEnd('\').Length + 1
        ).Replace('\', '/')
        '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash,
            $relative
    })
Write-LeanTTYAtomicText `
    -Path $bundleChecksumPath `
    -Content (($bundleChecksums -join "`n") + "`n")

Write-Host "APPGALLERY RELEASE ARCHIVE READY [$ReleaseId]" -ForegroundColor Green
Write-Host "Upload APP: $archivedApp" -ForegroundColor Cyan
Write-Host "Evidence: $evidenceDirectory" -ForegroundColor Cyan
if ($review) {
    Write-Host 'Review HAP archived separately for device/media use only.' -ForegroundColor Yellow
}
}
