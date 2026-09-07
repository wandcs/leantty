<#
.SYNOPSIS
  Build the HarmonyOS PC ARM64 HAP.
.DESCRIPTION
  This is the single HAP build path for current LeanTTY development.
  Native Rust code is rebuilt only when its inputs change. The resulting HAP
  is checked to ensure that it contains only the arm64-v8a native library.
#>
param(
    [switch]$Clean,
    [switch]$ForceNative,
    [ValidateSet('debug', 'release')]
    [string]$BuildMode = 'debug',
    [switch]$Metadata,
    [switch]$PreflightOnly,
    [switch]$NoDaemon,
    [switch]$Offline,
    [string]$BuildLogDirectory = '',
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$ReleaseId
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'build-lock.ps1')
. (Join-Path $PSScriptRoot 'package-policy.ps1')
. (Join-Path $PSScriptRoot 'acceptance-source.ps1')
. (Join-Path $PSScriptRoot 'rust-wsl.ps1')
. (Join-Path $PSScriptRoot 'formal-build-environment.ps1')
$productName = 'default'
$projectProfilePath = Join-Path $repoRoot 'build-profile.json5'
$localSigningConfigPath = Join-Path $repoRoot 'signing.local.json5'
$releasePreflight = $null
if (-not $ReleaseId) {
    $appVersionConfig = Get-Content -LiteralPath (
        Join-Path $repoRoot 'AppScope\app.json5'
    ) -Raw | ConvertFrom-Json
    $ReleaseId = [string]$appVersionConfig.app.versionName
}

function Get-CargoPackageVersion {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    $content = Get-Content -LiteralPath $ManifestPath -Raw
    $packageSection = [regex]::Match(
        $content,
        '(?ms)^\[package\]\s*(?<body>.*?)(?=^\[|\z)'
    )
    if (-not $packageSection.Success) {
        throw "Cargo package section missing: $ManifestPath"
    }
    $versionMatch = [regex]::Match(
        $packageSection.Groups['body'].Value,
        '(?m)^\s*version\s*=\s*"(?<version>[^"]+)"\s*$'
    )
    if (-not $versionMatch.Success) {
        throw "Cargo package version missing: $ManifestPath"
    }
    return $versionMatch.Groups['version'].Value
}

