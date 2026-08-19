<#
.SYNOPSIS
  Verify the production PUT/GET event chain on a physical HarmonyOS PC.
.DESCRIPTION
  Builds and deploys the debug HAP, starts the repository-only SSH fixture with
  its bounded temporary SFTP root, maps a device loopback port, downloads one
  deterministic file into an existing Downloads subdirectory with an occupied
  basename, uploads the numbered result to an existing remote directory,
  compares SHA-256, and removes all disposable local and remote data.
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [ValidateRange(0, 65535)][int]$FixturePort = 0,
    [switch]$SkipBuild,
    [switch]$CancelGet,
    [switch]$CloseApplication,
    [switch]$ClosePane,
    [switch]$StallPreparation,
    [switch]$FailRemoteCleanup,
    [switch]$FailLocalCleanup,
    [switch]$LocalDiskFull,
    [switch]$Backpressure,
    [switch]$ForceTerminate,
    [switch]$LateEvents,
    [switch]$DisconnectGet,
    [switch]$MinimizeGet,
    [switch]$SuspendGet,
    [switch]$SelectionCopy,
    [switch]$FileNameMatrix,
    [switch]$TabCompletionMatrix,
    [switch]$AuthenticationMatrix,
    [ValidateSet('', 'unavailable', 'permission-denied', 'rename-unsupported')]
    [string]$SftpFailure = '',
    [ValidateRange(0, 5000)][int]$SftpDelayMilliseconds = 0,
    [string]$EvidenceDirectory = '',
    [string]$SourceFile = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')
. (Join-Path $PSScriptRoot 'acceptance-source.ps1')

$hdc = Resolve-Hdc
$Target = Resolve-LeanTTYRegressionTarget -Hdc $hdc -Target $Target
$exclusiveModes = @(
    $CancelGet, $CloseApplication, $ClosePane, $FailRemoteCleanup, $FailLocalCleanup,
    $LocalDiskFull, $Backpressure, $ForceTerminate, $LateEvents, $DisconnectGet, $MinimizeGet,
    $SuspendGet,
    $SelectionCopy, $FileNameMatrix,
    $TabCompletionMatrix, $AuthenticationMatrix,
    (-not [string]::IsNullOrWhiteSpace($SftpFailure))
) |
    Where-Object { $_ }
if ($exclusiveModes.Count -gt 1) {
    throw (
        'CancelGet, CloseApplication, ClosePane, FailRemoteCleanup, FailLocalCleanup, LocalDiskFull, ' +
        'Backpressure, ForceTerminate, LateEvents, DisconnectGet, MinimizeGet, SuspendGet, SelectionCopy, FileNameMatrix, ' +
        'TabCompletionMatrix, ' +
        'AuthenticationMatrix and SftpFailure are mutually exclusive'
    )
}
if ($StallPreparation -and -not ($CloseApplication -or $ClosePane)) {
    throw 'StallPreparation requires CloseApplication or ClosePane'
}
if (($FailLocalCleanup -or $Backpressure -or $SelectionCopy -or $FileNameMatrix) -and $SkipBuild) {
    throw 'FailLocalCleanup, Backpressure, SelectionCopy and FileNameMatrix require a fresh acceptance build; SkipBuild is not supported'
}
if ($FixturePort -eq 0) { $FixturePort = Get-Random -Minimum 24000 -Maximum 48000 }
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $repoRoot (
        'build\verification\put-get-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    )
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null

$attemptToken = [Guid]::NewGuid().ToString('N')
$localDirectoryName = '.leantty-transfer-fixture'
$remoteGetName = if ($Backpressure) {
    'backpressure-source.bin'
} elseif ($LocalDiskFull) {
    'disk-full-source.bin'
} else {
    'source.bin'
}
$remoteDirectoryName = 'put-' + $attemptToken.Substring(0, 12)
$localExistingName = $localDirectoryName + '/' + $remoteGetName
$remoteStem = [IO.Path]::GetFileNameWithoutExtension($remoteGetName)
$remoteExtension = [IO.Path]::GetExtension($remoteGetName)
$localDownloadedName = $localDirectoryName + '/' + $remoteStem + ' (1)' + $remoteExtension
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('leantty-put-get-' + $attemptToken)
$fixtureReady = Join-Path $fixtureRoot 'fixture-ready'
$fixtureCredentials = Join-Path $fixtureRoot 'server-credentials'
$fixtureSftpRoot = Join-Path $fixtureRoot 'sftp-root'
$fixtureStdout = Join-Path $EvidenceDirectory 'fixture-stdout.log'
$fixtureStderr = Join-Path $EvidenceDirectory 'fixture-stderr.log'
$fixtureProcess = $null
$fixtureLinuxPid = 0
$reverseMapped = $false
$awakeLease = $false
$appProcessId = ''
$secret = ''
$fixtureSecrets = @{}
$authenticationSecrets = [Collections.Generic.List[string]]::new()
$keyName = ''
$keyPassphrase = ''
$keyCleanupRequired = $false
$primaryFailure = $null
$authObservationProcess = $null
$authObservationProcessId = ''
$authObservationSequence = 0
$authObservationOffset = 0
$authObservationStdout = ''
$authObservationStderr = ''
$authObservationFiles = [Collections.Generic.List[string]]::new()
$authObservationRecords = [Collections.Generic.List[object]]::new()
$sourceKind = 'generated-random'
$sourceBytesCount = if ($SelectionCopy) {
    1MB
} elseif ($CancelGet -or $CloseApplication -or $ClosePane -or $DisconnectGet -or $MinimizeGet -or
    $SuspendGet -or
    $Backpressure -or $ForceTerminate -or $LateEvents) {
    8MB
} else {
    131089L
}
if ($SftpDelayMilliseconds -eq 0) {
    if ($SelectionCopy) {
        $SftpDelayMilliseconds = 1000
    } elseif ($CloseApplication -or $ClosePane -or $DisconnectGet -or $MinimizeGet -or $SuspendGet -or
        $ForceTerminate -or $LateEvents) {
        $SftpDelayMilliseconds = 250
    } elseif ($Backpressure) {
        $SftpDelayMilliseconds = 100
    } elseif ($CancelGet) {
        $SftpDelayMilliseconds = 50
    }
}
if (-not [string]::IsNullOrWhiteSpace($SourceFile)) {
    $SourceFile = [IO.Path]::GetFullPath($SourceFile)
    if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) {
        throw "PUT/GET source file does not exist: $SourceFile"
    }
    $sourceBytesCount = (Get-Item -LiteralPath $SourceFile).Length
    $sourceKind = 'caller-provided'
}
function Wait-FixtureReady {
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 90) {
        if ($null -ne $fixtureProcess -and $fixtureProcess.HasExited) {
            throw "SFTP fixture exited before readiness (exit=$($fixtureProcess.ExitCode))"
        }
        if ((Test-Path -LiteralPath $fixtureReady -PathType Leaf) -and
            (Test-Path -LiteralPath $fixtureCredentials -PathType Leaf) -and
            (Test-Path -LiteralPath $fixtureSftpRoot -PathType Container)) {
            $readyText = [IO.File]::ReadAllText($fixtureReady)
            $pidMatch = [regex]::Match($readyText, '(?m)^pid=(?<pid>\d+)$')
            if ($pidMatch.Success) {
                $script:fixtureLinuxPid = [int]$pidMatch.Groups['pid'].Value
                return
            }
        }
        Start-Sleep -Milliseconds 1000
    }
    throw 'Timed out waiting for the temporary SFTP fixture'
}

function Read-SftpFixtureLogText {
    $stream = [IO.File]::Open(
        $fixtureStderr,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite
    )
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally {
        $stream.Dispose()
    }
}

function Read-SharedTextFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite
    )
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally {
        $stream.Dispose()
    }
}

function Stop-FileTransferAuthenticationObserver {
    if ($null -eq $script:authObservationProcess) { return }
    try {
        $script:authObservationProcess.Refresh()
        if (-not $script:authObservationProcess.HasExited) {
            Stop-Process -Id $script:authObservationProcess.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $script:authObservationProcess.Id -Timeout 5 -ErrorAction SilentlyContinue
        }
    } finally {
        $script:authObservationProcess = $null
        $script:authObservationProcessId = ''
    }
}

function Ensure-FileTransferAuthenticationObserver {
    $requiresStart = $null -eq $script:authObservationProcess -or
        $script:authObservationProcessId -ne $script:appProcessId
    if (-not $requiresStart) {
        $script:authObservationProcess.Refresh()
        $requiresStart = $script:authObservationProcess.HasExited
    }
    if (-not $requiresStart) { return }

    Stop-FileTransferAuthenticationObserver
    $script:authObservationSequence++
    $script:authObservationStdout = Join-Path $EvidenceDirectory (
        'auth-observer-' + $script:authObservationSequence.ToString() + '.log'
    )
    $script:authObservationStderr = Join-Path $EvidenceDirectory (
        'auth-observer-' + $script:authObservationSequence.ToString() + '.stderr.log'
    )
    $arguments = @(
        '-t', $Target, 'shell',
        "hilog -t app -P $script:appProcessId -T SessionViewModel,FileTransferClient"
    )
    $script:authObservationProcess = Start-Process `
        -FilePath $hdc `
        -ArgumentList $arguments `
        -RedirectStandardOutput $script:authObservationStdout `
        -RedirectStandardError $script:authObservationStderr `
        -WindowStyle Hidden `
        -PassThru
    $script:authObservationProcessId = $script:appProcessId
    $script:authObservationFiles.Add($script:authObservationStdout)
    Start-Sleep -Milliseconds 300
    $script:authObservationProcess.Refresh()
    if ($script:authObservationProcess.HasExited) {
        throw 'Bounded live authentication log observer exited before command submission'
    }
}

function Set-FileTransferAuthenticationObservationCursor {
    Ensure-FileTransferAuthenticationObserver
    $script:authObservationOffset = (Read-SharedTextFile -Path $script:authObservationStdout).Length
}

function Wait-FileTransferAuthenticationState {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [ValidateRange(1, 60)][int]$TimeoutSeconds
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $lastSnapshot = ''
    $lastSnapshotError = ''
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try {
            $lastSnapshot = Get-LeanTTYAppLogs `
                -Hdc $hdc -Target $Target -ProcessId $appProcessId
            $lastSnapshotError = ''
        } catch {
            $lastSnapshotError = $_.Exception.Message
        }
        $liveAll = Read-SharedTextFile -Path $script:authObservationStdout
        $liveCurrent = if ($script:authObservationOffset -le $liveAll.Length) {
            $liveAll.Substring($script:authObservationOffset)
        } else {
            $liveAll
        }
        $observation = Resolve-LeanTTYAuthenticationObservation `
            -SnapshotLogs $lastSnapshot -LiveLogs $liveCurrent -Pattern $Pattern
        if ($null -ne $observation) {
            $script:authObservationRecords.Add([pscustomobject][ordered]@{
                stage = $Stage
                state = $observation.state
                snapshotObserved = $observation.snapshotObserved
                liveObserved = $observation.liveObserved
                elapsedMilliseconds = [int]$stopwatch.ElapsedMilliseconds
            })
            return [pscustomobject]@{
                state = $observation.state
                logs = $observation.logs
                snapshotObserved = $observation.snapshotObserved
                liveObserved = $observation.liveObserved
            }
        }
        Start-Sleep -Milliseconds 200
    }

    $safeStage = $Stage -replace '[^A-Za-z0-9._-]', '-'
    $layoutPath = Join-Path $EvidenceDirectory (
        'authentication-observation-timeout-' + $safeStage + '.json'
    )
    $screenshotPath = Join-Path $EvidenceDirectory (
        'authentication-observation-timeout-' + $safeStage + '.png'
    )
    $layoutCaptured = $false
    $screenshotCaptured = $false
    try {
        Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $layoutPath | Out-Null
        $layoutCaptured = $true
    } catch {}
    try {
        Save-LeanTTYDeviceScreenshot -Hdc $hdc -Target $Target -LocalPath $screenshotPath
        $screenshotCaptured = $true
    } catch {}
    $observerExited = $true
    if ($null -ne $script:authObservationProcess) {
        $script:authObservationProcess.Refresh()
        $observerExited = $script:authObservationProcess.HasExited
    }
    [ordered]@{
        recordedAt = (Get-Date).ToString('o')
        stage = $Stage
        result = 'product-authentication-state-unobserved'
        timeoutSeconds = $TimeoutSeconds
        snapshotQueryError = $lastSnapshotError
        liveObserverExited = $observerExited
        layoutCaptured = $layoutCaptured
        screenshotCaptured = $screenshotCaptured
    } | ConvertTo-Json -Depth 4 | Set-Content `
        -LiteralPath (Join-Path $EvidenceDirectory (
                'authentication-observation-timeout-' + $safeStage + '-diagnostic.json'
            )) `
        -Encoding utf8NoBOM
    throw (
        "PUT/GET $Stage did not expose a structured authentication state through either " +
        'the bounded snapshot or live observer'
    )
}

function Focus-TerminalInput {
    param([Parameter(Mandatory = $true)][string]$Name)

    $layoutPath = Join-Path $EvidenceDirectory ($Name + '.json')
    $layout = Wait-LeanTTYTerminalInputLayout `
        -Hdc $hdc -Target $Target -LocalPath $layoutPath -TimeoutSeconds 20
    $nodes = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
    $focusedNodes = @($nodes | Where-Object {
        [string]$_.attributes.focused -eq 'true'
    })
    $inputNode = if ($focusedNodes.Count -eq 1) {
        $focusedNodes[0]
    } elseif ($nodes.Count -eq 1) {
        $nodes[0]
    } else {
        throw 'PUT/GET verifier could not identify one active terminal input'
    }
    Set-LeanTTYTerminalInputFocus `
        -Hdc $hdc -Target $Target -InputNode $inputNode -LocalPath $layoutPath | Out-Null
}

function Reset-TerminalInput {
    param([Parameter(Mandatory = $true)][string]$LayoutName)

    Focus-TerminalInput -Name ($LayoutName + '-focus')
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Clear-LeanTTYDeviceInput -Hdc $hdc -Target $Target
    Wait-LeanTTYAppLog `
        -Hdc $hdc -Target $Target -ProcessId $appProcessId `
        -Pattern 'ACCEPTANCE_IDLE_INTERRUPT cleared=true' -TimeoutSeconds 10 | Out-Null
    Get-LeanTTYDeviceLayout `
        -Hdc $hdc -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory ($LayoutName + '-after-interrupt.json')) | Out-Null
}

function Wait-ExactAcceptanceCommandSubmit {
    param(
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Stage
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 10) {
        $liveAll = Read-SharedTextFile -Path $script:authObservationStdout
        $liveCurrent = if ($script:authObservationOffset -le $liveAll.Length) {
            $liveAll.Substring($script:authObservationOffset)
        } else {
            $liveAll
        }
        $records = @([regex]::Matches(
                $liveCurrent,
                'ACCEPTANCE_INPUT_SUBMIT sequence=\d+,kind=command,input=(?<input>[^\r\n]*)'
            ))
        if ($records.Count -gt 0) {
            $actual = $records[$records.Count - 1].Groups['input'].Value
            return [pscustomobject]@{
                exact = $actual -ceq $Expected
                actual = $actual
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Acceptance package did not expose the submitted production command buffer for $Stage"
}

function Submit-TerminalText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$LayoutName,
        [ValidateSet('command', 'host-key')][string]$InputKind = 'command'
    )

    if ($InputKind -eq 'host-key') {
        Focus-TerminalInput -Name ($LayoutName + '-focus')
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $Text
        Get-LeanTTYDeviceLayout `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory ($LayoutName + '-typed.json')) | Out-Null
        Set-FileTransferAuthenticationObservationCursor
        Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
        return
    }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        Focus-TerminalInput -Name ($LayoutName + '-focus-' + $attempt.ToString())
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $Text
        Get-LeanTTYDeviceLayout `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory (
                    $LayoutName + '-typed-' + $attempt.ToString() + '.json'
                )) | Out-Null
        Set-FileTransferAuthenticationObservationCursor
        Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
        $submitted = Wait-ExactAcceptanceCommandSubmit -Expected $Text -Stage $LayoutName
        if ($submitted.exact) { return }
        Start-Sleep -Milliseconds 300
        $stateLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appProcessId
        if ($stateLogs -match 'File transfer authentication prompt=|FILE_TRANSFER phase=(PREPARING|TRANSFERRING)') {
            throw "Inexact physical command unexpectedly started work for $LayoutName"
        }
    }
    throw "Physical key injection could not submit the exact production command for $LayoutName"
}

function Submit-TerminalTextWithAcceptanceData {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$LayoutName
    )

    $marker = '{{DATA}}'
    $markerIndex = $Text.IndexOf($marker, [StringComparison]::Ordinal)
    if ($markerIndex -lt 0 -or
        $Text.IndexOf($marker, $markerIndex + $marker.Length, [StringComparison]::Ordinal) -ge 0) {
        throw 'Acceptance Unicode command must contain exactly one {{DATA}} marker'
    }
    $before = $Text.Substring(0, $markerIndex)
    $after = $Text.Substring($markerIndex + $marker.Length)
    $expected = $before + '数据' + $after
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        Focus-TerminalInput -Name ($LayoutName + '-focus-' + $attempt.ToString())
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $before
        & $hdc -t $Target shell (
            'uinput -K -d 2072 -d 2045 -d 2037 -u 2037 -u 2045 -u 2072'
        ) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to inject the Unicode file-name segment' }
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $after
        Get-LeanTTYDeviceLayout `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory (
                    $LayoutName + '-typed-' + $attempt.ToString() + '.json'
                )) | Out-Null
        Set-FileTransferAuthenticationObservationCursor
        Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
        $submitted = Wait-ExactAcceptanceCommandSubmit -Expected $expected -Stage $LayoutName
        if ($submitted.exact) { return }
        Start-Sleep -Milliseconds 300
        $stateLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appProcessId
        if ($stateLogs -match 'File transfer authentication prompt=|FILE_TRANSFER phase=(PREPARING|TRANSFERRING)') {
            throw "Inexact physical Unicode command unexpectedly started work for $LayoutName"
        }
    }
    throw "Physical key injection could not submit the exact production Unicode command for $LayoutName"
}

