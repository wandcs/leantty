<#
.SYNOPSIS
  Start the controlled SSH authentication fixture with temporary credentials.
.DESCRIPTION
  Creates random credentials under the current user's temporary directory,
  starts the repository-only russh server in WSL, and removes the credentials
  when the server exits. The fixture is not part of the native library or HAP.
#>
[CmdletBinding()]
param(
    [string]$ListenAddress = '0.0.0.0:22222',
    [ValidateRange(1, 3600)]
    [int]$RunSeconds = 900,
    [ValidateRange(0, 5000)]
    [int]$SftpDelayMilliseconds = 0,
    [ValidateSet('none', 'put-write-remove', 'permission-denied', 'rename-unsupported', 'unavailable')]
    [string]$SftpFault = 'none',
    [string]$ControlDirectory = '',
    [string]$Distribution = $env:LEANTTY_WSL_DISTRO
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'rust-wsl.ps1')

function New-FixtureSecret {
    $bytes = [byte[]]::new(16)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $characters = [char[]]::new($bytes.Length * 2)
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        $characters[$index * 2] = [char](97 + ($bytes[$index] -shr 4))
        $characters[$index * 2 + 1] = [char](97 + ($bytes[$index] -band 15))
    }
    return -join $characters
}

$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + `
    [IO.Path]::DirectorySeparatorChar
if ([string]::IsNullOrWhiteSpace($ControlDirectory)) {
    $fixtureDirectory = Join-Path $temporaryRoot ('leantty-ssh-auth-' + [guid]::NewGuid().ToString('N'))
} else {
    $fixtureDirectory = [IO.Path]::GetFullPath($ControlDirectory)
    if (-not $fixtureDirectory.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'SSH fixture control directory must be inside the system temporary directory'
    }
    if (Test-Path -LiteralPath $fixtureDirectory) {
        throw "SSH fixture control directory already exists: $fixtureDirectory"
    }
}
$credentialsPath = Join-Path $fixtureDirectory 'server-credentials'
$readyPath = Join-Path $fixtureDirectory 'fixture-ready'
New-Item -ItemType Directory -Path $fixtureDirectory | Out-Null

try {
    $lines = @(
        'password=' + (New-FixtureSecret)
        'account=' + (New-FixtureSecret)
        'token=' + (New-FixtureSecret)
        'second_token=' + (New-FixtureSecret)
    )
    [IO.File]::WriteAllLines($credentialsPath, $lines, [Text.UTF8Encoding]::new($false))
    $lines = $null

    $wslCredentialsPath = ConvertTo-LeanTTYWslPath -WindowsPath $credentialsPath -Distribution $Distribution
    $wslReadyPath = ConvertTo-LeanTTYWslPath -WindowsPath $readyPath -Distribution $Distribution
    Write-Host "Temporary fixture directory: $fixtureDirectory" -ForegroundColor Yellow
    Write-Host 'Credentials are available only in server-credentials while this process is running.'
    Write-Host ('Users: password, publickey, password-kbdint, publickey-password, ' +
        'publickey-kbdint, kbdint-multiround, kbdint-zero, unsupported, channel-denied')
    Write-Host 'Stop with Ctrl+C; temporary credentials will be removed.'

    Invoke-LeanTTYRustWsl -RepoRoot $repoRoot -Distribution $Distribution -CargoArguments @(
        'run', '--locked', '--offline', '--manifest-path', './leantty_ssh/Cargo.toml',
        '-p', 'leantty-ssh-auth-fixture', '--', $ListenAddress, $wslCredentialsPath,
        $RunSeconds.ToString([Globalization.CultureInfo]::InvariantCulture), $wslReadyPath,
        $SftpDelayMilliseconds.ToString([Globalization.CultureInfo]::InvariantCulture),
        $SftpFault
    )
} finally {
    if (Test-Path -LiteralPath $fixtureDirectory) {
        Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force
    }
}
