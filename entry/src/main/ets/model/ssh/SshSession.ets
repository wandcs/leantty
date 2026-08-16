import { SshSessionState } from '../../common/types/TerminalTypes'

export { SshSessionState }

export class SshSession {
  private state: SshSessionState = SshSessionState.IDLE
  private displayHost: string = ''
  private hostname: string = ''
  private port: number = 22
  private username: string = ''
  private errorMessage: string = ''
  private exitCode: number = -1

  getState(): SshSessionState {
    return this.state
  }

  setState(state: SshSessionState): void {
    this.state = state
  }

  getDisplayHost(): string {
    return this.displayHost
  }

  setDisplayHost(host: string): void {
    this.displayHost = host
  }

  getHostname(): string {
    return this.hostname
  }

  setHostname(host: string): void {
    this.hostname = host
  }

  getPort(): number {
    return this.port
  }

  setPort(p: number): void {
    this.port = p
  }

  getUsername(): string {
    return this.username
  }

  setUsername(u: string): void {
    this.username = u
  }

  getErrorMessage(): string {
    return this.errorMessage
  }

  setErrorMessage(msg: string): void {
    this.errorMessage = msg
  }

  getExitCode(): number {
    return this.exitCode
  }

  setExitCode(code: number): void {
    this.exitCode = code
  }

  getDisplayTitle(): string {
    return this.getConnectionTitle()
  }

  getConnectionTitle(): string {
    let host: string = this.displayHost.length > 0 ? this.displayHost : this.hostname
    if (host.length === 0) {
      return 'ltty'
    }
    return this.username.length > 0 ? this.username + '@' + host : host
  }

  isConnected(): boolean {
    return this.state === SshSessionState.CONNECTED
  }

  isActive(): boolean {
    return this.state === SshSessionState.CONNECTING ||
      this.state === SshSessionState.HOST_VERIFICATION_REQUIRED ||
      this.state === SshSessionState.AUTHENTICATING ||
      this.state === SshSessionState.CONNECTED
  }

  reset(): void {
    this.state = SshSessionState.IDLE
    this.errorMessage = ''
    this.exitCode = -1
  }
}
