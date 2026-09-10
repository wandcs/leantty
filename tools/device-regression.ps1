function Resolve-LeanTTYRegressionTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [string]$Target = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($Target)) {
        Assert-HdcTargetReady -Hdc $Hdc -Target $Target | Out-Null
        return $Target
    }
    $readyTargets = @(Get-HdcTargets -Hdc $Hdc | Where-Object {
        $_.transport -match '^(USB|TCP)$' -and $_.status -match '^(Ready|Connected)$'
    })
    $usbTargets = @($readyTargets | Where-Object { $_.transport -eq 'USB' })
    $candidates = if ($usbTargets.Count -gt 0) { $usbTargets } else { $readyTargets }
    if ($candidates.Count -eq 1) { return $candidates[0].key }
    if ($candidates.Count -eq 0) {
        throw '[infrastructure] No ready physical HarmonyOS PC found for device regression'
    }
    throw '[environment] Multiple HarmonyOS PCs are connected; pass -Target explicitly'
}

function Read-LeanTTYSharedTextFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite
    )
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally {
        $stream.Dispose()
    }
}

function Read-LeanTTYFixtureReadiness {
    param(
        [Parameter(Mandatory = $true)][string]$ControlDirectory,
        [string[]]$RequiredCredentialNames = @('password'),
        [string]$ExpectedAddress = ''
    )

    $readyPath = Join-Path $ControlDirectory 'fixture-ready'
    $credentialsPath = Join-Path $ControlDirectory 'server-credentials'
    if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $credentialsPath -PathType Leaf)) {
        return $null
    }
    $readyText = [IO.File]::ReadAllText($readyPath)
    if (-not [string]::IsNullOrWhiteSpace($ExpectedAddress)) {
        $addressPattern = '(?m)^address=' + [regex]::Escape($ExpectedAddress) + '$'
        if ($readyText -notmatch $addressPattern) { return $null }
    }
    $pidMatch = [regex]::Match($readyText, '(?m)^pid=(?<pid>\d+)$')
    if (-not $pidMatch.Success) { return $null }

    $credentials = @{}
    foreach ($line in [IO.File]::ReadAllLines($credentialsPath)) {
        $parts = $line.Split('=', 2)
        if ($parts.Count -ne 2) { throw 'SSH fixture credential file is malformed' }
        $credentials[$parts[0]] = $parts[1]
    }
    foreach ($name in $RequiredCredentialNames) {
        if (-not $credentials.ContainsKey($name) -or
            [string]::IsNullOrEmpty([string]$credentials[$name])) {
            return $null
        }
    }
    return [pscustomobject]@{
        linuxPid = [int]$pidMatch.Groups['pid'].Value
        credentials = $credentials
    }
}

function Start-LeanTTYDeviceAwakeLease {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [ValidateRange(60000, 28800000)][int]$TimeoutMilliseconds = 1800000
    )

    Invoke-HdcChecked `
        -Hdc $Hdc `
        -Target $Target `
        -Arguments @('shell', 'power-shell wakeup') `
        -Operation 'HarmonyOS regression PC wakeup' | Out-Null
    $output = Invoke-HdcChecked `
        -Hdc $Hdc `
        -Target $Target `
        -Arguments @('shell', "power-shell timeout -o $TimeoutMilliseconds") `
        -Operation 'HarmonyOS regression screen-timeout lease'
    if ($output -notmatch 'Override screen off time') {
        throw 'Unable to acquire the HarmonyOS regression screen-timeout lease'
    }
}

function Stop-LeanTTYDeviceAwakeLease {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $output = Invoke-HdcChecked `
        -Hdc $Hdc `
        -Target $Target `
        -Arguments @('shell', 'power-shell timeout -r 0') `
        -Operation 'HarmonyOS regression screen-timeout restore'
    if ($output -notmatch 'Restore screen off time') {
        throw 'Unable to restore the HarmonyOS regression screen timeout'
    }
}

function Get-LeanTTYDeviceUnlockPasswordPath {
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw 'Unable to resolve the current Windows user LocalAppData directory'
    }
    return Join-Path $localAppData 'LeanTTY\regression\device-unlock-password.txt'
}

