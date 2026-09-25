. (Join-Path $PSScriptRoot 'device-package.ps1')

function Get-LeanTTYZipPayload {
    param([Parameter(Mandatory)][string]$Path)
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    $entries = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    try {
        foreach ($entry in $archive.Entries) {
            if ($entries.ContainsKey($entry.FullName)) { throw 'Duplicate ZIP member in release payload' }
            $stream = $entry.Open()
            try { $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
            finally { $stream.Dispose() }
            $entries.Add($entry.FullName, [ordered]@{ path=$entry.FullName; size=$entry.Length; sha256=$hash })
        }
        return ,@($entries.Values | Sort-Object { $_.path } -CaseSensitive)
    } finally { $archive.Dispose() }
}

function Assert-LeanTTYPayloadEqual {
    param([Parameter(Mandatory)][object[]]$Expected, [Parameter(Mandatory)][object[]]$Actual)
    if (($Expected | ConvertTo-Json -Depth 5 -Compress) -cne ($Actual | ConvertTo-Json -Depth 5 -Compress)) {
        throw 'Release payload members differ (name, size or SHA-256)'
    }
}

function Assert-LeanTTYUnsignedPayload {
    param([Parameter(Mandatory)][object[]]$Unsigned, [Parameter(Mandatory)][object[]]$Signed)
    # SDK SignProvider generates a page bitmap while code-signing. Only this
    # added member is allowed here; signed production/review compare ALL members.
    if (@($Unsigned | Where-Object path -CEQ '.pages.info').Count -ne 0 -or
        @($Signed | Where-Object path -CEQ '.pages.info').Count -ne 1) {
        throw 'Unexpected SDK page bitmap boundary'
    }
    Assert-LeanTTYPayloadEqual $Unsigned @($Signed | Where-Object path -CNE '.pages.info')
}

function Read-LeanTTYReleaseModule {
    param([Parameter(Mandatory)][string]$Path, [string]$Member = 'module.json')
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $members = @($archive.Entries | Where-Object FullName -CEQ $Member)
        if ($members.Count -ne 1) { throw "Release HAP must contain exactly one $Member" }
        $reader = [IO.StreamReader]::new($members[0].Open())
        try { return ($reader.ReadToEnd() | ConvertFrom-Json) } finally { $reader.Dispose() }
    } finally { $archive.Dispose() }
}

function Assert-LeanTTYAppHapPayload {
    param([Parameter(Mandatory)][string]$AppPath, [Parameter(Mandatory)][string]$ExpectedHap)
    # Do not extract archive paths to disk. Only the single actual module is read.
    $null = Get-LeanTTYZipPayload -Path $AppPath
    $archive = [IO.Compression.ZipFile]::OpenRead($AppPath)
    $temporaryHap = Join-Path ([IO.Path]::GetTempPath()) ('LeanTTY-app-payload-' + [guid]::NewGuid().ToString('N') + '.hap')
    try {
        $haps = @($archive.Entries | Where-Object FullName -CLike '*.hap')
        if ($haps.Count -ne 1) { throw 'Production APP must contain exactly one HAP' }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($haps[0], $temporaryHap, $false)
        $expected = Get-LeanTTYZipPayload $ExpectedHap
        $actual = Get-LeanTTYZipPayload $temporaryHap
        # APP packaging pretty-prints pack.info. All other members remain byte-exact;
        # compare the complete pack.info JSON value, and retain both byte hashes.
        Assert-LeanTTYPayloadEqual @($expected | Where-Object path -CNE 'pack.info') @($actual | Where-Object path -CNE 'pack.info')
        if ((Read-LeanTTYReleaseModule $ExpectedHap 'pack.info' | ConvertTo-Json -Depth 50 -Compress) -cne
            (Read-LeanTTYReleaseModule $temporaryHap 'pack.info' | ConvertTo-Json -Depth 50 -Compress)) {
            throw 'APP embedded HAP pack.info value differs'
        }
        return [ordered]@{ member=$haps[0].FullName; sha256=(Get-FileHash -LiteralPath $temporaryHap).Hash.ToLowerInvariant()
            programPayloadEqual=$true; packInfoValueEqual=$true
            standalonePackInfo=@($expected | Where-Object path -CEQ 'pack.info')[0]
            embeddedPackInfo=@($actual | Where-Object path -CEQ 'pack.info')[0] }
    } finally {
        $archive.Dispose()
        if (Test-Path -LiteralPath $temporaryHap) { Remove-Item -LiteralPath $temporaryHap -Force }
    }
}

function Read-LeanTTYSigningProfile {
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.Security.Cryptography.Pkcs
    $cms = [Security.Cryptography.Pkcs.SignedCms]::new()
    $cms.Decode([IO.File]::ReadAllBytes($Path))
    $cms.CheckSignature($true)
    return ([Text.Encoding]::UTF8.GetString($cms.ContentInfo.Content) | ConvertFrom-Json)
}

