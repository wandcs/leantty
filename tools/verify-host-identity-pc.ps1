<#
.SYNOPSIS
  Verify saved Host IdentityFile behavior on a physical HarmonyOS PC.
.DESCRIPTION
  By default, uses the repository-controlled russh authentication fixture. A
  one-time password bootstraps ssh-copy-id for the fixture's key-install
  account, and the fixture then accepts only the exact installed public-key
  fingerprint. -OpenSshCompatibility instead creates one random disposable WSL
  account on an already running system OpenSSH server and removes it in finally.
  Both modes prove saved-Host authentication before and after app restart,
  password fallback after removing IdentityFile, and recovery after restoring
  the binding. -DefaultEcdsa narrows the OpenSSH mode to one imported standard
  id_ecdsa key and proves default selection before and after restart.
  -PreserveExistingEd25519 first exports an existing id_ed25519 through the
  product command, removes it, then restores and independently audits it in
  finally before deleting the sensitive Downloads backup.
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [Parameter(Mandatory = $true)][string]$HapPath,
    [string]$EvidenceDirectory = '',
    [ValidateRange(20000, 50000)][int]$Port = 0,
    [string]$Distribution = $env:LEANTTY_WSL_DISTRO,
    [string]$UnlockPasswordPath = '',
    [switch]$OpenSshCompatibility,
    [switch]$DefaultEcdsa,
    [switch]$PreserveExistingEd25519
)

$ErrorActionPreference = 'Stop'
if ($DefaultEcdsa -and -not $OpenSshCompatibility) {
    throw '-DefaultEcdsa requires -OpenSshCompatibility'
}
if ($PreserveExistingEd25519 -and -not $DefaultEcdsa) {
    throw '-PreserveExistingEd25519 requires -DefaultEcdsa'
}
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')
. (Join-Path $PSScriptRoot 'release-tooling.ps1')
. (Join-Path $PSScriptRoot 'rust-wsl.ps1')

$startedAt = [DateTimeOffset]::UtcNow
if (-not $Port) { $Port = Get-Random -Minimum 32000 -Maximum 45000 }
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $repoRoot (
        'build\verification\device-host-identity-' + $startedAt.ToString('yyyyMMddTHHmmssfffZ')
    )
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$HapPath = [IO.Path]::GetFullPath($HapPath)
if (-not (Test-Path -LiteralPath $HapPath -PathType Leaf) -or
    (Split-Path $HapPath -Leaf) -match 'unsigned') {
    throw "Host Identity verification requires a signed HAP: $HapPath"
}

$hdc = Resolve-Hdc
$Target = Resolve-LeanTTYRegressionTarget -Hdc $hdc -Target $Target
$harnessCommit = (& git -C $repoRoot rev-parse HEAD 2>&1).Trim().ToLowerInvariant()
$harnessTree = (& git -C $repoRoot rev-parse 'HEAD^{tree}' 2>&1).Trim().ToLowerInvariant()
$harnessDirty = @(& git -C $repoRoot status --porcelain --untracked-files=all 2>&1).Count -gt 0
$candidateHash = (Get-FileHash -LiteralPath $HapPath -Algorithm SHA256).Hash.ToLowerInvariant()
$runSuffix = [Guid]::NewGuid().ToString('N').Substring(0, 10)
$keyName = if ($DefaultEcdsa) { 'id_ecdsa' } else { 'ltty_reg_' + $runSuffix }
$hostAlias = 'host-' + $runSuffix
$fixtureUser = 'key-install'
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$fixtureDirectory = Join-Path $temporaryRoot ('leantty-host-identity-' + $runSuffix)
$fixtureStdout = Join-Path $EvidenceDirectory 'fixture-stdout.log'
$fixtureStderr = Join-Path $EvidenceDirectory 'fixture-stderr.log'
$ecdsaSourceFileName = 'default-ecdsa-' + $runSuffix
$ecdsaLocalSourcePath = Join-Path $fixtureDirectory $ecdsaSourceFileName
$ecdsaImportPath = "/data/storage/el2/base/haps/entry/files/$ecdsaSourceFileName"
$ecdsaSandboxPath = "/data/app/el2/100/base/com.leantty.app/haps/entry/files/$ecdsaSourceFileName"
$ecdsaSourceCleanupRequired = $false
$ecdsaSourceAbsenceAudited = -not $DefaultEcdsa
$keyAbsenceAudited = -not $DefaultEcdsa
$ecdsaSlotOwned = $false
$authorizedKeyCount = $null
$downloadsDirectory = '/storage/Users/currentUser/Download'
$ed25519BackupName = 'leantty-id-ed25519-backup-' + $runSuffix
$ed25519BackupPath = "$downloadsDirectory/$ed25519BackupName"
$ed25519BackupPublicPath = "$ed25519BackupPath.pub"
$ed25519ExportAttempted = $false
$ed25519ExportVerified = $false
$ed25519BackupExported = $false
$ed25519Removed = $false
$ed25519Restored = -not $PreserveExistingEd25519
$ed25519BackupAbsenceAudited = -not $PreserveExistingEd25519
$originalEd25519Fingerprint = ''
$originalConfigDigest = ''
$restoredEd25519Fingerprint = ''
$ed25519PrivateDigestMatched = -not $PreserveExistingEd25519
$ed25519FingerprintMatched = -not $PreserveExistingEd25519
$ed25519ConfigDigestMatched = -not $PreserveExistingEd25519
$fixtureProcess = $null
$fixtureLinuxPid = 0
$fixturePassword = ''
$temporaryWslUser = ''
$temporaryWslUserCreated = $false
$wslPrefix = Get-LeanTTYWslPrefix -Distribution $Distribution
$serverEnvironment = if ($OpenSshCompatibility) {
    if ($DefaultEcdsa) {
        'default-wsl-system-openssh-disposable-account-default-ecdsa'
    } else {
        'default-wsl-system-openssh-disposable-account'
    }
} else {
    'default-wsl-repository-russh-fixture'
}
$mappingActive = $false
$hostPort = $Port
$awakeLeaseActive = $false
$appPid = ''
$connected = $false
$hostCreated = $false
$keyCreated = $false
$cleanupFailures = [Collections.Generic.List[string]]::new()
$checks = [Collections.Generic.List[object]]::new()
$commandObservations = [Collections.Generic.List[object]]::new()
$result = 'failed'
$failure = ''

