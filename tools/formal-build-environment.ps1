function Test-LeanTTYOhpmLockfileTextEqual {
    param([byte[]]$Before, [byte[]]$After)

    # OHPM rewrites CRLF and the final newline. All dependency text stays exact.
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    return $utf8.GetString($Before).Replace("`r`n", "`n").TrimEnd("`n") -ceq
        $utf8.GetString($After).Replace("`r`n", "`n").TrimEnd("`n")
}

function Resolve-LeanTTYDevEcoBuildTools {
    param([string]$DevEcoHome = $env:DEVECO_HOME)

    $resolved = $DevEcoHome
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $resolved = @(
            'C:\Program Files\Huawei\DevEco Studio',
            'D:\Program Files\Huawei\DevEco Studio'
        ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
            Select-Object -First 1
    }
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw 'DevEco Studio not found. Set DEVECO_HOME.'
    }
    $resolved = [IO.Path]::GetFullPath($resolved)
    $tools = [pscustomobject][ordered]@{
        root = $resolved
        node = Join-Path $resolved 'tools\node\node.exe'
        npmCli = Join-Path $resolved 'tools\node\node_modules\npm\bin\npm-cli.js'
        hvigor = Join-Path $resolved 'tools\hvigor\bin\hvigorw.js'
        ohpm = Join-Path $resolved 'tools\ohpm\bin\ohpm.bat'
        javaHome = Join-Path $resolved 'jbr'
        sdkHome = Join-Path $resolved 'sdk'
        productInfo = Join-Path $resolved 'product-info.json'
    }
    foreach ($path in @(
        $tools.node, $tools.npmCli, $tools.hvigor, $tools.ohpm, $tools.productInfo
    )) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "DevEco build input is missing: $path"
        }
    }
    return $tools
}

function Invoke-LeanTTYCapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$StandardOutputPath,
        [Parameter(Mandatory = $true)][string]$StandardErrorPath
    )

    foreach ($path in @($StandardOutputPath, $StandardErrorPath)) {
        New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = [IO.Path]::GetFullPath($FilePath)
    $startInfo.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Unable to start captured process: $FilePath" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        [IO.File]::WriteAllText($StandardOutputPath, $stdout, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($StandardErrorPath, $stderr, [Text.UTF8Encoding]::new($false))
        return [pscustomobject][ordered]@{
            exitCode = $process.ExitCode
            stdout = $stdout
            stderr = $stderr
            stdoutPath = [IO.Path]::GetFullPath($StandardOutputPath)
            stderrPath = [IO.Path]::GetFullPath($StandardErrorPath)
        }
    } finally {
        $process.Dispose()
    }
}

function Get-LeanTTYArkTsWarningFingerprint {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$StandardError,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )

    $clean = [regex]::Replace($StandardError, "`e\[[0-9;]*m", '')
    $matches = [regex]::Matches(
        $clean,
        'ArkTS:WARN File: (?<path>[^\r\n]+)\r?\n (?<message>[^\r\n]+)'
    )
    $rootPrefix = [IO.Path]::GetFullPath($RepoRoot).Replace('\', '/').TrimEnd('/') + '/'
    $warnings = [string[]]@(
        foreach ($match in $matches) {
            $path = ([string]$match.Groups['path'].Value).Replace('\', '/')
            if ($path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                $path = $path.Substring($rootPrefix.Length)
            }
            $path + '|' + ([string]$match.Groups['message'].Value).Trim()
        }
    )
    [Array]::Sort($warnings, [StringComparer]::Ordinal)
    $normalized = $warnings -join "`n"
    $hash = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($normalized))
    ).ToLowerInvariant()
    return [pscustomobject][ordered]@{
        warningCount = $warnings.Count
        sha256 = $hash
        normalized = $normalized
    }
}

function Assert-LeanTTYArkTsWarningBaseline {
    param(
        [Parameter(Mandatory = $true)][string]$BaselinePath,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$DevEcoVersion,
        [Parameter(Mandatory = $true)][string]$HvigorVersion,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$StandardError
    )

    $baseline = Get-Content -LiteralPath $BaselinePath -Raw | ConvertFrom-Json
    if ([string]$baseline.devEcoVersion -cne $DevEcoVersion -or
        [string]$baseline.hvigorVersion -cne $HvigorVersion) {
        throw ('ArkTS warning baseline does not authorize this toolchain: DevEco ' +
            "$DevEcoVersion, Hvigor $HvigorVersion")
    }
    $actual = Get-LeanTTYArkTsWarningFingerprint `
        -StandardError $StandardError -RepoRoot $RepoRoot
    if ($actual.warningCount -ne [int]$baseline.warningCount -or
        $actual.sha256 -cne [string]$baseline.sha256) {
        throw ('ArkTS warning set changed: expected count/hash ' +
            "$($baseline.warningCount)/$($baseline.sha256), got " +
            "$($actual.warningCount)/$($actual.sha256)")
    }
    return $actual
}
