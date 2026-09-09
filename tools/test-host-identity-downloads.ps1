param([string]$EvidencePath = '')
$ErrorActionPreference = 'Stop'
$checks = [Collections.Generic.List[object]]::new()
function Assert-Downloads([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Test-Downloads([string]$Name, [scriptblock]$Action) {
    try { & $Action; $checks.Add(@{name=$Name; result='passed'}) }
    catch { $checks.Add(@{name=$Name; result='failed'; failure=$_.Exception.Message}) }
}
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'verify-host-identity-pc.ps1'), [ref]$null, [ref]$parseErrors)
Assert-Downloads ($parseErrors.Count -eq 0) 'Host Identity script must parse'
$export = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Export-And-Remove-HostIdentityEd25519'
}, $true))
Assert-Downloads ($export.Count -eq 1) 'Missing export owner'
. ([scriptblock]::Create($export[0].Extent.Text))

# The actual export/delete function runs; only external device and file boundaries
# are replaced. A submit ACK never satisfies the export completion condition.
foreach ($outcome in @('success', 'denied', 'pending', 'unknown')) {
    Test-Downloads "export-$outcome-before-delete" {
        $script:completionObserved = $false
        $script:sent = [Collections.Generic.List[string]]::new()
        $script:activeKeyPresent = $true
        $script:ed25519ExportVerified = $false
        $script:ed25519BackupExported = $false
        $script:ed25519Removed = $false
        $ed25519BackupName = 'leantty-id-ed25519-backup-1234567890'
        $EvidenceDirectory = [IO.Path]::GetTempPath()
        $hdc = 'unused'; $Target = 'unused'; $appPid = '42'
        function Test-HostIdentityDefaultKeyFilesPresent { return $script:activeKeyPresent }
        function Get-HostIdentityPublicFingerprint { return 'fixture-fingerprint' }
        function Get-HostIdentityConfigDigest { return 'fixture-config-digest' }
        function Submit-HostIdentityCommand { param($Command, $Stage) $script:sent.Add($Stage) }
        function Wait-HostIdentityExportComplete {
            if ($outcome -ne 'success') { throw "[$outcome] export not completed" }
            $script:completionObserved = $true
        }
        function Invoke-HostIdentityKeyBackupAcceptance {
            Assert-Downloads $script:completionObserved 'Backup command sent before export completion'
            return 'observed'
        }
        function Invoke-LeanTTYDialogButton { $script:activeKeyPresent = $false }
        function Wait-HostIdentityLog {}
        function Add-HostIdentityCheck {}
        $errorText = ''
        try { Export-And-Remove-HostIdentityEd25519 } catch { $errorText = $_.Exception.Message }
        if ($outcome -eq 'success') {
            Assert-Downloads (-not $errorText -and $script:ed25519ExportVerified -and $script:ed25519Removed) 'Completed export did not reach verified deletion'
        } else {
            Assert-Downloads ($errorText.StartsWith("[$outcome]")) 'Export outcome was not preserved'
            Assert-Downloads ($script:activeKeyPresent -and -not $script:ed25519ExportVerified -and
                $script:sent.Count -eq 1 -and $script:sent[0] -eq 'preserve-ed25519-export') 'Uncompleted export must not be resent or delete the key'
        }
    }
}

