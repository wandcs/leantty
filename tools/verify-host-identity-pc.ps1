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
  the binding.
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [Parameter(Mandatory = $true)][string]$HapPath,
    [string]$EvidenceDirectory = '',
    [ValidateRange(20000, 50000)][int]$Port = 0,
    [string]$Distribution = $env:LEANTTY_WSL_DISTRO,
    [string]$UnlockPasswordPath = '',
    [switch]$OpenSshCompatibility
)

$ErrorActionPreference = 'Stop'
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
$keyName = 'ltty_reg_' + $runSuffix
$hostAlias = 'host-' + $runSuffix
$fixtureUser = 'key-install'
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$fixtureDirectory = Join-Path $temporaryRoot ('leantty-host-identity-' + $runSuffix)
$fixtureStdout = Join-Path $EvidenceDirectory 'fixture-stdout.log'
$fixtureStderr = Join-Path $EvidenceDirectory 'fixture-stderr.log'
$fixtureProcess = $null
$fixtureLinuxPid = 0
$fixturePassword = ''
$temporaryWslUser = ''
$temporaryWslUserCreated = $false
$wslPrefix = Get-LeanTTYWslPrefix -Distribution $Distribution
$serverEnvironment = if ($OpenSshCompatibility) {
    'default-wsl-system-openssh-disposable-account'
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

    Submit-HostIdentityCommand `
        -Command "ssh-keygen -t ed25519 -f $keyName -C host-identity-acceptance" `
        -Stage 'generate-identity'
    Wait-HostIdentityLog -Pattern 'Key generated:'
    $keyCreated = $true
    $dedicatedPublicKey = (@(& $hdc -t $Target shell -b com.leantty.app `
        "cat /data/app/el2/100/base/com.leantty.app/haps/entry/files/.ssh/$keyName.pub" 2>&1) -join "`n").Trim()
    if ($dedicatedPublicKey -notmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,3}') {
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
        $authorizedFingerprint = (@(& wsl.exe @wslPrefix --exec sudo -n ssh-keygen -lf `
            "/home/$temporaryWslUser/.ssh/authorized_keys" 2>&1) -join "`n")
        if ($LASTEXITCODE -ne 0 -or $authorizedFingerprint -notmatch [regex]::Escape($fingerprint)) {
            throw '[product] System OpenSSH authorized_keys omitted the exact installed identity'
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
    $fixtureOffset = Get-HostIdentityFixtureLogLength
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-HostIdentityCommand -Command "ssh $hostAlias" -Stage 'default-identity-password-fallback'
    Wait-HostIdentityLog -Pattern 'native auth event kind=password, layer=target' -TimeoutSeconds 30
    if (-not $OpenSshCompatibility) {
        $removalFixtureLog = (Read-LeanTTYSharedTextFile -Path $fixtureStderr).Substring([int]$fixtureOffset)
        if ($removalFixtureLog -match ('fingerprint=' + [regex]::Escape($fingerprint) + ' result=accept')) {
            throw '[product] Removing Host IdentityFile still used the dedicated key'
        }
    }
    Add-HostIdentityCheck -Name 'identity-removal-restored-password-fallback'

    Restart-HostIdentityApp -LayoutName 'post-removal-restart-layout'
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
                if (Test-LeanTTYDeviceKeyFilesPresent -Hdc $hdc -Target $Target -KeyName $keyName) {
                    throw 'Dedicated key remained after product cleanup'
                }
                $keyCreated = $false
            } catch { $cleanupFailures.Add('Disposable key cleanup failed') }
        }
        try {
            Submit-HostIdentityCommand `
                -Command "ssh-keygen -R [127.0.0.1]:$Port" -Stage 'cleanup-known-host'
        } catch { $cleanupFailures.Add('Known-host cleanup failed') }
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
        checks = @($checks)
        commandAutomation = Get-LeanTTYDeviceCommandAutomationSummary `
            -Observations $commandObservations `
            -BusinessVerdict $(if ($result -eq 'passed') { 'passed' } else { 'failed' }) `
            -BusinessPostcondition 'saved-identity-copy-restart-remove-fallback-recover'
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
