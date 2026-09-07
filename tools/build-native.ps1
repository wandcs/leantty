<#
.SYNOPSIS
  LeanTTY native cross-compilation
.DESCRIPTION
  Build leantty_ssh in WSL for the HarmonyOS PC ARM64 target, using the OHOS
  SDK/NDK from DevEco Studio for linking.
#>
param(
    [string]$DevEcoHome = $env:DEVECO_HOME,
    [string]$WslDistribution = $env:LEANTTY_WSL_DISTRO,
    [switch]$Force,
    [switch]$SkipCopy,
    [switch]$Offline
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'build-lock.ps1')
. (Join-Path $PSScriptRoot 'rust-wsl.ps1')

Invoke-WithLeanTTYBuildLock -RepoRoot $repoRoot -Operation 'build-native' -Action {
# ── Detect DevEco Studio ──
$deveco = ''
$candidates = @(
    $DevEcoHome,
    $env:DEVECO_HOME,
    'C:\Program Files\Huawei\DevEco Studio',
    'D:\Program Files\Huawei\DevEco Studio'
)
foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c)) { $deveco = $c; break }
}
if ($deveco -eq '') {
    Write-Host 'DevEco Studio not found. Set DEVECO_HOME.' -ForegroundColor Red
    Write-Host 'Example: $env:DEVECO_HOME = ''C:\Program Files\Huawei\DevEco Studio''' -ForegroundColor Yellow
    throw 'DevEco Studio not found. Set DEVECO_HOME.'
}

    $sdkDir = Join-Path $deveco 'sdk'
    if (Test-Path -LiteralPath 'C:\ohos-sdk') {
        $sdkDir = 'C:\ohos-sdk'
    }
    $ndkDir = Join-Path $sdkDir 'default\openharmony'
$llvmBin = Join-Path $ndkDir 'native\llvm\bin'
$jbrBin  = Join-Path $deveco 'jbr\bin'

# ── Self-check ──
$required = @(
    @{ Path = (Join-Path $llvmBin 'clang.exe');      Name = 'OHOS Clang' },
    @{ Path = (Join-Path $llvmBin 'llvm-ar.exe');     Name = 'OHOS llvm-ar' },
    @{ Path = (Join-Path $llvmBin 'llvm-readelf.exe'); Name = 'OHOS llvm-readelf' },
    @{ Path = (Join-Path $jbrBin 'java.exe');         Name = 'JBR Java' }
)
foreach ($r in $required) {
    if (-not (Test-Path -LiteralPath $r.Path)) {
        Write-Host "ERROR: $($r.Name) not found at $($r.Path)" -ForegroundColor Red
        throw "$($r.Name) not found at $($r.Path)"
    }
}

Write-Host "[build-native] DevEco: $deveco" -ForegroundColor Cyan

# ── Env ──
$env:DEVECO_SDK_HOME = $sdkDir
$env:OHOS_NDK_HOME = $ndkDir
$env:JAVA_HOME = Join-Path $deveco 'jbr'
$env:PATH = "$PSScriptRoot;$llvmBin;$jbrBin;$env:PATH"

$cargoManifest = Join-Path $repoRoot 'leantty_ssh\Cargo.toml'
$rustSrcDir   = Join-Path $repoRoot 'leantty_ssh\src'
$buildScript  = Join-Path $repoRoot 'leantty_ssh\build.rs'
$coreManifest = Join-Path $repoRoot 'leantty_ssh\leantty-ssh-core\Cargo.toml'
$coreSrcDir   = Join-Path $repoRoot 'leantty_ssh\leantty-ssh-core\src'
$libsDir       = Join-Path $repoRoot 'entry\libs'
$cargoLock     = Join-Path $repoRoot 'leantty_ssh\Cargo.lock'
$toolchainToml = Join-Path $repoRoot 'rust-toolchain.toml'
$cargoConfig   = Join-Path $repoRoot '.cargo\config.toml'
$rustWslScript = Join-Path $PSScriptRoot 'rust-wsl.ps1'
$clangWslWrapper = Join-Path $PSScriptRoot 'ohos-aarch64-clang-wsl.sh'
$arWslWrapper = Join-Path $PSScriptRoot 'ohos-aarch64-ar-wsl.sh'