function Add-HostIdentityCheck {
    param([Parameter(Mandatory = $true)][string]$Name)
    $checks.Add([ordered]@{ name = $Name; result = 'passed' })
}

function Invoke-HostIdentityWslPasswordSet {
    param(
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'wsl.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @($wslPrefix) + @('--exec', 'sudo', '-n', 'chpasswd')) {
        $startInfo.ArgumentList.Add([string]$argument)
    }
    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        $process.StandardInput.Write("$UserName`:$Password`n")
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(10000)) {
            $process.Kill($true)
            throw '[environment] Timed out setting the disposable WSL account password'
        }
        if ($process.ExitCode -ne 0) {
            throw '[environment] Unable to set the disposable WSL account password'
        }
    } finally {
        $process.Dispose()
    }
}

function Get-HostIdentityOpenSshLogLength {
    $lengthText = (@(& wsl.exe @wslPrefix --exec sudo -n stat -c '%s' /var/log/auth.log `
        2>$null) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or $lengthText -notmatch '^\d+$') {
        throw '[environment] Unable to inspect the system OpenSSH authentication log boundary'
    }
    return [long]$lengthText
}

function Assert-HostIdentityOpenSshSession {
    param(
        [Parameter(Mandatory = $true)][string]$Fingerprint,
        [Parameter(Mandatory = $true)][long]$StartIndex
    )

    $pattern = 'Accepted publickey for ' + [regex]::Escape($temporaryWslUser) +
        ' .* ' + [regex]::Escape($Fingerprint)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt 10) {
        $logText = (@(& wsl.exe @wslPrefix --exec sudo -n tail -c "+$($StartIndex + 1)" `
            /var/log/auth.log 2>$null) -join "`n")
        if ($LASTEXITCODE -eq 0 -and $logText -match $pattern) { return }
        Start-Sleep -Milliseconds 200
    }
    throw '[product] System OpenSSH omitted the exact accepted public-key fingerprint'
}

function Focus-HostIdentityInput {
    param([Parameter(Mandatory = $true)][string]$Name)
    $layout = Wait-LeanTTYTerminalInputLayout `
        -Hdc $hdc -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory "$Name.json") -TimeoutSeconds 20
    $inputs = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
    if ($inputs.Count -ne 1) { throw '[environment] Expected one terminal input' }
    $center = Get-LeanTTYBoundsCenter -Bounds ([string]$inputs[0].attributes.bounds)
    Invoke-LeanTTYDeviceClick `
        -Hdc $hdc -Target $Target -X $center.x -Y $center.y `
        -Operation 'Focus Host Identity terminal input'
    return $inputs[0]
}

function Submit-HostIdentityCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Stage
    )
    Submit-LeanTTYDeviceCommand `
        -Hdc $hdc -Target $Target -ProcessId $appPid `
        -Command $Command -Stage $Stage -ObservationSink $commandObservations `
        -InputNodeProvider { param($attempt) Focus-HostIdentityInput -Name "$Stage-$attempt" } |
        Out-Null
}

function Submit-HostIdentityAnswer {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $inputNode = Focus-HostIdentityInput -Name $Name
    Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $Text -InputNode $inputNode
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
}

function Submit-HostIdentitySecret {
    param(
        [Parameter(Mandatory = $true)][string]$Secret,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $inputNode = Focus-HostIdentityInput -Name $Name
    if ($OpenSshCompatibility) {
        foreach ($digit in $Secret.ToCharArray()) {
            if ($digit -lt '0' -or $digit -gt '9') {
                throw '[harness] Physical secret input accepts only disposable numeric passwords'
            }
            Invoke-LeanTTYDevicePhysicalKey `
                -Hdc $hdc -Target $Target -KeyCode (2000 + [int]$digit - [int][char]'0')
        }
    } else {
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $Secret -InputNode $inputNode
    }
    $hiddenLayout = Get-LeanTTYDeviceLayout `
        -Hdc $hdc -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory "$Name-hidden.json")
    Assert-LeanTTYLayoutExcludesValues -Layout $hiddenLayout -Values @($Secret)
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
}

function Wait-HostIdentityLog {
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 20
    )
    Wait-LeanTTYAppLog `
        -Hdc $hdc -Target $Target -ProcessId $appPid `
        -Pattern $Pattern -TimeoutSeconds $TimeoutSeconds | Out-Null
}

function Restart-HostIdentityApp {
    param([Parameter(Mandatory = $true)][string]$LayoutName)
    & $hdc -t $Target shell 'aa force-stop com.leantty.app' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '[environment] Unable to stop LeanTTY for restart' }
    $start = Start-LeanTTYRegressionApp `
        -Hdc $hdc -Target $Target -CredentialPath $UnlockPasswordPath `
        -RepositoryRoot $repoRoot
    $script:appPid = $start.processId
    Wait-LeanTTYTerminalInputLayout `
        -Hdc $hdc -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory "$LayoutName.json") `
        -TimeoutSeconds 20 | Out-Null
}

