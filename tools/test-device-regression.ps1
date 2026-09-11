param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')

& (Join-Path $PSScriptRoot 'diagnose-text-input-pc.ps1') -SelfTest
& (Join-Path $PSScriptRoot 'test-mosh-runtime-contract.ps1')
& (Join-Path $PSScriptRoot 'test-recovery-command-probes.ps1')
& (Join-Path $PSScriptRoot 'test-mosh-lifecycle-observation.ps1')
& (Join-Path $PSScriptRoot 'test-notification-regression.ps1')

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw $Message }
}

& {
    $authAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'verify-ssh-auth-pc.ps1'), [ref]$null, [ref]$null)
    foreach ($name in @('Get-AuthInputWebEvidence', 'Get-AuthFixturePasswordEvidence',
        'Save-AuthFixturePasswordEvidence', 'Submit-AuthValue', 'Assert-NoSecretExposure', 'Write-AuthEvidence')) {
        $definition = $authAst.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true) | Select-Object -First 1
        Assert-True ($null -ne $definition) "Missing authentication evidence helper: $name"
        Invoke-Expression $definition.Extent.Text
    }
    $sampleLogs = 'irrelevant runtime-secret-value' + "`n" +
        'ACCEPTANCE_INPUT_WEB 32,22,0,22,22,0,32,0,0,1,1,0'
    $web = Get-AuthInputWebEvidence -Logs $sampleLogs
    Assert-True ($web.status -eq 'observed' -and $web.reportCount -eq 1 -and
        $web.latest.dataPrintableUnits -eq 32 -and $web.latest.imeKeydowns -eq 22) (
        'Web evidence did not preserve the typed aggregate counters'
    )
    foreach ($invalid in @('', 'ACCEPTANCE_INPUT_WEB 1,2,3',
        'ACCEPTANCE_INPUT_WEB 1,2,3,4,5,6,7,8,9,10,11,12,13',
        'ACCEPTANCE_INPUT_WEB 1,2,3,4,5,6,7,8,9,10,11,99999999999999')) {
        $missing = Get-AuthInputWebEvidence -Logs $invalid
        Assert-True ($missing.status -eq 'missing' -and $null -eq $missing.latest) (
            'Missing or malformed metrics were promoted to zero counts'
        )
    }
    $fixtureLogs = @(
        'auth method=password scenario=Password result=matched',
        'auth method=password scenario=Mosh result=reject expected_bytes=32 received_bytes=31 overlap_mismatches=23 length_delta=-1',
        'auth method=password scenario=runtime-secret-value result=matched',
        'auth method=password scenario=Password result=matched secret=runtime-secret-value'
    ) -join "`n"
    $fixture = Get-AuthFixturePasswordEvidence -Logs $fixtureLogs
    Assert-True ($fixture.status -eq 'observed' -and $fixture.events.Count -eq 2 -and
        $fixture.unparsedEventCount -eq 2 -and $fixture.events[0].exactCredentialMatch -eq $true -and
        $null -eq $fixture.events[0].receivedBytes -and $fixture.events[1].receivedBytes -eq 31 -and
        $fixture.events[1].lengthDelta -eq -1) 'Fixture evidence invented byte counts or accepted an unsafe log line'
    Assert-True ((@($web, $fixture) | ConvertTo-Json -Depth 12) -notmatch 'runtime-secret-value') (
        'Authentication evidence retained raw application or fixture text'
    )

    # Exercise real submission/audit functions; only external device boundaries are mocked.
    $hdc = 'unused'; $Target = 'unused'; $appPid = '100'
    $EvidenceDirectory = [IO.Path]::GetTempPath()
    $secrets = @('runtime-secret-value'); $currentStage = 'password-success'
    $authInputObservations = [Collections.Generic.List[object]]::new()
    function Focus-ActiveCommandInput { return @{ attributes = @{} } }
    function Clear-LeanTTYAppLogs {}
    function Get-LeanTTYAppLogs { return $sampleLogs.Replace('runtime-secret-value', 'redacted') }
    function Get-LeanTTYDeviceLayout { return @{ attributes = @{} } }
    function Wait-AuthLog {}
    $script:authEnterCalls = 0
    $script:rejectAuthTarget = $false
    function Invoke-TemporaryFixtureAuthText {
        if ($script:rejectAuthTarget) {
            throw (New-LeanTTYTextInputFailure -Phase after -ExpectedNode $null -CurrentNodes @() `
                -Message '[harness] synthetic target rejection')
        }
    }
    function Invoke-LeanTTYDeviceKey { $script:authEnterCalls++ }
    Submit-AuthValue -Value 'runtime-secret-value' -LayoutName 'password.json'
    Assert-True ($authInputObservations.Count -eq 1 -and
        $authInputObservations[0].submitAckObserved -and $authInputObservations[0].web.latest.dataPrintableUnits -eq 32) (
        'Successful authentication submission lost pre-Enter metrics'
    )
    $script:rejectAuthTarget = $true
    Assert-Throws { Submit-AuthValue -Value 'runtime-secret-value' -LayoutName 'password.json' } 'Target rejection was swallowed'
    Assert-True ($script:authEnterCalls -eq 1 -and $authInputObservations.Count -eq 2 -and
        $authInputObservations[1].result -eq 'failed' -and
        $authInputObservations[1].textTargetFailure.phase -eq 'after' -and
        $authInputObservations[1].web.latest.dataPrintableUnits -eq 32) (
        'Failed authentication did not retain evidence before cleanup, or sent Enter after rejection'
    )
    function Get-LeanTTYAppLogs { throw 'synthetic unavailable logs' }
    Assert-Throws { Submit-AuthValue -Value 'runtime-secret-value' -LayoutName 'password.json' } 'Missing logs replaced the original failure'
    Assert-True ($authInputObservations[2].web.status -eq 'unavailable' -and
        $authInputObservations[2].textTargetFailure.phase -eq 'after') 'Diagnostic read failure hid the original target failure'
    Assert-True (($authInputObservations | ConvertTo-Json -Depth 12) -notmatch 'runtime-secret-value') 'Submission record exposed credentials'
    $script:rejectAuthTarget = $false
    function Get-LeanTTYAppLogs { return '' }
    Submit-AuthValue -Value 'runtime-secret-value' -LayoutName 'password.json'
    Assert-True ($script:authEnterCalls -eq 2 -and $authInputObservations[3].submitAckObserved -and
        $authInputObservations[3].web.status -eq 'missing' -and $null -eq $authInputObservations[3].web.latest) (
        'Absent acceptance metrics became an authentication gate or a fabricated zero observation'
    )

    function Get-LeanTTYAppLogs { return 'runtime-secret-value' }
    Assert-Throws { Submit-AuthValue -Value 'runtime-secret-value' -LayoutName 'password.json' } 'Secret exposure did not stop submission'
    Assert-True ($script:authEnterCalls -eq 2 -and $authInputObservations[4].result -eq 'failed' -and
        -not $authInputObservations[4].enterAttempted) 'Privacy audit failure sent Enter'

    function Get-LeanTTYAppLogs { return '' }
    function Wait-AuthLog { throw 'synthetic ACK timeout' }
    Assert-Throws { Submit-AuthValue -Value 'runtime-secret-value' -LayoutName 'password.json' } 'Missing submission ACK was swallowed'
    Assert-True ($script:authEnterCalls -eq 3 -and $authInputObservations[5].enterAttempted -and
        -not $authInputObservations[5].submitAckObserved -and $authInputObservations[5].result -eq 'failed') (
        'Failed ACK was promoted to success or retried'
    )
    function Focus-ActiveCommandInput {
        throw (New-LeanTTYTextInputFailure -Phase before -ExpectedNode $null -CurrentNodes @() `
            -Message '[harness] synthetic pre-focus rejection')
    }
    $script:unscopedAuthRead = $false
    function Get-LeanTTYAppLogs { $script:unscopedAuthRead = $true; return $sampleLogs }
    Assert-Throws { Submit-AuthValue -Value 'runtime-secret-value' -LayoutName 'password.json' } 'Pre-focus rejection was swallowed'
    Assert-True ($script:authEnterCalls -eq 3 -and -not $script:unscopedAuthRead -and
        $authInputObservations[6].web.status -eq 'not-captured' -and
        $authInputObservations[6].textTargetFailure.phase -eq 'before') (
        'Pre-focus failure captured unscoped logs or sent Enter'
    )

    $fixtureStderr = 'unused-fixture-path'
    function Test-Path { return $true }
    function Read-FixtureLogText { return $fixtureLogs }
    Save-AuthFixturePasswordEvidence
    $fixtureLogs = '' # Model cleanup after retention, for both successful and failed runs.
    Assert-True ($script:fixturePasswordEvidence.events.Count -eq 2) 'Fixture cleanup erased retained authentication outcomes'

    # Run the real final writer and read its JSON; no HDC, signing or fixture process.
    $startedAt = [DateTimeOffset]::UtcNow
    $scenarioResult = 'failed'; $runMode = 'diagnostic'; $DiagnosticHap = 'synthetic-no-device'
    $commandObservations = [Collections.Generic.List[object]]::new()
    $connectedInputObservations = [Collections.Generic.List[object]]::new()
    $checks = @(); $selectedStageNames = @(); $harnessDifferencePaths = @()
    $candidate = @{ sha256 = 'synthetic'; gitCommit = 'synthetic'; gitTree = 'synthetic'; gitDirty = $true }
    $textTargetFailure = $authInputObservations[6].textTargetFailure
    $evidencePath = Join-Path ([IO.Path]::GetTempPath()) ('leantty-auth-evidence-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        Write-AuthEvidence
        $json = [IO.File]::ReadAllText($evidencePath)
        $saved = $json | ConvertFrom-Json -Depth 20
        Assert-True ($saved.result -eq 'failed' -and $saved.runMode -eq 'diagnostic' -and
            $saved.inputBoundary.submissions.Count -eq 7 -and
            $saved.inputBoundary.submissions[0].web.latest.dataPrintableUnits -eq 32 -and
            $null -eq $saved.inputBoundary.submissions[3].web.latest -and
            $saved.inputBoundary.submissions[6].textTargetFailure.phase -eq 'before' -and
            $saved.inputBoundary.fixturePassword.events[1].receivedBytes -eq 31 -and
            $saved.inputBoundary.textTargetFailure.phase -eq 'before') (
            'Final authentication JSON lost nested failure, counters, nulls or fixture outcomes'
        )
        Assert-True ($saved.inputBoundary.webScope -eq 'process-log-since-clear-before-enter-unsettled' -and
            $saved.inputBoundary.fixtureScope -eq 'run-ordered-password-events-no-submission-correlation' -and
            $json -notmatch 'runtime-secret-value') 'Final authentication report lost scope labels or exposed input'
    } finally {
        if ([IO.File]::Exists($evidencePath)) { Remove-Item -LiteralPath $evidencePath -Force }
    }
    function Test-Path { return $false }
    Save-AuthFixturePasswordEvidence
    Assert-True ($script:fixturePasswordEvidence.status -eq 'missing' -and
        $script:fixturePasswordEvidence.events.Count -eq 0) 'Missing fixture log reused stale evidence'
    function Test-Path { return $true }
    function Read-FixtureLogText { throw 'synthetic unavailable fixture log' }
    Save-AuthFixturePasswordEvidence
    Assert-True ($script:fixturePasswordEvidence.status -eq 'unavailable' -and
        $script:fixturePasswordEvidence.events.Count -eq 0) 'Fixture read failure hid its status or reused stale evidence'
    $source = $authAst.Extent.Text
    Assert-True ($source.LastIndexOf('Save-AuthFixturePasswordEvidence') -lt
        $source.LastIndexOf('Remove-Item -LiteralPath $fixtureRoot') -and
        $source.Contains('inputBoundary = [ordered]@{')) 'Authentication report does not retain evidence before fixture cleanup'
}

$deleteKeyButtonTexts = @(Resolve-LeanTTYDialogButtonTexts -ButtonText 'Delete key')
Assert-True (
    $deleteKeyButtonTexts.Count -eq 2 -and
    $deleteKeyButtonTexts -contains 'Delete key' -and
    $deleteKeyButtonTexts -contains '删除密钥'
) 'Delete-key dialog matching does not cover the supported English and Chinese labels'

$closePaneButtonTexts = @(Resolve-LeanTTYDialogButtonTexts -ButtonText 'Close pane')
Assert-True (
    $closePaneButtonTexts.Count -eq 2 -and
    $closePaneButtonTexts -contains 'Close pane' -and
    $closePaneButtonTexts -contains '关闭分屏'
) 'Close-pane dialog matching does not cover the supported English and Chinese labels'

$unknownButtonTexts = @(Resolve-LeanTTYDialogButtonTexts -ButtonText 'Acceptance action')
Assert-True (
    $unknownButtonTexts.Count -eq 1 -and
    $unknownButtonTexts[0] -eq 'Acceptance action'
) 'Unknown dialog actions must keep exact matching'

$layout = @'
{
  "attributes": {"bounds":"[0,0][3120,2080]","text":"","originalText":"","hint":""},
  "children": [
    {
      "attributes": {
        "bounds":"[120,130][3000,1980]",
        "text":"ssh-keygen -p -f regression_key",
        "originalText":"ssh-keygen -p -f regression_key",
        "hint":"Terminal input"
      },
      "children": []
    },
    {
      "attributes": {
        "bounds":"[1900,1200][2200,1300]",
        "text":"Delete key",
        "originalText":"Delete key",
        "hint":""
      },
      "children": []
    }
  ]
}
'@ | ConvertFrom-Json -Depth 20

Assert-True (
    (Get-LeanTTYTerminalInputText -Layout $layout) -eq 'ssh-keygen -p -f regression_key'
) 'Terminal input text was not read from the accessibility layout'

$focusedTextLayout = @'
{
  "attributes":{"type":"root","focused":"true","bounds":"[0,0][100,100]"},
  "children":[
    {"attributes":{"type":"textField","accessibilityId":"search-node","hint":"Search text Find","focused":"true","bounds":"[10,10][50,30]"},"children":[]},
    {"attributes":{"type":"textField","accessibilityId":"terminal-node","hint":"Terminal input","focused":"false","bounds":"[10,60][50,80]"},"children":[]}
  ]
}
'@ | ConvertFrom-Json -Depth 20
$focusedTextInputs = @(Get-LeanTTYFocusedTextInputNodes -Layout $focusedTextLayout)
Assert-True (
    $focusedTextInputs.Count -eq 1 -and
    $focusedTextInputs[0].attributes.hint -eq 'Search text Find'
) 'Targeted text input did not select the unique focused text field'

$warmPaneLayout = @'
{"attributes":{},"children":[
 {"attributes":{"type":"__Common__","opacity":"0.000000","hitTestBehavior":"HitTestMode.None"},"children":[
  {"attributes":{"type":"textField","hint":"Terminal input","visible":"true","bounds":"[10,10][30,30]"},"children":[]}]},
 {"attributes":{"type":"__Common__","opacity":"1.000000","hitTestBehavior":"HitTestMode.Default"},"children":[
  {"attributes":{"type":"textField","hint":"Terminal input","opacity":"0.000000","visible":"true","bounds":"[40,10][60,30]"},"children":[]}]}
]}
'@ | ConvertFrom-Json -Depth 10
Assert-True (@(Get-LeanTTYTerminalInputNodes -Layout $warmPaneLayout).Count -eq 1) (
    'Hidden warm Tab inputs must be excluded without excluding the active xterm transparent textarea'
)

& {
    $script:capturedHdcCalls = [Collections.Generic.List[object]]::new()
    function Get-HdcUiLayout {
        param($Hdc, $Target, $LocalPath, $BundleName, $Operation)
        return $focusedTextLayout
    }
    function Invoke-FakeHdc {
        $script:capturedHdcCalls.Add(@($args))
        $global:LASTEXITCODE = 0
    }

    Invoke-LeanTTYDeviceText `
        -Hdc 'Invoke-FakeHdc' `
        -Target 'regression-device' `
        -Text 'ssh-keygen -p -f regression_key' `
        -InputNode ([pscustomobject]@{
            attributes = [pscustomobject]@{
                type = 'textField'
                accessibilityId = 'search-node'
                hint = 'Search text Find'
                focused = 'true'
                bounds = '[9,9][49,29]'
            }
        })
    Assert-True (
        $script:capturedHdcCalls.Count -eq 1 -and
        $script:capturedHdcCalls[0].Count -eq 9 -and
        $script:capturedHdcCalls[0][0] -eq '-t' -and
        $script:capturedHdcCalls[0][1] -eq 'regression-device' -and
        $script:capturedHdcCalls[0][2] -eq 'shell' -and
        $script:capturedHdcCalls[0][3] -eq 'uitest' -and
        $script:capturedHdcCalls[0][4] -eq 'uiInput' -and
        $script:capturedHdcCalls[0][5] -eq 'inputText' -and
        $script:capturedHdcCalls[0][6] -eq 30 -and
        $script:capturedHdcCalls[0][7] -eq 20 -and
        $script:capturedHdcCalls[0][8] -eq 'ssh-keygen -p -f regression_key'
    ) 'Device text did not revalidate and target the current focused UiTest text field'
}

& {
    $script:regeneratedIdentityHdcCalls = 0
    function Get-HdcUiLayout {
        param($Hdc, $Target, $LocalPath, $BundleName, $Operation)
        return $focusedTextLayout
    }
    function Invoke-FakeHdc {
        $script:regeneratedIdentityHdcCalls++
        $global:LASTEXITCODE = 0
    }

    Invoke-LeanTTYDeviceText `
        -Hdc 'Invoke-FakeHdc' `
        -Target 'regression-device' `
        -Text 'same-target-after-layout-refresh' `
        -InputNode ([pscustomobject]@{
            attributes = [pscustomobject]@{
                type = 'textField'
                accessibilityId = 'previous-search-node'
                hint = 'Search text Find'
                focused = 'true'
                bounds = '[10,10][50,30]'
            }
        })
    Assert-True ($script:regeneratedIdentityHdcCalls -eq 1) (
        'Device text rejected the same semantic and geometric target after UiTest regenerated its opaque ID'
    )
}

& {
    $script:staleTargetInputCalls = 0
    function Get-HdcUiLayout {
        param($Hdc, $Target, $LocalPath, $BundleName, $Operation)
        return $focusedTextLayout
    }
    function Invoke-FakeHdc {
        $script:staleTargetInputCalls++
        $global:LASTEXITCODE = 0
    }

    $targetFailure = $null
    try {
        Invoke-LeanTTYDeviceText `
            -Hdc 'Invoke-FakeHdc' `
            -Target 'regression-device' `
            -Text 'must-not-reach-terminal' `
            -InputNode ([pscustomobject]@{
                attributes = [pscustomobject]@{
                    type = 'textField'
                    accessibilityId = 'terminal-node'
                    hint = 'Terminal input'
                    focused = 'true'
                    bounds = '[10,60][50,80]'
                }
            })
    } catch { $targetFailure = $_.Exception }
    Assert-True ($null -ne $targetFailure) 'Device text accepted a target whose focus had moved to another field'
    $detail = $targetFailure.Data['LeanTTYTextInputFailure']
    Assert-True ($null -ne $detail -and $detail.phase -eq 'before' -and
        $detail.focusedCount -eq 1 -and $detail.targets[0].attributes.hint.equal -eq $false) (
        'Pre-input rejection lost its content-free target comparison'
    )
    $serializedDetail = $detail | ConvertTo-Json -Depth 12
    Assert-True ($serializedDetail -notmatch 'Terminal input|Search text Find|terminal-node|must-not-reach-terminal') (
        'Target rejection evidence retained field content or opaque identifiers'
    )
    Assert-True ($script:staleTargetInputCalls -eq 0) (
        'Device text reached UiTest after the intended target lost focus'
    )
}

& {
    $script:ownerCheckLayouts = 0
    $script:ownerCheckInputs = 0
    function Get-HdcUiLayout {
        param($Hdc, $Target, $LocalPath, $BundleName, $Operation)
        $script:ownerCheckLayouts++
        $focusedIndex = if ($script:ownerCheckLayouts -eq 1) { 0 } else { 1 }
        return [pscustomobject]@{ attributes = @{}; children = @(0, 1 | ForEach-Object {
            [pscustomobject]@{ attributes = [pscustomobject]@{
                type = 'textField'; hint = 'Terminal input'; bounds = '[10,10][30,30]'
                hierarchy = "ROOT1,0,$_"; hostWindowId = '1'
                focused = $(if ($_ -eq $focusedIndex) { 'true' } else { 'false' })
            }; children = @() }
        }) }
    }
    function Invoke-FakeHdc {
        $script:ownerCheckInputs++
        $global:LASTEXITCODE = 0
    }
    $targetFailure = $null
    try {
        Invoke-LeanTTYDeviceText -Hdc 'Invoke-FakeHdc' -Target 'regression-device' -Text 'probe'
    } catch { $targetFailure = $_.Exception }
    Assert-True ($null -ne $targetFailure) 'Text input must fail immediately when its click transfers focus to an overlapping Pane'
    $detail = $targetFailure.Data['LeanTTYTextInputFailure']
    Assert-True ($null -ne $detail -and $detail.phase -eq 'after' -and
        $detail.targets[0].expectedPath.indices -join ',' -eq '0,0' -and
        $detail.targets[0].currentPath.indices -join ',' -eq '0,1' -and
        $detail.targets[0].sameRoot -eq $true -and
        $detail.targets[0].attributes.bounds.equal -eq $true) (
        'Post-input rejection lost the changed tree path at overlapping geometry'
    )
    Assert-True (($detail | ConvertTo-Json -Depth 12) -notmatch 'ROOT1|Terminal input|probe') (
        'Post-input rejection exposed layout identifiers or content'
    )
    Assert-True ($script:ownerCheckInputs -eq 1 -and $script:ownerCheckLayouts -eq 2) (
        'Owner loss must capture one post-input layout and never retry or send Enter'
    )
}

