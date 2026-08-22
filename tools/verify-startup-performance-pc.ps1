<#
.SYNOPSIS
  Measure LeanTTY cold startup from a real App Center icon click to first-letter paint.
.DESCRIPTION
  Builds and installs a test-signed diagnostic HAP unless -SkipBuild is used,
  opens the system App Center, force-stops LeanTTY before every sample, clicks
  the real LeanTTY icon, and injects one ASCII 'a' through uinput immediately
  after T4. The diagnostic Web marker reports T5 only after that same byte has
  returned through the production local-input path and xterm has rendered it.
#>
param(
    [string]$Target = '',
    [ValidateRange(3, 100)][int]$SampleCount = 20,
    [switch]$SkipBuild,
    [string]$EvidenceDirectory = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')
. (Join-Path $PSScriptRoot 'startup-performance-source.ps1')

function Invoke-StartupHdcShell {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [switch]$AllowEmpty
    )

    $output = @(& $script:hdc -t $script:target shell $Command 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw "HarmonyOS shell command failed: $Command"
    }
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($output)) {
        throw "HarmonyOS shell command returned no output: $Command"
    }
    return $output
}

function Get-StartupGlobalLayout {
    param([Parameter(Mandatory = $true)][string]$Name)
    $localPath = Join-Path $script:evidenceDirectory ($Name + '.json')
    return Get-HdcUiLayout `
        -Hdc $script:hdc `
        -Target $script:target `
        -LocalPath $localPath `
        -Operation 'HarmonyOS cold-start global UI layout capture'
}

function Get-StartupNodeCenter {
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)][string]$Id
    )

    $matches = @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object {
        [string]$_.attributes.id -eq $Id -and [string]$_.attributes.clickable -eq 'true'
    })
    if ($matches.Count -ne 1) {
        throw "Expected one clickable UI node '$Id', found $($matches.Count)"
    }
    return Get-LeanTTYBoundsCenter -Bounds ([string]$matches[0].attributes.bounds)
}

function Wait-StartupProcessStopped {
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $processId = (Invoke-StartupHdcShell -Command 'pidof com.leantty.app' -AllowEmpty).Trim()
        if ([string]::IsNullOrWhiteSpace($processId)) { return }
        Start-Sleep -Milliseconds 100
    } while ($stopwatch.Elapsed.TotalSeconds -lt 5)
    throw 'LeanTTY process remained alive after force-stop'
}

function Convert-StartupEpochToMilliseconds {
    param([Parameter(Mandatory = $true)][string]$Epoch)

    return [long][Math]::Round(([double]::Parse(
        $Epoch,
        [Globalization.CultureInfo]::InvariantCulture
    ) * 1000.0))
}

function Get-StartupMarkerTimes {
    param([Parameter(Mandatory = $true)][string]$Logs)

    $times = @{}
    foreach ($line in $Logs -split "`r?`n") {
        $match = [regex]::Match(
            $line,
            '^(?<epoch>\d+\.\d{3}) .*STARTUP_PERF phase=(?<phase>T[1-5])$'
        )
        if (-not $match.Success) { continue }
        $phase = $match.Groups['phase'].Value
        if ($times.ContainsKey($phase)) {
            throw "Duplicate startup marker in one sample: $phase"
        }
        $times[$phase] = Convert-StartupEpochToMilliseconds -Epoch $match.Groups['epoch'].Value
    }
    foreach ($phase in @('T1', 'T2', 'T3', 'T4', 'T5')) {
        if (-not $times.ContainsKey($phase)) {
            throw "Startup marker is missing: $phase"
        }
    }
    return $times
}

function Get-StartupSegments {
    param([Parameter(Mandatory = $true)][string]$Logs)

    $segments = [ordered]@{}
    foreach ($line in $Logs -split "`r?`n") {
        $match = [regex]::Match(
            $line,
            'STARTUP_PERF segment=(?<segment>[a-z-]+) elapsedMs=(?<elapsed>\d+)$'
        )
        if ($match.Success) {
            $segments[$match.Groups['segment'].Value] = [int]$match.Groups['elapsed'].Value
        }
    }
    return $segments
}

