. (Join-Path $PSScriptRoot 'release-tooling.ps1')
. (Join-Path $PSScriptRoot 'package-policy.ps1')

function Read-LeanTTYVerifiedHapProfile {
    param([Parameter(Mandatory = $true)][string]$HapPath)
    $deveco = $env:DEVECO_HOME
    if (-not $deveco) {
        foreach ($candidate in @('C:\Program Files\Huawei\DevEco Studio', 'D:\Program Files\Huawei\DevEco Studio')) {
            if (Test-Path -LiteralPath $candidate) { $deveco = $candidate; break }
        }
    }
    if (-not $deveco) { throw '[environment] DevEco Studio is required for HAP verification' }
    $java = Join-Path $deveco 'jbr/bin/java.exe'
    $signTool = Join-Path $deveco 'sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar'
    if (-not (Test-Path -LiteralPath $java) -or -not (Test-Path -LiteralPath $signTool)) {
        throw '[environment] DevEco HAP signature verifier is missing'
    }
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('LeanTTY-hap-profile-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    $cert = Join-Path $temp 'chain.cer'
    $profile = Join-Path $temp 'profile.p7b'
    try {
        # SDK owns signature validation. Never print its certificate/Profile output.
        $verification = @(& $java -jar $signTool verify-app -inFile $HapPath -outCertChain $cert -outProfile $profile 2>&1)
        if ($LASTEXITCODE -ne 0 -or ($verification -join "`n") -notmatch 'Digest verify result:\s*true' -or
            ($verification -join "`n") -notmatch 'verify-app success' -or -not (Test-Path -LiteralPath $profile)) {
            throw '[harness] HAP signature verification failed; installation forbidden'
        }
        Add-Type -AssemblyName System.Security.Cryptography.Pkcs
        $cms = [Security.Cryptography.Pkcs.SignedCms]::new()
        $cms.Decode([IO.File]::ReadAllBytes($profile))
        $document = [Text.Encoding]::UTF8.GetString($cms.ContentInfo.Content) | ConvertFrom-Json
        return [pscustomobject]@{ type=[string]$document.type; bundleName=[string]$document.'bundle-info'.'bundle-name' }
    } finally {
        foreach ($path in @($cert, $profile)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
        Remove-Item -LiteralPath $temp -Force
    }
}

function Assert-LeanTTYDeviceHap {
    param(
        [Parameter(Mandatory = $true)][string]$HapPath,
        [Parameter(Mandatory = $true)][ValidateSet('development', 'acceptance', 'review-smoke')][string]$Purpose
    )
    $path = Assert-LeanTTYDeviceTestHapPath -HapPath $HapPath -ParameterName $Purpose
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $profile = Read-LeanTTYVerifiedHapProfile -HapPath $path
    if ($profile.type -cne 'debug') {
        throw '[harness] A production or unknown signing Profile must not enter HDC installation'
    }
    $archive = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $modules = @($archive.Entries | Where-Object FullName -CEQ 'module.json')
        if ($modules.Count -ne 1) { throw '[harness] HAP must contain one module.json' }
        $reader = [IO.StreamReader]::new($modules[0].Open())
        try { $module = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        if ($module.app.bundleName -cne 'com.leantty.app' -or $profile.bundleName -cne $module.app.bundleName -or
            $module.module.name -cne 'entry' -or $module.module.type -cne 'entry') {
            throw '[harness] Unexpected HAP bundle or module identity'
        }
        if ($module.app.debug -isnot [bool]) { throw '[harness] HAP app.debug must be a boolean' }
        $abis = @($archive.Entries | ForEach-Object {
            if ($_.FullName -cmatch '^libs/([^/]+)/[^/]+\.so$') { $Matches[1] }
        } | Select-Object -Unique)
        if ($abis.Count -ne 1 -or $abis[0] -cne 'arm64-v8a') { throw '[harness] HAP must contain only ARM64 native libraries' }
        if ($Purpose -eq 'acceptance') {
            if (-not $module.app.debug) { throw '[harness] A release-mode HAP cannot serve acceptance-only marker scenarios' }
            $abc = $archive.GetEntry('ets/modules.abc')
            if ($null -eq $abc) { throw '[harness] HAP is missing acceptance bytecode' }
            $reader = [IO.StreamReader]::new($abc.Open(), [Text.Encoding]::GetEncoding(28591))
            try { $bytecode = $reader.ReadToEnd() } finally { $reader.Dispose() }
            foreach ($marker in @('ACCEPTANCE_INPUT_SUBMIT', 'ACCEPTANCE_INPUT_NATIVE')) {
                if (-not $bytecode.Contains($marker)) { throw "[harness] HAP is missing acceptance capability: $marker" }
            }
        }
        if ($Purpose -eq 'review-smoke' -and $module.app.debug) {
            throw '[harness] The review smoke requires release-mode bytecode with a test Profile'
        }
    } finally { $archive.Dispose() }
    if (-not $module.app.debug) {
        Assert-LeanTTYReleasePackageExcludesAcceptanceMarkers -PackagePath $path
    }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hash) {
        throw '[harness] HAP changed during admission; installation forbidden'
    }
    return [pscustomobject][ordered]@{
        path=$path; sha256=$hash; purpose=$Purpose; profileType=$profile.type;
        buildMode=$(if ($module.app.debug) { 'debug' } else { 'release' });
        bundleName=[string]$module.app.bundleName; version=[string]$module.app.versionName;
        abi=$abis[0]; signatureVerified=$true
    }
}
