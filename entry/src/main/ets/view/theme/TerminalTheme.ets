import { AnsiColors, AnsiColorsLatte, TerminalColors, TerminalColorsLatte } from './ThemeConstants'

export class XtermTheme {
  background: string
  foreground: string
  cursor: string
  cursorAccent: string
  selectionBackground: string
  selectionForeground: string
  selectionInactiveBackground: string
  black: string
  red: string
  green: string
  yellow: string
  blue: string
  magenta: string
  cyan: string
  white: string
  brightBlack: string
  brightRed: string
  brightGreen: string
  brightYellow: string
  brightBlue: string
  brightMagenta: string
  brightCyan: string
  brightWhite: string
  cellBackgroundOpacity: number

  constructor(term: TerminalColors, ansi: AnsiColors, cellBackgroundOpacity: number = 1.00) {
    this.background = term.background
    this.foreground = term.foreground
    this.cursor = term.cursor
    this.cursorAccent = term.cursorAccent
    this.selectionBackground = term.selectionBackground
    this.selectionForeground = term.selectionForeground
    this.selectionInactiveBackground = term.selectionInactiveBackground
    this.black = ansi.black
    this.red = ansi.red
    this.green = ansi.green
    this.yellow = ansi.yellow
    this.blue = ansi.blue
    this.magenta = ansi.magenta
    this.cyan = ansi.cyan
    this.white = ansi.white
    this.brightBlack = ansi.brightBlack
    this.brightRed = ansi.brightRed
    this.brightGreen = ansi.brightGreen
    this.brightYellow = ansi.brightYellow
    this.brightBlue = ansi.brightBlue
    this.brightMagenta = ansi.brightMagenta
    this.brightCyan = ansi.brightCyan
    this.brightWhite = ansi.brightWhite
    this.cellBackgroundOpacity = cellBackgroundOpacity
  }
}

const catppuccinMochaTheme: XtermTheme = new XtermTheme(
  new TerminalColors(), new AnsiColors()
)

const catppuccinLatteTheme: XtermTheme = new XtermTheme(
  new TerminalColorsLatte(), new AnsiColorsLatte()
)

export { catppuccinMochaTheme as CATPPUCCIN_MOCHA_THEME, catppuccinLatteTheme as CATPPUCCIN_LATTE_THEME }

export class Osc4ColorOverride {
  colorIndex: number
  hexValue: string

  constructor(index: number, hex: string) {
    this.colorIndex = index
    this.hexValue = hex
  }
}

export class TerminalThemeState {
  private baseTheme: XtermTheme
  private osc4Overrides: Osc4ColorOverride[]

  constructor(theme: XtermTheme) {
    this.baseTheme = theme
    this.osc4Overrides = []
  }

  get current(): XtermTheme {
    return this.baseTheme
  }

  applyOsc4(index: number, hex: string): void {
    let found: boolean = false
    for (let i = 0; i < this.osc4Overrides.length; i++) {
      if (this.osc4Overrides[i].colorIndex === index) {
        this.osc4Overrides[i].hexValue = hex
        found = true
        break
      }
    }
    if (!found) {
      this.osc4Overrides.push(new Osc4ColorOverride(index, hex))
    }
  }

  resetOsc4(): void {
    this.osc4Overrides = []
  }

  toJsInitObject(): string {
    return JSON.stringify(this.baseTheme)
  }

  toOsc4ResetCommands(): string[] {
    let commands: string[] = []
    for (let i = 0; i < 16; i++) {
      let hex: string = this.colorAtBaseIndex(i)
      if (hex.length > 0) {
        commands.push('\x1b]4;' + i.toString() + ';rgb:' +
          hex.substring(1, 3) + '/' +
          hex.substring(3, 5) + '/' +
          hex.substring(5, 7) + '\x07')
      }
    }
    return commands
  }

  private indexToColorName(index: number): string {
    if (index === 0) return 'black'
    if (index === 1) return 'red'
    if (index === 2) return 'green'
    if (index === 3) return 'yellow'
    if (index === 4) return 'blue'
    if (index === 5) return 'magenta'
    if (index === 6) return 'cyan'
    if (index === 7) return 'white'
    if (index === 8) return 'brightBlack'
    if (index === 9) return 'brightRed'
    if (index === 10) return 'brightGreen'
    if (index === 11) return 'brightYellow'
    if (index === 12) return 'brightBlue'
    if (index === 13) return 'brightMagenta'
    if (index === 14) return 'brightCyan'
    if (index === 15) return 'brightWhite'
    return ''
  }

  private colorAtBaseIndex(index: number): string {
    let t: XtermTheme = this.baseTheme
    if (index === 0) return t.black
    if (index === 1) return t.red
    if (index === 2) return t.green
    if (index === 3) return t.yellow
    if (index === 4) return t.blue
    if (index === 5) return t.magenta
    if (index === 6) return t.cyan
    if (index === 7) return t.white
    if (index === 8) return t.brightBlack
    if (index === 9) return t.brightRed
    if (index === 10) return t.brightGreen
    if (index === 11) return t.brightYellow
    if (index === 12) return t.brightBlue
    if (index === 13) return t.brightMagenta
    if (index === 14) return t.brightCyan
    if (index === 15) return t.brightWhite
    return ''
  }
}
