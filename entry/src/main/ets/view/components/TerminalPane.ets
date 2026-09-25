import { TerminalMode } from '../../common/types/TerminalTypes'
import { common } from '@kit.AbilityKit'
import { UiText } from '../../model/ui/UiText'
import { NativeTerminalPane } from './NativeTerminalPane'
import { TerminalSurfaceController } from '../../model/terminal/TerminalSurfaceController'

@Component
export struct TerminalPane {
  surface: TerminalSurfaceController = new TerminalSurfaceController()
  onNativeControllerReady: () => void = () => {}
  @Prop focusVeilColor: string = '#11111B'
  @Prop normalBackground: string = '#FF1E1E2E'
  @Prop reverseBackground: string = '#FFCDD6F4'
  @State reverseVideo: boolean = false
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
  onPaneDisappear: () => void = () => {}
  onPaneKeyEvent: (event: KeyEvent) => boolean = () => false
  onPaneFocus: (userInitiated: boolean) => void = () => {}
  onSecondaryClick: () => void = () => {}
  onClosePane: () => void = () => {}
  onRendererExited: () => void = () => {}
  aboutToDisappear(): void {
    this.onPaneDisappear()
  }

  private text(name: string): string {
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext
    return UiText.get(context, name)
  }

  build() {
    Stack() {
      NativeTerminalPane({ surface: this.surface, paneId: this.paneId, isFocused: this.isFocused,
        onKey: this.onPaneKeyEvent, onReady: this.onNativeControllerReady,
        onReverseVideo: (enabled: boolean) => { this.reverseVideo = enabled },
        onRebuildDisplay: this.onRendererExited })

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
          .accessibilityText(this.text('a11y_close_active_split'))
          .onClick(() => { this.onClosePane() })
          .onHover((hovered: boolean) => { this.closeButtonHovered = hovered })
          .onFocus(() => { this.closeButtonFocused = true })
          .onBlur(() => { this.closeButtonFocused = false })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.reverseVideo ? this.reverseBackground : this.normalBackground)
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
