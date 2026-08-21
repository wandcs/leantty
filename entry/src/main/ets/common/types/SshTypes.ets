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
export const DEFAULT_SSH_SERVER_ALIVE_INTERVAL_SECONDS: number = 30
export const DEFAULT_SSH_SERVER_ALIVE_COUNT_MAX: number = 3
export const MAX_SSH_SERVER_ALIVE_INTERVAL_SECONDS: number = 3600
export const MAX_SSH_SERVER_ALIVE_COUNT_MAX: number = 100

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
  jumpServerAliveIntervalSeconds: number
  jumpServerAliveCountMax: number
  knownHostsPath: string
  connectTimeoutMs: number
  serverAliveIntervalSeconds: number
  serverAliveCountMax: number
  verbose: boolean

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
    this.jumpServerAliveIntervalSeconds = DEFAULT_SSH_SERVER_ALIVE_INTERVAL_SECONDS
    this.jumpServerAliveCountMax = DEFAULT_SSH_SERVER_ALIVE_COUNT_MAX
    this.knownHostsPath = ''
    this.connectTimeoutMs = DEFAULT_SSH_CONNECT_TIMEOUT_MS
    this.serverAliveIntervalSeconds = DEFAULT_SSH_SERVER_ALIVE_INTERVAL_SECONDS
    this.serverAliveCountMax = DEFAULT_SSH_SERVER_ALIVE_COUNT_MAX
    this.verbose = false
  }
}
