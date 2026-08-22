import { AnsiColors, AnsiColorsLatte, ChromeColors, ChromeColorsLatte, TerminalColors, TerminalColorsLatte, Sizing, Spacing, Typography, GhosttyDefault } from './ThemeConstants'
import { XtermTheme, TerminalThemeState } from './TerminalTheme'

export enum ColorMode {
  DARK = 0,
  LIGHT = 1,
  SYSTEM = 2
}

export enum TransparencyMode {
  HIGH = 0,
  MEDIUM = 1,
  LOW = 2,
  OFF = 3,
  EXTREME = 4
}

export class TransparencyPolicy {
  static defaultMode(): TransparencyMode {
    return TransparencyMode.MEDIUM
  }

  static normalize(value: number): TransparencyMode {
    if (value === TransparencyMode.HIGH) return TransparencyMode.HIGH
    if (value === TransparencyMode.LOW) return TransparencyMode.LOW
    if (value === TransparencyMode.OFF) return TransparencyMode.OFF
    if (value === TransparencyMode.EXTREME) return TransparencyMode.EXTREME
    return TransparencyMode.MEDIUM
  }

  static decrease(mode: TransparencyMode): TransparencyMode {
    if (mode === TransparencyMode.EXTREME) return TransparencyMode.HIGH
    if (mode === TransparencyMode.HIGH) return TransparencyMode.MEDIUM
    if (mode === TransparencyMode.MEDIUM) return TransparencyMode.LOW
    return TransparencyMode.OFF
  }

  static increase(mode: TransparencyMode): TransparencyMode {
    if (mode === TransparencyMode.OFF) return TransparencyMode.LOW
    if (mode === TransparencyMode.LOW) return TransparencyMode.MEDIUM
    if (mode === TransparencyMode.MEDIUM) return TransparencyMode.HIGH
    return TransparencyMode.EXTREME
  }

  static canDecrease(mode: TransparencyMode): boolean {
    return mode !== TransparencyMode.OFF
  }

  static canIncrease(mode: TransparencyMode): boolean {
    return mode !== TransparencyMode.EXTREME
  }

  static label(mode: TransparencyMode): string {
    if (mode === TransparencyMode.OFF) return 'Off'
    if (mode === TransparencyMode.HIGH) return 'High'
    if (mode === TransparencyMode.LOW) return 'Low'
    if (mode === TransparencyMode.EXTREME) return 'Extreme'
    return 'Medium'
  }

  static contentOpacity(mode: TransparencyMode): number {
    if (mode === TransparencyMode.OFF) return 1.00
    if (mode === TransparencyMode.HIGH) return 0.60
    if (mode === TransparencyMode.LOW) return 0.82
    if (mode === TransparencyMode.EXTREME) return 0.45
    return 0.72
  }

  static chromeOpacity(mode: TransparencyMode): number {
    if (mode === TransparencyMode.OFF) return 1.00
    if (mode === TransparencyMode.LOW || mode === TransparencyMode.MEDIUM) return 0.94
    return 0.86
  }

  static terminalBackground(mode: TransparencyMode, isLight: boolean): string {
    return 'rgba(30, 30, 46, 0)'
  }

  static surfaceBackground(mode: TransparencyMode, isLight: boolean): string {
    let rgb: string = isLight ? 'EFF1F5' : '1E1E2E'
    if (mode === TransparencyMode.OFF) return '#FF' + rgb
    if (mode === TransparencyMode.HIGH) return '#99' + rgb
    if (mode === TransparencyMode.LOW) return '#D1' + rgb
    if (mode === TransparencyMode.EXTREME) return '#73' + rgb
    return '#B8' + rgb
  }

  static chromeSurfaceBackground(mode: TransparencyMode, isLight: boolean): string {
    let rgb: string = isLight ? 'EFF1F5' : '1E1E2E'
    return '#' + TransparencyPolicy.chromeAlpha(mode) + rgb
  }