function Assert-LeanTTYProfileRoles {
    param([Parameter(Mandatory)]$Production, [Parameter(Mandatory)]$Review)
    if ($Production.type -cne 'release' -or $Production.'app-distribution-type' -cne 'app_gallery' -or
        $Review.type -cne 'debug') { throw 'Expected AppGallery production and debug review signing Profiles' }
    foreach ($field in @('developer-id', 'bundle-name', 'apl', 'app-feature')) {
        if ([string]::IsNullOrWhiteSpace([string]$Production.'bundle-info'.$field) -or
            $Production.'bundle-info'.$field -cne $Review.'bundle-info'.$field) {
            throw "Signing Profile identity differs: $field"
        }
    }
    if ($Production.'bundle-info'.'bundle-name' -cne 'com.leantty.app') { throw 'Unexpected signing bundle' }
    foreach ($field in @('baseapp-info', 'permissions')) {
        if (($Production.$field | ConvertTo-Json -Depth 20 -Compress) -cne
            ($Review.$field | ConvertTo-Json -Depth 20 -Compress)) { throw "Signing Profile capabilities differ: $field" }
    }
    # A narrower debug ACL does not mask a missing production entitlement.
    $productionAcl = @($Production.acls.'allowed-acls' | Sort-Object -Unique)
    $reviewAcl = @($Review.acls.'allowed-acls' | Sort-Object -Unique)
    if (@($reviewAcl | Where-Object { $_ -cnotin $productionAcl }).Count -gt 0) {
        throw 'Review Profile grants ACLs absent from production'
    }
    $productionPrivileges = @($Production.'app-privilege-capabilities' | Where-Object { $null -ne $_ })
    $reviewPrivileges = @($Review.'app-privilege-capabilities' | Where-Object { $null -ne $_ })
    if (($productionPrivileges | ConvertTo-Json -Depth 20 -Compress) -cne
        ($reviewPrivileges | ConvertTo-Json -Depth 20 -Compress)) { throw 'Signing Profile privilege capabilities differ' }
    return [ordered]@{
        productionType='release'; productionDistribution='app_gallery'; reviewType='debug'
        productionAcl=$productionAcl; reviewAcl=$reviewAcl; reviewHasNoExtraCapabilities=$true
        appIdentifierEqual=($Production.'bundle-info'.'app-identifier' -ceq $Review.'bundle-info'.'app-identifier')
        roleDifferences=@('certificate', 'Profile identity and validity', 'debug device admission')
    }
}

function Invoke-LeanTTYReleaseSignatureCheck {
    param([string]$DevEco, [string]$Path, [string]$Prefix, [string]$ExpectedProfile)
    $cert = "$Prefix.cer"
    $profile = "$Prefix.p7b"
    $output = @(& (Join-Path $DevEco 'jbr/bin/java.exe') -jar (
        Join-Path $DevEco 'sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar'
    ) verify-app -inFile $Path -outCertChain $cert -outProfile $profile 2>&1)
    if ($LASTEXITCODE -ne 0 -or ($output -join "`n") -notmatch 'Digest verify result:\s*true' -or
        ($output -join "`n") -notmatch 'verify-app success' -or -not (Test-Path -LiteralPath $cert) -or
        -not (Test-Path -LiteralPath $profile)) { throw 'SDK release signature verification failed' }
    if ((Get-FileHash -LiteralPath $profile).Hash -cne (Get-FileHash -LiteralPath $ExpectedProfile).Hash) {
        throw 'Signed artifact contains an unexpected Profile'
    }
    return [ordered]@{ digestVerified=$true; verifyAppSuccess=$true; certificateChain=$cert; profile=$profile }
}