function Assert-LeanTTYCredentialPathOutsideRepository {
    param(
        [Parameter(Mandatory = $true)][string]$CredentialPath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    $credentialFullPath = [IO.Path]::GetFullPath($CredentialPath)
    $repositoryPrefix = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/') + `
        [IO.Path]::DirectorySeparatorChar
    if ($credentialFullPath.StartsWith(
        $repositoryPrefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Device unlock credential must be stored outside the repository'
    }
}

function ConvertTo-LeanTTYDevicePasswordKeyCommand {
    param([Parameter(Mandatory = $true)][string]$Password)

    if ($Password -notmatch '^[a-z]{1,64}$') {
        throw 'Device unlock password must contain only lowercase ASCII letters'
    }
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add('uinput -K')
    foreach ($character in $Password.ToCharArray()) {
        $keyCode = 2017 + ([int]$character - [int][char]'a')
        $parts.Add("-d $keyCode -u $keyCode")
    }
    $parts.Add('-d 2054 -u 2054')
    return $parts -join ' '
}

function Start-LeanTTYRegressionApp {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$CredentialPath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    Assert-LeanTTYCredentialPathOutsideRepository `
        -CredentialPath $CredentialPath `
        -RepositoryRoot $RepositoryRoot
    $launchCommand = 'aa start -a EntryAbility -b com.leantty.app'
    $launchOutput = @(& $Hdc -t $Target shell $launchCommand 2>&1) -join "`n"
    $launchExitCode = $LASTEXITCODE
    $deviceLocked = $launchOutput -match 'Error Code:10106102|device screen is locked'
    if ($launchExitCode -ne 0 -and -not $deviceLocked) {
        throw 'LeanTTY application launch command failed before device unlock detection'
    }
    if ($launchOutput -match '(?i)\[Fail\]|error' -and -not $deviceLocked) {
        throw "LeanTTY application launch failed: $launchOutput"
    }

    $unlockResult = 'not-required'
    if ($deviceLocked) {
        if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
            throw "Locked regression PC requires local credential file: $CredentialPath"
        }
        $password = [IO.File]::ReadAllText($CredentialPath).TrimEnd("`r", "`n")
        try {
            $keyCommand = ConvertTo-LeanTTYDevicePasswordKeyCommand -Password $password
            & $Hdc -t $Target shell 'power-shell wakeup' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Unable to wake the locked regression PC' }
            & $Hdc -t $Target shell 'uinput -K -d 2050 -u 2050' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Unable to focus the regression PC unlock prompt' }
            Start-Sleep -Milliseconds 500
            & $Hdc -t $Target shell $keyCommand | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Unable to inject regression PC unlock key events' }
        } finally {
            $password = ''
            $keyCommand = ''
        }
        Start-Sleep -Milliseconds 800
        $launchOutput = @(& $Hdc -t $Target shell $launchCommand 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $launchOutput -match '(?i)\[Fail\]|error') {
            throw 'Regression PC remained locked after local credential injection'
        }
        $unlockResult = 'local-plaintext-credential'
    }

    Start-Sleep -Milliseconds 800
    $processId = (@(& $Hdc -t $Target shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or $processId -notmatch '^\d+$') {
        throw 'LeanTTY application PID is unavailable after launch'
    }
    return [pscustomobject]@{
        processId = $processId
        unlock = $unlockResult
    }
}

function Get-LeanTTYLayoutNodes {
    param([Parameter(Mandatory = $true)]$Node)

    $nodes = [Collections.Generic.List[object]]::new()
    $nodes.Add($Node)
    foreach ($child in @($Node.children)) {
        foreach ($descendant in @(Get-LeanTTYLayoutNodes -Node $child)) {
            $nodes.Add($descendant)
        }
    }
    return @($nodes)
}

function Get-LeanTTYBoundsCenter {
    param([Parameter(Mandatory = $true)][string]$Bounds)

    $match = [regex]::Match($Bounds, '^\[(?<x1>\d+),(?<y1>\d+)\]\[(?<x2>\d+),(?<y2>\d+)\]$')
    if (-not $match.Success) { throw "Invalid UI bounds: $Bounds" }
    return [pscustomobject]@{
        x = [int](([int]$match.Groups['x1'].Value + [int]$match.Groups['x2'].Value) / 2)
        y = [int](([int]$match.Groups['y1'].Value + [int]$match.Groups['y2'].Value) / 2)
    }
}

function Invoke-LeanTTYSerializedUiTest {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$Operation,
        [scriptblock]$Action = $null
    )

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $targetHash = [Convert]::ToHexString(
            $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($Target.ToLowerInvariant()))
        ).Substring(0, 16)
    } finally {
        $sha256.Dispose()
    }
    $mutex = [Threading.Mutex]::new($false, "Local\LeanTTY.UiTest.$targetHash")
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne(60000)
        } catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw '[harness] UiTest control channel remained busy for 60 seconds'
        }
        if ($null -ne $Action) { return & $Action }
        return Invoke-HdcChecked `
            -Hdc $Hdc `
            -Target $Target `
            -Arguments (@('shell', 'uitest') + $Arguments) `
            -Operation $Operation `
            -FailureDomain 'environment'
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-LeanTTYDeviceClick {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y,
        [string]$Operation = 'HarmonyOS UI click'
    )

    Invoke-LeanTTYSerializedUiTest `
        -Hdc $Hdc `
        -Target $Target `
        -Arguments @('uiInput', 'click', $X, $Y) `
        -Operation $Operation | Out-Null
}

function Get-LeanTTYDeviceLayout {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [string]$BundleName = 'com.leantty.app'
    )

    for ($captureAttempt = 1; $captureAttempt -le 2; $captureAttempt++) {
        $layout = Invoke-LeanTTYSerializedUiTest `
            -Hdc $Hdc `
            -Target $Target `
            -Arguments @('shared-layout-capture') `
            -Operation 'HarmonyOS UI layout capture' `
            -Action {
                Get-HdcUiLayout `
                    -Hdc $Hdc `
                    -Target $Target `
                    -LocalPath $LocalPath `
                    -BundleName $BundleName
            }
        if (@($layout.children).Count -gt 0) { return $layout }
        if ($captureAttempt -lt 2) { Start-Sleep -Milliseconds 500 }
    }
    throw '[environment] HarmonyOS UI layout remained empty after two captures'
}

function Get-LeanTTYTerminalInputText {
    param([Parameter(Mandatory = $true)]$Layout)

    $inputNode = @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object {
        [string]$_.attributes.hint -eq 'Terminal input'
    } | Select-Object -First 1)
    if ($inputNode.Count -ne 1) {
        throw 'LeanTTY terminal input accessibility node was not found'
    }
    $originalText = [string]$inputNode[0].attributes.originalText
    if (-not [string]::IsNullOrEmpty($originalText)) { return $originalText }
    return [string]$inputNode[0].attributes.text
}

function Get-LeanTTYTerminalInputNodes {
    param([Parameter(Mandatory = $true)]$Layout)

    # Index mounts each Tab's Panes in model order. Preserve their current
    # layout traversal order: xterm moves the hidden textarea with the cursor.
    # Geometry is not identity, and overlapping Panes require diagnosis.
    $inputs = [Collections.Generic.List[object]]::new()
    $visit = {
        param($Node)
        if ($null -eq $Node) { return }
        # UiTest still exposes descendants of retained, hidden Tab wrappers.
        # Do not filter the textarea's own opacity: xterm intentionally hides it.
        if ([string]$Node.attributes.type -eq '__Common__' -and (
                [string]$Node.attributes.opacity -eq '0.000000' -or
                [string]$Node.attributes.hitTestBehavior -eq 'HitTestMode.None')) { return }
        if ([string]$Node.attributes.hint -eq 'Terminal input') { $inputs.Add($Node) }
        foreach ($child in @($Node.children)) { & $visit $child }
    }
    & $visit $Layout
    return @($inputs)
}

