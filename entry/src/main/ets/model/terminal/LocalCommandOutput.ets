const RESET: string = '\u001b[0m'
const RED: string = '\u001b[31m'
const GREEN: string = '\u001b[32m'
const YELLOW: string = '\u001b[33m'
const CYAN: string = '\u001b[36m'

export class LocalCommandOutput {
  static prompt(): string {
    return CYAN + 'L' + GREEN + '>' + RESET + ' '
  }

  static status(label: string, detail: string): string {
    return CYAN + label + RESET + (detail.length > 0 ? ' ' + detail : '')
  }

  static progress(value: string): string {
    return CYAN + value + RESET
  }

  static finalizing(value: string): string {
    return YELLOW + value + RESET
  }

  static success(message: string): string {
    return GREEN + '●' + RESET + ' ' + message
  }

  static warning(message: string): string {
    return YELLOW + 'Warning:' + RESET + ' ' + message
  }

  static note(message: string): string {
    return CYAN + 'Note:' + RESET + ' ' + message
  }

  static cancelled(): string {
    return YELLOW + 'Cancelled.' + RESET
  }

  static error(message: string, guidance: string = ''): string {
    if (message.startsWith('Usage: ')) {
      guidance = message
      message = 'Invalid command syntax.'
    }
    let normalized: string = message.replace(/\r\n/g, '\n').replace(/\r/g, '\n')
    let lines: string[] = normalized.split('\n')
    let output: string = RESET + '\r\n' + RED + 'Error:' + RESET + ' ' +
      (lines.length > 0 && lines[0].length > 0 ? lines[0] : 'The command could not be completed.')
    for (let index: number = 1; index < lines.length; index++) {
      output += lines[index].length > 0 ? '\r\n  ' + lines[index] : '\r\n'
    }
    if (guidance.length > 0) { output += '\r\n  ' + guidance }
    return output + '\r\n' + LocalCommandOutput.prompt()
  }
}