function Get-DurableStartupSegments {
    param([Parameter(Mandatory = $true)][string]$Logs)

    $segments = [ordered]@{}
    foreach ($line in $Logs -split "`r?`n") {
        $match = [regex]::Match(
            $line,
            'STARTUP_PERF durable=(?<segment>[a-z-]+) elapsedMs=(?<elapsed>\d+)$'
        )
        if ($match.Success) {
            $segments[$match.Groups['segment'].Value] = [int]$match.Groups['elapsed'].Value
        }
    }
    foreach ($segment in @('initialized-read')) {
        if (-not $segments.Contains($segment)) {
            throw "Durable startup segment is missing: $segment"
        }
    }
    return $segments
}

function Get-StartupPercentile {
    param(
        [Parameter(Mandatory = $true)][long[]]$Values,
        [Parameter(Mandatory = $true)][ValidateRange(0, 100)][int]$Percentile
    )

    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { throw 'Cannot calculate a percentile for an empty sample set' }
    $index = [Math]::Max(0, [Math]::Ceiling(($Percentile / 100.0) * $sorted.Count) - 1)
    return [long]$sorted[$index]
}

function Get-StartupStatistics {
    param([Parameter(Mandatory = $true)][long[]]$Values)

    $measure = $Values | Measure-Object -Minimum -Maximum -Average
    return [ordered]@{
        count = $Values.Count
        p50Ms = Get-StartupPercentile -Values $Values -Percentile 50
        p95Ms = Get-StartupPercentile -Values $Values -Percentile 95
        minMs = [long]$measure.Minimum
        maxMs = [long]$measure.Maximum
        averageMs = [Math]::Round([double]$measure.Average, 1)
    }
}

$script:hdc = Resolve-Hdc
$script:target = Resolve-LeanTTYRegressionTarget -Hdc $script:hdc -Target $Target
$transport = Get-HdcTargetTransport -Hdc $script:hdc -Target $script:target
if ($transport -ne 'usb') {
    throw "Startup performance measurement requires a USB-connected physical PC, got $transport"
}

if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $repoRoot (
        'build\verification\startup-performance-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    )
}
$script:evidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Force -Path $script:evidenceDirectory | Out-Null

