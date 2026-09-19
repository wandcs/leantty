export class KeyCodeMap {
  static readonly ESCAPE: number = 2070
  static readonly TAB: number = 2049
  static readonly ENTER: number = 2054
  static readonly BACKSPACE: number = 2055
  static readonly A: number = 2017
  static readonly C: number = 2019
  static readonly T: number = 2036
  static readonly W: number = 2039
  static readonly Z: number = 2042
  static readonly NUM_0: number = 2000
  static readonly NUM_1: number = 2001
  static readonly NUM_9: number = 2009
  static readonly ARROW_UP: number = 2012
  static readonly ARROW_DOWN: number = 2013
  static readonly ARROW_LEFT: number = 2014
  static readonly ARROW_RIGHT: number = 2015
  static readonly CTRL_LEFT: number = 2072
  static readonly CTRL_RIGHT: number = 2073
  static readonly ALT_LEFT: number = 2045
  static readonly ALT_RIGHT: number = 2046
  static readonly SHIFT_LEFT: number = 2047
  static readonly SHIFT_RIGHT: number = 2048
  static readonly PAGE_UP: number = 2068
  static readonly PAGE_DOWN: number = 2069
  static readonly HOME: number = 2081
  static readonly END: number = 2082
  static readonly DELETE: number = 2071
  static readonly F1: number = 2090
  static readonly F2: number = 2091
  static readonly F3: number = 2092
  static readonly F4: number = 2093
  static readonly F5: number = 2094
  static readonly F6: number = 2095
  static readonly F7: number = 2096
  static readonly F8: number = 2097
  static readonly F9: number = 2098
  static readonly F10: number = 2099
  static readonly F11: number = 2100
  static readonly F12: number = 2101

  static toAnsi(keyCode: number, ctrlKey: boolean, altKey: boolean, shiftKey: boolean,
    applicationCursorMode: boolean = false): string {
    let printable: string = KeyCodeMap.toPrintable(keyCode, shiftKey)
    if (ctrlKey && printable.length > 0) {
      let control: string = KeyCodeMap.toControl(printable)
      if (control.length > 0) {
        return altKey ? '\x1b' + control : control
      }
    }
    if (printable.length > 0) {
      return altKey ? '\x1b' + printable : printable
    }
    let modifier: number = KeyCodeMap.modifierCode(ctrlKey, altKey, shiftKey)
    switch (keyCode) {
      case 2054: return altKey ? '\x1b\r' : '\r'
      case 2055: return altKey ? '\x1b\x7f' : '\x7f'
      case 2049: return shiftKey ? '\x1b[Z' : '\t'
      case 2070: return '\x1b'
      case 2012: return KeyCodeMap.cursorSequence('A', modifier, applicationCursorMode)
      case 2013: return KeyCodeMap.cursorSequence('B', modifier, applicationCursorMode)
      case 2015: return KeyCodeMap.cursorSequence('C', modifier, applicationCursorMode)
      case 2014: return KeyCodeMap.cursorSequence('D', modifier, applicationCursorMode)
      case 2081: return KeyCodeMap.cursorSequence('H', modifier, applicationCursorMode)
      case 2082: return KeyCodeMap.cursorSequence('F', modifier, applicationCursorMode)
      case 2068: return KeyCodeMap.tildeSequence(5, modifier)
      case 2069: return KeyCodeMap.tildeSequence(6, modifier)
      case 2071: return KeyCodeMap.tildeSequence(3, modifier)
      default:
        break
    }
    if (keyCode >= 2090 && keyCode <= 2093) {
      let finals: string[] = ['P', 'Q', 'R', 'S']
      let finalChar: string = finals[keyCode - 2090]
      return modifier === 1 ? '\x1bO' + finalChar : '\x1b[1;' + modifier.toString() + finalChar
    }
    if (keyCode >= 2094 && keyCode <= 2101) {
      let bases: number[] = [15, 17, 18, 19, 20, 21, 23, 24]
      return KeyCodeMap.tildeSequence(bases[keyCode - 2094], modifier)
    }
    return ''
  }

  static toPrintable(keyCode: number, shiftKey: boolean): string {
    if (keyCode >= 2017 && keyCode <= 2042) {
      return String.fromCharCode(keyCode - 2017 + (shiftKey ? 65 : 97))
    }
    if (keyCode >= 2000 && keyCode <= 2009) {
      if (shiftKey) {
        let shiftedDigits: string[] = [')', '!', '@', '#', '$', '%', '^', '&', '*', '(']
        return shiftedDigits[keyCode - 2000]
      }
      return String.fromCharCode(keyCode - 2000 + 48)
    }
    switch (keyCode) {
      case 2050: return ' '
      case 2056: return shiftKey ? '~' : '`'
      case 2057: return shiftKey ? '_' : '-'
      case 2058: return shiftKey ? '+' : '='
      case 2059: return shiftKey ? '{' : '['
      case 2060: return shiftKey ? '}' : ']'
      case 2061: return shiftKey ? '|' : '\\'
      case 2062: return shiftKey ? ':' : ';'
      case 2063: return shiftKey ? '"' : "'"
      case 2064: return shiftKey ? '?' : '/'
      case 2043: return shiftKey ? '<' : ','
      case 2044: return shiftKey ? '>' : '.'
      case 2065: return '@'
      case 2066: return '+'
      case 2010: return '*'
      case 2011: return '#'
      default: return ''
    }
  }

  private static toControl(printable: string): string {
    let code: number = printable.charCodeAt(0)
    if (code >= 97 && code <= 122) {
      return String.fromCharCode(code - 96)
    }
    if (code >= 65 && code <= 90) {
      return String.fromCharCode(code - 64)
    }
    switch (printable) {
      case ' ':
      case '@': return '\x00'
      case '[': return '\x1b'
      case '\\': return '\x1c'
      case ']': return '\x1d'
      case '^': return '\x1e'
      case '_': return '\x1f'
      case '?': return '\x7f'
      default: return ''
    }
  }

  private static modifierCode(ctrlKey: boolean, altKey: boolean, shiftKey: boolean): number {
    return 1 + (shiftKey ? 1 : 0) + (altKey ? 2 : 0) + (ctrlKey ? 4 : 0)
  }

  private static cursorSequence(finalChar: string, modifier: number, applicationCursorMode: boolean): string {
    if (modifier > 1) {
      return '\x1b[1;' + modifier.toString() + finalChar
    }
    return applicationCursorMode ? '\x1bO' + finalChar : '\x1b[' + finalChar
  }

  private static tildeSequence(base: number, modifier: number): string {
    if (modifier > 1) {
      return '\x1b[' + base.toString() + ';' + modifier.toString() + '~'
    }
    return '\x1b[' + base.toString() + '~'
  }
}