# ── Content hash check ──
function Get-SourceHash {
    $inputs = @()
    foreach ($inputFile in @(
        $cargoManifest,
        $cargoLock,
        $buildScript,
        $coreManifest,
        $toolchainToml,
        $cargoConfig,
        $rustWslScript,
        $clangWslWrapper,
        $arWslWrapper
    )) {
        if (Test-Path -LiteralPath $inputFile) {
            $inputs += (Get-FileHash -LiteralPath $inputFile -Algorithm SHA256).Hash
        }
    }
    foreach ($sourceDir in @($rustSrcDir, $coreSrcDir)) {
        Get-ChildItem -LiteralPath $sourceDir -Recurse -Filter '*.rs' -ErrorAction SilentlyContinue |
            Sort-Object FullName |
            ForEach-Object {
                $inputs += (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }
    }
    $combined = $inputs -join '|'
    $hash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($combined))).Replace('-', '')
    return $hash
}

function Test-Stale {
    param($SoPath)
    if ($Force) { return $true }
    if (-not (Test-Path -LiteralPath $SoPath)) { return $true }
    $hashFile = $SoPath + '.build-hash'
    $currentHash = Get-SourceHash
    if (-not (Test-Path -LiteralPath $hashFile)) { return $true }
    $storedHash = (Get-Content -LiteralPath $hashFile -Raw).Trim()
    return $currentHash -ne $storedHash
}

# ── Build ──
$targets = @(
    @{ Target = 'aarch64-unknown-linux-ohos'; Abi = 'arm64-v8a'; Machine = 'AArch64' }
)
$rebuiltTargets = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)

foreach ($t in $targets) {
    $target = $t.Target
    $abi    = $t.Abi
    $soPath = Join-Path $libsDir "$abi\libleantty_ssh.so"

    if (-not (Test-Stale $soPath)) {
        Write-Host "[build-native] $abi up to date, skip" -ForegroundColor Green
        continue
    }
    Write-Host "[build-native] Building $target ..." -ForegroundColor Yellow
    $targetKey = $target.Replace('-', '_')
    $wslNdkDir = ConvertTo-LeanTTYWslPath -WindowsPath $ndkDir -Distribution $WslDistribution
    $wslClangWrapper = ConvertTo-LeanTTYWslPath `
        -WindowsPath (Join-Path $PSScriptRoot 'ohos-aarch64-clang-wsl.sh') `
        -Distribution $WslDistribution
    $wslArWrapper = ConvertTo-LeanTTYWslPath `
        -WindowsPath (Join-Path $PSScriptRoot 'ohos-aarch64-ar-wsl.sh') `
        -Distribution $WslDistribution
    $rustEnvironment = @{
        OHOS_NDK_HOME = $wslNdkDir
        CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER = $wslClangWrapper
        CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_AR = $wslArWrapper
        "CC_$targetKey" = $wslClangWrapper
        "AR_$targetKey" = $wslArWrapper
    }
    $cargoArguments = @(
        'build',
        '--manifest-path', './leantty_ssh/Cargo.toml',
        '--target', $target,
        '--release',
        '--locked'
    )
    if ($Offline) { $cargoArguments += '--offline' }
    Invoke-LeanTTYRustWsl `
        -RepoRoot $repoRoot `
        -Distribution $WslDistribution `
        -Environment $rustEnvironment `
        -CargoArguments $cargoArguments
    [void]$rebuiltTargets.Add($target)
}

# ── Verify & copy ──
if ($SkipCopy) {
    Write-Host '[build-native] Skip copy' -ForegroundColor Yellow
    return
}

$readelf = Join-Path $llvmBin 'llvm-readelf.exe'
foreach ($t in $targets) {
    $cargoOutput = Join-Path $repoRoot "leantty_ssh\target\$($t.Target)\release\libleantty_ssh.so"
    $dest   = Join-Path $libsDir "$($t.Abi)\libleantty_ssh.so"
    if ($rebuiltTargets.Contains($t.Target)) {
        if (-not (Test-Path -LiteralPath $cargoOutput)) {
            throw "$($t.Abi) .so is missing after the ARM64 build"
        }
        $verificationSource = $cargoOutput
    } else {
        if (-not (Test-Path -LiteralPath $dest)) {
            throw "$($t.Abi) cached .so is missing"
        }
        $verificationSource = $dest
    }
    $header = & $readelf -h $verificationSource | Out-String
    if (-not $header.Contains($t.Machine)) {
        throw "ELF arch mismatch: $verificationSource"
    }
    if ($rebuiltTargets.Contains($t.Target)) {
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $cargoOutput -Destination $dest -Force
        Get-SourceHash | Set-Content -LiteralPath ($dest + '.build-hash') -NoNewline
    }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $dest).Hash
    Write-Host "[build-native] $($t.Abi) OK  SHA256=$hash" -ForegroundColor Green
}

Write-Host '[build-native] Done' -ForegroundColor Green
}
