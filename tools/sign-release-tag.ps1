<#
.SYNOPSIS
  Create and locally verify one immutable LeanTTY OpenPGP release tag.
.DESCRIPTION
  Resolves Git's effective OpenPGP executable once, then uses that exact
  executable and keyring for both tag creation and verification. The local
  passphrase file is read by GPG and is never copied into the repository.
  This script does not push the tag.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$Commit,
    [Parameter(Mandatory = $true)][string]$PassphrasePath,
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-tooling.ps1')

if ($Tag -notmatch '^v\d+\.\d+\.\d+$') {
    throw "Stable release tag must match vX.Y.Z: $Tag"
}
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$PassphrasePath = [IO.Path]::GetFullPath($PassphrasePath)
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.git'))) {
    throw "Git repository was not found: $RepoRoot"
}
if (-not (Test-Path -LiteralPath $PassphrasePath -PathType Leaf) -or
    (Get-Item -LiteralPath $PassphrasePath).Length -eq 0) {
    throw "Local PGP passphrase file is missing or empty: $PassphrasePath"
}

$gitStatus = @(& git -C $RepoRoot status --porcelain=v1 2>&1)
if ($LASTEXITCODE -ne 0 -or $gitStatus.Count -ne 0) {
    throw 'Release tag requires a clean Git worktree'
}
& git -C $RepoRoot fetch origin --tags
if ($LASTEXITCODE -ne 0) { throw 'Unable to fetch origin before tag creation' }

& git -C $RepoRoot show-ref --verify --quiet "refs/tags/$Tag"
if ($LASTEXITCODE -eq 0) { throw "Local tag already exists: $Tag" }
$remoteTag = @(& git -C $RepoRoot ls-remote --tags origin "refs/tags/$Tag" "refs/tags/$Tag^{}" 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect remote tag state' }
if ($remoteTag.Count -ne 0) { throw "Remote tag already exists: $Tag" }

$resolvedCommit = (@(& git -C $RepoRoot rev-parse ($Commit + '^{commit}') 2>&1) -join "`n").Trim()
if ($LASTEXITCODE -ne 0 -or $resolvedCommit -notmatch '^[0-9a-f]{40}$') {
    throw "Invalid release commit: $Commit"
}
& git -C $RepoRoot merge-base --is-ancestor $resolvedCommit origin/main
if ($LASTEXITCODE -ne 0) { throw 'Release commit is not contained by origin/main' }

$backend = Resolve-LeanTTYGitSigningBackend -RepoRoot $RepoRoot
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') +
    [IO.Path]::DirectorySeparatorChar
$wrapperPath = Join-Path $temporaryRoot ('leantty-gpg-' + [Guid]::NewGuid().ToString('N') + '.cmd')
try {
    $wrapper = @(
        '@echo off',
        ('"' + $backend.executablePath + '" --batch --pinentry-mode loopback ' +
            '--passphrase-file "' + $PassphrasePath + '" %*')
    ) -join "`r`n"
    [IO.File]::WriteAllText($wrapperPath, $wrapper + "`r`n", [Text.ASCIIEncoding]::new())
    $gitWrapperPath = $wrapperPath.Replace('\', '/')
    $backendConfig = "gpg.$($backend.format).program=$gitWrapperPath"

    & git -C $RepoRoot -c "gpg.format=$($backend.format)" -c $backendConfig `
        tag -s $Tag $resolvedCommit -m $Tag
    if ($LASTEXITCODE -ne 0) { throw "GPG tag creation failed: $Tag" }

    & git -C $RepoRoot -c "gpg.format=$($backend.format)" -c $backendConfig tag -v $Tag
    if ($LASTEXITCODE -ne 0) { throw "GPG tag verification failed: $Tag" }
} catch {
    & git -C $RepoRoot tag -d $Tag 2>$null | Out-Null
    throw
} finally {
    if (Test-Path -LiteralPath $wrapperPath) {
        Remove-Item -LiteralPath $wrapperPath -Force
    }
}

$tagTarget = (@(& git -C $RepoRoot rev-list -n 1 $Tag 2>&1) -join "`n").Trim()
if ($LASTEXITCODE -ne 0 -or $tagTarget -ne $resolvedCommit) {
    & git -C $RepoRoot tag -d $Tag 2>$null | Out-Null
    throw "Signed tag target mismatch: expected $resolvedCommit, got $tagTarget"
}

Write-Host (
    "SIGNED TAG VERIFIED: $Tag -> $tagTarget using $($backend.executablePath)"
) -ForegroundColor Green
