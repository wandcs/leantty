$ErrorActionPreference = 'Stop'
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'verify-host-identity-pc.ps1'), [ref]$null, [ref]$null
)
$blocks = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Clauses[0].Item1.Extent.Text -eq '$keyCreated'
}, $true))
if ($blocks.Count -ne 1) { throw 'Owned-key cleanup boundary is ambiguous' }
$cleanup = [scriptblock]::Create($blocks[0].Extent.Text)
& {
    function Test-HostIdentityDefaultKeyFilesPresent {
        if ($script:inspectFails) { throw 'inspection unavailable' }
        $script:inspections++
        return $script:present
    }
    function Test-LeanTTYDeviceKeyFilesPresent { Test-HostIdentityDefaultKeyFilesPresent }
    function Submit-HostIdentityCommand { $script:deletes++ }
    function Invoke-LeanTTYDialogButton {}
    function Wait-HostIdentityLog {
        if ($script:deleteFails) { throw 'delete rejected' }
        if (-not $script:remains) { $script:present = $false }
    }
    foreach ($standard in @($true, $false)) {
        foreach ($case in @('absent', 'present', 'partial', 'unreadable', 'delete-fails', 'remains')) {
            $DefaultEcdsa = $standard
            $keyCreated = $true
            $keyName = 'id_ecdsa'
            $EvidenceDirectory = $PSScriptRoot
            $cleanupFailures = [Collections.Generic.List[string]]::new()
            $script:keyAbsenceAudited = $false
            $script:inspections = 0
            $script:deletes = 0
            $script:present = $case -ne 'absent'
            $script:inspectFails = $case -eq 'unreadable'
            $script:deleteFails = $case -eq 'delete-fails'
            $script:remains = $case -eq 'remains'
            . $cleanup
            $expectedFailure = $case -in @('unreadable', 'delete-fails', 'remains')
            if (($cleanupFailures.Count -gt 0) -ne $expectedFailure) {
                throw "Cleanup misclassified $standard/$case"
            }
            if (-not $expectedFailure -and ($keyCreated -or $script:inspections -ne 2)) {
                throw "Cleanup failed to audit both boundaries for $standard/$case"
            }
            if ($case -in @('absent', 'unreadable') -and $script:deletes -ne 0) {
                throw 'Cleanup attempted deletion without an observed owned file'
            }
            if ($case -in @('present', 'partial') -and $script:deletes -ne 1) {
                throw 'Cleanup skipped the product deletion of a present/partial key'
            }
        }
    }
}
Write-Host 'Host Identity cleanup passed: 12 absence/partial/failure cases against the real cleanup block.'
