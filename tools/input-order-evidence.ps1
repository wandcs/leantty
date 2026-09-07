# Numeric-only diagnostic wire format, emitted after the observation window closes.
function ConvertFrom-LeanTTYObserverEvidence {
    param([string]$Logs, [ValidatePattern('^[1-9][0-9]{6}$')][string]$Token,
        [ValidateRange(5, 8)][int]$Profile)
    $expectedUnits = if ($Profile -eq 8) { 40 } else { 180 }
    $lines = @([regex]::Matches($Logs, '(?m)ACCEPTANCE_OBSERVER_FINAL ' + $Token + ';([^\r\n]+)'))
    if ($lines.Count -ne 1 -or $lines[0].Groups[1].Value.Trim() -cnotmatch '^([5-8]);([01]);([0-9]{1,4});([01]);([0-9]{1,4})$') {
        throw '[harness] Missing or malformed observer final summary'
    }
    $values = @($lines[0].Groups[1].Value.Trim().Split(';') | ForEach-Object { [int]$_ })
    if ($values[0] -ne $Profile -or $values[1] -ne 1 -or
        ($values[3] -eq 1 -and ($values[2] -ne $expectedUnits -or $values[4] -ne 0)) -or
        ($values[3] -eq 0 -and ($values[4] -eq 0 -or $values[4] -gt ($expectedUnits + 1)))) {
        throw '[harness] Invalid observer owner or equality summary'
    }
    return [ordered]@{ units = $values[2]; exact = $values[3] -eq 1;
        firstMismatchIndex = $values[4] - 1; observation = 'single-post-window-owner-buffer-summary' }
}

