# Downloads fixture for verify-host-identity-pc.ps1. The system owns grants;
# this scenario temporarily changes only LeanTTY's Downloads checkbox.
function Get-HostIdentityDownloadsPermission {
    $raw = Invoke-HdcChecked -Hdc $hdc -Target $Target `
        -Arguments @('shell', 'atm dump -t -b com.leantty.app') `
        -Operation 'Read LeanTTY Downloads grant'
    try { $state = $raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw '[harness] Downloads permission query was not structured JSON' }
    $permissions = @($state.permStateList | Where-Object {
        $_.permissionName -ceq 'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY'
    })
    if ($state.bundleName -cne 'com.leantty.app' -or $state.instIndex -ne 0 -or
        $permissions.Count -ne 1 -or $permissions[0].grantStatus -notin @(-1, 0)) {
        throw '[harness] Downloads permission state is missing or ambiguous'
    }
    return ($permissions[0].grantStatus -eq 0)
}

function Get-HostIdentityDownloadsLayout {
    param([string]$Stage)
    Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -BundleName '' `
        -LocalPath (Join-Path $EvidenceDirectory "$Stage.json")
}

function Find-HostIdentitySettingsNode {
    param($Layout, [string]$Id = '', [string]$Text = '', [string]$Type = '')
    $nodes = @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object {
        (($Id -and $_.attributes.id -ceq $Id) -or ($Text -and $_.attributes.text -ceq $Text)) -and
        (-not $Type -or $_.attributes.type -ceq $Type)
    })
    if ($nodes.Count -ne 1) { throw "[harness] Downloads settings control is missing or ambiguous: id=$Id text=$Text type=$Type" }
    return $nodes[0]
}

function Click-HostIdentitySettingsNode {
    param($Node)
    $center = Get-LeanTTYBoundsCenter -Bounds $Node.attributes.bounds
    Invoke-LeanTTYDeviceClick -Hdc $hdc -Target $Target -X $center.x -Y $center.y `
        -Operation 'Operate the identified Downloads settings control'
}

function Get-HostIdentityDownloadsCheckbox {
    param($Layout)
    Find-HostIdentitySettingsNode -Layout $Layout -Text '文件夹权限' -Type Text | Out-Null
    Find-HostIdentitySettingsNode -Layout $Layout -Text 'LeanTTY' -Type Text | Out-Null
    $checkbox = Find-HostIdentitySettingsNode -Layout $Layout -Id 'CheckBox_DOWNLOAD_DIRECTORY' -Type Checkbox
    if ($checkbox.attributes.text -cne 'DOWNLOAD_DIRECTORY' -or $checkbox.attributes.checked -notin @('true', 'false')) {
        throw '[harness] Downloads checkbox has an invalid state'
    }
    return $checkbox
}

function Get-HostIdentityStableSettingsNode {
    param([string]$Stage, [string]$Text, [string]$PageText)
    $previousBounds = ''
    for ($sample = 1; $sample -le 4; $sample++) {
        $layout = Get-HostIdentityDownloadsLayout -Stage "$Stage-$sample"
        Find-HostIdentitySettingsNode -Layout $layout -Text $PageText | Out-Null
        $node = Find-HostIdentitySettingsNode -Layout $layout -Text $Text -Type Text
        $bounds = [string]$node.attributes.bounds
        if ($bounds -and $bounds -ceq $previousBounds) { return $node }
        $previousBounds = $bounds
    }
    throw '[environment] Downloads settings navigation did not settle; no click sent'
}

function Open-HostIdentityDownloadsSettings {
    $output = Invoke-HdcChecked -Hdc $hdc -Target $Target `
        -Arguments @('shell', 'aa start -b com.huawei.hmos.settings -a com.huawei.hmos.settings.MainAbility -U privacy_settings') `
        -Operation 'Open system settings for the Downloads fixture'
    if ($output -notmatch 'start ability successfully') { throw '[environment] System settings did not open' }
    # The route is verified on the test PC. Do not rely on a retained Settings
    # subpage or sidebar scroll position. Reject a changed route/layout before
    # permission mutation rather than guessing another navigation path.
    # Privacy asynchronously inserts recent-access cards. Stable bounds and
    # page identity prevent selecting a different LeanTTY card after a missed click.
    Click-HostIdentitySettingsNode -Node (Get-HostIdentityStableSettingsNode `
        -Stage 'downloads-settings-privacy' -Text '文件夹' -PageText '隐私和安全')
    Click-HostIdentitySettingsNode -Node (Get-HostIdentityStableSettingsNode `
        -Stage 'downloads-settings-folders' -Text 'LeanTTY' -PageText '全部应用')
    return Get-HostIdentityDownloadsLayout -Stage 'downloads-settings-leantty'
}