function Complete-TerminalTextWithAcceptanceDataAndTab {
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$ExpectedCompletedPrefix,
        [Parameter(Mandatory = $true)][string]$Suffix,
        [Parameter(Mandatory = $true)][string]$LayoutName
    )

    $marker = '{{DATA}}'
    $markerIndex = $Prefix.IndexOf($marker, [StringComparison]::Ordinal)
    if ($markerIndex -lt 0 -or
        $Prefix.IndexOf($marker, $markerIndex + $marker.Length, [StringComparison]::Ordinal) -ge 0) {
        throw 'Acceptance Unicode completion must contain exactly one {{DATA}} marker'
    }
    $completedExactly = $false
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        Focus-TerminalInput -Name ($LayoutName + '-focus-' + $attempt.ToString())
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $Prefix.Substring(0, $markerIndex)
        & $hdc -t $Target shell (
            'uinput -K -d 2072 -d 2045 -d 2037 -u 2037 -u 2045 -u 2072'
        ) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to inject the Unicode completion segment' }
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target `
            -Text $Prefix.Substring($markerIndex + $marker.Length)
        Get-LeanTTYDeviceLayout `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory (
                    $LayoutName + '-prefix-' + $attempt.ToString() + '.json'
                )) | Out-Null
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2049
        Start-Sleep -Milliseconds 300
        $tabLogs = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'ACCEPTANCE_TAB_COMPLETE input=' -TimeoutSeconds 10
        if ($tabLogs -match 'File transfer authentication prompt=|FILE_TRANSFER result=') {
            throw 'Unicode Tab completion unexpectedly started a transfer or authentication'
        }
        $tabRecords = @([regex]::Matches(
                $tabLogs,
                'ACCEPTANCE_TAB_COMPLETE input=(?<input>[^\r\n]*),matches=(?<matches>\d+)'
            ))
        if ($tabRecords.Count -gt 0) {
            $tabRecord = $tabRecords[$tabRecords.Count - 1]
            $completedPrefix = $tabRecord.Groups['input'].Value
            $matches = [int]$tabRecord.Groups['matches'].Value
            if ($matches -eq 1 -and $completedPrefix -ceq $ExpectedCompletedPrefix) {
                $completedExactly = $true
                break
            }
        }
        if ($attempt -lt 2) {
            Reset-TerminalInput -LayoutName ($LayoutName + '-retry-' + $attempt.ToString())
            Start-Sleep -Milliseconds 300
        }
    }
    if (-not $completedExactly) {
        throw "Physical Unicode Tab completion did not produce the expected command for $LayoutName"
    }
    if (-not [string]::IsNullOrEmpty($Suffix)) {
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $Suffix
    }
    Set-FileTransferAuthenticationObservationCursor
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
    $submitted = Wait-ExactAcceptanceCommandSubmit `
        -Expected ($ExpectedCompletedPrefix + $Suffix) -Stage $LayoutName
    if (-not $submitted.exact) {
        throw "Physical key injection changed the completed Unicode command for $LayoutName"
    }
}

function Complete-TerminalTextWithTab {
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [string]$Suffix = '',
        [Parameter(Mandatory = $true)][string]$LayoutName
    )

    $typedExactly = $false
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        Focus-TerminalInput -Name ($LayoutName + '-focus-' + $attempt.ToString())
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $Prefix
        $typedLayout = Get-LeanTTYDeviceLayout `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory (
                    $LayoutName + '-prefix-' + $attempt.ToString() + '.json'
                ))
        if ((Get-LeanTTYTerminalInputText -Layout $typedLayout) -ceq $Prefix) {
            $typedExactly = $true
            break
        }
        Reset-TerminalInput -LayoutName ($LayoutName + '-retry-' + $attempt.ToString())
        Start-Sleep -Milliseconds 300
    }
    if (-not $typedExactly) {
        throw "Physical key injection could not enter the exact Tab prefix for $LayoutName"
    }
    Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2049
    Start-Sleep -Milliseconds 300
    $tabLogs = Wait-LeanTTYAppLog `
        -Hdc $hdc -Target $Target -ProcessId $appProcessId `
        -Pattern 'ACCEPTANCE_TAB_COMPLETE input=' -TimeoutSeconds 10
    if ($tabLogs -match 'File transfer authentication prompt=|FILE_TRANSFER result=') {
        throw 'Tab completion unexpectedly started a transfer or remote authentication'
    }
    $tabRecords = @([regex]::Matches(
            $tabLogs,
            'ACCEPTANCE_TAB_COMPLETE input=(?<input>[^\r\n]*),matches=(?<matches>\d+)'
        ))
    if ($tabRecords.Count -eq 0 -or
        [int]$tabRecords[$tabRecords.Count - 1].Groups['matches'].Value -ne 1) {
        throw "Tab completion did not resolve exactly one production candidate for $LayoutName"
    }
    $completedPrefix = $tabRecords[$tabRecords.Count - 1].Groups['input'].Value
    if (-not [string]::IsNullOrEmpty($Suffix)) {
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $Suffix
    }
    Set-FileTransferAuthenticationObservationCursor
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
    $submitted = Wait-ExactAcceptanceCommandSubmit `
        -Expected ($completedPrefix + $Suffix) -Stage $LayoutName
    if (-not $submitted.exact) {
        throw "Physical key injection changed the completed command for $LayoutName"
    }
}

function Assert-LocalTabCompletion {
    param(
        [Parameter(Mandatory = $true)][string]$Typed,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateRange(0, 100)][int]$ExpectedMatches = 1,
        [ValidateRange(1, 3)][int]$TabCount = 1
    )

    $typedExactly = $false
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        Focus-TerminalInput -Name ($Name + '-focus-' + $attempt.ToString())
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $Typed
        $typedLayout = Get-LeanTTYDeviceLayout `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory ($Name + '-typed-' + $attempt.ToString() + '.json'))
        try {
            Wait-LocalCompletionInputState `
                -ExpectedInput $Typed -Stage ($Name + ' typed prefix') `
                -CompletionActive $false -MenuActive $false | Out-Null
            $typedExactly = $true
            break
        } catch {
            if ($attempt -ge 2) { throw }
        }
        Reset-TerminalInput -LayoutName ($Name + '-retry-' + $attempt.ToString())
        Start-Sleep -Milliseconds 300
    }
    if (-not $typedExactly) {
        throw "Physical key injection could not enter the exact Tab prefix for $Name"
    }
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    for ($index = 0; $index -lt $TabCount; $index++) {
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2049
        Start-Sleep -Milliseconds 250
    }
    $completionLogs = Wait-LeanTTYAppLog `
        -Hdc $hdc -Target $Target -ProcessId $appProcessId `
        -Pattern 'ACCEPTANCE_TAB_COMPLETE input=' `
        -TimeoutSeconds 10
    $completionRecords = @([regex]::Matches(
            $completionLogs,
            'ACCEPTANCE_TAB_COMPLETE input=(?<input>[^\r\n]*),matches=(?<matches>\d+)'
        ))
    if ($completionRecords.Count -eq 0) {
        throw "Tab completion $Name did not expose its acceptance state"
    }
    $completionRecord = $completionRecords[$completionRecords.Count - 1]
    $actualInput = $completionRecord.Groups['input'].Value
    $actualMatches = [int]$completionRecord.Groups['matches'].Value
    if ($actualInput -cne $Expected -or $actualMatches -ne $ExpectedMatches) {
        throw (
            "Tab completion $Name produced '$actualInput' with $actualMatches matches; " +
            "expected '$Expected' with $ExpectedMatches matches"
        )
    }
    $layout = Get-LeanTTYDeviceLayout `
        -Hdc $hdc -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory ($Name + '.json'))
    $tabLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appProcessId
    if ($tabLogs -match 'File transfer authentication prompt=|FILE_TRANSFER phase=PREPARING|FILE_TRANSFER result=') {
        throw "Tab completion $Name started a transfer or remote authentication"
    }
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
    Start-Sleep -Milliseconds 200
}

function Wait-LocalCompletionInputState {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedInput,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][bool]$CompletionActive,
        [Parameter(Mandatory = $true)][bool]$MenuActive
    )

    $logs = Wait-LeanTTYAppLog `
        -Hdc $hdc -Target $Target -ProcessId $appProcessId `
        -Pattern 'ACCEPTANCE_IDLE_RESULT kind=' -TimeoutSeconds 10
    $records = @([regex]::Matches(
            $logs,
            'ACCEPTANCE_IDLE_RESULT kind=(?<kind>\d+),input=(?<input>[^\r\n]*),' +
            'completionActive=(?<active>true|false),menuActive=(?<menu>true|false)'
        ))
    if ($records.Count -eq 0) {
        throw "Completion state $Stage did not expose an acceptance result"
    }
    $record = $records[$records.Count - 1]
    $actualInput = $record.Groups['input'].Value
    $actualActive = $record.Groups['active'].Value -eq 'true'
    $actualMenu = $record.Groups['menu'].Value -eq 'true'
    if ($actualInput -cne $ExpectedInput -or $actualActive -ne $CompletionActive -or
        $actualMenu -ne $MenuActive) {
        throw (
            "Completion state $Stage was input='$actualInput', active=$actualActive, " +
            "menu=$actualMenu; expected input='$ExpectedInput', active=$CompletionActive, " +
            "menu=$MenuActive"
        )
    }
    return $logs
}

function Assert-LocalUnicodeTabCompletion {
    Focus-TerminalInput -Name 'tab-unicode-focus'
    Invoke-LeanTTYDeviceText `
        -Hdc $hdc -Target $Target `
        -Text 'put .leantty-transfer-fixture/'
    & $hdc -t $Target shell (
        'uinput -K -d 2072 -d 2045 -d 2037 -u 2037 -u 2045 -u 2072'
    ) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inject the Unicode completion prefix' }
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2049
    $completionLogs = Wait-LeanTTYAppLog `
        -Hdc $hdc -Target $Target -ProcessId $appProcessId `
        -Pattern 'ACCEPTANCE_TAB_COMPLETE input=' `
        -TimeoutSeconds 10
    $expected = 'put .leantty-transfer-fixture/数据.bin '
    if ($completionLogs -notmatch (
            'ACCEPTANCE_TAB_COMPLETE input=' + [regex]::Escape($expected) + ',matches=1'
        )) {
        throw 'Unicode Tab completion did not produce the expected escaped filename'
    }
    Get-LeanTTYDeviceLayout `
        -Hdc $hdc -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory 'tab-unicode.json') | Out-Null
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
    Start-Sleep -Milliseconds 200
}

function Complete-PasswordAuthentication {
    param([Parameter(Mandatory = $true)][string]$Stage)

    $observation = Wait-FileTransferAuthenticationState `
        -Stage $Stage `
        -Pattern 'File transfer authentication prompt=(host-key|password)|FILE_TRANSFER result=failed' `
        -TimeoutSeconds 30
    $logs = $observation.logs
    if ($logs -match 'FILE_TRANSFER result=failed') {
        throw "PUT/GET $Stage failed before authentication"
    }
    if ($logs -match 'File transfer authentication prompt=host-key') {
        Submit-TerminalText -Text 'yes' -LayoutName ($Stage + '-host-key') -InputKind host-key
        $passwordObservation = Wait-FileTransferAuthenticationState `
            -Stage ($Stage + '-password') `
            -Pattern 'File transfer authentication prompt=password|FILE_TRANSFER result=failed' `
            -TimeoutSeconds 20
        if ($passwordObservation.logs -match 'FILE_TRANSFER result=failed') {
            throw "PUT/GET $Stage failed after host-key verification"
        }
    }
    Submit-HiddenTransferValue -Value $script:secret -LayoutName ($Stage + '-password')
}

function Submit-FocusedTerminalText {
    param([Parameter(Mandatory = $true)][string]$Text)

    Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $Text
    Set-FileTransferAuthenticationObservationCursor
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
}

function Complete-FocusedPasswordAuthentication {
    param([Parameter(Mandatory = $true)][string]$Stage)

    $observation = Wait-FileTransferAuthenticationState `
        -Stage $Stage `
        -Pattern 'File transfer authentication prompt=(host-key|password)|FILE_TRANSFER result=failed' `
        -TimeoutSeconds 30
    $logs = $observation.logs
    if ($logs -match 'FILE_TRANSFER result=failed') {
        throw "PUT/GET $Stage failed before authentication"
    }
    if ($logs -match 'File transfer authentication prompt=host-key') {
        Submit-FocusedTerminalText -Text 'yes'
        $passwordObservation = Wait-FileTransferAuthenticationState `
            -Stage ($Stage + '-password') `
            -Pattern 'File transfer authentication prompt=password|FILE_TRANSFER result=failed' `
            -TimeoutSeconds 20
        if ($passwordObservation.logs -match 'FILE_TRANSFER result=failed') {
            throw "PUT/GET $Stage failed after host-key verification"
        }
    }
    Submit-FocusedTerminalText -Text $script:secret
}

function New-DeviceSafeRandomLetters {
    param([ValidateRange(1, 64)][int]$Length = 16)

    $bytes = [byte[]]::new($Length)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $builder = [Text.StringBuilder]::new($Length)
    foreach ($value in $bytes) {
        [void]$builder.Append([char]([int][char]'a' + ($value -band 0x0f)))
    }
    return $builder.ToString()
}

function Submit-HiddenTransferValue {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$LayoutName
    )

    $focusLayoutPath = Join-Path $EvidenceDirectory ($LayoutName + '-focus.json')
    $focusLayout = Get-LeanTTYDeviceLayout `
        -Hdc $hdc -Target $Target -LocalPath $focusLayoutPath
    $focusNodes = @(Get-LeanTTYTerminalInputNodes -Layout $focusLayout)
    if ($focusNodes.Count -eq 1) {
        Set-LeanTTYTerminalInputFocus `
            -Hdc $hdc -Target $Target -InputNode $focusNodes[0] `
            -LocalPath $focusLayoutPath | Out-Null
    } elseif ($focusNodes.Count -ne 0) {
        throw 'Secret input exposed an ambiguous accessibility focus target'
    }
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $Value
    $layout = Get-LeanTTYDeviceLayout `
        -Hdc $hdc -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory ($LayoutName + '.json'))
    Assert-LeanTTYLayoutExcludesValues -Layout $layout -Values @($authenticationSecrets)
    Set-FileTransferAuthenticationObservationCursor
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
}

function Wait-AuthenticationMatrixEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    $eventPattern = (
        'File transfer authentication prompt=(host-key|password|private-key-passphrase|' +
        'keyboard-interactive)|FILE_TRANSFER result=(completed|failed|cancelled)'
    )
    $observation = Wait-FileTransferAuthenticationState `
        -Stage $Stage -Pattern $eventPattern -TimeoutSeconds 45
    if ($observation.state -eq 'File transfer authentication prompt=host-key') {
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Submit-TerminalText -Text 'yes' -LayoutName ($Stage + '-host-key') -InputKind host-key
        $observation = Wait-FileTransferAuthenticationState `
            -Stage ($Stage + '-after-host-key') -Pattern $eventPattern -TimeoutSeconds 45
    }
    if ($observation.state -notmatch $Expected) {
        throw (
            "Authentication matrix $Stage observed '$($observation.state)'; " +
            "expected '$Expected'"
        )
    }
    return $observation
}

function Wait-AuthenticationMatrixCompletion {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [ValidateSet('get', 'put')][string]$Direction,
        [switch]$AlreadyObserved
    )

    if (-not $AlreadyObserved) {
        $observation = Wait-FileTransferAuthenticationState `
            -Stage ($Stage + '-completion') `
            -Pattern 'FILE_TRANSFER result=(completed|failed|cancelled)' `
            -TimeoutSeconds 60
        if ($observation.state -ne 'FILE_TRANSFER result=completed') {
            throw "Authentication matrix $Stage did not complete successfully"
        }
    }
    $logs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appProcessId
    if ($logs -notmatch ('FILE_TRANSFER result=completed direction=' + $Direction + ',bytes=')) {
        throw "Authentication matrix $Stage completed with the wrong transfer direction"
    }
    $terminalResults = @([regex]::Matches(
            $logs,
            'FILE_TRANSFER result=(completed|failed|cancelled)'
        ))
    if ($terminalResults.Count -ne 1 -or
        $terminalResults[0].Groups[1].Value -ne 'completed') {
        throw "Authentication matrix $Stage did not produce exactly one completed result"
    }
    foreach ($value in $authenticationSecrets) {
        if (-not [string]::IsNullOrEmpty($value) -and
            $logs.Contains($value, [StringComparison]::Ordinal)) {
            throw "Authentication matrix $Stage exposed a temporary credential in app logs"
        }
    }
}

function Wait-AuthenticationMatrixKeyCreated {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedName,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ExistingNames,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 30
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $currentNames = @(Get-LeanTTYDeviceRegressionKeyNames -Hdc $hdc -Target $Target)
        if ($currentNames -contains $ExpectedName) { return $ExpectedName }
        $newNames = @($currentNames | Where-Object { $ExistingNames -notcontains $_ })
        if ($newNames.Count -eq 1) { return $newNames[0] }
        if ($newNames.Count -gt 1) {
            throw 'Authentication matrix created more than one disposable key'
        }
        Start-Sleep -Milliseconds 200
    }
    throw 'Timed out waiting for the authentication matrix disposable key pair'
}

function Reset-AuthenticationMatrixDownload {
    param([Parameter(Mandatory = $true)][string]$Stage)

    $cleanup = Invoke-TransferFixtureAction -Stage ($Stage + '-cleanup')
    if ($cleanup -notmatch (
            'state=cleaned,originalPreserved=true,numberedPresent=true,' +
            'temporaryPresent=false,cleanupFailureFinalPresent=false,temporaryCount=0'
        )) {
        throw "Authentication matrix $Stage did not clean its completed Downloads file"
    }
    $prepared = Invoke-TransferFixtureAction -Stage ($Stage + '-prepare')
    if ($prepared -notmatch 'state=prepared') {
        throw "Authentication matrix $Stage could not restore the Downloads fixture"
    }
    Focus-TerminalInput -Name ($Stage + '-after-prepare')
}

function Remove-AuthenticationMatrixKey {
    param([Parameter(Mandatory = $true)][string]$Stage)

    if ([string]::IsNullOrWhiteSpace($keyName) -or
        -not (Test-LeanTTYDeviceKeyFilesPresent -Hdc $hdc -Target $Target -KeyName $keyName)) {
        $script:keyCleanupRequired = $false
        return
    }
    $dialogClicked = $false
    for ($attempt = 1; $attempt -le 3 -and -not $dialogClicked; $attempt++) {
        Clear-LeanTTYDeviceInput -Hdc $hdc -Target $Target
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Submit-TerminalText `
            -Text "key rm $keyName" `
            -LayoutName ($Stage + '-command-' + $attempt.ToString())
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        while ($stopwatch.Elapsed.TotalSeconds -lt 10) {
            try {
                Invoke-LeanTTYDialogButton `
                    -Hdc $hdc -Target $Target -ButtonText 'Delete key' `
                    -LayoutPath (Join-Path $EvidenceDirectory (
                            $Stage + '-dialog-' + $attempt.ToString() + '.json'
                        ))
                $dialogClicked = $true
                break
            } catch {
                Start-Sleep -Milliseconds 200
            }
        }
    }
    if (-not $dialogClicked) {
        throw 'Authentication matrix key deletion confirmation did not appear'
    }
    Wait-LeanTTYAppLog `
        -Hdc $hdc -Target $Target -ProcessId $appProcessId `
        -Pattern 'KEY_DELETE result=success' -TimeoutSeconds 20 | Out-Null
    if (Test-LeanTTYDeviceKeyFilesPresent -Hdc $hdc -Target $Target -KeyName $keyName) {
        throw 'Authentication matrix disposable key remained after deletion'
    }
    $script:keyCleanupRequired = $false
}

function Invoke-TransferFixtureAction {
    param([Parameter(Mandatory = $true)][string]$Stage)

    $layoutPath = Join-Path $EvidenceDirectory ($Stage + '-before-menu.json')
    $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $layoutPath
    $moreButton = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
        [string]$_.attributes.type -eq 'Stack' -and
        [string]$_.attributes.clickable -eq 'true' -and
        [string]$_.attributes.description -eq ''
    } | Sort-Object {
        (Get-LeanTTYBoundsCenter -Bounds ([string]$_.attributes.bounds)).x
    } -Descending | Select-Object -First 1)
    if ($moreButton.Count -ne 1) { throw 'LeanTTY four-dot menu button was not found' }
    $moreCenter = Get-LeanTTYBoundsCenter -Bounds ([string]$moreButton[0].attributes.bounds)
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Invoke-LeanTTYDeviceClick `
        -Hdc $hdc -Target $Target -X $moreCenter.x -Y $moreCenter.y `
        -Operation 'LeanTTY transfer fixture menu open'
    Start-Sleep -Milliseconds 300
    $menuPath = Join-Path $EvidenceDirectory ($Stage + '-menu.json')
    $menu = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $menuPath
    $label = 'Acceptance: Transfer Fixture'
    $node = @(Get-LeanTTYLayoutNodes -Node $menu | Where-Object {
        [string]$_.attributes.text -eq $label -or [string]$_.attributes.originalText -eq $label
    } | Select-Object -First 1)
    if ($node.Count -ne 1) { throw 'The debug package does not expose the transfer fixture action' }
    $center = Get-LeanTTYBoundsCenter -Bounds ([string]$node[0].attributes.bounds)
    Invoke-LeanTTYDeviceClick `
        -Hdc $hdc -Target $Target -X $center.x -Y $center.y `
        -Operation 'LeanTTY transfer fixture action'
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $logs = ''
    do {
        $logs = (@(& $hdc -t $Target shell "hilog -z 1200 -t app -P $appProcessId" 2>&1) -join "`n")
        if ($logs -match 'ACCEPTANCE_TRANSFER_FIXTURE state=(prepared|cleaned|failed)') { break }
        Start-Sleep -Milliseconds 1000
    } while ($stopwatch.Elapsed.TotalSeconds -lt 10)
    if ($logs -notmatch 'ACCEPTANCE_TRANSFER_FIXTURE state=(prepared|cleaned|failed)') {
        throw 'Timed out waiting for the transfer fixture action'
    }
    $line = @($logs -split "`n" | Where-Object {
        $_ -match 'ACCEPTANCE_TRANSFER_FIXTURE state='
    } | Select-Object -Last 1)
    if ($line.Count -ne 1 -or $line[0] -match 'state=failed') {
        throw 'The transfer fixture action failed'
    }
    return [string]$line[0]
}

