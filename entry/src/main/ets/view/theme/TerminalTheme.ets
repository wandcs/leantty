import { AnsiColors, TerminalColors } from './ThemeConstants'

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

  constructor(term: TerminalColors, ansi: AnsiColors) {
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
  }
}

export class TerminalThemeState {
  private baseTheme: XtermTheme

  constructor(theme: XtermTheme) {
    this.baseTheme = theme
  }

  toJsInitObject(): string {
    return JSON.stringify(this.baseTheme)
  }
}
