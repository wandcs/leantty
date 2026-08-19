function Resolve-LeanTTYRegressionTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [string]$Target = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($Target)) {
        Assert-HdcTargetReady -Hdc $Hdc -Target $Target | Out-Null
        return $Target
    }
    $readyTargets = @(Get-HdcTargets -Hdc $Hdc | Where-Object {
        $_.transport -match '^(USB|TCP)$' -and $_.status -match '^(Ready|Connected)$'
    })
    $usbTargets = @($readyTargets | Where-Object { $_.transport -eq 'USB' })
    $candidates = if ($usbTargets.Count -gt 0) { $usbTargets } else { $readyTargets }
    if ($candidates.Count -eq 1) { return $candidates[0].key }
    if ($candidates.Count -eq 0) {
        throw '[infrastructure] No ready physical HarmonyOS PC found for device regression'
    }
    throw '[environment] Multiple HarmonyOS PCs are connected; pass -Target explicitly'
}

function Start-LeanTTYDeviceAwakeLease {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [ValidateRange(60000, 28800000)][int]$TimeoutMilliseconds = 1800000
    )

    Invoke-HdcChecked `
        -Hdc $Hdc `
        -Target $Target `
        -Arguments @('shell', 'power-shell wakeup') `
        -Operation 'HarmonyOS regression PC wakeup' | Out-Null
    $output = Invoke-HdcChecked `
        -Hdc $Hdc `
        -Target $Target `
        -Arguments @('shell', "power-shell timeout -o $TimeoutMilliseconds") `
        -Operation 'HarmonyOS regression screen-timeout lease'
    if ($output -notmatch 'Override screen off time') {
        throw 'Unable to acquire the HarmonyOS regression screen-timeout lease'
    }
}

function Stop-LeanTTYDeviceAwakeLease {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $output = Invoke-HdcChecked `
        -Hdc $Hdc `
        -Target $Target `
        -Arguments @('shell', 'power-shell timeout -r 0') `
        -Operation 'HarmonyOS regression screen-timeout restore'
    if ($output -notmatch 'Restore screen off time') {
        throw 'Unable to restore the HarmonyOS regression screen timeout'
    }
}

function Get-LeanTTYDeviceUnlockPasswordPath {
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw 'Unable to resolve the current Windows user LocalAppData directory'
    }
    return Join-Path $localAppData 'LeanTTY\regression\device-unlock-password.txt'
}

