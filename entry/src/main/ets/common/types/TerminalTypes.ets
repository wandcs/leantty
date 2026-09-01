export enum TerminalMode {
  IDLE = 0,
  PASSWORD_INPUT = 1,
  CONNECTING = 2,
  CONNECTED = 3,
  HOST_KEY_INPUT = 4,
  KEY_PASSPHRASE_INPUT = 5,
  KEY_PASSPHRASE_CHANGE_INPUT = 6,
  AUTH_CHALLENGE_INPUT = 7,
  TRANSFERRING = 8,
  KEY_COMMENT_PASSPHRASE_INPUT = 9,
  KEY_COMMENT_INPUT = 10
}

export enum SshSessionState {
  IDLE = 0,
  CONNECTING = 1,
  HOST_VERIFICATION_REQUIRED = 2,
  AUTHENTICATING = 3,
  CONNECTED = 4,
  FAILED = 5,
  DISCONNECTED = 6,
  RECONNECTING = 7,
  INTERRUPTED = 8
}

export class PaneInfo {
  id: string
  title: string
  state: SshSessionState
  mode: TerminalMode
  needsAttention: boolean

  constructor(id: string, title: string) {
    this.id = id
    this.title = title
    this.state = SshSessionState.IDLE
    this.mode = TerminalMode.IDLE
    this.needsAttention = false
  }
}

@Observed
export class TabInfo {
  id: string
  title: string
  isFocused: boolean
  panes: PaneInfo[]
  activePaneId: string

  constructor(id: string, title: string) {
    this.id = id
    this.title = title
    this.isFocused = false
    this.panes = []
    this.activePaneId = ''
  }
}
