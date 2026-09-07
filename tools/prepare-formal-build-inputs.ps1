<#
.SYNOPSIS
  Prewarm and verify all network-dependent inputs used by formal LeanTTY verification.
#>
[CmdletBinding()]
param(
    [string]$EvidencePath = '',
    [string]$Distribution = $env:LEANTTY_WSL_DISTRO
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'formal-build-environment.ps1')
. (Join-Path $PSScriptRoot 'release-tooling.ps1')
. (Join-Path $PSScriptRoot 'rust-wsl.ps1')

$startedAt = [DateTimeOffset]::UtcNow
if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $EvidencePath = Join-Path $repoRoot (
        'build\verification\formal-inputs-' + $startedAt.ToString('yyyyMMddTHHmmssfffZ') + '.json'
    )
}
$EvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$evidenceDirectory = Split-Path $EvidencePath -Parent
New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
$tools = Resolve-LeanTTYDevEcoBuildTools
$env:NODE_OPTIONS = ''
$env:DEVECO_SDK_HOME = $tools.sdkHome
$env:JAVA_HOME = $tools.javaHome
$env:PATH = (Join-Path $tools.javaHome 'bin') + ';' + $env:PATH

$trackedInputPaths = @(
    'tools/web-terminal/package-lock.json',
    'tools/web-terminal/assets-manifest.json',
    'oh-package-lock.json5',
    'entry/oh-package-lock.json5'
) + @(git -C $repoRoot ls-files -- 'entry/src/main/resources/rawfile')
if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate formal Web build inputs' }
$beforeHashes = @{}
$beforeBytes = @{}
foreach ($relativePath in $trackedInputPaths) {
    $fullPath = Join-Path $repoRoot $relativePath
    $beforeHashes[$relativePath] = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
    $beforeBytes[$relativePath] = [IO.File]::ReadAllBytes($fullPath)
}

$result = 'failed'
$failure = ''
$versions = [ordered]@{}
$sourceInputsUnchanged = $false
try {
    $productInfo = Get-Content -LiteralPath $tools.productInfo -Raw | ConvertFrom-Json
    $versions.devEco = [string]$productInfo.version
    $versions.node = (& $tools.node --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read the bundled Node.js version' }

    $npmVersion = Invoke-LeanTTYCapturedProcess `
        -FilePath $tools.node -Arguments @($tools.npmCli, '--version') `
        -WorkingDirectory $repoRoot `
        -StandardOutputPath (Join-Path $evidenceDirectory 'npm-version.stdout.log') `
        -StandardErrorPath (Join-Path $evidenceDirectory 'npm-version.stderr.log')
    if ($npmVersion.exitCode -ne 0) { throw 'Unable to read the bundled npm version' }
    $versions.npm = $npmVersion.stdout.Trim()

    $hvigorVersion = Invoke-LeanTTYCapturedProcess `
        -FilePath $tools.node -Arguments @($tools.hvigor, '--version') `
        -WorkingDirectory $repoRoot `
        -StandardOutputPath (Join-Path $evidenceDirectory 'hvigor-version.stdout.log') `
        -StandardErrorPath (Join-Path $evidenceDirectory 'hvigor-version.stderr.log')
    if ($hvigorVersion.exitCode -ne 0) { throw 'Unable to read the Hvigor version' }
    $versions.hvigor = $hvigorVersion.stdout.Trim()
    $versions.ohpm = (& $tools.ohpm --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read the OHPM version' }

    $webRoot = Join-Path $repoRoot 'tools\web-terminal'
    $npmCi = Invoke-LeanTTYCapturedProcess `
        -FilePath $tools.node -Arguments @($tools.npmCli, 'ci', '--ignore-scripts') `
        -WorkingDirectory $webRoot `
        -StandardOutputPath (Join-Path $evidenceDirectory 'npm-ci.stdout.log') `
        -StandardErrorPath (Join-Path $evidenceDirectory 'npm-ci.stderr.log')
    if ($npmCi.exitCode -ne 0) { throw 'Locked Web dependency preparation failed' }
    $npmBuild = Invoke-LeanTTYCapturedProcess `
        -FilePath $tools.node -Arguments @($tools.npmCli, 'run', 'build') `
        -WorkingDirectory $webRoot `
        -StandardOutputPath (Join-Path $evidenceDirectory 'npm-build.stdout.log') `
        -StandardErrorPath (Join-Path $evidenceDirectory 'npm-build.stderr.log')
    if ($npmBuild.exitCode -ne 0) { throw 'Packaged Web asset rebuild failed' }

    Push-Location $repoRoot
    try {
        & $tools.ohpm install --all --lockfile_stable_order
        if ($LASTEXITCODE -ne 0) { throw 'OHPM dependency preparation failed' }
    } finally {
        Pop-Location
    }
    Invoke-LeanTTYRustWsl -RepoRoot $repoRoot -Distribution $Distribution -CargoArguments @(
        'fetch', '--locked', '--manifest-path', './leantty_ssh/Cargo.toml',
        '--target', 'aarch64-unknown-linux-ohos'
    )

    foreach ($relativePath in $trackedInputPaths) {
        $afterHash = (Get-FileHash -LiteralPath (Join-Path $repoRoot $relativePath) -Algorithm SHA256).Hash
        if ($afterHash -cne $beforeHashes[$relativePath]) {
            $fullPath = Join-Path $repoRoot $relativePath
            if ($relativePath -in @('oh-package-lock.json5', 'entry/oh-package-lock.json5') -and
                (Test-LeanTTYOhpmLockfileTextEqual -Before $beforeBytes[$relativePath] `
                    -After ([IO.File]::ReadAllBytes($fullPath)))) {
                [IO.File]::WriteAllBytes($fullPath, [byte[]]$beforeBytes[$relativePath])
            } else {
                throw "Formal dependency preparation changed tracked input: $relativePath"
            }
        }
    }
    $sourceInputsUnchanged = $true
    $result = 'passed'
} catch {
    $failure = $_.Exception.Message
} finally {
    if (-not $sourceInputsUnchanged) {
        foreach ($relativePath in $trackedInputPaths) {
            [IO.File]::WriteAllBytes(
                (Join-Path $repoRoot $relativePath),
                [byte[]]$beforeBytes[$relativePath]
            )
        }
    }
    Write-LeanTTYAtomicJson -Path $EvidencePath -Value ([ordered]@{
        schemaVersion = 1
        gate = 'formal-build-input-preparation'
        result = $result
        startedAt = $startedAt.ToString('o')
        completedAt = [DateTimeOffset]::UtcNow.ToString('o')
        versions = $versions
        sourceInputsUnchanged = $sourceInputsUnchanged
        networkDependentWorkCompleted = ($result -eq 'passed')
        failure = $failure
    }) -Depth 6
}
if ($failure) { throw $failure }
Write-Host "FORMAL BUILD INPUTS READY: $EvidencePath" -ForegroundColor Green