function Assert-LeanTTYCredentialPathOutsideRepository {
    param(
        [Parameter(Mandatory = $true)][string]$CredentialPath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    $credentialFullPath = [IO.Path]::GetFullPath($CredentialPath)
    $repositoryPrefix = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/') + `
        [IO.Path]::DirectorySeparatorChar
    if ($credentialFullPath.StartsWith(
        $repositoryPrefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Device unlock credential must be stored outside the repository'
    }
}

function ConvertTo-LeanTTYDevicePasswordKeyCommand {
    param([Parameter(Mandatory = $true)][string]$Password)

    if ($Password -notmatch '^[a-z]{1,64}$') {
        throw 'Device unlock password must contain only lowercase ASCII letters'
    }
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add('uinput -K')
    foreach ($character in $Password.ToCharArray()) {
        $keyCode = 2017 + ([int]$character - [int][char]'a')
        $parts.Add("-d $keyCode -u $keyCode")
    }
    $parts.Add('-d 2054 -u 2054')
    return $parts -join ' '
}

function Start-LeanTTYRegressionApp {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$CredentialPath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    Assert-LeanTTYCredentialPathOutsideRepository `
        -CredentialPath $CredentialPath `
        -RepositoryRoot $RepositoryRoot
    $launchCommand = 'aa start -a EntryAbility -b com.leantty.app'
    $launchOutput = @(& $Hdc -t $Target shell $launchCommand 2>&1) -join "`n"
    $launchExitCode = $LASTEXITCODE
    $deviceLocked = $launchOutput -match 'Error Code:10106102|device screen is locked'
    if ($launchExitCode -ne 0 -and -not $deviceLocked) {
        throw 'LeanTTY application launch command failed before device unlock detection'
    }
    if ($launchOutput -match '(?i)\[Fail\]|error' -and -not $deviceLocked) {
        throw "LeanTTY application launch failed: $launchOutput"
    }

    $unlockResult = 'not-required'
    if ($deviceLocked) {
        if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
            throw "Locked regression PC requires local credential file: $CredentialPath"
        }
        $password = [IO.File]::ReadAllText($CredentialPath).TrimEnd("`r", "`n")
        try {
            $keyCommand = ConvertTo-LeanTTYDevicePasswordKeyCommand -Password $password
            & $Hdc -t $Target shell 'power-shell wakeup' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Unable to wake the locked regression PC' }
            & $Hdc -t $Target shell 'uinput -K -d 2050 -u 2050' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Unable to focus the regression PC unlock prompt' }
            Start-Sleep -Milliseconds 500
            & $Hdc -t $Target shell $keyCommand | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Unable to inject regression PC unlock key events' }
        } finally {
            $password = ''
            $keyCommand = ''
        }
        Start-Sleep -Milliseconds 800
        $launchOutput = @(& $Hdc -t $Target shell $launchCommand 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $launchOutput -match '(?i)\[Fail\]|error') {
            throw 'Regression PC remained locked after local credential injection'
        }
        $unlockResult = 'local-plaintext-credential'
    }

    Start-Sleep -Milliseconds 800
    $processId = (@(& $Hdc -t $Target shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or $processId -notmatch '^\d+$') {
        throw 'LeanTTY application PID is unavailable after launch'
    }
    return [pscustomobject]@{
        processId = $processId
        unlock = $unlockResult
    }
}

function Get-LeanTTYLayoutNodes {
    param([Parameter(Mandatory = $true)]$Node)

    $nodes = [Collections.Generic.List[object]]::new()
    $nodes.Add($Node)
    foreach ($child in @($Node.children)) {
        foreach ($descendant in @(Get-LeanTTYLayoutNodes -Node $child)) {
            $nodes.Add($descendant)
        }
    }
    return @($nodes)
}

function Get-LeanTTYBoundsCenter {
    param([Parameter(Mandatory = $true)][string]$Bounds)

    $match = [regex]::Match($Bounds, '^\[(?<x1>\d+),(?<y1>\d+)\]\[(?<x2>\d+),(?<y2>\d+)\]$')
    if (-not $match.Success) { throw "Invalid UI bounds: $Bounds" }
    return [pscustomobject]@{
        x = [int](([int]$match.Groups['x1'].Value + [int]$match.Groups['x2'].Value) / 2)
        y = [int](([int]$match.Groups['y1'].Value + [int]$match.Groups['y2'].Value) / 2)
    }
}

function Invoke-LeanTTYSerializedUiTest {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Operation
    )

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $targetHash = [Convert]::ToHexString(
            $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($Target.ToLowerInvariant()))
        ).Substring(0, 16)
    } finally {
        $sha256.Dispose()
    }
    $mutex = [Threading.Mutex]::new($false, "Local\LeanTTY.UiTest.$targetHash")
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne(60000)
        } catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw '[harness] UiTest control channel remained busy for 60 seconds'
        }
        return Invoke-HdcChecked `
            -Hdc $Hdc `
            -Target $Target `
            -Arguments (@('shell', 'uitest') + $Arguments) `
            -Operation $Operation `
            -FailureDomain 'environment'
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-LeanTTYDeviceClick {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y,
        [string]$Operation = 'HarmonyOS UI click'
    )

    Invoke-LeanTTYSerializedUiTest `
        -Hdc $Hdc `
        -Target $Target `
        -Arguments @('uiInput', 'click', $X, $Y) `
        -Operation $Operation | Out-Null
}

function Get-LeanTTYDeviceLayout {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$LocalPath
    )

    for ($captureAttempt = 1; $captureAttempt -le 2; $captureAttempt++) {
        $remotePath = '/data/local/tmp/leantty-layout-' + [Guid]::NewGuid().ToString('N') + '.json'
        try {
            Invoke-LeanTTYSerializedUiTest `
                -Hdc $Hdc `
                -Target $Target `
                -Arguments @(
                    'dumpLayout', '-p', $remotePath, '-a', '-b', 'com.leantty.app'
                ) `
                -Operation 'HarmonyOS UI layout capture' | Out-Null
            Invoke-HdcChecked `
                -Hdc $Hdc `
                -Target $Target `
                -Arguments @('file', 'recv', $remotePath, $LocalPath) `
                -Operation 'HarmonyOS UI layout transfer' `
                -FailureDomain 'environment' | Out-Null
            if (-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)) {
                throw 'HarmonyOS UI layout transfer produced no local file'
            }
            $layout = Get-Content -LiteralPath $LocalPath -Raw | ConvertFrom-Json -Depth 100
            if (@($layout.children).Count -gt 0) { return $layout }
        } finally {
            & $Hdc -t $Target shell rm -f $remotePath 2>$null | Out-Null
        }
        if ($captureAttempt -lt 2) { Start-Sleep -Milliseconds 500 }
    }
    throw '[environment] HarmonyOS UI layout remained empty after two captures'
}

