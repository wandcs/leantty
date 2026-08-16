export class LocalCommandLine {
  private text: string = ''
  private cursor: number = 0

  getText(): string {
    return this.text
  }

  getCursor(): number {
    return this.cursor
  }

  setText(text: string): void {
    this.text = text
    this.cursor = text.length
  }

  clear(): void {
    this.text = ''
    this.cursor = 0
  }

  insert(text: string): string {
    let suffix: string = this.text.substring(this.cursor)
    this.text = this.text.substring(0, this.cursor) + text + suffix
    this.cursor += text.length
    return suffix
  }

  backspace(): string | null {
    if (this.cursor === 0) {
      return null
    }
    let removedLength: number = 1
    if (this.cursor >= 2 && LocalCommandLine.isLowSurrogate(this.text.charCodeAt(this.cursor - 1)) &&
      LocalCommandLine.isHighSurrogate(this.text.charCodeAt(this.cursor - 2))) {
      removedLength = 2
    }
    let suffix: string = this.text.substring(this.cursor)
    this.text = this.text.substring(0, this.cursor - removedLength) + suffix
    this.cursor -= removedLength
    return suffix
  }

  delete(): string | null {
    if (this.cursor === this.text.length) {
      return null
    }
    let removedLength: number = 1
    if (this.cursor + 1 < this.text.length &&
      LocalCommandLine.isHighSurrogate(this.text.charCodeAt(this.cursor)) &&
      LocalCommandLine.isLowSurrogate(this.text.charCodeAt(this.cursor + 1))) {
      removedLength = 2
    }
    this.text = this.text.substring(0, this.cursor) + this.text.substring(this.cursor + removedLength)
    return this.text.substring(this.cursor)
  }

  moveLeft(): boolean {
    if (this.cursor === 0) {
      return false
    }
    this.cursor--
    if (this.cursor > 0 && LocalCommandLine.isLowSurrogate(this.text.charCodeAt(this.cursor)) &&
      LocalCommandLine.isHighSurrogate(this.text.charCodeAt(this.cursor - 1))) {
      this.cursor--
    }
    return true
  }

  moveRight(): boolean {
    if (this.cursor === this.text.length) {
      return false
    }
    if (this.cursor + 1 < this.text.length &&
      LocalCommandLine.isHighSurrogate(this.text.charCodeAt(this.cursor)) &&
      LocalCommandLine.isLowSurrogate(this.text.charCodeAt(this.cursor + 1))) {
      this.cursor += 2
    } else {
      this.cursor++
    }
    return true
  }

  private static isHighSurrogate(code: number): boolean {
    return code >= 0xD800 && code <= 0xDBFF
  }

  private static isLowSurrogate(code: number): boolean {
    return code >= 0xDC00 && code <= 0xDFFF
  }

  renderForTerminal(prompt: string): string {
    let prefix: string = this.text.substring(0, this.cursor)
    return '\r\u001b[2K' + prompt + this.text + '\r' + prompt + prefix
  }
}