function Set-HostIdentityDownloadsPermission {
    param([Parameter(Mandatory = $true)][bool]$Enabled)
    if ((Get-HostIdentityDownloadsPermission) -eq $Enabled) { return }
    try {
        # Revoking a running app otherwise requires a force-exit confirmation.
        # The scenario is idle here, before export or after sensitive cleanup.
        Invoke-HdcChecked -Hdc $hdc -Target $Target `
            -Arguments @('shell', 'aa force-stop com.leantty.app') `
            -Operation 'Stop the test app before its scoped permission change' | Out-Null
        $running = Invoke-HdcChecked -Hdc $hdc -Target $Target `
            -Arguments @('shell', 'if pidof com.leantty.app; then echo RUNNING; else echo STOPPED; fi') `
            -Operation 'Check the test app is stopped before permission change'
        if ($running.Trim() -cne 'STOPPED') {
            throw '[environment] LeanTTY remained running before permission change'
        }
        $layout = Open-HostIdentityDownloadsSettings
        $checkbox = Get-HostIdentityDownloadsCheckbox -Layout $layout
        if (($checkbox.attributes.checked -eq 'true') -eq $Enabled) {
            throw '[environment] Downloads UI and system grant disagree before mutation'
        }
        # One toggle only. If dispatch or observation fails, finally re-reads the
        # system owner; repeating a toggle could undo an already applied action.
        Click-HostIdentitySettingsNode -Node $checkbox
        $watch = [Diagnostics.Stopwatch]::StartNew()
        do {
            if ((Get-HostIdentityDownloadsPermission) -eq $Enabled) { break }
            Start-Sleep -Milliseconds 500
        } while ($watch.Elapsed.TotalSeconds -lt 10)
        if ((Get-HostIdentityDownloadsPermission) -ne $Enabled) {
            throw '[environment] Downloads permission did not reach the requested state'
        }
        $layout = Get-HostIdentityDownloadsLayout -Stage 'downloads-settings-readback'
        if (((Get-HostIdentityDownloadsCheckbox -Layout $layout).attributes.checked -eq 'true') -ne $Enabled) {
            throw '[environment] Downloads checkbox did not match the system grant'
        }
    } finally {
        Invoke-HdcChecked -Hdc $hdc -Target $Target `
            -Arguments @('shell', 'aa force-stop com.huawei.hmos.settings') `
            -Operation 'Close the fixture settings window' | Out-Null
        Restart-HostIdentityApp -LayoutName 'downloads-return-layout'
    }
    if ((Get-HostIdentityDownloadsPermission) -ne $Enabled) {
        throw '[environment] Downloads grant changed after leaving settings'
    }
}

function Start-HostIdentityDownloadsFixture {
    $script:downloadsPermissionOriginal = Get-HostIdentityDownloadsPermission
    Set-HostIdentityDownloadsPermission -Enabled $true
    $script:downloadsPermissionPrepared = $true
}

function Restore-HostIdentityDownloadsFixture {
    if ($null -eq $downloadsPermissionOriginal) { return }
    # Retain access if backup cleanup is ambiguous: revocation must not make a
    # possibly sensitive recovery copy inaccessible before it can be audited.
    if ($ed25519ExportAttempted -and -not $ed25519BackupAbsenceAudited) {
        throw '[unknown] Downloads permission retained until key backup cleanup is proved'
    }
    Set-HostIdentityDownloadsPermission -Enabled $downloadsPermissionOriginal
    $script:downloadsPermissionRestored = $true
}

function Wait-HostIdentityExportComplete {
    param([ValidateRange(1, 30)][int]$TimeoutSeconds = 20)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $logs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appPid
        if ($logs -match 'Key export failed:') {
            if ($logs -match 'Downloads access was not granted; no files were exported') {
                throw '[environment] Key export was denied Downloads access'
            }
            throw '[product] Key export failed before its completion acknowledgement'
        }
        if ($logs -match 'KEY_EXPORT result=success(?:\r?\n|$)') {
            $script:ed25519ExportCompleted = $true
            return
        }
        Start-Sleep -Milliseconds 500
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    Get-HostIdentityDownloadsLayout -Stage 'export-completion-unknown' | Out-Null
    throw '[unknown] Key export completion is unknown; do not resend or delete the key'
}