& {
    $expected = [pscustomobject]@{ attributes = [pscustomobject]@{
        type='textField'; hint='Terminal input'; hierarchy='ROOT1,0,0'; hostWindowId='1'
        accessibilityId='old'; bounds='[10,10][30,30]'
    } }
    $moved = [pscustomobject]@{ attributes = [pscustomobject]@{
        type='textField'; hint='Terminal input'; hierarchy='ROOT1,0,0'; hostWindowId='1'
        accessibilityId='new'; bounds='[40,10][60,30]'
    } }
    Assert-True (Test-LeanTTYSameTextInputTarget -ExpectedNode $expected -CurrentNode $moved) (
        'Within one input operation, cursor movement and regenerated opaque IDs must preserve the same tree target'
    )
    $moved.attributes.hierarchy = 'ROOT1,0,1'
    $moved.attributes.bounds = $expected.attributes.bounds
    $moved.attributes.accessibilityId = $expected.attributes.accessibilityId
    Assert-True (-not (Test-LeanTTYSameTextInputTarget -ExpectedNode $expected -CurrentNode $moved)) (
        'Matching bounds or an opaque ID must not override a different current tree owner'
    )
    $moved.attributes.hierarchy = 'ROOT-private-host,secret-text'
    $failure = New-LeanTTYTextInputFailure -Message 'test-only' -Phase after `
        -ExpectedNode $expected -CurrentNodes @($moved)
    $detail = $failure.Data['LeanTTYTextInputFailure']
    Assert-True (-not $detail.targets[0].currentPath.valid -and $null -eq $detail.targets[0].sameRoot -and
        ($detail | ConvertTo-Json -Depth 12) -notmatch 'private-host|secret-text|old|new') (
        'Malformed hierarchy was leaked or treated as known structural identity'
    )
}

& {
    # The native Web owner survives a DOM renderer change; its virtual textarea
    # path, opaque ID and cursor-following bounds do not have to survive it.
    function New-WebOwnerLayout($after, $case) {
        $webPath = if ($after -and $case -in @('other-pane', 'ancestor-reindex')) { 'ROOT1,1' } else { 'ROOT1,0' }
        $webId = if ($after -and $case -in @('replaced-web', 'other-pane')) { 'web-new' } else { 'web-owner' }
        $windowId = if ($after -and $case -eq 'other-window') { '2' } else { '1' }
        if (($after -and $case -eq 'missing-id-after') -or (-not $after -and $case -eq 'missing-id-before')) { $webId = '' }
        if ($case -eq 'blank-id') { $webId = ' ' }
        if (($after -and $case -eq 'missing-window-after') -or (-not $after -and $case -eq 'missing-window-before')) { $windowId = '' }
        $hint = if ($after -and $case -eq 'search') { 'Search text Find' } else { 'Terminal input' }
        $leaf = [pscustomobject]@{attributes=[pscustomobject]@{
            type='textField'; hint=$hint; focused='true'; hostWindowId=$windowId
            hierarchy=($webPath + $(if ($after) { ',0,2,0,0' } else { ',0,0,2,0,0' }))
            accessibilityId=$(if ($after) { 'input-new' } else { 'input-old' })
            bounds=$(if ($after) { '[80,20][100,40]' } else { '[10,10][30,30]' })
        };children=@()}
        $children = @($leaf)
        if ($after -and $case -eq 'ambiguous') {
            $leaf.attributes.hierarchy = $webPath + ',0,0,2,0,0'
            $children += [pscustomobject]@{attributes=@{type='textField';hint='Terminal input';focused='false'};children=@()}
        }
        $web = [pscustomobject]@{attributes=[pscustomobject]@{
            type='Web'; hierarchy=$webPath; accessibilityId=$webId; hostWindowId=$windowId
            bounds='[0,0][200,200]'
        };children=$children}
        if ($after -and $case -eq 'leaf-window-mismatch') { $leaf.attributes.hostWindowId = '2' }
        $roots = @($web)
        if (($after -and $case -eq 'duplicate-id-after') -or
                (-not $after -and $case -eq 'duplicate-id-before') -or $case -eq 'other-visible-pane') {
            # A second Web may occupy identical bounds, but must have a distinct
            # native identity. Reject duplicate IDs even if only one is focused.
            $peerId = if ($case -eq 'other-visible-pane') { 'peer-web' } else { $webId }
            $roots += [pscustomobject]@{attributes=@{type='Web';hierarchy='ROOT1,2';
                accessibilityId=$peerId;hostWindowId=$windowId;bounds='[0,0][200,200]'};children=@(
                [pscustomobject]@{attributes=@{type='textField';hint='Terminal input';focused='false'};children=@()}
            )}
        }
        return [pscustomobject]@{attributes=@{};children=$roots}
    }
    $acceptedCases = @('same-web', 'ancestor-reindex', 'other-visible-pane')
    foreach ($case in @('same-web', 'ancestor-reindex', 'other-visible-pane', 'other-pane', 'replaced-web',
            'other-window', 'search', 'ambiguous', 'missing-id-before', 'missing-id-after', 'blank-id',
            'missing-window-before', 'missing-window-after', 'duplicate-id-before', 'duplicate-id-after',
            'leaf-window-mismatch')) {
        $script:webOwnerLayoutReads = 0
        $script:webOwnerInputs = 0
        function Get-HdcUiLayout {
            param($Hdc, $Target, $LocalPath, $BundleName, $Operation)
            $script:webOwnerLayoutReads++
            return New-WebOwnerLayout ($script:webOwnerLayoutReads -gt 1) $case
        }
        function Invoke-FakeHdc { $script:webOwnerInputs++; $global:LASTEXITCODE = 0 }
        $failure = $null
        try { Invoke-LeanTTYDeviceText -Hdc 'Invoke-FakeHdc' -Target 'regression-device' -Text 'public-owner-probe' }
        catch { $failure = $_.Exception }
        if ($case -in $acceptedCases) {
            Assert-True ($null -eq $failure) "Same unique native Web owner must survive structural reindexing: $case"
        } else {
            Assert-True ($null -ne $failure) "Terminal input must reject changed or ambiguous owner: $case"
            $owners = $failure.Data['LeanTTYTextInputFailure'].webOwners
            Assert-True ($owners.expectedPresent -and $owners.targets.Count -eq 1) 'Missing native Web failure comparison'
            if ($case -in @('other-pane', 'replaced-web')) {
                Assert-True (-not $owners.targets[0].attributes.accessibilityId.equal) 'Web identity comparison was lost'
            }
            Assert-True (($owners | ConvertTo-Json -Depth 12) -notmatch 'web-owner|web-new|input-old|input-new|Terminal input|Search text') 'Web comparison leaked raw attributes'
        }
        Assert-True ($script:webOwnerInputs -eq 1 -and $script:webOwnerLayoutReads -eq 2) (
            'Web owner comparison must not add input retries or Enter'
        )
    }
}

foreach ($focusCount in @(0, 5)) {
    & {
        function Get-HdcUiLayout {
            return @{ attributes = @{}; children = @(for ($index = 0; $index -lt $focusCount; $index++) {
                @{ attributes = @{ type = 'textField'; hint = 'private-hint'; focused = 'true';
                    hierarchy = "ROOT123,$index"; bounds = '[0,0][20,20]' }; children = @() }
            }) }
        }
        function Invoke-FakeHdc { throw 'Input must not be attempted for non-unique focus' }
        $focusFailure = $null
        try {
            Invoke-LeanTTYDeviceText -Hdc Invoke-FakeHdc -Target regression-device -Text private-value
        } catch { $focusFailure = $_.Exception.Data['LeanTTYTextInputFailure'] }
        Assert-True ($null -ne $focusFailure -and $focusFailure.focusedCount -eq $focusCount -and
            $focusFailure.targets.Count -eq [Math]::Min(4, $focusCount) -and
            $focusFailure.targetsTruncated -eq ($focusCount -gt 4) -and
            ($focusFailure | ConvertTo-Json -Depth 12) -notmatch 'ROOT123|private-hint|private-value') (
            'Non-unique focus failure lost its count, exceeded the evidence bound or leaked content'
        )
    }
}

& {
    function Get-HdcTargets {
        return @([pscustomobject]@{
                key = 'regression-device'; transport = 'USB'; status = 'Ready'; raw = ''
            })
    }
    Assert-True (
        (Assert-HdcTargetReady -Hdc 'unused' -Target 'regression-device').status -eq 'Ready'
    ) 'Ready USB HDC target was rejected by preflight'
}

& {
    function Invoke-FailingHdc {
        '[E001005] runtime-only-secret'
        $global:LASTEXITCODE = 0
    }
    $failureMessage = ''
    try {
        Invoke-HdcChecked `
            -Hdc 'Invoke-FailingHdc' `
            -Target 'regression-device' `
            -Arguments @('shell', 'probe') `
            -Operation 'bounded probe' | Out-Null
    } catch {
        $failureMessage = $_.Exception.Message
    }
    Assert-True (
        $failureMessage.Contains('hdcCode=E001005') -and
        -not $failureMessage.Contains('runtime-only-secret')
    ) 'Checked HDC failures either lost the standard code or exposed command output'
}

Assert-Throws -Action {
    Invoke-LeanTTYDeviceText -Hdc 'unused' -Target 'unused' -Text "line`nbreak"
} -Message 'Device text input accepted a command separator'

Assert-True (Test-HdcCommandFailure -Output '[E001005] target disconnected') (
    'HDC standard error code was not recognized as a failed command'
)
Assert-True (Test-HdcCommandFailure -Output 'Max tag count is 10 [CODE: -42]') (
    'HarmonyOS command error code was not recognized as a failed command'
)
Assert-True (-not (Test-HdcCommandFailure -Output 'Forwardport result:OK')) (
    'Successful HDC output was classified as a failure'
)

$helperTestRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'leantty-helper-' + [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $helperTestRoot | Out-Null
try {
    $controlDirectory = Join-Path $helperTestRoot 'fixture'
    New-Item -ItemType Directory -Path $controlDirectory | Out-Null
    Assert-True (
        $null -eq (Read-LeanTTYFixtureReadiness -ControlDirectory $controlDirectory)
    ) 'Missing fixture files were accepted as ready'
    [IO.File]::WriteAllText(
        (Join-Path $controlDirectory 'fixture-ready'),
        "address=127.0.0.1:22222`npid=4242`n",
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $controlDirectory 'server-credentials'),
        "password=temporary`naccount=fixture`n",
        [Text.UTF8Encoding]::new($false)
    )
    $fixtureReadiness = Read-LeanTTYFixtureReadiness `
        -ControlDirectory $controlDirectory `
        -RequiredCredentialNames @('password', 'account') `
        -ExpectedAddress '127.0.0.1:22222'
    Assert-True (
        $fixtureReadiness.linuxPid -eq 4242 -and
        $fixtureReadiness.credentials.password -eq 'temporary' -and
        $null -eq (Read-LeanTTYFixtureReadiness `
            -ControlDirectory $controlDirectory `
            -ExpectedAddress '127.0.0.1:33333')
    ) 'Fixture readiness parsing lost exact address, PID or credential validation'

    & {
        $script:confirmTransfer = $false
        function Invoke-FakeFileHdc {
            if ($args.Count -ge 6 -and $args[2] -eq 'file' -and $args[3] -eq 'recv') {
                [IO.File]::WriteAllText($args[5], '{"children":[]}', [Text.UTF8Encoding]::new($false))
                if ($script:confirmTransfer) { 'FileTransfer finish, Size:15, File count = 1' } else { 'done' }
            }
            $global:LASTEXITCODE = 0
        }
        $receivedPath = Join-Path $helperTestRoot 'received.json'
        Assert-Throws -Action {
            Receive-HdcFileChecked `
                -Hdc 'Invoke-FakeFileHdc' `
                -Target 'regression-device' `
                -RemotePath '/data/local/tmp/layout.json' `
                -LocalPath $receivedPath | Out-Null
        } -Message 'Device file receive accepted output without FileTransfer finish'
        $script:confirmTransfer = $true
        $confirmedPath = Receive-HdcFileChecked `
            -Hdc 'Invoke-FakeFileHdc' `
            -Target 'regression-device' `
            -RemotePath '/data/local/tmp/layout.json' `
            -LocalPath $receivedPath
        Assert-True (
            $confirmedPath -eq [IO.Path]::GetFullPath($receivedPath)
        ) 'Confirmed device file receive did not return the exact local file'
    }
} finally {
    if ((Test-Path -LiteralPath $helperTestRoot) -and
        [IO.Path]::GetFullPath($helperTestRoot).StartsWith(
            [IO.Path]::GetFullPath([IO.Path]::GetTempPath()),
            [StringComparison]::OrdinalIgnoreCase
        )) {
        Remove-Item -LiteralPath $helperTestRoot -Recurse -Force
    }
}

& {
    function Get-HdcTargets {
        return @([pscustomobject]@{
                key = 'regression-device'; transport = 'USB'; status = 'Offline'; raw = ''
            })
    }
    Assert-Throws -Action {
        Assert-HdcTargetReady -Hdc 'unused' -Target 'regression-device'
    } -Message 'Offline HDC target was accepted instead of stopping at preflight'
}

& {
    function Get-HdcTargets {
        return @([pscustomobject]@{
                key = 'regression-device'; transport = 'USB'; status = 'Offline'; raw = ''
            })
    }
    $message = ''
    try {
        Resolve-LeanTTYRegressionTarget -Hdc 'unused'
    } catch {
        $message = $_.Exception.Message
    }
    Assert-True ($message.StartsWith('[infrastructure]')) (
        'No ready device was not classified as an infrastructure stop'
    )
}

& {
    function Get-HdcTargets {
        return @(
            [pscustomobject]@{ key = 'device-a'; transport = 'USB'; status = 'Ready'; raw = '' },
            [pscustomobject]@{ key = 'device-b'; transport = 'USB'; status = 'Ready'; raw = '' }
        )
    }
    $message = ''
    try {
        Resolve-LeanTTYRegressionTarget -Hdc 'unused'
    } catch {
        $message = $_.Exception.Message
    }
    Assert-True ($message.StartsWith('[environment]')) (
        'Ambiguous ready targets were not classified as an environment stop'
    )
}

$devicePreflightPath = Join-Path $PSScriptRoot 'preflight-device.ps1'
Assert-True (Test-Path -LiteralPath $devicePreflightPath -PathType Leaf) (
    'Standalone device control preflight is missing'
)
$preflightTokens = $null
$preflightErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
    $devicePreflightPath,
    [ref]$preflightTokens,
    [ref]$preflightErrors
)
Assert-True ($preflightErrors.Count -eq 0) 'Standalone device control preflight has invalid syntax'
$devicePreflightText = Get-Content -LiteralPath $devicePreflightPath -Raw
Assert-True (
    $devicePreflightText.Contains('Resolve-LeanTTYRegressionTarget') -and
    $devicePreflightText.Contains('Assert-HdcTargetReady') -and
    $devicePreflightText.Contains('Invoke-HdcChecked') -and
    $devicePreflightText.Contains('Get-LeanTTYDeviceLayout') -and
    $devicePreflightText.Contains("gate = 'device-control-preflight'") -and
    $devicePreflightText.Contains('acceptanceEligible = $false') -and
    $devicePreflightText.Contains('productBehaviorClaimed = $false') -and
    $devicePreflightText.Contains('Get-PreflightFailureDomain') -and
    -not $devicePreflightText.Contains('aa start') -and
    -not $devicePreflightText.Contains('power-shell wakeup') -and
    -not $devicePreflightText.Contains('Start-LeanTTYRegressionApp')
) 'Device preflight mutates product state, repairs the target, or claims product acceptance'

$idleState = Get-LeanTTYAcceptanceIdleInputState -Logs @'
ACCEPTANCE_IDLE_RESULT kind=0,input=partial,completionActive=false,menuActive=false
ACCEPTANCE_IDLE_RESULT kind=0,input=exact command,completionActive=false,menuActive=false
'@
Assert-True (
    $null -ne $idleState -and $idleState.input -ceq 'exact command' -and
    -not $idleState.completionActive -and -not $idleState.menuActive
) 'Acceptance input parser did not return the last native command-buffer state'

& {
    $script:injectedText = [Collections.Generic.List[string]]::new()
    $script:submittedKeyCodes = [Collections.Generic.List[int]]::new()
    $script:interruptCount = 0
    $script:bufferChecks = 0
    function Clear-LeanTTYAppLogs { param($Hdc, $Target) }
    function Invoke-LeanTTYDeviceCtrlC {
        param($Hdc, $Target)
        $script:interruptCount++
    }
    function Wait-LeanTTYAppLog {
        param($Hdc, $Target, $ProcessId, $Pattern, $TimeoutSeconds)
        if ($Pattern -match 'ACCEPTANCE_IDLE_INTERRUPT') { return 'cleared' }
        if ($Pattern -match 'ACCEPTANCE_INPUT_SUBMIT') {
            $logs = @'
ACCEPTANCE_INPUT_SUBMIT sequence=1,kind=command,input=echo LEANTTY_SMOKE
ACCEPTANCE_IDLE_RESULT kind=1,input=,completionActive=false,menuActive=false
'@
            if ($logs -notmatch $Pattern) { throw 'submission acknowledgement pattern did not match' }
            return $logs
        }
        throw "Unexpected log wait: $Pattern"
    }
    function Wait-LeanTTYAcceptanceIdleInputState {
        param($Hdc, $Target, $ProcessId, $Expected, $TimeoutSeconds)
        $script:bufferChecks++
        if ($script:bufferChecks -eq 1) {
            return [pscustomobject]@{ input = 'echo LEANTTY_SMOK'; exact = $false }
        }
        return [pscustomobject]@{ input = $Expected; exact = $true }
    }
    function Invoke-LeanTTYDeviceText {
        param($Hdc, $Target, $Text, $InputNode)
        Assert-True ($null -ne $InputNode) 'Verified command input was not coordinate-targeted'
        $script:injectedText.Add($Text)
    }
    function Invoke-LeanTTYDeviceKey {
        param($Hdc, $Target, $KeyCode)
        $script:submittedKeyCodes.Add($KeyCode)
    }

    $observations = [Collections.Generic.List[object]]::new()
    $result = Submit-LeanTTYDeviceCommand `
        -Hdc 'unused' `
        -Target 'unused' `
        -ProcessId '1234' `
        -Command 'echo LEANTTY_SMOKE' `
        -Stage 'short-write-retry' `
        -ObservationSink $observations `
        -InputNodeProvider { [pscustomobject]@{ attributes = @{ bounds = '[0,0][10,10]' } } }
    $summary = Get-LeanTTYDeviceCommandAutomationSummary `
        -Observations $observations `
        -BusinessVerdict 'passed' `
        -BusinessPostcondition 'fixture-observed-command-result'
    $summaryJson = ConvertTo-Json -InputObject $summary -Depth 8 -Compress
    Assert-True (
        $result.inputAttempts -eq 2 -and
        $script:injectedText.Count -eq 2 -and
        $script:interruptCount -eq 2 -and
        $script:submittedKeyCodes.Count -eq 1 -and
        $script:submittedKeyCodes[0] -eq 2054 -and
        $summary.businessVerdict -eq 'passed' -and
        $summary.harnessStability -eq 'flaky-harness' -and
        $summary.inputAttemptCount -eq 2 -and
        $summary.inputMismatchCount -eq 1 -and
        $summary.enterCount -eq 1 -and
        $summary.commands[0].stage -eq 'short-write-retry' -and
        $summary.commands[0].actualLength -eq 18 -and
        $summary.commands[0].lastProvenBoundary -eq 'submission-acknowledged' -and
        $summaryJson -notmatch 'LEANTTY_SMOKE'
    ) 'Verified command contract did not retry before Enter and submit exactly once'
}

& {
    function Clear-LeanTTYAppLogs { param($Hdc, $Target) }
    function Invoke-LeanTTYDeviceCtrlC { param($Hdc, $Target) }
    function Wait-LeanTTYAcceptanceIdleInputState {
        param($Hdc, $Target, $ProcessId, $Expected, $TimeoutSeconds)
        return [pscustomobject]@{ input = $Expected; exact = $true }
    }
    function Invoke-LeanTTYDeviceText { param($Hdc, $Target, $Text, $InputNode) }
    function Invoke-LeanTTYDeviceKey { param($Hdc, $Target, $KeyCode) }
    function Wait-LeanTTYAppLog {
        param($Hdc, $Target, $ProcessId, $Pattern, $TimeoutSeconds)
        if ($Pattern -match 'ACCEPTANCE_IDLE_INTERRUPT') { return 'cleared' }
        throw 'submission acknowledgement missing'
    }
    $message = ''
    $observations = [Collections.Generic.List[object]]::new()
    try {
        Submit-LeanTTYDeviceCommand `
            -Hdc 'unused' -Target 'unused' -ProcessId '1234' -Command 'key list' `
            -Stage 'missing-submit-ack' -ObservationSink $observations `
            -InputNodeProvider {
                [pscustomobject]@{ attributes = @{ bounds = '[0,0][10,10]' } }
            } | Out-Null
    } catch {
        $message = $_.Exception.Message
    }
    $summary = Get-LeanTTYDeviceCommandAutomationSummary `
        -Observations $observations `
        -BusinessVerdict 'unknown' `
        -BusinessPostcondition 'command-result-not-observable'
    Assert-True (
        $message -match 'unknown' -and
        $summary.businessVerdict -eq 'unknown' -and
        $summary.harnessStability -eq 'unknown' -and
        $summary.enterCount -eq 1 -and
        $summary.commands[0].failureDomain -eq 'unknown' -and
        $summary.commands[0].lastProvenBoundary -eq 'enter-dispatched'
    ) (
        'Missing post-Enter acknowledgement was not classified as an unknown outcome'
    )
}

$environmentSummary = Get-LeanTTYDeviceCommandAutomationSummary `
    -Observations @([pscustomobject]@{
        result = 'failed'
        failureDomain = 'environment'
        inputAttempts = 1
        inputMismatches = 0
        enterCount = 0
    }) `
    -BusinessVerdict 'failed' `
    -BusinessPostcondition 'not-reached'
Assert-True ($environmentSummary.harnessStability -eq 'not-assessed') (
    'Environment interruption was incorrectly classified as a harness failure'
)

& {
    $prepared = [pscustomobject]@{ command = $null }
    $script:dynamicEnterCount = 0
    function Clear-LeanTTYAppLogs { param($Hdc, $Target) }
    function Invoke-LeanTTYDeviceCtrlC { param($Hdc, $Target) }
    function Wait-LeanTTYAppLog {
        param($Hdc, $Target, $ProcessId, $Pattern, $TimeoutSeconds)
        return 'acknowledged'
    }
    function Wait-LeanTTYAcceptanceIdleInputState {
        param($Hdc, $Target, $ProcessId, $Expected, $TimeoutSeconds)
        return [pscustomobject]@{ input = $Expected; exact = $true }
    }
    function Invoke-LeanTTYDeviceKey {
        param($Hdc, $Target, $KeyCode)
        $script:dynamicEnterCount++
    }
    $result = Submit-LeanTTYDeviceCommand `
        -Hdc 'unused' -Target 'unused' -ProcessId '1234' `
        -InputNodeProvider {
            [pscustomobject]@{ attributes = @{ bounds = '[0,0][10,10]' } }
        } `
        -InputPreparer { param($inputNode, $inputAttempt) $prepared.command = 'completed command' } `
        -ExpectedCommandProvider { param($inputAttempt) $prepared.command }
    Assert-True (
        $result.expectedLength -eq 17 -and $script:dynamicEnterCount -eq 1
    ) 'Prepared Tab/Unicode command did not reuse the exact pre-submit contract'
}

& {
    $script:targetFailureResets = 0
    $script:targetFailureEnters = 0
    $observations = [Collections.Generic.List[object]]::new()
    function Reset-LeanTTYDeviceCommandInput { $script:targetFailureResets++ }
    function Clear-LeanTTYAppLogs {}
    function Invoke-LeanTTYDeviceKey { $script:targetFailureEnters++ }
    $expectedTarget = @{ attributes = @{ type='textField'; hint='private-hint'; hierarchy='ROOT9,0' } }
    $currentTarget = @{ attributes = @{ type='textField'; hint='private-hint'; hierarchy='ROOT9,1' } }
    $targetError = New-LeanTTYTextInputFailure -Message '[harness] Synthetic owner loss' -Phase after `
        -ExpectedNode $expectedTarget -CurrentNodes @($currentTarget)
    $caught = $null
    try {
        Submit-LeanTTYDeviceCommand -Hdc 'unused' -Target 'unused' -ProcessId '100' `
            -Command 'public-input' -Stage 'owner-loss-before-submit' -ObservationSink $observations `
            -InputNodeProvider { $expectedTarget } -InputPreparer { throw $targetError } | Out-Null
    } catch { $caught = $_.Exception }
    Assert-True ([object]::ReferenceEquals($caught, $targetError) -and $observations.Count -eq 1 -and
        $observations[0].result -eq 'failed' -and $observations[0].failureDomain -eq 'harness' -and
        $observations[0].textTargetFailure.phase -eq 'after' -and $observations[0].inputAttempts -eq 1 -and
        $observations[0].enterCount -eq 0 -and $script:targetFailureEnters -eq 0 -and
        $script:targetFailureResets -eq 1) 'Owner loss was not retained or triggered a retry, reset or Enter'
    Assert-True (($observations | ConvertTo-Json -Depth 12) -notmatch 'private-hint|ROOT9|public-input') (
        'Ordinary command failure evidence exposed target identifiers or input text'
    )
}

$deviceTextSource = (Get-Command Invoke-LeanTTYDeviceText).Definition
foreach ($evidenceOwner in @('verify-ssh-auth-pc.ps1', 'verify-key-passphrase-pc.ps1')) {
    $evidenceSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot $evidenceOwner) -Raw
    Assert-True ($evidenceSource.Contains('postInputSettleMilliseconds = 0')) (
        "$evidenceOwner still reports a fixed input delay that the shared helper no longer applies"
    )
}
$submitCommandParameters = (Get-Command Submit-LeanTTYDeviceCommand).Parameters.Keys
$submitCommandSource = (Get-Command Submit-LeanTTYDeviceCommand).Definition
$automationSummarySource = (Get-Command Get-LeanTTYDeviceCommandAutomationSummary).Definition
Assert-True (
    $deviceTextSource.Contains("'shell', 'uitest', 'uiInput', 'inputText', `$center.x, `$center.y, `$Text") -and
    -not $deviceTextSource.Contains("@('uiInput', 'text', `$Text)") -and
    $deviceTextSource.Contains('Get-HdcUiLayout') -and
    $deviceTextSource.Contains('[harness] Intended HarmonyOS text target is no longer uniquely focused')
) 'Ordinary device text does not atomically revalidate and target its intended focus node'
Assert-True (
    $submitCommandParameters -contains 'ProcessId' -and
    $submitCommandParameters -contains 'InputNodeProvider' -and
    $submitCommandParameters -contains 'ObservationSink' -and
    $submitCommandParameters -contains 'Stage' -and
    $submitCommandSource.Contains('Wait-LeanTTYAcceptanceIdleInputState') -and
    $submitCommandSource.Contains('ACCEPTANCE_INPUT_SUBMIT') -and
    -not $submitCommandSource.Contains('Get-LeanTTYTerminalInputText') -and
    $automationSummarySource.Contains("'flaky-harness'") -and
    $automationSummarySource.Contains('businessPostcondition') -and
    $automationSummarySource.Contains('inputMismatchCount')
) 'Device command submission does not enforce the native pre-submit buffer contract'

foreach ($ordinaryCommandOwner in @(
        'verify-key-passphrase-pc.ps1',
        'verify-ssh-auth-pc.ps1',
        'verify-terminal-search-pc.ps1',
        'verify-proxy-jump-pc.ps1',
        'verify-put-get-pc.ps1',
        'verify-startup-readiness-pc.ps1',
        'verify-startup-upgrade-pc.ps1'
    )) {
    $ownerText = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot $ordinaryCommandOwner)
    Assert-True (
        $ownerText.Contains('Submit-LeanTTYDeviceCommand') -and
        $ownerText.Contains('-ObservationSink') -and
        $ownerText.Contains('Get-LeanTTYDeviceCommandAutomationSummary')
    ) (
        "$ordinaryCommandOwner bypasses the observable ordinary command contract"
    )
}

$keyPassphraseVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-key-passphrase-pc.ps1'
) -Raw
Assert-True (
    $keyPassphraseVerifier.Contains('Submit-LeanTTYDeviceCommand') -and
    -not $keyPassphraseVerifier.Contains("-Pattern 'ACCEPTANCE_IDLE_RESULT kind='")
) 'Key-passphrase verifier still duplicates the ordinary command submission contract'

$center = Get-LeanTTYBoundsCenter -Bounds '[1900,1200][2200,1300]'
Assert-True ($center.x -eq 2050 -and $center.y -eq 1250) (
    'Native-layout button coordinates were not calculated correctly'
)

Assert-LeanTTYLayoutExcludesValues -Layout $layout -Values @('runtime-only-secret')
Assert-Throws -Action {
    Assert-LeanTTYLayoutExcludesValues -Layout $layout -Values @('regression_key')
} -Message 'Layout secret detection did not reject an exposed value'

Assert-Throws -Action {
    Get-LeanTTYBoundsCenter -Bounds '[0,0][bad,20]'
} -Message 'Malformed device bounds were accepted'