function Set-LeanTTYTerminalInputFocus {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)]$InputNode,
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 30
    )

    $inputBounds = [string]$InputNode.attributes.bounds
    $center = Get-LeanTTYBoundsCenter -Bounds $inputBounds
    Invoke-LeanTTYDeviceClick `
        -Hdc $Hdc -Target $Target -X $center.x -Y $center.y `
        -Operation 'LeanTTY terminal input focus'

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $layout = Get-LeanTTYDeviceLayout `
            -Hdc $Hdc `
            -Target $Target `
            -LocalPath $LocalPath
        $focusedTarget = @(Get-LeanTTYTerminalInputNodes -Layout $layout | Where-Object {
            [string]$_.attributes.bounds -eq $inputBounds -and
            [string]$_.attributes.focused -eq 'true'
        })
        if ($focusedTarget.Count -eq 1) {
            return $layout
        }
        if ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            Start-Sleep -Milliseconds 200
        }
    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw '[environment] Timed out waiting for LeanTTY terminal input focus'
}

function Wait-LeanTTYTerminalInputCount {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [ValidateRange(1, 2)][int]$Count,
        [ValidateRange(1, 30)][int]$TimeoutSeconds = 20
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $layout = Get-LeanTTYDeviceLayout -Hdc $Hdc -Target $Target -LocalPath $LocalPath
        if (@(Get-LeanTTYTerminalInputNodes -Layout $layout).Count -eq $Count) {
            return $layout
        }
        if ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            Start-Sleep -Milliseconds 200
        }
    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw "Timed out waiting for $Count LeanTTY terminal input accessibility nodes"
}

function Wait-LeanTTYTerminalInputLayout {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [ValidateRange(1, 30)][int]$TimeoutSeconds = 20
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $layout = Get-LeanTTYDeviceLayout `
            -Hdc $Hdc `
            -Target $Target `
            -LocalPath $LocalPath
        $inputNodes = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
            [string]$_.attributes.hint -eq 'Terminal input'
        } | Select-Object -First 1)
        if ($inputNodes.Count -eq 1) { return $layout }
        if ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            Start-Sleep -Milliseconds 200
        }
    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw 'Timed out waiting for the LeanTTY terminal input accessibility node'
}

function Get-LeanTTYFocusedTextInputNodes {
    param([Parameter(Mandatory = $true)]$Layout)

    return @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object {
        [string]$_.attributes.type -eq 'textField' -and
        [string]$_.attributes.focused -eq 'true'
    })
}

function Get-LeanTTYTerminalInputWebOwner {
    param($Layout, $InputNode)

    if ($null -eq $Layout -or $null -eq $InputNode) { return $null }
    $owners = [Collections.Generic.List[object]]::new()
    $visit = {
        param($Node, $WebOwner)
        if ($null -eq $Node) { return }
        if ([string]$Node.attributes.type -eq '__Common__' -and (
                [string]$Node.attributes.opacity -eq '0.000000' -or
                [string]$Node.attributes.hitTestBehavior -eq 'HitTestMode.None')) { return }
        if ([string]$Node.attributes.type -eq 'Web') { $WebOwner = $Node }
        if ([object]::ReferenceEquals($Node, $InputNode)) {
            if ($null -ne $WebOwner) { $owners.Add($WebOwner) }
            return
        }
        foreach ($child in @($Node.children)) { & $visit $child $WebOwner }
    }
    & $visit $Layout $null
    if ($owners.Count -ne 1) { return $null }
    return $owners[0]
}

function Test-LeanTTYSameTextInputTarget {
    param(
        [Parameter(Mandatory = $true)]$ExpectedNode,
        [Parameter(Mandatory = $true)]$CurrentNode,
        $ExpectedLayout = $null,
        $CurrentLayout = $null
    )

    $expectedAttributes = $ExpectedNode.attributes
    $currentAttributes = $CurrentNode.attributes
    foreach ($attributeName in @('type', 'id', 'hint')) {
        $expectedValue = [string]$expectedAttributes.$attributeName
        if (-not [string]::IsNullOrEmpty($expectedValue) -and
            [string]$currentAttributes.$attributeName -cne $expectedValue) {
            return $false
        }
    }

    if ($null -ne $ExpectedLayout -and $null -ne $CurrentLayout -and
        [string]$expectedAttributes.hint -eq 'Terminal input') {
        $expectedWeb = Get-LeanTTYTerminalInputWebOwner -Layout $ExpectedLayout -InputNode $ExpectedNode
        $currentWeb = Get-LeanTTYTerminalInputWebOwner -Layout $CurrentLayout -InputNode $CurrentNode
        if ($null -ne $expectedWeb -or $null -ne $currentWeb) {
            if ($null -eq $expectedWeb -or $null -eq $currentWeb) { return $false }
            $expectedInputs = @(Get-LeanTTYTerminalInputNodes -Layout $expectedWeb)
            $currentInputs = @(Get-LeanTTYTerminalInputNodes -Layout $currentWeb)
            if ($expectedInputs.Count -ne 1 -or $currentInputs.Count -ne 1) { return $false }
            # Virtual DOM containers and cursor-following textarea bounds can
            # change during input. Bind to the unchanged native Web instance,
            # never another Pane at coincident coordinates or just the window.
            foreach ($name in @('hostWindowId', 'hierarchy', 'accessibilityId')) {
                $expectedValue = [string]$expectedWeb.attributes.$name
                if ([string]::IsNullOrEmpty($expectedValue) -or
                    [string]$currentWeb.attributes.$name -cne $expectedValue) { return $false }
            }
            if ([string]$expectedAttributes.hostWindowId -cne [string]$expectedWeb.attributes.hostWindowId -or
                [string]$currentAttributes.hostWindowId -cne [string]$currentWeb.attributes.hostWindowId) { return $false }
            return $true
        }
    }

    # This comparison is scoped to one input operation, not a cached locator
    # across navigation/rebuilds. Geometry can coincide across separate Panes;
    # the current window/tree target must win over bounds or regenerated IDs.
    foreach ($attributeName in @('hostWindowId', 'hierarchy')) {
        $expectedValue = [string]$expectedAttributes.$attributeName
        $currentValue = [string]$currentAttributes.$attributeName
        if ($expectedValue.Length -gt 0 -and $currentValue -cne $expectedValue) {
            return $false
        }
    }
    if (-not [string]::IsNullOrEmpty([string]$expectedAttributes.hierarchy)) {
        return $true
    }

    $expectedAccessibilityId = [string]$expectedAttributes.accessibilityId
    $currentAccessibilityId = [string]$currentAttributes.accessibilityId
    $sameOpaqueId = -not [string]::IsNullOrEmpty($expectedAccessibilityId) -and
        -not [string]::IsNullOrEmpty($currentAccessibilityId) -and
        $expectedAccessibilityId -ceq $currentAccessibilityId
    $expectedBounds = [string]$expectedAttributes.bounds
    $currentBounds = [string]$currentAttributes.bounds
    $sameGeometry = -not [string]::IsNullOrEmpty($expectedBounds) -and
        $expectedBounds -ceq $currentBounds

    # UiTest 6.0.2.3 regenerates accessibilityId between adjacent dumpLayout
    # snapshots. Legacy nodes without a tree path require a matching ID or
    # exact geometry; real current layouts also prove the tree target above.
    return $sameOpaqueId -or $sameGeometry
}