function Assert-ReleasePreflight {
    $gitStatus = @(git -C $repoRoot status --porcelain --untracked-files=all 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect the release checkout'
    }
    if ($gitStatus.Count -gt 0) {
        throw "Release checkout must be clean before the build:`n$($gitStatus -join "`n")"
    }

    $branchName = (& git -C $repoRoot symbolic-ref --quiet --short HEAD 2>$null)
    $branchExitCode = $LASTEXITCODE
    if ($branchExitCode -eq 0 -and $branchName) {
        throw "Release checkout must use a detached exact commit, not branch '$branchName'"
    }
    if ($branchExitCode -notin @(0, 1)) {
        throw 'Unable to determine whether the release checkout is detached'
    }

    $gitCommit = (& git -C $repoRoot rev-parse HEAD 2>&1).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to resolve the release commit'
    }
    $gitTree = (& git -C $repoRoot rev-parse 'HEAD^{tree}' 2>&1).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to resolve the release tree'
    }
    $remoteRefs = @(& git -C $repoRoot for-each-ref '--format=%(refname)' `
        "--contains=$gitCommit" refs/remotes/origin 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect origin refs for the release commit'
    }
    if ($remoteRefs.Count -eq 0) {
        throw "Release commit is not contained by a fetched origin ref: $gitCommit"
    }

    $appConfigPath = Join-Path $repoRoot 'AppScope\app.json5'
    $appConfig = Get-Content -LiteralPath $appConfigPath -Raw | ConvertFrom-Json
    $versionSources = [ordered]@{
        'AppScope/app.json5' = [string]$appConfig.app.versionName
        'leantty_ssh/Cargo.toml' = Get-CargoPackageVersion `
            (Join-Path $repoRoot 'leantty_ssh\Cargo.toml')
        'leantty_ssh/leantty-ssh-core/Cargo.toml' = Get-CargoPackageVersion `
            (Join-Path $repoRoot 'leantty_ssh\leantty-ssh-core\Cargo.toml')
        'entry/oh-package.json5' = [string](
            Get-Content -LiteralPath (Join-Path $repoRoot 'entry\oh-package.json5') -Raw |
                ConvertFrom-Json
        ).version
        'entry/src/main/cpp/types/libleantty_ssh/oh-package.json5' = [string](
            Get-Content -LiteralPath (
                Join-Path $repoRoot 'entry\src\main\cpp\types\libleantty_ssh\oh-package.json5'
            ) -Raw |
                ConvertFrom-Json
        ).version
        'oh-package.json5' = [string](
            Get-Content -LiteralPath (Join-Path $repoRoot 'oh-package.json5') -Raw |
                ConvertFrom-Json
        ).version
    }
    $versionMismatches = @($versionSources.GetEnumerator() |
        Where-Object { $_.Value -ne $ReleaseId } |
        ForEach-Object { "$($_.Key)=$($_.Value)" })
    if ($versionMismatches.Count -gt 0) {
        throw "ReleaseId $ReleaseId does not match all version sources:`n$($versionMismatches -join "`n")"
    }

    if (-not (Test-Path -LiteralPath $localSigningConfigPath -PathType Leaf)) {
        throw "Formal release metadata requires ignored signing config: $localSigningConfigPath"
    }
    $signingConfig = Get-Content -LiteralPath $localSigningConfigPath -Raw | ConvertFrom-Json
    foreach ($requiredProperty in @('name', 'type', 'material')) {
        if ($null -eq $signingConfig.$requiredProperty) {
            throw "Local signing config is missing '$requiredProperty': $localSigningConfigPath"
        }
    }
    foreach ($requiredMaterial in @(
        'certpath',
        'keyAlias',
        'keyPassword',
        'profile',
        'signAlg',
        'storeFile',
        'storePassword'
    )) {
        $value = $signingConfig.material.$requiredMaterial
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
            throw "Local signing material is missing '$requiredMaterial': $localSigningConfigPath"
        }
    }

    $repoPrefix = [IO.Path]::GetFullPath($repoRoot).TrimEnd('\') + '\'
    foreach ($pathProperty in @('certpath', 'profile', 'storeFile')) {
        $configuredPath = [string]$signingConfig.material.$pathProperty
        if (-not [IO.Path]::IsPathRooted($configuredPath)) {
            throw "Signing material '$pathProperty' must use an absolute external path"
        }
        $materialPath = [IO.Path]::GetFullPath($configuredPath)
        if ($materialPath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Signing material '$pathProperty' must remain outside the release checkout"
        }
        if (-not (Test-Path -LiteralPath $materialPath -PathType Leaf)) {
            throw "Signing material '$pathProperty' does not exist: $materialPath"
        }
    }
    foreach ($passwordProperty in @('keyPassword', 'storePassword')) {
        $passwordValue = [string]$signingConfig.material.$passwordProperty
        if ($passwordValue.Length -lt 64 -or
            $passwordValue.Length % 2 -ne 0 -or
            $passwordValue -notmatch '^[0-9A-Fa-f]+$') {
            throw "Signing material '$passwordProperty' does not match the current DevEco encrypted format; configure it with DevEco Studio"
        }
    }

    return [ordered]@{
        commit = $gitCommit
        tree = $gitTree
        remoteRefs = @($remoteRefs)
        bundleName = [string]$appConfig.app.bundleName
        versionName = [string]$appConfig.app.versionName
        versionCode = [int64]$appConfig.app.versionCode
        versionSources = $versionSources
        signingProfileSha256 = (
            Get-FileHash -LiteralPath $signingConfig.material.profile -Algorithm SHA256
        ).Hash
    }
}

function Get-RepoRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $rootPrefix = [IO.Path]::GetFullPath($repoRoot).TrimEnd('\') + '\'
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Release artifact is outside the repository: $fullPath"
    }
    return $fullPath.Substring($rootPrefix.Length).Replace('\', '/')
}

function Get-AppOutput {
    param(
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [Parameter(Mandatory = $true)][ValidateSet('unsigned', 'signed')][string]$SignatureState
    )

    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
        if ($SignatureState -eq 'signed') { return $null }
        throw "APP output directory missing: $OutputDirectory"
    }

    $suffix = "-$SignatureState.app"
    $candidates = @(Get-ChildItem -LiteralPath $OutputDirectory -File |
        Where-Object {
            $_.Name.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)
        })
    if ($candidates.Count -eq 0 -and $SignatureState -eq 'signed') {
        return $null
    }
    if ($candidates.Count -ne 1) {
        throw "Expected one $BuildMode $SignatureState APP, found $($candidates.Count) in $OutputDirectory"
    }
    return $candidates[0].FullName
}

function Test-AppNativeAbi {
    param([Parameter(Mandatory = $true)][string]$AppPath)

    $appArchive = [IO.Compression.ZipFile]::OpenRead($AppPath)
    try {
        $hapEntries = @($appArchive.Entries | Where-Object { $_.FullName -match '\.hap$' })
        if ($hapEntries.Count -ne 1) {
            throw "APP must contain exactly one HAP, found $($hapEntries.Count): $AppPath"
        }
        $hapStream = $hapEntries[0].Open()
        try {
            $hapArchive = [IO.Compression.ZipArchive]::new(
                $hapStream,
                [IO.Compression.ZipArchiveMode]::Read,
                $false
            )
            try {
                $nativeAbis = @($hapArchive.Entries |
                    Where-Object { $_.FullName -match '^libs/([^/]+)/[^/]+\.so$' } |
                    ForEach-Object { if ($_.FullName -match '^libs/([^/]+)/') { $Matches[1] } } |
                    Select-Object -Unique)
                if ($nativeAbis.Count -ne 1 -or $nativeAbis[0] -ne 'arm64-v8a') {
                    throw "APP ABI mismatch: expected arm64-v8a, found $($nativeAbis -join ', ')"
                }
            } finally {
                $hapArchive.Dispose()
            }
        } finally {
            $hapStream.Dispose()
        }
    } finally {
        $appArchive.Dispose()
    }
}

function Invoke-SignatureVerification {
    param(
        [Parameter(Mandatory = $true)][string]$ArtifactPath,
        [Parameter(Mandatory = $true)][string]$CertificateOutput,
        [Parameter(Mandatory = $true)][string]$ProfileOutput,
        [Parameter(Mandatory = $true)][string]$ExpectedProfile
    )

    $verificationOutput = @(& $javaExe -jar $signToolJar verify-app `
        -inFile $ArtifactPath `
        -outCertChain $CertificateOutput `
        -outProfile $ProfileOutput 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Signature verification failed: $ArtifactPath`n$($verificationOutput -join "`n")"
    }
    $verificationText = $verificationOutput -join "`n"
    if ($verificationText -notmatch 'Digest verify result:\s*true' -or
        $verificationText -notmatch 'verify-app success') {
        throw "Signature verification did not report success: $ArtifactPath"
    }
    if (-not (Test-Path -LiteralPath $CertificateOutput) -or
        -not (Test-Path -LiteralPath $ProfileOutput)) {
        throw "Signature verification outputs missing: $ArtifactPath"
    }
    if ((Get-FileHash -LiteralPath $ProfileOutput -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $ExpectedProfile -Algorithm SHA256).Hash) {
        throw "Signed artifact contains an unexpected Profile: $ArtifactPath"
    }

    return [ordered]@{
        digestVerified = $true
        verifyAppSuccess = $true
        certificateChain = Get-RepoRelativePath $CertificateOutput
        profile = Get-RepoRelativePath $ProfileOutput
    }
}

