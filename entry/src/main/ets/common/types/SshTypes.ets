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

export class SshConnectionSpec {
  host: string = ''
  displayHost: string = ''
  port: number = 22
  username: string = ''
  identityFile: string = ''
  jumpHost: string = ''
  jumpDisplayHost: string = ''
  jumpPort: number = 22
  jumpUsername: string = ''
  jumpIdentityFile: string = ''
  jumpConnectTimeoutMs: number = DEFAULT_SSH_CONNECT_TIMEOUT_MS
  jumpServerAliveIntervalSeconds: number = DEFAULT_SSH_SERVER_ALIVE_INTERVAL_SECONDS
  jumpServerAliveCountMax: number = DEFAULT_SSH_SERVER_ALIVE_COUNT_MAX
  connectTimeoutMs: number = DEFAULT_SSH_CONNECT_TIMEOUT_MS
  serverAliveIntervalSeconds: number = DEFAULT_SSH_SERVER_ALIVE_INTERVAL_SECONDS
  serverAliveCountMax: number = DEFAULT_SSH_SERVER_ALIVE_COUNT_MAX
  verbose: boolean = false

  copy(): SshConnectionSpec {
    let copied: SshConnectionSpec = new SshConnectionSpec()
    copied.host = this.host
    copied.displayHost = this.displayHost
    copied.port = this.port
    copied.username = this.username
    copied.identityFile = this.identityFile
    copied.jumpHost = this.jumpHost
    copied.jumpDisplayHost = this.jumpDisplayHost
    copied.jumpPort = this.jumpPort
    copied.jumpUsername = this.jumpUsername
    copied.jumpIdentityFile = this.jumpIdentityFile
    copied.jumpConnectTimeoutMs = this.jumpConnectTimeoutMs
    copied.jumpServerAliveIntervalSeconds = this.jumpServerAliveIntervalSeconds
    copied.jumpServerAliveCountMax = this.jumpServerAliveCountMax
    copied.connectTimeoutMs = this.connectTimeoutMs
    copied.serverAliveIntervalSeconds = this.serverAliveIntervalSeconds
    copied.serverAliveCountMax = this.serverAliveCountMax
    copied.verbose = this.verbose
    return copied
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

  static fromConnectionSpec(spec: SshConnectionSpec, knownHostsPath: string): SshConnectOptions {
    let options: SshConnectOptions = new SshConnectOptions()
    options.host = spec.host
    options.port = spec.port
    options.username = spec.username
    options.jumpHost = spec.jumpHost
    options.jumpPort = spec.jumpPort
    options.jumpUsername = spec.jumpUsername
    options.jumpConnectTimeoutMs = spec.jumpConnectTimeoutMs
    options.jumpServerAliveIntervalSeconds = spec.jumpServerAliveIntervalSeconds
    options.jumpServerAliveCountMax = spec.jumpServerAliveCountMax
    options.knownHostsPath = knownHostsPath
    options.connectTimeoutMs = spec.connectTimeoutMs
    options.serverAliveIntervalSeconds = spec.serverAliveIntervalSeconds
    options.serverAliveCountMax = spec.serverAliveCountMax
    options.verbose = spec.verbose
    return options
  }
}
