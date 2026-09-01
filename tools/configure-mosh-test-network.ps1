<#
.SYNOPSIS
  Configure the persistent Windows network boundary for LeanTTY Mosh tests.
.DESCRIPTION
  Enable and Disable require an Administrator PowerShell. Status is read-only
  and is designed for the normal non-elevated development loop. The script
  owns only one TCP portproxy and four current firewall rule names. Two exact
  legacy UDP rule names are recognized only for the 60042-to-default-range
  migration. The script refuses to overwrite drifted or conflicting state.
#>
[CmdletBinding()]
param(
    [ValidateSet('Enable', 'Status', 'Disable')]
    [string]$Mode = 'Status',
    [string]$ServerAddress = '192.168.1.4',
    [ValidateRange(1024, 65535)][int]$ExternalSshPort = 2223,
    [string]$BackendAddress = '127.0.0.1',
    [ValidateRange(1024, 65535)][int]$BackendSshPort = 32223,
    [string]$RemoteScope = '192.168.1.0/24',
    [string]$OutputPath = '',
    [string]$ErrorPath = ''
)

$ErrorActionPreference = 'Stop'
$hyperVCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
$windowsSshRuleName = 'LeanTTY-Mosh-Test-SSH-2223'
$windowsUdpRuleName = 'LeanTTY-Mosh-Test-UDP-60000-61000'
$hyperVSshRuleName = $windowsSshRuleName + '-HyperV'
$hyperVUdpRuleName = $windowsUdpRuleName + '-HyperV'
$legacyWindowsUdpRuleName = 'LeanTTY-Mosh-Test-UDP-60042'
$legacyHyperVUdpRuleName = $legacyWindowsUdpRuleName + '-HyperV'
$legacyUdpPort = '60042'
$udpPortRange = '60000-61000'

function Assert-IPv4Address {
    param([Parameter(Mandatory = $true)][string]$Value, [string]$Name)
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Value, [ref]$parsed) -or
        $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw "$Name must be one IPv4 address"
    }
}

function Assert-Administrator {
    $principal = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "$Mode requires an Administrator PowerShell; Status does not"
    }
}

function ConvertTo-ComparableList {
    param($Value)
    return @($Value | ForEach-Object { [string]$_ } | Sort-Object -Unique)
}

function Test-ComparableList {
    param($Actual, [string[]]$Expected)
    $actualValues = @(ConvertTo-ComparableList $Actual)
    $expectedValues = @(ConvertTo-ComparableList $Expected)
    return ($actualValues.Count -eq $expectedValues.Count -and
        (@(Compare-Object $actualValues $expectedValues).Count -eq 0))
}

function ConvertTo-CanonicalNetwork {
    param([Parameter(Mandatory = $true)][string]$Value)
    $parts = $Value.Split('/', 2)
    if ($parts.Count -ne 2) { return $Value }
    $prefix = 0
    if ([int]::TryParse($parts[1], [ref]$prefix)) {
        return "$($parts[0])/$prefix"
    }
    $mask = $null
    if (-not [Net.IPAddress]::TryParse($parts[1], [ref]$mask)) { return $Value }
    $bits = -join ($mask.GetAddressBytes() | ForEach-Object {
        [Convert]::ToString($_, 2).PadLeft(8, '0')
    })
    if ($bits -notmatch '^1*0*$') { return $Value }
    return "$($parts[0])/$($bits.IndexOf('0') -replace '^-1$', '32')"
}

function Test-NetworkList {
    param($Actual, [string[]]$Expected)
    $actualValues = @($Actual | ForEach-Object {
        ConvertTo-CanonicalNetwork ([string]$_)
    } | Sort-Object -Unique)
    $expectedValues = @($Expected | ForEach-Object {
        ConvertTo-CanonicalNetwork ([string]$_)
    } | Sort-Object -Unique)
    return ($actualValues.Count -eq $expectedValues.Count -and
        (@(Compare-Object $actualValues $expectedValues).Count -eq 0))
}