if ($Metadata -and $BuildMode -eq 'release') {
    $releasePreflight = Assert-ReleasePreflight
    Write-Host "RELEASE PREFLIGHT SUCCESS [$ReleaseId]" -ForegroundColor Green
    Write-Host "Commit: $($releasePreflight.commit)" -ForegroundColor Cyan
    Write-Host "Tree: $($releasePreflight.tree)" -ForegroundColor Cyan
}
if ($PreflightOnly) {
    if (-not ($Metadata -and $BuildMode -eq 'release')) {
        throw '-PreflightOnly requires -Metadata -BuildMode release'
    }
    return $releasePreflight
}

Invoke-WithLeanTTYBuildLock -RepoRoot $repoRoot -Operation "build-all $BuildMode" -Action {
$deveco = $env:DEVECO_HOME
if (-not $deveco) {
    foreach ($candidate in @('C:\Program Files\Huawei\DevEco Studio', 'D:\Program Files\Huawei\DevEco Studio')) {
        if (Test-Path -LiteralPath $candidate) { $deveco = $candidate; break }
    }
}
if (-not $deveco) { throw 'DevEco Studio not found. Set DEVECO_HOME.' }

$nodeExe = Join-Path $deveco 'tools\node\node.exe'
$hvigorJs = Join-Path $deveco 'tools\hvigor\bin\hvigorw.js'
$ohpm = Join-Path $deveco 'tools\ohpm\bin\ohpm.bat'
$jbrBin = Join-Path $deveco 'jbr\bin'
$javaExe = Join-Path $jbrBin 'java.exe'
$signToolJar = Join-Path $deveco 'sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar'
if (-not (Test-Path -LiteralPath $ohpm -PathType Leaf)) {
    throw "DevEco OHPM tool is missing: $ohpm"
}

$env:NODE_OPTIONS = ''
$env:DEVECO_SDK_HOME = Join-Path $deveco 'sdk'
$env:JAVA_HOME = Join-Path $deveco 'jbr'
$env:PATH = "$jbrBin;$env:PATH"

if ($Clean) {
    foreach ($directory in @(
        (Join-Path $repoRoot 'entry\build'),
        (Join-Path $repoRoot 'build'),
        (Join-Path $repoRoot '.hvigor'),
        (Join-Path $repoRoot 'leantty_ssh\target')
    )) {
        if (Test-Path -LiteralPath $directory) {
            Remove-Item -LiteralPath $directory -Recurse -Force
        }
    }
}

$nativeTypePackage = Join-Path $repoRoot 'entry\oh_modules\libleantty_ssh.so'
if (-not (Test-Path -LiteralPath $nativeTypePackage -PathType Container)) {
    if ($Offline) {
        throw 'Offline build requires prepare-formal-build-inputs.ps1 first'
    }
    Push-Location $repoRoot
    try {
        & $ohpm install --all --lockfile_stable_order
        if ($LASTEXITCODE -ne 0) { throw 'OHPM dependency restore failed' }
    } finally {
        Pop-Location
    }
    if (-not (Test-Path -LiteralPath $nativeTypePackage -PathType Container)) {
        throw "Native OHPM type package is missing after restore: $nativeTypePackage"
    }
}

$nativeArgs = @{}
if ($ForceNative -or $Clean) { $nativeArgs['Force'] = $true }
if ($Offline) { $nativeArgs['Offline'] = $true }
& (Join-Path $PSScriptRoot 'build-native.ps1') @nativeArgs
if ($LASTEXITCODE -ne 0) { throw 'ARM64 native build failed' }
$nativeSo = Join-Path $repoRoot 'entry\libs\arm64-v8a\libleantty_ssh.so'
if (-not (Test-Path -LiteralPath $nativeSo)) { throw "Native output missing: $nativeSo" }

$hapArgs = @(
    $hvigorJs,
    '--mode', 'project',
    '-p', ('product=' + $productName),
    'assembleApp',
    '-p', ('buildMode=' + $BuildMode)
)
if ($NoDaemon) { $hapArgs += '--no-daemon' }
$projectProfileBackup = $null
if (Test-Path -LiteralPath $localSigningConfigPath) {
    $projectProfileBackup = [IO.File]::ReadAllBytes($projectProfilePath)
    $projectProfile = Get-Content -LiteralPath $projectProfilePath -Raw | ConvertFrom-Json
    $localSigningConfig = Get-Content -LiteralPath $localSigningConfigPath -Raw | ConvertFrom-Json
    foreach ($requiredProperty in @('name', 'type', 'material')) {
        if ($null -eq $localSigningConfig.$requiredProperty) {
            throw "Local signing config is missing '$requiredProperty': $localSigningConfigPath"
        }
    }
    $projectProfile.app | Add-Member -NotePropertyName 'signingConfigs' -NotePropertyValue @($localSigningConfig) -Force
    foreach ($product in $projectProfile.app.products) {
        $product | Add-Member -NotePropertyName 'signingConfig' -NotePropertyValue $localSigningConfig.name -Force
    }
    $temporaryProfile = ConvertTo-Json -InputObject $projectProfile -Depth 10
    [IO.File]::WriteAllText($projectProfilePath, $temporaryProfile, [Text.UTF8Encoding]::new($false))
    Write-Host "Using ignored local signing config: $localSigningConfigPath" -ForegroundColor Cyan
}

try {
    Push-Location $repoRoot
    try {
        Invoke-WithLeanTTYAcceptanceSource `
            -RepoRoot $repoRoot `
            -Enabled ($BuildMode -eq 'debug') `
            -Action {
                if ([string]::IsNullOrWhiteSpace($BuildLogDirectory)) {
                    & $nodeExe @hapArgs
                    if ($LASTEXITCODE -ne 0) { throw "PC HAP build failed in $BuildMode mode" }
                } else {
                    $buildRun = Invoke-LeanTTYCapturedProcess `
                        -FilePath $nodeExe `
                        -Arguments $hapArgs `
                        -WorkingDirectory $repoRoot `
                        -StandardOutputPath (Join-Path $BuildLogDirectory 'hvigor-build.stdout.log') `
                        -StandardErrorPath (Join-Path $BuildLogDirectory 'hvigor-build.stderr.log')
                    if ($buildRun.exitCode -ne 0) {
                        throw "PC HAP build failed in $BuildMode mode; inspect captured stdout/stderr"
                    }
                }
            }
    } finally {
        Pop-Location
    }
} finally {
    if ($null -ne $projectProfileBackup) {
        [IO.File]::WriteAllBytes($projectProfilePath, $projectProfileBackup)
    }
}
$outputDir = Join-Path $repoRoot "entry\build\$productName\outputs\default"
$unsignedHap = Join-Path $outputDir 'entry-default-unsigned.hap'
if (-not (Test-Path -LiteralPath $unsignedHap)) { throw "HAP output missing: $unsignedHap" }