function Get-LeanTTYTerminalInputText {
    param([Parameter(Mandatory = $true)]$Layout)

    $inputNode = @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object {
        [string]$_.attributes.hint -eq 'Terminal input'
    } | Select-Object -First 1)
    if ($inputNode.Count -ne 1) {
        throw 'LeanTTY terminal input accessibility node was not found'
    }
    $originalText = [string]$inputNode[0].attributes.originalText
    if (-not [string]::IsNullOrEmpty($originalText)) { return $originalText }
    return [string]$inputNode[0].attributes.text
}

function Get-LeanTTYTerminalInputNodes {
    param([Parameter(Mandatory = $true)]$Layout)

    return @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object {
        [string]$_.attributes.hint -eq 'Terminal input'
    } | Sort-Object {
        (Get-LeanTTYBoundsCenter -Bounds ([string]$_.attributes.bounds)).x
    })
}

function Set-LeanTTYTerminalInputFocus {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)]$InputNode,
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 30
    )

    $inputBounds = [string]$InputNode.attributes.bounds
    $center = Get-LeanTTYBoundsCenter -Bounds $inputBounds
    Invoke-LeanTTYDeviceClick `
        -Hdc $Hdc -Target $Target -X $center.x -Y $center.y `
        -Operation 'LeanTTY terminal input focus'

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $layout = Get-LeanTTYDeviceLayout `
            -Hdc $Hdc `
            -Target $Target `
            -LocalPath $LocalPath
        $focusedTarget = @(Get-LeanTTYTerminalInputNodes -Layout $layout | Where-Object {
            [string]$_.attributes.bounds -eq $inputBounds -and
            [string]$_.attributes.focused -eq 'true'
        })
        if ($focusedTarget.Count -eq 1) {
            return $layout
        }
        if ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            Start-Sleep -Milliseconds 200
        }
    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw '[environment] Timed out waiting for LeanTTY terminal input focus'
}

function Wait-LeanTTYTerminalInputCount {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [ValidateRange(1, 2)][int]$Count,
        [ValidateRange(1, 30)][int]$TimeoutSeconds = 20
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $layout = Get-LeanTTYDeviceLayout -Hdc $Hdc -Target $Target -LocalPath $LocalPath
        if (@(Get-LeanTTYTerminalInputNodes -Layout $layout).Count -eq $Count) {
            return $layout
        }
        if ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            Start-Sleep -Milliseconds 200
        }
    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw "Timed out waiting for $Count LeanTTY terminal input accessibility nodes"
}

function Wait-LeanTTYTerminalInputLayout {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [ValidateRange(1, 30)][int]$TimeoutSeconds = 20
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $layout = Get-LeanTTYDeviceLayout `
            -Hdc $Hdc `
            -Target $Target `
            -LocalPath $LocalPath
        $inputNodes = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
            [string]$_.attributes.hint -eq 'Terminal input'
        } | Select-Object -First 1)
        if ($inputNodes.Count -eq 1) { return $layout }
        if ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            Start-Sleep -Milliseconds 200
        }
    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw 'Timed out waiting for the LeanTTY terminal input accessibility node'
}

function Assert-LeanTTYLayoutExcludesValues {
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)][string[]]$Values
    )

    $layoutText = ConvertTo-Json -InputObject $Layout -Depth 100 -Compress
    foreach ($value in $Values) {
        if (-not [string]::IsNullOrEmpty($value) -and $layoutText.Contains($value)) {
            throw 'A device layout snapshot exposed secret input'
        }
    }
}