$appLogParameters = (Get-Command Get-LeanTTYAppLogs).Parameters.Keys
$waitLogParameters = (Get-Command Wait-LeanTTYAppLog).Parameters.Keys
$waitLogSource = (Get-Command Wait-LeanTTYAppLog).Definition
$layoutCaptureSource = (Get-Command Get-LeanTTYDeviceLayout).Definition
$layoutCaptureParameters = (Get-Command Get-LeanTTYDeviceLayout).Parameters
$layoutPrimitiveSource = (Get-Command Get-HdcUiLayout).Definition
$physicalKeySource = (Get-Command Invoke-LeanTTYDevicePhysicalKey).Definition
Assert-True (
    $appLogParameters -notcontains 'Pid' -and
    $waitLogParameters -notcontains 'Pid' -and
    $waitLogSource.Contains('[ValidateRange(1, 60)]') -and
    $waitLogSource.Contains('Start-Sleep -Milliseconds 1000') -and
    -not $waitLogSource.Contains('Start-Sleep -Milliseconds 200')
) 'Device log helpers conflict with the read-only PowerShell PID automatic variable'
Assert-True (
    $layoutCaptureSource.Contains('for ($captureAttempt = 1; $captureAttempt -le 2; $captureAttempt++)') -and
    $layoutCaptureSource.Contains('HarmonyOS UI layout remained empty after two captures')
) 'Transient empty UiTest layouts are not handled by one bounded idempotent retry'
Assert-True (
    $layoutCaptureParameters.ContainsKey('BundleName') -and
    $layoutCaptureSource.Contains("[string]`$BundleName = 'com.leantty.app'") -and
    $layoutCaptureSource.Contains('Get-HdcUiLayout') -and
    $layoutPrimitiveSource.Contains("if (-not [string]::IsNullOrWhiteSpace(`$BundleName))") -and
    $layoutPrimitiveSource.Contains('Receive-HdcFileChecked') -and
    $devicePreflightText.Contains("-BundleName ''")
) 'Generic device preflight cannot request a global layout without launching LeanTTY'

$awakeLeaseParameter = (Get-Command Start-LeanTTYDeviceAwakeLease).Parameters['TimeoutMilliseconds']
Assert-True (
    $awakeLeaseParameter.Attributes.Where({ $_ -is [Management.Automation.ValidateRangeAttribute] }).MaxRange `
        -ge 7200000
) 'Device awake lease cannot cover the declared full-matrix budget'
Assert-True (
    $physicalKeySource.Contains('$process.WaitForExit(5000)') -and
    $physicalKeySource.Contains('$process.Kill($true)') -and
    $physicalKeySource.Contains('$attempt -le 2')
) 'Physical key injection can hang the device verification without a bounded retry'

$authenticationPattern = 'File transfer authentication prompt=(host-key|password)'
$liveOnlyObservation = Resolve-LeanTTYAuthenticationObservation `
    -SnapshotLogs '' `
    -LiveLogs 'File transfer authentication prompt=host-key' `
    -Pattern $authenticationPattern
$snapshotOnlyObservation = Resolve-LeanTTYAuthenticationObservation `
    -SnapshotLogs 'File transfer authentication prompt=password' `
    -LiveLogs '' `
    -Pattern $authenticationPattern
$dualObservation = Resolve-LeanTTYAuthenticationObservation `
    -SnapshotLogs 'File transfer authentication prompt=password' `
    -LiveLogs 'File transfer authentication prompt=password' `
    -Pattern $authenticationPattern
$missingObservation = Resolve-LeanTTYAuthenticationObservation `
    -SnapshotLogs '' -LiveLogs '' -Pattern $authenticationPattern
Assert-True (
    $liveOnlyObservation.liveObserved -and -not $liveOnlyObservation.snapshotObserved -and
    $snapshotOnlyObservation.snapshotObserved -and -not $snapshotOnlyObservation.liveObserved -and
    $dualObservation.snapshotObserved -and $dualObservation.liveObserved -and
    $null -eq $missingObservation
) 'Authentication observation does not distinguish snapshot loss from an unobserved product state'

$deviceRegressionText = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'device-regression.ps1'
) -Raw
$authFixtureLauncherText = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'start-ssh-auth-fixture.ps1'
) -Raw
$authFixtureSourceText = Get-Content -LiteralPath (
    Join-Path $repoRoot 'leantty_ssh\ssh-auth-fixture\src\main.rs'
) -Raw
Assert-True (
    $authFixtureLauncherText.Contains('[ValidateRange(1, 7200)]')
) 'SSH authentication fixture does not allow the bounded full acceptance budget'
Assert-True (
    $authFixtureLauncherText.Contains('[string]$MoshServerAddress') -and
    $authFixtureLauncherText.Contains('[int]$MoshServerPort = 0') -and
    $authFixtureLauncherText.Contains('MoshServerAddress must be one IPv4 address') -and
    $authFixtureLauncherText.Contains("channel-denied, mosh'")
) 'SSH authentication fixture launcher lacks the opt-in IPv4 Mosh endpoint contract'
Assert-True (
    $authFixtureSourceText.Contains(
        'const MOSH_FIXTURE_NETWORK_TIMEOUT_SECONDS: u64 = 30;'
    )
) 'Controlled Mosh fixture network timeout can no longer distinguish graceful close from fallback cleanup'
Assert-True (
    $authFixtureSourceText.Contains('const MOSH_SHELL_COMMAND: &str = "ltty-mosh-shell";') -and
    $authFixtureSourceText.Contains('const MOSH_TMUX_COMMAND: &str = "ltty-mosh-tmux";') -and
    $authFixtureSourceText.Contains('const MOSH_EDITOR_COMMAND: &str = "ltty-mosh-editor";') -and
    $authFixtureSourceText.Contains('const MOSH_RESIZE_COMMAND: &str = "ltty-mosh-resize";') -and
    $authFixtureSourceText.Contains('const MOSH_STREAM_INPUT_BYTES: usize = 512;') -and
    $authFixtureSourceText.Contains('parse_mosh_bootstrap_request') -and
    $authFixtureSourceText.Contains('mosh-server returned a port outside the requested range') -and
    $authFixtureSourceText.Contains('StdCommand::new("/bin/bash")') -and
    $authFixtureSourceText.Contains('StdCommand::new("tmux")') -and
    $authFixtureSourceText.Contains('bind -x') -and
    $authFixtureSourceText.Contains('\\C-g') -and
    $authFixtureSourceText.Contains('StdCommand::new("vim")') -and
    $authFixtureSourceText.Contains('control_directory.join("mosh-terminal-pid")') -and
    $authFixtureSourceText.Contains('control_directory.join("mosh-kernel-echo")') -and
    $authFixtureSourceText.Contains('.join("mosh-prediction-relay")') -and
    $authFixtureSourceText.Contains('.join("mosh-prediction-relay-paused")') -and
    $authFixtureSourceText.Contains('.join("mosh-prediction-relay-stats")') -and
    $authFixtureSourceText.Contains('control_directory.join("mosh-prediction-event")') -and
    $authFixtureSourceText.Contains('StdCommand::new("/bin/sh")') -and
    $authFixtureSourceText.Contains('.env("PS1", "MOSH_SESSION> ")') -and
    $authFixtureSourceText.Contains('.env("LTTY_MOSH_PREDICTION_EVENT", &prediction_event_path)') -and
    $authFixtureSourceText.Contains('rewrite_mosh_bootstrap_port') -and
    $authFixtureSourceText.Contains('MOSH_PREDICTION_RELAY_DELAY') -and
    $authFixtureSourceText.Contains('forward_mosh_prediction_client_datagrams') -and
    $authFixtureSourceText.Contains('forward_mosh_prediction_server_datagrams') -and
    $authFixtureSourceText.Contains('mosh_terminal_stty_args(kernel_echo)') -and
    -not $authFixtureSourceText.Contains('if prediction_echo_path.is_file()')
) 'Controlled Mosh fixture no longer launches the real shell, tmux, editor, resize and stream workloads'
Assert-True (
    $deviceRegressionText -notmatch 'hilog\s+-x[^\r\n]*\s-z\s'
) 'Device log query combines mutually exclusive hilog exit and tail modes'
Assert-True (
    $deviceRegressionText.Contains(
        'EntryAbility,IndexPage,'
    ) -and
    $deviceRegressionText.Contains(
        'TerminalSurfaceController,TerminalBridge,AppViewModel,BackgroundBellNotification'
    ) -and
    -not $deviceRegressionText.Contains('EntryAbility,Index,IndexPage')
) 'Device log query omits the Pane attention state owner'
Assert-True (
    $deviceRegressionText -notmatch 'terminal-line cleanup|backspaceCount'
) 'Device input cleanup still uses inferred backspaces'
Assert-True (
    $deviceRegressionText.Contains("'shell', 'uitest', 'uiInput', 'inputText', `$center.x, `$center.y, `$Text") -and
    -not $deviceRegressionText.Contains('ConvertTo-LeanTTYDeviceTextKeyCommand') -and
    $deviceRegressionText.Contains('HarmonyOS pre-input focus layout capture')
) 'Ordinary device text does not use the focus-verified targeted UiTest path'
Assert-True (
    $deviceRegressionText.Contains('function Invoke-LeanTTYSerializedUiTest') -and
    $deviceRegressionText.Contains('[Threading.Mutex]::new') -and
    $deviceRegressionText.Contains('$mutex.WaitOne(60000)')
) 'UiTest operations are not serialized across concurrent device harness processes'
Assert-True (
    $deviceRegressionText -notmatch 'shell\s+run-as\s+com\.leantty\.app' -and
    $deviceRegressionText -match 'shell\s+-b\s+com\.leantty\.app'
) 'Device key-state inspection does not use the HarmonyOS bundle shell'

$clearInputParameters = (Get-Command Clear-LeanTTYDeviceInput).Parameters.Keys
$clearInputSource = (Get-Command Clear-LeanTTYDeviceInput).Definition
Assert-True (
    $clearInputParameters -notcontains 'LayoutPath' -and
    $clearInputSource.Contains('Invoke-LeanTTYDeviceCtrlC') -and
    -not $clearInputSource.Contains('Get-LeanTTYTerminalInputText')
) 'Device input cleanup still accepts the non-authoritative ArkWeb layout readback'

& {
    $script:ctrlCCount = 0
    function Invoke-LeanTTYDeviceCtrlC {
        param($Hdc, $Target)
        $script:ctrlCCount++
    }
    Clear-LeanTTYDeviceInput -Hdc 'unused' -Target 'unused'
    Assert-True ($script:ctrlCCount -eq 1) (
        'Device input cleanup did not use the single application interrupt path'
    )
}

Assert-True (
    $null -ne (Get-Command Start-LeanTTYDeviceAwakeLease -ErrorAction SilentlyContinue) -and
    $null -ne (Get-Command Stop-LeanTTYDeviceAwakeLease -ErrorAction SilentlyContinue)
) 'Device regression has no reversible screen-timeout lease'

Assert-True (
    $null -ne (Get-Command ConvertTo-LeanTTYDevicePasswordKeyCommand -ErrorAction SilentlyContinue) -and
    $null -ne (Get-Command Assert-LeanTTYCredentialPathOutsideRepository -ErrorAction SilentlyContinue) -and
    $null -ne (Get-Command Start-LeanTTYRegressionApp -ErrorAction SilentlyContinue) -and
    $null -ne (Get-Command Wait-LeanTTYTerminalInputLayout -ErrorAction SilentlyContinue)
) 'Device regression has no conditional local-credential unlock helpers'
$passwordKeyCommand = ConvertTo-LeanTTYDevicePasswordKeyCommand -Password 'abc'
Assert-True (
    $passwordKeyCommand -eq (
        'uinput -K -d 2017 -u 2017 -d 2018 -u 2018 -d 2019 -u 2019 ' +
        '-d 2054 -u 2054'
    ) -and
    -not $passwordKeyCommand.Contains('abc')
) 'Device unlock command does not convert plaintext to the expected non-secret key events'
Assert-Throws -Action {
    ConvertTo-LeanTTYDevicePasswordKeyCommand -Password 'unsafe value'
} -Message 'Device unlock accepted an unsupported password alphabet'
Assert-Throws -Action {
    Assert-LeanTTYCredentialPathOutsideRepository `
        -CredentialPath (Join-Path $PSScriptRoot 'device-password.txt') `
        -RepositoryRoot (Split-Path $PSScriptRoot -Parent)
} -Message 'Device unlock accepted a credential file inside the repository'

$keyPresenceCommand = Get-Command Test-LeanTTYDeviceKeyFilesPresent -ErrorAction SilentlyContinue
Assert-True ($null -ne $keyPresenceCommand) (
    'Device cleanup has no independent app-sandbox key-file verification helper'
)
$keyEnumerationCommand = Get-Command Get-LeanTTYDeviceRegressionKeyNames -ErrorAction SilentlyContinue
Assert-True ($null -ne $keyEnumerationCommand) (
    'Authentication matrix has no bounded disposable-key enumeration helper'
)
Assert-Throws -Action {
    Test-LeanTTYDeviceKeyFilesPresent `
        -Hdc 'unused' `
        -Target 'unused' `
        -KeyName '../unsafe'
} -Message 'Device key-file verification accepted an unsafe generated-key name'

$deviceRegressionSource = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'device-regression.ps1'
) -Raw
Assert-True (
    $deviceRegressionSource.Contains(
        '-T SessionViewModel,KeyCommandService,SshClient,FileTransferClient,EntryAbility,Index'
    ) -and
    $deviceRegressionSource.Contains('-T MoshClient')
) 'Device application log capture omits authentication or window lifecycle events'

$splitLayout = @'
{
  "attributes": {"bounds":"[0,0][3120,1955]","hint":""},
  "children": [
    {"attributes":{"bounds":"[127,495][145,536]","hint":"Terminal input","focused":"false"},"children":[]},
    {"attributes":{"bounds":"[1694,135][1712,176]","hint":"Terminal input","focused":"true"},"children":[]}
  ]
}
'@ | ConvertFrom-Json -Depth 20
$splitInputs = @(Get-LeanTTYTerminalInputNodes -Layout $splitLayout)
Assert-True (
    $splitInputs.Count -eq 2 -and
    $splitInputs[0].attributes.bounds -eq '[127,495][145,536]' -and
    $splitInputs[1].attributes.bounds -eq '[1694,135][1712,176]'
) 'Terminal input nodes did not preserve layout traversal order'

# Web bounds can overlap in UiTest while each hidden textarea follows its own
# cursor. Pane selection must survive both reversed and identical cursor X.
$overlappingPaneLayout = @'
{
  "attributes": {"type":"Stack","bounds":"[0,0][2000,1000]"},
  "children": [
    {"attributes":{"type":"Web","bounds":"[1000,0][2000,1000]"},"children":[
      {"attributes":{"type":"textField","bounds":"[1613,589][1632,630]","hint":"Terminal input","focused":"true"},"children":[]}
    ]},
    {"attributes":{"type":"Web","bounds":"[1000,0][2000,1000]"},"children":[
      {"attributes":{"type":"textField","bounds":"[1541,749][1560,790]","hint":"Terminal input","focused":"false"},"children":[]}
    ]}
  ]
}
'@ | ConvertFrom-Json -Depth 20
$orderedPaneInputs = @(Get-LeanTTYTerminalInputNodes -Layout $overlappingPaneLayout)
Assert-True (
    $orderedPaneInputs.Count -eq 2 -and
    [object]::ReferenceEquals($orderedPaneInputs[0], $overlappingPaneLayout.children[0].children[0]) -and
    [object]::ReferenceEquals($orderedPaneInputs[1], $overlappingPaneLayout.children[1].children[0]) -and
    $orderedPaneInputs[0].attributes.focused -ceq 'true'
) 'Pane order was reversed by hidden textarea cursor coordinates'
$overlappingPaneLayout.children[1].children[0].attributes.bounds = '[1613,749][1632,790]'
$orderedPaneInputs = @(Get-LeanTTYTerminalInputNodes -Layout $overlappingPaneLayout)
Assert-True (
    [object]::ReferenceEquals($orderedPaneInputs[0], $overlappingPaneLayout.children[0].children[0]) -and
    [object]::ReferenceEquals($orderedPaneInputs[1], $overlappingPaneLayout.children[1].children[0])
) 'Pane order changed when cursor X coordinates were identical'

& {
    $script:focusLayoutIndex = 0
    $script:focusClickCalls = [Collections.Generic.List[object]]::new()
    $focusLayouts = @(
        (@'
{"attributes":{"bounds":"[0,0][0,0]","hint":""},"children":[]}
'@ | ConvertFrom-Json -Depth 20),
        (@'
{"attributes":{"bounds":"[0,0][3120,1955]","hint":""},"children":[{"attributes":{"bounds":"[127,495][145,536]","hint":"Terminal input","focused":"true"},"children":[]},{"attributes":{"bounds":"[1694,135][1712,176]","hint":"Terminal input","focused":"false"},"children":[]}]}
'@ | ConvertFrom-Json -Depth 20)
    )
    function Invoke-FocusHdc {
        $script:focusClickCalls.Add(@($args))
        $global:LASTEXITCODE = 0
    }
    function Get-LeanTTYDeviceLayout {
        param($Hdc, $Target, $LocalPath)
        $layout = $focusLayouts[[Math]::Min($script:focusLayoutIndex, $focusLayouts.Count - 1)]
        $script:focusLayoutIndex++
        return $layout
    }

    $focusedLayout = Set-LeanTTYTerminalInputFocus `
        -Hdc 'Invoke-FocusHdc' `
        -Target 'regression-device' `
        -InputNode $splitInputs[0] `
        -LocalPath 'unused.json' `
        -TimeoutSeconds 2
    $focusedNodes = @(Get-LeanTTYTerminalInputNodes -Layout $focusedLayout | Where-Object {
        [string]$_.attributes.focused -eq 'true'
    })
    Assert-True (
        $script:focusClickCalls.Count -eq 1 -and
        ($script:focusClickCalls[0] -join ' ') -match 'uiInput click 136 516' -and
        $script:focusLayoutIndex -eq 2 -and
        $focusedNodes.Count -eq 1 -and
        $focusedNodes[0].attributes.bounds -eq '[127,495][145,536]'
    ) 'Terminal focus gate did not accept one focused post-click snapshot'
}

Assert-True (
    $deviceRegressionSource.Contains(
        '[ValidateRange(1, 60)][int]$TimeoutSeconds = 30'
    )
) 'Terminal focus gate does not allow a slow HarmonyOS layout capture to retry'