function Wait-HostIdentityFixtureReady {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt 60) {
        $fixtureProcess.Refresh()
        if ($fixtureProcess.HasExited) {
            throw "[harness] SSH fixture exited before readiness (exit=$($fixtureProcess.ExitCode))"
        }
        $readiness = Read-LeanTTYFixtureReadiness `
            -ControlDirectory $fixtureDirectory `
            -RequiredCredentialNames @('password') `
            -ExpectedAddress "0.0.0.0:$Port"
        if ($null -ne $readiness) { return $readiness }
        Start-Sleep -Milliseconds 200
    }
    throw '[harness] Timed out waiting for the controlled SSH fixture'
}

function Get-HostIdentityFixtureLogLength {
    if (-not (Test-Path -LiteralPath $fixtureStderr -PathType Leaf)) { return 0L }
    return (Get-Item -LiteralPath $fixtureStderr).Length
}

function Wait-HostIdentityFixtureLog {
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [long]$StartIndex = 0,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 20
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $text = Read-LeanTTYSharedTextFile -Path $fixtureStderr
        if ($text.Length -ge $StartIndex -and $text.Substring([int]$StartIndex) -match $Pattern) {
            return
        }
        Start-Sleep -Milliseconds 200
    }
    throw "[product] Controlled SSH fixture omitted expected result: $Pattern"
}

function Test-HostIdentityDefaultKeyFilesPresent {
    param(
        [Parameter(Mandatory = $true)][string]$KeyName
    )

    if ($KeyName -notin @('id_ed25519', 'id_rsa', 'id_ecdsa')) {
        throw 'Host Identity default-key inspection received an unsupported standard name'
    }
    $sshDirectory = '/data/app/el2/100/base/com.leantty.app/haps/entry/files/.ssh'
    $privatePath = "$sshDirectory/$KeyName"
    $publicPath = "$privatePath.pub"
    $condition = (
        "if [ -e $privatePath ] || [ -e $publicPath ]; " +
        'then echo PRESENT; else echo ABSENT; fi'
    )
    $output = @(& $hdc -t $Target shell -b com.leantty.app $condition 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect a standard key in the LeanTTY application sandbox'
    }
    $state = ($output -join "`n").Trim()
    if ($state -eq 'PRESENT') { return $true }
    if ($state -eq 'ABSENT') { return $false }
    throw 'Unexpected standard key-state response from the LeanTTY application sandbox'
}

function Invoke-HostIdentityKeyBackupAcceptance {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('observe', 'verify')][string]$Action
    )

    Submit-HostIdentityCommand `
        -Command "__acceptance_key_backup_$Action $ed25519BackupName" `
        -Stage "preserve-ed25519-$Action"
    $escapedName = [regex]::Escape($ed25519BackupName)
    $logs = Wait-LeanTTYAppLog `
        -Hdc $hdc -Target $Target -ProcessId $appPid `
        -Pattern "ACCEPTANCE_KEY_BACKUP state=(?:observed|verified|absent|failed),name=$escapedName" `
        -TimeoutSeconds 30
    if ($logs -match "ACCEPTANCE_KEY_BACKUP state=failed,name=$escapedName") {
        throw "Private-key backup acceptance failed during $Action"
    }
    if ($Action -eq 'observe') {
        if ($logs -match "ACCEPTANCE_KEY_BACKUP state=absent,name=$escapedName,cleanupComplete=true") {
            return 'absent'
        }
        $match = [regex]::Match(
            $logs,
            "ACCEPTANCE_KEY_BACKUP state=observed,name=$escapedName," +
            'sourcePath=(?<path>/[^,\r\n]+),privateMatch=true,publicMatch=true'
        )
        if (-not $match.Success) {
            throw 'Private-key backup observation was malformed'
        }
        $sourcePath = $match.Groups['path'].Value
        if (-not $sourcePath.EndsWith('/' + $ed25519BackupName, [StringComparison]::Ordinal)) {
            throw 'Private-key backup source escaped the run-owned basename'
        }
        $script:ed25519BackupPath = $sourcePath
        $script:ed25519BackupPublicPath = $sourcePath + '.pub'
        return 'observed'
    }
    if ($logs -notmatch "ACCEPTANCE_KEY_BACKUP state=verified,name=$escapedName," +
        'privateMatch=true,publicBytesMatch=(?:true|false),cleanupComplete=true') {
        throw 'Restored private-key backup verification was malformed'
    }
    return 'verified'
}

function Get-HostIdentityPublicFingerprint {
    param([Parameter(Mandatory = $true)][string]$Path)

    $appPublicPath = '/data/app/el2/100/base/com.leantty.app/haps/entry/files/.ssh/id_ed25519.pub'
    if ($Path -ne $appPublicPath) {
        throw 'Host Identity fingerprint received a path outside the preserved identity'
    }
    $publicText = (@(& $hdc -t $Target shell -b com.leantty.app "cat $Path" 2>&1) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or $publicText -notmatch '^ssh-ed25519\s+') {
        throw 'Unable to read the preserved Ed25519 public key'
    }
    New-Item -ItemType Directory -Path $fixtureDirectory -Force | Out-Null
    $temporaryPublicPath = Join-Path $fixtureDirectory ('fingerprint-' + [Guid]::NewGuid().ToString('N') + '.pub')
    try {
        [IO.File]::WriteAllText(
            $temporaryPublicPath,
            $publicText + "`n",
            [Text.UTF8Encoding]::new($false)
        )
        $wslPublicPath = ConvertTo-LeanTTYWslPath `
            -WindowsPath $temporaryPublicPath -Distribution $Distribution
        $fingerprintOutput = (@(& wsl.exe @wslPrefix -- ssh-keygen -lf $wslPublicPath 2>&1) -join "`n")
        $fingerprint = [regex]::Match($fingerprintOutput, 'SHA256:[A-Za-z0-9+/]+').Value
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($fingerprint)) {
            throw 'Unable to fingerprint the preserved Ed25519 public key'
        }
        return $fingerprint
    } finally {
        Remove-Item -LiteralPath $temporaryPublicPath -Force -ErrorAction SilentlyContinue
        $publicText = ''
    }
}

function Get-HostIdentityConfigDigest {
    $configPath = '/data/app/el2/100/base/com.leantty.app/haps/entry/files/.ssh/config'
    $configText = (@(& $hdc -t $Target shell -b com.leantty.app "cat $configPath" 2>&1) -join "`n")
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read the preserved Host config boundary' }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return [Convert]::ToHexString(
            $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($configText))
        ).ToLowerInvariant()
    } finally {
        $sha256.Dispose()
        $configText = ''
    }
}

