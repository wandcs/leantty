export enum SshErrorCode {
  Network = 1,
  Auth = 2,
  HostKey = 3,
  Channel = 4,
  Protocol = 5,
  Internal = 6,
  SessionClosed = 7
}

export const DEFAULT_SSH_CONNECT_TIMEOUT_MS: number = 15000
export const MAX_SSH_CONNECT_TIMEOUT_SECONDS: number = 300

export class SshError extends Error {
  code: SshErrorCode
  detail: string
  layer: string

  constructor(code: SshErrorCode, message: string, detail: string, layer: string) {
    super(message)
    this.code = code
    this.detail = detail
    this.layer = layer
  }
}

export class SshConnectOptions {
  host: string
  port: number
  username: string
  privateKeyPath: string
  privateKeyRequiresPassphrase: boolean
  jumpHost: string
  jumpPort: number
  jumpUsername: string
  jumpPrivateKeyPath: string
  jumpPrivateKeyRequiresPassphrase: boolean
  jumpConnectTimeoutMs: number
  knownHostsPath: string
  connectTimeoutMs: number

  constructor() {
    this.host = ''
    this.port = 22
    this.username = ''
    this.privateKeyPath = ''
    this.privateKeyRequiresPassphrase = false
    this.jumpHost = ''
    this.jumpPort = 22
    this.jumpUsername = ''
    this.jumpPrivateKeyPath = ''
    this.jumpPrivateKeyRequiresPassphrase = false
    this.jumpConnectTimeoutMs = DEFAULT_SSH_CONNECT_TIMEOUT_MS
    this.knownHostsPath = ''
    this.connectTimeoutMs = DEFAULT_SSH_CONNECT_TIMEOUT_MS
  }
}
