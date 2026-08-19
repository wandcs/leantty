function Resolve-Hdc {
    $candidates = @(
        $(if ($env:DEVECO_HOME) {
                Join-Path $env:DEVECO_HOME 'sdk\default\openharmony\toolchains\hdc.exe'
            } else {
                ''
            }),
        'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }
    throw 'hdc not found. Set DEVECO_HOME or install DevEco Studio.'
}

function ConvertFrom-HdcTargetList {
    param([string[]]$Lines)

    $targets = [Collections.Generic.List[object]]::new()
    foreach ($line in $Lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed -eq '[Empty]') {
            continue
        }
        $fields = @($trimmed -split '\s+')
        if ($fields.Count -lt 2) {
            continue
        }
        $targets.Add([pscustomobject]@{
                key       = $fields[0]
                transport = $fields[1].ToUpperInvariant()
                status    = $(if ($fields.Count -ge 3) { $fields[2] } else { '' })
                raw       = $trimmed
            })
    }
    return @($targets)
}

function Get-HdcTargets {
    param([string]$Hdc)

    $output = @(& $Hdc list targets -v 2>&1)
    return @(ConvertFrom-HdcTargetList -Lines $output)
}

function Get-HdcTargetTransport {
    param([string]$Hdc, [string]$Target)

    $match = @(Get-HdcTargets -Hdc $Hdc |
        Where-Object { $_.key -eq $Target } |
        Select-Object -First 1)
    if ($match.Count -eq 1) {
        return $match[0].transport.ToLowerInvariant()
    }
    if ($Target -match '^127\.0\.0\.1:') {
        return 'emulator'
    }
    if ($Target -match ':\d+$') {
        return 'tcp'
    }
    return 'unknown'
}

function Test-HdcCommandFailure {
    param([string]$Output)

    if ([string]::IsNullOrWhiteSpace($Output)) { return $false }
    return $Output -match '(?im)\[E[0-9A-F]{6}\]|^\s*\[Fail\]|Forwardport result:(?!OK)|Mutlti commands can''t be used'
}

function Assert-HdcTargetReady {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $matches = @(Get-HdcTargets -Hdc $Hdc | Where-Object { $_.key -eq $Target })
    if ($matches.Count -ne 1) {
        throw "[infrastructure] HDC target '$Target' is unavailable; reconnect or power it before rerunning"
    }
    $match = $matches[0]
    if ($match.transport -notmatch '^(USB|TCP)$' -or
        $match.status -notmatch '^(Ready|Connected)$') {
        $state = if ([string]::IsNullOrWhiteSpace($match.status)) { 'unknown' } else { $match.status }
        throw "[infrastructure] HDC target '$Target' is $state; no automatic recovery was attempted"
    }
    return $match
}

function Invoke-HdcChecked {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Operation,
        [ValidateSet('environment', 'infrastructure', 'harness')]
        [string]$FailureDomain = 'infrastructure'
    )

    $output = @(& $Hdc -t $Target @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = $output -join "`n"
    if ($exitCode -ne 0 -or (Test-HdcCommandFailure -Output $text)) {
        $codeMatch = [regex]::Match($text, '\[(?<code>E[0-9A-F]{6})\]', 'IgnoreCase')
        $code = if ($codeMatch.Success) { ", hdcCode=$($codeMatch.Groups['code'].Value)" } else { '' }
        throw "[$FailureDomain] $Operation failed (exitCode=$exitCode$code)"
    }
    return $text
}

function Invoke-HdcShell {
    param([string]$Hdc, [string]$Target, [string]$Command)

    return ((& $Hdc -t $Target shell $Command 2>&1) -join "`n")
}