function New-LeanTTYTextInputFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('before', 'after')][string]$Phase,
        $ExpectedNode,
        [AllowEmptyCollection()][object[]]$CurrentNodes = @()
    )

    # Exception.Data is visible to every caller. Construct a whitelist here,
    # never attach a raw layout, field value, hint, identifier or content hash.
    $targets = @($CurrentNodes | Select-Object -First 4 | ForEach-Object {
        $currentNode = $_
        $attributes = [ordered]@{}
        foreach ($name in @('type', 'id', 'hint', 'hostWindowId', 'hierarchy', 'accessibilityId', 'bounds')) {
            $expectedValue = [string]$ExpectedNode.attributes.$name
            $currentValue = [string]$currentNode.attributes.$name
            $attributes[$name] = [ordered]@{
                expectedPresent = $expectedValue.Length -gt 0
                currentPresent = $currentValue.Length -gt 0
                equal = $(if ($null -ne $ExpectedNode -and
                    ($expectedValue.Length -gt 0 -or $currentValue.Length -gt 0)) {
                    $expectedValue -ceq $currentValue
                } else { $null })
            }
        }
        $paths = @($ExpectedNode, $currentNode | ForEach-Object {
            $pathMatch = [regex]::Match([string]$_.attributes.hierarchy,
                '^ROOT([0-9]{1,9})((?:,[0-9]{1,9}){0,64})$')
            [pscustomobject]@{
                valid = $pathMatch.Success
                indices = @($(if ($pathMatch.Success -and $pathMatch.Groups[2].Length -gt 0) {
                    $pathMatch.Groups[2].Value.Substring(1).Split(',') | ForEach-Object { [int]$_ }
                }))
            }
        })
        [ordered]@{
            attributes = $attributes
            expectedPath = $paths[0]
            currentPath = $paths[1]
            sameRoot = $(if ($paths[0].valid -and $paths[1].valid) {
                ([string]$ExpectedNode.attributes.hierarchy).Split(',')[0] -ceq
                    ([string]$currentNode.attributes.hierarchy).Split(',')[0]
            } else { $null })
        }
    })
    $failure = [InvalidOperationException]::new($Message)
    $failure.Data['LeanTTYTextInputFailure'] = [ordered]@{
        phase = $Phase
        expectedPresent = $null -ne $ExpectedNode
        focusedCount = $CurrentNodes.Count
        targetsTruncated = $CurrentNodes.Count -gt 4
        targets = $targets
    }
    return $failure
}

