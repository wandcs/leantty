export interface AuthPromptEvent {
  text: string
  echo: boolean
}
export interface AuthEvent {
  kind: string
  layer: string
  sessionId: string
  generation: number
  roundId: number
  text: string
  name: string
  instructions: string
  prompts: AuthPromptEvent[]
}
export interface TransportEvent {
  kind: string
  data: Uint8Array
  result: string
}
export interface FileTransferEvent {
  kind: string
  transferId: string
  paneId: string
  generation: number
  transferredBytes: string
  totalBytes: string
  code: string
  detail: string
}
export declare function sshConnect(
  host: string, port: number, user: string,
  privateKeyPath: string, privateKeyRequiresPassphrase: boolean,
  jumpHost: string, jumpPort: number, jumpUser: string,
  jumpPrivateKeyPath: string, jumpPrivateKeyRequiresPassphrase: boolean,
  jumpConnectTimeoutMs: number,
  jumpServerAliveIntervalSeconds: number, jumpServerAliveCountMax: number,
  knownHostsPath: string, connectTimeoutMs: number,
  serverAliveIntervalSeconds: number, serverAliveCountMax: number, generation: number,
  onTransport: (event: TransportEvent) => void,
  onControl: (event: string) => void,
  onAuth: (event: AuthEvent) => void
): string
export declare function sshAuthPassword(
  sessionId: string, generation: number, layer: string, password: string
): void
export declare function sshAuthPrivateKeyPassphrase(
  sessionId: string, generation: number, layer: string, passphrase: string
): void
export declare function sshAuthKeyboardInteractiveResponses(
  sessionId: string, generation: number, layer: string, roundId: number, responses: string[]
): void
export declare function sshVerifyHostKey(
  sessionId: string,
  generation: number,
  layer: string,
  accepted: boolean
): void
export declare function sshWrite(sessionId: string, data: string): void
export declare function sshResize(sessionId: string, cols: number, rows: number): void
export declare function sshSetOutputPaused(sessionId: string, paused: boolean): void
export declare function sshDisconnect(sessionId: string): void
export declare function sshStartFileTransfer(
  direction: string, host: string, port: number, user: string,
  privateKeyPath: string, privateKeyRequiresPassphrase: boolean,
  knownHostsPath: string, connectTimeoutMs: number,
  serverAliveIntervalSeconds: number, serverAliveCountMax: number, generation: number,
  paneId: string, remotePath: string, localPath: string, localDescriptor: number,
  onControl: (event: string) => void,
  onAuth: (event: AuthEvent) => void,
  onTransfer: (event: FileTransferEvent) => void
): string
export declare function sshGenerateKeyPair(algorithm: string, passphrase: string, outputDir: string, fileName: string, comment: string): Promise<string>
export declare function sshChangePrivateKeyPassphrase(keyPath: string, oldPassphrase: string, newPassphrase: string): void
export declare function sshExportKeyPair(privatePath: string, publicPath: string, outputDir: string, fileName: string): void
export declare function sshReadPublicKey(keyPath: string): string
export declare function sshInspectPrivateKey(keyPath: string): string
export declare function sshProtectPrivateKey(keyPath: string): void
export interface KnownHostsQueryResult {
  output: string
  found: number
}
export declare function sshFindKnownHostEntries(
  content: string, host: string, port: number
): KnownHostsQueryResult
export interface KnownHostsRemovalResult {
  content: string
  removed: number
}
export declare function sshRemoveKnownHostEntries(
  content: string, host: string, port: number
): KnownHostsRemovalResult