function Invoke-LeanTTYDeviceText {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Text
    )

    if ($Text -match '[\r\n\x00]') {
        throw '[harness] HarmonyOS UI text input does not accept command separators'
    }
    Invoke-LeanTTYSerializedUiTest `
        -Hdc $Hdc `
        -Target $Target `
        -Arguments @('uiInput', 'text', $Text) `
        -Operation 'HarmonyOS complete UI text input' | Out-Null
}

function Invoke-LeanTTYDeviceKey {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][int]$KeyCode
    )

    Invoke-LeanTTYSerializedUiTest `
        -Hdc $Hdc `
        -Target $Target `
        -Arguments @('uiInput', 'keyEvent', $KeyCode) `
        -Operation "HarmonyOS key injection $KeyCode" | Out-Null
}

function Invoke-LeanTTYDeviceCtrlC {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target
    )

    & $Hdc -t $Target shell 'uinput -K -d 2072 -d 2019 -u 2019 -u 2072' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'HarmonyOS Ctrl+C injection failed' }
}

function Invoke-LeanTTYDeviceCtrlAltS {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target
    )

    & $Hdc -t $Target shell 'uinput -K -d 2072 -d 2045 -d 2035 -u 2035 -u 2045 -u 2072' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'HarmonyOS Ctrl+Alt+S injection failed' }
}

function Invoke-LeanTTYDeviceCtrlD {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target
    )

    & $Hdc -t $Target shell 'uinput -K -d 2072 -d 2020 -u 2020 -u 2072' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'HarmonyOS Ctrl+D injection failed' }
}

function Clear-LeanTTYDeviceInput {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target
    )

    Invoke-LeanTTYDeviceCtrlC -Hdc $Hdc -Target $Target
}

function Test-LeanTTYDeviceKeyFilesPresent {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$KeyName
    )

    if ($KeyName -notmatch '^ltty_reg_(?:[0-9a-f]{10}|[a-p]{10})$') {
        throw 'Device regression key name is outside the disposable-key namespace'
    }
    $sshDirectory = '/data/app/el2/100/base/com.leantty.app/haps/entry/files/.ssh'
    $privatePath = "$sshDirectory/$KeyName"
    $publicPath = "$privatePath.pub"
    $condition = (
        "if [ -e $privatePath ] || [ -e $publicPath ]; " +
        'then echo PRESENT; else echo ABSENT; fi'
    )
    $output = @(& $Hdc -t $Target shell -b com.leantty.app $condition 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect disposable key state in the LeanTTY application sandbox'
    }
    $result = ($output -join "`n").Trim()
    if ($result -eq 'PRESENT') { return $true }
    if ($result -eq 'ABSENT') { return $false }
    throw 'Unexpected disposable key-state response from the LeanTTY application sandbox'
}

function Get-LeanTTYDeviceRegressionKeyNames {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $sshDirectory = '/data/app/el2/100/base/com.leantty.app/haps/entry/files/.ssh'
    $output = @(& $Hdc -t $Target shell -b com.leantty.app "ls -1 $sshDirectory" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to enumerate disposable key state in the LeanTTY application sandbox'
    }
    return @($output | ForEach-Object { [string]$_ } | Where-Object {
        $_ -match '^ltty_reg_(?:[0-9a-f]{10}|[a-p]{10})$'
    } | Sort-Object -Unique)
}

function Submit-LeanTTYDeviceCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Command
    )

    Invoke-LeanTTYDeviceText -Hdc $Hdc -Target $Target -Text $Command
    Invoke-LeanTTYDeviceKey -Hdc $Hdc -Target $Target -KeyCode 2054
}

function Clear-LeanTTYAppLogs {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target
    )

    Invoke-HdcChecked `
        -Hdc $Hdc `
        -Target $Target `
        -Arguments @('shell', 'hilog -r -t app') `
        -Operation 'HarmonyOS application log clear' | Out-Null
}

