export enum SshEscapeEventKind {
  REMOTE_DATA = 0,
  DISCONNECT = 1,
  HELP = 2,
  CONNECTION_INFO = 3
}

export class SshEscapeEvent {
  kind: SshEscapeEventKind
  data: string

  constructor(kind: SshEscapeEventKind, data: string = '') {
    this.kind = kind
    this.data = data
  }
}

export class SshEscapeResult {
  events: SshEscapeEvent[] = []
}

export class SshEscapeParser {
  private atLineStart: boolean = true
  private pendingEscape: boolean = false

  reset(): void {
    this.atLineStart = true
    this.pendingEscape = false
  }

  consume(data: string): SshEscapeResult {
    let result: SshEscapeResult = new SshEscapeResult()
    for (let index = 0; index < data.length; index++) {
      let character: string = data.charAt(index)
      if (this.pendingEscape) {
        this.pendingEscape = false
        if (character === '.') {
          result.events.push(new SshEscapeEvent(SshEscapeEventKind.DISCONNECT))
          return result
        }
        if (character === '?') {
          result.events.push(new SshEscapeEvent(SshEscapeEventKind.HELP))
          continue
        }
        if (character === 'I') {
          result.events.push(new SshEscapeEvent(SshEscapeEventKind.CONNECTION_INFO))
          continue
        }
        if (character === '~') {
          SshEscapeParser.appendRemoteData(result, '~')
          this.atLineStart = false
          continue
        }
        SshEscapeParser.appendRemoteData(result, '~' + character)
        this.atLineStart = SshEscapeParser.isLineEnd(character)
        continue
      }

      if (this.atLineStart && character === '~') {
        this.pendingEscape = true
        continue
      }
      SshEscapeParser.appendRemoteData(result, character)
      this.atLineStart = SshEscapeParser.isLineEnd(character)
    }
    return result
  }

  private static appendRemoteData(result: SshEscapeResult, data: string): void {
    let lastIndex: number = result.events.length - 1
    if (lastIndex >= 0 && result.events[lastIndex].kind === SshEscapeEventKind.REMOTE_DATA) {
      result.events[lastIndex].data += data
      return
    }
    result.events.push(new SshEscapeEvent(SshEscapeEventKind.REMOTE_DATA, data))
  }

  private static isLineEnd(character: string): boolean {
    return character === '\r' || character === '\n'
  }
}
