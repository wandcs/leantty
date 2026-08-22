$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$rustPath = Join-Path $repoRoot 'leantty_ssh\src\lib.rs'
$typingPath = Join-Path $repoRoot 'entry\src\main\cpp\types\libleantty_ssh\index.d.ts'
$clientPath = Join-Path $repoRoot 'entry\src\main\ets\model\ssh\SshClient.ets'
$transferPath = Join-Path $repoRoot 'entry\src\main\ets\model\transfer\FileTransferClient.ets'

$rust = Get-Content -Raw -LiteralPath $rustPath
$typing = Get-Content -Raw -LiteralPath $typingPath
$client = Get-Content -Raw -LiteralPath $clientPath
$transfer = Get-Content -Raw -LiteralPath $transferPath

if (-not $rust.Contains('type JsTransportCallback =') -or
    $rust.Contains('type JsDataCallback =') -or
    $rust.Contains('close_callback: JsCallback')) {
    throw 'Rust SSH data and close still use separate N-API callback types'
}
if (-not $typing.Contains('export interface TransportEvent') -or
    -not $typing.Contains('onTransport: (event: TransportEvent) => void') -or
    -not $typing.Contains('exitCode: number') -or
    -not $typing.Contains('code: string') -or
    -not $typing.Contains('detail: string') -or
    $typing.Contains('onData: (data: Uint8Array) => void') -or
    $typing.Contains('onClose: (exitCode: string) => void')) {
    throw 'N-API typing does not expose one structured SSH transport callback'
}
if (-not $client.Contains('handleNativeTransportEvent(event)') -or
    -not $client.Contains("event.kind === 'data'") -or
    -not $client.Contains("event.kind === 'close'") -or
    $client.Contains("event.result.startsWith('ERROR:')")) {
    throw 'ArkTS SSH client does not route the structured transport event'
}
if (-not $rust.Contains('pub struct ControlEvent') -or
    -not $typing.Contains('export interface ControlEvent') -or
    -not $typing.Contains('onControl: (event: ControlEvent) => void') -or
    -not $client.Contains('handleNativeControlEvent(event)') -or
    -not $transfer.Contains('handleNativeControlEvent(event)') -or
    $client.Contains('handleRustEvent(event)') -or
    $transfer.Contains('handleRustEvent(event)')) {
    throw 'Interactive SSH and file transfer must share one structured control callback'
}

Write-Host 'SSH transport contract check passed.' -ForegroundColor Green
