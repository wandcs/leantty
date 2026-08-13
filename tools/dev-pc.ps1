<#
.SYNOPSIS
  Incrementally build, install, and launch LeanTTY on a HarmonyOS PC.
.DESCRIPTION
  This is the default high-frequency development command. It builds only the
  ARM64 debug target, uses the locally configured test signature, replaces the
  installed app, launches it, and verifies that its process is running.
#>
param(
    [string]$Target = '',
    [string]$UnlockPasswordPath = '',
    [string]$HapPath = '',
    [switch]$Clean,
    [switch]$ForceNative,
    [switch]$SkipBuild,
    [switch]$LatestCandidate,
    [switch]$NoLaunch,
    [switch]$FollowLogs,
    [switch]$RequireUsb
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'build-lock.ps1')
. (Join-Path $PSScriptRoot 'candidate-store.ps1')
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')

Invoke-WithLeanTTYBuildLock -RepoRoot $repoRoot -Operation 'dev-pc' -Action {
if ($LatestCandidate) {
    if (-not [string]::IsNullOrWhiteSpace($HapPath) -or $Clean -or $ForceNative) {
        throw '-LatestCandidate cannot be combined with -HapPath, -Clean or -ForceNative'
    }
    $candidate = Get-LeanTTYLatestVerifiedCandidate -RepoRoot $repoRoot
    if ($null -eq $candidate) {
        throw 'No verified LeanTTY candidate is retained for this repository'
    }
    $HapPath = $candidate.hapPath
    $SkipBuild = $true
    Write-Host (
        "Using latest $($candidate.verificationMode)-verified candidate: " +
        "$HapPath (SHA256=$($candidate.sha256))"
    ) -ForegroundColor Cyan
}

$hdc = Resolve-Hdc
if ([string]::IsNullOrWhiteSpace($Target)) {
    $readyTargets = @(Get-HdcTargets -Hdc $hdc | Where-Object {
        $_.transport -match '^(USB|TCP)$' -and $_.status -match '^(Ready|Connected)$'
    })
    $usbTargets = @($readyTargets | Where-Object { $_.transport -eq 'USB' })
    $candidates = if ($usbTargets.Count -gt 0) { $usbTargets } else { $readyTargets }
    if ($candidates.Count -eq 1) {
        $Target = $candidates[0].key
    } elseif ($candidates.Count -gt 1) {
        $keys = ($candidates | ForEach-Object { $_.key }) -join ', '
        throw "Multiple HarmonyOS PCs are connected ($keys). Pass -Target explicitly."
    } else {
        throw 'No ready USB or TCP HarmonyOS PC found. Connect the test PC or pass -Target explicitly.'
    }
}
$transport = Get-HdcTargetTransport -Hdc $hdc -Target $Target
if ($RequireUsb -and $transport -ne 'usb') {
    throw "Target $Target uses $transport, not USB."
}

$probe = Invoke-HdcShell -Hdc $hdc -Target $Target -Command 'echo LEANTTY_PC_READY'
if ($probe -notmatch 'LEANTTY_PC_READY') { throw "HarmonyOS PC is not reachable: $Target" }
$model = (Invoke-HdcShell $hdc $Target 'param get const.product.model').Trim()
$abi = (Invoke-HdcShell $hdc $Target 'param get const.product.cpu.abilist').Trim()
if ($abi -notmatch 'arm64-v8a') { throw "Target $Target is not an ARM64 HarmonyOS PC: $abi" }
Write-Host "HarmonyOS PC: $model ($Target, $transport, $abi)" -ForegroundColor Cyan

if (-not $SkipBuild) {
    $buildArgs = @{ BuildMode = 'debug' }
    if ($Clean) { $buildArgs['Clean'] = $true }
    if ($ForceNative) { $buildArgs['ForceNative'] = $true }
    & (Join-Path $PSScriptRoot 'build-all.ps1') @buildArgs
    if ($LASTEXITCODE -ne 0) { throw 'ARM64 PC debug build failed' }
}

if ([string]::IsNullOrWhiteSpace($HapPath)) {
    $HapPath = Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
}
if (-not (Test-Path -LiteralPath $HapPath)) {
    throw "Signed test HAP not found: $HapPath. Create ignored signing.local.json5 with the local test identity."
}
if ((Split-Path $HapPath -Leaf) -match 'unsigned') {
    throw 'A physical HarmonyOS PC requires a signed HAP.'
}

$installOutput = (& $hdc -t $Target install -r $HapPath 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0 -or $installOutput -match '(?i)\[Fail\]|error') {
    throw "HAP install failed: $installOutput"
}
Write-Host 'INSTALL SUCCESS' -ForegroundColor Green

if (-not $NoLaunch) {
    if ([string]::IsNullOrWhiteSpace($UnlockPasswordPath)) {
        $UnlockPasswordPath = Get-LeanTTYDeviceUnlockPasswordPath
    }
    $start = Start-LeanTTYRegressionApp `
        -Hdc $hdc `
        -Target $Target `
        -CredentialPath $UnlockPasswordPath `
        -RepositoryRoot $repoRoot
    Write-Host (
        "LeanTTY started. PID=$($start.processId), unlock=$($start.unlock)"
    ) -ForegroundColor Green
}

if ($FollowLogs) {
    Write-Host 'Following LeanTTY logs. Press Ctrl+C to stop.' -ForegroundColor Cyan
    & $hdc -t $Target hilog | Select-String 'LeanTTY|LTTY_SSH|EntryAbility'
}
}