  static chromeTabBackground(mode: TransparencyMode, isLight: boolean): string {
    let rgb: string = isLight ? 'D3D7DF' : '2D2E40'
    if (mode === TransparencyMode.OFF) {
      rgb = isLight ? 'DEE1E8' : '282839'
    } else if (mode === TransparencyMode.HIGH || mode === TransparencyMode.EXTREME) {
      rgb = isLight ? 'CCD0DA' : '313244'
    }
    return '#' + TransparencyPolicy.chromeAlpha(mode) + rgb
  }

  static chromeTabHoverBackground(mode: TransparencyMode, isLight: boolean): string {
    let rgb: string = isLight ? 'CACED8' : '343547'
    if (mode === TransparencyMode.OFF) {
      rgb = isLight ? 'D5D8E1' : '2C2D3F'
    } else if (mode === TransparencyMode.HIGH || mode === TransparencyMode.EXTREME) {
      rgb = isLight ? 'C4C8D3' : '3B3D4F'
    }
    return '#' + TransparencyPolicy.chromeAlpha(mode) + rgb
  }

  static chromeTabActiveBackground(mode: TransparencyMode, isLight: boolean): string {
    let rgb: string = isLight ? 'C6CAD4' : '393A4D'
    if (mode === TransparencyMode.OFF) {
      rgb = isLight ? 'CCD0DA' : '313244'
    } else if (mode === TransparencyMode.HIGH || mode === TransparencyMode.EXTREME) {
      rgb = isLight ? 'C0C4D0' : '404255'
    }
    return '#' + TransparencyPolicy.chromeAlpha(mode) + rgb
  }

  private static chromeAlpha(mode: TransparencyMode): string {
    if (mode === TransparencyMode.OFF) return 'FF'
    if (mode === TransparencyMode.LOW || mode === TransparencyMode.MEDIUM) return 'F0'
    return 'DB'
  }

  static opaqueSurfaceBackground(isLight: boolean): string {
    return isLight ? '#FFEFF1F5' : '#FF1E1E2E'
  }

  static opaqueChromeSurfaceBackground(isLight: boolean): string {
    return isLight ? '#FFEFF1F5' : '#FF1E1E2E'
  }
}

export class AppTheme {
  colorMode: ColorMode
  terminal: TerminalThemeState
  terminalColors: TerminalColors | TerminalColorsLatte
  ansiColors: AnsiColors | AnsiColorsLatte
  chrome: ChromeColors | ChromeColorsLatte
  sizing: Sizing
  spacing: Spacing
  typography: Typography
  ghosttyDefault: GhosttyDefault
  transparencyMode: TransparencyMode

  constructor(mode: ColorMode, transparencyMode: TransparencyMode = TransparencyMode.MEDIUM) {
    this.colorMode = mode
    this.transparencyMode = transparencyMode
    this.sizing = new Sizing()
    this.spacing = new Spacing()
    this.typography = new Typography()
    this.ghosttyDefault = new GhosttyDefault()
    if (mode === ColorMode.LIGHT) {
      this.terminalColors = new TerminalColorsLatte()
      this.ansiColors = new AnsiColorsLatte()
      this.chrome = new ChromeColorsLatte()
      this.terminalColors.background = TransparencyPolicy.terminalBackground(transparencyMode, true)
      this.terminalColors.surfaceBackground = TransparencyPolicy.surfaceBackground(transparencyMode, true)
      this.terminal = new TerminalThemeState(new XtermTheme(
        this.terminalColors, this.ansiColors))
    } else {
      this.terminalColors = new TerminalColors()
      this.ansiColors = new AnsiColors()
      this.chrome = new ChromeColors()
      this.terminalColors.background = TransparencyPolicy.terminalBackground(transparencyMode, false)
      this.terminalColors.surfaceBackground = TransparencyPolicy.surfaceBackground(transparencyMode, false)
      this.terminal = new TerminalThemeState(new XtermTheme(
        this.terminalColors, this.ansiColors))
    }
    this.chrome.tabBackground = TransparencyPolicy.chromeTabBackground(
      transparencyMode, mode === ColorMode.LIGHT)
    this.chrome.tabHoverBackground = TransparencyPolicy.chromeTabHoverBackground(
      transparencyMode, mode === ColorMode.LIGHT)
    this.chrome.tabActiveBackground = TransparencyPolicy.chromeTabActiveBackground(
      transparencyMode, mode === ColorMode.LIGHT)
  }