$awakeLease = $false
$samples = [Collections.Generic.List[object]]::new()
try {
    Start-LeanTTYDeviceAwakeLease -Hdc $script:hdc -Target $script:target
    $awakeLease = $true

    if (-not $SkipBuild) {
        Invoke-WithLeanTTYStartupPerformanceSource -RepoRoot $repoRoot -Action {
            & (Join-Path $PSScriptRoot 'dev-pc.ps1') -Target $script:target -NoLaunch
            if ($LASTEXITCODE -ne 0) { throw 'Startup diagnostic build or deployment failed' }
        }
    }

    $model = (Invoke-StartupHdcShell -Command 'param get const.product.model').Trim()
    $abi = (Invoke-StartupHdcShell -Command 'param get const.product.cpu.abilist').Trim()
    $osVersion = (Invoke-StartupHdcShell -Command 'param get const.product.software.version').Trim()
    if ($abi -notmatch 'arm64-v8a') { throw "Target is not an ARM64 HarmonyOS PC: $abi" }

    $hapPath = Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
    if (-not (Test-Path -LiteralPath $hapPath -PathType Leaf)) {
        throw "Diagnostic signed HAP is missing: $hapPath"
    }
    $hapSha256 = (Get-FileHash -LiteralPath $hapPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $gitCommit = (& git -C $repoRoot rev-parse HEAD).Trim()

    for ($sampleIndex = 1; $sampleIndex -le $SampleCount; $sampleIndex++) {
        & $script:hdc -t $script:target shell 'aa force-stop com.leantty.app' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'LeanTTY force-stop failed' }
        Wait-StartupProcessStopped

        & $script:hdc -t $script:target shell 'uitest uiInput keyEvent Home' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to return the test PC to the desktop' }
        Start-Sleep -Milliseconds 500
        $desktopLayout = Get-StartupGlobalLayout -Name ("sample-{0:D2}-desktop" -f $sampleIndex)
        $appCenter = Get-StartupNodeCenter -Layout $desktopLayout `
            -Id 'AppIconCommonView_com.ohos.sceneboard.com.ohos.sceneboard.appcenter.MainAbility'
        & $script:hdc -t $script:target shell (
            "uitest uiInput click $($appCenter.x) $($appCenter.y)"
        ) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to open the HarmonyOS App Center' }
        Start-Sleep -Milliseconds 900
        $appCenterLayout = Get-StartupGlobalLayout -Name ("sample-{0:D2}-app-center" -f $sampleIndex)
        $leanTtyIcon = Get-StartupNodeCenter -Layout $appCenterLayout `
            -Id 'AppCenterAppGrid_AppBubble_com.leantty.app'

        Clear-LeanTTYAppLogs -Hdc $script:hdc -Target $script:target
        $deviceCommand = 'sh -c ''(i=0; while ! hilog -x -t app -T TerminalBridge | ' +
            'grep -q "STARTUP_PERF phase=T4"; do i=$((i+1)); ' +
            'if [ $i -ge 500 ]; then printf WATCH_TIMEOUT=1; exit 1; fi; sleep 0.02; done; ' +
            'printf TIN=; date +%s%3N; uinput -K -d 2017 -u 2017; sleep 0.3) & ' +
            'sleep 0.1; printf T0=; date +%s%3N; uitest uiInput click ' +
            $leanTtyIcon.x + ' ' + $leanTtyIcon.y + '; wait'''
        $launchOutput = @(& $script:hdc -t $script:target shell $deviceCommand 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $launchOutput -match 'WATCH_TIMEOUT') {
            throw "Device-side T4 input watcher failed for sample ${sampleIndex}: $launchOutput"
        }
        $t0Match = [regex]::Match($launchOutput, '(?m)^T0=(?<time>\d{13})$')
        $inputMatch = [regex]::Match($launchOutput, '(?m)^TIN=(?<time>\d{13})$')
        if (-not $t0Match.Success -or -not $inputMatch.Success) {
            throw "Device-side timestamps are missing for sample ${sampleIndex}: $launchOutput"
        }
        $t0 = [long]$t0Match.Groups['time'].Value
        $inputAt = [long]$inputMatch.Groups['time'].Value

        Start-Sleep -Milliseconds 300
        $processId = (Invoke-StartupHdcShell -Command 'pidof com.leantty.app').Trim()
        if ($processId -notmatch '^\d+$') { throw "Invalid LeanTTY PID: $processId" }
        $logs = @(& $script:hdc -t $script:target shell (
            "hilog -z 500 -t app -P $processId " +
            '-T EntryAbility,StartupPerformance,TerminalBridge -v epoch -v msec'
        ) 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "Unable to read startup logs for sample $sampleIndex" }
        $startupLogLines = @($logs -split "`r?`n" | Where-Object {
            $_ -match 'STARTUP_PERF|Ability onCreate|Succeeded in loading the content'
        }) -join "`n"
        [IO.File]::WriteAllText(
            (Join-Path $script:evidenceDirectory ("sample-{0:D2}-startup.log" -f $sampleIndex)),
            $startupLogLines + "`n"
        )
        $markerTimes = Get-StartupMarkerTimes -Logs $startupLogLines
        $segments = Get-StartupSegments -Logs $startupLogLines
        $durableSegments = Get-DurableStartupSegments -Logs $startupLogLines
        $injectionLag = $inputAt - [long]$markerTimes.T4
        if ($injectionLag -lt 0 -or $injectionLag -gt 250) {
            throw "T4-to-input injection lag is outside the 0-250 ms validity bound: $injectionLag"
        }
        if ([long]$markerTimes.T5 -lt $inputAt) {
            throw 'T5 preceded the physical-key injection timestamp'
        }

        $sample = [ordered]@{
            index = $sampleIndex
            t0ClickEpochMs = $t0
            t1AbilityEpochMs = [long]$markerTimes.T1
            t2ContentEpochMs = [long]$markerTimes.T2
            t3WebPageEndEpochMs = [long]$markerTimes.T3
            t4PromptPaintEpochMs = [long]$markerTimes.T4
            inputInjectedEpochMs = $inputAt
            t5FirstLetterPaintEpochMs = [long]$markerTimes.T5
            clickToAbilityMs = [long]$markerTimes.T1 - $t0
            abilityToContentMs = [long]$markerTimes.T2 - [long]$markerTimes.T1
            contentToWebPageEndMs = [long]$markerTimes.T3 - [long]$markerTimes.T2
            webPageEndToPromptPaintMs = [long]$markerTimes.T4 - [long]$markerTimes.T3
            t4ToInputInjectionMs = $injectionLag
            inputRoundTripPaintMs = [long]$markerTimes.T5 - $inputAt
            clickToFirstLetterPaintMs = [long]$markerTimes.T5 - $t0
            onCreateSegments = $segments
            durableStateSegments = $durableSegments
        }
        $samples.Add([pscustomobject]$sample)
        Write-Host (
            "Cold sample $sampleIndex/${SampleCount}: T0-T5=$($sample.clickToFirstLetterPaintMs) ms, " +
            "T0-T1=$($sample.clickToAbilityMs) ms, T1-T2=$($sample.abilityToContentMs) ms, " +
            "T2-T3=$($sample.contentToWebPageEndMs) ms, T3-T4=$($sample.webPageEndToPromptPaintMs) ms, " +
            "input=$($sample.inputRoundTripPaintMs) ms"
        ) -ForegroundColor Cyan

        if ($sampleIndex -eq 1) {
            Save-LeanTTYDeviceScreenshot -Hdc $script:hdc -Target $script:target `
                -LocalPath (Join-Path $script:evidenceDirectory 'sample-01-first-letter.png')
        }
        Start-Sleep -Milliseconds 500
    }

    $summary = [ordered]@{
        schemaVersion = 1
        capturedAt = (Get-Date).ToString('o')
        scenario = 'daily-cold-start-from-system-app-center'
        input = 'device-side-uinput-ascii-a-after-t4'
        sampleCount = $samples.Count
        gitCommit = $gitCommit
        hapSha256 = $hapSha256
        device = [ordered]@{
            target = $script:target
            transport = $transport
            model = $model
            abi = $abi
            osVersion = $osVersion
        }
        validity = [ordered]@{
            processAbsentBeforeClick = $true
            realAppCenterIconClick = $true
            t5RequiresMatchingAsciiEchoAndPaint = $true
            maxT4ToInputInjectionMs = 250
        }
        statistics = [ordered]@{
            clickToFirstLetterPaint = Get-StartupStatistics -Values @(
                $samples | ForEach-Object { [long]$_.clickToFirstLetterPaintMs }
            )
            clickToAbility = Get-StartupStatistics -Values @(
                $samples | ForEach-Object { [long]$_.clickToAbilityMs }
            )
            abilityToContent = Get-StartupStatistics -Values @(
                $samples | ForEach-Object { [long]$_.abilityToContentMs }
            )
            contentToWebPageEnd = Get-StartupStatistics -Values @(
                $samples | ForEach-Object { [long]$_.contentToWebPageEndMs }
            )
            webPageEndToPromptPaint = Get-StartupStatistics -Values @(
                $samples | ForEach-Object { [long]$_.webPageEndToPromptPaintMs }
            )
            inputRoundTripPaint = Get-StartupStatistics -Values @(
                $samples | ForEach-Object { [long]$_.inputRoundTripPaintMs }
            )
            durableInitialize = Get-StartupStatistics -Values @(
                $samples | ForEach-Object { [long]$_.onCreateSegments.durable }
            )
            durableInitializedRead = Get-StartupStatistics -Values @(
                $samples | ForEach-Object { [long]$_.durableStateSegments.'initialized-read' }
            )
        }
        samples = @($samples)
    }
    $summaryPath = Join-Path $script:evidenceDirectory 'summary.json'
    [IO.File]::WriteAllText(
        $summaryPath,
        (ConvertTo-Json -InputObject $summary -Depth 12) + "`n"
    )
    Write-Host "STARTUP PERFORMANCE EVIDENCE: $summaryPath" -ForegroundColor Green
    Write-Host (
        "Cold T0-T5 P50=$($summary.statistics.clickToFirstLetterPaint.p50Ms) ms, " +
        "P95=$($summary.statistics.clickToFirstLetterPaint.p95Ms) ms"
    ) -ForegroundColor Green
} finally {
    & $script:hdc -t $script:target shell 'aa force-stop com.leantty.app' 2>$null | Out-Null
    & $script:hdc -t $script:target shell 'uitest uiInput keyEvent Home' 2>$null | Out-Null
    if ($awakeLease) {
        Stop-LeanTTYDeviceAwakeLease -Hdc $script:hdc -Target $script:target
    }
}
