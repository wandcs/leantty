param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'device-package.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('LeanTTY-package-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
function Assert-Rejected([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw "Expected package rejection: $Pattern"
}
function New-TestHap([object]$Debug, [string]$Markers = '', [string]$Bundle = 'com.leantty.app',
    [string[]]$Abis = @('arm64-v8a')) {
    $path = Join-Path $testRoot ([guid]::NewGuid().ToString('N') + '.hap')
    $zip = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $items = @(
            @{ name = 'module.json'; content = (@{app=@{debug=$Debug;bundleName=$Bundle;versionName='1.6.0'};module=@{name='entry';type='entry'}} | ConvertTo-Json -Depth 4 -Compress) },
            @{ name = 'ets/modules.abc'; content = $Markers }
        )
        foreach ($abi in $Abis) { $items += @{ name = "libs/$abi/libleantty_ssh.so"; content = 'synthetic' } }
        foreach ($item in $items) {
            $writer = [IO.StreamWriter]::new($zip.CreateEntry($item.name).Open())
            try { $writer.Write($item.content) } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose() }
    return $path
}
# Only the SDK signature boundary is stubbed. Real ZIP parsing and policy run.
function Read-LeanTTYVerifiedHapProfile {
    param([string]$HapPath)
    if ($script:signatureFails) { throw '[harness] HAP signature verification failed' }
    return [pscustomobject]@{ type=$script:profileType; bundleName=$script:profileBundle }
}
try {
    $script:signatureFails = $false
    $script:profileType = 'debug'
    $script:profileBundle = 'com.leantty.app'
    $review = New-TestHap $false
    $debug = New-TestHap $true 'ACCEPTANCE_INPUT_SUBMIT ACCEPTANCE_INPUT_NATIVE'
    $admitted = Assert-LeanTTYDeviceHap -HapPath $review -Purpose review-smoke
    if ($admitted.buildMode -cne 'release' -or $admitted.profileType -cne 'debug') { throw 'Review role mismatch' }
    Assert-LeanTTYDeviceHap -HapPath $debug -Purpose acceptance | Out-Null
    Assert-Rejected { Assert-LeanTTYDeviceHap $review acceptance } 'release-mode.*acceptance'
    Assert-Rejected { Assert-LeanTTYDeviceHap $debug review-smoke } 'review smoke requires release-mode'
    Assert-Rejected { Assert-LeanTTYDeviceHap (New-TestHap $true) acceptance } 'missing acceptance'
    Assert-Rejected { Assert-LeanTTYDeviceHap (New-TestHap $false 'ACCEPTANCE_RUNTIME_RECOVERY') review-smoke } 'acceptance-only marker'
    foreach ($marker in @('ACCEPTANCE_MOSH_INPUT_REJECTION', 'mosh_arm_input_rejection_for_acceptance',
        'moshArmInputRejectionForAcceptance', 'armMoshInputRejectionForAcceptance',
        'acceptance_reject_input', 'acceptanceRejectMoshInput')) {
        Assert-Rejected { Assert-LeanTTYDeviceHap (New-TestHap $false $marker) review-smoke } 'acceptance-only marker'
    }
    Assert-Rejected { Assert-LeanTTYDeviceHap (New-TestHap 'false') review-smoke } 'debug.*boolean'
    Assert-Rejected { Assert-LeanTTYDeviceHap (New-TestHap $null) review-smoke } 'debug.*boolean'
    Assert-Rejected { Assert-LeanTTYDeviceHap (New-TestHap $false '' 'wrong.bundle') review-smoke } 'bundle'
    Assert-Rejected { Assert-LeanTTYDeviceHap (New-TestHap $false -Abis @()) review-smoke } 'only ARM64'
    Assert-Rejected { Assert-LeanTTYDeviceHap (New-TestHap $false -Abis @('x86_64')) review-smoke } 'only ARM64'
    Assert-Rejected { Assert-LeanTTYDeviceHap (New-TestHap $false -Abis @('arm64-v8a','x86_64')) review-smoke } 'only ARM64'
    $script:profileBundle = 'wrong.profile.bundle'
    Assert-Rejected { Assert-LeanTTYDeviceHap $review review-smoke } 'bundle'
    $script:profileBundle = 'com.leantty.app'
    $script:profileType = 'release'
    # A neutral filename must not hide a production Profile.
    Assert-Rejected { Assert-LeanTTYDeviceHap $review review-smoke } 'production.*Profile'
    $script:profileType = 'unknown'
    Assert-Rejected { Assert-LeanTTYDeviceHap $review review-smoke } 'Profile'
    $script:profileType = 'debug'
    $script:signatureFails = $true
    Assert-Rejected { Assert-LeanTTYDeviceHap $review review-smoke } 'signature verification failed'
    $script:signatureFails = $false
    $app = Join-Path $testRoot 'renamed.app'
    Copy-Item -LiteralPath $review -Destination $app
    Assert-Rejected { Assert-LeanTTYDeviceHap $app review-smoke } 'signed HAP'

    # Exercise the upgrade install function and its real call sites without a PC.
    # The legacy baseline predates acceptance markers; only the candidate needs them.
    $tokens = $null
    $parseErrors = $null
    $upgrade = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'verify-startup-upgrade-pc.ps1'), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -ne 0) { throw 'Upgrade script parse failed' }
    $installer = $upgrade.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Install-StartupUpgradeHap'
    }, $true)
    . ([scriptblock]::Create($installer.Extent.Text))
    $calls = @($upgrade.FindAll({ param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Install-StartupUpgradeHap'
    }, $true))
    if ($calls.Count -ne 2) { throw 'Expected baseline and candidate upgrade installs' }
    $script:installs = [Collections.Generic.List[string]]::new()
    $script:target = 'synthetic-target'
    $script:hdc = {
        $script:installs.Add([string]$args[-1])
        $global:LASTEXITCODE = 0
        'install bundle successfully'
    }
    $v13Hap = New-TestHap $true
    $candidateHap = $debug
    foreach ($call in $calls) { & ([scriptblock]::Create($call.Extent.Text)) }
    if ($script:installs.Count -ne 2 -or $script:installs[0] -cne $v13Hap -or
        $script:installs[1] -cne $candidateHap) { throw 'Upgrade did not admit baseline then candidate' }
    $candidateHap = $v13Hap
    Assert-Rejected { & ([scriptblock]::Create($calls[1].Extent.Text)) } 'missing acceptance'
    if ($script:installs.Count -ne 2) { throw 'Invalid candidate reached HDC' }
    $script:profileType = 'release'
    Assert-Rejected { & ([scriptblock]::Create($calls[0].Extent.Text)) } 'production.*Profile'
    if ($script:installs.Count -ne 2) { throw 'Production baseline reached HDC' }
    # Artifact boundary: every direct installer must admit the HAP before HDC.
    foreach ($file in @('dev-pc.ps1', 'diagnose-text-input-pc.ps1', 'verify-terminal-search-pc.ps1',
        'verify-startup-warm-pc.ps1', 'verify-startup-upgrade-pc.ps1', 'verify-unexpected-recovery-uninstall-pc.ps1')) {
        $content = Get-Content -LiteralPath (Join-Path $PSScriptRoot $file) -Raw
        if ($content -notmatch '(?s)Assert-LeanTTYDeviceHap.*?install.*?-r') {
            throw "Installation missing package admission: $file"
        }
    }
    Write-Host 'DEVICE PACKAGE POLICY TESTS PASSED'
} finally {
    # Exactly the unique directory created above, never a repository or profile root.
    if (-not ([IO.Path]::GetFullPath($testRoot)).StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unsafe package-test cleanup target'
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
