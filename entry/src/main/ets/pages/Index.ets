import { AppViewModel } from '../viewmodel/AppViewModel'
import { PaneInfo, TabInfo } from '../common/types/TerminalTypes'
import { SessionViewModel, TerminalMode } from '../viewmodel/SessionViewModel'
import { SshSessionState } from '../common/types/TerminalTypes'
import { ThemeManager, AppTheme, TransparencyMode, TransparencyPolicy } from '../view/theme/ThemeManager'
import { ChromeColors } from '../view/theme/ThemeConstants'
import { Logger } from '../common/logger/Logger'
import { ChromeBar } from '../view/components/ChromeBar'
import { TerminalPane } from '../view/components/TerminalPane'
import webview from '@ohos.web.webview'
import { common } from '@kit.AbilityKit'
import { InteractionPolicy, WorkspaceNavigationAction } from '../model/ui/InteractionPolicy'
import { UserPreferences } from '../model/settings/UserPreferences'
import { TerminalSurfaceController } from '../model/terminal/TerminalSurfaceController'
import { BrowserLauncher } from '../model/browser/BrowserLauncher'
import { ApplicationCloseCoordinator } from '../model/ui/ApplicationCloseCoordinator'

const logger: Logger = new Logger('IndexPage')
const WARM_TAB_RETENTION_MS: number = 30000
const MENU_ACTION_COUNT: number = 6

class PaneRuntime {
  id: string
  viewModel: SessionViewModel
  surface: TerminalSurfaceController
  generation: number = 0

  constructor(id: string, viewModel: SessionViewModel) {
    this.id = id
    this.viewModel = viewModel
    this.surface = new TerminalSurfaceController()
    this.viewModel.bindTerminalSurface(this.surface)
  }

  attachSurface(ctrl: webview.WebviewController): void {
    this.detachSurface()
    this.surface.attach(ctrl)
  }

  detachSurface(): void {
    this.surface.detach()
    this.viewModel.onTerminalSurfaceDetached()
  }
}

@Entry
@Component
struct Index {
  @State appVm: AppViewModel = new AppViewModel()
  @State tabs: TabInfo[] = []
  @State paneRuntimes: PaneRuntime[] = []
  @State activeTabIndex: number = 0
  @State chromeColors: ChromeColors = new ChromeColors()
  @State contentBg: string = '#FF1E1E2E'
  @State chromeBg: string = '#FF181825'
  @State backgroundMaterial: BlurStyle = BlurStyle.NONE
  @State menuOpen: boolean = false
  @StorageLink('terminalFontSize') fontSize: number = InteractionPolicy.DEFAULT_FONT_SIZE
  @StorageLink('mainWindowVisible') @Watch('onMainWindowVisibilityChanged')
  mainWindowVisible: boolean = true
  @StorageLink('windowTransparencyAvailable') @Watch('onWindowTransparencyAvailabilityChanged')
  windowTransparencyAvailable: boolean = false
  @State splitRatio: number = 0.5
  @State splitDragging: boolean = false
  @State splitHandleHovered: boolean = false
  @State splitHandleFocused: boolean = false
  @State menuSelectedIndex: number = 0
  @State transparencyLabel: string = 'Medium'
  @State transparencyDecreaseHovered: boolean = false
  @State transparencyIncreaseHovered: boolean = false
  @State fontDecreaseHovered: boolean = false
  @State fontIncreaseHovered: boolean = false
  @State warmTabId: string = ''
  @State checkpointingTabIds: string[] = []
  @State attentionPulsePaneId: string = ''
  @State attentionPulseToken: number = 0
  @State attentionPulseCount: number = 0
  private workspaceWidth: number = 0
  private splitDragStartRatio: number = 0.5
  private warmTabEvictionTimerId: number = -1
  @StorageLink('pcTitleButtonReservedWidth') titleButtonReservedWidth: number = 140
  private themeChangeHandler: () => void = () => { this.applyTheme() }
  private applicationCloseHandler: () => Promise<void> = async (): Promise<void> => {
    await this.disconnectAllRuntimes()
  }

  aboutToAppear(): void {
    this.fontSize = InteractionPolicy.clampFontSize(this.fontSize)
    let tab: TabInfo = this.appVm.addTab('ltty')
    this.addPaneRuntime(tab.panes[0])
    this.syncWorkspace()
    this.applyTheme()
    ThemeManager.getInstance().onThemeChange(this.themeChangeHandler)
    ApplicationCloseCoordinator.register(this.applicationCloseHandler)
    logger.info('Index page initialized')
  }

  aboutToDisappear(): void {
    ApplicationCloseCoordinator.unregister(this.applicationCloseHandler)
    ThemeManager.getInstance().removeThemeChange(this.themeChangeHandler)
    this.clearWarmTabEvictionTimer()
    AppStorage.setOrCreate('hasActiveSshSession', false)
    for (let i = 0; i < this.paneRuntimes.length; i++) {
      this.paneRuntimes[i].viewModel.disconnect()
      this.paneRuntimes[i].detachSurface()
    }
  }