if ($BuildMode -eq 'release') {
    Assert-LeanTTYReleasePackageExcludesAcceptanceMarkers -PackagePath $unsignedHap
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($unsignedHap)
try {
    $nativeAbis = @($archive.Entries |
        Where-Object { $_.FullName -match '^libs/([^/]+)/[^/]+\.so$' } |
        ForEach-Object { if ($_.FullName -match '^libs/([^/]+)/') { $Matches[1] } } |
        Select-Object -Unique)
    if ($nativeAbis.Count -ne 1 -or $nativeAbis[0] -ne 'arm64-v8a') {
        throw "HAP ABI mismatch: expected arm64-v8a, found $($nativeAbis -join ', ')"
    }
} finally {
    $archive.Dispose()
}

$signedHap = Join-Path $outputDir 'entry-default-signed.hap'
$appOutputDir = Join-Path $repoRoot 'build\outputs\default'
$unsignedApp = Get-AppOutput -OutputDirectory $appOutputDir -SignatureState unsigned
$signedApp = Get-AppOutput -OutputDirectory $appOutputDir -SignatureState signed
Test-AppNativeAbi -AppPath $unsignedApp
if ($null -ne $signedApp) {
    Test-AppNativeAbi -AppPath $signedApp
}
if (Test-Path -LiteralPath $localSigningConfigPath) {
    if (-not (Test-Path -LiteralPath $signedHap) -or $null -eq $signedApp) {
        throw 'Signing is configured, but signed HAP and APP outputs were not both generated'
    }
}
if ($BuildMode -eq 'release' -and (Test-Path -LiteralPath $signedHap)) {
    Assert-LeanTTYReleasePackageExcludesAcceptanceMarkers -PackagePath $signedHap
}
Write-Host "BUILD SUCCESS [$BuildMode, arm64-v8a]" -ForegroundColor Green
Write-Host "Unsigned HAP: $unsignedHap" -ForegroundColor Cyan
Write-Host "Unsigned APP: $unsignedApp" -ForegroundColor Cyan
if (Test-Path -LiteralPath $signedHap) {
    Write-Host "Signed HAP: $signedHap" -ForegroundColor Cyan
} else {
    Write-Host 'Signed HAP not generated. Configure the ignored signing.local.json5 with the identity appropriate for this checkout.' -ForegroundColor Yellow
}
if ($null -ne $signedApp) {
    Write-Host "Signed APP: $signedApp" -ForegroundColor Cyan
} else {
    Write-Host 'Signed APP not generated. Production signing is required before AppGallery upload.' -ForegroundColor Yellow
}

if ($Metadata) {
    $metadataDir = Join-Path $repoRoot 'build\outputs\metadata'
    $artifactDir = Join-Path $repoRoot 'build\outputs\release'
    $licenseDir = Join-Path $artifactDir 'licenses'
    New-Item -ItemType Directory -Force -Path $metadataDir | Out-Null
    New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
    $artifactDirPrefix = [IO.Path]::GetFullPath($artifactDir).TrimEnd('\') + '\'
    $licenseDirFull = [IO.Path]::GetFullPath($licenseDir)
    if (-not $licenseDirFull.StartsWith($artifactDirPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Release license directory is outside the artifact directory: $licenseDirFull"
    }
    if (Test-Path -LiteralPath $licenseDir) {
        Remove-Item -LiteralPath $licenseDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $licenseDir | Out-Null
    $manifestPath = Join-Path $metadataDir 'build-manifest.json'
    $releaseUnsignedHap = Join-Path $artifactDir "LeanTTY-$ReleaseId-arm64-v8a-unsigned.hap"
    Copy-Item -LiteralPath $unsignedHap -Destination $releaseUnsignedHap -Force
    $releaseUnsignedApp = Join-Path $artifactDir "LeanTTY-$ReleaseId-arm64-v8a-unsigned.app"
    Copy-Item -LiteralPath $unsignedApp -Destination $releaseUnsignedApp -Force
    $releaseSignedHap = $null
    $releaseSignedApp = $null
    if (Test-Path -LiteralPath $signedHap) {
        $releaseSignedHap = Join-Path $artifactDir "LeanTTY-$ReleaseId-arm64-v8a-signed.hap"
        Copy-Item -LiteralPath $signedHap -Destination $releaseSignedHap -Force
    }
    if ($null -ne $signedApp) {
        $releaseSignedApp = Join-Path $artifactDir "LeanTTY-$ReleaseId-arm64-v8a-signed.app"
        Copy-Item -LiteralPath $signedApp -Destination $releaseSignedApp -Force
    }

    $signatureVerification = $null
    if ($null -ne $releaseSignedHap -and $null -ne $releaseSignedApp) {
        if (-not (Test-Path -LiteralPath $javaExe) -or -not (Test-Path -LiteralPath $signToolJar)) {
            throw 'DevEco signature verification tool is missing'
        }
        $expectedProfile = $localSigningConfig.material.profile
        $hapCertificateOutput = Join-Path $metadataDir 'hap-signing-cert-chain.cer'
        $hapProfileOutput = Join-Path $metadataDir 'hap-signing-profile.p7b'
        $appCertificateOutput = Join-Path $metadataDir 'app-signing-cert-chain.cer'
        $appProfileOutput = Join-Path $metadataDir 'app-signing-profile.p7b'
        $signatureVerification = [ordered]@{
            hap = Invoke-SignatureVerification `
                -ArtifactPath $releaseSignedHap `
                -CertificateOutput $hapCertificateOutput `
                -ProfileOutput $hapProfileOutput `
                -ExpectedProfile $expectedProfile
            app = Invoke-SignatureVerification `
                -ArtifactPath $releaseSignedApp `
                -CertificateOutput $appCertificateOutput `
                -ProfileOutput $appProfileOutput `
                -ExpectedProfile $expectedProfile
        }
    }

    $noticeSources = [ordered]@{
        'LICENSE-Apache-2.0.txt' = (Join-Path $repoRoot 'LICENSE')
        'THIRD_PARTY_NOTICES.md' = (Join-Path $repoRoot 'docs\THIRD_PARTY_NOTICES.md')
        'RUST_DEPENDENCIES.md' = (Join-Path $repoRoot 'docs\RUST_DEPENDENCIES.md')
        'OFL-1.1.txt' = (Join-Path $repoRoot 'docs\OFL-1.1.txt')
    }
    $noticeArtifacts = @()
    foreach ($noticeName in $noticeSources.Keys) {
        $noticeSource = $noticeSources[$noticeName]
        if (-not (Test-Path -LiteralPath $noticeSource)) {
            throw "Required release notice missing: $noticeSource"
        }
        $noticeDestination = Join-Path $licenseDir $noticeName
        Copy-Item -LiteralPath $noticeSource -Destination $noticeDestination -Force
        $noticeArtifacts += [ordered]@{
            path = Get-RepoRelativePath $noticeDestination
            sha256 = (Get-FileHash -LiteralPath $noticeDestination -Algorithm SHA256).Hash
        }
    }

    $rustLicenseDir = Join-Path $licenseDir 'rust'
    New-Item -ItemType Directory -Force -Path $rustLicenseDir | Out-Null
    try {
        $cargoMetadataJson = Invoke-LeanTTYRustWsl -RepoRoot $repoRoot -CargoArguments @(
            'metadata',
            '--manifest-path', './leantty_ssh/Cargo.toml',
            '--locked',
            '--offline',
            '--filter-platform', 'aarch64-unknown-linux-ohos',
            '--format-version', '1'
        )
        $wslCargoHome = Get-LeanTTYWslCargoHome
    } catch {
        throw 'Unable to resolve locked ARM64 Rust dependencies for release notices'
    }
    $cargoMetadata = ($cargoMetadataJson -join "`n") | ConvertFrom-Json
    $registryPackages = @($cargoMetadata.packages |
        Where-Object { $_.source -like 'registry+*' } |
        Sort-Object name, version)
    if ($registryPackages.Count -eq 0) {
        throw 'No locked ARM64 Rust registry dependencies found for release notices'
    }

    $rustPackageNotices = @()
    foreach ($package in $registryPackages) {
        if (-not $package.license -and -not $package.license_file) {
            throw "Rust package has no license metadata: $($package.name) $($package.version)"
        }

        $packageManifestPath = ConvertFrom-LeanTTYWslPathWithinRoot `
            -WslRoot $wslCargoHome.WslPath `
            -WindowsRoot $wslCargoHome.WindowsPath `
            -WslPath $package.manifest_path
        $packageSourceDir = Split-Path -Parent $packageManifestPath
        $licenseFiles = @(Get-ChildItem -LiteralPath $packageSourceDir -File |
            Where-Object {
                $_.Name -match '^(?i:LICENSE|LICENCE|COPYING|COPYRIGHT|NOTICE|UNLICENSE)'
            })
        if ($package.license_file) {
            $declaredLicenseFile = Join-Path $packageSourceDir $package.license_file
            if (-not (Test-Path -LiteralPath $declaredLicenseFile -PathType Leaf)) {
                throw "Declared Rust license file is missing: $declaredLicenseFile"
            }
            if ($licenseFiles.FullName -notcontains $declaredLicenseFile) {
                $licenseFiles += Get-Item -LiteralPath $declaredLicenseFile
            }
        }
        $licenseFiles = @($licenseFiles | Sort-Object FullName -Unique)

        $fallbackNotice = $null
        if ($licenseFiles.Count -eq 0) {
            switch -Regex ($package.license) {
                '^MIT$' { $fallbackNotice = '../THIRD_PARTY_NOTICES.md'; break }
                '^Apache-2\.0$' { $fallbackNotice = '../LICENSE-Apache-2.0.txt'; break }
                '^(MIT OR Apache-2\.0|Apache-2\.0 OR MIT|MIT/Apache-2\.0)$' {
                    $fallbackNotice = '../THIRD_PARTY_NOTICES.md and ../LICENSE-Apache-2.0.txt'
                    break
                }
                default {
                    throw "Rust package has no distributable license file: $($package.name) $($package.version)"
                }
            }
        }

        $packageDirName = "$($package.name)-$($package.version)"
        $packageLicenseDir = Join-Path $rustLicenseDir $packageDirName
        $copiedLicensePaths = @()
        if ($licenseFiles.Count -gt 0) {
            New-Item -ItemType Directory -Force -Path $packageLicenseDir | Out-Null
            $usedNames = [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::OrdinalIgnoreCase
            )
            foreach ($licenseFile in $licenseFiles) {
                $destinationName = $licenseFile.Name
                if (-not $usedNames.Add($destinationName)) {
                    $destinationName = "$($usedNames.Count)-$destinationName"
                    [void]$usedNames.Add($destinationName)
                }
                $licenseDestination = Join-Path $packageLicenseDir $destinationName
                Copy-Item -LiteralPath $licenseFile.FullName -Destination $licenseDestination -Force
                $copiedLicensePaths += Get-RepoRelativePath $licenseDestination
                $noticeArtifacts += [ordered]@{
                    path = Get-RepoRelativePath $licenseDestination
                    sha256 = (Get-FileHash -LiteralPath $licenseDestination -Algorithm SHA256).Hash
                }
            }
        }

        $rustPackageNotices += [ordered]@{
            name = $package.name
            version = $package.version
            license = $package.license
            licenseFile = $package.license_file
            authors = @($package.authors)
            repository = $package.repository
            files = $copiedLicensePaths
            fallbackNotice = $fallbackNotice
        }
    }
    $rustNoticeIndexPath = Join-Path $rustLicenseDir 'packages.json'
    Set-Content -LiteralPath $rustNoticeIndexPath `
        -Value (ConvertTo-Json -InputObject $rustPackageNotices -Depth 4) -Encoding UTF8
    $noticeArtifacts += [ordered]@{
        path = Get-RepoRelativePath $rustNoticeIndexPath
        sha256 = (Get-FileHash -LiteralPath $rustNoticeIndexPath -Algorithm SHA256).Hash
    }

    $gitCommit = (git -C $repoRoot rev-parse HEAD 2>&1).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve Git commit for build manifest' }
    $gitStatus = @(git -C $repoRoot status --porcelain 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve Git dirty state for build manifest' }

    $manifest = [ordered]@{
        schemaVersion = 3
        releaseId = $ReleaseId
        timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
        git = [ordered]@{
            commit = $gitCommit
            tree = if ($null -ne $releasePreflight) {
                $releasePreflight.tree
            } else {
                (& git -C $repoRoot rev-parse 'HEAD^{tree}' 2>&1).Trim()
            }
            dirty = ($gitStatus.Count -gt 0)
        }
        app = if ($null -ne $releasePreflight) {
            [ordered]@{
                bundleName = $releasePreflight.bundleName
                versionName = $releasePreflight.versionName
                versionCode = $releasePreflight.versionCode
            }
        } else {
            $null
        }
        product = $productName
        buildMode = $BuildMode
        abi = 'arm64-v8a'
        nativeSo = [ordered]@{
            path = Get-RepoRelativePath $nativeSo
            sha256 = (Get-FileHash -LiteralPath $nativeSo -Algorithm SHA256).Hash
        }
        unsignedHap = [ordered]@{
            path = Get-RepoRelativePath $releaseUnsignedHap
            sha256 = (Get-FileHash -LiteralPath $releaseUnsignedHap -Algorithm SHA256).Hash
        }
        signedHap = $null
        unsignedApp = [ordered]@{
            path = Get-RepoRelativePath $releaseUnsignedApp
            sha256 = (Get-FileHash -LiteralPath $releaseUnsignedApp -Algorithm SHA256).Hash
        }
        signedApp = $null
        signatureVerification = $signatureVerification
        notices = $noticeArtifacts
    }
    if ($null -ne $releaseSignedHap) {
        $manifest['signedHap'] = [ordered]@{
            path = Get-RepoRelativePath $releaseSignedHap
            sha256 = (Get-FileHash -LiteralPath $releaseSignedHap -Algorithm SHA256).Hash
        }
    }
    if ($null -ne $releaseSignedApp) {
        $manifest['signedApp'] = [ordered]@{
            path = Get-RepoRelativePath $releaseSignedApp
            sha256 = (Get-FileHash -LiteralPath $releaseSignedApp -Algorithm SHA256).Hash
        }
    }
    Set-Content -LiteralPath $manifestPath -Value (ConvertTo-Json -InputObject $manifest -Depth 4) -Encoding UTF8
    Write-Host "Manifest: $manifestPath" -ForegroundColor Cyan
}
}