function Invoke-SystemApplicationClose {
    $layoutPath = Join-Path $EvidenceDirectory 'application-close-before.json'
    $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $layoutPath
    $button = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
        [string]$_.attributes.id -eq 'EnhanceCloseBtn' -and
        [string]$_.attributes.clickable -eq 'true'
    } | Select-Object -First 1)
    if ($button.Count -ne 1) { throw 'HarmonyOS system close button was not found' }
    $beforeCloseLogs = Get-LeanTTYAppLogs `
        -Hdc $hdc -Target $Target -ProcessId $appProcessId
    if ($beforeCloseLogs -match 'FILE_TRANSFER result=(cancelled|failed|completed)') {
        throw 'GET reached a terminal state while locating the system close button'
    }
    $center = Get-LeanTTYBoundsCenter -Bounds ([string]$button[0].attributes.bounds)
    Invoke-LeanTTYDeviceClick `
        -Hdc $hdc -Target $Target -X $center.x -Y $center.y `
        -Operation 'HarmonyOS system close'
}

function Minimize-LeanTTYTransferWindow {
    $layoutPath = Join-Path $EvidenceDirectory 'transfer-before-minimize.json'
    $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $layoutPath
    $button = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
        [string]$_.attributes.id -eq 'EnhanceMinimizeBtn'
    } | Select-Object -First 1)
    if ($button.Count -ne 1) { throw 'HarmonyOS system minimize button was not found' }
    $center = Get-LeanTTYBoundsCenter -Bounds ([string]$button[0].attributes.bounds)
    Invoke-LeanTTYDeviceClick `
        -Hdc $hdc -Target $Target -X $center.x -Y $center.y `
        -Operation 'HarmonyOS system minimize'
    Wait-LeanTTYAppLog `
        -Hdc $hdc -Target $Target -ProcessId $appProcessId `
        -Pattern 'Window visibility changed: visible=false' -TimeoutSeconds 10 | Out-Null
    $minimizedProcessId = (@(& $hdc -t $Target shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
    if ($minimizedProcessId -ne $appProcessId) {
        throw 'LeanTTY process changed while minimizing an active transfer'
    }
}

function Restore-LeanTTYTransferWindow {
    & $hdc -t $Target shell 'aa start -a EntryAbility -b com.leantty.app' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to restore the minimized LeanTTY transfer window' }
    Wait-LeanTTYAppLog `
        -Hdc $hdc -Target $Target -ProcessId $appProcessId `
        -Pattern 'Window visibility changed: visible=true' -TimeoutSeconds 10 | Out-Null
    $restoredProcessId = (@(& $hdc -t $Target shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
    if ($restoredProcessId -ne $appProcessId) {
        throw 'LeanTTY process changed while restoring the transfer window'
    }
    Wait-LeanTTYTerminalInputLayout `
        -Hdc $hdc -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory 'transfer-after-restore.json') `
        -TimeoutSeconds 20 | Out-Null
}

function Confirm-SystemApplicationClose {
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 20) {
        $layoutPath = Join-Path $EvidenceDirectory 'application-close-dialog.json'
        $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $layoutPath
        $button = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
            [string]$_.attributes.text -eq 'Close LeanTTY' -or
            [string]$_.attributes.originalText -eq 'Close LeanTTY'
        } | Select-Object -First 1)
        if ($button.Count -eq 1) {
            Save-LeanTTYDeviceScreenshot `
                -Hdc $hdc -Target $Target `
                -LocalPath (Join-Path $EvidenceDirectory 'application-close-dialog.png')
            $center = Get-LeanTTYBoundsCenter -Bounds ([string]$button[0].attributes.bounds)
            $closeStopwatch = [Diagnostics.Stopwatch]::StartNew()
            Invoke-LeanTTYDeviceClick `
                -Hdc $hdc -Target $Target -X $center.x -Y $center.y `
                -Operation 'LeanTTY close confirmation'
            return $closeStopwatch
        }
        Start-Sleep -Milliseconds 200
    }
    throw 'Timed out waiting for the Close LeanTTY confirmation dialog'
}

function Wait-ApplicationProcessExit {
    param([Parameter(Mandatory = $true)][string]$ExpectedProcessId)

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 20) {
        $current = (@(& $hdc -t $Target shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
        if ($current -notmatch '^\d+$' -or $current -ne $ExpectedProcessId) { return }
        Start-Sleep -Milliseconds 200
    }
    throw 'LeanTTY process did not exit after confirmed application close'
}

function Stop-LeanTTYApplicationAbruptly {
    param([Parameter(Mandatory = $true)][string]$Stage)

    $before = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appProcessId
    if ($before -match 'FILE_TRANSFER result=(cancelled|failed|completed)') {
        throw "$Stage reached a terminal transfer result before forced termination"
    }
    $oldProcessId = $appProcessId
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    & $hdc -t $Target shell 'aa force-stop com.leantty.app' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "$Stage force-stop command failed" }
    Wait-ApplicationProcessExit -ExpectedProcessId $oldProcessId
    $stopwatch.Stop()
    $after = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $oldProcessId
    if ($after -match 'Application close preparation' -or
        $after -match 'FILE_TRANSFER result=(cancelled|failed|completed)' -or
        $after -match 'FILE_TRANSFER phase=IDLE') {
        throw "$Stage did not bypass the graceful transfer and application-close paths"
    }
    return [pscustomobject]@{
        processId = $oldProcessId
        elapsedMilliseconds = [int]$stopwatch.ElapsedMilliseconds
        logs = $after
    }
}

function Wait-PaneCount {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 2)][int]$Count,
        [Parameter(Mandatory = $true)][string]$LayoutName
    )

    $path = Join-Path $EvidenceDirectory $LayoutName
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 20) {
        $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $path
        if (@(Get-LeanTTYTerminalInputNodes -Layout $layout).Count -eq $Count) { return $layout }
        Start-Sleep -Milliseconds 200
    }
    throw "Timed out waiting for LeanTTY pane count: $Count"
}

function Split-And-FocusTransferPane {
    & $hdc -t $Target shell (
        'uinput -K -d 2072 -d 2047 -d 2020 -u 2020 -u 2047 -u 2072'
    ) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to invoke the LeanTTY split shortcut' }
    $layout = Wait-PaneCount -Count 2 -LayoutName 'pane-close-after-split.json'
    $nodes = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
    $center = Get-LeanTTYBoundsCenter -Bounds ([string]$nodes[0].attributes.bounds)
    Invoke-LeanTTYDeviceClick `
        -Hdc $hdc -Target $Target -X $center.x -Y $center.y `
        -Operation 'LeanTTY transfer Pane focus before close'
    $path = Join-Path $EvidenceDirectory 'pane-close-focused.json'
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 10) {
        $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $path
        $nodes = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
        if ($nodes.Count -eq 2 -and [string]$nodes[0].attributes.focused -eq 'true') { return }
        Start-Sleep -Milliseconds 200
    }
    throw 'Timed out focusing the transfer Pane before close'
}

function Focus-TransferPaneByIndex {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(0, 1)][int]$Index,
        [Parameter(Mandatory = $true)][string]$LayoutName
    )

    $layout = Wait-PaneCount -Count 2 -LayoutName ($LayoutName + '-before.json')
    $nodes = @(Get-LeanTTYTerminalInputNodes -Layout $layout | Sort-Object {
        (Get-LeanTTYBoundsCenter -Bounds ([string]$_.attributes.bounds)).x
    })
    $center = Get-LeanTTYBoundsCenter -Bounds ([string]$nodes[$Index].attributes.bounds)
    Invoke-LeanTTYDeviceClick `
        -Hdc $hdc -Target $Target -X $center.x -Y $center.y `
        -Operation "LeanTTY transfer Pane $Index focus"
    $path = Join-Path $EvidenceDirectory ($LayoutName + '-focused.json')
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 10) {
        $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $path
        $nodes = @(Get-LeanTTYTerminalInputNodes -Layout $layout | Sort-Object {
            (Get-LeanTTYBoundsCenter -Bounds ([string]$_.attributes.bounds)).x
        })
        if ($nodes.Count -eq 2 -and [string]$nodes[$Index].attributes.focused -eq 'true') { return }
        Start-Sleep -Milliseconds 200
    }
    throw "Timed out focusing transfer Pane index $Index"
}

function Invoke-ActivePaneClose {
    $layout = Wait-PaneCount -Count 2 -LayoutName 'pane-close-before.json'
    $buttons = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
        [string]$_.attributes.text -eq '×' -and
        [string]$_.attributes.clickable -eq 'true' -and
        [string]$_.attributes.visible -eq 'true'
    } | Sort-Object {
        (Get-LeanTTYBoundsCenter -Bounds ([string]$_.attributes.bounds)).x
    })
    if ($buttons.Count -lt 1) { throw 'LeanTTY active-Pane close button was not found' }
    $beforeCloseLogs = Get-LeanTTYAppLogs `
        -Hdc $hdc -Target $Target -ProcessId $appProcessId
    if ($beforeCloseLogs -match 'FILE_TRANSFER result=(cancelled|failed|completed)') {
        throw 'GET reached a terminal state while locating the Pane close button'
    }
    $center = Get-LeanTTYBoundsCenter -Bounds ([string]$buttons[0].attributes.bounds)
    Invoke-LeanTTYDeviceClick `
        -Hdc $hdc -Target $Target -X $center.x -Y $center.y `
        -Operation 'LeanTTY active-Pane close button'
}

