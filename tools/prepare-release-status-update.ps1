<#
.SYNOPSIS
  Prepare one auditable post-release status record for a single status PR.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$ReleaseId,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v\d+\.\d+\.\d+$')]
    [string]$Tag,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$Commit,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://github\.com/[^/]+/[^/]+/releases/tag/v\d+\.\d+\.\d+$')]
    [string]$GitHubReleaseUrl,
    [Parameter(Mandatory = $true)]
    [ValidateSet('Submitted', 'In review', 'Rejected', 'Released')]
    [string]$AppGalleryState,
    [Parameter(Mandatory = $true)][DateTimeOffset]$MaintainerReportedAt,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-tooling.ps1')

if ($Tag -ne "v$ReleaseId" -or -not $GitHubReleaseUrl.EndsWith("/tag/$Tag")) {
    throw 'ReleaseId, tag and GitHub Release URL do not identify one version'
}
$record = @"
# LeanTTY $ReleaseId post-release status

- GitHub Release: $GitHubReleaseUrl
- Tag: $Tag
- Commit: $($Commit.ToLowerInvariant())
- Maintainer-reported AppGallery state: $AppGalleryState
- Maintainer report time: $($MaintainerReportedAt.ToString('o'))

Record this file, the matching current-status documentation, and the maintainer
handoff outcome in one status pull request. Do not infer a later AppGallery state.
"@
Write-LeanTTYAtomicText -Path $OutputPath -Content ($record.TrimEnd() + "`n")
Write-Host "Post-release status record prepared: $([IO.Path]::GetFullPath($OutputPath))"