  build() {
    Stack() {
      Column() {
        ChromeBar({
          tabs: this.tabs,
          activeTabIndex: this.activeTabIndex,
          chromeColors: this.chromeColors,
          chromeBackground: this.chromeBg,
          titleButtonReservedWidth: this.titleButtonReservedWidth,
          attentionPulsePaneId: this.attentionPulsePaneId,
          attentionPulseToken: this.attentionPulseToken,
          attentionPulseCount: this.attentionPulseCount,
          onTabSelect: (index: number) => { this.selectTab(index) },
          onTabClose: (index: number) => { this.requestCloseTab(index) },
          onNewTab: () => { this.newTab() },
          onMenuToggle: () => { this.toggleMenu() }
        })

        Stack() {
          ForEach(this.mountedPaneRuntimes(), (runtime: PaneRuntime) => {
            TerminalPane({
              focusVeilColor: this.chromeColors.paneFocusVeil,
              focusVeilOpacity: this.chromeColors.paneFocusVeilOpacity,
              sessionMode: this.paneMode(runtime.id),
              isFocused: this.isPaneFocused(runtime.id),
              paneId: runtime.id,
              closeButtonBackground: this.chromeColors.paneControlBackground,
              closeButtonBorder: this.chromeColors.paneControlBorder,
              closeButtonText: this.chromeColors.paneControlText,
              focusRing: this.chromeColors.focusRing,
              showCloseButton: this.isPaneInActiveTab(runtime.id) && this.activeTabIsSplit(),
              onWebControllerReady: (ctrl: webview.WebviewController) => {
                if (this.isPaneFocused(runtime.id)) {
                  runtime.viewModel.requestFocus()
                } else {
                  runtime.viewModel.requestBlur()
                }
                runtime.attachSurface(ctrl)
                runtime.viewModel.applyTerminalTheme(this.getTerminalThemeJson())
                runtime.surface.setFontSize(this.fontSize)
              },
              onPaneDisappear: () => {
                runtime.detachSurface()
              },
              onPaneKeyEvent: (event: KeyEvent) => {
                return this.handleKeyEvent(event)
              },
              onPaneFocus: (userInitiated: boolean) => {
                this.focusPane(runtime.id, userInitiated)
              },
              onSecondaryClick: () => {
                logger.info('Secondary click pane=' + runtime.id)
                runtime.surface.handleSecondaryAction()
              },
              onClosePane: () => { this.requestCloseActivePane() },
              onRendererExited: () => {
                logger.warn('ArkWeb renderer exited for pane=' + runtime.id + ', rebuilding WebView')
                this.recyclePaneWebView(runtime.id)
              }
            })
              .width(this.paneWidth(runtime.id))
              .opacity(this.isPaneInActiveTab(runtime.id) ? 1 : 0)
              .zIndex(this.isPaneInActiveTab(runtime.id) ? 1 : 0)
              .hitTestBehavior(this.isPaneInActiveTab(runtime.id) ? HitTestMode.Default : HitTestMode.None)
              .position(this.isRightPane(runtime.id) ?
                { x: this.splitRatio * 100 + '%', y: 0 } :
                { x: 0, y: 0 })
              .padding(this.isRightPane(runtime.id) ?
                { left: 4 } : {})
          }, (runtime: PaneRuntime) => runtime.id + '-' + runtime.generation.toString())

          if (this.activeTabIsSplit()) {
            Stack({ alignContent: Alignment.Center }) {
              Column()
                .width(1)
                .height('100%')
                .backgroundColor(this.chromeColors.divider)
                .opacity(0.50)
                .hitTestBehavior(HitTestMode.None)
              if (this.splitPaneNeedsAttention(false)) {
                Circle()
                  .width(5)
                  .height(5)
                  .fill(this.chromeColors.attention)
                  .position({ x: 0, y: 8 })
                  .accessibilityText('Left pane attention requested')
              }
              if (this.splitPaneNeedsAttention(true)) {
                Circle()
                  .width(5)
                  .height(5)
                  .fill(this.chromeColors.attention)
                  .position({ x: 9, y: 8 })
                  .accessibilityText('Right pane attention requested')
              }
              Column()
                .width(this.splitDragging || this.splitHandleHovered ? 3 : 2)
                .height(28)
                .backgroundColor(this.splitDragging || this.splitHandleHovered || this.splitHandleFocused ?
                  this.chromeColors.splitHandleActive : this.chromeColors.splitHandle)
                .borderRadius(2)
                .animation({ duration: 100, curve: Curve.EaseOut })
            }
              .width(14)
              .height('100%')
              .zIndex(2)
              .position({ x: this.splitRatio * 100 + '%', y: 0 })
              .translate({ x: -7, y: 0 })
              .accessibilityText('Resize split panes')
              .focusable(true)
              .onHover((hovered: boolean) => { this.splitHandleHovered = hovered })
              .onFocus(() => { this.splitHandleFocused = true })
              .onBlur(() => { this.splitHandleFocused = false })
              .onKeyEvent((event: KeyEvent) => {
                if (event.type !== KeyType.Down) { return true }
                if (event.keyCode === 2014 || event.keyCode === 2015) {
                  let direction: number = event.keyCode === 2014 ? -0.05 : 0.05
                  this.splitRatio = InteractionPolicy.clampSplitRatio(this.splitRatio + direction)
                  this.requestActiveTabFit()
                } else if (event.keyCode === 2054) {
                  this.splitRatio = 0.5
                  this.requestActiveTabFit()
                }
                return true
              })
              .gesture(
                PanGesture({ direction: PanDirection.Horizontal, distance: 1 })
                  .onActionStart(() => {
                    this.splitDragging = true
                    this.splitDragStartRatio = this.splitRatio
                  })
                  .onActionUpdate((event: GestureEvent) => {
                    if (this.workspaceWidth > 0) {
                      this.splitRatio = InteractionPolicy.clampSplitRatio(
                        this.splitDragStartRatio + event.offsetX / this.workspaceWidth)
                    }
                  })
                  .onActionEnd(() => {
                    this.splitDragging = false
                    this.requestActiveTabFit()
                    this.restoreActivePaneFocus()
                  })
                  .onActionCancel(() => {
                    this.splitDragging = false
                    this.restoreActivePaneFocus()
                  })
              )
          }
        }
        .layoutWeight(1)
        .clip(true)
        .width('100%')
        .backgroundColor(this.contentBg)
        .onAreaChange((oldArea: Area, newArea: Area) => {
          this.workspaceWidth = Number(newArea.width)
          this.requestActiveTabFit()
        })

      }
      .width('100%')
      .height('100%')

      if (this.menuOpen) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#00000000')
          .onClick(() => {
            this.menuOpen = false
            this.restoreActivePaneFocus()
          })
        this.menuPanel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundBlurStyle(this.backgroundMaterial, {
      policy: BlurStyleActivePolicy.FOLLOWS_WINDOW_ACTIVE_STATE
    })
  }

  private activeTabIsSplit(): boolean {
    let tab: TabInfo | null = this.activeTab()
    return tab !== null && tab.panes.length === 2
  }

  private activeTab(): TabInfo | null {
    if (this.activeTabIndex < 0 || this.activeTabIndex >= this.tabs.length) {
      return null
    }
    return this.tabs[this.activeTabIndex]
  }

  private mountedPaneRuntimes(): PaneRuntime[] {
    let mounted: PaneRuntime[] = []
    let active: TabInfo | null = this.activeTab()
    for (let tabIndex = 0; tabIndex < this.tabs.length; tabIndex++) {
      let tab: TabInfo = this.tabs[tabIndex]
      let isActiveTab: boolean = active !== null && tab.id === active.id
      let isWarmTab: boolean = tab.id === this.warmTabId
      let isCheckpointing: boolean = this.checkpointingTabIds.indexOf(tab.id) >= 0
      if (!isCheckpointing && !InteractionPolicy.shouldMountTab(isActiveTab, isWarmTab,
        this.tabHasActiveSession(tab), this.mainWindowVisible)) {
        continue
      }
      for (let paneIndex = 0; paneIndex < tab.panes.length; paneIndex++) {
        let runtime: PaneRuntime | null = this.findPaneRuntime(tab.panes[paneIndex].id)
        if (runtime !== null) {
          mounted.push(runtime)
        }
      }
    }
    return mounted
  }

  private onMainWindowVisibilityChanged(): void {
    logger.info('Main window visibility applied: visible=' + this.mainWindowVisible.toString())
    if (this.mainWindowVisible) {
      this.restoreActivePaneFocus()
      return
    }
    this.captureMountedTerminalSnapshots()
    if (this.warmTabId.length > 0) {
      this.checkpointAndDestroyTabBridge(this.warmTabId)
    }
    this.clearWarmTabEvictionTimer()
    this.warmTabId = ''
  }

  private onWindowTransparencyAvailabilityChanged(): void {
    this.applyTheme()
  }

  private captureMountedTerminalSnapshots(): void {
    let mounted: PaneRuntime[] = this.mountedPaneRuntimes()
    for (let i = 0; i < mounted.length; i++) {
      mounted[i].surface.captureSnapshot()
    }
  }

  private isPaneInActiveTab(paneId: string): boolean {
    let tab: TabInfo | null = this.activeTab()
    if (tab === null) {
      return false
    }
    for (let i = 0; i < tab.panes.length; i++) {
      if (tab.panes[i].id === paneId) {
        return true
      }
    }
    return false
  }

  private isPaneFocused(paneId: string): boolean {
    let tab: TabInfo | null = this.activeTab()
    return tab !== null && tab.activePaneId === paneId
  }

  private isRightPane(paneId: string): boolean {
    let tab: TabInfo | null = this.findTabForPane(paneId)
    return tab !== null && tab.panes.length === 2 && tab.panes[1].id === paneId
  }

  private splitPaneNeedsAttention(rightPane: boolean): boolean {
    let tab: TabInfo | null = this.activeTab()
    if (tab === null || tab.panes.length !== 2) {
      return false
    }
    let paneIndex: number = rightPane ? 1 : 0
    return tab.panes[paneIndex].needsAttention
  }

  private paneMode(paneId: string): TerminalMode {
    let pane: PaneInfo | null = this.appVm.getPane(paneId)
    return pane === null ? TerminalMode.IDLE : pane.mode
  }

  private activeSessionState(): SshSessionState {
    let pane: PaneInfo | null = this.appVm.getActivePane()
    return pane === null ? SshSessionState.IDLE : pane.state
  }

  private applyTheme(): void {
    let theme: AppTheme = ThemeManager.getInstance().getTheme()
    this.chromeColors = theme.chrome
    this.contentBg = theme.background(this.windowTransparencyAvailable)
    this.chromeBg = theme.chromeBackground(this.windowTransparencyAvailable)
    this.backgroundMaterial = this.windowTransparencyAvailable &&
      theme.transparencyMode !== TransparencyMode.OFF ?
      BlurStyle.BACKGROUND_REGULAR : BlurStyle.NONE
    this.transparencyLabel = TransparencyPolicy.label(theme.transparencyMode)
    let themeJson: string = theme.terminal.toJsInitObject()
    for (let i = 0; i < this.paneRuntimes.length; i++) {
      this.paneRuntimes[i].viewModel.applyTerminalTheme(themeJson)
    }
  }

  private getTerminalThemeJson(): string {
    return ThemeManager.getInstance().getTheme().terminal.toJsInitObject()
  }

  private newTab(): void {
    if (this.appVm.getTabs().length > 0) {
      this.deactivateActiveTab('')
    }
    let tab: TabInfo = this.appVm.addTab('ltty')
    this.addPaneRuntime(tab.panes[0])
    this.syncWorkspace()
    this.restoreActivePaneFocus()
  }

  private addPaneRuntime(pane: PaneInfo): void {
    let vm: SessionViewModel = new SessionViewModel()
    vm.setPaneIdentity(pane.id)
    vm.setOnStateChange((state: SshSessionState) => {
      this.updatePaneState(pane.id, state)
    })
    vm.setOnModeChange((mode: TerminalMode) => {
      this.updatePaneMode(pane.id, mode)
    })
    vm.setOnTitleChange((title: string) => {
      this.updatePaneTitle(pane.id, title)
    })
    vm.setOnLocalExit(() => { return this.requestLocalExit(pane.id) })
    vm.setOnConfirmKeyDelete((name: string, fingerprint: string,
      onConfirm: () => void, onCancel: () => void) => {
      this.requestKeyDelete(name, fingerprint, onConfirm, onCancel)
    })
    try {
      let ctx: common.Context | undefined = this.getUIContext().getHostContext()
      if (ctx !== undefined) {
        vm.loadSshConfig(ctx)
      }
    } catch (e) {
      logger.warn('loadSshConfig failed: ' + e)
    }
    let runtime: PaneRuntime = new PaneRuntime(pane.id, vm)
    runtime.surface.setOnCopyResult((success: boolean) => {
      this.showTransientFeedback(success ? 'Copied' : 'Copy failed')
    })
    runtime.surface.setOnBellAttention(() => {
      this.markPaneAttention(pane.id)
    })
    runtime.surface.setOnAttentionAcknowledged(() => {
      this.clearPaneAttention(pane.id)
    })
    runtime.surface.setOnOpenUrl((url: string) => {
      this.openUrlForPane(pane.id, runtime.generation, url)
    })
    this.paneRuntimes = this.paneRuntimes.concat([runtime])
  }

  private recyclePaneWebView(paneId: string): void {
    let runtime: PaneRuntime | null = this.findPaneRuntime(paneId)
    if (runtime === null) {
      return
    }
    runtime.detachSurface()
    runtime.generation += 1
    this.paneRuntimes = this.paneRuntimes.slice()
  }

  private selectTab(index: number): void {
    if (index < 0 || index >= this.tabs.length) {
      return
    }
    if (index === this.activeTabIndex) {
      this.appVm.clearPaneAttention(this.tabs[index].activePaneId)
      this.syncWorkspace()
      this.restoreActivePaneFocus()
      return
    }
    let targetTabId: string = this.tabs[index].id
    this.deactivateActiveTab(targetTabId)
    this.appVm.setActiveTab(index)
    this.appVm.clearPaneAttention(this.tabs[index].activePaneId)
    this.syncWorkspace()
    this.restoreActivePaneFocus()
  }

  private deactivateActiveTab(targetTabId: string): void {
    let tab: TabInfo | null = this.activeTab()
    if (tab === null) {
      return
    }
    let evictedTabId: string = InteractionPolicy.evictedWarmTab(tab.id, targetTabId, this.warmTabId)
    if (evictedTabId.length > 0) {
      this.checkpointAndDestroyTabBridge(evictedTabId)
    }
    this.clearWarmTabEvictionTimer()
    this.warmTabId = InteractionPolicy.warmTabAfterSwitch(tab.id)
    for (let i = 0; i < tab.panes.length; i++) {
      let runtime: PaneRuntime | null = this.findPaneRuntime(tab.panes[i].id)
      if (runtime !== null) {
        runtime.viewModel.requestBlur()
      }
    }
    this.scheduleWarmTabEviction(this.warmTabId)
  }

  private checkpointAndDestroyTabBridge(tabId: string): void {
    let tab: TabInfo | null = this.findTabById(tabId)
    if (tab === null) {
      return
    }
    if (!InteractionPolicy.shouldDetachTabOnEviction(this.tabHasActiveSession(tab))) {
      return
    }
    if (this.checkpointingTabIds.indexOf(tabId) >= 0) {
      return
    }
    this.checkpointingTabIds = this.checkpointingTabIds.concat([tabId])
    let pendingCaptures: number = tab.panes.length
    if (pendingCaptures === 0) {
      this.finishTabCheckpoint(tabId)
      return
    }
    for (let i = 0; i < tab.panes.length; i++) {
      let runtime: PaneRuntime | null = this.findPaneRuntime(tab.panes[i].id)
      if (runtime !== null) {
        runtime.surface.captureSnapshot(() => {
          pendingCaptures--
          if (pendingCaptures === 0) {
            this.finishTabCheckpoint(tabId)
          }
        })
      } else {
        pendingCaptures--
        if (pendingCaptures === 0) {
          this.finishTabCheckpoint(tabId)
        }
      }
    }
  }

  private finishTabCheckpoint(tabId: string): void {
    this.checkpointingTabIds = this.checkpointingTabIds.filter((id: string) => id !== tabId)
    let tab: TabInfo | null = this.findTabById(tabId)
    if (tab === null) {
      return
    }
    let active: TabInfo | null = this.activeTab()
    let shouldRemainMounted: boolean = InteractionPolicy.shouldMountTab(
      active !== null && active.id === tab.id,
      tab.id === this.warmTabId,
      this.tabHasActiveSession(tab),
      this.mainWindowVisible)
    if (shouldRemainMounted) {
      return
    }
    for (let i = 0; i < tab.panes.length; i++) {
      let runtime: PaneRuntime | null = this.findPaneRuntime(tab.panes[i].id)
      if (runtime !== null) {
        runtime.detachSurface()
      }
    }
  }

  private scheduleWarmTabEviction(tabId: string): void {
    if (tabId.length === 0) {
      return
    }
    this.warmTabEvictionTimerId = setTimeout(() => {
      this.warmTabEvictionTimerId = -1
      if (this.warmTabId !== tabId) {
        return
      }
      let active: TabInfo | null = this.activeTab()
      if (active !== null && active.id === tabId) {
        this.warmTabId = ''
        return
      }
      this.checkpointAndDestroyTabBridge(tabId)
      this.warmTabId = ''
    }, WARM_TAB_RETENTION_MS)
  }

  private clearWarmTabEvictionTimer(): void {
    if (this.warmTabEvictionTimerId >= 0) {
      clearTimeout(this.warmTabEvictionTimerId)
      this.warmTabEvictionTimerId = -1
    }
  }

  private async closeTab(index: number): Promise<void> {
    if (index < 0 || index >= this.tabs.length) {
      return
    }
    let tab: TabInfo = this.tabs[index]
    if (this.tabs.length === 1) {
      await this.terminateApplication(tab.panes[0].id)
      return
    }
    if (tab.id === this.warmTabId) {
      this.clearWarmTabEvictionTimer()
      this.warmTabId = ''
    }
    let removedRuntimes: PaneRuntime[] = this.removePaneRuntimes(tab.panes)
    this.appVm.removeTab(index)
    this.syncWorkspace()
    let activeAfterClose: TabInfo | null = this.activeTab()
    if (activeAfterClose !== null && activeAfterClose.id === this.warmTabId) {
      this.clearWarmTabEvictionTimer()
      this.warmTabId = ''
    }
    this.restoreActivePaneFocus()
    for (let i = 0; i < removedRuntimes.length; i++) {
      await this.disposeRuntime(removedRuntimes[i])
    }
  }

  private requestCloseTab(index: number): void {
    if (index < 0 || index >= this.tabs.length) {
      return
    }
    if (!this.tabHasActiveSession(this.tabs[index])) {
      this.closeTab(index)
      return
    }
    this.showConfirmation('Close active session?',
      'Closing this tab will disconnect its SSH session.', 'Close tab', () => { this.closeTab(index) })
  }

  private requestCloseActivePane(): void {
    let pane: PaneInfo | null = this.appVm.getActivePane()
    if (pane === null || pane.mode === TerminalMode.IDLE) {
      this.closeActivePane()
      return
    }
    this.showConfirmation('Close active pane?',
      'Closing this pane will disconnect its SSH session.', 'Close pane', () => { this.closeActivePane() })
  }

  private requestKeyDelete(name: string, fingerprint: string,
    onConfirm: () => void, onCancel: () => void): void {
    let detail: string = fingerprint.length > 0 ? '\nFingerprint: ' + fingerprint : ''
    this.showConfirmation('Delete key "' + name + '"?',
      'This permanently deletes the private and public key files.' + detail,
      'Delete key', onConfirm, onCancel)
  }

  private async showConfirmation(title: string, message: string, confirmLabel: string,
    onConfirm: () => void, onCancel?: () => void): Promise<void> {
    try {
      let result = await this.getUIContext().getPromptAction().showDialog({
        title: title,
        message: message,
        buttons: [
          { text: 'Cancel', color: this.chromeColors.commandBarText },
          { text: confirmLabel, color: '#F38BA8' }
        ]
      })
      if (result.index === 1) {
        onConfirm()
      } else if (onCancel !== undefined) {
        onCancel()
      }
    } catch (e) {
      logger.error('Confirmation dialog failed: ' + e)
      if (onCancel !== undefined) {
        onCancel()
      }
    } finally {
      setTimeout(() => { this.restoreActivePaneFocus() }, 0)
    }
  }

  private tabHasActiveSession(tab: TabInfo): boolean {
    for (let i = 0; i < tab.panes.length; i++) {
      if (tab.panes[i].mode !== TerminalMode.IDLE) {
        return true
      }
    }
    return false
  }

  private handleKeyEvent(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) {
      return false
    }
    let activeRuntime: PaneRuntime | null = this.activePaneRuntime()
    if (event.keyCode === 2070 && activeRuntime !== null && activeRuntime.surface.isSearchOpen() &&
      !activeRuntime.surface.isSearchComposing()) {
      activeRuntime.surface.closeSearch()
      return true
    }
    let ctrlKey: boolean = false
    let shiftKey: boolean = false
    let altKey: boolean = false
    if (event.getModifierKeyState) {
      ctrlKey = event.getModifierKeyState(['Ctrl'])
      shiftKey = event.getModifierKeyState(['Shift'])
      altKey = event.getModifierKeyState(['Alt'])
    } else {
      ctrlKey = (event.metaKey & 1) !== 0
    }
    if (InteractionPolicy.isTerminalTabKey(event.keyCode, ctrlKey, altKey, shiftKey)) {
      let runtime: PaneRuntime | null = activeRuntime
      if (runtime !== null) {
        runtime.viewModel.handleTerminalInput('\t')
        return true
      }
    }

    if (InteractionPolicy.isTerminalCopyOrInterruptKey(event.keyCode, ctrlKey, altKey)) {
      let runtime: PaneRuntime | null = activeRuntime
      if (runtime !== null) {
        runtime.surface.copyOrInterrupt()
        return true
      }
    }

    let navigationAction: WorkspaceNavigationAction = InteractionPolicy.workspaceNavigationAction(
      event.keyCode, ctrlKey, altKey, shiftKey)
    if (navigationAction === WorkspaceNavigationAction.NEXT_TAB ||
      navigationAction === WorkspaceNavigationAction.PREVIOUS_TAB) {
      let direction: number = navigationAction === WorkspaceNavigationAction.PREVIOUS_TAB ? -1 : 1
      let targetIndex: number = InteractionPolicy.wrappedTabIndex(
        this.activeTabIndex, this.tabs.length, direction)
      if (targetIndex >= 0 && targetIndex !== this.activeTabIndex) {
        this.selectTab(targetIndex)
      }
      return true
    }
    let activeTab: TabInfo | null = this.activeTab()
    let paneIndex: number = InteractionPolicy.workspacePaneIndex(
      navigationAction, activeTab === null ? 0 : activeTab.panes.length)
    if (activeTab !== null && paneIndex >= 0) {
      this.focusPane(activeTab.panes[paneIndex].id, true)
      return true
    }

    if (InteractionPolicy.isTerminalSearchShortcut(event.keyCode, ctrlKey, altKey, shiftKey)) {
      this.openActivePaneSearch()
      return true
    }

    if (ctrlKey && shiftKey && event.keyCode === 2036) {
      this.newTab()
      return true
    }
    if (ctrlKey && shiftKey && event.keyCode === 2039) {
      this.requestCloseActivePane()
      return true
    }
    if (ctrlKey && shiftKey && event.keyCode === 2020) {
      this.toggleSplit()
      return true
    }
    let transparencyDirection: number = InteractionPolicy.transparencyShortcutDirection(
      event.keyCode, ctrlKey, altKey)
    if (transparencyDirection !== 0) {
      this.adjustTransparency(transparencyDirection)
      return true
    }
    let fontSizeDirection: number = InteractionPolicy.fontSizeShortcutDirection(
      event.keyCode, ctrlKey, altKey)
    if (fontSizeDirection < 0) {
      this.handleFontDecrease()
      return true
    }
    if (fontSizeDirection > 0) {
      this.handleFontIncrease()
      return true
    }
    if (ctrlKey && !altKey && event.keyCode === 2000) {
      this.handleFontReset()
      return true
    }
    if (this.menuOpen) {
      this.handleMenuKeyEvent(event)
      return true
    }
    return false
  }

