export class TerminalTextPolicy {
  static isSafe(value: string): boolean {
    for (let index: number = 0; index < value.length; index++) {
      let code: number = value.charCodeAt(index)
      if (code === 0x1B || code < 0x20 || (code >= 0x7F && code <= 0x9F)) { return false }
      if (code >= 0xD800 && code <= 0xDBFF) {
        if (index + 1 >= value.length) { return false }
        let following: number = value.charCodeAt(index + 1)
        if (following < 0xDC00 || following > 0xDFFF) { return false }
        let codePoint: number = 0x10000 + ((code - 0xD800) << 10) + following - 0xDC00
        if (TerminalTextPolicy.isUnsafeFormat(codePoint)) { return false }
        index++
      } else if (code >= 0xDC00 && code <= 0xDFFF || TerminalTextPolicy.isUnsafeFormat(code)) {
        return false
      }
    }
    return true
  }

  static escape(value: string): string {
    let result: string = ''
    for (let index: number = 0; index < value.length; index++) {
      let code: number = value.charCodeAt(index)
      if (code === 0x1B) { result += '\\e'; continue }
      if (code < 0x20 || (code >= 0x7F && code <= 0x9F)) {
        result += '\\x' + code.toString(16).padStart(2, '0')
        continue
      }
      if (code >= 0xD800 && code <= 0xDBFF && index + 1 < value.length) {
        let following: number = value.charCodeAt(index + 1)
        if (following >= 0xDC00 && following <= 0xDFFF) {
          let codePoint: number = 0x10000 + ((code - 0xD800) << 10) + following - 0xDC00
          if (TerminalTextPolicy.isUnsafeFormat(codePoint)) {
            result += '\\u{' + codePoint.toString(16) + '}'
          } else {
            result += value[index] + value[index + 1]
          }
          index++
          continue
        }
      }
      if ((code >= 0xD800 && code <= 0xDFFF) || TerminalTextPolicy.isUnsafeFormat(code)) {
        result += '\\u{' + code.toString(16) + '}'
      } else {
        result += value[index]
      }
    }
    return result
  }

  private static isUnsafeFormat(codePoint: number): boolean {
    return codePoint === 0x00AD || (codePoint >= 0x0600 && codePoint <= 0x0605) ||
      codePoint === 0x061C || codePoint === 0x06DD || codePoint === 0x070F ||
      (codePoint >= 0x0890 && codePoint <= 0x0891) || codePoint === 0x08E2 ||
      codePoint === 0x180E || (codePoint >= 0x200B && codePoint <= 0x200F) ||
      (codePoint >= 0x202A && codePoint <= 0x202E) ||
      (codePoint >= 0x2060 && codePoint <= 0x2064) ||
      (codePoint >= 0x2066 && codePoint <= 0x206F) || codePoint === 0xFEFF ||
      (codePoint >= 0xFFF9 && codePoint <= 0xFFFB) || codePoint === 0x110BD ||
      codePoint === 0x110CD || (codePoint >= 0x13430 && codePoint <= 0x1343F) ||
      (codePoint >= 0x1BCA0 && codePoint <= 0x1BCAF) ||
      (codePoint >= 0x1D173 && codePoint <= 0x1D17A) || codePoint === 0xE0001 ||
      (codePoint >= 0xE0020 && codePoint <= 0xE007F)
  }
}