foreach ($scriptName in @(
    'device-regression.ps1',
    'preflight-device.ps1',
    'verify-key-passphrase-pc.ps1',
    'verify-ssh-auth-pc.ps1',
    'verify-host-identity-pc.ps1',
    'verify-terminal-search-pc.ps1',
    'verify-background-bell-notification-pc.ps1',
    'verify-background-bell-permission-pc.ps1',
    'verify-long-task-notification-pc.ps1',
    'verify-proxy-jump-pc.ps1',
    'verify-mosh-pc.ps1',
    'verify-mosh-matrix-pc.ps1'
)) {
    $scriptPath = Join-Path $PSScriptRoot $scriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Device regression script is missing: $scriptName"
    }
    $content = Get-Content -LiteralPath $scriptPath -Raw
    Assert-True ($content -notmatch '3QC[0-9A-Z]{8,}') (
        "$scriptName contains a fixed physical device identifier"
    )
    if ($scriptName -eq 'verify-key-passphrase-pc.ps1') {
        Assert-True (
            $content.Contains('Device behavior harness requires a clean committed tree') -and
            $content.Contains('harness = [ordered]@{')
        ) 'Device behavior evidence is not bound to a clean committed harness'
        Assert-True (
            $content.Contains('schemaVersion = 2') -and
            $content.Contains('cleanup = [ordered]@{') -and
            $content.Contains('durationMs =')
        ) 'Device behavior evidence does not record stage timing and cleanup outcome'
        Assert-True (
            $content.Contains("'device-harness-preflight'") -and
            $content.Contains('Test-LeanTTYDeviceKeyFilesPresent') -and
            $content.Contains('Disposable key files disappeared after rejected old passphrase') -and
            $content.Contains("'failure-app-logs.txt'") -and
            $content.Contains("'[REDACTED]'")
        ) 'Device scenario does not preflight telemetry and independently verify cleanup'
        Assert-True (
            $content.Contains('Start-LeanTTYDeviceAwakeLease') -and
            $content.Contains('Stop-LeanTTYDeviceAwakeLease')
        ) 'Device scenario does not acquire and restore a screen-timeout lease'
        Assert-True (
            $content.Contains('UnlockPasswordPath') -and
            $content.Contains('Start-LeanTTYRegressionApp') -and
            $content.Contains('Wait-LeanTTYTerminalInputLayout') -and
            $content.Contains('Set-LeanTTYTerminalInputFocus') -and
            $content.Contains('deviceUnlock = $deviceUnlockResult')
        ) 'Device scenario does not record conditional local-credential unlock behavior'
    }
    if ($scriptName -eq 'verify-ssh-auth-pc.ps1') {
        Assert-True (
            $content.Contains('$harnessDirty -and -not $DiagnosticHap') -and
            $content.Contains('Assert-LeanTTYCandidateHarnessCompatibility') -and
            $content.Contains("'tools/start-ssh-auth-fixture.ps1'") -and
            $content.Contains("'tools/hdc-common.ps1'") -and
            $content.Contains('harness = [ordered]@{')
        ) 'SSH authentication evidence does not separate candidate and harness identity safely'
        Assert-True (
            $content.Contains('rport "tcp:$FixturePort"') -and
            $content.Contains('fport rm "tcp:$FixturePort" "tcp:$FixturePort"') -and
            $content.Contains('Assert-AuthControlChannels') -and
            $content.Contains('Assert-HdcTargetReady') -and
            $content.Contains('cleanup = [ordered]@{')
        ) 'SSH authentication fixture mapping is not paired with recorded cleanup'
        Assert-True (
            $content.Contains('Assert-LeanTTYLayoutExcludesValues') -and
            $content.Contains('HarmonyOS application logs exposed a temporary SSH fixture secret') -and
            $content.Contains("'failure-fixture-stderr.txt'") -and
            $content.Contains("'[REDACTED]'") -and
            -not $content.Contains('Device auth input delivery length mismatch') -and
            -not $content.Contains('Get-AuthInputEventCount') -and
            -not $content.Contains('Authentication input character was not acknowledged after three attempts') -and
            -not $content.Contains('Invoke-AcknowledgedAuthText') -and
            -not $content.Contains('Invoke-SerializedAuthText') -and
            -not $content.Contains('Invoke-SecretKeyEventText') -and
            $content.Contains('function Invoke-AuthUiText') -and
            ([regex]::Matches($content, 'Invoke-AuthUiText').Count -ge 5) -and
            -not $content.Contains("'layout-auth-text-focus-' + [Guid]::NewGuid().ToString('N') + '.json'") -and
            $content.Contains('-Hdc $hdc -Target $Target -Text $Text -InputNode $InputNode') -and
            $content.Contains('function Invoke-TemporaryFixtureAuthText') -and
            ([regex]::Matches($content, 'Invoke-TemporaryFixtureAuthText').Count -ge 6) -and
            $content.Contains("'^[a-z0-9]+$'") -and
            $content.Contains('repository-only-test-values-not-user-or-production-credentials') -and
            $content.Contains('harmony-uitest-focus-verified-inputText-runtime-generated-temporary-fixture-values') -and
            $content.Contains("method = 'harmony-uitest-text-and-raw-physical-special-keys'") -and
            $content.Contains("ordinaryTextInjection = 'harmony-uitest-focus-verified-inputText'") -and
            $content.Contains("physicalKeyInjection = 'raw-key-events-special-keys-only'") -and
            $content.Contains('Submit-FocusedDeviceCommand') -and
            $content.Contains('Submit-LeanTTYDeviceCommand') -and
            $content.Contains('-ProcessId $appPid') -and
            $content.Contains('-InputNodeProvider') -and
            -not $content.Contains("-Pattern 'ACCEPTANCE_IDLE_RESULT kind='") -and
            $content.Contains("'ltty-exit'") -and
            $content.Contains("'shell command=exit result=closed'") -and
            $content.Contains('Assert-AuthCommandStarted') -and
            $content.Contains("'[environment] Device key injection did not start the SSH command'") -and
            -not $content.Contains('SSH connect initiated:') -and
            $content.Contains('Activate-RegressionWindow') -and
            $content.Contains('function Assert-RegressionProcessUnchanged') -and
            ([regex]::Matches($content, 'Assert-RegressionProcessUnchanged -Action').Count -eq 3) -and
            $content.Contains("process identity was unavailable while `$Action") -and
            $content.Contains('Focus-ActiveCommandInput') -and
            $content.Contains('Invoke-LeanTTYDeviceClick') -and
            $content.Contains('if ($focusedInputs.Count -eq 1)') -and
            $content.Contains('return $focusedInputs[0]') -and
            $content.Contains('businessOutcomeRequired = $true') -and
            $content.Contains('fixedDelayUsedAsVerdict = $false')
        ) 'SSH authentication scenario does not enforce the layout/log secret boundary'
        Assert-True (
            $content.Contains("'terminal-key-input'") -and
            $content.Contains("Start-AuthCommand -User 'navigation'") -and
            $content.Contains("left = 'navigation input hex=1b 5b 44'") -and
            $content.Contains("right = 'navigation input hex=1b 5b 43'") -and
            $content.Contains("ctrlP = 'navigation input hex=10'") -and
            $content.Contains("ctrlC = 'navigation input hex=03'") -and
            $content.Contains("tab = 'navigation input hex=09'") -and
            $content.Contains("ctrlVPaste = 'navigation input hex=6c 65 61 6e 74 74 79")
        ) 'SSH authentication scenario does not capture terminal key bytes at the server boundary'
        Assert-True (
            $content.Contains("`$alternateFocusReportPattern = 'fixture command bytes=5b 49 result=unrecognized'") -and
            $content.Contains('$alternateFocusReportCount = Get-FixtureLogMatchCount') -and
            $content.Contains('-GreaterThan $alternateFocusReportCount') -and
            $content.Contains('Alternate-screen focus report submission was not observed')
        ) 'SSH alternate-screen escape coverage relies on a fixed line-boundary delay'
        Assert-True (
            $content.Contains('[string[]]$Only') -and
            $content.Contains('[string]$Group') -and
            $content.Contains("'transport-performance'") -and
            $content.Contains("'authentication-methods'") -and
            $content.Contains("'lifecycle-recovery'") -and
            $content.Contains("'pane-focus-attention'") -and
            $content.Contains('$authGroupDefinitions') -and
            $content.Contains('Group cannot be combined with -Only') -and
            $content.Contains('[switch]$DiagnosticHap') -and
            $content.Contains('[switch]$VerifyPreferencesUnchanged') -and
            $content.Contains('-DiagnosticHap requires an explicit -HapPath') -and
            $content.Contains("provenance = 'explicit-unretained-diagnostic-hap'") -and
            $content.Contains("`$runMode = if (-not `$DiagnosticHap -and `$Only.Count -eq 0)") -and
            $content.Contains("runMode = `$runMode") -and
            $content.Contains('executionGroup = $executionGroup') -and
            $content.Contains('groupManifest = $selectedGroupManifest') -and
            $content.Contains('knownHostRemovalCommandCompleted = $knownHostCleanupCompleted') -and
            $content.Contains("'layout-known-host-finally-cleanup.json'") -and
            $content.Contains("failureDomain = `$failureDomain") -and
            $content.Contains('attemptId = $attemptId') -and
            $content.Contains('resourceManifest = [ordered]@{') -and
            $content.Contains('Write-AuthLiveStatus') -and
            $content.Contains('Get-LeanTTYFixtureStageBudgetSeconds') -and
            $content.Contains('Get-LeanTTYFixtureRunSeconds') -and
            $content.Contains('$awakeLeaseMilliseconds = ($fixtureRunSeconds + 300) * 1000') -and
            $content.Contains('-TimeoutMilliseconds $awakeLeaseMilliseconds') -and
            $content.Contains('selectedStageBudgetsSeconds') -and
            $content.Contains("'password-kbdint-mixed-echo' = 300") -and
            $content.Contains("'multiround-wrong-answer-recovery' = 420") -and
            $content.Contains("'parallel-pane-authentication' = 480") -and
            $content.Contains("'diagnostic'") -and
            $content.Contains("'acceptance'")
        ) 'SSH authentication harness lacks targeted diagnostics or auditable live evidence'
        Assert-True (
            $content.Contains("`$preferencesComparisonBoundary = 'all-selected-stages'") -and
            $content.Contains("`$preferencesAllowedMutation = 'none'") -and
            $content.Contains("'before-transparency-performance'") -and
            $content.Contains("'terminal-transparency-mode-restored'") -and
            $content.Contains("'preferences-unchanged-before-transparency-performance'") -and
            $content.Contains('comparisonBoundary = $preferencesComparisonBoundary') -and
            $content.Contains('allowedMutation = $preferencesAllowedMutation')
        ) 'SSH performance coverage can misclassify restored transparency as a Preferences change'
        $groupDefinitionStart = $content.IndexOf('$authGroupDefinitions = [ordered]@{')
        $groupDefinitionEnd = $content.IndexOf('$availableStages = @(', $groupDefinitionStart)
        Assert-True (
            $groupDefinitionStart -ge 0 -and $groupDefinitionEnd -gt $groupDefinitionStart
        ) 'SSH group definition boundary could not be inspected'
        $groupDefinitionText = $content.Substring(
            $groupDefinitionStart,
            $groupDefinitionEnd - $groupDefinitionStart
        )
        foreach ($groupedStage in @(
                'password-success',
                'ssh-diagnostics',
                'terminal-key-input',
                'transport-main-path',
                'performance-matrix',
                'bell-attention',
                'password-kbdint-mixed-echo',
                'multiround-wrong-answer-recovery',
                'publickey-unencrypted',
                'publickey-then-password',
                'publickey-then-keyboard-interactive',
                'keyboard-interactive-zero-prompt',
                'unsupported-method-error-and-recovery',
                'ctrl-c-authentication-cancellation-and-recovery',
                'pane-close-during-hidden-prompt-and-recovery',
                'publickey-encrypted-passphrase',
                'parallel-pane-authentication',
                'minimize-restore-hidden-prompt',
                'process-stop-during-hidden-prompt-cleanup'
            )) {
            Assert-True (
                ([regex]::Matches(
                    $groupDefinitionText,
                    [regex]::Escape("'$groupedStage'")
                )).Count -eq 1
            ) "SSH public stage is missing from or duplicated across groups: $groupedStage"
        }
        foreach ($internalStage in @(
                'generated-disposable-auth-key',
                'encrypted-disposable-auth-key',
                'deleted-disposable-auth-key'
            )) {
            Assert-True (-not $groupDefinitionText.Contains("'$internalStage'")) (
                "SSH internal dependency was incorrectly promoted to a public group stage: $internalStage"
            )
        }
        Assert-True (
            $content.Contains('Get-LeanTTYPreferencesDigest') -and
            $content.Contains('sha256sum $preferencesPath') -and
            $content.Contains('contentReadOrExported = $false') -and
            $content.Contains('digestPersisted = $false') -and
            $content.Contains('unchanged = $preferencesDigestUnchanged') -and
            -not $content.Contains('beforeDigest =') -and
            -not $content.Contains('afterDigest =')
        ) 'SSH authentication harness does not compare Preferences safely without persisting digests'
        Assert-True (
            $content.Contains("'password-success'") -and
            $content.Contains("'password-then-keyboard-interactive-mixed-echo'") -and
            $content.Contains("'keyboard-interactive-multi-round-wrong-answer-recovery'") -and
            $content.Contains(
                "Wait-AuthLog -Pattern 'native control event: error:target:authentication:auth'"
            ) -and
            -not $content.Contains(
                "Wait-AuthLog -Pattern 'native control event: error::authentication:auth'"
            ) -and
            $content.Contains("'publickey-unencrypted'") -and
            $content.Contains("'publickey-then-password'") -and
            $content.Contains("'publickey-then-keyboard-interactive'") -and
            $content.Contains("'keyboard-interactive-zero-prompt'") -and
            $content.Contains("'unsupported-method-error-and-recovery'") -and
            $content.Contains(
                "Wait-AuthLog -Pattern 'SSH error: target:no supported authentication method is available'"
            ) -and
            -not $content.Contains(
                "Wait-AuthLog -Pattern 'SSH error: no supported authentication method is available'"
            ) -and
            $content.Contains("'ctrl-c-authentication-cancellation-and-recovery'") -and
            $content.Contains('Invoke-LeanTTYDeviceCtrlC') -and
            $content.Contains("'pane-close-during-hidden-prompt-and-recovery'") -and
            $content.Contains("-ButtonText 'Close pane'") -and
            $content.Contains("'layout-close-auth-single-pane.json'") -and
            -not $content.Contains("'-RunSeconds', '1200'") -and
            $content.Contains("'publickey-encrypted-passphrase'") -and
            $content.Contains("'parallel-pane-independent-authentication'") -and
            $content.Contains("'minimize-restore-hidden-answer-continuity'") -and
            $content.Contains("'EnhanceMinimizeBtn'") -and
            $content.Contains('LeanTTY active-pane close button was not found') -and
            -not $content.Contains("Invoke-AuthShortcut -Action 'close-pane'") -and
            $content.Contains('LeanTTY process changed while $Action') -and
            $content.Contains("'process-stop-during-hidden-prompt-cleanup'") -and
            $content.Contains("'tools/verify-terminal-search-pc.ps1'") -and
            $content.Contains("'docs/design/terminal-search.md'") -and
            $content.Contains("'docs/next-work.md'") -and
            $content.Contains('Submit-LeanTTYDeviceCommand') -and
            -not $content.Contains('for ($commandAttempt = 1; $commandAttempt -le 3; $commandAttempt++)') -and
            -not $content.Contains("-Pattern 'ACCEPTANCE_IDLE_RESULT kind='")
        ) 'SSH authentication scenario does not declare its bounded physical coverage'
        Assert-True (
            $content.Contains("'transport-main-path'") -and
            $content.Contains("'ltty-input-check russhmain'") -and
            $content.Contains("'ltty-paste-prepare russhmain 1048576'") -and
            ([regex]::Matches($content, 'Submit-ConnectedInputUntilFixtureEvent').Count -ge 8) -and
            ([regex]::Matches($content, 'Submit-ConnectedInputUntilAuthEvent').Count -ge 2) -and
            $content.Contains("'connected-input-snapshot'") -and
            $content.Contains('function Wait-FixtureConnectedInputSnapshot') -and
            $content.Contains('for ($inputAttempt = 1; $inputAttempt -le 3; $inputAttempt++)') -and
            $content.Contains('connected input state=cleared') -and
            $content.Contains('Connected input could not be made exact before Enter') -and
            $content.Contains('Connected input outcome is unknown; the scenario must be restarted') -and
            $content.Contains('Connected input application outcome is unknown; the scenario must be restarted') -and
            -not $content.Contains("Submit-ConnectedInput -Text 'ltty-paste-prepare russhmain 1048576'") -and
            $content.Contains("'Clipboard paste ok,1048576'") -and
            $content.Contains("'D: 1048576 chars'") -and
            $content.Contains("'paste case=russhmain bytes=1048576 result=matched'") -and
            $content.Contains("'uitest uiInput keyEvent 2072 2045 2038'") -and
            $content.Contains("'uinput -K -u 2038 -u 2045 -u 2072'") -and
            $content.Contains("Invoke-AuthPerfSample -CaseId 'russhmain'") -and
            $content.Contains('"completenessPercent":100') -and
            $content.Contains("'resize cols=\d+ rows=\d+'") -and
            $content.Contains("'ltty-input-check afterperf'") -and
            $content.Contains("'input case=afterperf result=matched'") -and
            $content.Contains("'layout-transport-close-connected.json'") -and
            $content.Contains("'layout-transport-close-connected-dialog.json'") -and
            $content.Contains("'SSH closed, exitCode=-1'") -and
            $content.Contains("'ltty-input-check reconnect'") -and
            $content.Contains("'input case=reconnect result=matched'") -and
            $content.Contains('Wait-AuthPaneCount -Count 1')
        ) 'SSH transport main-path coverage is incomplete'
        Assert-True (
            $content.Contains("Wait-AuthLog -Pattern 'SSH error: target:SSH keepalive timed out'") -and
            -not $content.Contains("Wait-AuthLog -Pattern 'SSH error: SSH keepalive timed out'")
        ) 'SSH server-alive oracle does not match the structured target-layer error label'
        Assert-True (
            $content.Contains("'performance-matrix'") -and
            $content.Contains("@('Off', 'Low', 'Medium', 'High', 'Extreme')") -and
            $content.Contains("'Maximum' = 'Extreme'; '最高' = 'Extreme'") -and
            $content.Contains('Invoke-AuthPerfSample -CaseId $caseId') -and
            $content.Contains("' lines=12000 width=80 bytes=\d+ state=prepared'") -and
            $content.Contains('PERF prepare outcome is unknown') -and
            $content.Contains('PERF run outcome is unknown') -and
            $content.Contains('commandAttempts') -and
            $content.Contains('renderSamples = @($renderSamples)') -and
            $content.Contains('memorySamples = @($memorySamples)') -and
            $content.Contains("hidumper -s 10 -a 'hitchs app0'") -and
            $content.Contains("hidumper -s 10 -a 'gles'") -and
            $content.Contains('Get-AuthTransparencyMode') -and
            $content.Contains('-Mode $performanceInitialTransparencyMode') -and
            $content.Contains('$performanceTransparencyRestored = $true') -and
            -not $content.Contains('$screenshotName = "performance-$modeSlug.png"') -and
            -not $content.Contains('screenshot = $screenshotName') -and
            $content.Contains('performanceMatrix = $performanceEvidence')
        ) 'SSH five-mode performance matrix is incomplete'
        Assert-True (
            $content.Contains("'bell-attention'") -and
            $content.Contains("'ltty-bell active01 500'") -and
            $content.Contains("'ltty-bell inactive01 5000'") -and
            $content.Contains("'ltty-bell split01 5000'") -and
            $content.Contains("'ltty-bell flood01 5000'") -and
            $content.Contains("'ltty-bell flood02 5000'") -and
            $content.Contains('Repeated BEL did not coalesce to one pending attention transition') -and
            $content.Contains('bellAttention = $bellEvidence')
        ) 'SSH BEL attention matrix is incomplete'
    }
    if ($scriptName -eq 'verify-terminal-search-pc.ps1') {
        Assert-True (
            $content.Contains('Terminal-search device harness requires a clean committed tree') -and
            $content.Contains("'open-close-focus'") -and
            $content.Contains("'ascii-query-navigation'") -and
            $content.Contains("'pane-tab-ownership'") -and
            $content.Contains("'warm-tab-eviction'") -and
            $content.Contains("'window-renderer-lifecycle'") -and
            $content.Contains("'uitest uiInput keyEvent 2072 2045 2022'") -and
            -not $content.Contains("'uitest uiInput keyEvent 2047 2054'") -and
            $content.Contains("'Previous match, Shift+Enter'") -and
            $content.Contains('-RequireSearchInputFocus $false') -and
            -not $content.Contains("'uitest uiInput keyEvent 2072 2017'") -and
            $content.Contains('Clear-TerminalSearchQuery -CharacterCount $query.Length') -and
            $content.Contains('Clear-TerminalSearchQuery -CharacterCount $missingQuery.Length') -and
            $content.Contains("'LEANTTY_NO_RESULT_ZXQVK'") -and
            $content.Contains("'^(?:Find text|Search text|查找内容)'") -and
            $content.Contains('[AllowEmptyString()]') -and
            $content.Contains("'^(?:No results|未找到结果)$'") -and
            $content.Contains('wrappedForward = $true') -and
            $content.Contains('wrappedBackward = $true') -and
            $content.Contains("'TerminalBridge: PERF bridge reason=destroy'") -and
            $content.Contains("'TerminalBridge: Bridge initialized'") -and
            $content.Contains("'Acceptance: Rebuild Renderer'") -and
            $content.Contains("'EnhanceMinimizeBtn'") -and
            $content.Contains("Invoke-LocalTerminalCommand -Command 'help mosh'") -and
            $content.Contains('function Invoke-LocalTerminalCommand') -and
            $content.Contains('Get-LeanTTYActiveTerminalInputNodes -Layout $layout') -and
            $content.Contains('$contentTop = Get-LeanTTYTerminalContentTop -Layout $Layout') -and
            -not $content.Contains('[int]$Matches.top -ge 100') -and
            $content.Contains('Submit-LeanTTYDeviceCommand') -and
            $content.Contains('-ProcessId $appPid') -and
            $content.Contains('-InputNodeProvider') -and
            $content.Contains("elseif (`$failure -match '^\[unknown\]')") -and
            -not $content.Contains('$actualBuffer -ceq $Command') -and
            $content.Contains('rightPaneRejectedLeftScrollbackQuery = $true') -and
            $content.Contains('secondTabRejectedFirstTabScrollbackQuery = $true') -and
            $content.Contains("'pane-scroll-after-focus-switch.png'") -and
            $content.Contains("'tab-scroll-first-return.png'") -and
            $content.Contains('singleTabSinglePaneRestored = $workspaceRestored') -and
            $content.Contains('$activePaneBounds') -and
            $content.Contains('[Collections.Generic.List[string]]::new()') -and
            $content.Contains('$activePaneBounds.Contains($bounds)') -and
            $content.Contains('Get-LeanTTYActiveTerminalInputNodes') -and
            $content.Contains('Get-LeanTTYActiveTerminalSurfaceNodes') -and
            $content.Contains('-RequireTerminalFocus $false') -and
            $content.Contains('terminalFocusRestoredByCommandSubmit') -and
            $content.Contains("attributes.opacity -eq '1.000000'") -and
            $content.Contains("attributes.zIndex -eq '1'") -and
            $content.Contains('does not ') -and
            $content.Contains('satisfy physical-keyboard or Chinese/English IME acceptance') -and
            $content.Contains("'layout-search-open.json'") -and
            $content.Contains("'layout-search-closed.json'") -and
            $content.Contains("'explicit-unretained-diagnostic-hap'") -and
            $content.Contains('$harnessDirty -and -not $DiagnosticHap') -and
            $content.Contains('gitDirty = $harnessDirty') -and
            $content.Contains('Assert-LeanTTYCandidateHarnessCompatibility') -and
            $content.Contains("'tools/start-ssh-auth-fixture.ps1'") -and
            $content.Contains("'retained-verified-candidate'") -and
            $content.Contains('Save-LeanTTYVerifiedCandidate') -and
            $content.Contains('harness = [ordered]@{') -and
            $content.Contains('failureDomain = $failureDomain') -and
            $content.Contains('transientSearchClosed = $searchClosed') -and
            $content.Contains('Stop-LeanTTYDeviceAwakeLease')
        ) 'Terminal-search physical scenario lacks identity, product routing, evidence, or cleanup'

        $tokens = $null
        $parseErrors = $null
        $syntaxTree = [Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        Assert-True ($parseErrors.Count -eq 0) 'Terminal-search harness could not be parsed for layout tests'
        foreach ($functionName in @(
            'Get-LeanTTYTerminalContentTop',
            'Get-LeanTTYTabNodes',
            'Get-LeanTTYActiveTerminalSurfaceNodes'
        )) {
            $functionDefinition = $syntaxTree.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $functionName
            }, $true) | Select-Object -First 1
            Assert-True ($null -ne $functionDefinition) "Missing terminal-search helper: $functionName"
            Invoke-Expression $functionDefinition.Extent.Text
        }
        $scaledChromeLayout = @'
{
  "attributes": {"type":"root","bounds":"[0,0][2926,1926]"},
  "children": [
    {"attributes":{"type":"Stack","clickable":"true","description":"active","bounds":"[143,67][470,135]"},"children":[]},
    {"attributes":{"type":"Stack","clickable":"true","description":"content decoy","bounds":"[143,300][470,368]"},"children":[]},
    {"attributes":{"type":"Web","visible":"true","originalText":"resource:/RAWFILE/terminal.html","bounds":"[121,135][2926,1926]"},"children":[]}
  ]
}
'@ | ConvertFrom-Json -Depth 10
        $scaledTabs = @(Get-LeanTTYTabNodes -Layout $scaledChromeLayout)
        Assert-True (
            $scaledTabs.Count -eq 1 -and
            [string]$scaledTabs[0].attributes.description -eq 'active'
        ) 'Terminal-search harness did not derive the scaled Chrome boundary from terminal content'

        $rendererRebuiltLayout = @'
{
  "attributes": {"type":"root","bounds":"[0,0][2926,1926]"},
  "children": [
    {"attributes":{"type":"__Common__","opacity":"1.000000","zIndex":"0","bounds":"[2584,67][2645,128]"},"children":[]},
    {"attributes":{"type":"__Common__","opacity":"1.000000","zIndex":"1","bounds":"[121,135][2926,1926]"},"children":[
      {"attributes":{"type":"Web","visible":"true","originalText":"resource:/RAWFILE/terminal.html","bounds":"[121,135][2926,1926]"},"children":[]}
    ]},
    {"attributes":{"type":"__Common__","opacity":"0.000000","zIndex":"0","bounds":"[121,135][2926,1926]"},"children":[
      {"attributes":{"type":"Web","visible":"true","originalText":"resource:/RAWFILE/terminal.html","bounds":"[121,135][2926,1926]"},"children":[]}
    ]}
  ]
}
'@ | ConvertFrom-Json -Depth 10
        $activeSurfaces = @(Get-LeanTTYActiveTerminalSurfaceNodes -Layout $rendererRebuiltLayout)
        Assert-True (
            $activeSurfaces.Count -eq 1 -and
            [string]$activeSurfaces[0].attributes.zIndex -eq '1'
        ) 'Renderer-rebuilt layout did not retain one observable active terminal Surface'
    }
    if ($scriptName -eq 'verify-proxy-jump-pc.ps1') {
        Assert-True (
            $content.Contains('function Submit-ProxyCommand') -and
            $content.Contains('Submit-LeanTTYDeviceCommand') -and
            $content.Contains('-ProcessId $script:proxyAppPid') -and
            $content.Contains('-InputNodeProvider') -and
            $content.Contains('function Get-ProxyCommandInputText') -and
            $content.Contains('function Wait-ProxyCommandInputText') -and
            $content.Contains('Get-LeanTTYTerminalInputNodes -Layout $Layout') -and
            -not $content.Contains("-Pattern 'ACCEPTANCE_IDLE_RESULT kind='") -and
            -not $content.Contains('$actualBuffer -ceq $Command') -and
            $content.Contains("[string]`$HapPath = ''") -and
            $content.Contains('[IO.Path]::GetFullPath($HapPath)') -and
            $content.Contains('ProxyJump verification requires a signed HAP') -and
            $content.Contains('-HapPath $selectedHapPath') -and
            $content.Contains('$script:proxyHapPath = $selectedHapPath') -and
            $content.Contains('[ValidateRange(0, 3600)][int]$ServerAliveIntervalSeconds') -and
            $content.Contains('sameConnectionInputObserved = $true') -and
            $content.Contains('deviceTimeoutObserved = $false')
        ) 'ProxyJump physical scenario can submit an unverified command buffer'
    }
}

$moshParser = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\model\command\CommandParser.ets'
) -Raw
$moshClient = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\model\mosh\MoshClient.ets'
) -Raw
$moshSessionViewModel = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\viewmodel\SessionViewModel.ets'
) -Raw
$moshPaneRuntime = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\viewmodel\PaneRuntime.ets'
) -Raw
$moshTerminalSurface = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\model\terminal\TerminalSurfaceController.ets'
) -Raw
$moshIndexPage = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\pages\Index.ets'
) -Raw
$moshNativeTypes = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\cpp\types\libleantty_ssh\index.d.ts'
) -Raw
$moshNative = Get-Content -LiteralPath (
    Join-Path $repoRoot 'leantty_ssh\src\lib.rs'
) -Raw
$moshManifest = Get-Content -LiteralPath (
    Join-Path $repoRoot 'leantty_ssh\Cargo.toml'
) -Raw
$acceptanceSource = Get-Content -LiteralPath (
    Join-Path $repoRoot 'tools\acceptance-source.ps1'
) -Raw
foreach ($predictionContract in @(
    @{ Source = $moshParser; Text = 'MoshPredictionMode.ADAPTIVE' },
    @{ Source = $moshParser; Text = "word.startsWith('--predict=')" },
    @{ Source = $moshParser; Text = 'Mosh prediction mode must be adaptive, always or never' },
    @{ Source = $moshClient; Text = 'predictionMode: MoshPredictionMode' },
    @{ Source = $moshClient; Text = 'predictionMode,' },
    @{ Source = $moshSessionViewModel; Text = 'predictionMode: MoshPredictionMode = this.moshPredictionMode' },
    @{ Source = $moshSessionViewModel; Text = 'result.moshServerPath, result.moshPredictionMode' },
    @{ Source = $moshNativeTypes; Text = 'predictionMode: string' },
    @{ Source = $moshNative; Text = 'connect_with_prediction_mode' },
    @{ Source = $moshNative; Text = 'mosh_prediction_mode(&prediction_mode)' },
    @{ Source = $moshManifest; Text = 'tag = "v0.1.1"' },
    @{ Source = $moshManifest; Text = 'version = "=0.1.1"' },
    @{ Source = $acceptanceSource; Text = 'ACCEPTANCE_MOSH_OUTPUT mode=' },
    @{ Source = $acceptanceSource; Text = 'ACCEPTANCE_TERMINAL_WRITE_ACK bytes=' },
    @{ Source = $moshIndexPage; Text = 'runtime.viewModel.getMode() === TerminalMode.IDLE' },
    @{ Source = $moshSessionViewModel; Text = 'if (this.requestRuntimeRecoveryBeforeIdleInput(sourceSurface))' },
    @{ Source = $moshSessionViewModel; Text = '!surface.ownsMoshSessionPage()' },
    @{ Source = $moshTerminalSurface; Text = 'return this.moshPageRequested || this.outputBuffer.isSessionPageActive()' },
    @{ Source = $moshIndexPage; Text = 'runtime.surface.ownsMoshSessionPage()' },
    @{ Source = $moshIndexPage; Text = 'this.recoverReclaimedRuntimeSessions(requestedPaneId)' },
    @{ Source = $moshSessionViewModel; Text = 'this.terminalResetPending' },
    @{ Source = $moshPaneRuntime; Text = 'this.surface.setPaneIdentity(id)' },
    @{ Source = $moshSessionViewModel; Text = 'Terminal input withheld for runtime recovery' },
    @{ Source = $moshIndexPage; Text = "@Watch('onRuntimeRecoveryRequested')" },
    @{ Source = $acceptanceSource; Text = "AppStorage.setOrCreate('activeRemotePaneIds', '')" }
)) {
    Assert-True ($predictionContract.Source.Contains($predictionContract.Text)) (
        "Mosh prediction pass-through omitted contract: $($predictionContract.Text)"
    )
}