  private findPaneRuntime(paneId: string): PaneRuntime | null {
    for (let i = 0; i < this.paneRuntimes.length; i++) {
      if (this.paneRuntimes[i].id === paneId) {
        return this.paneRuntimes[i]
      }
    }
    return null
  }

  private activePaneRuntime(): PaneRuntime | null {
    let pane: PaneInfo | null = this.appVm.getActivePane()
    return pane === null ? null : this.findPaneRuntime(pane.id)
  }

  private updatePaneState(paneId: string, state: SshSessionState): void {
    this.appVm.updatePaneState(paneId, state)
    let tab: TabInfo | null = this.findTabForPane(paneId)
    let active: TabInfo | null = this.activeTab()
    if (tab !== null && !InteractionPolicy.shouldMountTab(
      active !== null && active.id === tab.id,
      tab.id === this.warmTabId,
      this.tabHasActiveSession(tab),
      this.mainWindowVisible)) {
      this.checkpointAndDestroyTabBridge(tab.id)
    }
    this.syncWorkspace()
  }

  private updatePaneMode(paneId: string, mode: TerminalMode): void {
    this.appVm.updatePaneMode(paneId, mode)
    this.syncWorkspace()
  }

  private updatePaneTitle(paneId: string, title: string): void {
    logger.info('Tab title update: paneId=' + paneId + ', title=' + title)
    this.appVm.updatePaneTitle(paneId, title)
    this.syncWorkspace()
  }