function Confirm-ActivePaneClose {
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 20) {
        $layoutPath = Join-Path $EvidenceDirectory 'pane-close-dialog.json'
        $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $layoutPath
        $button = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
            [string]$_.attributes.text -eq 'Close pane' -or
            [string]$_.attributes.originalText -eq 'Close pane'
        } | Select-Object -First 1)
        if ($button.Count -eq 1) {
            $beforeConfirmLogs = Get-LeanTTYAppLogs `
                -Hdc $hdc -Target $Target -ProcessId $appProcessId
            if ($beforeConfirmLogs -match 'FILE_TRANSFER result=(cancelled|failed|completed)') {
                throw 'GET reached a terminal state while locating the Pane-close confirmation'
            }
            Save-LeanTTYDeviceScreenshot `
                -Hdc $hdc -Target $Target `
                -LocalPath (Join-Path $EvidenceDirectory 'pane-close-dialog.png')
            $center = Get-LeanTTYBoundsCenter -Bounds ([string]$button[0].attributes.bounds)
            $closeStopwatch = [Diagnostics.Stopwatch]::StartNew()
            Invoke-LeanTTYDeviceClick `
                -Hdc $hdc -Target $Target -X $center.x -Y $center.y `
                -Operation 'LeanTTY Pane close confirmation'
            return $closeStopwatch
        }
        Start-Sleep -Milliseconds 200
    }
    throw 'Timed out waiting for the Close pane confirmation dialog'
}

try {
    $fixtureRunSeconds = 900
    $awakeLeaseMilliseconds = ($fixtureRunSeconds + 300) * 1000
    Start-LeanTTYDeviceAwakeLease `
        -Hdc $hdc `
        -Target $Target `
        -TimeoutMilliseconds $awakeLeaseMilliseconds
    $awakeLease = $true

    $deployArgs = @{ Target = $Target; NoLaunch = $true }
    if ($SkipBuild) { $deployArgs['SkipBuild'] = $true }
    if ($FailLocalCleanup -or $LocalDiskFull -or $Backpressure) {
        $deployArgs['ForceNative'] = $true
        Invoke-WithLeanTTYNativeAcceptanceSource -RepoRoot $repoRoot -Action {
            & (Join-Path $PSScriptRoot 'dev-pc.ps1') @deployArgs
        }
    } else {
        & (Join-Path $PSScriptRoot 'dev-pc.ps1') @deployArgs
    }
    if ($LASTEXITCODE -ne 0) { throw 'LeanTTY PUT/GET debug deployment failed' }

    $sftpFault = if ($FailRemoteCleanup) { 'put-write-remove' } elseif (
        -not [string]::IsNullOrWhiteSpace($SftpFailure)) { $SftpFailure } else { 'none' }
    $fixtureArguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $PSScriptRoot 'start-ssh-auth-fixture.ps1'),
        '-ListenAddress', "0.0.0.0:$FixturePort",
        '-RunSeconds', $fixtureRunSeconds.ToString(),
        '-ControlDirectory', $fixtureRoot,
        '-SftpDelayMilliseconds', $SftpDelayMilliseconds.ToString(
            [Globalization.CultureInfo]::InvariantCulture
        ),
        '-SftpFault', $sftpFault
    )
    $fixtureProcess = Start-Process `
        -FilePath 'pwsh.exe' `
        -ArgumentList $fixtureArguments `
        -RedirectStandardOutput $fixtureStdout `
        -RedirectStandardError $fixtureStderr `
        -WindowStyle Hidden `
        -PassThru
    Wait-FixtureReady

    foreach ($line in [IO.File]::ReadAllLines($fixtureCredentials)) {
        $separator = $line.IndexOf('=')
        if ($separator -le 0) { continue }
        $name = $line.Substring(0, $separator)
        $value = $line.Substring($separator + 1)
        $fixtureSecrets[$name] = $value
    }
    $secret = [string]$fixtureSecrets['password']
    if ([string]::IsNullOrWhiteSpace($secret)) { throw 'Fixture password is unavailable' }
    foreach ($name in @('password', 'account', 'token', 'second_token')) {
        $value = [string]$fixtureSecrets[$name]
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Fixture credential is unavailable: $name"
        }
        $authenticationSecrets.Add($value)
    }

    $remoteSourcePath = Join-Path $fixtureSftpRoot $remoteGetName
    $remoteUploadDirectory = Join-Path $fixtureSftpRoot $remoteDirectoryName
    New-Item -ItemType Directory -Path $remoteUploadDirectory | Out-Null
    $remoteUploadedPath = Join-Path $remoteUploadDirectory ($remoteStem + ' (1)' + $remoteExtension)
    $remoteCleanupFinalPath = Join-Path $remoteUploadDirectory 'cleanup.bin'
    if ($sourceKind -eq 'caller-provided') {
        Copy-Item -LiteralPath $SourceFile -Destination $remoteSourcePath
    } else {
        $sourceBytes = [byte[]]::new([int]$sourceBytesCount)
        [Security.Cryptography.RandomNumberGenerator]::Fill($sourceBytes)
        [IO.File]::WriteAllBytes($remoteSourcePath, $sourceBytes)
    }
    $sourceHash = (Get-FileHash -LiteralPath $remoteSourcePath -Algorithm SHA256).Hash
    $expectedCompletionBytes = [regex]::Escape($sourceBytesCount.ToString())
    $fileNameMatrixCases = @()
    if ($FileNameMatrix) {
        $longName = ('l' * 220) + '.bin'
        $fileNameMatrixCases = @(
            [pscustomobject]@{ name = 'space name.bin'; commandName = 'space\ name.bin'; kind = 'space' },
            [pscustomobject]@{ name = '数据.bin'; commandName = '{{DATA}}.bin'; kind = 'unicode' },
            [pscustomobject]@{ name = $longName; commandName = $longName; kind = 'long' }
        )
        foreach ($case in $fileNameMatrixCases) {
            Copy-Item -LiteralPath $remoteSourcePath -Destination (Join-Path $fixtureSftpRoot $case.name)
        }
    }
    if ($LateEvents) {
        $remoteLateCancelPath = Join-Path $fixtureSftpRoot 'late-cancel-source.bin'
        $remoteLateDisconnectPath = Join-Path $fixtureSftpRoot 'late-disconnect-source.bin'
        Copy-Item -LiteralPath $remoteSourcePath -Destination $remoteLateCancelPath
        Copy-Item -LiteralPath $remoteSourcePath -Destination $remoteLateDisconnectPath
    }

    $existingMappings = @(& $hdc -t $Target rport ls 2>&1) -join "`n"
    if ($existingMappings -match "tcp:$FixturePort\b") {
        throw "HDC reverse mapping already exists for fixture port $FixturePort"
    }
    & $hdc -t $Target rport "tcp:$FixturePort" "tcp:$FixturePort" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create the PUT/GET reverse mapping' }
    $reverseMapped = $true

    $launch = Start-LeanTTYRegressionApp `
        -Hdc $hdc `
        -Target $Target `
        -CredentialPath (Get-LeanTTYDeviceUnlockPasswordPath) `
        -RepositoryRoot $repoRoot
    $appProcessId = $launch.processId
    Focus-TerminalInput -Name 'initial-input'
    $fixtureState = Invoke-TransferFixtureAction -Stage 'fixture-prepare'
    if ($fixtureState -match 'state=cleaned') {
        $fixtureState = Invoke-TransferFixtureAction -Stage 'fixture-prepare-retry'
    }
    if ($fixtureState -notmatch 'state=prepared') { throw 'Transfer fixture was not prepared' }
    Focus-TerminalInput -Name 'after-fixture-prepare'

    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    if ($TabCompletionMatrix) {
        $ambiguousPrefix = 'put .leantty-transfer-fixture/report'
        $ambiguousTypedExactly = $false
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            Focus-TerminalInput -Name ('tab-ambiguous-focus-' + $attempt.ToString())
            Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $ambiguousPrefix
            $ambiguousTypedLayout = Get-LeanTTYDeviceLayout `
                -Hdc $hdc -Target $Target `
                -LocalPath (Join-Path $EvidenceDirectory (
                        'tab-ambiguous-typed-' + $attempt.ToString() + '.json'
                    ))
            if ((Get-LeanTTYTerminalInputText -Layout $ambiguousTypedLayout) -ceq $ambiguousPrefix) {
                $ambiguousTypedExactly = $true
                break
            }
            Clear-LeanTTYDeviceInput -Hdc $hdc -Target $Target
            Start-Sleep -Milliseconds 300
        }
        if (-not $ambiguousTypedExactly) {
            throw 'Physical key injection could not enter the exact ambiguous Tab prefix'
        }
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2049
        $listedLogs = Wait-LocalCompletionInputState `
            -ExpectedInput $ambiguousPrefix -Stage 'first Tab list' `
            -CompletionActive $true -MenuActive $false
        $listedLayout = Get-LeanTTYDeviceLayout `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'tab-ambiguous-listed.json')
        if ((Get-LeanTTYTerminalInputText -Layout $listedLayout) -cne $ambiguousPrefix) {
            throw 'First ambiguous Tab did not preserve the typed prefix while listing candidates'
        }
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'tab-ambiguous-listed.png')
        Focus-TerminalInput -Name 'tab-ambiguous-second-tab'
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2049
        $firstCandidate = 'put .leantty-transfer-fixture/report\ alpha.txt'
        $secondCandidate = 'put .leantty-transfer-fixture/report\ beta.txt'
        $menuDiagnosticLogs = Wait-LocalCompletionInputState `
            -ExpectedInput $firstCandidate -Stage 'second Tab menu entry' `
            -CompletionActive $true -MenuActive $true
        $menuLayout = Get-LeanTTYDeviceLayout `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'tab-ambiguous-menu.json')
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'tab-ambiguous-menu.png')
        [IO.File]::WriteAllText(
            (Join-Path $EvidenceDirectory 'tab-ambiguous-menu-hilog.log'),
            $menuDiagnosticLogs
        )
        $ambiguousLogs = $menuDiagnosticLogs
        [IO.File]::WriteAllText(
            (Join-Path $EvidenceDirectory 'tab-ambiguous-hilog.log'),
            $ambiguousLogs
        )
        $ambiguousRecords = @([regex]::Matches(
                $ambiguousLogs,
                'ACCEPTANCE_TAB_COMPLETE input=(?<input>[^\r\n]*),matches=(?<matches>\d+)'
            ))
        if ($ambiguousRecords.Count -eq 0) {
            throw 'Ambiguous Tab completion did not expose its acceptance state'
        }
        $ambiguousRecord = $ambiguousRecords[$ambiguousRecords.Count - 1]
        if ($ambiguousRecord.Groups['input'].Value -cne $firstCandidate -or
            [int]$ambiguousRecord.Groups['matches'].Value -ne 2) {
            throw 'Ambiguous Tab completion did not list then enter the two-candidate menu'
        }

        Focus-TerminalInput -Name 'tab-ambiguous-next'
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2049
        Wait-LocalCompletionInputState `
            -ExpectedInput $secondCandidate -Stage 'next Tab candidate' `
            -CompletionActive $true -MenuActive $true | Out-Null
        $nextLayout = Get-LeanTTYDeviceLayout `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'tab-ambiguous-next.json')

        Focus-TerminalInput -Name 'tab-ambiguous-shift-tab'
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        & $hdc -t $Target shell 'uinput -K -d 2047 -d 2049 -u 2049 -u 2047' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to inject physical Shift+Tab for completion' }
        Wait-LocalCompletionInputState `
            -ExpectedInput $firstCandidate -Stage 'Shift+Tab previous candidate' `
            -CompletionActive $true -MenuActive $true | Out-Null
        $reverseLayout = Get-LeanTTYDeviceLayout `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'tab-ambiguous-shift-tab.json')

        Focus-TerminalInput -Name 'tab-ambiguous-up'
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2012
        Wait-LocalCompletionInputState `
            -ExpectedInput $firstCandidate -Stage 'Up stays in the only displayed row' `
            -CompletionActive $true -MenuActive $true | Out-Null
        $upLayout = Get-LeanTTYDeviceLayout `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'tab-ambiguous-up.json')

        Focus-TerminalInput -Name 'tab-ambiguous-down'
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2013
        Wait-LocalCompletionInputState `
            -ExpectedInput $firstCandidate -Stage 'Down stays in the only displayed row' `
            -CompletionActive $true -MenuActive $true | Out-Null
        $downLayout = Get-LeanTTYDeviceLayout `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'tab-ambiguous-down.json')

        Focus-TerminalInput -Name 'tab-ambiguous-right'
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2015
        Wait-LocalCompletionInputState `
            -ExpectedInput $secondCandidate -Stage 'Right next candidate column' `
            -CompletionActive $true -MenuActive $true | Out-Null
        $rightLayout = Get-LeanTTYDeviceLayout `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'tab-ambiguous-right.json')

        Focus-TerminalInput -Name 'tab-ambiguous-left'
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2014
        Wait-LocalCompletionInputState `
            -ExpectedInput $firstCandidate -Stage 'Left previous candidate column' `
            -CompletionActive $true -MenuActive $true | Out-Null
        $leftLayout = Get-LeanTTYDeviceLayout `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'tab-ambiguous-left.json')

        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Focus-TerminalInput -Name 'tab-ambiguous-accept'
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2054
        $acceptedLogs = Wait-LocalCompletionInputState `
            -ExpectedInput ($firstCandidate + ' ') -Stage 'Enter accept without submit' `
            -CompletionActive $false -MenuActive $false
        $acceptedLayout = Get-LeanTTYDeviceLayout `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'tab-ambiguous-accepted.json')
        if ($acceptedLogs -match 'ACCEPTANCE_INPUT_SUBMIT|File transfer authentication prompt=|FILE_TRANSFER phase=') {
            throw 'Accepting a completion candidate unexpectedly submitted the command'
        }
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'tab-ambiguous-accepted.png')
        Reset-TerminalInput -LayoutName 'tab-ambiguous-reset'

        Focus-TerminalInput -Name 'tab-ambiguous-cancel-focus'
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $ambiguousPrefix
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2049
        Wait-LocalCompletionInputState `
            -ExpectedInput $ambiguousPrefix -Stage 'cancel list setup' `
            -CompletionActive $true -MenuActive $false | Out-Null
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2049
        Wait-LocalCompletionInputState `
            -ExpectedInput $firstCandidate -Stage 'cancel menu setup' `
            -CompletionActive $true -MenuActive $true | Out-Null
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2070
        Wait-LocalCompletionInputState `
            -ExpectedInput $ambiguousPrefix -Stage 'Esc restore' `
            -CompletionActive $false -MenuActive $false | Out-Null
        $cancelledLayout = Get-LeanTTYDeviceLayout `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'tab-ambiguous-cancelled.json')
        Reset-TerminalInput -LayoutName 'tab-ambiguous-cancel-reset'

        Focus-TerminalInput -Name 'tab-selected-space-focus'
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $ambiguousPrefix
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2049
        Wait-LocalCompletionInputState `
            -ExpectedInput $ambiguousPrefix -Stage 'selected space list setup' `
            -CompletionActive $true -MenuActive $false | Out-Null
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2049
        Wait-LocalCompletionInputState `
            -ExpectedInput $firstCandidate -Stage 'selected space menu setup' `
            -CompletionActive $true -MenuActive $true | Out-Null
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2050
        Wait-LocalCompletionInputState `
            -ExpectedInput ($firstCandidate + ' ') -Stage 'selected file keeps name before Space' `
            -CompletionActive $false -MenuActive $false | Out-Null
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'tab-selected-space.png')
        Reset-TerminalInput -LayoutName 'tab-selected-space-reset'

        Focus-TerminalInput -Name 'tab-selected-backspace-focus'
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $ambiguousPrefix
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2049
        Wait-LocalCompletionInputState `
            -ExpectedInput $ambiguousPrefix -Stage 'selected Backspace list setup' `
            -CompletionActive $true -MenuActive $false | Out-Null
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2049
        Wait-LocalCompletionInputState `
            -ExpectedInput $firstCandidate -Stage 'selected Backspace menu setup' `
            -CompletionActive $true -MenuActive $true | Out-Null
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2055
        Wait-LocalCompletionInputState `
            -ExpectedInput $firstCandidate.Substring(0, $firstCandidate.Length - 1) `
            -Stage 'selected file Backspace edits visible name' `
            -CompletionActive $false -MenuActive $false | Out-Null
        Reset-TerminalInput -LayoutName 'tab-selected-backspace-reset'

        $nestedPrefix = 'put .leantty-transfer-fixture/nested'
        $nestedDirectory = 'put .leantty-transfer-fixture/nested\ alpha/'
        $nestedListReady = $false
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            Focus-TerminalInput -Name ('tab-slash-descent-focus-' + $attempt.ToString())
            Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
            Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $nestedPrefix
            Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2049
            try {
                Wait-LocalCompletionInputState `
                    -ExpectedInput $nestedPrefix -Stage ('repeated slash list setup attempt ' + $attempt.ToString()) `
                    -CompletionActive $true -MenuActive $false | Out-Null
                $nestedListReady = $true
                break
            } catch {
                if ($attempt -eq 2) { throw }
                Clear-LeanTTYDeviceInput -Hdc $hdc -Target $Target
                Start-Sleep -Milliseconds 300
            }
        }
        if (-not $nestedListReady) {
            throw 'Physical key injection could not open the exact slash-descent candidate list'
        }
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2049
        Wait-LocalCompletionInputState `
            -ExpectedInput $nestedDirectory -Stage 'repeated slash menu setup' `
            -CompletionActive $true -MenuActive $true | Out-Null
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2064
        Wait-LocalCompletionInputState `
            -ExpectedInput $nestedDirectory -Stage 'repeated slash keeps one separator and closes menu' `
            -CompletionActive $false -MenuActive $false | Out-Null
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'tab-repeated-slash.png')
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2049
        Wait-LocalCompletionInputState `
            -ExpectedInput ($nestedDirectory + 'child.txt ') -Stage 'next Tab explicitly completes child' `
            -CompletionActive $false -MenuActive $false | Out-Null
        Reset-TerminalInput -LayoutName 'tab-repeated-slash-reset'

        $directoryPrefix = 'put ./.leantty-transfer-f'
        $completedDirectory = 'put ./.leantty-transfer-fixture/'
        Focus-TerminalInput -Name 'tab-directory-descent-focus'
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $directoryPrefix
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2049
        Wait-LocalCompletionInputState `
            -ExpectedInput $completedDirectory -Stage 'directory completion' `
            -CompletionActive $false -MenuActive $false | Out-Null
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2049
        $descentLogs = Wait-LocalCompletionInputState `
            -ExpectedInput $completedDirectory -Stage 'directory child list' `
            -CompletionActive $true -MenuActive $false
        $descentLayout = Get-LeanTTYDeviceLayout `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'tab-directory-descent.json')
        $descentRecords = @([regex]::Matches(
                $descentLogs,
                'ACCEPTANCE_TAB_COMPLETE input=(?<input>[^\r\n]*),matches=(?<matches>\d+)'
            ))
        if ($descentRecords.Count -lt 1 -or
            $descentRecords[$descentRecords.Count - 1].Groups['input'].Value -cne $completedDirectory -or
            [int]$descentRecords[$descentRecords.Count - 1].Groups['matches'].Value -lt 2) {
            throw 'Completed directory did not expose its current-layer child candidates'
        }
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'tab-directory-descent.png')
        Reset-TerminalInput -LayoutName 'tab-directory-descent-reset'

        Assert-LocalTabCompletion `
            -Typed 'put .leantty-transfer-f' `
            -Expected 'put .leantty-transfer-fixture/' `
            -Name 'tab-directory'
        Assert-LocalTabCompletion `
            -Typed 'put ./.leantty-transfer-f' `
            -Expected 'put ./.leantty-transfer-fixture/' `
            -Name 'tab-explicit-downloads-root'
        Assert-LocalTabCompletion `
            -Typed 'put .leantty-transfer-fixture/report\ a' `
            -Expected 'put .leantty-transfer-fixture/report\ alpha.txt ' `
            -Name 'tab-space'
        Assert-LocalTabCompletion `
            -Typed 'put ".leantty-transfer-fixture/report a' `
            -Expected 'put .leantty-transfer-fixture/report\ alpha.txt ' `
            -Name 'tab-quote-canonicalization'
        Assert-LocalUnicodeTabCompletion
        Assert-LocalTabCompletion `
            -Typed 'put .leantty-transfer-fixture/.h' `
            -Expected 'put .leantty-transfer-fixture/.hidden-file ' `
            -Name 'tab-hidden'

        Assert-LocalTabCompletion `
            -Typed 'put .leantty-transfer-fixture/unsafe' `
            -Expected 'put .leantty-transfer-fixture/unsafe' `
            -Name 'tab-unsafe-format-filter' `
            -ExpectedMatches 0 `
            -TabCount 2
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'tab-safe-final.png')
        $allLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appProcessId
        if ($allLogs -match 'File transfer authentication prompt=|FILE_TRANSFER phase=PREPARING|FILE_TRANSFER result=') {
            throw 'Tab completion matrix started a transfer or remote authentication'
        }
        $cleanupState = Invoke-TransferFixtureAction -Stage 'fixture-tab-completion-cleanup'
        if ($cleanupState -notmatch (
                'state=cleaned,originalPreserved=true,numberedPresent=false,' +
                'temporaryPresent=false,cleanupFailureFinalPresent=false,temporaryCount=0'
            )) {
            throw 'Tab completion matrix changed fixture data or retained a temporary file'
        }
        [ordered]@{
            recordedAt = (Get-Date).ToString('o')
            gate = '1.3-production-local-tab-completion'
            result = 'passed'
            fixedFont = 'packaged HarmonyOS Sans Mono'
            unique = @('directory', './ Downloads root', 'space', 'quoted input canonicalized', 'Unicode', 'hidden item')
            ambiguous = 'first Tab listed; second entered menu; Tab and Shift+Tab cycled; two-dimensional arrows followed displayed rows and columns; Enter accepted and Esc restored without execution'
            selectedEditing = 'Space and Backspace closed the menu and edited the selected visible file name without restoring the old prefix'
            directoryDescent = './ root completion remained explicit; repeated slash kept one separator and the next Tab completed the child without recursion'
            unsafe = 'Unicode format-control candidate was excluded before terminal rendering'
            sideEffects = 'no permission request, transfer state or remote authentication observed'
            sourceDirty = (@(git -C $repoRoot status --short).Count -gt 0)
            sourceCommit = (git -C $repoRoot rev-parse HEAD)
            hapSha256 = (Get-FileHash -LiteralPath (
                    Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
                ) -Algorithm SHA256).Hash.ToLowerInvariant()
        } | ConvertTo-Json -Depth 6 | Set-Content `
            -LiteralPath (Join-Path $EvidenceDirectory 'device-tab-completion.json') `
            -Encoding utf8NoBOM
        Write-Host 'TAB COMPLETION PC GATE PASSED: fixed-font local matrix stayed offline and safe' `
            -ForegroundColor Green
        return
    }
    if ($AuthenticationMatrix) {
        $existingAuthenticationKeyNames = @(
            Get-LeanTTYDeviceRegressionKeyNames -Hdc $hdc -Target $Target
        )
        $keyName = 'ltty_reg_' + (New-DeviceSafeRandomLetters -Length 10)
        $keyPassphrase = New-DeviceSafeRandomLetters -Length 24
        $authenticationSecrets.Add($keyPassphrase)

        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        $keyCleanupRequired = $true
        Submit-TerminalText `
            -Text "ssh-keygen -t ed25519 -f $keyName -C regression" `
            -LayoutName 'auth-key-generate'
        $keyName = Wait-AuthenticationMatrixKeyCreated `
            -ExpectedName $keyName -ExistingNames $existingAuthenticationKeyNames

        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Submit-TerminalText `
            -Text (
                "get -p $FixturePort -i $keyName publickey@127.0.0.1:/$remoteGetName " +
                $localDirectoryName + '/'
            ) `
            -LayoutName 'auth-publickey-get-command'
        Wait-AuthenticationMatrixEvent `
            -Stage 'auth-publickey-get' `
            -Expected '^FILE_TRANSFER result=completed$' | Out-Null
        Wait-AuthenticationMatrixCompletion `
            -Stage 'auth-publickey-get' -Direction get -AlreadyObserved
        Reset-AuthenticationMatrixDownload -Stage 'auth-publickey-get'

        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Submit-TerminalText `
            -Text "ssh-keygen -p -f $keyName" `
            -LayoutName 'auth-key-encrypt-command'
        Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'KEY_PASSPHRASE_CHANGE stage=old' -TimeoutSeconds 60 | Out-Null
        Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
        Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'KEY_PASSPHRASE_CHANGE stage=new' -TimeoutSeconds 60 | Out-Null
        Submit-HiddenTransferValue `
            -Value $keyPassphrase -LayoutName 'auth-key-encrypt-new'
        Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'KEY_PASSPHRASE_CHANGE stage=confirm' -TimeoutSeconds 60 | Out-Null
        Submit-HiddenTransferValue `
            -Value $keyPassphrase -LayoutName 'auth-key-encrypt-confirm'
        Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'KEY_PASSPHRASE_CHANGE result=success' -TimeoutSeconds 30 | Out-Null

        $encryptedRemotePath = Join-Path $remoteUploadDirectory 'auth-encrypted.bin'
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Submit-TerminalText `
            -Text (
                "put -p $FixturePort -i $keyName $localDirectoryName/source.bin " +
                "publickey@127.0.0.1:/$remoteDirectoryName/auth-encrypted.bin"
            ) `
            -LayoutName 'auth-encrypted-put-command'
        Wait-AuthenticationMatrixEvent `
            -Stage 'auth-encrypted-put' `
            -Expected '^File transfer authentication prompt=private-key-passphrase$' | Out-Null
        Submit-HiddenTransferValue `
            -Value $keyPassphrase -LayoutName 'auth-encrypted-put-passphrase'
        Wait-AuthenticationMatrixCompletion -Stage 'auth-encrypted-put' -Direction put
        if (-not (Test-Path -LiteralPath $encryptedRemotePath -PathType Leaf)) {
            throw 'Encrypted-key PUT did not expose its completed remote file'
        }
        Remove-Item -LiteralPath $encryptedRemotePath -Force

        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Submit-TerminalText `
            -Text (
                "get -p $FixturePort kbdint-multiround@127.0.0.1:/$remoteGetName " +
                $localDirectoryName + '/'
            ) `
            -LayoutName 'auth-kbdint-get-command'
        Wait-AuthenticationMatrixEvent `
            -Stage 'auth-kbdint-round-one' `
            -Expected '^File transfer authentication prompt=keyboard-interactive$' | Out-Null
        Submit-HiddenTransferValue `
            -Value ([string]$fixtureSecrets['account']) `
            -LayoutName 'auth-kbdint-account'
        Wait-AuthenticationMatrixEvent `
            -Stage 'auth-kbdint-round-two' `
            -Expected '^File transfer authentication prompt=keyboard-interactive$' | Out-Null
        Submit-HiddenTransferValue `
            -Value ([string]$fixtureSecrets['second_token']) `
            -LayoutName 'auth-kbdint-second-token'
        Wait-AuthenticationMatrixCompletion -Stage 'auth-kbdint-get' -Direction get
        Reset-AuthenticationMatrixDownload -Stage 'auth-kbdint-get'

        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Submit-TerminalText `
            -Text (
                "get -p $FixturePort password@127.0.0.1:/$remoteGetName " +
                $localDirectoryName + '/'
            ) `
            -LayoutName 'auth-password-after-identity-command'
        Wait-AuthenticationMatrixEvent `
            -Stage 'auth-password-after-identity' `
            -Expected '^File transfer authentication prompt=password$' | Out-Null
        Submit-HiddenTransferValue `
            -Value $secret -LayoutName 'auth-password-after-identity-password'
        Wait-AuthenticationMatrixCompletion `
            -Stage 'auth-password-after-identity' -Direction get

        $cleanupState = Invoke-TransferFixtureAction -Stage 'auth-password-final-cleanup'
        if ($cleanupState -notmatch (
                'state=cleaned,originalPreserved=true,numberedPresent=true,' +
                'temporaryPresent=false,cleanupFailureFinalPresent=false,temporaryCount=0'
            )) {
            throw 'Authentication matrix final Downloads cleanup was incomplete'
        }
        Remove-AuthenticationMatrixKey -Stage 'auth-key-cleanup'
        Submit-TerminalText `
            -Text "ssh-keygen -R [127.0.0.1]:$FixturePort" `
            -LayoutName 'auth-known-host-cleanup'
        Start-Sleep -Milliseconds 500
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'authentication-matrix.png')

        [ordered]@{
            recordedAt = (Get-Date).ToString('o')
            gate = '1.3-production-file-transfer-authentication-matrix'
            result = 'passed'
            authentication = @(
                'GET with an explicitly selected unencrypted Ed25519 key'
                'PUT with the same key after adding a private-key passphrase'
                'GET with two-round keyboard-interactive authentication'
                'GET with password and no identity after explicit -i commands'
            )
            identityScope = 'explicit -i affected only its command; the following no-identity GET prompted for password'
            secrets = 'not present in app logs or hidden-input layout snapshots'
            disposableKey = 'removed through the product key rm workflow and absence audited'
            localCleanup = 'each completed numbered download was observed and removed'
            remoteCleanup = 'completed encrypted-key upload was observed and removed; no temporary file remained'
            sourceDirty = (@(git -C $repoRoot status --short).Count -gt 0)
            sourceCommit = (git -C $repoRoot rev-parse HEAD)
            hapSha256 = (Get-FileHash -LiteralPath (
                    Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
                ) -Algorithm SHA256).Hash.ToLowerInvariant()
        } | ConvertTo-Json -Depth 6 | Set-Content `
            -LiteralPath (Join-Path $EvidenceDirectory 'device-authentication-matrix.json') `
            -Encoding utf8NoBOM
        Write-Host (
            'PUT/GET AUTHENTICATION MATRIX PASSED: password, unencrypted key, encrypted key, ' +
            'keyboard-interactive and command-local -i'
        ) -ForegroundColor Green
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($SftpFailure)) {
        $expectedCode = switch ($SftpFailure) {
            'unavailable' { 'SFTP_UNAVAILABLE' }
            'permission-denied' { 'REMOTE_TEMP_CREATE' }
            'rename-unsupported' { 'REMOTE_COMMIT' }
        }
        if ($SftpFailure -eq 'unavailable') {
            Submit-TerminalText `
                -Text (
                    "get -p $FixturePort password@127.0.0.1:/$remoteGetName " +
                    "$localDirectoryName/local-cleanup-failure.bin"
                ) `
                -LayoutName 'get-sftp-unavailable-command'
        } else {
            Submit-TerminalText `
                -Text (
                    "put -p $FixturePort $localDirectoryName/source.bin " +
                    "password@127.0.0.1:/$remoteDirectoryName/protocol-failure.bin"
                ) `
                -LayoutName ('put-' + $SftpFailure + '-command')
        }
        Complete-PasswordAuthentication -Stage ('sftp-' + $SftpFailure)
        $failureResult = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern ('FILE_TRANSFER result=failed code=' + $expectedCode) `
            -TimeoutSeconds 60
        $failureIdle = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER phase=IDLE' `
            -TimeoutSeconds 20
        if ($failureResult -notmatch ('FILE_TRANSFER result=failed code=' + $expectedCode) -or
            $failureIdle -notmatch 'FILE_TRANSFER phase=IDLE') {
            throw "SFTP $SftpFailure did not fail with $expectedCode and return to IDLE"
        }
        $allLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appProcessId
        $terminalMatches = [regex]::Matches(
            $allLogs,
            'FILE_TRANSFER result=(cancelled|failed|completed)'
        )
        if ($terminalMatches.Count -ne 1 -or
            $terminalMatches[0].Groups[1].Value -ne 'failed') {
            throw "SFTP $SftpFailure did not produce exactly one failed terminal result"
        }
        if ($allLogs.Contains($secret, [StringComparison]::Ordinal)) {
            throw 'HarmonyOS application logs exposed the temporary fixture password'
        }
        $remoteProtocolFailurePath = Join-Path $remoteUploadDirectory 'protocol-failure.bin'
        if (Test-Path -LiteralPath $remoteProtocolFailurePath) {
            throw "SFTP $SftpFailure exposed the remote final file"
        }
        $remoteProtocolTemporaryFiles = @(
            Get-ChildItem -LiteralPath $remoteUploadDirectory -File `
                -Filter '.leantty-*.part'
        )
        if ($remoteProtocolTemporaryFiles.Count -ne 0) {
            throw "SFTP $SftpFailure retained a remote temporary file"
        }
        $fixtureLogs = Read-SftpFixtureLogText
        $fixturePattern = switch ($SftpFailure) {
            'unavailable' { 'channel subsystem=sftp result=unavailable' }
            'permission-denied' { 'sftp open .*result=permission-denied' }
            'rename-unsupported' { 'sftp rename .*result=unsupported' }
        }
        if ($fixtureLogs -notmatch $fixturePattern) {
            throw "Controlled fixture did not record the SFTP $SftpFailure fault"
        }
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory ('sftp-' + $SftpFailure + '.png'))
        $cleanupState = Invoke-TransferFixtureAction -Stage ('fixture-sftp-' + $SftpFailure + '-cleanup')
        if ($cleanupState -notmatch (
                'state=cleaned,originalPreserved=true,numberedPresent=false,' +
                'temporaryPresent=false,cleanupFailureFinalPresent=false,temporaryCount=0'
            )) {
            throw "SFTP $SftpFailure changed fixture data or retained a local temporary file"
        }
        [ordered]@{
            recordedAt = (Get-Date).ToString('o')
            gate = '1.3-production-sftp-failure-recovery'
            result = 'passed'
            fault = $SftpFailure
            failureCode = $expectedCode
            terminalResult = 'failed exactly once, then returned to IDLE'
            localFinal = 'not exposed'
            localTemporary = 'none after product cleanup'
            remoteFinal = 'not exposed'
            remoteTemporary = 'none after product cleanup'
            localSource = 'pre-existing Downloads source.bin remained byte-exact'
            sourceDirty = (@(git -C $repoRoot status --short).Count -gt 0)
            sourceCommit = (git -C $repoRoot rev-parse HEAD)
            hapSha256 = (Get-FileHash -LiteralPath (
                    Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
                ) -Algorithm SHA256).Hash.ToLowerInvariant()
        } | ConvertTo-Json -Depth 6 | Set-Content `
            -LiteralPath (Join-Path $EvidenceDirectory ('device-sftp-' + $SftpFailure + '.json')) `
            -Encoding utf8NoBOM
        Write-Host "SFTP $SftpFailure GATE PASSED: failed once, no final/temp, Pane IDLE" `
            -ForegroundColor Green
        return
    }
    if ($LateEvents) {
        Split-And-FocusTransferPane
        Submit-FocusedTerminalText -Text (
            "get -p $FixturePort password@127.0.0.1:/late-cancel-source.bin " +
            "$localDirectoryName/late-cancel-result.bin"
        )
        Complete-FocusedPasswordAuthentication -Stage 'late-cancel'
        $cancelProgress = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER (progress=visible|result=(failed|completed|cancelled))' `
            -TimeoutSeconds 60
        if ($cancelProgress -notmatch 'FILE_TRANSFER progress=visible') {
            throw 'Late-event cancellation GET reached a terminal state before positive progress'
        }
        $cancelProgress | Set-Content `
            -LiteralPath (Join-Path $EvidenceDirectory 'late-events-cancel-checkpoint.log') `
            -Encoding utf8NoBOM
        if ($cancelProgress -notmatch (
                'ACCEPTANCE_FILE_TRANSFER_LATE_EVENT scenario=cancel,state=armed'
            )) {
            throw 'Late-event cancellation fixture did not arm for its remote path'
        }
        if ($cancelProgress -notmatch (
                'ACCEPTANCE_FILE_TRANSFER_LATE_EVENT scenario=cancel,state=captured'
            )) {
            throw 'Late-event cancellation fixture did not capture the old transfer identity'
        }
        Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $Target
        $cancelResult = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER result=(cancelled|failed|completed)' `
            -TimeoutSeconds 30
        $cancelIdle = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER phase=IDLE' `
            -TimeoutSeconds 20
        if ($cancelResult -notmatch 'FILE_TRANSFER result=cancelled' -or
            $cancelIdle -notmatch 'FILE_TRANSFER phase=IDLE') {
            throw 'Late-event cancellation GET did not cancel exactly and return to IDLE'
        }
        $cancelLogs = Get-LeanTTYAppLogs `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId
        $cancelTerminalMatches = [regex]::Matches(
            $cancelLogs,
            'FILE_TRANSFER result=(cancelled|failed|completed)'
        )
        if ($cancelTerminalMatches.Count -ne 1 -or
            $cancelTerminalMatches[0].Groups[1].Value -ne 'cancelled') {
            throw 'Late-event cancellation GET did not produce exactly one cancelled terminal result'
        }

        Focus-TransferPaneByIndex -Index 0 -LayoutName 'late-events-transfer-pane'
        Submit-FocusedTerminalText -Text (
            "get -p $FixturePort password@127.0.0.1:/late-disconnect-source.bin " +
            "$localDirectoryName/late-disconnect-result.bin"
        )
        Complete-FocusedPasswordAuthentication -Stage 'late-disconnect'
        $disconnectProgress = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER (progress=visible|result=(failed|completed|cancelled))' `
            -TimeoutSeconds 60
        if ($disconnectProgress -notmatch 'FILE_TRANSFER progress=visible') {
            throw 'Late-event disconnect GET reached a terminal state before positive progress'
        }
        $disconnectProgress | Set-Content `
            -LiteralPath (Join-Path $EvidenceDirectory 'late-events-disconnect-checkpoint.log') `
            -Encoding utf8NoBOM
        if ($disconnectProgress -notmatch (
                'ACCEPTANCE_FILE_TRANSFER_LATE_EVENT scenario=disconnect,state=armed'
            )) {
            throw 'Late-event disconnect fixture did not arm for the second Pane transfer'
        }
        $cancelLateEvent = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'ACCEPTANCE_FILE_TRANSFER_LATE_EVENT scenario=cancel,state=(injected|missing)' `
            -TimeoutSeconds 20
        if ($cancelLateEvent -match 'ACCEPTANCE_FILE_TRANSFER_LATE_EVENT scenario=cancel,state=missing') {
            throw 'Cancelled transfer old event was not retained for the next Pane transfer'
        }
        if ($cancelLateEvent -notmatch 'Rejected stale file transfer event, kind=completed') {
            throw 'Cancelled transfer late completion was not rejected by the active Pane transfer identity'
        }
        if ($fixtureLinuxPid -le 0) { throw 'SFTP fixture Linux process ID is unavailable' }
        & wsl.exe --exec kill -TERM $fixtureLinuxPid 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to terminate the controlled SFTP fixture' }
        $fixtureLinuxPid = 0
        $disconnectResult = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER result=(failed code=\S+|completed|cancelled)' `
            -TimeoutSeconds 40
        $disconnectIdle = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER phase=IDLE' `
            -TimeoutSeconds 20
        if ($disconnectResult -notmatch 'FILE_TRANSFER result=failed code=NETWORK' -or
            $disconnectIdle -notmatch 'FILE_TRANSFER phase=IDLE') {
            throw 'Late-event disconnected GET did not fail with NETWORK and return to IDLE'
        }

        Focus-TransferPaneByIndex -Index 1 -LayoutName 'late-events-surviving-pane'
        $disconnectLateEvent = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'ACCEPTANCE_FILE_TRANSFER_LATE_EVENT scenario=disconnect,state=injected' `
            -TimeoutSeconds 20
        if ($disconnectLateEvent -notmatch 'Rejected stale file transfer event, kind=completed') {
            throw 'Disconnected transfer late completion was not rejected after focus moved to the other Pane'
        }
        $allLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appProcessId
        $terminalMatches = [regex]::Matches(
            $allLogs,
            'FILE_TRANSFER result=(cancelled|failed|completed)'
        )
        $rejectionMatches = [regex]::Matches(
            $allLogs,
            'Rejected stale file transfer event, kind=completed'
        )
        $allLogs | Set-Content `
            -LiteralPath (Join-Path $EvidenceDirectory 'late-events-final-checkpoint.log') `
            -Encoding utf8NoBOM
        [ordered]@{
            terminalCount = $terminalMatches.Count
            terminalKinds = @($terminalMatches | ForEach-Object { $_.Groups[1].Value })
            rejectionCount = $rejectionMatches.Count
        } | ConvertTo-Json -Depth 4 | Set-Content `
            -LiteralPath (Join-Path $EvidenceDirectory 'late-events-final-counts.json') `
            -Encoding utf8NoBOM
        if ($terminalMatches.Count -ne 1 -or
            $terminalMatches[0].Groups[1].Value -ne 'failed' -or
            $rejectionMatches.Count -ne 2) {
            throw 'Late events changed the disconnect outcome or were not rejected exactly once per old transfer'
        }
        if ($allLogs.Contains($secret, [StringComparison]::Ordinal)) {
            throw 'HarmonyOS application logs exposed the temporary fixture password'
        }
        $currentProcessId = (@(& $hdc -t $Target shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
        if ($currentProcessId -ne $appProcessId) {
            throw 'Late transfer events changed the LeanTTY application process'
        }
        $finalLayout = Wait-PaneCount -Count 2 -LayoutName 'late-events-final-layout.json'
        $finalNodes = @(Get-LeanTTYTerminalInputNodes -Layout $finalLayout | Sort-Object {
            (Get-LeanTTYBoundsCenter -Bounds ([string]$_.attributes.bounds)).x
        })
        if ([string]$finalNodes[1].attributes.focused -ne 'true') {
            throw 'The surviving second Pane lost focus after disconnected-transfer late delivery'
        }
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'late-events-surviving-pane.png')
        $cleanupState = Invoke-TransferFixtureAction -Stage 'fixture-late-events-cleanup'
        if ($cleanupState -notmatch (
                'state=cleaned,originalPreserved=true,numberedPresent=false,' +
                'temporaryPresent=false,cleanupFailureFinalPresent=false,temporaryCount=0,' +
                'backpressureFinalPresent=false,forceGetFinalPresent=false,' +
                'forcePutSourcePresent=true,forcePutSourceSize=2097152,' +
                'lateCancelFinalPresent=false,lateDisconnectFinalPresent=false'
            )) {
            throw 'Late-event gate exposed a final file, retained a temporary file or changed fixture data'
        }
        $lateEventEvidence = [ordered]@{
            recordedAt = (Get-Date).ToString('o')
            gate = '1.3-production-put-get-two-pane-late-event-isolation'
            result = 'passed'
            bytesAvailablePerTransfer = $sourceBytesCount
            sftpDelayMilliseconds = $SftpDelayMilliseconds
            injectedLateEvents = 2
            rejectedLateEvents = $rejectionMatches.Count
            terminalResults = 'cancelled once before hilog rollover, then failed with NETWORK once; no completion'
            identityBoundary = 'transferId, paneId and generation rejected both old completed events'
            survivingPanes = 'two Panes remained in the original application process; the second Pane remained focusable'
            localFinals = 'neither late-cancel-result.bin nor late-disconnect-result.bin was exposed'
            localTemporary = 'no owned same-directory temporary file remained before fixture cleanup'
            original = 'pre-existing Downloads source.bin remained byte-exact'
            sourceDirty = (@(git -C $repoRoot status --short).Count -gt 0)
            sourceCommit = (git -C $repoRoot rev-parse HEAD)
            hapSha256 = (Get-FileHash -LiteralPath (
                    Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
                ) -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $lateEventEvidence | ConvertTo-Json -Depth 6 | Set-Content `
            -LiteralPath (Join-Path $EvidenceDirectory 'device-put-get-late-events.json') `
            -Encoding utf8NoBOM
        Write-Host 'PUT/GET LATE EVENT GATE PASSED: two Panes survived, stale completions rejected' `
            -ForegroundColor Green
        return
    }
    if ($FailRemoteCleanup) {
        Complete-TerminalTextWithTab `
            -Prefix "put -p $FixturePort $localDirectoryName/source.b" `
            -Suffix "password@127.0.0.1:/$remoteDirectoryName/cleanup.bin" `
            -LayoutName 'put-remote-cleanup-command'
        Complete-PasswordAuthentication -Stage 'put-remote-cleanup'
        $cleanupFailure = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER result=failed code=REMOTE_CLEANUP' `
            -TimeoutSeconds 60
        $cleanupIdle = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER phase=IDLE' `
            -TimeoutSeconds 20
        $allLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appProcessId
        $terminalMatches = [regex]::Matches(
            $allLogs,
            'FILE_TRANSFER result=(cancelled|failed|completed)'
        )
        if ($terminalMatches.Count -ne 1 -or
            $terminalMatches[0].Groups[1].Value -ne 'failed') {
            throw 'Remote cleanup failure did not produce exactly one failed terminal result'
        }
        if ($cleanupFailure -notmatch 'FILE_TRANSFER result=failed code=REMOTE_CLEANUP' -or
            $cleanupIdle -notmatch 'FILE_TRANSFER phase=IDLE') {
            throw 'Remote cleanup failure did not return the Pane to IDLE'
        }
        if ($allLogs.Contains($secret, [StringComparison]::Ordinal)) {
            throw 'HarmonyOS application logs exposed the temporary fixture password'
        }
        if (Test-Path -LiteralPath $remoteCleanupFinalPath) {
            throw 'Remote cleanup failure exposed the final remote file name'
        }
        $remoteTemporaryFiles = @(
            Get-ChildItem -LiteralPath $remoteUploadDirectory -File `
            -Filter '.leantty-*.part'
        )
        if ($remoteTemporaryFiles.Count -ne 1) {
            throw 'Remote cleanup failure did not retain exactly one identifiable temporary file'
        }
        $fixtureLogs = Read-SftpFixtureLogText
        if ($fixtureLogs -notmatch 'sftp write .*result=injected-failure' -or
            $fixtureLogs -notmatch 'sftp remove .*result=injected-failure') {
            throw 'Controlled SFTP fixture did not record both injected failures'
        }
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'remote-cleanup-failure.png')
        $cleanupState = Invoke-TransferFixtureAction -Stage 'fixture-remote-cleanup-failure-cleanup'
        if ($cleanupState -notmatch (
                'state=cleaned,originalPreserved=true,numberedPresent=false,temporaryPresent=false'
            )) {
            throw 'Remote cleanup failure changed the local source or left a local temporary file'
        }
        $cleanupFailureEvidence = [ordered]@{
            recordedAt = (Get-Date).ToString('o')
            gate = '1.3-production-put-remote-cleanup-failure'
            result = 'passed'
            terminalResult = 'failed exactly once with REMOTE_CLEANUP, then returned to IDLE'
            remoteFinal = 'cleanup.bin was never exposed'
            remoteTemporary = $remoteTemporaryFiles[0].Name
            localSource = 'pre-existing Downloads source.bin remained byte-exact'
            fixtureFaults = 'write failure followed by remove failure'
            sourceDirty = (@(git -C $repoRoot status --short).Count -gt 0)
            sourceCommit = (git -C $repoRoot rev-parse HEAD)
            hapSha256 = (Get-FileHash -LiteralPath (
                    Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
                ) -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $cleanupFailureEvidence | ConvertTo-Json -Depth 6 | Set-Content `
            -LiteralPath (Join-Path $EvidenceDirectory 'device-put-remote-cleanup-failure.json') `
            -Encoding utf8NoBOM
        Write-Host 'PUT REMOTE CLEANUP FAILURE GATE PASSED: failed once, final hidden, Pane IDLE' `
            -ForegroundColor Green
        return
    }
    if ($FailLocalCleanup) {
        $missingRemoteName = 'missing-local-cleanup-source.bin'
        $localCleanupName = $localDirectoryName + '/local-cleanup-failure.bin'
        Submit-TerminalText `
            -Text "get -p $FixturePort password@127.0.0.1:/$missingRemoteName $localCleanupName" `
            -LayoutName 'get-local-cleanup-failure-command'
        Complete-PasswordAuthentication -Stage 'get-local-cleanup-failure'
        $localCleanupFailure = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER result=failed code=REMOTE_NOT_FOUND' `
            -TimeoutSeconds 60
        $localCleanupIdle = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER phase=IDLE' `
            -TimeoutSeconds 20
        $allLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appProcessId
        $terminalMatches = [regex]::Matches(
            $allLogs,
            'FILE_TRANSFER result=(cancelled|failed|completed)'
        )
        if ($terminalMatches.Count -ne 1 -or
            $terminalMatches[0].Groups[1].Value -ne 'failed') {
            throw 'Local cleanup failure did not produce exactly one failed terminal result'
        }
        if ($localCleanupFailure -notmatch 'FILE_TRANSFER result=failed code=REMOTE_NOT_FOUND' -or
            $localCleanupIdle -notmatch 'FILE_TRANSFER phase=IDLE') {
            throw 'Local cleanup failure did not preserve the primary error and return the Pane to IDLE'
        }
        if ($allLogs -notmatch 'Owned transfer temporary file cleanup failed:') {
            throw 'Controlled local cleanup failure was not observed by the Pane owner'
        }
        if ($allLogs.Contains($secret, [StringComparison]::Ordinal)) {
            throw 'HarmonyOS application logs exposed the temporary fixture password'
        }
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'local-cleanup-failure.png')
        $cleanupState = Invoke-TransferFixtureAction -Stage 'fixture-local-cleanup-failure-cleanup'
        if ($cleanupState -notmatch (
                'state=cleaned,originalPreserved=true,numberedPresent=false,' +
                'temporaryPresent=true,cleanupFailureFinalPresent=false,temporaryCount=1'
            )) {
            throw (
                'Local cleanup failure did not retain one temporary file while hiding the final name, ' +
                'or it changed the original fixture file'
            )
        }
        $localCleanupEvidence = [ordered]@{
            recordedAt = (Get-Date).ToString('o')
            gate = '1.3-production-get-local-cleanup-failure'
            result = 'passed'
            terminalResult = 'failed exactly once with REMOTE_NOT_FOUND, then returned to IDLE'
            primaryFailure = 'remote source not found remained the user-facing primary failure'
            cleanupWarning = 'local temporary cleanup warning was appended and visible'
            localFinal = 'local-cleanup-failure.bin was never exposed'
            localTemporary = 'exactly one owned same-directory temporary file remained until fixture cleanup'
            original = 'pre-existing Downloads source.bin remained byte-exact'
            sourceDirty = (@(git -C $repoRoot status --short).Count -gt 0)
            sourceCommit = (git -C $repoRoot rev-parse HEAD)
            hapSha256 = (Get-FileHash -LiteralPath (
                    Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
                ) -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $localCleanupEvidence | ConvertTo-Json -Depth 6 | Set-Content `
            -LiteralPath (Join-Path $EvidenceDirectory 'device-get-local-cleanup-failure.json') `
            -Encoding utf8NoBOM
        Write-Host 'GET LOCAL CLEANUP FAILURE GATE PASSED: warning visible, final hidden, Pane IDLE' `
            -ForegroundColor Green
        return
    }
    if ($LocalDiskFull) {
        $diskFullLocalName = $localDirectoryName + '/disk-full-result.bin'
        Submit-TerminalText `
            -Text "get -p $FixturePort password@127.0.0.1:/$remoteGetName $diskFullLocalName" `
            -LayoutName 'get-local-disk-full-command'
        Complete-PasswordAuthentication -Stage 'get-local-disk-full'
        Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'ACCEPTANCE_LOCAL_DISK_FULL armed' `
            -TimeoutSeconds 60 | Out-Null
        $diskFullFailure = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER result=failed code=\S+' `
            -TimeoutSeconds 60
        $diskFullIdle = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER phase=IDLE' `
            -TimeoutSeconds 20
        $allLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appProcessId
        $terminalMatches = [regex]::Matches(
            $allLogs,
            'FILE_TRANSFER result=(cancelled|failed|completed)'
        )
        if ($terminalMatches.Count -ne 1 -or
            $terminalMatches[0].Groups[1].Value -ne 'failed') {
            throw 'Local disk-full failure did not produce exactly one failed terminal result'
        }
        if ($diskFullFailure -notmatch 'FILE_TRANSFER result=failed code=WRITE' -or
            $diskFullIdle -notmatch 'FILE_TRANSFER phase=IDLE') {
            throw 'Local disk-full failure did not exercise ENOSPC and return the Pane to IDLE'
        }
        if ($allLogs.Contains($secret, [StringComparison]::Ordinal)) {
            throw 'HarmonyOS application logs exposed the temporary fixture password'
        }
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'local-disk-full.png')
        $cleanupState = Invoke-TransferFixtureAction -Stage 'fixture-local-disk-full-cleanup'
        if ($cleanupState -notmatch (
                'state=cleaned,originalPreserved=true,numberedPresent=false,' +
                'temporaryPresent=false,cleanupFailureFinalPresent=false,temporaryCount=0'
            )) {
            throw 'Local disk-full failure exposed a final file, left a temporary file or changed existing data'
        }
        $diskFullEvidence = [ordered]@{
            recordedAt = (Get-Date).ToString('o')
            gate = '1.3-production-get-local-disk-full'
            result = 'passed'
            terminalResult = 'failed exactly once with WRITE/ENOSPC, then returned to IDLE'
            localFinal = 'disk-full-result.bin was never exposed'
            localTemporary = 'owned .part was removed exactly'
            existingFile = 'pre-existing Downloads source.bin remained byte-exact'
            sourceDirty = (@(git -C $repoRoot status --short).Count -gt 0)
            sourceCommit = (git -C $repoRoot rev-parse HEAD)
            hapSha256 = (Get-FileHash -LiteralPath (
                    Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
                ) -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $diskFullEvidence | ConvertTo-Json -Depth 6 | Set-Content `
            -LiteralPath (Join-Path $EvidenceDirectory 'device-get-local-disk-full.json') `
            -Encoding utf8NoBOM
        Write-Host 'GET LOCAL DISK FULL GATE PASSED: failed once, final hidden, temp cleaned, Pane IDLE' `
            -ForegroundColor Green
        return
    }
    if ($ForceTerminate) {
        $forceGetLocalName = $localDirectoryName + '/force-get-result.bin'
        Submit-TerminalText `
            -Text "get -p $FixturePort password@127.0.0.1:/$remoteGetName $forceGetLocalName" `
            -LayoutName 'get-force-termination-command'
        Complete-PasswordAuthentication -Stage 'get-force-termination'
        $getProgress = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER (progress=visible|result=(failed|completed|cancelled))' `
            -TimeoutSeconds 60
        if ($getProgress -notmatch 'FILE_TRANSFER progress=visible') {
            throw 'GET reached a terminal state before the forced-termination point'
        }
        $getTermination = Stop-LeanTTYApplicationAbruptly -Stage 'GET'

        $launch = Start-LeanTTYRegressionApp `
            -Hdc $hdc `
            -Target $Target `
            -CredentialPath (Get-LeanTTYDeviceUnlockPasswordPath) `
            -RepositoryRoot $repoRoot
        $appProcessId = $launch.processId
        Focus-TerminalInput -Name 'force-get-restarted-input'
        $getCleanupState = Invoke-TransferFixtureAction -Stage 'fixture-force-get-cleanup'
        if ($getCleanupState -notmatch (
                'state=cleaned,originalPreserved=true,numberedPresent=false,' +
                'temporaryPresent=true,cleanupFailureFinalPresent=false,temporaryCount=1,' +
                'backpressureFinalPresent=false,forceGetFinalPresent=false,' +
                'forcePutSourcePresent=true,forcePutSourceSize=2097152'
            )) {
            throw 'Forced GET exposed its final name, lost its one hidden temporary file or changed fixture data'
        }

        $putFixtureState = Invoke-TransferFixtureAction -Stage 'fixture-force-put-prepare'
        if ($putFixtureState -notmatch 'state=prepared') {
            throw 'Transfer fixture was not prepared for forced PUT'
        }
        Focus-TerminalInput -Name 'force-put-prepared-input'
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        $forcePutFinalPath = Join-Path $remoteUploadDirectory 'force-put-result.bin'
        Submit-TerminalText `
            -Text (
                "put -p $FixturePort $localDirectoryName/force-put-source.bin " +
                "password@127.0.0.1:/$remoteDirectoryName/force-put-result.bin"
            ) `
            -LayoutName 'put-force-termination-command'
        Complete-PasswordAuthentication -Stage 'put-force-termination'
        $putProgress = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER (progress=visible|result=(failed|completed|cancelled))' `
            -TimeoutSeconds 60
        if ($putProgress -notmatch 'FILE_TRANSFER progress=visible') {
            throw 'PUT reached a terminal state before the forced-termination point'
        }
        $putTermination = Stop-LeanTTYApplicationAbruptly -Stage 'PUT'
        if (Test-Path -LiteralPath $forcePutFinalPath) {
            throw 'Forced PUT exposed the final remote file name'
        }
        $forcePutTemporaryFiles = @(
            Get-ChildItem -LiteralPath $remoteUploadDirectory -File `
                -Filter '.leantty-*.part'
        )
        if ($forcePutTemporaryFiles.Count -ne 1) {
            throw 'Forced PUT did not retain exactly one identifiable remote temporary file'
        }

        $launch = Start-LeanTTYRegressionApp `
            -Hdc $hdc `
            -Target $Target `
            -CredentialPath (Get-LeanTTYDeviceUnlockPasswordPath) `
            -RepositoryRoot $repoRoot
        $appProcessId = $launch.processId
        Focus-TerminalInput -Name 'force-put-restarted-input'
        $cleanupState = Invoke-TransferFixtureAction -Stage 'fixture-force-put-cleanup'
        if ($cleanupState -notmatch (
                'state=cleaned,originalPreserved=true,numberedPresent=false,' +
                'temporaryPresent=false,cleanupFailureFinalPresent=false,temporaryCount=0,' +
                'backpressureFinalPresent=false,forceGetFinalPresent=false,' +
                'forcePutSourcePresent=true,forcePutSourceSize=2097152'
            )) {
            throw 'Forced PUT changed its local source, exposed a local final file or left a local temporary file'
        }
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'force-termination-restarted.png')

        $remoteTemporaryPath = [IO.Path]::GetFullPath($forcePutTemporaryFiles[0].FullName)
        $remoteRootPrefix = [IO.Path]::GetFullPath($fixtureSftpRoot).TrimEnd('\', '/') +
            [IO.Path]::DirectorySeparatorChar
        if (-not $remoteTemporaryPath.StartsWith(
                $remoteRootPrefix, [StringComparison]::OrdinalIgnoreCase
            )) {
            throw 'Forced PUT temporary file resolved outside the controlled SFTP fixture root'
        }
        Remove-Item -LiteralPath $remoteTemporaryPath -Force
        if ((Test-Path -LiteralPath $remoteTemporaryPath) -or
            (Test-Path -LiteralPath $forcePutFinalPath)) {
            throw 'Forced PUT fixture data was not cleaned after evidence capture'
        }
        $forceTerminationEvidence = [ordered]@{
            recordedAt = (Get-Date).ToString('o')
            gate = '1.3-production-put-get-forced-termination'
            result = 'passed'
            getBytesAvailable = $sourceBytesCount
            putBytesAvailable = 2MB
            sftpDelayMilliseconds = $SftpDelayMilliseconds
            getForceStopToExitMs = $getTermination.elapsedMilliseconds
            putForceStopToExitMs = $putTermination.elapsedMilliseconds
            gracefulCloseBypassed = 'no application close preparation, transfer terminal result or IDLE before process death'
            getFinal = 'force-get-result.bin was never exposed'
            getTemporary = 'exactly one owned same-directory .part remained until post-restart fixture cleanup'
            putFinal = 'force-put-result.bin was never exposed'
            putTemporary = $forcePutTemporaryFiles[0].Name
            restart = 'a fresh Pane was focusable after each forced process termination'
            cleanup = 'local and remote disposable temporary files were removed after evidence capture'
            sourceDirty = (@(git -C $repoRoot status --short).Count -gt 0)
            sourceCommit = (git -C $repoRoot rev-parse HEAD)
            hapSha256 = (Get-FileHash -LiteralPath (
                    Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
                ) -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $forceTerminationEvidence | ConvertTo-Json -Depth 6 | Set-Content `
            -LiteralPath (Join-Path $EvidenceDirectory 'device-put-get-force-termination.json') `
            -Encoding utf8NoBOM
        Write-Host 'PUT/GET FORCE TERMINATION GATE PASSED: final names hidden, restart usable' `
            -ForegroundColor Green
        return
    }
    if ($Backpressure) {
        $backpressureLocalName = $localDirectoryName + '/backpressure-result.bin'
        $backpressureRemoteReturn = Join-Path $remoteUploadDirectory 'backpressure-return.bin'
        Submit-TerminalText `
            -Text "get -p $FixturePort password@127.0.0.1:/$remoteGetName $backpressureLocalName" `
            -LayoutName 'get-backpressure-command'
        Complete-PasswordAuthentication -Stage 'get-backpressure'
        $backpressureResult = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'ACCEPTANCE_FILE_TRANSFER_BACKPRESSURE state=completed.*ACCEPTANCE_FILE_TRANSFER_DROPPED=[1-9]' `
            -TimeoutSeconds 60
        $getIdle = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER phase=IDLE' `
            -TimeoutSeconds 30
        $getLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appProcessId
        if ($backpressureResult -notmatch 'ACCEPTANCE_FILE_TRANSFER_DROPPED=[1-9]\d*' -or
            $getLogs -notmatch 'ACCEPTANCE_FILE_TRANSFER_BACKPRESSURE state=stalling' -or
            $getLogs -notmatch 'ACCEPTANCE_FILE_TRANSFER_BACKPRESSURE state=released' -or
            $getLogs -notmatch "FILE_TRANSFER result=completed direction=get,bytes=$expectedCompletionBytes" -or
            $getLogs -notmatch 'FILE_TRANSFER stage=finalizing' -or
            $getIdle -notmatch 'FILE_TRANSFER phase=IDLE') {
            throw 'Backpressured GET did not drop intermediate callbacks, finalize once and return to IDLE'
        }
        $getTerminalMatches = [regex]::Matches(
            $getLogs,
            'FILE_TRANSFER result=(cancelled|failed|completed)'
        )
        if ($getTerminalMatches.Count -ne 1 -or
            $getTerminalMatches[0].Groups[1].Value -ne 'completed') {
            throw 'Backpressured GET did not produce exactly one completed terminal result'
        }
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'backpressure-get-completed.png')

        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Submit-TerminalText `
            -Text "put -p $FixturePort $backpressureLocalName password@127.0.0.1:/$remoteDirectoryName/backpressure-return.bin" `
            -LayoutName 'put-backpressure-return-command'
        Complete-PasswordAuthentication -Stage 'put-backpressure-return'
        $putResult = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern "FILE_TRANSFER result=(completed direction=put,bytes=$expectedCompletionBytes|failed code=\S+)" `
            -TimeoutSeconds 60
        if ($putResult -notmatch "FILE_TRANSFER result=completed direction=put,bytes=$expectedCompletionBytes") {
            throw 'Backpressure round-trip PUT failed'
        }
        Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER phase=IDLE' -TimeoutSeconds 30 | Out-Null
        if (-not (Test-Path -LiteralPath $backpressureRemoteReturn -PathType Leaf)) {
            throw 'Backpressure round-trip PUT did not expose the final remote file'
        }
        $roundTripHash = (Get-FileHash -LiteralPath $backpressureRemoteReturn -Algorithm SHA256).Hash
        if ($roundTripHash -ne $sourceHash) {
            throw 'Backpressured GET then PUT changed the file SHA-256'
        }
        $cleanupState = Invoke-TransferFixtureAction -Stage 'fixture-backpressure-cleanup'
        if ($cleanupState -notmatch (
                'state=cleaned,originalPreserved=true,numberedPresent=false,' +
                'temporaryPresent=false,cleanupFailureFinalPresent=false,temporaryCount=0,' +
                'backpressureFinalPresent=true'
            )) {
            throw 'Backpressure gate did not retain the complete final file or left a temporary file'
        }
        $droppedMatch = [regex]::Match(
            $backpressureResult,
            'ACCEPTANCE_FILE_TRANSFER_DROPPED=(\d+)'
        )
        $backpressureEvidence = [ordered]@{
            recordedAt = (Get-Date).ToString('o')
            gate = '1.3-production-put-get-callback-backpressure'
            result = 'passed'
            bytes = $sourceBytesCount
            sftpDelayMilliseconds = $SftpDelayMilliseconds
            acceptanceCallbackQueue = 2
            acceptanceMainThreadStallMs = 1500
            droppedIntermediateCallbacks = [int]$droppedMatch.Groups[1].Value
            terminalResult = 'GET completed exactly once through FINALIZING and returned to IDLE'
            roundTripSha256 = $roundTripHash.ToLowerInvariant()
            localFinal = 'backpressure-result.bin was committed only after complete transfer'
            localTemporary = 'no owned same-directory temporary file remained before fixture cleanup'
            sourceDirty = (@(git -C $repoRoot status --short).Count -gt 0)
            sourceCommit = (git -C $repoRoot rev-parse HEAD)
            hapSha256 = (Get-FileHash -LiteralPath (
                    Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
                ) -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $backpressureEvidence | ConvertTo-Json -Depth 6 | Set-Content `
            -LiteralPath (Join-Path $EvidenceDirectory 'device-put-get-backpressure.json') `
            -Encoding utf8NoBOM
        Write-Host 'PUT/GET BACKPRESSURE GATE PASSED: progress dropped, final delivered, SHA-256 exact' `
            -ForegroundColor Green
        return
    }
    if ($FileNameMatrix) {
        $matrixEvidence = [Collections.Generic.List[object]]::new()
        foreach ($case in $fileNameMatrixCases) {
            $stem = [IO.Path]::GetFileNameWithoutExtension($case.name)
            $extension = [IO.Path]::GetExtension($case.name)
            $downloadedName = $stem + ' (1)' + $extension
            $localCommandName = $downloadedName.Replace(' ', '\ ')
            if ($case.kind -eq 'unicode') {
                $localCommandName = $localCommandName.Replace('数据', '{{DATA}}')
            }
            $getCommand = (
                "get -p $FixturePort password@127.0.0.1:/$($case.commandName) " +
                $localDirectoryName + '/'
            )
            Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
            if ($case.kind -eq 'unicode') {
                Submit-TerminalTextWithAcceptanceData `
                    -Text $getCommand -LayoutName ('filename-' + $case.kind + '-get')
            } else {
                Submit-TerminalText -Text $getCommand -LayoutName ('filename-' + $case.kind + '-get')
            }
            Complete-PasswordAuthentication -Stage ('filename-' + $case.kind + '-get')
            $getLogs = Wait-LeanTTYAppLog `
                -Hdc $hdc -Target $Target -ProcessId $appProcessId `
                -Pattern "FILE_TRANSFER result=(completed direction=get,bytes=$expectedCompletionBytes|failed code=\S+)" `
                -TimeoutSeconds 60
            if ($getLogs -match 'FILE_TRANSFER result=failed code=(?<code>\S+)') {
                throw "File-name matrix GET failed for $($case.kind): $($Matches['code'])"
            }
            if ($getLogs -notmatch 'FILE_TRANSFER stage=finalizing') {
                throw "File-name matrix GET skipped FINALIZING for $($case.kind)"
            }

            $putPrefix = "put -p $FixturePort $localDirectoryName/" +
                $localCommandName.Substring(0, $localCommandName.Length - 2)
            $expectedPutCompletedPrefix = "put -p $FixturePort $localDirectoryName/" +
                $localCommandName.Replace('{{DATA}}', '数据') + ' '
            $putSuffix = "password@127.0.0.1:/$remoteDirectoryName/"
            Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
            if ($case.kind -eq 'unicode') {
                Complete-TerminalTextWithAcceptanceDataAndTab `
                    -Prefix $putPrefix -ExpectedCompletedPrefix $expectedPutCompletedPrefix `
                    -Suffix $putSuffix `
                    -LayoutName ('filename-' + $case.kind + '-put')
            } else {
                Complete-TerminalTextWithTab `
                    -Prefix $putPrefix -Suffix $putSuffix `
                    -LayoutName ('filename-' + $case.kind + '-put')
            }
            Complete-PasswordAuthentication -Stage ('filename-' + $case.kind + '-put')
            $putLogs = Wait-LeanTTYAppLog `
                -Hdc $hdc -Target $Target -ProcessId $appProcessId `
                -Pattern "FILE_TRANSFER result=(completed direction=put,bytes=$expectedCompletionBytes|failed code=\S+)" `
                -TimeoutSeconds 60
            if ($putLogs -match 'FILE_TRANSFER result=failed code=(?<code>\S+)') {
                throw "File-name matrix PUT failed for $($case.kind): $($Matches['code'])"
            }
            if ($putLogs -notmatch 'FILE_TRANSFER stage=finalizing') {
                throw "File-name matrix PUT skipped FINALIZING for $($case.kind)"
            }
            $uploadedPath = Join-Path $remoteUploadDirectory $downloadedName
            if (-not (Test-Path -LiteralPath $uploadedPath -PathType Leaf)) {
                throw "File-name matrix PUT did not preserve the actual Downloads basename for $($case.kind)"
            }
            $uploadedHash = (Get-FileHash -LiteralPath $uploadedPath -Algorithm SHA256).Hash
            if ($uploadedHash -cne $sourceHash) {
                throw "File-name matrix changed SHA-256 for $($case.kind)"
            }
            $matrixEvidence.Add([ordered]@{
                    kind = $case.kind
                    sourceName = $case.name
                    savedName = $downloadedName
                    bytes = $sourceBytesCount
                    sha256 = $uploadedHash.ToLowerInvariant()
                })
        }
        $allowedRemotePaths = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        [void]$allowedRemotePaths.Add($remoteSourcePath)
        foreach ($case in $fileNameMatrixCases) {
            [void]$allowedRemotePaths.Add((Join-Path $fixtureSftpRoot $case.name))
            $stem = [IO.Path]::GetFileNameWithoutExtension($case.name)
            $extension = [IO.Path]::GetExtension($case.name)
            [void]$allowedRemotePaths.Add((Join-Path $remoteUploadDirectory ($stem + ' (1)' + $extension)))
        }
        $unexpectedRemote = @(Get-ChildItem -LiteralPath $fixtureSftpRoot -Recurse -File | Where-Object {
                -not $allowedRemotePaths.Contains($_.FullName)
            })
        if ($unexpectedRemote.Count -ne 0) {
            throw 'File-name matrix left an unexpected remote temporary file'
        }
        $cleanupState = Invoke-TransferFixtureAction -Stage 'fixture-file-name-matrix-cleanup'
        if ($cleanupState -notmatch 'state=cleaned.*temporaryPresent=false.*temporaryCount=0') {
            throw 'File-name matrix did not clean all local final and temporary files'
        }
        $evidence = [ordered]@{
            recordedAt = (Get-Date).ToString('o')
            gate = '1.3-production-put-get-file-name-matrix'
            result = 'passed'
            cases = @($matrixEvidence)
            semantics = 'space, Unicode and 224-character basenames round-tripped through a Downloads directory target'
            conflict = 'each pre-existing Downloads basename was preserved and the transfer used the minimal (1) name'
            sourceDirty = (@(git -C $repoRoot status --short).Count -gt 0)
            sourceCommit = (git -C $repoRoot rev-parse HEAD)
            hapSha256 = (Get-FileHash -LiteralPath (
                    Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
                ) -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $evidence | ConvertTo-Json -Depth 8 | Set-Content `
            -LiteralPath (Join-Path $EvidenceDirectory 'device-put-get-file-name-matrix.json') `
            -Encoding utf8NoBOM
        Write-Host 'PUT/GET FILE-NAME MATRIX PASSED: space, Unicode and long basenames, SHA-256 exact' `
            -ForegroundColor Green
        return
    }
    $commandRemotePath = if ($StallPreparation) {
        '/.leantty-acceptance-preparation-wait/source.bin'
    } else {
        '/' + $remoteGetName
    }
    Complete-TerminalTextWithTab `
        -Prefix "get -p $FixturePort password@127.0.0.1:$commandRemotePath $localDirectoryName" `
        -LayoutName 'get-command'
    if ($StallPreparation) {
        $preparationResult = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'ACCEPTANCE_FILE_TRANSFER_PREPARATION waiting=true|FILE_TRANSFER result=' `
            -TimeoutSeconds 30
        if ($preparationResult -notmatch 'ACCEPTANCE_FILE_TRANSFER_PREPARATION waiting=true') {
            throw 'GET reached a terminal state before the stalled preparation point'
        }
    } else {
        Complete-PasswordAuthentication -Stage 'get'
    }
    if ($DisconnectGet) {
        $progressResult = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER (progress=visible|result=(failed|completed|cancelled))' `
            -TimeoutSeconds 60
        if ($progressResult -notmatch 'FILE_TRANSFER progress=visible') {
            throw 'GET reached a terminal state before the disconnect point became observable'
        }
        if ($fixtureLinuxPid -le 0) { throw 'SFTP fixture Linux process ID is unavailable' }
        $disconnectStopwatch = [Diagnostics.Stopwatch]::StartNew()
        & wsl.exe --exec kill -TERM $fixtureLinuxPid 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to terminate the controlled SFTP fixture' }
        $fixtureLinuxPid = 0
        $disconnectResult = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER result=(failed code=\S+|completed|cancelled)' `
            -TimeoutSeconds 40
        $disconnectIdle = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER phase=IDLE' `
            -TimeoutSeconds 20
        $disconnectStopwatch.Stop()
        $allLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appProcessId
        $terminalMatches = [regex]::Matches(
            $allLogs,
            'FILE_TRANSFER result=(cancelled|failed|completed)'
        )
        if ($terminalMatches.Count -ne 1 -or
            $terminalMatches[0].Groups[1].Value -ne 'failed' -or
            $disconnectResult -notmatch 'FILE_TRANSFER result=failed code=NETWORK' -or
            $disconnectIdle -notmatch 'FILE_TRANSFER phase=IDLE') {
            throw 'Disconnected GET did not fail exactly once with NETWORK and return to IDLE'
        }
        if ($allLogs.Contains($secret, [StringComparison]::Ordinal)) {
            throw 'HarmonyOS application logs exposed the temporary fixture password'
        }
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'get-disconnect.png')
        $cleanupState = Invoke-TransferFixtureAction -Stage 'fixture-disconnect-cleanup'
        if ($cleanupState -notmatch (
                'state=cleaned,originalPreserved=true,numberedPresent=false,temporaryPresent=false'
            )) {
            throw 'Disconnected GET exposed a final file, retained a local temporary file or changed the original'
        }
        $disconnectEvidence = [ordered]@{
            recordedAt = (Get-Date).ToString('o')
            gate = '1.3-production-get-transport-disconnect'
            result = 'passed'
            bytesAvailable = $sourceBytesCount
            sourceSha256 = $sourceHash.ToLowerInvariant()
            sftpDelayMilliseconds = $SftpDelayMilliseconds
            disconnectToIdleMs = [int]$disconnectStopwatch.ElapsedMilliseconds
            terminalResult = 'failed exactly once with NETWORK, then returned to IDLE'
            localFinal = 'numbered download was not exposed'
            localTemporary = 'owned same-directory temporary file was absent before fixture cleanup'
            original = 'pre-existing Downloads source.bin remained byte-exact'
            sourceDirty = (@(git -C $repoRoot status --short).Count -gt 0)
            sourceCommit = (git -C $repoRoot rev-parse HEAD)
            hapSha256 = (Get-FileHash -LiteralPath (
                    Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
                ) -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $disconnectEvidence | ConvertTo-Json -Depth 6 | Set-Content `
            -LiteralPath (Join-Path $EvidenceDirectory 'device-get-disconnect.json') `
            -Encoding utf8NoBOM
        Write-Host 'GET DISCONNECT GATE PASSED: early EOF rejected, final hidden, Pane IDLE' `
            -ForegroundColor Green
        return
    }
    if ($ClosePane) {
        if (-not $StallPreparation) {
            $progressResult = Wait-LeanTTYAppLog `
                -Hdc $hdc -Target $Target -ProcessId $appProcessId `
                -Pattern 'FILE_TRANSFER (progress=visible|result=(failed|completed|cancelled))' `
                -TimeoutSeconds 60
            if ($progressResult -notmatch 'FILE_TRANSFER progress=visible') {
                throw 'GET reached a terminal state before the Pane-close point became observable'
            }
        }
        Split-And-FocusTransferPane
        Invoke-ActivePaneClose
        $closeStopwatch = Confirm-ActivePaneClose
        $closeLogs = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER phase=IDLE' `
            -TimeoutSeconds 60
        $closeStopwatch.Stop()
        Wait-PaneCount -Count 1 -LayoutName 'pane-close-after.json' | Out-Null
        $currentProcessId = (@(& $hdc -t $Target shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
        if ($currentProcessId -ne $appProcessId) {
            throw 'Closing the transfer Pane changed the LeanTTY application process'
        }
        $terminalMatches = [regex]::Matches(
            $closeLogs,
            'FILE_TRANSFER result=(cancelled|failed|completed)'
        )
        if ($terminalMatches.Count -ne 1 -or
            $terminalMatches[0].Groups[1].Value -ne 'cancelled') {
            throw 'Pane close did not produce exactly one cancelled GET terminal result'
        }
        if ($StallPreparation -and $closeLogs -match (
                'File transfer authentication prompt=|FILE_TRANSFER progress=visible|' +
                'FILE_TRANSFER stage=finalizing|FILE_TRANSFER result=completed'
            )) {
            throw 'Stalled preparation continued into native transfer work after Pane close'
        }
        if ($closeLogs.Contains($secret, [StringComparison]::Ordinal)) {
            throw 'HarmonyOS application logs exposed the temporary fixture password'
        }
        $unexpectedRemote = @(Get-ChildItem -LiteralPath $fixtureSftpRoot -Recurse -File | Where-Object {
            $_.FullName -ne $remoteSourcePath
        })
        if ($unexpectedRemote.Count -ne 0) {
            throw 'Pane close left an unexpected remote temporary file'
        }
        $cleanupState = Invoke-TransferFixtureAction -Stage 'fixture-pane-close-cleanup'
        if ($cleanupState -notmatch (
                'state=cleaned,originalPreserved=true,numberedPresent=false,temporaryPresent=false'
            )) {
            throw 'Pane close left a final or temporary Downloads file'
        }
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'pane-close-survivor.png')
        $paneCloseEvidence = [ordered]@{
            recordedAt = (Get-Date).ToString('o')
            gate = $(if ($StallPreparation) {
                    '1.3-production-get-preparation-pane-close-cancellation'
                } else {
                    '1.3-production-get-pane-close-cancellation'
                })
            result = 'passed'
            phaseAtClose = $(if ($StallPreparation) { 'PREPARING' } else { 'TRANSFERRING' })
            bytesAvailable = $sourceBytesCount
            sourceSha256 = $sourceHash.ToLowerInvariant()
            sftpDelayMilliseconds = $SftpDelayMilliseconds
            closeToIdleMs = [int]$closeStopwatch.ElapsedMilliseconds
            terminalResult = $(if ($StallPreparation) {
                    'stalled preparation cancelled exactly once and returned to IDLE before Pane disposal'
                } else {
                    'cancelled exactly once and returned to IDLE before Pane disposal'
                })
            survivingPane = 'one Pane remained usable in the original application process'
            localFinal = 'numbered download was not exposed'
            localTemporary = 'owned same-directory temporary file was absent before fixture cleanup'
            remoteTemporary = 'owned remote temporary file was absent before fixture shutdown'
            original = 'pre-existing Downloads source.bin remained byte-exact'
            sourceDirty = (@(git -C $repoRoot status --short).Count -gt 0)
            sourceCommit = (git -C $repoRoot rev-parse HEAD)
            hapSha256 = (Get-FileHash -LiteralPath (
                    Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
                ) -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $paneEvidenceName = if ($StallPreparation) {
            'device-put-get-pane-close-preparing.json'
        } else {
            'device-put-get-pane-close.json'
        }
        $paneCloseEvidence | ConvertTo-Json -Depth 6 | Set-Content `
            -LiteralPath (Join-Path $EvidenceDirectory $paneEvidenceName) `
            -Encoding utf8NoBOM
        Write-Host 'PUT/GET PC PANE CLOSE GATE PASSED: active GET cleaned before Pane disposal' `
            -ForegroundColor Green
        return
    }
    if ($CloseApplication) {
        if (-not $StallPreparation) {
            $progressResult = Wait-LeanTTYAppLog `
                -Hdc $hdc -Target $Target -ProcessId $appProcessId `
                -Pattern 'FILE_TRANSFER (progress=visible|result=(failed|completed|cancelled))' `
                -TimeoutSeconds 60
            if ($progressResult -notmatch 'FILE_TRANSFER progress=visible') {
                throw 'GET reached a terminal state before the application-close point became observable'
            }
        }
        Invoke-SystemApplicationClose
        $closeStopwatch = Confirm-SystemApplicationClose
        $closeLogs = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'Application close preparation (completed|failed)' `
            -TimeoutSeconds 60
        if ($closeLogs -notmatch 'Application close preparation completed') {
            throw 'Application close preparation failed during the active GET'
        }
        Wait-ApplicationProcessExit -ExpectedProcessId $appProcessId
        $closeStopwatch.Stop()
        $allLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appProcessId
        $terminalMatches = [regex]::Matches(
            $allLogs,
            'FILE_TRANSFER result=(cancelled|failed|completed)'
        )
        if ($terminalMatches.Count -ne 1 -or
            $terminalMatches[0].Groups[1].Value -ne 'cancelled' -or
            $allLogs -notmatch 'FILE_TRANSFER phase=IDLE') {
            throw 'Application close did not await exactly one cancelled GET and clean IDLE'
        }
        if ($StallPreparation -and $allLogs -match (
                'File transfer authentication prompt=|FILE_TRANSFER progress=visible|' +
                'FILE_TRANSFER stage=finalizing|FILE_TRANSFER result=completed'
            )) {
            throw 'Stalled preparation continued into native transfer work after application close'
        }
        if ($allLogs.Contains($secret, [StringComparison]::Ordinal)) {
            throw 'HarmonyOS application logs exposed the temporary fixture password'
        }
        $unexpectedRemote = @(Get-ChildItem -LiteralPath $fixtureSftpRoot -Recurse -File | Where-Object {
            $_.FullName -ne $remoteSourcePath
        })
        if ($unexpectedRemote.Count -ne 0) {
            throw 'Application close left an unexpected remote temporary file'
        }
        $launch = Start-LeanTTYRegressionApp `
            -Hdc $hdc `
            -Target $Target `
            -CredentialPath (Get-LeanTTYDeviceUnlockPasswordPath) `
            -RepositoryRoot $repoRoot
        $appProcessId = $launch.processId
        $cleanupState = Invoke-TransferFixtureAction -Stage 'fixture-application-close-cleanup'
        if ($cleanupState -notmatch (
                'state=cleaned,originalPreserved=true,numberedPresent=false,temporaryPresent=false'
            )) {
            throw 'Application close left a final or temporary Downloads file'
        }
        $closeEvidence = [ordered]@{
            recordedAt = (Get-Date).ToString('o')
            gate = $(if ($StallPreparation) {
                    '1.3-production-get-preparation-application-close-cancellation'
                } else {
                    '1.3-production-get-application-close-cancellation'
                })
            result = 'passed'
            phaseAtClose = $(if ($StallPreparation) { 'PREPARING' } else { 'TRANSFERRING' })
            bytesAvailable = $sourceBytesCount
            sourceSha256 = $sourceHash.ToLowerInvariant()
            sftpDelayMilliseconds = $SftpDelayMilliseconds
            confirmToProcessExitMs = [int]$closeStopwatch.ElapsedMilliseconds
            terminalResult = $(if ($StallPreparation) {
                    'stalled preparation cancelled exactly once and IDLE before application close preparation completed'
                } else {
                    'cancelled exactly once and IDLE before application close preparation completed'
                })
            localFinal = 'numbered download was not exposed'
            localTemporary = 'owned same-directory temporary file was absent after relaunch'
            remoteTemporary = 'owned remote temporary file was absent before fixture shutdown'
            original = 'pre-existing Downloads source.bin remained byte-exact'
            sourceDirty = (@(git -C $repoRoot status --short).Count -gt 0)
            sourceCommit = (git -C $repoRoot rev-parse HEAD)
            hapSha256 = (Get-FileHash -LiteralPath (
                    Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
                ) -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $applicationEvidenceName = if ($StallPreparation) {
            'device-put-get-application-close-preparing.json'
        } else {
            'device-put-get-application-close.json'
        }
        $closeEvidence | ConvertTo-Json -Depth 6 | Set-Content `
            -LiteralPath (Join-Path $EvidenceDirectory $applicationEvidenceName) `
            -Encoding utf8NoBOM
        Write-Host 'PUT/GET PC APPLICATION CLOSE GATE PASSED: active GET cleaned before exit' `
            -ForegroundColor Green
        return
    }
    if ($CancelGet) {
        $progressResult = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER (progress=visible|result=(failed|completed|cancelled))' `
            -TimeoutSeconds 60
        if ($progressResult -notmatch 'FILE_TRANSFER progress=visible') {
            throw 'GET reached a terminal state before the cancellation point became observable'
        }
        $cancelStopwatch = [Diagnostics.Stopwatch]::StartNew()
        Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $Target
        $cancelResult = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER result=(cancelled|failed|completed)' `
            -TimeoutSeconds 60
        if ($cancelResult -notmatch 'FILE_TRANSFER result=cancelled') {
            throw 'GET Ctrl+C did not produce the cancelled terminal result'
        }
        $idleResult = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER phase=IDLE' `
            -TimeoutSeconds 20
        $cancelStopwatch.Stop()
        if ($idleResult -match 'FILE_TRANSFER result=(completed|failed)') {
            throw 'GET emitted a conflicting terminal result after cancellation'
        }
        $allLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appProcessId
        $terminalMatches = [regex]::Matches(
            $allLogs,
            'FILE_TRANSFER result=(cancelled|failed|completed)'
        )
        if ($terminalMatches.Count -ne 1 -or
            $terminalMatches[0].Groups[1].Value -ne 'cancelled') {
            throw 'GET did not emit exactly one cancelled terminal result'
        }
        if ($allLogs.Contains($secret, [StringComparison]::Ordinal)) {
            throw 'HarmonyOS application logs exposed the temporary fixture password'
        }
        $cleanupState = Invoke-TransferFixtureAction -Stage 'fixture-cancel-cleanup'
        if ($cleanupState -notmatch (
                'state=cleaned,originalPreserved=true,numberedPresent=false,temporaryPresent=false'
            )) {
            throw 'Cancelled GET left a final or temporary Downloads file'
        }
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'cancelled-get.png')
        $cancelEvidence = [ordered]@{
            recordedAt = (Get-Date).ToString('o')
            gate = '1.3-production-get-ctrl-c-cancellation'
            result = 'passed'
            bytesAvailable = $sourceBytesCount
            sourceSha256 = $sourceHash.ToLowerInvariant()
            sftpDelayMilliseconds = $SftpDelayMilliseconds
            cancelToIdleMs = [int]$cancelStopwatch.ElapsedMilliseconds
            terminalResult = 'cancelled exactly once, then returned to FILE_TRANSFER phase=IDLE'
            localFinal = 'numbered download was not exposed'
            localTemporary = 'owned same-directory temporary file was absent before fixture cleanup'
            original = 'pre-existing Downloads source.bin remained byte-exact'
            sourceDirty = (@(git -C $repoRoot status --short).Count -gt 0)
            sourceCommit = (git -C $repoRoot rev-parse HEAD)
            hapSha256 = (Get-FileHash -LiteralPath (
                    Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
                ) -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $cancelEvidence | ConvertTo-Json -Depth 6 | Set-Content `
            -LiteralPath (Join-Path $EvidenceDirectory 'device-put-get-cancel.json') `
            -Encoding utf8NoBOM
        Write-Host 'PUT/GET PC CANCEL GATE PASSED: in-flight GET Ctrl+C -> clean IDLE' `
            -ForegroundColor Green
        return
    }
    $getStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $getLogsBeforeIsolation = ''
    if ($MinimizeGet) {
        $progressResult = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER (progress=visible|result=(failed|completed|cancelled))' `
            -TimeoutSeconds 60
        if ($progressResult -notmatch 'FILE_TRANSFER progress=visible') {
            throw 'GET reached a terminal state before the minimize point became observable'
        }
        Minimize-LeanTTYTransferWindow
    }
    if ($SuspendGet) {
        $progressResult = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER (progress=visible|result=(failed|completed|cancelled))' `
            -TimeoutSeconds 60
        if ($progressResult -notmatch 'FILE_TRANSFER progress=visible') {
            throw 'GET reached a terminal state before the suspend point became observable'
        }
        $speedResult = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER (speed=visible|result=(failed|completed|cancelled))' `
            -TimeoutSeconds 10
        if ($speedResult -notmatch 'FILE_TRANSFER speed=visible') {
            throw 'GET reached a terminal state before live speed became observable at suspend'
        }
        $getLogsBeforeIsolation = $progressResult + "`n" + $speedResult
        $suspendStopwatch = [Diagnostics.Stopwatch]::StartNew()
        & $hdc -t $Target shell 'power-shell suspend' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to suspend the HarmonyOS PC during GET' }
        Start-Sleep -Seconds 5
        & $hdc -t $Target shell 'power-shell wakeup' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to wake the HarmonyOS PC during GET' }
        Start-Sleep -Seconds 2
        $resumedProcessId = (@(& $hdc -t $Target shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
        if ($LASTEXITCODE -ne 0 -or $resumedProcessId -cne $appProcessId) {
            throw 'LeanTTY did not retain the same application process across suspend and wake'
        }
        $resumeLaunch = Start-LeanTTYRegressionApp `
            -Hdc $hdc -Target $Target `
            -CredentialPath (Get-LeanTTYDeviceUnlockPasswordPath) `
            -RepositoryRoot $repoRoot
        if ($resumeLaunch.processId -cne $appProcessId) {
            throw 'LeanTTY restarted instead of returning the same process after device unlock'
        }
    }
    if ($SelectionCopy) {
        $progressResult = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER (progress=visible|result=(failed|completed|cancelled))' `
            -TimeoutSeconds 60
        if ($progressResult -notmatch 'FILE_TRANSFER progress=visible') {
            throw 'GET reached a terminal state before the selection-copy point became observable'
        }
        $speedResult = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'FILE_TRANSFER (speed=visible|result=(failed|completed|cancelled))' `
            -TimeoutSeconds 10
        if ($speedResult -notmatch 'FILE_TRANSFER speed=visible') {
            throw 'GET reached a terminal state before live speed became observable'
        }
        $getLogsBeforeIsolation = $progressResult + "`n" + $speedResult
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDeviceCtrlAltS -Hdc $hdc -Target $Target
        Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'ACCEPTANCE_SELECTION result=.*selected' -TimeoutSeconds 10 | Out-Null
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $Target
        $copyLogs = Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'Clipboard copy success=(true|false),length=' -TimeoutSeconds 10
        if ($copyLogs -notmatch 'Clipboard copy success=true,length=4') {
            throw 'Selected-text Ctrl+C did not copy the acceptance selection'
        }
        if ($copyLogs -match 'FILE_TRANSFER result=(cancelled|failed|completed)') {
            throw 'Selected-text Ctrl+C changed the active transfer terminal state'
        }
    }
    $getResult = Wait-LeanTTYAppLog `
        -Hdc $hdc -Target $Target -ProcessId $appProcessId `
        -Pattern "FILE_TRANSFER result=(completed direction=get,bytes=$expectedCompletionBytes|failed code=\S+)" `
        -TimeoutSeconds 60
    if (-not [string]::IsNullOrEmpty($getLogsBeforeIsolation)) {
        $getResult = $getLogsBeforeIsolation + "`n" + $getResult
    }
    $getStopwatch.Stop()
    if ($getResult -match 'FILE_TRANSFER result=failed code=(?<code>\S+)') {
        throw "GET failed with code $($Matches['code'])"
    }
    if ($getResult -notmatch 'FILE_TRANSFER stage=finalizing') {
        throw 'GET completed without the FINALIZING stage'
    }
    if ($MinimizeGet) {
        Restore-LeanTTYTransferWindow
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'transfer-restored-after-minimized-get.png')
    }
    if ($SuspendGet) {
        $suspendStopwatch.Stop()
        Wait-LeanTTYTerminalInputLayout `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'transfer-restored-after-suspended-get.json') `
            -TimeoutSeconds 30 | Out-Null
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'transfer-restored-after-suspended-get.png')
    }
    if ($sourceBytesCount -ge 1MB -and
        ($getResult -notmatch 'FILE_TRANSFER progress=visible' -or
        $getResult -notmatch 'FILE_TRANSFER speed=visible')) {
        throw 'GET large-file progress completed without visible progress and live speed'
    }
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Complete-TerminalTextWithTab `
        -Prefix "put -p $FixturePort $localDirectoryName/source\ (1).b" `
        -Suffix "password@127.0.0.1:/$remoteDirectoryName/" `
        -LayoutName 'put-command'
    Complete-PasswordAuthentication -Stage 'put'
    $putStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $putResult = Wait-LeanTTYAppLog `
        -Hdc $hdc -Target $Target -ProcessId $appProcessId `
        -Pattern "FILE_TRANSFER result=(completed direction=put,bytes=$expectedCompletionBytes|failed code=\S+)" `
        -TimeoutSeconds 60
    $putStopwatch.Stop()
    if ($putResult -match 'FILE_TRANSFER result=failed code=(?<code>\S+)') {
        throw "PUT failed with code $($Matches['code'])"
    }
    if ($putResult -notmatch 'FILE_TRANSFER stage=finalizing') {
        throw 'PUT completed without the FINALIZING stage'
    }
    if ($sourceBytesCount -ge 1MB -and
        ($putResult -notmatch 'FILE_TRANSFER progress=visible' -or
        $putResult -notmatch 'FILE_TRANSFER speed=visible')) {
        throw 'PUT large-file progress completed without visible progress and live speed'
    }

    if (-not (Test-Path -LiteralPath $remoteUploadedPath -PathType Leaf)) {
        throw 'PUT completed without the expected remote final file'
    }
    $uploadedHash = (Get-FileHash -LiteralPath $remoteUploadedPath -Algorithm SHA256).Hash
    if ($uploadedHash -cne $sourceHash) { throw 'GET then PUT changed the file SHA-256' }
    $unexpectedRemote = @(Get-ChildItem -LiteralPath $fixtureSftpRoot -Recurse -File | Where-Object {
        $_.FullName -notin @($remoteSourcePath, $remoteUploadedPath)
    })
    if ($unexpectedRemote.Count -ne 0) { throw 'PUT/GET left an unexpected remote temporary file' }

    $allLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appProcessId
    if ($allLogs.Contains($secret, [StringComparison]::Ordinal)) {
        throw 'HarmonyOS application logs exposed the temporary fixture password'
    }
    $cleanupState = Invoke-TransferFixtureAction -Stage 'fixture-cleanup'
    if ($cleanupState -notmatch 'state=cleaned,originalPreserved=true,numberedPresent=true') {
        throw 'Transfer fixture cleanup did not prove original-file preservation and numbered download presence'
    }

    $evidence = [ordered]@{
        recordedAt = (Get-Date).ToString('o')
        gate = '1.3-production-put-get-event-chain'
        result = 'passed'
        bytes = $sourceBytesCount
        sha256 = $sourceHash.ToLowerInvariant()
        sourceKind = $sourceKind
        getDurationMs = [int]$getStopwatch.ElapsedMilliseconds
        putDurationMs = [int]$putStopwatch.ElapsedMilliseconds
        getMiBPerSecond = [Math]::Round(
            ($sourceBytesCount / 1MB) / $getStopwatch.Elapsed.TotalSeconds, 2
        )
        putMiBPerSecond = [Math]::Round(
            ($sourceBytesCount / 1MB) / $putStopwatch.Elapsed.TotalSeconds, 2
        )
        get = 'existing Downloads subdirectory target auto-numbered without overwriting the original file'
        put = 'opened a Downloads subdirectory source and derived the basename for a remote directory target'
        pathSemantics = 'existing local and remote directories were reused; neither command created a directory'
        completion = 'local directory and file completion were used; Tab did not start transfer authentication'
        minimizedGet = $(if ($MinimizeGet) {
                'positive-byte GET completed while minimized; same process restored and continued to PUT'
            } else { 'not requested' })
        suspendedGet = $(if ($SuspendGet) {
                'positive-byte GET survived system suspend/wakeup in the same process, completed through FINALIZING and continued to PUT'
            } else { 'not requested' })
        suspendToRecoveredTerminalMs = $(if ($SuspendGet) {
                [int]$suspendStopwatch.ElapsedMilliseconds
            } else { 0 })
        selectedTextCtrlC = $(if ($SelectionCopy) {
                'copied the xterm-owned selection and did not cancel; GET and PUT completed'
            } else { 'not requested' })
        authenticationObservation = @($authObservationRecords)
        progress = $(if ($sourceBytesCount -ge 1MB) {
                'TTY progress rendered positive bytes, live speed and FINALIZING for GET and PUT'
            } else {
                'FINALIZING observed; transfer completed inside the intermediate UI throttle interval'
            })
        remoteCleanup = 'no unowned or temporary fixture files observed'
        sourceDirty = (@(git -C $repoRoot status --short).Count -gt 0)
        sourceCommit = (git -C $repoRoot rev-parse HEAD)
        hapSha256 = (Get-FileHash -LiteralPath (
                Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
            ) -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $evidence | ConvertTo-Json -Depth 6 | Set-Content `
        -LiteralPath (Join-Path $EvidenceDirectory 'device-put-get.json') -Encoding utf8NoBOM
    Write-Host 'PUT/GET PC GATE PASSED: production GET -> Downloads -> PUT, SHA-256 exact' -ForegroundColor Green
} catch {
    $primaryFailure = $_
    throw
} finally {
    if ($keyCleanupRequired -and -not [string]::IsNullOrWhiteSpace($appProcessId)) {
        try {
            Stop-FileTransferAuthenticationObserver
            & $hdc -t $Target shell 'aa force-stop com.leantty.app' | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw 'Unable to restart LeanTTY before disposable-key cleanup'
            }
            Start-Sleep -Milliseconds 500
            $cleanupLaunch = Start-LeanTTYRegressionApp `
                -Hdc $hdc `
                -Target $Target `
                -CredentialPath (Get-LeanTTYDeviceUnlockPasswordPath) `
                -RepositoryRoot $repoRoot
            $appProcessId = $cleanupLaunch.processId
            Focus-TerminalInput -Name 'auth-key-finally-cleanup-ready'
            Remove-AuthenticationMatrixKey -Stage 'auth-key-finally-cleanup'
        } catch {
            Write-Warning 'Disposable authentication-matrix key cleanup failed'
        }
    }
    Stop-FileTransferAuthenticationObserver
    $authenticationLogLeakedSecret = $false
    foreach ($path in $authObservationFiles) {
        $observationText = Read-SharedTextFile -Path $path
        foreach ($value in $authenticationSecrets) {
            if (-not [string]::IsNullOrWhiteSpace($value) -and
                $observationText.Contains($value, [StringComparison]::Ordinal)) {
                $authenticationLogLeakedSecret = $true
                break
            }
        }
        if ($authenticationLogLeakedSecret) { break }
    }
    $secret = ''
    $fixtureSecrets = @{}
    $authenticationSecrets.Clear()
    $keyPassphrase = ''
    if (-not [string]::IsNullOrWhiteSpace($appProcessId) -and
        ($null -eq $cleanupState -or $cleanupState -notmatch 'state=cleaned')) {
        try {
            $cleanupState = Invoke-TransferFixtureAction -Stage 'fixture-finally-cleanup'
            if ($cleanupState -match 'state=prepared') {
                $cleanupState = Invoke-TransferFixtureAction -Stage 'fixture-finally-cleanup-retry'
            }
        } catch {
            Write-Warning "Disposable Downloads fixture may remain: $localDirectoryName"
        }
    }
    if ($reverseMapped) {
        & $hdc -t $Target fport rm "tcp:$FixturePort" "tcp:$FixturePort" 2>$null | Out-Null
    }
    if ($fixtureLinuxPid -gt 0) {
        & wsl.exe --exec kill -TERM $fixtureLinuxPid 2>$null | Out-Null
    }
    if ($null -ne $fixtureProcess -and -not $fixtureProcess.HasExited) {
        Wait-Process -Id $fixtureProcess.Id -Timeout 10 -ErrorAction SilentlyContinue
        $fixtureProcess.Refresh()
        if (-not $fixtureProcess.HasExited) { Stop-Process -Id $fixtureProcess.Id -Force }
    }
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') +
        [IO.Path]::DirectorySeparatorChar
    if ((Test-Path -LiteralPath $fixtureRoot) -and
        [IO.Path]::GetFullPath($fixtureRoot).StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
    if ($awakeLease) {
        Stop-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $Target
    }
    if ($keyCleanupRequired) {
        if ($null -eq $primaryFailure) {
            throw 'Disposable authentication-matrix key may remain on the device'
        }
        Write-Warning 'Disposable authentication-matrix key may remain on the device'
    }
    if ($authenticationLogLeakedSecret) {
        throw 'Live HarmonyOS authentication observation exposed a temporary fixture credential'
    }
}
