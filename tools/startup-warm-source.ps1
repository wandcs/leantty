<#
.SYNOPSIS
  Temporarily inject warm-start paint markers into a diagnostic build.
.DESCRIPTION
  The probe reuses the production focus, terminal input, bridge echo, and xterm
  render paths. It only emits T4 after the foreground focus has caused a paint,
  and T5 after the same ASCII byte returns through the local command path and
  is painted. The one touched source file is restored byte-for-byte.
#>

. (Join-Path $PSScriptRoot 'acceptance-source.ps1')

function Add-LeanTTYStartupWarmSource {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $terminalHtml = Join-Path $RepoRoot 'entry\src\main\resources\rawfile\terminal.html'
    $text = [IO.File]::ReadAllText($terminalHtml)

    $text = Set-LeanTTYAcceptanceSourceText $text `
        '    var perfPaintFrameScheduled = false;' `
        ("    var perfPaintFrameScheduled = false;`n" +
            "    var startupWarmArmed = false;`n" +
            "    var startupWarmPromptPainted = false;`n" +
            "    var startupWarmAwaitingEcho = false;`n" +
            "    var startupWarmPaintPhase = '';")

    $reportAnchor = @'
    function acknowledgeBellAttention() {
'@
    $reportReplacement = @'
    function scheduleStartupWarmPaint(phase) {
      if (!term || startupWarmPaintPhase.length > 0) return;
      startupWarmPaintPhase = phase;
      term.refresh(0, term.rows - 1);
    }

    function reportStartupWarmPaint() {
      if (startupWarmPaintPhase.length === 0) return;
      var phase = startupWarmPaintPhase;
      startupWarmPaintPhase = '';
      if (phase === 'T4') {
        startupWarmPromptPainted = true;
      }
      sendBridgeControl('perfRender', 'STARTUP_WARM phase=' + phase);
    }

    function acknowledgeBellAttention() {
'@
    $text = Set-LeanTTYAcceptanceSourceText $text $reportAnchor $reportReplacement

    $focusAnchor = @'
            case 'focus':
              if (message.channel !== BRIDGE_CONTROL) break;
              bellAttentionGate.rearmDelivery();
              if (term && !isSearchOpen()) { term.focus(); }
              break;
'@
    $focusReplacement = @'
            case 'focus':
              if (message.channel !== BRIDGE_CONTROL) break;
              bellAttentionGate.rearmDelivery();
              if (term && !isSearchOpen()) { term.focus(); }
              startupWarmArmed = true;
              startupWarmPromptPainted = false;
              startupWarmAwaitingEcho = false;
              requestAnimationFrame(function() {
                requestAnimationFrame(function() {
                  if (startupWarmArmed) scheduleStartupWarmPaint('T4');
                });
              });
              break;
'@
    $text = Set-LeanTTYAcceptanceSourceText $text $focusAnchor $focusReplacement

    $dataAnchor = @'
      term.onData(function(data) {
        if (!restoringSnapshot) {
          sendBridgeData('terminal', data);
        }
      });
'@
    $dataReplacement = @'
      term.onData(function(data) {
        if (!restoringSnapshot) {
          if (data === 'a' && startupWarmArmed && startupWarmPromptPainted) {
            startupWarmAwaitingEcho = true;
          }
          sendBridgeData('terminal', data);
        }
      });
'@
    $text = Set-LeanTTYAcceptanceSourceText $text $dataAnchor $dataReplacement

    $renderAnchor = @'
      term.onRender(function() {
        reportPerfAfterPaint();
'@
    $renderReplacement = @'
      term.onRender(function() {
        reportStartupWarmPaint();
        reportPerfAfterPaint();
'@
    $text = Set-LeanTTYAcceptanceSourceText $text $renderAnchor $renderReplacement

    $writeAnchor = @'
      term.write(terminalBytes, function() {
        sendBridgeControl('writeAck',
'@
    $writeReplacement = @'
      term.write(terminalBytes, function() {
        if (startupWarmAwaitingEcho && terminalBytes.indexOf(97) >= 0) {
          startupWarmAwaitingEcho = false;
          startupWarmArmed = false;
          scheduleStartupWarmPaint('T5');
        }
        sendBridgeControl('writeAck',
'@
    $text = Set-LeanTTYAcceptanceSourceText $text $writeAnchor $writeReplacement

    [IO.File]::WriteAllText($terminalHtml, $text)
    return $terminalHtml
}

function Invoke-WithLeanTTYStartupWarmSource {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    $terminalHtml = Join-Path $RepoRoot 'entry\src\main\resources\rawfile\terminal.html'
    $backup = [IO.File]::ReadAllBytes($terminalHtml)
    try {
        Add-LeanTTYStartupWarmSource -RepoRoot $RepoRoot | Out-Null
        & $Action
    } finally {
        Restore-LeanTTYAcceptanceSourceFile -Path $terminalHtml -Bytes $backup
    }
}