$moshVerifierPath = Join-Path $PSScriptRoot 'verify-mosh-pc.ps1'
$moshVerifier = Get-Content -LiteralPath $moshVerifierPath -Raw
$moshVerifierTokens = $null
$moshVerifierParseErrors = $null
$moshVerifierAst = [Management.Automation.Language.Parser]::ParseFile(
    $moshVerifierPath,
    [ref]$moshVerifierTokens,
    [ref]$moshVerifierParseErrors
)
Assert-True ($moshVerifierParseErrors.Count -eq 0) 'Mosh verifier could not be parsed for helper tests'
& {
    # Run the actual focus, input, retry and Enter chain. Only device/PTY I/O
    # is replaced; the shared native-owner predicate remains real.
    foreach ($name in @('Focus-ActiveTerminalInput', 'Submit-MoshInput')) {
        $definition = $moshVerifierAst.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        Invoke-Expression $definition.Extent.Text
    }
    function New-MoshOwnerTestLayout {
        $changed = $state.reads -ge $case.at
        $webPath = if ($changed -and $case.change -eq 'reindex') { 'ROOT1,1' } else { 'ROOT1,0' }
        $webId = if ($changed -and $case.change -eq 'replacement') { 'other-web' } else { 'owner-web' }
        $windowId = if ($changed -and $case.change -eq 'window') { '2' } else { '1' }
        if ($changed -and $case.change -eq 'missing') { $webId = '' }
        $leafPath = if ($changed -and $case.change -eq 'virtual') { ',0,2,0' } else { ',0,0' }
        $leaf = [pscustomobject]@{ attributes = @{
            type = 'textField'; hint = 'Terminal input'; focused = 'true'; hostWindowId = $windowId
            hierarchy = $webPath + $leafPath; accessibilityId = 'virtual-input'; bounds = '[10,10][30,30]'
        }; children = @() }
        $web = [pscustomobject]@{ attributes = @{
            type = 'Web'; hierarchy = $webPath; accessibilityId = $webId; hostWindowId = $windowId
        }; children = @($leaf) }
        $children = @($web)
        if ($changed -and $case.change -eq 'no-web') { $children = @($leaf) }
        if ($changed -and $case.change -in @('duplicate', 'two-focused', 'peer')) {
            $peerId = if ($case.change -eq 'duplicate') { $webId } else { 'peer-web' }
            $peerFocus = if ($case.change -eq 'two-focused') { 'true' } else { 'false' }
            $children += [pscustomobject]@{ attributes = @{
                type = 'Web'; hierarchy = 'ROOT1,3'; accessibilityId = $peerId; hostWindowId = $windowId
            }; children = @([pscustomobject]@{ attributes = @{
                type = 'textField'; hint = 'Terminal input'; focused = $peerFocus; hostWindowId = $windowId
                hierarchy = 'ROOT1,3,0,0'; bounds = '[40,10][60,30]'
            }; children = @() }) }
        }
        return [pscustomobject]@{ attributes = @{}; children = $children }
    }
    $cases = @(
        @{ change='stable'; at=1; text=1; enter=1; cancel=0 },
        @{ change='reindex'; at=2; text=1; enter=1; cancel=0 },
        @{ change='reindex'; at=3; text=1; enter=1; cancel=0 },
        @{ change='reindex'; at=4; text=1; enter=1; cancel=0 },
        @{ change='virtual'; at=2; text=1; enter=1; cancel=0 },
        @{ change='virtual'; at=4; text=1; enter=1; cancel=0 },
        @{ change='peer'; at=1; text=1; enter=1; cancel=0 },
        @{ change='replacement'; at=2; text=0; enter=0; cancel=0 },
        @{ change='replacement'; at=3; text=1; enter=0; cancel=0 },
        @{ change='replacement'; at=4; text=1; enter=0; cancel=0 },
        @{ change='window'; at=4; text=1; enter=0; cancel=0 },
        @{ change='missing'; at=1; text=0; enter=0; cancel=0 },
        @{ change='missing'; at=4; text=1; enter=0; cancel=0 },
        @{ change='duplicate'; at=1; text=0; enter=0; cancel=0 },
        @{ change='duplicate'; at=4; text=1; enter=0; cancel=0 },
        @{ change='no-web'; at=1; text=0; enter=0; cancel=0 },
        @{ change='two-focused'; at=4; text=1; enter=0; cancel=0 },
        @{ change='reindex'; at=5; retry='once'; text=2; enter=1; cancel=1 },
        @{ change='replacement'; at=5; retry='once'; text=1; enter=0; cancel=1 },
        @{ change='stable'; at=1; retry='exhausted'; text=3; enter=0; cancel=2 },
        @{ change='stable'; at=1; retry='clear-failed'; text=1; enter=0; cancel=1 },
        @{ change='stable'; at=1; retry='local-prompt'; text=1; enter=0; cancel=0 }
    )
    foreach ($case in $cases) {
        $state = @{ reads=0; text=0; enter=0; cancel=0; snapshots=0 }
        $hdc = 'synthetic'; $targetId = 'synthetic'; $appPid = 1
        $EvidenceDirectory = [IO.Path]::GetTempPath(); $activeMoshControlDirectory = 'synthetic'
        $connectedInputObservations = [Collections.Generic.List[object]]::new()
        function Get-LeanTTYDeviceLayout {
            $state.reads++
            if ($state.reads -gt 12) { throw 'Synthetic layout sequence exhausted' }
            New-MoshOwnerTestLayout
        }
        function Get-HdcUiLayout { Get-LeanTTYDeviceLayout }
        function Invoke-LeanTTYSerializedUiTest { param($Action) & $Action }
        function Invoke-HdcChecked { $state.text++ }
        function Invoke-LeanTTYDeviceKey { $state.enter++ }
        function Invoke-LeanTTYDeviceCtrlC { $state.cancel++ }
        function Wait-MoshInputSnapshot {
            param($Expected)
            $state.snapshots++
            $mismatch = ($case.retry -and $state.snapshots -eq 1) -or
                ($case.retry -eq 'exhausted' -and $Expected -ne '') -or
                ($case.retry -eq 'clear-failed' -and $state.snapshots -eq 2)
            return @{ observed=$true; value=$(if ($mismatch) { 'wrong' } else { $Expected }) }
        }
        function Get-LeanTTYAppLogs { return '' }
        function Get-LeanTTYAcceptanceIdleInputState {
            if ($case.retry -eq 'local-prompt') { return @{ input='public-owner-probe' } }
            return $null
        }
        $failure = $null
        try { Submit-MoshInput -Text 'public-owner-probe' } catch { $failure = $_.Exception }
        $label = "$($case.change) at layout $($case.at), retry=$($case.retry)"
        Assert-True (($null -eq $failure) -eq ($case.enter -eq 1)) "Mosh native owner verdict failed: $label"
        Assert-True ($state.text -eq $case.text -and $state.enter -eq $case.enter -and
            $state.cancel -eq $case.cancel) "Mosh sent an unsafe input, retry or Enter: $label"
        Assert-True ($connectedInputObservations.Count -eq 1 -and
            $connectedInputObservations[0].enterCount -eq $case.enter -and
            $connectedInputObservations[0].result -eq $(if ($case.enter) { 'passed' } else { 'failed' })) (
            "Mosh command observation lost its verdict: $label"
        )
        if ($case.enter -eq 1) {
            Assert-True ($state.reads -eq (4 * $case.text)) "Owner matching added layout captures: $label"
        }
    }
    foreach ($change in @('stable', 'reindex', 'virtual', 'replacement')) {
        $case = @{ change=$change; at=2 }
        $state = @{ reads=0; focus=0 }
        function Get-LeanTTYDeviceLayout {
            $state.reads++
            $layout = New-MoshOwnerTestLayout
            if ($state.reads -eq 1) { $layout.children[0].children[0].attributes.focused = 'false' }
            return $layout
        }
        function Set-LeanTTYTerminalInputFocus { $state.focus++; Get-LeanTTYDeviceLayout }
        $failure = $null; $capture = $null
        try { $capture = Focus-ActiveTerminalInput -Name 'synthetic-focus.json' -IncludeLayout }
        catch { $failure = $_.Exception }
        Assert-True (($null -eq $failure) -eq ($change -ne 'replacement')) "Focus owner was not preserved: $change"
        if ($null -ne $capture) {
            $focused = @(Get-LeanTTYFocusedTextInputNodes -Layout $capture.layout)
            Assert-True ($focused.Count -eq 1 -and [object]::ReferenceEquals($focused[0], $capture.node)) (
                "Focus returned a stale pre-click node: $change"
            )
        }
        Assert-True ($state.reads -eq 2 -and $state.focus -eq 1) 'Focus capture added a read or a click'
    }
}
& {
    $timestampDefinition = $moshVerifierAst.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'ConvertFrom-MoshHilogTimestamp'
    }, $true) | Select-Object -First 1
    Invoke-Expression $timestampDefinition.Extent.Text
    $definition = $moshVerifierAst.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-MoshInputRejectionObservation'
    }, $true) | Select-Object -First 1
    Invoke-Expression $definition.Extent.Text
    $logs = @('09-06 23:03:16.554 6549 6549 I tag: ACCEPTANCE_MOSH_INPUT_REJECTION receivedBytes=42',
        '09-06 23:03:16.555 6549 6549 I tag: ACCEPTANCE_MOSH_INPUT_REJECTION kind=full',
        '09-06 23:03:16.557 6549 6549 I tag: ACCEPTANCE_TERMINAL_WRITE_ACK bytes=42',
        '09-06 23:03:16.597 6549 6549 I tag: ACCEPTANCE_PAGE_REPLACED_FINGERPRINT 2,normal,71,36,0,0123456789abcdef') -join "`n"
    $observation = Get-MoshInputRejectionObservation -Logs $logs
    Assert-True ($observation.nativeErrorKind -ceq 'Full' -and $observation.receivedOutputBytes -eq 42 -and
        $observation.outputAcknowledgedBeforeRestore) 'Input rejection lost its actual drain observations'
    $grouped = ($logs -split "`n")[@(0, 2, 3, 1)] -join "`n"
    $observation = Get-MoshInputRejectionObservation -Logs $grouped
    Assert-True $observation.outputAcknowledgedBeforeRestore (
        'Tag-grouped logs must use device event time, not concatenated file order'
    )
    foreach ($invalid in @('', $logs.Replace('kind=full', 'kind=unexpected'),
        $logs.Replace('bytes=42', 'bytes=0'), $logs.Replace('receivedBytes=42', 'receivedBytes=0'),
        ($logs + "`n" + $logs),
        $logs.Replace('23:03:16.557', '23:03:16.598'),
        $logs.Replace('23:03:16.557', '23:03:16.553'),
        $logs.Replace('23:03:16.555', '23:03:16.553'),
        $logs.Replace('23:03:16.555', '23:03:16.598'),
        $logs.Replace('09-06 23:03:16.555', 'missing timestamp'),
        $logs.Replace('23:03:16.597', '23:03:16.557'),
        ($logs + "`nACCEPTANCE_MOSH_INPUT_REJECTION state=precondition-failed"))) {
        Assert-Throws { Get-MoshInputRejectionObservation -Logs $invalid } (
            'Input rejection accepted missing, ambiguous, synthetic or out-of-order evidence'
        )
    }
}
& {
    $fingerprintFunction = $moshVerifierAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Test-MoshPageFingerprintRestored'
    }, $true) | Select-Object -First 1
    Invoke-Expression $fingerprintFunction.Extent.Text
    $original = [pscustomobject]@{ cols = 144; rows = 36; identity = 'normal,144,36,15,aaa' }
    $same = [pscustomobject]@{ cols = 144; rows = 36; identity = 'normal,144,36,15,aaa' }
    $changed = [pscustomobject]@{ cols = 144; rows = 36; identity = 'normal,144,36,15,bbb' }
    Assert-True (Test-MoshPageFingerprintRestored $original $same) 'Equal geometry and framebuffer must pass'
    Assert-True (-not (Test-MoshPageFingerprintRestored $original $changed)) 'Changed framebuffer must fail'
    foreach ($geometry in @(@(71, 36), @(144, 18))) {
        $changed.cols = $geometry[0]
        $changed.rows = $geometry[1]
        $failure = ''
        try { Test-MoshPageFingerprintRestored $original $changed | Out-Null } catch { $failure = $_.Exception.Message }
        Assert-True ($failure.StartsWith('[harness] Exact page fingerprint comparison')) `
            'Different geometry must reject the comparison, not claim content loss or a pass'
    }
}
& {
    # Execute the real survivor reconnect branch; substitute only device/fixture boundaries.
    $paneCloseBranches = @($moshVerifierAst.FindAll({ param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -ceq '$Scenario -eq ''pane-close''' -and
            $node.Clauses[0].Item2.Extent.Text.Contains('$closedPaneServerPid =')
    }, $true))
    Assert-True ($paneCloseBranches.Count -eq 1) 'Missing or ambiguous Pane-close survivor branch'
    $paneCloseBody = [scriptblock]::Create((
        $paneCloseBranches[0].Clauses[0].Item2.Statements.Extent.Text -join "`n"
    ))
    foreach ($definition in $moshVerifierAst.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -in @('Get-MoshSessionPageBaseline', 'Test-MoshPageFingerprintRestored')
    }, $true)) { Invoke-Expression $definition.Extent.Text }
    function Write-LiveStatus {}
    function Clear-LeanTTYAppLogs {}
    function Close-ActiveMoshPane {}
    function Test-MoshTerminalSearch { return $true }
    function Reset-LeanTTYDeviceCommandInput {}
    function Clear-MoshSessionControlFiles {}
    function Submit-LocalCommand {}
    function Wait-LeanTTYAppLog {}
    function Submit-InteractiveValue {}
    function Wait-ControlFile {}
    function Read-ControlledLinuxPid { return 202 }
    function Read-MoshSession { return @{ pid = 201; port = 60042; serverPort = 60042 } }
    function Submit-MoshInput { $observations.commands++ }
    function Wait-ControlFileMatch {}
    function Wait-WslProcessAbsent { return 10 }
    function Test-WslProcessPresent { return $true }
    function Get-MoshLifecycleObservation { return @{ closed = $observations.closed; error = $false } }
    function Get-MoshSnapshotFingerprint {
        if ($observations.missingSnapshot -or $observations.visiblePageRead) {
            throw '[harness] Saved Mosh page snapshot fingerprint was missing or ambiguous'
        }
        return $survivorOriginal
    }
    function Get-MoshTerminalFingerprint {
        $observations.visiblePageRead = $true
        $observations.closed = $false
        return $survivorMosh
    }
    $attemptId = '0123456789abcdef'
    $survivorOriginal = [pscustomobject]@{
        generation = 1; cols = 144; rows = 36; identity = 'normal,144,36,8,survivor'
    }
    $survivorMosh = [pscustomobject]@{
        generation = 2; cols = 144; rows = 36; identity = 'normal,144,36,0,remote'
    }
    foreach ($oldCols in @(71, 144)) {
        $originalPageFingerprint = [pscustomobject]@{
            generation = 7; cols = $oldCols; rows = 36; identity = "normal,$oldCols,36,0,closed-pane"
        }
        $moshPageFingerprint = $null
        $originalPageHiddenDuringSession = $false
        $observations = @{ commands = 0; missingSnapshot = $false; visiblePageRead = $false }
        . $paneCloseBody
        Assert-True ($originalPageFingerprint.identity -ceq $survivorOriginal.identity) (
            'Survivor reconnect retained the closed Pane baseline, including when geometry matches'
        )
        Assert-True ($moshPageFingerprint.identity -ceq $survivorMosh.identity -and
            $originalPageHiddenDuringSession -and $observations.commands -eq 1) (
            'Original and Mosh fingerprints must both belong to the surviving Session'
        )
        Assert-True (Test-MoshPageFingerprintRestored $originalPageFingerprint $survivorOriginal) (
            'Survivor restoration did not compare with its own baseline'
        )
    }
    $observations = @{ commands = 0; missingSnapshot = $true; visiblePageRead = $false }
    Assert-Throws { . $paneCloseBody } 'Reconnect must reject missing snapshot evidence, not reuse an old baseline'
    $observations = @{ commands = 0; missingSnapshot = $false; visiblePageRead = $false }
    $survivorMosh.generation = $survivorOriginal.generation
    Assert-Throws { . $paneCloseBody } 'Reconnect must still prove a new Mosh page generation'
    $survivorMosh.generation = 2
    $observations = @{ commands = 0; missingSnapshot = $false; visiblePageRead = $false; closed = $true }
    Assert-Throws { . $paneCloseBody } 'Fingerprint capture must not erase a pre-existing survivor close event'
    Assert-True (-not $observations.visiblePageRead) 'Observe survivor lifecycle before fingerprint capture clears logs'
}
& {
    $focusFunction = $moshVerifierAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Focus-MoshPane'
    }, $true) | Select-Object -First 1
    Invoke-Expression $focusFunction.Extent.Text
    $paneLayout = $overlappingPaneLayout | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $paneLayout.children[1].children[0].attributes.bounds = '[1541,749][1560,790]'
    $script:paneFocusLayoutsRead = 0
    $script:paneFocusShortcuts = [Collections.Generic.List[string]]::new()
    function Invoke-MoshFocusHdc {
        $script:paneFocusShortcuts.Add(($args -join ' '))
        $global:LASTEXITCODE = 0
    }
    function Get-LeanTTYDeviceLayout {
        param($Hdc, $Target, $LocalPath)
        $script:paneFocusLayoutsRead++
        if ($script:paneFocusLayoutsRead -gt 1) {
            throw 'Pane focus did not accept the first correct owner snapshot'
        }
        return $paneLayout
    }
    $hdc = 'Invoke-MoshFocusHdc'
    $targetId = 'unused'
    $EvidenceDirectory = 'unused'
    foreach ($side in @('left', 'right')) {
        $leftFocused = $side -ceq 'left'
        $paneLayout.children[0].children[0].attributes.focused = $leftFocused.ToString().ToLowerInvariant()
        $paneLayout.children[1].children[0].attributes.focused = (-not $leftFocused).ToString().ToLowerInvariant()
        $script:paneFocusLayoutsRead = 0
        Focus-MoshPane -Side $side -Name 'owner-order'
        Assert-True ($script:paneFocusLayoutsRead -eq 1) 'Mosh Pane focus retried a correct snapshot'
    }
    Assert-True (
        $script:paneFocusShortcuts.Count -eq 2 -and
        $script:paneFocusShortcuts[0].Contains('-d 2014 -u 2014') -and
        $script:paneFocusShortcuts[1].Contains('-d 2015 -u 2015')
    ) 'Mosh Pane focus did not send exactly one correct shortcut per side'
    $paneLayout.children[0].children[0].attributes.focused = 'true'
    $paneLayout.children[1].children[0].attributes.focused = 'true'
    $script:paneFocusLayoutsRead = 0
    Assert-Throws -Action {
        Focus-MoshPane -Side 'left' -Name 'ambiguous-focus'
    } -Message 'Mosh Pane focus accepted two focused owners'
}
$moshHashFunction = $moshVerifierAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-MoshAcceptanceTextHash'
}, $true) | Select-Object -First 1
Assert-True ($null -ne $moshHashFunction) 'Mosh verifier search hash helper is missing'
Invoke-Expression $moshHashFunction.Extent.Text
Assert-True (
    (Get-MoshAcceptanceTextHash -Value 'help') -ceq '3871a3fa7c715c94'
) 'Mosh verifier search hash does not match the acceptance Web implementation'
foreach ($functionName in @(
    'ConvertTo-MoshIpv4Number',
    'Get-MoshEndpointRoute',
    'ConvertFrom-MoshWifiDeviceDump',
    'Get-MoshWifiToggle',
    'Get-MoshWifiPanelButton',
    'Get-MoshWifiPanelState',
    'Normalize-MoshWifiPanelClosed'
)) {
    $functionDefinition = $moshVerifierAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true) | Select-Object -First 1
    Assert-True ($null -ne $functionDefinition) "Missing Mosh verifier helper: $functionName"
    Invoke-Expression $functionDefinition.Extent.Text
}
$connectedWifi = ConvertFrom-MoshWifiDeviceDump -Dump @'
WiFi active state: activated

WiFi connection status: connected
  Connection.ssid: saved-network
  Connection.rssi: -48

Country Code: CN
'@
Assert-True (
    $connectedWifi.active -and $connectedWifi.connected -and
    $connectedWifi.ssid -ceq 'saved-network'
) 'Mosh Wi-Fi service dump parser did not return the current connected SSID'
$disconnectedWifi = ConvertFrom-MoshWifiDeviceDump -Dump @'
WiFi active state: activated

WiFi connection status: not connected

