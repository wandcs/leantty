import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { ThemeManager, TransparencyPolicy } from '../view/theme/ThemeManager';
import { Logger } from '../common/logger/Logger';
import { UserPreferences } from '../model/settings/UserPreferences';
import { InteractionPolicy } from '../model/ui/InteractionPolicy';
import { DurableStateManager } from '../model/persistence/DurableStateManager';
import webview from '@ohos.web.webview';
import { BusinessError } from '@ohos.base';
import { ApplicationCloseCoordinator } from '../model/ui/ApplicationCloseCoordinator';
import { WindowGridSnapPolicy } from '../model/ui/WindowGridSnapPolicy';

const logger: Logger = new Logger('EntryAbility')
const FALLBACK_TITLE_BUTTON_WIDTH: number = 140

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null
  private windowDragStartRect: window.Rect | null = null
  private windowVisibilityChangeHandler: (visible: boolean) => void = (visible: boolean): void => {
    AppStorage.setOrCreate('mainWindowVisible', visible)
    logger.info('Window visibility changed: visible=' + visible.toString())
  }
  private titleButtonRectChangeHandler: (rect: window.TitleButtonRect) => void =
    (rect: window.TitleButtonRect): void => {
      this.publishTitleButtonRect(rect)
      logger.info('Title button rect changed: right=' + rect.right.toString() +
        ', top=' + rect.top.toString() + ', width=' + rect.width.toString() +
        ', height=' + rect.height.toString())
    }
  private windowRectChangeHandler: (options: window.RectChangeOptions) => void =
    (options: window.RectChangeOptions): void => {
      if (options.reason === window.RectChangeReason.DRAG_START) {
        this.windowDragStartRect = this.copyWindowRect(options.rect)
        return
      }
      if (options.reason !== window.RectChangeReason.DRAG_END || this.windowDragStartRect === null) {
        return
      }
      let startRect: window.Rect = this.windowDragStartRect
      this.windowDragStartRect = null
      this.snapWindowAfterDrag(startRect, options.rect)
    }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    DurableStateManager.initialize(this.context)
    AppStorage.setOrCreate('pcTitleButtonReservedWidth', FALLBACK_TITLE_BUTTON_WIDTH)
    AppStorage.setOrCreate('mainWindowVisible', true)
    AppStorage.setOrCreate('windowTransparencyAvailable', false)
    AppStorage.setOrCreate('terminalFontSize', UserPreferences.initialize(this.context))
    ThemeManager.getInstance().setTransparencyMode(
      TransparencyPolicy.normalize(UserPreferences.loadTransparencyMode()))
    AppStorage.setOrCreate('hasActiveSshSession', false)
    AppStorage.setOrCreate('skipNextTerminateConfirmation', false)
    try {
      webview.WebviewController.setRenderProcessMode(webview.RenderProcessMode.SINGLE)
      webview.WebviewController.setWebDestroyMode(webview.WebDestroyMode.FAST_MODE)
      logger.info('ArkWeb configured: renderProcessMode=' +
        webview.WebviewController.getRenderProcessMode().toString() + ', destroyMode=fast')
    } catch (e) {
      logger.error('Failed to configure ArkWeb process lifecycle: ' + e)
    }
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } catch (err) {
      logger.error('Failed to set colorMode: ' + err)
    }
    logger.info('Ability onCreate');
  }

  onDestroy(): void {
    logger.info('Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    logger.info('Ability onWindowStageCreate');
    windowStage.setWindowRectAutoSave(true).catch((e: Error) => {
      logger.warn('Window rect auto-save is unavailable: ' + e.message)
    })

    windowStage.loadContent('pages/Index', (loadError) => {
      if (loadError.code) {
        logger.error('Failed to load the content: ' + loadError.code + ' ' + loadError.message);
        return;
      }
      logger.info('Succeeded in loading the content.');

      windowStage.getMainWindow((windowError, mainWindow: window.Window) => {
        if (windowError.code) {
          logger.error('Failed to get main window: ' + windowError.code + ' ' + windowError.message);
          return;
        }
        this.mainWindow = mainWindow
        this.configurePcWindowTransparency(mainWindow)
        this.validatePcWindowChrome(mainWindow)
      })
    });
  }

  onWindowStageDestroy(): void {
    if (this.mainWindow !== null) {
      try {
        this.mainWindow.off('windowTitleButtonRectChange', this.titleButtonRectChangeHandler)
      } catch (e) {
        logger.warn('Failed to unregister title button rect listener: ' + e)
      }
      try {
        this.mainWindow.off('windowVisibilityChange', this.windowVisibilityChangeHandler)
      } catch (e) {
        logger.warn('Failed to unregister window visibility listener: ' + e)
      }
      try {
        this.mainWindow.off('windowRectChange', this.windowRectChangeHandler)
      } catch (e) {
        logger.warn('Failed to unregister window rect listener: ' + e)
      }
      this.mainWindow = null
    }
    logger.info('Ability onWindowStageDestroy');
  }

  onForeground(): void {
    AppStorage.setOrCreate('mainWindowVisible', true)
    logger.info('Ability onForeground');
  }

  onBackground(): void {
    AppStorage.setOrCreate('mainWindowVisible', false)
    try {
      DurableStateManager.collectGarbageOnce()
    } catch (e) {
      logger.warn('Deferred durable garbage collection failed: ' + e)
    }
    logger.info('Ability onBackground');
  }

  async onPrepareToTerminateAsync(): Promise<boolean> {
    let hasActiveSession: boolean = AppStorage.get<boolean>('hasActiveSshSession') ?? false
    let confirmationSuppressed: boolean =
      AppStorage.get<boolean>('skipNextTerminateConfirmation') ?? false
    AppStorage.setOrCreate('skipNextTerminateConfirmation', false)
    if (!InteractionPolicy.shouldConfirmApplicationClose(hasActiveSession, confirmationSuppressed)) {
      return !(await this.prepareApplicationClose())
    }
    if (this.mainWindow === null) {
      logger.warn('Application close canceled because the main window is unavailable')
      return true
    }
    try {
      let result = await this.mainWindow.getUIContext().getPromptAction().showDialog({
        title: 'Close active sessions?',
        message: 'Closing LeanTTY will disconnect all active SSH sessions.',
        buttons: [
          { text: 'Cancel', color: '#CDD6F4' },
          { text: 'Close LeanTTY', color: '#F38BA8' }
        ]
      })
      if (result.index !== 1) {
        return true
      }
      return !(await this.prepareApplicationClose())
    } catch (e) {
      logger.error('Application close confirmation failed: ' + e)
      return true
    }
  }

  private async prepareApplicationClose(): Promise<boolean> {
    try {
      await ApplicationCloseCoordinator.prepareTermination()
      logger.info('Application close preparation completed')
      return true
    } catch (e) {
      ApplicationCloseCoordinator.resetPreparation()
      logger.error('Application close preparation failed: ' + e)
      return false
    }
  }

  private validatePcWindowChrome(mainWindow: window.Window): void {
    try {
      mainWindow.on('windowVisibilityChange', this.windowVisibilityChangeHandler)
      logger.info('Window visibility listener registered')
    } catch (e) {
      logger.warn('Window visibility listener registration failed: ' + e)
    }

    try {
      mainWindow.on('windowRectChange', this.windowRectChangeHandler)
      logger.info('Window grid snap listener registered')
    } catch (e) {
      logger.warn('Window grid snap listener registration failed: ' + e)
    }

    try {
      logger.info('Window decor before=' + mainWindow.getWindowDecorVisible().toString())
      mainWindow.setWindowDecorVisible(false)
      logger.info('Window decor after=' + mainWindow.getWindowDecorVisible().toString())
    } catch (e) {
      logger.error('setWindowDecorVisible validation failed: ' + e)
    }

    try {
      mainWindow.setWindowDecorHeight(40)
      logger.info('Window decor height=' + mainWindow.getWindowDecorHeight().toString())
    } catch (e) {
      logger.warn('Window decor height validation failed: ' + e)
    }

    try {
      let rect: window.TitleButtonRect = mainWindow.getTitleButtonRect()
      this.publishTitleButtonRect(rect)
      logger.info('Title button rect: right=' + rect.right.toString() +
        ', top=' + rect.top.toString() + ', width=' + rect.width.toString() +
        ', height=' + rect.height.toString())
      mainWindow.on('windowTitleButtonRectChange', this.titleButtonRectChangeHandler)
    } catch (e) {
      logger.warn('Title button rect validation failed: ' + e)
    }
  }

  private configurePcWindowTransparency(mainWindow: window.Window): void {
    AppStorage.setOrCreate('windowTransparencyAvailable', false)
    try {
      mainWindow.setWindowBackgroundColor('#00000000')
      mainWindow.setWindowContainerColor('#00000000', '#FF1E1E2E')
      AppStorage.setOrCreate('windowTransparencyAvailable', true)
      logger.info('Window and PC container configured for restrained terminal transparency')
    } catch (e) {
      let error: BusinessError = e as BusinessError
      logger.warn('PC container transparency unavailable; using opaque terminal surface: code=' +
        error.code.toString() + ', message=' + error.message)
    }
  }

  private publishTitleButtonRect(rect: window.TitleButtonRect): void {
    if (rect.width > 0 && rect.height > 0) {
      AppStorage.setOrCreate('pcTitleButtonReservedWidth', rect.right + rect.width)
    }
  }

  private copyWindowRect(rect: window.Rect): window.Rect {
    return {
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height
    }
  }

  private snapWindowAfterDrag(startRect: window.Rect, endRect: window.Rect): void {
    if (this.mainWindow === null) {
      return
    }
    let widthChanged: boolean = Math.abs(endRect.width - startRect.width) >= 1
    let heightChanged: boolean = Math.abs(endRect.height - startRect.height) >= 1
    if (!widthChanged && !heightChanged) {
      return
    }

    let fontSize: number = InteractionPolicy.clampFontSize(
      AppStorage.get<number>('terminalFontSize') ?? InteractionPolicy.DEFAULT_FONT_SIZE)
    let density: number = 0
    try {
      density = this.mainWindow.getUIContext().vp2px(1)
    } catch (e) {
      logger.warn('Window grid snap skipped because display density is unavailable: ' + e)
      return
    }
    let targetWidth: number = widthChanged ?
      WindowGridSnapPolicy.snapWidth(endRect.width, fontSize, density) : endRect.width
    let targetHeight: number = heightChanged ?
      WindowGridSnapPolicy.snapHeight(endRect.height, fontSize, density) : endRect.height
    try {
      let limits: window.WindowLimits = this.mainWindow.getWindowLimits()
      targetWidth = WindowGridSnapPolicy.clampExtent(targetWidth, limits.minWidth, limits.maxWidth)
      targetHeight = WindowGridSnapPolicy.clampExtent(targetHeight, limits.minHeight, limits.maxHeight)
    } catch (e) {
      logger.warn('Window limits unavailable during grid snap: ' + e)
    }

    let leftEdgeMoved: boolean = widthChanged && Math.abs(endRect.left - startRect.left) >= 1
    let topEdgeMoved: boolean = heightChanged && Math.abs(endRect.top - startRect.top) >= 1
    let targetLeft: number = leftEdgeMoved ?
      startRect.left + startRect.width - targetWidth : endRect.left
    let targetTop: number = topEdgeMoved ?
      startRect.top + startRect.height - targetHeight : endRect.top
    if (targetWidth === endRect.width && targetHeight === endRect.height &&
      targetLeft === endRect.left && targetTop === endRect.top) {
      return
    }

    let snapWindow: window.Window = this.mainWindow
    snapWindow.resize(targetWidth, targetHeight).then(() => {
      if (targetLeft === endRect.left && targetTop === endRect.top) {
        logger.info('Window grid snap applied: width=' + targetWidth.toString() +
          ', height=' + targetHeight.toString() + ', fontSize=' + fontSize.toString())
        return
      }
      snapWindow.moveWindowTo(targetLeft, targetTop).then(() => {
        logger.info('Window grid snap applied: left=' + targetLeft.toString() +
          ', top=' + targetTop.toString() + ', width=' + targetWidth.toString() +
          ', height=' + targetHeight.toString() + ', fontSize=' + fontSize.toString())
      }).catch((e: Error) => {
        logger.warn('Window grid snap position correction failed: ' + e.message)
      })
    }).catch((e: Error) => {
      logger.warn('Window grid snap resize failed: ' + e.message)
    })
  }
}