function ConvertFrom-LeanTTYInputAttributionEvidence {
    param([string]$Logs, [ValidatePattern('^[1-9][0-9]{6}$')][string]$Token,
        [ValidateSet(0, 1, 2, 3, 4, 8)][int]$Mode)
    $chain = $Mode -eq 4
    $synthetic = $Mode -eq 8
    $maxChunks = if ($chain) { 256 } else { 16 }
    $maxRows = if ($chain) { 4096 } else { 256 }
    $maxKind = if ($synthetic) { 17 } elseif ($chain) { 16 } else { 11 }
    $expectedUnits = if ($synthetic) { 40 } elseif ($chain) { 180 } else { 31 }
    $parts = @{}
    $reason = -1
    $count = 0
    foreach ($entry in [regex]::Matches($Logs, '(?m)ACCEPTANCE_INPUT_ORDER ([^\r\n]+)')) {
        $payload = $entry.Groups[1].Value.Trim()
        if (-not $payload.StartsWith($Token + ';')) { continue }
        if ($payload -ceq ($Token + ';0;0;0;')) { continue }
        if ($payload.Length -gt 4096 -or $payload -cnotmatch '^[0-9;,/]+$') {
            throw '[harness] Invalid attribution payload'
        }
        $fields = $payload.Split(';')
        if ($fields.Count -ne 5) { throw '[harness] Invalid attribution header' }
        $part = [int]$fields[2]; $total = [int]$fields[3]; $currentReason = [int]$fields[1]
        if ($currentReason -notin 1..4 -or $total -lt 1 -or $total -gt $maxChunks -or $part -lt 0 -or $part -ge $total -or
            $parts.ContainsKey($part) -or ($reason -ne -1 -and ($reason -ne $currentReason -or $count -ne $total))) {
            throw '[harness] Inconsistent attribution chunks'
        }
        $reason = $currentReason; $count = $total; $parts[$part] = $fields[4]
    }
    if ($count -eq 0 -or $parts.Count -ne $count) { throw '[harness] Missing attribution chunks' }
    $rows = [Collections.Generic.List[object]]::new()
    $previousTime = 0
    for ($part = 0; $part -lt $count; $part++) {
        $partRows = @($parts[$part].Split('/'))
        if ($partRows.Count -gt 16 -or ($part -lt $count - 1 -and $partRows.Count -ne 16)) {
            throw '[harness] Invalid attribution chunk size'
        }
        foreach ($row in $partRows) {
            if ($row -cnotmatch '^[0-9]{1,6}(?:,[0-9]{1,6}){11}$') { throw '[harness] Invalid attribution row' }
            $values = @($row.Split(',') | ForEach-Object { [int]$_ })
            if ($values[0] -ne $rows.Count -or $values[1] -lt $previousTime -or $values[1] -gt 600000 -or
                $values[2] -lt 1 -or $values[2] -gt $maxKind) { throw '[harness] Invalid attribution sequence' }
            if ($chain -and (($values[2] -in 6, 7, 8 -and $values[3] -lt 1) -or
                ($values[2] -eq 15 -and $values[3] -lt 1) -or
                ($values[2] -eq 16 -and $values[4] -notin 0..1))) {
                throw '[harness] Invalid chain correlation metadata'
            }
            $rows.Add($values); $previousTime = $values[1]
        }
    }
    if ($rows.Count -gt $maxRows) { throw '[harness] Attribution row limit exceeded' }
    $summaries = @($rows | Where-Object { $_[2] -eq 9 })
    if ($summaries.Count -ne 1 -or $rows[-1][2] -ne 9 -or $rows[-1][3] -ne $Mode -or $rows[-1][4] -ne $expectedUnits) {
        throw '[harness] Missing or inconsistent attribution summary'
    }
    $summary = $rows[-1]
    $syntheticCases = @()
    if ($synthetic) {
        $syntheticUnits = 0
        $syntheticDomUnits = 0
        $caseNames = @('xterm-normal', 'xterm-delayed-input', 'xterm-keyup-before-input', 'xterm-input-only', 'textarea-delayed-input')
        for ($i = 0; $i -lt $rows.Count - 1; $i++) {
            $r = $rows[$i]
            if ($r[2] -ne 17 -or $r[3] -ne ($i % 5) -or $r[4] -ne [Math]::Floor($i / 5) -or
                $r[6] -notin 0..1 -or $r[8] -notin 0..1 -or $r[9] -notin 0..1 -or $r[10] -ne 0 -or $r[11] -ne 1 -or
                ($r[6] -eq 1 -and $r[5] -ne 1) -or ($r[8] -eq 1 -and $r[7] -ne 1)) {
                throw '[harness] Invalid synthetic case order or contract'
            }
            $syntheticCases += [ordered]@{ name = $caseNames[$r[3]]; repeat = $r[4];
                domUnits = $r[5]; domExact = $r[6] -eq 1; outputUnits = $r[7]; outputExact = $r[8] -eq 1;
                keyDownSeenBeforeInput = $r[9] -eq 1; trustedEvents = $r[10] }
            if ($r[3] -ne 4) { $syntheticUnits += $r[7]; $syntheticDomUnits += $r[5] }
        }
        if ($reason -eq 1 -and $syntheticCases.Count -ne 50) { throw '[harness] Synthetic case set incomplete' }
        if ($summary[5] -ne $syntheticUnits -or $summary[7] -ne $syntheticDomUnits) {
            throw '[harness] Synthetic case totals disagree with summary'
        }
    }
    if ($summary[6] -notin 0..1 -or $summary[9] -notin 0..1 -or $summary[10] -notin 0..1 -or
        $summary[11] -notin 0..1 -or ($summary[6] -eq 1 -and $summary[5] -ne $expectedUnits)) {
        throw '[harness] Invalid attribution equality summary'
    }
    return [ordered]@{ complete = $reason -eq 1 -and $rows.Count -gt 1; stopReason = $reason;
        chunks = $count; rows = @($rows); contentRecorded = $false;
        syntheticCases = $syntheticCases;
        eventColumns = $(if ($synthetic) { @('sequence','elapsedTenthsMs','kind','caseId','repeat',
            'domUnits','domExact','outputUnits','outputExact','keyDownSeenBeforeInput','trustedEvents','valid') }
            else { @('sequence','elapsedTenthsMs','kind','keyCategory','composed','isComposing',
            'inputTypeCategory','dataUnits','textareaUnits','keyDownSeen','onDataUnits','onDataExactPrefix') });
        eventKinds = $(if ($synthetic) { [ordered]@{ summary=9; syntheticCase=17 } } else { [ordered]@{ beforeinput=1; input=2; keydown=3; keyup=4; onData=5;
            diffScheduled=6; diffCallbackStart=7; diffCallbackEnd=8; summary=9;
            compositionstart=10; compositionend=11; bridgePostAttempt=12; bridgePostCompleted=13;
            bridgePortMissing=14; printableKeyIndex=15; inputKeyMatch=16 } });
        chainColumnOverrides = $(if ($chain) { [ordered]@{
            diff = [ordered]@{ column3 = 'diffId'; column4 = 'textareaUnitsWhenScheduled' };
            printableKeyIndex = [ordered]@{ column3 = 'oneBasedKeyIndex'; column4 = 'unused' };
            inputKeyMatch = [ordered]@{ column3 = 'oneBasedKeyIndex'; column4 = 'matchesExpectedCharacter' }
        } } else { $null });
        summary = [ordered]@{ mode = $Mode; expectedUnits = $expectedUnits; actualUnits = $summary[5];
            exact = $summary[6] -eq 1; domInputUnits = $summary[7];
            textareaUnits = $(if ($synthetic) { $null } else { $summary[8] });
            textareaExact = $(if ($synthetic) { $null } else { $summary[9] -eq 1 });
            domIsFullVector = $(if ($synthetic) { $null } else { $summary[10] -eq 1 });
            domIsLettersOnly = $(if ($chain -or $synthetic) { $null } else { $summary[11] -eq 1 }) } }
}