Country Code: CN
'@
Assert-True (
    $disconnectedWifi.active -and -not $disconnectedWifi.connected -and
    [string]::IsNullOrEmpty($disconnectedWifi.ssid)
) 'Mosh Wi-Fi service dump parser did not preserve a disconnected state'
$crlfWifiDump = @(
    'WiFi active state: activated',
    '',
    'WiFi connection status: connected',
    '  Connection.ssid: saved-network',
    ''
) -join "`r`n"
$crlfWifi = ConvertFrom-MoshWifiDeviceDump -Dump $crlfWifiDump
Assert-True (
    $crlfWifi.active -and $crlfWifi.connected -and
    $crlfWifi.ssid -ceq 'saved-network'
) 'Mosh Wi-Fi service dump parser rejected CRLF output'
Assert-Throws -Action {
    ConvertFrom-MoshWifiDeviceDump -Dump @'
WiFi active state: activated
WiFi connection status: connected
  Connection.ssid: first
  Connection.ssid: second
'@ | Out-Null
} -Message 'Mosh Wi-Fi service dump parser accepted an ambiguous SSID'
$wifiPanelOpenLayout = @'
{
  "attributes": {"id":"","type":"root","visible":"true","clickable":"false"},
  "children": [
    {"attributes":{"id":"PluginRootComponent_Stack_status_bar_wifi_panel","type":"Stack","visible":"true","clickable":"true"},"children":[]},
    {"attributes":{"id":"entry_toggle_wifi_switch","type":"Toggle","visible":"true","clickable":"true"},"children":[]}
  ]
}
'@ | ConvertFrom-Json -Depth 10
$wifiPanelClosedLayout = @'
{
  "attributes": {"id":"","type":"root","visible":"true","clickable":"false"},
  "children": [
    {"attributes":{"id":"PluginRootComponent_Stack_status_bar_wifi_panel","type":"Stack","visible":"true","clickable":"true"},"children":[]}
  ]
}
'@ | ConvertFrom-Json -Depth 10
$wifiPanelUnknownLayout = @'
{
  "attributes": {"id":"","type":"root","visible":"true","clickable":"false"},
  "children": []
}
'@ | ConvertFrom-Json -Depth 10
Assert-True (
    (Get-MoshWifiPanelState -Layout $wifiPanelOpenLayout) -ceq 'open' -and
    (Get-MoshWifiPanelState -Layout $wifiPanelClosedLayout) -ceq 'closed' -and
    (Get-MoshWifiPanelState -Layout $wifiPanelUnknownLayout) -ceq 'unknown'
) 'Mosh Wi-Fi panel state did not distinguish open, closed and unknown layouts'
$ambiguousWifiPanelLayout = @'
{
  "attributes": {"id":"","type":"root","visible":"true","clickable":"false"},
  "children": [
    {"attributes":{"id":"entry_toggle_wifi_switch","type":"Toggle","visible":"true","clickable":"true"},"children":[]},
    {"attributes":{"id":"entry_toggle_wifi_switch","type":"Toggle","visible":"true","clickable":"true"},"children":[]}
  ]
}
'@ | ConvertFrom-Json -Depth 10
Assert-Throws -Action {
    Get-MoshWifiPanelState -Layout $ambiguousWifiPanelLayout | Out-Null
} -Message 'Mosh Wi-Fi panel state accepted multiple toggle owners'
$script:wifiPanelNormalizeLayouts = [Collections.Generic.Queue[object]]::new()
$script:wifiPanelNormalizeLayouts.Enqueue($wifiPanelOpenLayout)
$script:wifiPanelNormalizeLayouts.Enqueue($wifiPanelClosedLayout)
$script:wifiPanelBackCount = 0
function Get-MoshWifiLayout {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($script:wifiPanelNormalizeLayouts.Count -gt 0) {
        return $script:wifiPanelNormalizeLayouts.Dequeue()
    }
    return $wifiPanelClosedLayout
}
function Invoke-LeanTTYDeviceKey {
    param(
        [string]$Hdc,
        [string]$Target,
        [int]$KeyCode
    )
    if ($KeyCode -ne 2070) { throw 'Unexpected Wi-Fi panel normalization key' }
    $script:wifiPanelBackCount++
}
$hdc = 'unused'
$targetId = 'unused'
$normalizedWifiPanel = Normalize-MoshWifiPanelClosed -Name 'regression'
Assert-True (
    (Get-MoshWifiPanelState -Layout $normalizedWifiPanel) -ceq 'closed' -and
    $script:wifiPanelBackCount -eq 1
) 'Mosh Wi-Fi panel normalization did not close one known open panel exactly once'
$route = Get-MoshEndpointRoute -Endpoint '192.168.1.4' -RouteTable @'
Destination Gateway Genmask Flags Metric Ref Use Iface
0.0.0.0 192.168.1.1 0.0.0.0 UG 0 0 0 wlan0
192.168.1.0 0.0.0.0 255.255.255.0 U 0 0 0 wlan0
'@
Assert-True ($null -ne $route -and
    $route.identity -ceq '192.168.1.0,0.0.0.0,255.255.255.0,wlan0') `
    'Mosh endpoint route helper did not select the longest matching prefix'
Assert-True ($moshVerifier.Contains("-Text 'x' -InputNode `$inputNode") -and
    $moshVerifier.Contains('Terminal input withheld for runtime recovery')) `
    'Mosh runtime-reclaim verifier does not exercise the post-visibility first-input guard'
$moshNetwork = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'configure-mosh-test-network.ps1'
) -Raw
foreach ($networkContract in @(
    "[ValidateSet('Enable', 'Status', 'Disable')]",
    '[int]$ExternalSshPort = 2223',
    '[int]$BackendSshPort = 32223',
    "`$udpPortRange = '60000-61000'",
    "'LeanTTY-Mosh-Test-SSH-2223'",
    "'LeanTTY-Mosh-Test-UDP-60000-61000'",
    "'LeanTTY-Mosh-Test-UDP-60042'",
    '$migratedLegacy',
    "'{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'",
    'Refusing to overwrite drifted Mosh test network state',
    'netsh interface portproxy add v4tov4',
    'netsh interface portproxy delete v4tov4',
    'New-NetFirewallRule',
    'New-NetFirewallHyperVRule',
    'existingSsh2222Untouched = $true'
)) {
    Assert-True ($moshNetwork.Contains($networkContract)) (
        "Persistent Mosh test network omitted contract: $networkContract"
    )
}
foreach ($moshContract in @(
    'real stock',
    "'start-ssh-auth-fixture.ps1'",
    "'leantty_ssh/ssh-auth-fixture/src/main.rs'",
    "'preflight-device.ps1'",
    "'dev-pc.ps1'",
    "'mosh-input-snapshot'",
    "'mosh-event'",
    "'server-input-exact-before-enter'",
    'function Invoke-MoshChildCheck',
    "'uinput -K -d 2072 -d 2023 -u 2023 -u 2072'",
    'Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $targetId -KeyCode 2023',
    "'uinput -K -d 2047 -d 2023 -u 2023 -u 2047'",
    'Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $targetId -KeyCode 2033',
    '$moshUdpPortMin = 60000',
    '$moshUdpPortMax = 61000',
    'Resolve-MoshRemoteScope',
    "'configure-mosh-test-network.ps1'",
    '-Mode Status',
    '[int]$FixtureBackendPort = 32223',
    "`$fixtureSshAddress = '127.0.0.1'",
    "rport `"tcp:`$FixturePort`" `"tcp:`$FixtureBackendPort`"",
    "fport rm `"tcp:`$FixturePort`" `"tcp:`$FixtureBackendPort`"",
    "sshBootstrapTransport = 'run-scoped-hdc-reverse'",
    "requiredPersistentBoundary = 'windows-and-hyper-v-udp-firewall'",
    'fixtureReverseMappingRemoved = $fixtureMappingRemoved',
    "'-MoshNetworkTimeoutSeconds', `$moshNetworkTimeoutSeconds",
    'serverNetworkTimeoutSeconds = $moshNetworkTimeoutSeconds',
    'FixtureBackendPort must differ from the external FixturePort',
    "[ValidateSet('compatibility', 'agent-tui', 'fixed-endpoint', 'server-path', 'prediction', 'surface-rebuild', 'page-rebuild', 'runtime-reclaim', 'abnormal-exit', 'input-rejection', 'process-recovery', 'pane-close', 'session-isolation', 'pause-recovery', 'wifi-pause-recovery', 'wifi-network-switch', 'suspend-recovery', 'operator-lock-recovery', 'operator-lid-recovery', 'server-disappearance')]",
    "'mosh-session-isolation'",
    'controlName=',
    'mosh-session-[1-9][0-9]*',
    'Clear-MoshLatestSessionMetadata',
    '-ControlDirectory $leftMoshControlDirectory',
    '-ControlDirectory $rightMoshControlDirectory',
    "Submit-MoshChildInput -Text 'ltty-exit' -Name 'ssh-mosh-ssh-exit'",
    'Initialize-MoshSinglePaneWorkspace',
    "Wait-MoshPaneCount -Count 1 -Name 'mosh-pane-close-before-split'",
    "'SSH session connected, pty resized to'",
    'Submit-MoshSshEchoProbe',
    'PERF ping id=',
    'Get-MoshFocusedPaneTerminalMode',
    "-Pattern 'D: 1 chars, mode=\d+'",
    "'pause-recovery', 'wifi-pause-recovery', 'wifi-network-switch', 'prediction'",
    'persistentStateMutatedByScenario = $false',
    'persistentNetworkPreserved = $networkStateReady',
    'localPromptReady = $localPromptReady',
    'uitest uiInput keyEvent 2072 2047 2006',
    'Assert-MoshTerminalSurfaceFocused',
    "'mosh-physical-key-focus.json'",
    '-KeyCode 2044',
    'Wait-WslProcessAbsent',
    '-LinuxPid $moshServerPid -TimeoutSeconds 8',
    'authenticatedGracefulClose = $authenticatedGracefulClose',
    'gracefulServerExitElapsedMs = $gracefulServerExitElapsedMs',
    '"stock-default-dynamic-$moshUdpPortMin-$moshUdpPortMax"',
    'mosh -p $fixedUdpPortStart`:$fixedUdpPortEnd $alias',
    'endpointMatchesRequest = $udpEndpointMatchesRequest',
    'controlled-mosh-fixed-udp-range-selected-and-disconnected',
    'mosh --server=/usr/bin/mosh-server $alias',
    'serverPathMatchesRequest = $serverPathMatchesRequest',
    'controlled-mosh-server-path-selected-and-disconnected',
    'mosh --predict=always $alias',
    'mosh --predict=never $alias',
    'alwaysVisibleBeforeAuthority = $predictionAlwaysVisibleBeforeAuthority',
    'neverHiddenBeforeAuthority = $predictionNeverHiddenBeforeAuthority',
    'normal-pty-kernel-echo-real-interactive-shell',
    'predictionRttBaselineMs =',
    'predictionConfirmationThresholdMs =',
    'controlledOneWayDelayMs =',
    'fixture-owned-bidirectional-40ms-udp-relay',
    'fixture-udp-relay-bidirectional-pause',
    'mosh-prediction-relay-paused',
    'mosh-prediction-relay-stats',
    'mosh-prediction-event',
    'Wait-MoshPredictionRelayDrop',
    'Submit-MoshCanonicalCommand',
    'predictionRelayDroppedPackets =',
    'predictionVisibleLatencyMs =',
    'predictionRenderLatencyMs =',
    'predictionWarmupSamples =',
    "@('uiInput', 'text', `$Text)",
    'Prediction measurement was invalidated by a terminal resize',
    'actual-vt-output-below-measured-rtt',
    'one-printable-ascii-visible-before-udp-recovery',
    'bytes=[1-9][0-9]*',
    'controlled-mosh-prediction-modes-visible-and-isolated',
    'controlled-mosh-zero-model-real-codex-tui-completed',
    'representativeAgentTui = $agentCompatibilityPassed',
    "plannedModelRequests = 0",
    "'agent-compatibility-wsl.sh'",
    'codex-direct-interaction.json',
    'active-mosh-page-survived-arkweb-surface-rebuild-and-restored-the-original-page',
    'Invoke-MoshSurfaceRebuild',
    'moshPageRetainedAfterRebuild = $surfaceRebuildPageRetained',
    'injected-mosh-session-error-restored-the-original-page-and-rejected-session-output',
    "-Pattern 'ACCEPTANCE_MOSH_ERROR state=injected'",
    'moshErrorObserved = $abnormalExitObserved',
    'originalPageRestored = $originalPageRestoredAfterSession',
    'moshPageDiscarded = $moshPageDiscardedAfterSession',
    'forced-client-process-exit-restored-only-the-local-workspace-without-session-content',
    "-Query 'Workspace layout was recovered' -ExpectMatch `$true",
    'remoteContentAbsent = $processRecoveryRemoteContentAbsent',
    'sessionNotRestored = $processRecoverySessionNotRestored',
    'runtimeReclaimed = $runtimeWorkspaceRecovered',
    'acceptance-only-runtime-state-reclaim',
    'ACCEPTANCE_RUNTIME_RECLAIM state=dropped',
    'Terminal input withheld for runtime recovery',
    'Runtime recovery request handled pane=.*recovered=true',
    'active-mosh-pane-closed-and-surviving-pane-started-an-isolated-session',
    'two-mosh-and-ssh-mosh-concurrent-sessions-kept-state-terminal-input-output-and-cleanup-isolated',
    'twoMoshKeysDistinct = $sessionIsolationKeysDistinct',
    'twoMoshOutputIsolated = $twoMoshOutputIsolated',
    'closingOneMoshPreservedTheOther = $twoMoshCloseIsolated',
    'sshMoshOutputIsolated = $sshMoshOutputIsolated',
    'closingMoshPreservedSsh = $sshMoshCloseIsolated',
    'Focus-MoshPane -Side',
    'Concurrent Mosh Panes reused one bootstrap encryption key',
    'closedPaneOutputAbsentFromSurvivor = $paneCloseOldOutputAbsent',
    'survivingPaneCommandPassed = $paneCloseSurvivorCommandPassed',
    'Close-ActiveMoshPane',
    'Wait-MoshPaneCount -Count 1',
    '-Query "LTTY_MOSH_CHECK_OK:$caseId" -ExpectMatch $false',
    "'pane-close-surviving-session-command-passed'",
    'selectedUdpPort = $moshServerPort',
    'realShell = $shellCompatibilityPassed',
    'tmux = $tmuxCompatibilityPassed',
    'basicEditor = $editorCompatibilityPassed',
    'Wait-ControlFile -Path $fixtureShellReady',
    'Wait-ControlFile -Path $fixtureTmuxReady',
    'Wait-ControlFile -Path $fixtureEditorReady',
    'remotePtyResize = $resizeCompatibilityPassed',
    'sustainedInputOutput = $streamCompatibilityPassed',
    'utf8WideAndCombiningOutput = $unicodeCompatibilityPassed',
    'unicodeScreenshotCaptured = (-not [string]::IsNullOrWhiteSpace($unicodeScreenshot))',
    'interactiveLargeOutputAndScrollback = $scrollbackCompatibilityPassed',
    'scrollbackBottomObservedInTerminal = $scrollbackBottomObserved',
    'scrollbackTopAbsentUnderMoshStateSync = $scrollbackTopAbsent',
    'realLess = $lessCompatibilityPassed',
    'lessFirstLineObservedAfterHome = $lessFirstLineObserved',
    'lessLastLineObservedAfterEnd = $lessLastLineObserved',
    'alternateScreenEnterExit = $alternateScreenCompatibilityPassed',
    'alternateScreenPriorContentSearchableAfterExit = $alternateScreenHistoryRetained',
    'mosh-alternate-active.png',
    'mosh-alternate-closed.png',
    "largeOutputContract = 'paced-terminal-state-output-with-observed-local-scrollback-boundary'",
    'bootstrapTextAbsentFromTerminal = $bootstrapTerminalAbsent',
    'preferencesUnchanged = $preferencesUnchanged',
    'streamInputBytes = 512',
    "tc qdisc add dev `$udpImpairmentInterface clsact",
    "tc qdisc del dev `$udpImpairmentInterface clsact",
    'flower ip_proto udp dst_port $moshServerPort action drop',
    'flower ip_proto udp src_port $moshServerPort action drop',
    "'PluginRootComponent_Stack_status_bar_wifi_panel'",
    "'entry_toggle_wifi_switch'",
    'Set-MoshDeviceWifi -Enabled $false',
    'Set-MoshDeviceWifi -Enabled $true',
    "'harmony-status-bar-wlan-toggle'",
    'wifiControlCleanupVerified = $wifiControlCleanupVerified',
    'physical-wifi-pause-reported-interrupted-then-recovered-with-remote-shell-preserved',
    '[string]$AlternateWifiSsid',
    'Get-MoshConnectedWifiSsid',
    "@('shell', 'hidumper', '-s', 'WifiDevice')",
    'ConvertFrom-MoshWifiDeviceDump',
    'Normalize-MoshWifiPanelClosed',
    "-LocalPath (Join-Path `$fixtureRoot `"`$Name.json`")",
    'Alternate Wi-Fi must be saved before automated network switching',
    'neither source address nor routing changed',
    "'harmony-status-bar-saved-wlan-network-selection'",
    'networkIdentityRetention = ''redacted''',
    'sameRemoteTerminalPreserved = $remoteShellAliveAfter',
    'outcome = $sshSwitchOutcome',
    'transportReachable = $sshSwitchTransportReachable',
    'Test-MoshDeviceTcpReachable',
    'reconnectFailed = $sshSwitchReconnectFailed',
    'reconnectTerminalMode = $sshSwitchReconnectTerminalMode',
    "`$sshSwitchOutcome = 'reconnect-failed'",
    'sessionPreserved = $sshSwitchSessionPreserved',
    "requiredUserAction = `$sshSwitchUserAction",
    "`$sshSwitchUserAction = 'reconnect'",
    "`$sshSwitchUserAction = 'disconnect-and-reconnect'",
    'Invoke-MoshSshDisconnectEscape',
    "-Pattern 'SSH escape action=disconnect'",
    "'network-switch-protocol.log'",
    "-Name 'network-switch-ssh-post-switch-command'",
    'physical-wifi-network-switch-mosh-ssh-comparison-passed',
    'Set-MoshWifiNetwork -Ssid $wifiOriginalSsid',
    '& wsl.exe @prefix --exec kill -KILL $moshServerPid',
    "-Pattern 'Mosh reachability state=interrupted reason=no_recent_contact'",
    "-Pattern 'Mosh reachability state=responsive transition=recovered'",
    "shell 'power-shell suspend'",
    "shell 'power-shell wakeup'",
    'sameAppProcessAfterResume = $sameAppProcessAfterResume',
    "processIdentityMethod = 'pid-plus-proc-stat-starttime'",
    'cat /proc/$processId/stat',
    'initialAppProcessStartTimeTicks = $initialAppProcessStartTimeTicks',
    'resumedAppProcessStartTimeTicks = $resumedAppProcessStartTimeTicks',
    "recoveryOutcome = `$operatorRecoveryOutcome",
    "`$operatorRecoveryOutcome = 'client-process-replaced-workspace-only'",
    "`$operatorRecoveryOutcome = 'client-process-and-session-preserved'",
    "`$workspaceOnlyLidRecovery =",
    "'operator-lid-client-process-replaced-workspace-only-recovered'",
    'initialAppProcessId = $initialAppProcessId',
    'resumedAppProcessId = $resumedAppProcessId',
    'remoteShellAliveAtProcessChange = $remoteShellAliveAtProcessChange',
    'serverAliveAtProcessChange = $serverAliveAtProcessChange',
    'preRecoveryCloseObserved = $operatorPreRecoveryCloseObserved',
    'preRecoveryErrorObserved = $operatorPreRecoveryErrorObserved',
    'preRecoveryCloseReason = $operatorPreRecoveryCloseReason',
    'remoteShellAliveBeforeRecoveryInput = $remoteShellAliveBeforeRecoveryInput',
    'serverAliveBeforeRecoveryInput = $serverAliveBeforeRecoveryInput',
    'terminalEofObservedBeforeRecoveryInput = $terminalEofObservedBeforeRecoveryInput',
    '"$operatorStage-pre-recovery-device-app.log"',
    '$operatorPreRecoveryLogs = Get-LeanTTYAppLogs',
    'if ($Scenario -in @(''operator-lock-recovery'', ''operator-lid-recovery''))',
    'recoveryInputMethod = $recoveryInputMethod',
    'systemSuspendMs = $systemSuspendMs',
    'resumeCommandElapsedMs = $resumeCommandElapsedMs',
    'operator-physical-lid-close-open-produced-session-preservation-or-workspace-only-recovery',
    'operator-physical-lid-close-open-then-manual-unlock',
    'physicalLidExercised =',
    'UnavailableCountsAsLocked',
    'Write-LiveStatus -Stage "await-$operatorStage-close"',
    'Write-LiveStatus -Stage "await-$operatorStage-open-unlock"',
    'OPERATOR ACTION REQUIRED:',
    "'lid_' + `$attemptId.Substring(0, 10)",
    "`$recoveryInputMethod = 'harmony-uitest-focus-verified-inputText'",
    'operatorLockObserved = $operatorLockObserved',
    'operatorUnlockObserved = $operatorUnlockObserved',
    'mosh-input-owner-$attempt.json',
    'Controlled Mosh input lost its original Pane; refusing retry or Enter',
    'Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $targetId',
    'interruptionObserved = $interruptionObserved',
    'interruptionReason = $interruptionReason',
    'recoveredStatusObserved = $recoveredStatusObserved',
    'recoveryCommandPassed = $recoveryCommandPassed',
    'remoteShellAliveAfter = $remoteShellAliveAfter',
    "'acceptance-only-ui-context-router-current-page-replacement'",
    'pageRebuildProcessPreserved =',
    'pageRebuildWorkspaceReused =',
    'pageRebuildPageRetained =',
    'pageRebuildCommandPassed =',
    "'page-rebuilt-with-process-session-and-command-preserved'",
    'userCloseRequired = $userCloseRequired',
    'localCloseElapsedMs = $localCloseElapsedMs',
    'impairmentCleanupVerified = $udpImpairmentCleanupVerified',
    "-Query 'MOSH CONNECT' -ExpectMatch `$false",
    "'failure-fixture-stderr.log'",
    "'failure-fixture-stdout.log'",
    "'failure-device-lifecycle.log'",
    "hilog -z 30000 | grep -E '`$remotePattern' | ",
    "grep -E 'Ability on|AppMgr|Process|Kill|Terminate|Fault|APP_CRASH|",
    'MOSH CONNECT\s+\d+\s+[A-Za-z0-9+/]{22}',
    "'1.6-mosh-physical-acceptance'",
    "acceptanceEligible = (`$Formal -and `$result -eq 'passed' -and `$cleanupPassed)",
    'Resolve-LeanTTYRetainedCandidate',
    'Assert-LeanTTYCandidateHarnessCompatibility',
    'previousAttemptId = $PreviousAttemptId',
    'result = $(if ($cleanupPassed)',
    'Write-LeanTTYAtomicJson -Path $evidencePath',
    'temporaryDirectoryRemoved'
)) {
    Assert-True ($moshVerifier.Contains($moshContract)) (
        "Mosh physical diagnostic omitted contract: $moshContract"
    )
}
Assert-True (-not $moshVerifier.Contains('已连接 WLAN')) `
    'Mosh Wi-Fi switching still infers connection state from localized system UI text'

Assert-True (
    $acceptanceSource.Contains('acceptancePageReplacedFingerprint') -and
    $acceptanceSource.Contains('acceptanceSnapshotFingerprint') -and
    $acceptanceSource -match
      '(?s)\$snapshotReplacement\s*=.*?if \(snapshot !== null\).*?reportAcceptanceSnapshotFingerprint\(\).*?for \(var j = 0;' -and
    $acceptanceSource -match
      '(?s)\$pageReplacementReplacement\s*=.*?var completeReplacement = function\(\).*?reportAcceptancePageReplacedFingerprint\(\).*?onComplete\(\)' -and
    $moshVerifier.Contains('function Get-MoshSnapshotFingerprint') -and
    $moshVerifier.Contains('ACCEPTANCE_SNAPSHOT_FINGERPRINT') -and
    $moshVerifier.Contains('function Get-MoshPageReplacementFingerprint') -and
    $moshVerifier.Contains('ACCEPTANCE_PAGE_REPLACED_FINGERPRINT') -and
    $moshVerifier.Contains('restoredBeforeLocalOutput = $restoredPageFingerprint') -and
    $moshVerifier.Contains('postExit = $postExitPageFingerprint')
) 'Mosh page restoration lacks an acknowledged pre-local-output xterm fingerprint oracle'
Assert-True (
    $moshVerifier.Contains('function Get-MoshTerminalFingerprint') -and
    $moshVerifier.Contains('ACCEPTANCE_TERMINAL_FINGERPRINT') -and
    $moshVerifier.Contains('ACCEPTANCE_SEARCH_RESULT') -and
    $moshVerifier.Contains('Intended terminal Search field lost focus before query delivery') -and
    -not $moshVerifier.Contains("-Name 'mosh-original-page-restored-search'") -and
    -not $moshVerifier.Contains("-Name 'mosh-abnormal-original-page-restored-search'")
) 'Mosh page restoration and Search must retain independent direct oracles'
Assert-True (
    $moshVerifier.Contains('function Get-MoshEndpointRoute') -and
    $moshVerifier.Contains('endpointRoute') -and
    $moshVerifier.Contains('endpointReachable') -and
    $moshVerifier.Contains('transitionHistory') -and
    $moshVerifier.Contains('mosh-environment-dirty-') -and
    $moshVerifier.Contains('if ($route.Count -ne 1) { return $null }') -and
    $moshVerifier.Contains('if ($linkActive)') -and
    -not $moshVerifier.Contains('if ($linkActive -and $null -ne $endpointRoute)') -and
    $moshVerifier.Contains("@('shell', 'hidumper', '-s', 'WifiDevice')") -and
    $moshVerifier.Contains('Normalize-MoshWifiPanelClosed') -and
    -not $moshVerifier.Contains('已连接 WLAN') -and
    $moshVerifier.Contains('if (-not [bool]$beforeState.active -or -not [bool]$beforeState.endpointReachable)') -and
    -not $moshVerifier.Contains('[string]::IsNullOrWhiteSpace([string]$beforeState.endpointRoute) -or') -and
    -not $moshVerifier.Contains('routeDigest')
) 'Mosh Wi-Fi switching lacks the system-state, direct-endpoint or dirty-state guards'
Assert-True (
    -not $moshVerifier.Contains('Submit-MoshVerifiedChildCommand') -and
    -not $moshVerifier.Contains('Get-MoshTerminalSearchMatch') -and
    -not $moshVerifier.Contains('Submit-MoshChildInput -Text "ltty-shell-check $caseId"') -and
    -not $moshVerifier.Contains("Submit-MoshChildInput -Text 'g' -Submit `$false") -and
    -not $moshVerifier.Contains("Submit-MoshChildInput -Text 'G' -Submit `$false") -and
    -not $moshVerifier.Contains("Submit-MoshChildInput -Text 'q' -Submit `$false")
) 'Mosh pager control keys still use unreliable UiTest text injection'
Assert-True (
    -not $moshVerifier.Contains('pane-output-and-xterm-write-ack-after-four-authoritative-warmup-characters')
) 'Mosh prediction verifier still treats a fixed warmup count as confirmed prediction evidence'
Assert-True (
    $moshVerifier.Contains("[string]`$_.attributes.bundleName -eq 'com.leantty.app'") -and
    $moshVerifier.Contains("[string]`$_.attributes.abilityName -eq 'EntryAbility'") -and
    $moshVerifier.Contains('[string]$_.attributes.hostWindowId -eq $leanTTYWindowId')
) 'Mosh window resize selector is not scoped to the focused LeanTTY host window'
Assert-True (
    -not $moshVerifier.Contains("@('uiInput', 'keyEvent', 2072, 2019)")
) 'Mosh input retry still uses a UiTest chord that does not reliably clear the remote line'
Assert-True (
    $moshVerifier.Contains('[string]$resumedProcessIdentity.key -ceq') -and
    -not $moshVerifier.Contains('$resumedPid -ceq $appPid')
) 'Mosh lifecycle verifier still treats a reusable numeric PID as process identity'
Assert-True (
    -not ($moshSessionViewModel -match 'this\.moshClient\.resize\(this\.lastCols, this\.lastRows\)')
) 'Mosh connected handling still repeats the initial terminal size and resets the prediction epoch'
Assert-True (
    $moshVerifier.Contains('Mosh prediction Ctrl+U injection') -and
    $moshVerifier.Contains("@('uiInput', 'keyEvent', 2072, 2037)") -and
    $moshVerifier.Contains('function Submit-MoshShellMarker') -and
    $moshVerifier.Contains('Submit-MoshCanonicalCommand -Text "touch -- $WslPath"') -and
    $moshVerifier.Contains("'^/[A-Za-z0-9_./-]+$'") -and
    $moshVerifier.Contains('Wait-ControlFile -Path $WindowsPath') -and
    $moshVerifier.Contains('-WslPath "$fixturePredictionEventWsl-main"')
) 'Mosh prediction verifier no longer reserves a shell-safe authoritative marker for post-recovery convergence'
Assert-True (
    $moshVerifier.Contains('controlled-mosh-terminal-compatibility-and-disconnect-completed') -and
    $moshVerifier.Contains('deviceStateRemoved = $deviceStateCleaned') -and
    $moshVerifier.Contains('fixtureProcessesAbsent = $fixtureCleaned') -and
    $moshVerifier.Contains('$script:deviceStateCleaned = $true') -and
    $moshVerifier.Contains('$script:fixtureCleaned = $true') -and
    -not $moshVerifier.Contains('New-NetFirewallRule') -and
    -not $moshVerifier.Contains('Remove-NetFirewallRule') -and
    -not $moshVerifier.Contains('portproxy add') -and
    -not $moshVerifier.Contains('portproxy delete') -and
    -not $moshVerifier.Contains("'-MoshServerPort'") -and
    -not $moshVerifier.Contains("-Pattern 'ACCEPTANCE_INPUT_SUBMIT'") -and
    -not $moshVerifier.Contains('MOSH_KEY=')
) 'Mosh physical diagnostic lacks a content-free verdict or paired cleanup contract'

$moshMatrixPath = Join-Path $PSScriptRoot 'verify-mosh-matrix-pc.ps1'
Assert-True (Test-Path -LiteralPath $moshMatrixPath -PathType Leaf) (
    'Formal Mosh physical matrix orchestrator is missing'
)
$moshMatrix = Get-Content -LiteralPath $moshMatrixPath -Raw
foreach ($formalMoshContract in @(
    'Get-LeanTTYMoshFormalScenarios',
    'Assert-LeanTTYRuntimeReclaimEvidence -Evidence $evidence.runtimeReclaim',
    'Formal = $true',
    'acceptanceEligible = ($matrixResult',
    'Assert-MoshScenarioEvidence',
    'Mosh completed checkpoints are not a valid fixed-order prefix',
    'Mosh failed-stage cleanup did not pass',
    'alternateWifiSsidIdentity = $alternateWifiSsidIdentity',
    'Write-LeanTTYAtomicJson -Path $matrixPath',
    'PreviousAttemptId = $previousAttemptId'
)) {
    Assert-True ($moshMatrix.Contains($formalMoshContract)) (
        "Formal Mosh matrix omitted contract: $formalMoshContract"
    )
}
Assert-True (
    -not $moshMatrix.Contains('Start-Job') -and
    -not $moshMatrix.Contains('ForEach-Object -Parallel')
) 'Formal Mosh matrix must control the physical PC serially'

