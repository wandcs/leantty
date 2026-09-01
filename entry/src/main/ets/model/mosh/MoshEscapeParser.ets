export enum MoshEscapeEventKind {
  REMOTE_DATA = 0,
  DISCONNECT = 1,
  HELP = 2
}

export class MoshEscapeEvent {
  kind: MoshEscapeEventKind
  data: string

  constructor(kind: MoshEscapeEventKind, data: string = '') {
    this.kind = kind
    this.data = data
  }
}

export class MoshEscapeResult {
  events: MoshEscapeEvent[] = []
}

export class MoshEscapeParser {
  private static readonly PREFIX: string = '\u001e'
  private prefixPending: boolean = false

  consume(data: string): MoshEscapeResult {
    let result: MoshEscapeResult = new MoshEscapeResult()
    let remoteData: string = ''
    let flushRemoteData: () => void = () => {
      if (remoteData.length > 0) {
        result.events.push(new MoshEscapeEvent(MoshEscapeEventKind.REMOTE_DATA, remoteData))
        remoteData = ''
      }
    }
    for (let index: number = 0; index < data.length; index++) {
      let value: string = data.charAt(index)
      if (!this.prefixPending) {
        if (value === MoshEscapeParser.PREFIX) {
          this.prefixPending = true
        } else {
          remoteData += value
        }
        continue
      }
      this.prefixPending = false
      if (value === '.') {
        flushRemoteData()
        result.events.push(new MoshEscapeEvent(MoshEscapeEventKind.DISCONNECT))
        return result
      }
      if (value === '?') {
        flushRemoteData()
        result.events.push(new MoshEscapeEvent(MoshEscapeEventKind.HELP))
      } else if (value === MoshEscapeParser.PREFIX) {
        remoteData += MoshEscapeParser.PREFIX
      } else {
        remoteData += MoshEscapeParser.PREFIX + value
      }
    }
    flushRemoteData()
    return result
  }

  reset(): void {
    this.prefixPending = false
  }
}