function ConvertFrom-LeanTTYInputOrderEvidence {
    param([string]$Logs, [ValidatePattern('^[1-9][0-9]{6}$')][string]$Token)
    $parts = @{}
    $reason = -1
    $chunkCount = 0
    foreach ($entry in [regex]::Matches($Logs, '(?m)ACCEPTANCE_INPUT_ORDER ([^\r\n]+)')) {
        $payload = $entry.Groups[1].Value.Trim()
        if (-not $payload.StartsWith($Token + ';')) { continue }
        if ($payload.Length -gt 4096 -or $payload -cnotmatch '^[0-9;,/]+$') {
            throw '[harness] Invalid numeric input-order payload'
        }
        $fields = $payload.Split(';')
        if ($fields.Count -ne 5) { throw '[harness] Invalid input-order header' }
        $currentReason = [int]$fields[1]
        $part = [int]$fields[2]
        $total = [int]$fields[3]
        if ($currentReason -eq 0 -and $part -eq 0 -and $total -eq 0 -and $fields[4] -eq '') { continue }
        if ($currentReason -lt 1 -or $currentReason -gt 4 -or $total -lt 1 -or $total -gt 16 -or
            $part -lt 0 -or $part -ge $total -or $parts.ContainsKey($part) -or
            ($reason -ne -1 -and ($reason -ne $currentReason -or $chunkCount -ne $total))) {
            throw '[harness] Inconsistent or duplicate input-order chunk'
        }
        $reason = $currentReason
        $chunkCount = $total
        $parts[$part] = $fields[4]
    }
    if ($chunkCount -eq 0 -or $parts.Count -ne $chunkCount) {
        throw '[harness] Missing input-order report chunks'
    }
    $rows = [Collections.Generic.List[object]]::new()
    $previousTime = 0
    for ($part = 0; $part -lt $chunkCount; $part++) {
        $partRows = if ($parts[$part] -eq '') { @() } else { @($parts[$part].Split('/')) }
        if ($partRows.Count -gt 16 -or ($part -lt $chunkCount - 1 -and $partRows.Count -ne 16)) {
            throw '[harness] Invalid input-order chunk size'
        }
        foreach ($row in $partRows) {
            if ($row -cnotmatch '^[0-9]{1,6}(?:,[0-9]{1,6}){11}$') { throw '[harness] Invalid input-order row' }
            $values = @($row.Split(',') | ForEach-Object { [int]$_ })
            if ($values[0] -ne $rows.Count -or $values[1] -lt $previousTime -or $values[1] -gt 200000 -or
                $values[2] -lt 1 -or $values[2] -gt 5 -or $values[3] -gt 2 -or
                $values[4] -gt 1 -or $values[5] -gt 1 -or $values[6] -gt 2) {
                throw '[harness] Invalid input-order sequence or enum'
            }
            $rows.Add($values)
            $previousTime = $values[1]
        }
    }
    return [ordered]@{ complete = $reason -eq 1 -and $rows.Count -gt 0;
        stopReason = @('ready', 'deadline', 'capacity', 'mode-or-replay', 'pagehide')[$reason];
        chunks = $chunkCount; rows = @($rows); contentEqualityObserved = $false;
        columns = @('sequence', 'elapsedTenthsMs', 'kind', 'keyCategory', 'composed', 'isComposing',
            'inputTypeCategory', 'dataUnits', 'textareaUnits', 'printableUnits', 'deleteUnits', 'otherUnits') }
}