  private markPaneAttention(paneId: string): void {
    let persistAttention: boolean = InteractionPolicy.shouldPersistBellAttention(
      this.isPaneInActiveTab(paneId),
      this.isPaneFocused(paneId),
      this.mainWindowVisible,
      this.menuOpen)
    if (persistAttention) {
      this.appVm.markPaneAttention(paneId)
    }
    this.attentionPulsePaneId = paneId
    this.attentionPulseCount = InteractionPolicy.bellPulseCount(persistAttention)
    this.attentionPulseToken++
    this.syncWorkspace()
  }

  private clearPaneAttention(paneId: string): void {
    let pane: PaneInfo | null = this.appVm.getPane(paneId)
    if (pane === null || !pane.needsAttention) {
      return
    }
    this.appVm.clearPaneAttention(paneId)
    this.syncWorkspace()
  }

  private showTransientFeedback(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1200 })
    } catch (e) {
      logger.warn('Copy feedback failed: ' + e)
    }
  }

  private async openUrlForPane(paneId: string, generation: number, url: string): Promise<void> {
    let runtime: PaneRuntime | null = this.findPaneRuntime(paneId)
    if (runtime === null || runtime.generation !== generation || !this.isPaneInActiveTab(paneId)) {
      return
    }
    if (!this.isPaneFocused(paneId)) {
      this.focusPane(paneId, true)
    }
    try {
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext
      let opened: boolean = await BrowserLauncher.open(context, url)
      if (!opened) {
        opened = await BrowserLauncher.openUserGuide(context, url)
      }
      if (!opened) {
        this.showTransientFeedback('Unable to open link')
      }
    } catch (e) {
      logger.warn('Open link failed')
      this.showTransientFeedback('Unable to open link')
    }
  }

  private handleFontIncrease(): void {
    this.fontSize = InteractionPolicy.clampFontSize(this.fontSize + 1)
    this.applyFontSize()
  }

  private openActivePaneSearch(): void {
    let runtime: PaneRuntime | null = this.activePaneRuntime()
    if (runtime !== null) {
      runtime.surface.openSearch()
    }
  }

  private handleFontDecrease(): void {
    this.fontSize = InteractionPolicy.clampFontSize(this.fontSize - 1)
    this.applyFontSize()
  }

  private handleFontReset(): void {
    this.fontSize = InteractionPolicy.DEFAULT_FONT_SIZE
    this.applyFontSize()
  }

  private applyFontSize(): void {
    UserPreferences.saveFontSize(this.fontSize)
    for (let i = 0; i < this.paneRuntimes.length; i++) {
      this.paneRuntimes[i].surface.setFontSize(this.fontSize)
    }
  }

  private toggleSplit(): void {
    let tab: TabInfo | null = this.activeTab()
    if (tab === null) {
      return
    }
    if (tab.panes.length === 2) {
      return
    }
    let pane: PaneInfo | null = this.appVm.splitPane(tab.id)
    if (pane !== null) {
      this.addPaneRuntime(pane)
      this.syncWorkspace()
      this.restoreActivePaneFocus()
    }
  }

  private syncWorkspace(): void {
    this.tabs = this.appVm.getTabs().slice()
    this.activeTabIndex = this.appVm.getActiveTabIndex()
    AppStorage.setOrCreate('hasActiveSshSession', this.workspaceHasActiveSession())
  }

  private focusPane(paneId: string, userInitiated: boolean): void {
    let tab: TabInfo | null = this.activeTab()
    if (tab === null) {
      return
    }
    this.appVm.setActivePane(tab.id, paneId)
    if (userInitiated) {
      this.appVm.clearPaneAttention(paneId)
    }
    this.syncWorkspace()
    this.restoreActivePaneFocus()
  }

  private async closeActivePane(): Promise<void> {
    let tab: TabInfo | null = this.activeTab()
    let pane: PaneInfo | null = this.appVm.getActivePane()
    if (tab === null || pane === null) {
      return
    }
    await this.closePane(tab.id, pane.id)
  }

  private async closePane(tabId: string, paneId: string): Promise<void> {
    let tab: TabInfo | null = this.findTabById(tabId)
    if (tab === null) {
      return
    }
    if (tab.panes.length === 1) {
      await this.closeTab(this.findTabIndexForPane(paneId))
      return
    }
    let removedPane: PaneInfo | null = this.appVm.removePane(tab.id, paneId)
    if (removedPane === null) {
      return
    }
    let removedRuntimes: PaneRuntime[] = this.removePaneRuntimes([removedPane])
    this.syncWorkspace()
    this.restoreActivePaneFocus()
    if (removedRuntimes.length > 0) {
      await this.disposeRuntime(removedRuntimes[0])
    }
  }

  private requestLocalExit(paneId: string): boolean {
    let tabIndex: number = this.findTabIndexForPane(paneId)
    if (tabIndex < 0) {
      return false
    }
    let tab: TabInfo = this.tabs[tabIndex]
    let pane: PaneInfo | null = this.appVm.getPane(paneId)
    if (pane === null || pane.mode !== TerminalMode.IDLE) {
      return false
    }
    this.closePane(tab.id, paneId)
    return true
  }

  private findTabIndexForPane(paneId: string): number {
    for (let tabIndex = 0; tabIndex < this.tabs.length; tabIndex++) {
      for (let paneIndex = 0; paneIndex < this.tabs[tabIndex].panes.length; paneIndex++) {
        if (this.tabs[tabIndex].panes[paneIndex].id === paneId) {
          return tabIndex
        }
      }
    }
    return -1
  }

  private findTabById(tabId: string): TabInfo | null {
    for (let i = 0; i < this.tabs.length; i++) {
      if (this.tabs[i].id === tabId) {
        return this.tabs[i]
      }
    }
    return null
  }

  private findTabForPane(paneId: string): TabInfo | null {
    let index: number = this.findTabIndexForPane(paneId)
    return index < 0 ? null : this.tabs[index]
  }

  private async terminateApplication(paneId: string): Promise<void> {
    AppStorage.setOrCreate('skipNextTerminateConfirmation', true)
    try {
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext
      await context.terminateSelf()
    } catch (e) {
      ApplicationCloseCoordinator.resetPreparation()
      AppStorage.setOrCreate('skipNextTerminateConfirmation', false)
      logger.error('Application termination failed: ' + e)
      let runtime: PaneRuntime | null = this.findPaneRuntime(paneId)
      if (runtime !== null) {
        runtime.viewModel.writeError('Unable to close the application: ' + e)
      }
    }
  }

  private workspaceHasActiveSession(): boolean {
    for (let i = 0; i < this.tabs.length; i++) {
      if (this.tabHasActiveSession(this.tabs[i])) {
        return true
      }
    }
    return false
  }

  private removePaneRuntimes(panes: PaneInfo[]): PaneRuntime[] {
    let removed: PaneRuntime[] = []
    let kept: PaneRuntime[] = []
    for (let i = 0; i < this.paneRuntimes.length; i++) {
      let shouldRemove: boolean = false
      for (let j = 0; j < panes.length; j++) {
        if (this.paneRuntimes[i].id === panes[j].id) {
          shouldRemove = true
          break
        }
      }
      if (shouldRemove) {
        removed.push(this.paneRuntimes[i])
      } else {
        kept.push(this.paneRuntimes[i])
      }
    }
    this.paneRuntimes = kept
    return removed
  }

  private async disposeRuntime(runtime: PaneRuntime): Promise<void> {
    try {
      await runtime.viewModel.disconnect()
    } catch (e) {
      logger.warn('Pane disconnect failed: ' + e)
    }
    runtime.detachSurface()
  }

  private async disconnectAllRuntimes(): Promise<void> {
    let runtimes: PaneRuntime[] = this.paneRuntimes.slice()
    let pending: Promise<void>[] = []
    for (let i: number = 0; i < runtimes.length; i++) {
      pending.push(runtimes[i].viewModel.disconnect())
    }
    await Promise.all(pending)
  }

  private requestActiveTabFit(): void {
    let tab: TabInfo | null = this.activeTab()
    if (tab === null) {
      return
    }
    for (let i = 0; i < tab.panes.length; i++) {
      let runtime: PaneRuntime | null = this.findPaneRuntime(tab.panes[i].id)
      if (runtime !== null) {
        runtime.viewModel.requestTerminalFit()
      }
    }
  }

  private restoreActivePaneFocus(): void {
    let tab: TabInfo | null = this.activeTab()
    if (tab === null) {
      return
    }
    let activeRuntime: PaneRuntime | null = null
    for (let i = 0; i < tab.panes.length; i++) {
      let runtime: PaneRuntime | null = this.findPaneRuntime(tab.panes[i].id)
      if (runtime === null) {
        continue
      }
      if (tab.panes[i].id === tab.activePaneId) {
        activeRuntime = runtime
      } else {
        runtime.viewModel.requestBlur()
      }
    }
    if (activeRuntime !== null) {
      let paneId: string = activeRuntime.id
      let runtime: PaneRuntime = activeRuntime
      setTimeout(() => {
        if (!this.isPaneFocused(paneId)) {
          return
        }
        runtime.viewModel.requestFocus()
        runtime.viewModel.requestTerminalFit()
      }, 0)
    }
  }

  private paneWidth(paneId: string): string {
    let tab: TabInfo | null = this.findTabForPane(paneId)
    if (tab === null || tab.panes.length !== 2) {
      return '100%'
    }
    return this.isRightPane(paneId) ? (1 - this.splitRatio) * 100 + '%' : this.splitRatio * 100 + '%'
  }

  private toggleMenu(): void {
    this.menuOpen = !this.menuOpen
    if (this.menuOpen) {
      this.menuSelectedIndex = 0
      if (!this.isMenuItemEnabled(0)) {
        this.moveMenuSelection(1)
      }
    } else {
      this.restoreActivePaneFocus()
    }
  }

  private handleMenuKeyEvent(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) {
      return true
    }
    if (event.keyCode === 2070) {
      this.menuOpen = false
      this.restoreActivePaneFocus()
      return true
    }
    if (event.keyCode === 2012) {
      this.moveMenuSelection(-1)
      return true
    }
    if (event.keyCode === 2013) {
      this.moveMenuSelection(1)
      return true
    }
    if (this.menuSelectedIndex === 4 && event.keyCode === 2014) {
      this.adjustTransparency(-1)
      return true
    }
    if (this.menuSelectedIndex === 4 && event.keyCode === 2015) {
      this.adjustTransparency(1)
      return true
    }
    if (this.menuSelectedIndex === 5 && event.keyCode === 2014) {
      this.handleFontDecrease()
      return true
    }
    if (this.menuSelectedIndex === 5 && event.keyCode === 2015) {
      this.handleFontIncrease()
      return true
    }
    if (event.keyCode === 2054) {
      this.executeMenuSelection()
      return true
    }
    return true
  }

  private executeMenuSelection(): void {
    let selected: number = this.menuSelectedIndex
    if (!this.isMenuItemEnabled(selected)) {
      return
    }
    if (selected === 4 || selected === 5) { return }
    if (selected === 3) {
      this.menuOpen = false
      this.openActivePaneSearch()
      return
    }
    this.menuOpen = false
    setTimeout(() => { this.restoreActivePaneFocus() }, 0)
    if (selected === 0) { this.newTab(); return }
    if (selected === 1) { this.toggleSplit(); return }
    if (selected === 2) { this.requestCloseActivePane(); return }
  }

  private adjustTransparency(direction: number): void {
    let manager: ThemeManager = ThemeManager.getInstance()
    let current: TransparencyMode = manager.getTransparencyMode()
    if ((direction < 0 && !TransparencyPolicy.canDecrease(current)) ||
      (direction > 0 && !TransparencyPolicy.canIncrease(current))) {
      return
    }
    let mode: TransparencyMode = manager.stepTransparencyMode(direction)
    this.transparencyLabel = TransparencyPolicy.label(mode)
    UserPreferences.saveTransparencyMode(mode)
  }

  private moveMenuSelection(direction: number): void {
    let next: number = this.menuSelectedIndex
    for (let i = 0; i < MENU_ACTION_COUNT; i++) {
      next = (next + direction + MENU_ACTION_COUNT) % MENU_ACTION_COUNT
      if (this.isMenuItemEnabled(next)) {
        this.menuSelectedIndex = next
        return
      }
    }
  }

  private isMenuItemEnabled(index: number): boolean {
    if (index === 0) { return true }
    if (index === 1) { return !this.activeTabIsSplit() }
    if (index === 2) { return this.activeTabIsSplit() }
    if (index === 3) { return this.activePaneRuntime() !== null }
    return true
  }

  @Builder
  menuPanel() {
    Column() {
      this.menuRow(0, '+', 'New Tab', 'Ctrl+Shift+T', true, () => { this.newTab() })
      this.menuRow(1, '⋕', 'Split Pane', 'Ctrl+Shift+D', !this.activeTabIsSplit(), () => { this.toggleSplit() })
      this.menuRow(2, '✕', 'Close Pane', 'Ctrl+Shift+W', this.activeTabIsSplit(), () => { this.requestCloseActivePane() })
      this.menuRow(3, '⌕', 'Search', 'Ctrl+Alt+F', this.activePaneRuntime() !== null,
        () => { this.openActivePaneSearch() }, true, false)
      this.menuDivider()
      this.transparencyMenuRow()
      this.fontSizeMenuRow()
    }
    .width(292)
    .backgroundColor(this.chromeColors.commandBarBackground)
    .border({ width: 1, color: this.chromeColors.commandBarBorder, radius: 8 })
    .padding({ top: 4, bottom: 4 })
    .position({ x: '100%', y: 42 })
    .translate({ x: -304 - this.titleButtonReservedWidth, y: 0 })
    .shadow({ radius: 12, color: '#00000040', offsetY: 4 })
    .focusable(true)
    .defaultFocus(true)
    .onKeyEvent((event: KeyEvent) => { return this.handleMenuKeyEvent(event) })
  }

  @Builder
  menuRow(index: number, icon: string, label: string, shortcut: string, enabled: boolean, action?: () => void,
    closeAfterAction: boolean = true, restoreFocusAfterAction: boolean = true) {
    Row() {
      Text(icon)
        .fontSize(14)
        .fontColor(enabled ? this.chromeColors.commandBarText : this.chromeColors.commandBarPlaceholder)
        .width(24)
        .textAlign(TextAlign.Center)
      Text(label)
        .fontSize(13)
        .fontColor(enabled ? this.chromeColors.commandBarText : this.chromeColors.commandBarPlaceholder)
        .layoutWeight(1)
        .margin({ left: 8 })
      if (shortcut.length > 0) {
        Text(shortcut)
          .fontSize(11)
          .fontColor(this.chromeColors.commandBarPlaceholder)
          .margin({ right: 8 })
      }
    }
    .width('100%')
    .height(36)
    .padding({ left: 12, right: 12 })
    .borderRadius(4)
    .backgroundColor(index === this.menuSelectedIndex ? this.chromeColors.commandBarBorder : '#00000000')
    .focusable(enabled)
    .accessibilityText(label + (shortcut.length > 0 ? ', ' + shortcut : ''))
    .onHover((hovered: boolean) => { if (hovered) { this.menuSelectedIndex = index } })
    .onClick(() => {
      if (enabled && action !== undefined) {
        if (closeAfterAction) {
          this.menuOpen = false
        }
        action()
        if (closeAfterAction && restoreFocusAfterAction) {
          setTimeout(() => { this.restoreActivePaneFocus() }, 0)
        }
      }
    })
  }

  @Builder
  transparencyMenuRow() {
    Row() {
      Text('◐')
        .fontSize(14)
        .fontColor(this.chromeColors.commandBarText)
        .width(24)
        .textAlign(TextAlign.Center)
      Text('Transparency')
        .fontSize(13)
        .fontColor(this.chromeColors.commandBarText)
        .layoutWeight(1)
        .margin({ left: 8 })
      Text('−')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(TransparencyPolicy.canDecrease(ThemeManager.getInstance().getTransparencyMode()) ?
          this.chromeColors.commandBarText : this.chromeColors.commandBarPlaceholder)
        .width(32)
        .height(28)
        .textAlign(TextAlign.Center)
        .borderRadius(4)
        .border({ width: 1, color: this.chromeColors.commandBarBorder })
        .backgroundColor(this.transparencyDecreaseHovered ? this.chromeColors.commandBarBorder : '#00000000')
        .enabled(TransparencyPolicy.canDecrease(ThemeManager.getInstance().getTransparencyMode()))
        .focusable(false)
        .accessibilityText('Decrease transparency, Ctrl+Alt+-')
        .onHover((hovered: boolean) => { this.transparencyDecreaseHovered = hovered })
        .bindTips('Ctrl+Alt+-', {
          appearingTime: 300,
          disappearingTime: 100
        })
        .onClick(() => {
          this.menuSelectedIndex = 4
          this.adjustTransparency(-1)
        })
      Text(this.transparencyLabel)
        .fontSize(11)
        .fontColor(this.chromeColors.commandBarPlaceholder)
        .width(56)
        .textAlign(TextAlign.Center)
      Text('+')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(TransparencyPolicy.canIncrease(ThemeManager.getInstance().getTransparencyMode()) ?
          this.chromeColors.commandBarText : this.chromeColors.commandBarPlaceholder)
        .width(32)
        .height(28)
        .textAlign(TextAlign.Center)
        .borderRadius(4)
        .border({ width: 1, color: this.chromeColors.commandBarBorder })
        .backgroundColor(this.transparencyIncreaseHovered ? this.chromeColors.commandBarBorder : '#00000000')
        .enabled(TransparencyPolicy.canIncrease(ThemeManager.getInstance().getTransparencyMode()))
        .focusable(false)
        .accessibilityText('Increase transparency, Ctrl+Alt+=')
        .onHover((hovered: boolean) => { this.transparencyIncreaseHovered = hovered })
        .bindTips('Ctrl+Alt+=', {
          appearingTime: 300,
          disappearingTime: 100
        })
        .onClick(() => {
          this.menuSelectedIndex = 4
          this.adjustTransparency(1)
        })
    }
    .width('100%')
    .height(40)
    .padding({ left: 12, right: 12 })
    .borderRadius(4)
    .backgroundColor(this.menuSelectedIndex === 4 ? this.chromeColors.commandBarBorder : '#00000000')
    .focusable(true)
    .accessibilityText('Transparency, ' + this.transparencyLabel +
      '. Use left and right arrow keys to adjust')
    .onHover((hovered: boolean) => { if (hovered) { this.menuSelectedIndex = 4 } })
    .onClick(() => { this.menuSelectedIndex = 4 })
  }

  @Builder
  fontSizeMenuRow() {
    Row() {
      Text('Aa')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.chromeColors.commandBarText)
        .width(24)
        .textAlign(TextAlign.Center)
      Text('Font Size')
        .fontSize(13)
        .fontColor(this.chromeColors.commandBarText)
        .layoutWeight(1)
        .margin({ left: 8 })
      Text('−')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.fontSize > InteractionPolicy.MIN_FONT_SIZE ?
          this.chromeColors.commandBarText : this.chromeColors.commandBarPlaceholder)
        .width(32)
        .height(28)
        .textAlign(TextAlign.Center)
        .borderRadius(4)
        .border({ width: 1, color: this.chromeColors.commandBarBorder })
        .backgroundColor(this.fontDecreaseHovered ? this.chromeColors.commandBarBorder : '#00000000')
        .enabled(this.fontSize > InteractionPolicy.MIN_FONT_SIZE)
        .focusable(false)
        .accessibilityText('Decrease font size, Ctrl+-')
        .onHover((hovered: boolean) => { this.fontDecreaseHovered = hovered })
        .bindTips('Ctrl+-', {
          appearingTime: 300,
          disappearingTime: 100
        })
        .onClick(() => {
          this.menuSelectedIndex = 5
          this.handleFontDecrease()
        })
      Text(this.fontSize.toString() + ' px')
        .fontSize(11)
        .fontColor(this.chromeColors.commandBarPlaceholder)
        .width(56)
        .textAlign(TextAlign.Center)
      Text('+')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.fontSize < InteractionPolicy.MAX_FONT_SIZE ?
          this.chromeColors.commandBarText : this.chromeColors.commandBarPlaceholder)
        .width(32)
        .height(28)
        .textAlign(TextAlign.Center)
        .borderRadius(4)
        .border({ width: 1, color: this.chromeColors.commandBarBorder })
        .backgroundColor(this.fontIncreaseHovered ? this.chromeColors.commandBarBorder : '#00000000')
        .enabled(this.fontSize < InteractionPolicy.MAX_FONT_SIZE)
        .focusable(false)
        .accessibilityText('Increase font size, Ctrl+=')
        .onHover((hovered: boolean) => { this.fontIncreaseHovered = hovered })
        .bindTips('Ctrl+=', {
          appearingTime: 300,
          disappearingTime: 100
        })
        .onClick(() => {
          this.menuSelectedIndex = 5
          this.handleFontIncrease()
        })
    }
    .width('100%')
    .height(40)
    .padding({ left: 12, right: 12 })
    .borderRadius(4)
    .backgroundColor(this.menuSelectedIndex === 5 ? this.chromeColors.commandBarBorder : '#00000000')
    .focusable(true)
    .accessibilityText('Font size, ' + this.fontSize.toString() + ' pixels. ' +
      'Use left and right arrow keys to adjust. Ctrl+0 resets')
    .onHover((hovered: boolean) => { if (hovered) { this.menuSelectedIndex = 5 } })
    .onClick(() => { this.menuSelectedIndex = 5 })
  }

  @Builder
  menuDivider() {
    Row()
      .width('100%')
      .height(1)
      .backgroundColor(this.chromeColors.divider)
      .margin({ top: 4, bottom: 4, left: 12, right: 12 })
  }
}