$sshMatrixPath = Join-Path $PSScriptRoot 'verify-ssh-matrix-pc.ps1'
Assert-True (Test-Path -LiteralPath $sshMatrixPath -PathType Leaf) (
    'Formal SSH physical matrix orchestrator is missing'
)
$sshMatrixVerifier = Get-Content -Raw -LiteralPath $sshMatrixPath
Assert-True (
    $sshMatrixVerifier.Contains("'transport-performance'") -and
    $sshMatrixVerifier.Contains("'authentication-methods'") -and
    $sshMatrixVerifier.Contains("'lifecycle-recovery'") -and
    $sshMatrixVerifier.Contains("'pane-focus-attention'") -and
    $sshMatrixVerifier.Contains("'verify-ssh-auth-pc.ps1'") -and
    $sshMatrixVerifier.Contains('-Group $group') -and
    $sshMatrixVerifier.Contains('-VerifyPreferencesUnchanged') -and
    $sshMatrixVerifier.Contains("cleanup.result -ne 'passed'") -and
    $sshMatrixVerifier.Contains("runMode -ne 'acceptance'") -and
    $sshMatrixVerifier.Contains('candidate.retained') -and
    $sshMatrixVerifier.Contains('harness.gitDirty') -and
    $sshMatrixVerifier.Contains('preferences.unchanged') -and
    $sshMatrixVerifier.Contains("'before-transparency-performance'") -and
    $sshMatrixVerifier.Contains("'terminal-transparency-mode-restored'") -and
    $sshMatrixVerifier.Contains('performanceMatrix.initialMode') -and
    $sshMatrixVerifier.Contains('performanceMatrix.restoredMode') -and
    $sshMatrixVerifier.Contains('candidate.sha256') -and
    $sshMatrixVerifier.Contains('harness.gitTree') -and
    $sshMatrixVerifier.Contains("'ssh-matrix.json'") -and
    $sshMatrixVerifier.Contains('completedGroups') -and
    $sshMatrixVerifier.Contains('[switch]$Resume') -and
    $sshMatrixVerifier.Contains('Write-LeanTTYAtomicJson') -and
    $sshMatrixVerifier.Contains("'progress.json'") -and
    $sshMatrixVerifier.Contains('attemptId = [string]$groupEvidence.attemptId') -and
    $sshMatrixVerifier.Contains("throw 'R2: harness identity changed") -and
    $sshMatrixVerifier.Contains("throw 'R4: product candidate identity changed") -and
    $sshMatrixVerifier.Contains('contentRecorded = $false')
) 'Formal SSH physical matrix does not enforce isolated fixed-order checkpoints'

$hostIdentityVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-host-identity-pc.ps1'
) -Raw
foreach ($hostIdentityContract in @(
    'Get-LeanTTYDeviceUnlockPasswordPath',
    "`$keyName = if (`$DefaultEcdsa)",
    "`$fixtureUser = 'key-install'",
    "'start-ssh-auth-fixture.ps1'",
    'Read-LeanTTYFixtureReadiness',
    '$fixtureLinuxPid',
    'native auth event kind=password, layer=target',
    'Assert-LeanTTYLayoutExcludesValues',
    'host add $hostAlias',
    'ssh-copy-id -i $keyName',
    'ssh $hostAlias',
    'Restart-HostIdentityApp',
    '-i none',
    'Wait-HostIdentityFixtureLog',
    'auth method=publickey scenario=KeyInstall fingerprint=',
    'key-install fingerprint=',
    'identity-removal-restored-password-fallback',
    'explicit-binding-recovery',
    'Invoke-LeanTTYDialogButton',
    'Controlled SSH fixture Linux process cleanup failed',
    "'failure-app.log'",
    "'fixture-stderr.log'",
    "scenario = 'host-identity-binding'"
)) {
    Assert-True ($hostIdentityVerifier.Contains($hostIdentityContract)) (
        "Host Identity physical verifier omitted contract: $hostIdentityContract"
    )
}
Assert-True (
    $hostIdentityVerifier.Contains('[switch]$OpenSshCompatibility') -and
    $hostIdentityVerifier.Contains('sudo -n useradd') -and
    $hostIdentityVerifier.Contains('sudo -n userdel -r') -and
    $hostIdentityVerifier.Contains('Disposable WSL OpenSSH account remained after cleanup') -and
    $hostIdentityVerifier.Contains('Physical secret input accepts only disposable numeric passwords') -and
    $hostIdentityVerifier.Contains('StandardInput.Write("$UserName`:$Password`n")') -and
    -not $hostIdentityVerifier.Contains('StandardInput.WriteLine("$UserName`:$Password")') -and
    $hostIdentityVerifier.Contains('System OpenSSH omitted the exact accepted public-key fingerprint') -and
    -not $hostIdentityVerifier.Contains('pgrep -u $temporaryWslUser -x sshd') -and
    -not $hostIdentityVerifier.Contains('/usr/sbin/sshd') -and
    $hostIdentityVerifier.Contains('/.ssh/authorized_keys')
) 'Host Identity OpenSSH compatibility mode lacks bounded account setup, proof, or cleanup'
Assert-True (
    $hostIdentityVerifier.Contains('[switch]$DefaultEcdsa') -and
    $hostIdentityVerifier.Contains('-DefaultEcdsa requires -OpenSshCompatibility') -and
    $hostIdentityVerifier.Contains("`$keyName = if (`$DefaultEcdsa) { 'id_ecdsa' }") -and
    $hostIdentityVerifier.Contains('key import $ecdsaImportPath $keyName') -and
    $hostIdentityVerifier.Contains('default-ecdsa-authenticated-before-restart') -and
    $hostIdentityVerifier.Contains('default-ecdsa-authenticated-after-restart') -and
    $hostIdentityVerifier.Contains('temporary-account-authorized-only-id-ecdsa') -and
    $hostIdentityVerifier.Contains('independentEcdsaSourceAbsenceAudit')
) 'Host Identity verifier lacks the isolated default id_ecdsa compatibility scenario'
Assert-True (
    $hostIdentityVerifier.Contains('function Test-HostIdentityDefaultKeyFilesPresent') -and
    $hostIdentityVerifier.Contains(
        "`$KeyName -notin @('id_ed25519', 'id_rsa', 'id_ecdsa')"
    ) -and
    $hostIdentityVerifier.Contains('Test-HostIdentityDefaultKeyFilesPresent')
) 'Host Identity default-key inspection bypasses the bounded standard-name guard'
Assert-True (
    $hostIdentityVerifier.Contains(
        "foreach (`$defaultName in @('id_ed25519', 'id_rsa', 'id_ecdsa'))"
    ) -and
    $hostIdentityVerifier.Contains(
        'Default Identity precondition is not isolated: $defaultName exists'
    )
) 'Host Identity default-key scenario does not require an isolated standard-name baseline'
Assert-True (
    $hostIdentityVerifier.Contains('[switch]$PreserveExistingEd25519') -and
    $hostIdentityVerifier.Contains('-PreserveExistingEd25519 requires -DefaultEcdsa') -and
    $hostIdentityVerifier.Contains('key export id_ed25519 $ed25519BackupName') -and
    $hostIdentityVerifier.Contains('key rm id_ed25519') -and
    $hostIdentityVerifier.Contains('key import $ed25519BackupPath id_ed25519') -and
    $hostIdentityVerifier.Contains('__acceptance_key_backup_$Action $ed25519BackupName') -and
    $hostIdentityVerifier.Contains(
        "-not (Test-HostIdentityDefaultKeyFilesPresent -KeyName 'id_ed25519')"
    ) -and
    $hostIdentityVerifier.Contains('ed25519ExportAttempted') -and
    $hostIdentityVerifier.Contains('ed25519ExportVerified') -and
    $hostIdentityVerifier.Contains('restoredEd25519Fingerprint') -and
    $hostIdentityVerifier.Contains('independentEd25519BackupAbsenceAudit') -and
    -not $hostIdentityVerifier.Contains('sha256sum $Path')
) 'Host Identity verifier lacks reversible product-path preservation for an existing id_ed25519'

$deviceRegressionText = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'device-regression.ps1'
) -Raw
$hdcCommonText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hdc-common.ps1') -Raw
Assert-True (
    $deviceRegressionText.Contains('Get-HdcUiLayout') -and
    $hdcCommonText.Contains("@('shell', 'uitest', 'dumpLayout', '-p', `$remotePath)") -and
    -not $hdcCommonText.Contains("'dumpLayout', '-p', `$remotePath, '-a'")
) 'Routine device layouts still request unused UiTest extended visual attributes'
Assert-True (
    $deviceRegressionText.Contains("return 't' + [Guid]::NewGuid()") -and
    $deviceTextSource.Contains("'shell', 'uitest', 'uiInput', 'inputText', `$center.x, `$center.y, `$Text") -and
    -not $deviceTextSource.Contains('Start-Sleep -Milliseconds 500')
) 'Device secret injection is not restricted to stable lowercase input with focus-verified targeted UiTest delivery'

$sessionViewModel = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\viewmodel\SessionViewModel.ets'
) -Raw
$indexPage = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\pages\Index.ets'
) -Raw
$terminalPane = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\view\components\TerminalPane.ets'
) -Raw
$entryAbility = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\entryability\EntryAbility.ets'
) -Raw
$transferFileManager = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\model\transfer\TransferFileManager.ets'
) -Raw
$commandBarViewModel = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\viewmodel\CommandBarViewModel.ets'
) -Raw
$acceptanceSource = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'acceptance-source.ps1'
) -Raw
$fileTransferVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-file-transfer-pc.ps1'
) -Raw
$putGetVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-put-get-pc.ps1'
) -Raw
$configVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-config-import-export-pc.ps1'
) -Raw
Assert-True (
    $configVerifier.Contains("gate = 'config-import-export-physical-pc'") -and
    $configVerifier.Contains('Submit-LeanTTYDeviceCommand') -and
    $configVerifier.Contains('CONFIG_IMPORT result=success,replace=true') -and
    $configVerifier.Contains('CONFIG_EXPORT result=success') -and
    $configVerifier.Contains('Export conflict changed the existing Downloads file') -and
    $configVerifier.Contains('Restart did not reopen the imported durable config') -and
    $configVerifier.Contains('Product-path cleanup did not restore the original unmanaged config bytes') -and
    $configVerifier.Contains('__acceptance_config_') -and
    $configVerifier.Contains('ACCEPTANCE_CONFIG state=verified,passed=true') -and
    -not $configVerifier.Contains('/storage/Users/currentUser/Download') -and
    -not $configVerifier.Contains('file recv') -and
    $configVerifier.Contains('cleanupComplete = $cleanupComplete') -and
    $configVerifier.Contains("acceptanceEligible = `$false")
) 'Config import/export physical verifier lost input, persistence, conflict, evidence or cleanup controls'
Assert-True (
    $terminalPane.Contains('.onKeyPreIme') -and
    $terminalPane.Contains('.onInterceptKeyEvent') -and
    -not $terminalPane.Contains('.onKeyEventDispatch')
) 'Terminal Web owns unhandled key dispatch; the generic component dispatcher must not shadow it'
Assert-True (
    -not $sessionViewModel.Contains('ACCEPTANCE_INPUT_SUBMIT') -and
    $acceptanceSource.Contains("import { ACCEPTANCE_TESTS } from 'BuildProfile'") -and
    $acceptanceSource.Contains('ACCEPTANCE_INPUT_SUBMIT') -and
    $acceptanceSource.Contains('ACCEPTANCE_RUNTIME_RECLAIM state=dropped') -and
    $acceptanceSource.Contains('reclaimRuntimeStateForAcceptance') -and
    $acceptanceSource.Contains('Acceptance: Rebuild Renderer') -and
    $acceptanceSource.Contains('Acceptance: Downloads No-Replace') -and
    $acceptanceSource.Contains('Acceptance: Downloads FD Boundary') -and
    $acceptanceSource.Contains('Acceptance: Downloads Manager Boundary') -and
    $acceptanceSource.Contains('ACCEPTANCE_DOWNLOADS_NOREPLACE') -and
    $acceptanceSource.Contains('ACCEPTANCE_DOWNLOADS_FD') -and
    $acceptanceSource.Contains('ACCEPTANCE_DOWNLOADS_MANAGER') -and
    $acceptanceSource.Contains('ACCEPTANCE_CONFIG state=prepared') -and
    $acceptanceSource.Contains('ACCEPTANCE_CONFIG state=verified,passed=true') -and
    $acceptanceSource.Contains('__acceptance_config_') -and
    $acceptanceSource.Contains('ACCEPTANCE_KEY_BACKUP state=observed') -and
    $acceptanceSource.Contains('ACCEPTANCE_KEY_BACKUP state=verified') -and
    $acceptanceSource.Contains('__acceptance_key_backup_') -and
    $acceptanceSource.Contains('FileUtils.removeFileRequired(backupPrivate)') -and
    $acceptanceSource.Contains('FileUtils.removeFileRequired(backupPublic)') -and
    -not $acceptanceSource.Contains('Acceptance: Open Search') -and
    -not $acceptanceSource.Contains('Debug Material') -and
    $acceptanceSource.Contains('pasteClipboardForAcceptance') -and
    $acceptanceSource.Contains('ctrlKey && altKey && !shiftKey && event.keyCode === 2038') -and
    $acceptanceSource.Contains('ACCEPTANCE_LOCAL_DISK_FULL armed') -and
    $acceptanceSource.Contains('No space left on device (os error 28)') -and
    $acceptanceSource.Contains('Invoke-WithLeanTTYAcceptanceSource') -and
    $acceptanceSource.Contains('Invoke-WithLeanTTYNativeAcceptanceSource')
) 'Acceptance-only ArkTS is not isolated from the production source tree'
Assert-True (
    $fileTransferVerifier.Contains('Acceptance: Downloads No-Replace') -and
    $fileTransferVerifier.Contains('Acceptance: Downloads FD Boundary') -and
    $fileTransferVerifier.Contains('Acceptance: Downloads Manager Boundary') -and
    $fileTransferVerifier.Contains('ACCEPTANCE_DOWNLOADS_NOREPLACE passed=true') -and
    $fileTransferVerifier.Contains('ACCEPTANCE_DOWNLOADS_FD passed=true') -and
    $fileTransferVerifier.Contains('ACCEPTANCE_DOWNLOADS_MANAGER passed=true') -and
    $fileTransferVerifier.Contains('managerObservation') -and
    $fileTransferVerifier.Contains('device-downloads-capability.json') -and
    ([regex]::Matches($fileTransferVerifier, 'Start-Sleep -Milliseconds 1000').Count -ge 3) -and
    $fileTransferVerifier.Contains('Invoke-LeanTTYDeviceClick') -and
    $fileTransferVerifier.Contains('Get-LeanTTYDeviceLayout') -and
    $fileTransferVerifier.Contains('Start-LeanTTYRegressionApp')
) 'Focused file-transfer physical-PC gate is incomplete'
Assert-True (
    $putGetVerifier.Contains('get -p $FixturePort') -and
    $putGetVerifier.Contains('put -p $FixturePort') -and
    $putGetVerifier.Contains('completed direction=get,bytes=$expectedCompletionBytes|failed code=\S+') -and
    $putGetVerifier.Contains('completed direction=put,bytes=$expectedCompletionBytes|failed code=\S+') -and
    $putGetVerifier.Contains('GET completed without the FINALIZING stage') -and
    $putGetVerifier.Contains('PUT completed without the FINALIZING stage') -and
    $putGetVerifier.Contains('GET large-file progress completed without visible progress and live speed') -and
    $putGetVerifier.Contains('PUT large-file progress completed without visible progress and live speed') -and
    $putGetVerifier.Contains('FILE_TRANSFER progress=visible') -and
    $putGetVerifier.Contains('FILE_TRANSFER speed=visible') -and
    $putGetVerifier.Contains('GET then PUT changed the file SHA-256') -and
    $putGetVerifier.Contains('HarmonyOS application logs exposed the temporary fixture password') -and
    $putGetVerifier.Contains('[switch]$CancelGet') -and
    $putGetVerifier.Contains('[switch]$CloseApplication') -and
    $putGetVerifier.Contains('[switch]$ClosePane') -and
    $putGetVerifier.Contains('[switch]$StallPreparation') -and
    $putGetVerifier.Contains('[switch]$FailRemoteCleanup') -and
    $putGetVerifier.Contains('[switch]$FailLocalCleanup') -and
    $putGetVerifier.Contains('[switch]$LocalDiskFull') -and
    $putGetVerifier.Contains('[switch]$Backpressure') -and
    $putGetVerifier.Contains('[switch]$ForceTerminate') -and
    $putGetVerifier.Contains('[switch]$LateEvents') -and
    $putGetVerifier.Contains('[switch]$DisconnectGet') -and
    $putGetVerifier.Contains('[switch]$ServerAliveBlackhole') -and
    $putGetVerifier.Contains('[switch]$AuthenticationMatrix') -and
    $putGetVerifier.Contains("'-SftpFault'") -and
    $putGetVerifier.Contains('Read-LeanTTYSharedTextFile') -and
    $deviceRegressionText.Contains('[IO.FileShare]::ReadWrite') -and
    $putGetVerifier.Contains('FILE_TRANSFER result=failed code=REMOTE_CLEANUP') -and
    $putGetVerifier.Contains('Remote cleanup failure exposed the final remote file name') -and
    $putGetVerifier.Contains('device-put-remote-cleanup-failure.json') -and
    $putGetVerifier.Contains('device-get-local-cleanup-failure.json') -and
    $putGetVerifier.Contains('device-get-local-disk-full.json') -and
    $putGetVerifier.Contains('device-authentication-matrix.json') -and
    $putGetVerifier.Contains('File transfer authentication prompt=private-key-passphrase') -and
    $putGetVerifier.Contains('File transfer authentication prompt=keyboard-interactive') -and
    $putGetVerifier.Contains('explicit -i affected only its command') -and
    $putGetVerifier.Contains('Test-LeanTTYDeviceKeyFilesPresent') -and
    $putGetVerifier.Contains('Submit-LeanTTYDeviceCommand') -and
    $putGetVerifier.Contains('-ExpectedCommandProvider') -and
    $putGetVerifier.Contains('Wait-LeanTTYAcceptanceIdleInputState') -and
    -not $putGetVerifier.Contains('Wait-ExactAcceptanceCommandSubmit') -and
    $putGetVerifier.Contains('Submit-HiddenTransferValue -Value $script:secret') -and
    $putGetVerifier.Contains('Assert-LeanTTYLayoutExcludesValues') -and
    $putGetVerifier.Contains('Wait-AuthenticationMatrixKeyCreated') -and
    $putGetVerifier.Contains('device-put-get-backpressure.json') -and
    $putGetVerifier.Contains('device-put-get-force-termination.json') -and
    $putGetVerifier.Contains('device-put-get-late-events.json') -and
    $putGetVerifier.Contains('Rejected stale file transfer event, kind=completed') -and
    $putGetVerifier.Contains('function Wait-FileTransferAuthenticationState') -and
    $putGetVerifier.Contains('auth-observer-') -and
    $putGetVerifier.Contains('snapshotObserved') -and
    $putGetVerifier.Contains('liveObserved') -and
    $putGetVerifier.Contains('authentication-observation-timeout') -and
    $putGetVerifier.Contains('SessionViewModel,FileTransferClient') -and
    $putGetVerifier.Contains('aa force-stop com.leantty.app') -and
    $putGetVerifier.Contains('Application close preparation') -and
    $putGetVerifier.Contains('ACCEPTANCE_FILE_TRANSFER_DROPPED=[1-9]') -and
    $putGetVerifier.Contains('cleanupFailureFinalPresent=false') -and
    $putGetVerifier.Contains('temporaryCount=1') -and
    $putGetVerifier.Contains('device-get-disconnect.json') -and
    $putGetVerifier.Contains('device-get-server-alive.json') -and
    $putGetVerifier.Contains('FILE_TRANSFER result=failed code=KEEPALIVE_TIMEOUT') -and
    $putGetVerifier.Contains("'-EnableServerOutputDrop'") -and
    $putGetVerifier.Contains('host rm $serverAliveHostAlias') -and
    $putGetVerifier.Contains('[switch]$MinimizeGet') -and
    $putGetVerifier.Contains('[switch]$SelectionCopy') -and
    $putGetVerifier.Contains('[switch]$FileNameMatrix') -and
    $putGetVerifier.Contains('Submit-TerminalTextWithAcceptanceData') -and
    $putGetVerifier.Contains('device-put-get-file-name-matrix.json') -and
    $putGetVerifier.Contains("('l' * 220) + '.bin'") -and
    $putGetVerifier.Contains('Invoke-LeanTTYDeviceCtrlAltS') -and
    $putGetVerifier.Contains('Invoke-LeanTTYDeviceCtrlC') -and
    $putGetVerifier.Contains('Clipboard copy success=true,length=4') -and
    $putGetVerifier.Contains('Window visibility changed: visible=false') -and
    $putGetVerifier.Contains('transfer-restored-after-minimized-get.png') -and
    $putGetVerifier.Contains('FILE_TRANSFER result=failed code=NETWORK') -and
    $putGetVerifier.Contains('ACCEPTANCE_LOCAL_DISK_FULL armed') -and
    $putGetVerifier.Contains('ACCEPTANCE_FILE_TRANSFER_PREPARATION waiting=true') -and
    $putGetVerifier.Contains('device-put-get-pane-close-preparing.json') -and
    $putGetVerifier.Contains('device-put-get-application-close-preparing.json') -and
    $putGetVerifier.Contains('SftpDelayMilliseconds') -and
    $putGetVerifier.Contains('Invoke-LeanTTYDeviceCtrlC') -and
    $putGetVerifier.Contains('FILE_TRANSFER result=(cancelled|failed|completed)') -and
    $putGetVerifier.Contains("terminalMatches.Count -ne 1") -and
    $putGetVerifier.Contains('Application close preparation completed') -and
    $putGetVerifier.Contains('EnhanceCloseBtn') -and
    $putGetVerifier.Contains('device-put-get-application-close.json') -and
    $putGetVerifier.Contains('device-put-get-pane-close.json') -and
    $putGetVerifier.Contains('one Pane remained usable in the original application process') -and
    $putGetVerifier.Contains('temporaryPresent=false') -and
    $putGetVerifier.Contains('device-put-get-cancel.json') -and
    $putGetVerifier.Contains('fport rm "tcp:$FixturePort" "tcp:$FixturePort"') -and
    -not $putGetVerifier.Contains('rport rm "tcp:$FixturePort"') -and
    $putGetVerifier.Contains('$awakeLeaseMilliseconds = ($fixtureRunSeconds + 300) * 1000') -and
    $putGetVerifier.Contains('-TimeoutMilliseconds $awakeLeaseMilliseconds') -and
    $putGetVerifier.Contains('Invoke-LeanTTYDeviceClick') -and
    $putGetVerifier.Contains('-WindowStyle Hidden') -and
    $putGetVerifier.Contains('device-put-get.json')
) 'Production PUT/GET physical-PC verifier is incomplete'
Assert-True (
    $indexPage.Contains('ApplicationCloseCoordinator.register(this.applicationCloseHandler)') -and
    $indexPage.Contains('ApplicationCloseCoordinator.unregister(this.applicationCloseHandler)') -and
    $entryAbility.Contains('await ApplicationCloseCoordinator.prepareTermination()') -and
    $indexPage -match (
        'private async terminateApplication[\s\S]*?' +
        'await ApplicationCloseCoordinator\.prepareTermination\(\)[\s\S]*?' +
        'await context\.terminateSelf\(\)'
    ) -and
    $entryAbility.Contains('ApplicationCloseCoordinator.resetPreparation()') -and
    $indexPage.Contains('ApplicationCloseCoordinator.resetPreparation()') -and
    $entryAbility.Contains('Application close preparation failed')
) 'Application termination lost the public close-coordinator lifecycle wiring'
Assert-True (
    $transferFileManager.Contains('fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW') -and
    $transferFileManager.Contains('fs.OpenMode.READ_ONLY | fs.OpenMode.DIR | fs.OpenMode.NOFOLLOW') -and
    $transferFileManager.Contains('!stat.isFile() || stat.isSymbolicLink()') -and
    $transferFileManager.Contains('!stat.isDirectory() || stat.isSymbolicLink()') -and
    $transferFileManager.Contains('fs.moveFileSync(prepared.tempPath, prepared.finalPath, 1)') -and
    $transferFileManager.Contains('fs.moveFileSync(prepared.tempPath, candidatePath, 1)')
) 'Downloads transfer lost required no-follow, symlink rejection, or no-replace platform flags'
Assert-True (
    $commandBarViewModel.Contains('TerminalTextPolicy.isSafe(value)') -and
    -not $commandBarViewModel.Contains('DownloadsAccessManager') -and
    -not $commandBarViewModel.Contains('FileTransferClient') -and
    -not $commandBarViewModel.Contains('SshClient')
) 'Tab completion lost its text-safety or no-network dependency boundary'