function Get-PortProxyState {
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($line in @(& netsh interface portproxy show v4tov4)) {
        $match = [regex]::Match(
            [string]$line,
            '^\s*(?<listen>\d+(?:\.\d+){3})\s+(?<listenPort>\d+)\s+' +
                '(?<connect>\d+(?:\.\d+){3})\s+(?<connectPort>\d+)\s*$'
        )
        if ($match.Success) {
            $entries.Add([pscustomobject]@{
                listenAddress = $match.Groups['listen'].Value
                listenPort = [int]$match.Groups['listenPort'].Value
                connectAddress = $match.Groups['connect'].Value
                connectPort = [int]$match.Groups['connectPort'].Value
            }) | Out-Null
        }
    }
    $sameListener = @($entries | Where-Object {
        $_.listenAddress -eq $ServerAddress -and $_.listenPort -eq $ExternalSshPort
    })
    $exact = @($sameListener | Where-Object {
        $_.connectAddress -eq $BackendAddress -and $_.connectPort -eq $BackendSshPort
    })
    return [pscustomobject]@{
        state = if ($exact.Count -eq 1 -and $sameListener.Count -eq 1) {
            'ready'
        } elseif ($sameListener.Count -eq 0) {
            'missing'
        } else {
            'drift'
        }
        observed = $sameListener
    }
}

function Get-WindowsRuleState {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Protocol,
        [Parameter(Mandatory = $true)][string]$Port
    )
    $rules = @(Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue)
    if ($rules.Count -eq 0) { return 'missing' }
    if ($rules.Count -ne 1) { return 'drift' }
    $rule = $rules[0]
    $portFilter = @($rule | Get-NetFirewallPortFilter)
    $addressFilter = @($rule | Get-NetFirewallAddressFilter)
    $protocolMatches = $portFilter.Count -eq 1 -and
        ([string]$portFilter[0].Protocol -eq $Protocol -or
            [string]$portFilter[0].Protocol -eq $(if ($Protocol -eq 'TCP') { '6' } else { '17' }))
    if ([string]$rule.Direction -eq 'Inbound' -and
        [string]$rule.Action -eq 'Allow' -and
        [string]$rule.Enabled -eq 'True' -and
        [string]$rule.Profile -eq 'Any' -and
        $protocolMatches -and
        [string]$portFilter[0].LocalPort -eq $Port -and
        $addressFilter.Count -eq 1 -and
        (Test-ComparableList $addressFilter[0].LocalAddress @($ServerAddress)) -and
        (Test-NetworkList $addressFilter[0].RemoteAddress @($RemoteScope))) {
        return 'ready'
    }
    return 'drift'
}

function Get-HyperVRuleState {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Protocol,
        [Parameter(Mandatory = $true)][string]$Port
    )
    if ($null -eq (Get-Command Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue)) {
        return 'unavailable'
    }
    $rules = @(Get-NetFirewallHyperVRule -Name $Name -ErrorAction SilentlyContinue)
    if ($rules.Count -eq 0) { return 'missing' }
    if ($rules.Count -ne 1) { return 'drift' }
    $rule = $rules[0]
    $protocolValue = [string]$rule.Protocol
    $protocolMatches = $protocolValue -eq $Protocol -or
        $protocolValue -eq $(if ($Protocol -eq 'TCP') { '6' } else { '17' })
    $creatorMatches = ([string]$rule.VMCreatorId).Trim('{}') -eq
        $hyperVCreatorId.Trim('{}')
    if ([string]$rule.Direction -in @('Inbound', '1') -and
        [string]$rule.Action -in @('Allow', '2') -and
        [string]$rule.Enabled -in @('True', '1') -and
        $creatorMatches -and
        $protocolMatches -and
        (Test-ComparableList $rule.LocalPorts @($Port)) -and
        (Test-ComparableList $rule.LocalAddresses @($ServerAddress)) -and
        (Test-NetworkList $rule.RemoteAddresses @($RemoteScope))) {
        return 'ready'
    }
    return 'drift'
}