function Export-And-Remove-HostIdentityEd25519 {
    if (-not (Test-HostIdentityDefaultKeyFilesPresent -KeyName 'id_ed25519')) {
        throw '[environment] -PreserveExistingEd25519 requires an existing id_ed25519'
    }
    $script:originalEd25519Fingerprint = Get-HostIdentityPublicFingerprint `
        -Path '/data/app/el2/100/base/com.leantty.app/haps/entry/files/.ssh/id_ed25519.pub'
    $script:originalConfigDigest = Get-HostIdentityConfigDigest

    $script:ed25519ExportAttempted = $true
    Submit-HostIdentityCommand `
        -Command "key export id_ed25519 $ed25519BackupName" `
        -Stage 'preserve-ed25519-export'
    if ((Invoke-HostIdentityKeyBackupAcceptance -Action observe) -ne 'observed') {
        throw 'Exported id_ed25519 backup did not match the active identity'
    }
    $script:ed25519ExportVerified = $true
    $script:ed25519BackupExported = $true
    $script:ed25519PrivateDigestMatched = $true

    Submit-HostIdentityCommand -Command 'key rm id_ed25519' -Stage 'preserve-ed25519-remove'
    $dialogWatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            Invoke-LeanTTYDialogButton `
                -Hdc $hdc -Target $Target -ButtonText 'Delete key' `
                -LayoutPath (Join-Path $EvidenceDirectory 'preserve-ed25519-remove-dialog.json')
            break
        } catch { Start-Sleep -Milliseconds 200 }
    } while ($dialogWatch.Elapsed.TotalSeconds -lt 10)
    Wait-HostIdentityLog -Pattern 'KEY_DELETE result=success' -TimeoutSeconds 15
    if (Test-HostIdentityDefaultKeyFilesPresent -KeyName 'id_ed25519') {
        throw 'Product deletion left id_ed25519 active after a verified export'
    }
    $script:ed25519Removed = $true
    Add-HostIdentityCheck -Name 'existing-id-ed25519-exported-and-removed'
}

function Restore-HostIdentityEd25519 {
    if (-not $ed25519BackupExported) { return }

    if (-not $ed25519Removed -and
        -not (Test-HostIdentityDefaultKeyFilesPresent -KeyName 'id_ed25519')) {
        $script:ed25519Removed = $true
    }

    if ($ed25519Removed) {
        Submit-HostIdentityCommand `
            -Command "key import $ed25519BackupPath id_ed25519" `
            -Stage 'restore-ed25519-import'
        Wait-HostIdentityLog -Pattern 'KEY_IMPORT result=success,algorithm=ed25519' -TimeoutSeconds 20
        if (-not (Test-HostIdentityDefaultKeyFilesPresent -KeyName 'id_ed25519')) {
            throw 'Restored id_ed25519 is unavailable after product import'
        }
        Restart-HostIdentityApp -LayoutName 'restore-ed25519-restart-layout'
    }

    $script:restoredEd25519Fingerprint = Get-HostIdentityPublicFingerprint `
        -Path '/data/app/el2/100/base/com.leantty.app/haps/entry/files/.ssh/id_ed25519.pub'
    $script:ed25519FingerprintMatched = (
        $restoredEd25519Fingerprint -ceq $originalEd25519Fingerprint
    )
    if (-not $ed25519FingerprintMatched) {
        throw 'Restored id_ed25519 did not match the exported identity; backup was retained'
    }

    if ((Invoke-HostIdentityKeyBackupAcceptance -Action verify) -ne 'verified') {
        throw 'Restored id_ed25519 private bytes did not match the exported backup'
    }
    $script:ed25519PrivateDigestMatched = $true
    $script:ed25519Restored = $true
    $script:ed25519BackupExported = $false
    $script:ed25519BackupAbsenceAudited = $true
    $script:ed25519ConfigDigestMatched = (
        (Get-HostIdentityConfigDigest) -ceq $originalConfigDigest
    )
    if (-not $ed25519ConfigDigestMatched) {
        throw 'Host config changed while preserving id_ed25519'
    }
    $script:ed25519Removed = $false
    Add-HostIdentityCheck -Name 'existing-id-ed25519-restored-after-restart'
}