function Get-LeanTTYSingleFocusedTerminalInputNode {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [ValidateRange(1, 30)][int]$TimeoutSeconds = 10
    )

    $layout = Wait-LeanTTYTerminalInputLayout `
        -Hdc $Hdc -Target $Target -LocalPath $LocalPath -TimeoutSeconds $TimeoutSeconds
    $nodes = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
    if ($nodes.Count -ne 1) {
        throw '[environment] Expected exactly one LeanTTY terminal input'
    }
    if ([string]$nodes[0].attributes.focused -eq 'true') { return $nodes[0] }
    $focusedLayout = Set-LeanTTYTerminalInputFocus `
        -Hdc $Hdc -Target $Target -InputNode $nodes[0] `
        -LocalPath $LocalPath -TimeoutSeconds $TimeoutSeconds
    $focusedNodes = @(Get-LeanTTYTerminalInputNodes -Layout $focusedLayout | Where-Object {
            [string]$_.attributes.focused -eq 'true'
        })
    if ($focusedNodes.Count -ne 1) {
        throw '[environment] LeanTTY terminal input focus was not unique'
    }
    return $focusedNodes[0]
}

function Assert-LeanTTYLayoutExcludesValues {
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)][string[]]$Values
    )

    $layoutText = ConvertTo-Json -InputObject $Layout -Depth 100 -Compress
    foreach ($value in $Values) {
        if (-not [string]::IsNullOrEmpty($value) -and $layoutText.Contains($value)) {
            throw 'A device layout snapshot exposed secret input'
        }
    }
}

function Invoke-LeanTTYDeviceText {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Text,
        $InputNode = $null
    )

    if ($Text -match '[\r\n\x00]') {
        throw '[harness] HarmonyOS UI text input does not accept command separators'
    }

    $temporaryLayoutPath = Join-Path ([IO.Path]::GetTempPath()) (
        'leantty-focused-input-' + [Guid]::NewGuid().ToString('N') + '.json'
    )
    try {
        Invoke-LeanTTYSerializedUiTest `
            -Hdc $Hdc `
            -Target $Target `
            -Arguments @('focus-verified-inputText') `
            -Operation 'HarmonyOS focus-verified targeted UI text input' `
            -Action {
                $layout = Get-HdcUiLayout `
                    -Hdc $Hdc `
                    -Target $Target `
                    -LocalPath $temporaryLayoutPath `
                    -BundleName 'com.leantty.app' `
                    -Operation 'HarmonyOS pre-input focus layout capture'
                $focusedInputs = @(Get-LeanTTYFocusedTextInputNodes -Layout $layout)
                if ($focusedInputs.Count -ne 1) {
                    throw (New-LeanTTYTextInputFailure -Phase before -ExpectedNode $InputNode `
                        -CurrentNodes $focusedInputs `
                        -Message '[harness] HarmonyOS text input requires one current focused text field')
                }
                if ($null -ne $InputNode) {
                    if (-not (Test-LeanTTYSameTextInputTarget `
                            -ExpectedNode $InputNode -CurrentNode $focusedInputs[0])) {
                        throw (New-LeanTTYTextInputFailure -Phase before -ExpectedNode $InputNode `
                            -CurrentNodes $focusedInputs `
                            -Message '[harness] Intended HarmonyOS text target is no longer uniquely focused')
                    }
                }
                $center = Get-LeanTTYBoundsCenter `
                    -Bounds ([string]$focusedInputs[0].attributes.bounds)
                Invoke-HdcChecked `
                    -Hdc $Hdc `
                    -Target $Target `
                    -Arguments @(
                        'shell', 'uitest', 'uiInput', 'inputText', $center.x, $center.y, $Text
                    ) `
                    -Operation 'HarmonyOS focus-verified targeted UI text input' `
                    -FailureDomain 'environment' | Out-Null
                $afterLayout = Get-HdcUiLayout `
                    -Hdc $Hdc -Target $Target -LocalPath $temporaryLayoutPath `
                    -BundleName 'com.leantty.app' `
                    -Operation 'HarmonyOS post-input focus layout capture'
                $afterInputs = @(Get-LeanTTYFocusedTextInputNodes -Layout $afterLayout)
                if ($afterInputs.Count -ne 1 -or -not (Test-LeanTTYSameTextInputTarget `
                        -ExpectedNode $focusedInputs[0] -CurrentNode $afterInputs[0] `
                        -ExpectedLayout $layout -CurrentLayout $afterLayout)) {
                    throw (New-LeanTTYTextInputFailure -Phase after -ExpectedNode $focusedInputs[0] `
                        -CurrentNodes $afterInputs `
                        -Message '[harness] HarmonyOS text input changed its intended target; refusing retry or Enter')
                }
            } | Out-Null
    } finally {
        Remove-Item -LiteralPath $temporaryLayoutPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-LeanTTYDeviceKey {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][int]$KeyCode
    )

    Invoke-LeanTTYSerializedUiTest `
        -Hdc $Hdc `
        -Target $Target `
        -Arguments @('uiInput', 'keyEvent', $KeyCode) `
        -Operation "HarmonyOS key injection $KeyCode" | Out-Null
}

function Invoke-LeanTTYDeviceCtrlC {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target
    )

    & $Hdc -t $Target shell 'uinput -K -d 2072 -d 2019 -u 2019 -u 2072' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'HarmonyOS Ctrl+C injection failed' }
}

function Invoke-LeanTTYDeviceCtrlAltS {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target
    )

    & $Hdc -t $Target shell 'uinput -K -d 2072 -d 2045 -d 2035 -u 2035 -u 2045 -u 2072' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'HarmonyOS Ctrl+Alt+S injection failed' }
}

function Invoke-LeanTTYDeviceCtrlD {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target
    )

    & $Hdc -t $Target shell 'uinput -K -d 2072 -d 2020 -u 2020 -u 2072' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'HarmonyOS Ctrl+D injection failed' }
}

function Clear-LeanTTYDeviceInput {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target
    )

    Invoke-LeanTTYDeviceCtrlC -Hdc $Hdc -Target $Target
}

function Test-LeanTTYDeviceKeyFilesPresent {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$KeyName
    )

    if ($KeyName -notmatch '^ltty_reg_(?:[0-9a-f]{10}|[a-p]{10})$') {
        throw 'Device regression key name is outside the disposable-key namespace'
    }
    $sshDirectory = '/data/app/el2/100/base/com.leantty.app/haps/entry/files/.ssh'
    $privatePath = "$sshDirectory/$KeyName"
    $publicPath = "$privatePath.pub"
    $condition = (
        "if [ -e $privatePath ] || [ -e $publicPath ]; " +
        'then echo PRESENT; else echo ABSENT; fi'
    )
    $output = @(& $Hdc -t $Target shell -b com.leantty.app $condition 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect disposable key state in the LeanTTY application sandbox'
    }
    $result = ($output -join "`n").Trim()
    if ($result -eq 'PRESENT') { return $true }
    if ($result -eq 'ABSENT') { return $false }
    throw 'Unexpected disposable key-state response from the LeanTTY application sandbox'
}

function Get-LeanTTYDeviceRegressionKeyNames {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $sshDirectory = '/data/app/el2/100/base/com.leantty.app/haps/entry/files/.ssh'
    $output = @(& $Hdc -t $Target shell -b com.leantty.app "ls -1 $sshDirectory" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to enumerate disposable key state in the LeanTTY application sandbox'
    }
    return @($output | ForEach-Object { [string]$_ } | Where-Object {
        $_ -match '^ltty_reg_(?:[0-9a-f]{10}|[a-p]{10})$'
    } | Sort-Object -Unique)
}

function Get-LeanTTYTextMismatchIndex {
    param(
        [AllowEmptyString()][string]$Expected,
        [AllowEmptyString()][string]$Actual
    )

    $sharedLength = [Math]::Min($Expected.Length, $Actual.Length)
    for ($index = 0; $index -lt $sharedLength; $index++) {
        if ($Expected[$index] -cne $Actual[$index]) { return $index }
    }
    if ($Expected.Length -ne $Actual.Length) { return $sharedLength }
    return -1
}