  isDark(): boolean {
    return this.colorMode === ColorMode.DARK
  }

  background(windowTransparencyAvailable: boolean = true): string {
    if (!windowTransparencyAvailable) {
      return TransparencyPolicy.opaqueSurfaceBackground(this.colorMode === ColorMode.LIGHT)
    }
    return this.terminalColors.surfaceBackground
  }

  chromeBackground(windowTransparencyAvailable: boolean = true): string {
    if (!windowTransparencyAvailable) {
      return TransparencyPolicy.opaqueChromeSurfaceBackground(this.colorMode === ColorMode.LIGHT)
    }
    return TransparencyPolicy.chromeSurfaceBackground(
      this.transparencyMode, this.colorMode === ColorMode.LIGHT)
  }
}

export class ThemeManager {
  private static instance: ThemeManager | null = null
  private currentTheme: AppTheme
  private listeners: (() => void)[]
  private preferredMode: ColorMode
  private systemIsDark: boolean
  private transparencyMode: TransparencyMode

  private constructor() {
    this.preferredMode = ColorMode.DARK
    this.systemIsDark = true
    this.transparencyMode = TransparencyPolicy.defaultMode()
    this.currentTheme = new AppTheme(ColorMode.DARK, this.transparencyMode)
    this.listeners = []
  }

  static getInstance(): ThemeManager {
    if (ThemeManager.instance === null) {
      ThemeManager.instance = new ThemeManager()
    }
    return ThemeManager.instance
  }

  getTheme(): AppTheme {
    return this.currentTheme
  }

  setMode(mode: ColorMode): void {
    this.preferredMode = mode
    this.refreshTheme()
  }

  setSystemIsDark(isDark: boolean): void {
    this.systemIsDark = isDark
    if (this.preferredMode === ColorMode.SYSTEM) {
      this.refreshTheme()
    }
  }

  getTransparencyMode(): TransparencyMode {
    return this.transparencyMode
  }

  setTransparencyMode(mode: TransparencyMode): void {
    let normalized: TransparencyMode = TransparencyPolicy.normalize(mode)
    if (normalized === this.transparencyMode) {
      return
    }
    this.transparencyMode = normalized
    this.refreshTheme()
  }

  stepTransparencyMode(direction: number): TransparencyMode {
    let nextMode: TransparencyMode = direction < 0 ?
      TransparencyPolicy.decrease(this.transparencyMode) :
      TransparencyPolicy.increase(this.transparencyMode)
    this.setTransparencyMode(nextMode)
    return nextMode
  }

  private refreshTheme(): void {
    let effectiveMode: ColorMode = this.preferredMode
    if (this.preferredMode === ColorMode.SYSTEM) {
      effectiveMode = this.systemIsDark ? ColorMode.DARK : ColorMode.LIGHT
    }
    this.currentTheme = new AppTheme(effectiveMode, this.transparencyMode)
    this.notifyListeners()
  }

  onThemeChange(callback: () => void): void {
    this.listeners.push(callback)
  }

  removeThemeChange(callback: () => void): void {
    let idx: number = -1
    for (let i = 0; i < this.listeners.length; i++) {
      if (this.listeners[i] === callback) {
        idx = i
        break
      }
    }
    if (idx >= 0) {
      this.listeners.splice(idx, 1)
    }
  }

  private notifyListeners(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i]()
    }
  }
}
