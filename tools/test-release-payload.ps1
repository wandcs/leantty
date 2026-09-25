param()
$ErrorActionPreference = 'Stop'
& node (Join-Path $PSScriptRoot 'test-sign-review-hap.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Review signing bridge tests failed' }
. (Join-Path $PSScriptRoot 'release-payload.ps1')
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$testRoot = Join-Path $tempBase ('LeanTTY-payload-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
function Assert-PayloadRejected([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw "Expected release payload rejection: $Pattern"
}
function New-PayloadFixture([object[]]$Members) {
    $path = Join-Path $testRoot ([guid]::NewGuid().ToString('N') + '.zip')
    $zip = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($member in $Members) {
            $stream = $zip.CreateEntry($member.name).Open()
            try { $stream.Write([byte[]]$member.bytes) } finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
    return $path
}
try {
    $members = @(@{name='module.json';bytes=[byte[]](1,2)}, @{name='libs/arm64-v8a/libleantty_terminal.so';bytes=[byte[]](3,4)},
        @{name='pack.info';bytes=[Text.Encoding]::UTF8.GetBytes('{"version":1}')})
    $hap = New-PayloadFixture $members
    $payload = Get-LeanTTYZipPayload $hap
    $reordered = New-PayloadFixture @($members[2], $members[1], $members[0])
    Assert-LeanTTYPayloadEqual $payload (Get-LeanTTYZipPayload $reordered)
    $signedMembers = @(@{name='.pages.info';bytes=[byte[]](9)}) + $members
    $signedPayload = Get-LeanTTYZipPayload (New-PayloadFixture $signedMembers)
    Assert-LeanTTYUnsignedPayload $payload $signedPayload
    Assert-PayloadRejected { Assert-LeanTTYUnsignedPayload $payload $payload } 'page bitmap boundary'
    $extraSigned = Get-LeanTTYZipPayload (New-PayloadFixture ($signedMembers + @{name='unexpected';bytes=[byte[]](7)}))
    Assert-PayloadRejected { Assert-LeanTTYUnsignedPayload $payload $extraSigned } 'payload members differ'
    $changedBitmap = Get-LeanTTYZipPayload (New-PayloadFixture (@(@{name='.pages.info';bytes=[byte[]](8)}) + $members))
    Assert-PayloadRejected { Assert-LeanTTYPayloadEqual $signedPayload $changedBitmap } 'payload members differ'
    foreach ($badMembers in @(
        ,@($members[0], @{name=$members[1].name;bytes=[byte[]](3,5)}, $members[2])
        ,@($members[0])
        ,@($members[0], $members[1], $members[2], @{name='extra';bytes=[byte[]](8)})
    )) {
        $bad = New-PayloadFixture $badMembers
        Assert-PayloadRejected { Assert-LeanTTYPayloadEqual $payload (Get-LeanTTYZipPayload $bad) } 'payload members differ'
    }
    $duplicate = New-PayloadFixture @($members[0], $members[0])
    Assert-PayloadRejected { Get-LeanTTYZipPayload $duplicate } 'Duplicate ZIP'
    $app = New-PayloadFixture @(@{name='entry.hap';bytes=[IO.File]::ReadAllBytes($hap)})
    $nested = Assert-LeanTTYAppHapPayload $app $hap
    if (-not $nested.programPayloadEqual) { throw 'Real nested HAP payload not compared' }
    $pretty = New-PayloadFixture @($members[0], $members[1], @{name='pack.info';bytes=[Text.Encoding]::UTF8.GetBytes("{`n  `"version`": 1`n}")})
    $prettyApp = New-PayloadFixture @(@{name='entry.hap';bytes=[IO.File]::ReadAllBytes($pretty)})
    Assert-LeanTTYAppHapPayload $prettyApp $hap | Out-Null
    $different = New-PayloadFixture @($members[0], $members[1], @{name='pack.info';bytes=[Text.Encoding]::UTF8.GetBytes('{"version":2}')})
    $differentApp = New-PayloadFixture @(@{name='entry.hap';bytes=[IO.File]::ReadAllBytes($different)})
    Assert-PayloadRejected { Assert-LeanTTYAppHapPayload $differentApp $hap } 'pack.info value differs'
    $wrongHap = New-PayloadFixture @($members[0])
    $wrongApp = New-PayloadFixture @(@{name='entry.hap';bytes=[IO.File]::ReadAllBytes($wrongHap)})
    Assert-PayloadRejected { Assert-LeanTTYAppHapPayload $wrongApp $hap } 'payload members differ'
    $extraApp = New-PayloadFixture @(@{name='entry.hap';bytes=[IO.File]::ReadAllBytes($hap)}, @{name='other.hap';bytes=[IO.File]::ReadAllBytes($hap)})
    Assert-PayloadRejected { Assert-LeanTTYAppHapPayload $extraApp $hap } 'exactly one HAP'

    $bundle = @{ 'developer-id'='fixture'; 'bundle-name'='com.leantty.app'; apl='normal'; 'app-feature'='hos_normal_app' }
    $production = [pscustomobject]@{ type='release'; 'app-distribution-type'='app_gallery'; 'bundle-info'=$bundle
        'baseapp-info'=@{}; permissions=@{}; acls=@{'allowed-acls'=@('clipboard','downloads')}; 'app-privilege-capabilities'=@() }
    $review = [pscustomobject]@{ type='debug'; 'bundle-info'=$bundle; 'baseapp-info'=@{}; permissions=@{}; acls=@{'allowed-acls'=@('clipboard')} }
    $roles = Assert-LeanTTYProfileRoles $production $review
    if (-not $roles.reviewHasNoExtraCapabilities) { throw 'Profile role comparison failed' }
    $review.acls.'allowed-acls' = @('clipboard','extra')
    Assert-PayloadRejected { Assert-LeanTTYProfileRoles $production $review } 'ACLs absent from production'
    $review.acls.'allowed-acls' = @('clipboard')
    $review.type = 'release'
    Assert-PayloadRejected { Assert-LeanTTYProfileRoles $production $review } 'AppGallery production and debug'
    $review.type = 'debug'
    $review.permissions = @{ added='privilege' }
    Assert-PayloadRejected { Assert-LeanTTYProfileRoles $production $review } 'capabilities differ'
    Write-Host 'Release payload and signing-role tests passed.'
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