function Get-NetworkState {
    $portProxy = Get-PortProxyState
    $windowsSsh = Get-WindowsRuleState -Name $windowsSshRuleName -Protocol TCP `
        -Port $ExternalSshPort.ToString()
    $windowsUdp = Get-WindowsRuleState -Name $windowsUdpRuleName -Protocol UDP `
        -Port $udpPortRange
    $hyperVSsh = Get-HyperVRuleState -Name $hyperVSshRuleName -Protocol TCP `
        -Port $ExternalSshPort.ToString()
    $hyperVUdp = Get-HyperVRuleState -Name $hyperVUdpRuleName -Protocol UDP `
        -Port $udpPortRange
    $legacyWindowsUdp = Get-WindowsRuleState -Name $legacyWindowsUdpRuleName `
        -Protocol UDP -Port $legacyUdpPort
    $legacyHyperVUdp = Get-HyperVRuleState -Name $legacyHyperVUdpRuleName `
        -Protocol UDP -Port $legacyUdpPort
    $components = [ordered]@{
        tcpPortProxy = $portProxy.state
        windowsSshFirewall = $windowsSsh
        windowsUdpFirewall = $windowsUdp
        hyperVSshFirewall = $hyperVSsh
        hyperVUdpFirewall = $hyperVUdp
    }
    $legacy = [ordered]@{
        windowsUdpFirewall60042 = $legacyWindowsUdp
        hyperVUdpFirewall60042 = $legacyHyperVUdp
    }
    return [pscustomobject]@{
        schemaVersion = 1
        mode = $Mode
        ready = (@($components.Values | Where-Object { $_ -ne 'ready' }).Count -eq 0 -and
            @($legacy.Values | Where-Object { $_ -notin @('missing', 'unavailable') }).Count -eq 0)
        endpoint = [ordered]@{
            ssh = "${ServerAddress}:$ExternalSshPort/TCP"
            sshBackend = "${BackendAddress}:$BackendSshPort/TCP"
            mosh = "${ServerAddress}:$udpPortRange/UDP"
            remoteScope = $RemoteScope
        }
        components = $components
        legacy = $legacy
        ownedNames = @(
            $windowsSshRuleName,
            $windowsUdpRuleName,
            $hyperVSshRuleName,
            $hyperVUdpRuleName,
            $legacyWindowsUdpRuleName,
            $legacyHyperVUdpRuleName
        )
        existingSsh2222Untouched = $true
    }
}

function Assert-NoDrift {
    param($State)
    $drift = @($State.components.GetEnumerator() | Where-Object { $_.Value -eq 'drift' })
    $drift += @($State.legacy.GetEnumerator() | Where-Object { $_.Value -eq 'drift' })
    if ($drift.Count -gt 0) {
        throw ('Refusing to overwrite drifted Mosh test network state: ' +
            (($drift | ForEach-Object Key) -join ', '))
    }
}

