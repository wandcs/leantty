import webview from '@ohos.web.webview'
import { TerminalMode } from '../../common/types/TerminalTypes'

@Component
export struct TerminalPane {
  private webCtrl: webview.WebviewController = new webview.WebviewController()
  @Prop focusVeilColor: string = '#11111B'
  @Prop focusVeilOpacity: number = 0.20
  @Prop sessionMode: TerminalMode = TerminalMode.IDLE
  @Prop isFocused: boolean = true
  @Prop paneId: string = ''
  @Prop showCloseButton: boolean = false
  @Prop closeButtonBackground: string = '#181825'
  @Prop closeButtonBorder: string = '#45475A'
  @Prop closeButtonText: string = '#CDD6F4'
  @Prop focusRing: string = '#89B4FA'
  @State closeButtonHovered: boolean = false
  @State closeButtonFocused: boolean = false
  onWebControllerReady: (ctrl: webview.WebviewController) => void = () => {}
  onPaneDisappear: () => void = () => {}
  onPaneKeyEvent: (event: KeyEvent) => boolean = () => false
  onPaneFocus: (userInitiated: boolean) => void = () => {}
  onSecondaryClick: () => void = () => {}
  onClosePane: () => void = () => {}
  onRendererExited: () => void = () => {}
  aboutToDisappear(): void {
    this.onPaneDisappear()
  }

  build() {
    Stack() {
      Web({
        src: $rawfile('terminal.html'),
        controller: this.webCtrl,
        renderMode: RenderMode.ASYNC_RENDER,
        sharedRenderProcessToken: 'leantty-terminal'
      })
        .width('100%')
        .height('100%')
        .javaScriptAccess(true)
        .domStorageAccess(false)
        .fileAccess(false)
        .onlineImageAccess(false)
        .mixedMode(MixedMode.None)
        .darkMode(WebDarkMode.Off)
        .zoomAccess(false)
        .zoomControlAccess(false)
        .overviewModeAccess(false)
        .backgroundColor('#00000000')
        .onControllerAttached(() => {
        })
        .onPageEnd(() => {
          this.onWebControllerReady(this.webCtrl)
        })
        .onRenderExited(() => {
          this.onRendererExited()
        })
        .onContextMenuShow((event: OnContextMenuShowEvent) => {
          this.onPaneFocus(true)
          event.result.closeContextMenu()
          return true
        })
        .onKeyPreIme((event: KeyEvent) => {
          return this.onPaneKeyEvent(event)
        })
        .onKeyEventDispatch((event: KeyEvent) => {
          return this.onPaneKeyEvent(event)
        })
        .onInterceptKeyEvent((event: KeyEvent) => {
          return this.onPaneKeyEvent(event)
        })

      if (!this.isFocused) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(this.focusVeilColor)
          .opacity(this.focusVeilOpacity)
          .transition(TransitionEffect.OPACITY.animation({ duration: 140, curve: Curve.EaseOut }))
      }

      if (this.showCloseButton && this.isFocused) {
        Text('×')
          .fontSize(16)
          .fontColor(this.closeButtonText)
          .textAlign(TextAlign.Center)
          .width(28)
          .height(28)
          .backgroundColor(this.closeButtonHovered ? this.closeButtonBorder : this.closeButtonBackground)
          .border({
            width: this.closeButtonFocused ? 2 : 1,
            color: this.closeButtonFocused ? this.focusRing : this.closeButtonBorder,
            radius: 6
          })
          .position({ x: '100%', y: 8 })
          .translate({ x: -38, y: 0 })
          .focusable(true)
          .accessibilityText('Close active pane')
          .onClick(() => { this.onClosePane() })
          .onHover((hovered: boolean) => { this.closeButtonHovered = hovered })
          .onFocus(() => { this.closeButtonFocused = true })
          .onBlur(() => { this.closeButtonFocused = false })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#00000000')
    .onClick(() => {
      this.onPaneFocus(true)
    })
    .onMouse((event: MouseEvent) => {
      if (event.button === MouseButton.Right && event.action === MouseAction.Release) {
        event.stopPropagation()
        this.onPaneFocus(true)
        this.onSecondaryClick()
      }
    })
    .onAppear(() => {
      if (this.isFocused) {
        this.onPaneFocus(false)
      }
    })
  }
}