function Install-HostIdentityDefaultEcdsa {
    foreach ($defaultName in @('id_ed25519', 'id_rsa', 'id_ecdsa')) {
        if (Test-HostIdentityDefaultKeyFilesPresent -KeyName $defaultName) {
            throw "[environment] Default Identity precondition is not isolated: $defaultName exists"
        }
    }

    New-Item -ItemType Directory -Path $fixtureDirectory -Force | Out-Null
    $sshKeygen = Get-Command ssh-keygen.exe -ErrorAction Stop
    $emptyPassphrase = ''
    & $sshKeygen.Source `
        -q -t ecdsa -b 256 `
        -N $emptyPassphrase `
        -C 'default-ecdsa@leantty-regression' `
        -f $ecdsaLocalSourcePath
    if ($LASTEXITCODE -ne 0 -or
        -not (Test-Path -LiteralPath $ecdsaLocalSourcePath -PathType Leaf)) {
        throw '[harness] Unable to create the temporary default ECDSA import source'
    }

    $script:ecdsaSourceCleanupRequired = $true
    $sendOutput = @(
        & $hdc -t $Target file send -b com.leantty.app `
            $ecdsaLocalSourcePath $ecdsaImportPath 2>&1
    ) -join "`n"
    if ($LASTEXITCODE -ne 0 -or
        $sendOutput -match '(?i)\[Fail\]|error' -or
        $sendOutput -notmatch 'FileTransfer finish') {
        throw "[infrastructure] Unable to send the default ECDSA import source: $sendOutput"
    }
    $sourceCheck = @(
        & $hdc -t $Target shell -b com.leantty.app `
            "stat -c '%a %u %g %s' $ecdsaSandboxPath" 2>&1
    ) -join "`n"
    if ($sourceCheck -notmatch '(?m)^\d{3,4} \d+ \d+ [1-9]\d*$') {
        throw "[infrastructure] Default ECDSA import source is not visible: $sourceCheck"
    }

    $script:ecdsaSlotOwned = $true
    $script:keyCreated = $true
    Submit-HostIdentityCommand `
        -Command "key import $ecdsaImportPath $keyName" `
        -Stage 'import-default-ecdsa'
    Wait-HostIdentityLog -Pattern 'KEY_IMPORT result=success,algorithm=ecdsa-p256'
    if (-not (Test-HostIdentityDefaultKeyFilesPresent -KeyName $keyName)) {
        throw '[product] Imported default id_ecdsa key is unavailable'
    }
    Add-HostIdentityCheck -Name 'imported-standard-id-ecdsa'
}

function Remove-HostIdentityEcdsaImportSource {
    & $hdc -t $Target shell -b com.leantty.app "rm -f $ecdsaSandboxPath" | Out-Null
    $absenceOutput = @(
        & $hdc -t $Target shell -b com.leantty.app "ls $ecdsaSandboxPath" 2>&1
    ) -join "`n"
    if ($absenceOutput -notmatch 'No such file or directory') {
        throw "Temporary default ECDSA source cleanup failed: $absenceOutput"
    }
    $script:ecdsaSourceCleanupRequired = $false
    $script:ecdsaSourceAbsenceAudited = $true
}

function Get-HostIdentityConfigBlock {
    $configText = (@(& $hdc -t $Target shell -b com.leantty.app `
        'cat /data/app/el2/100/base/com.leantty.app/haps/entry/files/.ssh/config' 2>&1) -join "`n")
    $match = [regex]::Match(
        $configText,
        '(?ms)^Host\s+' + [regex]::Escape($hostAlias) + '\s*$\r?\n(?<body>.*?)(?=^Host\s+|\z)'
    )
    if (-not $match.Success) { throw '[product] Saved Host block is missing' }
    return $match.Groups['body'].Value
}

function Close-HostIdentitySession {
    Invoke-LeanTTYDeviceCtrlD -Hdc $hdc -Target $Target
    Wait-HostIdentityLog -Pattern 'SSH closed, exitCode=' -TimeoutSeconds 20
    $script:connected = $false
}

function Connect-HostIdentityAlias {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Fingerprint
    )
    $fixtureOffset = if ($OpenSshCompatibility) {
        Get-HostIdentityOpenSshLogLength
    } else {
        Get-HostIdentityFixtureLogLength
    }
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-HostIdentityCommand -Command "ssh $hostAlias" -Stage $Stage
    Wait-HostIdentityLog -Pattern 'SSH session connected' -TimeoutSeconds 30
    $script:connected = $true
    if ($OpenSshCompatibility) {
        Assert-HostIdentityOpenSshSession -Fingerprint $Fingerprint -StartIndex $fixtureOffset
    } else {
        Wait-HostIdentityFixtureLog `
            -Pattern ('auth method=publickey scenario=KeyInstall fingerprint=' +
                [regex]::Escape($Fingerprint) + ' result=accept') `
            -StartIndex $fixtureOffset -TimeoutSeconds 20
    }
    Close-HostIdentitySession
}

try {
    & (Join-Path $PSScriptRoot 'preflight-device.ps1') `
        -Target $Target -EvidencePath (Join-Path $EvidenceDirectory 'device-preflight.json')
    if ($LASTEXITCODE -ne 0) { throw '[infrastructure] Device preflight failed' }
    Start-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $Target -TimeoutMilliseconds 900000
    $awakeLeaseActive = $true
    & (Join-Path $PSScriptRoot 'dev-pc.ps1') `
        -Target $Target -HapPath $HapPath -SkipBuild -NoLaunch
    if ($LASTEXITCODE -ne 0) { throw '[infrastructure] Signed test HAP deployment failed' }
    if ([string]::IsNullOrWhiteSpace($UnlockPasswordPath)) {
        $UnlockPasswordPath = Get-LeanTTYDeviceUnlockPasswordPath
    }
    Restart-HostIdentityApp -LayoutName 'initial-layout'

    if ($PreserveExistingEd25519) {
        Export-And-Remove-HostIdentityEd25519
    }

    if ($OpenSshCompatibility) {
        $temporaryWslUser = 'ltty' + [Guid]::NewGuid().ToString('N').Substring(0, 10)
        $fixturePassword = [Security.Cryptography.RandomNumberGenerator]::GetInt32(
            10000000,
            100000000
        ).ToString([Globalization.CultureInfo]::InvariantCulture)
        & wsl.exe @wslPrefix --exec sudo -n useradd -m -s /bin/bash -- $temporaryWslUser
        if ($LASTEXITCODE -ne 0) {
            throw '[environment] Unable to create the disposable WSL OpenSSH account'
        }
        $temporaryWslUserCreated = $true
        Invoke-HostIdentityWslPasswordSet `
            -UserName $temporaryWslUser -Password $fixturePassword
        $fixtureUser = $temporaryWslUser
    } else {
        $launcherArguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            (Join-Path $PSScriptRoot 'start-ssh-auth-fixture.ps1'),
            '-ListenAddress', "0.0.0.0:$Port", '-RunSeconds', '900',
            '-ControlDirectory', $fixtureDirectory
        )
        if ($Distribution) { $launcherArguments += @('-Distribution', $Distribution) }
        $fixtureProcess = Start-Process `
            -FilePath (Get-Process -Id $PID).Path -ArgumentList $launcherArguments `
            -RedirectStandardOutput $fixtureStdout -RedirectStandardError $fixtureStderr `
            -WindowStyle Hidden -PassThru
        $readiness = Wait-HostIdentityFixtureReady
        $fixtureLinuxPid = $readiness.linuxPid
        $fixturePassword = [string]$readiness.credentials.password
        $readiness.credentials.Clear()
        $readiness = $null
    }

    $hostPort = if ($OpenSshCompatibility) { 22 } else { $Port }
    $mappingOutput = (@(& $hdc -t $Target rport "tcp:$Port" "tcp:$hostPort" 2>&1) -join "`n")
    if ($LASTEXITCODE -ne 0 -or $mappingOutput -notmatch 'Forwardport result:OK') {
        throw '[infrastructure] Unable to create Host Identity reverse mapping'
    }
    $mappingActive = $true

    if ($DefaultEcdsa) {
        Install-HostIdentityDefaultEcdsa
        Remove-HostIdentityEcdsaImportSource
    } else {
        Submit-HostIdentityCommand `
            -Command "ssh-keygen -t ed25519 -f $keyName -C host-identity-acceptance" `
            -Stage 'generate-identity'
        Wait-HostIdentityLog -Pattern 'Key generated:'
        $keyCreated = $true
    }
    $dedicatedPublicKey = (@(& $hdc -t $Target shell -b com.leantty.app `
        "cat /data/app/el2/100/base/com.leantty.app/haps/entry/files/.ssh/$keyName.pub" 2>&1) -join "`n").Trim()
    $expectedPublicKeyType = if ($DefaultEcdsa) { 'ecdsa-sha2-nistp256' } else { 'ssh-ed25519' }
    if ($dedicatedPublicKey -notmatch ('^' + [regex]::Escape($expectedPublicKeyType) +
        ' [A-Za-z0-9+/]+={0,3}')) {
        throw '[product] Dedicated public key was not generated'
    }
    $publicKeyPath = Join-Path $EvidenceDirectory 'dedicated-key.tmp.pub'
    [IO.File]::WriteAllText($publicKeyPath, $dedicatedPublicKey + "`n", [Text.UTF8Encoding]::new($false))
    $wslPublicKeyPath = ConvertTo-LeanTTYWslPath `
        -WindowsPath $publicKeyPath -Distribution $Distribution
    $wslPrefix = Get-LeanTTYWslPrefix -Distribution $Distribution
    $fingerprintOutput = (@(& wsl.exe @wslPrefix -- ssh-keygen -lf $wslPublicKeyPath 2>&1) -join "`n")
    Remove-Item -LiteralPath $publicKeyPath -Force
    $fingerprint = [regex]::Match($fingerprintOutput, 'SHA256:[A-Za-z0-9+/]+').Value
    if (-not $fingerprint) { throw '[harness] Unable to fingerprint the dedicated public key' }
    $dedicatedPublicKey = ''

    Submit-HostIdentityCommand `
        -Command "host add $hostAlias $fixtureUser@127.0.0.1:$Port -i $keyName" `
        -Stage 'host-add-identity'
    Wait-HostIdentityLog -Pattern 'Host added:'
    $hostCreated = $true
    $configBlock = Get-HostIdentityConfigBlock
    if ($configBlock -notmatch '(?m)^\s*IdentityFile\s+' + [regex]::Escape($keyName) + '\s*$') {
        throw '[product] Saved Host config omitted the dedicated IdentityFile'
    }
    Add-HostIdentityCheck -Name 'host-add-saved-identity'

    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-HostIdentityCommand `
        -Command "ssh-copy-id -i $keyName -p $Port $fixtureUser@127.0.0.1" `
        -Stage 'ssh-copy-id'
    Wait-HostIdentityLog -Pattern 'host_key_prompt:'
    Submit-HostIdentityAnswer -Text 'yes' -Name 'ssh-copy-id-trust'
    Wait-HostIdentityLog -Pattern 'native auth event kind=password, layer=target'
    Submit-HostIdentitySecret -Secret $fixturePassword -Name 'ssh-copy-id-password'
    Wait-HostIdentityLog -Pattern 'Keypush command sent' -TimeoutSeconds 20
    Wait-HostIdentityLog -Pattern 'Key installation completed, status=0' -TimeoutSeconds 20
    if ($OpenSshCompatibility) {
        $authorizedKeyLines = @(
            @(& wsl.exe @wslPrefix --exec sudo -n cat `
                "/home/$temporaryWslUser/.ssh/authorized_keys" 2>$null) |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_) -and
                    -not $_.TrimStart().StartsWith('#')
                }
        )
        $authorizedFingerprint = (@(& wsl.exe @wslPrefix --exec sudo -n ssh-keygen -lf `
            "/home/$temporaryWslUser/.ssh/authorized_keys" 2>&1) -join "`n")
        if ($LASTEXITCODE -ne 0 -or $authorizedFingerprint -notmatch [regex]::Escape($fingerprint)) {
            throw '[product] System OpenSSH authorized_keys omitted the exact installed identity'
        }
        if ($DefaultEcdsa -and
            ($authorizedKeyLines.Count -ne 1 -or
             $authorizedKeyLines[0] -notmatch '^ecdsa-sha2-nistp256\s+')) {
            throw '[product] Disposable OpenSSH account did not authorize only id_ecdsa'
        }
        if ($DefaultEcdsa) {
            $script:authorizedKeyCount = $authorizedKeyLines.Count
            Add-HostIdentityCheck -Name 'temporary-account-authorized-only-id-ecdsa'
        }
    } else {
        Wait-HostIdentityFixtureLog `
            -Pattern ('key-install fingerprint=' + [regex]::Escape($fingerprint) + ' result=installed') `
            -TimeoutSeconds 20
    }
    Add-HostIdentityCheck -Name 'ssh-copy-id-installed-exact-public-key'

    Connect-HostIdentityAlias -Stage 'ssh-alias-before-restart' -Fingerprint $fingerprint
    Add-HostIdentityCheck -Name 'alias-authenticated-with-bound-identity'

    Restart-HostIdentityApp -LayoutName 'restart-layout'
    Connect-HostIdentityAlias -Stage 'ssh-alias-after-restart' -Fingerprint $fingerprint
    Add-HostIdentityCheck -Name 'binding-survived-app-restart'

    Submit-HostIdentityCommand `
        -Command "host set $hostAlias $fixtureUser@127.0.0.1:$Port -i none" `
        -Stage 'host-remove-identity'
    Wait-HostIdentityLog -Pattern 'Host added:'
    $configBlock = Get-HostIdentityConfigBlock
    if ($configBlock -match '(?m)^\s*IdentityFile\s+') {
        throw '[product] Host IdentityFile remained after -i none'
    }
    if ($DefaultEcdsa) {
        Connect-HostIdentityAlias `
            -Stage 'default-ecdsa-before-restart' -Fingerprint $fingerprint
        Add-HostIdentityCheck -Name 'default-ecdsa-authenticated-before-restart'
        Restart-HostIdentityApp -LayoutName 'default-ecdsa-restart-layout'
        Connect-HostIdentityAlias `
            -Stage 'default-ecdsa-after-restart' -Fingerprint $fingerprint
        Add-HostIdentityCheck -Name 'default-ecdsa-authenticated-after-restart'
    } else {
        $fixtureOffset = Get-HostIdentityFixtureLogLength
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Submit-HostIdentityCommand `
            -Command "ssh $hostAlias" -Stage 'default-identity-password-fallback'
        Wait-HostIdentityLog -Pattern 'native auth event kind=password, layer=target' -TimeoutSeconds 30
        if (-not $OpenSshCompatibility) {
            $fixtureLogText = Read-LeanTTYSharedTextFile -Path $fixtureStderr
            $removalFixtureLog = $fixtureLogText.Substring([int]$fixtureOffset)
            if ($removalFixtureLog -match (
                'fingerprint=' + [regex]::Escape($fingerprint) + ' result=accept'
            )) {
                throw '[product] Removing Host IdentityFile still used the dedicated key'
            }
        }
        Add-HostIdentityCheck -Name 'identity-removal-restored-password-fallback'
        Restart-HostIdentityApp -LayoutName 'post-removal-restart-layout'
    }

    Submit-HostIdentityCommand `
        -Command "host set $hostAlias $fixtureUser@127.0.0.1:$Port -i $keyName" `
        -Stage 'host-restore-identity'
    Wait-HostIdentityLog -Pattern 'Host added:'
    Connect-HostIdentityAlias -Stage 'ssh-alias-recovered' -Fingerprint $fingerprint
    Add-HostIdentityCheck -Name 'explicit-binding-recovery'
    $result = 'passed'
} catch {
    $failure = $_.Exception.Message
    if ($appPid -match '^\d+$') {
        try {
            Write-LeanTTYAtomicText `
                -Path (Join-Path $EvidenceDirectory 'failure-app.log') `
                -Content (Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appPid)
        } catch {}
    }
} finally {
    if ($connected) {
        try { Close-HostIdentitySession } catch { $cleanupFailures.Add($_.Exception.Message) }
    }
    if ($appPid -match '^\d+$' -and ($hostCreated -or $keyCreated -or $ed25519BackupExported)) {
        try {
            Restart-HostIdentityApp -LayoutName 'cleanup-reset-layout'
        } catch {
            $cleanupFailures.Add('Cleanup could not reset LeanTTY to an idle prompt')
        }
    }
    if ($appPid -match '^\d+$') {
        if ($hostCreated) {
            try {
                Submit-HostIdentityCommand -Command "host rm $hostAlias" -Stage 'cleanup-host'
                Start-Sleep -Milliseconds 300
                $hostCreated = $false
            } catch { $cleanupFailures.Add('Disposable Host cleanup failed') }
        }
        if ($keyCreated) {
            try {
                Submit-HostIdentityCommand -Command "key rm $keyName" -Stage 'cleanup-key'
                $dialogWatch = [Diagnostics.Stopwatch]::StartNew()
                do {
                    try {
                        Invoke-LeanTTYDialogButton `
                            -Hdc $hdc -Target $Target -ButtonText 'Delete key' `
                            -LayoutPath (Join-Path $EvidenceDirectory 'cleanup-key-dialog.json')
                        break
                    } catch { Start-Sleep -Milliseconds 200 }
                } while ($dialogWatch.Elapsed.TotalSeconds -lt 10)
                Wait-HostIdentityLog -Pattern 'KEY_DELETE result=success' -TimeoutSeconds 15
                $keyStillPresent = if ($DefaultEcdsa) {
                    Test-HostIdentityDefaultKeyFilesPresent -KeyName $keyName
                } else {
                    Test-LeanTTYDeviceKeyFilesPresent `
                        -Hdc $hdc -Target $Target -KeyName $keyName
                }
                if ($keyStillPresent) {
                    throw 'Dedicated key remained after product cleanup'
                }
                if ($DefaultEcdsa) { $script:keyAbsenceAudited = $true }
                $keyCreated = $false
            } catch { $cleanupFailures.Add('Disposable key cleanup failed') }
        }
        try {
            Submit-HostIdentityCommand `
                -Command "ssh-keygen -R [127.0.0.1]:$Port" -Stage 'cleanup-known-host'
        } catch { $cleanupFailures.Add('Known-host cleanup failed') }
        if ($DefaultEcdsa -and $ecdsaSlotOwned) {
            try {
                if (Test-HostIdentityDefaultKeyFilesPresent -KeyName $keyName) {
                    $cleanupFailures.Add('Default id_ecdsa remained after independent cleanup audit')
                    $script:keyAbsenceAudited = $false
                } else {
                    $script:keyAbsenceAudited = $true
                }
            } catch {
                $cleanupFailures.Add('Default id_ecdsa independent cleanup audit failed')
                $script:keyAbsenceAudited = $false
            }
        }
        if ($PreserveExistingEd25519 -and $ed25519ExportAttempted -and
            -not $ed25519BackupExported -and -not $ed25519BackupAbsenceAudited) {
            try {
                $backupState = Invoke-HostIdentityKeyBackupAcceptance -Action observe
                if ($backupState -eq 'observed') {
                    $script:ed25519ExportVerified = $true
                    $script:ed25519PrivateDigestMatched = $true
                    $script:ed25519BackupExported = $true
                } elseif ($backupState -eq 'absent') {
                    $script:ed25519BackupAbsenceAudited = $true
                }
            } catch {
                $cleanupFailures.Add('Sensitive id_ed25519 Downloads backup state is ambiguous')
            }
        }
        if ($PreserveExistingEd25519 -and $ed25519BackupExported) {
            try {
                Restore-HostIdentityEd25519
            } catch {
                $cleanupFailures.Add('Existing id_ed25519 restoration failed: ' + $_.Exception.Message)
            }
        }
    }
    if ($ecdsaSourceCleanupRequired) {
        try {
            Remove-HostIdentityEcdsaImportSource
        } catch {
            $cleanupFailures.Add('Default ECDSA import source cleanup failed')
        }
    }
    if ($PreserveExistingEd25519 -and -not $ed25519ExportAttempted) {
        $script:ed25519BackupAbsenceAudited = $true
    }
    if ($mappingActive) {
        & $hdc -t $Target fport rm "tcp:$Port" "tcp:$hostPort" 2>$null | Out-Null
        $mappingState = (@(& $hdc -t $Target fport ls 2>&1) -join "`n")
        if ($mappingState -match "(?m)tcp:$Port\s+tcp:$hostPort\s+\[Reverse\]") {
            $cleanupFailures.Add('Reverse mapping remained after cleanup')
        }
        $mappingActive = $false
    }
    if ($fixtureLinuxPid -gt 0) {
        try {
            $wslPrefix = Get-LeanTTYWslPrefix -Distribution $Distribution
            & wsl.exe @wslPrefix --exec kill -TERM $fixtureLinuxPid 2>$null | Out-Null
        } catch { $cleanupFailures.Add('Controlled SSH fixture Linux process cleanup failed') }
        $fixtureLinuxPid = 0
    }
    if ($null -ne $fixtureProcess -and -not $fixtureProcess.HasExited) {
        Wait-Process -Id $fixtureProcess.Id -Timeout 15 -ErrorAction SilentlyContinue
        $fixtureProcess.Refresh()
        if (-not $fixtureProcess.HasExited) {
            Stop-Process -Id $fixtureProcess.Id -Force -ErrorAction SilentlyContinue
            $cleanupFailures.Add('Controlled SSH fixture launcher required forced cleanup')
        }
    }
    if ($temporaryWslUserCreated) {
        & wsl.exe @wslPrefix --exec sudo -n pkill -KILL -u $temporaryWslUser 2>$null | Out-Null
        & wsl.exe @wslPrefix --exec sudo -n userdel -r -- $temporaryWslUser 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $cleanupFailures.Add('Disposable WSL OpenSSH account deletion failed')
        } else {
            & wsl.exe @wslPrefix --exec id -u $temporaryWslUser 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $cleanupFailures.Add('Disposable WSL OpenSSH account remained after cleanup')
            } else {
                $temporaryWslUserCreated = $false
            }
        }
    }
    if ($awakeLeaseActive) {
        try { Stop-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $Target } catch {
            $cleanupFailures.Add('Screen-timeout policy restore failed')
        }
        $awakeLeaseActive = $false
    }
    foreach ($logPath in @($fixtureStdout, $fixtureStderr, (Join-Path $EvidenceDirectory 'failure-app.log'))) {
        if (-not [string]::IsNullOrEmpty($fixturePassword) -and
            (Test-Path -LiteralPath $logPath -PathType Leaf) -and
            (Read-LeanTTYSharedTextFile -Path $logPath).Contains($fixturePassword)) {
            $cleanupFailures.Add('Temporary fixture credential appeared in diagnostic evidence')
        }
    }
    $fixturePassword = ''
    $tempPrefix = $temporaryRoot + [IO.Path]::DirectorySeparatorChar
    if ((Test-Path -LiteralPath $fixtureDirectory) -and
        [IO.Path]::GetFullPath($fixtureDirectory).StartsWith(
            $tempPrefix,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force
    }
    if ($cleanupFailures.Count -gt 0) { $result = 'invalid/interrupted' }
    $evidence = [ordered]@{
        schemaVersion = 1
        gate = 'device-behavior'
        scenario = 'host-identity-binding'
        result = $result
        runMode = 'diagnostic'
        releaseEligible = $false
        startedAt = $startedAt.ToString('o')
        completedAt = [DateTimeOffset]::UtcNow.ToString('o')
        candidate = [ordered]@{ sha256 = $candidateHash; role = 'test-signed-diagnostic-hap' }
        harness = [ordered]@{
            gitCommit = $harnessCommit
            gitTree = $harnessTree
            gitDirty = $harnessDirty
        }
        server = [ordered]@{
            environment = $serverEnvironment
            scenario = $(if ($OpenSshCompatibility) { 'system-openssh' } else { 'key-install' })
            endpoint = 'ephemeral-reverse-port'
        }
        identity = [ordered]@{
            mode = $(if ($DefaultEcdsa) { 'default-id-ecdsa' } else { 'explicit-random-ed25519' })
            authorizedKeyCount = $authorizedKeyCount
            independentKeyAbsenceAudit = $keyAbsenceAudited
            independentEcdsaSourceAbsenceAudit = $ecdsaSourceAbsenceAudited
            preservedEd25519 = [ordered]@{
                selected = [bool]$PreserveExistingEd25519
                productExportVerified = $(if ($PreserveExistingEd25519) {
                    $ed25519ExportVerified
                } else { $null })
                productRemovalVerified = $(if ($PreserveExistingEd25519) {
                    $ed25519Removed -or $ed25519Restored
                } else { $null })
                restoredAfterRestart = $(if ($PreserveExistingEd25519) {
                    $ed25519Restored
                } else { $null })
                privateDigestMatched = $(if ($PreserveExistingEd25519) {
                    $ed25519PrivateDigestMatched
                } else { $null })
                publicFingerprintMatched = $(if ($PreserveExistingEd25519) {
                    $ed25519FingerprintMatched
                } else { $null })
                hostConfigDigestMatched = $(if ($PreserveExistingEd25519) {
                    $ed25519ConfigDigestMatched
                } else { $null })
                independentEd25519BackupAbsenceAudit = $ed25519BackupAbsenceAudited
                backupRetainedForRecovery = $ed25519BackupExported
                backupName = $(if ($ed25519BackupExported) { $ed25519BackupName } else { $null })
            }
        }
        checks = @($checks)
        commandAutomation = Get-LeanTTYDeviceCommandAutomationSummary `
            -Observations $commandObservations `
            -BusinessVerdict $(if ($result -eq 'passed') { 'passed' } else { 'failed' }) `
            -BusinessPostcondition $(if ($DefaultEcdsa) {
                'saved-id-ecdsa-default-before-after-restart-and-cleanup'
            } else {
                'saved-identity-copy-restart-remove-fallback-recover'
            })
        cleanup = [ordered]@{
            result = $(if ($cleanupFailures.Count -eq 0) { 'passed' } else { 'failed' })
            detail = $(if ($cleanupFailures.Count -eq 0) {
                'host-key-known-host-server-state-reverse-port-and-screen-policy-removed-or-restored'
            } else { $cleanupFailures -join '; ' })
        }
        failure = $failure
    }
    Write-LeanTTYAtomicJson `
        -Path (Join-Path $EvidenceDirectory 'device-host-identity.json') `
        -Value $evidence -Depth 10
}

if ($result -ne 'passed') {
    throw "HOST IDENTITY $result`: $failure; evidence=$EvidenceDirectory"
}
Write-Host "DEVICE BEHAVIOR SUCCESS: host-identity-binding evidence=$EvidenceDirectory" `
    -ForegroundColor Green
