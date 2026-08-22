import { AnsiColors, ChromeColors, TerminalColors } from './ThemeConstants'
import { XtermTheme, TerminalThemeState } from './TerminalTheme'

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

  static terminalBackground(): string {
    return 'rgba(30, 30, 46, 0)'
  }

  static surfaceBackground(mode: TransparencyMode): string {
    if (mode === TransparencyMode.OFF) return '#FF1E1E2E'
    if (mode === TransparencyMode.HIGH) return '#991E1E2E'
    if (mode === TransparencyMode.LOW) return '#D11E1E2E'
    if (mode === TransparencyMode.EXTREME) return '#731E1E2E'
    return '#B81E1E2E'
  }

  static chromeSurfaceBackground(mode: TransparencyMode): string {
    return '#' + TransparencyPolicy.chromeAlpha(mode) + '1E1E2E'
  }

  static chromeTabBackground(mode: TransparencyMode): string {
    let rgb: string = '2D2E40'
    if (mode === TransparencyMode.OFF) {
      rgb = '282839'
    } else if (mode === TransparencyMode.HIGH || mode === TransparencyMode.EXTREME) {
      rgb = '313244'
    }
    return '#' + TransparencyPolicy.chromeAlpha(mode) + rgb
  }

  static chromeTabHoverBackground(mode: TransparencyMode): string {
    let rgb: string = '343547'
    if (mode === TransparencyMode.OFF) {
      rgb = '2C2D3F'
    } else if (mode === TransparencyMode.HIGH || mode === TransparencyMode.EXTREME) {
      rgb = '3B3D4F'
    }
    return '#' + TransparencyPolicy.chromeAlpha(mode) + rgb
  }

  static chromeTabActiveBackground(mode: TransparencyMode): string {
    let rgb: string = '393A4D'
    if (mode === TransparencyMode.OFF) {
      rgb = '313244'
    } else if (mode === TransparencyMode.HIGH || mode === TransparencyMode.EXTREME) {
      rgb = '404255'
    }
    return '#' + TransparencyPolicy.chromeAlpha(mode) + rgb
  }

  private static chromeAlpha(mode: TransparencyMode): string {
    if (mode === TransparencyMode.OFF) return 'FF'
    if (mode === TransparencyMode.LOW || mode === TransparencyMode.MEDIUM) return 'F0'
    return 'DB'
  }

  static opaqueSurfaceBackground(): string {
    return '#FF1E1E2E'
  }

  static opaqueChromeSurfaceBackground(): string {
    return '#FF1E1E2E'
  }
}

export class AppTheme {
  terminal: TerminalThemeState
  terminalColors: TerminalColors
  chrome: ChromeColors
  transparencyMode: TransparencyMode

  constructor(transparencyMode: TransparencyMode = TransparencyMode.MEDIUM) {
    this.transparencyMode = transparencyMode
    this.terminalColors = new TerminalColors()
    this.terminalColors.background = TransparencyPolicy.terminalBackground()
    this.terminalColors.surfaceBackground = TransparencyPolicy.surfaceBackground(transparencyMode)
    this.chrome = new ChromeColors()
    this.chrome.tabBackground = TransparencyPolicy.chromeTabBackground(transparencyMode)
    this.chrome.tabHoverBackground = TransparencyPolicy.chromeTabHoverBackground(transparencyMode)
    this.chrome.tabActiveBackground = TransparencyPolicy.chromeTabActiveBackground(transparencyMode)
    this.terminal = new TerminalThemeState(new XtermTheme(
      this.terminalColors, new AnsiColors()))
  }

  background(windowTransparencyAvailable: boolean = true): string {
    if (!windowTransparencyAvailable) {
      return TransparencyPolicy.opaqueSurfaceBackground()
    }
    return this.terminalColors.surfaceBackground
  }

  chromeBackground(windowTransparencyAvailable: boolean = true): string {
    if (!windowTransparencyAvailable) {
      return TransparencyPolicy.opaqueChromeSurfaceBackground()
    }
    return TransparencyPolicy.chromeSurfaceBackground(this.transparencyMode)
  }
}

export class ThemeManager {
  private static instance: ThemeManager | null = null
  private currentTheme: AppTheme
  private listeners: (() => void)[]
  private transparencyMode: TransparencyMode

  private constructor() {
    this.transparencyMode = TransparencyPolicy.defaultMode()
    this.currentTheme = new AppTheme(this.transparencyMode)
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
    this.currentTheme = new AppTheme(this.transparencyMode)
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
