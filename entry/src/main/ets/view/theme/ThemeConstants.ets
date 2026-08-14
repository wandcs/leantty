export class AnsiColors {
  black: string = '#45475A'
  red: string = '#F38BA8'
  green: string = '#A6E3A1'
  yellow: string = '#F9E2AF'
  blue: string = '#89B4FA'
  magenta: string = '#F5C2E7'
  cyan: string = '#94E2D5'
  white: string = '#BAC2DE'
  brightBlack: string = '#585B70'
  brightRed: string = '#F38BA8'
  brightGreen: string = '#A6E3A1'
  brightYellow: string = '#F9E2AF'
  brightBlue: string = '#89B4FA'
  brightMagenta: string = '#F5C2E7'
  brightCyan: string = '#94E2D5'
  brightWhite: string = '#A6ADC8'
}

export class AnsiColorsLatte extends AnsiColors {
  black: string = '#5C5F77'
  red: string = '#D20F39'
  green: string = '#40A02B'
  yellow: string = '#DF8E1D'
  blue: string = '#1E66F5'
  magenta: string = '#EA76CB'
  cyan: string = '#179299'
  white: string = '#4C4F69'
  brightBlack: string = '#6C6F85'
  brightRed: string = '#D20F39'
  brightGreen: string = '#40A02B'
  brightYellow: string = '#DF8E1D'
  brightBlue: string = '#1E66F5'
  brightMagenta: string = '#EA76CB'
  brightCyan: string = '#179299'
  brightWhite: string = '#BCC0CC'
}

export class TerminalColors {
  background: string = 'rgba(0, 0, 0, 0)'
  surfaceBackground: string = '#D11E1E2E'
  foreground: string = '#CDD6F4'
  cursor: string = '#F5E0DC'
  cursorAccent: string = '#1E1E2E'
  selectionBackground: string = '#585B70'
  selectionForeground: string = '#CDD6F4'
  selectionInactiveBackground: string = '#45475A'
}

export class TerminalColorsLatte extends TerminalColors {
  background: string = 'rgba(0, 0, 0, 0)'
  surfaceBackground: string = '#D1EFF1F5'
  foreground: string = '#4C4F69'
  cursor: string = '#DC8A78'
  cursorAccent: string = '#EFF1F5'
  selectionBackground: string = '#ACB0BE'
  selectionForeground: string = '#4C4F69'
  selectionInactiveBackground: string = '#CCD0DA'
}

export class ChromeColors {
  tabBackground: string = '#00181825'
  tabActiveBackground: string = '#CC313244'
  focusRing: string = '#89B4FA'
  attention: string = '#F9E2AF'
  commandBarBackground: string = '#181825'
  commandBarText: string = '#CDD6F4'
  commandBarPlaceholder: string = '#585B70'
  commandBarBorder: string = '#313244'
  statusText: string = '#A6ADC8'
  statusConnected: string = '#A6E3A1'
  statusDisconnected: string = '#F38BA8'
  statusConnecting: string = '#F9E2AF'
  divider: string = '#313244'
  paneFocusVeil: string = '#11111B'
  paneFocusVeilOpacity: number = 0.20
  splitHandle: string = '#6C7086'
  splitHandleActive: string = '#89B4FA'
  paneControlBackground: string = '#181825'
  paneControlBorder: string = '#45475A'
  paneControlText: string = '#CDD6F4'
}

export class ChromeColorsLatte extends ChromeColors {
  tabBackground: string = '#00E6E9EF'
  tabActiveBackground: string = '#CCBCC0CC'
  focusRing: string = '#1E66F5'
  attention: string = '#DF8E1D'
  commandBarBackground: string = '#E6E9EF'
  commandBarText: string = '#4C4F69'
  commandBarPlaceholder: string = '#9CA0B0'
  commandBarBorder: string = '#CCD0DA'
  statusText: string = '#6C6F85'
  statusConnected: string = '#40A02B'
  statusDisconnected: string = '#D20F39'
  statusConnecting: string = '#DF8E1D'
  divider: string = '#CCD0DA'
  paneFocusVeil: string = '#4C4F69'
  paneFocusVeilOpacity: number = 0.08
  splitHandle: string = '#9CA0B0'
  splitHandleActive: string = '#1E66F5'
  paneControlBackground: string = '#E6E9EF'
  paneControlBorder: string = '#BCC0CC'
  paneControlText: string = '#4C4F69'
}

export class Sizing {
  tabHeight: number = 40
  tabMinWidth: number = 120
  tabMaxWidth: number = 240
  tabPaddingH: number = 12
  tabFontSize: number = 13
  commandBarHeight: number = 36
  commandBarFontSize: number = 14
  commandBarPaddingH: number = 12
  commandBarIconSize: number = 16
  commandBarRadius: number = 8
  statusBarHeight: number = 24
  statusBarFontSize: number = 11
  dividerWidth: number = 1
  paneMinWidth: number = 200
  paneMinHeight: number = 100
}

export class Spacing {
  contentPadding: number = 8
  tabGap: number = 2
  elementGap: number = 8
  commandBarMarginH: number = 8
  commandBarMarginV: number = 4
}

export class Typography {
  fontFamily: string = 'JetBrains Mono Nerd Font Mono'
  fontFamilyFallback: string = 'HarmonyOS Sans Mono, monospace'
  terminalFontSize: number = 14
  terminalLineHeight: number = 1.2
  uiFontFamily: string = 'HarmonyOS Sans'
  uiFontSize: string = '14fp'
  uiFontSizeSmall: string = '12fp'
}

export class GhosttyDefault {
  theme: string = 'catppuccin-mocha'
  fontSize: number = 14
  lineHeight: number = 1.2
  cursorStyle: string = 'bar'
  cursorBlink: boolean = true
  scrollback: number = 10000
  confirmClose: boolean = true
  copyOnSelect: boolean = false
  windowPadding: number = 4
}

export const GHOSTTY_DEFAULT: GhosttyDefault = new GhosttyDefault()
export const SIZING: Sizing = new Sizing()
export const SPACING: Spacing = new Spacing()
export const TYPOGRAPHY: Typography = new Typography()