function Get-LeanTTYAcceptanceIdleInputState {
    param([AllowEmptyString()][string]$Logs)

    $records = @([regex]::Matches(
            $Logs,
            'ACCEPTANCE_IDLE_RESULT kind=(?<kind>\d+),input=(?<input>[^\r\n]*),' +
            'completionActive=(?<completion>true|false),menuActive=(?<menu>true|false)'
        ))
    if ($records.Count -eq 0) { return $null }
    $record = $records[$records.Count - 1]
    return [pscustomobject]@{
        kind = [int]$record.Groups['kind'].Value
        input = $record.Groups['input'].Value
        completionActive = $record.Groups['completion'].Value -eq 'true'
        menuActive = $record.Groups['menu'].Value -eq 'true'
    }
}

function Wait-LeanTTYAcceptanceIdleInputState {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$ProcessId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Expected,
        [ValidateRange(1, 30)][int]$TimeoutSeconds = 10
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $lastState = $null
    $lastChangeAt = 0L
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $logs = Get-LeanTTYAppLogs -Hdc $Hdc -Target $Target -ProcessId $ProcessId
        $state = Get-LeanTTYAcceptanceIdleInputState -Logs $logs
        if ($null -ne $state) {
            if ($state.input -ceq $Expected) {
                $state | Add-Member -NotePropertyName exact -NotePropertyValue $true
                $state | Add-Member `
                    -NotePropertyName observationMs `
                    -NotePropertyValue ([int]$stopwatch.ElapsedMilliseconds)
                return $state
            }
            if ($null -eq $lastState -or $lastState.input -cne $state.input) {
                $lastState = $state
                $lastChangeAt = $stopwatch.ElapsedMilliseconds
            } elseif (($stopwatch.ElapsedMilliseconds - $lastChangeAt) -ge 1000) {
                $state | Add-Member -NotePropertyName exact -NotePropertyValue $false
                $state | Add-Member `
                    -NotePropertyName observationMs `
                    -NotePropertyValue ([int]$stopwatch.ElapsedMilliseconds)
                return $state
            }
        }
        Start-Sleep -Milliseconds 250
    }
    if ($null -eq $lastState) {
        throw '[harness] Acceptance package exposed no native command-buffer result'
    }
    $lastState | Add-Member -NotePropertyName exact -NotePropertyValue $false
    $lastState | Add-Member `
        -NotePropertyName observationMs `
        -NotePropertyValue ([int]$stopwatch.ElapsedMilliseconds)
    return $lastState
}

function Reset-LeanTTYDeviceCommandInput {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$ProcessId
    )

    Clear-LeanTTYAppLogs -Hdc $Hdc -Target $Target
    Invoke-LeanTTYDeviceCtrlC -Hdc $Hdc -Target $Target
    Wait-LeanTTYAppLog `
        -Hdc $Hdc -Target $Target -ProcessId $ProcessId `
        -Pattern 'ACCEPTANCE_IDLE_INTERRUPT cleared=true' `
        -TimeoutSeconds 10 | Out-Null
}

function Submit-LeanTTYDeviceCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$ProcessId,
        [AllowNull()][string]$Command = $null,
        [Parameter(Mandatory = $true)][scriptblock]$InputNodeProvider,
        [scriptblock]$InputPreparer = $null,
        [scriptblock]$ExpectedCommandProvider = $null,
        [Collections.IList]$ObservationSink = $null,
        [ValidateNotNullOrEmpty()][string]$Stage = 'ordinary-command',
        [ValidateRange(1, 3)][int]$MaxInputAttempts = 3
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $mismatches = [Collections.Generic.List[object]]::new()
    $observation = [ordered]@{
        stage = $Stage
        inputMethod = 'harmony-uitest-focus-verified-inputText'
        result = 'running'
        failureDomain = 'none'
        inputAttempts = 0
        inputMismatches = 0
        expectedLength = $null
        actualLength = $null
        firstMismatchIndex = $null
        enterCount = 0
        durationMs = 0
        lastProvenBoundary = 'none'
        mismatches = $mismatches
    }
    try {
        $hasStaticCommand = $PSBoundParameters.ContainsKey('Command')
        $hasDynamicCommand = (
            $PSBoundParameters.ContainsKey('ExpectedCommandProvider') -and
            $null -ne $ExpectedCommandProvider
        )
        if ($hasStaticCommand -eq $hasDynamicCommand) {
            throw '[harness] Verified command submission requires one expected-command source'
        }
        if ($null -ne $ExpectedCommandProvider -and $null -eq $InputPreparer) {
            throw '[harness] Dynamic expected commands require an input preparer'
        }
        if ($hasStaticCommand -and (
            [string]::IsNullOrEmpty($Command) -or
            $Command -match '[\r\n\x00]'
        )) {
            throw '[harness] Verified command submission does not accept command separators'
        }
        Reset-LeanTTYDeviceCommandInput -Hdc $Hdc -Target $Target -ProcessId $ProcessId
        $observation.lastProvenBoundary = 'input-reset-verified'
        for ($inputAttempt = 1; $inputAttempt -le $MaxInputAttempts; $inputAttempt++) {
            $observation.inputAttempts = $inputAttempt
            $inputNode = & $InputNodeProvider $inputAttempt
            if ($null -eq $inputNode) {
                throw '[environment] Verified command submission found no active terminal input'
            }
            Clear-LeanTTYAppLogs -Hdc $Hdc -Target $Target
            if ($null -eq $InputPreparer) {
                Invoke-LeanTTYDeviceText `
                    -Hdc $Hdc -Target $Target -Text $Command -InputNode $inputNode
            } else {
                & $InputPreparer $inputNode $inputAttempt
            }
            $expectedCommand = if ($null -eq $ExpectedCommandProvider) {
                $Command
            } else {
                & $ExpectedCommandProvider $inputAttempt
            }
            if ([string]::IsNullOrEmpty($expectedCommand) -or
                $expectedCommand -match '[\r\n\x00]') {
                throw '[harness] Input preparer produced an invalid expected command'
            }
            $observation.expectedLength = $expectedCommand.Length
            $state = Wait-LeanTTYAcceptanceIdleInputState `
                -Hdc $Hdc -Target $Target -ProcessId $ProcessId -Expected $expectedCommand `
                -TimeoutSeconds 10
            $actual = [string]$state.input
            $observation.actualLength = $actual.Length
            if ($state.exact) {
                $observation.lastProvenBoundary = 'native-command-buffer-exact'
                Clear-LeanTTYAppLogs -Hdc $Hdc -Target $Target
                $observation.enterCount = 1
                $observation.lastProvenBoundary = 'enter-dispatch-attempted'
                try {
                    Invoke-LeanTTYDeviceKey -Hdc $Hdc -Target $Target -KeyCode 2054
                } catch {
                    throw '[unknown] Enter dispatch outcome is unknown; restart the isolated scenario'
                }
                $observation.lastProvenBoundary = 'enter-dispatched'
                $submittedPattern = (
                    'ACCEPTANCE_INPUT_SUBMIT sequence=\d+,kind=command,input=' +
                    [regex]::Escape($expectedCommand) + '(?:\r?\n|$)'
                )
                try {
                    Wait-LeanTTYAppLog `
                        -Hdc $Hdc -Target $Target -ProcessId $ProcessId `
                        -Pattern $submittedPattern -TimeoutSeconds 10 | Out-Null
                } catch {
                    throw '[unknown] Command submission outcome is unknown; restart the isolated scenario'
                }
                $observation.lastProvenBoundary = 'submission-acknowledged'
                $observation.result = 'passed'
                return [pscustomobject]$observation
            }

            $mismatchIndex = Get-LeanTTYTextMismatchIndex `
                -Expected $expectedCommand -Actual $actual
            $observation.inputMismatches = $mismatches.Count + 1
            $observation.firstMismatchIndex = $mismatchIndex
            $mismatches.Add([pscustomobject]@{
                attempt = $inputAttempt
                expectedLength = $expectedCommand.Length
                actualLength = $actual.Length
                firstMismatchIndex = $mismatchIndex
            })
            Write-Host (
                '[device-command] RETRY inexact native command buffer ' +
                "attempt=$inputAttempt expectedLength=$($expectedCommand.Length) " +
                "actualLength=$($actual.Length) firstMismatchIndex=$mismatchIndex"
            ) -ForegroundColor Yellow
            Reset-LeanTTYDeviceCommandInput `
                -Hdc $Hdc -Target $Target -ProcessId $ProcessId
            $observation.lastProvenBoundary = 'input-reset-verified'
        }
        throw '[harness] UiTest could not prepare the exact native command buffer before Enter'
    } catch {
        $observation['textTargetFailure'] = $_.Exception.Data['LeanTTYTextInputFailure']
        if ($observation.result -eq 'running') {
            $message = $_.Exception.Message
            $observation.result = if ($message -match '^\[unknown\]') { 'unknown' } else { 'failed' }
            $observation.failureDomain = if ($message -match '^\[environment\]') {
                'environment'
            } elseif ($message -match '^\[infrastructure\]') {
                'infrastructure'
            } elseif ($message -match '^\[unknown\]') {
                'unknown'
            } else {
                'harness'
            }
        }
        throw
    } finally {
        $observation.durationMs = [long]$stopwatch.ElapsedMilliseconds
        if ($null -ne $ObservationSink) {
            $ObservationSink.Add([pscustomobject]$observation) | Out-Null
        }
    }
}

