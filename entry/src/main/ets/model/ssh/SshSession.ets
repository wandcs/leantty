import { SshSessionState } from '../../common/types/TerminalTypes'

export { SshSessionState }

export class SshSession {
  private state: SshSessionState = SshSessionState.IDLE
  private displayHost: string = ''
  private hostname: string = ''
  private port: number = 22
  private username: string = ''
  private identityFile: string = ''
  private jumpDisplayHost: string = ''
  private jumpHostname: string = ''
  private jumpPort: number = 22
  private jumpUsername: string = ''
  private jumpIdentityFile: string = ''
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

  getIdentityFile(): string {
    return this.identityFile
  }

  setIdentityFile(identityFile: string): void {
    this.identityFile = identityFile
  }

  getJumpDisplayHost(): string {
    return this.jumpDisplayHost
  }

  setJumpDisplayHost(host: string): void {
    this.jumpDisplayHost = host
  }

  getJumpHostname(): string {
    return this.jumpHostname
  }

  setJumpHostname(host: string): void {
    this.jumpHostname = host
  }

  getJumpPort(): number {
    return this.jumpPort
  }

  setJumpPort(port: number): void {
    this.jumpPort = port
  }

  getJumpUsername(): string {
    return this.jumpUsername
  }

  setJumpUsername(username: string): void {
    this.jumpUsername = username
  }

  getJumpIdentityFile(): string {
    return this.jumpIdentityFile
  }

  setJumpIdentityFile(identityFile: string): void {
    this.jumpIdentityFile = identityFile
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