. (Join-Path $PSScriptRoot 'host-identity-downloads.ps1')
Test-Downloads 'settings-route-does-not-depend-on-sidebar-state' {
    $hdc='unused'; $Target='unused'
    $script:navigation = [Collections.Generic.List[string]]::new()
    function Invoke-HdcChecked { param($Arguments)
        Assert-Downloads ($Arguments[1].EndsWith(' -U privacy_settings')) 'Missing direct Privacy route'
        return 'start ability successfully.'
    }
    function Get-HostIdentityStableSettingsNode { param($Stage,$Text,$PageText)
        Assert-Downloads (($Text -ceq '文件夹' -and $PageText -ceq '隐私和安全') -or
            ($Text -ceq 'LeanTTY' -and $PageText -ceq '全部应用')) 'Missing page qualification'
        return @{attributes=@{text=$Text}}
    }
    function Get-HostIdentityDownloadsLayout { return @{attributes=@{text='文件夹权限'}} }
    function Get-LeanTTYLayoutNodes { param($Node) return $Node }
    function Click-HostIdentitySettingsNode { param($Node) $script:navigation.Add($Node.attributes.text) }
    $result = Open-HostIdentityDownloadsSettings
    Assert-Downloads (($script:navigation -join ',') -ceq '文件夹,LeanTTY') 'Unexpected Settings controls clicked'
    Assert-Downloads ($result.attributes.text -ceq '文件夹权限') 'Missing target page'
}
foreach ($nodeCase in @('missing','ambiguous','wrong-type')) {
    Test-Downloads "settings-route-$nodeCase-fails-before-click" {
        $hdc='unused'; $Target='unused'
        function Invoke-HdcChecked { return 'start ability successfully.' }
        function Get-HostIdentityDownloadsLayout { return @{} }
        function Get-LeanTTYLayoutNodes {
            switch ($nodeCase) {
                missing { return @() }
                ambiguous { return @(@{attributes=@{text='文件夹';type='Text'}},@{attributes=@{text='文件夹';type='Text'}}) }
                wrong-type { return @{attributes=@{text='文件夹';type='Button'}} }
            }
        }
        $script:clicked=$false
        function Click-HostIdentitySettingsNode { $script:clicked=$true }
        $failureText=''
        try { Get-HostIdentityStableSettingsNode -Stage unit -Text '文件夹' -PageText '文件夹' | Out-Null } catch { $failureText=$_.Exception.Message }
        Assert-Downloads ($failureText.StartsWith('[harness]') -and -not $script:clicked) 'Unidentified control was clicked'
    }
}
foreach ($movement in @('stable','card-inserted','never-stable')) {
    Test-Downloads "settings-bounds-$movement" {
        $script:sample=0
        function Get-HostIdentityDownloadsLayout {
            $script:sample++
            $position = if ($movement -eq 'stable') {1} elseif ($movement -eq 'card-inserted') {[Math]::Min(2,$script:sample)} else {$script:sample}
            return @{attributes=@{text='文件夹';type='Text';bounds="[0,$position][10,20]"}}
        }
        function Get-LeanTTYLayoutNodes {param($Node) return $Node}
        $failureText=''
        try { Get-HostIdentityStableSettingsNode -Stage unit -Text '文件夹' -PageText '文件夹' | Out-Null } catch {$failureText=$_.Exception.Message}
        $expectedSamples=if ($movement -eq 'stable') {2} elseif ($movement -eq 'card-inserted') {3} else {4}
        Assert-Downloads ($script:sample -eq $expectedSamples) 'Bounds were not settled or observation exceeded its bound'
        Assert-Downloads (($movement -eq 'never-stable') -eq [bool]$failureText) 'Unstable coordinates were accepted'
    }
}
foreach ($stateCase in @('granted', 'denied', 'missing', 'duplicate', 'malformed', 'other-app', 'invalid-status')) {
    Test-Downloads "permission-query-$stateCase" {
        $hdc = 'unused'; $Target = 'unused'
        function Invoke-HdcChecked {
            $status = if ($stateCase -eq 'granted') { 0 } elseif ($stateCase -eq 'invalid-status') { 1 } else { -1 }
            $permission = @{permissionName='ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY'; grantStatus=$status}
            $permissions = if ($stateCase -eq 'missing') { @() } elseif ($stateCase -eq 'duplicate') { @($permission,$permission) } else { @($permission) }
            if ($stateCase -eq 'malformed') { return 'permission query failed' }
            return (@{bundleName=$(if ($stateCase -eq 'other-app') {'other.app'} else {'com.leantty.app'});
                instIndex=0; permStateList=@($permissions)} | ConvertTo-Json -Depth 5)
        }
        $observed = $null; $failureText = ''
        try { $observed = Get-HostIdentityDownloadsPermission } catch { $failureText = $_.Exception.Message }
        if ($stateCase -in @('granted','denied')) {
            Assert-Downloads (-not $failureText -and $observed -eq ($stateCase -eq 'granted')) 'Permission state was misread'
        } else { Assert-Downloads ($failureText.StartsWith('[harness]')) 'Ambiguous permission state did not fail closed' }
    }
}
foreach ($event in @('success', 'denied', 'failure', 'pending')) {
    Test-Downloads "completion-wait-$event" {
        $hdc = 'unused'; $Target = 'unused'; $appPid = '42'
        $script:ed25519ExportCompleted = $false
        $script:unknownLayout = $false
        function Get-LeanTTYAppLogs {
            switch ($event) {
                success { "info KEY_EXPORT result=success`n" }
                denied { 'Key export failed: Downloads access was not granted; no files were exported' }
                failure { 'Key export failed: Cannot write key pair to Downloads' }
                pending { 'ACCEPTANCE_INPUT_SUBMIT sequence=1,kind=command' }
            }
        }
        function Get-HostIdentityDownloadsLayout { $script:unknownLayout = $true }
        $failureText = ''
        try { Wait-HostIdentityExportComplete -TimeoutSeconds 1 } catch { $failureText = $_.Exception.Message }
        if ($event -eq 'success') {
            Assert-Downloads (-not $failureText -and $script:ed25519ExportCompleted) 'Success event not consumed'
        } else {
            $domain = if ($event -eq 'denied') {'environment'} elseif ($event -eq 'failure') {'product'} else {'unknown'}
            Assert-Downloads ($failureText.StartsWith("[$domain]") -and -not $script:ed25519ExportCompleted) 'Uncompleted export was promoted'
            if ($event -eq 'pending') { Assert-Downloads $script:unknownLayout 'Missing unknown-outcome layout' }
        }
    }
}
foreach ($settingCase in @('unchanged','changed','dispatch-unknown','readback-failed','running','stop-failed')) {
    Test-Downloads "permission-set-$settingCase" {
        $hdc = 'unused'; $Target = 'unused'; $EvidenceDirectory = [IO.Path]::GetTempPath()
        $script:enabled = $settingCase -eq 'unchanged'
        $script:toggleCount = 0; $script:returnedToApp = $false
        function Get-HostIdentityDownloadsPermission { return $script:enabled }
        function Open-HostIdentityDownloadsSettings { return @{} }
        function Get-HostIdentityDownloadsCheckbox { return @{attributes=@{checked=$script:enabled.ToString().ToLowerInvariant()}} }
        function Click-HostIdentitySettingsNode {
            $script:toggleCount++
            $script:enabled = $true
            if ($settingCase -eq 'dispatch-unknown') { throw '[unknown] click ACK lost' }
        }
        function Get-HostIdentityDownloadsLayout {
            if ($settingCase -eq 'readback-failed') { throw '[environment] UI readback failed' }
            return @{}
        }
        function Invoke-HdcChecked { param($Arguments)
            if ($Arguments[1] -ceq 'aa force-stop com.leantty.app' -and $settingCase -eq 'stop-failed') {
                throw '[environment] Stop failed'
            }
            if ($Arguments[1] -like 'if pidof*') {
                if ($settingCase -eq 'running') { return "42`nRUNNING" }
                return 'STOPPED'
            }
        }
        function Restart-HostIdentityApp { $script:returnedToApp = $true }
        $failureText = ''
        try { Set-HostIdentityDownloadsPermission -Enabled $true } catch { $failureText = $_.Exception.Message }
        if ($settingCase -eq 'unchanged') {
            Assert-Downloads ($script:toggleCount -eq 0 -and -not $script:returnedToApp) 'Already granted permission was mutated'
        } elseif ($settingCase -in @('running','stop-failed')) {
            Assert-Downloads ($script:toggleCount -eq 0 -and $script:returnedToApp -and $failureText.StartsWith('[environment]')) 'Permission changed while the app could still be running'
        } else {
            Assert-Downloads ($script:toggleCount -eq 1 -and $script:returnedToApp) 'Toggle was retried or Settings obstructed cleanup'
            Assert-Downloads (($settingCase -eq 'changed') -eq [string]::IsNullOrEmpty($failureText)) 'Mutation uncertainty was hidden'
        }
    }
}
Test-Downloads 'permission-initial-state-survives-setup-failure' {
    $script:downloadsPermissionOriginal=$null
    $script:downloadsPermissionPrepared=$false
    function Get-HostIdentityDownloadsPermission {return $false}
    function Set-HostIdentityDownloadsPermission {throw '[unknown] setup interrupted'}
    try {Start-HostIdentityDownloadsFixture} catch {}
    Assert-Downloads ($script:downloadsPermissionOriginal -eq $false -and -not $script:downloadsPermissionPrepared) 'Original grant lost on failed setup'
}
foreach ($cleanupCase in @('never-prepared','original-granted','original-denied','backup-unknown','restore-failed')) {
    Test-Downloads "permission-cleanup-$cleanupCase" {
        $downloadsPermissionOriginal = if ($cleanupCase -eq 'never-prepared') {$null} else {$cleanupCase -eq 'original-granted'}
        $ed25519ExportAttempted = $true
        $ed25519BackupAbsenceAudited = $cleanupCase -ne 'backup-unknown'
        $script:downloadsPermissionRestored = $false
        $script:restoredValue = $null
        function Set-HostIdentityDownloadsPermission { param($Enabled)
            $script:restoredValue = $Enabled
            if ($cleanupCase -eq 'restore-failed') { throw '[environment] restore failed' }
        }
        $failureText = ''
        try { Restore-HostIdentityDownloadsFixture } catch { $failureText = $_.Exception.Message }
        if ($cleanupCase -eq 'never-prepared') {
            Assert-Downloads ($null -eq $script:restoredValue -and -not $script:downloadsPermissionRestored) 'Unowned permission changed'
        } elseif ($cleanupCase -eq 'backup-unknown') {
            Assert-Downloads ($failureText.StartsWith('[unknown]') -and $null -eq $script:restoredValue) 'Revoked access before sensitive cleanup'
        } elseif ($cleanupCase -eq 'restore-failed') {
            Assert-Downloads ($failureText -and -not $script:downloadsPermissionRestored) 'Failed restoration was declared passed'
        } else {
            Assert-Downloads (-not $failureText -and $script:downloadsPermissionRestored -and
                $script:restoredValue -eq $downloadsPermissionOriginal) 'Original grant state not restored'
        }
    }
}

