[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$failures = [Collections.Generic.List[string]]::new()

# Only the byte-verified upstream package may contain its public example keys.
& (Join-Path $PSScriptRoot 'check-ssh-key-patch.ps1')

Push-Location $repoRoot
try {
    $tracked = @(git ls-files)
    if ($LASTEXITCODE -ne 0) {
        throw 'git ls-files failed'
    }
    if ($tracked.Count -eq 0) {
        throw 'No tracked source files were found'
    }
    $sourceFiles = @(git ls-files --cached --others --exclude-standard | Sort-Object -Unique)
    if ($LASTEXITCODE -ne 0) {
        throw 'git source-file enumeration failed'
    }
    $sourceFiles = @($sourceFiles | Where-Object {
        Test-Path -LiteralPath (Join-Path $repoRoot $_) -PathType Leaf
    })

    $forbiddenPaths = @(
        @{ Pattern = '(^|/)node_modules/'; Reason = 'dependency cache' },
        @{ Pattern = '(^|/)target/'; Reason = 'Rust build output' },
        @{ Pattern = '(^|/)build/'; Reason = 'generated build output' },
        @{ Pattern = '(^|/)\.codex/'; Reason = 'machine-local agent configuration' },
        @{ Pattern = '(^|/)agent\.md$'; Reason = 'obsolete machine-local instruction' },
        @{ Pattern = '(^|/)entry/libs/x86_64/'; Reason = 'unsupported native target' },
        @{ Pattern = '\.(hap|app|so|dll|exe)$'; Reason = 'generated binary or package' },
        @{ Pattern = '(^|/)signing\.local\.json5$'; Reason = 'local signing injection' },
        @{ Pattern = '\.(p12|pfx|jks|keystore|pem|key)$'; Reason = 'credential material' }
    )

    foreach ($path in $sourceFiles) {
        $normalized = $path.Replace('\', '/')
        foreach ($rule in $forbiddenPaths) {
            if ($normalized -match $rule.Pattern) {
                $failures.Add("Forbidden tracked path ($($rule.Reason)): $normalized")
            }
        }

        $fullPath = [IO.Path]::GetFullPath((Join-Path $repoRoot $path))
        if (-not $fullPath.StartsWith($repoRoot + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase)) {
            $failures.Add("Tracked path escapes the repository: $path")
            continue
        }
        if ((Get-Item -LiteralPath $fullPath).Length -gt 10MB) {
            $failures.Add("Tracked file exceeds 10 MiB: $normalized")
        }
    }

    $textExtensions = @(
        '.c', '.cc', '.cpp', '.css', '.d.ts', '.ets', '.h', '.html', '.js',
        '.json', '.json5', '.md', '.mjs', '.ps1', '.py', '.rs', '.toml',
        '.ts', '.txt', '.xml', '.yaml', '.yml'
    )
    $sensitiveContent = @(
        @{ Pattern = '(?i)[A-Z]:[\\/]+Users[\\/]+'; Reason = 'personal Windows profile path' },
        @{ Pattern = '(?i)[A-Z]:[\\/]+repos[\\/]+[^\\/\s]+'; Reason = 'fixed local checkout path' },
        @{ Pattern = '3QC[0-9A-Z]{8,}'; Reason = 'physical device identifier' },
        @{ Pattern = '10\.160\.'; Reason = 'known private network address' },
        @{ Pattern = 'security@leantty\.dev'; Reason = 'nonexistent placeholder address' },
        @{ Pattern = '-----BEGIN (?:OPENSSH |RSA |EC )?PRIVATE KEY-----'; Reason = 'private key data' },
        @{ Pattern = '(?:ghp_|ghs_|github_pat_)[A-Za-z0-9_]{20,}'; Reason = 'GitHub credential' }
    )

    foreach ($path in $sourceFiles) {
        $normalized = $path.Replace('\', '/')
        if ($normalized -eq 'tools/check-public-source.ps1') {
            continue
        }
        $extension = [IO.Path]::GetExtension($path).ToLowerInvariant()
        if ($textExtensions -notcontains $extension -and
            [IO.Path]::GetFileName($path) -notin @('LICENSE', '.gitignore')) {
            continue
        }
        $content = Get-Content -LiteralPath (Join-Path $repoRoot $path) -Raw
        foreach ($rule in $sensitiveContent) {
            if ($rule.Reason -eq 'private key data' -and
                $normalized.StartsWith('third-party/ssh-key/ssh-key-0.7.0-rc.11/')) {
                continue
            }
            if ($content -match $rule.Pattern) {
                $failures.Add("Sensitive content ($($rule.Reason)): $normalized")
            }
        }
    }

    foreach ($path in $sourceFiles | Where-Object { $_ -like '*.ps1' }) {
        $tokens = $null
        $parseErrors = $null
        [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $repoRoot $path),
            [ref]$tokens,
            [ref]$parseErrors
        ) | Out-Null
        foreach ($parseError in @($parseErrors)) {
            $failures.Add("PowerShell syntax error in $path`: $($parseError.Message)")
        }

        $content = Get-Content -LiteralPath (Join-Path $repoRoot $path) -Raw
        foreach ($dotSource in [regex]::Matches(
                $content,
                "(?m)^\s*\.\s+\(Join-Path\s+\`$PSScriptRoot\s+'(?<relative>[^']+)'\)\s*$"
            )) {
            $scriptDirectory = Split-Path (Join-Path $repoRoot $path) -Parent
            $dependencyPath = [IO.Path]::GetFullPath(
                (Join-Path $scriptDirectory $dotSource.Groups['relative'].Value)
            )
            if (-not $dependencyPath.StartsWith(
                    $repoRoot + [IO.Path]::DirectorySeparatorChar,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                $failures.Add("PowerShell dot-source escapes the repository: $path")
                continue
            }
            $dependencyRelative = $dependencyPath.Substring($repoRoot.Length + 1).Replace('\', '/')
            if ($sourceFiles -notcontains $dependencyRelative) {
                $failures.Add(
                    "PowerShell dot-source is not part of the source tree: $path -> $dependencyRelative"
                )
            }
        }
    }

    $workflowFiles = @($sourceFiles | Where-Object {
        $_.Replace('\', '/') -match '^\.github/workflows/.+\.ya?ml$'
    })
    foreach ($path in $workflowFiles) {
        $content = Get-Content -LiteralPath (Join-Path $repoRoot $path) -Raw
        if ($content -match '(?m)^\s*pull_request_target\s*:') {
            $failures.Add("Unsafe pull_request_target workflow trigger: $path")
        }
        if ($content -notmatch '(?m)^permissions:\s*\r?\n\s+contents:\s+read\s*$') {
            $failures.Add("Workflow must declare top-level contents: read: $path")
        }
        foreach ($actionUse in [regex]::Matches($content, '(?m)^\s*uses:\s+[^@\s]+@([^\s#]+)')) {
            if ($actionUse.Groups[1].Value -notmatch '^[0-9a-f]{40}$') {
                $failures.Add("Workflow action is not pinned to a full commit SHA: $path")
            }
        }
    }

    if ($failures.Count -gt 0) {
        $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
        throw "Public-source policy failed with $($failures.Count) finding(s)"
    }

    Write-Host "Public-source policy passed for $($sourceFiles.Count) source files."
}
finally {
    Pop-Location
}