function Enable-NetworkState {
    Assert-Administrator
    $created = [Collections.Generic.List[string]]::new()
    $migratedLegacy = [Collections.Generic.List[string]]::new()
    try {
        $before = Get-NetworkState
        Assert-NoDrift $before
        if ($before.components.tcpPortProxy -eq 'missing') {
            & netsh interface portproxy add v4tov4 listenaddress=$ServerAddress `
                listenport=$ExternalSshPort connectaddress=$BackendAddress `
                connectport=$BackendSshPort | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Unable to add the Mosh test TCP portproxy' }
            $created.Add('tcpPortProxy') | Out-Null
        }
        foreach ($definition in @(
            @{ Key = 'windowsSshFirewall'; Name = $windowsSshRuleName; Protocol = 'TCP'; Port = $ExternalSshPort },
            @{ Key = 'windowsUdpFirewall'; Name = $windowsUdpRuleName; Protocol = 'UDP'; Port = $udpPortRange }
        )) {
            if ($before.components[$definition.Key] -eq 'missing') {
                New-NetFirewallRule -Name $definition.Name -DisplayName $definition.Name `
                    -Direction Inbound -Action Allow -Enabled True -Profile Any `
                    -Protocol $definition.Protocol -LocalAddress $ServerAddress `
                    -LocalPort $definition.Port -RemoteAddress $RemoteScope | Out-Null
                $created.Add($definition.Key) | Out-Null
            }
        }
        if ($before.components.hyperVSshFirewall -eq 'unavailable' -or
            $before.components.hyperVUdpFirewall -eq 'unavailable') {
            throw 'Hyper-V firewall cmdlets are required for the mirrored WSL test path'
        }
        foreach ($definition in @(
            @{ Key = 'hyperVSshFirewall'; Name = $hyperVSshRuleName; Protocol = 'TCP'; Port = $ExternalSshPort },
            @{ Key = 'hyperVUdpFirewall'; Name = $hyperVUdpRuleName; Protocol = 'UDP'; Port = $udpPortRange }
        )) {
            if ($before.components[$definition.Key] -eq 'missing') {
                New-NetFirewallHyperVRule -Name $definition.Name -DisplayName $definition.Name `
                    -Direction Inbound -Action Allow -Enabled True -VMCreatorId $hyperVCreatorId `
                    -Protocol $definition.Protocol -LocalAddresses $ServerAddress `
                    -LocalPorts $definition.Port -RemoteAddresses $RemoteScope | Out-Null
                $created.Add($definition.Key) | Out-Null
            }
        }
        $interim = Get-NetworkState
        Assert-NoDrift $interim
        $currentNotReady = @(
            $interim.components.Values | Where-Object { $_ -ne 'ready' }
        )
        if ($currentNotReady.Count -gt 0) {
            throw ('Mosh test network range state did not become ready: ' +
                (ConvertTo-Json $interim.components -Compress))
        }
        if ($interim.legacy.hyperVUdpFirewall60042 -eq 'ready') {
            Remove-NetFirewallHyperVRule -Name $legacyHyperVUdpRuleName
            $migratedLegacy.Add('hyperVUdpFirewall60042') | Out-Null
        }
        if ($interim.legacy.windowsUdpFirewall60042 -eq 'ready') {
            Remove-NetFirewallRule -Name $legacyWindowsUdpRuleName
            $migratedLegacy.Add('windowsUdpFirewall60042') | Out-Null
        }
        $after = Get-NetworkState
        if (-not $after.ready) {
            throw ('Mosh test network state did not become ready: ' +
                (ConvertTo-Json $after.components -Compress))
        }
        return $after
    } catch {
        for ($index = $created.Count - 1; $index -ge 0; $index--) {
            $key = $created[$index]
            switch ($key) {
                'hyperVUdpFirewall' { Remove-NetFirewallHyperVRule -Name $hyperVUdpRuleName -ErrorAction SilentlyContinue }
                'hyperVSshFirewall' { Remove-NetFirewallHyperVRule -Name $hyperVSshRuleName -ErrorAction SilentlyContinue }
                'windowsUdpFirewall' { Remove-NetFirewallRule -Name $windowsUdpRuleName -ErrorAction SilentlyContinue }
                'windowsSshFirewall' { Remove-NetFirewallRule -Name $windowsSshRuleName -ErrorAction SilentlyContinue }
                'tcpPortProxy' {
                    & netsh interface portproxy delete v4tov4 listenaddress=$ServerAddress `
                        listenport=$ExternalSshPort | Out-Null
                }
            }
        }
        for ($index = $migratedLegacy.Count - 1; $index -ge 0; $index--) {
            switch ($migratedLegacy[$index]) {
                'windowsUdpFirewall60042' {
                    New-NetFirewallRule -Name $legacyWindowsUdpRuleName `
                        -DisplayName $legacyWindowsUdpRuleName -Direction Inbound `
                        -Action Allow -Enabled True -Profile Any -Protocol UDP `
                        -LocalAddress $ServerAddress -LocalPort $legacyUdpPort `
                        -RemoteAddress $RemoteScope | Out-Null
                }
                'hyperVUdpFirewall60042' {
                    New-NetFirewallHyperVRule -Name $legacyHyperVUdpRuleName `
                        -DisplayName $legacyHyperVUdpRuleName -Direction Inbound `
                        -Action Allow -Enabled True -VMCreatorId $hyperVCreatorId `
                        -Protocol UDP -LocalAddresses $ServerAddress `
                        -LocalPorts $legacyUdpPort -RemoteAddresses $RemoteScope | Out-Null
                }
            }
        }
        throw
    }
}

function Disable-NetworkState {
    Assert-Administrator
    $before = Get-NetworkState
    Assert-NoDrift $before
    if ($before.legacy.hyperVUdpFirewall60042 -eq 'ready') {
        Remove-NetFirewallHyperVRule -Name $legacyHyperVUdpRuleName
    }
    if ($before.legacy.windowsUdpFirewall60042 -eq 'ready') {
        Remove-NetFirewallRule -Name $legacyWindowsUdpRuleName
    }
    if ($before.components.hyperVUdpFirewall -eq 'ready') {
        Remove-NetFirewallHyperVRule -Name $hyperVUdpRuleName
    }
    if ($before.components.hyperVSshFirewall -eq 'ready') {
        Remove-NetFirewallHyperVRule -Name $hyperVSshRuleName
    }
    if ($before.components.windowsUdpFirewall -eq 'ready') {
        Remove-NetFirewallRule -Name $windowsUdpRuleName
    }
    if ($before.components.windowsSshFirewall -eq 'ready') {
        Remove-NetFirewallRule -Name $windowsSshRuleName
    }
    if ($before.components.tcpPortProxy -eq 'ready') {
        & netsh interface portproxy delete v4tov4 listenaddress=$ServerAddress `
            listenport=$ExternalSshPort | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to delete the Mosh test TCP portproxy' }
    }
    $after = Get-NetworkState
    $remaining = @($after.components.Values | Where-Object { $_ -notin @('missing', 'unavailable') })
    $remaining += @($after.legacy.Values | Where-Object { $_ -notin @('missing', 'unavailable') })
    if ($remaining.Count -gt 0) { throw 'Mosh test network state remains after Disable' }
    return $after
}

try {
    Assert-IPv4Address -Value $ServerAddress -Name ServerAddress
    Assert-IPv4Address -Value $BackendAddress -Name BackendAddress
    if ($RemoteScope -notmatch '^\d+(?:\.\d+){3}/(?:[1-9]|[12]\d|3[0-2])$') {
        throw 'RemoteScope must be one IPv4 CIDR'
    }
    if ($ExternalSshPort -eq $BackendSshPort) {
        throw 'BackendSshPort must differ from ExternalSshPort'
    }
    $hostAddress = @(Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ServerAddress `
        -ErrorAction SilentlyContinue)
    if ($hostAddress.Count -ne 1) {
        throw "ServerAddress is not assigned to this Windows host: $ServerAddress"
    }

    $state = switch ($Mode) {
        'Enable' { Enable-NetworkState }
        'Disable' { Disable-NetworkState }
        default { Get-NetworkState }
    }
    $json = ConvertTo-Json $state -Depth 8
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
        $parent = Split-Path $resolvedOutput -Parent
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        [IO.File]::WriteAllText(
            $resolvedOutput,
            $json + "`n",
            [Text.UTF8Encoding]::new($false)
        )
    }
    $json
} catch {
    if (-not [string]::IsNullOrWhiteSpace($ErrorPath)) {
        $resolvedError = [IO.Path]::GetFullPath($ErrorPath)
        $parent = Split-Path $resolvedError -Parent
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        [IO.File]::WriteAllText(
            $resolvedError,
            $_.Exception.Message + "`n",
            [Text.UTF8Encoding]::new($false)
        )
    }
    throw
}