# Exercise the owning finally's actual reset predicate, including export whose
# backup flag was never set. Later cleanup must not depend on that success flag.
Test-Downloads 'finally-resets-unacknowledged-export-before-terminal-cleanup' {
    $resetIf = @($ast.FindAll({param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item2.Extent.Text.Contains("Restart-HostIdentityApp -LayoutName 'cleanup-reset-layout'")
    }, $true))
    Assert-Downloads ($resetIf.Count -eq 1) 'Missing cleanup reset owner'
    $appPid='42'; $hostCreated=$false; $keyCreated=$false; $ed25519BackupExported=$false; $ed25519ExportAttempted=$true
    $script:resetCalled=$false
    $cleanupFailures=[Collections.Generic.List[string]]::new()
    function Restart-HostIdentityApp { $script:resetCalled=$true }
    & ([scriptblock]::Create($resetIf[0].Extent.Text))
    Assert-Downloads $script:resetCalled 'Pending export did not cancel before input reset'
}

$failed = @($checks | Where-Object result -eq 'failed')
if ($EvidencePath) {
    . (Join-Path $PSScriptRoot 'release-tooling.ps1')
    Write-LeanTTYAtomicJson -Path $EvidencePath -Depth 6 -Value ([ordered]@{
        gate='host-identity-downloads-regression'; result=$(if ($failed.Count) {'failed'} else {'passed'});
        acceptanceEligible=$false; deviceOperations=0; checks=@($checks)
    })
}
if ($failed.Count) { throw ($failed.failure -join '; ') }
Write-Host "Host Identity Downloads regressions passed: $($checks.Count)."