foreach ($productionSource in @(
    'entry\src\main\ets\pages\Index.ets',
    'entry\src\main\ets\model\bridge\TerminalBridge.ets',
    'entry\src\main\ets\model\terminal\TerminalSurfaceController.ets',
    'entry\src\main\ets\viewmodel\SessionViewModel.ets'
)) {
    $productionText = Get-Content -LiteralPath (Join-Path $repoRoot $productionSource) -Raw
    Assert-True (
        $productionText -notmatch (
            'ACCEPTANCE_TESTS|Acceptance:|ForAcceptance|ACCEPTANCE_INPUT_SUBMIT'
        )
    ) "Production ArkTS contains acceptance-only source: $productionSource"
}

$backgroundBellVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-background-bell-notification-pc.ps1'
) -Raw
$backgroundBellVerifier += Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'notification-regression.ps1'
) -Raw
Assert-True (
    $backgroundBellVerifier.Contains('notificationCardCount') -and
    $backgroundBellVerifier.Contains("minimizeBounds.Groups['y2']") -and
    $backgroundBellVerifier.Contains("'-HapPath is required") -and
    $backgroundBellVerifier.Contains('test-signed-diagnostic-hap') -and
    $backgroundBellVerifier.Contains('suppressedPaneId') -and
    $backgroundBellVerifier.Contains('resetPublished') -and
    $backgroundBellVerifier.Contains('Expected one notification after visible reset') -and
    $backgroundBellVerifier.Contains('notification suppressed for current background episode') -and
    $backgroundBellVerifier.Contains('A terminal needs your attention') -and
    $backgroundBellVerifier.Contains('终端有新提示') -and
    $backgroundBellVerifier.Contains('Background BEL return applied') -and
    $backgroundBellVerifier.Contains('Background BEL return ignored because the source is no longer pending') -and
    $backgroundBellVerifier.Contains('source-handled-first') -and
    $backgroundBellVerifier.Contains('source-pane-destroyed') -and
    $backgroundBellVerifier.Contains('notification-panel-after-manual-dismiss') -and
    $backgroundBellVerifier.Contains('notification-panel-after-dismiss-settle') -and
    $backgroundBellVerifier.Contains('Assert-NotificationCleanup') -and
    $backgroundBellVerifier.Contains('Restore-NotificationPermission') -and
    $backgroundBellVerifier.Contains('[privacy]')
) 'Background BEL notification scenario lacks suppression, return, privacy, or cleanup oracles'

$backgroundBellSource = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\model\ui\BackgroundBellNotification.ets'
) -Raw
Assert-True (
    $backgroundBellSource.Contains('autoDeletedTime: new Date().getTime() + NOTIFICATION_LIFETIME_MS') -and
    $backgroundBellSource.Contains('const NOTIFICATION_LIFETIME_MS: number = 24 * 60 * 60 * 1000') -and
    -not $backgroundBellSource.Contains('NotificationSubscriber') -and
    -not $backgroundBellSource.Contains('subscribeNotification')
) 'Background BEL expiration lost its bounded lifetime or introduced dismissal tracking'

$longTaskVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-long-task-notification-pc.ps1'
) -Raw
Assert-True (
    $longTaskVerifier.Contains("ValidateSet('shell', 'tmux', 'codex')") -and
    $longTaskVerifier.Contains('Temporary WSL sshd') -and
    $longTaskVerifier.Contains('codex exec --sandbox read-only') -and
    $longTaskVerifier.Contains("tmux -L '") -and
    $longTaskVerifier.Contains("printf '\a'") -and
    $longTaskVerifier.Contains('Background BEL notification published') -and
    $longTaskVerifier.Contains('Background BEL return applied') -and
    $longTaskVerifier.Contains('genericPayload') -and
    $longTaskVerifier.Contains('fport rm "tcp:$Port" "tcp:$Port"') -and
    $longTaskVerifier.Contains('reverse mapping remained after cleanup') -and
    $longTaskVerifier.Contains('reverse-port-removed') -and
    $longTaskVerifier.Contains('app-identity-unchanged') -and
    $longTaskVerifier.Contains('Resolve-LeanTTYRetainedCandidate') -and
    $longTaskVerifier.Contains('harness = [ordered]@{') -and
    $longTaskVerifier.Contains('attemptId = $attemptId') -and
    $longTaskVerifier.Contains('previousAttemptId = $PreviousAttemptId') -and
    $longTaskVerifier.Contains('Write-LeanTTYAtomicJson') -and
    $longTaskVerifier.Contains('contentRecorded = $false')
) 'Long-task notification scenario lacks real workloads, notification return, privacy, or cleanup oracles'
Assert-True (
    $longTaskVerifier.Contains('Restore-NotificationPermission') -and
    $longTaskVerifier.Contains('Assert-NotificationCleanup')
) 'Long-task notification cleanup must not toggle an already visible singleton window'

$agentCompatibilityVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-agent-compatibility-pc.ps1'
) -Raw
Assert-True (
    $agentCompatibilityVerifier.Contains('attemptId = $attemptId') -and
    $agentCompatibilityVerifier.Contains('previousAttemptId = $PreviousAttemptId') -and
    $agentCompatibilityVerifier.Contains('Write-AgentCompatibilityProgress') -and
    $agentCompatibilityVerifier.Contains('Write-LeanTTYAtomicJson') -and
    $agentCompatibilityVerifier.Contains('contentRecorded = $false')
) 'Agent compatibility groups lack atomic attempt checkpoints and content-free progress'

$backgroundBellPermissionVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-background-bell-permission-pc.ps1'
) -Raw
$backgroundBellPermissionVerifier += Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'notification-regression.ps1'
) -Raw
Assert-True (
    $backgroundBellPermissionVerifier.Contains('originalEnabled') -and
    $backgroundBellPermissionVerifier.Contains("minimizeBounds.Groups['y2']") -and
    $backgroundBellPermissionVerifier.Contains('notifications are disabled') -and
    $backgroundBellPermissionVerifier.Contains('disabledNotificationCardCount') -and
    $backgroundBellPermissionVerifier.Contains('permissionPromptObserved') -and
    $backgroundBellPermissionVerifier.Contains('Handle disabled background BEL attention') -and
    $backgroundBellPermissionVerifier.Contains("'Pane attention cleared: ' + [regex]::Escape(") -and
    $backgroundBellPermissionVerifier.Contains('enabledPublished') -and
    $backgroundBellPermissionVerifier.Contains('enabledReturned') -and
    $backgroundBellPermissionVerifier.Contains('restore-original') -and
    $backgroundBellPermissionVerifier.Contains('original-notification-setting-verified') -and
    -not $backgroundBellPermissionVerifier.Contains('bm clean') -and
    -not $backgroundBellPermissionVerifier.Contains('uninstall')
) 'Background BEL permission scenario lacks disabled, enabled, return, or restoration oracles'

$unexpectedRecoveryUninstallVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-unexpected-recovery-uninstall-pc.ps1'
) -Raw
Assert-True (
    $unexpectedRecoveryUninstallVerifier.Contains("@('uninstall', 'com.leantty.app')") -and
    -not $unexpectedRecoveryUninstallVerifier.Contains("@('uninstall', '-k'") -and
    $unexpectedRecoveryUninstallVerifier.Contains('Wait-WorkspaceState -TabCount 1 -PaneCount 1') -and
    $unexpectedRecoveryUninstallVerifier.Contains('-TabCount 2 -PaneCount 2') -and
    $unexpectedRecoveryUninstallVerifier.Contains(
        'Recovery run started: generation=1, unexpected=false') -and
    $unexpectedRecoveryUninstallVerifier.Contains('durableAssetStoreReadOrMutated = $false') -and
    $unexpectedRecoveryUninstallVerifier.Contains('exactCandidateReinstalled = $true')
) 'Unexpected-recovery uninstall scenario lost its fresh-install or durable-asset boundary'

. (Join-Path $PSScriptRoot 'input-order-evidence.ps1')
$traceLine = 'ACCEPTANCE_INPUT_ORDER 1234567;1;0;1;0,12,2,0,1,0,1,1,1,0,0,0'
$traceParsed = ConvertFrom-LeanTTYInputOrderEvidence -Logs $traceLine -Token '1234567'
Assert-True ($traceParsed.complete -and $traceParsed.rows.Count -eq 1 -and
    $traceParsed.rows[0][2] -eq 2 -and -not $traceParsed.contentEqualityObserved) 'Numeric trace parsing failed'
foreach ($invalidTrace in @('', ($traceLine + "`n" + $traceLine),
    $traceLine.Replace(';0;1;', ';0;2;'), $traceLine.Replace('0,12,2', '1,12,2'),
    $traceLine.Replace('0,12,2', '0,12,9'), $traceLine.Replace('0,12,2', '0,200001,2'),
    ($traceLine + 'private-sentinel'), $traceLine.Replace(';1;0;1;', ';1;0;17;'))) {
    Assert-Throws { ConvertFrom-LeanTTYInputOrderEvidence -Logs $invalidTrace -Token '1234567' } `
        'Malformed, missing, duplicate or unbounded input-order evidence was accepted'
}
$earlyTrace = ConvertFrom-LeanTTYInputOrderEvidence -Logs $traceLine.Replace(';1;0;1;', ';3;0;1;') -Token '1234567'
Assert-True (-not $earlyTrace.complete -and $earlyTrace.stopReason -eq 'mode-or-replay') 'Early trace end was promoted'
$otherTrace = $traceLine.Replace('1234567', '7654321') + "`n" + $traceLine
Assert-True ((ConvertFrom-LeanTTYInputOrderEvidence -Logs $otherTrace -Token '1234567').rows.Count -eq 1) `
    'Trace token isolation failed'

$attributionLine = 'ACCEPTANCE_INPUT_ORDER 1234567;1;0;1;0,1,2,0,1,0,1,31,31,0,0,1/1,200000,9,0,31,31,1,31,31,1,1,0'
$attributionParsed = ConvertFrom-LeanTTYInputAttributionEvidence -Logs $attributionLine -Token '1234567' -Mode 0
Assert-True ($attributionParsed.complete -and $attributionParsed.summary.exact -and
    $attributionParsed.rows.Count -eq 2 -and -not $attributionParsed.contentRecorded) 'Attribution evidence parser failed'
foreach ($invalidAttribution in @('', ($attributionLine + "`n" + $attributionLine),
    $attributionLine.Replace(';0;1;', ';0;2;'), $attributionLine.Replace(',9,0,31,31,1,', ',9,0,31,30,1,'),
    $attributionLine.Replace('1,200000,9', '1,600001,9'), ($attributionLine + 'private-sentinel'))) {
    Assert-Throws { ConvertFrom-LeanTTYInputAttributionEvidence -Logs $invalidAttribution -Token '1234567' -Mode 0 } `
        'Invalid attribution trace was accepted'
}
Assert-Throws { ConvertFrom-LeanTTYInputAttributionEvidence -Logs $attributionLine -Token '1234567' -Mode 1 } `
    'Different attribution mode was accepted'
Assert-True (-not (ConvertFrom-LeanTTYInputAttributionEvidence -Logs $attributionLine.Replace(';1;0;1;', ';2;0;1;') `
    -Token '1234567' -Mode 0).complete) 'Truncated attribution trace was promoted'

$observerLine = 'ACCEPTANCE_OBSERVER_FINAL 1234567;6;1;180;1;0'
Assert-True ((ConvertFrom-LeanTTYObserverEvidence -Logs $observerLine -Token '1234567' -Profile 6).exact) 'Observer final parser failed'
foreach ($invalidObserver in @('', ($observerLine + "`n" + $observerLine), $observerLine.Replace(';6;', ';5;'),
    $observerLine.Replace(';1;180;', ';0;180;'), $observerLine.Replace(';180;1;', ';179;1;'),
    $observerLine.Replace('1234567', '7654321'), ($observerLine + 'private-sentinel'))) {
    Assert-Throws { ConvertFrom-LeanTTYObserverEvidence -Logs $invalidObserver -Token '1234567' -Profile 6 } `
        'Invalid or stale observer final accepted'
}
$observerMissing = ConvertFrom-LeanTTYObserverEvidence -Logs $observerLine.Replace(';180;1;0', ';179;0;19') -Token '1234567' -Profile 6
Assert-True (-not $observerMissing.exact -and $observerMissing.firstMismatchIndex -eq 18) 'Observer mismatch hidden'
$syntheticNative = ConvertFrom-LeanTTYObserverEvidence -Logs 'ACCEPTANCE_OBSERVER_FINAL 1234567;8;1;30;0;31' -Token '1234567' -Profile 8
Assert-True ($syntheticNative.units -eq 30 -and -not $syntheticNative.exact) 'Synthetic missing native output was hidden'
$syntheticRows = [Collections.Generic.List[string]]::new()
for ($caseIndex = 0; $caseIndex -lt 50; $caseIndex++) {
    $caseId = $caseIndex % 5
    $outputUnits = if ($caseId -eq 1) { 0 } else { 1 }
    $downSeen = if ($caseId -lt 2) { 1 } else { 0 }
    $syntheticRows.Add("$caseIndex,$caseIndex,17,$caseId,$([Math]::Floor($caseIndex / 5)),1,1,$outputUnits,$outputUnits,$downSeen,0,1")
}
$syntheticRows.Add('50,50,9,8,40,30,0,40,0,0,0,0')
$syntheticLines = @(for ($part = 0; $part -lt 4; $part++) {
    'ACCEPTANCE_INPUT_ORDER 1234567;1;' + $part + ';4;' +
        (($syntheticRows | Select-Object -Skip ($part * 16) -First 16) -join '/')
}) -join "`n"
$syntheticEvidence = ConvertFrom-LeanTTYInputAttributionEvidence -Logs $syntheticLines -Token '1234567' -Mode 8
Assert-True ($syntheticEvidence.complete -and $syntheticEvidence.syntheticCases.Count -eq 50 -and
    $syntheticEvidence.summary.actualUnits -eq 30) 'Synthetic fixed-set evidence parser failed'
Assert-True ($syntheticEvidence.eventKinds.syntheticCase -eq 17 -and $syntheticEvidence.eventColumns[3] -eq 'caseId' -and
    $null -eq $syntheticEvidence.summary.textareaUnits) 'Synthetic schema mislabeled columns or invented final textarea measurement'
$syntheticCancelled = ConvertFrom-LeanTTYInputAttributionEvidence -Logs 'ACCEPTANCE_INPUT_ORDER 1234567;3;0;1;0,10,9,8,40,0,0,0,0,0,0,0' -Token '1234567' -Mode 8
Assert-True (-not $syntheticCancelled.complete -and $syntheticCancelled.syntheticCases.Count -eq 0) 'Cancelled synthetic run was promoted'
foreach ($invalidSynthetic in @($syntheticLines.Replace('50,50,9,8,40,30', '50,50,9,8,40,31'),
    $syntheticLines.Replace('0,0,17,0,0', '0,0,17,1,0'),
    $syntheticLines.Replace(',0,1/', ',1,1/'), ($syntheticLines + "`n" + $syntheticLines))) {
    Assert-Throws { ConvertFrom-LeanTTYInputAttributionEvidence -Logs $invalidSynthetic -Token '1234567' -Mode 8 } `
        'Malformed synthetic sequence, totals or duplicate evidence accepted'
}
$chainLine = 'ACCEPTANCE_INPUT_ORDER 1234567;1;0;1;0,1,15,1,0,0,0,0,0,0,0,1/1,2,16,1,1,0,1,1,1,1,0,1/2,3,6,1,0,0,0,0,0,1,0,1/3,4,12,0,0,0,0,180,0,1,180,1/4,200000,9,4,180,180,1,180,180,1,1,0'
$chainParsed = ConvertFrom-LeanTTYInputAttributionEvidence -Logs $chainLine -Token '1234567' -Mode 4
Assert-True ($chainParsed.complete -and $chainParsed.summary.exact -and $chainParsed.summary.expectedUnits -eq 180 -and
    $null -eq $chainParsed.summary.domIsLettersOnly -and $chainParsed.rows.Count -eq 5) 'Chain evidence parser failed'
foreach ($invalidChain in @($chainLine.Replace(',9,4,180,180,1,', ',9,4,31,31,1,'),
    $chainLine.Replace(';0;1;', ';0;257;'), $chainLine.Replace('2,3,6,1,0', '2,3,6,0,0'),
    $chainLine.Replace('1,2,16,1,1', '1,2,16,1,2'), $chainLine.Replace('1234567', '7654321'))) {
    Assert-Throws { ConvertFrom-LeanTTYInputAttributionEvidence -Logs $invalidChain -Token '1234567' -Mode 4 } `
        'Invalid chain evidence was accepted'
}
$chainMismatch = ConvertFrom-LeanTTYInputAttributionEvidence -Logs $chainLine.Replace(',9,4,180,180,1,', ',9,4,180,179,0,') -Token '1234567' -Mode 4
Assert-True ($chainMismatch.complete -and -not $chainMismatch.summary.exact) 'Missing input was hidden'

& {
    # Exercise the diagnostic owner with device boundaries replaced, not the parser.
    $diagnosticAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'diagnose-text-input-pc.ps1'), [ref]$null, [ref]$null)
    foreach ($name in @('Invoke-InputOrderDiagnostic', 'Get-SingleFocusedDiagnosticInputNode',
        'Get-TextInputMismatchIndex')) {
        $definition = $diagnosticAst.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        Assert-True ($null -ne $definition) "Input diagnostic owner missing: $name"
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $Scenario = 'input-attribution'; $hdc = 'unused'; $resolvedTarget = 'unused'; $appProcessId = '100'
    $EvidenceDirectory = Join-Path ([IO.Path]::GetTempPath()) ('leantty-input-owner-test-' + [Guid]::NewGuid().ToString('N'))
    function Wait-LeanTTYTerminalInputLayout { return @{} }
    function Get-LeanTTYTerminalInputNodes { return @{ attributes = @{ focused = 'true' } } }
    function Clear-LeanTTYAppLogs {}
    function Invoke-HdcChecked { param($Hdc, $Target, $Arguments, $Operation) $deviceActions.Add($Operation) }
    function Submit-LeanTTYDeviceCommand {
        param($Hdc, $Target, $ProcessId, $Command, $Stage, $MaxInputAttempts, $ObservationSink, $InputNodeProvider)
        Assert-True ($Command -cmatch '^__acceptance_input_attribution_[1578]_([1-9][0-9]{6})$' -and
            $MaxInputAttempts -eq 1) 'Diagnostic arming must remain single-shot'
        $probeState.token = $Matches[1]
        $ObservationSink.Add([ordered]@{ enterCount = 1 })
    }
    function Wait-LeanTTYAppLog {
        param($Hdc, $Target, $ProcessId, $Pattern, $TimeoutSeconds)
        if ($Pattern -ceq 'Tab added: ') { return 'Tab added: owned-input-tab title=Terminal' }
        if ($Pattern.StartsWith('Tab removed: ')) { return 'Tab removed: owned-input-tab' }
        if ($Pattern.StartsWith('ACCEPTANCE_OBSERVER_READY') -or $Pattern.EndsWith(';0;0;0;')) { return $Pattern }
        return $probeLogs.Replace('1234567', $probeState.token)
    }
    function Invoke-LeanTTYDeviceText {
        param($Hdc, $Target, $InputNode, $Text)
        $deliveredVectors.Add($Text)
        if ($loseTarget) {
            throw (New-LeanTTYTextInputFailure -Phase after -ExpectedNode $null -CurrentNodes @() `
                -Message '[harness] controlled owner loss')
        }
    }
    function Get-LastAcceptanceInputState { return $expectedVector }
    function Reset-LeanTTYDeviceCommandInput { $probeState.resets++ }
    foreach ($case in @(
        @{ mode = 1; loseTarget = $false }, @{ mode = 5; loseTarget = $false },
        @{ mode = 7; loseTarget = $false }, @{ mode = 8; loseTarget = $false },
        @{ mode = 1; loseTarget = $true }
    )) {
        $AttributionMode = $case.mode; $loseTarget = $case.loseTarget
        $probeState = @{ token = ''; resets = 0 }
        $deliveredVectors = [Collections.Generic.List[string]]::new()
        $deviceActions = [Collections.Generic.List[string]]::new()
        $expectedVector = if ($AttributionMode -eq 1) { '0123456789abcdefghijklmnopqrstu' }
            elseif ($AttributionMode -eq 8) { 'a' * 40 } else { 'ssh-keygen -R [127.0.0.1]:2223' * 6 }
        $probeLogs = switch ($AttributionMode) {
            1 { $attributionLine.Replace(',9,0,31,', ',9,1,31,') }
            5 { 'ACCEPTANCE_OBSERVER_FINAL 1234567;5;1;180;1;0' }
            7 { $chainLine + "`nACCEPTANCE_OBSERVER_FINAL 1234567;7;1;180;1;0`nACCEPTANCE_INPUT_CHAIN_NATIVE 1234567;1;180" }
            8 { $syntheticLines + "`nACCEPTANCE_OBSERVER_FINAL 1234567;8;1;30;0;31`nACCEPTANCE_INPUT_CHAIN_NATIVE 1234567;30;30" }
        }
        $result = Invoke-InputOrderDiagnostic
        $expectedDeliveries = if ($AttributionMode -eq 8) { 0 } else { 1 }
        Assert-True ($result.vectorAttempts -eq $expectedDeliveries -and
            $deliveredVectors.Count -eq $expectedDeliveries -and -not $result.vectorSubmitted -and
            $result.armingObservations.Count -eq 1) 'Diagnostic injected or submitted an unexpected vector'
        if ($expectedDeliveries -eq 1) {
            Assert-True ($deliveredVectors[0] -ceq $expectedVector) 'Diagnostic changed the public input vector'
        }
        if ($loseTarget) {
            Assert-True ($result.result -eq 'failed' -and $result.cleanup -eq 'failed' -and
                $result.textTargetFailure.phase -eq 'after' -and $probeState.resets -eq 0 -and
                $deviceActions.Count -eq 1 -and $result.trace.complete) (
                'Owner loss must retain available trace without further reset or close keys'
            )
        } else {
            Assert-True ($result.result -eq 'completed' -and $result.cleanup -eq 'passed' -and
                $probeState.resets -eq 1 -and $deviceActions.Count -eq 2) 'Diagnostic did not close its completed probe'
            if ($AttributionMode -eq 5) {
                Assert-True ($null -eq $result.trace -and $result.native.exact -and
                    -not $result.observationProfile.logsPolledDuringInjection -and
                    -not $result.observationProfile.zeroOverhead) 'Observer control invented trace or zero overhead'
            }
            if ($AttributionMode -eq 8) {
                Assert-True ($result.synthetic.mechanismReproduced -and -not $result.synthetic.deviceCauseProven) (
                    'Synthetic mechanism must not be promoted to natural device causality'
                )
            }
        }
    }
}

& {
    # Run the real performance submission and JSON reader, not a parallel validator.
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'verify-ssh-auth-pc.ps1'), [ref]$null, [ref]$null)
    foreach ($name in @('Invoke-AuthPerfSample', 'Get-AuthPerfRenderRecord')) {
        $definition = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true))
        Assert-True ($definition.Count -eq 1) "Missing or ambiguous performance owner: $name"
        Invoke-Expression $definition[0].Extent.Text
    }
    $state = @{ commands = [Collections.Generic.List[string]]::new(); failure = ''; waits = 0; logs = '' }
    function Submit-ConnectedInput { param($Text) $state.commands.Add($Text) }
    function Get-FixtureLogMatchCount { return 0 }
    function Wait-FixtureLogMatchCount {
        $state.waits++
        if (($state.failure -eq 'prepare' -and $state.waits -eq 1) -or
            ($state.failure -eq 'run' -and $state.waits -eq 2)) { throw 'controlled fixture timeout' }
    }
    function Clear-LeanTTYAppLogs {}
    function Wait-AuthLog { if ($state.failure -eq 'render') { throw 'controlled render timeout' } }
    function Get-LeanTTYAppLogs { return $state.logs }
    $valid = @{ caseId = 'fixture_01'; schemaVersion = 2; contentOrdered = $true
        visibleTailConfirmed = $true; mismatches = 0; completenessPercent = 100 }
    $state.logs = 'PERF render ' + ($valid | ConvertTo-Json -Compress)
    $record = Invoke-AuthPerfSample -CaseId fixture_01
    Assert-True ($record.commandAttempts -eq 1 -and $state.commands.Count -eq 2) (
        'Valid schema-2 evidence must prepare and run exactly once'
    )
    foreach ($case in @(
        @{ field = 'schemaVersion'; value = 1 },
        @{ field = 'contentOrdered'; value = $false },
        @{ field = 'visibleTailConfirmed'; value = $false },
        @{ field = 'mismatches'; value = 1 },
        @{ field = 'mismatches'; value = $null },
        @{ field = 'caseId'; value = 'another_case' }
    )) {
        $bad = $valid.Clone(); $bad[$case.field] = $case.value
        $state.logs = 'PERF render ' + ($bad | ConvertTo-Json -Compress)
        $state.commands.Clear(); $state.waits = 0
        Assert-Throws { Invoke-AuthPerfSample -CaseId fixture_01 } (
            "Headline completeness must not hide invalid evidence: $($case.field)"
        )
        Assert-True ($state.commands.Count -eq 2) 'Rejected evidence must not resubmit the stream'
    }
    foreach ($failure in @('prepare', 'run', 'render')) {
        $state.failure = $failure; $state.commands.Clear(); $state.waits = 0
        Assert-Throws { Invoke-AuthPerfSample -CaseId fixture_01 } 'Unknown outcomes must stop without retries'
        $expectedCommands = if ($failure -eq 'prepare') { 1 } else { 2 }
        Assert-True ($state.commands.Count -eq $expectedCommands) 'An uncertain stage dispatched more input'
    }
}

Write-Host 'Device regression helper tests passed.' -ForegroundColor Green