function Get-LeanTTYDeviceCommandAutomationSummary {
    param(
        [Parameter(Mandatory = $true)][Collections.IEnumerable]$Observations,
        [Parameter(Mandatory = $true)][ValidateSet('passed', 'failed', 'unknown')]
        [string]$BusinessVerdict,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]
        [string]$BusinessPostcondition
    )

    $records = @($Observations)
    $unknownCount = @($records | Where-Object { $_.result -eq 'unknown' }).Count
    $harnessFailureCount = @($records | Where-Object {
        $_.result -eq 'failed' -and $_.failureDomain -eq 'harness'
    }).Count
    $externalFailureCount = @($records | Where-Object {
        $_.result -eq 'failed' -and $_.failureDomain -ne 'harness'
    }).Count
    $retriedCount = @($records | Where-Object {
        $_.result -eq 'passed' -and $_.inputAttempts -gt 1
    }).Count
    $stability = if ($unknownCount -gt 0) {
        'unknown'
    } elseif ($harnessFailureCount -gt 0) {
        'failed-harness'
    } elseif ($externalFailureCount -gt 0) {
        'not-assessed'
    } elseif ($retriedCount -gt 0) {
        'flaky-harness'
    } elseif ($records.Count -gt 0) {
        'stable'
    } else {
        'not-exercised'
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        businessVerdict = $BusinessVerdict
        businessPostcondition = $BusinessPostcondition
        harnessStability = $stability
        inputMethod = 'harmony-uitest-focus-verified-inputText'
        commandCount = $records.Count
        inputAttemptCount = [int](($records | Measure-Object -Property inputAttempts -Sum).Sum)
        inputMismatchCount = [int](($records | Measure-Object -Property inputMismatches -Sum).Sum)
        enterCount = [int](($records | Measure-Object -Property enterCount -Sum).Sum)
        commands = $records
    }
}

function Clear-LeanTTYAppLogs {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target
    )

    Invoke-HdcChecked `
        -Hdc $Hdc `
        -Target $Target `
        -Arguments @('shell', 'hilog -r -t app') `
        -Operation 'HarmonyOS application log clear' | Out-Null
}

function Get-LeanTTYAppLogs {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$ProcessId
    )

    $primary = Invoke-HdcChecked `
        -Hdc $Hdc `
        -Target $Target `
        -Arguments @(
            'shell',
            (
                "hilog -z 500 -t app -P $ProcessId " +
                '-T SessionViewModel,KeyCommandService,SshClient,FileTransferClient,EntryAbility,IndexPage,' +
                'TerminalSurfaceController,TerminalBridge,AppViewModel,BackgroundBellNotification'
            )
        ) `
        -Operation 'HarmonyOS application log query'
    $mosh = Invoke-HdcChecked `
        -Hdc $Hdc `
        -Target $Target `
        -Arguments @('shell', "hilog -z 500 -t app -P $ProcessId -T MoshClient") `
        -Operation 'HarmonyOS Mosh application log query'
    return $primary + "`n" + $mosh
}

