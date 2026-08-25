import { preferences } from '@kit.ArkData'
import { common } from '@kit.AbilityKit'
import { Logger } from '../../common/logger/Logger'
import { InteractionPolicy } from '../ui/InteractionPolicy'
import { DurableStateManager } from '../persistence/DurableStateManager'

const logger: Logger = new Logger('UserPreferences')
const PREFERENCES_NAME: string = 'leantty_settings'
const TERMINAL_FONT_SIZE_KEY: string = 'terminal_font_size'
const TERMINAL_TRANSPARENCY_MODE_KEY: string = 'terminal_transparency_mode'
const BACKGROUND_BELL_PERMISSION_PENDING_KEY: string = 'background_bell_permission_pending'
const BACKGROUND_BELL_PERMISSION_ATTEMPTED_KEY: string = 'background_bell_permission_attempted'
const DEFAULT_TRANSPARENCY_MODE: number = 1

export class UserPreferences {
  private static store: preferences.Preferences | null = null

  static initialize(context: common.UIAbilityContext): number {
    let retainedValue: number | null = DurableStateManager.readFontSize()
    if (retainedValue !== null) {
      let retainedFontSize: number = InteractionPolicy.clampFontSize(retainedValue)
      if (retainedFontSize !== retainedValue) {
        DurableStateManager.writeFontSize(retainedFontSize)
      }
      UserPreferences.openLocalStore(context)
      UserPreferences.writeLocalFontSize(retainedFontSize)
      return retainedFontSize
    }
    try {
      UserPreferences.openLocalStore(context)
      if (UserPreferences.store === null) {
        DurableStateManager.writeFontSize(InteractionPolicy.DEFAULT_FONT_SIZE)
        return InteractionPolicy.DEFAULT_FONT_SIZE
      }
      let storedValue: preferences.ValueType = UserPreferences.store.getSync(
        TERMINAL_FONT_SIZE_KEY, InteractionPolicy.DEFAULT_FONT_SIZE)
      if (typeof storedValue !== 'number') {
        DurableStateManager.writeFontSize(InteractionPolicy.DEFAULT_FONT_SIZE)
        UserPreferences.writeLocalFontSize(InteractionPolicy.DEFAULT_FONT_SIZE)
        return InteractionPolicy.DEFAULT_FONT_SIZE
      }
      let fontSize: number = InteractionPolicy.clampFontSize(storedValue)
      DurableStateManager.writeFontSize(fontSize)
      UserPreferences.writeLocalFontSize(fontSize)
      return fontSize
    } catch (e) {
      logger.warn('Failed to load user preferences: ' + e)
      throw new Error('Failed to initialize retained user preferences: ' + e)
    }
  }

  static saveFontSize(value: number): void {
    let fontSize: number = InteractionPolicy.clampFontSize(value)
    DurableStateManager.writeFontSize(fontSize)
    if (UserPreferences.store === null) {
      logger.warn('Cannot save terminal font size before preferences initialization')
      return
    }
    try {
      UserPreferences.writeLocalFontSize(fontSize)
    } catch (e) {
      logger.warn('Failed to save terminal font size: ' + e)
    }
  }

  static loadTransparencyMode(): number {
    if (UserPreferences.store === null) {
      return DEFAULT_TRANSPARENCY_MODE
    }
    try {
      let storedValue: preferences.ValueType = UserPreferences.store.getSync(
        TERMINAL_TRANSPARENCY_MODE_KEY, DEFAULT_TRANSPARENCY_MODE)
      return typeof storedValue === 'number' ? storedValue : DEFAULT_TRANSPARENCY_MODE
    } catch (e) {
      logger.warn('Failed to load terminal transparency mode: ' + e)
      return DEFAULT_TRANSPARENCY_MODE
    }
  }

  static saveTransparencyMode(value: number): void {
    if (UserPreferences.store === null) {
      logger.warn('Cannot save terminal transparency mode before preferences initialization')
      return
    }
    try {
      UserPreferences.store.putSync(TERMINAL_TRANSPARENCY_MODE_KEY, value)
      UserPreferences.store.flushSync()
    } catch (e) {
      logger.warn('Failed to save terminal transparency mode: ' + e)
    }
  }

  static scheduleBackgroundBellPermissionRequest(): void {
    if (UserPreferences.store === null) {
      logger.warn('Cannot schedule notification permission before preferences initialization')
      return
    }
    try {
      if (UserPreferences.backgroundBellPermissionAttempted()) {
        return
      }
      UserPreferences.store.putSync(BACKGROUND_BELL_PERMISSION_PENDING_KEY, true)
      UserPreferences.store.flushSync()
    } catch (e) {
      logger.warn('Failed to schedule notification permission: ' + e)
    }
  }

  static consumeBackgroundBellPermissionRequest(): boolean {
    if (UserPreferences.store === null) {
      return false
    }
    try {
      let pendingValue: preferences.ValueType = UserPreferences.store.getSync(
        BACKGROUND_BELL_PERMISSION_PENDING_KEY, false)
      if (pendingValue !== true || UserPreferences.backgroundBellPermissionAttempted()) {
        return false
      }
      UserPreferences.store.putSync(BACKGROUND_BELL_PERMISSION_PENDING_KEY, false)
      UserPreferences.store.putSync(BACKGROUND_BELL_PERMISSION_ATTEMPTED_KEY, true)
      UserPreferences.store.flushSync()
      return true
    } catch (e) {
      logger.warn('Failed to consume notification permission request: ' + e)
      return false
    }
  }

  private static backgroundBellPermissionAttempted(): boolean {
    if (UserPreferences.store === null) {
      return false
    }
    try {
      let attemptedValue: preferences.ValueType = UserPreferences.store.getSync(
        BACKGROUND_BELL_PERMISSION_ATTEMPTED_KEY, false)
      return attemptedValue === true
    } catch (e) {
      logger.warn('Failed to read notification permission history: ' + e)
      return false
    }
  }

  private static openLocalStore(context: common.UIAbilityContext): void {
    try {
      UserPreferences.store = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME })
    } catch (e) {
      logger.warn('Failed to open local preferences projection: ' + e)
      UserPreferences.store = null
    }
  }

  private static writeLocalFontSize(fontSize: number): void {
    if (UserPreferences.store === null) {
      return
    }
    UserPreferences.store.putSync(TERMINAL_FONT_SIZE_KEY, fontSize)
    UserPreferences.store.flushSync()
  }
}
