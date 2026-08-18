$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$authStatePath = Join-Path $repoRoot 'leantty_ssh\leantty-ssh-core\src\authentication.rs'
$rustPath = Join-Path $repoRoot 'leantty_ssh\src\lib.rs'
$sshClientPath = Join-Path $repoRoot 'entry\src\main\ets\model\ssh\SshClient.ets'
$viewModelPath = Join-Path $repoRoot 'entry\src\main\ets\viewmodel\SessionViewModel.ets'
$preferencesPath = Join-Path $repoRoot 'entry\src\main\ets\model\settings\UserPreferences.ets'

$authState = Get-Content -Raw -LiteralPath $authStatePath
$rust = Get-Content -Raw -LiteralPath $rustPath
$sshClient = Get-Content -Raw -LiteralPath $sshClientPath
$viewModel = Get-Content -Raw -LiteralPath $viewModelPath
$preferences = Get-Content -Raw -LiteralPath $preferencesPath

function Assert-Contains {
  param(
    [Parameter(Mandatory)] [string] $Source,
    [Parameter(Mandatory)] [string[]] $Markers,
    [Parameter(Mandatory)] [string] $Boundary
  )

  foreach ($marker in $Markers) {
    if (-not $Source.Contains($marker)) {
      throw "$Boundary marker was not found: $marker"
    }
  }
}

function Assert-Ordered {
  param(
    [Parameter(Mandatory)] [string] $Source,
    [Parameter(Mandatory)] [string[]] $Markers,
    [Parameter(Mandatory)] [string] $Boundary
  )

  $previousIndex = -1
  foreach ($marker in $Markers) {
    $index = $Source.IndexOf($marker, $previousIndex + 1)
    if ($index -lt 0) {
      throw "$Boundary marker was not found: $marker"
    }
    if ($index -le $previousIndex) {
      throw "$Boundary markers are out of order at: $marker"
    }
    $previousIndex = $index
  }
}

Assert-Contains -Source $authState -Boundary 'Authentication state machine' -Markers @(
  'pub enum AuthAction {'
  'RequestPrivateKeyPassphrase,'
  'RequestPassword,'
  'StartKeyboardInteractive,'
  'PresentChallenge(AuthChallenge),'
  'pub fn validate_responses('
  'AuthFailure::StaleChallenge'
  'AuthFailure::ResponseCountMismatch'
  'AuthFailure::ProtocolLimitExceeded'
)

Assert-Ordered -Source $rust -Boundary 'SSH connection authentication' -Markers @(
  'stage=kex_complete'
  'match run_authentication('
  'send_control(&control_callback, "CONNECTED")'
)

Assert-Contains -Source $rust -Boundary 'Rust authentication exchange' -Markers @(
  'AuthAction::RequestPrivateKeyPassphrase'
  'AuthAction::RequestPassword'
  'AuthAction::StartKeyboardInteractive'
  'AuthAction::PresentChallenge(challenge)'
  'wait_for_auth_command('
  'AUTH_RESPONSE_TIMEOUT'
  'wait_for_auth_exchange('
  'AUTH_EXCHANGE_TIMEOUT'
  'pub fn ssh_auth_password('
  'pub fn ssh_auth_private_key_passphrase('
  'pub fn ssh_auth_keyboard_interactive_responses('
  'pub fn ssh_verify_host_key('
  'is_current_auth_generation('
  'stale host-key generation'
)

Assert-Contains -Source $sshClient -Boundary 'ArkTS SSH authentication bridge' -Markers @(
  'SshClient.isCurrentAuthEvent('
  "event.kind === 'banner'"
  "event.kind === 'password'"
  "event.kind === 'private_key_passphrase'"
  "event.kind === 'challenge'"
  'sshNative.sshAuthPassword(this.sessionId, this.generation, this.pendingLayer, password)'
  'this.sessionId, this.generation, this.pendingLayer, passphrase'
  'this.sessionId, this.generation, this.pendingLayer, roundId, responses'
  'sshNative.sshVerifyHostKey(this.sessionId, this.generation, this.pendingLayer, accepted)'
  'this.pendingAuthChallenge = null'
)

Assert-Contains -Source $viewModel -Boundary 'Session authentication input' -Markers @(
  'private beginAuthChallenge(): void {'
  'private submitAuthChallengeResponse(): void {'
  'private submitCompletedAuthChallenge(): void {'
  'private clearAuthChallenge(): void {'
  'this.authResponseBuffer = '''''
  'this.authResponses[i] = '''''
  'responses[i] = '''''
  'this.sshClient.authKeyboardInteractiveResponses(roundId, responses)'
  'let actions: TerminalInputAction[] = TerminalInputParser.parse(data, false)'
  'this.commandBarVm.addToHistory(cmd)'
)

if ([regex]::Matches($viewModel, '\.addToHistory\(').Count -ne 1) {
  throw 'Only submitted local commands may enter command history.'
}

Assert-Contains -Source $preferences -Boundary 'Local preferences projection' -Markers @(
  "const TERMINAL_FONT_SIZE_KEY: string = 'terminal_font_size'"
  "const TERMINAL_TRANSPARENCY_MODE_KEY: string = 'terminal_transparency_mode'"
  'UserPreferences.store.putSync(TERMINAL_FONT_SIZE_KEY, fontSize)'
  'UserPreferences.store.putSync(TERMINAL_TRANSPARENCY_MODE_KEY, value)'
)

if ([regex]::Matches($preferences, '\.putSync\(').Count -ne 2 -or
    $preferences -match '(?i)password|passphrase|token|authresponse|challenge') {
  throw 'Local Preferences must remain limited to approved non-secret terminal display settings.'
}

if ($rust.Contains('send_control(&control_callback, "PASSWORD_PROMPT")') -or
    $rust.Contains('stage=key_rejected fallback=password') -or
    $viewModel.Contains('private privateKeyAttempted: boolean = false')) {
  throw 'Obsolete prompt-string or UI-owned authentication fallback state is present.'
}

Write-Output 'SSH structured authentication flow regression checks passed.'