function Wait-LeanTTYAppLog {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$ProcessId,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 10
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $logs = Get-LeanTTYAppLogs -Hdc $Hdc -Target $Target -ProcessId $ProcessId
        if ($logs -match $Pattern) { return $logs }
        Start-Sleep -Milliseconds 1000
    }
    throw "Timed out waiting for LeanTTY device state: $Pattern"
}

function Invoke-LeanTTYDevicePhysicalKey {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][int]$KeyCode
    )

    $failure = $null
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $Hdc
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        foreach ($argument in @('-t', $Target, 'shell', "uinput -K -d $KeyCode -u $KeyCode")) {
            [void]$startInfo.ArgumentList.Add($argument)
        }

        $process = [Diagnostics.Process]::Start($startInfo)
        try {
            if (-not $process.WaitForExit(5000)) {
                $failure = "timed out on attempt $attempt"
                $process.Kill($true)
                $process.WaitForExit()
            } elseif ($process.ExitCode -eq 0) {
                return
            } else {
                $failure = "exited with code $($process.ExitCode) on attempt $attempt"
            }
        } finally {
            $process.Dispose()
        }
        Start-Sleep -Milliseconds 250
    }
    throw "HarmonyOS physical key injection failed for key ${KeyCode}: $failure"
}

function Resolve-LeanTTYAuthenticationObservation {
    param(
        [AllowEmptyString()][string]$SnapshotLogs = '',
        [AllowEmptyString()][string]$LiveLogs = '',
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    $snapshotObserved = $SnapshotLogs -match $Pattern
    $liveObserved = $LiveLogs -match $Pattern
    if (-not $snapshotObserved -and -not $liveObserved) { return $null }
    $combined = $SnapshotLogs + "`n" + $LiveLogs
    $stateMatch = [regex]::Match($combined, $Pattern)
    return [pscustomobject]@{
        state = $stateMatch.Value
        snapshotObserved = $snapshotObserved
        liveObserved = $liveObserved
        logs = $combined
    }
}

function Resolve-LeanTTYDialogButtonTexts {
    param([Parameter(Mandatory = $true)][string]$ButtonText)

    switch ($ButtonText.Trim().ToLowerInvariant()) {
        'delete key' { return @('Delete key', '删除密钥') }
        'close pane' { return @('Close pane', '关闭分屏') }
        default { return @($ButtonText) }
    }
}

function Invoke-LeanTTYDialogButton {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$ButtonText,
        [Parameter(Mandatory = $true)][string]$LayoutPath
    )

    $layout = Get-LeanTTYDeviceLayout -Hdc $Hdc -Target $Target -LocalPath $LayoutPath
    $buttonTexts = @(Resolve-LeanTTYDialogButtonTexts -ButtonText $ButtonText)
    $buttonNode = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
        $buttonTexts -contains [string]$_.attributes.text -or
        $buttonTexts -contains [string]$_.attributes.originalText
    } | Select-Object -First 1)
    if ($buttonNode.Count -ne 1) { throw "Dialog button was not found: $ButtonText" }
    $center = Get-LeanTTYBoundsCenter -Bounds ([string]$buttonNode[0].attributes.bounds)
    Invoke-LeanTTYDeviceClick `
        -Hdc $Hdc -Target $Target -X $center.x -Y $center.y `
        -Operation "LeanTTY dialog button '$ButtonText'"
}

function Save-LeanTTYDeviceScreenshot {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$LocalPath
    )

    $remotePath = '/data/local/tmp/leantty-screen-' + [Guid]::NewGuid().ToString('N') + '.png'
    try {
        Invoke-LeanTTYSerializedUiTest `
            -Hdc $Hdc -Target $Target `
            -Arguments @('screenCap', '-p', $remotePath) `
            -Operation 'HarmonyOS screenshot capture' | Out-Null
        Invoke-HdcChecked `
            -Hdc $Hdc -Target $Target `
            -Arguments @('file', 'recv', $remotePath, $LocalPath) `
            -Operation 'HarmonyOS screenshot transfer' `
            -FailureDomain 'environment' | Out-Null
        if (-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)) {
            throw 'HarmonyOS screenshot transfer produced no local file'
        }
    } finally {
        & $Hdc -t $Target shell rm -f $remotePath 2>$null | Out-Null
    }
}

function New-LeanTTYRegressionSecret {
    return 't' + [Guid]::NewGuid().ToString('N').Substring(0, 23)
}
function Wait-LeanTTYDeviceKnownHostAbsent {
    param(
        [Parameter(Mandatory = $true)][string]$Hdc,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port,
        [ValidateRange(1, 30)][int]$TimeoutSeconds = 8
    )
    # Read the projection only; callers own the single command and prove local mode.
    # The command submission ACK precedes the durable known-host operation.
    $path = '/data/app/el2/100/base/com.leantty.app/haps/entry/files/.ssh/known_hosts'
    $endpoint = "[127.0.0.1]:$Port"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $content = Invoke-HdcChecked -Hdc $Hdc -Target $Target -Arguments @(
            'shell', '-b', 'com.leantty.app', "cat $path && printf '\nLEANTTY_KNOWN_HOST_READ_OK\n'"
        ) -Operation 'Audit temporary known-host removal'
        if ($content -notmatch '(?m)^LEANTTY_KNOWN_HOST_READ_OK\r?$') {
            throw '[infrastructure] Known-host projection read was not confirmed'
        }
        $present = @($content -split "`n" | Where-Object {
            $hosts = (($_.Trim() -split '\s+')[0]) -split ','
            $hosts -ccontains $endpoint
        }).Count -gt 0
        if (-not $present) { return }
        Start-Sleep -Milliseconds 250
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw '[cleanup] Temporary known-host entry remained after the single removal command'
}
