param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'prepare-release-assets.ps1')
$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$testRoot = Join-Path $temporaryBase ('LeanTTY-release-materials-' + [Guid]::NewGuid().ToString('N'))

function Invoke-FixtureGit {
    param([string[]]$Arguments)
    $result = & git -C $testRoot @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $result" }
    return $result
}

function Assert-MaterialRejected {
    param([scriptblock]$Action, [string]$ExpectedError)
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notlike "*$ExpectedError*") { throw }
        return
    }
    throw "Expected rejection: $ExpectedError"
}

New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    Invoke-FixtureGit @('init', '--quiet') | Out-Null
    $copyPath = Join-Path $testRoot 'appgallery.md'
    [IO.File]::WriteAllText($copyPath, "# LeanTTY 9.8.7`n`nVerified feature.`n")
    Invoke-FixtureGit @('add', 'appgallery.md') | Out-Null
    Invoke-FixtureGit @('-c', 'user.name=di', '-c', 'user.email=2195397+wandcs@users.noreply.github.com',
        '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'material fixture') | Out-Null
    $commit = [string](Invoke-FixtureGit @('rev-parse', 'HEAD'))
    Invoke-FixtureGit @('checkout', '--detach', '--quiet') | Out-Null
    Assert-MaterialRejected {
        Get-LeanTTYReleaseMaterialIdentity -Checkout $testRoot -AppGalleryCopyPath $copyPath -ReleaseId '9.8.7'
    } 'fetched origin'
    Invoke-FixtureGit @('update-ref', 'refs/remotes/origin/main', $commit) | Out-Null
    $identity = Get-LeanTTYReleaseMaterialIdentity -Checkout $testRoot -AppGalleryCopyPath $copyPath -ReleaseId '9.8.7'
    if ($identity.commit -cne $commit -or $identity.path -cne 'appgallery.md' -or
        $identity.sha256 -cne (Get-FileHash -LiteralPath $copyPath -Algorithm SHA256).Hash.ToLowerInvariant()) {
        throw 'Material provenance does not match the independent checkout and file'
    }
    Assert-MaterialRejected {
        Get-LeanTTYReleaseMaterialIdentity -Checkout $testRoot -AppGalleryCopyPath $copyPath -ReleaseId '9.8.6'
    } 'release and contain no placeholder'
    Assert-MaterialRejected {
        Get-LeanTTYReleaseMaterialIdentity -Checkout $testRoot -AppGalleryCopyPath $PSCommandPath -ReleaseId '9.8.7'
    } 'inside the materials checkout'
    [IO.File]::AppendAllText($copyPath, 'uncommitted')
    Assert-MaterialRejected {
        Get-LeanTTYReleaseMaterialIdentity -Checkout $testRoot -AppGalleryCopyPath $copyPath -ReleaseId '9.8.7'
    } 'clean'
    [IO.File]::WriteAllText($copyPath, "# LeanTTY 9.8.7`n`nVerified feature.`n")
    $untrackedCopy = Join-Path $testRoot 'untracked.md'
    [IO.File]::WriteAllText($untrackedCopy, 'LeanTTY 9.8.7')
    Assert-MaterialRejected {
        Get-LeanTTYReleaseMaterialIdentity -Checkout $testRoot -AppGalleryCopyPath $untrackedCopy -ReleaseId '9.8.7'
    } 'clean'
    [IO.File]::WriteAllText((Join-Path $testRoot '.git/info/exclude'), "untracked.md`n")
    Assert-MaterialRejected {
        Get-LeanTTYReleaseMaterialIdentity -Checkout $testRoot -AppGalleryCopyPath $untrackedCopy -ReleaseId '9.8.7'
    } 'tracked by the materials commit'
    Invoke-FixtureGit @('update-index', '--assume-unchanged', 'appgallery.md') | Out-Null
    [IO.File]::AppendAllText($copyPath, 'hidden edit')
    Assert-MaterialRejected {
        Get-LeanTTYReleaseMaterialIdentity -Checkout $testRoot -AppGalleryCopyPath $copyPath -ReleaseId '9.8.7'
    } 'bytes differ'
    [IO.File]::WriteAllText($copyPath, "# LeanTTY 9.8.7`n`nVerified feature.`n")
    Invoke-FixtureGit @('update-index', '--no-assume-unchanged', 'appgallery.md') | Out-Null
    Invoke-FixtureGit @('switch', '-c', 'fixture-branch') | Out-Null
    Assert-MaterialRejected {
        Get-LeanTTYReleaseMaterialIdentity -Checkout $testRoot -AppGalleryCopyPath $copyPath -ReleaseId '9.8.7'
    } 'detached'
    Invoke-FixtureGit @('checkout', '--detach', '--quiet') | Out-Null
    [IO.File]::AppendAllText($copyPath, 'local-only change')
    Invoke-FixtureGit @('add', 'appgallery.md') | Out-Null
    Invoke-FixtureGit @('-c', 'user.name=di', '-c', 'user.email=2195397+wandcs@users.noreply.github.com',
        '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'unpublished material') | Out-Null
    Assert-MaterialRejected {
        Get-LeanTTYReleaseMaterialIdentity -Checkout $testRoot -AppGalleryCopyPath $copyPath -ReleaseId '9.8.7'
    } 'fetched origin'
    [IO.File]::WriteAllText($untrackedCopy, 'LeanTTY 9.8.7 TODO')
    Assert-MaterialRejected {
        Assert-LeanTTYAppGalleryCopy -Path $untrackedCopy -ReleaseId '9.8.7'
    } 'release and contain no placeholder'
    Write-Host 'Release material provenance tests passed.'
} finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedTestRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