function Get-LeanTTYAppLogs {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$ProcessId
    )

    return Invoke-HdcChecked `
        -Hdc $Hdc `
        -Target $Target `
        -Arguments @(
            'shell',
            (
                "hilog -z 500 -t app -P $ProcessId " +
                '-T SessionViewModel,KeyCommandService,SshClient,FileTransferClient,EntryAbility,Index,' +
                'TerminalSurfaceController,TerminalBridge,AppViewModel'
            )
        ) `
        -Operation 'HarmonyOS application log query'
}

function Wait-LeanTTYAppLog {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$ProcessId,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 10
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $logs = Get-LeanTTYAppLogs -Hdc $Hdc -Target $Target -ProcessId $ProcessId
        if ($logs -match $Pattern) { return $logs }
        Start-Sleep -Milliseconds 1000
    }
    throw "Timed out waiting for LeanTTY device state: $Pattern"
}

function Invoke-LeanTTYDevicePhysicalKey {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][int]$KeyCode
    )

    $failure = $null
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $Hdc
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        foreach ($argument in @('-t', $Target, 'shell', "uinput -K -d $KeyCode -u $KeyCode")) {
            [void]$startInfo.ArgumentList.Add($argument)
        }

        $process = [Diagnostics.Process]::Start($startInfo)
        try {
            if (-not $process.WaitForExit(5000)) {
                $failure = "timed out on attempt $attempt"
                $process.Kill($true)
                $process.WaitForExit()
            } elseif ($process.ExitCode -eq 0) {
                return
            } else {
                $failure = "exited with code $($process.ExitCode) on attempt $attempt"
            }
        } finally {
            $process.Dispose()
        }
        Start-Sleep -Milliseconds 250
    }
    throw "HarmonyOS physical key injection failed for key ${KeyCode}: $failure"
}

function Resolve-LeanTTYAuthenticationObservation {
    param(
        [AllowEmptyString()][string]$SnapshotLogs = '',
        [AllowEmptyString()][string]$LiveLogs = '',
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    $snapshotObserved = $SnapshotLogs -match $Pattern
    $liveObserved = $LiveLogs -match $Pattern
    if (-not $snapshotObserved -and -not $liveObserved) { return $null }
    $combined = $SnapshotLogs + "`n" + $LiveLogs
    $stateMatch = [regex]::Match($combined, $Pattern)
    return [pscustomobject]@{
        state = $stateMatch.Value
        snapshotObserved = $snapshotObserved
        liveObserved = $liveObserved
        logs = $combined
    }
}

function Invoke-LeanTTYDialogButton {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$ButtonText,
        [Parameter(Mandatory = $true)][string]$LayoutPath
    )

    $layout = Get-LeanTTYDeviceLayout -Hdc $Hdc -Target $Target -LocalPath $LayoutPath
    $buttonNode = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
        [string]$_.attributes.text -eq $ButtonText -or
        [string]$_.attributes.originalText -eq $ButtonText
    } | Select-Object -First 1)
    if ($buttonNode.Count -ne 1) { throw "Dialog button was not found: $ButtonText" }
    $center = Get-LeanTTYBoundsCenter -Bounds ([string]$buttonNode[0].attributes.bounds)
    Invoke-LeanTTYDeviceClick `
        -Hdc $Hdc -Target $Target -X $center.x -Y $center.y `
        -Operation "LeanTTY dialog button '$ButtonText'"
}

function Save-LeanTTYDeviceScreenshot {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$LocalPath
    )

    $remotePath = '/data/local/tmp/leantty-screen-' + [Guid]::NewGuid().ToString('N') + '.png'
    try {
        Invoke-LeanTTYSerializedUiTest `
            -Hdc $Hdc -Target $Target `
            -Arguments @('screenCap', '-p', $remotePath) `
            -Operation 'HarmonyOS screenshot capture' | Out-Null
        Invoke-HdcChecked `
            -Hdc $Hdc -Target $Target `
            -Arguments @('file', 'recv', $remotePath, $LocalPath) `
            -Operation 'HarmonyOS screenshot transfer' `
            -FailureDomain 'environment' | Out-Null
        if (-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)) {
            throw 'HarmonyOS screenshot transfer produced no local file'
        }
    } finally {
        & $Hdc -t $Target shell rm -f $remotePath 2>$null | Out-Null
    }
}

function New-LeanTTYRegressionSecret {
    return 't' + [Guid]::NewGuid().ToString('N').Substring(0, 23)
}