function New-LeanTTYReviewHap {
    param([Parameter(Mandatory)]$Production, [Parameter(Mandatory)][string]$ReviewCheckout,
        [Parameter(Mandatory)][string]$ProductionCheckout)
    $deveco = $env:DEVECO_HOME
    if (-not $deveco) {
        $deveco = @('C:\Program Files\Huawei\DevEco Studio', 'D:\Program Files\Huawei\DevEco Studio') |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    if (-not $deveco) { throw 'DevEco Studio is required for same-payload signing' }
    $configPath = Join-Path $ReviewCheckout 'signing.local.json5'
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ((Get-FileHash -LiteralPath $Production.HapProfile).Hash -cne
        (Get-FileHash -LiteralPath $Production.AppProfile).Hash) { throw 'Production APP/HAP signing Profiles differ' }
    $profileRoles = Assert-LeanTTYProfileRoles -Production (Read-LeanTTYSigningProfile $Production.HapProfile) `
        -Review (Read-LeanTTYSigningProfile $config.material.profile)
    $payload = Get-LeanTTYZipPayload $Production.UnsignedHap
    $signedPayload = Get-LeanTTYZipPayload $Production.SignedHap
    Assert-LeanTTYUnsignedPayload $payload $signedPayload
    # The signed APP contains the unsigned module, with pack.info pretty-printed.
    $appHap = Assert-LeanTTYAppHapPayload $Production.SignedApp $Production.UnsignedHap
    $module = Read-LeanTTYReleaseModule $Production.UnsignedHap
    if ($module.app.debug -isnot [bool] -or $module.app.debug -or $module.app.buildMode -cne 'release' -or
        $module.app.bundleName -cne $Production.Data.app.bundleName -or
        $module.app.versionName -cne $Production.Data.app.versionName -or
        $module.app.versionCode -ne $Production.Data.app.versionCode -or
        $module.module.name -cne 'entry' -or $module.module.type -cne 'entry') { throw 'Release payload identity mismatch' }
    $native = @($payload | Where-Object { $_.path -cmatch '^libs/[^/]+/[^/]+\.so$' })
    if ($native.Count -ne 3 -or @($native | Where-Object { $_.path -cnotmatch '^libs/arm64-v8a/(libc\+\+_shared|libleantty_ssh|libleantty_terminal)\.so$' }).Count -gt 0) {
        throw 'Release payload must contain the three expected ARM64 native libraries'
    }
    Assert-LeanTTYReleasePackageExcludesAcceptanceMarkers -PackagePath $Production.UnsignedHap
    $outputDirectory = Join-Path $ReviewCheckout ('build/review-signing/' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    $outputHap = Join-Path $outputDirectory 'LeanTTY-review-test-signed.hap'
    $helper = Join-Path $PSScriptRoot 'sign-review-hap.cjs'
    $unsignedHash = (Get-FileHash -LiteralPath $Production.UnsignedHap).Hash.ToLowerInvariant()
    & (Join-Path $deveco 'tools/node/node.exe') $helper $deveco $configPath $Production.UnsignedHap $outputHap ([string]$module.app.minAPIVersion) $ProductionCheckout
    if ($LASTEXITCODE -ne 0) { throw 'SDK review signing failed; no credentials or raw SDK diagnostics logged' }
    $signatures = [ordered]@{
        productionHap = Invoke-LeanTTYReleaseSignatureCheck $deveco $Production.SignedHap (Join-Path $outputDirectory 'production-hap') $Production.HapProfile
        productionApp = Invoke-LeanTTYReleaseSignatureCheck $deveco $Production.SignedApp (Join-Path $outputDirectory 'production-app') $Production.AppProfile
        reviewHap = Invoke-LeanTTYReleaseSignatureCheck $deveco $outputHap (Join-Path $outputDirectory 'review-hap') $config.material.profile
    }
    Assert-LeanTTYPayloadEqual $signedPayload (Get-LeanTTYZipPayload $outputHap)
    $admission = Assert-LeanTTYDeviceHap -HapPath $outputHap -Purpose review-smoke
    if ((Get-FileHash -LiteralPath $Production.UnsignedHap).Hash.ToLowerInvariant() -cne $unsignedHash) {
        throw 'Unsigned HAP changed during signing'
    }
    $receiptPath = Join-Path $outputDirectory 'review-signing.json'
    $receipt = [ordered]@{
        schemaVersion=1; mode='same-production-payload'; commit=$Production.Data.git.commit; tree=$Production.Data.git.tree
        productionManifestSha256=(Get-FileHash -LiteralPath $Production.Path).Hash.ToLowerInvariant()
        unsignedHapSha256=$unsignedHash; signedHapSha256=$admission.sha256
        productionSignedHapSha256=(Get-FileHash -LiteralPath $Production.SignedHap).Hash.ToLowerInvariant()
        productionSignedAppSha256=(Get-FileHash -LiteralPath $Production.SignedApp).Hash.ToLowerInvariant()
        sdkSignerSha256=(Get-FileHash -LiteralPath (Join-Path $deveco 'sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar')).Hash.ToLowerInvariant()
        sdkCredentialHelperSha256=(Get-FileHash -LiteralPath (Join-Path $deveco 'tools/hvigor/hvigor-ohos-plugin/src/utils/decipher-util.js')).Hash.ToLowerInvariant()
        sdkModuleInitializerSha256=(Get-FileHash -LiteralPath (Join-Path $deveco 'tools/hvigor/hvigor/src/cli/wrapper/prepare-node-path.js')).Hash.ToLowerInvariant()
        signingBridgeSha256=(Get-FileHash -LiteralPath $helper).Hash.ToLowerInvariant()
        sdkProjectCheckout=$ProductionCheckout
        payloadEqual=$true; payload=$signedPayload; unsignedPayload=$payload; native=$native; appHap=$appHap
        profiles=$profileRoles; signatures=$signatures; deviceAdmission=$admission
    }
    Write-LeanTTYAtomicJson -Path $receiptPath -Value $receipt -Depth 12
    return [pscustomobject]@{ Path=$receiptPath; SignedHap=$outputHap; Data=$receipt
        HapCertificate=$signatures.reviewHap.certificateChain; HapProfile=$signatures.reviewHap.profile }
}
